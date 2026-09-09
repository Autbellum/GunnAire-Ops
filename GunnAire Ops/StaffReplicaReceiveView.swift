import SwiftUI

struct StaffReplicaReceiveRecoveryModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var access = CompanyWorkspaceAccessController.shared
    @ObservedObject private var receive = StaffReplicaReceiveController.shared
    func body(content: Content) -> some View {
        content.task(id: "\(access.generation)-\(scenePhase == .active)") {
            guard scenePhase == .active, !GunnAireCloudKit.usesTestDatabase, access.authorizedContainer == nil else {
                receive.clearDisplay(); return
            }
            while !Task.isCancelled {
                await receive.refreshFromSetup()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
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
