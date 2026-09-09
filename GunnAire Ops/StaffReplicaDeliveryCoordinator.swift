import Foundation
import CryptoKit

struct StaffReplicaDeliveryDependencies {
    typealias Context = CloudKitStaffSetupController.Context
    let stamp: () -> CloudKitStaffSetupStamp?
    let authorize: (Context, CloudKitStaffSharePlan) async throws -> Void
    let request: (String) async throws -> Data
    let ownerIO: (CloudKitStaffSharePlan, Context, @escaping CloudKitStaffRemote.Authorize) throws -> StaffReplicaCloudIO
    let participantIO: (CloudKitStaffSharePlan, Context, URL, @escaping CloudKitStaffRemote.Authorize) async throws -> StaffReplicaCloudIO
    let store: SharedTimeLocalStore
    var now: () -> Date = Date.init

    static var live: Self {
        .init(stamp: { .current }, authorize: { context, plan in
            guard CloudKitStaffSetupStamp.current == context.stamp else { throw StaffReplicaDeliveryError.access }
            let account = try await CompanyCloudKitRuntimeAccount.current()
            let bytes = try await GunnAireBackendService.staffCloudKitSetupRequest(path: "/api/workspace", method: "GET", body: nil)
            let workspace = try JSONDecoder().decode(BackendCompanyWorkspaceResponse.self, from: bytes)
            guard CloudKitStaffSetupStamp.current == context.stamp, account.environment == context.account.environment,
                  account.accountHash == context.account.accountHash, workspace.workspace == context.workspace,
                  workspace.user.email == context.member.email, workspace.user.role == context.member.role, workspace.user.isActive else {
                throw StaffReplicaDeliveryError.changed
            }
            let path = CloudKitStaffSetupPolicy.query(company: plan.companyID, environment: plan.environment, id: plan.id)
            let latest = try await GunnAireBackendService.staffCloudKitSetupRequest(path: path, method: "GET", body: nil)
            guard try JSONDecoder().decode(CloudKitStaffSharePlan.self, from: latest) == plan,
                  CloudKitStaffSetupStamp.current == context.stamp else { throw StaffReplicaDeliveryError.changed }
        }, request: { try await GunnAireBackendService.staffReplicaDeliveryRequest(path: $0) },
              ownerIO: StaffReplicaCloudTransfer.ownerIO, participantIO: StaffReplicaCloudTransfer.participantIO,
              store: StaffReplicaDeliveryStorage.device)
    }
}

enum StaffReplicaDeliveryStorage {
    static var device: SharedTimeLocalStore {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return .init(read: { _ in throw StaffReplicaDeliveryError.storage }, write: { _, _ in throw StaffReplicaDeliveryError.storage })
        }
        return .encrypted(directory: root.appendingPathComponent("StaffReplicaDelivery-v1", isDirectory: true), maximumBytes: 24 * 1024 * 1024) { create in
            let name = "StaffReplicaDeliveryEncryption-v1"
            if let bytes = try KeychainStore.loadCodable(Data.self, account: name) {
                guard bytes.count == 32 else { throw StaffReplicaDeliveryError.storage }; return bytes
            }
            guard create else { throw StaffReplicaDeliveryError.storage }
            let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try KeychainStore.saveCodable(bytes, account: name); return bytes
        }
    }
}

struct StaffReplicaDeliveryJournal: Codable {
    let scope: CloudKitStaffSetupScope
    let plan: CloudKitStaffSharePlan
    let manifest: StaffReplicaManifest
    let state: String
    let payload: Data?
}

/// Durable callable delivery service. It does not bootstrap source data, import
/// models, schedule background work, or change CompanyWorkspaceStore authority.
@MainActor final class StaffReplicaDeliveryCoordinator {
    typealias Context = CloudKitStaffSetupController.Context
    let dependencies: StaffReplicaDeliveryDependencies
    init(dependencies: StaffReplicaDeliveryDependencies? = nil) { self.dependencies = dependencies ?? .live }

    private func check(_ context: Context, plan: CloudKitStaffSharePlan) throws {
        try Task.checkCancellation()
        guard dependencies.stamp() == context.stamp, dependencies.now() < context.stamp.session.expiresAt,
              context.member.isActive, context.member.email == context.stamp.session.email,
              plan.environment == context.account.environment,
              context.ownerAdministrator || (context.owns(plan) && context.member.role == plan.memberRole) else { throw StaffReplicaDeliveryError.access }
        try plan.validate(workspace: context.workspace, now: dependencies.now())
        guard plan.state == "accepted", plan.businessAccessEligible, !plan.reviewRequired, !plan.cloudKitRevocationRequired else { throw StaffReplicaDeliveryError.changed }
    }
    private func authorize(_ context: Context, plan: CloudKitStaffSharePlan) async throws {
        try check(context, plan: plan)
        try await dependencies.authorize(context, plan)
        try check(context, plan: plan)
    }
    private func receipt(_ operation: UUID, plan: CloudKitStaffSharePlan, context: Context, payload: Bool = false, key: Bool = false) async throws -> StaffReplicaProjectionReceipt {
        try await authorize(context, plan: plan)
        guard !payload || context.ownerAdministrator else { throw StaffReplicaDeliveryError.access }
        let path = StaffReplicaDeliveryPolicy.path(plan: plan, operation: operation, payload: payload, key: key)
        guard StaffReplicaDeliveryPolicy.allows(path: path) else { throw StaffReplicaDeliveryError.invalid }
        let bytes = try await dependencies.request(path)
        try check(context, plan: plan)
        let maximum = payload ? ((StaffReplicaManifest.maximumPayloadBytes + 30) / 3) * 4 + 8192 : 8192
        guard bytes.count <= maximum else { throw StaffReplicaDeliveryError.invalid }
        let result = try JSONDecoder().decode(StaffReplicaProjectionReceipt.self, from: bytes)
        try result.validate(plan: plan, workspace: context.workspace, now: dependencies.now())
        guard result.manifest.operationID == operation, result.payloadBase64 == nil,
              payload || result.sealedBase64 == nil, payload || key || result.keyBase64 == nil else { throw StaffReplicaDeliveryError.invalid }
        return result
    }
    func key(context: Context, plan: CloudKitStaffSharePlan, operation: UUID? = nil) -> String {
        ["staff-replica-delivery-v1", context.scope.key, plan.id.uuidString.lowercased(), StaffReplicaCoreSource.schemaVersion,
         operation.map { "publish-" + $0.uuidString.lowercased() } ?? "staged"].joined(separator: "\n")
    }
    private func load(_ key: String, context: Context, plan: CloudKitStaffSharePlan, operation: UUID?) throws -> StaffReplicaDeliveryJournal? {
        do {
            guard let bytes = try dependencies.store.read(key) else { return nil }
            guard bytes.count <= 24 * 1024 * 1024 - 64 else { throw StaffReplicaDeliveryError.storage }
            let saved = try JSONDecoder().decode(StaffReplicaDeliveryJournal.self, from: bytes)
            guard saved.scope == context.scope, saved.plan == plan else { throw StaffReplicaDeliveryError.storage }
            try saved.manifest.validate(plan: plan, workspace: context.workspace, now: dependencies.now())
            if let operation {
                guard saved.manifest.operationID == operation, ["prepared", "confirmed"].contains(saved.state), saved.payload == nil else { throw StaffReplicaDeliveryError.storage }
            } else {
                guard saved.state == "staged", let payload = saved.payload else { throw StaffReplicaDeliveryError.storage }
                _ = try StaffReplicaVerifiedPayload(manifest: saved.manifest, bytes: payload)
            }
            return saved
        } catch { throw StaffReplicaDeliveryError.storage }
    }
    private func save(_ value: StaffReplicaDeliveryJournal, key: String, context: Context) throws {
        try check(context, plan: value.plan)
        do { try dependencies.store.write(key, JSONEncoder().encode(value)) }
        catch { throw StaffReplicaDeliveryError.storage }
    }

    /// Receives an already prepared backend operation; never invents a new
    /// snapshot on timeout. Reopening this exact ID recovers Apple's original.
    func publish(operation: UUID, plan: CloudKitStaffSharePlan, context: Context) async throws -> StaffReplicaManifest {
        try check(context, plan: plan)
        guard context.ownerAdministrator else { throw StaffReplicaDeliveryError.access }
        let lock = key(context: context, plan: plan), key = key(context: context, plan: plan, operation: operation)
        try CloudKitStaffSetupLocks.acquire(lock)
        defer { CloudKitStaffSetupLocks.release(lock) }
        let saved = try load(key, context: context, plan: plan, operation: operation)
        let receipt = try await receipt(operation, plan: plan, context: context, payload: true)
        let payload = try receipt.ownerSealedPayload()
        guard saved == nil || saved?.manifest == payload.manifest else { throw StaffReplicaDeliveryError.changed }
        let intent = StaffReplicaDeliveryJournal(scope: context.scope, plan: plan, manifest: payload.manifest, state: "prepared", payload: nil)
        // Write before any CloudKit I/O, including recovery. An uncertain prior
        // result never silently becomes a new operation or a replaced payload.
        try save(intent, key: key, context: context)
        let authorize: CloudKitStaffRemote.Authorize = {
            let current = try await self.receipt(operation, plan: plan, context: context)
            guard current.manifest == payload.manifest else { throw StaffReplicaDeliveryError.changed }
        }
        let io = try dependencies.ownerIO(plan, context, authorize)
        try await StaffReplicaCloudTransfer.publish(payload, plan: plan, workspace: context.workspace, io: io, now: dependencies.now)
        try await authorize()
        try save(.init(scope: context.scope, plan: plan, manifest: payload.manifest, state: "confirmed", payload: nil), key: key, context: context)
        return payload.manifest
    }

    /// Keeps an encrypted, monotonic staging envelope only. No SwiftData model
    /// changes and no pending technician edits are consumed by this transport.
    func download(plan: CloudKitStaffSharePlan, context: Context, invitation: URL) async throws -> StaffReplicaManifest {
        try check(context, plan: plan)
        guard context.owns(plan), CloudKitStaffSetupPolicy.invitationURL(invitation) else { throw StaffReplicaDeliveryError.access }
        let key = key(context: context, plan: plan)
        try CloudKitStaffSetupLocks.acquire(key)
        defer { CloudKitStaffSetupLocks.release(key) }
        let old = try load(key, context: context, plan: plan, operation: nil)
        let authorize: CloudKitStaffRemote.Authorize = { try await self.authorize(context, plan: plan) }
        let io = try await dependencies.participantIO(plan, context, invitation, authorize)
        let payload = try await StaffReplicaCloudTransfer.download(plan: plan, workspace: context.workspace, io: io,
            authority: { try await self.receipt($0, plan: plan, context: context, key: true) }, now: dependencies.now)
        if let old {
            guard payload.manifest.sourceSequence >= old.manifest.sourceSequence,
                  payload.manifest.authorizationSequence >= old.manifest.authorizationSequence,
                  payload.manifest.sourceSequence != old.manifest.sourceSequence || payload.bytes == old.payload else { throw StaffReplicaDeliveryError.superseded }
        }
        let fresh = try await receipt(payload.manifest.operationID, plan: plan, context: context)
        guard fresh.manifest == payload.manifest else { throw StaffReplicaDeliveryError.changed }
        try await authorize()
        try save(.init(scope: context.scope, plan: plan, manifest: payload.manifest, state: "staged", payload: payload.bytes), key: key, context: context)
        return payload.manifest // Applied sourceSequence remains untouched.
    }
}
