import SwiftUI
import SwiftData

struct OperationsDashboardView: View {
    @Binding private var showingCommandPalette: Bool
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(sort: \Customer.name, order: .forward) private var customers: [Customer]
    @Query(sort: \ServiceCall.scheduledDate, order: .forward) private var serviceCalls: [ServiceCall]
    @Query(sort: \Technician.name, order: .forward) private var technicians: [Technician]
    @Query(sort: \TechnicianAvailabilityBlock.startsAt, order: .forward) private var technicianAvailabilityBlocks: [TechnicianAvailabilityBlock]
    @Query(sort: \TechnicianWorkShift.createdAt, order: .reverse) private var technicianWorkShifts: [TechnicianWorkShift]
    @Query(sort: \RecurringMaintenanceContract.nextDate, order: .forward) private var recurringContracts: [RecurringMaintenanceContract]
    @Query(sort: \Estimate.createdAt, order: .reverse) private var estimates: [Estimate]
    @Query(sort: \Invoice.createdAt, order: .reverse) private var invoices: [Invoice]
    @Query(sort: \Payment.date, order: .reverse) private var payments: [Payment]
    @Query(sort: \ServiceDocumentAttachment.createdAt, order: .reverse) private var attachments: [ServiceDocumentAttachment]
    @Query(sort: \FieldFormTemplate.createdAt, order: .forward) private var fieldFormTemplates: [FieldFormTemplate]
    @Query(sort: \FieldFormResponse.completedAt, order: .reverse) private var fieldFormResponses: [FieldFormResponse]
    @Query(sort: \ServiceCallActivity.occurredAt, order: .reverse) private var serviceCallActivities: [ServiceCallActivity]
    @Query(sort: \TimeEntry.clockIn, order: .reverse) private var timeEntries: [TimeEntry]
    @Query(sort: \Item.name, order: .forward) private var items: [Item]
    @Query(sort: \InventoryMovement.createdAt, order: .reverse) private var inventoryMovements: [InventoryMovement]
    @Query(sort: \ProjectMilestone.plannedDate, order: .forward) private var projectMilestones: [ProjectMilestone]
    @Query(sort: \Vendor.name, order: .forward) private var vendors: [Vendor]
    @Query(sort: \CustomerCommunication.createdAt, order: .reverse) private var customerCommunications: [CustomerCommunication]
    @Query(sort: \FleetVehicle.unitNumber, order: .forward) private var fleetVehicles: [FleetVehicle]
    @Query(sort: \BusinessTask.dueAt, order: .forward) private var businessTasks: [BusinessTask]
    @Query(sort: \TechnicianTimeOffRequest.createdAt, order: .reverse) private var timeOffRequests: [TechnicianTimeOffRequest]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @ObservedObject private var googleAuth = GoogleAuthManager.shared
    @AppStorage("enableOnsitePayments") private var enableOnsitePayments = false
    @AppStorage("onsitePaymentProcessor") private var onsitePaymentProcessor = OnsitePaymentProcessor.none.rawValue
    @AppStorage("onsitePaymentProcessorReady") private var onsitePaymentProcessorReady = false
    @AppStorage("requireWorkPerformedLogForCloseout") private var requireWorkPerformedLogForCloseout = true
    @State private var dispatchMessage: String?
    @State private var isBusinessOverviewExpanded = false
    @State private var isOperationalStatusExpanded = false
    @State private var showingFleetWorkspace = false
    @State private var showingBusinessTasks = false
    @State private var showingTimeOffRequests = false

    private let calendar = Calendar.current

    init(showingCommandPalette: Binding<Bool>) {
        _showingCommandPalette = showingCommandPalette
    }

    private var currentUserEmail: String? {
        AppIdentity.currentEmail
    }

    private var operationsAccess: OperationsAccessCapabilities {
        OperationsAccessPolicy.capabilities(email: currentUserEmail, users: users)
    }

    /// CloudKit may hydrate relationship records after their owning records.
    /// Keep the command center available while those links converge instead of
    /// dereferencing the models' intentionally optional-at-rest relationships.
    private var dashboardServiceCalls: [ServiceCall] {
        let visibleIDs = OperationsAccessPolicy.visibleServiceCallIDs(
            email: currentUserEmail,
            users: users,
            serviceCalls: serviceCalls,
            technicians: technicians
        )
        return serviceCalls.filter { visibleIDs.contains($0.id) }
    }

    private var dashboardCustomers: [Customer] {
        let visibleIDs = OperationsAccessPolicy.dashboardCustomerIDs(
            email: currentUserEmail,
            users: users,
            customers: customers,
            serviceCalls: serviceCalls,
            invoices: invoices,
            technicians: technicians
        )
        return customers.filter { visibleIDs.contains($0.id) }
    }

    private var searchableCustomers: [Customer] {
        let visibleIDs = OperationsAccessPolicy.searchableCustomerIDs(
            email: currentUserEmail,
            users: users,
            customers: customers
        )
        return customers.filter { visibleIDs.contains($0.id) }
    }

    private var dashboardContracts: [RecurringMaintenanceContract] {
        let customerIDs = Set(dashboardCustomers.map(\.id))
        let visibleIDs = OperationsAccessPolicy.visibleContractIDs(
            customerIDs: customerIDs,
            contracts: recurringContracts
        )
        return recurringContracts.filter { visibleIDs.contains($0.id) }
    }

    private var dashboardEstimates: [Estimate] {
        let visibleIDs = OperationsAccessPolicy.visibleEstimateIDs(
            email: currentUserEmail,
            users: users,
            estimates: estimates
        )
        return estimates.filter { visibleIDs.contains($0.id) }
    }

    private var dashboardInvoices: [Invoice] {
        let visibleIDs = OperationsAccessPolicy.visibleInvoiceIDs(
            email: currentUserEmail,
            users: users,
            serviceCalls: serviceCalls,
            invoices: invoices,
            technicians: technicians
        )
        return invoices.filter { visibleIDs.contains($0.id) }
    }

    private var dashboardPayments: [Payment] {
        let visibleIDs = OperationsAccessPolicy.visiblePaymentIDs(
            email: currentUserEmail,
            users: users,
            serviceCalls: serviceCalls,
            invoices: invoices,
            payments: payments,
            technicians: technicians
        )
        return payments.filter { visibleIDs.contains($0.id) }
    }

    private var dashboardCommunications: [CustomerCommunication] {
        let visibleIDs = OperationsAccessPolicy.visibleCommunicationIDs(
            customerIDs: Set(dashboardCustomers.map(\.id)),
            communications: customerCommunications
        )
        return customerCommunications.filter { visibleIDs.contains($0.id) }
    }

    private var assignableTechnicians: [Technician] {
        AppAccess.schedulableTechnicians(technicians, users: users)
    }

    private var canViewFinancials: Bool {
        operationsAccess.canViewFinancials
    }

    private var canCollectFieldPayments: Bool {
        operationsAccess.canCollectPayments
    }

    private var visibleTechnicians: [Technician] {
        let visibleIDs = OperationsAccessPolicy.visibleTechnicianIDs(
            email: currentUserEmail,
            users: users,
            technicians: technicians
        )
        return technicians.filter { visibleIDs.contains($0.id) }
    }

    private var isAdminUser: Bool {
        AppAccess.isAdmin(email: currentUserEmail, users: users)
    }

    private var currentUserRole: AppUserRole? {
        AppAccess.activeRole(email: currentUserEmail, users: users)
    }

    private var currentTechnicianID: UUID? {
        AppAccess.ownPerformanceTechnicianID(
            email: currentUserEmail,
            users: users,
            technicians: technicians
        )
    }

    private var visibleFleetVehicles: [FleetVehicle] {
        switch currentUserRole {
        case .fieldTechnician:
            guard let currentTechnicianID else { return [] }
            return fleetVehicles.filter { $0.assignedTechnicianID == currentTechnicianID }
        case .standard, nil:
            return []
        case .dispatcher, .accounting, .admin:
            return fleetVehicles
        }
    }

    private var fleetAttentionVehicles: [FleetVehicle] {
        visibleFleetVehicles
            .filter { $0.readiness().needsAttention }
            .sorted {
                if $0.administrativeStatus != $1.administrativeStatus {
                    return $0.administrativeStatus == .outOfService
                }
                return $0.unitNumber.localizedCaseInsensitiveCompare($1.unitNumber) == .orderedAscending
            }
    }

    private var visibleBusinessTasks: [BusinessTask] {
        let visibleCallIDs = AppAccess.visibleServiceCallIDs(
            email: currentUserEmail,
            users: users,
            serviceCalls: serviceCalls,
            technicians: technicians
        )
        return BusinessTaskPolicy.visibleTasks(
            from: businessTasks,
            email: currentUserEmail,
            users: users,
            visibleServiceCallIDs: visibleCallIDs
        )
    }

    private var openBusinessTasks: [BusinessTask] {
        visibleBusinessTasks.filter(\.isOpen)
    }

    private var canReviewTimeOffRequests: Bool {
        AppAccess.canReviewTimeOffRequests(email: currentUserEmail, users: users)
    }

    private var pendingTimeOffRequests: [TechnicianTimeOffRequest] {
        guard canReviewTimeOffRequests else { return [] }
        return TechnicianTimeOffPolicy.ordered(timeOffRequests.filter { $0.status == .pending })
    }

    private var todayCalls: [ServiceCall] {
        dashboardServiceCalls
            .filter { calendar.isDate($0.scheduledDate, inSameDayAs: Date()) && $0.status != .cancelled }
            .sorted { $0.scheduledDate < $1.scheduledDate }
    }

    private var upcomingCalls: [ServiceCall] {
        let now = Date()
        let sevenDaysAhead = calendar.date(byAdding: .day, value: 7, to: now) ?? now
        return dashboardServiceCalls
            .filter { $0.status != .cancelled && $0.scheduledDate >= now && $0.scheduledDate <= sevenDaysAhead }
            .sorted { $0.scheduledDate < $1.scheduledDate }
    }

    private var inProgressCalls: [ServiceCall] {
        dashboardServiceCalls
            .filter { $0.status == .inProgress || $0.documentationStartedAt != nil && $0.documentationCompletedAt == nil }
            .sorted { $0.scheduledDate < $1.scheduledDate }
    }

    private var unassignedUpcomingCalls: [ServiceCall] {
        upcomingCalls
            .filter { $0.assignedTechnician == nil }
            .sorted {
                if $0.dispatchUrgency.dispatchSortRank != $1.dispatchUrgency.dispatchSortRank {
                    return $0.dispatchUrgency.dispatchSortRank < $1.dispatchUrgency.dispatchSortRank
                }
                return $0.scheduledDate < $1.scheduledDate
            }
    }

    private var readyToBillCalls: [ServiceCall] {
        dashboardServiceCalls
            .filter(\.isReadyToCreateBillingDocument)
            .sorted { $0.scheduledDate > $1.scheduledDate }
    }

    private var followUpCalls: [ServiceCall] {
        dashboardServiceCalls
            .filter { $0.followUpRequired || ($0.type == .estimate && $0.linkedInvoiceID == nil) }
            .sorted {
                let lhsDate = $0.followUpDueDate ?? $0.scheduledDate
                let rhsDate = $1.followUpDueDate ?? $1.scheduledDate
                return lhsDate < rhsDate
            }
    }

    private var maintenanceAlerts: [RecurringMaintenanceContract] {
        guard operationsAccess.canSearchJobs else { return [] }
        return dashboardContracts
            .filter { $0.active && ($0.isOverdue || $0.isUpcoming || $0.needsReminder) }
            .sorted { $0.nextDate < $1.nextDate }
    }

    private var acceptedEstimateCalls: [ServiceCall] {
        dashboardServiceCalls
            .filter { call in
                guard let estimate = estimate(for: call) else { return false }
                return estimate.status.caseInsensitiveCompare("accepted") == .orderedSame && call.linkedInvoiceID == nil
            }
            .sorted { $0.scheduledDate > $1.scheduledDate }
    }

    private var openInvoices: [Invoice] {
        dashboardInvoices
            .filter { outstandingBalance(for: $0) > 0 }
            .sorted { outstandingBalance(for: $0) > outstandingBalance(for: $1) }
    }

    private var overdueInvoices: [Invoice] {
        return openInvoices
            .filter { Invoice.isOverdue($0, payments: dashboardPayments) }
            .sorted { $0.effectiveDueDate(calendar: calendar) < $1.effectiveDueDate(calendar: calendar) }
    }

    private var quickBooksAttentionPayments: [Payment] {
        dashboardPayments
            .filter(\.needsQuickBooksAttention)
            .sorted { $0.date > $1.date }
    }

    private var quickBooksAttentionInvoices: [Invoice] {
        QuickBooksInvoicePublicationRecovery.queuedInvoices(from: dashboardInvoices)
    }

    private var quickBooksAttentionCount: Int {
        quickBooksAttentionInvoices.count + quickBooksAttentionPayments.count
    }

    private var openTimeEntries: [TimeEntry] {
        let visibleEmails = Set(visibleTechnicians.map { AppAccess.normalizedEmail($0.contactInfo) })
        return timeEntries.filter {
            $0.isOpen && visibleEmails.contains(AppAccess.normalizedEmail($0.userEmail))
        }
    }

    private var monthInvoiceTotal: Double {
        dashboardInvoices
            .filter { calendar.isDate($0.createdAt, equalTo: Date(), toGranularity: .month) }
            .reduce(0) { $0 + $1.amount }
    }

    private var monthPaymentsCollected: Double {
        dashboardPayments
            .filter { calendar.isDate($0.date, equalTo: Date(), toGranularity: .month) }
            .reduce(0) { $0 + $1.amount }
    }

    private var openReceivablesTotal: Double {
        openInvoices.reduce(0) { $0 + outstandingBalance(for: $1) }
    }

    private var estimatePipelineTotal: Double {
        dashboardEstimates
            .filter { estimate in
                let status = estimate.status.lowercased()
                return status != "rejected" && status != "invoiced"
            }
            .reduce(0) { $0 + $1.amount }
    }

    private var priorityItemCount: Int {
        [
            unassignedUpcomingCalls.first != nil,
            readyToBillCalls.first != nil,
            overdueInvoices.first != nil,
            maintenanceAlerts.first != nil,
            acceptedEstimateCalls.first != nil,
            quickBooksAttentionInvoices.first != nil,
            quickBooksAttentionPayments.first != nil,
            followUpCalls.first != nil,
            openBusinessTasks.first != nil,
            pendingTimeOffRequests.first != nil,
            fleetAttentionVehicles.first != nil,
            upcomingCalls.first != nil
        ]
        .filter { $0 }
        .count
    }

    private var dispatchWindowCalls: [ServiceCall] {
        let startOfToday = calendar.startOfDay(for: Date())
        let dispatchWindowEnd = calendar.date(byAdding: .day, value: 3, to: startOfToday) ?? Date()
        return dashboardServiceCalls
            .filter {
                $0.status != .cancelled &&
                $0.status != .completed &&
                $0.scheduledDate >= startOfToday &&
                $0.scheduledDate < dispatchWindowEnd
            }
            .sorted {
                if $0.scheduledDate != $1.scheduledDate {
                    return $0.scheduledDate < $1.scheduledDate
                }
                return $0.customer.name.localizedCaseInsensitiveCompare($1.customer.name) == .orderedAscending
            }
    }

    private var dispatchRiskCount: Int {
        dispatchWindowCalls.filter { !dispatchRiskReasons(for: $0).isEmpty }.count
    }

    private var clearTechnicianCountToday: Int {
        visibleTechnicians.filter { technician in
            todayCalls.allSatisfy { !$0.includesAssignedTechnician(technician.id) }
        }
        .count
    }

    private var selectedPaymentProcessor: OnsitePaymentProcessor {
        OnsitePaymentProcessor(rawValue: onsitePaymentProcessor) ?? .none
    }

    private var suiteSnapshot: BusinessSuiteSnapshot {
        BusinessSuiteIntelligence.snapshot(
            customers: dashboardCustomers,
            serviceCalls: dashboardServiceCalls,
            technicians: technicians,
            contracts: dashboardContracts,
            estimates: dashboardEstimates,
            invoices: dashboardInvoices,
            payments: dashboardPayments,
            attachments: attachments,
            communications: dashboardCommunications,
            timeEntries: timeEntries,
            items: items,
            vendors: vendors,
            googleConnected: googleAuth.isAuthenticated,
            quickBooksConnected: QuickBooksDataAPI.shared.isAuthenticated,
            onsitePaymentsReady: enableOnsitePayments && onsitePaymentProcessorReady,
            now: Date(),
            calendar: calendar
        )
    }

    private var accountSnapshots: [CustomerIntelligenceSnapshot] {
        CustomerIntelligence.snapshots(
            customers: dashboardCustomers,
            serviceCalls: dashboardServiceCalls,
            invoices: dashboardInvoices,
            estimates: dashboardEstimates,
            payments: dashboardPayments,
            contracts: dashboardContracts,
            now: Date(),
            calendar: calendar
        )
    }

    private var activeAccountSnapshots: [CustomerIntelligenceSnapshot] {
        accountSnapshots.filter {
            $0.hasRisk ||
            $0.hasOpenWork ||
            $0.activeContractCount > 0 ||
            $0.openEstimateCount > 0
        }
    }

    private var atRiskAccountCount: Int {
        accountSnapshots.filter { $0.healthScore < 70 || $0.overdueInvoiceCount > 0 }.count
    }

    private var accountOpenBalanceTotal: Double {
        accountSnapshots.reduce(0) { $0 + $1.openBalance }
    }

    private var accountPipelineTotal: Double {
        accountSnapshots.reduce(0) { $0 + $1.openEstimateTotal }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                WatermarkBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        headerSection
                        metricsGrid
                        priorityQueueSection
                        if operationsAccess.canSearchJobs {
                            dispatchIntelligenceSection
                        }
                        if operationsAccess.canShowBusinessOverview {
                            DisclosureGroup(isExpanded: $isBusinessOverviewExpanded) {
                                VStack(alignment: .leading, spacing: 18) {
                                    suiteSynchronizationSection
                                    accountIntelligenceSection
                                    workflowSection
                                }
                                .padding(.top, 12)
                            } label: {
                                Label("Business overview", systemImage: "chart.bar.xaxis")
                                    .font(.headline)
                            }
                            .padding(14)
                            .background(Color(.secondarySystemBackground).opacity(0.64), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        DisclosureGroup(isExpanded: $isOperationalStatusExpanded) {
                            VStack(alignment: .leading, spacing: 18) {
                                fieldTeamSection
                                systemsSection
                            }
                            .padding(.top, 12)
                        } label: {
                            Label("Field and system status", systemImage: "checklist.checked")
                                .font(.headline)
                        }
                        .padding(14)
                        .background(Color(.secondarySystemBackground).opacity(0.64), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 14)
                }
            }
            .navigationTitle("Command Center")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingCommandPalette = true
                    } label: {
                        Label("Find", systemImage: "magnifyingglass")
                    }
                    .accessibilityLabel("Search Command Center")
                    .accessibilityIdentifier("CommandCenterToolbarFindButton")
                    .tint(Color.brandGold)
                }
            }
            .sheet(isPresented: $showingCommandPalette) {
                OperationsCommandPalette(
                    customers: searchableCustomers,
                    serviceCalls: dashboardServiceCalls,
                    invoices: dashboardInvoices,
                    estimates: dashboardEstimates,
                    payments: dashboardPayments,
                    access: operationsAccess
                )
                    .tint(Color.brandGold)
            }
            .sheet(isPresented: $showingFleetWorkspace) {
                FleetWorkspaceView()
                    .tint(Color.brandGold)
            }
            .sheet(isPresented: $showingBusinessTasks) {
                BusinessTaskWorkspaceView()
                    .tint(Color.brandGold)
            }
            .sheet(isPresented: $showingTimeOffRequests) {
                TechnicianTimeOffWorkspaceSheet()
                    .tint(Color.brandGold)
            }
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 54, height: 54)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("GunnAire Command Center")
                        .font(.title2.weight(.bold))
                    Text(Date(), format: .dateTime.weekday(.wide).month(.wide).day().year())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Group {
                if horizontalSizeClass == .compact {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        commandCenterQuickActions
                    }
                } else {
                    HStack(spacing: 10) {
                        commandCenterQuickActions
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.brandGold)
            .foregroundStyle(Color.primaryBlack)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var commandCenterQuickActions: some View {
        Button {
            showingCommandPalette = true
        } label: {
            Label("Find", systemImage: "magnifyingglass")
                .frame(maxWidth: .infinity)
        }
        .accessibilityLabel("Find customers and work from Command Center")
        .accessibilityIdentifier("CommandCenterQuickFindButton")

        if operationsAccess.canOpenSchedule {
            Button {
                GunnAireAppIntentRouter.store(.schedule)
            } label: {
                Label("Schedule", systemImage: "calendar.badge.clock")
                    .frame(maxWidth: .infinity)
            }
            .accessibilityLabel("Open schedule from Command Center")
        }

        Button {
            showingBusinessTasks = true
        } label: {
            Label("Tasks", systemImage: "checklist")
                .frame(maxWidth: .infinity)
        }

        if canCollectFieldPayments {
            Button {
                GunnAireAppIntentRouter.store(.payments)
            } label: {
                Label("Collect", systemImage: "creditcard")
                    .frame(maxWidth: .infinity)
            }
            .accessibilityLabel("Open payment collection from Command Center")
        }

        if operationsAccess.canOpenSync {
            Button {
                GunnAireAppIntentRouter.store(.sync)
            } label: {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var metricsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            if operationsAccess.canSearchJobs {
                metricCard(
                    title: "Today",
                    value: "\(todayCalls.count)",
                    detail: "\(inProgressCalls.count) active",
                    systemImage: "calendar",
                    tint: Color.brandGold
                )
            }
            if operationsAccess.canOpenDocumentation && canViewFinancials {
                metricCard(
                    title: "Ready To Bill",
                    value: "\(readyToBillCalls.count)",
                    detail: currency(monthInvoiceTotal) + " this month",
                    systemImage: "doc.badge.plus",
                    tint: .green
                )
            }
            if canViewFinancials {
                metricCard(
                    title: "Receivables",
                    value: currency(openReceivablesTotal),
                    detail: "\(overdueInvoices.count) overdue",
                    systemImage: "dollarsign.circle",
                    tint: overdueInvoices.isEmpty ? Color.brandGold : .red
                )
            }
            if operationsAccess.canSearchJobs {
                metricCard(
                    title: "Agreements",
                    value: "\(maintenanceAlerts.count)",
                    detail: "\(dashboardContracts.filter(\.active).count) active",
                    systemImage: "repeat.circle",
                    tint: maintenanceAlerts.isEmpty ? Color.brandGold : .orange
                )
            }
            if operationsAccess.canSearchJobs || AppAccess.canReviewTeamTime(email: currentUserEmail, users: users) {
                metricCard(
                    title: "Field Team",
                    value: "\(openTimeEntries.count)",
                    detail: operationsAccess.canSearchJobs ? "\(unassignedUpcomingCalls.count) unassigned" : "open time entries",
                    systemImage: "person.2.badge.gearshape",
                    tint: unassignedUpcomingCalls.isEmpty ? Color.brandGold : .blue
                )
            }
            if canViewFinancials {
                metricCard(
                    title: "Sync Risk",
                    value: "\(quickBooksAttentionCount)",
                    detail: "\(quickBooksAttentionInvoices.count) invoice\(quickBooksAttentionInvoices.count == 1 ? "" : "s") • \(quickBooksAttentionPayments.count) payment\(quickBooksAttentionPayments.count == 1 ? "" : "s")",
                    systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                    tint: quickBooksAttentionCount == 0 ? Color.brandGold : .red
                )
            }
        }
    }

    private var suiteSynchronizationSection: some View {
        dashboardSection(title: "Suite Synchronization", systemImage: "point.3.connected.trianglepath.dotted") {
            suiteScoreHeader

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 12)], spacing: 12) {
                ForEach(suiteSnapshot.workstreams) { workstream in
                    suiteWorkstreamCard(workstream)
                }
            }

            if suiteSnapshot.actions.isEmpty {
                emptyState("Connected workstreams show no sync exceptions.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Next Best Actions")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(suiteSnapshot.actions.prefix(5)) { action in
                        suiteActionRow(action)
                        if action.id != suiteSnapshot.actions.prefix(5).last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var priorityQueueSection: some View {
        dashboardSection(title: "Priority Queue", systemImage: "list.bullet.clipboard") {
            if priorityItemCount == 0 {
                emptyState("No priority work is waiting.")
            } else {
                if let call = unassignedUpcomingCalls.first {
                    priorityRow(
                        title: "Assign upcoming work",
                        subtitle: "\(call.customer.name) • \(call.scheduledDate.formatted(date: .abbreviated, time: .shortened))",
                        value: call.dispatchUrgency == .normal ? call.type.displayName : call.dispatchUrgency.displayName,
                        systemImage: "person.crop.circle.badge.plus",
                        tint: .blue,
                        actionTitle: "Open Schedule"
                    ) {
                        GunnAireAppIntentRouter.storeScheduleCallRoute(call.id)
                    }
                }

                if canViewFinancials, let call = readyToBillCalls.first {
                    priorityRow(
                        title: "Create invoice",
                        subtitle: "\(call.customer.name) • \(call.type.displayName)",
                        value: "Ready",
                        systemImage: "doc.badge.plus",
                        tint: .green,
                        actionTitle: "Build Invoice"
                    ) {
                        GunnAireAppIntentRouter.storeDocumentationRoute(call.id)
                    }
                }

                if canViewFinancials, let invoice = overdueInvoices.first {
                    priorityRow(
                        title: "Collect overdue balance",
                        subtitle: "\(invoice.customer.name) • \(invoice.createdAt.formatted(date: .abbreviated, time: .omitted))",
                        value: currency(outstandingBalance(for: invoice)),
                        systemImage: "creditcard.trianglebadge.exclamationmark",
                        tint: .red,
                        actionTitle: "Collect"
                    ) {
                        GunnAireAppIntentRouter.storePaymentCollectionRoute(invoice.id)
                    }
                }

                if let contract = maintenanceAlerts.first {
                    priorityRow(
                        title: maintenanceTitle(for: contract),
                        subtitle: "\(contract.customer.name) • \(contract.schedulePattern)",
                        value: contract.nextDate.formatted(date: .abbreviated, time: .omitted),
                        systemImage: "wrench.and.screwdriver",
                        tint: .orange,
                        actionTitle: "Schedule"
                    ) {
                        GunnAireAppIntentRouter.store(.schedule)
                    }
                }

                if canViewFinancials, let call = acceptedEstimateCalls.first {
                    priorityRow(
                        title: "Approved work waiting",
                        subtitle: "\(call.customer.name) • estimate accepted",
                        value: estimate(for: call).map { currency($0.amount) } ?? "Accepted",
                        systemImage: "checkmark.seal",
                        tint: .green,
                        actionTitle: "Open Job"
                    ) {
                        GunnAireAppIntentRouter.storeScheduleCallRoute(call.id)
                    }
                }

                if canViewFinancials, let invoice = quickBooksAttentionInvoices.first {
                    priorityRow(
                        title: invoice.needsQuickBooksAttention ? "QuickBooks invoice needs attention" : "QuickBooks invoice pending",
                        subtitle: invoice.customer.name,
                        value: currency(invoice.amount),
                        systemImage: "doc.badge.arrow.up",
                        tint: invoice.needsQuickBooksAttention ? .red : .orange,
                        actionTitle: "Review"
                    ) {
                        if operationsAccess.canManageQuickBooks {
                            GunnAireAppIntentRouter.storeQuickBooksRoute(workspace: .sales)
                        } else {
                            GunnAireAppIntentRouter.store(.invoices)
                        }
                    }
                }

                if canViewFinancials, let payment = quickBooksAttentionPayments.first {
                    priorityRow(
                        title: "QuickBooks payment sync",
                        subtitle: payment.invoice.customer.name,
                        value: currency(payment.amount),
                        systemImage: "arrow.triangle.2.circlepath.circle",
                        tint: .red,
                        actionTitle: "Review"
                    ) {
                        GunnAireAppIntentRouter.store(.payments)
                    }
                }

                if let call = followUpCalls.first {
                    priorityRow(
                        title: "Customer follow-up",
                        subtitle: followUpSubtitle(for: call),
                        value: call.customer.name,
                        systemImage: "arrow.uturn.forward.circle",
                        tint: Color.brandGold,
                        actionTitle: "Open"
                    ) {
                        GunnAireAppIntentRouter.storeScheduleCallRoute(call.id)
                    }
                }

                if let task = openBusinessTasks.first {
                    priorityRow(
                        title: task.isOverdue() ? "Overdue team task" : "Team task",
                        subtitle: task.linkedRecordSummary ?? "Internal follow-up",
                        value: AppAccess.inferredDisplayName(fromEmail: task.assignedToEmail),
                        systemImage: task.priority.systemImage,
                        tint: task.isOverdue() || task.priority == .urgent ? .red : Color.brandGold,
                        actionTitle: "Review"
                    ) {
                        showingBusinessTasks = true
                    }
                    .accessibilityIdentifier("ReviewBusinessTask")
                }

                if let request = pendingTimeOffRequests.first {
                    priorityRow(
                        title: "Time-off request",
                        subtitle: "\(request.technicianNameSnapshot) • capacity review required",
                        value: request.startsAt.formatted(date: .abbreviated, time: .omitted),
                        systemImage: "calendar.badge.clock",
                        tint: .orange,
                        actionTitle: "Review"
                    ) {
                        showingTimeOffRequests = true
                    }
                    .accessibilityLabel(
                        "Time-off request, \(request.technicianNameSnapshot), capacity review required, \(request.startsAt.formatted(date: .abbreviated, time: .omitted)), Review"
                    )
                    .accessibilityIdentifier("ReviewTimeOffRequest")
                }

                if let vehicle = fleetAttentionVehicles.first {
                    priorityRow(
                        title: "Fleet readiness",
                        subtitle: "\(vehicle.unitNumber) • \(vehicle.assignedTechnicianName ?? "Unassigned")",
                        value: vehicle.readiness().title,
                        systemImage: "car.rear.and.tire.marks",
                        tint: vehicle.administrativeStatus == .outOfService ? .red : .orange,
                        actionTitle: "Review"
                    ) {
                        showingFleetWorkspace = true
                    }
                    .accessibilityIdentifier("ReviewFleetReadiness")
                }

                if let call = upcomingCalls.first {
                    priorityRow(
                        title: "Next scheduled job",
                        subtitle: "\(call.customer.name) • \(call.type.displayName)",
                        value: call.scheduledDate.formatted(date: .omitted, time: .shortened),
                        systemImage: "clock.badge.checkmark",
                        tint: Color.brandGold,
                        actionTitle: "Open"
                    ) {
                        GunnAireAppIntentRouter.storeScheduleCallRoute(call.id)
                    }
                }
            }
        }
    }

    private var dispatchIntelligenceSection: some View {
        dashboardSection(title: "Dispatch Intelligence", systemImage: "location.north.line") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 156), spacing: 12)], spacing: 12) {
                dispatchMetric(
                    title: "Dispatch Window",
                    value: "\(dispatchWindowCalls.count)",
                    detail: "next 72 hours",
                    systemImage: "calendar.badge.clock",
                    tint: Color.brandGold
                )
                dispatchMetric(
                    title: "Unassigned",
                    value: "\(unassignedUpcomingCalls.count)",
                    detail: "this week",
                    systemImage: "person.crop.circle.badge.questionmark",
                    tint: unassignedUpcomingCalls.isEmpty ? .green : .blue
                )
                dispatchMetric(
                    title: "Capacity",
                    value: "\(clearTechnicianCountToday)",
                    detail: "\(visibleTechnicians.count) technicians",
                    systemImage: "person.2.wave.2",
                    tint: clearTechnicianCountToday == 0 && !visibleTechnicians.isEmpty ? .orange : .green
                )
                dispatchMetric(
                    title: "Risk Flags",
                    value: "\(dispatchRiskCount)",
                    detail: "needs review",
                    systemImage: "exclamationmark.triangle",
                    tint: dispatchRiskCount == 0 ? .green : .orange
                )
            }

            if let dispatchMessage {
                Text(dispatchMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
            }

            if dispatchWindowCalls.isEmpty {
                emptyState("No active dispatch work is inside the next 72 hours.")
            } else {
                ForEach(dispatchWindowCalls.prefix(5)) { call in
                    dispatchRow(for: call)
                    if call.id != dispatchWindowCalls.prefix(5).last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private var accountIntelligenceSection: some View {
        dashboardSection(title: "Account Intelligence", systemImage: "person.crop.rectangle.stack") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 156), spacing: 12)], spacing: 12) {
                dispatchMetric(
                    title: "Watched Accounts",
                    value: "\(atRiskAccountCount)",
                    detail: "\(dashboardCustomers.count) total",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    tint: atRiskAccountCount == 0 ? .green : .orange
                )
                dispatchMetric(
                    title: "Open Balance",
                    value: currency(accountOpenBalanceTotal),
                    detail: "\(openInvoices.count) invoices",
                    systemImage: "creditcard.trianglebadge.exclamationmark",
                    tint: accountOpenBalanceTotal > 0 ? .red : .green
                )
                dispatchMetric(
                    title: "Estimate Pipeline",
                    value: currency(accountPipelineTotal),
                    detail: "\(openEstimateCount) open",
                    systemImage: "chart.bar.doc.horizontal",
                    tint: Color.brandGold
                )
            }

            if dashboardCustomers.isEmpty {
                emptyState("No customer accounts are on file yet.")
            } else if activeAccountSnapshots.isEmpty {
                emptyState("Customer accounts are current across payments, agreements, and scheduled work.")
            } else {
                ForEach(Array(activeAccountSnapshots.prefix(5))) { snapshot in
                    accountIntelligenceRow(for: snapshot)
                    if snapshot.id != activeAccountSnapshots.prefix(5).last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private var workflowSection: some View {
        dashboardSection(title: "Revenue & Workflow", systemImage: "chart.line.uptrend.xyaxis") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                workflowCard(
                    title: "Month Invoiced",
                    value: currency(monthInvoiceTotal),
                    detail: "\(invoicesThisMonthCount) invoices",
                    systemImage: "doc.text"
                )
                workflowCard(
                    title: "Month Collected",
                    value: currency(monthPaymentsCollected),
                    detail: "\(paymentsThisMonthCount) payments",
                    systemImage: "banknote"
                )
                workflowCard(
                    title: "Estimate Pipeline",
                    value: currency(estimatePipelineTotal),
                    detail: "\(openEstimateCount) open estimates",
                    systemImage: "doc.text.magnifyingglass"
                )
                workflowCard(
                    title: "Open Balances",
                    value: currency(openReceivablesTotal),
                    detail: "\(openInvoices.count) collectible invoices",
                    systemImage: "tray.full"
                )
            }
        }
    }

    private var fieldTeamSection: some View {
        dashboardSection(title: "Field Team", systemImage: "person.2") {
            if visibleTechnicians.isEmpty && unassignedUpcomingCalls.isEmpty && visibleFleetVehicles.isEmpty && !isAdminUser {
                emptyState("No technicians or upcoming assignments yet.")
            } else {
                if !visibleFleetVehicles.isEmpty || isAdminUser {
                    summaryStrip(
                        title: fleetSummaryTitle,
                        subtitle: fleetSummaryDetail,
                        systemImage: fleetAttentionVehicles.isEmpty ? "car.fill" : "car.rear.and.tire.marks",
                        tint: fleetAttentionVehicles.isEmpty ? .green : .orange
                    ) {
                        showingFleetWorkspace = true
                    }
                    .accessibilityIdentifier("OpenFleetWorkspace")
                }

                if !unassignedUpcomingCalls.isEmpty {
                    summaryStrip(
                        title: "\(unassignedUpcomingCalls.count) unassigned job\(unassignedUpcomingCalls.count == 1 ? "" : "s") this week",
                        subtitle: unassignedUpcomingCalls.prefix(2).map { $0.customer.name }.joined(separator: ", "),
                        systemImage: "person.slash",
                        tint: .blue
                    ) {
                        GunnAireAppIntentRouter.store(.schedule)
                    }
                }

                ForEach(technicianLoads.prefix(6)) { load in
                    HStack(spacing: 12) {
                        Image(systemName: load.isClockedIn ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                            .foregroundStyle(load.isClockedIn ? .green : Color.brandGold)
                            .font(.title3)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(load.name)
                                .font(.subheadline.weight(.semibold))
                            Text(load.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 3) {
                            Text("\(load.todayCount)")
                                .font(.headline)
                            Text("today")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)

                    if load.id != technicianLoads.prefix(6).last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private var fleetSummaryTitle: String {
        if visibleFleetVehicles.isEmpty {
            return "Add fleet vehicles"
        }
        if fleetAttentionVehicles.isEmpty {
            return "Fleet ready"
        }
        return "\(fleetAttentionVehicles.count) fleet vehicle\(fleetAttentionVehicles.count == 1 ? "" : "s") need attention"
    }

    private var fleetSummaryDetail: String {
        if visibleFleetVehicles.isEmpty {
            return "Connect each service truck, technician, and stock location."
        }
        if let vehicle = fleetAttentionVehicles.first {
            return "\(vehicle.unitNumber) • \(vehicle.readiness().title)"
        }
        return "\(visibleFleetVehicles.count) vehicle\(visibleFleetVehicles.count == 1 ? "" : "s") dispatch-ready"
    }

    private var systemsSection: some View {
        dashboardSection(title: "Connected Systems", systemImage: "point.3.connected.trianglepath.dotted") {
            if operationsAccess.canSearchJobs || operationsAccess.canOpenSync {
                systemRow(
                    title: "Google Calendar",
                    status: googleAuth.isAuthenticated ? "Connected" : "Disconnected",
                    detail: "\(linkedCalendarJobCount) linked jobs",
                    systemImage: "calendar.badge.checkmark",
                    tint: googleAuth.isAuthenticated ? .green : .orange
                ) {
                    GunnAireAppIntentRouter.store(operationsAccess.canOpenSync ? .sync : .schedule)
                }
            }

            if canViewFinancials {
                if operationsAccess.canSearchJobs || operationsAccess.canOpenSync {
                    Divider()
                }
                systemRow(
                    title: "QuickBooks",
                    status: QuickBooksDataAPI.shared.isAuthenticated ? "Connected" : "Disconnected",
                    detail: "\(linkedInvoiceCount) linked invoices • \(linkedEstimateCount) linked estimates",
                    systemImage: "banknote",
                    tint: QuickBooksDataAPI.shared.isAuthenticated ? .green : .orange
                ) {
                    GunnAireAppIntentRouter.store(operationsAccess.canManageQuickBooks ? .quickBooks : .invoices)
                }
            }

            if canCollectFieldPayments {
                Divider()

                systemRow(
                    title: "On-Site Payments",
                    status: onsitePaymentsStatus,
                    detail: selectedPaymentProcessor.displayName,
                    systemImage: "iphone.gen3.radiowaves.left.and.right",
                    tint: onsitePaymentsTint
                ) {
                    GunnAireAppIntentRouter.store(.payments)
                }
            }
        }
    }

    private func dashboardSection<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(Color.brandGold)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func metricCard(
        title: String,
        value: String,
        detail: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                Spacer()
            }
            Text(value)
                .font(.title3.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(title)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemBackground).opacity(0.76), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func dispatchMetric(
        title: String,
        value: String,
        detail: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground).opacity(0.64), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var suiteScoreHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .stroke(suiteTint(for: suiteSnapshot.healthScore).opacity(0.24), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: CGFloat(suiteSnapshot.healthScore) / 100)
                    .stroke(suiteTint(for: suiteSnapshot.healthScore), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(suiteSnapshot.healthScore)")
                        .font(.title3.weight(.bold))
                    Text("score")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 82, height: 82)

            VStack(alignment: .leading, spacing: 6) {
                Text(suiteSnapshot.healthLabel)
                    .font(.headline)
                    .foregroundStyle(suiteTint(for: suiteSnapshot.healthScore))
                Text(suiteSnapshot.healthDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    suiteSignalPill("\(suiteSnapshot.openWorkCount)", label: "open work")
                    suiteSignalPill(currency(suiteSnapshot.monthPaymentTotal), label: "collected")
                    suiteSignalPill("\(suiteSnapshot.pricebookAttentionCount)", label: "pricebook")
                    suiteSignalPill("\(suiteSnapshot.syncAttentionCount)", label: "sync")
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground).opacity(0.64), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func suiteSignalPill(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func suiteWorkstreamCard(_ workstream: BusinessSuiteWorkstream) -> some View {
        Button {
            perform(workstream.destination)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: workstream.systemImage)
                        .foregroundStyle(suiteSeverityTint(workstream.severity))
                    Spacer()
                    Text("\(workstream.score)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(suiteSeverityTint(workstream.severity))
                }

                Text(workstream.value)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(workstream.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(workstream.status)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(suiteSeverityTint(workstream.severity))
                Text(workstream.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(.secondarySystemBackground).opacity(0.64), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func suiteActionRow(_ action: BusinessSuiteAction) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: action.systemImage)
                .foregroundStyle(suiteSeverityTint(action.severity))
                .font(.title3)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(action.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(action.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                Text(action.value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Button {
                    perform(action.destination)
                } label: {
                    Label("Open", systemImage: "arrow.right.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(suiteSeverityTint(action.severity))
            }
        }
        .padding(.vertical, 2)
    }

    private func workflowCard(
        title: String,
        value: String,
        detail: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.brandGold)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground).opacity(0.64), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func accountIntelligenceRow(for snapshot: CustomerIntelligenceSnapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: accountHealthIcon(for: snapshot))
                .foregroundStyle(accountHealthTint(for: snapshot))
                .font(.title3)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(snapshot.customer.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(snapshot.healthLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accountHealthTint(for: snapshot))
                }

                Text(snapshot.actionDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    if snapshot.openBalance > 0 {
                        Label(currency(snapshot.openBalance), systemImage: "creditcard")
                    }
                    if snapshot.readyToBillCount > 0 {
                        Label("\(snapshot.readyToBillCount) ready", systemImage: "doc.badge.plus")
                    }
                    if snapshot.activeContractCount > 0 {
                        Label("\(snapshot.activeContractCount) agreements", systemImage: "repeat.circle")
                    }
                    if snapshot.syncAttentionCount > 0 {
                        Label("sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                Text("\(snapshot.healthScore)")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(accountHealthTint(for: snapshot))
                Button {
                    perform(snapshot.primaryAction)
                } label: {
                    Label(snapshot.primaryAction.title, systemImage: snapshot.primaryAction.systemImage)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(accountHealthTint(for: snapshot))
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func dispatchRow(for call: ServiceCall) -> some View {
        let risks = dispatchRiskReasons(for: call)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: dispatchIconName(for: call))
                    .foregroundStyle(risks.isEmpty ? Color.brandGold : .orange)
                    .font(.title3)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(call.customer.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(call.type.displayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.brandGold)
                    }

                    Text(dispatchDetail(for: call))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    if !risks.isEmpty {
                        Text(risks.joined(separator: " • "))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(call.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(call.status.rawValue.capitalized)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Button {
                    GunnAireAppIntentRouter.storeScheduleCallRoute(call.id)
                } label: {
                    Label("Open", systemImage: "arrow.right.circle")
                }
                .accessibilityLabel(dispatchActionAccessibilityLabel("Open schedule", for: call))

                Button {
                    GunnAireAppIntentRouter.storeDocumentationRoute(call.id)
                } label: {
                    Label("Docs", systemImage: "doc.text")
                }
                .accessibilityLabel(dispatchActionAccessibilityLabel("Open documents", for: call))

                if operationsAccess.canManageDispatch,
                   call.assignedTechnician == nil,
                   !assignableTechnicians.isEmpty {
                    assignmentMenu(for: call)
                }

                if let linkedInvoiceID = call.linkedInvoiceID,
                   let invoice = invoice(for: call),
                   outstandingBalance(for: invoice) > 0 {
                    Button {
                        GunnAireAppIntentRouter.storePaymentCollectionRoute(linkedInvoiceID)
                    } label: {
                        Label("Collect", systemImage: "creditcard")
                    }
                    .accessibilityLabel(dispatchActionAccessibilityLabel("Collect payment", for: call))
                    .tint(.green)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(Color.brandGold)
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("CommandCenterDispatchJob-\(call.id.uuidString)")
    }

    private func dispatchActionAccessibilityLabel(_ action: String, for call: ServiceCall) -> String {
        "\(action) for \(call.customer.name), \(call.type.displayName), \(call.scheduledDate.formatted(date: .abbreviated, time: .shortened))"
    }

    private func priorityRow(
        title: String,
        subtitle: String,
        value: String,
        systemImage: String,
        tint: Color,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .font(.title3)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                Text(value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Color.brandGold)
                    .accessibilityLabel("\(actionTitle): \(title). \(subtitle)")
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground).opacity(0.64), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func systemRow(
        title: String,
        status: String,
        detail: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .font(.title3)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer()

            Button(status, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(tint)
                .accessibilityLabel("\(status) \(title). \(detail)")
        }
    }

    private func summaryStrip(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground).opacity(0.64), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(.secondarySystemBackground).opacity(0.54), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var invoicesThisMonthCount: Int {
        dashboardInvoices.filter { calendar.isDate($0.createdAt, equalTo: Date(), toGranularity: .month) }.count
    }

    private var paymentsThisMonthCount: Int {
        dashboardPayments.filter { calendar.isDate($0.date, equalTo: Date(), toGranularity: .month) }.count
    }

    private var openEstimateCount: Int {
        dashboardEstimates.filter {
            let status = $0.status.lowercased()
            return status != "rejected" && status != "invoiced"
        }.count
    }

    private var linkedCalendarJobCount: Int {
        dashboardServiceCalls.filter { $0.googleEventID?.isEmpty == false }.count
    }

    private var linkedInvoiceCount: Int {
        dashboardInvoices.filter { $0.quickBooksID?.isEmpty == false }.count
    }

    private var linkedEstimateCount: Int {
        dashboardEstimates.filter { $0.quickBooksID?.isEmpty == false }.count
    }

    private var onsitePaymentsStatus: String {
        guard enableOnsitePayments else { return "Disabled" }
        return onsitePaymentProcessorReady ? "Ready" : "Setup Required"
    }

    private var onsitePaymentsTint: Color {
        guard enableOnsitePayments else { return .secondary }
        return onsitePaymentProcessorReady ? .green : .orange
    }

    private var technicianLoads: [TechnicianLoad] {
        visibleTechnicians
            .map { technician in
                let todaysJobs = todayCalls.filter { $0.includesAssignedTechnician(technician.id) }
                let weekJobs = upcomingCalls.filter { $0.includesAssignedTechnician(technician.id) }
                let nextJob = weekJobs.first
                let isClockedIn = openTimeEntries.contains { entry in
                    AppAccess.normalizedEmail(entry.userEmail) == AppAccess.normalizedEmail(technician.contactInfo)
                }
                let detail = nextJob.map {
                    "Next: \($0.customer.name) at \($0.scheduledDate.formatted(date: .omitted, time: .shortened))"
                } ?? "\(weekJobs.count) jobs this week"
                return TechnicianLoad(
                    id: technician.id,
                    name: technician.name,
                    todayCount: todaysJobs.count,
                    weekCount: weekJobs.count,
                    isClockedIn: isClockedIn,
                    detail: detail
                )
            }
            .sorted {
                if $0.isClockedIn != $1.isClockedIn { return $0.isClockedIn }
                if $0.todayCount != $1.todayCount { return $0.todayCount > $1.todayCount }
                if $0.weekCount != $1.weekCount { return $0.weekCount > $1.weekCount }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    private func outstandingBalance(for invoice: Invoice) -> Double {
        Invoice.outstandingBalance(for: invoice, payments: dashboardPayments)
    }

    private func estimate(for call: ServiceCall) -> Estimate? {
        guard let estimateID = call.linkedEstimateID else { return nil }
        return dashboardEstimates.first { $0.id == estimateID }
    }

    private func invoice(for call: ServiceCall) -> Invoice? {
        guard let invoiceID = call.linkedInvoiceID else { return nil }
        return dashboardInvoices.first { $0.id == invoiceID }
    }

    private func dispatchIconName(for call: ServiceCall) -> String {
        switch call.type {
        case .service:
            return "wrench.adjustable"
        case .repair:
            return "wrench.and.screwdriver"
        case .estimate:
            return "doc.text.magnifyingglass"
        case .replacement:
            return "shippingbox.and.arrow.backward"
        case .install:
            return "hammer"
        case .maintenance:
            return "repeat.circle"
        case .meeting:
            return "person.2"
        case .reminder:
            return "bell"
        case .siteVisit:
            return "mappin.and.ellipse"
        case .other:
            return "calendar"
        }
    }

    private func dispatchDetail(for call: ServiceCall) -> String {
        let technician = call.assignedTechnician?.name ?? "Unassigned"
        let address = (call.siteAddress ?? call.customer.address)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let addressLabel = address?.isEmpty == false ? address! : "No service address"
        return "\(technician) • \(addressLabel)"
    }

    private func dispatchRiskReasons(for call: ServiceCall) -> [String] {
        var reasons: [String] = []
        let address = (call.siteAddress ?? call.customer.address)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if call.assignedTechnician == nil {
            reasons.append("Unassigned")
        }
        if address?.isEmpty != false {
            reasons.append("No address")
        }
        if call.scheduledDate < Date(), call.status == .scheduled {
            reasons.append("Past start")
        }
        if googleAuth.isAuthenticated && call.googleEventID == nil {
            reasons.append("Calendar not linked")
        }
        if call.assignedTechnician != nil,
           ServiceCalendarRouting.hasStaleAssignedCalendarRoute(
            calendarID: call.googleCalendarID,
            technician: call.assignedTechnician
           ) {
            reasons.append("Calendar route")
        }
        if call.isReadyToCreateBillingDocument {
            reasons.append("Ready to bill")
        }
        if let invoice = invoice(for: call) {
            let readiness = closeoutReadiness(for: call, invoice: invoice)
            if !readiness.isReady, let missing = readiness.missingActionItems.first {
                reasons.append(missing)
            }
        }
        if call.followUpRequired {
            reasons.append("Follow-up")
        }

        return reasons
    }

    private func closeoutReadiness(for call: ServiceCall, invoice: Invoice?) -> JobCloseoutReadiness {
        call.closeoutReadiness(
            invoice: invoice,
            payments: dashboardPayments.filter { payment in
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
                estimates: dashboardEstimates,
                projectMilestones: projectMilestones,
                items: items,
                movements: inventoryMovements
            ),
            serviceCallActivities: serviceCallActivities,
            requireWorkPerformedLog: requireWorkPerformedLogForCloseout
        )
    }

    @ViewBuilder
    private func assignmentMenu(for call: ServiceCall) -> some View {
        Menu {
            if let bestTechnician = bestTechnician(for: call) {
                Button("Best fit: \(bestTechnician.name)") {
                    assign(call, to: bestTechnician)
                }
            }

            ForEach(assignableTechnicians) { technician in
                Button(assignmentTitle(for: call, technician: technician)) {
                    assign(call, to: technician)
                }
            }
        } label: {
            Label("Assign", systemImage: "person.crop.circle.badge.plus")
        }
        .accessibilityIdentifier("CommandCenterAssign-\(call.id.uuidString)")
    }

    private func assignmentTitle(for call: ServiceCall, technician: Technician) -> String {
        let technicianLabel = AppAccess.scheduleLabel(for: technician)
        let qualification = technician.qualification(for: call.equipmentType)
        let qualificationSuffix = qualification.assignmentNotice.map { " • \($0)" } ?? ""
        let areaMatch = technician.serviceAreaMatch(for: call.siteAddress ?? call.customer.address)
        let areaSuffix = areaMatch == .covered ? "" : " • \(areaMatch.dispatchDetail.lowercased())"
        guard let nextStart = nextAvailableStart(for: technician, call: call) else {
            let scheduleSuffix = TechnicianWorkShiftPolicy.hasConfiguredSchedule(
                technicianID: technician.id,
                shifts: technicianWorkShifts
            ) ? " • no scheduled hours" : ""
            return technicianLabel + scheduleSuffix + qualificationSuffix + areaSuffix
        }
        guard nextStart > call.scheduledDate else {
            let coverage = TechnicianWorkShiftPolicy.coverage(
                technicianID: technician.id,
                start: call.scheduledDate,
                end: call.scheduledDate.addingTimeInterval(max(call.duration, 60)),
                shifts: technicianWorkShifts,
                allowOnCall: call.dispatchUrgency == .priority || call.dispatchUrgency == .emergency
            )
            let scheduleSuffix = coverage == .onCall ? " • on call" : ""
            return technicianLabel + scheduleSuffix + qualificationSuffix + areaSuffix
        }
        return "\(technicianLabel) • move to \(nextStart.formatted(date: .omitted, time: .shortened))\(qualificationSuffix)\(areaSuffix)"
    }

    private func assign(_ call: ServiceCall, to technician: Technician) {
        guard AppAccess.canPerformScheduleMutation(
            .assignTechnician,
            email: currentUserEmail,
            users: users
        ) else {
            dispatchMessage = "Your business account has read-only schedule access. Dispatch or an administrator must assign technicians."
            return
        }
        let originalStart = call.scheduledDate
        let previousTechnician = call.assignedTechnician?.name
        let nextStart = nextAvailableStart(for: technician, call: call)
        if nextStart == nil,
           TechnicianWorkShiftPolicy.hasConfiguredSchedule(
            technicianID: technician.id,
            shifts: technicianWorkShifts
           ) {
            dispatchMessage = "\(technician.name) has no eligible recurring hours in the next \(TechnicianWorkShiftPolicy.recommendationHorizonDays) days. Review Technician Availability before assigning this job."
            return
        }
        call.assignedTechnician = technician
        if GoogleCalendarScheduleSync.shouldSelectGoogleCalendarBeforeCreate(for: call) {
            call.googleCalendarID = ServiceCalendarRouting.assignedCalendarID(for: technician)
        }

        if let nextStart, nextStart > originalStart {
            call.scheduledDate = nextStart
            dispatchMessage = "\(call.customer.name) assigned to \(technician.name) and moved to \(nextStart.formatted(date: .abbreviated, time: .shortened))."
        } else {
            dispatchMessage = "\(call.customer.name) assigned to \(technician.name)."
        }
        let assignment = previousTechnician.map { "Reassigned from \($0) to \(technician.name)." } ?? "Assigned to \(technician.name)."
        let moved = call.scheduledDate != originalStart
            ? " Moved from \(originalStart.formatted(date: .abbreviated, time: .shortened)) to \(call.scheduledDate.formatted(date: .abbreviated, time: .shortened))."
            : ""
        ServiceCallActivity.record(
            for: call,
            action: moved.isEmpty ? "Technician assigned" : "Assignment and schedule updated",
            detail: assignment + moved,
            actorEmail: currentUserEmail,
            in: modelContext
        )

        guard GoogleCalendarScheduleSync.shouldPublishAfterLocalSave(for: call) else {
            try? modelContext.save()
            dispatchMessage = "\(dispatchMessage ?? "") Google-owned calendar event left unchanged."
            return
        }
        GoogleCalendarScheduleSync.markCalendarCallLocallyEdited(call)
        publishToGoogleCalendar(call)
    }

    private func publishToGoogleCalendar(_ call: ServiceCall) {
        guard googleAuth.isAuthenticated else { return }
        try? modelContext.save()
        GoogleCalendarScheduleSync.exportImmediately(
            call: call,
            auth: googleAuth,
            modelContext: modelContext,
            signedInEmail: currentUserEmail,
            isAdminUser: isAdminUser
        ) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    dispatchMessage = "\(call.customer.name) calendar update published."
                case .failure(let error):
                    dispatchMessage = "Calendar update failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func bestTechnician(for call: ServiceCall) -> Technician? {
        assignableTechnicians
            .compactMap { technician in
                nextAvailableStart(for: technician, call: call).map { (technician, $0) }
            }
            .sorted { lhs, rhs in
                let lhsQualification = lhs.0.qualification(for: call.equipmentType)
                let rhsQualification = rhs.0.qualification(for: call.equipmentType)
                if lhsQualification.dispatchRank != rhsQualification.dispatchRank {
                    return lhsQualification.dispatchRank < rhsQualification.dispatchRank
                }
                let lhsArea = lhs.0.serviceAreaMatch(for: call.siteAddress ?? call.customer.address)
                let rhsArea = rhs.0.serviceAreaMatch(for: call.siteAddress ?? call.customer.address)
                if lhsArea != rhsArea {
                    return lhsArea < rhsArea
                }
                if lhs.1 != rhs.1 {
                    return lhs.1 < rhs.1
                }

                let lhsWeekLoad = upcomingCalls.filter { $0.includesAssignedTechnician(lhs.0.id) }.count
                let rhsWeekLoad = upcomingCalls.filter { $0.includesAssignedTechnician(rhs.0.id) }.count
                if lhsWeekLoad != rhsWeekLoad {
                    return lhsWeekLoad < rhsWeekLoad
                }

                return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
            }
            .map { $0.0 }
            .first
    }

    private func nextAvailableStart(for technician: Technician, call: ServiceCall) -> Date? {
        TechnicianDispatchAvailability.nextAvailableStart(
            technicianID: technician.id,
            proposedStart: call.scheduledDate,
            duration: call.duration,
            serviceCalls: dashboardServiceCalls,
            availabilityBlocks: technicianAvailabilityBlocks,
            workShifts: technicianWorkShifts,
            urgency: call.dispatchUrgency
        )
    }

    private func followUpSubtitle(for call: ServiceCall) -> String {
        if let action = call.followUpAction?.trimmingCharacters(in: .whitespacesAndNewlines),
           !action.isEmpty {
            if let dueDate = call.followUpDueDate {
                return "\(action) • due \(dueDate.formatted(date: .abbreviated, time: .omitted))"
            }
            return action
        }
        return "\(call.type.displayName) • \(call.scheduledDate.formatted(date: .abbreviated, time: .shortened))"
    }

    private func maintenanceTitle(for contract: RecurringMaintenanceContract) -> String {
        if contract.isOverdue {
            return "Maintenance overdue"
        }
        if contract.needsReminder {
            return "Maintenance reminder"
        }
        return "Maintenance due soon"
    }

    private func accountHealthTint(for snapshot: CustomerIntelligenceSnapshot) -> Color {
        switch snapshot.healthScore {
        case 85...100:
            return .green
        case 70..<85:
            return Color.brandGold
        case 50..<70:
            return .orange
        default:
            return .red
        }
    }

    private func accountHealthIcon(for snapshot: CustomerIntelligenceSnapshot) -> String {
        if snapshot.overdueInvoiceCount > 0 {
            return "creditcard.trianglebadge.exclamationmark"
        }
        if snapshot.syncAttentionCount > 0 {
            return "arrow.triangle.2.circlepath.circle"
        }
        if snapshot.readyToBillCount > 0 {
            return "doc.badge.plus"
        }
        if snapshot.followUpCount > 0 {
            return "arrow.uturn.forward.circle"
        }
        return snapshot.healthScore >= 70 ? "checkmark.seal" : "exclamationmark.triangle"
    }

    private func suiteTint(for score: Int) -> Color {
        switch score {
        case 85...100:
            return .green
        case 70..<85:
            return Color.brandGold
        case 50..<70:
            return .orange
        default:
            return .red
        }
    }

    private func suiteSeverityTint(_ severity: BusinessSuiteSeverity) -> Color {
        switch severity {
        case .stable:
            return .green
        case .notice:
            return Color.brandGold
        case .warning:
            return .orange
        case .critical:
            return .red
        }
    }

    private func perform(_ action: CustomerIntelligenceAction) {
        switch action {
        case .collectPayment(let invoiceID):
            GunnAireAppIntentRouter.storePaymentCollectionRoute(invoiceID)
        case .openDocumentation(let serviceCallID):
            GunnAireAppIntentRouter.storeDocumentationRoute(serviceCallID)
        case .openSchedule(let serviceCallID):
            GunnAireAppIntentRouter.storeScheduleCallRoute(serviceCallID)
        case .openPayments:
            GunnAireAppIntentRouter.store(.payments)
        case .completeProfile(let customerID), .openCustomer(let customerID):
            GunnAireAppIntentRouter.storeCustomerRoute(customerID)
        }
    }

    private func perform(_ destination: BusinessSuiteDestination) {
        switch destination {
        case .commandCenter:
            GunnAireAppIntentRouter.store(.commandCenter)
        case .schedule(let serviceCallID):
            if let serviceCallID {
                GunnAireAppIntentRouter.storeScheduleCallRoute(serviceCallID)
            } else {
                GunnAireAppIntentRouter.store(.schedule)
            }
        case .documentation(let serviceCallID):
            if let serviceCallID {
                GunnAireAppIntentRouter.storeDocumentationRoute(serviceCallID)
            } else {
                GunnAireAppIntentRouter.store(.documentation)
            }
        case .collectPayment(let invoiceID):
            GunnAireAppIntentRouter.storePaymentCollectionRoute(invoiceID)
        case .customer(let customerID):
            GunnAireAppIntentRouter.storeCustomerRoute(customerID)
        case .customers:
            GunnAireAppIntentRouter.store(.customers)
        case .payments:
            GunnAireAppIntentRouter.store(.payments)
        case .sync:
            GunnAireAppIntentRouter.store(.sync)
        case .quickBooks:
            GunnAireAppIntentRouter.store(.quickBooks)
        case .quickBooksSales:
            GunnAireAppIntentRouter.storeQuickBooksRoute(workspace: .sales)
        case .estimates:
            GunnAireAppIntentRouter.store(.estimates)
        case .invoices:
            GunnAireAppIntentRouter.store(.invoices)
        case .timeClock:
            GunnAireAppIntentRouter.store(.timeClock)
        case .mail:
            GunnAireAppIntentRouter.store(.mail)
        }
    }

    private func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "USD"))
    }
}

private struct TechnicianLoad: Identifiable {
    let id: UUID
    let name: String
    let todayCount: Int
    let weekCount: Int
    let isClockedIn: Bool
    let detail: String
}

private struct OperationsCommandPalette: View {
    @Environment(\.dismiss) private var dismiss

    let customers: [Customer]
    let serviceCalls: [ServiceCall]
    let invoices: [Invoice]
    let estimates: [Estimate]
    let payments: [Payment]
    let access: OperationsAccessCapabilities

    @State private var searchText = ""

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var matchingCustomers: [Customer] {
        let query = trimmedSearch
        guard !query.isEmpty else { return Array(customers.prefix(6)) }
        return customers
            .filter {
                $0.name.localizedCaseInsensitiveContains(query) ||
                ($0.email?.localizedCaseInsensitiveContains(query) ?? false) ||
                ($0.phone?.localizedCaseInsensitiveContains(query) ?? false) ||
                ($0.address?.localizedCaseInsensitiveContains(query) ?? false)
            }
            .prefix(8)
            .map { $0 }
    }

    private var matchingServiceCalls: [ServiceCall] {
        let query = trimmedSearch
        let source = serviceCalls
            .filter { $0.status != .cancelled }
            .sorted { $0.scheduledDate > $1.scheduledDate }
        guard !query.isEmpty else { return Array(source.prefix(6)) }
        return source
            .filter {
                $0.customer.name.localizedCaseInsensitiveContains(query) ||
                $0.type.rawValue.localizedCaseInsensitiveContains(query) ||
                $0.status.rawValue.localizedCaseInsensitiveContains(query) ||
                ($0.siteAddress?.localizedCaseInsensitiveContains(query) ?? false) ||
                ($0.notes?.localizedCaseInsensitiveContains(query) ?? false)
            }
            .prefix(8)
            .map { $0 }
    }

    private var matchingInvoices: [Invoice] {
        let query = trimmedSearch
        let source = invoices.sorted { $0.createdAt > $1.createdAt }
        guard !query.isEmpty else { return Array(source.prefix(6)) }
        return source
            .filter {
                $0.customer.name.localizedCaseInsensitiveContains(query) ||
                $0.status.localizedCaseInsensitiveContains(query) ||
                $0.lineItemSummary.localizedCaseInsensitiveContains(query) ||
                ($0.quickBooksID?.localizedCaseInsensitiveContains(query) ?? false)
            }
            .prefix(8)
            .map { $0 }
    }

    private var matchingEstimates: [Estimate] {
        let query = trimmedSearch
        let source = estimates.sorted { $0.createdAt > $1.createdAt }
        guard !query.isEmpty else { return Array(source.prefix(4)) }
        return source
            .filter {
                $0.customer.name.localizedCaseInsensitiveContains(query) ||
                $0.status.localizedCaseInsensitiveContains(query) ||
                $0.lineItemSummary.localizedCaseInsensitiveContains(query) ||
                ($0.quickBooksID?.localizedCaseInsensitiveContains(query) ?? false)
            }
            .prefix(6)
            .map { $0 }
    }

    private var recentPayments: [Payment] {
        payments.sorted { $0.date > $1.date }.prefix(6).map { $0 }
    }

    var body: some View {
        NavigationStack {
            List {
                quickActionsSection
                if access.canSearchCustomers {
                    customersSection
                }
                if access.canSearchJobs {
                    jobsSection
                }
                if access.canSearchInvoices {
                    invoicesSection
                }
                if access.canSearchEstimates {
                    estimatesSection
                }
                if access.canShowRecentPayments && trimmedSearch.isEmpty {
                    recentPaymentsSection
                }
            }
            .navigationTitle("Find")
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: access.findPrompt
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var quickActionsSection: some View {
        Section("Quick Actions") {
            if access.canOpenSchedule {
                commandButton("Open Schedule", detail: "Calendar and dispatch board", systemImage: "calendar.badge.clock") {
                    GunnAireAppIntentRouter.store(.schedule)
                }
                .accessibilityIdentifier("CommandFindOpenSchedule")
            }
            if access.canCollectPayments {
                commandButton("Collect Payment", detail: "Open payment collection", systemImage: "creditcard") {
                    GunnAireAppIntentRouter.store(.payments)
                }
                .accessibilityIdentifier("CommandFindCollectPayment")
            }
            if access.canOpenDocumentation {
                commandButton("Job Documentation", detail: "Estimate, invoice, and closeout queue", systemImage: "book") {
                    GunnAireAppIntentRouter.store(.documentation)
                }
                .accessibilityIdentifier("CommandFindOpenDocumentation")
            }
            if access.canOpenInvoices && !access.canOpenSchedule {
                commandButton("Open Invoices", detail: "Billing and QuickBooks status", systemImage: "doc.text") {
                    GunnAireAppIntentRouter.store(.invoices)
                }
                .accessibilityIdentifier("CommandFindOpenInvoices")
            }
            if access.canOpenReports && !access.canOpenSchedule {
                commandButton("Open Reports", detail: "Financial and operating results", systemImage: "chart.bar.xaxis") {
                    GunnAireAppIntentRouter.store(.reports)
                }
                .accessibilityIdentifier("CommandFindOpenReports")
            }
            if access.canOpenSync {
                commandButton("Sync Systems", detail: "Google, QuickBooks, and integrations", systemImage: "arrow.triangle.2.circlepath") {
                    GunnAireAppIntentRouter.store(.sync)
                }
                .accessibilityIdentifier("CommandFindOpenSync")
            }
        }
    }

    @ViewBuilder
    private var customersSection: some View {
        if !matchingCustomers.isEmpty {
            Section("Customers") {
                ForEach(matchingCustomers) { customer in
                    commandButton(
                        customer.name,
                        detail: [customer.phone, customer.email, customer.address].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " • "),
                        systemImage: "person.crop.circle"
                    ) {
                        GunnAireAppIntentRouter.storeCustomerRoute(customer.id)
                    }
                    .accessibilityIdentifier("CommandFindCustomer-\(customer.id.uuidString)")
                }
            }
        }
    }

    @ViewBuilder
    private var jobsSection: some View {
        if !matchingServiceCalls.isEmpty {
            Section("Jobs") {
                ForEach(matchingServiceCalls) { call in
                    commandButton(
                        "\(call.customer.name) • \(call.type.displayName)",
                        detail: "\(call.scheduledDate.formatted(date: .abbreviated, time: .shortened)) • \(call.status.rawValue.capitalized)",
                        systemImage: "wrench.and.screwdriver"
                    ) {
                        GunnAireAppIntentRouter.storeScheduleCallRoute(call.id)
                    }
                    .accessibilityIdentifier("CommandFindJob-\(call.id.uuidString)")
                }
            }
        }
    }

    @ViewBuilder
    private var invoicesSection: some View {
        if !matchingInvoices.isEmpty {
            Section("Invoices") {
                ForEach(matchingInvoices) { invoice in
                    commandButton(
                        "\(invoice.customer.name) • \(invoice.amount.formatted(.currency(code: "USD")))",
                        detail: "\(invoice.status.capitalized) • \(invoice.createdAt.formatted(date: .abbreviated, time: .omitted))",
                        systemImage: "doc.text"
                    ) {
                        GunnAireAppIntentRouter.storePaymentCollectionRoute(invoice.id)
                    }
                    .accessibilityIdentifier("CommandFindInvoice-\(invoice.id.uuidString)")
                }
            }
        }
    }

    @ViewBuilder
    private var estimatesSection: some View {
        if !matchingEstimates.isEmpty {
            Section("Estimates") {
                ForEach(matchingEstimates) { estimate in
                    commandButton(
                        "\(estimate.customer.name) • \(estimate.amount.formatted(.currency(code: "USD")))",
                        detail: "\(estimate.status.capitalized) • \(estimate.createdAt.formatted(date: .abbreviated, time: .omitted))",
                        systemImage: "doc.text.magnifyingglass"
                    ) {
                        if let serviceCallID = estimate.serviceCallID {
                            GunnAireAppIntentRouter.storeDocumentationRoute(serviceCallID)
                        } else {
                            GunnAireAppIntentRouter.store(.estimates)
                        }
                    }
                    .accessibilityIdentifier("CommandFindEstimate-\(estimate.id.uuidString)")
                }
            }
        }
    }

    @ViewBuilder
    private var recentPaymentsSection: some View {
        if !recentPayments.isEmpty {
            Section("Recent Payments") {
                ForEach(recentPayments) { payment in
                    commandButton(
                        "\(payment.invoice.customer.name) • \(payment.amount.formatted(.currency(code: "USD")))",
                        detail: "\(payment.method.capitalized) • \(payment.date.formatted(date: .abbreviated, time: .omitted))",
                        systemImage: payment.needsQuickBooksAttention ? "exclamationmark.arrow.triangle.2.circlepath" : "checkmark.circle"
                    ) {
                        GunnAireAppIntentRouter.store(.payments)
                    }
                }
            }
        }
    }

    private func commandButton(_ title: String, detail: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            dismiss()
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 24)
                    .foregroundStyle(Color.brandGold)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    OperationsDashboardView(showingCommandPalette: .constant(false))
}
