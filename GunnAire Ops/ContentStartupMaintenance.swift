import Foundation
import SwiftData

nonisolated private final class ContentStartupCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}

/// Full-table startup maintenance creates and uses a private SwiftData
/// context entirely on a dedicated background queue.
nonisolated struct ContentStartupColdMaintenance: Sendable {
    let modelContainer: ModelContainer

    fileprivate func run<T: Sendable>(cancelled: T, _ work: @escaping @Sendable (ModelContext) -> T) async -> T {
        let queue = DispatchQueue(label: "com.gunnaire.content.startup.\(UUID().uuidString)", qos: .utility)
        let cancellation = ContentStartupCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    guard !cancellation.isCancelled else { continuation.resume(returning: cancelled); return }
                    let context = ModelContext(modelContainer)
                    context.autosaveEnabled = false
                    guard !cancellation.isCancelled else { continuation.resume(returning: cancelled); return }
                    continuation.resume(returning: work(context))
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    func modelWorkRunsOffMainThread() async -> Bool {
        await run(cancelled: false) { context in
            _ = try? context.fetchCount(FetchDescriptor<AppUser>())
            return !Thread.isMainThread
        }
    }

    @discardableResult
    func collapseCloudKitUserDuplicates() async -> Int {
        await run(cancelled: 0) { context in
            let descriptor = FetchDescriptor<AppUser>(sortBy: [SortDescriptor(\AppUser.email, order: .forward)])
            let users = (try? context.fetch(descriptor)) ?? []
            return AppUserDataMaintenance.collapseCloudKitDuplicates(users, modelContext: context)
        }
    }

    func hasCalendarCreatedCustomersToClean() async -> Bool {
        await run(cancelled: false) { context in
            let customers = (try? context.fetch(FetchDescriptor<Customer>())) ?? []
            return customers.contains {
                CustomerDataMaintenance.isGenericCalendarCustomer($0) &&
                    !CustomerDataMaintenance.isSystemCalendarCustomer($0)
            }
        }
    }

    func cleanupCalendarNamedCustomers(
        authorize: @escaping @MainActor @Sendable () async throws -> CustomerCleanupCommitPermit
    ) async throws -> CustomerDataMaintenance.DeletionSummary {
        try await CustomerCalendarCleanup.run(container: modelContainer, authorize: authorize)
    }
}

/// Reads and updates retry records on private background contexts. Only
/// immutable request data crosses a network suspension point.
nonisolated struct ContentStartupUploadMaintenance: Sendable {
    let modelContainer: ModelContainer

    /// How many pending uploads one pass retries: the newest first, the same
    /// selection the former root query made.
    static let uploadRetryBatchSize = 10

    nonisolated struct DocumentCandidate: Sendable {
        let id: PersistentIdentifier
        let displayName: String
        let modelUUID: UUID
    }

    nonisolated struct CommunicationCandidate: Sendable {
        let id: PersistentIdentifier
        let subject: String
        let modelUUID: UUID
    }

    private nonisolated enum DocumentPreparation: Sendable {
        case skipped
        case ready(GunnAireBackendService.SharedCompanyDocumentUploadRequest)
        case failed(String)
    }

    private nonisolated enum CommunicationPreparation: Sendable {
        case skipped
        case ready(GunnAireBackendService.CustomerCommunicationPayload)
    }

    private var worker: ContentStartupColdMaintenance {
        ContentStartupColdMaintenance(modelContainer: modelContainer)
    }

    private func captureUploadOperation() async -> WorkspaceProviderOperation? {
        await MainActor.run {
            let access = CompanyWorkspaceAccessController.shared
            guard access.authorizedContainer === modelContainer else { return nil }
            return try? WorkspaceProviderOperation.capture {
                access.authorizedContainer === modelContainer
            }
        }
    }

    private func canContinue(operation: WorkspaceProviderOperation) async -> Bool {
        guard !Task.isCancelled else { return false }
        return await MainActor.run {
            (try? operation.check()) != nil
        }
    }

    /// The attachments the next upload pass will retry, newest first.
    func pendingSharedCompanyDocumentUploads() async -> [DocumentCandidate] {
        await worker.run(cancelled: []) { context in
            let descriptor = FetchDescriptor<ServiceDocumentAttachment>(
                sortBy: [SortDescriptor(\ServiceDocumentAttachment.createdAt, order: .reverse)]
            )
            let attachments = (try? context.fetch(descriptor)) ?? []
            return Array(attachments.filter(\.needsSharedCompanyStorageUpload).prefix(Self.uploadRetryBatchSize))
                .map { .init(id: $0.persistentModelID, displayName: $0.displayName, modelUUID: $0.id) }
        }
    }

    /// The communications the next sync pass will retry, newest first.
    func pendingCustomerCommunicationUploads() async -> [CommunicationCandidate] {
        await worker.run(cancelled: []) { context in
            let descriptor = FetchDescriptor<CustomerCommunication>(
                sortBy: [SortDescriptor(\CustomerCommunication.createdAt, order: .reverse)]
            )
            let communications = (try? context.fetch(descriptor)) ?? []
            return Array(communications.filter(\.needsSharedCompanySync).prefix(Self.uploadRetryBatchSize))
                .map { .init(id: $0.persistentModelID, subject: $0.subject, modelUUID: $0.id) }
        }
    }

    private func prepareDocument(_ candidate: DocumentCandidate) async -> DocumentPreparation {
        await worker.run(cancelled: .skipped) { context in
            let uuid = candidate.modelUUID
            let descriptor = FetchDescriptor<ServiceDocumentAttachment>(predicate: #Predicate { $0.id == uuid })
            guard let matches = try? context.fetch(descriptor),
                  let attachment = matches.first(where: { $0.persistentModelID == candidate.id }),
                  attachment.needsSharedCompanyStorageUpload else { return .skipped }
            do {
                return .ready(try GunnAireBackendService.sharedCompanyDocumentUploadRequest(for: attachment))
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    func completeDocument(_ candidate: DocumentCandidate, storedID: String?, failure: String?) async {
        await worker.run(cancelled: ()) { context in
            let uuid = candidate.modelUUID
            let descriptor = FetchDescriptor<ServiceDocumentAttachment>(predicate: #Predicate { $0.id == uuid })
            guard let matches = try? context.fetch(descriptor),
                  let attachment = matches.first(where: { $0.persistentModelID == candidate.id }),
                  attachment.needsSharedCompanyStorageUpload else { return }
            if let storedID {
                attachment.markSharedCompanyStored(id: storedID)
            } else if let failure {
                attachment.markSharedCompanyUploadFailed(failure)
            }
            try? context.save()
        }
    }

    private func prepareCommunication(_ candidate: CommunicationCandidate) async -> CommunicationPreparation {
        await worker.run(cancelled: .skipped) { context in
            let uuid = candidate.modelUUID
            let descriptor = FetchDescriptor<CustomerCommunication>(predicate: #Predicate { $0.id == uuid })
            guard let matches = try? context.fetch(descriptor),
                  let communication = matches.first(where: { $0.persistentModelID == candidate.id }),
                  communication.needsSharedCompanySync else { return .skipped }
            return .ready(GunnAireBackendService.communicationPayload(for: communication))
        }
    }

    func completeCommunication(_ candidate: CommunicationCandidate, syncedID: String?, failure: String?) async {
        await worker.run(cancelled: ()) { context in
            let uuid = candidate.modelUUID
            let descriptor = FetchDescriptor<CustomerCommunication>(predicate: #Predicate { $0.id == uuid })
            guard let matches = try? context.fetch(descriptor),
                  let communication = matches.first(where: { $0.persistentModelID == candidate.id }),
                  communication.needsSharedCompanySync else { return }
            if let syncedID {
                communication.markSharedCompanySynced(id: syncedID)
            } else if let failure {
                communication.markSharedCompanySyncFailed(failure)
            }
            try? context.save()
        }
    }

    /// Returns how many requests were stored and how many failed.
    @discardableResult
    func retryPendingSharedCompanyDocumentUploads() async -> (stored: Int, failed: Int) {
        guard let operation = await captureUploadOperation() else { return (0, 0) }
        var stored = 0
        var failed = 0
        for candidate in await pendingSharedCompanyDocumentUploads() {
            guard await canContinue(operation: operation) else { break }
            let preparation = await prepareDocument(candidate)
            guard await canContinue(operation: operation) else { break }
            switch preparation {
            case .skipped:
                continue
            case .ready(let request):
                do {
                    let response = try await GunnAireBackendService.retrySharedCompanyDocumentUpload(
                        request: request, originatingOperation: operation)
                    guard await canContinue(operation: operation) else { break }
                    await completeDocument(candidate, storedID: response.id, failure: nil)
                    stored += 1
                } catch {
                    guard await canContinue(operation: operation) else { break }
                    await completeDocument(candidate, storedID: nil, failure: error.localizedDescription)
                    failed += 1
                }
            case .failed(let detail):
                await completeDocument(candidate, storedID: nil, failure: detail)
                failed += 1
            }
        }
        return (stored, failed)
    }

    /// Retries the pending customer-communication syncs the same way.
    @discardableResult
    func retryPendingCustomerCommunicationUploads() async -> (synced: Int, failed: Int) {
        guard let operation = await captureUploadOperation() else { return (0, 0) }
        var synced = 0
        var failed = 0
        for candidate in await pendingCustomerCommunicationUploads() {
            guard await canContinue(operation: operation) else { break }
            let preparation = await prepareCommunication(candidate)
            guard await canContinue(operation: operation) else { break }
            switch preparation {
            case .skipped:
                continue
            case .ready(let payload):
                do {
                    let response = try await GunnAireBackendService.uploadCustomerCommunication(
                        payload: payload, originatingOperation: operation)
                    guard await canContinue(operation: operation) else { break }
                    await completeCommunication(candidate, syncedID: response.id, failure: nil)
                    synced += 1
                } catch {
                    guard await canContinue(operation: operation) else { break }
                    await completeCommunication(candidate, syncedID: nil, failure: error.localizedDescription)
                    failed += 1
                }
            }
        }
        return (synced, failed)
    }
}
