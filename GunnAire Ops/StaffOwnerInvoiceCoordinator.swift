import Foundation
import Combine
import SwiftData

struct StaffOwnerInvoiceDependencies {
    let check: (StaffReplicaSourceContext) throws -> Void
    let request: (String, String, Data?) async throws -> Data
    let store: SharedTimeLocalStore
    let serviceVersion: () async throws -> String
    let verify: (StaffOwnerInvoiceProposal, StaffReplicaSourceContext, Bool) throws -> Bool
    let apply: (StaffOwnerInvoiceProposal, StaffOwnerInvoiceApplication, StaffReplicaSourceContext) throws -> Void
    var now: () -> Date = Date.init
    var operation: () -> UUID = UUID.init
    static var live: Self {
        func container(_ context: StaffReplicaSourceContext) throws -> ModelContainer {
            try StaffReplicaSourceDependencies.verify(context)
            guard let value = CompanyWorkspaceAccessController.shared.authorizedContainer else { throw StaffReplicaSourceSyncError.access }
            return value
        }
        return .init(check: { try StaffReplicaSourceDependencies.verify($0) },
            request: { try await GunnAireBackendService.staffReplicaSourceRequest(path: $0, method: $1, body: $2) },
            store: StaffWorkspaceSourceStaging.device,
            serviceVersion: { try await GunnAireBackendService.fetchReadiness().serviceVersion },
            verify: { try StaffOwnerInvoiceModels.verify($0, scope: $1.scope, container: container($1), allowApplied: $2) },
            apply: { proposal, receipt, context in
                try StaffOwnerInvoiceModels.apply(proposal, application: receipt, scope: context.scope,
                    container: container(context), check: { try StaffReplicaSourceDependencies.verify(context) })
            })
    }
}

/// .63 offered the endpoints but did not fence provider writes and payments.
enum StaffOwnerInvoiceBackendGate {
    static func supports(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.count <= 8 && $0.utf8.allSatisfy({ (48...57).contains($0) }) }) else { return false }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == 4, (1...12).contains(numbers[1]), (1...31).contains(numbers[2]) else { return false }
        return !numbers.lexicographicallyPrecedes([2026, 9, 11, 64])
    }
}

struct StaffOwnerInvoicePending: Codable, Equatable {
    let review: StaffOwnerInvoiceReview
    let proposal: StaffOwnerInvoiceProposal
    let prepareBytes: Data
    var phase: String // queued -> claimed -> applying -> saved; only explicit approvals enter.
    var receipt: StaffOwnerInvoiceApplication?
}
struct StaffOwnerInvoiceJournal: Codable {
    let version: Int
    let scope: StaffReplicaSourceScope
    var queue: [String] = []
    var after: String?
    var lastAttempted: String?
    var lastConfirmationAttempt: String?
    var pending: [String: StaffOwnerInvoicePending] = [:]
    var rejected: [StaffOwnerInvoiceRejection] = []
}
struct StaffOwnerInvoiceRejection: Codable {
    let pending: StaffOwnerInvoicePending
    let code: String
}
struct StaffOwnerInvoiceRow: Identifiable {
    let review: StaffOwnerInvoiceReview
    let customer: String
    let message: String
    let canReview: Bool
    var id: String { review.id }
}
struct StaffOwnerInvoiceDraft: Identifiable {
    let context: StaffReplicaSourceContext
    let review: StaffOwnerInvoiceReview
    let proposal: StaffOwnerInvoiceProposal
    let customer: String
    var id: String { proposal.operationID }
}

@MainActor final class StaffOwnerInvoiceCoordinator: ObservableObject {
    static let shared = StaffOwnerInvoiceCoordinator()
    let dependencies: StaffOwnerInvoiceDependencies
    @Published private(set) var reviews: [StaffOwnerInvoiceRow] = []
    @Published private(set) var recentInvoices: [StaffOwnerInvoiceRoute] = []
    @Published private(set) var message = "Check for invoice work submitted from the field."
    @Published private(set) var hasMore = false
    @Published private(set) var displayGeneration = UUID()
    private var displayed: StaffReplicaSourceContext?
    private var published: StaffWorkspacePublicationSummary?
    private var recoveryMessages: [String: String] = [:]
    init(dependencies: StaffOwnerInvoiceDependencies? = nil) { self.dependencies = dependencies ?? .live }
    static func key(_ scope: StaffReplicaSourceScope) -> String { "owner-invoice-applications-v1\n" + scope.key }
    func clearDisplay() {
        reviews = []; recentInvoices = []; displayed = nil; published = nil; hasMore = false
        displayGeneration = UUID(); recoveryMessages = [:]
        message = "Check for invoice work submitted from the field."
    }
    private func check(_ context: StaffReplicaSourceContext) throws {
        try Task.checkCancellation(); try dependencies.check(context)
    }
    private func gate(_ context: StaffReplicaSourceContext) async throws {
        try check(context)
        let version = try await dependencies.serviceVersion()
        try check(context)
        guard StaffOwnerInvoiceBackendGate.supports(version) else { throw StaffOwnerInvoiceError.backend }
    }
    private func validate(_ value: StaffOwnerInvoiceJournal, _ context: StaffReplicaSourceContext) throws {
        guard value.version == 1, value.scope == context.scope, value.queue.count <= 50,
              value.queue == Set(value.queue).sorted(), value.queue.allSatisfy(CloudKitStaffSetupPolicy.canonicalID),
              value.after.map(CloudKitStaffSetupPolicy.canonicalID) ?? true,
              value.lastAttempted.map(CloudKitStaffSetupPolicy.canonicalID) ?? true, value.pending.count <= 32,
              value.lastConfirmationAttempt.map(CloudKitStaffSetupPolicy.canonicalID) ?? true,
              value.rejected.count <= 1000,
              Set(value.rejected.map { $0.pending.proposal.operationID }).count == value.rejected.count,
              value.rejected.allSatisfy({ $0.pending.phase == "queued" && $0.pending.receipt == nil && StaffOwnerInvoiceTransport.rejectionCodes.contains($0.code) }) else { throw StaffOwnerInvoiceError.storage }
        let retained = value.pending.map { ($0.key, $0.value) } + value.rejected.map { ($0.pending.review.id, $0.pending) }
        for (id, pending) in retained {
            try pending.review.validate(context.scope)
            try pending.proposal.validate(context.scope, original: pending.review)
            guard id == pending.review.id, ["queued", "claimed", "applying", "saved"].contains(pending.phase),
                  pending.phase == "queued" || pending.receipt != nil,
                  try StaffWorkspacePublicationContract.decode(StaffOwnerInvoiceProposal.self, from: pending.prepareBytes,
                    maximum: StaffOwnerInvoiceTransport.maximumRequestBytes) == pending.proposal else { throw StaffOwnerInvoiceError.storage }
            if let receipt = pending.receipt { try validate(receipt, proposal: pending.proposal, original: pending.review, context: context) }
        }
    }
    private func load(_ context: StaffReplicaSourceContext) throws -> StaffOwnerInvoiceJournal {
        try check(context)
        let bytes = try dependencies.store.read(Self.key(context.scope))
        try check(context)
        guard let bytes else { return .init(version: 1, scope: context.scope) }
        let value = try StaffWorkspacePublicationContract.decode(StaffOwnerInvoiceJournal.self, from: bytes, maximum: 64 * 1024 * 1024)
        try validate(value, context); return value
    }
    private func save(_ value: StaffOwnerInvoiceJournal, _ context: StaffReplicaSourceContext) throws {
        try check(context); try validate(value, context)
        let bytes = try StaffWorkspacePublicationContract.encode(value)
        guard bytes.count <= 64 * 1024 * 1024 else { throw StaffOwnerInvoiceError.storage }
        try dependencies.store.write(Self.key(context.scope), bytes); try check(context)
    }
    private func request<T: Codable>(_ type: T.Type, _ path: String, method: String = "GET", body: Data? = nil,
                                     context: StaffReplicaSourceContext) async throws -> T {
        try check(context)
        guard StaffOwnerInvoiceTransport.allows(path: path, method: method, body: body) else { throw StaffReplicaSourceSyncError.invalid }
        let bytes = try await dependencies.request(path, method, body)
        try check(context)
        return try StaffWorkspacePublicationContract.decode(type, from: bytes, maximum: StaffOwnerInvoiceTransport.maximumResponseBytes)
    }
    private func detail(_ id: String, _ context: StaffReplicaSourceContext) async throws -> StaffOwnerInvoiceReview {
        let value = try await request(StaffOwnerInvoiceReview.self, StaffOwnerInvoiceTransport.path(context.scope, id: id), context: context)
        try value.validate(context.scope)
        guard value.id == id else { throw StaffReplicaSourceSyncError.invalid }; return value
    }
    private func application(_ id: String, _ context: StaffReplicaSourceContext) async throws -> StaffOwnerInvoiceSavedApplication? {
        let value = try await request(StaffOwnerInvoiceApplicationEnvelope.self,
            StaffOwnerInvoiceTransport.path(context.scope, id: id, application: true), context: context)
        guard value.schema == StaffOwnerInvoiceProposal.schema else { throw StaffReplicaSourceSyncError.invalid }
        if let saved = value.application {
            // Validate another office's evidence for display, never as write authority.
            guard saved.proposal.commandID == id, SharedTimeError.validEmail(saved.receipt.ownerEmail),
                  CloudKitStaffSetupPolicy.canonicalID(saved.receipt.ownerStoreID) else { throw StaffReplicaSourceSyncError.invalid }
            let evidenceScope = StaffReplicaSourceScope(backendOrigin: context.scope.backendOrigin, actorEmail: saved.receipt.ownerEmail,
                binding: context.scope.binding, storeUUID: saved.receipt.ownerStoreID)
            try saved.receipt.validate(saved.proposal, scope: evidenceScope)
        }
        return value.application
    }
    private func validate(_ receipt: StaffOwnerInvoiceApplication, proposal: StaffOwnerInvoiceProposal,
                          original: StaffOwnerInvoiceReview, context: StaffReplicaSourceContext) throws {
        try receipt.validate(proposal, scope: context.scope)
        guard let prepared = StaffOwnerFieldEditApplication.instant(receipt.preparedAt),
              let created = StaffOwnerFieldEditApplication.instant(original.receipt.createdAt), prepared >= created else { throw StaffReplicaSourceSyncError.invalid }
    }
    private func proof(_ saved: StaffOwnerInvoiceSavedApplication, pending: StaffOwnerInvoicePending,
                       context: StaffReplicaSourceContext) throws {
        guard saved.receipt.ownerStoreID == context.scope.storeUUID.lowercased(), saved.receipt.ownerEmail == context.scope.actorEmail else { throw StaffOwnerInvoiceError.otherDevice }
        guard saved.proposal == pending.proposal else { throw StaffOwnerInvoiceError.changed }
        try validate(saved.receipt, proposal: pending.proposal, original: pending.review, context: context)
        if let earlier = pending.receipt {
            guard earlier.preparedAt == saved.receipt.preparedAt, earlier.proposalSHA256 == saved.receipt.proposalSHA256,
                  earlier.state != "published" || earlier == saved.receipt else { throw StaffReplicaSourceSyncError.invalid }
        }
    }
    private func resume(_ id: String, state: inout StaffOwnerInvoiceJournal, context: StaffReplicaSourceContext) async throws {
        guard var pending = state.pending[id] else { return }
        if let saved = try await application(id, context) {
            try proof(saved, pending: pending, context: context)
            if saved.receipt.state == "published" {
                state.pending[id] = nil; try save(state, context); return // Never reapply a historical published invoice.
            }
        } else if pending.receipt != nil || pending.phase != "queued" { throw StaffOwnerInvoiceError.storage }
        if pending.phase == "saved" { return } // Source publication/confirmation recovers this next.
        _ = try dependencies.verify(pending.proposal, context, pending.phase == "applying")
        let receipt: StaffOwnerInvoiceApplication
        do {
            receipt = try await request(StaffOwnerInvoiceApplication.self,
                StaffOwnerInvoiceTransport.root + "/" + id + "/prepare", method: "POST", body: pending.prepareBytes, context: context)
        } catch let rejection as StaffReplicaSourceRejected {
            // Only a documented rejection PLUS a fresh absent claim permits a
            // new human review. Unknown replies and existing claims retain the
            // original pending bytes; never infer failure from local state.
            if pending.phase == "queued", pending.receipt == nil,
               StaffOwnerInvoiceTransport.rejectionCodes.contains(rejection.code),
               try await application(id, context) == nil {
                guard state.rejected.count < 1000 else { throw StaffOwnerInvoiceError.storage }
                state.rejected.append(.init(pending: pending, code: rejection.code))
                state.pending[id] = nil; try save(state, context)
            }
            throw rejection
        }
        try validate(receipt, proposal: pending.proposal, original: pending.review, context: context)
        if let earlier = pending.receipt {
            guard earlier.preparedAt == receipt.preparedAt, earlier.proposalSHA256 == receipt.proposalSHA256 else { throw StaffReplicaSourceSyncError.invalid }
        }
        pending.receipt = receipt
        guard let saved = try await application(id, context) else { throw StaffOwnerInvoiceError.storage }
        try proof(saved, pending: pending, context: context) // Compare full original; do not trust a cross-language JSON hash alone.
        pending.receipt = saved.receipt
        if saved.receipt.state == "published" { state.pending[id] = nil; try save(state, context); return }
        if pending.phase != "applying" { pending.phase = "claimed" }
        state.pending[id] = pending; try save(state, context) // Claim durable before model callback.
        _ = try dependencies.verify(pending.proposal, context, pending.phase == "applying")
        pending.phase = "applying"; state.pending[id] = pending; try save(state, context)
        try check(context); try dependencies.apply(pending.proposal, saved.receipt, context); try check(context)
        pending.phase = "saved"; state.pending[id] = pending; try save(state, context)
    }
    /// Only previously approved durable intent can mutate models during sync.
    func recover(_ context: StaffReplicaSourceContext) async throws {
        let key = Self.key(context.scope), lock = try SharedTimeMutationGate.begin(key)
        defer { SharedTimeMutationGate.finish(key, id: lock) }
        var state = try load(context)
        hasMore = false
        guard !state.pending.isEmpty else { return }
        try await gate(context)
        let ids = state.pending.keys.sorted()
        let ordered = ids.filter { $0 > (state.lastAttempted ?? "") } + ids.filter { $0 <= (state.lastAttempted ?? "") }
        for id in ordered.prefix(8) {
            do { try await resume(id, state: &state, context: context); recoveryMessages[id] = nil }
            catch {
                try check(context); state = try load(context)
                message = Self.safe(error); recoveryMessages[id] = message
            }
            state.lastAttempted = id; try save(state, context)
        }
        // Pending work is round-robin at the normal interval. Only unread review
        // pages request the one-second loop; failed approvals cannot hot-loop.
    }
    func confirmPublished(_ context: StaffReplicaSourceContext) async throws {
        let key = Self.key(context.scope), lock = try SharedTimeMutationGate.begin(key)
        defer { SharedTimeMutationGate.finish(key, id: lock) }
        var state = try load(context)
        let ids = state.pending.filter { $0.value.phase == "saved" }.keys.sorted()
        guard !ids.isEmpty else { return }; try await gate(context)
        let ordered = ids.filter { $0 > (state.lastConfirmationAttempt ?? "") } + ids.filter { $0 <= (state.lastConfirmationAttempt ?? "") }
        for id in ordered.prefix(8) {
            guard let pending = state.pending[id] else { continue }
            do {
                let receipt = try await request(StaffOwnerInvoiceApplication.self,
                    StaffOwnerInvoiceTransport.root + "/" + id + "/confirm", method: "POST",
                    body: StaffWorkspacePublicationContract.encode(pending.proposal.confirmation), context: context)
                guard receipt.state == "published" else { throw StaffReplicaSourceSyncError.invalid }
                try proof(.init(proposal: pending.proposal, receipt: receipt), pending: pending, context: context)
                guard let saved = try await application(id, context) else { throw StaffOwnerInvoiceError.storage }
                try proof(saved, pending: pending, context: context)
                guard saved.receipt == receipt else { throw StaffReplicaSourceSyncError.invalid }
                state.pending[id] = nil; try save(state, context)
                recoveryMessages[id] = nil
            } catch { try check(context); state = try load(context); message = Self.safe(error); recoveryMessages[id] = message }
            state.lastConfirmationAttempt = id; try save(state, context)
        }
    }
    /// Read-only review after a complete owner publication; never auto-approves field prices.
    func refresh(_ context: StaffReplicaSourceContext, published summary: StaffWorkspacePublicationSummary) async throws {
        let key = Self.key(context.scope), lock = try SharedTimeMutationGate.begin(key)
        defer { SharedTimeMutationGate.finish(key, id: lock) }
        try check(context)
        guard summary.preparedStage.scope == context.scope, !summary.hasMore, summary.conflicts.isEmpty,
              summary.waitingForCloudKit == 0 else { throw StaffOwnerInvoiceError.changed }
        if displayed?.scope != context.scope || displayed?.stamp != context.stamp { clearDisplay() }
        displayed = context; published = summary; reviews = []
        do { try await gate(context) }
        catch StaffOwnerInvoiceError.backend { message = StaffOwnerInvoiceError.backend.localizedDescription; return }
        var state = try load(context)
        let pendingInvoices = Set(state.pending.values.map { $0.proposal.expectedInvoice.id })
        recentInvoices.removeAll { pendingInvoices.contains($0.invoiceID.uuidString.lowercased()) }
        if state.queue.isEmpty {
            let page = try await request(StaffOwnerInvoicePage.self,
                StaffOwnerInvoiceTransport.path(context.scope, after: state.after), context: context)
            try page.validate(context.scope, after: state.after)
            state.queue = page.commandIDs; state.after = page.nextCursor; try save(state, context)
        }
        for id in state.queue.prefix(8) {
            let review = try await detail(id, context)
            let saved = try await application(id, context)
            guard saved == nil || saved?.proposal.request == review.request else { throw StaffReplicaSourceSyncError.invalid }
            let customer = summary.publishedRecords.first { $0.kind == "customer" && $0.id == review.request.origin.customerID }
            let title = customer.flatMap { try? StaffOwnerInvoicePlanner.text($0.fields, "name") } ?? "Customer invoice"
            let status: String
            if let failure = recoveryMessages[id] { status = failure }
            else if saved?.receipt.state == "published" { status = "Applied to company records. QuickBooks publication is a separate review." }
            else if saved != nil && state.pending[id] == nil { status = StaffOwnerInvoiceError.otherDevice.localizedDescription }
            else if let pending = state.pending[id] { status = pending.phase == "saved" ? "Saved on this device; awaiting company workspace confirmation." : "Approval retained. Check Again on this device to recover it." }
            else { status = "Review the requested work before changing this invoice." }
            // Completed history stays on the server and invoice, not in the action queue.
            if saved?.receipt.state != "published" {
                reviews.append(.init(review: review, customer: title, message: status, canReview: saved == nil && state.pending[id] == nil))
            } else if !pendingInvoices.contains(review.request.origin.invoiceID) {
                try rememberInvoice(review, context: context, customer: title)
            }
            state.queue.removeAll { $0 == id }; try save(state, context)
        }
        hasMore = !state.queue.isEmpty || state.after != nil
        message = reviews.isEmpty ? (hasMore ? "Checking additional invoice requests…" : "No invoice requests are currently listed.") : "Review field work, then publish approved invoices to QuickBooks."
    }
    func makeDraft(_ id: String, reason: String, context: StaffReplicaSourceContext) async throws -> StaffOwnerInvoiceDraft {
        try check(context)
        guard displayed?.scope == context.scope, displayed?.stamp == context.stamp, let published,
              let row = reviews.first(where: { $0.id == id && $0.canReview }), try load(context).pending[id] == nil else { throw StaffOwnerInvoiceError.changed }
        try await gate(context)
        let review = try await detail(id, context)
        guard review == row.review, review.currentSourceSequence == published.sourceSequence,
              try await application(id, context) == nil else { throw StaffOwnerInvoiceError.changed }
        let proposal = try StaffOwnerInvoicePlanner.make(review: review, records: published.publishedRecords, scope: context.scope,
            reason: reason, now: dependencies.now(), operation: dependencies.operation())
        _ = try dependencies.verify(proposal, context, false); try check(context)
        return .init(context: context, review: review, proposal: proposal, customer: row.customer)
    }
    func applyReviewed(_ draft: StaffOwnerInvoiceDraft, context: StaffReplicaSourceContext) async throws {
        let key = Self.key(context.scope), lock = try SharedTimeMutationGate.begin(key)
        defer { SharedTimeMutationGate.finish(key, id: lock) }
        try check(context)
        guard displayed?.scope == context.scope, displayed?.stamp == context.stamp,
              draft.context.scope == context.scope, draft.context.stamp == context.stamp else { throw StaffReplicaSourceSyncError.access }
        var state = try load(context)
        guard state.pending[draft.review.id] == nil, state.pending.count < 32,
              reviews.contains(where: { $0.id == draft.review.id && $0.canReview && $0.review == draft.review }) else { throw StaffOwnerInvoiceError.changed }
        try await gate(context)
        guard try await detail(draft.review.id, context) == draft.review,
              try await application(draft.review.id, context) == nil else { throw StaffOwnerInvoiceError.changed }
        try draft.proposal.validate(context.scope, original: draft.review)
        _ = try dependencies.verify(draft.proposal, context, false); try check(context)
        // A later approval for this invoice retires an earlier follow-up link.
        recentInvoices.removeAll { $0.invoiceID.uuidString.lowercased() == draft.proposal.expectedInvoice.id }
        state.pending[draft.review.id] = .init(review: draft.review, proposal: draft.proposal,
            prepareBytes: try StaffWorkspacePublicationContract.encode(draft.proposal), phase: "queued", receipt: nil)
        try save(state, context) // Full original and exact wire bytes precede every remote claim.
        try await resume(draft.review.id, state: &state, context: context)
        // Offer the editable invoice only after refresh observes the published
        // application; a local save alone still needs source confirmation.
        hasMore = true; message = "Saved on this device. Sync to confirm the company workspace, then review QuickBooks publication."
    }
    private func rememberInvoice(_ review: StaffOwnerInvoiceReview, context: StaffReplicaSourceContext, customer: String) throws {
        try check(context)
        let route = try StaffOwnerInvoiceRoute(review: review, context: context, customer: customer)
        recentInvoices.removeAll { $0.invoiceID == route.invoiceID }
        recentInvoices.insert(route, at: 0)
        recentInvoices = Array(recentInvoices.prefix(8))
    }
    static func safe(_ error: Error) -> String {
        if let value = error as? StaffOwnerInvoiceError { return value.localizedDescription }
        if let value = error as? StaffOwnerFieldEditError { return value.localizedDescription }
        if let value = error as? StaffReplicaSourceRejected {
            if value.code == "invoice_claimed" { return StaffOwnerInvoiceError.otherDevice.localizedDescription }
            if ["invoice_provider_pending", "invoice_catalog_pending", "invoice_payment_pending"].contains(value.code) {
                return "Finish the original QuickBooks or payment operation before approving more work."
            }
        }
        return "Invoice approval needs another check. Its original work was retained; no new QuickBooks invoice or payment was sent."
    }
}
