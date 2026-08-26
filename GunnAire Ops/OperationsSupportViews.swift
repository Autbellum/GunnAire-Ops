import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit

@MainActor
enum CustomerDataMaintenance {
    static let unassignedCalendarCustomerName = "Unassigned Calendar Event"
    static let unassignedCalendarCustomerMarker = "local-calendar-unassigned"

    struct DeletionSummary {
        var customers = 0
        var serviceCalls = 0
        var estimates = 0
        var invoices = 0
        var payments = 0
        var contracts = 0
        var timeEntries = 0
        var documentAttachments = 0
        var equipmentProfiles = 0
        var customerCommunications = 0
    }

    private static let genericCalendarCustomerNames: Set<String> = [
        "service",
        "service call",
        "install",
        "installation",
        "maintenance",
        "maintenance call",
        "repair",
        "estimate",
        "quote",
        "job",
        "appointment",
        "meeting",
        "reminder",
        "holiday",
        "site visit",
        "tune up",
        "no heat",
        "no cool",
        "ac call",
        "hvac service"
    ]

    static func isGenericCalendarCustomer(_ customer: Customer) -> Bool {
        let name = customer.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasQuickBooksLink = customer.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return genericCalendarCustomerNames.contains(name) && !hasQuickBooksLink
    }

    static func isSystemCalendarCustomer(_ customer: Customer) -> Bool {
        customer.quickBooksID == unassignedCalendarCustomerMarker ||
            customer.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(unassignedCalendarCustomerName) == .orderedSame
    }

    static func cleanupCalendarNamedCustomers(modelContext: ModelContext) -> DeletionSummary {
        let customers = (try? modelContext.fetch(FetchDescriptor<Customer>())) ?? []
        let genericCustomers = customers.filter { isGenericCalendarCustomer($0) && !isSystemCalendarCustomer($0) }
        guard !genericCustomers.isEmpty else { return DeletionSummary() }

        let serviceCalls = (try? modelContext.fetch(FetchDescriptor<ServiceCall>())) ?? []
        let estimates = (try? modelContext.fetch(FetchDescriptor<Estimate>())) ?? []
        let invoices = (try? modelContext.fetch(FetchDescriptor<Invoice>())) ?? []
        let payments = (try? modelContext.fetch(FetchDescriptor<Payment>())) ?? []
        let contracts = (try? modelContext.fetch(FetchDescriptor<RecurringMaintenanceContract>())) ?? []
        let timeEntries = (try? modelContext.fetch(FetchDescriptor<TimeEntry>())) ?? []
        let documentAttachments = (try? modelContext.fetch(FetchDescriptor<ServiceDocumentAttachment>())) ?? []
        let equipmentProfiles = (try? modelContext.fetch(FetchDescriptor<CustomerEquipment>())) ?? []
        let customerCommunications = (try? modelContext.fetch(FetchDescriptor<CustomerCommunication>())) ?? []

        var summary = DeletionSummary()
        for customer in genericCustomers {
            summary.merge(deleteCustomer(
                customer,
                modelContext: modelContext,
                serviceCalls: serviceCalls,
                estimates: estimates,
                invoices: invoices,
                payments: payments,
                contracts: contracts,
                timeEntries: timeEntries,
                documentAttachments: documentAttachments,
                equipmentProfiles: equipmentProfiles,
                customerCommunications: customerCommunications
            ))
        }
        try? modelContext.save()
        return summary
    }

    static func deleteCustomer(
        _ customer: Customer,
        modelContext: ModelContext,
        serviceCalls: [ServiceCall],
        estimates: [Estimate],
        invoices: [Invoice],
        payments: [Payment],
        contracts: [RecurringMaintenanceContract],
        timeEntries: [TimeEntry],
        documentAttachments: [ServiceDocumentAttachment],
        equipmentProfiles: [CustomerEquipment],
        customerCommunications: [CustomerCommunication]
    ) -> DeletionSummary {
        var summary = DeletionSummary()
        let customerID = customer.id
        let customerCalls = serviceCalls.filter { $0.customer.id == customerID }
        let customerCallIDs = Set(customerCalls.map(\.id))
        let customerInvoices = invoices.filter { $0.customer.id == customerID }
        let customerInvoiceIDs = Set(customerInvoices.map(\.id))

        for entry in timeEntries {
            guard let serviceCallID = entry.serviceCall?.id,
                  customerCallIDs.contains(serviceCallID) else { continue }
            modelContext.delete(entry)
            summary.timeEntries += 1
        }
        for payment in payments where customerInvoiceIDs.contains(payment.invoice.id) {
            modelContext.delete(payment)
            summary.payments += 1
        }
        for invoice in customerInvoices {
            modelContext.delete(invoice)
            summary.invoices += 1
        }
        for estimate in estimates where estimate.customer.id == customerID {
            modelContext.delete(estimate)
            summary.estimates += 1
        }
        for call in customerCalls {
            modelContext.delete(call)
            summary.serviceCalls += 1
        }
        for contract in contracts where contract.customer.id == customerID {
            modelContext.delete(contract)
            summary.contracts += 1
        }
        for attachment in documentAttachments where attachment.customer?.id == customerID {
            modelContext.delete(attachment)
            summary.documentAttachments += 1
        }
        for equipment in equipmentProfiles where equipment.customer?.id == customerID {
            modelContext.delete(equipment)
            summary.equipmentProfiles += 1
        }
        for communication in customerCommunications where communication.customer.id == customerID {
            modelContext.delete(communication)
            summary.customerCommunications += 1
        }
        modelContext.delete(customer)
        summary.customers += 1
        return summary
    }
}

private extension CustomerDataMaintenance.DeletionSummary {
    mutating func merge(_ other: CustomerDataMaintenance.DeletionSummary) {
        customers += other.customers
        serviceCalls += other.serviceCalls
        estimates += other.estimates
        invoices += other.invoices
        payments += other.payments
        contracts += other.contracts
        timeEntries += other.timeEntries
        documentAttachments += other.documentAttachments
        equipmentProfiles += other.equipmentProfiles
        customerCommunications += other.customerCommunications
    }

    var deletedAnything: Bool {
        customers + serviceCalls + estimates + invoices + payments + contracts + timeEntries + documentAttachments + equipmentProfiles + customerCommunications > 0
    }

    var customerScreenMessage: String {
        deletedAnything
            ? "Cleaned \(customers) calendar-created customer\(customers == 1 ? "" : "s"), \(serviceCalls) related local job\(serviceCalls == 1 ? "" : "s"), \(equipmentProfiles) equipment profile\(equipmentProfiles == 1 ? "" : "s"), and \(documentAttachments) attachment\(documentAttachments == 1 ? "" : "s")."
            : "No calendar-created generic customers found."
    }
}

struct CustomersView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Customer.name, order: .forward) private var customers: [Customer]
    @Query(sort: \ServiceCall.scheduledDate, order: .reverse) private var serviceCalls: [ServiceCall]
    @Query(sort: \Invoice.createdAt, order: .reverse) private var invoices: [Invoice]
    @Query(sort: \Estimate.createdAt, order: .reverse) private var estimates: [Estimate]
    @Query(sort: \Payment.date, order: .reverse) private var payments: [Payment]
    @Query(sort: \RecurringMaintenanceContract.nextDate, order: .forward) private var recurringContracts: [RecurringMaintenanceContract]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @Query(sort: \ServiceDocumentAttachment.createdAt, order: .reverse) private var documentAttachments: [ServiceDocumentAttachment]
    @Query(sort: \CustomerEquipment.name, order: .forward) private var equipmentProfiles: [CustomerEquipment]

    @State private var newCustomerName = ""
    @State private var newCustomerEmail = ""
    @State private var newCustomerPhone = ""
    @State private var newCustomerAddress = ""
    @State private var selectedCustomer: Customer?
    @State private var customerSearchText = ""
    @State private var customerSyncMessage: String?
    @State private var isSyncingCustomers = false

    private var currentEmail: String? {
        GoogleAuthManager.shared.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail")
    }

    private var filteredCustomers: [Customer] {
        let search = customerSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleCustomers = customers.filter { !CustomerDataMaintenance.isSystemCalendarCustomer($0) }
        guard !search.isEmpty else { return visibleCustomers }
        return visibleCustomers.filter { customer in
            CustomerIntelligence.matchesOperationalSearch(
                customer: customer,
                query: search,
                serviceCalls: serviceCalls,
                equipmentProfiles: equipmentProfiles,
                contracts: recurringContracts
            )
        }
    }

    private var canViewFinancials: Bool {
        AppAccess.canViewBillingFinancialDetails(
            email: currentEmail,
            users: users
        )
    }

    private var canManageCustomerRecords: Bool {
        AppAccess.canManageCustomerRecords(email: currentEmail, users: users)
    }

    private var canDeleteCustomerRecords: Bool {
        AppAccess.canDeleteCustomerRecords(email: currentEmail, users: users)
    }

    private var canSyncCustomerRecords: Bool {
        AppAccess.canSyncCustomerRecordsWithAccounting(email: currentEmail, users: users)
    }

    private var canOpenSchedule: Bool {
        AppAccess.canAccessSidebarItem(.scheduleAndJobs, email: currentEmail, users: users)
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
                if canManageCustomerRecords {
                Section("Add Customer") {
                    TextField("Customer Name", text: $newCustomerName)
                    TextField("Address", text: $newCustomerAddress, axis: .vertical)
                        .lineLimit(2...3)
                    TextField("Email", text: $newCustomerEmail)
                        .keyboardType(.emailAddress)
                    TextField("Phone", text: $newCustomerPhone)
                        .keyboardType(.phonePad)

                    Button("Save Customer") {
                        guard canManageCustomerRecords else {
                            customerSyncMessage = "This account can review customers but cannot create them."
                            return
                        }
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
                            let snapshot = customerSnapshotsByID[customer.id]
                            HStack(alignment: .top, spacing: 12) {
                                customerProfileThumbnail(for: customer, size: 54)

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
                                            .accessibilityIdentifier("OpenCustomerRecord-\(customer.id.uuidString)")

                                            if canOpenSchedule,
                                               let nextCall = nextActiveServiceCall(for: customer) {
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
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle("Customers")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if canDeleteCustomerRecords {
                        Button {
                            cleanupCalendarCreatedCustomers()
                        } label: {
                            Label("Clean Calendar Imports", systemImage: "wand.and.stars")
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if canSyncCustomerRecords {
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
        guard AppAccess.canAccessSidebarItem(.customers, email: currentEmail, users: users),
              let pendingID = GunnAireAppIntentRouter.consumePendingCustomerID(),
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
            .filter { $0.customer.id == customer.id }
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

    @ViewBuilder
    private func customerProfileThumbnail(for customer: Customer, size: CGFloat) -> some View {
        if let attachment = ServiceDocumentAttachment.primaryCustomerPhoto(for: customer, in: documentAttachments),
           let image = UIImage(contentsOfFile: attachment.localFilePath) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Customer photo")
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.brandGold.opacity(0.16))
                Text(customer.name.prefix(1).uppercased())
                    .font(.headline.weight(.semibold))
                    .foregroundColor(Color.brandGold)
            }
            .frame(width: size, height: size)
            .accessibilityLabel("Customer initials")
        }
    }

    private func cleanupCalendarCreatedCustomers() {
        guard canDeleteCustomerRecords else {
            customerSyncMessage = "Only an administrator can remove imported customer records."
            return
        }
        let summary = CustomerDataMaintenance.cleanupCalendarNamedCustomers(modelContext: modelContext)
        customerSyncMessage = summary.customerScreenMessage
    }

    private func syncCustomersToQuickBooks() {
        guard canSyncCustomerRecords else {
            customerSyncMessage = "Only an administrator can sync customers to QuickBooks."
            return
        }
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
        guard canSyncCustomerRecords else {
            isSyncingCustomers = false
            customerSyncMessage = "Customer sync stopped because this account no longer has integration access."
            return
        }
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
    @Query(sort: \ServiceDocumentAttachment.createdAt, order: .reverse) private var documentAttachments: [ServiceDocumentAttachment]
    @Query(sort: \CustomerEquipment.name, order: .forward) private var equipmentProfiles: [CustomerEquipment]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @Query(sort: \RecurringMaintenanceContract.nextDate, order: .forward) private var recurringContracts: [RecurringMaintenanceContract]
    @Query(sort: \TimeEntry.clockIn, order: .reverse) private var timeEntries: [TimeEntry]
    @Query(sort: \Item.name, order: .forward) private var items: [Item]
    @Query(sort: \Vendor.name, order: .forward) private var vendors: [Vendor]
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
            attachments: documentAttachments,
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
                        Text("Connected workstreams show no sync exceptions.")
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
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ServiceCall.scheduledDate, order: .forward) private var serviceCalls: [ServiceCall]
    @Query(sort: \Invoice.createdAt, order: .reverse) private var invoices: [Invoice]
    @Query(sort: \Estimate.createdAt, order: .reverse) private var estimates: [Estimate]
    @Query(sort: \Payment.date, order: .reverse) private var payments: [Payment]
    @Query(sort: \ServiceDocumentAttachment.createdAt, order: .reverse) private var documentAttachments: [ServiceDocumentAttachment]
    @Query(sort: \CustomerEquipment.name, order: .forward) private var equipmentProfiles: [CustomerEquipment]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @Query(sort: \Technician.name, order: .forward) private var technicians: [Technician]
    @State private var selectedServiceCallID: UUID?
    @State private var didLoadPendingRoute = false
    @State private var generatedCustomerDocumentURL: URL?
    @State private var documentExportMessage = ""

    private var quickBooksConnected: Bool {
        QuickBooksDataAPI.shared.isAuthenticated
    }

    private var currentUserEmail: String? {
        GoogleAuthManager.shared.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail")
    }

    private var canViewFinancials: Bool {
        AppAccess.canViewBillingFinancialDetails(email: currentUserEmail, users: users)
    }

    private var canCollectFieldPayments: Bool {
        AppAccess.canCollectFieldPayments(email: currentUserEmail, users: users)
    }

    private var canIncludeFinancialsInOnsiteReports: Bool {
        canViewFinancials || canCollectFieldPayments
    }

    private var openJobs: [ServiceCall] {
        visibleServiceCalls.filter { $0.status != .completed && $0.status != .cancelled }
    }

    private var visibleServiceCalls: [ServiceCall] {
        let visibleIDs = AppAccess.visibleServiceCallIDs(
            email: currentUserEmail,
            users: users,
            serviceCalls: serviceCalls,
            technicians: technicians
        )
        return serviceCalls.filter { visibleIDs.contains($0.id) }
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
        invoices.filter { invoice in
            if let call = serviceCall(for: invoice) {
                return !closeoutReadiness(for: call, invoice: invoice).isReady
            }
            return canViewFinancials && (invoiceBalanceDue(for: invoice) > 0 || invoice.finalizedAt == nil)
        }
    }

    private var selectedServiceCall: ServiceCall? {
        guard let selectedServiceCallID else { return nil }
        return visibleServiceCalls.first { $0.id == selectedServiceCallID }
    }

    private func serviceCall(for invoice: Invoice) -> ServiceCall? {
        guard let serviceCallID = invoice.serviceCallID else { return nil }
        return visibleServiceCalls.first(where: { $0.id == serviceCallID })
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
        Invoice.outstandingBalance(for: invoice, payments: payments(for: invoice))
    }

    private func closeoutReadiness(for call: ServiceCall, invoice: Invoice?) -> JobCloseoutReadiness {
        call.closeoutReadiness(
            invoice: invoice,
            payments: payments(for: invoice),
            attachments: attachments(for: call)
        )
    }

    private func closeoutSummary(for call: ServiceCall, invoice: Invoice?) -> String {
        let readiness = closeoutReadiness(for: call, invoice: invoice)
        if readiness.isReady {
            return readiness.statusLabel
        }
        return readiness.missingSummary(limit: 3)
    }

    private func billingDocumentationSummary(for call: ServiceCall) -> String? {
        call.billingDocumentationPackageSummary(
            invoice: invoice(for: call),
            estimate: estimate(for: call),
            attachments: attachments(for: call)
        )
    }

    private func documentationQueueLabel(for call: ServiceCall) -> String {
        let hasDocumentation = call.linkedInvoiceID != nil || call.linkedEstimateID != nil || call.documentationStartedAt != nil
        switch call.type {
        case .estimate:
            return hasDocumentation ? "Continue Estimate" : "Start Estimate"
        case .install, .maintenance, .service, .meeting, .reminder, .siteVisit, .other:
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
                                        if let linkedCall = serviceCall(for: invoice) {
                                            let readiness = closeoutReadiness(for: linkedCall, invoice: invoice)
                                            Text(closeoutSummary(for: linkedCall, invoice: invoice))
                                                .font(.caption2)
                                                .foregroundColor(readiness.isReady ? .green : .orange)
                                            if let packageSummary = billingDocumentationSummary(for: linkedCall) {
                                                Text(packageSummary)
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                            }
                                        } else if invoice.finalizedAt == nil {
                                            Text("Invoice finalization missing.")
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

                                            if invoiceBalanceDue(for: invoice) > 0.009 {
                                                Button("Collect Payment") {
                                                    GunnAireAppIntentRouter.storePaymentCollectionRoute(invoice.id)
                                                }
                                                .buttonStyle(.borderedProminent)
                                                .tint(.green)
                                            }

                                            Menu {
                                                Button("Generate Invoice PDF") {
                                                    generateInvoiceDocument(invoice)
                                                }
                                            } label: {
                                                Label("Documents", systemImage: "doc.on.doc")
                                            }
                                            .buttonStyle(.bordered)
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
                                    Text(call.type.displayName)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text("Checklist \(call.checklistCompletedCount)/\(call.checklistTotalCount)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    if let packageSummary = billingDocumentationSummary(for: call) {
                                        Text(packageSummary)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .lineLimit(2)
                                    }
                                    if call.linkedInvoiceID != nil {
                                        Text(closeoutSummary(for: call, invoice: invoice(for: call)))
                                            .font(.caption2)
                                            .foregroundColor(closeoutReadiness(for: call, invoice: invoice(for: call)).isReady ? .green : .orange)
                                    }
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

                                if let invoice = invoice(for: call) {
                                    Button("Generate Invoice PDF") {
                                        generateInvoiceDocument(invoice)
                                    }
                                }
                            } label: {
                                Label("Documents", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.bordered)

                            if call.linkedInvoiceID == nil {
                                Button("Create Invoice") {
                                    GunnAireAppIntentRouter.storeInvoiceBuilderRoute(call.id)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Color.brandGold)
                                .disabled(!call.canCreateInvoiceDocument)
                            } else {
                                Button("Collect Payment") {
                                    if let linkedInvoiceID = call.linkedInvoiceID {
                                        GunnAireAppIntentRouter.storePaymentCollectionRoute(linkedInvoiceID)
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)
                            }
                        }
                        if call.linkedInvoiceID == nil,
                           let blockedMessage = call.invoiceCreationBlockedMessage {
                            Text(blockedMessage)
                                .font(.caption2)
                                .foregroundColor(.orange)
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
        guard visibleServiceCalls.contains(where: { $0.id == pendingID }) else { return }
        selectedServiceCallID = pendingID
    }

    private func generateOnsiteReport(for call: ServiceCall) {
        let linkedInvoice = invoice(for: call)
        do {
            let url = try CustomerDocumentExporter.exportOnsiteReport(
                serviceCall: call,
                estimate: estimate(for: call),
                invoice: linkedInvoice,
                payments: payments(for: linkedInvoice),
                attachments: reportEvidenceAttachments(for: call),
                equipmentProfiles: equipmentProfiles,
                serviceCalls: serviceCalls,
                includeFinancials: canIncludeFinancialsInOnsiteReports
            )
            generatedCustomerDocumentURL = url
            if !call.markDocumentationCompleteIfReady() {
                call.documentationChecklist = false
            }
            persistGeneratedOnsiteReport(url, for: call, invoice: linkedInvoice, estimate: estimate(for: call))
        } catch {
            documentExportMessage = "Could not generate onsite report: \(error.localizedDescription)"
        }
    }

    private func persistGeneratedOnsiteReport(_ url: URL, for call: ServiceCall, invoice: Invoice?, estimate: Estimate?) {
        do {
            let data = try Data(contentsOf: url)
            let invoiceID = invoice?.id ?? call.linkedInvoiceID
            let estimateID = estimate?.id ?? call.linkedEstimateID
            let caption = CustomerDocumentExporter.onsiteReportAttachmentCaption(
                serviceCall: call,
                estimate: estimate,
                invoice: invoice,
                includeFinancials: canIncludeFinancialsInOnsiteReports
            )
            let attachment: ServiceDocumentAttachment
            if let reusable = ServiceDocumentAttachment.reusableGeneratedServiceReport(
                in: documentAttachments,
                serviceCallID: call.id,
                invoiceID: invoiceID,
                estimateID: estimateID
            ) {
                reusable.replaceGeneratedFile(
                    displayName: url.lastPathComponent,
                    localFilePath: url.path,
                    contentType: "application/pdf",
                    fileSizeBytes: data.count,
                    caption: caption
                )
                reusable.customerEquipmentID = call.customerEquipmentID
                attachment = reusable
            } else {
                let generated = ServiceDocumentAttachment(
                    customer: call.customer,
                    serviceCallID: call.id,
                    customerEquipmentID: call.customerEquipmentID,
                    invoiceID: invoiceID,
                    estimateID: estimateID,
                    kind: .serviceReport,
                    displayName: url.lastPathComponent,
                    caption: caption,
                    localFilePath: url.path,
                    contentType: "application/pdf",
                    fileSizeBytes: data.count
                )
                modelContext.insert(generated)
                attachment = generated
            }

            try? modelContext.save()
            syncGeneratedOnsiteReportToCompanyStorage(attachment, data: data)
            QuickBooksInvoiceAttachmentSync.syncPendingServiceReports(
                estimates: estimates,
                invoices: invoices,
                serviceCalls: serviceCalls,
                attachments: documentAttachments + [attachment],
                modelContext: modelContext
            )
            let completionNote = call.documentationCompletionBlockedMessage.map { " \($0)" } ?? ""
            if invoice?.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                documentExportMessage = "Onsite report generated and queued for QuickBooks invoice attachment.\(completionNote)"
            } else if call.linkedInvoiceID == nil && call.canCreateInvoiceDocument {
                documentExportMessage = "Onsite report generated and saved to this job. Create the invoice from this job to carry the report into billing.\(completionNote)"
            } else {
                documentExportMessage = "Onsite report generated and saved to this job.\(completionNote)"
            }
        } catch {
            documentExportMessage = "Onsite report generated, but could not save it as a job attachment: \(error.localizedDescription)"
        }
    }

    private func syncGeneratedOnsiteReportToCompanyStorage(_ attachment: ServiceDocumentAttachment, data: Data) {
        guard GunnAireBackendService.isConfigured else { return }
        Task {
            do {
                let response = try await GunnAireBackendService.uploadDocument(
                    data: data,
                    filename: attachment.displayName,
                    contentType: attachment.contentType,
                    kind: attachment.kindRaw,
                    serviceCallID: attachment.serviceCallID,
                    invoiceID: attachment.invoiceID,
                    estimateID: attachment.estimateID,
                    customerEquipmentID: attachment.customerEquipmentID,
                    equipmentName: attachment.linkedEquipment(in: equipmentProfiles, serviceCalls: serviceCalls)?.displayName,
                    customerName: attachment.customer?.name
                )
                attachment.markSharedCompanyStored(id: response.id)
                try? modelContext.save()
            } catch {
                attachment.markSharedCompanyUploadFailed(error.localizedDescription)
                try? modelContext.save()
                documentExportMessage = "Onsite report saved locally, but company storage upload failed: \(error.localizedDescription)"
            }
        }
    }

    private func attachments(for call: ServiceCall) -> [ServiceDocumentAttachment] {
        documentAttachments.filter { $0.serviceCallID == call.id }
    }

    private func reportEvidenceAttachments(for call: ServiceCall) -> [ServiceDocumentAttachment] {
        CustomerDocumentExporter.reportEvidenceAttachments(for: documentAttachments, serviceCall: call)
    }

    private func generateEstimateDocument(for call: ServiceCall) {
        guard let estimate = estimate(for: call) else {
            documentExportMessage = "No estimate is linked to this job yet."
            return
        }
        do {
            let url = try CustomerDocumentExporter.exportEstimate(
                estimate,
                serviceCall: call,
                attachments: documentAttachments,
                equipmentProfiles: equipmentProfiles,
                serviceCalls: serviceCalls
            )
            generatedCustomerDocumentURL = url
            persistGeneratedBillingDocument(
                url,
                customer: estimate.customer,
                serviceCallID: call.id,
                invoiceID: nil,
                estimateID: estimate.id,
                kind: .estimateSupport,
                caption: "Generated estimate PDF",
                successMessage: "Estimate PDF generated and saved to this job."
            )
        } catch {
            documentExportMessage = "Could not generate estimate PDF: \(error.localizedDescription)"
        }
    }

    private func generateInvoiceDocument(_ invoice: Invoice) {
        do {
            let linkedCall = serviceCall(for: invoice)
            let invoicePayments = payments(for: invoice)
            let url = try CustomerDocumentExporter.exportInvoice(
                invoice,
                serviceCall: linkedCall,
                payments: invoicePayments,
                attachments: documentAttachments,
                equipmentProfiles: equipmentProfiles,
                serviceCalls: serviceCalls
            )
            generatedCustomerDocumentURL = url
            let documentLabel = CustomerDocumentExporter.invoiceDocumentLabel(for: invoice, payments: invoicePayments)
            persistGeneratedBillingDocument(
                url,
                customer: invoice.customer,
                serviceCallID: linkedCall?.id,
                invoiceID: invoice.id,
                estimateID: nil,
                kind: .invoiceSupport,
                caption: CustomerDocumentExporter.invoiceDocumentCaption(for: invoice, payments: invoicePayments),
                successMessage: "\(documentLabel) PDF generated and saved to this job."
            )
        } catch {
            documentExportMessage = "Could not generate invoice PDF: \(error.localizedDescription)"
        }
    }

    private func persistGeneratedBillingDocument(
        _ url: URL,
        customer: Customer,
        serviceCallID: UUID?,
        invoiceID: UUID?,
        estimateID: UUID?,
        kind: ServiceDocumentAttachmentKind,
        caption: String,
        successMessage: String
    ) {
        do {
            let data = try Data(contentsOf: url)
            let equipmentID = serviceCallID.flatMap { id in serviceCalls.first { $0.id == id }?.customerEquipmentID }
            let attachment: ServiceDocumentAttachment
            if let reusable = ServiceDocumentAttachment.reusableGeneratedBillingDocument(
                in: documentAttachments,
                kind: kind,
                serviceCallID: serviceCallID,
                invoiceID: invoiceID,
                estimateID: estimateID
            ) {
                reusable.replaceGeneratedFile(
                    displayName: url.lastPathComponent,
                    localFilePath: url.path,
                    contentType: "application/pdf",
                    fileSizeBytes: data.count,
                    caption: caption
                )
                reusable.customerEquipmentID = equipmentID
                attachment = reusable
            } else {
                let generated = ServiceDocumentAttachment(
                    customer: customer,
                    serviceCallID: serviceCallID,
                    customerEquipmentID: equipmentID,
                    invoiceID: invoiceID,
                    estimateID: estimateID,
                    kind: kind,
                    displayName: url.lastPathComponent,
                    caption: caption,
                    localFilePath: url.path,
                    contentType: "application/pdf",
                    fileSizeBytes: data.count
                )
                modelContext.insert(generated)
                attachment = generated
            }
            try? modelContext.save()
            syncGeneratedBillingDocumentToCompanyStorage(attachment, data: data)
            QuickBooksInvoiceAttachmentSync.syncPendingServiceReports(
                estimates: estimates,
                invoices: invoices,
                serviceCalls: serviceCalls,
                attachments: documentAttachments + [attachment],
                modelContext: modelContext
            )
            documentExportMessage = successMessage
        } catch {
            documentExportMessage = "\(successMessage) Company document history was not updated: \(error.localizedDescription)"
        }
    }

    private func syncGeneratedBillingDocumentToCompanyStorage(_ attachment: ServiceDocumentAttachment, data: Data) {
        guard GunnAireBackendService.isConfigured else { return }
        Task {
            do {
                let response = try await GunnAireBackendService.uploadDocument(
                    data: data,
                    filename: attachment.displayName,
                    contentType: attachment.contentType,
                    kind: attachment.kindRaw,
                    serviceCallID: attachment.serviceCallID,
                    invoiceID: attachment.invoiceID,
                    estimateID: attachment.estimateID,
                    customerEquipmentID: attachment.customerEquipmentID,
                    equipmentName: attachment.linkedEquipment(in: equipmentProfiles, serviceCalls: serviceCalls)?.displayName,
                    customerName: attachment.customer?.name
                )
                attachment.markSharedCompanyStored(id: response.id)
                try? modelContext.save()
            } catch {
                attachment.markSharedCompanyUploadFailed(error.localizedDescription)
                try? modelContext.save()
                documentExportMessage = "Billing PDF saved locally, but company storage upload failed: \(error.localizedDescription)"
            }
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum CustomerProfileWorkspace: String, CaseIterable, Identifiable {
    case overview
    case systems
    case files
    case history

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview: "Overview"
        case .systems: "Systems"
        case .files: "Files"
        case .history: "History"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "person.crop.rectangle"
        case .systems: "wrench.and.screwdriver"
        case .files: "folder"
        case .history: "clock.arrow.circlepath"
        }
    }

    var guidance: String {
        switch self {
        case .overview:
            "Maintain contact and consent details, review account health, and resolve open balances."
        case .systems:
            "Maintain installed equipment, warranty context, service trends, and maintenance agreements."
        case .files:
            "Capture and review customer, equipment, service, estimate, invoice, and receipt files."
        case .history:
            "Review recent jobs and the customer-facing email and document delivery trail."
        }
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
    @Query(sort: \TimeEntry.clockIn, order: .reverse) private var timeEntries: [TimeEntry]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @Query(sort: \ServiceDocumentAttachment.createdAt, order: .reverse) private var documentAttachments: [ServiceDocumentAttachment]
    @Query(sort: \CustomerEquipment.name, order: .forward) private var equipmentProfiles: [CustomerEquipment]
    @Query(sort: \CustomerCommunication.createdAt, order: .reverse) private var customerCommunications: [CustomerCommunication]

    let customer: Customer

    @State private var name: String
    @State private var address: String
    @State private var email: String
    @State private var phone: String
    @State private var allowsTransactionalEmail: Bool
    @State private var allowsServiceText: Bool
    @State private var allowsMarketing: Bool
    @State private var preferredContactMethod: CustomerContactMethod
    @State private var newContractName: String = ""
    @State private var newContractPattern: String = ""
    @State private var newContractDate: Date = Date()
    @State private var includesContractTerm = false
    @State private var newContractTermEnd = Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date()
    @State private var newContractPricePerVisit = ""
    @State private var newContractIncludedVisits = 2
    @State private var newContractCoveredEquipmentIDs: Set<UUID> = []
    @State private var customerActionMessage: String?
    @State private var isSyncingCustomer = false
    @State private var showingDeleteConfirmation = false
    @State private var showingCustomerFileImporter = false
    @State private var showingCustomerCamera = false
    @State private var customerAttachmentKind: ServiceDocumentAttachmentKind = .customerDocument
    @State private var forcedCustomerAttachmentKind: ServiceDocumentAttachmentKind?
    @State private var customerAttachmentCaption = ""
    @State private var selectedCustomerAttachmentEquipmentID: UUID?
    @State private var customerAttachmentMessage: String?
    @State private var customerAttachmentSearchText = ""
    @State private var customerAttachmentPreviewURL: URL?
    @State private var sharedCustomerDocuments: [BackendDocumentRecord] = []
    @State private var sharedCustomerDocumentsMessage: String?
    @State private var isLoadingSharedCustomerDocuments = false
    @State private var downloadingSharedDocumentID: String?
    @State private var editingEquipmentID: UUID?
    @State private var newEquipmentType: HVACEquipmentType = .splitSystemAC
    @State private var newEquipmentName = ""
    @State private var newEquipmentManufacturer = ""
    @State private var newEquipmentModel = ""
    @State private var newEquipmentSerial = ""
    @State private var newEquipmentLocation = ""
    @State private var newEquipmentFilterSize = ""
    @State private var newEquipmentNotes = ""
    @State private var includeNewEquipmentInstallDate = false
    @State private var newEquipmentInstallDate = Date()
    @State private var includeNewEquipmentWarranty = false
    @State private var newEquipmentWarranty = Date()
    @State private var selectedWorkspace: CustomerProfileWorkspace = .overview

    private var customerServiceCalls: [ServiceCall] {
        serviceCalls.filter { $0.customer.id == customer.id }
    }

    private var recentCustomerServiceCalls: [ServiceCall] {
        Array(customerServiceCalls.prefix(5))
    }

    private var customerAttachments: [ServiceDocumentAttachment] {
        documentAttachments.filter { $0.customer?.id == customer.id }
    }

    private var visibleCustomerAttachments: [ServiceDocumentAttachment] {
        ServiceDocumentAttachment.visibleCustomerProfileAttachments(
            in: customerAttachments,
            canViewFinancials: canViewFinancials
        )
    }

    private var filteredCustomerAttachments: [ServiceDocumentAttachment] {
        let query = customerAttachmentSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return visibleCustomerAttachments }
        return visibleCustomerAttachments.filter {
            $0.matchesCustomerProfileSearch(
                query,
                serviceCalls: serviceCalls,
                invoices: invoices,
                estimates: estimates,
                equipmentProfiles: equipmentProfiles,
                canViewFinancials: canViewFinancials
            )
        }
    }

    private var generatedServiceReportAttachments: [ServiceDocumentAttachment] {
        customerLevelFilteredAttachments.filter { $0.kind.customerProfileGroupTitle == "Service Reports" }
    }

    private var customerPhotoAttachments: [ServiceDocumentAttachment] {
        customerLevelFilteredAttachments.filter { $0.kind.customerProfileGroupTitle == "Photos" }
    }

    private var estimateDocumentAttachments: [ServiceDocumentAttachment] {
        customerLevelFilteredAttachments.filter { $0.kind.customerProfileGroupTitle == "Estimate Documents" }
    }

    private var invoiceDocumentAttachments: [ServiceDocumentAttachment] {
        customerLevelFilteredAttachments.filter { $0.kind.customerProfileGroupTitle == "Invoice Documents" }
    }

    private var receiptDocumentAttachments: [ServiceDocumentAttachment] {
        customerLevelFilteredAttachments.filter { $0.kind.customerProfileGroupTitle == "Receipts & Bills" }
    }

    private var generalCustomerAttachments: [ServiceDocumentAttachment] {
        customerLevelFilteredAttachments.filter { attachment in
            attachment.kind.customerProfileGroupTitle == "Customer Files"
        }
    }

    private var customerLevelFilteredAttachments: [ServiceDocumentAttachment] {
        ServiceDocumentAttachment.customerLevelAttachments(
            in: filteredCustomerAttachments,
            equipmentProfiles: customerEquipmentProfiles,
            serviceCalls: customerServiceCalls
        )
    }

    private var equipmentAttachmentGroups: [EquipmentAttachmentGroup] {
        ServiceDocumentAttachment.groupedEquipmentAttachments(
            equipmentProfiles: customerEquipmentProfiles,
            attachments: filteredCustomerAttachments,
            serviceCalls: customerServiceCalls
        )
    }

    private var customerEquipmentProfiles: [CustomerEquipment] {
        equipmentProfiles.filter { $0.customer?.id == customer.id }
    }

    private var customerCommunicationsForCustomer: [CustomerCommunication] {
        customerCommunications.filter { $0.customer.id == customer.id }
    }

    private func equipmentFileSummary(for equipment: CustomerEquipment) -> String? {
        let attachments = ServiceDocumentAttachment.equipmentAttachments(
            for: equipment,
            in: visibleCustomerAttachments,
            serviceCalls: customerServiceCalls
        )
        guard !attachments.isEmpty else { return nil }
        return EquipmentAttachmentGroup(equipment: equipment, attachments: attachments).summary
    }

    private var matchingSharedCustomerDocuments: [BackendDocumentRecord] {
        let customerName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !customerName.isEmpty else { return [] }
        let query = customerAttachmentSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sharedCustomerDocuments.filter { document in
            document.matchesCustomerName(customerName) &&
                document.matchesCustomerDocumentSearch(query)
        }
    }

    private var customerEquipmentDropdownOptions: [SearchableDropdownOption] {
        customerEquipmentProfiles
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            .map { equipment in
                SearchableDropdownOption(
                    id: equipment.id.uuidString,
                    title: equipment.name,
                    subtitle: equipment.displayName == equipment.name ? nil : equipment.displayName
                )
            }
    }

    private var selectedCustomerAttachmentEquipmentDropdownID: Binding<String?> {
        Binding(
            get: { selectedCustomerAttachmentEquipmentID?.uuidString },
            set: { selectedCustomerAttachmentEquipmentID = $0.flatMap(UUID.init(uuidString:)) }
        )
    }

    private var openCustomerInvoiceBalances: [(invoice: Invoice, balance: Double)] {
        invoices.filter {
            $0.customer.id == customer.id
        }
        .compactMap { invoice in
            let balance = CustomerIntelligence.outstandingBalance(for: invoice, payments: payments)
            guard balance > 0 else { return nil }
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

    private var isCustomerAttachmentPreviewPresented: Binding<Bool> {
        Binding(
            get: { customerAttachmentPreviewURL != nil },
            set: { isPresented in
                if !isPresented {
                    customerAttachmentPreviewURL = nil
                }
            }
        )
    }

    private var canViewFinancials: Bool {
        AppAccess.canViewBillingFinancialDetails(
            email: GoogleAuthManager.shared.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail"),
            users: users
        )
    }

    private var currentEmail: String? {
        GoogleAuthManager.shared.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail")
    }

    private var canEditCustomerRecords: Bool {
        AppAccess.canManageCustomerRecords(email: currentEmail, users: users)
    }

    private var canDeleteCustomerRecords: Bool {
        AppAccess.canDeleteCustomerRecords(email: currentEmail, users: users)
    }

    private var canSyncCustomerRecords: Bool {
        AppAccess.canSyncCustomerRecordsWithAccounting(email: currentEmail, users: users)
    }

    private var customerFileImporterContentTypes: [UTType] {
        forcedCustomerAttachmentKind == .customerProfilePhoto
            ? [.image]
            : [.image, .pdf, .plainText, .data]
    }

    init(customer: Customer) {
        self.customer = customer
        _name = State(initialValue: customer.name)
        _address = State(initialValue: customer.address ?? "")
        _email = State(initialValue: customer.email ?? "")
        _phone = State(initialValue: customer.phone ?? "")
        _allowsTransactionalEmail = State(initialValue: customer.allowsTransactionalEmail)
        _allowsServiceText = State(initialValue: customer.allowsServiceText)
        _allowsMarketing = State(initialValue: customer.allowsMarketing)
        _preferredContactMethod = State(initialValue: customer.preferredContactMethod)
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
                Section("Customer Workspace") {
                    Picker("Workspace", selection: $selectedWorkspace) {
                        ForEach(CustomerProfileWorkspace.allCases) { workspace in
                            Text(workspace.label).tag(workspace)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("CustomerProfileWorkspacePicker")

                    Label(selectedWorkspace.guidance, systemImage: selectedWorkspace.systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !canEditCustomerRecords {
                        Label("Read-only customer record for this account role.", systemImage: "lock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("CustomerRecordReadOnlyNotice")
                    }
                }

                if selectedWorkspace == .overview {
                Section("Profile Photo") {
                    if let profilePhoto = ServiceDocumentAttachment.primaryCustomerPhoto(for: customer, in: customerAttachments) {
                        customerAttachmentRow(profilePhoto)
                    }
                    if canEditCustomerRecords {
                    HStack {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button {
                                beginDirectProfilePhotoCapture()
                            } label: {
                                Label("Take Profile Photo", systemImage: "camera")
                            }
                            .buttonStyle(.bordered)
                        }

                        Button {
                            beginDirectProfilePhotoImport()
                        } label: {
                            Label("Import Profile Photo", systemImage: "photo")
                        }
                        .buttonStyle(.bordered)
                    }
                    }
                }

                TextField("Customer Name", text: $name)
                    .disabled(!canEditCustomerRecords)
                TextField("Address", text: $address, axis: .vertical)
                    .lineLimit(2...3)
                    .disabled(!canEditCustomerRecords)
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .disabled(!canEditCustomerRecords)
                TextField("Phone", text: $phone)
                    .keyboardType(.phonePad)
                    .disabled(!canEditCustomerRecords)
                Section("Contact Preferences") {
                    Picker("Preferred Contact", selection: $preferredContactMethod) {
                        ForEach(CustomerContactMethod.allCases) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    Toggle("Allow service and billing email", isOn: $allowsTransactionalEmail)
                    Toggle("Allow service text messages", isOn: $allowsServiceText)
                    Toggle("Allow marketing email", isOn: $allowsMarketing)

                    Text("Service and billing email covers appointment, estimate, invoice, and report delivery. Marketing is optional and never implied by service consent. Text preference is stored for a future consent-aware provider; this app does not send texts yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .disabled(!canEditCustomerRecords)
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
                }

                if selectedWorkspace == .systems {
                Section("Equipment Profiles") {
                    if customerEquipmentProfiles.isEmpty {
                        Text("No equipment profiles saved for this customer.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(customerEquipmentProfiles) { equipment in
                            VStack(alignment: .leading, spacing: 4) {
                                if let equipmentPhoto = ServiceDocumentAttachment.primaryEquipmentPhoto(
                                    for: equipment,
                                    in: visibleCustomerAttachments,
                                    serviceCalls: customerServiceCalls
                                ) {
                                    customerAttachmentThumbnail(for: equipmentPhoto)
                                }
                                HStack {
                                    Text(equipment.name)
                                        .font(.headline)
                                    Spacer()
                                    Text(equipment.isActive ? "Active" : "Inactive")
                                        .font(.caption)
                                        .foregroundColor(equipment.isActive ? .green : .secondary)
                                }
                                Text(equipment.displayName)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if let location = equipment.location, !location.isEmpty {
                                    Text("Location: \(location)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                if let warranty = equipment.warrantyExpiration {
                                    Text("Warranty: \(warranty.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                if let history = equipment.serviceHistorySummary(in: customerServiceCalls) {
                                    Text(history)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                if let followUp = equipment.openFollowUpSummary(in: customerServiceCalls) {
                                    Text("Follow-up: \(followUp)")
                                        .font(.caption2)
                                        .foregroundColor(followUp.localizedCaseInsensitiveContains("overdue") ? .red : .orange)
                                        .lineLimit(3)
                                }
                                if let concerns = equipment.unresolvedServiceConcernSummary(in: customerServiceCalls) {
                                    Text("Open concerns: \(concerns)")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                        .lineLimit(3)
                                }
                                if let readings = equipment.latestTechnicalReadingsSummary(in: customerServiceCalls) {
                                    Text("Last readings: \(readings)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(3)
                                }
                                if let trends = equipment.recentTechnicalTrendSummary(in: customerServiceCalls) {
                                    Text("Reading trends: \(trends)")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                        .lineLimit(3)
                                }
                                if let fileSummary = equipmentFileSummary(for: equipment) {
                                    Text("Files: \(fileSummary)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                                if canEditCustomerRecords {
                                HStack {
                                    Button("Edit") {
                                        beginEditingEquipment(equipment)
                                    }
                                    .buttonStyle(.bordered)

                                    Button(equipment.isActive ? "Deactivate" : "Reactivate") {
                                        equipment.isActive.toggle()
                                        try? modelContext.save()
                                    }
                                    .buttonStyle(.bordered)

                                    Button(role: .destructive) {
                                        removeEquipmentProfile(equipment)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .buttonStyle(.bordered)
                                }
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }

                    if canEditCustomerRecords {
                    Picker("Type", selection: $newEquipmentType) {
                        ForEach(HVACEquipmentType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    TextField("Equipment Name", text: $newEquipmentName)
                    TextField("Manufacturer", text: $newEquipmentManufacturer)
                    TextField("Model", text: $newEquipmentModel)
                    TextField("Serial Number", text: $newEquipmentSerial)
                    TextField("Location", text: $newEquipmentLocation)
                    TextField("Filter Size", text: $newEquipmentFilterSize)
                    TextField("Equipment Notes", text: $newEquipmentNotes, axis: .vertical)
                        .lineLimit(2...4)
                    Toggle("Track Install Date", isOn: $includeNewEquipmentInstallDate)
                    if includeNewEquipmentInstallDate {
                        DatePicker("Install Date", selection: $newEquipmentInstallDate, displayedComponents: .date)
                    }
                    Toggle("Track Warranty Expiration", isOn: $includeNewEquipmentWarranty)
                    if includeNewEquipmentWarranty {
                        DatePicker("Warranty Expiration", selection: $newEquipmentWarranty, displayedComponents: .date)
                    }
                    Button {
                        addCustomerEquipmentProfile()
                    } label: {
                        Label(editingEquipmentID == nil ? "Add Equipment Profile" : "Update Equipment Profile", systemImage: "wrench.and.screwdriver")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandGold)
                    .foregroundStyle(Color.primaryBlack)
                    .disabled(newEquipmentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if editingEquipmentID != nil {
                        Button("Cancel Equipment Edit") {
                            resetEquipmentEditor()
                        }
                        .buttonStyle(.bordered)
                    }
                    }
                }
                }

                if selectedWorkspace == .files {
                Section("Documents & Photos") {
                    if canEditCustomerRecords {
                    Picker("Attachment Type", selection: $customerAttachmentKind) {
                        Text(ServiceDocumentAttachmentKind.customerProfilePhoto.label).tag(ServiceDocumentAttachmentKind.customerProfilePhoto)
                        Text(ServiceDocumentAttachmentKind.customerDocument.label).tag(ServiceDocumentAttachmentKind.customerDocument)
                        Text(ServiceDocumentAttachmentKind.diagnosticPhoto.label).tag(ServiceDocumentAttachmentKind.diagnosticPhoto)
                        Text(ServiceDocumentAttachmentKind.equipmentDataPlatePhoto.label).tag(ServiceDocumentAttachmentKind.equipmentDataPlatePhoto)
                        if canViewFinancials {
                            Text(ServiceDocumentAttachmentKind.receipt.label).tag(ServiceDocumentAttachmentKind.receipt)
                        }
                        Text(ServiceDocumentAttachmentKind.other.label).tag(ServiceDocumentAttachmentKind.other)
                    }

                    TextField("Caption or notes", text: $customerAttachmentCaption, axis: .vertical)
                        .lineLimit(2...4)

                    if !customerEquipmentDropdownOptions.isEmpty {
                        SearchableDropdownPicker(
                            title: "Linked Equipment",
                            options: customerEquipmentDropdownOptions,
                            selectedID: selectedCustomerAttachmentEquipmentDropdownID,
                            placeholder: "No linked equipment",
                            showsClearButton: true
                        )
                    }

                    HStack {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button {
                                showingCustomerCamera = true
                            } label: {
                                Label("Camera", systemImage: "camera")
                            }
                            .buttonStyle(.bordered)
                        }

                        Button {
                            showingCustomerFileImporter = true
                        } label: {
                            Label("Files", systemImage: "paperclip")
                        }
                        .buttonStyle(.bordered)
                    }
                    }

                    if let customerAttachmentMessage {
                        Text(customerAttachmentMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if visibleCustomerAttachments.isEmpty {
                        Text("No customer documents or photos saved yet.")
                            .foregroundColor(.secondary)
                    } else {
                        TextField("Search documents and photos", text: $customerAttachmentSearchText)
                            .textInputAutocapitalization(.never)

                        if filteredCustomerAttachments.isEmpty {
                            Text("No saved customer documents or photos match that search.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            customerEquipmentAttachmentHistory()
                            customerAttachmentGroup("Service Reports", attachments: generatedServiceReportAttachments)
                            if canViewFinancials {
                                customerAttachmentGroup("Estimate Documents", attachments: estimateDocumentAttachments)
                                customerAttachmentGroup("Invoice Documents", attachments: invoiceDocumentAttachments)
                                customerAttachmentGroup("Receipts & Bills", attachments: receiptDocumentAttachments)
                            }
                            customerAttachmentGroup("Photos", attachments: customerPhotoAttachments)
                            customerAttachmentGroup("Customer Files", attachments: generalCustomerAttachments)
                        }
                    }

                    if canViewFinancials {
                        Divider()
                        HStack {
                            Text("Shared Company Storage")
                                .font(.headline)
                            Spacer()
                            Button(isLoadingSharedCustomerDocuments ? "Refreshing..." : "Refresh") {
                                Task {
                                    await refreshSharedCustomerDocuments()
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isLoadingSharedCustomerDocuments || !GunnAireBackendService.isConfigured)
                        }

                        if !GunnAireBackendService.isConfigured {
                            Text("Shared company storage is not configured for this build.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else if matchingSharedCustomerDocuments.isEmpty {
                            Text(sharedCustomerDocumentsMessage ?? "No shared company documents loaded for this customer.")
                                .font(.caption)
                                .foregroundColor((sharedCustomerDocumentsMessage ?? "").localizedCaseInsensitiveContains("failed") ? .orange : .secondary)
                        } else {
                            ForEach(matchingSharedCustomerDocuments.prefix(8)) { document in
                                sharedCustomerDocumentRow(document)
                            }
                            if let sharedCustomerDocumentsMessage {
                                Text(sharedCustomerDocumentsMessage)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                }

                if selectedWorkspace == .history,
                   !customerCommunicationsForCustomer.isEmpty {
                    Section("Sent Documents & Emails") {
                        Text("A delivery record is kept for customer-facing email. Full message content remains in the connected Gmail mailbox.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        ForEach(customerCommunicationsForCustomer.prefix(12)) { communication in
                            customerCommunicationRow(communication)
                        }
                    }
                }

                if selectedWorkspace == .history,
                   !recentCustomerServiceCalls.isEmpty {
                    Section("Recent Jobs") {
                        ForEach(recentCustomerServiceCalls) { call in
                            recentCustomerJobRow(for: call)
                        }
                    }
                }

                if selectedWorkspace == .overview,
                   canViewFinancials,
                   !openCustomerInvoiceBalances.isEmpty {
                    Section("Open Invoices") {
                        ForEach(openCustomerInvoiceBalances.prefix(5), id: \.invoice.id) { entry in
                            openInvoiceBalanceRow(for: entry)
                        }
                    }
                }

                if selectedWorkspace == .systems {
                Section("Service Agreements") {
                    if customer.recurringContracts.isEmpty {
                        Text("No service agreements on file.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(customer.recurringContracts.sorted(by: { $0.nextDate < $1.nextDate })) { contract in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(contract.displayName)
                                        .font(.headline)
                                    Spacer()
                                    Text(contract.isExpired ? "Expired" : (contract.active ? "Active" : "Inactive"))
                                        .font(.caption)
                                        .foregroundColor(contract.isExpired ? .orange : (contract.active ? .green : .secondary))
                                }
                                Text(contract.schedulePattern)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("Next visit: \(contract.nextDate.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if let termEndsOn = contract.termEndsOn {
                                    Text("Term ends: \(termEndsOn.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption2)
                                        .foregroundColor(contract.needsRenewalAttention || contract.isExpired ? .orange : .secondary)
                                }
                                if let pricePerVisit = contract.pricePerVisit {
                                    Text("Member visit price: \(pricePerVisit, format: .currency(code: "USD"))")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                if let includedVisits = contract.includedVisitsPerTerm {
                                    Text("Included visits per term: \(includedVisits)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                let coveredEquipment = customerEquipmentProfiles.filter { contract.coveredEquipmentIDs.contains($0.id) }
                                if !coveredEquipment.isEmpty {
                                    Text("Covered: \(coveredEquipment.map(\.displayName).joined(separator: ", "))")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                                Text("Reminder: \(contract.reminderDate.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Toggle("Active", isOn: Binding(
                                    get: { contract.active },
                                    set: { contract.active = $0 }
                                ))
                                .disabled(!canEditCustomerRecords)
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    if canEditCustomerRecords {
                    DisclosureGroup("Add Service Agreement") {
                        TextField("Plan Name (optional)", text: $newContractName)
                        TextField("Schedule Pattern", text: $newContractPattern)
                        DatePicker("Next Visit", selection: $newContractDate, displayedComponents: .date)
                        Toggle("Set Agreement Term", isOn: $includesContractTerm)
                        if includesContractTerm {
                            DatePicker("Term Ends", selection: $newContractTermEnd, displayedComponents: .date)
                        }
                        TextField("Member Visit Price (optional)", text: $newContractPricePerVisit)
                            .keyboardType(.decimalPad)
                        Stepper("Included Visits Per Term: \(newContractIncludedVisits)", value: $newContractIncludedVisits, in: 1...12)
                        if !customerEquipmentProfiles.isEmpty {
                            Text("Covered Equipment")
                                .font(.subheadline.weight(.semibold))
                            ForEach(customerEquipmentProfiles) { equipment in
                                Toggle(equipment.displayName, isOn: Binding(
                                    get: { newContractCoveredEquipmentIDs.contains(equipment.id) },
                                    set: { isCovered in
                                        if isCovered {
                                            newContractCoveredEquipmentIDs.insert(equipment.id)
                                        } else {
                                            newContractCoveredEquipmentIDs.remove(equipment.id)
                                        }
                                    }
                                ))
                            }
                        }
                        Button("Add Service Agreement") {
                            let contract = RecurringMaintenanceContract(
                                customer: customer,
                                planName: newContractName.nilIfBlank,
                                schedulePattern: newContractPattern.trimmingCharacters(in: .whitespacesAndNewlines),
                                nextDate: newContractDate,
                                active: true,
                                termEndsOn: includesContractTerm ? newContractTermEnd : nil,
                                pricePerVisit: Double(newContractPricePerVisit),
                                includedVisitsPerTerm: newContractIncludedVisits,
                                coveredEquipmentIDs: newContractCoveredEquipmentIDs
                            )
                            modelContext.insert(contract)
                            newContractName = ""
                            newContractPattern = ""
                            newContractDate = Date()
                            includesContractTerm = false
                            newContractPricePerVisit = ""
                            newContractIncludedVisits = 2
                            newContractCoveredEquipmentIDs = []
                        }
                        .disabled(newContractPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    }
                }

                if canViewFinancials, !customer.activeStoredPaymentMethods.isEmpty {
                    Section("Payment Method on File") {
                        DisclosureGroup("\(customer.activeStoredPaymentMethods.count) QuickBooks payment method\(customer.activeStoredPaymentMethods.count == 1 ? "" : "s")") {
                            ForEach(customer.activeStoredPaymentMethods) { method in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(method.displayLabel)
                                    if let expirationLabel = method.expirationLabel {
                                        Text(expirationLabel)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        Text("QuickBooks retains the payment credentials. GunnAire keeps only masked operational references; recurring charges remain disabled until customer authorization and accounting approval are recorded.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .accessibilityIdentifier("CustomerStoredPaymentMethods")
                }
                }

                if selectedWorkspace == .overview,
                   canSyncCustomerRecords || canDeleteCustomerRecords {
                Section("Customer Actions") {
                    if canSyncCustomerRecords {
                        Button {
                            syncCustomerToQuickBooks()
                        } label: {
                            Label(isSyncingCustomer ? "Syncing Customer" : "Sync Customer to QuickBooks", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(isSyncingCustomer || !QuickBooksDataAPI.shared.isAuthenticated)
                    }

                    if canDeleteCustomerRecords {
                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: {
                            Label("Remove Customer from App", systemImage: "trash")
                        }

                        Text("This removes the customer and related local app records. It does not delete QuickBooks records.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                }
            }
            .navigationTitle(canEditCustomerRecords ? "Edit Customer" : "Customer Record")
            .onAppear {
                if selectedWorkspace == .files,
                   canViewFinancials,
                   GunnAireBackendService.isConfigured,
                   sharedCustomerDocuments.isEmpty {
                    Task {
                        await refreshSharedCustomerDocuments()
                    }
                }
            }
            .onChange(of: selectedWorkspace) { _, workspace in
                if workspace == .files,
                   canViewFinancials,
                   GunnAireBackendService.isConfigured,
                   sharedCustomerDocuments.isEmpty {
                    Task {
                        await refreshSharedCustomerDocuments()
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if canEditCustomerRecords {
                        Button("Cancel") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if canEditCustomerRecords {
                    Button("Save") {
                        customer.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        customer.address = address.nilIfBlank
                        customer.email = email.nilIfBlank
                        customer.phone = phone.nilIfBlank
                        customer.allowsTransactionalEmail = allowsTransactionalEmail
                        customer.allowsServiceText = allowsServiceText
                        customer.allowsMarketing = allowsMarketing
                        customer.preferredContactMethod = preferredContactMethod
                        customer.communicationConsentUpdatedAt = Date()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .confirmationDialog("Remove this customer from the app?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
                Button("Remove Customer and Local Records", role: .destructive) {
                    deleteCustomer()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes this customer, local jobs, estimates, invoices, payments, service agreements, files, and delivery records tied to the customer. QuickBooks and retained company-server audit records are not deleted.")
            }
            .sheet(isPresented: $showingCustomerCamera) {
                CustomerAttachmentCameraPicker(sourceType: .camera) { image in
                    handleCapturedCustomerImage(image)
                }
            }
            .fileImporter(
                isPresented: $showingCustomerFileImporter,
                allowedContentTypes: customerFileImporterContentTypes,
                allowsMultipleSelection: true
            ) { result in
                handleImportedCustomerFiles(result)
            }
            .fullScreenCover(isPresented: isCustomerAttachmentPreviewPresented) {
                if let customerAttachmentPreviewURL {
                    AttachmentPreviewScreen(url: customerAttachmentPreviewURL)
                        .tint(Color.brandGold)
                }
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

    private func recentCustomerJobRow(for call: ServiceCall) -> some View {
        let title = "\(call.type.displayName) • \(call.status.rawValue.capitalized)"
        let scheduled = call.scheduledDate.formatted(date: .abbreviated, time: .shortened)
        let trimmedNotes = call.notes?.trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(scheduled)
                .font(.caption)
                .foregroundColor(.secondary)
            if let trimmedNotes, !trimmedNotes.isEmpty {
                Text(trimmedNotes)
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

    private func openInvoiceBalanceRow(for entry: (invoice: Invoice, balance: Double)) -> some View {
        let invoice = entry.invoice
        let summary = invoice.lineItemSummary.isEmpty
            ? "Invoice \(String(invoice.id.uuidString.prefix(8)))"
            : invoice.lineItemSummary
        let serviceCall = invoice.serviceCallID.flatMap { serviceCallID in
            customerServiceCalls.first { $0.id == serviceCallID }
        }

        return VStack(alignment: .leading, spacing: 4) {
            Text(entry.balance.formatted(.currency(code: "USD")))
                .font(.headline)
            Text("\(invoice.status.capitalized) • \(invoice.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(summary)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(2)
            HStack {
                Button("Collect Payment") {
                    GunnAireAppIntentRouter.storePaymentCollectionRoute(invoice.id)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                if let serviceCall {
                    Button("Open Job") {
                        GunnAireAppIntentRouter.storeDocumentationRoute(serviceCall.id)
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func customerCommunicationRow(_ communication: CustomerCommunication) -> some View {
        let linkedInvoice = communication.invoiceID.flatMap { id in invoices.first { $0.id == id } }
        let linkedEstimate = communication.estimateID.flatMap { id in estimates.first { $0.id == id } }
        let linkedCall = communication.serviceCallID.flatMap { id in customerServiceCalls.first { $0.id == id } }

        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Label(communication.deliveryStatus.capitalized, systemImage: communication.deliveryStatus == "sent" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(communication.deliveryStatus == "sent" ? .green : .orange)
                Spacer()
                Text(communication.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Text(communication.subject)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Text("To: \(communication.recipient)")
                .font(.caption)
                .foregroundColor(.secondary)
            if let providerMessageID = communication.providerMessageID, !providerMessageID.isEmpty {
                Text("Gmail ID: \(providerMessageID)")
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
            if !communication.attachmentFileNames.isEmpty {
                Label(communication.attachmentFileNames.joined(separator: ", "), systemImage: "paperclip")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            HStack {
                if linkedInvoice != nil {
                    Button("Invoice") {
                        GunnAireAppIntentRouter.store(.invoices)
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
                if linkedEstimate != nil {
                    Button("Estimate") {
                        GunnAireAppIntentRouter.store(.estimates)
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
                if let linkedCall {
                    Button("Job") {
                        GunnAireAppIntentRouter.storeDocumentationRoute(linkedCall.id)
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func handleCapturedCustomerImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.84) else {
            customerAttachmentMessage = "Could not save the captured photo."
            forcedCustomerAttachmentKind = nil
            return
        }
        saveCustomerAttachment(
            data: data,
            filename: "customer-photo-\(UUID().uuidString).jpg",
            contentType: "image/jpeg"
        )
        forcedCustomerAttachmentKind = nil
    }

    private func handleImportedCustomerFiles(_ result: Result<[URL], Error>) {
        defer { forcedCustomerAttachmentKind = nil }
        switch result {
        case .failure(let error):
            customerAttachmentMessage = "File import failed: \(error.localizedDescription)"
        case .success(let urls):
            guard !urls.isEmpty else { return }
            for url in urls {
                let didStartAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didStartAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    let data = try Data(contentsOf: url)
                    saveCustomerAttachment(
                        data: data,
                        filename: url.lastPathComponent.isEmpty ? "customer-document-\(UUID().uuidString)" : url.lastPathComponent,
                        contentType: contentType(for: url)
                    )
                } catch {
                    customerAttachmentMessage = "Could not import \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }

    private func saveCustomerAttachment(data: Data, filename: String, contentType: String) {
        guard canEditCustomerRecords else {
            customerAttachmentMessage = "This account can review customer files but cannot add them."
            return
        }
        do {
            let storedURL = try persistCustomerAttachmentData(data, filename: filename)
            let requestedKind = forcedCustomerAttachmentKind ?? customerAttachmentKind
            let safeRequestedKind = canViewFinancials || !requestedKind.isFinancialCustomerProfileAttachment
                ? requestedKind
                : .customerDocument
            let isImage = contentType.lowercased().hasPrefix("image/")
            let attachmentKind = safeRequestedKind == .customerProfilePhoto && !isImage
                ? .customerDocument
                : safeRequestedKind
            let isProfilePhoto = attachmentKind == .customerProfilePhoto
            let attachment = ServiceDocumentAttachment(
                customer: customer,
                serviceCallID: nil,
                customerEquipmentID: isProfilePhoto ? nil : selectedCustomerAttachmentEquipmentID,
                invoiceID: nil,
                estimateID: nil,
                kind: attachmentKind,
                displayName: filename,
                caption: isProfilePhoto
                    ? (customerAttachmentCaption.nilIfBlank ?? "Customer profile photo")
                    : customerAttachmentCaption.nilIfBlank,
                localFilePath: storedURL.path,
                contentType: contentType,
                fileSizeBytes: data.count
            )
            modelContext.insert(attachment)
            try modelContext.save()
            customerAttachmentCaption = ""
            if isProfilePhoto {
                selectedCustomerAttachmentEquipmentID = nil
                customerAttachmentMessage = "Updated profile photo for \(customer.name)."
            } else {
                selectedCustomerAttachmentEquipmentID = nil
                customerAttachmentMessage = "Saved \(filename) to \(customer.name)."
            }
            syncCustomerAttachmentIfPossible(attachment, data: data)
        } catch {
            customerAttachmentMessage = "Attachment save failed: \(error.localizedDescription)"
        }
    }

    private func beginDirectProfilePhotoCapture() {
        forcedCustomerAttachmentKind = .customerProfilePhoto
        selectedCustomerAttachmentEquipmentID = nil
        showingCustomerCamera = true
    }

    private func beginDirectProfilePhotoImport() {
        forcedCustomerAttachmentKind = .customerProfilePhoto
        selectedCustomerAttachmentEquipmentID = nil
        showingCustomerFileImporter = true
    }

    private func persistCustomerAttachmentData(_ data: Data, filename: String) throws -> URL {
        let documentsURL = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folderURL = documentsURL.appendingPathComponent("GunnAire Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let fileURL = folderURL.appendingPathComponent("\(UUID().uuidString)-\(sanitizeAttachmentFilename(filename))")
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func sanitizeAttachmentFilename(_ filename: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._- "))
        let sanitized = filename.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let value = String(sanitized).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "customer-attachment" : value
    }

    private func syncCustomerAttachmentIfPossible(_ attachment: ServiceDocumentAttachment, data: Data) {
        guard GunnAireBackendService.isConfigured else { return }
        Task {
            do {
                let response = try await GunnAireBackendService.uploadDocument(
                    data: data,
                    filename: attachment.displayName,
                    contentType: attachment.contentType,
                    kind: attachment.kindRaw,
                    serviceCallID: nil,
                    invoiceID: nil,
                    estimateID: nil,
                    customerEquipmentID: attachment.customerEquipmentID,
                    equipmentName: attachment.linkedEquipment(in: equipmentProfiles, serviceCalls: serviceCalls)?.displayName,
                    customerName: customer.name
                )
                attachment.markSharedCompanyStored(id: response.id)
                try? modelContext.save()
            } catch {
                attachment.markSharedCompanyUploadFailed(error.localizedDescription)
                try? modelContext.save()
                customerAttachmentMessage = "Attachment saved locally. Company storage upload failed: \(error.localizedDescription)"
            }
        }
    }

    private func refreshSharedCustomerDocuments() async {
        guard GunnAireBackendService.isConfigured else {
            sharedCustomerDocumentsMessage = "Shared company storage is not configured."
            return
        }
        isLoadingSharedCustomerDocuments = true
        defer { isLoadingSharedCustomerDocuments = false }
        do {
            sharedCustomerDocuments = try await GunnAireBackendService.fetchDocuments()
            sharedCustomerDocumentsMessage = "Loaded \(matchingSharedCustomerDocuments.count) shared company document\(matchingSharedCustomerDocuments.count == 1 ? "" : "s") for this customer."
        } catch {
            sharedCustomerDocumentsMessage = "Shared document refresh failed: \(error.localizedDescription)"
        }
    }

    private func removeCustomerAttachment(_ attachment: ServiceDocumentAttachment) {
        guard canEditCustomerRecords else {
            customerAttachmentMessage = "This account can review customer files but cannot remove them."
            return
        }
        let fileURL = attachment.localFileURL
        modelContext.delete(attachment)
        try? modelContext.save()
        try? FileManager.default.removeItem(at: fileURL)
        customerAttachmentMessage = "Removed attachment from \(customer.name)."
    }

    private func contentType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }
        return "application/octet-stream"
    }

    @ViewBuilder
    private func customerAttachmentGroup(_ title: String, attachments: [ServiceDocumentAttachment]) -> some View {
        if !attachments.isEmpty {
            DisclosureGroup("\(title) (\(attachments.count))") {
                ForEach(attachments) { attachment in
                    customerAttachmentRow(attachment)
                }
            }
        }
    }

    @ViewBuilder
    private func customerEquipmentAttachmentHistory() -> some View {
        if !equipmentAttachmentGroups.isEmpty {
            DisclosureGroup("Equipment File History (\(equipmentAttachmentGroups.count))") {
                ForEach(equipmentAttachmentGroups) { group in
                    DisclosureGroup {
                        Text(group.summary)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if let latestDate = group.latestAttachmentDate {
                            Text("Latest file: \(latestDate.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        ForEach(group.attachments) { attachment in
                            customerAttachmentRow(attachment)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(group.equipment.displayName) (\(group.attachments.count))")
                            Text(group.summary)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func sharedCustomerDocumentRow(_ document: BackendDocumentRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: document.contentType.lowercased().hasPrefix("image/") ? "photo" : "externaldrive.badge.checkmark")
                .foregroundColor(Color.brandGold)
                .frame(width: 42, height: 42)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(document.filename)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(sharedDocumentKindLabel(document.kind))
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let createdAt = document.createdAt, !createdAt.isEmpty {
                    Text("Uploaded: \(sharedDocumentDisplayDate(createdAt))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if let serviceCallID = document.serviceCallID, !serviceCallID.isEmpty {
                    Text("Job file: \(serviceCallID.prefix(8))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if let invoiceID = document.invoiceID?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !invoiceID.isEmpty {
                    Text("Invoice file: \(invoiceID.prefix(8))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if let estimateID = document.estimateID?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !estimateID.isEmpty {
                    Text("Estimate file: \(estimateID.prefix(8))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if let equipmentLabel = sharedDocumentEquipmentLabel(document) {
                    Text(equipmentLabel)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                Text("Synced to company storage")
                    .font(.caption2)
                    .foregroundColor(.green)
                Button(downloadingSharedDocumentID == document.id ? "Downloading..." : "Download & Open") {
                    Task {
                        await downloadSharedCustomerDocument(document)
                    }
                }
                .buttonStyle(.bordered)
                .font(.caption)
                .disabled(downloadingSharedDocumentID != nil)
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }

    private func downloadSharedCustomerDocument(_ document: BackendDocumentRecord) async {
        downloadingSharedDocumentID = document.id
        defer { downloadingSharedDocumentID = nil }
        do {
            let data = try await GunnAireBackendService.downloadDocument(id: document.id)
            let cachedURL = try persistSharedCustomerDocument(data, document: document)
            hydrateSharedCustomerDocumentAttachment(document, cachedURL: cachedURL, fileSizeBytes: data.count)
            customerAttachmentPreviewURL = cachedURL
            sharedCustomerDocumentsMessage = "Downloaded \(document.filename)."
        } catch {
            sharedCustomerDocumentsMessage = "Shared document download failed: \(error.localizedDescription)"
        }
    }

    private func persistSharedCustomerDocument(_ data: Data, document: BackendDocumentRecord) throws -> URL {
        let documentsURL = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folderURL = documentsURL.appendingPathComponent("GunnAire Shared Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let fileURL = folderURL.appendingPathComponent("\(document.id)-\(sanitizeAttachmentFilename(document.filename))")
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func hydrateSharedCustomerDocumentAttachment(
        _ document: BackendDocumentRecord,
        cachedURL: URL,
        fileSizeBytes: Int
    ) {
        let attachment = ServiceDocumentAttachment.localAttachment(
            from: document,
            existingAttachments: documentAttachments,
            customer: customer,
            serviceCallID: document.serviceCallUUID,
            customerEquipmentID: document.customerEquipmentUUID,
            localFilePath: cachedURL.path,
            fileSizeBytes: fileSizeBytes
        )
        if attachment.modelContext == nil {
            modelContext.insert(attachment)
        }
        try? modelContext.save()
    }

    private func sharedDocumentKindLabel(_ kind: String) -> String {
        ServiceDocumentAttachmentKind(rawValue: kind)?.label ??
            kind.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func sharedDocumentEquipmentLabel(_ document: BackendDocumentRecord) -> String? {
        if let equipmentName = document.equipmentName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !equipmentName.isEmpty {
            return "Equipment: \(equipmentName)"
        }
        if let equipmentID = document.customerEquipmentID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !equipmentID.isEmpty {
            return "Equipment ID: \(equipmentID.prefix(8))"
        }
        return nil
    }

    private func sharedDocumentDisplayDate(_ value: String) -> String {
        let date = ISO8601DateFormatter().date(from: value) ?? Date(timeIntervalSince1970: 0)
        return Self.sharedDocumentDateFormatter.string(from: date)
    }

    private static let sharedDocumentDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private func customerAttachmentRow(_ attachment: ServiceDocumentAttachment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            customerAttachmentThumbnail(for: attachment)
            VStack(alignment: .leading, spacing: 3) {
                Text(attachment.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(attachment.kind.label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                ForEach(attachment.customerProfileDetailLines(
                    serviceCalls: serviceCalls,
                    invoices: invoices,
                    estimates: estimates,
                    equipmentProfiles: equipmentProfiles,
                    canViewFinancials: canViewFinancials
                ), id: \.self) { line in
                    Text(line)
                        .font(.caption2)
                        .foregroundColor(line.localizedCaseInsensitiveContains("failed") ? .orange : .secondary)
                        .lineLimit(2)
                }
                if let caption = attachment.caption, !caption.isEmpty {
                    Text(caption)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 12) {
                    Button {
                        previewCustomerAttachment(attachment)
                    } label: {
                        Label("Preview", systemImage: attachment.isImage ? "photo" : "doc.text.magnifyingglass")
                    }

                    ShareLink(item: attachment.localFileURL) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                .font(.caption)
            }
            Spacer()
            if canEditCustomerRecords {
                Button(role: .destructive) {
                    removeCustomerAttachment(attachment)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete attachment")
            }
        }
        .padding(.vertical, 3)
    }

    private func previewCustomerAttachment(_ attachment: ServiceDocumentAttachment) {
        let url = attachment.localFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            customerAttachmentMessage = "\(attachment.displayName) is no longer available on this device."
            return
        }
        customerAttachmentPreviewURL = url
    }

    @ViewBuilder
    private func customerAttachmentThumbnail(for attachment: ServiceDocumentAttachment) -> some View {
        if attachment.isImage,
           let image = UIImage(contentsOfFile: attachment.localFilePath) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(.separator), lineWidth: 0.5)
                )
                .accessibilityLabel("Attachment preview")
        } else {
            Image(systemName: attachment.isImage ? "photo" : "doc")
                .foregroundColor(Color.brandGold)
                .frame(width: 56, height: 56)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel(attachment.isImage ? "Photo attachment" : "Document attachment")
        }
    }

    private func addCustomerEquipmentProfile() {
        guard canEditCustomerRecords else {
            customerActionMessage = "This account can review installed systems but cannot change them."
            return
        }
        let trimmedName = newEquipmentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let equipment: CustomerEquipment
        if let editingEquipmentID,
           let existing = equipmentProfiles.first(where: { $0.id == editingEquipmentID && $0.customer?.id == customer.id }) {
            equipment = existing
        } else {
            equipment = CustomerEquipment(customer: customer, name: trimmedName)
            modelContext.insert(equipment)
        }

        equipment.updateFrom(
            equipmentType: newEquipmentType,
            name: trimmedName,
            manufacturer: newEquipmentManufacturer.nilIfBlank,
            modelNumber: newEquipmentModel.nilIfBlank,
            serialNumber: newEquipmentSerial.nilIfBlank,
            location: newEquipmentLocation.nilIfBlank,
            installDate: includeNewEquipmentInstallDate ? newEquipmentInstallDate : nil,
            warrantyExpiration: includeNewEquipmentWarranty ? newEquipmentWarranty : nil,
            filterSize: newEquipmentFilterSize.nilIfBlank,
            notes: newEquipmentNotes.nilIfBlank,
            isActive: true
        )
        try? modelContext.save()
        let action = editingEquipmentID == nil ? "Added" : "Updated"
        resetEquipmentEditor()
        customerActionMessage = "\(action) equipment profile for \(customer.name)."
    }

    private func beginEditingEquipment(_ equipment: CustomerEquipment) {
        editingEquipmentID = equipment.id
        newEquipmentType = equipment.equipmentType ?? .splitSystemAC
        newEquipmentName = equipment.name
        newEquipmentManufacturer = equipment.manufacturer ?? ""
        newEquipmentModel = equipment.modelNumber ?? ""
        newEquipmentSerial = equipment.serialNumber ?? ""
        newEquipmentLocation = equipment.location ?? ""
        newEquipmentFilterSize = equipment.filterSize ?? ""
        newEquipmentNotes = equipment.notes ?? ""
        if let installDate = equipment.installDate {
            includeNewEquipmentInstallDate = true
            newEquipmentInstallDate = installDate
        } else {
            includeNewEquipmentInstallDate = false
            newEquipmentInstallDate = Date()
        }
        if let warrantyExpiration = equipment.warrantyExpiration {
            includeNewEquipmentWarranty = true
            newEquipmentWarranty = warrantyExpiration
        } else {
            includeNewEquipmentWarranty = false
            newEquipmentWarranty = Date()
        }
        customerActionMessage = "Editing \(equipment.name)."
    }

    private func resetEquipmentEditor() {
        editingEquipmentID = nil
        newEquipmentType = .splitSystemAC
        newEquipmentName = ""
        newEquipmentManufacturer = ""
        newEquipmentModel = ""
        newEquipmentSerial = ""
        newEquipmentLocation = ""
        newEquipmentFilterSize = ""
        newEquipmentNotes = ""
        includeNewEquipmentInstallDate = false
        newEquipmentInstallDate = Date()
        includeNewEquipmentWarranty = false
        newEquipmentWarranty = Date()
    }

    private func removeEquipmentProfile(_ equipment: CustomerEquipment) {
        guard canEditCustomerRecords else {
            customerActionMessage = "This account can review installed systems but cannot remove them."
            return
        }
        let preservedAttachmentCount = ServiceDocumentAttachment.equipmentAttachments(
            for: equipment,
            in: documentAttachments,
            serviceCalls: serviceCalls
        ).count
        ServiceDocumentAttachment.detachEquipmentProfileLinks(
            for: equipment,
            from: documentAttachments,
            serviceCalls: serviceCalls
        )
        for call in serviceCalls where call.customerEquipmentID == equipment.id {
            call.customerEquipmentID = nil
        }
        modelContext.delete(equipment)
        try? modelContext.save()
        if editingEquipmentID == equipment.id {
            resetEquipmentEditor()
        }
        customerActionMessage = preservedAttachmentCount > 0
            ? "Deleted equipment profile from \(customer.name). Preserved \(preservedAttachmentCount) linked file\(preservedAttachmentCount == 1 ? "" : "s") under the customer."
            : "Deleted equipment profile from \(customer.name)."
    }

    private func deleteCustomer() {
        guard canDeleteCustomerRecords else {
            customerActionMessage = "Only an administrator can remove a customer record."
            return
        }
        _ = CustomerDataMaintenance.deleteCustomer(
            customer,
            modelContext: modelContext,
            serviceCalls: serviceCalls,
            estimates: estimates,
            invoices: invoices,
            payments: payments,
            contracts: recurringContracts,
            timeEntries: timeEntries,
            documentAttachments: documentAttachments,
            equipmentProfiles: equipmentProfiles,
            customerCommunications: customerCommunications
        )
        try? modelContext.save()
        dismiss()
    }

    private func syncCustomerToQuickBooks() {
        guard canSyncCustomerRecords else {
            customerActionMessage = "Only an administrator can sync customer records to QuickBooks."
            return
        }
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

private struct CustomerAttachmentCameraPicker: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let onImagePicked: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: CustomerAttachmentCameraPicker

        init(_ parent: CustomerAttachmentCameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImagePicked(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

private struct TechnicianEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let technician: Technician

    @State private var name: String
    @State private var calendarEmail: String
    @State private var supportedEquipmentTypes: Set<HVACEquipmentType>
    @State private var qualificationNotes: String
    @State private var serviceAreas: String
    @State private var laborCostPerHour: String

    init(technician: Technician) {
        self.technician = technician
        _name = State(initialValue: technician.name)
        _calendarEmail = State(initialValue: technician.contactInfo ?? "")
        _supportedEquipmentTypes = State(initialValue: technician.supportedEquipmentTypes)
        _qualificationNotes = State(initialValue: technician.qualificationNotes ?? "")
        _serviceAreas = State(initialValue: technician.serviceAreas.joined(separator: ", "))
        _laborCostPerHour = State(initialValue: technician.laborCostPerHour.map { String(format: "%.2f", $0) } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Technician name", text: $name)
                TextField("Calendar ID or email", text: $calendarEmail)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                Section("Internal Job Costing") {
                    TextField("Loaded labor cost per hour", text: $laborCostPerHour)
                        .keyboardType(.decimalPad)
                    Text("Used only in internal job-cost reporting after completed time is recorded. It is never shown on customer estimates or invoices.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Equipment Qualifications") {
                    Text("Leave all unchecked when qualifications have not yet been verified. Dispatch will show a review cue rather than block assignment.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(HVACEquipmentType.allCases) { type in
                        Toggle(type.displayName, isOn: Binding(
                            get: { supportedEquipmentTypes.contains(type) },
                            set: { isSupported in
                                if isSupported {
                                    supportedEquipmentTypes.insert(type)
                                } else {
                                    supportedEquipmentTypes.remove(type)
                                }
                            }
                        ))
                    }
                    TextField("Qualification notes", text: $qualificationNotes, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section("Dispatch Service Areas") {
                    TextField("Cities, ZIP codes, or territories", text: $serviceAreas, axis: .vertical)
                        .lineLimit(2...3)
                    Text("Separate entries with commas. Dispatch uses these as a visible recommendation only; office staff can always assign outside an area.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                        technician.supportedEquipmentTypes = supportedEquipmentTypes
                        technician.qualificationNotes = qualificationNotes.nilIfBlank
                        technician.serviceAreas = Technician.serviceAreas(from: serviceAreas)
                        technician.laborCostPerHour = Double(laborCostPerHour.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .tint(Color.brandGold)
    }
}
