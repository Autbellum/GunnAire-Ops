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
    /// One verified receive-to-screen operation, including import and activation.
    var openWorkspace: ((CloudKitStaffSharePlan, Context, URL, String, String,
                        StaffWorkspaceOperationalSession?) async throws -> StaffWorkspaceOperationalSession)? = nil
    /// Independent device evidence, never taken from a saved identity journal.
    var currentDeviceFingerprint: () throws -> String = { throw StaffReplicaDeliveryError.unavailable }
    var now: () -> Date = Date.init
    static var live: Self {
        .init(check: { context in
            guard !GunnAireCloudKit.usesTestDatabase, CloudKitStaffSetupStamp.current == context.stamp else { throw StaffReplicaDeliveryError.access }
        }, download: { plan, context, url in
            try await StaffReplicaDeliveryCoordinator().download(plan: plan, context: context, invitation: url, requireCurrent: true,
                validate: { _ = try StaffReplicaCoreGraph(payload: $0, plan: plan, workspace: context.workspace) })
        }, receiveFullWorkspace: { plan, context, url in
            try await StaffWorkspaceContentCoordinator.shared.receiveAndLease(plan: plan, context: context, invitation: url)
        }, openWorkspace: { plan, context, url, selection, fingerprint, previous in
            try await StaffWorkspaceContentCoordinator.shared.openReceivedOperationalWorkspace(
                plan: plan, context: context, invitation: url, selectionID: selection,
                deviceFingerprint: fingerprint, previous: previous)
        }, currentDeviceFingerprint: {
            StaffWorkspaceOperationalIdentityStore.deviceFingerprint(
                installationID: StaffPushNotificationManager.shared.installationID)
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
    @Published private(set) var presentation: StaffReplicaPresentation?
    /// Recheck live session, expiry and device evidence when a screen requests
    /// the snapshot, not only when the last network request completed.
    var authorizedPresentation: StaffReplicaPresentation? {
        guard let presentation else { return nil }
        do {
            try check(presentation.context, presentation.plan, generation)
            try presentation.workspace.validate(plan: presentation.plan, context: presentation.context,
                selectionID: presentation.workspace.hosted.journal.selectionID,
                deviceFingerprint: dependencies.currentDeviceFingerprint())
            return presentation
        } catch { return nil }
    }
    var hostedStore: StaffWorkspaceOperationalHostedStore? { authorizedPresentation?.workspace.hosted }
    var operationalIdentity: StaffWorkspaceOperationalIdentityJournal? { authorizedPresentation?.workspace.identity }
    private var generation = UUID()
    init(dependencies: StaffReplicaReceiveDependencies? = nil) { self.dependencies = dependencies ?? .live }
    // No cleanup callbacks or actor-state changes are needed when releasing it.
    nonisolated deinit {}
    func clearDisplay() {
        generation = UUID(); received = nil; presentation = nil
        message = "Waiting for shared business data."
    }
    /// Reuse only this still-authorized, hosted session for offline local capture.
    /// Never grants the owner store or revives a previous account's cached context.
    func fieldEditingAuthority(for hosted: StaffWorkspaceOperationalHostedStore) throws -> (Context, CloudKitStaffSharePlan) {
        guard let presentation = authorizedPresentation, presentation.workspace.hosted === hosted else {
            throw StaffReplicaDeliveryError.access
        }
        if isRunning { throw StaffReplicaDeliveryError.pending }
        return (presentation.context, presentation.plan)
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
            if let current = presentation,
               current.context.stamp != context.stamp || current.context.scope != context.scope || current.plan != plan {
                presentation = nil
            }
            message = "Checking shared business data…"
            let value = try await dependencies.download(plan, context, invitation)
            try check(context, plan, generation)
            try value.validate(plan: plan, workspace: context.workspace, now: dependencies.now())
            received = value
            guard let receiveFullWorkspace = dependencies.receiveFullWorkspace else {
                presentation = nil
                message = "Shared records received. Full workspace data is still required before opening."
                return true
            }
            do {
                let cloud = try await receiveFullWorkspace(plan, context, invitation)
                try check(context, plan, generation)
                if cloud.operationalMounted && cloud.operationalAccepted {
                    guard let openWorkspace = dependencies.openWorkspace else { throw StaffReplicaDeliveryError.pending }
                    let fingerprint = try dependencies.currentDeviceFingerprint()
                    let workspace = try await openWorkspace(plan, context, invitation, cloud.selectionID,
                        fingerprint, presentation?.workspace)
                    try check(context, plan, generation)
                    guard try dependencies.currentDeviceFingerprint() == fingerprint else { throw StaffReplicaDeliveryError.access }
                    try workspace.validate(plan: plan, context: context, selectionID: cloud.selectionID,
                        deviceFingerprint: fingerprint)
                    if presentation?.workspace.hosted !== workspace.hosted
                        || presentation?.workspace.identity != workspace.identity {
                        presentation = .init(workspace: workspace, context: context, plan: plan, deviceFingerprint: fingerprint)
                    }
                    message = "Shared workspace is up to date."
                } else {
                    presentation = nil
                    message = "Shared records are saved. Full workspace verification is still required before opening."
                }
                if cloud.commandRecovery.pending > 0 {
                    message += " \(cloud.commandRecovery.pending) saved field edits still need sync or review."
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch StaffReplicaDeliveryError.pending {
                try check(context, plan, generation)
                presentation = nil
                message = "Shared records are saved. Workspace access still needs verification."
            } catch StaffReplicaDeliveryError.unavailable {
                try check(context, plan, generation)
                presentation = nil
                message = "Shared records are saved. Check your connection and try again."
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
