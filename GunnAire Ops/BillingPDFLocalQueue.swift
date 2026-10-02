import Foundation
import SwiftData
import CryptoKit

nonisolated enum BillingPDFLocalQueueStatus: Equatable, Sendable {
    case archived
    case queued
    case alreadyQueued
    case inProgress
    case needsReview
}

/// Persists a customer PDF after save and attempts a session-bound server
/// delivery. Its local journal survives relaunch when the verified workspace
/// or Google grant is unavailable; a successful provider readback closes it.
actor BillingPDFLocalQueue {
    typealias Check = @Sendable () async throws -> Void
    static let shared = BillingPDFLocalQueue(
        journal: .device,
        generatedRoot: FileManager.default.urls(for: .documentDirectory,
            in: .userDomainMask).first?.appendingPathComponent(
                "GunnAire Customer Documents", isDirectory: true))

    private let journal: BillingPDFGenerationJournal
    private let generatedRoot: URL?
    private var active: Set<String> = []

    init(journal: BillingPDFGenerationJournal, generatedRoot: URL?) {
        self.journal = journal
        self.generatedRoot = generatedRoot
    }

    func enqueue(companyID: UUID, container: ModelContainer,
                 kind: BillingPDFPrivateProjection.Kind,
                 documentID: UUID,
                 check: Check = {}) async -> BillingPDFLocalQueueStatus {
        let key = "\(companyID.uuidString).\(kind.rawValue).\(documentID.uuidString)"
        guard active.insert(key).inserted else { return .inProgress }
        defer { active.remove(key) }
        do {
            try await check()
            let snapshot = try await BillingPDFPrivateProjection.prepare(
                container: container, kind: kind, documentID: documentID,
                renderedAt: Date(timeIntervalSince1970: 0))
            try await check()
            let digest = try BillingPDFPrivateProjection.sourceDigest(snapshot)
            let intent = try await journal.record(companyID: companyID,
                documentID: documentID, kind: kind.journalKind,
                sourceDigest: digest)
            if intent.stage == .rendered {
                guard try await journal.current(intent) != nil else { return .needsReview }
                if (try? await deliverIfAvailable(intent, companyID: companyID,
                    container: container, kind: kind, check: check)) == true { return .archived }
                return .alreadyQueued
            }
            let rendered = try await BillingPDFPrivateProjection.renderCurrent(
                container: container, kind: kind, documentID: documentID,
                renderedAt: intent.createdAt)
            try await check()
            guard try BillingPDFPrivateProjection.sourceDigest(rendered.prepared) == digest,
                  try await BillingPDFPrivateProjection.isCurrent(rendered.prepared,
                      container: container, kind: kind, renderedAt: intent.createdAt) else {
                return .needsReview
            }
            let file = try write(rendered.data, intent: intent)
            try await check()
            guard try await BillingPDFPrivateProjection.isCurrent(rendered.prepared,
                container: container, kind: kind, renderedAt: intent.createdAt) else {
                try? FileManager.default.removeItem(at: file)
                return .needsReview
            }
            let checkpoint = try await journal.rendered(intent, fileURL: file,
                byteCount: rendered.data.count)
            if (try? await deliverIfAvailable(checkpoint, companyID: companyID,
                container: container, kind: kind, check: check)) == true { return .archived }
            return .queued
        } catch {
            return .needsReview
        }
    }

    private func deliverIfAvailable(_ intent: BillingPDFGenerationIntent,
                                    companyID: UUID, container: ModelContainer,
                                    kind: BillingPDFPrivateProjection.Kind,
                                    check: Check) async throws -> Bool {
        guard intent.companyID == companyID, intent.kind.rawValue == kind.rawValue,
              intent.stage == .rendered,
              let current = try await journal.current(intent),
              let path = current.renderedFilePath,
              let byteCount = current.renderedByteCount,
              let contentDigest = current.renderedFileDigest,
              (5...25 * 1024 * 1024).contains(byteCount) else {
            throw BillingPDFGenerationError.invalidIntent
        }
        try await check()
        let prepared = try await BillingPDFPrivateProjection.prepare(container: container,
            kind: kind, documentID: intent.documentID, renderedAt: intent.createdAt)
        guard try BillingPDFPrivateProjection.sourceDigest(prepared) == intent.sourceDigest else {
            throw BillingPDFGenerationError.changed
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count == byteCount,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == contentDigest,
              try await BillingPDFPrivateProjection.isCurrent(prepared,
                  container: container, kind: kind, renderedAt: intent.createdAt) else {
            throw BillingPDFGenerationError.changed
        }
        try await check()
        let client = try await BillingPDFArchiveClient.capture(container: container)
        if let saved = try await client.status(kind: intent.kind,
            documentID: intent.documentID, sourceDigest: intent.sourceDigest,
            rendererVersion: BillingPDFPrivateProjection.rendererVersion),
           saved.confirmedLink != nil {
            guard saved.contentDigest == contentDigest,
                  let fileID = saved.driveFileID,
                  saved.confirmedLink == "https://drive.google.com/file/d/\(fileID)/view",
                  try await BillingPDFPrivateProjection.isCurrent(prepared,
                      container: container, kind: kind, renderedAt: intent.createdAt) else {
                throw BillingPDFGenerationError.changed
            }
            try await check()
            try await journal.complete(intent)
            return true
        }
        var reservation = try await client.reserve(kind: intent.kind,
            documentID: intent.documentID, sourceDigest: intent.sourceDigest,
            rendererVersion: BillingPDFPrivateProjection.rendererVersion)
        guard reservation.key.companyID == companyID,
              reservation.key.documentID == intent.documentID,
              reservation.key.sourceDigest == intent.sourceDigest else {
            throw BillingPDFGenerationError.changed
        }
        if reservation.artifactReady == true {
            let retained = try await client.readArtifact(for: reservation)
            guard retained == data else { throw BillingPDFGenerationError.changed }
        } else {
            reservation = try await client.storeArtifact(data, for: reservation)
        }
        let delivered = try await client.deliver(reservation)
        guard delivered.contentDigest == contentDigest,
              delivered.confirmedLink != nil,
              try await BillingPDFPrivateProjection.isCurrent(prepared,
                  container: container, kind: kind, renderedAt: intent.createdAt) else {
            throw BillingPDFGenerationError.changed
        }
        try await check()
        try await journal.complete(intent)
        return true
    }

    /// Revalidates the original journal source on relaunch. A changed source
    /// creates a new local generation while preserving the old checkpoint for
    /// explicit review. Each wake processes at most twenty saved intents.
    func recoverPending(companyID: UUID, container: ModelContainer,
                        check: Check = {}) async -> [BillingPDFLocalQueueStatus] {
        do {
            try await check()
            let intents = try await journal.pending(companyID: companyID)
            var results: [BillingPDFLocalQueueStatus] = []
            for intent in intents.prefix(20) {
                guard let kind = BillingPDFPrivateProjection.Kind(rawValue: intent.kind.rawValue) else {
                    results.append(.needsReview)
                    continue
                }
                results.append(await enqueue(companyID: companyID, container: container,
                    kind: kind, documentID: intent.documentID, check: check))
            }
            return results
        } catch {
            return [.needsReview]
        }
    }

    private func write(_ data: Data, intent: BillingPDFGenerationIntent) throws -> URL {
        guard let generatedRoot,
              (5...25 * 1024 * 1024).contains(data.count),
              data.starts(with: Data("%PDF-".utf8)) else {
            throw BillingPDFGenerationError.invalidIntent
        }
        try FileManager.default.createDirectory(at: generatedRoot,
            withIntermediateDirectories: true)
        let rootInfo = try generatedRoot.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey])
        guard rootInfo.isDirectory == true, rootInfo.isSymbolicLink != true else {
            throw BillingPDFGenerationError.invalidIntent
        }
        let file = generatedRoot.appendingPathComponent(
            "BillingPDF-\(intent.generationID.uuidString).pdf")
        if FileManager.default.fileExists(atPath: file.path) {
            let info = try file.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true else {
                throw BillingPDFGenerationError.invalidIntent
            }
        }
        try data.write(to: file, options: [
            .atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return file
    }
}

private extension BillingPDFPrivateProjection.Kind {
    nonisolated var journalKind: BillingPDFGenerationIntent.DocumentKind {
        switch self {
        case .estimate: .estimate
        case .invoice: .invoice
        }
    }
}
