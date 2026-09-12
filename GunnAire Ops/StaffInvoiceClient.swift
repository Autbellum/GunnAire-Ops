import Foundation

struct StaffInvoiceClientDependencies {
    struct Access {
        let scope: CloudKitStaffSetupScope
        let plan: UUID
        let source: StaffInvoiceSource
    }
    /// false requires foreground, non-refreshing transmission authority; true only permits local draft capture.
    let current: (Bool) throws -> Access
    let store: SharedTimeLocalStore
    let send: (String, Data) async throws -> Data
    var operation: () -> UUID = UUID.init

    static func live(hosted: StaffWorkspaceOperationalHostedStore, invoice: String,
                     receive: StaffReplicaReceiveController? = nil, store: SharedTimeLocalStore? = nil) -> Self {
        let receive = receive ?? .shared, anchor = receive.authorizedPresentation
        var verifiedHost: StaffWorkspaceOperationalHostedStore?
        var verifiedSource: StaffInvoiceSource?
        return .init(current: { local in
            guard let anchor, anchor.workspace.hosted === hosted,
                  let current = receive.authorizedPresentation,
                  current.navigationIdentity.authority == anchor.navigationIdentity.authority else { throw StaffReplicaDeliveryError.access }
            let host = current.workspace.hosted
            let (context, plan) = try receive.fieldEditingAuthority(for: host, localDraftOnly: local)
            guard context.owns(plan), context.member.role == plan.memberRole, host.plan.memberRole == plan.memberRole else {
                throw StaffReplicaDeliveryError.access
            }
            // Keystrokes use the last verified immutable choices while still checking the live lease.
            // Queue/transmit paths always recheck the actual projection store.
            if local, verifiedHost === host, let verifiedSource {
                return .init(scope: context.scope, plan: plan.id, source: verifiedSource)
            }
            try StaffWorkspaceOperationalPresentation.requireHosted(host)
            let actual = try host.fetch(), expected = host.plan.records.sorted { ($0.kind, $0.id) < ($1.kind, $1.id) }
            guard actual == expected else { throw StaffReplicaDeliveryError.changed }
            // Financial permission is separate from the operations-field allowlist.
            let source = try StaffInvoiceSource.make(plan: host.plan, invoiceID: invoice)
            verifiedHost = host; verifiedSource = source
            return .init(scope: context.scope, plan: plan.id, source: source)
        }, store: store ?? StaffWorkspaceContentStorage.device,
            send: { try await GunnAireBackendService.staffInvoiceRequest(path: $0, body: $1) })
    }
}

/// All entry points are actor-bound and use fresh live authority; saved scope is never a lease.
@MainActor final class StaffInvoiceClient {
    let dependencies: StaffInvoiceClientDependencies
    let scope: CloudKitStaffSetupScope
    let plan: UUID
    let replica: String
    let invoice: String
    nonisolated deinit {}
    init(dependencies: StaffInvoiceClientDependencies) throws {
        let access = try dependencies.current(false)
        self.dependencies = dependencies; scope = access.scope; plan = access.plan
        replica = access.source.origin.replicaID; invoice = access.source.origin.invoiceID
    }
    func source(local: Bool = false) throws -> StaffInvoiceSource {
        let current = try dependencies.current(local)
        guard current.scope == scope, current.plan == plan, current.source.origin.replicaID == replica,
              current.source.origin.invoiceID == invoice else { throw StaffReplicaDeliveryError.access }
        return current.source
    }
    func load() throws -> StaffInvoiceJournal? {
        _ = try source(local: true)
        let result = try StaffInvoiceJournalStore.load(store: dependencies.store, scope: scope, plan: plan, replica: replica, invoice: invoice)
        _ = try source(local: true); return result
    }
    func next(_ original: StaffInvoiceJournal?) -> StaffInvoiceJournal {
        var next = original ?? .init(scope: scope, planID: plan, replicaID: replica, invoiceID: invoice)
        next.revision = original.map { $0.revision + 1 } ?? 0
        return next
    }
    private func write(_ next: StaffInvoiceJournal, expected: StaffInvoiceJournal?, local: Bool) throws {
        try next.validate(scope: scope, plan: plan, replica: replica, invoice: invoice)
        try StaffInvoiceJournalStore.write(store: dependencies.store, next: next, expected: expected, check: { _ = try self.source(local: local) })
    }
    func draft(_ draft: StaffInvoiceDraft?, expected: StaffInvoiceJournal?) throws -> StaffInvoiceJournal {
        var next = next(expected); next.draft = draft
        try write(next, expected: expected, local: true); return next
    }
    func stage(expected: StaffInvoiceJournal) throws -> StaffInvoiceJournal {
        guard let draft = expected.draft, expected.entries.count < 128 else { throw StaffReplicaDeliveryError.pending }
        let request = try draft.request()
        try source().validate(request)
        var next = next(expected); next.entries.append(.init(request: request, receipt: nil)); next.draft = nil
        try write(next, expected: expected, local: false); return next
    }
    /// Only an original already present in this primary journal may be retried.
    func send(id: String) async throws -> StaffInvoiceJournal {
        _ = try source()
        let lockKey = StaffInvoiceJournalStore.key(scope: scope, plan: plan, invoice: invoice) + "\nsend\n" + id
        let lock = try SharedTimeMutationGate.begin(lockKey)
        defer { SharedTimeMutationGate.finish(lockKey, id: lock) }
        guard let before = try load(), let entry = before.entries.first(where: { $0.id == id }) else { throw StaffReplicaDeliveryError.storage }
        if entry.receipt != nil { return before }
        let path = StaffInvoiceHTTPPolicy.path(plan: plan, request: entry.request)
        let body = try StaffWorkspacePublicationContract.encode(entry.request)
        guard StaffInvoiceHTTPPolicy.allows(path: path, method: "POST", body: body) else { throw StaffReplicaDeliveryError.invalid }
        _ = try source(); try Task.checkCancellation()
        let bytes = try await dependencies.send(path, body)
        _ = try source(); try Task.checkCancellation()
        let receipt = try StaffWorkspacePublicationContract.decode(StaffInvoiceReceipt.self, from: bytes, maximum: 32 * 1024)
        try receipt.validate(request: entry.request, email: scope.email, plan: plan)
        guard let current = try load(), let index = current.entries.firstIndex(where: { $0.id == id }),
              current.entries[index].request == entry.request else { throw StaffReplicaDeliveryError.storage }
        if let previous = current.entries[index].receipt {
            guard previous == receipt else { throw StaffReplicaDeliveryError.storage }; return current
        }
        var next = next(current); next.entries[index].receipt = receipt
        try write(next, expected: current, local: false); return next
    }
}
