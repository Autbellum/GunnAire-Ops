import SwiftUI
import SwiftData
import UIKit

struct JobBillingAccessRow: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var dispatch: JobBillingDispatch = .shared
    let call: ServiceCall

    private var status: String {
        do {
            guard let record = try dispatch.record(jobID: call.id, context: modelContext) else { return "Review job access" }
            if let pending = record.pending { return pending.state == .review ? "Needs review" : "Pending sync" }
            if record.confirmed?.assignment?.usable == true { return "Last confirmed: enabled" }
            return "Last confirmed: off"
        } catch { return "Review connection" }
    }

    var body: some View {
        NavigationLink {
            JobBillingAccessView(dispatch: dispatch, call: call, context: modelContext)
        } label: {
            HStack {
                Label("Field billing", systemImage: "person.badge.shield.checkmark")
                Spacer()
                Text(status).font(.subheadline).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        }
        .accessibilityIdentifier("JobBillingAccessLink")
    }
}

struct JobBillingAccessView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var technicians: [Technician]
    @ObservedObject var dispatch: JobBillingDispatch = .shared
    let call: ServiceCall
    @State private var review: JobBillingDispatch.Review?
    @State private var message: String?
    @State private var busy = false
    @State private var confirmsSavedCrew = false

    init(dispatch: JobBillingDispatch? = nil, call: ServiceCall, context: ModelContext) {
        self.call = call
        #if DEBUG
        if GunnAireCloudKit.usesTestDatabase,
           ProcessInfo.processInfo.arguments.contains("-uiTestJobBillingReview"),
           let fixture = try? JobBillingDispatch.reviewFixture(call: call, context: context) {
            self.dispatch = fixture
            return
        }
        #endif
        self.dispatch = dispatch ?? .shared
    }

    private func names(_ emails: [String]) -> String {
        let names = emails.map { email in
            let matches = technicians.filter { AppAccess.normalizedEmail($0.contactInfo) == email }
            return matches.count == 1 ? matches[0].name : "Unlinked crew account"
        }
        return names.isEmpty ? "Off" : names.joined(separator: ", ")
    }

    var body: some View {
        Form {
            Section {
                Text(call.customer.name).font(.headline)
                Text("\(call.type.displayName) · \(call.scheduledDate.formatted(date: .abbreviated, time: .omitted))")
                    .foregroundStyle(.secondary)
            }
            if let review {
                Section("Job access") {
                    LabeledContent("Saved crew", value: names(review.target.technicianEmails))
                        .accessibilityIdentifier("JobBillingSavedCrew")
                    LabeledContent("Server access", value: review.snapshot.assignment?.usable == true
                                   ? names(review.snapshot.assignment?.technicianEmails ?? []) : "Off")
                        .accessibilityIdentifier("JobBillingServerCrew")
                    if review.record.pending != nil {
                        Label(review.record.pending?.state == .review ? "Review the saved assignment" : "Saved on this device", systemImage: "arrow.triangle.2.circlepath")
                            .accessibilityIdentifier("JobBillingPendingStatus")
                        Text("Other devices keep the last confirmed access until this change syncs. A newer dispatcher decision is never replaced automatically.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if review.target.matches(review.snapshot.assignment) {
                        Label("Access confirmed", systemImage: "checkmark.shield")
                            .accessibilityIdentifier("JobBillingConfirmedStatus")
                    }
                    if review.target.needsCrewAccounts {
                        Text("One or more crew members need an active business account linked to their technician record. Field billing stays off until those accounts are ready.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if !review.target.matches(review.snapshot.assignment) {
                        Button(review.target.enabled ? "Apply Saved Crew" : "Turn Field Billing Off") { confirmsSavedCrew = true }
                            .disabled(busy)
                            .accessibilityIdentifier("JobBillingApplySavedCrew")
                    }
                }
            }
            if let message {
                Section { Text(message).foregroundStyle(.secondary).accessibilityIdentifier("JobBillingReviewMessage") }
            }
            Section {
                Button { Task { await load() } } label: {
                    if busy { ProgressView("Checking job access…") }
                    else { Label("Refresh Access", systemImage: "arrow.clockwise") }
                }
                .disabled(busy)
                .accessibilityIdentifier("JobBillingRefresh")
            } footer: {
                Text("This controls the crew's access for this job only. It does not create an invoice, charge a customer, or send a message.")
            }
        }
        .navigationTitle("Field Billing")
        .accessibilityIdentifier("JobBillingAccessReview")
        .task { await load() }
        .alert("Apply this job's saved access?", isPresented: $confirmsSavedCrew) {
            Button("Cancel", role: .cancel) { }
            Button("Apply Saved Access") { Task { await apply() } }
                .accessibilityIdentifier("JobBillingConfirmSavedCrew")
        } message: {
            Text("This replaces the server access shown here with the saved crew's access. If another dispatcher changes it first, you will be asked to review again.")
        }
    }

    private func load() async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do { review = try await dispatch.refresh(call, context: modelContext) }
        catch { message = safeMessage(error) }
    }

    private func apply() async {
        guard !busy, let reviewed = review else { return }
        busy = true; message = nil
        defer { busy = false }
        do { review = try await dispatch.applySavedCrew(call, context: modelContext, reviewed: reviewed) }
        catch { message = safeMessage(error) }
    }

    private func safeMessage(_ error: Error) -> String {
        if let error = error as? JobBillingDispatchError { return error.localizedDescription }
        if error as? BillingPublicationError == .reviewRequired {
            return "Job access changed. Refresh to review the current decision before applying your saved crew."
        }
        if error as? BillingPublicationError == .accessRequired {
            return "Confirm your dispatcher or administrator sign-in for this business. Saved work stays on this device."
        }
        return "Job access could not be confirmed. Saved work is retained. Reconnect, then refresh this job before making another access change."
    }
}

#if DEBUG
extension JobBillingDispatch {
    /// Fixture-only navigation tests use the real journal/client/coordinator,
    /// with in-memory persistence and a strict CAS server double. No Keychain,
    /// CloudKit or external account is used.
    static func reviewFixture(call: ServiceCall, context: ModelContext) throws -> JobBillingDispatch {
        let (revision, target) = try JobBillingTarget.capture(call, context: context)
        let company = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        let scope = JobBillingQueueScope(companyID: company, realmID: "job-access-ui-fixture",
                                        environment: Config.QuickBooks.environment, actorEmail: AppAccess.normalizedEmail(AppIdentity.currentEmail))
        let epoch = String(repeating: "a", count: 64)
        let recovering = ProcessInfo.processInfo.arguments.contains("-uiTestJobBillingRecovered")
        func assignment(_ version: Int, enabled: Bool) -> JobBillingAssignment {
            .init(companyID: company, realmID: scope.realmID, environment: scope.environment, serviceCallID: call.id,
                  localCustomerID: call.customer.id, revision: version, technicianEmails: enabled ? target.technicianEmails : [],
                  enabled: enabled, usable: enabled, updatedAt: "2026-09-07T00:00:00Z")
        }
        var remote = assignment(recovering ? 1 : 2, enabled: recovering && target.enabled)
        var queue = JobBillingQueue(scope: scope, records: [.init(id: call.id, pending: .init(
            id: UUID(), original: nil, desired: target, localRevision: revision,
            baseline: .init(assignment: nil, connectionRevision: epoch), state: recovering ? .queued : .review,
            supersededRequests: []))])
        var sent = false
        let api = QuickBooksDataAPI(testTokens: .init(accessToken: "fixture", expiration: .distantFuture),
            realmID: scope.realmID, environment: scope.environment, catalogCompanyID: company,
            transport: { _ in throw JobBillingDispatchError.connection })
        return .init(store: .init(read: { expected in
            guard expected == scope else { throw JobBillingDispatchError.access }
            return queue
        }, write: { queue = $0 }), api: api, client: .init { path, method, body in
            guard path.hasPrefix("/api/job-billing-assignments") else { throw JobBillingDispatchError.connection }
            if method == "POST" {
                guard !recovering, !sent, let body else { throw BillingPublicationError.invalidProposal }
                let request = try JSONDecoder().decode(JobBillingAssignmentRequest.self, from: body)
                guard request.expectedRevision == remote.revision, request.connectionRevision == epoch,
                      request.technicianEmails == target.technicianEmails, request.scope == scope.job(call.id) else {
                    throw BillingPublicationError.reviewRequired
                }
                sent = true
                remote = assignment(remote.revision + 1, enabled: request.enabled)
            }
            return try JSONEncoder().encode(JobBillingAssignmentSnapshot(assignment: remote, connectionRevision: epoch))
        }, actor: { scope.actorEmail }, validateAccess: { context, email in
            try GoogleCalendarWorkflow.requireDispatchAccess(context: context, email: email)
        }, fixture: true)
    }
}
#endif

/// Runs only inside the authorized CloudKit workspace. No timer, credentials in
/// UI state, cross-account queue replay, or private queue data in screenshots.
struct JobBillingRecoveryModifier: ViewModifier {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var api = QuickBooksDataAPI.shared

    func body(content: Content) -> some View {
        content
            .task(id: api.realmID) { await JobBillingDispatch.shared.resume(context: modelContext) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await JobBillingDispatch.shared.resume(context: modelContext) } }
            }
    }
}
