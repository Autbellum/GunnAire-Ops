import SwiftUI
import SwiftData

struct CustomersView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Customer.name, order: .forward) private var customers: [Customer]
    @Query(sort: \ServiceCall.scheduledDate, order: .reverse) private var serviceCalls: [ServiceCall]
    @Query(sort: \Invoice.createdAt, order: .reverse) private var invoices: [Invoice]
    @Query(sort: \Estimate.createdAt, order: .reverse) private var estimates: [Estimate]
    @Query(sort: \Payment.date, order: .reverse) private var payments: [Payment]
    @Query(sort: \RecurringMaintenanceContract.nextDate, order: .forward) private var recurringContracts: [RecurringMaintenanceContract]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]

    @State private var newCustomerName = ""
    @State private var newCustomerEmail = ""
    @State private var newCustomerPhone = ""
    @State private var newCustomerAddress = ""
    @State private var selectedCustomer: Customer?
    @State private var customerSearchText = ""
    @State private var customerSyncMessage: String?
    @State private var isSyncingCustomers = false

    private var filteredCustomers: [Customer] {
        let search = customerSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return customers }
        return customers.filter { customer in
            customer.name.localizedCaseInsensitiveContains(search) ||
            (customer.email?.localizedCaseInsensitiveContains(search) ?? false) ||
            (customer.phone?.localizedCaseInsensitiveContains(search) ?? false) ||
            (customer.address?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    private var canViewFinancials: Bool {
        AppAccess.isAdmin(
            email: GoogleAuthManager.shared.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail"),
            users: users
        )
    }

    private var customerSnapshotsByID: [UUID: CustomerIntelligenceSnapshot] {
        Dictionary(
            uniqueKeysWithValues: CustomerIntelligence.snapshots(
                customers: customers,
                serviceCalls: serviceCalls,
                invoices: invoices,
                estimates: estimates,
                payments: payments,
                contracts: recurringContracts
            )
            .map { ($0.customer.id, $0) }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Add Customer") {
                    TextField("Customer Name", text: $newCustomerName)
                    TextField("Address", text: $newCustomerAddress, axis: .vertical)
                        .lineLimit(2...3)
                    TextField("Email", text: $newCustomerEmail)
                        .keyboardType(.emailAddress)
                    TextField("Phone", text: $newCustomerPhone)
                        .keyboardType(.phonePad)

                    Button("Save Customer") {
                        let customer = Customer(
                            name: newCustomerName.trimmingCharacters(in: .whitespacesAndNewlines),
                            phone: newCustomerPhone.nilIfBlank,
                            email: newCustomerEmail.nilIfBlank,
                            address: newCustomerAddress.nilIfBlank
                        )
                        modelContext.insert(customer)
                        newCustomerName = ""
                        newCustomerEmail = ""
                        newCustomerPhone = ""
                        newCustomerAddress = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandGold)
                    .foregroundStyle(Color.primaryBlack)
                    .disabled(newCustomerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("Customer Directory") {
                    TextField("Search customers", text: $customerSearchText)
                        .textInputAutocapitalization(.never)

                    if let customerSyncMessage {
                        Text(customerSyncMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if filteredCustomers.isEmpty {
                        Text("No customers saved yet.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(filteredCustomers) { customer in
                            Button {
                                selectedCustomer = customer
                            } label: {
                                let snapshot = customerSnapshotsByID[customer.id]
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(customer.name)
                                            .font(.headline)
                                        Spacer()
                                        if canViewFinancials, let snapshot {
                                            Label("\(snapshot.healthScore)", systemImage: accountHealthIcon(for: snapshot))
                                                .font(.caption2.weight(.semibold))
                                                .foregroundColor(accountHealthTint(for: snapshot))
                                        }
                                        if canViewFinancials, let quickBooksID = customer.quickBooksID, !quickBooksID.isEmpty {
                                            Label("QuickBooks", systemImage: "link")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    if let address = customer.address, !address.isEmpty {
                                        Text(address)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    if let email = customer.email, !email.isEmpty {
                                        Text(email)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    if let phone = customer.phone, !phone.isEmpty {
                                        Text(phone)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    Text(canViewFinancials
                                         ? "\(serviceCallCount(for: customer)) jobs • \(invoiceCount(for: customer)) invoices • \(activeContractCount(for: customer)) agreements"
                                         : "\(serviceCallCount(for: customer)) jobs • \(activeContractCount(for: customer)) agreements")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    if canViewFinancials, let snapshot {
                                        Text(accountPulseLine(for: snapshot))
                                            .font(.caption2.weight(.semibold))
                                            .foregroundColor(accountHealthTint(for: snapshot))
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.78)
                                    }
                                    if let nextContract = nextActiveContract(for: customer) {
                                        Text("Next maintenance: \(nextContract.nextDate.formatted(date: .abbreviated, time: .omitted))")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }

                                    HStack {
                                        Button("Open Record") {
                                            selectedCustomer = customer
                                        }
                                        .buttonStyle(.bordered)

                                        if let nextCall = nextActiveServiceCall(for: customer) {
                                            Button("Open Job") {
                                                GunnAireAppIntentRouter.storeScheduleCallRoute(nextCall.id)
                                            }
                                            .buttonStyle(.bordered)
                                        }

                                        if canViewFinancials, let openInvoice = nextOpenInvoice(for: customer) {
                                            Button("Collect Payment") {
                                                GunnAireAppIntentRouter.storePaymentCollectionRoute(openInvoice.id)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .tint(.green)
                                        }
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle("Customers")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if canViewFinancials {
                        Button {
                            syncCustomersToQuickBooks()
                        } label: {
                            Label(isSyncingCustomers ? "Syncing" : "Sync", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(isSyncingCustomers || !QuickBooksDataAPI.shared.isAuthenticated)
                    }
                }
            }
            .onAppear(perform: applyPendingIntentCustomerIfNeeded)
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GunnAireRouteDidChange"))) { _ in
                applyPendingIntentCustomerIfNeeded()
            }
            .sheet(item: $selectedCustomer) { customer in
                CustomerEditorView(customer: customer)
            }
        }
    }

    private func applyPendingIntentCustomerIfNeeded() {
        guard let pendingID = GunnAireAppIntentRouter.consumePendingCustomerID(),
              let customer = customers.first(where: { $0.id == pendingID }) else {
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedCustomer = customer
        }
    }

    private func serviceCallCount(for customer: Customer) -> Int {
        serviceCalls.filter { $0.customer.id == customer.id }.count
    }

    private func invoiceCount(for customer: Customer) -> Int {
        invoices.filter { $0.customer.id == customer.id }.count
    }

    private func activeContractCount(for customer: Customer) -> Int {
        recurringContracts.filter { $0.customer.id == customer.id && $0.active }.count
    }

    private func nextActiveContract(for customer: Customer) -> RecurringMaintenanceContract? {
        recurringContracts
            .filter { $0.customer.id == customer.id && $0.active }
            .sorted(by: { $0.nextDate < $1.nextDate })
            .first
    }

    private func nextActiveServiceCall(for customer: Customer) -> ServiceCall? {
        serviceCalls
            .filter { $0.customer.id == customer.id && $0.status != .completed && $0.status != .cancelled }
            .sorted(by: { $0.scheduledDate < $1.scheduledDate })
            .first
    }

    private func nextOpenInvoice(for customer: Customer) -> Invoice? {
        invoices
            .filter {
                $0.customer.id == customer.id &&
                $0.status.caseInsensitiveCompare("paid") != .orderedSame
            }
            .compactMap { invoice -> (invoice: Invoice, balance: Double)? in
                let balance = CustomerIntelligence.outstandingBalance(for: invoice, payments: payments)
                guard balance > 0 else { return nil }
                return (invoice, balance)
            }
            .sorted { $0.balance > $1.balance }
            .first?
            .invoice
    }

    private func accountPulseLine(for snapshot: CustomerIntelligenceSnapshot) -> String {
        var parts: [String] = ["\(snapshot.healthLabel) account"]
        if snapshot.openBalance > 0 {
            parts.append("\(snapshot.openBalance.formatted(.currency(code: "USD"))) open")
        }
        if snapshot.readyToBillCount > 0 {
            parts.append("\(snapshot.readyToBillCount) ready to bill")
        }
        if snapshot.openEstimateCount > 0 {
            parts.append("\(snapshot.openEstimateCount) estimates")
        }
        if snapshot.syncAttentionCount > 0 {
            parts.append("\(snapshot.syncAttentionCount) sync")
        }
        return parts.joined(separator: " • ")
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

    private func syncCustomersToQuickBooks() {
        guard QuickBooksDataAPI.shared.isAuthenticated else {
            customerSyncMessage = "Connect QuickBooks before syncing customers."
            return
        }
        let pendingCustomers = customers.filter {
            $0.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        }
        guard !pendingCustomers.isEmpty else {
            customerSyncMessage = "All app customers already have QuickBooks links."
            return
        }

        isSyncingCustomers = true
        customerSyncMessage = "Syncing \(pendingCustomers.count) customer\(pendingCustomers.count == 1 ? "" : "s") to QuickBooks..."
        syncCustomerBatch(pendingCustomers, created: 0, failed: 0)
    }

    private func syncCustomerBatch(_ pendingCustomers: [Customer], created: Int, failed: Int) {
        guard let customer = pendingCustomers.first else {
            isSyncingCustomers = false
            customerSyncMessage = "Customer sync complete: \(created) created, \(failed) failed."
            return
        }

        QuickBooksDataAPI.shared.createCustomer(quickBooksPayload(for: customer)) { result in
            DispatchQueue.main.async {
                var createdCount = created
                var failedCount = failed
                switch result {
                case .success(let quickBooksCustomer):
                    customer.quickBooksID = quickBooksCustomer.Id
                    createdCount += 1
                case .failure:
                    failedCount += 1
                }
                syncCustomerBatch(Array(pendingCustomers.dropFirst()), created: createdCount, failed: failedCount)
            }
        }
    }

    private func quickBooksPayload(for customer: Customer) -> QuickBooksCustomerCreate {
        QuickBooksCustomerCreate(
            DisplayName: customer.name,
            PrimaryPhone: customer.phone.flatMap { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : QuickBooksPhoneNumber(FreeFormNumber: trimmed)
            },
            PrimaryEmailAddr: customer.email.flatMap { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : QuickBooksEmailAddress(Address: trimmed)
            },
            BillAddr: customer.address.flatMap { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : QuickBooksAddress(Line1: trimmed)
            }
        )
    }
}

enum TechnicianCalendarAccessState: String {
    case writable
    case readOnly
    case notShared
    case noCalendar

    var label: String {
        switch self {
        case .writable:
            return "Writable"
        case .readOnly:
            return "Read-only"
        case .notShared:
            return "Not shared"
        case .noCalendar:
            return "No calendar"
        }
    }

    var systemImage: String {
        switch self {
        case .writable:
            return "checkmark.circle.fill"
        case .readOnly:
            return "lock.circle"
        case .notShared:
            return "exclamationmark.triangle.fill"
        case .noCalendar:
            return "calendar.badge.exclamationmark"
        }
    }

    var tint: Color {
        switch self {
        case .writable:
            return .green
        case .readOnly:
            return .orange
        case .notShared:
            return .red
        case .noCalendar:
            return .secondary
        }
    }
}

struct TechnicianCalendarAccessAssessment {
    let state: TechnicianCalendarAccessState
    let calendarLabel: String
    let detail: String

    static func evaluate(calendarID: String?, availableCalendars: [GoogleCalendar]) -> TechnicianCalendarAccessAssessment {
        let normalizedCalendarID = AppAccess.normalizedEmail(calendarID)
        guard !normalizedCalendarID.isEmpty else {
            return TechnicianCalendarAccessAssessment(
                state: .noCalendar,
                calendarLabel: "Unassigned",
                detail: "Assign a writable Google calendar before scheduling."
            )
        }

        if normalizedCalendarID == "primary" {
            return TechnicianCalendarAccessAssessment(
                state: .writable,
                calendarLabel: "Primary Calendar",
                detail: "Jobs can be exported to the signed-in user's primary calendar."
            )
        }

        if let calendar = availableCalendars.first(where: { $0.matchesTechnicianEmail(normalizedCalendarID) || $0.normalizedID == normalizedCalendarID }) {
            return TechnicianCalendarAccessAssessment(
                state: calendar.isWritable ? .writable : .readOnly,
                calendarLabel: calendar.displayLabel,
                detail: calendar.isWritable ? "Jobs can be created and updated on this calendar." : "The connected Google account can view this calendar but cannot write events."
            )
        }

        return TechnicianCalendarAccessAssessment(
            state: .notShared,
            calendarLabel: normalizedCalendarID,
            detail: "Share this calendar with write access or assign a writable calendar below."
        )
    }
}

struct SyncIntegrationsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Customer.name, order: .forward) private var customers: [Customer]
    @Query(sort: \Technician.name, order: .forward) private var technicians: [Technician]
    @Query(sort: \ServiceCall.scheduledDate, order: .forward) private var serviceCalls: [ServiceCall]
    @Query(sort: \Invoice.createdAt, order: .reverse) private var invoices: [Invoice]
    @Query(sort: \Estimate.createdAt, order: .reverse) private var estimates: [Estimate]
    @Query(sort: \Payment.date, order: .reverse) private var payments: [Payment]
    @Query(sort: \RecurringMaintenanceContract.nextDate, order: .forward) private var recurringContracts: [RecurringMaintenanceContract]
    @Query(sort: \TimeEntry.clockIn, order: .reverse) private var timeEntries: [TimeEntry]
    @Query(sort: \Item.name, order: .forward) private var items: [Item]
    @Query(sort: \Vendor.name, order: .forward) private var vendors: [Vendor]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @ObservedObject private var googleAuth = GoogleAuthManager.shared

    @State private var availableCalendars: [GoogleCalendar] = []
    @State private var loadingCalendars = false
    @State private var calendarStatusMessage: String?
    @State private var newTechnicianName = ""
    @State private var newTechnicianCalendarEmail = ""
    @State private var selectedTechnician: Technician?
    @State private var technicianMessage: String?

    private let calendar = Calendar.current

    private var quickBooksConnected: Bool {
        QuickBooksDataAPI.shared.isAuthenticated
    }

    private var canViewFinancials: Bool {
        AppAccess.isAdmin(
            email: googleAuth.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail"),
            users: users
        )
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
            timeEntries: timeEntries,
            items: items,
            vendors: vendors,
            googleConnected: googleAuth.isAuthenticated,
            quickBooksConnected: quickBooksConnected,
            onsitePaymentsReady: UserDefaults.standard.bool(forKey: "enableOnsitePayments") &&
                UserDefaults.standard.bool(forKey: "onsitePaymentProcessorReady"),
            now: Date(),
            calendar: calendar
        )
    }

    private var attentionWorkstreams: [BusinessSuiteWorkstream] {
        suiteSnapshot.workstreams.filter { $0.severity != .stable }
    }

    private var availableCalendarIDs: Set<String> {
        Set(availableCalendars.map(\.id) + ["primary"])
    }

    private var writableCalendarIDs: Set<String> {
        Set(availableCalendars.filter(\.isWritable).map(\.normalizedID) + ["primary"])
    }

    private var writableCalendars: [GoogleCalendar] {
        availableCalendars
            .filter(\.isWritable)
            .sorted { $0.displayLabel.localizedCaseInsensitiveCompare($1.displayLabel) == .orderedAscending }
    }

    private var readOnlyCalendars: [GoogleCalendar] {
        availableCalendars
            .filter { !$0.isWritable }
            .sorted { $0.displayLabel.localizedCaseInsensitiveCompare($1.displayLabel) == .orderedAscending }
    }

    private var calendarControlSummary: String {
        guard googleAuth.isAuthenticated else { return "Google is disconnected." }
        if loadingCalendars { return "Checking Google Calendar permissions..." }
        if availableCalendars.isEmpty { return "Refresh to load writable and read-only calendars." }
        return "\(writableCalendarIDs.count) writable, \(readOnlyCalendars.count) read-only"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Sync Status") {
                    statusRow("Google", value: googleAuth.isAuthenticated ? "Connected" : "Disconnected")
                    if canViewFinancials {
                        statusRow("QuickBooks", value: quickBooksConnected ? "Connected" : "Disconnected")
                    }
                }

                if canViewFinancials {
                    Section("Suite Readiness") {
                    HStack(alignment: .center, spacing: 14) {
                        ZStack {
                            Circle()
                                .stroke(suiteTint(for: suiteSnapshot.healthScore).opacity(0.24), lineWidth: 7)
                            Circle()
                                .trim(from: 0, to: CGFloat(suiteSnapshot.healthScore) / 100)
                                .stroke(suiteTint(for: suiteSnapshot.healthScore), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text("\(suiteSnapshot.healthScore)")
                                .font(.headline.weight(.bold))
                        }
                        .frame(width: 62, height: 62)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(suiteSnapshot.healthLabel)
                                .font(.headline)
                                .foregroundColor(suiteTint(for: suiteSnapshot.healthScore))
                            Text(suiteSnapshot.healthDetail)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }

                        Spacer()

                        Button {
                            GunnAireAppIntentRouter.store(.commandCenter)
                        } label: {
                            Label("Command Center", systemImage: "rectangle.3.group")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    HStack {
                        suiteMetric("\(suiteSnapshot.openWorkCount)", label: "open work")
                        suiteMetric(suiteSnapshot.openReceivablesTotal.formatted(.currency(code: "USD")), label: "receivables")
                        suiteMetric("\(suiteSnapshot.syncAttentionCount)", label: "sync gaps")
                    }

                    if attentionWorkstreams.isEmpty {
                        Text("All workstreams are synchronized.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(attentionWorkstreams.prefix(4)) { workstream in
                            Button {
                                perform(workstream.destination)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: workstream.systemImage)
                                        .foregroundColor(suiteSeverityTint(workstream.severity))
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(workstream.title)
                                            .font(.subheadline.weight(.semibold))
                                        Text(workstream.detail)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Text("\(workstream.score)")
                                        .font(.caption.weight(.bold))
                                        .foregroundColor(suiteSeverityTint(workstream.severity))
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if let action = suiteSnapshot.actions.first {
                        Button {
                            perform(action.destination)
                        } label: {
                            Label(action.title, systemImage: action.systemImage)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(suiteSeverityTint(action.severity))
                    }
                    }
                }

                Section("Google Calendar Control") {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Calendar Access")
                                .font(.subheadline.weight(.semibold))
                            Text(calendarControlSummary)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(loadingCalendars ? "Loading..." : "Refresh") {
                            refreshCalendarAccess()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!googleAuth.isAuthenticated || loadingCalendars)
                    }

                    if !googleAuth.isAuthenticated {
                        Text("Connect Google in Settings before checking calendar access.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if let calendarStatusMessage {
                        Text(calendarStatusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if !technicians.isEmpty {
                        ForEach(technicians) { technician in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Label {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(technician.name)
                                                .font(.subheadline.weight(.semibold))
                                            Text("\(assignedJobCount(for: technician)) assigned jobs")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    } icon: {
                                        Image(systemName: calendarAccessAssessment(for: technician).state.systemImage)
                                            .foregroundColor(calendarAccessAssessment(for: technician).state.tint)
                                    }
                                    Spacer()
                                    Button("Edit") {
                                        selectedTechnician = technician
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }

                                LabeledContent("Status") {
                                    Text(calendarAccessAssessment(for: technician).state.label)
                                        .foregroundColor(calendarAccessAssessment(for: technician).state.tint)
                                }

                                Text(calendarAccessAssessment(for: technician).detail)
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                Picker("Assigned Calendar", selection: calendarSelectionBinding(for: technician)) {
                                    Text("Unassigned").tag("")
                                    Text("Primary Calendar").tag("primary")
                                    ForEach(writableCalendars) { calendar in
                                        Text(calendar.displayLabel).tag(calendar.normalizedID)
                                    }
                                }
                                .disabled(!googleAuth.isAuthenticated || loadingCalendars)
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    if !readOnlyCalendars.isEmpty {
                        DisclosureGroup("Read-only calendars") {
                            ForEach(readOnlyCalendars) { calendar in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(calendar.displayLabel)
                                    Text("Ask the calendar owner to grant make changes access before assigning jobs here.")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("Technician Directory") {
                    TextField("Technician name", text: $newTechnicianName)
                    TextField("Calendar ID or email", text: $newTechnicianCalendarEmail)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)

                    Button {
                        addTechnician()
                    } label: {
                        Label("Add Technician", systemImage: "person.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandGold)
                    .foregroundStyle(Color.primaryBlack)

                    if let technicianMessage {
                        Text(technicianMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if technicians.isEmpty {
                        Text("No technicians added yet.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(technicians) { technician in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(technician.name)
                                    Text(technician.contactInfo ?? "No calendar email")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Delete", role: .destructive) {
                                    modelContext.delete(technician)
                                }
                                .disabled(assignedJobCount(for: technician) > 0)
                            }
                        }
                        Text("Technicians with assigned jobs must be reassigned before they can be deleted.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Operational Notes") {
                    Text("Google account and calendar access are managed from Settings.")
                    Text("Mail now uses the connected Google account with Gmail API access.")
                    Text("Technician events can be created from Schedule by assigning a technician whose calendar email is accessible to the connected Google account.")
                    if canViewFinancials {
                        Text("QuickBooks sync is managed from the QuickBooks Management screen.")
                        Text("Receipts, bills, invoices, payments, and catalog records now use the live QuickBooks integration path.")
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .navigationTitle("Sync & Integrations")
            .onAppear {
                if googleAuth.isAuthenticated && availableCalendars.isEmpty {
                    refreshCalendarAccess()
                }
            }
            .sheet(item: $selectedTechnician) { technician in
                TechnicianEditorView(technician: technician)
            }
        }
    }

    @ViewBuilder
    private func statusRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
    }

    private func suiteMetric(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

    private func refreshCalendarAccess() {
        guard googleAuth.isAuthenticated else { return }
        loadingCalendars = true
        calendarStatusMessage = "Checking accessible calendars..."
        googleAuth.fetchCalendars { result in
            DispatchQueue.main.async {
                loadingCalendars = false
                switch result {
                case .success(let calendars):
                    availableCalendars = calendars
                    calendarStatusMessage = "Loaded \(calendars.count) accessible calendars."
                case .failure(let error):
                    availableCalendars = []
                    calendarStatusMessage = "Calendar diagnostics failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func calendarSelectionBinding(for technician: Technician) -> Binding<String> {
        Binding(
            get: {
                let value = AppAccess.normalizedEmail(technician.contactInfo)
                return value.isEmpty ? "" : value
            },
            set: { newValue in
                technician.contactInfo = newValue.isEmpty ? nil : newValue
                technicianMessage = newValue.isEmpty ? "Calendar assignment removed for \(technician.name)." : "Calendar assignment updated for \(technician.name)."
            }
        )
    }

    private func calendarAccessAssessment(for technician: Technician) -> TechnicianCalendarAccessAssessment {
        TechnicianCalendarAccessAssessment.evaluate(
            calendarID: technician.contactInfo,
            availableCalendars: availableCalendars
        )
    }

    private func assignedJobCount(for technician: Technician) -> Int {
        serviceCalls.filter { $0.assignedTechnician?.id == technician.id }.count
    }

    private func addTechnician() {
        let name = newTechnicianName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            technicianMessage = "Enter a technician name first."
            return
        }
        let email = AppAccess.normalizedEmail(newTechnicianCalendarEmail).nilIfBlank
        if let email, technicians.contains(where: { AppAccess.normalizedEmail($0.contactInfo) == email }) {
            technicianMessage = "A technician with that calendar email already exists."
            return
        }
        modelContext.insert(Technician(name: name, contactInfo: email))
        newTechnicianName = ""
        newTechnicianCalendarEmail = ""
        technicianMessage = "Added \(name)."
    }
}

struct OnsiteDocumentationView: View {
    @Query(sort: \ServiceCall.scheduledDate, order: .forward) private var serviceCalls: [ServiceCall]
    @Query(sort: \Invoice.createdAt, order: .reverse) private var invoices: [Invoice]
    @Query(sort: \Estimate.createdAt, order: .reverse) private var estimates: [Estimate]
    @Query(sort: \Payment.date, order: .reverse) private var payments: [Payment]
    @State private var selectedServiceCallID: UUID?
    @State private var didLoadPendingRoute = false
    @State private var generatedCustomerDocumentURL: URL?
    @State private var documentExportMessage = ""

    private var quickBooksConnected: Bool {
        QuickBooksDataAPI.shared.isAuthenticated
    }

    private var openJobs: [ServiceCall] {
        serviceCalls.filter { $0.status != .completed && $0.status != .cancelled }
    }

    private var jobsNeedingDocumentation: [ServiceCall] {
        openJobs.filter {
            $0.documentationCompletedAt == nil ||
            $0.linkedEstimateID != nil ||
            $0.linkedInvoiceID != nil
        }
        .sorted(by: { $0.scheduledDate < $1.scheduledDate })
    }

    private var estimateDocumentationCalls: [ServiceCall] {
        jobsNeedingDocumentation.filter { $0.type == .estimate }
    }

    private var invoiceDocumentationCalls: [ServiceCall] {
        jobsNeedingDocumentation.filter { $0.linkedInvoiceID != nil && $0.type != .estimate }
    }

    private var fieldDocumentationCalls: [ServiceCall] {
        jobsNeedingDocumentation.filter { $0.type != .estimate && $0.linkedInvoiceID == nil }
    }

    private var invoicesAwaitingCloseout: [Invoice] {
        invoices.filter { invoiceBalanceDue(for: $0) > 0 || $0.finalizedAt == nil }
    }

    private var selectedServiceCall: ServiceCall? {
        guard let selectedServiceCallID else { return nil }
        return serviceCalls.first { $0.id == selectedServiceCallID }
    }

    private func serviceCall(for invoice: Invoice) -> ServiceCall? {
        guard let serviceCallID = invoice.serviceCallID else { return nil }
        return serviceCalls.first(where: { $0.id == serviceCallID })
    }

    private func estimate(for call: ServiceCall) -> Estimate? {
        if let linkedEstimateID = call.linkedEstimateID,
           let linkedEstimate = estimates.first(where: { $0.id == linkedEstimateID }) {
            return linkedEstimate
        }
        return estimates.first(where: { $0.serviceCallID == call.id })
    }

    private func invoice(for call: ServiceCall) -> Invoice? {
        if let linkedInvoiceID = call.linkedInvoiceID,
           let linkedInvoice = invoices.first(where: { $0.id == linkedInvoiceID }) {
            return linkedInvoice
        }
        return invoices.first(where: { $0.serviceCallID == call.id })
    }

    private func payments(for invoice: Invoice?) -> [Payment] {
        guard let invoice else { return [] }
        return payments.filter { $0.invoice.id == invoice.id }
    }

    private func invoiceBalanceDue(for invoice: Invoice) -> Double {
        if invoice.status.caseInsensitiveCompare("paid") == .orderedSame {
            return 0
        }
        return max(invoice.amount - payments(for: invoice).reduce(0) { partial, payment in
            partial + payment.amount
        }, 0)
    }

    private func canGeneratePaidInvoice(_ invoice: Invoice?) -> Bool {
        guard let invoice else { return false }
        return invoice.status.caseInsensitiveCompare("paid") == .orderedSame || invoiceBalanceDue(for: invoice) <= 0.009
    }

    private func documentationQueueLabel(for call: ServiceCall) -> String {
        let hasDocumentation = call.linkedInvoiceID != nil || call.linkedEstimateID != nil || call.documentationStartedAt != nil
        switch call.type {
        case .estimate:
            return hasDocumentation ? "Continue Estimate" : "Start Estimate"
        case .install, .maintenance, .service:
            if call.linkedInvoiceID != nil {
                return "Continue Invoice"
            }
            return hasDocumentation ? "Continue Documentation" : "Start Documentation"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                        if jobsNeedingDocumentation.isEmpty {
                            Section("Documentation Queue") {
                                Text("No active jobs are waiting for documentation.")
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            documentationQueueSection(title: "Estimate Queue", calls: estimateDocumentationCalls)
                            documentationQueueSection(title: "Invoice Queue", calls: invoiceDocumentationCalls)
                            documentationQueueSection(title: "Field Documentation Queue", calls: fieldDocumentationCalls)
                        }

                        if !documentExportMessage.isEmpty || generatedCustomerDocumentURL != nil {
                            Section("Customer Documents") {
                                if !documentExportMessage.isEmpty {
                                    Text(documentExportMessage)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                if let generatedCustomerDocumentURL {
                                    ShareLink(item: generatedCustomerDocumentURL) {
                                        Label("Share Last Generated Document", systemImage: "square.and.arrow.up")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(Color.brandGold)
                                    .foregroundStyle(Color.primaryBlack)
                                }
                            }
                        }

                        Section("Invoices Awaiting Closeout") {
                            if invoicesAwaitingCloseout.isEmpty {
                                Text("All invoices are finalized and paid.")
                                    .foregroundColor(.secondary)
                            } else {
                                ForEach(invoicesAwaitingCloseout) { invoice in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(invoice.customer.name)
                                            .font(.headline)
                                        Text("\(invoice.amount, format: .currency(code: "USD")) • \(invoice.status.capitalized)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        if invoice.finalizedAt == nil {
                                            Text("Missing final signature or closeout details.")
                                                .font(.caption2)
                                                .foregroundColor(.orange)
                                        }
                                        HStack {
                                            if let linkedCall = serviceCall(for: invoice) {
                                                Button("Open Documents") {
                                                    selectedServiceCallID = linkedCall.id
                                                }
                                                .buttonStyle(.bordered)

                                                Button("Open Schedule") {
                                                    GunnAireAppIntentRouter.storeScheduleCallRoute(linkedCall.id)
                                                }
                                                .buttonStyle(.bordered)
                                            }

                                            if invoice.status.caseInsensitiveCompare("paid") != .orderedSame {
                                                Button("Collect Payment") {
                                                    GunnAireAppIntentRouter.storePaymentCollectionRoute(invoice.id)
                                                }
                                                .buttonStyle(.borderedProminent)
                                                .tint(.green)
                                            }

                                            if canGeneratePaidInvoice(invoice) {
                                                Menu {
                                                    Button("Generate Paid Invoice PDF") {
                                                        generatePaidInvoiceDocument(invoice)
                                                    }
                                                } label: {
                                                    Label("Documents", systemImage: "doc.on.doc")
                                                }
                                                .buttonStyle(.bordered)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }

                        Section("Workflow Notes") {
                            Text("Open a scheduled call from Schedule or this queue to start documentation, build the invoice or estimate, and capture closeout details.")
                            Text("Use Receipts & Bills to attach PDFs, photos, and vendor documents.")
                            Text("Use Payments to review or sync recorded payments after invoice closeout.")
                            Text(quickBooksConnected ? "QuickBooks is connected and ready for live billing document workflows." : "Connect QuickBooks in Settings before expecting live billing document sync.")
                        }
                        .foregroundColor(.secondary)
            }
            .navigationTitle("Onsite Documentation")
            .fullScreenCover(isPresented: Binding(
                get: { selectedServiceCall != nil },
                set: { isPresented in
                    if !isPresented {
                        selectedServiceCallID = nil
                    }
                }
            )) {
                if let selectedServiceCall {
                    BillingDocumentsView(
                        initialServiceCall: selectedServiceCall,
                        showsDismissButton: true,
                        dismissButtonTitle: "Back"
                    )
                    .tint(Color.brandGold)
                }
            }
            .onAppear(perform: applyPendingDocumentationRouteIfNeeded)
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GunnAireRouteDidChange"))) { _ in
                applyPendingDocumentationRouteIfNeeded()
            }
        }
    }

    @ViewBuilder
    private func documentationQueueSection(title: String, calls: [ServiceCall]) -> some View {
        if !calls.isEmpty {
            Section(title) {
                ForEach(calls) { call in
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            selectedServiceCallID = call.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(call.customer.name)
                                        .font(.headline)
                                    Text(call.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(call.type.rawValue.capitalized)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text("Checklist \(call.checklistCompletedCount)/\(call.checklistTotalCount)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Text(documentationQueueLabel(for: call))
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(Color.brandGold)
                            }
                        }
                        .buttonStyle(.plain)

                        HStack {
                            Button("Open Documents") {
                                selectedServiceCallID = call.id
                            }
                            .buttonStyle(.bordered)

                            Button("Open Schedule") {
                                GunnAireAppIntentRouter.storeScheduleCallRoute(call.id)
                            }
                            .buttonStyle(.bordered)

                            Menu {
                                Button("Generate Onsite Report") {
                                    generateOnsiteReport(for: call)
                                }

                                if estimate(for: call) != nil {
                                    Button("Generate Estimate PDF") {
                                        generateEstimateDocument(for: call)
                                    }
                                }

                                if let invoice = invoice(for: call), canGeneratePaidInvoice(invoice) {
                                    Button("Generate Paid Invoice PDF") {
                                        generatePaidInvoiceDocument(invoice)
                                    }
                                }
                            } label: {
                                Label("Documents", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.bordered)

                            if call.linkedInvoiceID != nil {
                                Button("Collect Payment") {
                                    if let linkedInvoiceID = call.linkedInvoiceID {
                                        GunnAireAppIntentRouter.storePaymentCollectionRoute(linkedInvoiceID)
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)
                            }
                        }
                    }
                }
            }
        }
    }

    private func applyPendingDocumentationRouteIfNeeded() {
        if !didLoadPendingRoute {
            didLoadPendingRoute = true
        }
        guard let pendingID = GunnAireAppIntentRouter.consumePendingServiceCallID() else { return }
        selectedServiceCallID = pendingID
    }

    private func generateOnsiteReport(for call: ServiceCall) {
        let linkedInvoice = invoice(for: call)
        do {
            let url = try CustomerDocumentExporter.exportOnsiteReport(
                serviceCall: call,
                estimate: estimate(for: call),
                invoice: linkedInvoice,
                payments: payments(for: linkedInvoice)
            )
            generatedCustomerDocumentURL = url
            documentExportMessage = "Onsite report generated for \(call.customer.name)."
            call.documentationChecklist = true
            call.documentationCompletedAt = call.documentationCompletedAt ?? Date()
        } catch {
            documentExportMessage = "Could not generate onsite report: \(error.localizedDescription)"
        }
    }

    private func generateEstimateDocument(for call: ServiceCall) {
        guard let estimate = estimate(for: call) else {
            documentExportMessage = "No estimate is linked to this job yet."
            return
        }
        do {
            let url = try CustomerDocumentExporter.exportEstimate(estimate, serviceCall: call)
            generatedCustomerDocumentURL = url
            documentExportMessage = "Estimate PDF generated for \(estimate.customer.name)."
        } catch {
            documentExportMessage = "Could not generate estimate PDF: \(error.localizedDescription)"
        }
    }

    private func generatePaidInvoiceDocument(_ invoice: Invoice) {
        do {
            let url = try CustomerDocumentExporter.exportPaidInvoice(
                invoice,
                serviceCall: serviceCall(for: invoice),
                payments: payments(for: invoice)
            )
            generatedCustomerDocumentURL = url
            documentExportMessage = "Paid invoice PDF generated for \(invoice.customer.name)."
        } catch {
            documentExportMessage = "Could not generate paid invoice PDF: \(error.localizedDescription)"
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct CustomerEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ServiceCall.scheduledDate, order: .reverse) private var serviceCalls: [ServiceCall]
    @Query(sort: \Invoice.createdAt, order: .reverse) private var invoices: [Invoice]
    @Query(sort: \Estimate.createdAt, order: .reverse) private var estimates: [Estimate]
    @Query(sort: \Payment.date, order: .reverse) private var payments: [Payment]
    @Query(sort: \RecurringMaintenanceContract.nextDate, order: .forward) private var recurringContracts: [RecurringMaintenanceContract]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]

    let customer: Customer

    @State private var name: String
    @State private var address: String
    @State private var email: String
    @State private var phone: String
    @State private var newContractPattern: String = ""
    @State private var newContractDate: Date = Date()
    @State private var customerActionMessage: String?
    @State private var isSyncingCustomer = false
    @State private var showingDeleteConfirmation = false

    private var customerServiceCalls: [ServiceCall] {
        serviceCalls.filter { $0.customer.id == customer.id }
    }

    private var recentCustomerServiceCalls: [ServiceCall] {
        Array(customerServiceCalls.prefix(5))
    }

    private var openCustomerInvoiceBalances: [(invoice: Invoice, balance: Double)] {
        invoices.filter {
            $0.customer.id == customer.id
        }
        .compactMap { invoice in
            let balance = CustomerIntelligence.outstandingBalance(for: invoice, payments: payments)
            guard balance > 0 && invoice.status.caseInsensitiveCompare("paid") != .orderedSame else { return nil }
            return (invoice, balance)
        }
    }

    private var customerSnapshot: CustomerIntelligenceSnapshot {
        CustomerIntelligence.snapshot(
            for: customer,
            serviceCalls: serviceCalls,
            invoices: invoices,
            estimates: estimates,
            payments: payments,
            contracts: recurringContracts
        )
    }

    private var canViewFinancials: Bool {
        AppAccess.isAdmin(
            email: GoogleAuthManager.shared.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail"),
            users: users
        )
    }

    private var canDeleteCustomer: Bool {
        customerServiceCalls.isEmpty &&
        invoices.filter { $0.customer.id == customer.id }.isEmpty &&
        estimates.filter { $0.customer.id == customer.id }.isEmpty &&
        recurringContracts.filter { $0.customer.id == customer.id }.isEmpty
    }

    init(customer: Customer) {
        self.customer = customer
        _name = State(initialValue: customer.name)
        _address = State(initialValue: customer.address ?? "")
        _email = State(initialValue: customer.email ?? "")
        _phone = State(initialValue: customer.phone ?? "")
    }

    private var customerHealthTint: Color {
        switch customerSnapshot.healthScore {
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

    private var customerHealthIcon: String {
        if customerSnapshot.overdueInvoiceCount > 0 {
            return "creditcard.trianglebadge.exclamationmark"
        }
        if customerSnapshot.syncAttentionCount > 0 {
            return "arrow.triangle.2.circlepath.circle"
        }
        if customerSnapshot.readyToBillCount > 0 {
            return "doc.badge.plus"
        }
        if customerSnapshot.followUpCount > 0 {
            return "arrow.uturn.forward.circle"
        }
        return customerSnapshot.healthScore >= 70 ? "checkmark.seal" : "exclamationmark.triangle"
    }

    private var shouldShowExternalAccountAction: Bool {
        switch customerSnapshot.primaryAction {
        case .completeProfile, .openCustomer:
            return false
        default:
            return true
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Customer Name", text: $name)
                TextField("Address", text: $address, axis: .vertical)
                    .lineLimit(2...3)
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                TextField("Phone", text: $phone)
                    .keyboardType(.phonePad)
                if canViewFinancials, let quickBooksID = customer.quickBooksID, !quickBooksID.isEmpty {
                    Text("QuickBooks ID: \(quickBooksID)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let customerActionMessage {
                    Text(customerActionMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Account Intelligence") {
                    if canViewFinancials {
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: customerHealthIcon)
                                .font(.title2)
                                .foregroundColor(customerHealthTint)
                                .frame(width: 34)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(customerSnapshot.healthScore) • \(customerSnapshot.healthLabel)")
                                    .font(.headline)
                                Text(customerSnapshot.actionDetail)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()
                        }

                        HStack {
                            metricPill("\(customerServiceCalls.count)", label: "jobs")
                            metricPill(openCustomerInvoiceBalances.reduce(0) { $0 + $1.balance }.formatted(.currency(code: "USD")), label: "balance")
                            metricPill("\(customerSnapshot.activeContractCount)", label: "agreements")
                        }
                    } else {
                        HStack {
                            metricPill("\(customerServiceCalls.count)", label: "jobs")
                            metricPill("\(customerSnapshot.activeContractCount)", label: "agreements")
                        }
                    }

                    if canViewFinancials && customerSnapshot.openEstimateTotal > 0 {
                        Text("Open estimate pipeline: \(customerSnapshot.openEstimateTotal.formatted(.currency(code: "USD"))) across \(customerSnapshot.openEstimateCount) estimate\(customerSnapshot.openEstimateCount == 1 ? "" : "s").")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if canViewFinancials && customerSnapshot.syncAttentionCount > 0 {
                        Text("\(customerSnapshot.syncAttentionCount) payment sync item\(customerSnapshot.syncAttentionCount == 1 ? "" : "s") need review.")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }

                    if canViewFinancials && shouldShowExternalAccountAction {
                        Button {
                            perform(customerSnapshot.primaryAction)
                        } label: {
                            Label(customerSnapshot.primaryAction.title, systemImage: customerSnapshot.primaryAction.systemImage)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(customerHealthTint)
                    }
                }

                if !recentCustomerServiceCalls.isEmpty {
                    Section("Recent Jobs") {
                        ForEach(recentCustomerServiceCalls) { call in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(call.type.rawValue.capitalized) • \(call.status.rawValue.capitalized)")
                                    .font(.headline)
                                Text(call.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if let notes = call.notes, !notes.isEmpty {
                                    Text(notes)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                                HStack {
                                    if canViewFinancials {
                                        Button("Open Job") {
                                            GunnAireAppIntentRouter.storeDocumentationRoute(call.id)
                                            dismiss()
                                        }
                                        .buttonStyle(.bordered)
                                    }

                                    Button("Open Schedule") {
                                        GunnAireAppIntentRouter.storeScheduleCallRoute(call.id)
                                        dismiss()
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if canViewFinancials && !openCustomerInvoiceBalances.isEmpty {
                    Section("Open Invoices") {
                        ForEach(openCustomerInvoiceBalances.prefix(5), id: \.invoice.id) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.balance.formatted(.currency(code: "USD")))
                                    .font(.headline)
                                Text("\(entry.invoice.status.capitalized) • \(entry.invoice.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(entry.invoice.lineItemSummary.isEmpty ? "Invoice \(entry.invoice.id.uuidString.prefix(8))" : entry.invoice.lineItemSummary)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                                HStack {
                                    Button("Collect Payment") {
                                        GunnAireAppIntentRouter.storePaymentCollectionRoute(entry.invoice.id)
                                        dismiss()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.green)

                                    if let serviceCallID = entry.invoice.serviceCallID,
                                       let call = customerServiceCalls.first(where: { $0.id == serviceCallID }) {
                                        Button("Open Job") {
                                            GunnAireAppIntentRouter.storeDocumentationRoute(call.id)
                                            dismiss()
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section("Service Agreements") {
                    if customer.recurringContracts.isEmpty {
                        Text("No service agreements on file.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(customer.recurringContracts.sorted(by: { $0.nextDate < $1.nextDate })) { contract in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(contract.schedulePattern)
                                        .font(.headline)
                                    Spacer()
                                    Text(contract.active ? "Active" : "Inactive")
                                        .font(.caption)
                                        .foregroundColor(contract.active ? .green : .secondary)
                                }
                                Text("Next visit: \(contract.nextDate.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("Reminder: \(contract.reminderDate.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Toggle("Active", isOn: Binding(
                                    get: { contract.active },
                                    set: { contract.active = $0 }
                                ))
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    TextField("Schedule Pattern", text: $newContractPattern)
                    DatePicker("Next Visit", selection: $newContractDate, displayedComponents: .date)
                    Button("Add Service Agreement") {
                        let contract = RecurringMaintenanceContract(
                            customer: customer,
                            schedulePattern: newContractPattern.trimmingCharacters(in: .whitespacesAndNewlines),
                            nextDate: newContractDate,
                            active: true
                        )
                        modelContext.insert(contract)
                        newContractPattern = ""
                        newContractDate = Date()
                    }
                    .disabled(newContractPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("Customer Actions") {
                    if canViewFinancials {
                        Button {
                            syncCustomerToQuickBooks()
                        } label: {
                            Label(isSyncingCustomer ? "Syncing Customer" : "Sync Customer to QuickBooks", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(isSyncingCustomer || !QuickBooksDataAPI.shared.isAuthenticated)
                    }

                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Remove Customer from App", systemImage: "trash")
                    }
                    .disabled(!canDeleteCustomer)

                    if !canDeleteCustomer {
                        Text("Customers with jobs, estimates, invoices, or service agreements stay locked to preserve history. Remove or reassign those records first.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Edit Customer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        customer.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        customer.address = address.nilIfBlank
                        customer.email = email.nilIfBlank
                        customer.phone = phone.nilIfBlank
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog("Remove this customer from the app?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
                Button("Remove Customer", role: .destructive) {
                    deleteCustomer()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This only removes the local app customer. QuickBooks records are not deleted.")
            }
        }
        .tint(Color.brandGold)
    }

    private func metricPill(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func deleteCustomer() {
        guard canDeleteCustomer else {
            customerActionMessage = "Remove or reassign related records before deleting this customer."
            return
        }
        modelContext.delete(customer)
        dismiss()
    }

    private func syncCustomerToQuickBooks() {
        guard QuickBooksDataAPI.shared.isAuthenticated else {
            customerActionMessage = "Connect QuickBooks before syncing this customer."
            return
        }
        isSyncingCustomer = true
        customerActionMessage = "Syncing \(customer.name) to QuickBooks..."
        QuickBooksDataAPI.shared.createCustomer(quickBooksPayload(for: customer)) { result in
            DispatchQueue.main.async {
                isSyncingCustomer = false
                switch result {
                case .success(let quickBooksCustomer):
                    customer.quickBooksID = quickBooksCustomer.Id
                    customerActionMessage = "\(customer.name) is linked to QuickBooks."
                case .failure(let error):
                    customerActionMessage = "QuickBooks customer sync failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func quickBooksPayload(for customer: Customer) -> QuickBooksCustomerCreate {
        QuickBooksCustomerCreate(
            DisplayName: customer.name,
            PrimaryPhone: customer.phone.flatMap { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : QuickBooksPhoneNumber(FreeFormNumber: trimmed)
            },
            PrimaryEmailAddr: customer.email.flatMap { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : QuickBooksEmailAddress(Address: trimmed)
            },
            BillAddr: customer.address.flatMap { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : QuickBooksAddress(Line1: trimmed)
            }
        )
    }

    private func perform(_ action: CustomerIntelligenceAction) {
        switch action {
        case .collectPayment(let invoiceID):
            GunnAireAppIntentRouter.storePaymentCollectionRoute(invoiceID)
            dismiss()
        case .openDocumentation(let serviceCallID):
            GunnAireAppIntentRouter.storeDocumentationRoute(serviceCallID)
            dismiss()
        case .openSchedule(let serviceCallID):
            GunnAireAppIntentRouter.storeScheduleCallRoute(serviceCallID)
            dismiss()
        case .openPayments:
            GunnAireAppIntentRouter.store(.payments)
            dismiss()
        case .completeProfile, .openCustomer:
            break
        }
    }
}

private struct TechnicianEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let technician: Technician

    @State private var name: String
    @State private var calendarEmail: String

    init(technician: Technician) {
        self.technician = technician
        _name = State(initialValue: technician.name)
        _calendarEmail = State(initialValue: technician.contactInfo ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Technician name", text: $name)
                TextField("Calendar ID or email", text: $calendarEmail)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
            }
            .navigationTitle("Edit Technician")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        technician.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        technician.contactInfo = AppAccess.normalizedEmail(calendarEmail).nilIfBlank
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .tint(Color.brandGold)
    }
}
