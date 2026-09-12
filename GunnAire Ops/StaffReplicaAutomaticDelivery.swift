import Foundation

struct StaffReplicaPreparation: Codable, Equatable {
    let companyID: String
    let environment: String
    let operationID: String
    let expectedSequence: Int
    let expectedShareRevision: Int
    init(plan: CloudKitStaffSharePlan, sequence: Int) {
        companyID = plan.companyID.uuidString.lowercased(); environment = plan.environment
        operationID = UUID().uuidString.lowercased(); expectedSequence = sequence; expectedShareRevision = plan.revision
    }
    func validate(plan: CloudKitStaffSharePlan) throws {
        guard companyID == plan.companyID.uuidString.lowercased(), environment == plan.environment,
              CloudKitStaffSetupPolicy.canonicalID(operationID), (1...2_147_483_647).contains(expectedSequence),
              expectedShareRevision == plan.revision else { throw StaffReplicaDeliveryError.invalid }
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

enum StaffReplicaPreparationPolicy {
    static func path(_ plan: CloudKitStaffSharePlan) -> String {
        CloudKitStaffSetupPolicy.base + "/\(plan.id.uuidString.lowercased())/projections"
    }
    static func allows(path: String, body: Data) -> Bool {
        guard body.count <= 8192, let parts = URLComponents(string: path), parts.scheme == nil, parts.host == nil,
              parts.query == nil, parts.fragment == nil, parts.path == parts.percentEncodedPath,
              let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              Set(root.keys) == ["companyID", "environment", "operationID", "expectedSequence", "expectedShareRevision"],
              let value = try? JSONDecoder().decode(StaffReplicaPreparation.self, from: body),
              CloudKitStaffSetupPolicy.canonicalID(value.companyID), CloudKitStaffSetupPolicy.canonicalID(value.operationID),
              ["development", "production"].contains(value.environment),
              (1...2_147_483_647).contains(value.expectedSequence), (1...2_147_483_647).contains(value.expectedShareRevision) else { return false }
        let segments = parts.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return segments.count == 6 && Array(segments.prefix(4)) == ["", "api", "workspace", "staff-shares"] &&
            CloudKitStaffSetupPolicy.canonicalID(segments[4]) && segments[5] == "projections"
    }
}

struct StaffReplicaPreparationRejected: Error {}
struct StaffReplicaAutomaticSummary: Equatable {
    var shared = 0
    var needsAttention = 0
    var waitingForSetup = 0
    var message: String {
        if needsAttention > 0 { return "Staff sharing needs another check. Saved work and original requests are retained." }
        if shared > 0 { return "Core records shared through iCloud for \(shared) staff account\(shared == 1 ? "" : "s"). Device receipt is not yet confirmed." }
        return "Core records prepared. Staff iCloud setup must be accepted before sharing."
    }
}

struct StaffReplicaAutomaticDependencies {
    typealias Context = CloudKitStaffSetupController.Context
    let setup: () async throws -> (Context, [CloudKitStaffSharePlan])
    let check: (StaffReplicaSourceContext) throws -> Void
    let prepare: (String, Data) async throws -> Data
    let delivery: StaffReplicaDeliveryCoordinator
    let store: SharedTimeLocalStore
    var now: () -> Date = Date.init
    static var live: Self {
        .init(setup: {
            let controller = CloudKitStaffSetupController()
            await controller.refresh()
            if let error = controller.error { throw error }
            guard let context = controller.context else { throw StaffReplicaDeliveryError.access }
            return (context, controller.plans)
        }, check: { try StaffReplicaSourceDependencies.live.check($0) },
              prepare: { try await GunnAireBackendService.staffReplicaPreparationRequest(path: $0, body: $1) },
              delivery: .init(), store: StaffReplicaDeliveryStorage.device)
    }
}

struct StaffReplicaAutomaticPending: Codable, Equatable {
    let plan: CloudKitStaffSharePlan
    let request: StaffReplicaPreparation
    var manifest: StaffReplicaManifest?
}
struct StaffReplicaAutomaticJournal: Codable {
    let scope: StaffReplicaSourceScope
    let planID: UUID
    var pending: StaffReplicaAutomaticPending?
    var lastShared: StaffReplicaManifest?
}
struct StaffReplicaAutomaticArchive: Codable, Equatable {
    let pending: StaffReplicaAutomaticPending
    let outcome: String
    let peer: StaffReplicaManifest?
}

/// Connects a fully reconciled saved source pass to per-member private shares.
/// Journals contain immutable request identities, never plaintext or sealing keys.
/// This does not authorize a participant SwiftData store or claim device receipt.
@MainActor final class StaffReplicaAutomaticDelivery {
    let dependencies: StaffReplicaAutomaticDependencies
    init(dependencies: StaffReplicaAutomaticDependencies? = nil) { self.dependencies = dependencies ?? .live }
    func key(_ source: StaffReplicaSourceContext, _ plan: CloudKitStaffSharePlan) -> String {
        ["staff-auto-delivery-v1", source.scope.key, plan.id.uuidString.lowercased()].joined(separator: "\n")
    }
    private func check(_ source: StaffReplicaSourceContext, _ context: CloudKitStaffSetupController.Context) throws {
        try Task.checkCancellation(); try dependencies.check(source)
        guard context.ownerAdministrator, context.member.isActive, context.member.email == source.scope.actorEmail,
              context.stamp.session == source.stamp.session, dependencies.now() < context.stamp.session.expiresAt,
              context.workspace.binding(for: context.account.environment) == source.scope.binding,
              context.account.accountHash == source.scope.binding.cloudAccountHash else { throw StaffReplicaDeliveryError.access }
    }
    private func load(_ source: StaffReplicaSourceContext, _ plan: CloudKitStaffSharePlan) throws -> StaffReplicaAutomaticJournal {
        guard let data = try dependencies.store.read(key(source, plan)) else { return .init(scope: source.scope, planID: plan.id) }
        guard data.count <= 64 * 1024 else { throw StaffReplicaDeliveryError.storage }
        let journal = try JSONDecoder().decode(StaffReplicaAutomaticJournal.self, from: data)
        guard journal.scope == source.scope, journal.planID == plan.id else { throw StaffReplicaDeliveryError.storage }
        if let pending = journal.pending {
            // Revocation or a changed role may not silently replace an in-flight original.
            guard pending.plan == plan else { throw StaffReplicaDeliveryError.changed }
            try pending.request.validate(plan: plan)
            if let manifest = pending.manifest {
                guard manifest.operationID.uuidString.lowercased() == pending.request.operationID,
                      manifest.sourceSequence == pending.request.expectedSequence else { throw StaffReplicaDeliveryError.storage }
            }
        }
        return journal
    }
    private func save(_ journal: StaffReplicaAutomaticJournal, source: StaffReplicaSourceContext, plan: CloudKitStaffSharePlan,
                      context: CloudKitStaffSetupController.Context) throws {
        try check(source, context)
        do { try dependencies.store.write(key(source, plan), JSONEncoder().encode(journal)) }
        catch { throw StaffReplicaDeliveryError.storage }
    }
    private func finish(_ journal: inout StaffReplicaAutomaticJournal, outcome: String, peer: StaffReplicaManifest? = nil,
                        source: StaffReplicaSourceContext, plan: CloudKitStaffSharePlan, context: CloudKitStaffSetupController.Context) throws {
        try check(source, context)
        guard let pending = journal.pending else { throw StaffReplicaDeliveryError.invalid }
        let archive = StaffReplicaAutomaticArchive(pending: pending, outcome: outcome, peer: peer)
        let archiveKey = key(source, plan) + "\noriginal-" + pending.request.operationID
        // Archive before clearing the index; a lost write acknowledgement replays
        // the same proof, never drops an uncertain request or changes its outcome.
        do {
            if let data = try dependencies.store.read(archiveKey) {
                guard try JSONDecoder().decode(StaffReplicaAutomaticArchive.self, from: data) == archive else { throw StaffReplicaDeliveryError.storage }
            } else { try dependencies.store.write(archiveKey, JSONEncoder().encode(archive)) }
        } catch { throw StaffReplicaDeliveryError.storage }
        journal.pending = nil
        if outcome == "shared" { journal.lastShared = pending.manifest }
        if outcome == "peer" { journal.lastShared = peer }
        try save(journal, source: source, plan: plan, context: context)
    }
    private func member(_ plan: CloudKitStaffSharePlan, source: StaffReplicaSourceContext,
                        context: CloudKitStaffSetupController.Context, sequence: Int) async throws {
        let base = dependencies.delivery.dependencies
        // Carry the physical owner-store fence through every nested server,
        // CloudKit and local-journal boundary, not merely the outer UI await.
        let delivery = StaffReplicaDeliveryCoordinator(dependencies: .init(stamp: base.stamp,
            authorize: { c, p in try self.check(source, context); try await base.authorize(c, p); try self.check(source, context) },
            request: { path in
                try self.check(source, context); let data = try await base.request(path); try self.check(source, context); return data
            }, ownerIO: { p, c, authorize in
                try self.check(source, context)
                return try base.ownerIO(p, c, { try self.check(source, context); try await authorize(); try self.check(source, context) })
            }, participantIO: base.participantIO, store: .init(read: { key in
                try self.check(source, context); return try base.store.read(key)
            }, write: { key, bytes in try self.check(source, context); try base.store.write(key, bytes) }), now: base.now))
        let lock = key(source, plan)
        try CloudKitStaffSetupLocks.acquire(lock); defer { CloudKitStaffSetupLocks.release(lock) }
        var journal = try load(source, plan)
        if let pending = journal.pending,
           let data = try dependencies.store.read(key(source, plan) + "\noriginal-" + pending.request.operationID) {
            guard data.count <= 64 * 1024 else { throw StaffReplicaDeliveryError.storage }
            let archive = try JSONDecoder().decode(StaffReplicaAutomaticArchive.self, from: data)
            guard archive.pending == pending, ["shared", "peer", "superseded", "rejected"].contains(archive.outcome),
                  archive.outcome != "peer" || archive.peer != nil else { throw StaffReplicaDeliveryError.storage }
            // Recover an acknowledged archive whose index-clear reply was lost.
            // A fresh CloudKit proof is still required below before reporting shared.
            journal.pending = nil
            try save(journal, source: source, plan: plan, context: context)
        }
        // At most one recovered obsolete original plus one new current operation.
        for _ in 0..<2 {
            try check(source, context)
            if journal.pending == nil {
                if let peer = try await delivery.currentPublication(plan: plan, context: context, sequence: sequence) {
                    try check(source, context); journal.lastShared = peer
                    try save(journal, source: source, plan: plan, context: context); return
                }
                journal.pending = .init(plan: plan, request: .init(plan: plan, sequence: sequence))
                try save(journal, source: source, plan: plan, context: context)
            }
            guard var pending = journal.pending else { throw StaffReplicaDeliveryError.storage }
            let bytes = try pending.request.encoded(), path = StaffReplicaPreparationPolicy.path(plan)
            guard StaffReplicaPreparationPolicy.allows(path: path, body: bytes) else { throw StaffReplicaDeliveryError.invalid }
            let receipt: StaffReplicaProjectionReceipt
            do {
                try check(source, context)
                let data = try await dependencies.prepare(path, bytes)
                try check(source, context)
                guard data.count <= 8192 else { throw StaffReplicaDeliveryError.invalid }
                receipt = try JSONDecoder().decode(StaffReplicaProjectionReceipt.self, from: data)
            } catch is StaffReplicaPreparationRejected {
                guard pending.manifest == nil else { throw StaffReplicaDeliveryError.changed }
                try finish(&journal, outcome: "rejected", source: source, plan: plan, context: context)
                throw StaffReplicaDeliveryError.changed
            }
            try receipt.validateMetadata(plan: plan, workspace: context.workspace, now: dependencies.now())
            guard receipt.manifest.operationID.uuidString.lowercased() == pending.request.operationID,
                  receipt.manifest.sourceSequence == pending.request.expectedSequence,
                  receipt.payloadBase64 == nil, receipt.keyBase64 == nil, receipt.sealedBase64 == nil, receipt.sealVersion == nil,
                  pending.manifest == nil || pending.manifest == receipt.manifest else { throw StaffReplicaDeliveryError.invalid }
            pending.manifest = receipt.manifest; journal.pending = pending
            try save(journal, source: source, plan: plan, context: context)
            if !receipt.isCurrent || !receipt.authorizationCurrent {
                try finish(&journal, outcome: "superseded", source: source, plan: plan, context: context)
                guard receipt.currentSequence == sequence else { throw StaffReplicaDeliveryError.changed }
                continue
            }
            guard receipt.currentSequence == sequence else { throw StaffReplicaDeliveryError.changed }
            // Resolve an equal-sequence winner before attempting an upload.
            if let peer = try await delivery.currentPublication(plan: plan, context: context, sequence: sequence) {
                try finish(&journal, outcome: "peer", peer: peer, source: source, plan: plan, context: context); return
            }
            let delivered: StaffReplicaManifest
            do {
                delivered = try await delivery.publish(operation: receipt.manifest.operationID, plan: plan, context: context, requireCurrent: true)
            } catch {
                // Another owner may win the atomic save race. Only an actual,
                // decrypted original asset and fresh authority prove that win.
                try check(source, context)
                if let peer = try await delivery.currentPublication(plan: plan, context: context, sequence: sequence) {
                    try finish(&journal, outcome: "peer", peer: peer, source: source, plan: plan, context: context); return
                }
                throw error
            }
            guard delivered == receipt.manifest else { throw StaffReplicaDeliveryError.changed }
            try finish(&journal, outcome: "shared", source: source, plan: plan, context: context); return
        }
        throw StaffReplicaDeliveryError.changed
    }
    func deliver(source: StaffReplicaSourceContext, sequence: Int) async throws -> StaffReplicaAutomaticSummary {
        try dependencies.check(source)
        guard (1...2_147_483_647).contains(sequence) else { return .init(waitingForSetup: 1) }
        let (context, plans) = try await dependencies.setup()
        try check(source, context)
        guard plans.count <= 5000, Set(plans.map(\.id)).count == plans.count,
              Set(plans.map(\.zoneName)).count == plans.count else { throw StaffReplicaDeliveryError.invalid }
        var result = StaffReplicaAutomaticSummary()
        for plan in plans {
            try check(source, context)
            try plan.validate(workspace: context.workspace, now: dependencies.now())
            guard plan.state == "accepted", plan.businessAccessEligible, !plan.reviewRequired, !plan.cloudKitRevocationRequired else {
                if plan.state != "revoked" { result.waitingForSetup += 1 }; continue
            }
            do { try await member(plan, source: source, context: context, sequence: sequence); result.shared += 1 }
            catch is CancellationError { throw CancellationError() }
            catch { try check(source, context); result.needsAttention += 1 }
        }
        return result
    }
}
