import SwiftUI
import SwiftData
import CoreData
import Combine

struct StaffReplicaSourceRecoveryModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var access = CompanyWorkspaceAccessController.shared
    @ObservedObject private var source = StaffReplicaSourceCoordinator.shared

    func body(content: Content) -> some View {
        content
            .task(id: "\(access.generation)-\(scenePhase == .active)") {
                guard scenePhase == .active, !GunnAireCloudKit.usesTestDatabase, access.verifiedRole == .admin else {
                    source.clearDisplay(); return
                }
                // Bounded, foreground-only recovery. Cancelling this task never
                // discards the original request; it is recovered next launch.
                while !Task.isCancelled {
                    await source.sync()
                    do { try await Task.sleep(for: .seconds(source.hasMore ? 1 : 60)) }
                    catch { return }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave).debounce(for: .milliseconds(750), scheduler: RunLoop.main)) { _ in
                resumeAfterSavedChange()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSPersistentCloudKitContainer.eventChangedNotification)) { notification in
                if let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event,
                   event.endDate != nil, event.succeeded { resumeAfterSavedChange() }
            }
    }
    private func resumeAfterSavedChange() {
        guard scenePhase == .active, !GunnAireCloudKit.usesTestDatabase, access.verifiedRole == .admin else { return }
        Task { await source.sync() }
    }
}

/// Secondary detail screen: normal mail, invoice and job navigation stays free
/// of transport/debug information. No raw JSON, tokens or account footer.
struct StaffReplicaSourceReviewView: View {
    @ObservedObject var source: StaffReplicaSourceCoordinator
    @State private var selected: StaffReplicaSourceConflict?
    var body: some View {
        List {
            Section("Saved changes") {
                Text(source.message).accessibilityIdentifier("StaffSourceStatus")
                Button("Check Again") { Task { await source.sync() } }
                    .disabled(source.isRunning)
                Text("This prepares customer, property, equipment, crew, job and catalog records. It does not confirm delivery to staff devices or change QuickBooks.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(source.conflicts) { conflict in
                Section(conflict.title) {
                    if conflict.deletion {
                        Text("This device saved a deletion. A different shared version exists.")
                    } else if conflict.remote.deleted {
                        Text("This record was removed from staff data. Sharing this device's version will restore it.")
                    } else {
                        Text("This device and the shared records have different saved versions.")
                    }
                    ForEach(changedFields(conflict), id: \.self) { field in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(label(field)).font(.subheadline.bold())
                            Text("This device: " + value(conflict.local?.fields[field], names: conflict.referenceNames)).textSelection(.enabled)
                            Text("Shared: " + value(conflict.remote.fields[field], names: conflict.referenceNames)).foregroundStyle(.secondary).textSelection(.enabled)
                        }.accessibilityElement(children: .combine)
                    }
                    Button(conflict.deletion ? "Review Saved Deletion" : "Review This Device's Version") { selected = conflict }
                        .disabled(source.isRunning)
                }
            }
        }
        .navigationTitle("Staff Data Preparation")
        .task { await source.sync() }
        .alert("Update shared staff records?", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let selected {
                Button(selected.deletion ? "Share Saved Deletion" : "Share This Device's Saved Version", role: selected.deletion ? .destructive : nil) {
                    let decision = selected; self.selected = nil
                    Task { await source.approve(decision) }
                }
                Button("Cancel", role: .cancel) { self.selected = nil }
            }
        } message: {
            Text("Share only the version you reviewed. Newer edits require review again. This does not change your company iCloud store or QuickBooks.")
        }
    }
    private func changedFields(_ conflict: StaffReplicaSourceConflict) -> [String] {
        Set(conflict.local?.fields.keys.map { $0 } ?? []).union(conflict.remote.fields.keys)
            .filter { conflict.local?.fields[$0] != conflict.remote.fields[$0] }.sorted()
    }
    private func label(_ field: String) -> String {
        field.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
    }
    private func value(_ scalar: StaffReplicaScalar?, names: [String: String]) -> String {
        switch scalar {
        case .text(let text): text.isEmpty ? "Not set" : (names[text] ?? text)
        case .number(let number): number.formatted()
        case .flag(let flag): flag ? "Yes" : "No"
        case .identifiers(let values): values.isEmpty ? "None" : values.map { id in names[id].map { name in name + " (" + id.suffix(6) + ")" } ?? id }.joined(separator: ", ")
        case nil: "Not present"
        }
    }
}

struct StaffReplicaSourceSettingsRow: View {
    @ObservedObject private var access = CompanyWorkspaceAccessController.shared
    @StateObject private var source: StaffReplicaSourceCoordinator
    init() {
        let fixture = StaffReplicaSourceUIFixture.dependencies
        _source = StateObject(wrappedValue: fixture.map { StaffReplicaSourceCoordinator(dependencies: $0) } ?? .shared)
    }
    var body: some View {
        if access.verifiedRole == .admin || StaffReplicaSourceUIFixture.isEnabled {
            NavigationLink {
                StaffReplicaSourceReviewView(source: source)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Staff Data Preparation", systemImage: "icloud.and.arrow.up")
                    Text(source.message).font(.caption).foregroundStyle(.secondary)
                }
            }.accessibilityIdentifier("OpenStaffSourceReview")
        }
    }
}
