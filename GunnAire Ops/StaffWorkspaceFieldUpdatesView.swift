import SwiftUI
import Combine

struct StaffWorkspaceFieldUpdatesDependencies {
    let setup: () async throws -> (CloudKitStaffSetupController.Context, [CloudKitStaffSharePlan])
    let fetch: (CloudKitStaffSharePlan, CloudKitStaffSetupController.Context, String?) async throws -> StaffWorkspaceFieldUpdatesPage
    var stamp: () -> CloudKitStaffSetupStamp? = { CloudKitStaffSetupStamp.current }
    var now: () -> Date = Date.init
    static var live: Self {
        .init(setup: StaffWorkspaceContentDependencies.live.setup, fetch: { plan, context, after in
            try await StaffWorkspaceContentCoordinator(dependencies: .live).readFieldUpdates(plan: plan, context: context, after: after)
        })
    }
}

@MainActor final class StaffWorkspaceFieldUpdatesController: ObservableObject {
    @Published private(set) var entries: [StaffWorkspaceFieldUpdate] = []
    @Published private(set) var message = "Check submitted updates to see the office outcome."
    @Published private(set) var isRunning = false
    @Published private(set) var checkedAt: Date?
    @Published private(set) var nextCursor = ""
    private let dependencies: StaffWorkspaceFieldUpdatesDependencies
    private var generation = UUID()
    private var displayStamp: CloudKitStaffSetupStamp?
    init(dependencies: StaffWorkspaceFieldUpdatesDependencies? = nil) { self.dependencies = dependencies ?? .live }
    // This UI controller has no actor-bound teardown work.
    nonisolated deinit {}

    func clear() {
        generation = UUID(); entries = []; nextCursor = ""; checkedAt = nil; displayStamp = nil; isRunning = false
        message = "Check submitted updates to see the office outcome."
    }
    func checkLifetime() {
        if let displayStamp, dependencies.stamp() != displayStamp || dependencies.now() >= displayStamp.session.expiresAt {
            clear()
            message = "Sign in and verify staff access to check updates."
        }
    }
    func load(scope: CloudKitStaffSetupScope, planID: UUID, more: Bool = false) async {
        guard !isRunning else { return }
        let after = more ? nextCursor : ""
        if more && after.isEmpty { return }
        clear()
        let run = generation
        isRunning = true
        defer { if generation == run { isRunning = false } }
        do {
            guard let stamp = dependencies.stamp(), dependencies.now() < stamp.session.expiresAt else { throw StaffReplicaDeliveryError.access }
            displayStamp = stamp
            let (context, plans) = try await dependencies.setup()
            try Task.checkCancellation()
            guard generation == run, dependencies.stamp() == stamp, context.stamp == stamp, context.scope == scope,
                  let plan = plans.first(where: { $0.id == planID }), context.owns(plan), !context.ownerAdministrator,
                  context.member.isActive, context.member.role == plan.memberRole,
                  context.member.email == stamp.session.email, context.account.environment == plan.environment,
                  dependencies.now() < stamp.session.expiresAt,
                  [AppUserRole.admin.rawValue, AppUserRole.dispatcher.rawValue, AppUserRole.fieldTechnician.rawValue].contains(context.member.role),
                  plan.state == "accepted", plan.businessAccessEligible, !plan.reviewRequired, !plan.cloudKitRevocationRequired else {
                throw StaffReplicaDeliveryError.access
            }
            try plan.validate(workspace: context.workspace, now: dependencies.now())
            let page = try await dependencies.fetch(plan, context, after.isEmpty ? nil : after)
            try Task.checkCancellation()
            guard generation == run, dependencies.stamp() == stamp, dependencies.now() < stamp.session.expiresAt else {
                throw StaffReplicaDeliveryError.access
            }
            try page.validate(scope: scope, plan: plan, after: after.isEmpty ? nil : after)
            entries = page.entries; nextCursor = page.nextCursor; checkedAt = dependencies.now()
            message = entries.isEmpty ? "No submitted updates on this page." : "Office outcomes checked."
        } catch {
            guard generation == run else { return }
            entries = []; nextCursor = ""; checkedAt = nil; displayStamp = nil
            message = "Updates could not be verified. Your original submissions are retained. Check your connection and staff access, then try again."
        }
    }
}

/// Secondary, staff-only status view. Values expand on demand; no raw transport
/// data, account footer, owner comparison or accounting completion claims.
struct StaffWorkspaceFieldUpdatesView: View {
    let hosted: StaffWorkspaceOperationalHostedStore
    @StateObject private var updates = StaffWorkspaceFieldUpdatesController()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(updates.message).foregroundStyle(.secondary)
                    if let checked = updates.checkedAt {
                        Text("Last checked \(checked.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                    if updates.isRunning { ProgressView("Checking updates…") }
                }
                ForEach(updates.entries) { entry in
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title(entry)).font(.headline)
                            Text(StaffWorkspacePublicationReview.label(entry.request.fieldName)).font(.subheadline)
                            Text(entry.status).font(.subheadline).foregroundStyle(.secondary)
                            if let recorded = StaffOwnerFieldEditApplication.instant(entry.receipt.createdAt) {
                                Text("Submitted \(recorded.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                            }
                            DisclosureGroup("Your submitted value") {
                                Text(StaffWorkspacePublicationReview.value(entry.request.value, field: entry.request.fieldName))
                                    .textSelection(.enabled)
                            }
                        }.padding(.vertical, 4)
                    }
                }
                if !updates.nextCursor.isEmpty {
                    Button("Next Updates") { Task { await load(more: true) } }.disabled(updates.isRunning)
                }
                Section {
                    Text("These are historical office decisions. Later office changes may differ. QuickBooks and iCloud delivery are tracked separately.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Submitted Updates")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(updates.isRunning)
                }
            }
            .refreshable { await load() }
        }
        .task { await load() }
        .onReceive(timer) { _ in updates.checkLifetime() }
        .onChange(of: CloudKitStaffSetupStamp.current) { _, _ in updates.checkLifetime() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await load() } } else { updates.clear() }
        }
        .onDisappear { updates.clear() }
        .accessibilityIdentifier("StaffSubmittedUpdates")
    }
    private func load(more: Bool = false) async {
        await updates.load(scope: hosted.journal.scope, planID: hosted.journal.planID, more: more)
    }
    private func title(_ entry: StaffWorkspaceFieldUpdate) -> String {
        guard let row = try? hosted.fetch(kind: entry.request.recordKind, id: entry.request.recordID).first,
              case .operational(let partition) = row.body,
              let available = try? StaffWorkspacePublicationContract.encode(partition.fields),
              let unavailable = try? StaffWorkspacePublicationContract.encode(partition.unavailableFields) else {
            return StaffWorkspacePublicationReview.label(entry.request.recordKind)
        }
        return StaffWorkspaceOperationalDetail.summary(kind: row.kind, recordID: row.id,
            availableFieldsJSON: String(decoding: available, as: UTF8.self),
            unavailableFieldsJSON: String(decoding: unavailable, as: UTF8.self)).title
    }
}
