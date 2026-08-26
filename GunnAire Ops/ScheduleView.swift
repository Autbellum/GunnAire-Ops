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
    @Query(sort: \CustomerEquipment.name, order: .forward) private var equipmentProfiles: [CustomerEquipment]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @Query(sort: \ServiceRequest.createdAt, order: .forward) private var serviceRequests: [ServiceRequest]
    @Query(sort: \Customer.name, order: .forward) private var customers: [Customer]
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
    @State private var requestMessage: String?
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
        Array(upcomingJobs.prefix(3))
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
        serviceRequests.filter { $0.status == .new || $0.status == .qualified }
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
        let email = googleAuth.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail")
        let visibleIDs = AppAccess.visibleServiceCallIDs(email: email, users: users, serviceCalls: serviceCalls, technicians: technicians)
        return serviceCalls.filter { visibleIDs.contains($0.id) }
    }
    
    var activeRecurringContracts: [RecurringMaintenanceContract] {
        let now = Date()
        return recurringContracts.filter { $0.nextDate >= now }
    }

    private var maintenanceAttentionContracts: [RecurringMaintenanceContract] {
        recurringContracts
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
        let email = googleAuth.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail")
        return AppAccess.isAdmin(email: email, users: users)
    }

    private var canManageDispatch: Bool {
        let email = googleAuth.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail")
        return AppAccess.canManageDispatch(email: email, users: users)
    }

    private var canCollectFieldPayments: Bool {
        let email = googleAuth.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail")
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
                                    ForEach(selectedDayCalls) { call in
                                        serviceCallCard(for: call)
                                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                            if canCollectFieldPayments, let invoice = invoice(for: call), !isInvoicePaid(invoice) {
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
                            if canManageDispatch {
                                Button {
                                    showingAvailabilityBlocks = true
                                } label: {
                                    Label("Availability", systemImage: "person.badge.clock")
                                }
                                .tint(Color.brandGold)
                            }

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
                .sheet(isPresented: $showingNewRequestSheet) {
                    NewServiceRequestView { request in
                        modelContext.insert(request)
                        try? modelContext.save()
                        requestMessage = "Request saved. Qualify it, then schedule without changing a committed appointment."
                    }
                    .tint(Color.brandGold)
                }
                .sheet(isPresented: $showingAvailabilityBlocks) {
                    TechnicianAvailabilityView()
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
                        if let preferredDate = request.preferredDate {
                            Text("Requested: \(preferredDate.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Button(request.status == .new ? "Qualify" : "Qualified") {
                                request.status = .qualified
                                request.qualifiedAt = request.qualifiedAt ?? Date()
                                try? modelContext.save()
                                requestMessage = "Request qualified. Choose Schedule when the appointment window is confirmed."
                            }
                            .buttonStyle(.bordered)
                            .disabled(request.status != .new)

                            Button("Schedule") {
                                schedule(request)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .disabled(!request.canSchedule)

                            Button("Decline", role: .destructive) {
                                request.status = .declined
                                try? modelContext.save()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }

    private func schedule(_ request: ServiceRequest) {
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
        let call = ServiceCall(
            eventTitle: "\(request.requestedServiceType.displayName) request",
            siteAddress: request.address,
            type: request.requestedServiceType,
            dispatchUrgency: request.urgency,
            scheduledDate: scheduledDate,
            customer: customer,
            notes: "Request intake: \(request.summary)"
        )
        modelContext.insert(call)
        request.markScheduled(customerID: customer.id, serviceCallID: call.id)
        ServiceCallActivity.record(
            for: call,
            action: "Request scheduled",
            detail: "Created from a \(request.urgency.displayName.lowercased()) service request received \(request.createdAt.formatted(date: .abbreviated, time: .shortened)).",
            actorEmail: googleAuth.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail"),
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

    private func importOnlineRequests() {
        guard GunnAireBackendService.isConfigured else { return }
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

                        if contract.isExpired {
                            Label("Agreement term expired", systemImage: "calendar.badge.exclamationmark")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else if contract.needsRenewalAttention, let termEndsOn = contract.termEndsOn {
                            Label("Renewal due \(termEndsOn.formatted(date: .abbreviated, time: .omitted))", systemImage: "arrow.clockwise.circle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        Button("Schedule Maintenance Visit") {
                            scheduleMaintenanceVisit(for: contract)
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.brandGold)
                        .disabled(!contract.canScheduleVisit)

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
                } else if isAdminUser && call.isReadyToCreateBillingDocument {
                    Button("Invoice") {
                        openDocumentationInCloseout = false
                        openDocumentationInTapToPay = false
                        documentationCall = call
                    }
                    .buttonStyle(.bordered)
                } else if canCollectFieldPayments, let invoice = invoice(for: call), !isInvoicePaid(invoice) {
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
        return Invoice.outstandingBalance(for: invoice, payments: payments)
    }

    private func isInvoicePaid(_ invoice: Invoice) -> Bool {
        Invoice.isPaid(invoice, payments: payments)
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
        let readiness = closeoutReadiness(for: call, invoice: invoice)
        return readiness.missingSummary(limit: 1)
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
        return "Closeout: \(readiness.missingSummary(limit: 2))"
    }

    private func closeoutReadiness(for call: ServiceCall, invoice: Invoice?) -> JobCloseoutReadiness {
        call.closeoutReadiness(
            invoice: invoice,
            payments: payments.filter { payment in
                guard let invoice else { return false }
                return payment.invoice.id == invoice.id
            },
            attachments: attachments.filter { $0.serviceCallID == call.id }
        )
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

    private func openFollowUpEmail(for call: ServiceCall, fallbackURL: URL) {
        if googleAuth.isAuthenticated, let draft = followUpEmailDraft(for: call) {
            GunnAireAppIntentRouter.storeMailDraftRoute(
                to: draft.to,
                subject: draft.subject,
                body: draft.body,
                customerID: call.customer.id,
                serviceCallID: call.id
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
                customerID: contract.customer.id
            )
        } else {
            openURL(fallbackURL)
        }
    }

    private func scheduleMaintenanceVisit(for contract: RecurringMaintenanceContract) {
        guard contract.canScheduleVisit else { return }
        let serviceAddress = contract.customer.address?.trimmingCharacters(in: .whitespacesAndNewlines)
        let call = ServiceCall(
            googleEventManagedByApp: true,
            siteAddress: serviceAddress?.isEmpty == false ? serviceAddress : nil,
            type: .maintenance,
            scheduledDate: contract.nextDate,
            duration: 90 * 60,
            customer: contract.customer,
            status: .scheduled,
            notes: "Scheduled from \(contract.displayName): \(contract.schedulePattern)",
            followUpRequired: false
        )
        if let coveredEquipment = equipmentProfiles.first(where: {
            $0.customer?.id == contract.customer.id && contract.coveredEquipmentIDs.contains($0.id)
        }) {
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
        contract.advanceNextDate()
        publishToGoogleCalendar(call)
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
            googleEventManagedByApp: true,
            siteAddress: sourceCall.siteAddress ?? sourceCall.customer.address,
            equipmentName: sourceCall.equipmentName,
            equipmentManufacturer: sourceCall.equipmentManufacturer,
            equipmentModel: sourceCall.equipmentModel,
            equipmentSerialNumber: sourceCall.equipmentSerialNumber,
            equipmentLocation: sourceCall.equipmentLocation,
            equipmentInstallDate: sourceCall.equipmentInstallDate,
            equipmentWarrantyExpiration: sourceCall.equipmentWarrantyExpiration,
            customerEquipmentID: sourceCall.customerEquipmentID,
            type: sourceCall.type,
            scheduledDate: scheduledDate,
            duration: sourceCall.duration,
            assignedTechnician: sourceCall.assignedTechnician,
            additionalTechnicianIDs: sourceCall.additionalTechnicianIDs,
            customer: sourceCall.customer,
            status: .scheduled,
            notes: generatedNotes.isEmpty ? "Scheduled follow-up visit" : "Scheduled follow-up visit\n\n\(generatedNotes)",
            findingsSummary: sourceCall.findingsSummary,
            recommendedWorkSummary: sourceCall.recommendedWorkSummary,
            followUpRequired: false
        )
        followUpCall.inheritEquipmentProfile(from: sourceCall)
        followUpCall.dispatchUrgency = sourceCall.dispatchUrgency
        modelContext.insert(followUpCall)
        sourceCall.followUpRequired = false
        sourceCall.followUpAction = nil
        sourceCall.followUpDueDate = nil
        publishToGoogleCalendar(followUpCall)
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
            googleEventManagedByApp: true,
            siteAddress: sourceCall.siteAddress ?? sourceCall.customer.address,
            equipmentName: sourceCall.equipmentName,
            equipmentManufacturer: sourceCall.equipmentManufacturer,
            equipmentModel: sourceCall.equipmentModel,
            equipmentSerialNumber: sourceCall.equipmentSerialNumber,
            equipmentLocation: sourceCall.equipmentLocation,
            equipmentInstallDate: sourceCall.equipmentInstallDate,
            equipmentWarrantyExpiration: sourceCall.equipmentWarrantyExpiration,
            customerEquipmentID: sourceCall.customerEquipmentID,
            type: sourceCall.type == .estimate ? .install : sourceCall.type,
            scheduledDate: scheduledDate,
            duration: sourceCall.duration,
            assignedTechnician: sourceCall.assignedTechnician,
            additionalTechnicianIDs: sourceCall.additionalTechnicianIDs,
            customer: sourceCall.customer,
            status: .scheduled,
            notes: generatedNotes.isEmpty ? "Scheduled from approved estimate" : "Scheduled from approved estimate\n\n\(generatedNotes)",
            findingsSummary: sourceCall.findingsSummary,
            recommendedWorkSummary: sourceCall.recommendedWorkSummary,
            followUpRequired: false
        )
        approvedWorkCall.inheritEquipmentProfile(from: sourceCall)
        approvedWorkCall.dispatchUrgency = sourceCall.dispatchUrgency
        modelContext.insert(approvedWorkCall)
        sourceCall.followUpRequired = false
        sourceCall.followUpAction = nil
        sourceCall.followUpDueDate = nil
        publishToGoogleCalendar(approvedWorkCall)
        selectedDate = Calendar.current.startOfDay(for: approvedWorkCall.scheduledDate)
        navigationPath.append(approvedWorkCall)
    }

    private func publishToGoogleCalendar(_ call: ServiceCall) {
        guard googleAuth.isAuthenticated else { return }
        try? modelContext.save()
        let signedInEmail = googleAuth.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail")
        GoogleCalendarScheduleSync.exportImmediately(
            call: call,
            auth: googleAuth,
            modelContext: modelContext,
            signedInEmail: signedInEmail,
            isAdminUser: isAdminUser
        )
    }

    private func assign(_ call: ServiceCall, to technician: Technician) {
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
            actorEmail: googleAuth.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail"),
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
            actorEmail: googleAuth.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail"),
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

private struct NewServiceRequestView: View {
    @Environment(\.dismiss) private var dismiss

    let onSave: (ServiceRequest) -> Void
    @State private var customerName = ""
    @State private var phone = ""
    @State private var email = ""
    @State private var address = ""
    @State private var serviceType: ServiceCallType = .service
    @State private var urgency: ServiceRequestUrgency = .normal
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
                            createdByEmail: GoogleAuthManager.shared.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail")
                        ))
                        dismiss()
                    }
                    .disabled(customerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

#Preview {
    ScheduleView()
}
