import CryptoKit
import Foundation

nonisolated enum BillingPDFGenerationError: Error, LocalizedError, Equatable {
    case unavailable
    case invalidIntent
    case changed
    case tooManyPending

    var errorDescription: String? {
        switch self {
        case .unavailable: "The saved PDF generation request could not be read or written. Review this billing document."
        case .invalidIntent: "The saved PDF generation request is invalid. Review this billing document."
        case .changed: "The billing document changed while its PDF was being prepared. The current version will be retried."
        case .tooManyPending: "Too many billing PDFs are waiting for generation. Review the document queue."
        }
    }
}

/// The source digest contains no customer text. Length prefixes keep distinct
/// source value sequences from having the same byte representation.
nonisolated enum BillingPDFSourceDigest {
    static func make(_ values: [String]) -> String {
        var bytes = Data()
        for value in values {
            let encoded = Data(value.utf8)
            var length = UInt64(encoded.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(encoded)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct BillingPDFGenerationIntent: Codable, Equatable, Sendable {
    enum DocumentKind: String, Codable, Sendable { case estimate, invoice }
    enum Stage: String, Codable, Sendable { case pending, rendered }

    let companyID: UUID
    let documentID: UUID
    let kind: DocumentKind
    let sourceDigest: String
    let generationID: UUID
    let createdAt: Date
    var stage: Stage
    var renderedFilePath: String?
    var renderedByteCount: Int?
    var renderedFileDigest: String?

    var key: String {
        BillingPDFSourceDigest.make([companyID.uuidString.lowercased(), kind.rawValue,
                                     documentID.uuidString.lowercased()])
    }
}

/// A local write-ahead checkpoint for the device that saved the document.
/// The caller must verify the workspace and exact source before and after each
/// suspension. A rendered URL is recorded before saving the attachment, so a
/// relaunch can reconcile that exact file instead of rendering another version.
actor BillingPDFGenerationJournal {
    static let device = BillingPDFGenerationJournal(directory:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BillingPDFGeneration-v1", isDirectory: true),
        generatedRoot: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("GunnAire Customer Documents", isDirectory: true))

    private let directory: URL?
    private let generatedRoot: URL?
    private var activeKeys: Set<String> = []

    init(directory: URL?, generatedRoot: URL?) {
        self.directory = directory
        self.generatedRoot = generatedRoot
    }

    func claim(_ intent: BillingPDFGenerationIntent) -> Bool {
        activeKeys.insert(intent.key).inserted
    }

    func release(_ intent: BillingPDFGenerationIntent) {
        activeKeys.remove(intent.key)
    }

    func record(companyID: UUID, documentID: UUID, kind: BillingPDFGenerationIntent.DocumentKind,
                sourceDigest: String, now: Date = Date()) throws -> BillingPDFGenerationIntent {
        guard Self.validDigest(sourceDigest) else { throw BillingPDFGenerationError.invalidIntent }
        let probe = BillingPDFGenerationIntent(companyID: companyID, documentID: documentID, kind: kind,
            sourceDigest: sourceDigest, generationID: UUID(), createdAt: now, stage: .pending,
            renderedFilePath: nil, renderedByteCount: nil, renderedFileDigest: nil)
        if let previous = try read(key: probe.key), previous.sourceDigest == sourceDigest {
            if previous.stage == .pending || (try? verifyRenderedFile(previous)) != nil { return previous }
            try preserveSuperseded(previous)
        } else if let previous = try read(key: probe.key) {
            try preserveSuperseded(previous)
        }
        try write(probe)
        return probe
    }

    func rendered(_ intent: BillingPDFGenerationIntent, fileURL: URL,
                  byteCount: Int) throws -> BillingPDFGenerationIntent {
        guard isInsideGeneratedRoot(fileURL), byteCount > 0,
              let current = try read(key: intent.key), current == intent,
              current.stage == .pending else { throw BillingPDFGenerationError.changed }
        let digest = try fileDigest(fileURL, expectedByteCount: byteCount)
        var updated = current
        updated.stage = .rendered
        updated.renderedFilePath = fileURL.path
        updated.renderedByteCount = byteCount
        updated.renderedFileDigest = digest
        try write(updated)
        return updated
    }

    func current(_ intent: BillingPDFGenerationIntent) throws -> BillingPDFGenerationIntent? {
        guard let value = try read(key: intent.key),
              value.generationID == intent.generationID else { return nil }
        if value.stage == .rendered { try verifyRenderedFile(value) }
        return value
    }

    func superseded(companyID: UUID) throws -> [BillingPDFGenerationIntent] {
        guard let directory else { throw BillingPDFGenerationError.unavailable }
        let folder = directory.appendingPathComponent("Superseded", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        do {
            try Self.validateDirectory(folder, create: false)
            let files = try FileManager.default.contentsOfDirectory(at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard files.count <= 1_000 else { throw BillingPDFGenerationError.tooManyPending }
            return try files.filter { $0.pathExtension == "json" }.compactMap { file in
                let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard info.isRegularFile == true, info.isSymbolicLink != true,
                      (info.fileSize ?? Int.max) <= 8_192 else { throw BillingPDFGenerationError.invalidIntent }
                let value = try JSONDecoder().decode(BillingPDFGenerationIntent.self, from: Data(contentsOf: file))
                return value.companyID == companyID ? value : nil
            }.sorted { $0.createdAt < $1.createdAt }
        } catch let error as BillingPDFGenerationError { throw error }
        catch { throw BillingPDFGenerationError.unavailable }
    }

    func complete(_ intent: BillingPDFGenerationIntent) throws {
        guard let current = try read(key: intent.key),
              current.generationID == intent.generationID else { throw BillingPDFGenerationError.changed }
        guard let directory else { throw BillingPDFGenerationError.unavailable }
        do {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(intent.key + ".json"))
        } catch { throw BillingPDFGenerationError.unavailable }
    }

    func pending(companyID: UUID) throws -> [BillingPDFGenerationIntent] {
        guard let directory else { throw BillingPDFGenerationError.unavailable }
        if !FileManager.default.fileExists(atPath: directory.path) {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: directory.path)) != nil {
                throw BillingPDFGenerationError.invalidIntent
            }
            return []
        }
        let files: [URL]
        do {
            try Self.validateDirectory(directory, create: false)
            files = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        } catch let error as BillingPDFGenerationError { throw error }
        catch { throw BillingPDFGenerationError.unavailable }
        guard files.count <= 1_000 else { throw BillingPDFGenerationError.tooManyPending }
        return try files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let value = try read(key: file.deletingPathExtension().lastPathComponent),
                  value.companyID == companyID else { return nil }
            if value.stage == .rendered { try verifyRenderedFile(value) }
            return value
        }.sorted { $0.createdAt < $1.createdAt }
    }

    private func read(key: String) throws -> BillingPDFGenerationIntent? {
        guard Self.validDigest(key), let directory else { throw BillingPDFGenerationError.unavailable }
        let file = directory.appendingPathComponent(key + ".json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) != nil {
                throw BillingPDFGenerationError.invalidIntent
            }
            return nil
        }
        do {
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true,
                  (info.fileSize ?? Int.max) <= 8_192 else { throw BillingPDFGenerationError.invalidIntent }
            let value = try JSONDecoder().decode(BillingPDFGenerationIntent.self, from: Data(contentsOf: file))
            guard value.key == key, Self.validDigest(value.sourceDigest),
                  (value.stage == .pending && value.renderedFilePath == nil &&
                   value.renderedByteCount == nil && value.renderedFileDigest == nil) ||
                    (value.stage == .rendered &&
                     value.renderedFilePath.map { isInsideGeneratedRoot(URL(fileURLWithPath: $0)) } == true &&
                     (value.renderedByteCount ?? 0) > 0 &&
                     value.renderedFileDigest.map(Self.validDigest) == true) else {
                throw BillingPDFGenerationError.invalidIntent
            }
            return value
        } catch let error as BillingPDFGenerationError { throw error }
        catch { throw BillingPDFGenerationError.invalidIntent }
    }

    private func write(_ value: BillingPDFGenerationIntent) throws {
        guard let directory else { throw BillingPDFGenerationError.unavailable }
        do {
            try Self.validateDirectory(directory, create: true)
            let data = try JSONEncoder().encode(value)
            guard data.count <= 8_192 else { throw BillingPDFGenerationError.invalidIntent }
            try data.write(to: directory.appendingPathComponent(value.key + ".json"),
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch let error as BillingPDFGenerationError { throw error }
        catch { throw BillingPDFGenerationError.unavailable }
    }

    private func preserveSuperseded(_ value: BillingPDFGenerationIntent) throws {
        guard let directory else { throw BillingPDFGenerationError.unavailable }
        let folder = directory.appendingPathComponent("Superseded", isDirectory: true)
        do {
            try Self.validateDirectory(folder, create: true)
            let data = try JSONEncoder().encode(value)
            guard data.count <= 8_192 else { throw BillingPDFGenerationError.invalidIntent }
            try data.write(to: folder.appendingPathComponent(value.key + "-" + value.generationID.uuidString + ".json"),
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch let error as BillingPDFGenerationError { throw error }
        catch { throw BillingPDFGenerationError.unavailable }
    }

    private func isInsideGeneratedRoot(_ file: URL) -> Bool {
        guard file.isFileURL, let generatedRoot else { return false }
        let root = generatedRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = file.standardizedFileURL.resolvingSymlinksInPath().path
        return candidate.hasPrefix(root + "/")
    }

    private func verifyRenderedFile(_ value: BillingPDFGenerationIntent) throws {
        guard let path = value.renderedFilePath,
              let byteCount = value.renderedByteCount,
              let digest = value.renderedFileDigest,
              isInsideGeneratedRoot(URL(fileURLWithPath: path)),
              try fileDigest(URL(fileURLWithPath: path), expectedByteCount: byteCount) == digest else {
            throw BillingPDFGenerationError.invalidIntent
        }
    }

    private func fileDigest(_ file: URL, expectedByteCount: Int) throws -> String {
        guard isInsideGeneratedRoot(file), (5...100_000_000).contains(expectedByteCount) else {
            throw BillingPDFGenerationError.invalidIntent
        }
        do {
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true,
                  info.fileSize == expectedByteCount else { throw BillingPDFGenerationError.invalidIntent }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            guard data.count == expectedByteCount, data.starts(with: Data("%PDF-".utf8)) else {
                throw BillingPDFGenerationError.invalidIntent
            }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } catch let error as BillingPDFGenerationError { throw error }
        catch { throw BillingPDFGenerationError.invalidIntent }
    }

    private static func validateDirectory(_ directory: URL, create: Bool) throws {
        if create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else {
            throw BillingPDFGenerationError.unavailable
        }
    }

    private static func validDigest(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }
}
