import SwiftUI
import SwiftData

struct TechnicianTimeOffWorkspaceSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TechnicianTimeOffWorkspaceView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

struct TechnicianTimeOffRequestRow: View {
    let request: TechnicianTimeOffRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(request.technicianNameSnapshot)
                    .font(.headline)
                Spacer()
                Text(request.status.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
            }
            Text("\(request.startsAt.formatted(date: .abbreviated, time: .shortened)) – \(request.endsAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.subheadline)
            if request.status == .pending {
                Text("Submitted \(request.createdAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        switch request.status {
        case .pending: .orange
        case .approved: .green
        case .declined, .cancelled: .red
        case .withdrawn: .secondary
        }
    }
}

struct TechnicianTimeOffWorkspaceView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TechnicianTimeOffRequest.createdAt, order: .reverse) private var requests: [TechnicianTimeOffRequest]
    @Query(sort: \Technician.name, order: .forward) private var technicians: [Technician]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]

    @State private var selectedRequest: TechnicianTimeOffRequest?
    @State private var showingNewRequest = false

    private var currentEmail: String { AppAccess.normalizedEmail(AppIdentity.currentEmail) }
    private var canReview: Bool { AppAccess.canReviewTimeOffRequests(email: currentEmail, users: users) }
    private var technicianID: UUID? {
        AppAccess.timeOffRequestTechnicianID(email: currentEmail, users: users, technicians: technicians)
    }
    private var canSubmit: Bool { technicianID != nil }
    private var visibleRequests: [TechnicianTimeOffRequest] {
        let scoped = canReview ? requests : requests.filter {
            $0.technicianID == technicianID && $0.requestedByEmail == currentEmail
        }
        return TechnicianTimeOffPolicy.ordered(scoped)
    }
    private var pendingRequests: [TechnicianTimeOffRequest] { visibleRequests.filter { $0.status == .pending } }
    private var completedRequests: [TechnicianTimeOffRequest] { visibleRequests.filter { $0.status != .pending } }

    var body: some View {
        Group {
            if canReview || canSubmit {
                List {
                    Section(canReview ? "Needs Office Review" : "Pending") {
                        if pendingRequests.isEmpty {
                            Text(canReview ? "No time-off requests need review." : "You have no pending time-off requests.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(pendingRequests) { request in
                                Button { selectedRequest = request } label: {
                                    TechnicianTimeOffRequestRow(request: request)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("TimeOffRequest-\(request.id.uuidString)")
                            }
                        }
                    }

                    Section("History") {
                        if completedRequests.isEmpty {
                            Text("Reviewed, withdrawn, and cancelled requests will remain here as history.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(completedRequests) { request in
                                Button { selectedRequest = request } label: {
                                    TechnicianTimeOffRequestRow(request: request)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("TimeOffRequestHistory-\(request.id.uuidString)")
                            }
                        }
                    }

                    Section {
                        Text(canReview
                             ? "Approval creates a generic Time off block on the dispatch board. Private employee and review notes stay inside this restricted workspace. Assigned jobs are never moved automatically."
                             : "Your reason is visible only to Dispatch and Admin reviewers. Approved time appears on the schedule only as Time off.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                ContentUnavailableView(
                    "Time Off Unavailable",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("A Field Technician account must match exactly one technician email. Dispatch and Admin accounts can review requests from Schedule.")
                )
            }
        }
        .navigationTitle(canReview ? "Time-Off Review" : "My Time Off")
        .toolbar {
            if canSubmit {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingNewRequest = true } label: {
                        Label("Request Time Off", systemImage: "plus")
                    }
                    .accessibilityIdentifier("RequestTimeOff")
                }
            }
        }
        .sheet(isPresented: $showingNewRequest) {
            if let technicianID,
               let technician = technicians.first(where: { $0.id == technicianID }) {
                NewTechnicianTimeOffRequestView(technician: technician)
                    .tint(Color.brandGold)
            }
        }
        .sheet(item: $selectedRequest) { request in
            TechnicianTimeOffRequestDetailView(request: request)
                .tint(Color.brandGold)
        }
        .onChange(of: canSubmit) { _, allowed in
            if !allowed { showingNewRequest = false }
        }
    }
}

private struct NewTechnicianTimeOffRequestView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @Query(sort: \Technician.name, order: .forward) private var technicians: [Technician]

    let technician: Technician
    @State private var startsAt = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var endsAt = Calendar.current.date(byAdding: .hour, value: 8, to: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()) ?? Date()
    @State private var privateReason = ""
    @State private var errorMessage: String?

    private var currentEmail: String { AppAccess.normalizedEmail(AppIdentity.currentEmail) }
    private var remainsAuthorized: Bool {
        AppAccess.timeOffRequestTechnicianID(email: currentEmail, users: users, technicians: technicians) == technician.id
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Request") {
                    LabeledContent("Technician", value: technician.name)
                    DatePicker("Starts", selection: $startsAt)
                    DatePicker("Ends", selection: $endsAt, in: startsAt...)
                    TextField("Private reason (optional)", text: $privateReason, axis: .vertical)
                        .lineLimit(2...5)
                        .accessibilityIdentifier("TimeOffPrivateReason")
                }
                Section {
                    Text("Submitting does not change the dispatch schedule. Dispatch or Admin must review it, and approval is blocked while assigned jobs overlap.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!remainsAuthorized)
            .navigationTitle("Request Time Off")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit", action: submit)
                        .disabled(!remainsAuthorized || endsAt <= startsAt)
                        .accessibilityIdentifier("SubmitTimeOffRequest")
                }
            }
            .alert("Request Not Saved", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "") }
            .onChange(of: remainsAuthorized) { _, allowed in if !allowed { dismiss() } }
        }
    }

    private func submit() {
        guard remainsAuthorized else { return }
        do {
            let created = try TechnicianTimeOffPolicy.makeRequest(
                technicianID: technician.id,
                technicianName: technician.name,
                actorEmail: currentEmail,
                startsAt: startsAt,
                endsAt: endsAt,
                privateReason: privateReason
            )
            modelContext.insert(created.request)
            modelContext.insert(created.event)
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }
}

private struct TechnicianTimeOffRequestDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TechnicianAvailabilityEvent.occurredAt, order: .reverse) private var allEvents: [TechnicianAvailabilityEvent]
    @Query(sort: \ServiceCall.scheduledDate, order: .forward) private var serviceCalls: [ServiceCall]
    @Query(sort: \Technician.name, order: .forward) private var technicians: [Technician]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]

    let request: TechnicianTimeOffRequest
    @State private var privateReviewNote = ""
    @State private var errorMessage: String?
    @State private var confirmingWithdrawal = false

    private var currentEmail: String { AppAccess.normalizedEmail(AppIdentity.currentEmail) }
    private var canReview: Bool { AppAccess.canReviewTimeOffRequests(email: currentEmail, users: users) }
    private var canViewRequest: Bool {
        if canReview { return true }
        return request.requestedByEmail == currentEmail &&
            AppAccess.timeOffRequestTechnicianID(
                email: currentEmail,
                users: users,
                technicians: technicians
            ) == request.technicianID
    }
    private var canWithdraw: Bool { AppAccess.canWithdrawTimeOffRequest(request, email: currentEmail, users: users) }
    private var conflicts: [ServiceCall] { TechnicianTimeOffPolicy.conflicts(for: request, serviceCalls: serviceCalls) }
    private var events: [TechnicianAvailabilityEvent] { allEvents.filter { $0.requestID == request.id } }

    var body: some View {
        NavigationStack {
            Group {
                if canViewRequest {
                    List {
                        Section("Request") {
                            TechnicianTimeOffRequestRow(request: request)
                            if let reason = request.privateReason {
                                LabeledContent("Private reason", value: reason)
                                    .accessibilityIdentifier("TimeOffPrivateReasonValue")
                            }
                        }

                        reviewContent
                    }
                } else {
                    ContentUnavailableView(
                        "Request Unavailable",
                        systemImage: "lock.fill",
                        description: Text("Your account no longer has access to this time-off request.")
                    )
                }
            }
            .navigationTitle("Time-Off Request")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Withdraw this request?", isPresented: $confirmingWithdrawal) {
                Button("Withdraw Request", role: .destructive, action: withdraw)
            } message: { Text("The request will remain in history and will not affect the schedule.") }
            .alert("Change Not Saved", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "") }
            .onChange(of: canViewRequest) { _, allowed in if !allowed { dismiss() } }
        }
    }

    @ViewBuilder
    private var reviewContent: some View {
        if canReview, request.status == .pending {
            Section("Schedule Check") {
                if conflicts.isEmpty {
                    Label("No active assigned-job conflicts", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("NoAssignedJobConflicts")
                } else {
                    Label("Resolve \(conflicts.count) assigned job conflict\(conflicts.count == 1 ? "" : "s") before approval", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    ForEach(conflicts) { call in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(call.customer?.name ?? "Assigned customer job")
                                .font(.subheadline.weight(.semibold))
                            Text(call.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Private Review") {
                TextField("Review note (required to decline)", text: $privateReviewNote, axis: .vertical)
                    .lineLimit(2...5)
                    .accessibilityIdentifier("TimeOffReviewNote")
                Button("Approve & Block Schedule", action: approve)
                    .disabled(!conflicts.isEmpty)
                    .accessibilityIdentifier("ApproveTimeOffRequest")
                Button("Decline Request", role: .destructive, action: decline)
                    .disabled(TechnicianTimeOffPolicy.optionalText(privateReviewNote, limit: TechnicianTimeOffPolicy.noteLimit) == nil)
                    .accessibilityIdentifier("DeclineTimeOffRequest")
            }
        }

        if canWithdraw {
            Section {
                Button("Withdraw Pending Request", role: .destructive) { confirmingWithdrawal = true }
                    .accessibilityIdentifier("WithdrawTimeOffRequest")
            }
        }

        if let reviewer = request.reviewedByEmail, let reviewedAt = request.reviewedAt {
            Section("Review") {
                LabeledContent("Reviewed by", value: AppAccess.inferredDisplayName(fromEmail: reviewer))
                LabeledContent("Reviewed", value: reviewedAt.formatted(date: .abbreviated, time: .shortened))
                if canReview, let note = request.privateReviewNote {
                    LabeledContent("Private note", value: note)
                }
            }
        }

        Section("Audit History") {
            ForEach(events) { event in
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.kind.displayName).font(.subheadline.weight(.semibold))
                    Text("\(AppAccess.inferredDisplayName(fromEmail: event.actorEmail)) • \(event.occurredAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if canReview {
                        Text(event.privateDetail).font(.caption)
                    }
                }
            }
        }
    }

    private func approve() {
        guard canReview else { return }
        mutate {
            let approval = try TechnicianTimeOffPolicy.approve(
                request,
                actorEmail: currentEmail,
                privateReviewNote: privateReviewNote,
                serviceCalls: serviceCalls
            )
            modelContext.insert(approval.block)
            modelContext.insert(approval.event)
        }
    }

    private func decline() {
        guard canReview else { return }
        mutate {
            let event = try TechnicianTimeOffPolicy.decline(
                request,
                actorEmail: currentEmail,
                privateReviewNote: privateReviewNote
            )
            modelContext.insert(event)
        }
    }

    private func withdraw() {
        guard canWithdraw else { return }
        mutate {
            let event = try TechnicianTimeOffPolicy.withdraw(request, actorEmail: currentEmail)
            modelContext.insert(event)
        }
    }

    private func mutate(_ mutation: () throws -> Void) {
        do {
            try mutation()
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }
}
