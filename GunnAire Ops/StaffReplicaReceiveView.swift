import SwiftUI

struct StaffReplicaReceiveRecoveryModifier: ViewModifier {
    @ObservedObject private var access = CompanyWorkspaceAccessController.shared
    @ObservedObject private var receive = StaffReplicaReceiveController.shared
    func body(content: Content) -> some View {
        // This view only enables recovery for the current access mode. The
        // controller owns one worker; a disappearing window doesn't cancel it.
        content.task(id: access.generation) {
            if GunnAireCloudKit.usesTestDatabase || access.authorizedContainer != nil { receive.stopRecovery() }
            else { receive.startRecovery() }
        }
    }
}

/// Only shown during a positively identified outage, not as permanent dashboard noise.
struct StaffReplicaOfflineStatusView: View {
    @ObservedObject var receive: StaffReplicaReceiveController
    var body: some View {
        if receive.showingSavedWorkspace, receive.authorizedPresentation != nil {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Showing saved records", systemImage: "wifi.slash").font(.headline)
                    Text("Recent office changes may not be available. Drafts stay on this device until submitted.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(receive.isRunning ? "Checking…" : "Retry") { Task { await receive.refreshFromSetup() } }
                    .disabled(receive.isRunning)
                    .accessibilityIdentifier("StaffOfflineRetry")
            }
            .padding().background(.regularMaterial)
            .accessibilityIdentifier("StaffOfflineStatus")
        }
    }
}

struct StaffReplicaReceiveStatusView: View {
    @ObservedObject var receive: StaffReplicaReceiveController
    let context: CloudKitStaffSetupController.Context
    let plan: CloudKitStaffSharePlan
    let invitation: URL?
    var body: some View {
        Section("Shared business data") {
            Text(receive.message).accessibilityIdentifier("StaffReplicaReceiveStatus")
            if receive.isRunning { ProgressView("Receiving staff data…") }
            if let invitation {
                Button("Check Shared Data") { Task { await receive.refresh(context: context, plan: plan, invitation: invitation) } }
                    .disabled(receive.isRunning).accessibilityIdentifier("StaffReplicaReceiveAgain")
            } else {
                Text("Verify the original invitation below to receive its shared data.").foregroundStyle(.secondary)
            }
            Text("Receiving a snapshot does not replace saved work or open the owner's private store.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
