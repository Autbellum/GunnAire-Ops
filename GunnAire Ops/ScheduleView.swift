import SwiftUI
import SwiftData

struct ScheduleView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\ServiceCall.scheduledDate)]) private var serviceCalls: [ServiceCall]
    @Query(sort: \Technician.name, order: .forward) private var technicians: [Technician]
    @Query private var recurringContracts: [RecurringMaintenanceContract]
    @Query(sort: \Estimate.createdAt, order: .reverse) private var estimates: [Estimate]
    @Query(sort: \Invoice.createdAt, order: .reverse) private var invoices: [Invoice]
    @Query(sort: \Payment.date, order: .reverse) private var payments: [Payment]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @ObservedObject private var googleAuth = GoogleAuthManager.shared
    @AppStorage("enableOnsitePayments") private var enableOnsitePayments = false
    @AppStorage("onsitePaymentProcessor") private var onsitePaymentProcessor = OnsitePaymentProcessor.none.rawValue
    @AppStorage("onsitePaymentProcessorReady") private var onsitePaymentProcessorReady = false
    
    @State private var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var showingAddCallSheet = false
    @State private var editingCall: ServiceCall?
    @State private var documentationCall: ServiceCall?
    @State private var navigationPath = NavigationPath()
    @State private var openDocumentationInCloseout = false
    @State private var openDocumentationInTapToPay = false
    @State private var isSyncingGoogleCalendar = false
    @State private var syncMessage: String?
    @State private var deleteConfirmationCall: ServiceCall?

    private var selectedDayCalls: [ServiceCall] {
        callsForSignedInUser
            .filter { Calendar.current.isDate($0.scheduledDate, inSameDayAs: selectedDate) }
            .sorted { $0.scheduledDate < $1.scheduledDate }
    }

    private var upcomingJobs: [ServiceCall] {
        let now = Date()
        let calendar = Calendar.current
        let sevenDaysAhead = calendar.date(byAdding: .day, value: 7, to: now) ?? now
        return callsForSignedInUser.filter { $0.scheduledDate >= now && $0.scheduledDate <= sevenDaysAhead }
            .sorted { $0.scheduledDate < $1.scheduledDate }
    }

    private var snapshotCalls: [ServiceCall] {
        Array(upcomingJobs.prefix(3))
    }

    private var followUpCalls: [ServiceCall] {
        callsForSignedInUser
            .filter { call in
                call.followUpRequired ||
                (call.type == .estimate && call.linkedInvoiceID == nil) ||
                isCollectionOverdue(for: call)
            }
            .sorted {
                let lhsDueDate = $0.followUpDueDate ?? $0.scheduledDate
                let rhsDueDate = $1.followUpDueDate ?? $1.scheduledDate
                if lhsDueDate != rhsDueDate {
                    return lhsDueDate < rhsDueDate
                }
                if $0.followUpRequired != $1.followUpRequired {
                    return $0.followUpRequired && !$1.followUpRequired
                }
                return $0.scheduledDate > $1.scheduledDate
            }
    }

    private var approvedEstimateCalls: [ServiceCall] {
        callsForSignedInUser
            .filter { call in
                guard let estimate = estimate(for: call) else { return false }
                return estimate.status == "accepted" && call.linkedInvoiceID == nil
            }
            .sorted { $0.scheduledDate > $1.scheduledDate }
    }

    private var signedInTechnician: Technician? {
        guard let email = googleAuth.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail") else {
            return nil
        }
        return technicians.first { technician in
            technician.contactInfo?.localizedCaseInsensitiveContains(email) == true ||
            email.localizedCaseInsensitiveContains(technician.name)
        }
    }

    private var assignableTechnicians: [Technician] {
        AppAccess.schedulableTechnicians(technicians, users: users)
    }

    private var unassignedUpcomingCalls: [ServiceCall] {
        let now = Date()
        let sevenDaysAhead = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now
        return serviceCalls
            .filter { call in
                call.assignedTechnician == nil &&
                call.status != .cancelled &&
                call.scheduledDate >= now &&
                call.scheduledDate <= sevenDaysAhead
            }
            .sorted { $0.scheduledDate < $1.scheduledDate }
    }

    private var readyToInvoiceCalls: [ServiceCall] {
        callsForSignedInUser
            .filter { call in
                call.linkedInvoiceID == nil &&
                call.status != .cancelled &&
                (
                    call.workCompletedChecklist ||
                    call.documentationChecklist ||
                    call.status == .completed
                )
            }
            .sorted { $0.scheduledDate > $1.scheduledDate }
    }

    private var needsCloseoutCalls: [ServiceCall] {
        callsForSignedInUser
            .filter { call in
                guard let invoice = invoice(for: call) else { return false }
                return invoice.finalizedAt == nil || invoice.customerSignedAt == nil
            }
            .sorted { $0.scheduledDate > $1.scheduledDate }
    }

    private var quickBooksAttentionPayments: [Payment] {
        payments
            .filter { payment in
                payment.needsQuickBooksAttention &&
                callsForSignedInUser.contains { $0.linkedInvoiceID == payment.invoice.id }
            }
            .sorted { $0.date > $1.date }
    }

    private var callsForSignedInUser: [ServiceCall] {
        guard let email = googleAuth.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail") else {
            return serviceCalls
        }
        let matched = serviceCalls.filter { call in
            guard let technician = call.assignedTechnician else { return true }
            return technician.contactInfo?.localizedCaseInsensitiveContains(email) == true ||
                email.localizedCaseInsensitiveContains(technician.name)
        }
        return matched
    }
    
    var activeRecurringContracts: [RecurringMaintenanceContract] {
        let now = Date()
        return recurringContracts.filter { $0.nextDate >= now }
    }

    private var maintenanceAttentionContracts: [RecurringMaintenanceContract] {
        recurringContracts
            .filter { $0.active && ($0.isOverdue || $0.isUpcoming || $0.needsReminder) }
            .sorted { $0.nextDate < $1.nextDate }
    }

    private var selectedProcessor: OnsitePaymentProcessor {
        OnsitePaymentProcessor(rawValue: onsitePaymentProcessor) ?? .none
    }

    private var tapToPayReady: Bool {
        enableOnsitePayments &&
        selectedProcessor.supportsTapToPay &&
        OnsitePaymentManager.shared.processorReady()
    }

    private var isAdminUser: Bool {
        let email = googleAuth.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail")
        return AppAccess.isAdmin(email: email, users: users)
    }
    
    var body: some View {
        ZStack {
            WatermarkBackground()
            NavigationStack(path: $navigationPath) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        snapshotSection

                        VStack(alignment: .leading, spacing: 10) {
                            sectionTitle("Calendar")
                            DatePicker(
                                "Select Date",
                                selection: $selectedDate,
                                displayedComponents: [.date]
                            )
                            .labelsHidden()
                            .datePickerStyle(.graphical)
                            .padding(12)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                sectionTitle(selectedDate.formatted(.dateTime.month(.wide).day().year()))
                                Spacer()
                                Text("\(selectedDayCalls.count) event\(selectedDayCalls.count == 1 ? "" : "s")")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }

                            if selectedDayCalls.isEmpty {
                                emptyDayState
                            } else {
                                LazyVStack(spacing: 10) {
                                    ForEach(selectedDayCalls) { call in
                                        serviceCallCard(for: call)
                                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                            if isAdminUser, let invoice = invoice(for: call), !isInvoicePaid(invoice) {
                                                Button {
                                                    openDocumentationInCloseout = true
                                                    openDocumentationInTapToPay = tapToPayReady
                                                    documentationCall = call
                                                } label: {
                                                    Label(tapToPayReady ? "Tap to Pay" : "Take Payment", systemImage: "creditcard")
                                                }
                                                .tint(.green)
                                            }

                                            if isAdminUser {
                                                Button {
                                                    openDocumentationInCloseout = false
                                                    openDocumentationInTapToPay = false
                                                    documentationCall = call
                                                } label: {
                                                    Label(documentationActionTitle(for: call, compact: true), systemImage: "doc.text")
                                                }
                                                .tint(Color.brandGold)
                                            }
                                        }
                                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                            if hasNavigableAddress(for: call) {
                                                Button {
                                                    openMaps(for: call)
                                                } label: {
                                                    Label("Navigate", systemImage: "map")
                                                }
                                                .tint(.blue)
                                            }
                                        }
                                    }
                                    .onDelete(perform: deleteCalls)
                                }
                            }
                        }

                        if let syncMessage {
                            Text(syncMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 2)
                        }

                        if googleAuth.isAuthenticated {
                            Text("If Google Calendar sync was connected before the calendar permission update, disconnect Google in Settings and reconnect it once so the app can request fresh calendar permission.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 2)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(Color.clear)
                .navigationTitle("Schedule")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        HStack {
                            Button {
                                syncGoogleCalendar()
                            } label: {
                                Label(isSyncingGoogleCalendar ? "Syncing..." : "Sync Google", systemImage: "arrow.triangle.2.circlepath")
                                    .bold()
                            }
                            .disabled(isSyncingGoogleCalendar || !googleAuth.isAuthenticated)
                            .tint(Color.brandGold)

                            Button {
                                showingAddCallSheet = true
                            } label: {
                                Label("Add Call", systemImage: "plus")
                                    .bold()
                            }
                            .tint(Color.brandGold)
                        }
                    }
                    ToolbarItem(placement: .navigationBarLeading) {
                        EditButton()
                            .tint(Color.brandGold)
                    }
                }
                .navigationDestination(for: ServiceCall.self) { call in
                    ServiceCallDetailView(call: call)
                        .tint(Color.brandGold)
                }
                .onAppear {
                    AppAccess.ensureTechnicianRecords(for: users, technicians: technicians, modelContext: modelContext)
                    applyPendingScheduleIntentIfNeeded()
                }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GunnAireRouteDidChange"))) { _ in
                    applyPendingScheduleIntentIfNeeded()
                }
                .sheet(isPresented: $showingAddCallSheet) {
                    AddServiceCallView(selectedDate: selectedDate) { createdCall in
                        openDocumentationInCloseout = false
                        openDocumentationInTapToPay = false
                        documentationCall = createdCall
                    }
                        .tint(Color.brandGold)
                }
                .fullScreenCover(item: $editingCall) { call in
                    EditServiceCallView(call: call)
                        .tint(Color.brandGold)
                }
                .fullScreenCover(item: $documentationCall) { call in
                    BillingDocumentsView(
                        initialServiceCall: call,
                        openCloseoutOnAppear: openDocumentationInCloseout,
                        openTapToPayOnAppear: openDocumentationInTapToPay,
                        showsDismissButton: true,
                        dismissButtonTitle: "Minimize"
                    )
                    .tint(Color.brandGold)
                    .onDisappear {
                        openDocumentationInCloseout = false
                        openDocumentationInTapToPay = false
                    }
                }
                .confirmationDialog(
                    "Delete this calendar event?",
                    isPresented: Binding(
                        get: { deleteConfirmationCall != nil },
                        set: { if !$0 { deleteConfirmationCall = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("Delete Event", role: .destructive) {
                        if let call = deleteConfirmationCall {
                            deleteCall(call)
                        }
                        deleteConfirmationCall = nil
                    }
                    Button("Cancel", role: .cancel) {
                        deleteConfirmationCall = nil
                    }
                } message: {
                    Text("This removes the event from the app. If it came from Google Calendar, sync will remember not to import it again.")
                }
            }
        }
    }

    private func applyPendingScheduleIntentIfNeeded() {
        guard let pendingID = GunnAireAppIntentRouter.consumePendingScheduleCallID(),
              let call = callsForSignedInUser.first(where: { $0.id == pendingID }) ?? serviceCalls.first(where: { $0.id == pendingID }) else {
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedDate = Calendar.current.startOfDay(for: call.scheduledDate)
            navigationPath = NavigationPath()
            navigationPath.append(call)
        }
    }

    @ViewBuilder
    private var snapshotSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("Upcoming Snapshot")
                Spacer()
                if !upcomingJobs.isEmpty {
                    Text("\(upcomingJobs.count) this week")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if snapshotCalls.isEmpty {
                Text("No upcoming jobs scheduled.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshotCalls) { job in
                    Button {
                        selectedDate = Calendar.current.startOfDay(for: job.scheduledDate)
                        navigationPath.append(job)
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(displayTitle(for: job))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(displaySubtitle(for: job))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(job.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    if job.id != snapshotCalls.last?.id {
                        Divider()
                    }
                }
            }

            if !followUpCalls.isEmpty {
                Divider()
                Text("Follow-Up Queue")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.brandGold)

                ForEach(followUpCalls.prefix(3)) { job in
                    Button {
                        selectedDate = Calendar.current.startOfDay(for: job.scheduledDate)
                        navigationPath.append(job)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(displayTitle(for: job))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(followUpReason(for: job))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(job.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            if job.followUpRequired || job.type == .estimate {
                                HStack(spacing: 10) {
                                    Button("Schedule Follow-Up Visit") {
                                        scheduleFollowUpVisit(for: job)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(Color.brandGold)

                                    if let followUpEmailURL = followUpEmailURL(for: job) {
                                        Button("Email Customer") {
                                            openFollowUpEmail(for: job, fallbackURL: followUpEmailURL)
                                            if !job.followUpRequired {
                                                job.followUpRequired = true
                                            }
                                            if job.followUpAction?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                                                job.followUpAction = "Customer follow-up"
                                            }
                                            if job.followUpDueDate == nil {
                                                job.followUpDueDate = Calendar.current.date(byAdding: .day, value: 3, to: Date())
                                            }
                                        }
                                        .buttonStyle(.bordered)
                                        .tint(Color.brandGold)
                                    }
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            if !maintenanceAttentionContracts.isEmpty {
                Divider()
                Text("Maintenance Attention")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.brandGold)

                ForEach(maintenanceAttentionContracts.prefix(3)) { contract in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(contract.customer.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(maintenanceReason(for: contract))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(contract.nextDate.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Button("Schedule Maintenance Visit") {
                            scheduleMaintenanceVisit(for: contract)
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.brandGold)

                        if let maintenanceReminderEmailURL = maintenanceReminderEmailURL(for: contract) {
                            Button("Send Reminder") {
                                openMaintenanceReminderEmail(for: contract, fallbackURL: maintenanceReminderEmailURL)
                                contract.active = true
                            }
                            .buttonStyle(.bordered)
                            .tint(Color.brandGold)
                        }
                    }
                }
            }

            if isAdminUser && !approvedEstimateCalls.isEmpty {
                Divider()
                Text("Approved Work")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.brandGold)

                ForEach(approvedEstimateCalls.prefix(3)) { job in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(displayTitle(for: job))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("Estimate approved and ready to schedule")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(job.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Button("Schedule Approved Work") {
                            scheduleApprovedWork(for: job)
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.brandGold)
                    }
                }
            }

            if !unassignedUpcomingCalls.isEmpty {
                Divider()
                Text("Unassigned Work")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.brandGold)

                ForEach(unassignedUpcomingCalls.prefix(3)) { job in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(displayTitle(for: job))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(displaySubtitle(for: job))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(job.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if let signedInTechnician {
                            Button("Assign To Me") {
                                assign(job, to: signedInTechnician)
                            }
                            .buttonStyle(.bordered)
                            .tint(Color.brandGold)
                        }

                        if !assignableTechnicians.isEmpty {
                            Menu {
                                ForEach(assignableTechnicians) { technician in
                                    if let nextAvailableStart = nextAvailableStart(for: technician, proposedStart: job.scheduledDate, duration: job.duration),
                                       nextAvailableStart > job.scheduledDate {
                                        Button("\(AppAccess.scheduleLabel(for: technician)) • move to \(nextAvailableStart.formatted(date: .omitted, time: .shortened))") {
                                            assign(job, to: technician, reschedulingTo: nextAvailableStart)
                                        }
                                    } else {
                                        Button(AppAccess.scheduleLabel(for: technician)) {
                                            assign(job, to: technician)
                                        }
                                    }
                                }
                            } label: {
                                Label("Assign Technician", systemImage: "person.crop.circle.badge.plus")
                            }
                            .tint(Color.brandGold)
                        }
                    }
                }
            }

            if isAdminUser && !readyToInvoiceCalls.isEmpty {
                Divider()
                Text("Ready To Bill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.brandGold)

                ForEach(readyToInvoiceCalls.prefix(3)) { job in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(displayTitle(for: job))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(displaySubtitle(for: job))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(job.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Button("Open Invoice Builder") {
                            openDocumentationInCloseout = false
                            openDocumentationInTapToPay = false
                            documentationCall = job
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.brandGold)
                    }
                }
            }

            if isAdminUser && !needsCloseoutCalls.isEmpty {
                Divider()
                Text("Needs Closeout")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.brandGold)

                ForEach(needsCloseoutCalls.prefix(3)) { job in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(displayTitle(for: job))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(closeoutReason(for: job))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(job.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Button("Open Closeout") {
                            openDocumentationInCloseout = true
                            openDocumentationInTapToPay = false
                            documentationCall = job
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.brandGold)
                    }
                }
            }

            if isAdminUser && !quickBooksAttentionPayments.isEmpty {
                Divider()
                Text("QuickBooks Attention")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.brandGold)

                ForEach(quickBooksAttentionPayments.prefix(3)) { payment in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(payment.invoice.customer.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(payment.quickBooksAccountingSyncDetail ?? "QuickBooks payment sync needs attention")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Text(payment.amount, format: .currency(code: "USD"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Button("Open Payments") {
                            GunnAireAppIntentRouter.storePaymentCollectionRoute(payment.invoice.id)
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.brandGold)
                    }
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private func serviceCallCard(for call: ServiceCall) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                NavigationLink(value: call) {
                    serviceCallSummary(for: call)
                }
                .buttonStyle(.plain)

                Button {
                    editingCall = call
                } label: {
                    Image(systemName: "square.and.pencil")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Edit schedule")

                Button(role: .destructive) {
                    deleteConfirmationCall = call
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .accessibilityLabel("Delete calendar event")
            }

            HStack(spacing: 10) {
                Button(CustomerDataMaintenance.isSystemCalendarCustomer(call.customer) ? "Assign Customer" : "Customer") {
                    if CustomerDataMaintenance.isSystemCalendarCustomer(call.customer) {
                        editingCall = call
                    } else {
                        GunnAireAppIntentRouter.storeCustomerRoute(call.customer.id)
                    }
                }
                .buttonStyle(.bordered)

                if hasNavigableAddress(for: call) {
                    Button("Navigate") {
                        openMaps(for: call)
                    }
                    .buttonStyle(.bordered)
                }

                if isAdminUser {
                    Button(documentationActionTitle(for: call, compact: true)) {
                        openDocumentationInCloseout = false
                        openDocumentationInTapToPay = false
                        documentationCall = call
                    }
                    .buttonStyle(.bordered)
                }

                if call.assignedTechnician == nil, let signedInTechnician {
                    Button("Assign To Me") {
                        assign(call, to: signedInTechnician)
                    }
                    .buttonStyle(.bordered)
                } else if isAdminUser && call.linkedInvoiceID == nil && (call.workCompletedChecklist || call.documentationChecklist || call.status == .completed) {
                    Button("Invoice") {
                        openDocumentationInCloseout = false
                        openDocumentationInTapToPay = false
                        documentationCall = call
                    }
                    .buttonStyle(.bordered)
                } else if isAdminUser, let invoice = invoice(for: call), !isInvoicePaid(invoice) {
                    Button(tapToPayReady ? "Pay" : "Collect") {
                        openDocumentationInCloseout = true
                        openDocumentationInTapToPay = tapToPayReady
                        documentationCall = call
                    }
                    .buttonStyle(.bordered)
                }
            }
            .font(.caption.weight(.semibold))
            .tint(Color.brandGold)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private func serviceCallSummary(for call: ServiceCall) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayTitle(for: call))
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text(displaySubtitle(for: call))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Color.brandGold)
                }
                Spacer()
                Text(call.scheduledDate.formatted(date: .omitted, time: .shortened))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(call.status.rawValue.capitalized)
                .font(.caption)
                .foregroundColor(.gray)
            if let address = call.siteAddress ?? call.customer.address,
               !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(address)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                if let technician = call.assignedTechnician {
                    Label(technician.name, systemImage: "person.fill")
                } else {
                    Label("Unassigned", systemImage: "person.slash")
                }
                if call.googleEventID != nil {
                    Label("Google", systemImage: "calendar.badge.checkmark")
                }
                if call.documentationStartedAt != nil {
                    Label("Started", systemImage: "doc.text")
                }
                if isAdminUser && call.linkedInvoiceID == nil && (call.workCompletedChecklist || call.documentationChecklist || call.status == .completed) {
                    Label("Ready to Bill", systemImage: "doc.badge.plus")
                }
                if isAdminUser, let invoice = invoice(for: call), invoice.finalizedAt == nil || invoice.customerSignedAt == nil {
                    Label("Closeout", systemImage: "signature")
                }
                if call.followUpRequired {
                    Label("Follow-Up", systemImage: "arrow.uturn.forward.circle.fill")
                }
                if isAdminUser, let estimate = estimate(for: call) {
                    Label(estimate.status.capitalized, systemImage: "list.clipboard.fill")
                }
                if isAdminUser, let invoice = invoice(for: call) {
                    Label(invoice.status.capitalized, systemImage: isInvoicePaid(invoice) ? "checkmark.circle.fill" : "creditcard.fill")
                }
                if isAdminUser && isCollectionOverdue(for: call) {
                    Label("Overdue", systemImage: "exclamationmark.triangle.fill")
                }
                if isAdminUser, let balanceDue = balanceDue(for: call), balanceDue > 0 {
                    Text("Due \(balanceDue, format: .currency(code: "USD"))")
                } else if isAdminUser && call.linkedInvoiceID != nil {
                    Text("Paid")
                }
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        }
    }

    private func documentationActionTitle(for call: ServiceCall, compact: Bool) -> String {
        let hasDocumentation = call.linkedEstimateID != nil || call.linkedInvoiceID != nil || call.documentationStartedAt != nil
        switch call.type {
        case .estimate:
            return hasDocumentation ? (compact ? "Estimate" : "Continue Estimate") : "Start Estimate"
        case .install, .maintenance, .service, .meeting, .reminder, .siteVisit, .other:
            if call.linkedInvoiceID != nil {
                return compact ? "Invoice" : "Continue Invoice"
            }
            return hasDocumentation ? (compact ? "Docs" : "Continue Documentation") : "Start Docs"
        }
    }

    private func displayTitle(for call: ServiceCall) -> String {
        if let eventTitle = call.eventTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !eventTitle.isEmpty {
            if !GoogleCalendarScheduleSync.isGeneratedCalendarTitle(eventTitle) {
                return eventTitle
            }
            if let originalCalendarTitle = GoogleCalendarScheduleSync.calendarEventSummary(from: call.notes) {
                return originalCalendarTitle
            }
            if let noteTitle = firstMeaningfulNoteLine(from: call.notes),
               CustomerDataMaintenance.isSystemCalendarCustomer(call.customer) {
                return noteTitle
            }
            return eventTitle
        }
        if let originalCalendarTitle = GoogleCalendarScheduleSync.calendarEventSummary(from: call.notes) {
            return originalCalendarTitle
        }
        if let noteTitle = firstMeaningfulNoteLine(from: call.notes),
           CustomerDataMaintenance.isSystemCalendarCustomer(call.customer) {
            return noteTitle
        }
        guard CustomerDataMaintenance.isSystemCalendarCustomer(call.customer) else {
            return call.customer.name
        }
        return "Unassigned calendar event"
    }

    private func displaySubtitle(for call: ServiceCall) -> String {
        if CustomerDataMaintenance.isSystemCalendarCustomer(call.customer) {
            return "Unassigned customer • \(call.type.displayName)"
        }
        if call.eventTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return "\(call.customer.name) • \(call.type.displayName)"
        }
        return call.type.displayName
    }

    private func firstMeaningfulNoteLine(from notes: String?) -> String? {
        guard let notes else { return nil }
        return notes
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !$0.localizedCaseInsensitiveContains("Calendar event:") }
    }
    
    private func deleteCalls(offsets: IndexSet) {
        withAnimation {
            for index in offsets.sorted(by: >) {
                deleteCall(selectedDayCalls[index])
            }
        }
    }

    private func deleteCall(_ call: ServiceCall) {
        GoogleCalendarScheduleSync.markCalendarEventDeleted(calendarID: call.googleCalendarID, eventID: call.googleEventID)

        let calendarID = call.googleCalendarID
        let eventID = call.googleEventID
        modelContext.delete(call)
        try? modelContext.save()
        syncMessage = "Event deleted from the app."

        guard googleAuth.isAuthenticated,
              let eventID,
              !eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        googleAuth.deleteCalendarEvent(calendarID: calendarID ?? "primary", eventID: eventID) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    syncMessage = "Event deleted from the app and Google Calendar."
                case .failure(let error):
                    syncMessage = "Event deleted from the app. Google Calendar did not delete it: \(error.localizedDescription)"
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(Color.brandGold)
    }

    private var emptyDayState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No events for this date.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text("Choose another date on the calendar or add a new service call.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func syncGoogleCalendar() {
        guard googleAuth.isAuthenticated else {
            syncMessage = "Sign in with Google first."
            return
        }
        isSyncingGoogleCalendar = true
        syncMessage = "Syncing Google Calendar..."
        let signedInEmail = googleAuth.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail")
        GoogleCalendarScheduleSync.sync(
            auth: googleAuth,
            modelContext: modelContext,
            signedInEmail: signedInEmail
            ,
            isAdminUser: isAdminUser
        ) { result in
            DispatchQueue.main.async {
                isSyncingGoogleCalendar = false
                switch result {
                case .success(let message):
                    syncMessage = message
                case .failure(let error):
                    let detail = error.localizedDescription
                    if detail.localizedCaseInsensitiveContains("insufficient") ||
                        detail.localizedCaseInsensitiveContains("scope") ||
                        detail.localizedCaseInsensitiveContains("forbidden") {
                        syncMessage = "Google Calendar sync failed: \(detail) Disconnect Google in Settings and reconnect it so the app can request calendar permission."
                    } else {
                        syncMessage = "Google Calendar sync failed: \(detail)"
                    }
                }
            }
        }
    }

    private func openMaps(for call: ServiceCall) {
        let address = (call.siteAddress ?? call.customer.address)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let address, !address.isEmpty else { return }
        var components = URLComponents(string: "http://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: address)]
        if let url = components?.url {
            openURL(url)
        }
    }

    private func hasNavigableAddress(for call: ServiceCall) -> Bool {
        let address = (call.siteAddress ?? call.customer.address)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !(address?.isEmpty ?? true)
    }

    private func invoice(for call: ServiceCall) -> Invoice? {
        guard let invoiceID = call.linkedInvoiceID else { return nil }
        return invoices.first { $0.id == invoiceID }
    }

    private func estimate(for call: ServiceCall) -> Estimate? {
        guard let estimateID = call.linkedEstimateID else { return nil }
        return estimates.first { $0.id == estimateID }
    }

    private func balanceDue(for call: ServiceCall) -> Double? {
        guard let invoice = invoice(for: call) else { return nil }
        if isInvoicePaid(invoice) {
            return 0
        }
        let paid = payments
            .filter { $0.invoice.id == invoice.id }
            .reduce(0) { partial, payment in
                partial + payment.amount
            }
        return max(invoice.amount - paid, 0)
    }

    private func isInvoicePaid(_ invoice: Invoice) -> Bool {
        invoice.status.caseInsensitiveCompare("paid") == .orderedSame
    }

    private func isCollectionOverdue(for call: ServiceCall) -> Bool {
        guard let invoice = invoice(for: call),
              let due = balanceDue(for: call),
              due > 0,
              let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) else { return false }
        return invoice.createdAt < cutoff
    }

    private func followUpReason(for call: ServiceCall) -> String {
        if isCollectionOverdue(for: call) {
            return "Overdue payment follow-up"
        }
        if call.followUpRequired,
           let followUpAction = call.followUpAction?.trimmingCharacters(in: .whitespacesAndNewlines),
           !followUpAction.isEmpty {
            if let dueDate = call.followUpDueDate {
                return "\(followUpAction) • due \(dueDate.formatted(date: .abbreviated, time: .omitted))"
            }
            return followUpAction
        }
        if call.type == .estimate && call.linkedInvoiceID == nil {
            return "Estimate waiting on approval"
        }
        if call.followUpRequired {
            return "Technician follow-up required"
        }
        return "Needs attention"
    }

    private func closeoutReason(for call: ServiceCall) -> String {
        guard let invoice = invoice(for: call) else { return "Invoice needs closeout" }
        if invoice.customerSignedAt == nil && invoice.finalizedAt == nil {
            return "Signature and finalization missing"
        }
        if invoice.customerSignedAt == nil {
            return "Customer signature missing"
        }
        if invoice.finalizedAt == nil {
            return "Invoice finalization missing"
        }
        return "Invoice needs closeout"
    }

    private func maintenanceReason(for contract: RecurringMaintenanceContract) -> String {
        if contract.isOverdue {
            return "Maintenance visit overdue"
        }
        if contract.needsReminder {
            return "Reminder window open"
        }
        return "\(contract.schedulePattern) maintenance due soon"
    }

    private func followUpEmailURL(for call: ServiceCall) -> URL? {
        guard let draft = followUpEmailDraft(for: call) else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = draft.to
        components.queryItems = [
            URLQueryItem(name: "subject", value: draft.subject),
            URLQueryItem(name: "body", value: draft.body)
        ]
        return components.url
    }

    private func followUpEmailDraft(for call: ServiceCall) -> (to: String, subject: String, body: String)? {
        guard let email = call.customer.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else { return nil }
        let trimmedFollowUpAction = call.followUpAction?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let followUpMessage = (trimmedFollowUpAction?.isEmpty == false)
            ? trimmedFollowUpAction!
            : "Please let us know if you would like to move forward or if you have any questions."
        return (
            to: email,
            subject: "Follow-Up From GunnAire",
            body: """
Hello \(call.customer.name),

Following up on your recent \(call.type.rawValue) appointment with GunnAire.

\(followUpMessage)

Thank you,
GunnAire
"""
        )
    }

    private func maintenanceReminderEmailURL(for contract: RecurringMaintenanceContract) -> URL? {
        guard let draft = maintenanceReminderEmailDraft(for: contract) else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = draft.to
        components.queryItems = [
            URLQueryItem(name: "subject", value: draft.subject),
            URLQueryItem(name: "body", value: draft.body)
        ]
        return components.url
    }

    private func maintenanceReminderEmailDraft(for contract: RecurringMaintenanceContract) -> (to: String, subject: String, body: String)? {
        guard let email = contract.customer.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else { return nil }
        return (
            to: email,
            subject: "Maintenance Reminder From GunnAire",
            body: """
Hello \(contract.customer.name),

This is a reminder that your \(contract.schedulePattern) maintenance visit is due on \(contract.nextDate.formatted(date: .abbreviated, time: .omitted)).

Reply to this email if you would like us to schedule your visit.

Thank you,
GunnAire
"""
        )
    }

    private func openFollowUpEmail(for call: ServiceCall, fallbackURL: URL) {
        if googleAuth.isAuthenticated, let draft = followUpEmailDraft(for: call) {
            GunnAireAppIntentRouter.storeMailDraftRoute(to: draft.to, subject: draft.subject, body: draft.body)
        } else {
            openURL(fallbackURL)
        }
    }

    private func openMaintenanceReminderEmail(for contract: RecurringMaintenanceContract, fallbackURL: URL) {
        if googleAuth.isAuthenticated, let draft = maintenanceReminderEmailDraft(for: contract) {
            GunnAireAppIntentRouter.storeMailDraftRoute(to: draft.to, subject: draft.subject, body: draft.body)
        } else {
            openURL(fallbackURL)
        }
    }

    private func scheduleMaintenanceVisit(for contract: RecurringMaintenanceContract) {
        let serviceAddress = contract.customer.address?.trimmingCharacters(in: .whitespacesAndNewlines)
        let call = ServiceCall(
            siteAddress: serviceAddress?.isEmpty == false ? serviceAddress : nil,
            type: .maintenance,
            scheduledDate: contract.nextDate,
            duration: 90 * 60,
            customer: contract.customer,
            status: .scheduled,
            notes: "Scheduled from maintenance agreement: \(contract.schedulePattern)",
            followUpRequired: false
        )
        modelContext.insert(call)
        contract.advanceNextDate()
        selectedDate = Calendar.current.startOfDay(for: call.scheduledDate)
        navigationPath.append(call)
    }

    private func scheduleFollowUpVisit(for sourceCall: ServiceCall) {
        let scheduledDate = sourceCall.followUpDueDate ?? Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let notesPrefix = sourceCall.followUpAction?.trimmingCharacters(in: .whitespacesAndNewlines)
        let generatedNotes = [notesPrefix, sourceCall.notes]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: "\n\n")

        let followUpCall = ServiceCall(
            siteAddress: sourceCall.siteAddress ?? sourceCall.customer.address,
            equipmentName: sourceCall.equipmentName,
            equipmentModel: sourceCall.equipmentModel,
            equipmentSerialNumber: sourceCall.equipmentSerialNumber,
            equipmentWarrantyExpiration: sourceCall.equipmentWarrantyExpiration,
            type: sourceCall.type,
            scheduledDate: scheduledDate,
            duration: sourceCall.duration,
            assignedTechnician: sourceCall.assignedTechnician,
            customer: sourceCall.customer,
            status: .scheduled,
            notes: generatedNotes.isEmpty ? "Scheduled follow-up visit" : "Scheduled follow-up visit\n\n\(generatedNotes)",
            findingsSummary: sourceCall.findingsSummary,
            recommendedWorkSummary: sourceCall.recommendedWorkSummary,
            followUpRequired: false
        )
        modelContext.insert(followUpCall)
        sourceCall.followUpRequired = false
        sourceCall.followUpAction = nil
        sourceCall.followUpDueDate = nil
        selectedDate = Calendar.current.startOfDay(for: followUpCall.scheduledDate)
        navigationPath.append(followUpCall)
    }

    private func scheduleApprovedWork(for sourceCall: ServiceCall) {
        let scheduledDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let generatedNotes = [sourceCall.recommendedWorkSummary, sourceCall.notes]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: "\n\n")

        let approvedWorkCall = ServiceCall(
            siteAddress: sourceCall.siteAddress ?? sourceCall.customer.address,
            equipmentName: sourceCall.equipmentName,
            equipmentModel: sourceCall.equipmentModel,
            equipmentSerialNumber: sourceCall.equipmentSerialNumber,
            equipmentWarrantyExpiration: sourceCall.equipmentWarrantyExpiration,
            type: sourceCall.type == .estimate ? .install : sourceCall.type,
            scheduledDate: scheduledDate,
            duration: sourceCall.duration,
            assignedTechnician: sourceCall.assignedTechnician,
            customer: sourceCall.customer,
            status: .scheduled,
            notes: generatedNotes.isEmpty ? "Scheduled from approved estimate" : "Scheduled from approved estimate\n\n\(generatedNotes)",
            findingsSummary: sourceCall.findingsSummary,
            recommendedWorkSummary: sourceCall.recommendedWorkSummary,
            followUpRequired: false
        )
        modelContext.insert(approvedWorkCall)
        sourceCall.followUpRequired = false
        sourceCall.followUpAction = nil
        sourceCall.followUpDueDate = nil
        selectedDate = Calendar.current.startOfDay(for: approvedWorkCall.scheduledDate)
        navigationPath.append(approvedWorkCall)
    }

    private func assign(_ call: ServiceCall, to technician: Technician) {
        call.assignedTechnician = technician
        call.googleCalendarID = ServiceCalendarRouting.assignedCalendarID(for: technician)
        call.googleEventID = nil
    }

    private func assign(_ call: ServiceCall, to technician: Technician, reschedulingTo newStart: Date) {
        call.assignedTechnician = technician
        call.googleCalendarID = ServiceCalendarRouting.assignedCalendarID(for: technician)
        call.googleEventID = nil
        call.scheduledDate = newStart
    }

    private func nextAvailableStart(for technician: Technician, proposedStart: Date, duration: TimeInterval) -> Date? {
        let proposedEnd = proposedStart.addingTimeInterval(duration)
        let conflicts = serviceCalls
            .filter { call in
                guard call.assignedTechnician?.id == technician.id, call.status != .cancelled else { return false }
                let existingStart = call.scheduledDate
                let existingEnd = call.scheduledDate.addingTimeInterval(call.duration)
                return proposedStart < existingEnd && proposedEnd > existingStart
            }
            .sorted { $0.scheduledDate < $1.scheduledDate }

        guard !conflicts.isEmpty else { return proposedStart }
        return conflicts
            .map { $0.scheduledDate.addingTimeInterval($0.duration) }
            .max()
    }

}

#Preview {
    ScheduleView()
}
