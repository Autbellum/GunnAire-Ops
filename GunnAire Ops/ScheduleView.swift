import SwiftUI
import SwiftData

struct ScheduleView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\ServiceCall.scheduledDate)]) private var serviceCalls: [ServiceCall]
    @Query(sort: \Technician.name, order: .forward) private var technicians: [Technician]
    @Query(sort: \TechnicianAvailabilityBlock.startsAt, order: .forward) private var technicianAvailabilityBlocks: [TechnicianAvailabilityBlock]
    @Query private var recurringContracts: [RecurringMaintenanceContract]
    @Query(sort: \Estimate.createdAt, order: .reverse) private var estimates: [Estimate]
    @Query(sort: \Invoice.createdAt, order: .reverse) private var invoices: [Invoice]
    @Query(sort: \Payment.date, order: .reverse) private var payments: [Payment]
    @Query(sort: \ServiceDocumentAttachment.createdAt, order: .reverse) private var attachments: [ServiceDocumentAttachment]
    @Query(sort: \FieldFormTemplate.createdAt, order: .forward) private var fieldFormTemplates: [FieldFormTemplate]
    @Query(sort: \FieldFormResponse.completedAt, order: .reverse) private var fieldFormResponses: [FieldFormResponse]
    @Query(sort: \TimeEntry.clockIn, order: .reverse) private var timeEntries: [TimeEntry]
    @Query(sort: \Item.name, order: .forward) private var items: [Item]
    @Query(sort: \InventoryMovement.createdAt, order: .reverse) private var inventoryMovements: [InventoryMovement]
    @Query(sort: \ProjectMilestone.plannedDate, order: .forward) private var projectMilestones: [ProjectMilestone]
    @Query(sort: \CustomerEquipment.name, order: .forward) private var equipmentProfiles: [CustomerEquipment]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @Query(sort: \ServiceRequest.createdAt, order: .forward) private var serviceRequests: [ServiceRequest]
    @Query(sort: \Customer.name, order: .forward) private var customers: [Customer]
    @Query(sort: \CustomerServiceLocation.name, order: .forward) private var serviceLocations: [CustomerServiceLocation]
    @Query(sort: \CustomerCommunication.createdAt, order: .reverse) private var customerCommunications: [CustomerCommunication]
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
    @State private var jobSearchText = ""
    @State private var showingNewRequestSheet = false
    @State private var showingAvailabilityBlocks = false
    @State private var showingDispatchWeekBoard = false
    @State private var showingWorkQueue = false
    @State private var requestForQualification: ServiceRequest?
    @State private var requestForDecline: ServiceRequest?
    @State private var requestMessage: String?
    @State private var maintenanceMessage: String?
    @State private var approvedWorkMessage: String?
    @State private var selectedEstimateForScheduling: Estimate?
    @State private var isImportingOnlineRequests = false

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
        guard let nextFieldRouteCall else {
            return Array(upcomingJobs.prefix(3))
        }
        return Array(
            ([nextFieldRouteCall] + upcomingJobs.filter { $0.id != nextFieldRouteCall.id })
                .prefix(3)
        )
    }

    private var searchedJobs: [ServiceCall] {
        let query = jobSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return callsForSignedInUser
            .filter { $0.matchesOperationalSearch(query) }
            .sorted { lhs, rhs in
                let lhsOpen = lhs.status != .completed && lhs.status != .cancelled
                let rhsOpen = rhs.status != .completed && rhs.status != .cancelled
                if lhsOpen != rhsOpen { return lhsOpen && !rhsOpen }
                return lhs.scheduledDate > rhs.scheduledDate
            }
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
                return estimate.status == "accepted" &&
                    call.linkedInvoiceID == nil &&
                    ApprovedEstimateScheduling.existingWorkOrder(for: estimate, in: serviceCalls) == nil
            }
            .sorted { $0.scheduledDate > $1.scheduledDate }
    }

    private var signedInTechnician: Technician? {
        guard let email = AppIdentity.currentEmail else {
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
        return AppAccess.visibleUnassignedServiceCalls(
            email: AppIdentity.currentEmail,
            users: users,
            serviceCalls: serviceCalls,
            technicians: technicians
        )
            .filter { call in
                call.status != .cancelled &&
                call.scheduledDate >= now &&
                call.scheduledDate <= sevenDaysAhead
            }
            .sorted {
                if $0.dispatchUrgency.dispatchSortRank != $1.dispatchUrgency.dispatchSortRank {
                    return $0.dispatchUrgency.dispatchSortRank < $1.dispatchUrgency.dispatchSortRank
                }
                return $0.scheduledDate < $1.scheduledDate
            }
    }

    private var readyToInvoiceCalls: [ServiceCall] {
        callsForSignedInUser
            .filter(\.isReadyToCreateBillingDocument)
            .sorted { $0.scheduledDate > $1.scheduledDate }
    }

    private var needsCloseoutCalls: [ServiceCall] {
        callsForSignedInUser
            .filter { call in
                guard let invoice = invoice(for: call) else { return false }
                return !closeoutReadiness(for: call, invoice: invoice).isReady
            }
            .sorted { $0.scheduledDate > $1.scheduledDate }
    }

    private var openServiceRequests: [ServiceRequest] {
        ServiceRequestPipelinePolicy.sortedOpenRequests(serviceRequests)
    }

    private var quickBooksAttentionPayments: [Payment] {
        payments
            .filter { payment in
                payment.needsQuickBooksAttention &&
                callsForSignedInUser.contains { $0.linkedInvoiceID == payment.invoice.id }
            }
            .sorted { $0.date > $1.date }
    }

    private var workQueueSummary: ScheduleWorkQueueSummary {
        ScheduleWorkQueueSummary(itemCounts: [
            followUpCalls.count,
            maintenanceAttentionContracts.count,
            canManageDispatch ? approvedEstimateCalls.count : 0,
            unassignedUpcomingCalls.count,
            isAdminUser ? readyToInvoiceCalls.count : 0,
            isAdminUser ? needsCloseoutCalls.count : 0,
            isAdminUser ? quickBooksAttentionPayments.count : 0
        ])
    }

    private var callsForSignedInUser: [ServiceCall] {
        let email = AppIdentity.currentEmail
        let visibleIDs = AppAccess.visibleServiceCallIDs(email: email, users: users, serviceCalls: serviceCalls, technicians: technicians)
        return serviceCalls.filter { visibleIDs.contains($0.id) }
    }

    private var nextFieldRouteCall: ServiceCall? {
        guard AppAccess.activeRole(email: AppIdentity.currentEmail, users: users) == .fieldTechnician else {
            return nil
        }
        return TechnicianRoutePolicy.nextNavigableStop(from: callsForSignedInUser)
    }

    var activeRecurringContracts: [RecurringMaintenanceContract] {
        let now = Date()
        return recurringContracts.filter { $0.nextDate >= now }
    }

    private var maintenanceAttentionContracts: [RecurringMaintenanceContract] {
        guard canManageDispatch else { return [] }
        return recurringContracts
            .filter { $0.active && ($0.isOverdue || $0.isUpcoming || $0.needsReminder || $0.needsRenewalAttention || $0.isExpired) }
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
        let email = AppIdentity.currentEmail
        return AppAccess.isAdmin(email: email, users: users)
    }

    private var canManageDispatch: Bool {
        let email = AppIdentity.currentEmail
        return AppAccess.canManageDispatch(email: email, users: users)
    }

    private var canCollectFieldPayments: Bool {
        let email = AppIdentity.currentEmail
        return AppAccess.canCollectFieldPayments(email: email, users: users)
    }

    var body: some View {
        ZStack {
            WatermarkBackground()
            NavigationStack(path: $navigationPath) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        snapshotSection

                        jobSearchSection

                        if canManageDispatch {
                            serviceRequestsSection
                        }

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
                                    if canManageDispatch {
                                        ForEach(selectedDayCalls) { call in
                                            selectedDayCallRow(for: call)
                                        }
                                        .onDelete(perform: deleteCalls)
                                    } else {
                                        ForEach(selectedDayCalls) { call in
                                            selectedDayCallRow(for: call)
                                        }
                                    }
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
                            if canManageDispatch {
                                Button {
                                    showingDispatchWeekBoard = true
                                } label: {
                                    Label("Week Board", systemImage: "rectangle.split.3x1")
                                }
                                .tint(Color.brandGold)
                                .accessibilityIdentifier("DispatchWeekBoard")

                                Button {
                                    showingAvailabilityBlocks = true
                                } label: {
                                    Label("Availability", systemImage: "person.badge.clock")
                                }
                                .tint(Color.brandGold)
                                .accessibilityIdentifier("ManageTechnicianAvailability")

                                Button {
                                    showingAddCallSheet = true
                                } label: {
                                    Label("Add Call", systemImage: "plus")
                                        .bold()
                                }
                                .tint(Color.brandGold)
                                .accessibilityIdentifier("AddServiceCall")

                                Button {
                                    syncGoogleCalendar()
                                } label: {
                                    Label(isSyncingGoogleCalendar ? "Syncing..." : "Sync Google", systemImage: "arrow.triangle.2.circlepath")
                                        .bold()
                                }
                                .disabled(isSyncingGoogleCalendar || !googleAuth.isAuthenticated)
                                .tint(Color.brandGold)
                                .accessibilityIdentifier("SyncGoogleCalendar")
                            }
                        }
                    }
                    ToolbarItem(placement: .navigationBarLeading) {
                        if canManageDispatch {
                            EditButton()
                                .tint(Color.brandGold)
                                .accessibilityIdentifier("EditScheduleList")
                        }
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
                .onChange(of: canManageDispatch) { _, isAllowed in
                    guard !isAllowed else { return }
                    showingAddCallSheet = false
                    editingCall = nil
                    deleteConfirmationCall = nil
                    showingNewRequestSheet = false
                    requestForQualification = nil
                    requestForDecline = nil
                    showingAvailabilityBlocks = false
                    showingDispatchWeekBoard = false
                    selectedEstimateForScheduling = nil
                }
                .sheet(isPresented: $showingAddCallSheet) {
                    if canManageDispatch {
                        AddServiceCallView(selectedDate: selectedDate) { createdCall in
                            openDocumentationInCloseout = false
                            openDocumentationInTapToPay = false
                            documentationCall = createdCall
                        }
                            .tint(Color.brandGold)
                    } else {
                        dispatchAccessRequiredView
                    }
                }
                .sheet(isPresented: $showingNewRequestSheet) {
                    if canManageDispatch {
                        NewServiceRequestView { request in
                            guard canManageDispatch else {
                                requestMessage = "Dispatcher or administrator access is required to create requests."
                                return
                            }
                            modelContext.insert(request)
                            try? modelContext.save()
                            requestMessage = "Request saved. Qualify it, then schedule without changing a committed appointment."
                        }
                        .tint(Color.brandGold)
                    } else {
                        dispatchAccessRequiredView
                    }
                }
                .sheet(item: $requestForQualification) { request in
                    if canManageDispatch {
                        ServiceRequestQualificationSheet(request: request) { source, sourceDetail, notes, nextFollowUpAt in
                            saveQualification(
                                for: request,
                                source: source,
                                sourceDetail: sourceDetail,
                                notes: notes,
                                nextFollowUpAt: nextFollowUpAt
                            )
                        }
                        .tint(Color.brandGold)
                    } else {
                        dispatchAccessRequiredView
                    }
                }
                .sheet(item: $requestForDecline) { request in
                    if canManageDispatch {
                        ServiceRequestDeclineSheet(request: request) { reason, notes in
                            decline(request, reason: reason, notes: notes)
                        }
                        .tint(Color.brandGold)
                    } else {
                        dispatchAccessRequiredView
                    }
                }
                .sheet(isPresented: $showingAvailabilityBlocks) {
                    if canManageDispatch {
                        TechnicianAvailabilityView()
                            .tint(Color.brandGold)
                    } else {
                        dispatchAccessRequiredView
                    }
                }
                .sheet(item: $selectedEstimateForScheduling) { estimate in
                    if canManageDispatch {
                        ApprovedEstimateSchedulingSheet(
                            estimate: estimate,
                            sourceCall: sourceCall(for: estimate)
                        ) { scheduledDate, duration, workType in
                            createApprovedWorkOrder(
                                for: estimate,
                                scheduledDate: scheduledDate,
                                duration: duration,
                                workType: workType
                            )
                        }
                        .tint(Color.brandGold)
                    } else {
                        dispatchAccessRequiredView
                    }
                }
                .fullScreenCover(isPresented: $showingDispatchWeekBoard) {
                    if canManageDispatch {
                        DispatchWeekBoardView(
                            initialDate: selectedDate,
                            calls: callsForSignedInUser,
                            onMove: { callID, targetDay, overrideReason in
                                moveCallFromDispatchBoard(
                                    callID,
                                    targetDay,
                                    overrideReason: overrideReason
                                )
                            }
                        )
                        .tint(Color.brandGold)
                    } else {
                        dispatchAccessRequiredView
                    }
                }
                .fullScreenCover(item: $editingCall) { call in
                    if canManageDispatch {
                        EditServiceCallView(call: call)
                            .tint(Color.brandGold)
                    } else {
                        dispatchAccessRequiredView
                    }
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
              let call = callsForSignedInUser.first(where: { $0.id == pendingID }) else {
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedDate = Calendar.current.startOfDay(for: call.scheduledDate)
            navigationPath = NavigationPath()
            navigationPath.append(call)
        }
    }

    @ViewBuilder
    private var serviceRequestsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("Incoming Requests")
                Spacer()
                Button {
                    showingNewRequestSheet = true
                } label: {
                    Label("New Request", systemImage: "phone.badge.plus")
                }
                .buttonStyle(.bordered)
                if GunnAireBackendService.isConfigured {
                    Button {
                        importOnlineRequests()
                    } label: {
                        Label(isImportingOnlineRequests ? "Importing..." : "Import Online", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isImportingOnlineRequests)
                }
            }

            if let requestMessage {
                Text(requestMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if openServiceRequests.isEmpty {
                Text("No unqualified service requests. New requests stay here until dispatch confirms the customer and appointment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(openServiceRequests.prefix(5)) { request in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(request.customerName)
                                .font(.headline)
                            Spacer()
                            Text(request.urgency.displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(request.urgency == .emergency ? .red : request.urgency == .priority ? .orange : .secondary)
                        }
                        Text("\(request.requestedServiceType.displayName) • \(request.summary)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Label(request.leadSourceSummary, systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let preferredDate = request.preferredDate {
                            Text("Requested: \(preferredDate.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let nextFollowUpAt = request.nextFollowUpAt {
                            Label(
                                "Follow-up \(nextFollowUpAt.formatted(date: .abbreviated, time: .shortened))",
                                systemImage: request.isFollowUpOverdue() ? "exclamationmark.circle.fill" : "clock"
                            )
                            .font(.caption2.weight(request.isFollowUpOverdue() ? .semibold : .regular))
                            .foregroundStyle(request.isFollowUpOverdue() ? .red : .secondary)
                            .accessibilityIdentifier("ServiceRequestFollowUp-\(request.id.uuidString)")
                        } else if request.status == .qualified {
                            Label("Ready to schedule", systemImage: "checkmark.circle.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.green)
                                .accessibilityIdentifier("ServiceRequestReady-\(request.id.uuidString)")
                        }
                        HStack {
                            Button(request.status == .new ? "Qualify" : "Review") {
                                requestForQualification = request
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("QualifyServiceRequest-\(request.id.uuidString)")

                            Button("Schedule") {
                                schedule(request)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .disabled(!request.canSchedule)
                            .accessibilityIdentifier("ScheduleServiceRequest-\(request.id.uuidString)")

                            Button("Decline", role: .destructive) {
                                requestForDecline = request
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("DeclineServiceRequest-\(request.id.uuidString)")
                        }
                    }
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                if openServiceRequests.count > 5 {
                    Text("\(openServiceRequests.count - 5) more request\(openServiceRequests.count == 6 ? "" : "s") remain in the queue.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func saveQualification(
        for request: ServiceRequest,
        source: ServiceRequestSource,
        sourceDetail: String?,
        notes: String?,
        nextFollowUpAt: Date?
    ) -> String? {
        guard canManageDispatch else {
            return "Dispatcher or administrator access is required to qualify requests."
        }
        let previousStatusRaw = request.statusRaw
        let previousQualificationNotes = request.qualificationNotes
        let previousQualifiedAt = request.qualifiedAt
        let now = Date()
        guard request.recordQualification(
            source: source,
            sourceDetail: sourceDetail,
            notes: notes,
            nextFollowUpAt: nextFollowUpAt,
            actorEmail: AppIdentity.currentEmail,
            at: now
        ) else {
            return "Add the required source detail and choose a future follow-up time."
        }
        do {
            try modelContext.save()
            requestMessage = nextFollowUpAt == nil
                ? "Request qualified and ready to schedule."
                : "Request qualified. The follow-up commitment is now in the queue."
            return nil
        } catch {
            request.statusRaw = previousStatusRaw
            request.qualificationNotes = previousQualificationNotes
            request.qualifiedAt = previousQualifiedAt
            return "Could not save this qualification: \(error.localizedDescription)"
        }
    }

    private func decline(
        _ request: ServiceRequest,
        reason: ServiceRequestLostReason,
        notes: String?
    ) -> String? {
        guard canManageDispatch else {
            return "Dispatcher or administrator access is required to close requests."
        }
        let previousStatusRaw = request.statusRaw
        let previousQualificationNotes = request.qualificationNotes
        guard request.recordDecline(
            reason: reason,
            notes: notes,
            actorEmail: AppIdentity.currentEmail
        ) else {
            return "Choose a reason and add notes when Other is selected."
        }
        do {
            try modelContext.save()
            requestMessage = "Request closed as \(reason.displayName.lowercased()). It remains in the lead history."
            return nil
        } catch {
            request.statusRaw = previousStatusRaw
            request.qualificationNotes = previousQualificationNotes
            return "Could not close this request: \(error.localizedDescription)"
        }
    }

    private func schedule(_ request: ServiceRequest) {
        guard canManageDispatch else {
            requestMessage = "Dispatcher or administrator access is required to schedule requests."
            return
        }
        guard request.canSchedule else {
            requestMessage = "Qualify the request before creating an appointment."
            return
        }
        let customer: Customer
        if let existingCustomer = matchingCustomer(for: request) {
            customer = existingCustomer
        } else {
            customer = Customer(
                name: request.customerName,
                phone: request.phone,
                email: request.email,
                address: request.address
            )
            modelContext.insert(customer)
        }
        let scheduledDate = request.preferredDate ?? defaultRequestScheduleDate()
        let serviceLocation = serviceLocationForScheduledRequest(request, customer: customer)
        var intakeContext = [
            "Request intake: \(request.summary)",
            "Lead source: \(request.leadSourceSummary)"
        ]
        if let qualificationNotes = request.intakeQualificationNotes {
            intakeContext.append("Qualification: \(qualificationNotes)")
        }
        let call = ServiceCall(
            eventTitle: "\(request.requestedServiceType.displayName) request",
            siteAddress: serviceLocation?.address ?? request.address,
            serviceLocationID: serviceLocation?.id,
            type: request.requestedServiceType,
            dispatchUrgency: request.urgency,
            scheduledDate: scheduledDate,
            customer: customer,
            notes: intakeContext.joined(separator: "\n")
        )
        modelContext.insert(call)
        request.markScheduled(customerID: customer.id, serviceCallID: call.id)
        ServiceCallActivity.record(
            for: call,
            action: "Request scheduled",
            detail: "Created from a \(request.leadSource.displayName.lowercased()) \(request.urgency.displayName.lowercased()) service request received \(request.createdAt.formatted(date: .abbreviated, time: .shortened)).",
            actorEmail: AppIdentity.currentEmail,
            in: modelContext
        )
        do {
            try modelContext.save()
            selectedDate = Calendar.current.startOfDay(for: scheduledDate)
            requestMessage = "Scheduled \(request.customerName). Assign a technician from the job card before dispatching."
            claimOnlineRequestIfNeeded(request)
            navigationPath.append(call)
        } catch {
            requestMessage = "Could not schedule this request: \(error.localizedDescription)"
        }
    }

    private func serviceLocationForScheduledRequest(_ request: ServiceRequest, customer: Customer) -> CustomerServiceLocation? {
        if let existing = CustomerServiceLocationPolicy.matchingLocation(
            address: request.address,
            customerID: customer.id,
            in: serviceLocations
        ) {
            return existing
        }
        guard let address = request.address?.trimmingCharacters(in: .whitespacesAndNewlines),
              !address.isEmpty else {
            return CustomerServiceLocationPolicy.preferredLocation(for: customer.id, in: serviceLocations)
        }
        let hasActiveLocation = CustomerServiceLocationPolicy.preferredLocation(for: customer.id, in: serviceLocations) != nil
        let location = CustomerServiceLocation(
            customer: customer,
            name: hasActiveLocation ? "Service Location" : "Primary Service Location",
            address: address,
            isPrimary: !hasActiveLocation
        )
        modelContext.insert(location)
        return location
    }

    private func importOnlineRequests() {
        guard canManageDispatch, GunnAireBackendService.isConfigured else { return }
        isImportingOnlineRequests = true
        Task {
            do {
                let count = try await GunnAireBackendService.importServiceRequests(
                    into: modelContext,
                    currentRequests: serviceRequests
                )
                requestMessage = count == 0 ? "No new online requests." : "Imported \(count) online request\(count == 1 ? "" : "s") for qualification."
            } catch {
                requestMessage = "Could not import online requests: \(error.localizedDescription)"
            }
            isImportingOnlineRequests = false
        }
    }

    private func claimOnlineRequestIfNeeded(_ request: ServiceRequest) {
        guard let backendRequestID = request.backendRequestID,
              GunnAireBackendService.isConfigured else { return }
        Task {
            do {
                try await GunnAireBackendService.claimServiceRequest(id: backendRequestID)
            } catch {
                requestMessage = "Appointment saved locally, but the online request still needs server reconciliation: \(error.localizedDescription)"
            }
        }
    }

    private func matchingCustomer(for request: ServiceRequest) -> Customer? {
        let email = AppAccess.normalizedEmail(request.email)
        let phone = normalizedPhone(request.phone)
        return customers.first { customer in
            (!email.isEmpty && AppAccess.normalizedEmail(customer.email) == email) ||
            (!phone.isEmpty && normalizedPhone(customer.phone) == phone) ||
            (email.isEmpty && phone.isEmpty && customer.name.caseInsensitiveCompare(request.customerName) == .orderedSame)
        }
    }

    private func normalizedPhone(_ value: String?) -> String {
        value?.filter(\.isNumber) ?? ""
    }

    private func defaultRequestScheduleDate() -> Date {
        let day = Calendar.current.startOfDay(for: selectedDate)
        return Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? selectedDate
    }

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
                    HStack(spacing: 10) {
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
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if job.id == nextFieldRouteCall?.id, hasNavigableAddress(for: job) {
                            Button {
                                openMaps(for: job)
                            } label: {
                                ViewThatFits(in: .horizontal) {
                                    Label("Next Stop", systemImage: "car.fill")
                                        .lineLimit(1)
                                    Image(systemName: "car.fill")
                                }
                                .frame(minWidth: 34, minHeight: 34)
                            }
                            .buttonStyle(.bordered)
                            .tint(.blue)
                            .accessibilityLabel("Navigate to next stop")
                            .accessibilityIdentifier("NavigateNextStop")
                        }
                    }
                    if job.id != snapshotCalls.last?.id {
                        Divider()
                    }
                }
            }

            if workQueueSummary.itemCount > 0 {
                Divider()

                DisclosureGroup(isExpanded: $showingWorkQueue) {
                    VStack(alignment: .leading, spacing: 12) {
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

                            if (job.followUpRequired || job.type == .estimate) && canManageDispatch {
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

                if let maintenanceMessage {
                    Label(maintenanceMessage, systemImage: "info.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(maintenanceAttentionContracts.prefix(3)) { contract in
                    let scheduledVisit = contract.scheduledVisit(
                        forDueDate: contract.nextDate,
                        in: serviceCalls
                    )
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(contract.customer.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(maintenanceReason(for: contract, scheduledVisit: scheduledVisit))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(contract.nextDate.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if contract.isExpired {
                            Label("Agreement term expired", systemImage: "calendar.badge.exclamationmark")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else if contract.needsRenewalAttention, let termEndsOn = contract.termEndsOn {
                            Label("Renewal due \(termEndsOn.formatted(date: .abbreviated, time: .omitted))", systemImage: "arrow.clockwise.circle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        Button(scheduledVisit == nil ? "Schedule Maintenance Visit" : "Open Scheduled Visit") {
                            if let scheduledVisit {
                                selectedDate = Calendar.current.startOfDay(for: scheduledVisit.scheduledDate)
                                navigationPath.append(scheduledVisit)
                            } else {
                                scheduleMaintenanceVisit(for: contract)
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.brandGold)
                        .disabled(scheduledVisit == nil && !contract.canScheduleVisit)
                        .accessibilityIdentifier("MaintenanceVisitAction-\(contract.id.uuidString)")

                        if let maintenanceReminderEmailURL = maintenanceReminderEmailURL(for: contract) {
                            Button(maintenanceReminderActionTitle(for: contract)) {
                                openMaintenanceReminderEmail(for: contract, fallbackURL: maintenanceReminderEmailURL)
                            }
                            .buttonStyle(.bordered)
                            .tint(Color.brandGold)
                            if let deliveredAt = lastMaintenanceReminderDate(for: contract) {
                                Text("Last sent \(deliveredAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if canManageDispatch && !approvedEstimateCalls.isEmpty {
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
                            if let estimate = estimate(for: job) {
                                presentApprovedWorkSchedule(for: estimate)
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.brandGold)
                        .disabled(estimate(for: job)?.hasRecordedCustomerApproval != true)
                    }
                }
                if let approvedWorkMessage {
                    Text(approvedWorkMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
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

                        if canManageDispatch {
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
                } label: {
                    HStack(spacing: 10) {
                        Label("Work Queue", systemImage: "tray.full")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.brandGold)
                        Spacer()
                        Text(workQueueSummary.detail)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var jobSearchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("Find Jobs")
                Spacer()
                if !searchedJobs.isEmpty {
                    Text("\(searchedJobs.count) match\(searchedJobs.count == 1 ? "" : "es")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            TextField("Search customer, equipment, report, concern, follow-up", text: $jobSearchText)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .textFieldStyle(.roundedBorder)

            if !jobSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if searchedJobs.isEmpty {
                    Text("No jobs match that search.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(searchedJobs.prefix(6))) { job in
                        Button {
                            selectedDate = Calendar.current.startOfDay(for: job.scheduledDate)
                            navigationPath.append(job)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(displayTitle(for: job))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(displaySubtitle(for: job))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let action = job.nextServiceReportActionLabel {
                                        Text(action)
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.orange)
                                            .lineLimit(1)
                                    } else if let concern = job.openServiceConcernRows.first {
                                        Text("\(concern.label): \(concern.value)")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.orange)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                Text(job.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        if job.id != searchedJobs.prefix(6).last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private func selectedDayCallRow(for call: ServiceCall) -> some View {
        serviceCallCard(for: call)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if canCollectFieldPayments, let invoice = invoice(for: call), !isInvoicePaid(invoice) {
                    Button {
                        openDocumentationInCloseout = true
                        openDocumentationInTapToPay = tapToPayReady
                        documentationCall = call
                    } label: {
                        Label(tapToPayReady ? "Tap to Pay on iPhone" : "Take Payment", systemImage: "creditcard")
                    }
                    .tint(.green)
                }

                if isAdminUser || canCollectFieldPayments {
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

    @ViewBuilder
    private func serviceCallCard(for call: ServiceCall) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                serviceCallSummary(for: call)

                Button {
                    navigationPath.append(call)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Open job details")
                .accessibilityIdentifier("OpenServiceCall-\(call.id.uuidString)")

                if canManageDispatch {
                    Button {
                        editingCall = call
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Edit schedule")
                    .accessibilityIdentifier("EditSchedule-\(call.id.uuidString)")

                    Button(role: .destructive) {
                        deleteConfirmationCall = call
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .accessibilityLabel("Delete calendar event")
                    .accessibilityIdentifier("DeleteSchedule-\(call.id.uuidString)")
                }
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

                if isAdminUser || canCollectFieldPayments {
                    Button(documentationActionTitle(for: call, compact: true)) {
                        openDocumentationInCloseout = false
                        openDocumentationInTapToPay = false
                        documentationCall = call
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("OpenDocumentation-\(call.id.uuidString)")
                }

                if canCollectFieldPayments, let invoice = invoice(for: call), !isInvoicePaid(invoice) {
                    Button(tapToPayReady ? "Pay" : "Collect") {
                        openDocumentationInCloseout = true
                        openDocumentationInTapToPay = tapToPayReady
                        documentationCall = call
                    }
                    .buttonStyle(.bordered)
                } else if canManageDispatch, call.assignedTechnician == nil, let signedInTechnician {
                    Button("Assign To Me") {
                        assign(call, to: signedInTechnician)
                    }
                    .buttonStyle(.bordered)
                } else if isAdminUser && call.isReadyToCreateBillingDocument {
                    Button("Invoice") {
                        openDocumentationInCloseout = false
                        openDocumentationInTapToPay = false
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
                Text(call.promisedArrivalWindowSummary ?? call.scheduledDate.formatted(date: .omitted, time: .shortened))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(call.status.rawValue.capitalized)
                .font(.caption)
                .foregroundColor(.gray)
            if call.dispatchUrgency != .normal {
                Label(call.dispatchUrgency.displayName, systemImage: call.dispatchUrgency == .emergency ? "exclamationmark.triangle.fill" : "flag.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(call.dispatchUrgency == .emergency ? .red : .orange)
            }
            if call.isCorrectiveWorkClassification {
                Label {
                    Text(correctiveDispatchSummary(for: call))
                        .lineLimit(1)
                } icon: {
                    Image(systemName: call.visitDisposition == .warranty ? "shield.checkered" : "arrow.trianglehead.clockwise")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .accessibilityIdentifier("CorrectiveStatus-\(call.id.uuidString)")
            }
            if call.technicianJobPresence == .enRoute || call.technicianJobPresence == .onSite {
                Label(call.technicianJobPresence.displayName, systemImage: call.technicianJobPresence == .enRoute ? "car.fill" : "mappin.and.ellipse")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(call.technicianJobPresence == .enRoute ? .orange : .green)
            }
            if let promisedArrivalWindowSummary = call.promisedArrivalWindowSummary {
                Text("Customer window • \(promisedArrivalWindowSummary)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.brandGold)
            }
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
                if !call.additionalTechnicianIDs.isEmpty {
                    Label("+\(call.additionalTechnicianIDs.count) crew", systemImage: "person.2.fill")
                }
                if call.googleEventID != nil {
                    Label("Google", systemImage: "calendar.badge.checkmark")
                }
                if call.documentationStartedAt != nil {
                    Label("Started", systemImage: "doc.text")
                }
                if isAdminUser && call.isReadyToCreateBillingDocument {
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
                if (isAdminUser || canCollectFieldPayments), let invoice = invoice(for: call) {
                    Label(invoice.status.capitalized, systemImage: isInvoicePaid(invoice) ? "checkmark.circle.fill" : "creditcard.fill")
                }
                if (isAdminUser || canCollectFieldPayments) && isCollectionOverdue(for: call) {
                    Label("Overdue", systemImage: "exclamationmark.triangle.fill")
                }
                if (isAdminUser || canCollectFieldPayments), let balanceDue = balanceDue(for: call), balanceDue > 0 {
                    Text("Due \(balanceDue, format: .currency(code: "USD"))")
                } else if (isAdminUser || canCollectFieldPayments) && call.linkedInvoiceID != nil {
                    Text("Paid")
                }
            }
            .font(.caption2)
            .foregroundColor(.secondary)
            if let closeoutAttention = closeoutAttentionText(for: call) {
                Label(closeoutAttention, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.orange)
                    .lineLimit(2)
            }
        }
    }

    private func documentationActionTitle(for call: ServiceCall, compact: Bool) -> String {
        let hasDocumentation = call.linkedEstimateID != nil || call.linkedInvoiceID != nil || call.documentationStartedAt != nil
        switch call.type {
        case .estimate:
            return hasDocumentation ? (compact ? "Estimate" : "Continue Estimate") : "Start Estimate"
        case .install, .replacement, .maintenance, .repair, .service, .meeting, .reminder, .siteVisit, .other:
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

    private func correctiveDispatchSummary(for call: ServiceCall) -> String {
        guard let reason = call.correctiveWorkReason else {
            return call.visitDisposition.displayName
        }
        return "\(call.visitDisposition.displayName) • \(reason.displayName)"
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
        guard AppAccess.canPerformScheduleMutation(
            .deleteServiceCall,
            email: AppIdentity.currentEmail,
            users: users
        ) else {
            syncMessage = "Dispatcher or administrator access is required to delete schedule entries."
            return
        }
        withAnimation {
            for index in offsets.sorted(by: >) {
                deleteCall(selectedDayCalls[index])
            }
        }
    }

    private func deleteCall(_ call: ServiceCall) {
        guard AppAccess.canPerformScheduleMutation(
            .deleteServiceCall,
            email: AppIdentity.currentEmail,
            users: users
        ) else {
            syncMessage = "Dispatcher or administrator access is required to delete schedule entries."
            return
        }
        let shouldTryGoogleDelete = GoogleCalendarScheduleSync.shouldAttemptManagedCalendarDeletion(for: call)
        if call.googleEventID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            GoogleCalendarScheduleSync.markCalendarEventDeleted(calendarID: call.googleCalendarID, eventID: call.googleEventID)
        }

        let calendarID = call.googleCalendarID
        let eventID = call.googleEventID
        let hasGoogleEventID = eventID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let isLocallyMarkedManagedByApp = call.googleEventManagedByApp
        modelContext.delete(call)
        try? modelContext.save()
        syncMessage = "Event deleted from the app."

        guard shouldTryGoogleDelete,
              googleAuth.isAuthenticated,
              let eventID,
              !eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        googleAuth.fetchCalendarEvent(calendarID: calendarID ?? "primary", eventID: eventID) { fetchResult in
            switch fetchResult {
            case .failure(let error):
                DispatchQueue.main.async {
                    syncMessage = "Event deleted from the app. Google Calendar was not changed: \(error.localizedDescription)"
                }
            case .success(let remoteEvent):
                guard GoogleCalendarScheduleSync.shouldDeleteExistingGoogleCalendarEvent(
                    hasGoogleEventID: hasGoogleEventID,
                    isLocallyMarkedManagedByApp: isLocallyMarkedManagedByApp,
                    remoteEvent: remoteEvent
                ) else {
                    DispatchQueue.main.async {
                        syncMessage = "Event deleted from the app. Google-owned calendar details were left unchanged."
                    }
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
            Text(canManageDispatch
                 ? "Choose another date on the calendar or add a new service call."
                 : "Choose another date or ask Dispatch to schedule work.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var dispatchAccessRequiredView: some View {
        NavigationStack {
            ContentUnavailableView(
                "Dispatch Access Required",
                systemImage: "person.badge.shield.checkmark",
                description: Text("Only a dispatcher or administrator can change company appointments, assignments, or capacity.")
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        showingAddCallSheet = false
                        editingCall = nil
                    }
                }
            }
        }
    }

    private func syncGoogleCalendar() {
        guard AppAccess.canPerformScheduleMutation(
            .syncGoogleCalendar,
            email: AppIdentity.currentEmail,
            users: users
        ) else {
            syncMessage = "Dispatcher or administrator access is required to import Google Calendar appointments."
            return
        }
        guard googleAuth.isAuthenticated else {
            syncMessage = "Google Calendar requires a Google sign-in. Your Apple sign-in still protects the rest of GunnAire Ops."
            return
        }
        isSyncingGoogleCalendar = true
        syncMessage = "Syncing Google Calendar..."
        let signedInEmail = AppIdentity.currentEmail
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
        if let url = AppleMapsDirections.destinationURL(
            siteAddress: call.siteAddress,
            customerAddress: call.customer?.address
        ) {
            openURL(url)
        }
    }

    private func hasNavigableAddress(for call: ServiceCall) -> Bool {
        AppleMapsDirections.destinationURL(
            siteAddress: call.siteAddress,
            customerAddress: call.customer?.address
        ) != nil
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
        return Invoice.outstandingBalance(for: invoice, payments: payments)
    }

    private func isInvoicePaid(_ invoice: Invoice) -> Bool {
        Invoice.isPaid(invoice, payments: payments)
    }

    private func isCollectionOverdue(for call: ServiceCall) -> Bool {
        guard let invoice = invoice(for: call),
              let due = balanceDue(for: call),
              due > 0 else { return false }
        return Invoice.isOverdue(invoice, payments: payments)
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
        let readiness = closeoutReadiness(for: call, invoice: invoice)
        return readiness.missingActionSummary(limit: 1)
    }

    private func closeoutAttentionText(for call: ServiceCall) -> String? {
        guard isAdminUser,
              call.linkedInvoiceID != nil ||
                call.workCompletedChecklist ||
                call.documentationChecklist ||
                call.status == .completed ||
                call.status == .invoiced else {
            return nil
        }
        let readiness = closeoutReadiness(for: call, invoice: invoice(for: call))
        guard !readiness.isReady else { return nil }
        return "Closeout next: \(readiness.missingActionSummary(limit: 2))"
    }

    private func closeoutReadiness(for call: ServiceCall, invoice: Invoice?) -> JobCloseoutReadiness {
        call.closeoutReadiness(
            invoice: invoice,
            payments: payments.filter { payment in
                guard let invoice else { return false }
                return payment.invoice.id == invoice.id
            },
            attachments: attachments.filter { $0.serviceCallID == call.id },
            fieldFormTemplates: fieldFormTemplates,
            fieldFormResponses: fieldFormResponses,
            timeEntries: timeEntries,
            materialReadiness: JobMaterialCloseoutPolicy.summary(
                for: call,
                invoice: invoice,
                estimates: estimates,
                projectMilestones: projectMilestones,
                items: items,
                movements: inventoryMovements
            )
        )
    }

    private func maintenanceReason(for contract: RecurringMaintenanceContract, scheduledVisit: ServiceCall?) -> String {
        if let scheduledVisit {
            return "Visit scheduled \(scheduledVisit.scheduledDate.formatted(date: .abbreviated, time: .shortened))"
        }
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
            subject: contract.needsRenewalAttention ? "Maintenance Agreement Renewal From GunnAire" : "Maintenance Reminder From GunnAire",
            body: """
Hello \(contract.customer.name),

\(contract.needsRenewalAttention && contract.termEndsOn != nil ? "Your \(contract.displayName) is due for renewal on \(contract.termEndsOn!.formatted(date: .abbreviated, time: .omitted))." : "This is a reminder that your \(contract.schedulePattern) maintenance visit is due on \(contract.nextDate.formatted(date: .abbreviated, time: .omitted)).")

Reply to this email if you would like us to schedule your visit.

Thank you,
GunnAire
"""
        )
    }

    private func maintenanceReminderWorkflow(for contract: RecurringMaintenanceContract) -> GunnAireMailWorkflow {
        contract.needsRenewalAttention ? .maintenanceRenewal : .maintenanceVisitReminder
    }

    private func lastMaintenanceReminderDate(for contract: RecurringMaintenanceContract) -> Date? {
        customerCommunications.first { communication in
            communication.maintenanceContractID == contract.id &&
            communication.workflow == maintenanceReminderWorkflow(for: contract) &&
            communication.normalizedDeliveryStatus == "sent"
        }?.deliveredAt
    }

    private func maintenanceReminderActionTitle(for contract: RecurringMaintenanceContract) -> String {
        if lastMaintenanceReminderDate(for: contract) != nil {
            return contract.needsRenewalAttention ? "Draft Another Renewal" : "Draft Another Reminder"
        }
        return contract.needsRenewalAttention ? "Draft Renewal" : "Draft Reminder"
    }

    private func openFollowUpEmail(for call: ServiceCall, fallbackURL: URL) {
        if googleAuth.isAuthenticated, let draft = followUpEmailDraft(for: call) {
            GunnAireAppIntentRouter.storeMailDraftRoute(
                to: draft.to,
                subject: draft.subject,
                body: draft.body,
                customerID: call.customer.id,
                serviceCallID: call.id,
                workflow: .serviceFollowUp
            )
        } else {
            openURL(fallbackURL)
        }
    }

    private func openMaintenanceReminderEmail(for contract: RecurringMaintenanceContract, fallbackURL: URL) {
        if googleAuth.isAuthenticated, let draft = maintenanceReminderEmailDraft(for: contract) {
            GunnAireAppIntentRouter.storeMailDraftRoute(
                to: draft.to,
                subject: draft.subject,
                body: draft.body,
                customerID: contract.customer.id,
                maintenanceContractID: contract.id,
                workflow: maintenanceReminderWorkflow(for: contract)
            )
        } else {
            openURL(fallbackURL)
        }
    }

    private func scheduleMaintenanceVisit(for contract: RecurringMaintenanceContract) {
        guard AppAccess.canPerformScheduleMutation(
            .scheduleMaintenance,
            email: AppIdentity.currentEmail,
            users: users
        ) else {
            maintenanceMessage = "Dispatcher or administrator access is required to schedule maintenance visits."
            return
        }
        guard contract.canScheduleVisit else { return }
        if let existingVisit = contract.scheduledVisit(forDueDate: contract.nextDate, in: serviceCalls) {
            selectedDate = Calendar.current.startOfDay(for: existingVisit.scheduledDate)
            navigationPath.append(existingVisit)
            return
        }
        let agreementDueDate = contract.nextDate
        let coveredEquipment = equipmentProfiles.first(where: {
            $0.customer?.id == contract.customer.id && contract.coveredEquipmentIDs.contains($0.id)
        })
        let serviceLocation = CustomerServiceLocationPolicy.location(
            id: coveredEquipment?.serviceLocationID,
            customerID: contract.customer.id,
            in: serviceLocations
        ) ?? CustomerServiceLocationPolicy.preferredLocation(for: contract.customer.id, in: serviceLocations)
        let serviceAddress = serviceLocation?.address ?? contract.customer.address?.trimmingCharacters(in: .whitespacesAndNewlines)
        let call = ServiceCall(
            googleEventManagedByApp: true,
            siteAddress: serviceAddress?.isEmpty == false ? serviceAddress : nil,
            serviceLocationID: serviceLocation?.id,
            type: .maintenance,
            scheduledDate: contract.nextDate,
            duration: 90 * 60,
            customer: contract.customer,
            status: .scheduled,
            notes: "Scheduled from \(contract.displayName): \(contract.schedulePattern)",
            followUpRequired: false,
            maintenanceAgreementID: contract.id,
            maintenanceAgreementDueDate: agreementDueDate
        )
        if let coveredEquipment {
            call.customerEquipmentID = coveredEquipment.id
            call.equipmentName = coveredEquipment.name
            call.equipmentManufacturer = coveredEquipment.manufacturer
            call.equipmentModel = coveredEquipment.modelNumber
            call.equipmentSerialNumber = coveredEquipment.serialNumber
            call.equipmentLocation = coveredEquipment.location
            call.equipmentInstallDate = coveredEquipment.installDate
            call.equipmentWarrantyExpiration = coveredEquipment.warrantyExpiration
            call.equipmentType = coveredEquipment.equipmentType
            call.filterSize = coveredEquipment.filterSize
            call.equipmentNotes = coveredEquipment.notes
            coveredEquipment.applyTechnicalBaselines(to: call)
        }
        modelContext.insert(call)
        do {
            try modelContext.save()
        } catch {
            modelContext.delete(call)
            maintenanceMessage = "Could not save the maintenance visit. The agreement due date was not advanced."
            return
        }
        maintenanceMessage = "Scheduled \(contract.displayName) for \(agreementDueDate.formatted(date: .abbreviated, time: .omitted)). The next obligation advances only after completion."
        publishToGoogleCalendar(call)
        selectedDate = Calendar.current.startOfDay(for: call.scheduledDate)
        navigationPath.append(call)
    }

    private func scheduleFollowUpVisit(for sourceCall: ServiceCall) {
        guard AppAccess.canPerformScheduleMutation(
            .scheduleFollowUp,
            email: AppIdentity.currentEmail,
            users: users
        ) else {
            syncMessage = "Dispatcher or administrator access is required to schedule follow-up visits."
            return
        }
        let followUpCall = sourceCall.makeFollowUpVisit()
        modelContext.insert(followUpCall)
        let actorEmail = AppIdentity.currentEmail
        ServiceCallActivity.record(
            for: sourceCall,
            action: sourceCall.isCorrectiveWorkClassification ? "Corrective visit scheduled" : "Follow-up visit scheduled",
            detail: "Linked follow-up for \(followUpCall.scheduledDate.formatted(date: .abbreviated, time: .shortened)).",
            actorEmail: actorEmail,
            in: modelContext
        )
        ServiceCallActivity.record(
            for: followUpCall,
            action: "Created from prior job",
            detail: "Linked to source job \(String(sourceCall.id.uuidString.prefix(8)).uppercased()).",
            actorEmail: actorEmail,
            in: modelContext
        )
        publishToGoogleCalendar(followUpCall)
        selectedDate = Calendar.current.startOfDay(for: followUpCall.scheduledDate)
        navigationPath.append(followUpCall)
    }

    private func sourceCall(for estimate: Estimate) -> ServiceCall? {
        guard let sourceID = estimate.serviceCallID else { return nil }
        return serviceCalls.first { $0.id == sourceID }
    }

    private func presentApprovedWorkSchedule(for estimate: Estimate) {
        guard canManageDispatch else { return }
        if let existing = ApprovedEstimateScheduling.existingWorkOrder(for: estimate, in: serviceCalls) {
            selectedDate = Calendar.current.startOfDay(for: existing.scheduledDate)
            navigationPath.append(existing)
            return
        }
        guard estimate.hasRecordedCustomerApproval else {
            approvedWorkMessage = "Record traceable customer approval before scheduling this estimate."
            return
        }
        approvedWorkMessage = nil
        selectedEstimateForScheduling = estimate
    }

    @discardableResult
    private func createApprovedWorkOrder(
        for estimate: Estimate,
        scheduledDate: Date,
        duration: TimeInterval,
        workType: ServiceCallType
    ) -> Bool {
        guard canManageDispatch else { return false }
        if let existing = ApprovedEstimateScheduling.existingWorkOrder(for: estimate, in: serviceCalls) {
            selectedDate = Calendar.current.startOfDay(for: existing.scheduledDate)
            navigationPath.append(existing)
            return true
        }
        let sourceCall = sourceCall(for: estimate)
        do {
            let approvedWorkCall = try ApprovedEstimateScheduling.makeWorkOrder(
                for: estimate,
                sourceCall: sourceCall,
                scheduledDate: scheduledDate,
                duration: duration,
                workType: workType
            )
            modelContext.insert(approvedWorkCall)
            estimate.scheduledServiceCallID = approvedWorkCall.id
            if estimate.serviceCallID == nil {
                estimate.serviceCallID = approvedWorkCall.id
            }
            sourceCall?.followUpRequired = false
            sourceCall?.followUpAction = nil
            sourceCall?.followUpDueDate = nil
            let actorEmail = AppIdentity.currentEmail
            ServiceCallActivity.record(
                for: approvedWorkCall,
                action: "Approved estimate scheduled",
                detail: "Created unassigned \(workType.displayName.lowercased()) work from approved estimate \(String(estimate.id.uuidString.prefix(8)).uppercased()) for \(estimate.amount.formatted(.currency(code: "USD"))).",
                actorEmail: actorEmail,
                in: modelContext
            )
            if let sourceCall, sourceCall.id != approvedWorkCall.id {
                ServiceCallActivity.record(
                    for: sourceCall,
                    action: "Approved work scheduled",
                    detail: "Created work order \(String(approvedWorkCall.id.uuidString.prefix(8)).uppercased()) for \(scheduledDate.formatted(date: .abbreviated, time: .shortened)).",
                    actorEmail: actorEmail,
                    in: modelContext
                )
            }
            try modelContext.save()
            selectedEstimateForScheduling = nil
            approvedWorkMessage = nil
            publishToGoogleCalendar(approvedWorkCall)
            selectedDate = Calendar.current.startOfDay(for: approvedWorkCall.scheduledDate)
            navigationPath.append(approvedWorkCall)
            return true
        } catch {
            modelContext.rollback()
            approvedWorkMessage = "Could not schedule approved work: \(error.localizedDescription)"
            return false
        }
    }

    private func publishToGoogleCalendar(_ call: ServiceCall) {
        guard googleAuth.isAuthenticated else { return }
        try? modelContext.save()
        let signedInEmail = AppIdentity.currentEmail
        GoogleCalendarScheduleSync.exportImmediately(
            call: call,
            auth: googleAuth,
            modelContext: modelContext,
            signedInEmail: signedInEmail,
            isAdminUser: isAdminUser
        )
    }

    private func moveCallFromDispatchBoard(
        _ callID: UUID,
        _ targetDay: Date,
        overrideReason: String? = nil
    ) -> DispatchBoardMoveResult {
        guard canManageDispatch else {
            return .rejected("Your business account cannot change the dispatch schedule.")
        }
        guard let call = callsForSignedInUser.first(where: { $0.id == callID }) else {
            return .rejected("That job is no longer available in your schedule.")
        }
        guard DispatchBoardScheduling.canMove(call) else {
            if GoogleCalendarScheduleSync.isExternalGoogleCalendarEvent(call), !call.googleEventManagedByApp {
                return .rejected("Google-owned events are read-only. Move this event in Google Calendar, then sync again.")
            }
            return .rejected("Completed and cancelled jobs cannot be moved from the dispatch board.")
        }

        let proposedStart = DispatchBoardScheduling.proposedStart(
            preservingTimeOf: call.scheduledDate,
            on: targetDay
        )
        guard proposedStart != call.scheduledDate else {
            return .unchanged("This job is already scheduled on that day.")
        }
        let conflict = DispatchBoardScheduling.conflictSummary(
            for: call,
            proposedStart: proposedStart,
            serviceCalls: serviceCalls,
            availabilityBlocks: technicianAvailabilityBlocks,
            technicians: technicians
        )
        let overrideDecision = DispatchBoardScheduling.conflictOverrideDecision(
            conflictSummary: conflict,
            overrideReason: overrideReason
        )
        switch overrideDecision {
        case .moveNormally:
            break
        case .needsReason(let conflictSummary):
            return .requiresOverride(
                DispatchConflictOverrideRequest(
                    callID: call.id,
                    targetDay: targetDay,
                    proposedStart: proposedStart,
                    conflictSummary: conflictSummary
                )
            )
        case .documented:
            break
        }

        let originalStart = call.scheduledDate
        call.scheduledDate = proposedStart
        let activityAction: String
        let activityDetail: String
        switch overrideDecision {
        case .documented(let conflictSummary, let reason):
            activityAction = "Dispatch conflict overridden"
            activityDetail = "Moved from \(originalStart.formatted(date: .abbreviated, time: .shortened)) to \(proposedStart.formatted(date: .abbreviated, time: .shortened)); appointment time preserved. Conflict: \(conflictSummary) Override reason: \(reason)"
        case .moveNormally, .needsReason:
            activityAction = "Dispatch board rescheduled"
            activityDetail = "Moved from \(originalStart.formatted(date: .abbreviated, time: .shortened)) to \(proposedStart.formatted(date: .abbreviated, time: .shortened)); appointment time preserved."
        }
        let activity = ServiceCallActivity(
            serviceCallID: call.id,
            action: activityAction,
            detail: activityDetail,
            actorEmail: AppIdentity.currentEmail
        )
        modelContext.insert(activity)

        do {
            try modelContext.save()
        } catch {
            call.scheduledDate = originalStart
            modelContext.delete(activity)
            try? modelContext.save()
            return .rejected("The schedule could not be saved: \(error.localizedDescription)")
        }

        selectedDate = Calendar.current.startOfDay(for: proposedStart)
        if GoogleCalendarScheduleSync.shouldPublishAfterLocalSave(for: call) {
            GoogleCalendarScheduleSync.markCalendarCallLocallyEdited(call)
            publishToGoogleCalendar(call)
        }
        if case .documented = overrideDecision {
            return .moved("\(displayTitle(for: call)) moved with a documented conflict override.")
        }
        return .moved("\(displayTitle(for: call)) moved to \(proposedStart.formatted(date: .abbreviated, time: .shortened)).")
    }

    private func assign(_ call: ServiceCall, to technician: Technician) {
        guard AppAccess.canPerformScheduleMutation(
            .assignTechnician,
            email: AppIdentity.currentEmail,
            users: users
        ) else {
            syncMessage = "Dispatcher or administrator access is required to assign technicians."
            return
        }
        let previousTechnician = call.assignedTechnician?.name
        call.assignedTechnician = technician
        var additionalCrew = call.additionalTechnicianIDs
        additionalCrew.remove(technician.id)
        call.additionalTechnicianIDs = additionalCrew
        let assignmentDetail = previousTechnician.map { "Reassigned from \($0) to \(technician.name)." } ?? "Assigned to \(technician.name)."
        ServiceCallActivity.record(
            for: call,
            action: previousTechnician == nil ? "Technician assigned" : "Technician reassigned",
            detail: assignmentDetail,
            actorEmail: AppIdentity.currentEmail,
            in: modelContext
        )
        if GoogleCalendarScheduleSync.shouldSelectGoogleCalendarBeforeCreate(for: call) {
            call.googleCalendarID = ServiceCalendarRouting.assignedCalendarID(for: technician)
        }
        guard GoogleCalendarScheduleSync.shouldPublishAfterLocalSave(for: call) else {
            try? modelContext.save()
            return
        }
        GoogleCalendarScheduleSync.markCalendarCallLocallyEdited(call)
        publishToGoogleCalendar(call)
    }

    private func assign(_ call: ServiceCall, to technician: Technician, reschedulingTo newStart: Date) {
        guard AppAccess.canPerformScheduleMutation(
            .assignTechnician,
            email: AppIdentity.currentEmail,
            users: users
        ) else {
            syncMessage = "Dispatcher or administrator access is required to assign or reschedule technicians."
            return
        }
        let originalStart = call.scheduledDate
        let previousTechnician = call.assignedTechnician?.name
        call.assignedTechnician = technician
        var additionalCrew = call.additionalTechnicianIDs
        additionalCrew.remove(technician.id)
        call.additionalTechnicianIDs = additionalCrew
        if GoogleCalendarScheduleSync.shouldSelectGoogleCalendarBeforeCreate(for: call) {
            call.googleCalendarID = ServiceCalendarRouting.assignedCalendarID(for: technician)
        }
        call.scheduledDate = newStart
        let technicianDetail = previousTechnician.map { "Reassigned from \($0) to \(technician.name)." } ?? "Assigned to \(technician.name)."
        ServiceCallActivity.record(
            for: call,
            action: "Assignment and schedule updated",
            detail: "\(technicianDetail) Moved from \(originalStart.formatted(date: .abbreviated, time: .shortened)) to \(newStart.formatted(date: .abbreviated, time: .shortened)).",
            actorEmail: AppIdentity.currentEmail,
            in: modelContext
        )
        guard GoogleCalendarScheduleSync.shouldPublishAfterLocalSave(for: call) else {
            try? modelContext.save()
            return
        }
        GoogleCalendarScheduleSync.markCalendarCallLocallyEdited(call)
        publishToGoogleCalendar(call)
    }

    private func nextAvailableStart(for technician: Technician, proposedStart: Date, duration: TimeInterval) -> Date? {
        TechnicianDispatchAvailability.nextAvailableStart(
            technicianID: technician.id,
            proposedStart: proposedStart,
            duration: duration,
            serviceCalls: serviceCalls,
            availabilityBlocks: technicianAvailabilityBlocks
        )
    }

}

struct ScheduleWorkQueueSummary: Equatable, Sendable {
    let queueCount: Int
    let itemCount: Int

    init(itemCounts: [Int]) {
        let visibleCounts = itemCounts.map { max($0, 0) }.filter { $0 > 0 }
        queueCount = visibleCounts.count
        itemCount = visibleCounts.reduce(0, +)
    }

    var detail: String {
        let itemLabel = itemCount == 1 ? "item" : "items"
        let queueLabel = queueCount == 1 ? "queue" : "queues"
        return "\(itemCount) \(itemLabel) • \(queueCount) \(queueLabel)"
    }
}

enum DispatchBoardMoveResult: Equatable {
    case moved(String)
    case unchanged(String)
    case rejected(String)
    case requiresOverride(DispatchConflictOverrideRequest)

    var message: String {
        switch self {
        case .moved(let message), .unchanged(let message), .rejected(let message):
            message
        case .requiresOverride(let request):
            "Move blocked: \(request.conflictSummary)"
        }
    }

    var isSuccess: Bool {
        if case .moved = self { return true }
        return false
    }
}

struct DispatchConflictOverrideRequest: Identifiable, Equatable {
    let callID: UUID
    let targetDay: Date
    let proposedStart: Date
    let conflictSummary: String

    var id: String {
        "\(callID.uuidString)-\(proposedStart.timeIntervalSinceReferenceDate)"
    }
}

enum DispatchConflictOverrideDecision: Equatable {
    case moveNormally
    case needsReason(conflictSummary: String)
    case documented(conflictSummary: String, reason: String)
}

enum DispatchBoardScheduling {
    static let minimumOverrideReasonLength = 10
    static let maximumOverrideReasonLength = 240

    static func startOfWeek(containing date: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)
        let offsetFromMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -offsetFromMonday, to: day) ?? day
    }

    static func daysInWeek(containing date: Date, calendar: Calendar = .current) -> [Date] {
        let start = startOfWeek(containing: date, calendar: calendar)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    static func proposedStart(
        preservingTimeOf currentStart: Date,
        on targetDay: Date,
        calendar: Calendar = .current
    ) -> Date {
        let time = calendar.dateComponents([.hour, .minute, .second], from: currentStart)
        return calendar.date(
            bySettingHour: time.hour ?? 0,
            minute: time.minute ?? 0,
            second: time.second ?? 0,
            of: targetDay
        ) ?? calendar.startOfDay(for: targetDay)
    }

    static func canMove(_ call: ServiceCall) -> Bool {
        guard call.status != .completed, call.status != .cancelled else { return false }
        return !GoogleCalendarScheduleSync.isExternalGoogleCalendarEvent(call) || call.googleEventManagedByApp
    }

    static func normalizedOverrideReason(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard normalized.count >= minimumOverrideReasonLength else { return nil }
        return String(normalized.prefix(maximumOverrideReasonLength))
    }

    static func conflictOverrideDecision(
        conflictSummary: String?,
        overrideReason: String?
    ) -> DispatchConflictOverrideDecision {
        guard let conflictSummary else { return .moveNormally }
        guard let reason = normalizedOverrideReason(overrideReason) else {
            return .needsReason(conflictSummary: conflictSummary)
        }
        return .documented(conflictSummary: conflictSummary, reason: reason)
    }

    static func conflictSummary(
        for call: ServiceCall,
        proposedStart: Date,
        serviceCalls: [ServiceCall],
        availabilityBlocks: [TechnicianAvailabilityBlock],
        technicians: [Technician]
    ) -> String? {
        let proposedEnd = proposedStart.addingTimeInterval(max(call.duration, 60))
        var assignedIDs = Set(call.additionalTechnicianIDs)
        if let leadID = call.assignedTechnician?.id {
            assignedIDs.insert(leadID)
        }
        guard !assignedIDs.isEmpty else { return nil }

        for technicianID in assignedIDs {
            let technicianName = technicians.first(where: { $0.id == technicianID })?.name ?? "Assigned technician"
            if let conflictingCall = serviceCalls.first(where: { other in
                guard other.id != call.id,
                      other.status != .cancelled,
                      other.status != .completed,
                      other.includesAssignedTechnician(technicianID) else { return false }
                let otherEnd = other.scheduledDate.addingTimeInterval(max(other.duration, 60))
                return proposedStart < otherEnd && proposedEnd > other.scheduledDate
            }) {
                return "\(technicianName) already has \(conflictingCall.customer.name) at \(conflictingCall.scheduledDate.formatted(date: .omitted, time: .shortened))."
            }
            if let block = availabilityBlocks.first(where: {
                $0.technicianID == technicianID && $0.overlaps(start: proposedStart, end: proposedEnd)
            }) {
                return "\(technicianName) is marked \(block.dispatchLabel.lowercased()) during that time."
            }
        }
        return nil
    }
}

private struct DispatchWeekBoardView: View {
    @Environment(\.dismiss) private var dismiss

    let calls: [ServiceCall]
    let onMove: (UUID, Date, String?) -> DispatchBoardMoveResult

    @State private var weekAnchor: Date
    @State private var actionMessage: String?
    @State private var lastMoveSucceeded = false
    @State private var editingCall: ServiceCall?
    @State private var pendingConflictOverride: DispatchConflictOverrideRequest?

    init(
        initialDate: Date,
        calls: [ServiceCall],
        onMove: @escaping (UUID, Date, String?) -> DispatchBoardMoveResult
    ) {
        self.calls = calls
        self.onMove = onMove
        _weekAnchor = State(initialValue: DispatchBoardScheduling.startOfWeek(containing: initialDate))
    }

    private var days: [Date] {
        DispatchBoardScheduling.daysInWeek(containing: weekAnchor)
    }

    private var weekTitle: String {
        guard let first = days.first, let last = days.last else { return "Dispatch Week" }
        return "\(first.formatted(.dateTime.month(.abbreviated).day())) – \(last.formatted(.dateTime.month(.abbreviated).day().year()))"
    }

    private var visibleCalls: [ServiceCall] {
        guard let first = days.first,
              let end = Calendar.current.date(byAdding: .day, value: 7, to: first) else { return [] }
        return calls
            .filter { $0.scheduledDate >= first && $0.scheduledDate < end }
            .sorted { $0.scheduledDate < $1.scheduledDate }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Label("Drag a job to another day. Its time stays the same.", systemImage: "hand.draw")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(visibleCalls.count) job\(visibleCalls.count == 1 ? "" : "s")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                if let actionMessage {
                    Label(actionMessage, systemImage: lastMoveSucceeded ? "checkmark.circle.fill" : "info.circle.fill")
                        .font(.caption)
                        .foregroundStyle(lastMoveSucceeded ? .green : .orange)
                }

                ScrollView([.horizontal, .vertical]) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(days, id: \.self) { day in
                            dayColumn(day)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.visible)
            }
            .padding()
            .navigationTitle("Dispatch Week")
            .navigationSubtitle(weekTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        moveWeek(by: -1)
                    } label: {
                        Label("Previous week", systemImage: "chevron.left")
                    }
                    Button("Today") {
                        withAnimation { weekAnchor = DispatchBoardScheduling.startOfWeek(containing: Date()) }
                    }
                    Button {
                        moveWeek(by: 1)
                    } label: {
                        Label("Next week", systemImage: "chevron.right")
                    }
                }
            }
            .fullScreenCover(item: $editingCall) { call in
                EditServiceCallView(call: call)
                    .tint(Color.brandGold)
            }
            .sheet(item: $pendingConflictOverride) { request in
                DispatchConflictOverrideSheet(request: request) { reason in
                    pendingConflictOverride = nil
                    performMove(request.callID, to: request.targetDay, overrideReason: reason)
                }
                .tint(Color.brandGold)
            }
        }
    }

    private func calls(on day: Date) -> [ServiceCall] {
        visibleCalls.filter { Calendar.current.isDate($0.scheduledDate, inSameDayAs: day) }
    }

    private func dayColumn(_ day: Date) -> some View {
        let dayCalls = calls(on: day)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.headline)
                    Text(day.formatted(.dateTime.month(.abbreviated).day()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(dayCalls.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if dayCalls.isEmpty {
                ContentUnavailableView("Open day", systemImage: "calendar.badge.plus")
                    .frame(maxWidth: .infinity, minHeight: 110)
            } else {
                ForEach(dayCalls) { call in
                    movableCard(call)
                }
            }

            Spacer(minLength: 40)
        }
        .padding(12)
        .frame(width: 190)
        .frame(minHeight: 430, alignment: .topLeading)
        .background(
            Calendar.current.isDateInToday(day) ? Color.brandGold.opacity(0.10) : Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Calendar.current.isDateInToday(day) ? Color.brandGold.opacity(0.55) : Color.secondary.opacity(0.14))
        }
        .dropDestination(for: String.self) { values, _ in
            guard let rawID = values.first, let callID = UUID(uuidString: rawID) else { return false }
            performMove(callID, to: day)
            return true
        }
        .accessibilityHint("Drop a job here to keep its appointment time and move it to this day.")
    }

    @ViewBuilder
    private func movableCard(_ call: ServiceCall) -> some View {
        let card = dispatchCard(call)
        if DispatchBoardScheduling.canMove(call) {
            card.draggable(call.id.uuidString) {
                dispatchCard(call)
                    .frame(width: 170)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                editingCall = call
            }
            .accessibilityAction(named: "Open job") {
                editingCall = call
            }
            .accessibilityIdentifier("DispatchJobCard-\(call.id.uuidString)")
        } else {
            card
                .opacity(0.65)
                .contentShape(Rectangle())
                .onTapGesture {
                    editingCall = call
                }
                .accessibilityAction(named: "Open job") {
                    editingCall = call
                }
                .accessibilityIdentifier("DispatchJobCard-\(call.id.uuidString)")
        }
    }

    private func dispatchCard(_ call: ServiceCall) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(call.eventTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? call.eventTitle! : call.customer.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(call.scheduledDate.formatted(date: .omitted, time: .shortened))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.brandGold)
                }
                Spacer()
                moveMenu(for: call)
            }
            Text(call.customer.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Label(call.assignedTechnician?.name ?? "Unassigned", systemImage: call.assignedTechnician == nil ? "person.slash" : "person.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(call.type.displayName)
                Text("•")
                Text(call.status.rawValue.capitalized)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(call.dispatchUrgency == .normal ? Color.secondary.opacity(0.12) : Color.orange.opacity(0.55))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(call.customer.name), \(call.scheduledDate.formatted(date: .abbreviated, time: .shortened)), \(call.assignedTechnician?.name ?? "unassigned")")
    }

    @ViewBuilder
    private func moveMenu(for call: ServiceCall) -> some View {
        if DispatchBoardScheduling.canMove(call) {
            Menu {
                Button {
                    editingCall = call
                } label: {
                    Label("Open Job", systemImage: "square.and.pencil")
                }
                Divider()
                ForEach(days, id: \.self) { day in
                    Button(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) {
                        performMove(call.id, to: day)
                    }
                    .disabled(Calendar.current.isDate(call.scheduledDate, inSameDayAs: day))
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel("Move \(call.customer.name)")
        } else {
            Menu {
                Button {
                    editingCall = call
                } label: {
                    Label("Open Job", systemImage: "square.and.pencil")
                }
            } label: {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Open locked job")
        }
    }

    private func performMove(_ callID: UUID, to day: Date, overrideReason: String? = nil) {
        let result = onMove(callID, day, overrideReason)
        actionMessage = result.message
        lastMoveSucceeded = result.isSuccess
        if case .requiresOverride(let request) = result {
            pendingConflictOverride = request
        }
    }

    private func moveWeek(by offset: Int) {
        guard let next = Calendar.current.date(byAdding: .day, value: offset * 7, to: weekAnchor) else { return }
        withAnimation { weekAnchor = next }
        actionMessage = nil
    }
}

private struct DispatchConflictOverrideSheet: View {
    @Environment(\.dismiss) private var dismiss

    let request: DispatchConflictOverrideRequest
    let onConfirm: (String) -> Void

    @State private var reason = ""

    private var normalizedReason: String? {
        DispatchBoardScheduling.normalizedOverrideReason(reason)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Scheduling Conflict") {
                    Label(request.conflictSummary, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    LabeledContent("Proposed start") {
                        Text(request.proposedStart.formatted(date: .abbreviated, time: .shortened))
                    }
                }

                Section("Required Reason") {
                    TextEditor(text: $reason)
                        .frame(minHeight: 92)
                        .accessibilityLabel("Conflict override reason")
                        .accessibilityIdentifier("DispatchConflictOverrideReason")
                    Text("Explain the operational reason for accepting this conflict. The signed-in dispatcher, time, conflict, and reason are retained in the job history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Label(
                        "Completed, cancelled, and Google-owned events remain locked and cannot use this override.",
                        systemImage: "lock.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Override Conflict")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Override Move") {
                        guard let normalizedReason else { return }
                        onConfirm(normalizedReason)
                        dismiss()
                    }
                    .disabled(normalizedReason == nil)
                    .accessibilityIdentifier("ConfirmDispatchConflictOverride")
                }
            }
            .interactiveDismissDisabled(!reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .presentationDetents([.medium, .large])
    }
}

private struct NewServiceRequestView: View {
    @Environment(\.dismiss) private var dismiss

    let onSave: (ServiceRequest) -> Void
    @State private var customerName = ""
    @State private var phone = ""
    @State private var email = ""
    @State private var address = ""
    @State private var serviceType: ServiceCallType = .service
    @State private var urgency: ServiceRequestUrgency = .normal
    @State private var source: ServiceRequestSource = .phone
    @State private var sourceDetail = ""
    @State private var summary = ""
    @State private var includesPreferredDate = false
    @State private var preferredDate = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section("Customer") {
                    TextField("Customer name", text: $customerName)
                    TextField("Phone", text: $phone)
                        .keyboardType(.phonePad)
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                    TextField("Service address", text: $address, axis: .vertical)
                        .lineLimit(2...3)
                }

                Section("Request") {
                    Picker("Lead source", selection: $source) {
                        ForEach(ServiceRequestSource.allCases) { source in
                            Text(source.displayName).tag(source)
                        }
                    }
                    .accessibilityIdentifier("NewServiceRequestSource")
                    if source.requiresDetail {
                        TextField("Source detail", text: $sourceDetail)
                            .accessibilityIdentifier("NewServiceRequestSourceDetail")
                    }
                    Picker("Requested work", selection: $serviceType) {
                        ForEach(ServiceCallType.allCases, id: \.rawValue) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    Picker("Urgency", selection: $urgency) {
                        ForEach(ServiceRequestUrgency.allCases) { urgency in
                            Text(urgency.displayName).tag(urgency)
                        }
                    }
                    TextField("What does the customer need?", text: $summary, axis: .vertical)
                        .lineLimit(3...6)
                    Toggle("Customer gave a preferred time", isOn: $includesPreferredDate)
                    if includesPreferredDate {
                        DatePicker("Preferred time", selection: $preferredDate)
                    }
                }

                Text("A request is not an appointment. Dispatch must qualify it and choose Schedule before it becomes a job.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("New Service Request")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(ServiceRequest(
                            customerName: customerName.trimmingCharacters(in: .whitespacesAndNewlines),
                            phone: phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : phone.trimmingCharacters(in: .whitespacesAndNewlines),
                            email: email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : email.trimmingCharacters(in: .whitespacesAndNewlines),
                            address: address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : address.trimmingCharacters(in: .whitespacesAndNewlines),
                            requestedServiceType: serviceType,
                            urgency: urgency,
                            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
                            preferredDate: includesPreferredDate ? preferredDate : nil,
                            source: source,
                            sourceDetail: sourceDetail,
                            createdByEmail: AppIdentity.currentEmail
                        ))
                        dismiss()
                    }
                    .disabled(
                        customerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        (source.requiresDetail && sourceDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    )
                }
            }
        }
    }
}

private struct ServiceRequestQualificationSheet: View {
    @Environment(\.dismiss) private var dismiss

    let request: ServiceRequest
    let onSave: (ServiceRequestSource, String?, String?, Date?) -> String?

    @State private var source: ServiceRequestSource
    @State private var sourceDetail: String
    @State private var notes: String
    @State private var includesFollowUp: Bool
    @State private var nextFollowUpAt: Date
    @State private var errorMessage: String?

    init(
        request: ServiceRequest,
        onSave: @escaping (ServiceRequestSource, String?, String?, Date?) -> String?
    ) {
        self.request = request
        self.onSave = onSave
        let now = Date()
        let storedFollowUp = request.nextFollowUpAt
        _source = State(initialValue: request.leadSource)
        _sourceDetail = State(initialValue: request.leadSourceDetail ?? "")
        _notes = State(initialValue: request.intakeQualificationNotes ?? "")
        _includesFollowUp = State(initialValue: storedFollowUp != nil)
        _nextFollowUpAt = State(
            initialValue: max(storedFollowUp ?? now.addingTimeInterval(24 * 60 * 60), now.addingTimeInterval(60))
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Lead") {
                    LabeledContent("Customer", value: request.customerName)
                    Picker("Source", selection: $source) {
                        ForEach(ServiceRequestSource.allCases) { source in
                            Text(source.displayName).tag(source)
                        }
                    }
                    .accessibilityIdentifier("ServiceRequestQualificationSource")
                    if source.requiresDetail {
                        TextField("Source detail", text: $sourceDetail)
                            .accessibilityIdentifier("ServiceRequestQualificationSourceDetail")
                    }
                }

                Section("Qualification") {
                    TextField("Qualification notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityIdentifier("ServiceRequestQualificationNotes")
                    Toggle("Set next follow-up", isOn: $includesFollowUp)
                        .accessibilityIdentifier("ServiceRequestFollowUpToggle")
                    if includesFollowUp {
                        DatePicker(
                            "Next follow-up",
                            selection: $nextFollowUpAt,
                            in: Date()...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("ServiceRequestQualificationError")
                    }
                }

                Section {
                    Text("Qualification records who contacted the lead and keeps any promised follow-up visible. Scheduling remains a separate commitment.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(request.status == .new ? "Qualify Request" : "Review Request")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(request.status == .new ? "Confirm Qualification" : "Save") {
                        errorMessage = onSave(
                            source,
                            sourceDetail.requestValue,
                            notes.requestValue,
                            includesFollowUp ? nextFollowUpAt : nil
                        )
                        if errorMessage == nil { dismiss() }
                    }
                    .disabled(
                        source.requiresDetail &&
                        sourceDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .accessibilityIdentifier("ConfirmServiceRequestQualification")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct ServiceRequestDeclineSheet: View {
    @Environment(\.dismiss) private var dismiss

    let request: ServiceRequest
    let onDecline: (ServiceRequestLostReason, String?) -> String?

    @State private var reason: ServiceRequestLostReason?
    @State private var notes: String
    @State private var errorMessage: String?

    init(
        request: ServiceRequest,
        onDecline: @escaping (ServiceRequestLostReason, String?) -> String?
    ) {
        self.request = request
        self.onDecline = onDecline
        _reason = State(initialValue: request.lostReason)
        _notes = State(initialValue: request.intakeQualificationNotes ?? "")
    }

    private var canClose: Bool {
        guard let reason else { return false }
        return !reason.requiresNotes || !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Close Lead") {
                    LabeledContent("Customer", value: request.customerName)
                    LabeledContent("Source", value: request.leadSourceSummary)
                    Picker("Reason", selection: $reason) {
                        Text("Choose a reason").tag(ServiceRequestLostReason?.none)
                        ForEach(ServiceRequestLostReason.allCases) { reason in
                            Text(reason.displayName).tag(ServiceRequestLostReason?.some(reason))
                        }
                    }
                    .accessibilityIdentifier("ServiceRequestLostReason")
                    TextField(reason?.requiresNotes == true ? "Notes (required)" : "Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityIdentifier("ServiceRequestDeclineNotes")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("ServiceRequestDeclineError")
                    }
                }

                Section {
                    Text("The lead leaves the active queue but its source, reason, staff account, and time remain available for funnel review.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Decline Request")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close Request", role: .destructive) {
                        guard let reason else { return }
                        errorMessage = onDecline(
                            reason,
                            notes.requestValue
                        )
                        if errorMessage == nil { dismiss() }
                    }
                    .disabled(!canClose)
                    .accessibilityIdentifier("ConfirmServiceRequestDecline")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private extension String {
    var requestValue: String? {
        let normalized = trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

#Preview {
    ScheduleView()
}
