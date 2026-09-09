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
    var now: () -> Date = Date.init
    static var live: Self {
        .init(check: { context in
            guard !GunnAireCloudKit.usesTestDatabase, CloudKitStaffSetupStamp.current == context.stamp else { throw StaffReplicaDeliveryError.access }
        }, download: { plan, context, url in
            try await StaffReplicaDeliveryCoordinator().download(plan: plan, context: context, invitation: url, requireCurrent: true,
                validate: { _ = try StaffReplicaCoreGraph(payload: $0, plan: plan, workspace: context.workspace) })
        })
    }
}

/// Receives and validates real shared-database bytes into the encrypted stage.
/// This is not a private owner-store lease or a full operational import receipt.
@MainActor final class StaffReplicaReceiveController: ObservableObject {
    static let shared = StaffReplicaReceiveController()
    typealias Context = CloudKitStaffSetupController.Context
    let dependencies: StaffReplicaReceiveDependencies
    @Published private(set) var isRunning = false
    @Published private(set) var message = "Waiting for shared business data."
    @Published private(set) var received: StaffReplicaManifest?
    private var generation = UUID()
    init(dependencies: StaffReplicaReceiveDependencies? = nil) { self.dependencies = dependencies ?? .live }
    func clearDisplay() {
        generation = UUID(); received = nil; message = "Waiting for shared business data."
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
            received = nil; message = StaffReplicaDeliveryPolicy.safe(error).localizedDescription; return
        }
        guard !setup.needsRecovery, let context = setup.context, !context.ownerAdministrator else {
            received = nil; message = "Verify the original staff setup before receiving business data."; return
        }
        let plans = setup.plans.filter { context.owns($0) && $0.state == "accepted" && $0.businessAccessEligible && !$0.reviewRequired && !$0.cloudKitRevocationRequired }
        guard plans.count == 1, let plan = plans.first,
              let url = setup.journal?.invitationURLs[plan.id.uuidString.lowercased()] else {
            received = nil; message = "Verify one original accepted invitation before receiving business data."; return
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
            message = "Core records received. Full workspace data is still required before opening."
        } catch is CancellationError {
            if self.generation == generation { message = "Staff sync paused. Saved work is retained." }
        } catch {
            if self.generation == generation { message = StaffReplicaDeliveryPolicy.safe(error).localizedDescription }
        }
        return true
    }
}
