import SwiftUI
import SwiftData
import UniformTypeIdentifiers

private struct ApprovedTimesheetCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var content: String

    init(content: String) {
        self.content = content
    }

    init(configuration: ReadConfiguration) throws {
        content = configuration.file.regularFileContents.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(content.utf8))
    }
}

struct TimeClockView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var googleAuth = GoogleAuthManager.shared
    @Query(sort: \TimeEntry.clockIn, order: .reverse) private var entries: [TimeEntry]
    @Query(sort: \ServiceCall.scheduledDate, order: .reverse) private var serviceCalls: [ServiceCall]
    @Query(sort: \Estimate.createdAt, order: .reverse) private var estimates: [Estimate]
    @Query(sort: \Invoice.createdAt, order: .reverse) private var invoices: [Invoice]
    @Query(sort: \Technician.name, order: .forward) private var technicians: [Technician]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @Query(sort: \FieldExpenseClaim.expenseDate, order: .reverse) private var expenseClaims: [FieldExpenseClaim]
    @Query(sort: \TechnicianTimeOffRequest.createdAt, order: .reverse) private var timeOffRequests: [TechnicianTimeOffRequest]
    @Query(sort: \TechnicianWorkShift.createdAt, order: .reverse) private var workShifts: [TechnicianWorkShift]
    @State private var syncMessage: String?
    @State private var selectedActivity: TimeEntryActivity = .general
    @State private var selectedServiceCallID: UUID?
    @State private var syncingEntryIDs: Set<UUID> = []
    @State private var selectedWorkspace: TimeClockWorkspace = .myTime
    @State private var reviewPeriod: TeamTimeReviewPeriod = .currentWeek
    @State private var performancePeriod: BusinessReportPeriod = .currentMonth
    @State private var entryPendingCorrection: TimeEntry?
    @State private var entryPendingCorrectionRequest: TimeEntry?
    @State private var reviewMessage: String?
    @State private var personalTimesheetPeriod: TimesheetPayPeriod = .currentWeek
    @State private var showingTimesheetSignOffConfirmation = false
    @State private var timesheetMessage: String?
    @State private var showingTimesheetExporter = false
    @State private var timesheetExportContent = ""
    @State private var timesheetExportError: String?

    private var signedInEmail: String {
        let candidate = AppIdentity.currentEmail
            ?? ""
        return AppAccess.normalizedEmail(candidate)
    }

    private var hasAuthenticatedUser: Bool {
        !signedInEmail.isEmpty
    }

    private var isOwnerAccount: Bool {
        AppAccess.isPrimaryAdmin(signedInEmail)
    }

    private var activeRole: AppUserRole? {
        AppAccess.activeRole(email: signedInEmail, users: users)
    }

    private var canReviewTeamTime: Bool {
        AppAccess.canReviewTeamTime(email: signedInEmail, users: users)
    }

    private var canRecordOwnTime: Bool {
        hasAuthenticatedUser && !isOwnerAccount && activeRole != .accounting
    }

    private var canUseFieldExpenses: Bool {
        AppAccess.canSubmitFieldExpenses(email: signedInEmail, users: users) ||
            AppAccess.canReviewFieldExpenses(email: signedInEmail, users: users)
    }

    private var canUseTimeOff: Bool {
        AppAccess.canReviewTimeOffRequests(email: signedInEmail, users: users) ||
            AppAccess.canSubmitTimeOffRequest(email: signedInEmail, users: users, technicians: technicians)
    }

    private var timeOffAttentionCount: Int {
        if AppAccess.canReviewTimeOffRequests(email: signedInEmail, users: users) {
            return timeOffRequests.filter { $0.status == .pending }.count
        }
        guard let technicianID = ownPerformanceTechnicianID else { return 0 }
        return timeOffRequests.filter {
            $0.technicianID == technicianID &&
                $0.requestedByEmail == signedInEmail &&
                $0.status == .pending
        }.count
    }

    private var ownWorkShifts: [TechnicianWorkShift] {
        guard let technicianID = ownPerformanceTechnicianID else { return [] }
        return TechnicianWorkShiftPolicy.ordered(
            workShifts.filter { $0.technicianID == technicianID && $0.isActive }
        )
    }

    private var hasOwnWorkScheduleHistory: Bool {
        guard let technicianID = ownPerformanceTechnicianID else { return false }
        return workShifts.contains { $0.technicianID == technicianID }
    }

    private var fieldExpenseAttentionCount: Int {
        if AppAccess.canReviewFieldExpenses(email: signedInEmail, users: users) {
            return expenseClaims.filter { $0.needsOfficeReview || $0.needsReimbursement }.count
        }
        return expenseClaims.filter {
            AppAccess.normalizedEmail($0.claimantEmail) == signedInEmail &&
                ($0.status == .correctionRequested || $0.status == .submitted)
        }.count
    }

    private var availableWorkspaces: [TimeClockWorkspace] {
        var workspaces: [TimeClockWorkspace] = canRecordOwnTime ? [.myTime] : []
        if ownPerformanceTechnicianID != nil {
            workspaces.append(.myPerformance)
        }
        if canReviewTeamTime {
            workspaces.append(.teamReview)
        }
        return workspaces.isEmpty ? [.myTime] : workspaces
    }

    private var ownPerformanceTechnicianID: UUID? {
        AppAccess.ownPerformanceTechnicianID(
            email: signedInEmail,
            users: users,
            technicians: technicians
        )
    }

    @MainActor
    private var ownPerformanceRow: TechnicianReportRow? {
        guard let technicianID = ownPerformanceTechnicianID else { return nil }
        return BusinessReporting.snapshot(
            period: performancePeriod,
            serviceCalls: serviceCalls,
            estimates: estimates,
            invoices: invoices,
            payments: [],
            timeEntries: entries,
            technicians: technicians
        ).technicianRows.first { $0.id == technicianID }
    }

    private var userEntries: [TimeEntry] {
        entries.filter { $0.userEmail.caseInsensitiveCompare(signedInEmail) == .orderedSame }
    }

    private var personalTimesheetInterval: DateInterval {
        personalTimesheetPeriod.dateInterval(now: Date())
    }

    private var personalTimesheetEntries: [TimeEntry] {
        TimesheetAttestationPolicy.entries(
            for: signedInEmail,
            interval: personalTimesheetInterval,
            allEntries: entries
        )
    }

    private var personalTimesheetReadiness: TimesheetReadinessSnapshot {
        TimesheetAttestationPolicy.readiness(
            employeeEmail: signedInEmail,
            interval: personalTimesheetInterval,
            entries: entries
        )
    }

    private var openEntry: TimeEntry? {
        userEntries.first { $0.isOpen }
    }

    private var trackableServiceCalls: [ServiceCall] {
        serviceCalls
            .filter { call in
                guard call.status != .cancelled && call.status != .completed && call.status != .invoiced else {
                    return false
                }
                let signedInTechnicianIDs = Set(technicians.compactMap { technician in
                    AppAccess.normalizedEmail(technician.contactInfo) == AppAccess.normalizedEmail(signedInEmail) ? technician.id : nil
                })
                let isLead = AppAccess.normalizedEmail(call.assignedTechnician?.contactInfo) == AppAccess.normalizedEmail(signedInEmail)
                return isLead || !signedInTechnicianIDs.isDisjoint(with: call.assignedCrewTechnicianIDs)
            }
            .sorted { lhs, rhs in
                if lhs.status != rhs.status {
                    return lhs.status == .inProgress
                }
                return lhs.scheduledDate < rhs.scheduledDate
            }
    }

    private var selectedServiceCall: ServiceCall? {
        guard let selectedServiceCallID else { return nil }
        return trackableServiceCalls.first { $0.id == selectedServiceCallID }
    }

    private var teamReviewEntries: [TimeEntry] {
        let interval = reviewPeriod.dateInterval(now: Date())
        return entries.filter { entry in
            entry.isOpen || (entry.clockIn >= interval.start && entry.clockIn < interval.end)
        }
    }

    private var teamMemberEmails: [String] {
        Array(Set(teamReviewEntries.map { AppAccess.normalizedEmail($0.userEmail) }.filter { !$0.isEmpty }))
            .sorted { teamMemberDisplayName(for: $0).localizedCaseInsensitiveCompare(teamMemberDisplayName(for: $1)) == .orderedAscending }
    }

    private var entriesReadyForApproval: [TimeEntry] {
        teamReviewEntries.filter { !$0.isOpen && $0.reviewStatus == .submitted }
    }

    private var teamReviewAttentionCount: Int {
        teamReviewEntries.filter { $0.isOpen || $0.needsTeamReview }.count
    }

    private var teamTimesheetInterval: DateInterval? {
        reviewPeriod.timesheetPayPeriod?.dateInterval(now: Date())
    }

    private var teamTimesheetEntries: [TimeEntry] {
        guard let teamTimesheetInterval else { return [] }
        return entries.filter {
            $0.clockIn >= teamTimesheetInterval.start && $0.clockIn < teamTimesheetInterval.end
        }
    }

    private var teamTimesheetEmployeeEmails: [String] {
        Array(Set(teamTimesheetEntries.map { AppAccess.normalizedEmail($0.userEmail) }.filter { !$0.isEmpty }))
            .sorted {
                teamMemberDisplayName(for: $0)
                    .localizedCaseInsensitiveCompare(teamMemberDisplayName(for: $1)) == .orderedAscending
            }
    }

    private var teamTimesheetReadiness: [TimesheetReadinessSnapshot] {
        guard let teamTimesheetInterval else { return [] }
        return teamTimesheetEmployeeEmails.map { email in
            TimesheetAttestationPolicy.readiness(
                employeeEmail: email,
                interval: teamTimesheetInterval,
                entries: teamTimesheetEntries
            )
        }
    }

    private var allTeamTimesheetsApprovedForExport: Bool {
        !teamTimesheetReadiness.isEmpty && teamTimesheetReadiness.allSatisfy(\.isApprovedForTimeExport)
    }

    private var teamTimesheetDisplayNames: [String: String] {
        Dictionary(uniqueKeysWithValues: teamTimesheetEmployeeEmails.map {
            ($0, teamMemberDisplayName(for: $0))
        })
    }

    private var approvedTimesheetFilename: String {
        guard let teamTimesheetInterval else { return "GunnAire-approved-time" }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return "GunnAire-approved-time-\(formatter.string(from: teamTimesheetInterval.start))"
    }

    private func serviceCall(for id: UUID?) -> ServiceCall? {
        guard let id else { return nil }
        return serviceCalls.first { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            List {
                if !hasAuthenticatedUser {
                    Section("Sign In Required") {
                        Text("Sign in with an approved GunnAire business account before recording time.")
                            .foregroundColor(.secondary)
                    }
                } else {
                    if availableWorkspaces.count > 1 {
                        Section("Time Workspace") {
                            Picker("Time Workspace", selection: $selectedWorkspace) {
                                ForEach(availableWorkspaces) { workspace in
                                    Text(workspace.displayName).tag(workspace)
                                }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier("TimeClockWorkspacePicker")
                            Text(selectedWorkspace.guidance)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if canUseFieldExpenses {
                        Section("Expenses & Mileage") {
                            NavigationLink {
                                FieldExpenseWorkspaceView()
                            } label: {
                                HStack {
                                    Label("Open Expense Claims", systemImage: "receipt")
                                    Spacer()
                                    if fieldExpenseAttentionCount > 0 {
                                        Text("\(fieldExpenseAttentionCount)")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.orange)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(.orange.opacity(0.12), in: Capsule())
                                            .accessibilityLabel("\(fieldExpenseAttentionCount) expense claims need attention")
                                    }
                                }
                            }
                            .accessibilityIdentifier("OpenFieldExpenses")
                            Text("Capture a receipt-backed field cost or mileage claim, then keep review and reimbursement evidence separate from time approval.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if canUseTimeOff {
                        Section("Availability") {
                            if ownPerformanceTechnicianID != nil {
                                DisclosureGroup("My Work Schedule") {
                                    if ownWorkShifts.isEmpty {
                                        Text(
                                            hasOwnWorkScheduleHistory
                                                ? "No active recurring hours. Dispatch treats you as off duty until new hours are added."
                                                : "Recurring hours have not been configured. Dispatch is still using appointments and approved unavailable time."
                                        )
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        ForEach(ownWorkShifts) { shift in
                                            HStack(alignment: .firstTextBaseline) {
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(shift.publicScheduleSummary)
                                                        .font(.subheadline.weight(.semibold))
                                                    Text(shift.effectiveDateSummary)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                                Spacer()
                                                Text(shift.kind.displayName)
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(shift.kind == .onCall ? .orange : .secondary)
                                            }
                                            .accessibilityIdentifier("MyWorkShift-\(shift.id.uuidString)")
                                        }
                                    }
                                }
                                .accessibilityIdentifier("MyWorkSchedule")
                            }
                            NavigationLink {
                                TechnicianTimeOffWorkspaceView()
                            } label: {
                                HStack {
                                    Label(
                                        AppAccess.canReviewTimeOffRequests(email: signedInEmail, users: users)
                                            ? "Review Time-Off Requests"
                                            : "Request Time Off",
                                        systemImage: "calendar.badge.clock"
                                    )
                                    Spacer()
                                    if timeOffAttentionCount > 0 {
                                        Text("\(timeOffAttentionCount)")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.orange)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(.orange.opacity(0.12), in: Capsule())
                                    }
                                }
                            }
                            .accessibilityIdentifier("OpenTimeOffRequests")
                            Text("Employees submit privately; Dispatch or Admin reviews capacity before approved time changes the schedule.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    switch selectedWorkspace {
                    case .myTime:
                        personalTimeSections
                    case .myPerformance:
                        personalPerformanceSections
                    case .teamReview:
                        teamReviewSections
                    }
                }
            }
            .navigationTitle("Time Clock")
            .onAppear(perform: normalizeSelectedWorkspace)
            .onChange(of: activeRole) { _, _ in normalizeSelectedWorkspace() }
            .sheet(item: $entryPendingCorrection) { entry in
                TimeEntryCorrectionSheet(
                    entry: entry,
                    serviceCalls: editableServiceCalls(for: entry)
                ) { draft in
                    applyCorrection(draft, to: entry)
                }
            }
            .sheet(item: $entryPendingCorrectionRequest) { entry in
                TimeEntryCorrectionRequestSheet(entry: entry) { reason in
                    requestCorrection(for: entry, reason: reason)
                }
            }
            .confirmationDialog(
                "Sign this weekly time snapshot?",
                isPresented: $showingTimesheetSignOffConfirmation,
                titleVisibility: .visible
            ) {
                Button("Sign Time Snapshot") {
                    signOffPersonalTimesheet()
                }
                .accessibilityIdentifier("ConfirmTimesheetSignOff")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You are confirming that every listed time entry is complete and accurate. Any later addition or correction automatically requires a new sign-off.")
            }
            .fileExporter(
                isPresented: $showingTimesheetExporter,
                document: ApprovedTimesheetCSVDocument(content: timesheetExportContent),
                contentType: .commaSeparatedText,
                defaultFilename: approvedTimesheetFilename
            ) { result in
                if case .failure(let error) = result {
                    timesheetExportError = "The approved-time file was not saved: \(error.localizedDescription)"
                }
            }
            .alert(
                "Timesheet Export",
                isPresented: Binding(
                    get: { timesheetExportError != nil },
                    set: { if !$0 { timesheetExportError = nil } }
                )
            ) {
                Button("OK") { timesheetExportError = nil }
            } message: {
                Text(timesheetExportError ?? "")
            }
        }
    }

    @ViewBuilder
    private var personalPerformanceSections: some View {
        if ownPerformanceTechnicianID == nil {
            Section("Performance Unavailable") {
                Text("Your business account does not resolve to one unique technician profile. Ask an administrator to correct the technician email mapping.")
                    .foregroundColor(.secondary)
            }
        } else {
            Section("Scorecard Period") {
                Picker("Scorecard Period", selection: $performancePeriod) {
                    ForEach(BusinessReportPeriod.allCases) { period in
                        Text(period.displayName).tag(period)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("MyPerformancePeriodPicker")

                Text("This coaching view uses only your own lead-job sales and quality results. Crew work still appears in assigned completions and time, but revenue is never counted twice.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("My Scorecard") {
                if let row = ownPerformanceRow {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)], spacing: 10) {
                        personalPerformanceMetric("Assigned Completed", value: "\(row.completedJobs)", detail: "lead or crew")
                        personalPerformanceMetric("Lead Invoiced", value: row.leadInvoicedRevenue.formatted(.currency(code: "USD")), detail: "\(row.leadInvoiceCount) invoice\(row.leadInvoiceCount == 1 ? "" : "s")")
                        personalPerformanceMetric("Average Invoice", value: row.leadInvoiceCount == 0 ? "—" : row.leadAverageInvoice.formatted(.currency(code: "USD")), detail: "lead-linked jobs")
                        personalPerformanceMetric("Estimate Close", value: row.leadEstimateConversionRate?.formatted(.percent.precision(.fractionLength(1))) ?? "—", detail: "\(row.leadAcceptedOpportunityCount) of \(row.leadEstimateOpportunityCount)")
                        personalPerformanceMetric("Corrective Rate", value: row.leadCorrectiveVisitRate?.formatted(.percent.precision(.fractionLength(1))) ?? "—", detail: "\(row.leadCorrectiveVisitCount) callback or warranty")
                        personalPerformanceMetric("Recorded Hours", value: String(format: "%.1f", row.recordedHours), detail: "completed entries")
                        personalPerformanceMetric("Job Time Mix", value: row.jobTimeShare?.formatted(.percent.precision(.fractionLength(1))) ?? "—", detail: "\(formatHours(row.jobHours)) job of \(formatHours(row.recordedHours))")
                    }
                    .accessibilityIdentifier("MyTechnicianScorecard")

                    if row.recordedHours > 0 {
                        Label(
                            "\(formatHours(row.travelHours)) travel • \(formatHours(row.otherPaidHours)) other paid",
                            systemImage: "clock.arrow.2.circlepath"
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }

                    Text("Job Time Mix is completed customer Job Labor divided by all payable completed time; unpaid breaks are excluded. Scorecards do not calculate sold-hour efficiency, payroll, commission, or final accounting revenue.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ContentUnavailableView(
                        "No activity in this period",
                        systemImage: "chart.bar.xaxis",
                        description: Text("Completed assigned jobs, linked estimates or invoices, and completed time will appear here.")
                    )
                }
            }
        }
    }

    private func personalPerformanceMetric(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(title)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func formatHours(_ value: Double) -> String {
        String(format: "%.1fh", value)
    }

    @ViewBuilder
    private var personalTimeSections: some View {
        if isOwnerAccount {
            Section("Owner Account") {
                Text("Owner account signed in.")
                    .font(.headline)
                Text("Clock in/out is not required for Eric Gunn. Use Team Review to approve staff time.")
                    .foregroundColor(.secondary)
            }
        } else if activeRole == .accounting {
            Section("Team Review") {
                Text("Accounting accounts review submitted staff time and do not create personal clock entries.")
                    .foregroundColor(.secondary)
            }
        } else {
            Section("Current Status") {
                currentStatusContent
            }

            personalTimesheetSignOffSection

            Section("Recent Time Entries") {
                if userEntries.isEmpty {
                    Text("No time entries yet.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(userEntries.prefix(20)) { entry in
                        personalEntryRow(entry)
                    }
                }
            }
        }
    }

    private var personalTimesheetSignOffSection: some View {
        let readiness = personalTimesheetReadiness
        return Section("Weekly Time") {
            Picker("Weekly Period", selection: $personalTimesheetPeriod) {
                ForEach(TimesheetPayPeriod.allCases) { period in
                    Text(period.displayName).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("PersonalTimesheetPeriodPicker")

            HStack(spacing: 12) {
                timeMetric("\(readiness.entryCount)", label: "Entries")
                timeMetric(durationLabel(minutes: readiness.payableMinutes), label: "Payable")
                timeMetric(durationLabel(minutes: readiness.unpaidMinutes), label: "Unpaid")
            }

            personalTimesheetStatus(readiness)
                .accessibilityIdentifier("TimesheetSignOffStatus")

            Button {
                showingTimesheetSignOffConfirmation = true
            } label: {
                Label(
                    readiness.employeeSignedOffAt == nil ? "Review & Sign Snapshot" : "Snapshot Signed",
                    systemImage: readiness.employeeSignedOffAt == nil ? "signature" : "checkmark.seal.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.brandGold)
            .foregroundStyle(Color.primaryBlack)
            .disabled(!readiness.canEmployeeSignOff || readiness.employeeSignedOffAt != nil)
            .accessibilityIdentifier("SignTimesheetSnapshot")

            Text("This confirms the exact entries shown for the week. New time or a correction invalidates the signature automatically; the office still approves every entry separately.")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("This app does not calculate wages, overtime, tax, commission, deductions, or net pay.")
                .font(.caption)
                .foregroundColor(.secondary)
            if let timesheetMessage {
                Text(timesheetMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func personalTimesheetStatus(_ readiness: TimesheetReadinessSnapshot) -> some View {
        if let signedAt = readiness.employeeSignedOffAt {
            Label(
                "Signed \(signedAt.formatted(date: .abbreviated, time: .shortened)) • \(readiness.unapprovedEntryCount) awaiting office approval",
                systemImage: "checkmark.seal.fill"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundColor(readiness.unapprovedEntryCount == 0 ? .green : .secondary)
        } else if readiness.entryCount == 0 {
            Label("No time entries in this period", systemImage: "clock.badge.questionmark")
                .foregroundColor(.secondary)
        } else if readiness.openEntryCount > 0 {
            Label("Clock out \(readiness.openEntryCount) open \(readiness.openEntryCount == 1 ? "entry" : "entries") before signing", systemImage: "clock.badge.exclamationmark")
                .foregroundColor(.orange)
        } else if readiness.correctionRequiredCount > 0 {
            Label("Resolve \(readiness.correctionRequiredCount) correction \(readiness.correctionRequiredCount == 1 ? "request" : "requests") before signing", systemImage: "exclamationmark.bubble")
                .foregroundColor(.orange)
        } else if readiness.invalidContextCount > 0 {
            Label("Resolve \(readiness.invalidContextCount) work-context \(readiness.invalidContextCount == 1 ? "issue" : "issues") before signing", systemImage: "link.badge.plus")
                .foregroundColor(.orange)
        } else {
            Label("Ready for your sign-off", systemImage: "signature")
                .foregroundColor(Color.brandGold)
        }
    }

    @ViewBuilder
    private var currentStatusContent: some View {
        if let openEntry {
            Text("Clocked in since \(openEntry.clockIn.formatted(date: .abbreviated, time: .shortened))")
            Picker("Activity", selection: Binding(
                get: { openEntry.activity },
                set: { updateActivity($0, for: openEntry) }
            )) {
                ForEach(TimeEntryActivity.allCases) { activity in
                    Label(activity.displayName, systemImage: activity.systemImage).tag(activity)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("ActiveTimeActivityPicker")

            if openEntry.activity.requiresServiceCall {
                Picker("Current job", selection: Binding(
                    get: { openEntry.serviceCall?.id },
                    set: { updateServiceCall(serviceCall(for: $0), for: openEntry) }
                )) {
                    Text("Choose a job").tag(UUID?.none)
                    ForEach(selectableServiceCalls(for: openEntry)) { call in
                        Text(jobLabel(for: call)).tag(UUID?.some(call.id))
                    }
                }
                .accessibilityIdentifier("ActiveTimeJobPicker")
                Text(openEntry.serviceCall == nil
                    ? "Choose the active service job before clocking out."
                    : "Job labor stays linked to the customer, visit, job costing, and approved QBO TimeActivity.")
                    .font(.caption)
                    .foregroundColor(openEntry.serviceCall == nil ? .orange : .secondary)
            } else if openEntry.activity == .unpaidBreak {
                Text("Unpaid break time remains in the review audit and is excluded from payable-hour and QBO totals.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Button("Clock Out & Submit") {
                clockOut(openEntry)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.brandGold)
            .foregroundStyle(Color.primaryBlack)
            .disabled(openEntry.activity.requiresServiceCall && openEntry.serviceCall == nil)
        } else {
            Text("You are clocked out.")
                .foregroundColor(.secondary)
            Picker("Activity", selection: $selectedActivity) {
                ForEach(TimeEntryActivity.allCases) { activity in
                    Label(activity.displayName, systemImage: activity.systemImage).tag(activity)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("TimeActivityPicker")
            .onChange(of: selectedActivity) { _, activity in
                if !activity.requiresServiceCall {
                    selectedServiceCallID = nil
                }
            }

            if selectedActivity.requiresServiceCall {
                Picker("Job for this shift", selection: $selectedServiceCallID) {
                    Text("Choose a job").tag(UUID?.none)
                    ForEach(trackableServiceCalls) { call in
                        Text(jobLabel(for: call)).tag(UUID?.some(call.id))
                    }
                }
                .accessibilityIdentifier("TimeJobPicker")
                if trackableServiceCalls.isEmpty {
                    Text("No assigned active jobs are available. Choose another activity or ask Dispatch to assign the visit.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            Button("Clock In") {
                clockIn()
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.brandGold)
            .foregroundStyle(Color.primaryBlack)
            .disabled(selectedActivity.requiresServiceCall && selectedServiceCall == nil)
            Text("Choose the activity once. Job labor asks for the visit; non-job time stays categorized without adding another workflow. Clock-out submits for office review.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        if let syncMessage {
            Text(syncMessage)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func personalEntryRow(_ entry: TimeEntry) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.clockIn.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                Spacer()
                timeReviewStatusLabel(for: entry)
            }
            Text(entry.clockOut.map { "Out: \($0.formatted(date: .abbreviated, time: .shortened)) • \(durationLabel(entry))" } ?? "Open shift")
                .font(.caption)
                .foregroundColor(.secondary)
            Label(entry.activity.displayName, systemImage: entry.activity.systemImage)
                .font(.caption.weight(.semibold))
            if let serviceCall = entry.serviceCall {
                Text("Job: \(serviceCall.customer.name)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if entry.reviewStatus == .correctionRequested, let note = entry.reviewNote {
                Label(note, systemImage: "exclamationmark.bubble")
                    .font(.caption)
                    .foregroundColor(.orange)
                Button("Correct & Resubmit") {
                    entryPendingCorrection = entry
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("CorrectTimeEntry-\(entry.id.uuidString)")
            } else if entry.reviewStatus == .submitted, !entry.isOpen {
                Text("Waiting for Accounting or Admin review. QuickBooks publication is blocked until approval.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if let quickBooksID = entry.quickBooksTimeActivityID {
                Text("QBO TimeActivity \(quickBooksID)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if entry.reviewStatus == .approved, !entry.activity.isQuickBooksPublishable {
                Text("Approved unpaid break • excluded from QBO paid time")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if entry.reviewStatus == .approved, Config.QuickBooksTime.enabled {
                Text(entry.quickBooksTimeActivitySyncError.map { "QBO sync issue: \($0)" } ?? "Approved; waiting for QBO publication.")
                    .font(.caption)
                    .foregroundColor(entry.quickBooksTimeActivitySyncError == nil ? .secondary : .orange)
            }
        }
    }

    @ViewBuilder
    private var teamReviewSections: some View {
        if !canReviewTeamTime {
            Section("Restricted") {
                Text("Only Accounting and Admin accounts can review team time.")
                    .foregroundColor(.secondary)
            }
        } else {
            Section("Review Period") {
                Picker("Review Period", selection: $reviewPeriod) {
                    ForEach(TeamTimeReviewPeriod.allCases) { period in
                        Text(period.displayName).tag(period)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 12) {
                    timeMetric("\(teamReviewEntries.count)", label: "Entries")
                    timeMetric("\(teamReviewAttentionCount)", label: "Attention")
                    timeMetric("\(entriesReadyForApproval.count)", label: "Ready")
                    timeMetric(durationLabel(minutes: approvedTeamMinutes), label: "Approved")
                }

                DisclosureGroup("Activity Summary") {
                    ForEach(TimeEntryActivity.allCases) { activity in
                        let activityEntries = teamReviewEntries.filter { $0.activity == activity }
                        let minutes = activityEntries.compactMap(\.durationMinutes).reduce(0, +)
                        if !activityEntries.isEmpty {
                            HStack {
                                Label(activity.displayName, systemImage: activity.systemImage)
                                Spacer()
                                Text(minutes == 0 ? "Open" : durationLabel(minutes: minutes))
                                    .foregroundColor(.secondary)
                                if !activity.countsTowardPayableTime {
                                    Text("unpaid")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundColor(.orange)
                                }
                            }
                            .font(.caption)
                        }
                    }
                }
                .accessibilityIdentifier("TeamTimeActivitySummary")

                teamTimesheetReadinessContent

                if !entriesReadyForApproval.isEmpty {
                    Button("Approve \(entriesReadyForApproval.count) Ready \(entriesReadyForApproval.count == 1 ? "Entry" : "Entries")") {
                        approveAllReadyEntries()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandGold)
                    .foregroundStyle(Color.primaryBlack)
                    .accessibilityIdentifier("ApproveReadyTimeEntries")
                }
                Text("Approval locks the local time record and authorizes QBO publication. Open shifts and correction requests are never included in bulk approval.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let reviewMessage {
                    Text(reviewMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Team Time") {
                if teamMemberEmails.isEmpty {
                    ContentUnavailableView(
                        "No time entries",
                        systemImage: "clock",
                        description: Text("No team time falls in this review period.")
                    )
                } else {
                    ForEach(teamMemberEmails, id: \.self) { email in
                        teamMemberDisclosure(email: email)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var teamTimesheetReadinessContent: some View {
        DisclosureGroup("Timesheet Readiness") {
            if teamTimesheetInterval == nil {
                Text("Select This Week or Last Week to review employee sign-offs and export a payroll-ready time file.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if teamTimesheetReadiness.isEmpty {
                Text("No employee time falls in this weekly period.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(teamTimesheetReadiness, id: \.employeeEmail) { readiness in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(teamMemberDisplayName(for: readiness.employeeEmail))
                                    .font(.subheadline.weight(.semibold))
                                Text("\(readiness.entryCount) entries • \(durationLabel(minutes: readiness.payableMinutes)) payable")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            teamTimesheetReadinessLabel(readiness)
                        }
                        if readiness.qboPendingCount > 0 || readiness.qboAttentionCount > 0 {
                            Text("QBO: \(readiness.qboPendingCount) pending • \(readiness.qboAttentionCount) need attention")
                                .font(.caption2)
                                .foregroundColor(readiness.qboAttentionCount > 0 ? .orange : .secondary)
                        }
                    }
                    .accessibilityIdentifier("TeamTimesheetReadiness-\(readiness.employeeEmail)")
                }

                Button {
                    beginTimesheetExport()
                } label: {
                    Label("Export Approved Time CSV", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.brandGold)
                .foregroundStyle(Color.primaryBlack)
                .disabled(!allTeamTimesheetsApprovedForExport)
                .accessibilityIdentifier("ExportApprovedTimesheetCSV")

                Text("Export requires a current employee signature and office approval for every entry. It includes QBO reconciliation state, but does not calculate wages, overtime, tax, commission, deductions, or net pay.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func teamTimesheetReadinessLabel(_ readiness: TimesheetReadinessSnapshot) -> some View {
        if readiness.isApprovedForTimeExport {
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundColor(.green)
        } else if readiness.openEntryCount > 0 {
            Label("\(readiness.openEntryCount) open", systemImage: "clock.badge.exclamationmark")
                .font(.caption.weight(.semibold))
                .foregroundColor(.orange)
        } else if readiness.correctionRequiredCount > 0 {
            Label("Correction", systemImage: "exclamationmark.bubble")
                .font(.caption.weight(.semibold))
                .foregroundColor(.orange)
        } else if readiness.invalidContextCount > 0 {
            Label("Context", systemImage: "link.badge.plus")
                .font(.caption.weight(.semibold))
                .foregroundColor(.orange)
        } else if readiness.employeeSignedOffAt == nil {
            Label("Sign-off", systemImage: "signature")
                .font(.caption.weight(.semibold))
                .foregroundColor(.orange)
        } else {
            Label("\(readiness.unapprovedEntryCount) approval", systemImage: "person.badge.clock")
                .font(.caption.weight(.semibold))
                .foregroundColor(.orange)
        }
    }

    private var approvedTeamMinutes: Int {
        teamReviewEntries
            .filter { $0.reviewStatus == .approved }
            .compactMap(\.payableDurationMinutes)
            .reduce(0, +)
    }

    private func timeMetric(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func teamMemberDisclosure(email: String) -> some View {
        let memberEntries = teamReviewEntries
            .filter { AppAccess.normalizedEmail($0.userEmail) == email }
            .sorted { $0.clockIn > $1.clockIn }
        let attention = memberEntries.filter { $0.isOpen || $0.needsTeamReview }.count
        let minutes = memberEntries.compactMap(\.payableDurationMinutes).reduce(0, +)
        let unpaidMinutes = memberEntries
            .filter { !$0.activity.countsTowardPayableTime }
            .compactMap(\.durationMinutes)
            .reduce(0, +)

        return DisclosureGroup {
            ForEach(memberEntries) { entry in
                teamReviewEntryRow(entry)
                    .padding(.vertical, 6)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(teamMemberDisplayName(for: email))
                        .font(.headline)
                    Text("\(memberEntries.count) entries • \(minutes / 60)h \(minutes % 60)m payable\(unpaidMinutes > 0 ? " • \(unpaidMinutes)m unpaid" : "")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if attention > 0 {
                    Text("\(attention) review")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.orange)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .accessibilityLabel("No review issues")
                }
            }
            .accessibilityIdentifier("TeamTimeMember-\(email)")
        }
    }

    private func teamReviewEntryRow(_ entry: TimeEntry) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.clockIn.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline.weight(.semibold))
                    Text(entry.clockOut.map { "\($0.formatted(date: .omitted, time: .shortened)) • \(durationLabel(entry))" } ?? "Open shift — clock-out required")
                        .font(.caption)
                        .foregroundColor(entry.isOpen ? .orange : .secondary)
                }
                Spacer()
                timeReviewStatusLabel(for: entry)
            }
            if let serviceCall = entry.serviceCall {
                Text("\(serviceCall.customer.name) • \(serviceCall.type.displayName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("General / non-job time")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Label(entry.activity.displayName, systemImage: entry.activity.systemImage)
                .font(.caption.weight(.semibold))
            if !entry.activity.countsTowardPayableTime {
                Text("Excluded from payable-hour and QBO totals")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if let note = entry.reviewNote, entry.reviewStatus == .correctionRequested {
                Text("Correction: \(note)")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            if let quickBooksID = entry.quickBooksTimeActivityID {
                Text("QBO TimeActivity \(quickBooksID)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if let error = entry.quickBooksTimeActivitySyncError {
                Text("QBO: \(error)")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            if !entry.isOpen && entry.quickBooksTimeActivityID == nil {
                HStack {
                    if entry.reviewStatus == .submitted {
                        Button("Approve") { approveEntry(entry) }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .accessibilityIdentifier("ApproveTimeEntry-\(entry.id.uuidString)")
                        Button("Request Correction") { entryPendingCorrectionRequest = entry }
                            .buttonStyle(.bordered)
                        Button("Edit") { entryPendingCorrection = entry }
                            .buttonStyle(.bordered)
                    } else if entry.reviewStatus == .correctionRequested {
                        Button("Correct Entry") { entryPendingCorrection = entry }
                            .buttonStyle(.bordered)
                    } else if Config.QuickBooksTime.enabled, entry.activity.isQuickBooksPublishable {
                        Button(syncingEntryIDs.contains(entry.id) ? "Checking QuickBooks..." : "Retry QBO Sync") {
                            syncCompletedEntryToQuickBooks(entry)
                        }
                        .buttonStyle(.bordered)
                        .disabled(syncingEntryIDs.contains(entry.id))
                        .accessibilityIdentifier("RetryQBOTimeSync-\(entry.id.uuidString)")
                    }
                }
            }
        }
    }

    private func timeReviewStatusLabel(for entry: TimeEntry) -> some View {
        let label = entry.isOpen ? "Open" : entry.reviewStatus.displayName
        let image = entry.isOpen ? "clock.badge.exclamationmark" : entry.reviewStatus.systemImage
        let color: Color = entry.isOpen || entry.reviewStatus == .correctionRequested
            ? .orange
            : (entry.reviewStatus == .approved ? .green : Color.brandGold)
        return Label(label, systemImage: image)
            .font(.caption.weight(.semibold))
            .foregroundColor(color)
    }

    private func normalizeSelectedWorkspace() {
        guard availableWorkspaces.contains(selectedWorkspace) else {
            selectedWorkspace = availableWorkspaces.first ?? .myTime
            return
        }
        if !canRecordOwnTime, canReviewTeamTime {
            selectedWorkspace = .teamReview
        }
    }

    private func teamMemberDisplayName(for email: String) -> String {
        if let technician = technicians.first(where: {
            AppAccess.normalizedEmail($0.contactInfo) == AppAccess.normalizedEmail(email)
        }) {
            return technician.name
        }
        return AppAccess.inferredDisplayName(fromEmail: email)
    }

    private func durationLabel(_ entry: TimeEntry) -> String {
        guard let minutes = entry.durationMinutes else { return "Open" }
        return durationLabel(minutes: minutes)
    }

    private func durationLabel(minutes: Int) -> String {
        "\(minutes / 60)h \(minutes % 60)m"
    }

    private func editableServiceCalls(for entry: TimeEntry) -> [ServiceCall] {
        let ownerEmail = AppAccess.normalizedEmail(entry.userEmail)
        let ownerTechnicianIDs = Set(technicians.compactMap { technician in
            AppAccess.normalizedEmail(technician.contactInfo) == ownerEmail ? technician.id : nil
        })
        return serviceCalls.filter { call in
            if call.id == entry.serviceCall?.id { return true }
            let isLead = AppAccess.normalizedEmail(call.assignedTechnician?.contactInfo) == ownerEmail
            let isCrew = !ownerTechnicianIDs.isDisjoint(with: call.assignedCrewTechnicianIDs)
            return isLead || isCrew
        }
        .sorted { $0.scheduledDate > $1.scheduledDate }
    }

    private func applyCorrection(_ draft: TimeEntryCorrectionDraft, to entry: TimeEntry) -> String? {
        do {
            let selectedCall = draft.activity.requiresServiceCall
                ? draft.serviceCallID.flatMap { id in
                    editableServiceCalls(for: entry).first { $0.id == id }
                }
                : nil
            try TimeEntryReviewPolicy.applyCorrection(
                draft,
                to: entry,
                serviceCall: selectedCall,
                allEntries: entries,
                actorEmail: signedInEmail,
                users: users
            )
            try modelContext.save()
            reviewMessage = "Corrected time was resubmitted for review."
            syncMessage = reviewMessage
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func requestCorrection(for entry: TimeEntry, reason: String) -> String? {
        do {
            try TimeEntryReviewPolicy.requestCorrection(
                for: entry,
                reason: reason,
                actorEmail: signedInEmail,
                users: users
            )
            try modelContext.save()
            reviewMessage = "Correction requested from \(teamMemberDisplayName(for: entry.userEmail))."
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func approveEntry(_ entry: TimeEntry) {
        do {
            try TimeEntryReviewPolicy.approve(entry, actorEmail: signedInEmail, users: users)
            try modelContext.save()
            reviewMessage = "Approved \(durationLabel(entry)) for \(teamMemberDisplayName(for: entry.userEmail))."
            syncCompletedEntryToQuickBooks(entry)
        } catch {
            reviewMessage = error.localizedDescription
        }
    }

    private func approveAllReadyEntries() {
        var approved: [TimeEntry] = []
        for entry in entriesReadyForApproval {
            do {
                try TimeEntryReviewPolicy.approve(entry, actorEmail: signedInEmail, users: users)
                approved.append(entry)
            } catch {
                reviewMessage = error.localizedDescription
            }
        }
        guard !approved.isEmpty else { return }
        do {
            try modelContext.save()
            reviewMessage = "Approved \(approved.count) \(approved.count == 1 ? "entry" : "entries")."
            for entry in approved {
                syncCompletedEntryToQuickBooks(entry)
            }
        } catch {
            reviewMessage = "Could not save time approvals: \(error.localizedDescription)"
        }
    }

    private func signOffPersonalTimesheet() {
        let originals = personalTimesheetEntries.map { ($0, $0.reviewAuditJSON) }
        do {
            let event = try TimesheetAttestationPolicy.signOff(
                employeeEmail: signedInEmail,
                actorEmail: signedInEmail,
                interval: personalTimesheetInterval,
                entries: personalTimesheetEntries
            )
            try modelContext.save()
            timesheetMessage = "Signed this weekly snapshot at \(event.occurredAt.formatted(date: .abbreviated, time: .shortened))."
        } catch {
            originals.forEach { entry, reviewAuditJSON in
                entry.reviewAuditJSON = reviewAuditJSON
            }
            timesheetMessage = error.localizedDescription
        }
    }

    private func beginTimesheetExport() {
        guard let teamTimesheetInterval else {
            timesheetExportError = "Select a weekly review period before exporting approved time."
            return
        }
        do {
            timesheetExportContent = try ApprovedTimesheetCSV.render(
                interval: teamTimesheetInterval,
                entries: teamTimesheetEntries,
                employeeDisplayNames: teamTimesheetDisplayNames
            )
            showingTimesheetExporter = true
        } catch {
            timesheetExportError = error.localizedDescription
        }
    }

    private func clockIn() {
        guard hasAuthenticatedUser else {
            syncMessage = "Sign in with an approved GunnAire business account before recording time."
            return
        }
        guard !selectedActivity.requiresServiceCall || selectedServiceCall != nil else {
            syncMessage = "Choose the active service job before recording Job Labor."
            return
        }
        let entry = TimeEntry(
            userEmail: signedInEmail,
            serviceCall: selectedActivity.requiresServiceCall ? selectedServiceCall : nil,
            activity: selectedActivity
        )
        modelContext.insert(entry)
        do {
            try modelContext.save()
            syncMessage = "Recording \(selectedActivity.displayName.lowercased()) time on this device."
            selectedActivity = .general
            selectedServiceCallID = nil
        } catch {
            modelContext.delete(entry)
            syncMessage = "Could not start the time entry: \(error.localizedDescription)"
        }
    }

    private func clockOut(_ entry: TimeEntry) {
        let now = Date()
        let previousClockOut = entry.clockOut
        let previousReviewStatusRawValue = entry.reviewStatusRawValue
        let previousReviewedByEmail = entry.reviewedByEmail
        let previousReviewedAt = entry.reviewedAt
        let previousReviewNote = entry.reviewNote
        let previousQuickBooksSyncError = entry.quickBooksTimeActivitySyncError
        let previousReviewAuditJSON = entry.reviewAuditJSON
        entry.clockOut = now
        do {
            try TimeEntryReviewPolicy.submitAfterClockOut(entry, actorEmail: signedInEmail, at: now)
            try modelContext.save()
            syncMessage = "Time stayed local and was submitted for office review. QuickBooks publication begins only after approval."
        } catch {
            entry.clockOut = previousClockOut
            entry.reviewStatusRawValue = previousReviewStatusRawValue
            entry.reviewedByEmail = previousReviewedByEmail
            entry.reviewedAt = previousReviewedAt
            entry.reviewNote = previousReviewNote
            entry.quickBooksTimeActivitySyncError = previousQuickBooksSyncError
            entry.reviewAuditJSON = previousReviewAuditJSON
            syncMessage = error.localizedDescription
        }
    }

    private func syncCompletedEntryToQuickBooks(_ entry: TimeEntry) {
        guard Config.QuickBooksTime.enabled else { return }
        guard entry.quickBooksTimeActivityID == nil else { return }
        guard entry.isApprovedForQuickBooksPublication else {
            reviewMessage = "Approve this completed time entry before QuickBooks publication."
            return
        }
        guard entry.activity.isQuickBooksPublishable else {
            entry.quickBooksTimeActivitySyncError = nil
            reviewMessage = "Approved unpaid break stayed in the time audit and was excluded from QBO paid time."
            try? modelContext.save()
            return
        }
        guard let mapping = QuickBooksTimeActivitySync.mapping(
            for: entry.userEmail,
            technicians: technicians
        ) else {
            entry.quickBooksTimeActivitySyncError = "No technician-specific QuickBooks Employee or Vendor ID is configured."
            reviewMessage = "Approved time stayed local because this technician needs one QBO Employee or Vendor mapping in Sync & Integrations."
            try? modelContext.save()
            return
        }
        guard QuickBooksDataAPI.shared.isAuthenticated else {
            entry.quickBooksTimeActivitySyncError = "QuickBooks is not connected."
            reviewMessage = "Time is approved, but QuickBooks is not connected. It stayed in the recovery queue."
            try? modelContext.save()
            return
        }
        guard let payload = QuickBooksTimeActivitySync.makePayload(for: entry, mapping: mapping) else {
            entry.quickBooksTimeActivitySyncError = "Could not build a valid TimeActivity duration."
            reviewMessage = entry.quickBooksTimeActivitySyncError
            try? modelContext.save()
            return
        }

        syncingEntryIDs.insert(entry.id)
        entry.quickBooksTimeActivitySyncError = nil
        reviewMessage = "Checking QuickBooks for the stable time marker before publication..."
        try? modelContext.save()

        QuickBooksDataAPI.shared.fetchTimeActivities { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    syncingEntryIDs.remove(entry.id)
                    entry.quickBooksTimeActivitySyncError = "Could not reconcile existing QBO time: \(error.localizedDescription)"
                    reviewMessage = "QuickBooks reconciliation failed; approved time stayed local and was not duplicated."
                    try? modelContext.save()
                case .success(let activities):
                    if let existing = QuickBooksTimeActivitySync.matchingActivity(
                        for: entry.id,
                        in: activities
                    ) {
                        finishQuickBooksSync(entry, activity: existing, reconciled: true)
                    } else {
                        createQuickBooksTimeActivity(payload, for: entry)
                    }
                }
            }
        }
    }

    private func createQuickBooksTimeActivity(
        _ payload: QuickBooksTimeActivityCreate,
        for entry: TimeEntry
    ) {
        reviewMessage = "Publishing approved time to QuickBooks..."
        QuickBooksDataAPI.shared.createTimeActivity(payload) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let activity):
                    finishQuickBooksSync(entry, activity: activity, reconciled: false)
                case .failure(let error):
                    syncingEntryIDs.remove(entry.id)
                    entry.quickBooksTimeActivitySyncError = error.localizedDescription
                    reviewMessage = "QBO time sync failed; approved time stayed local and can be retried."
                    try? modelContext.save()
                }
            }
        }
    }

    private func finishQuickBooksSync(
        _ entry: TimeEntry,
        activity: QuickBooksTimeActivity,
        reconciled: Bool
    ) {
        syncingEntryIDs.remove(entry.id)
        entry.quickBooksTimeActivityID = activity.Id
        entry.quickBooksTimeActivitySyncToken = activity.SyncToken
        entry.quickBooksTimeActivitySyncedAt = Date()
        entry.quickBooksTimeActivitySyncError = nil
        reviewMessage = reconciled
            ? "Recovered existing QBO TimeActivity \(activity.Id); no duplicate was created."
            : "Synced to QBO TimeActivity \(activity.Id)."
        syncMessage = reviewMessage
        try? modelContext.save()
    }

    private func jobLabel(for call: ServiceCall) -> String {
        "\(call.customer.name) • \(call.type.displayName) • \(call.scheduledDate.formatted(date: .abbreviated, time: .shortened))"
    }

    private func selectableServiceCalls(for entry: TimeEntry) -> [ServiceCall] {
        guard let current = entry.serviceCall,
              !trackableServiceCalls.contains(where: { $0.id == current.id }) else {
            return trackableServiceCalls
        }
        return [current] + trackableServiceCalls
    }

    private func updateActivity(_ activity: TimeEntryActivity, for entry: TimeEntry) {
        entry.activity = activity
        if !activity.requiresServiceCall {
            entry.serviceCall = nil
        }
        saveOpenTimeContext()
    }

    private func updateServiceCall(_ serviceCall: ServiceCall?, for entry: TimeEntry) {
        entry.serviceCall = serviceCall
        saveOpenTimeContext()
    }

    private func saveOpenTimeContext() {
        do {
            try modelContext.save()
            syncMessage = "Current time context saved on this device."
        } catch {
            syncMessage = "Could not save the time context: \(error.localizedDescription)"
        }
    }

}

private enum TimeClockWorkspace: String, CaseIterable, Identifiable {
    case myTime
    case myPerformance
    case teamReview

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .myTime: "My Time"
        case .myPerformance: "My Performance"
        case .teamReview: "Team Review"
        }
    }

    var guidance: String {
        switch self {
        case .myTime:
            "Clock in, link work to a job, and resolve any correction requested by the office."
        case .myPerformance:
            "Review your own lead-job sales, quality, assigned work, and recorded time without exposing another technician's results."
        case .teamReview:
            "Review submitted time, return errors for correction, approve valid hours, and recover approved QBO publication."
        }
    }
}

private enum TeamTimeReviewPeriod: String, CaseIterable, Identifiable {
    case currentWeek
    case previousWeek
    case trailingFourteenDays

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .currentWeek: "This Week"
        case .previousWeek: "Last Week"
        case .trailingFourteenDays: "14 Days"
        }
    }

    var timesheetPayPeriod: TimesheetPayPeriod? {
        switch self {
        case .currentWeek: .currentWeek
        case .previousWeek: .previousWeek
        case .trailingFourteenDays: nil
        }
    }

    func dateInterval(now: Date, calendar: Calendar = .current) -> DateInterval {
        let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now)
            ?? DateInterval(start: calendar.startOfDay(for: now), duration: 7 * 24 * 60 * 60)
        switch self {
        case .currentWeek:
            return currentWeek
        case .previousWeek:
            let start = calendar.date(byAdding: .weekOfYear, value: -1, to: currentWeek.start)
                ?? currentWeek.start.addingTimeInterval(-7 * 24 * 60 * 60)
            return DateInterval(start: start, end: currentWeek.start)
        case .trailingFourteenDays:
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            let start = calendar.date(byAdding: .day, value: -14, to: end) ?? end.addingTimeInterval(-14 * 24 * 60 * 60)
            return DateInterval(start: start, end: end)
        }
    }
}

private struct TimeEntryCorrectionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let entry: TimeEntry
    let serviceCalls: [ServiceCall]
    let onSave: (TimeEntryCorrectionDraft) -> String?

    @State private var draft: TimeEntryCorrectionDraft
    @State private var errorMessage: String?

    init(
        entry: TimeEntry,
        serviceCalls: [ServiceCall],
        onSave: @escaping (TimeEntryCorrectionDraft) -> String?
    ) {
        self.entry = entry
        self.serviceCalls = serviceCalls
        self.onSave = onSave
        _draft = State(initialValue: TimeEntryCorrectionDraft(entry: entry))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Time") {
                    DatePicker("Clock in", selection: $draft.clockIn)
                    DatePicker("Clock out", selection: $draft.clockOut)
                    Text("Corrections must not overlap another entry and cannot exceed 24 hours.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Work Context") {
                    Picker("Activity", selection: $draft.activity) {
                        ForEach(TimeEntryActivity.allCases) { activity in
                            Label(activity.displayName, systemImage: activity.systemImage).tag(activity)
                        }
                    }
                    .accessibilityIdentifier("CorrectedTimeActivityPicker")

                    if draft.activity.requiresServiceCall {
                        Picker("Job", selection: $draft.serviceCallID) {
                            Text("Choose a job").tag(UUID?.none)
                            ForEach(serviceCalls) { call in
                                Text("\(call.customer.name) • \(call.type.displayName) • \(call.scheduledDate.formatted(date: .abbreviated, time: .shortened))")
                                    .tag(UUID?.some(call.id))
                            }
                        }
                        if draft.serviceCallID == nil {
                            Text("Job Labor requires a service job before resubmission.")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    } else if draft.activity == .unpaidBreak {
                        Text("Unpaid break time remains auditable and is excluded from payable-hour and QBO totals.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    TextField("Work notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section("Approval") {
                    Text("Saving resubmits this entry for office approval. Approved or QBO-published time cannot be changed here.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Correct Time Entry")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: draft.activity) { _, activity in
                if !activity.requiresServiceCall {
                    draft.serviceCallID = nil
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save & Resubmit") {
                        if let error = onSave(draft) {
                            errorMessage = error
                        } else {
                            dismiss()
                        }
                    }
                    .accessibilityIdentifier("SaveCorrectedTimeEntry")
                }
            }
        }
    }
}

private struct TimeEntryCorrectionRequestSheet: View {
    @Environment(\.dismiss) private var dismiss

    let entry: TimeEntry
    let onSubmit: (String) -> String?

    @State private var reason = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Time Entry") {
                    Text(entry.userEmail)
                        .font(.headline)
                    Text("\(entry.clockIn.formatted(date: .abbreviated, time: .shortened)) – \(entry.clockOut?.formatted(date: .omitted, time: .shortened) ?? "Open")")
                        .foregroundColor(.secondary)
                }
                Section("Correction Needed") {
                    TextField("Explain the correction", text: $reason, axis: .vertical)
                        .lineLimit(3...6)
                    Text("The reason appears beside the employee's time entry and remains in its review audit.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Request Correction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send Request") {
                        if let error = onSubmit(reason) {
                            errorMessage = error
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("SubmitTimeCorrectionRequest")
                }
            }
        }
    }
}

enum QuickBooksTimeActivitySync {
    static func mapping(
        for userEmail: String,
        technicians: [Technician]
    ) -> TechnicianQuickBooksTimeMapping? {
        let normalizedEmail = AppAccess.normalizedEmail(userEmail)
        guard !normalizedEmail.isEmpty else { return nil }
        let mappings = technicians
            .filter { AppAccess.normalizedEmail($0.contactInfo) == normalizedEmail }
            .compactMap(\.quickBooksTimeMapping)
        let signatures = Set(mappings.map { "\($0.kind.rawValue):\($0.referenceID)" })
        guard signatures.count == 1 else { return nil }
        return mappings.first
    }

    static func operationMarker(for entryID: UUID) -> String {
        "GUNNAIRE-TIME:\(entryID.uuidString.uppercased())"
    }

    static func matchingActivity(
        for entryID: UUID,
        in activities: [QuickBooksTimeActivity]
    ) -> QuickBooksTimeActivity? {
        let marker = operationMarker(for: entryID)
        return activities.first { activity in
            activity.Description?.localizedCaseInsensitiveContains(marker) == true
        }
    }

    static func makePayload(
        for entry: TimeEntry,
        mapping: TechnicianQuickBooksTimeMapping
    ) -> QuickBooksTimeActivityCreate? {
        guard entry.isEligibleForQuickBooksPublication else { return nil }
        guard let durationMinutes = entry.payableDurationMinutes, durationMinutes > 0 else { return nil }
        let hours = durationMinutes / 60
        let minutes = durationMinutes % 60
        let nameOf = mapping.kind.quickBooksNameOf
        let entityRef = QuickBooksReference(value: mapping.referenceID, name: mapping.technicianName)
        let customerID = entry.serviceCall?.customer.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let customerRef = customerID.flatMap { $0.isEmpty ? nil : QuickBooksReference(value: $0, name: entry.serviceCall?.customer.name) }
        let projectID = Config.QuickBooksTime.projectRef.trimmingCharacters(in: .whitespacesAndNewlines)
        let itemID = Config.QuickBooksTime.itemRef.trimmingCharacters(in: .whitespacesAndNewlines)
        let payrollItemID = Config.QuickBooksTime.payrollItemRef.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = [
            "Activity: \(entry.activity.displayName)",
            entry.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
            entry.serviceCall.map { "GunnAire Ops time for \($0.customer.name)" },
            "Clocked \(entry.clockIn.formatted(date: .abbreviated, time: .shortened)) - \(entry.clockOut?.formatted(date: .abbreviated, time: .shortened) ?? "")",
            operationMarker(for: entry.id)
        ]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: "\n")

        return QuickBooksTimeActivityCreate(
            TxnDate: qboDateString(entry.clockIn),
            NameOf: nameOf,
            EmployeeRef: nameOf == "Employee" ? entityRef : nil,
            VendorRef: nameOf == "Vendor" ? entityRef : nil,
            CustomerRef: customerRef,
            ProjectRef: projectID.isEmpty ? nil : QuickBooksReference(value: projectID, name: nil),
            ItemRef: itemID.isEmpty ? nil : QuickBooksReference(value: itemID, name: nil),
            PayrollItemRef: payrollItemID.isEmpty ? nil : QuickBooksReference(value: payrollItemID, name: nil),
            Hours: hours,
            Minutes: minutes,
            Description: description.isEmpty ? nil : description
        )
    }

    static func qboDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

#Preview {
    TimeClockView()
}
