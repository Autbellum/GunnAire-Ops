import SwiftUI
import UIKit

struct CloudKitStaffSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: CloudKitStaffSetupController
    @ObservedObject private var inbox = CloudKitStaffInvitationInbox.shared
    @State private var confirmsAccount = false
    private let embedded: Bool

    init(embedded: Bool = false, dependencies: CloudKitStaffSetupDependencies? = nil) {
        self.embedded = embedded
        _model = StateObject(wrappedValue: CloudKitStaffSetupController(dependencies: dependencies ?? CloudKitStaffSetupUIFixture.dependencies))
    }

    var body: some View {
        navigation
            .accessibilityIdentifier("StaffCloudKitSetup")
            .task {
                await model.refresh()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                    model.checkLifetime()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                model.checkLifetime()
                Task { await model.refresh() }
            }
    }

    @ViewBuilder private var navigation: some View {
        if embedded { content }
        else { NavigationStack { content } }
    }

    private var content: some View {
            Form {
                Section {
                    Label("Staff iCloud access", systemImage: "person.icloud")
                        .font(.headline)
                    Text("Use your own iCloud account with your approved business login. This setup does not move or replace saved work.")
                        .foregroundStyle(.secondary)
                }
                if let error = model.error ?? inbox.error {
                    Section("Needs attention") {
                        Text(error.localizedDescription).accessibilityIdentifier("StaffCloudKitSetupError")
                        Button("Check Again") { Task { await model.refresh() } }
                            .disabled(model.busy)
                    }
                }
                if model.busy { ProgressView("Checking original access…") }
                if model.needsRecovery {
                    Section("Original setup retained") {
                        Text("A previous action needs confirmation. Recover that same request before starting another. No invitation or saved work has been discarded.")
                        Button("Recover Original Setup") { Task { await model.recover() } }
                            .disabled(model.busy).accessibilityIdentifier("StaffCloudKitRecoverOriginal")
                    }
                }
                if let context = model.context {
                    if context.ownerAdministrator {
                        Section {
                            Text("Review each person's business role before creating their private invitation. Administrator actions require a sign-in within the last 10 minutes.")
                        }
                    } else if model.canEnroll {
                        Section {
                            Toggle("Use the iCloud account signed in on this device", isOn: $confirmsAccount)
                                .accessibilityIdentifier("StaffCloudKitAccountConfirmation")
                            Button("Request Staff Access") { Task { await model.enroll(confirmed: confirmsAccount) } }
                                .disabled(!confirmsAccount || model.busy)
                                .accessibilityIdentifier("StaffCloudKitRequestAccess")
                        } header: { Text("Request access") } footer: {
                            Text("Your administrator receives the iCloud account reference needed to invite you. Your Apple password is never shared.")
                        }
                    }
                    if let invitation = inbox.pending {
                        Section("Opened invitation") {
                            if model.visiblePlans.contains(where: { invitation.matches($0) }) {
                                Text("Open your matching staff request below to review this invitation.")
                            } else {
                                Text("This link does not match a sharing request available to this business login. No invitation was accepted. Sign in with the invited business account or ask your administrator to review it.")
                            }
                            Button("Dismiss Opened Link") { inbox.dismissOriginal(invitation.id) }
                            Text("Dismissing a link does not revoke sharing or erase saved setup.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Section(context.ownerAdministrator ? "Team requests" : "Your requests") {
                        if model.visiblePlans.isEmpty {
                            Text(context.ownerAdministrator ? "No staff requests yet. Team members request access from their own device." : "No staff access has been requested.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.visiblePlans, id: \.id) { plan in
                            NavigationLink {
                                CloudKitStaffRequestView(model: model, id: plan.id, incoming: inbox.pending)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(context.ownerAdministrator ? plan.memberEmail : "Staff workspace")
                                    Text("\(plan.memberRole) · \(plan.setupStatus)").font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityIdentifier("StaffCloudKitRequest-\(plan.id.uuidString.lowercased())")
                        }
                    }
                }
            }
            .navigationTitle("Staff iCloud")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !embedded { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            }
            .refreshable { await model.refresh() }
    }
}

private struct CloudKitStaffRequestView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var model: CloudKitStaffSetupController
    @StateObject private var receive: StaffReplicaReceiveController
    let id: UUID
    let incoming: CloudKitStaffInvitation?
    @State private var confirmsReview = false
    @State private var invitationText = ""
    @State private var removal: String?

    init(model: CloudKitStaffSetupController, id: UUID, incoming: CloudKitStaffInvitation?) {
        self.model = model; self.id = id; self.incoming = incoming
        _receive = StateObject(wrappedValue: StaffReplicaReceiveUIFixture.dependencies.map { StaffReplicaReceiveController(dependencies: $0) } ?? .shared)
    }

    private var plan: CloudKitStaffSharePlan? { model.visiblePlans.first { $0.id == id } }
    private var originalURL: URL? {
        guard let plan else { return nil }
        if let value = model.journal?.invitationURLs[id.uuidString.lowercased()] { return value }
        return incoming.flatMap { $0.matches(plan) ? $0.url : nil }
    }
    private var enteredURL: URL? {
        let text = invitationText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return originalURL }
        guard let url = URL(string: text), CloudKitStaffSetupPolicy.invitationURL(url) else { return nil }
        return url
    }
    private var receiveIdentity: StaffReplicaReceiveIdentity? {
        guard let context = model.context, let plan, context.owns(plan), plan.state == "accepted",
              !model.needsRecovery, !GunnAireCloudKit.usesTestDatabase || StaffReplicaReceiveUIFixture.isEnabled else { return nil }
        return .init(stamp: context.stamp, plan: plan, invitation: originalURL, isActive: scenePhase == .active)
    }

    var body: some View {
        Form {
            if let plan, let context = model.context {
                Section {
                    Text(context.ownerAdministrator ? plan.memberEmail : "Your staff workspace").font(.headline)
                    LabeledContent("Business role", value: plan.memberRole)
                    LabeledContent("Status", value: plan.setupStatus)
                }
                if let error = model.error {
                    Section("Needs attention") { Text(error.localizedDescription).accessibilityIdentifier("StaffCloudKitSetupError") }
                }
                if model.busy { ProgressView("Checking original access…") }
                if model.needsRecovery {
                    Section("Original setup retained") {
                        Text("Recover the original action before making another change. If access has changed, ask the administrator to revoke the original request, then check again.")
                        Button("Recover Original Setup") { Task { await model.recover() } }
                            .disabled(model.busy).accessibilityIdentifier("StaffCloudKitRecoverOriginal")
                    }
                } else if plan.reviewRequired || plan.participantIdentityAvailable != true {
                    Section("Review required") {
                        Text(plan.participantIdentityAvailable != true
                             ? "This older request does not include an invitation account reference. Withdraw it, then request access again from the invited iCloud account."
                             : "Business access changed after this request. Revoke this request and review a new invitation before sharing again.")
                    }
                } else if plan.state == "accepted" {
                    if context.owns(plan) {
                        StaffReplicaReceiveStatusView(receive: receive, context: context, plan: plan, invitation: originalURL)
                    } else {
                        Section("Invitation accepted") {
                            Text("The invitation is accepted. The staff device still needs complete, verified workspace data before opening.")
                                .accessibilityIdentifier("StaffCloudKitAcceptedPendingSync")
                        }
                    }
                }
                if !model.needsRecovery {
                    if context.ownerAdministrator && !plan.reviewRequired && !plan.cloudKitRevocationRequired && plan.participantIdentityAvailable == true {
                        ownerActions(plan)
                    } else if context.owns(plan) && ["invited", "accepted"].contains(plan.state) && !plan.reviewRequired && !plan.cloudKitRevocationRequired {
                        Section {
                            if originalURL == nil {
                                TextField("Paste the iCloud invitation link", text: $invitationText)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                                    .accessibilityIdentifier("StaffCloudKitInvitationLink")
                            } else { Label("Original invitation available", systemImage: "link") }
                            Toggle("Accept for my current business and iCloud account", isOn: $confirmsReview)
                                .accessibilityIdentifier("StaffCloudKitReviewConfirmation")
                            Button(plan.state == "accepted" ? "Verify Original Invitation" : "Accept Original Invitation") {
                                if let url = enteredURL { Task { await model.accept(id, url: url, confirmed: confirmsReview) } }
                            }
                            .disabled(!confirmsReview || enteredURL == nil || model.busy)
                            .accessibilityIdentifier("StaffCloudKitAcceptInvitation")
                        } header: { Text("Accept invitation") } footer: { Text("Apple's account, owner and sharing permissions are checked before acceptance. An unrelated link cannot open a different workspace.") }
                    }
                    if plan.state != "revoked" && (context.ownerAdministrator || plan.memberEmail == context.member.email) {
                        Section {
                            Button(plan.state == "requested" ? "Withdraw Request" : "Revoke Business Access", role: .destructive) { removal = "revoke" }
                                .disabled(model.busy).accessibilityIdentifier("StaffCloudKitRevokeAccess")
                        }
                    }
                    if plan.state == "revoked" && plan.cloudKitRevocationRequired {
                        Section("iCloud removal still needed") {
                            Text("Business access is revoked. Apple sharing access remains separate until the owner removes this original invitation. Previously downloaded copies cannot be remotely erased.")
                            if context.ownerAdministrator {
                                Button("Remove Original iCloud Access", role: .destructive) { removal = "cleanup" }
                                    .disabled(model.busy).accessibilityIdentifier("StaffCloudKitRemoveAppleAccess")
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Access needs review", systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("Return to staff setup and verify the current business login. Saved setup has not been deleted."))
            }
        }
        .task(id: receiveIdentity) {
            guard receiveIdentity?.isActive == true, let context = model.context,
                  let plan, let url = originalURL else { return }
            receive.clearDisplay()
            while !Task.isCancelled {
                let ran = await receive.refresh(context: context, plan: plan, invitation: url)
                do { try await Task.sleep(for: .seconds(ran ? 60 : 1)) } catch { return }
            }
        }
        .navigationTitle("Staff request").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(removal == "cleanup" ? "Remove this person's original iCloud sharing access?" : "Revoke this original business request?",
            isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
                if removal == "cleanup" {
                    Button("Remove iCloud Access", role: .destructive) { Task { await model.cleanup(id, confirmed: true) }; removal = nil }
                } else {
                    Button("Revoke Business Access", role: .destructive) { Task { await model.revoke(id, confirmed: true) }; removal = nil }
                }
                Button("Cancel", role: .cancel) { removal = nil }
            } message: {
                Text(removal == "cleanup" ? "Only this invitation is removed. The company workspace and its work records are retained." : "Apple sharing removal is a separate owner action. Existing work is retained.")
            }
    }

    @ViewBuilder private func ownerActions(_ plan: CloudKitStaffSharePlan) -> some View {
        if ["requested", "approved"].contains(plan.state) {
            Section("Administrator review") {
                Text("This private invitation is restricted to the requested iCloud account. Shared records are read-only; the app's business role controls which work can be included.")
                Toggle("I reviewed this person and their business role", isOn: $confirmsReview)
                    .accessibilityIdentifier("StaffCloudKitReviewConfirmation")
                Button(plan.state == "requested" ? "Approve Staff Request" : "Create Private Invitation") {
                    Task {
                        if plan.state == "requested" { await model.approve(id, confirmed: confirmsReview) }
                        else { await model.invite(id, confirmed: confirmsReview) }
                        confirmsReview = false
                    }
                }
                .disabled(!confirmsReview || model.busy).accessibilityIdentifier("StaffCloudKitApproveOrInvite")
            }
        }
        if ["invited", "accepted"].contains(plan.state) {
            Section("Original invitation") {
                if let url = originalURL {
                    ShareLink("Share Original Invitation", item: url).accessibilityIdentifier("StaffCloudKitShareOriginalInvitation")
                } else {
                    Button("Recover Original Invitation Link") { Task { await model.invite(id, confirmed: true) } }
                        .disabled(model.busy).accessibilityIdentifier("StaffCloudKitRecoverInvitationLink")
                }
            }
        }
    }
}

extension CloudKitStaffSharePlan {
    var setupStatus: String {
        if state == "revoked" { return cloudKitRevocationRequired ? "Revoked · iCloud removal needed" : "Revoked" }
        if reviewRequired { return "Administrator review needed" }
        switch state {
        case "requested": return "Awaiting administrator"
        case "approved": return "Ready for invitation"
        case "invited": return "Invitation available"
        case "accepted": return "Invitation accepted"
        default: return "Needs review"
        }
    }
}
