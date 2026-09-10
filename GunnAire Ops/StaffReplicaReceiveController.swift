import Foundation
import Combine

/// SwiftUI task identity must compare the request, not an unordered JSON
/// encoding. A display update must not cancel and immediately retry a read.
struct StaffReplicaReceiveIdentity: Equatable {
    let stamp: CloudKitStaffSetupStamp
    let plan: CloudKitStaffSharePlan
    let invitation: URL?
    let isActive: Bool
}

struct StaffReplicaReceiveDependencies {
    typealias Context = CloudKitStaffSetupController.Context
    let check: (Context) throws -> Void
    let download: (CloudKitStaffSharePlan, Context, URL) async throws -> StaffReplicaManifest
    /// Optional full-workspace cloud receive/lease after core replica staging.
    /// Live wires StaffWorkspaceContentCoordinator.receiveAndLease. Tests may leave nil.
    var receiveFullWorkspace: ((CloudKitStaffSharePlan, Context, URL) async throws -> StaffWorkspaceCloudReceiveResult)? = nil
    /// Optional fail-soft ready-v1 flip after operational acceptance.
    var markOperationalReady: ((CloudKitStaffSharePlan, Context, URL) async throws -> StaffWorkspaceOperationalReadyJournal)? = nil
    /// Optional load of an already-present ready-v1 journal for messaging.
    var loadOperationalReady: ((CloudKitStaffSharePlan, Context) throws -> StaffWorkspaceOperationalReadyJournal?)? = nil
    /// Optional fail-soft host-v1 attach after ready flip.
    var openOperationalHost: ((CloudKitStaffSharePlan, Context) throws -> StaffWorkspaceOperationalHostedStore)? = nil
    /// Optional load of an already-present host-v1 journal for messaging.
    var loadOperationalHost: ((CloudKitStaffSharePlan, Context) throws -> StaffWorkspaceOperationalHostedStore?)? = nil
    /// Optional fail-soft identity-v1 bind after host attach.
    var bindOperationalIdentity: ((CloudKitStaffSharePlan, Context, StaffWorkspaceOperationalHostedStore) throws -> StaffWorkspaceOperationalIdentityJournal)? = nil
    /// Optional load of an already-present identity-v1 journal for messaging.
    var loadOperationalIdentity: ((CloudKitStaffSharePlan, Context) throws -> StaffWorkspaceOperationalIdentityJournal?)? = nil
    var now: () -> Date = Date.init
    static var live: Self {
        .init(check: { context in
            guard !GunnAireCloudKit.usesTestDatabase, CloudKitStaffSetupStamp.current == context.stamp else { throw StaffReplicaDeliveryError.access }
        }, download: { plan, context, url in
            try await StaffReplicaDeliveryCoordinator().download(plan: plan, context: context, invitation: url, requireCurrent: true,
                validate: { _ = try StaffReplicaCoreGraph(payload: $0, plan: plan, workspace: context.workspace) })
        }, receiveFullWorkspace: { plan, context, url in
            try await StaffWorkspaceContentCoordinator.shared.receiveAndLease(plan: plan, context: context, invitation: url)
        }, markOperationalReady: { plan, context, url in
            try await StaffWorkspaceContentCoordinator.shared.markOperationalWorkspaceReady(
                plan: plan, context: context, invitation: url)
        }, loadOperationalReady: { plan, context in
            try StaffWorkspaceContentCoordinator.shared.loadOperationalWorkspaceReady(plan: plan, context: context)
        }, openOperationalHost: { plan, context in
            try StaffWorkspaceContentCoordinator.shared.openOperationalHost(plan: plan, context: context)
        }, loadOperationalHost: { plan, context in
            try StaffWorkspaceContentCoordinator.shared.loadOperationalHost(plan: plan, context: context)
        }, bindOperationalIdentity: { plan, context, hosted in
            let fingerprint = StaffWorkspaceOperationalIdentityStore.deviceFingerprint(
                installationID: StaffPushNotificationManager.shared.installationID)
            return try StaffWorkspaceContentCoordinator.shared.bindOperationalIdentity(
                plan: plan, context: context, deviceFingerprint: fingerprint, hosted: hosted)
        }, loadOperationalIdentity: { plan, context in
            try StaffWorkspaceContentCoordinator.shared.loadOperationalIdentity(plan: plan, context: context)
        })
    }
}

/// Receives and validates real shared-database bytes into the encrypted stage,
/// then optionally verifies the full-workspace cloud seal into a durable operational
/// mount and lease marker. This is not a private owner-store lease or a ModelContext import.
@MainActor final class StaffReplicaReceiveController: ObservableObject {
    static let shared = StaffReplicaReceiveController()
    typealias Context = CloudKitStaffSetupController.Context
    let dependencies: StaffReplicaReceiveDependencies
    @Published private(set) var isRunning = false
    @Published private(set) var message = "Waiting for shared business data."
    @Published private(set) var received: StaffReplicaManifest?
    /// Live hosted staff projection handle after host-v1 attach. Retained for
    /// staff UI/nav presentation via the HostedStore ModelContainer.
    @Published private(set) var hostedStore: StaffWorkspaceOperationalHostedStore?
    /// Bound operational identity after identity-v1 (fail-soft; host may succeed first).
    @Published private(set) var operationalIdentity: StaffWorkspaceOperationalIdentityJournal?
    /// Account + device fingerprint used with the published identity for requireBound.
    @Published private(set) var presentationAccount: CompanyCloudKitAccount?
    @Published private(set) var presentationDeviceFingerprint: String?
    private var editingContext: Context?
    private var editingPlan: CloudKitStaffSharePlan?
    private var generation = UUID()
    init(dependencies: StaffReplicaReceiveDependencies? = nil) { self.dependencies = dependencies ?? .live }
    // No cleanup callbacks or actor-state changes are needed when releasing it.
    nonisolated deinit {}
    func clearDisplay() {
        generation = UUID(); received = nil; hostedStore = nil
        operationalIdentity = nil; presentationAccount = nil; presentationDeviceFingerprint = nil
        editingContext = nil; editingPlan = nil
        message = "Waiting for shared business data."
    }
    /// Reuse only this still-authorized, hosted session for offline local capture.
    /// Never grants the owner store or revives a previous account's cached context.
    func fieldEditingAuthority(for hosted: StaffWorkspaceOperationalHostedStore) throws -> (Context, CloudKitStaffSharePlan) {
        guard hostedStore === hosted, let context = editingContext, let plan = editingPlan,
              hosted.journal.scope == context.scope, hosted.journal.planID == plan.id else { throw StaffReplicaDeliveryError.access }
        try check(context, plan, generation)
        if isRunning { throw StaffReplicaDeliveryError.pending }
        return (context, plan)
    }
    /// Fresh setup reads recover the original accepted invitation while the
    /// authenticated staff device is waiting at the company gate.
    func refreshFromSetup() async {
        guard !isRunning, !GunnAireCloudKit.usesTestDatabase else { return }
        let generation = generation
        let setup = CloudKitStaffSetupController()
        await setup.refresh()
        guard !Task.isCancelled, self.generation == generation else { return }
        if let error = setup.error {
            clearDisplay(); message = StaffReplicaDeliveryPolicy.safe(error).localizedDescription; return
        }
        guard !setup.needsRecovery, let context = setup.context, !context.ownerAdministrator else {
            clearDisplay(); message = "Verify the original staff setup before receiving business data."; return
        }
        let plans = setup.plans.filter { context.owns($0) && $0.state == "accepted" && $0.businessAccessEligible && !$0.reviewRequired && !$0.cloudKitRevocationRequired }
        guard plans.count == 1, let plan = plans.first,
              let url = setup.journal?.invitationURLs[plan.id.uuidString.lowercased()] else {
            clearDisplay(); message = "Verify one original accepted invitation before receiving business data."; return
        }
        await refresh(context: context, plan: plan, invitation: url)
    }
    private func check(_ context: Context, _ plan: CloudKitStaffSharePlan, _ generation: UUID) throws {
        try Task.checkCancellation(); try dependencies.check(context)
        guard self.generation == generation, context.owns(plan), !context.ownerAdministrator,
              context.member.isActive, context.member.email == context.stamp.session.email,
              context.member.role == plan.memberRole, context.account.environment == plan.environment,
              dependencies.now() < context.stamp.session.expiresAt else { throw StaffReplicaDeliveryError.access }
        try plan.validate(workspace: context.workspace, now: dependencies.now())
        guard plan.state == "accepted", plan.businessAccessEligible, !plan.reviewRequired, !plan.cloudKitRevocationRequired else {
            throw StaffReplicaDeliveryError.changed
        }
    }
    @discardableResult func refresh(context: Context, plan: CloudKitStaffSharePlan, invitation: URL) async -> Bool {
        guard !isRunning else { return false }
        let generation = generation
        isRunning = true; received = nil
        defer { isRunning = false }
        do {
            try check(context, plan, generation)
            guard CloudKitStaffSetupPolicy.invitationURL(invitation) else { throw StaffReplicaDeliveryError.invalid }
            message = "Receiving shared records through iCloud…"
            let value = try await dependencies.download(plan, context, invitation)
            try check(context, plan, generation)
            try value.validate(plan: plan, workspace: context.workspace, now: dependencies.now())
            received = value
            if let receiveFullWorkspace = dependencies.receiveFullWorkspace {
                do {
                    let cloud = try await receiveFullWorkspace(plan, context, invitation)
                    try check(context, plan, generation)
                    if cloud.operationalAccepted {
                        message = "Core records received. Full workspace mounted and accepted for read-only staff view."
                        // Fail-soft ready-v1: core accept stays valid if flip is pending.
                        var readyAuthorized = false
                        if let loadReady = dependencies.loadOperationalReady,
                           let ready = try? loadReady(plan, context),
                           ready.operationalWorkspaceReady, ready.state == "ready" {
                            message = "Core records received. Operational workspace ready for staff projection."
                            readyAuthorized = true
                        } else if let markReady = dependencies.markOperationalReady {
                            do {
                                let ready = try await markReady(plan, context, invitation)
                                try check(context, plan, generation)
                                if ready.operationalWorkspaceReady, ready.state == "ready" {
                                    message = "Core records received. Operational workspace ready for staff projection."
                                    readyAuthorized = true
                                }
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                try check(context, plan, generation)
                                // Keep mounted/accepted message; ready flip can retry later.
                            }
                        }
                        // Fail-soft host-v1: ready message stays valid if host attach is pending.
                        if readyAuthorized {
                            var publishedHost: StaffWorkspaceOperationalHostedStore?
                            if let loadHost = dependencies.loadOperationalHost,
                               let hosted = try? loadHost(plan, context),
                               hosted.journal.operationalWorkspaceReady, hosted.journal.state == "hosted" {
                                publishedHost = hosted
                            } else if let openHost = dependencies.openOperationalHost {
                                do {
                                    let hosted = try openHost(plan, context)
                                    try check(context, plan, generation)
                                    if hosted.journal.operationalWorkspaceReady, hosted.journal.state == "hosted" {
                                        publishedHost = hosted
                                    }
                                } catch is CancellationError {
                                    throw CancellationError()
                                } catch {
                                    try check(context, plan, generation)
                                    // Keep ready/accepted message; host attach can retry later.
                                }
                            }
                            if let hosted = publishedHost {
                                hostedStore = hosted
                                editingContext = context; editingPlan = plan
                                message = "Core records received. Operational workspace hosted for staff projection."
                                // Fail-soft identity-v1: host remains valid if bind is pending.
                                if let loadIdentity = dependencies.loadOperationalIdentity,
                                   let identity = try? loadIdentity(plan, context),
                                   identity.state == "bound", identity.operationalWorkspaceReady == false {
                                    operationalIdentity = identity
                                    presentationAccount = context.account
                                    presentationDeviceFingerprint = identity.deviceFingerprint
                                    message = "Core records received. Operational workspace hosted and identity-bound for staff projection."
                                } else if let bindIdentity = dependencies.bindOperationalIdentity {
                                    do {
                                        let identity = try bindIdentity(plan, context, hosted)
                                        try check(context, plan, generation)
                                        if identity.state == "bound", identity.operationalWorkspaceReady == false {
                                            operationalIdentity = identity
                                            presentationAccount = context.account
                                            presentationDeviceFingerprint = identity.deviceFingerprint
                                            message = "Core records received. Operational workspace hosted and identity-bound for staff projection."
                                        }
                                    } catch is CancellationError {
                                        throw CancellationError()
                                    } catch {
                                        try check(context, plan, generation)
                                        // Keep hosted message; identity bind can retry later.
                                    }
                                }
                            }
                        }
                    } else {
                        message = "Core records received. Full workspace cloud data mounted for staff lease."
                    }
                    if cloud.commandRecovery.pending > 0 {
                        message += " \(cloud.commandRecovery.pending) saved field edits still need sync or review."
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch StaffReplicaDeliveryError.pending {
                    try check(context, plan, generation)
                    message = "Core records received. Full workspace data is still required before opening."
                } catch {
                    try check(context, plan, generation)
                    // Core stage remains valid; cloud lease can retry on the next pass.
                    message = "Core records received. Full workspace cloud receive needs another pass."
                }
            } else {
                message = "Core records received. Full workspace data is still required before opening."
            }
        } catch is CancellationError {
            if self.generation == generation {
                clearDisplay()
                message = "Staff sync paused. Saved work is retained."
            }
        } catch {
            if self.generation == generation {
                clearDisplay()
                message = StaffReplicaDeliveryPolicy.safe(error).localizedDescription
            }
        }
        return true
    }
}
