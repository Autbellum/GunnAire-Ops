import Foundation
import Darwin

/// Pending receipt bytes and original request metadata are kept in protected,
/// private storage before transport. Credentials are never persisted here.
actor ReceiptUploadIntentJournal {
    static let device = ReceiptUploadIntentJournal(directory: FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("ReceiptUploadIntents-v1", isDirectory: true))
    static let maximumBytes = 64 * 1024 * 1024
    enum Failure: LocalizedError {
        case storage, busy, pending, absent
        var errorDescription: String? {
            switch self {
            case .storage: "The retained receipt could not be verified. Its uncertain upload was retained; no new upload was sent."
            case .busy: "This receipt upload is already being checked."
            case .pending: "An earlier receipt upload is unresolved. Use Recover Pending Receipt before starting another receipt."
            case .absent: "There is no unresolved receipt upload for this account."
            }
        }
    }
    struct Request: Codable, Equatable, Sendable {
        let filename, contentType: String
        let serviceCallID, equipmentID: UUID?
        let equipmentName, customerName: String?
    }
    struct Payload: Sendable {
        let request: Request
        let data: Data
        static func capture(url: URL, request: Request) throws -> Payload {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let data = try handle.read(upToCount: ReceiptUploadIntentJournal.maximumBytes + 1) ?? Data()
            let payload = Payload(request: request, data: data)
            _ = try payload.fingerprint()
            return payload
        }
        func fingerprint() throws -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let metadata = try encoder.encode(request)
            guard !data.isEmpty, data.count <= ReceiptUploadIntentJournal.maximumBytes,
                  metadata.count <= 8192 else { throw Failure.storage }
            return QBODocumentFileInfo.hash(metadata + Data(QBODocumentFileInfo.hash(data).utf8))
        }
    }
    struct Pending: Sendable { let operation: UUID; let payload: Payload }
    struct Record: Codable, Equatable, Sendable {
        let scope: String
        let operation: UUID
        var fingerprint: String?
        var confirmed: Bool
        var payloadReady: Bool? = nil // nil means legacy/uncertain, never safe to discard.
    }
    private let directory: URL?
    private var active: Set<String> = []
    private var locks: [String: Int32] = [:]
    deinit { for descriptor in locks.values { Darwin.close(descriptor) } }
    init(directory: URL?) { self.directory = directory }
    nonisolated static func scope(origin: String, email: String) -> String {
        CompanyWorkspaceSession.digest(origin + "\n" + email)
    }
    func prepare(scope: String, payload: Payload) throws -> Pending {
        guard !active.contains(scope) else { throw Failure.busy }
        let fingerprint = try payload.fingerprint()
        try acquire(scope)
        defer { if !active.contains(scope) { unlock(scope) } }
        let prior = try read(scope)
        if let prior, let original = prior.fingerprint {
            if original == fingerprint {
                if !prior.confirmed {
                    try retain(payload, for: prior)
                    var ready = prior; ready.payloadReady = true; try write(ready)
                }
                active.insert(scope)
                return Pending(operation: prior.operation, payload: payload)
            }
            guard prior.confirmed else { throw Failure.pending }
        }
        let operation = prior?.fingerprint == nil ? (prior?.operation ?? UUID()) : UUID()
        var record = Record(scope: scope, operation: operation, fingerprint: fingerprint, confirmed: false, payloadReady: false)
        // Reserve one unarmed intent before writing bytes. Only the verified,
        // atomically armed record may authorize transport; partial writes reuse
        // this same folder instead of accumulating orphan payloads.
        try write(record)
        try retain(payload, for: record)
        record.payloadReady = true
        try write(record)
        active.insert(scope)
        return Pending(operation: operation, payload: payload)
    }
    func recover(scope: String) throws -> Pending {
        guard !active.contains(scope) else { throw Failure.busy }
        try acquire(scope)
        defer { if !active.contains(scope) { unlock(scope) } }
        guard var record = try read(scope), record.fingerprint != nil, !record.confirmed else { throw Failure.absent }
        let payload = try load(record)
        record.payloadReady = true; try write(record)
        active.insert(scope)
        return Pending(operation: record.operation, payload: payload)
    }
    @discardableResult
    func confirm(scope: String, operation: UUID) throws -> Bool {
        guard active.contains(scope), var value = try read(scope), value.operation == operation,
              value.fingerprint != nil else { throw Failure.storage }
        guard value.confirmed || value.payloadReady == true else { throw Failure.storage }
        if !value.confirmed { _ = try load(value) }
        value.confirmed = true
        try write(value) // Cleanup is allowed only after durable confirmation.
        do { try cleanup(value); return true }
        catch { return false } // Confirmation is durable; retain cleanup evidence.
    }
    func release(scope: String) { active.remove(scope); unlock(scope) }
    func startNew(scope: String) throws {
        guard !active.contains(scope) else { throw Failure.busy }
        try acquire(scope); defer { unlock(scope) }
        if let prior = try read(scope), prior.fingerprint != nil {
            // A false ready bit proves transport was never authorized. Missing
            // legacy bits and armed attempts remain uncertain until confirmed.
            guard prior.confirmed || prior.payloadReady == false else { throw Failure.pending }
            try cleanup(prior)
        }
        try write(Record(scope: scope, operation: UUID(), fingerprint: nil, confirmed: false, payloadReady: false))
    }
    private func acquire(_ scope: String) throws {
        guard locks[scope] == nil else { throw Failure.busy }
        let path = try file(scope).deletingLastPathComponent().appendingPathComponent(scope + ".lock").path
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Failure.storage }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(descriptor); throw Failure.busy }
        locks[scope] = descriptor
    }
    private func unlock(_ scope: String) {
        if let descriptor = locks.removeValue(forKey: scope) { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
    }
    private func cleanup(_ value: Record) throws {
        guard value.confirmed || value.payloadReady == false else { throw Failure.pending }
        let folder = try payloadFolder(value, create: false)
        if FileManager.default.fileExists(atPath: folder.path) {
            for name in ["receipt.bin", "request.json"] {
                let url = folder.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) {
                    _ = try boundedRead(url, maximum: name == "receipt.bin" ? Self.maximumBytes : 8192)
                    try FileManager.default.removeItem(at: url)
                }
            }
            guard Darwin.rmdir(folder.path) == 0 else { throw Failure.storage }
        }
    }
    private func valid(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private func file(_ scope: String) throws -> URL {
        guard valid(scope), let directory else { throw Failure.storage }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else { throw Failure.storage }
        return directory.appendingPathComponent(scope + ".json")
    }
    private func payloadFolder(_ record: Record, create: Bool) throws -> URL {
        let root = try file(record.scope).deletingLastPathComponent()
        let url = root.appendingPathComponent(record.scope + "-" + record.operation.uuidString + "-payload", isDirectory: true)
        if create && !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        if FileManager.default.fileExists(atPath: url.path) {
            let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else { throw Failure.storage }
        }
        return url
    }
    private func boundedRead(_ url: URL, maximum: Int) throws -> Data {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true,
              (info.fileSize ?? Int.max) <= maximum else { throw Failure.storage }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw Failure.storage }
        return data
    }
    private func protectedWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.synchronize()
    }
    private func retain(_ payload: Payload, for record: Record) throws {
        guard try payload.fingerprint() == record.fingerprint else { throw Failure.storage }
        let folder = try payloadFolder(record, create: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for (name, data) in [("receipt.bin", payload.data), ("request.json", try encoder.encode(payload.request))] {
            let url = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                guard try boundedRead(url, maximum: name == "receipt.bin" ? Self.maximumBytes : 8192) == data else { throw Failure.storage }
            } else { try protectedWrite(data, to: url) }
        }
        guard try load(record).fingerprint() == record.fingerprint else { throw Failure.storage }
    }
    private func load(_ record: Record) throws -> Payload {
        let folder = try payloadFolder(record, create: false)
        let request = try JSONDecoder().decode(Request.self, from: boundedRead(folder.appendingPathComponent("request.json"), maximum: 8192))
        let value = Payload(request: request, data: try boundedRead(folder.appendingPathComponent("receipt.bin"), maximum: Self.maximumBytes))
        guard try value.fingerprint() == record.fingerprint else { throw Failure.storage }
        return value
    }
    private func read(_ scope: String) throws -> Record? {
        let url = try file(scope)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(Record.self, from: boundedRead(url, maximum: 4096))
        guard value.scope == scope, value.fingerprint.map(valid) ?? !value.confirmed else { throw Failure.storage }
        return value
    }
    private func write(_ value: Record) throws {
        try protectedWrite(JSONEncoder().encode(value), to: file(value.scope))
        guard try read(value.scope) == value else { throw Failure.storage }
    }
}
