import Foundation
import Combine
import SwiftData

/// Same-business administrator history. Pages contain metadata only. Bytes are
/// fetched only for an explicit restore; no browse/restore operation sends QBO.
@MainActor final class QBODocumentSharedRecovery: ObservableObject {
    let access: QBODocumentNativeWorkflow.Access
    let store: QBODocumentCaptureStore
    let client: QBODocumentUploadClient
    @Published private(set) var rows: [QBODocumentUploadRecord] = []
    @Published private(set) var nextCursor: UUID?
    @Published private(set) var pageNumber = 1
    @Published private(set) var loaded = false
    @Published private(set) var working = false
    private var cursors: [UUID?] = [nil]
    var hasPrevious: Bool { pageNumber > 1 }

    init(access: QBODocumentNativeWorkflow.Access, store: QBODocumentCaptureStore,
         transport: @escaping QBODocumentUploadClient.Transport) throws {
        try access.check(); try access.owner.validate(); try access.scope.validate()
        guard access.owner.companyID == access.scope.companyID else { throw QBODocumentError.access }
        self.access = access; self.store = store
        client = .init(transport: transport, check: access.check)
    }

    enum Page { case refresh, next, previous }
    func load(_ direction: Page = .refresh) async throws {
        try access.check()
        guard !working else { throw QBODocumentError.changed }
        let index: Int
        let cursor: UUID?
        switch direction {
        case .refresh: index = pageNumber - 1; cursor = cursors[index]
        case .next:
            guard let nextCursor else { throw QBODocumentError.changed }
            index = pageNumber; cursor = nextCursor
        case .previous:
            guard hasPrevious else { throw QBODocumentError.changed }
            index = pageNumber - 2; cursor = cursors[index]
        }
        working = true; defer { working = false }
        let result = try await client.page(access.scope, after: cursor)
        try access.check()
        // Re-reading a visible record may advance it, never replace its intent
        // or turn an observed dispatch/confirmation back into unsent work.
        for value in result.uploads {
            if let old = rows.first(where: { $0.id == value.id }) { try value.validateUpdate(from: old) }
        }
        if index == cursors.count { cursors.append(cursor) }
        else { cursors = Array(cursors.prefix(index + 1)) }
        rows = result.uploads; nextCursor = result.nextCursor
        pageNumber = index + 1; loaded = true
    }

    func check(_ original: QBODocumentUploadRecord) async throws -> QBODocumentUploadRecord {
        try access.check(); try original.validate(access.scope)
        guard !working else { throw QBODocumentError.changed }
        working = true; defer { working = false }
        let fresh = try await client.read(original.id, scope: access.scope)
        try fresh.validateUpdate(from: original)
        let result = fresh.state == .cancelled ? fresh : try await client.action(.recover, original: fresh)
        try result.validateUpdate(from: fresh); try access.check()
        replace(result)
        return result
    }

    /// Original operation, immutable server envelope and verified bytes survive
    /// relaunch. A shared record has no fabricated device connection identity.
    func restore(_ original: QBODocumentUploadRecord) async throws -> QBODocumentCapture {
        try access.check(); try original.validate(access.scope)
        guard !working else { throw QBODocumentError.changed }
        working = true; defer { working = false }
        let fresh = try await client.read(original.id, scope: access.scope)
        try fresh.validateUpdate(from: original)
        let data = try await client.file(fresh)
        let final = try await client.read(original.id, scope: access.scope)
        try final.validateUpdate(from: fresh); try final.file.verify(data); try access.check()
        let local = try retain(final, data: data)
        replace(final)
        return local
    }

    private func replace(_ value: QBODocumentUploadRecord) {
        if let index = rows.firstIndex(where: { $0.id == value.id }) { rows[index] = value }
    }

    private func retain(_ remote: QBODocumentUploadRecord, data: Data) throws -> QBODocumentCapture {
        try access.check(); try remote.validate(access.scope); try remote.file.verify(data)
        let saved = try store.list(access.owner)
        let matches = saved.filter { $0.server?.id == remote.id || $0.id == remote.operationID }
        guard matches.count <= 1 else { throw QBODocumentError.changed }
        if let local = matches.first {
            guard local.scope == remote.scope, let server = local.server, server.matchesOriginal(remote),
                  !local.cancelledLocally else { throw QBODocumentError.changed }
            try local.file.verify(store.bytes(access.owner, local.id))
            let session = try QBODocumentCaptureSession(record: local, store: store, check: access.check)
            try session.observe(remote)
            return session.record
        }
        // Do not silently adopt an unsent local proposal with a different
        // operation, even if its bytes and destination happen to be identical.
        guard !saved.contains(where: { !$0.cancelledLocally && $0.server?.state != .cancelled &&
            $0.scope == remote.scope && $0.file == remote.file && $0.targets == remote.targets })
        else { throw QBODocumentError.changed }
        let identity = remote.jobDocument.flatMap { job -> QBODocumentLocalAttachment? in
            // A historical file can reference several documents of one type.
            // Preserve it for export/review instead of choosing one arbitrarily.
            guard job.documents.filter({ $0.type == "Invoice" }).count <= 1,
                  job.documents.filter({ $0.type == "Estimate" }).count <= 1 else { return nil }
            return QBODocumentLocalAttachment(attachmentID: job.attachmentID, customerID: job.localCustomerID,
                customerQuickBooksID: job.customerQuickBooksID, serviceCallID: job.serviceCallID,
                invoiceID: job.documents.first(where: { $0.type == "Invoice" })?.localID,
                estimateID: job.documents.first(where: { $0.type == "Estimate" })?.localID, kind: job.kind)
        }
        let row = QBODocumentCapture(id: remote.operationID, owner: access.owner, scope: remote.scope,
            file: remote.file, targets: remote.targets, jobDocument: remote.jobDocument, createdAt: Date(),
            server: remote, dispatchStarted: [.sending, .uncertain, .confirmed].contains(remote.state),
            localAttachment: identity, sharedSource: remote)
        try store.write(row, nil, data)
        return row
    }

    /// Applying a confirmed receipt never creates a missing CloudKit attachment,
    /// changes another device's path, increments photos, or claims job closeout.
    func apply(_ row: QBODocumentCapture, context: ModelContext,
               save: (ModelContext) throws -> Void = { try $0.save() }) throws -> QBODocumentCapture {
        try access.check()
        guard row.owner == access.owner, row.scope == access.scope else { throw QBODocumentError.access }
        let session = try QBODocumentCaptureSession(record: row, store: store, check: access.check)
        let bytes = try store.bytes(row.owner, row.id)
        try QBODocumentNativeWorkflow.applyConfirmed(row, context: context, retainedOriginal: bytes, save: save)
        try session.markLocalApplied()
        return session.record
    }
}
