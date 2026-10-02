import Foundation
import SwiftData

nonisolated enum BillingPDFLocalQueueStatus: Equatable, Sendable {
    case queued
    case alreadyQueued
    case inProgress
    case needsReview
}

/// Persists a customer PDF on the device after a successful document save.
/// This actor does no provider networking and does not create a CloudKit
/// attachment. Its journal and exact file digest survive app relaunch.
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
            _ = try await journal.rendered(intent, fileURL: file,
                byteCount: rendered.data.count)
            return .queued
        } catch {
            return .needsReview
        }
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
