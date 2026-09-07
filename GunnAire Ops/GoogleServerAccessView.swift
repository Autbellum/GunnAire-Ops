import SwiftUI
import SwiftData

struct GoogleServerAccessView: View {
    @StateObject private var connection: GoogleServerConnectionController
    @State private var features = Set(GoogleServerFeature.allCases)
    @State private var confirmingDisconnect = false

    init(context: ModelContext) {
        #if DEBUG
        if let fixture = GoogleServerAccessFixture.dependencies() {
            _connection = StateObject(wrappedValue: GoogleServerConnectionController(dependencies: fixture))
            return
        }
        #endif
        _connection = StateObject(wrappedValue: GoogleServerConnectionController(context: context))
    }

    var body: some View {
        Form {
                Section {
                    if let snapshot = connection.snapshot {
                        Label(status(snapshot), systemImage: snapshot.state == .active ? "checkmark.shield" : "link")
                            .accessibilityIdentifier("GoogleSharedAccessStatus")
                        if snapshot.state == .active {
                            ForEach(GoogleServerFeature.allCases) { feature in
                                LabeledContent(feature.title, value: snapshot.features.contains(feature) ? "Approved" : "Not approved")
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel(feature.title)
                                    .accessibilityValue(snapshot.features.contains(feature) ? "Approved" : "Not approved")
                                    .accessibilityIdentifier("GoogleSharedFeature-" + feature.rawValue)
                            }
                        }
                    } else if connection.busy {
                        ProgressView("Checking access…")
                    } else {
                        Text("Access has not been confirmed.").foregroundStyle(.secondary)
                    }
                    if let message = connection.message {
                        Text(message).font(.callout).accessibilityIdentifier("GoogleSharedAccessMessage")
                    }
                    Button("Check Status") { Task { await connection.refresh() } }
                        .disabled(connection.busy || !connection.available)
                        .accessibilityIdentifier("GoogleSharedAccessRefresh")
                } header: { Text("Shared access") } footer: {
                    Text("Approval prepares shared services; synchronization is not enabled yet. Your current device connection stays unchanged.")
                }
                if let pending = connection.pending {
                    Section("Unfinished request") {
                        if pending.action == .authorize {
                            if connection.canContinue {
                                Button("Continue with Google") { Task { await connection.continueApproval() } }
                                    .accessibilityIdentifier("GoogleSharedAccessContinue")
                            }
                            Button("Cancel Approval", role: .destructive) { Task { await connection.cancelApproval() } }
                                .accessibilityIdentifier("GoogleSharedAccessCancel")
                        } else {
                            Button("Retry Disconnection", role: .destructive) { confirmingDisconnect = true }
                        }
                        Text("You can return to Settings and check the same request later.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .disabled(connection.busy || !connection.available)
                } else if connection.snapshot != nil {
                    Section {
                        if connection.snapshot?.state == .active {
                            DisclosureGroup("Change Requested Access") { accessChoices }
                        } else {
                            accessChoices
                        }
                    } header: { Text("Request access") } footer: {
                        Text("Google will ask you to review access. Unchecking a feature here does not revoke access already approved in Google.")
                    }
                    .disabled(connection.busy || !connection.available)
                    if connection.snapshot?.id != nil && connection.snapshot?.state != .disconnected {
                        Section {
                            Button("Disconnect Shared Access", role: .destructive) { confirmingDisconnect = true }
                                .accessibilityIdentifier("GoogleSharedAccessDisconnect")
                        }
                        .disabled(connection.busy || !connection.available)
                    }
                }
            }
            .accessibilityIdentifier("GoogleSharedAccessForm")
            .navigationTitle("Google Access")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Disconnect shared Google access?", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
                Button("Disconnect Shared Access", role: .destructive) { Task { await connection.disconnect() } }
            } message: {
                Text("This removes this business login's saved Google credentials from the business server. Your existing device connection stays in place. It does not revoke all permissions in your Google Account.")
            }
            .task { await connection.refresh() }
            .onDisappear { connection.leave() }
    }

    private var accessChoices: some View {
        Group {
            ForEach(GoogleServerFeature.allCases) { feature in
                Toggle(feature.title, isOn: Binding(get: { features.contains(feature) }, set: { value in
                    if value { features.insert(feature) } else { features.remove(feature) }
                }))
            }
            Button(connection.snapshot?.state == .active ? "Review Access with Google" : "Approve with Google") {
                Task { await connection.authorize(features: features) }
            }
            .disabled(features.isEmpty)
            .accessibilityIdentifier("GoogleSharedAccessApprove")
        }
    }

    private func status(_ snapshot: GoogleServerSnapshot) -> String {
        switch snapshot.state {
        case .active: "Approval saved"
        case .disconnected: "Not connected for shared services"
        case .refreshing: "Checking Google access"
        case .review: "Google access needs review"
        }
    }
}

#if DEBUG
/// Isolated native-navigation fixtures never open Google or use business credentials.
enum GoogleServerAccessFixture {
    static func dependencies() -> GoogleServerConnectionDependencies? {
        guard GunnAireCloudKit.usesTestDatabase,
              let raw = ProcessInfo.processInfo.environment["GUNNAIRE_GOOGLE_ACCESS_FIXTURE"],
              let fixtureID = UUID(uuidString: raw),
              let defaults = UserDefaults(suiteName: "GoogleAccessFixture-" + fixtureID.uuidString) else { return nil }
        let scope = GoogleServerScope(companyID: fixtureID, backendOrigin: "https://backend.example.invalid", actorEmail: "fixture@example.invalid")
        let grantID = UUID(uuidString: "A1000000-0000-4000-8000-000000000090")!
        let mode = ProcessInfo.processInfo.environment["GUNNAIRE_GOOGLE_ACCESS_MODE"] ?? "pending"
        let original = GoogleServerPending(id: fixtureID, scope: scope, action: .authorize, features: [.mail, .calendar], sessionFingerprint: "fixture-session")
        if !defaults.bool(forKey: "seeded") {
            defaults.set(try? JSONEncoder().encode(original), forKey: "pending")
            defaults.set(true, forKey: "seeded")
        }
        func read() throws -> GoogleServerPending? {
            try defaults.data(forKey: "pending").map { try JSONDecoder().decode(GoogleServerPending.self, from: $0) }
        }
        return .init(scope: scope, sessionFingerprint: "fixture-session", check: {}, read: read, replace: { expected, next in
            guard try read() == expected else { throw GoogleServerConnectionError.changed }
            defaults.set(try next.map { try JSONEncoder().encode($0) }, forKey: "pending")
        }, request: { path, method, _ in
            let cancelled = defaults.bool(forKey: "cancelled")
            let completed = mode == "connected" && defaults.bool(forKey: "checked")
            let attempt = GoogleServerAttempt(id: original.id, companyID: scope.companyID, actorEmail: scope.actorEmail,
                features: original.features, state: completed ? .connected : cancelled ? .cancelled : .pending, grantID: completed ? grantID : nil)
            if path.hasPrefix("/api/google/connection?") {
                if mode == "connected" { defaults.set(true, forKey: "checked") }
                return try JSONEncoder().encode(GoogleServerSnapshot(id: completed ? grantID : nil,
                    companyID: scope.companyID, actorEmail: scope.actorEmail, state: completed ? .active : .disconnected,
                    features: completed ? [.mail] : [], pendingAttempt: completed || cancelled ? nil : attempt))
            }
            if path.hasSuffix("/cancel"), method == "POST" {
                defaults.set(true, forKey: "cancelled")
                return try JSONEncoder().encode(GoogleServerAttempt(id: original.id, companyID: scope.companyID,
                    actorEmail: scope.actorEmail, features: original.features, state: .cancelled, grantID: nil))
            }
            if method == "GET" { return try JSONEncoder().encode(attempt) }
            throw GoogleServerConnectionError.invalid
        }, browse: { _ in throw GoogleServerConnectionError.presentation }, stopBrowser: {})
    }
}
#endif
