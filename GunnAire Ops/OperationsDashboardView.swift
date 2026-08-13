import SwiftUI
import SwiftData

struct OperationsDashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Customer.name, order: .forward) private var customers: [Customer]
    @Query(sort: \ServiceCall.scheduledDate, order: .forward) private var serviceCalls: [ServiceCall]
    @Query(sort: \Technician.name, order: .forward) private var technicians: [Technician]
    @Query(sort: \RecurringMaintenanceContract.nextDate, order: .forward) private var recurringContracts: [RecurringMaintenanceContract]
    @Query(sort: \Estimate.createdAt, order: .reverse) private var estimates: [Estimate]
    @Query(sort: \Invoice.createdAt, order: .reverse) private var invoices: [Invoice]
    @Query(sort: \Payment.date, order: .reverse) private var payments: [Payment]
    @Query(sort: \ServiceDocumentAttachment.createdAt, order: .reverse) private var attachments: [ServiceDocumentAttachment]
    @Query(sort: \TimeEntry.clockIn, order: .reverse) private var timeEntries: [TimeEntry]
    @Query(sort: \Item.name, order: .forward) private var items: [Item]
    @Query(sort: \Vendor.name, order: .forward) private var vendors: [Vendor]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @ObservedObject private var googleAuth = GoogleAuthManager.shared
    @AppStorage("enableOnsitePayments") private var enableOnsitePayments = false
    @AppStorage("onsitePaymentProcessor") private var onsitePaymentProcessor = OnsitePaymentProcessor.none.rawValue
    @AppStorage("onsitePaymentProcessorReady") private var onsitePaymentProcessorReady = false
    @State private var dispatchMessage: String?
    @State private var showingCommandPalette = false

    private let calendar = Calendar.current

    private var currentUserEmail: String? {
        googleAuth.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail")
    }

    private var assignableTechnicians: [Technician] {
        AppAccess.schedulableTechnicians(technicians, users: users)
    }

    private var canViewFinancials: Bool {
        AppAccess.isAdmin(email: currentUserEmail, users: users)
    }

    private var canCollectFieldPayments: Bool {
        AppAccess.canCollectFieldPayments(email: currentUserEmail, users: users)
    }

    private var isAdminUser: Bool {
        AppAccess.isAdmin(email: currentUserEmail, users: users)
    }

    private var todayCalls: [ServiceCall] {
        serviceCalls
            .filter { calendar.isDate($0.scheduledDate, inSameDayAs: Date()) && $0.status != .cancelled }
            .sorted { $0.scheduledDate < $1.scheduledDate }
    }

    private var upcomingCalls: [ServiceCall] {
        let now = Date()
        let sevenDaysAhead = calendar.date(byAdding: .day, value: 7, to: now) ?? now
        return serviceCalls
            .filter { $0.status != .cancelled && $0.scheduledDate >= now && $0.scheduledDate <= sevenDaysAhead }
            .sorted { $0.scheduledDate < $1.scheduledDate }
    }

    private var inProgressCalls: [ServiceCall] {
        serviceCalls
            .filter { $0.status == .inProgress || $0.documentationStartedAt != nil && $0.documentationCompletedAt == nil }
            .sorted { $0.scheduledDate < $1.scheduledDate }
    }

    private var unassignedUpcomingCalls: [ServiceCall] {
        upcomingCalls
            .filter { $0.assignedTechnician == nil }
            .sorted { $0.scheduledDate < $1.scheduledDate }
    }

    private var readyToBillCalls: [ServiceCall] {
        serviceCalls
            .filter(\.isReadyToCreateBillingDocument)
            .sorted { $0.scheduledDate > $1.scheduledDate }
    }

    private var followUpCalls: [ServiceCall] {
        serviceCalls
            .filter { $0.followUpRequired || ($0.type == .estimate && $0.linkedInvoiceID == nil) }
            .sorted {
                let lhsDate = $0.followUpDueDate ?? $0.scheduledDate
                let rhsDate = $1.followUpDueDate ?? $1.scheduledDate
                return lhsDate < rhsDate
            }
    }

    private var maintenanceAlerts: [RecurringMaintenanceContract] {
        recurringContracts
            .filter { $0.active && ($0.isOverdue || $0.isUpcoming || $0.needsReminder) }
            .sorted { $0.nextDate < $1.nextDate }
    }

    private var acceptedEstimateCalls: [ServiceCall] {
        serviceCalls
            .filter { call in
                guard let estimate = estimate(for: call) else { return false }
                return estimate.status.caseInsensitiveCompare("accepted") == .orderedSame && call.linkedInvoiceID == nil
            }
            .sorted { $0.scheduledDate > $1.scheduledDate }
    }

    private var openInvoices: [Invoice] {
        invoices
            .filter { outstandingBalance(for: $0) > 0 }
            .sorted { outstandingBalance(for: $0) > outstandingBalance(for: $1) }
    }

    private var overdueInvoices: [Invoice] {
        let cutoff = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return openInvoices
            .filter { $0.createdAt <= cutoff }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private var quickBooksAttentionPayments: [Payment] {
        payments
            .filter(\.needsQuickBooksAttention)
            .sorted { $0.date > $1.date }
    }

    private var openTimeEntries: [TimeEntry] {
        timeEntries.filter(\.isOpen)
    }

    private var monthInvoiceTotal: Double {
        invoices
            .filter { calendar.isDate($0.createdAt, equalTo: Date(), toGranularity: .month) }
            .reduce(0) { $0 + $1.amount }
    }

    private var monthPaymentsCollected: Double {
        payments
            .filter { calendar.isDate($0.date, equalTo: Date(), toGranularity: .month) }
            .reduce(0) { $0 + $1.amount }
    }

    private var openReceivablesTotal: Double {
        openInvoices.reduce(0) { $0 + outstandingBalance(for: $1) }
    }

    private var estimatePipelineTotal: Double {
        estimates
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
            quickBooksAttentionPayments.first != nil,
            followUpCalls.first != nil,
            upcomingCalls.first != nil
        ]
        .filter { $0 }
        .count
    }

    private var dispatchWindowCalls: [ServiceCall] {
        let startOfToday = calendar.startOfDay(for: Date())
        let dispatchWindowEnd = calendar.date(byAdding: .day, value: 3, to: startOfToday) ?? Date()
        return serviceCalls
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
        technicians.filter { technician in
            todayCalls.allSatisfy { $0.assignedTechnician?.id != technician.id }
        }
        .count
    }

    private var selectedPaymentProcessor: OnsitePaymentProcessor {
        OnsitePaymentProcessor(rawValue: onsitePaymentProcessor) ?? .none
    }

    private var suiteSnapshot: BusinessSuiteSnapshot {
        BusinessSuiteIntelligence.snapshot(
            customers: customers,
            serviceCalls: serviceCalls,
            technicians: technicians,
            contracts: recurringContracts,
            estimates: estimates,
            invoices: invoices,
            payments: payments,
            attachments: attachments,
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
            customers: customers,
            serviceCalls: serviceCalls,
            invoices: invoices,
            estimates: estimates,
            payments: payments,
            contracts: recurringContracts,
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
                        if canViewFinancials {
                            suiteSynchronizationSection
                        }
                        priorityQueueSection
                        if canViewFinancials {
                            accountIntelligenceSection
                            workflowSection
                        }
                        dispatchIntelligenceSection
                        fieldTeamSection
                        systemsSection
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
                    .tint(Color.brandGold)
                }
            }
            .sheet(isPresented: $showingCommandPalette) {
                OperationsCommandPalette(
                    customers: customers,
                    serviceCalls: serviceCalls,
                    invoices: invoices,
                    estimates: estimates,
                    payments: payments,
                    canViewFinancials: canViewFinancials,
                    canCollectFieldPayments: canCollectFieldPayments
                )
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

            HStack(spacing: 10) {
                Button {
                    showingCommandPalette = true
                } label: {
                    Label("Find", systemImage: "magnifyingglass")
                }

                Button {
                    GunnAireAppIntentRouter.store(.schedule)
                } label: {
                    Label("Schedule", systemImage: "calendar.badge.clock")
                }

                if canCollectFieldPayments {
                    Button {
                        GunnAireAppIntentRouter.store(.payments)
                    } label: {
                        Label("Collect", systemImage: "creditcard")
                    }
                }

                Button {
                    GunnAireAppIntentRouter.store(.sync)
                } label: {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.brandGold)
            .foregroundStyle(Color.primaryBlack)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private var metricsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            metricCard(
                title: "Today",
                value: "\(todayCalls.count)",
                detail: "\(inProgressCalls.count) active",
                systemImage: "calendar",
                tint: Color.brandGold
            )
            if canViewFinancials {
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
            metricCard(
                title: "Agreements",
                value: "\(maintenanceAlerts.count)",
                detail: "\(recurringContracts.filter(\.active).count) active",
                systemImage: "repeat.circle",
                tint: maintenanceAlerts.isEmpty ? Color.brandGold : .orange
            )
            metricCard(
                title: "Field Team",
                value: "\(openTimeEntries.count)",
                detail: "\(unassignedUpcomingCalls.count) unassigned",
                systemImage: "person.2.badge.gearshape",
                tint: unassignedUpcomingCalls.isEmpty ? Color.brandGold : .blue
            )
            if canViewFinancials {
                metricCard(
                    title: "Sync Risk",
                    value: "\(quickBooksAttentionPayments.count)",
                    detail: "\(linkedCalendarJobCount) calendar-linked",
                    systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                    tint: quickBooksAttentionPayments.isEmpty ? Color.brandGold : .red
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
                emptyState("All workstreams are synchronized.")
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
                        value: call.type.displayName,
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
                    detail: "\(technicians.count) technicians",
                    systemImage: "person.2.wave.2",
                    tint: clearTechnicianCountToday == 0 && !technicians.isEmpty ? .orange : .green
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
                    detail: "\(customers.count) total",
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

            if customers.isEmpty {
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
            if technicians.isEmpty && unassignedUpcomingCalls.isEmpty {
                emptyState("No technicians or upcoming assignments yet.")
            } else {
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

    private var systemsSection: some View {
        dashboardSection(title: "Connected Systems", systemImage: "point.3.connected.trianglepath.dotted") {
            systemRow(
                title: "Google Calendar",
                status: googleAuth.isAuthenticated ? "Connected" : "Disconnected",
                detail: "\(linkedCalendarJobCount) linked jobs",
                systemImage: "calendar.badge.checkmark",
                tint: googleAuth.isAuthenticated ? .green : .orange
            ) {
                GunnAireAppIntentRouter.store(.sync)
            }

            Divider()

            if canViewFinancials {
                systemRow(
                    title: "QuickBooks",
                    status: QuickBooksDataAPI.shared.isAuthenticated ? "Connected" : "Disconnected",
                    detail: "\(linkedInvoiceCount) linked invoices • \(linkedEstimateCount) linked estimates",
                    systemImage: "banknote",
                    tint: QuickBooksDataAPI.shared.isAuthenticated ? .green : .orange
                ) {
                    GunnAireAppIntentRouter.store(.quickBooks)
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

                Button {
                    GunnAireAppIntentRouter.storeDocumentationRoute(call.id)
                } label: {
                    Label("Docs", systemImage: "doc.text")
                }

                if call.assignedTechnician == nil && !technicians.isEmpty {
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
                    .tint(.green)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(Color.brandGold)
        }
        .padding(.vertical, 2)
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
        invoices.filter { calendar.isDate($0.createdAt, equalTo: Date(), toGranularity: .month) }.count
    }

    private var paymentsThisMonthCount: Int {
        payments.filter { calendar.isDate($0.date, equalTo: Date(), toGranularity: .month) }.count
    }

    private var openEstimateCount: Int {
        estimates.filter {
            let status = $0.status.lowercased()
            return status != "rejected" && status != "invoiced"
        }.count
    }

    private var linkedCalendarJobCount: Int {
        serviceCalls.filter { $0.googleEventID?.isEmpty == false }.count
    }

    private var linkedInvoiceCount: Int {
        invoices.filter { $0.quickBooksID?.isEmpty == false }.count
    }

    private var linkedEstimateCount: Int {
        estimates.filter { $0.quickBooksID?.isEmpty == false }.count
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
        technicians
            .map { technician in
                let todaysJobs = todayCalls.filter { $0.assignedTechnician?.id == technician.id }
                let weekJobs = upcomingCalls.filter { $0.assignedTechnician?.id == technician.id }
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
        Invoice.outstandingBalance(for: invoice, payments: payments)
    }

    private func estimate(for call: ServiceCall) -> Estimate? {
        guard let estimateID = call.linkedEstimateID else { return nil }
        return estimates.first { $0.id == estimateID }
    }

    private func invoice(for call: ServiceCall) -> Invoice? {
        guard let invoiceID = call.linkedInvoiceID else { return nil }
        return invoices.first { $0.id == invoiceID }
    }

    private func dispatchIconName(for call: ServiceCall) -> String {
        switch call.type {
        case .service:
            return "wrench.adjustable"
        case .estimate:
            return "doc.text.magnifyingglass"
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
            if !readiness.isReady, let missing = readiness.missingItems.first {
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
            payments: payments.filter { payment in
                guard let invoice else { return false }
                return payment.invoice.id == invoice.id
            },
            attachments: attachments.filter { $0.serviceCallID == call.id }
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
    }

    private func assignmentTitle(for call: ServiceCall, technician: Technician) -> String {
        let technicianLabel = AppAccess.scheduleLabel(for: technician)
        guard let nextStart = nextAvailableStart(for: technician, proposedStart: call.scheduledDate, duration: call.duration),
              nextStart > call.scheduledDate else {
            return technicianLabel
        }
        return "\(technicianLabel) • move to \(nextStart.formatted(date: .omitted, time: .shortened))"
    }

    private func assign(_ call: ServiceCall, to technician: Technician) {
        let originalStart = call.scheduledDate
        let nextStart = nextAvailableStart(for: technician, proposedStart: call.scheduledDate, duration: call.duration)
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
            .sorted { lhs, rhs in
                let lhsStart = nextAvailableStart(for: lhs, proposedStart: call.scheduledDate, duration: call.duration) ?? call.scheduledDate
                let rhsStart = nextAvailableStart(for: rhs, proposedStart: call.scheduledDate, duration: call.duration) ?? call.scheduledDate
                if lhsStart != rhsStart {
                    return lhsStart < rhsStart
                }

                let lhsWeekLoad = upcomingCalls.filter { $0.assignedTechnician?.id == lhs.id }.count
                let rhsWeekLoad = upcomingCalls.filter { $0.assignedTechnician?.id == rhs.id }.count
                if lhsWeekLoad != rhsWeekLoad {
                    return lhsWeekLoad < rhsWeekLoad
                }

                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .first
    }

    private func nextAvailableStart(for technician: Technician, proposedStart: Date, duration: TimeInterval) -> Date? {
        let scheduledCalls = serviceCalls
            .filter { call in
                guard call.assignedTechnician?.id == technician.id, call.status != .cancelled else { return false }
                return call.status != .completed
            }
            .sorted { $0.scheduledDate < $1.scheduledDate }

        var candidateStart = proposedStart
        var moved = true
        while moved {
            moved = false
            let candidateEnd = candidateStart.addingTimeInterval(duration)
            if let conflict = scheduledCalls.first(where: { existingCall in
                let existingStart = existingCall.scheduledDate
                let existingEnd = existingCall.scheduledDate.addingTimeInterval(existingCall.duration)
                return candidateStart < existingEnd && candidateEnd > existingStart
            }) {
                candidateStart = conflict.scheduledDate.addingTimeInterval(conflict.duration)
                moved = true
            }
        }

        return candidateStart
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
        case .estimates:
            GunnAireAppIntentRouter.store(.estimates)
        case .invoices:
            GunnAireAppIntentRouter.store(.invoices)
        case .timeClock:
            GunnAireAppIntentRouter.store(.timeClock)
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
    let canViewFinancials: Bool
    let canCollectFieldPayments: Bool

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
                customersSection
                jobsSection
                if canViewFinancials {
                    invoicesSection
                    estimatesSection
                }
                if canViewFinancials && trimmedSearch.isEmpty {
                    recentPaymentsSection
                }
            }
            .navigationTitle("Find")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: canViewFinancials ? "Customer, job, invoice, address" : "Customer, job, address")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var quickActionsSection: some View {
        Section("Quick Actions") {
            commandButton("Open Schedule", detail: "Calendar and dispatch board", systemImage: "calendar.badge.clock") {
                GunnAireAppIntentRouter.store(.schedule)
            }
            if canCollectFieldPayments {
                commandButton("Collect Payment", detail: "Open payment collection", systemImage: "creditcard") {
                    GunnAireAppIntentRouter.store(.payments)
                }
            }
            if canViewFinancials {
                commandButton("Job Documentation", detail: "Estimate, invoice, and closeout queue", systemImage: "book") {
                    GunnAireAppIntentRouter.store(.documentation)
                }
            }
            commandButton("Sync Systems", detail: canViewFinancials ? "Google, QuickBooks, and integrations" : "Google Calendar and field sync", systemImage: "arrow.triangle.2.circlepath") {
                GunnAireAppIntentRouter.store(.sync)
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
    OperationsDashboardView()
}
