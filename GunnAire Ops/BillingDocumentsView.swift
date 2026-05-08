import SwiftUI
import SwiftData
import UIKit

struct BillingDocumentsView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Customer.name, order: .forward) private var customers: [Customer]
    @Query(sort: \Item.name, order: .forward) private var items: [Item]
    @Query(sort: \ServiceCall.scheduledDate, order: .reverse) private var serviceCalls: [ServiceCall]
    @Query(sort: \Invoice.createdAt, order: .reverse) private var invoices: [Invoice]
    @Query(sort: \Estimate.createdAt, order: .reverse) private var estimates: [Estimate]
    @Query(sort: \Payment.date, order: .reverse) private var payments: [Payment]

    private let initialServiceCall: ServiceCall?
    private let liveAPI = QuickBooksDataAPI.shared

    @State private var selectedDocumentKind: BillingDocumentKind
    @State private var selectedCustomerID: UUID?
    @State private var selectedItems: Set<UUID> = []
    @State private var notes = ""
    @State private var customerName = ""
    @State private var customerPhone = ""
    @State private var customerEmail = ""
    @State private var customerAddress = ""
    @State private var itemSearchText = ""
    @State private var catalogFilter: DocumentationCatalogFilter = .recommended
    @State private var newItemName = ""
    @State private var newItemType: CatalogItemType = .service
    @State private var newItemDescription = ""
    @State private var newItemPrice = ""
    @State private var newItemCost = ""
    @State private var newItemTaxable = false
    @State private var actionMessage = ""
    @State private var isCreatingDocument = false
    @State private var isImportingQuickBooksItems = false
    @State private var didLoadInitialContext = false
    @State private var didAttemptInitialCatalogImport = false
    @State private var openInvoiceAfterEstimateCreation = false
    @State private var didLoadLinkedDocumentContext = false
    @State private var pendingIntentServiceCallID: UUID?
    @State private var showingItemSelector = false
    @State private var showingItemCreator = false

    init(initialServiceCall: ServiceCall? = nil, openCloseoutOnAppear: Bool = false, openTapToPayOnAppear: Bool = false) {
        self.initialServiceCall = initialServiceCall
        _selectedDocumentKind = State(initialValue: initialServiceCall?.type == .estimate ? .estimate : .invoice)
    }

    private var activeServiceCall: ServiceCall? {
        if let initialServiceCall {
            return initialServiceCall
        }
        guard let pendingIntentServiceCallID else { return nil }
        return serviceCalls.first { $0.id == pendingIntentServiceCallID }
    }

    private var selectedTotal: Double {
        selectedLineItems.reduce(0) { $0 + $1.unitPrice }
    }

    private var selectedCustomer: Customer? {
        guard let selectedCustomerID else { return nil }
        return customers.first { $0.id == selectedCustomerID }
    }

    private var selectedLineItems: [Item] {
        items.filter { selectedItems.contains($0.id) }
    }

    private var selectedCostTotal: Double {
        selectedLineItems.reduce(0) { partial, item in
            partial + (item.purchaseCost ?? 0)
        }
    }

    private var selectedGrossProfit: Double {
        selectedTotal - selectedCostTotal
    }

    private var selectedGrossMarginPercent: Double? {
        guard selectedTotal > 0 else { return nil }
        return (selectedGrossProfit / selectedTotal) * 100
    }

    private var filteredItems: [Item] {
        let query = itemSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.filter { item in
            let matchesQuery = query.isEmpty || item.name.lowercased().contains(query) ||
                (item.itemDescription?.lowercased().contains(query) ?? false)
            return matchesQuery && matchesCatalogFilter(item)
        }
    }

    private var currentJobEstimate: Estimate? {
        guard let estimateID = activeServiceCall?.linkedEstimateID else { return nil }
        return estimates.first { $0.id == estimateID }
    }

    private var currentJobInvoice: Invoice? {
        guard let invoiceID = activeServiceCall?.linkedInvoiceID else { return nil }
        return invoices.first { $0.id == invoiceID }
    }

    private var currentJobPayments: [Payment] {
        guard let invoice = currentJobInvoice else { return [] }
        return payments.filter { $0.invoice.id == invoice.id }
    }

    private var currentJobBalanceDue: Double? {
        guard let invoice = currentJobInvoice else { return nil }
        let paid = currentJobPayments.reduce(0) { $0 + $1.amount }
        return max(invoice.amount - paid, 0)
    }

    private var contextCustomer: Customer? {
        if let selectedCustomer {
            return selectedCustomer
        }
        return activeServiceCall?.customer
    }

    private var activeServiceAgreement: RecurringMaintenanceContract? {
        contextCustomer?.recurringContracts
            .filter(\.active)
            .sorted(by: { $0.nextDate < $1.nextDate })
            .first
    }

    private var recentCustomerCalls: [ServiceCall] {
        guard let customer = contextCustomer else { return [] }
        return serviceCalls
            .filter { $0.customer.id == customer.id }
            .sorted(by: { $0.scheduledDate > $1.scheduledDate })
            .prefix(4)
            .map { $0 }
    }

    private var relatedEquipmentCalls: [ServiceCall] {
        guard let call = activeServiceCall,
              let equipmentKey = normalizedEquipmentKey(for: call),
              !equipmentKey.isEmpty else { return [] }
        return serviceCalls.filter { candidate in
            candidate.id != call.id &&
            candidate.customer.id == call.customer.id &&
            normalizedEquipmentKey(for: candidate) == equipmentKey
        }
    }

    private var customerLifetimeInvoiceTotal: Double {
        guard let customer = contextCustomer else { return 0 }
        return invoices
            .filter { $0.customer.id == customer.id }
            .reduce(0) { $0 + $1.amount }
    }

    private var selectedSummary: String {
        selectedLineItems
            .map { item in
                if let description = item.itemDescription, !description.isEmpty {
                    return "\(item.name) - \(item.unitPrice.formatted(.currency(code: "USD"))) - \(description)"
                }
                return "\(item.name) - \(item.unitPrice.formatted(.currency(code: "USD")))"
            }
            .joined(separator: "\n")
    }

    private var selectedJobAddress: String? {
        let address = activeServiceCall?.siteAddress ?? activeServiceCall?.customer.address
        guard let address, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return address
    }

    private var isQuickBooksConnected: Bool {
        liveAPI.isAuthenticated
    }

    private var mapsURL: URL? {
        let address = customerAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? selectedJobAddress
            : customerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let address, !address.isEmpty else { return nil }
        var components = URLComponents(string: "http://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: address)]
        return components?.url
    }

    private var phoneURL: URL? {
        let phone = customerPhone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phone.isEmpty else { return nil }
        let digits = phone.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        return URL(string: "tel://\(digits)")
    }

    private var emailURL: URL? {
        let email = customerEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return nil }
        return URL(string: "mailto:\(email)")
    }

    private var estimateFollowUpEmailURL: URL? {
        guard let estimate = currentJobEstimate,
              let email = contextCustomer?.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        let reference = estimate.quickBooksID?.isEmpty == false ? estimate.quickBooksID! : String(estimate.id.uuidString.prefix(8))
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Estimate Follow-Up - \(reference)"),
            URLQueryItem(name: "body", value: """
Hello \(estimate.customer.name),

Following up on your estimate for \(estimate.amount.formatted(.currency(code: "USD"))).

Please let us know if you would like to move forward or if you have any questions.

Thank you,
GunnAire
""")
        ]
        return components.url
    }

    var body: some View {
        NavigationStack {
            List {
                if let call = activeServiceCall {
                    Section("Job") {
                        Text(call.customer.name)
                            .font(.headline)
                        Text(call.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                            .foregroundColor(.secondary)
                        Text("Job Type: \(call.type.rawValue.capitalized)")
                            .foregroundColor(.secondary)
                        if let selectedJobAddress {
                            Button {
                                if let mapsURL {
                                    openURL(mapsURL)
                                }
                            } label: {
                                Label(selectedJobAddress, systemImage: "map")
                                    .foregroundColor(Color.brandGold)
                            }
                            .buttonStyle(.plain)
                        }
                        if let notes = call.notes, !notes.isEmpty {
                            Text(notes)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if let findingsSummary = call.findingsSummary, !findingsSummary.isEmpty {
                            Text("Findings: \(findingsSummary)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if let recommendedWorkSummary = call.recommendedWorkSummary, !recommendedWorkSummary.isEmpty {
                            Text("Recommended Work: \(recommendedWorkSummary)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if call.followUpRequired {
                            Text("Follow-up required")
                                .font(.caption2)
                                .foregroundColor(.orange)
                            if let followUpAction = call.followUpAction, !followUpAction.isEmpty {
                                Text("Next action: \(followUpAction)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            if let followUpDueDate = call.followUpDueDate {
                                Text("Due: \(followUpDueDate.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Button("Schedule Follow-Up Visit") {
                                scheduleFollowUpVisit(for: call)
                            }
                            .buttonStyle(.bordered)
                        }
                        if let equipmentSummary = call.equipmentSummary {
                            Text(equipmentSummary)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if let warrantyDate = call.equipmentWarrantyExpiration {
                            Text("Warranty expires: \(warrantyDate.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }

                    Section("Documentation Builder") {
                        Picker("Document", selection: $selectedDocumentKind) {
                            ForEach(BillingDocumentKind.allCases) { kind in
                                Text(kind.rawValue).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)

                        HStack {
                            Text("Customer")
                            Spacer()
                            Text(customerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Not selected" : customerName)
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            Text("Selected Items")
                            Spacer()
                            Text("\(selectedLineItems.count)")
                                .foregroundColor(.secondary)
                        }

                        Menu {
                            Button("Select Existing Items") {
                                showingItemSelector = true
                            }
                            Button("Create New Item") {
                                showingItemCreator = true
                            }
                        } label: {
                            Label("Items", systemImage: "chevron.down.circle")
                        }
                        .foregroundStyle(Color.brandGold)

                        if !selectedLineItems.isEmpty {
                            ForEach(selectedLineItems.prefix(5)) { item in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name)
                                            .font(.caption)
                                        if item.isTaxable {
                                            Text("Taxable")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text(item.unitPrice, format: .currency(code: "USD"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Button("Clear Selected Items") {
                                selectedItems.removeAll()
                            }
                            .buttonStyle(.bordered)
                        }

                        HStack {
                            Text("Total")
                            Spacer()
                            Text(selectedTotal, format: .currency(code: "USD"))
                                .font(.headline)
                        }

                        if selectedLineItems.isEmpty {
                            Text("Select or add at least one item below to enable estimate and invoice creation.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Button(isCreatingDocument && selectedDocumentKind == .estimate ? "Creating Estimate..." : "Create Estimate") {
                            selectedDocumentKind = .estimate
                            createDocument()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.brandGold)
                        .foregroundStyle(Color.primaryBlack)
                        .disabled(isCreatingDocument || customerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedItems.isEmpty)

                        Button(isCreatingDocument && selectedDocumentKind == .invoice ? "Creating Invoice..." : "Create Invoice") {
                            selectedDocumentKind = .invoice
                            createDocument()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(isCreatingDocument || customerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedItems.isEmpty)

                        if !actionMessage.isEmpty {
                            Text(actionMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Section("Job Progress") {
                        Toggle("Work Completed", isOn: Binding(
                            get: { call.workCompletedChecklist },
                            set: { call.workCompletedChecklist = $0 }
                        ))
                        Toggle("Documentation Completed", isOn: Binding(
                            get: { call.documentationChecklist },
                            set: { call.documentationChecklist = $0 }
                        ))
                        Toggle("Payment Collected", isOn: Binding(
                            get: { call.paymentCollectedChecklist },
                            set: { call.paymentCollectedChecklist = $0 }
                        ))

                        Text("Checklist: \(call.checklistCompletedCount)/\(call.checklistTotalCount)")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if call.status == .scheduled || call.status == .inProgress {
                            Button(call.status == .scheduled ? "Mark Job In Progress" : "Mark Job Completed") {
                                if call.status == .scheduled {
                                    call.status = .inProgress
                                    call.documentationStartedAt = call.documentationStartedAt ?? Date()
                                } else {
                                    call.status = call.linkedInvoiceID == nil ? .completed : .invoiced
                                    call.documentationCompletedAt = Date()
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    workflowSection(for: call)
                }

                if currentJobEstimate != nil || currentJobInvoice != nil {
                    Section("Current Job Documents") {
                        if let estimate = currentJobEstimate {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Estimate")
                                    .font(.headline)
                                Text("\(estimate.amount, format: .currency(code: "USD")) • \(estimate.status.capitalized)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(estimate.lineItemSummary)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Button("Resume Estimate") {
                                    loadEstimateIntoBuilder(estimate)
                                }
                                .buttonStyle(.bordered)

                                HStack {
                                    Button("Mark Accepted") {
                                        estimate.status = "accepted"
                                        activeServiceCall?.followUpRequired = false
                                        activeServiceCall?.followUpAction = nil
                                        activeServiceCall?.followUpDueDate = nil
                                        actionMessage = "Estimate marked accepted."
                                    }
                                    .buttonStyle(.bordered)

                                    Button("Mark Rejected") {
                                        estimate.status = "rejected"
                                        activeServiceCall?.followUpRequired = false
                                        activeServiceCall?.followUpAction = nil
                                        activeServiceCall?.followUpDueDate = nil
                                        actionMessage = "Estimate marked rejected."
                                    }
                                    .buttonStyle(.bordered)
                                }

                                if let estimateFollowUpEmailURL {
                                    Button("Send Estimate Follow-Up") {
                                        openURL(estimateFollowUpEmailURL)
                                        estimate.status = "follow-up"
                                        activeServiceCall?.followUpRequired = true
                                        activeServiceCall?.followUpAction = "Follow up on estimate"
                                        activeServiceCall?.followUpDueDate = Calendar.current.date(byAdding: .day, value: 3, to: Date())
                                    }
                                    .buttonStyle(.bordered)
                                }

                                if currentJobInvoice == nil {
                                    Button("Create Invoice From Estimate") {
                                        prepareInvoiceFromEstimate(estimate)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(Color.brandGold)
                                    .foregroundStyle(Color.primaryBlack)
                                }
                            }
                            .padding(.vertical, 2)
                        }

                        if let invoice = currentJobInvoice {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Invoice")
                                    .font(.headline)
                                Text("\(invoice.amount, format: .currency(code: "USD")) • \(invoice.status.capitalized)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if let currentJobBalanceDue {
                                    Text("Balance due: \(currentJobBalanceDue, format: .currency(code: "USD"))")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                if !currentJobPayments.isEmpty {
                                    Text("Payments recorded: \(currentJobPayments.count)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    ForEach(currentJobPayments.prefix(3)) { payment in
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("\(payment.amount, format: .currency(code: "USD")) • \(payment.methodSummary) • \(payment.date.formatted(date: .abbreviated, time: .shortened))")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                            if let processorDisplayName = payment.processorDisplayName {
                                                Text("Processor: \(processorDisplayName)")
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                    }
                                }
                                if let quickBooksID = invoice.quickBooksID, !quickBooksID.isEmpty {
                                    Text("QuickBooks ID: \(quickBooksID)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Button(invoice.status == "paid" ? "Invoice Paid" : "Collect Payment") {
                                    openPaymentsForInvoice(invoice)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Color.brandGold)
                                .foregroundStyle(Color.primaryBlack)
                                .disabled(invoice.status == "paid")

                                Button("Resume Invoice") {
                                    loadInvoiceIntoBuilder(invoice)
                                }
                                .buttonStyle(.bordered)

                                if invoice.status != "paid" {
                                    Button("Record Additional Payment") {
                                        openPaymentsForInvoice(invoice)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if let customer = contextCustomer {
                    Section("Customer Context") {
                        if let agreement = activeServiceAgreement {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Active Service Agreement")
                                    .font(.headline)
                                Text(agreement.schedulePattern)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("Next visit: \(agreement.nextDate.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text("Reminder: \(agreement.reminderDate.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 2)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Customer History")
                                .font(.headline)
                            Text("\(customer.serviceCalls.count) jobs • \(customer.invoices.count) invoices • \(customer.activeContractsCount) active agreements")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if customerLifetimeInvoiceTotal > 0 {
                                Text("Lifetime invoiced: \(customerLifetimeInvoiceTotal, format: .currency(code: "USD"))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }

                        if !recentCustomerCalls.isEmpty {
                            ForEach(recentCustomerCalls) { recentCall in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(recentCall.type.rawValue.capitalized) • \(recentCall.status.rawValue.capitalized)")
                                        .font(.caption)
                                    Text(recentCall.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    if let notes = recentCall.notes, !notes.isEmpty {
                                        Text(notes)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }

                if !relatedEquipmentCalls.isEmpty {
                    Section("Equipment History") {
                        ForEach(relatedEquipmentCalls.prefix(5)) { historyCall in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(historyCall.type.rawValue.capitalized) • \(historyCall.status.rawValue.capitalized)")
                                    .font(.caption)
                                Text(historyCall.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                if let notes = historyCall.notes, !notes.isEmpty {
                                    Text(notes)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section("Builder Details") {
                    Picker("Document", selection: $selectedDocumentKind) {
                        ForEach(BillingDocumentKind.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Customer", selection: $selectedCustomerID) {
                        Text("Select Customer").tag(UUID?.none)
                        ForEach(customers) { customer in
                            Text(customer.name).tag(UUID?.some(customer.id))
                        }
                    }

                    if let call = activeServiceCall {
                        Button(selectedCustomerID == call.customer.id ? "Using Job Customer" : "Use Job Customer") {
                            selectedCustomerID = call.customer.id
                            populateCustomerFields(from: call.customer)
                        }
                        .disabled(selectedCustomerID == call.customer.id)
                    }

                    if customers.isEmpty {
                        Text("Create a customer before making invoices or estimates.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...5)

                    if activeServiceCall != nil {
                        Button("Save Notes Back To Job") {
                            syncNotesToJob()
                        }
                        .buttonStyle(.bordered)
                    }

                    Text("Total: \(selectedTotal, format: .currency(code: "USD"))")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Job Costing")
                            .font(.headline)
                        HStack {
                            Text("Revenue")
                            Spacer()
                            Text(selectedTotal, format: .currency(code: "USD"))
                                .foregroundColor(.secondary)
                        }
                        HStack {
                            Text("Estimated Cost")
                            Spacer()
                            Text(selectedCostTotal, format: .currency(code: "USD"))
                                .foregroundColor(.secondary)
                        }
                        HStack {
                            Text("Gross Profit")
                            Spacer()
                            Text(selectedGrossProfit, format: .currency(code: "USD"))
                                .foregroundColor(selectedGrossProfit >= 0 ? .secondary : .red)
                        }
                        if let selectedGrossMarginPercent {
                            HStack {
                                Text("Gross Margin")
                                Spacer()
                                Text("\(selectedGrossMarginPercent, format: .number.precision(.fractionLength(1)))%")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    if activeServiceCall != nil && selectedDocumentKind == .estimate {
                        Toggle("Open Invoice Builder After Estimate", isOn: $openInvoiceAfterEstimateCreation)
                    }

                    Button(isCreatingDocument ? "Creating..." : "Create \(selectedDocumentKind.rawValue)") {
                        createDocument()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandGold)
                    .foregroundStyle(Color.primaryBlack)
                    .disabled(isCreatingDocument || customerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedItems.isEmpty)

                    if !actionMessage.isEmpty {
                        Text(actionMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Customer") {
                    TextField("Customer name", text: $customerName)
                    TextField("Address", text: $customerAddress, axis: .vertical)
                        .lineLimit(2...3)
                    if mapsURL != nil || phoneURL != nil || emailURL != nil {
                        HStack {
                            if let phoneURL {
                                Button {
                                    openURL(phoneURL)
                                } label: {
                                    Label("Call", systemImage: "phone")
                                }
                                .buttonStyle(.bordered)
                            }
                            if let emailURL {
                                Button {
                                    openURL(emailURL)
                                } label: {
                                    Label("Email", systemImage: "envelope")
                                }
                                .buttonStyle(.bordered)
                            }
                            if let mapsURL {
                                Button {
                                    openURL(mapsURL)
                                } label: {
                                    Label("Open Address in Maps", systemImage: "map")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    TextField("Phone", text: $customerPhone)
                        .keyboardType(.phonePad)
                    TextField("Email", text: $customerEmail)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)

                    Button(selectedCustomer == nil ? "Save New Customer" : "Update Customer") {
                        saveCustomerProfile()
                    }
                    .disabled(customerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if isQuickBooksConnected {
                        Text("New customers and items created here will sync to QuickBooks when the document is created.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Items") {
                    TextField("Search items", text: $itemSearchText)
                        .textInputAutocapitalization(.never)

                    if items.isEmpty {
                        Text("No items yet. Add one below.")
                            .foregroundColor(.secondary)
                    } else {
                        Picker("Catalog Filter", selection: $catalogFilter) {
                            ForEach(DocumentationCatalogFilter.allCases) { filter in
                                Text(filter.label).tag(filter)
                            }
                        }
                        .pickerStyle(.segmented)

                        ForEach(filteredItems) { item in
                            Button {
                                toggleItem(item)
                            } label: {
                                HStack {
                                    Image(systemName: selectedItems.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(Color.brandGold)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.name)
                                            .font(.headline)
                                        if let description = item.itemDescription, !description.isEmpty {
                                            Text(description)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        HStack(spacing: 8) {
                                            Text(item.itemType.rawValue)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                            Text(item.isTaxable ? "Taxable" : "Non-taxable")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                            if let purchaseCost = item.purchaseCost {
                                                Text("Cost: \(purchaseCost, format: .currency(code: "USD"))")
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        if let quickBooksID = item.quickBooksID, !quickBooksID.isEmpty {
                                            Text("QuickBooks linked")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text(item.unitPrice, format: .currency(code: "USD"))
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if !items.isEmpty && filteredItems.isEmpty {
                        Text("No items match that search.")
                            .foregroundColor(.secondary)
                    }

                    if isQuickBooksConnected {
                        Button(isImportingQuickBooksItems ? "Importing QuickBooks Items..." : "Load QuickBooks Catalog") {
                            importQuickBooksItems()
                        }
                        .disabled(isImportingQuickBooksItems)
                    }

                    TextField("New item", text: $newItemName)
                    Picker("Item Type", selection: $newItemType) {
                        ForEach(CatalogItemType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    TextField("Description", text: $newItemDescription, axis: .vertical)
                        .lineLimit(2...3)
                    Toggle("Taxable", isOn: $newItemTaxable)
                    HStack {
                        TextField("Price", text: $newItemPrice)
                            .keyboardType(.decimalPad)
                        TextField("Cost", text: $newItemCost)
                            .keyboardType(.decimalPad)
                        Button {
                            addItem()
                        } label: {
                            Label("Add Item", systemImage: "plus")
                        }
                        .disabled(newItemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Double(newItemPrice) == nil)
                    }
                }

                Section("Estimates") {
                    if estimates.isEmpty {
                        Text("No estimates yet.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(estimates) { estimate in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(estimate.customer.name)
                                            .font(.headline)
                                        Text("\(estimate.status.capitalized) - \(estimate.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Text(estimate.amount, format: .currency(code: "USD"))
                                }
                                Text(estimate.lineItemSummary)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if let quickBooksID = estimate.quickBooksID, !quickBooksID.isEmpty {
                                    Text("QuickBooks ID: \(quickBooksID)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Button("Convert to Invoice") {
                                    convertEstimate(estimate)
                                }
                                .buttonStyle(.bordered)
                                .disabled(estimate.status == "invoiced")
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section("Invoices") {
                    if invoices.isEmpty {
                        Text("No invoices yet.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(invoices) { invoice in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(invoice.customer.name)
                                            .font(.headline)
                                        Text("\(invoice.status.capitalized) - \(invoice.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Text(invoice.amount, format: .currency(code: "USD"))
                                }
                                Text(invoice.lineItemSummary)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if let signatureName = invoice.customerSignatureName, !signatureName.isEmpty {
                                    Text("Signed by \(signatureName)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                if invoice.finalizedAt != nil {
                                    Text("Finalized")
                                        .font(.caption2)
                                        .foregroundColor(.green)
                                }
                                Button(invoice.status == "paid" ? "Paid" : "Collect Payment") {
                                    openPaymentsForInvoice(invoice)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Color.brandGold)
                                .foregroundStyle(Color.primaryBlack)
                                .disabled(invoice.status == "paid")
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section("Payments") {
                    if payments.isEmpty {
                        Text("No payments recorded yet.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(payments.prefix(12)) { payment in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(payment.invoice.customer.name)
                                    Text("\(payment.methodSummary) - \(payment.date.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    if let processorDisplayName = payment.processorDisplayName {
                                        Text("Processor: \(processorDisplayName)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                Text(payment.amount, format: .currency(code: "USD"))
                            }
                        }
                    }
                }
            }
            .navigationTitle(activeServiceCall == nil ? "Invoices & Estimates" : "Job Documentation")
            .sheet(isPresented: $showingItemSelector) {
                DocumentationItemSelectorView(items: items, selectedItems: $selectedItems)
            }
            .sheet(isPresented: $showingItemCreator) {
                DocumentationItemCreatorView { createdItemID in
                    selectedItems.insert(createdItemID)
                    itemSearchText = ""
                }
            }
            .onAppear(perform: loadInitialContextIfNeeded)
            .onChange(of: selectedCustomerID) { _, newValue in
                guard let newValue, let customer = customers.first(where: { $0.id == newValue }) else { return }
                populateCustomerFields(from: customer)
            }
        }
    }

    private func loadInitialContextIfNeeded() {
        guard !didLoadInitialContext else { return }
        didLoadInitialContext = true
        loadPendingIntentServiceCallIfNeeded()

        if let call = activeServiceCall {
            selectedCustomerID = call.customer.id
            populateCustomerFields(from: call.customer)
            if notes.isEmpty, let callNotes = call.notes {
                notes = callNotes
            }
            if call.documentationStartedAt == nil {
                call.documentationStartedAt = Date()
            }
            if call.status == .scheduled {
                call.status = .inProgress
            }
            if customerAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let address = selectedJobAddress {
                customerAddress = address
            }
            if !didLoadLinkedDocumentContext {
                loadLinkedDocumentContextIfNeeded()
            }
            openInvoiceAfterEstimateCreation = true
        } else if let firstCustomer = customers.first {
            selectedCustomerID = firstCustomer.id
            populateCustomerFields(from: firstCustomer)
        }

        importQuickBooksItemsIfNeeded()
    }

    private func loadLinkedDocumentContextIfNeeded() {
        guard !didLoadLinkedDocumentContext else { return }
        if let invoice = currentJobInvoice {
            loadInvoiceIntoBuilder(invoice, announce: false)
            didLoadLinkedDocumentContext = true
            return
        }
        if let estimate = currentJobEstimate {
            loadEstimateIntoBuilder(estimate, announce: false)
            didLoadLinkedDocumentContext = true
        }
    }

    private func populateCustomerFields(from customer: Customer) {
        customerName = customer.name
        customerPhone = customer.phone ?? ""
        customerEmail = customer.email ?? ""
        customerAddress = customer.address ?? ""
    }

    private func saveCustomerProfile() {
        let customer = resolveCustomerForDocument()
        selectedCustomerID = customer.id
        activeServiceCall?.customer = customer
        if let trimmedAddress = customer.address?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmedAddress.isEmpty {
            activeServiceCall?.siteAddress = trimmedAddress
        }
        actionMessage = "\(customer.name) saved locally."
    }

    private func syncNotesToJob() {
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        activeServiceCall?.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        actionMessage = trimmedNotes.isEmpty ? "Cleared job notes." : "Saved documentation notes back to the job."
    }

    private func loadPendingIntentServiceCallIfNeeded() {
        guard initialServiceCall == nil, pendingIntentServiceCallID == nil else { return }
        pendingIntentServiceCallID = GunnAireAppIntentRouter.consumePendingServiceCallID()
        if let call = activeServiceCall {
            selectedDocumentKind = call.type == .estimate ? .estimate : .invoice
        }
    }

    private func addItem() {
        guard let price = Double(newItemPrice) else { return }
        let cost = Double(newItemCost)
        let item = Item(
            name: newItemName.trimmingCharacters(in: .whitespacesAndNewlines),
            itemType: newItemType,
            unitPrice: price,
            purchaseCost: cost,
            isTaxable: newItemTaxable,
            itemDescription: newItemDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : newItemDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        modelContext.insert(item)
        selectedItems.insert(item.id)
        itemSearchText = ""
        newItemName = ""
        newItemType = .service
        newItemDescription = ""
        newItemPrice = ""
        newItemCost = ""
        newItemTaxable = false
    }

    private func importQuickBooksItems() {
        guard isQuickBooksConnected else { return }
        isImportingQuickBooksItems = true
        actionMessage = "Loading QuickBooks catalog..."
        liveAPI.fetchItems { result in
            DispatchQueue.main.async {
                isImportingQuickBooksItems = false
                switch result {
                case .failure(let error):
                    actionMessage = "QuickBooks catalog sync failed: \(error.localizedDescription)"
                case .success(let quickBooksItems):
                    var imported = 0
                    for quickBooksItem in quickBooksItems {
                        let normalizedID = quickBooksItem.Id.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let existing = items.first(where: { $0.quickBooksID == normalizedID }) {
                            existing.name = quickBooksItem.Name
                            if let itemType = quickBooksItem.ItemType {
                                existing.itemTypeRawValue = itemType
                            }
                            existing.unitPrice = quickBooksItem.UnitPrice ?? existing.unitPrice
                            existing.purchaseCost = quickBooksItem.PurchaseCost ?? existing.purchaseCost
                            existing.isTaxable = quickBooksItem.Taxable ?? existing.isTaxable
                            existing.itemDescription = quickBooksItem.Description ?? existing.itemDescription
                            continue
                        }

                        let localItem = Item(
                            quickBooksID: normalizedID,
                            name: quickBooksItem.Name,
                            itemType: CatalogItemType(rawValue: quickBooksItem.ItemType ?? "") ?? .service,
                            unitPrice: quickBooksItem.UnitPrice ?? 0,
                            purchaseCost: quickBooksItem.PurchaseCost,
                            isTaxable: quickBooksItem.Taxable ?? false,
                            itemDescription: quickBooksItem.Description
                        )
                        modelContext.insert(localItem)
                        imported += 1
                    }
                    actionMessage = imported == 0
                        ? "QuickBooks catalog is already up to date."
                        : "Imported \(imported) catalog items from QuickBooks."
                }
            }
        }
    }

    private func importQuickBooksItemsIfNeeded() {
        guard !didAttemptInitialCatalogImport else { return }
        didAttemptInitialCatalogImport = true
        guard isQuickBooksConnected, items.isEmpty else { return }
        importQuickBooksItems()
    }

    private func loadEstimateIntoBuilder(_ estimate: Estimate, announce: Bool = true) {
        applyDocumentContext(
            customer: estimate.customer,
            notes: estimate.notes,
            lineItemSummary: estimate.lineItemSummary,
            preferredKind: .estimate,
            announce: announce
        )
    }

    private func prepareInvoiceFromEstimate(_ estimate: Estimate) {
        applyDocumentContext(
            customer: estimate.customer,
            notes: estimate.notes,
            lineItemSummary: estimate.lineItemSummary,
            preferredKind: .invoice,
            announce: false
        )
        actionMessage = "Estimate loaded into the invoice builder for this job."
    }

    private func loadInvoiceIntoBuilder(_ invoice: Invoice, announce: Bool = true) {
        applyDocumentContext(
            customer: invoice.customer,
            notes: invoice.notes,
            lineItemSummary: invoice.lineItemSummary,
            preferredKind: .invoice,
            announce: announce
        )
    }

    private func applyDocumentContext(
        customer: Customer,
        notes: String?,
        lineItemSummary: String,
        preferredKind: BillingDocumentKind,
        announce: Bool
    ) {
        selectedDocumentKind = preferredKind
        selectedCustomerID = customer.id
        populateCustomerFields(from: customer)
        if customerAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let address = selectedJobAddress {
            customerAddress = address
        }
        self.notes = notes ?? ""

        let restoredItems = matchingItemIDs(from: lineItemSummary)
        if restoredItems.isEmpty, activeServiceCall != nil {
            selectedItems.removeAll()
        } else {
            selectedItems = restoredItems
        }

        if announce {
            actionMessage = "Loaded the saved \(preferredKind.rawValue.lowercased()) back into the builder."
        }
    }

    private func matchingItemIDs(from lineItemSummary: String) -> Set<UUID> {
        let itemNames = lineItemSummary
            .split(separator: "\n")
            .map { line in
                let value = String(line)
                if let range = value.range(of: " - ") {
                    return normalizedItemLookupKey(String(value[..<range.lowerBound]))
                }
                return normalizedItemLookupKey(value)
            }
            .filter { !$0.isEmpty }

        guard !itemNames.isEmpty else { return [] }

        let exactMatches = items.filter { itemNames.contains(normalizedItemLookupKey($0.name)) }
        if !exactMatches.isEmpty {
            return Set(exactMatches.map(\.id))
        }

        let containsMatches = items.filter { item in
            let normalizedName = normalizedItemLookupKey(item.name)
            return itemNames.contains { savedName in
                normalizedName.contains(savedName) || savedName.contains(normalizedName)
            }
        }
        return Set(containsMatches.map(\.id))
    }

    private func normalizedItemLookupKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
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
        actionMessage = "Scheduled follow-up visit for \(followUpCall.scheduledDate.formatted(date: .abbreviated, time: .shortened))."
    }

    private func matchesCatalogFilter(_ item: Item) -> Bool {
        switch catalogFilter {
        case .recommended:
            return recommendedItemMatch(item)
        case .service:
            return item.itemType == .service
        case .materials:
            return item.itemType == .nonInventory
        case .selected:
            return selectedItems.contains(item.id)
        case .all:
            return true
        }
    }

    private func recommendedItemMatch(_ item: Item) -> Bool {
        let haystack = "\(item.name) \(item.itemDescription ?? "")".lowercased()
        switch activeServiceCall?.type {
        case .service:
            return item.itemType == .service ||
                haystack.contains("repair") ||
                haystack.contains("diagnostic") ||
                haystack.contains("labor")
        case .estimate:
            return haystack.contains("estimate") ||
                haystack.contains("proposal") ||
                haystack.contains("system") ||
                item.itemType == .service
        case .install:
            return item.itemType == .nonInventory ||
                haystack.contains("install") ||
                haystack.contains("equipment") ||
                haystack.contains("system")
        case .maintenance:
            return haystack.contains("maintenance") ||
                haystack.contains("tune") ||
                haystack.contains("clean") ||
                haystack.contains("filter") ||
                item.itemType == .service
        case nil:
            return true
        }
    }

    private func toggleItem(_ item: Item) {
        if selectedItems.contains(item.id) {
            selectedItems.remove(item.id)
        } else {
            selectedItems.insert(item.id)
        }
    }

    private func resolveCustomerForDocument() -> Customer {
        let trimmedName = customerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPhone = customerPhone.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = customerEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAddress = customerAddress.trimmingCharacters(in: .whitespacesAndNewlines)

        if let selectedCustomer {
            selectedCustomer.name = trimmedName
            selectedCustomer.phone = trimmedPhone.isEmpty ? nil : trimmedPhone
            selectedCustomer.email = trimmedEmail.isEmpty ? nil : trimmedEmail
            selectedCustomer.address = trimmedAddress.isEmpty ? nil : trimmedAddress
            return selectedCustomer
        }

        let customer = Customer(
            name: trimmedName,
            phone: trimmedPhone.isEmpty ? nil : trimmedPhone,
            email: trimmedEmail.isEmpty ? nil : trimmedEmail,
            address: trimmedAddress.isEmpty ? nil : trimmedAddress
        )
        modelContext.insert(customer)
        return customer
    }

    private func createDocument() {
        guard !selectedLineItems.isEmpty else { return }

        isCreatingDocument = true
        let customer = resolveCustomerForDocument()
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedCustomerID = customer.id
        activeServiceCall?.customer = customer
        activeServiceCall?.notes = trimmedNotes.isEmpty ? activeServiceCall?.notes : trimmedNotes
        if let trimmedAddress = customer.address?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmedAddress.isEmpty {
            activeServiceCall?.siteAddress = trimmedAddress
        }

        switch selectedDocumentKind {
        case .estimate:
            let estimate = Estimate(
                serviceCallID: activeServiceCall?.id,
                customer: customer,
                lineItemSummary: selectedSummary,
                amount: selectedTotal,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes
            )
            modelContext.insert(estimate)
            activeServiceCall?.linkedEstimateID = estimate.id
            actionMessage = isQuickBooksConnected ? "Estimate created locally. Syncing to QuickBooks..." : "Estimate created locally."
            syncEstimateIfNeeded(estimate, customer: customer, items: selectedLineItems)
            if openInvoiceAfterEstimateCreation {
                selectedDocumentKind = .invoice
                actionMessage = "Estimate created. Review and create the invoice when ready."
            } else {
                selectedItems.removeAll()
                notes = ""
            }

        case .invoice:
            let invoice = Invoice(
                serviceCallID: activeServiceCall?.id,
                customer: customer,
                lineItemSummary: selectedSummary,
                amount: selectedTotal,
                status: "unpaid",
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes
            )
            modelContext.insert(invoice)
            activeServiceCall?.linkedInvoiceID = invoice.id
            activeServiceCall?.documentationCompletedAt = Date()
            activeServiceCall?.status = .invoiced
            actionMessage = isQuickBooksConnected ? "Invoice created locally. Syncing to QuickBooks..." : "Invoice created locally."
            syncInvoiceIfNeeded(invoice, customer: customer, items: selectedLineItems)
            selectedItems.removeAll()
            notes = ""
        }
        isCreatingDocument = false
    }

    private func openPaymentsForInvoice(_ invoice: Invoice) {
        GunnAireAppIntentRouter.storePaymentCollectionRoute(invoice.id)
    }

    private func syncEstimateIfNeeded(_ estimate: Estimate, customer: Customer, items: [Item]) {
        guard isQuickBooksConnected else { return }
        ensureQuickBooksDocumentInputs(customer: customer, items: items) { result in
            switch result {
            case .failure(let error):
                actionMessage = "Estimate saved locally. QuickBooks sync failed: \(error.localizedDescription)"
            case .success(let syncedItems):
                let payload = QuickBooksEstimateCreate(
                    CustomerRef: QuickBooksReference(value: customer.quickBooksID ?? "", name: customer.name),
                    Line: quickBooksLineItems(for: syncedItems),
                    PrivateNote: estimate.notes
                )
                liveAPI.createEstimate(payload) { apiResult in
                    DispatchQueue.main.async {
                        switch apiResult {
                        case .success(let quickBooksEstimate):
                            estimate.quickBooksID = quickBooksEstimate.Id
                            actionMessage = "Estimate created and synced to QuickBooks."
                        case .failure(let error):
                            actionMessage = "Estimate saved locally. QuickBooks sync failed: \(error.localizedDescription)"
                        }
                    }
                }
            }
        }
    }

    private func syncInvoiceIfNeeded(_ invoice: Invoice, customer: Customer, items: [Item]) {
        guard isQuickBooksConnected else { return }
        ensureQuickBooksDocumentInputs(customer: customer, items: items) { result in
            switch result {
            case .failure(let error):
                actionMessage = "Invoice saved locally. QuickBooks sync failed: \(error.localizedDescription)"
            case .success(let syncedItems):
                let payload = QuickBooksInvoiceCreate(
                    CustomerRef: QuickBooksReference(value: customer.quickBooksID ?? "", name: customer.name),
                    Line: quickBooksLineItems(for: syncedItems),
                    PrivateNote: invoice.notes
                )
                liveAPI.createInvoice(payload) { apiResult in
                    DispatchQueue.main.async {
                        switch apiResult {
                        case .success(let quickBooksInvoice):
                            invoice.quickBooksID = quickBooksInvoice.Id
                            actionMessage = "Invoice created and synced to QuickBooks."
                        case .failure(let error):
                            actionMessage = "Invoice saved locally. QuickBooks sync failed: \(error.localizedDescription)"
                        }
                    }
                }
            }
        }
    }

    private func ensureQuickBooksDocumentInputs(
        customer: Customer,
        items: [Item],
        completion: @escaping (Result<[Item], Error>) -> Void
    ) {
        ensureQuickBooksCustomer(customer) { customerResult in
            switch customerResult {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                ensureQuickBooksItems(items, index: 0, synced: [], completion: completion)
            }
        }
    }

    private func ensureQuickBooksCustomer(_ customer: Customer, completion: @escaping (Result<Void, Error>) -> Void) {
        if let quickBooksID = customer.quickBooksID, !quickBooksID.isEmpty {
            completion(.success(()))
            return
        }

        let payload = QuickBooksCustomerCreate(
            DisplayName: customer.name,
            PrimaryPhone: customer.phone.flatMap { $0.isEmpty ? nil : QuickBooksPhoneNumber(FreeFormNumber: $0) },
            PrimaryEmailAddr: customer.email.flatMap { $0.isEmpty ? nil : QuickBooksEmailAddress(Address: $0) },
            BillAddr: customer.address.flatMap { $0.isEmpty ? nil : QuickBooksAddress(Line1: $0) }
        )
        liveAPI.createCustomer(payload) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let quickBooksCustomer):
                    customer.quickBooksID = quickBooksCustomer.Id
                    completion(.success(()))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    private func ensureQuickBooksItems(
        _ items: [Item],
        index: Int,
        synced: [Item],
        completion: @escaping (Result<[Item], Error>) -> Void
    ) {
        guard index < items.count else {
            completion(.success(synced))
            return
        }

        let item = items[index]
        if let quickBooksID = item.quickBooksID, !quickBooksID.isEmpty {
            ensureQuickBooksItems(items, index: index + 1, synced: synced + [item], completion: completion)
            return
        }

        let payload = QuickBooksItemCreate(
            Name: item.name,
            ItemType: item.itemType.rawValue,
            Description: item.itemDescription,
            PurchaseDesc: item.itemDescription,
            UnitPrice: item.unitPrice,
            PurchaseCost: item.purchaseCost,
            Taxable: item.isTaxable,
            IncomeAccountRef: Config.QuickBooks.defaultIncomeAccountRef.isEmpty
                ? nil
                : QuickBooksReference(value: Config.QuickBooks.defaultIncomeAccountRef, name: nil),
            ExpenseAccountRef: Config.QuickBooks.defaultExpenseAccountRef.isEmpty
                ? nil
                : QuickBooksReference(value: Config.QuickBooks.defaultExpenseAccountRef, name: nil)
        )
        liveAPI.createItem(payload) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let quickBooksItem):
                    item.quickBooksID = quickBooksItem.Id
                    ensureQuickBooksItems(items, index: index + 1, synced: synced + [item], completion: completion)
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    private func quickBooksLineItems(for items: [Item]) -> [QuickBooksLineItem] {
        items.compactMap { item in
            guard let quickBooksID = item.quickBooksID, !quickBooksID.isEmpty else { return nil }
            return QuickBooksLineItem(
                Amount: item.unitPrice,
                DetailType: "SalesItemLineDetail",
                Description: item.itemDescription ?? item.name,
                SalesItemLineDetail: QuickBooksSalesItemLineDetail(
                    ItemRef: QuickBooksReference(value: quickBooksID, name: item.name)
                )
            )
        }
    }

    private func convertEstimate(_ estimate: Estimate) {
        let invoice = Invoice(
            serviceCallID: estimate.serviceCallID,
            customer: estimate.customer,
            lineItemSummary: estimate.lineItemSummary,
            amount: estimate.amount,
            notes: estimate.notes
        )
        estimate.status = "invoiced"
        modelContext.insert(invoice)
        if let serviceCallID = estimate.serviceCallID,
           let calls = try? modelContext.fetch(FetchDescriptor<ServiceCall>()),
           let call = calls.first(where: { $0.id == serviceCallID }) {
            call.linkedInvoiceID = invoice.id
            call.status = .invoiced
            call.documentationCompletedAt = Date()
        }
    }

    @ViewBuilder
    private func workflowSection(for call: ServiceCall) -> some View {
        Section(jobWorkflowTitle(for: call)) {
            Text("Workflow progress: \(call.workflowChecklistCompletedCount)/\(call.workflowChecklistTotalCount)")
                .font(.caption)
                .foregroundColor(.secondary)

            switch call.type {
            case .service:
                Toggle("Diagnostics captured", isOn: Binding(
                    get: { call.diagnosticsCaptured },
                    set: { call.diagnosticsCaptured = $0 }
                ))
                Toggle("Recommended work reviewed with customer", isOn: Binding(
                    get: { call.quoteReviewedWithCustomer },
                    set: { call.quoteReviewedWithCustomer = $0 }
                ))
                Toggle("Safety checks completed", isOn: Binding(
                    get: { call.safetyChecklistComplete },
                    set: { call.safetyChecklistComplete = $0 }
                ))
                Text("Use this for diagnostic and repair calls before building the invoice.")
                    .font(.caption2)
                    .foregroundColor(.secondary)

            case .estimate:
                Toggle("Scope reviewed with customer", isOn: Binding(
                    get: { call.quoteReviewedWithCustomer },
                    set: { call.quoteReviewedWithCustomer = $0 }
                ))
                Toggle("Findings captured for quote", isOn: Binding(
                    get: { call.diagnosticsCaptured },
                    set: { call.diagnosticsCaptured = $0 }
                ))
                Toggle("Follow-up scheduled", isOn: Binding(
                    get: { call.followUpRequired },
                    set: { call.followUpRequired = $0 }
                ))
                Text("Estimate jobs should leave with a reviewed scope and a clear next step.")
                    .font(.caption2)
                    .foregroundColor(.secondary)

            case .install:
                Toggle("Equipment verified", isOn: Binding(
                    get: { call.equipmentVerifiedChecklist },
                    set: { call.equipmentVerifiedChecklist = $0 }
                ))
                Toggle("Startup checklist complete", isOn: Binding(
                    get: { call.startupChecklistComplete },
                    set: { call.startupChecklistComplete = $0 }
                ))
                Toggle("Safety checks completed", isOn: Binding(
                    get: { call.safetyChecklistComplete },
                    set: { call.safetyChecklistComplete = $0 }
                ))
                Text("Install jobs should verify model/serial, startup, and safety before closeout.")
                    .font(.caption2)
                    .foregroundColor(.secondary)

            case .maintenance:
                Toggle("Maintenance checklist complete", isOn: Binding(
                    get: { call.maintenanceChecklistComplete },
                    set: { call.maintenanceChecklistComplete = $0 }
                ))
                Toggle("Safety checks completed", isOn: Binding(
                    get: { call.safetyChecklistComplete },
                    set: { call.safetyChecklistComplete = $0 }
                ))
                Toggle("Customer notified of findings", isOn: Binding(
                    get: { call.customerNotified },
                    set: { call.customerNotified = $0 }
                ))
                Text("Maintenance jobs should leave with service completed, safety checked, and customer informed.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func jobWorkflowTitle(for call: ServiceCall) -> String {
        switch call.type {
        case .service:
            return "Service Workflow"
        case .estimate:
            return "Estimate Workflow"
        case .install:
            return "Install Workflow"
        case .maintenance:
            return "Maintenance Workflow"
        }
    }

    private func normalizedEquipmentKey(for call: ServiceCall) -> String? {
        if let serial = call.equipmentSerialNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
           !serial.isEmpty {
            return "serial:\(serial.lowercased())"
        }

        let equipmentName = call.equipmentName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let equipmentModel = call.equipmentModel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let composite = "\(equipmentName)|\(equipmentModel)"
        return composite == "|" || composite.isEmpty ? nil : composite
    }
}

private enum DocumentationCatalogFilter: String, CaseIterable, Identifiable {
    case recommended
    case service
    case materials
    case selected
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recommended:
            return "Recommended"
        case .service:
            return "Services"
        case .materials:
            return "Materials"
        case .selected:
            return "Selected"
        case .all:
            return "All"
        }
    }
}

private struct RecordInvoicePaymentView: View {
    @AppStorage("requireCustomerSignature") private var requireCustomerSignature = true
    @AppStorage("enableOnsitePayments") private var enableOnsitePayments = false
    @AppStorage("onsitePaymentProcessor") private var onsitePaymentProcessor = OnsitePaymentProcessor.none.rawValue

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var serviceCalls: [ServiceCall]
    @Query private var payments: [Payment]

    let invoice: Invoice
    let autoStartTapToPay: Bool
    @StateObject private var onsitePaymentManager = OnsitePaymentManager.shared
    @State private var amount: String
    @State private var shouldRecordPayment: Bool
    @State private var method = "card"
    @State private var completionNotes = ""
    @State private var signatureName = ""
    @State private var signatureStrokes: [[CGPoint]] = []
    @State private var cardLast4 = ""
    @State private var authorizationCode = ""
    @State private var paymentNotes = ""
    @State private var tapToPayMessage = ""
    @State private var didTriggerAutoTapToPay = false
    @State private var isProcessingQuickBooksPayment = false
    @State private var processCardWithQuickBooks = false
    @State private var cardholderName = ""
    @State private var cardNumber = ""
    @State private var expirationMonth = ""
    @State private var expirationYear = ""
    @State private var cardCVC = ""
    @State private var billingPostalCode = ""
    @State private var achAccountHolderName = ""
    @State private var achAccountNumber = ""
    @State private var achRoutingNumber = ""
    @State private var achPhone = ""
    @State private var achCheckNumber = ""
    @State private var achAccountType: QuickBooksBankAccountType = .businessChecking

    init(invoice: Invoice, autoStartTapToPay: Bool = false) {
        self.invoice = invoice
        self.autoStartTapToPay = autoStartTapToPay
        _amount = State(initialValue: String(format: "%.2f", invoice.amount))
        _shouldRecordPayment = State(initialValue: invoice.status != "paid")
        _completionNotes = State(initialValue: invoice.completionNotes ?? "")
        _signatureName = State(initialValue: invoice.customerSignatureName ?? "")
    }

    private var hasSignatureDrawing: Bool {
        !signatureStrokes.flatMap { $0 }.isEmpty
    }

    private var hasCapturedSignature: Bool {
        hasSignatureDrawing || invoice.customerSignatureImageBase64 != nil
    }

    private var balanceDue: Double {
        max(invoice.amount - paidAmountRecorded, 0)
    }

    private var paidAmountRecorded: Double {
        payments
            .filter { $0.invoice.id == invoice.id }
            .reduce(0) { $0 + $1.amount }
    }

    private var selectedProcessor: OnsitePaymentProcessor {
        OnsitePaymentProcessor(rawValue: onsitePaymentProcessor) ?? .none
    }

    private var closeoutPaymentFormIsValid: Bool {
        guard shouldRecordPayment else { return true }
        if method == "card", QuickBooksDataAPI.shared.isAuthenticated {
            return !cardholderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                cardNumber.filter(\.isNumber).count >= 12 &&
                expirationMonth.filter(\.isNumber).count >= 1 &&
                expirationYear.filter(\.isNumber).count == 4 &&
                cardCVC.filter(\.isNumber).count >= 3
        }
        if method == "ach", QuickBooksDataAPI.shared.isAuthenticated {
            return !achAccountHolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                achAccountNumber.filter(\.isNumber).count >= 4 &&
                achRoutingNumber.filter(\.isNumber).count == 9 &&
                achPhone.filter(\.isNumber).count >= 10
        }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Invoice") {
                    Text(invoice.customer.name)
                    Text(invoice.amount, format: .currency(code: "USD"))
                    Text("Balance due: \(balanceDue, format: .currency(code: "USD"))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let quickBooksID = invoice.quickBooksID, !quickBooksID.isEmpty {
                        Text("QuickBooks ID: \(quickBooksID)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Completion") {
                    TextField("Completion notes", text: $completionNotes, axis: .vertical)
                        .lineLimit(2...4)
                    TextField("Customer signature name", text: $signatureName)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Customer signature")
                            .font(.subheadline)
                        SignaturePad(strokes: $signatureStrokes)
                            .frame(height: 180)
                        HStack {
                            if invoice.customerSignatureImageBase64 != nil || hasSignatureDrawing {
                                Text(hasSignatureDrawing ? "Signature captured for this closeout." : "A saved signature already exists for this invoice.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("Clear") {
                                signatureStrokes = []
                            }
                            .font(.caption)
                        }
                    }
                    if requireCustomerSignature {
                        Text("A customer name and signature are required before finalizing this invoice.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Payment") {
                    Toggle("Record payment now", isOn: $shouldRecordPayment)
                    if shouldRecordPayment {
                        TextField("Amount", text: $amount)
                            .keyboardType(.decimalPad)
                        Picker("Method", selection: $method) {
                            Text("Card").tag("card")
                            Text("ACH").tag("ach")
                            Text("Cash").tag("cash")
                            Text("Check").tag("check")
                        }
                        if method == "card" {
                            if enableOnsitePayments && OnsitePaymentManager.shared.tapToPayAvailableInCurrentBuild {
                                Button(onsitePaymentManager.isProcessing ? "Processing Tap to Pay..." : "Start Tap to Pay") {
                                    Task {
                                        await runTapToPay()
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Color.brandGold)
                                .foregroundStyle(Color.primaryBlack)
                                .disabled(onsitePaymentManager.isProcessing || Double(amount) == nil || selectedProcessor == .none)

                                if !tapToPayMessage.isEmpty {
                                    Text(tapToPayMessage)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            if QuickBooksDataAPI.shared.isAuthenticated {
                                Text("QuickBooks card processing")
                                    .font(.subheadline.weight(.semibold))
                                TextField("Cardholder name", text: $cardholderName)
                                TextField("Card number", text: $cardNumber)
                                    .keyboardType(.numberPad)
                                HStack {
                                    TextField("Exp MM", text: $expirationMonth)
                                        .keyboardType(.numberPad)
                                    TextField("Exp YYYY", text: $expirationYear)
                                        .keyboardType(.numberPad)
                                    TextField("CVC", text: $cardCVC)
                                        .keyboardType(.numberPad)
                                }
                                TextField("Billing ZIP", text: $billingPostalCode)
                                    .keyboardType(.numbersAndPunctuation)
                                Text("Card details are only used to create a QuickBooks Payments token for this transaction and are not saved locally.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                TextField("Card last 4", text: $cardLast4)
                                    .keyboardType(.numberPad)
                                TextField("Authorization ref", text: $authorizationCode)
                                Text("QuickBooks Payments is not connected. This card entry will only record a manual payment note.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        if method == "ach", QuickBooksDataAPI.shared.isAuthenticated {
                            TextField("Account holder name", text: $achAccountHolderName)
                            TextField("Bank account number", text: $achAccountNumber)
                                .keyboardType(.numberPad)
                            TextField("Routing number", text: $achRoutingNumber)
                                .keyboardType(.numberPad)
                            TextField("Phone", text: $achPhone)
                                .keyboardType(.phonePad)
                            Picker("Account type", selection: $achAccountType) {
                                ForEach(QuickBooksBankAccountType.allCases) { type in
                                    Text(type.displayName).tag(type)
                                }
                            }
                            TextField("Check number (optional)", text: $achCheckNumber)
                                .keyboardType(.numbersAndPunctuation)
                            Text("Bank details are only used to create a QuickBooks Payments token for this ACH/eCheck transaction and are not saved locally.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        TextField("Payment notes", text: $paymentNotes, axis: .vertical)
                            .lineLimit(2...4)
                        if enableOnsitePayments && OnsitePaymentManager.shared.tapToPayAvailableInCurrentBuild {
                            Text(onsitePaymentManager.processorStatusDetail())
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text("Finalize the documentation now and leave the invoice open for later collection.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Finalize Invoice")
            .onAppear {
                loadSuggestedCloseoutValues()
                triggerAutoTapToPayIfNeeded()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isProcessingQuickBooksPayment ? "Processing..." : (shouldRecordPayment ? "Save" : "Finalize")) {
                        Task {
                            await savePayment()
                        }
                    }
                    .disabled(
                        (shouldRecordPayment && (!closeoutPaymentFormIsValid || Double(amount) == nil)) ||
                        isProcessingQuickBooksPayment ||
                        (requireCustomerSignature &&
                         (signatureName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !hasCapturedSignature))
                    )
                }
            }
        }
    }

    private func loadSuggestedCloseoutValues() {
        if shouldRecordPayment {
            amount = String(format: "%.2f", balanceDue > 0 ? balanceDue : invoice.amount)
        }
        cardholderName = invoice.customer.name
        processCardWithQuickBooks = QuickBooksDataAPI.shared.isAuthenticated && method == "card"
        achAccountHolderName = invoice.customer.name
        achAccountNumber = ""
        achRoutingNumber = ""
        achPhone = invoice.customer.phone ?? ""
        achCheckNumber = ""
        achAccountType = .businessChecking
    }

    private func runTapToPay() async {
        guard let amountValue = Double(amount), amountValue > 0 else {
            tapToPayMessage = "Enter a valid amount before starting Tap to Pay."
            return
        }

        do {
            let result = try await onsitePaymentManager.startTapToPay(amount: amountValue, customerName: invoice.customer.name)
            cardLast4 = result.cardLast4
            authorizationCode = result.authorizationCode
            paymentNotes = result.paymentSummary
            tapToPayMessage = "\(result.processorName) approved \(result.amount.formatted(.currency(code: "USD")))."
        } catch {
            tapToPayMessage = error.localizedDescription
        }
    }

    private func triggerAutoTapToPayIfNeeded() {
        guard autoStartTapToPay, !didTriggerAutoTapToPay else { return }
        guard shouldRecordPayment, method == "card" else { return }
        guard selectedProcessor.supportsTapToPay, onsitePaymentManager.processorReady() else { return }
        didTriggerAutoTapToPay = true
        Task {
            await runTapToPay()
        }
    }

    private func savePayment() async {
        let paidAmount = shouldRecordPayment ? (Double(amount) ?? 0) : 0
        guard !shouldRecordPayment || paidAmount > 0 else { return }
        let trimmedSignatureName = signatureName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCompletionNotes = completionNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCardLast4 = cardLast4.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAuthorization = authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPaymentNotes = paymentNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBillingPostalCode = billingPostalCode.trimmingCharacters(in: .whitespacesAndNewlines)

        invoice.customerSignatureName = trimmedSignatureName.isEmpty ? nil : trimmedSignatureName
        invoice.customerSignatureImageBase64 = signatureImageBase64()
        invoice.customerSignedAt = invoice.customerSignatureName == nil ? nil : Date()
        invoice.completionNotes = trimmedCompletionNotes.isEmpty ? nil : trimmedCompletionNotes
        invoice.finalizedAt = Date()

        if shouldRecordPayment {
            if method == "card", QuickBooksDataAPI.shared.isAuthenticated {
                isProcessingQuickBooksPayment = true
                defer { isProcessingQuickBooksPayment = false }

                do {
                    let result = try await QuickBooksPaymentsService.shared.processCardPayment(
                        invoice: invoice,
                        amount: paidAmount,
                        cardInput: QuickBooksPaymentsCardInput(
                            cardholderName: cardholderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? invoice.customer.name : cardholderName.trimmingCharacters(in: .whitespacesAndNewlines),
                            cardNumber: cardNumber.filter(\.isNumber),
                            expMonth: expirationMonth.filter(\.isNumber),
                            expYear: expirationYear.filter(\.isNumber),
                            cvc: cardCVC.filter(\.isNumber),
                            postalCode: trimmedBillingPostalCode.isEmpty ? nil : trimmedBillingPostalCode,
                            addressLine: invoice.customer.address,
                            city: nil,
                            region: nil,
                            country: "US"
                        ),
                        note: trimmedPaymentNotes.isEmpty ? nil : trimmedPaymentNotes
                    )

                    let resolvedCardLast4: String?
                    if !trimmedCardLast4.isEmpty {
                        resolvedCardLast4 = trimmedCardLast4
                    } else if let masked = result.charge.card?.number?.suffix(4) {
                        resolvedCardLast4 = String(masked)
                    } else {
                        resolvedCardLast4 = nil
                    }

                    modelContext.insert(
                        Payment(
                            invoice: invoice,
                            quickBooksID: result.accountingPayment?.Id,
                            quickBooksChargeID: result.charge.id,
                            quickBooksClientTransID: result.clientTransactionID,
                            quickBooksAccountingSyncStatus: result.accountingError == nil ? "synced" : "needs_attention",
                            quickBooksAccountingSyncDetail: result.accountingError,
                            amount: paidAmount,
                            method: "card",
                            cardLast4: resolvedCardLast4,
                            authorizationReference: result.charge.authCode ?? (trimmedAuthorization.isEmpty ? nil : trimmedAuthorization),
                            notes: trimmedPaymentNotes.isEmpty ? nil : trimmedPaymentNotes,
                            processor: OnsitePaymentProcessor.quickBooksPayments.rawValue
                        )
                    )

                    if let accountingError = result.accountingError {
                        tapToPayMessage = "Charge captured, but accounting sync still needs attention: \(accountingError)"
                    }
                } catch {
                    tapToPayMessage = error.localizedDescription
                    return
                }
            } else if method == "ach", QuickBooksDataAPI.shared.isAuthenticated {
                isProcessingQuickBooksPayment = true
                defer { isProcessingQuickBooksPayment = false }

                do {
                    let result = try await QuickBooksPaymentsService.shared.processBankPayment(
                        invoice: invoice,
                        amount: paidAmount,
                        bankInput: QuickBooksPaymentsBankAccountInput(
                            accountHolderName: achAccountHolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? invoice.customer.name : achAccountHolderName.trimmingCharacters(in: .whitespacesAndNewlines),
                            accountNumber: achAccountNumber.filter(\.isNumber),
                            routingNumber: achRoutingNumber.filter(\.isNumber),
                            phone: achPhone.filter(\.isNumber),
                            accountType: achAccountType,
                            checkNumber: achCheckNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : achCheckNumber.trimmingCharacters(in: .whitespacesAndNewlines)
                        ),
                        note: trimmedPaymentNotes.isEmpty ? nil : trimmedPaymentNotes
                    )

                    modelContext.insert(
                        Payment(
                            invoice: invoice,
                            quickBooksID: result.accountingPayment?.Id,
                            quickBooksChargeID: result.charge.id,
                            quickBooksClientTransID: result.clientTransactionID,
                            quickBooksAccountingSyncStatus: result.accountingError == nil ? "synced" : "needs_attention",
                            quickBooksAccountingSyncDetail: result.accountingError,
                            amount: paidAmount,
                            method: "ach",
                            authorizationReference: result.charge.authCode ?? (trimmedAuthorization.isEmpty ? nil : trimmedAuthorization),
                            notes: trimmedPaymentNotes.isEmpty ? nil : trimmedPaymentNotes,
                            processor: OnsitePaymentProcessor.quickBooksPayments.rawValue
                        )
                    )

                    if let accountingError = result.accountingError {
                        tapToPayMessage = "ACH payment submitted, but accounting sync still needs attention: \(accountingError)"
                    }
                } catch {
                    tapToPayMessage = error.localizedDescription
                    return
                }
            } else {
            let recordedMethod: String
            if method == "card", !trimmedCardLast4.isEmpty {
                recordedMethod = trimmedAuthorization.isEmpty ? "card ••••\(trimmedCardLast4)" : "card ••••\(trimmedCardLast4) auth \(trimmedAuthorization)"
            } else {
                recordedMethod = method
            }

            modelContext.insert(
                Payment(
                    invoice: invoice,
                    amount: paidAmount,
                    method: recordedMethod,
                    cardLast4: trimmedCardLast4.isEmpty ? nil : trimmedCardLast4,
                    authorizationReference: trimmedAuthorization.isEmpty ? nil : trimmedAuthorization,
                    notes: trimmedPaymentNotes.isEmpty ? nil : trimmedPaymentNotes,
                    processor: method == "card"
                        ? (authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "manual-entry" : selectedProcessor.rawValue)
                        : "onsite-recorded"
                )
            )
            }
        }

        let totalPaid = paidAmountRecorded + paidAmount
        if totalPaid >= invoice.amount {
            invoice.status = "paid"
        } else if totalPaid > 0 {
            invoice.status = "partial"
        } else {
            invoice.status = "unpaid"
        }

        if let serviceCallID = invoice.serviceCallID,
           let call = serviceCalls.first(where: { $0.id == serviceCallID }) {
            call.documentationCompletedAt = Date()
            call.documentationChecklist = true
            call.workCompletedChecklist = true
            call.paymentCollectedChecklist = totalPaid > 0
            call.status = invoice.status == "paid" ? .completed : .invoiced
            if !trimmedCompletionNotes.isEmpty {
                call.notes = mergedJobNotes(existing: call.notes, completionNotes: trimmedCompletionNotes)
            }
        }

        dismiss()
    }

    private func signatureImageBase64() -> String? {
        guard let image = SignatureRenderer.image(from: signatureStrokes) else { return invoice.customerSignatureImageBase64 }
        return image.pngData()?.base64EncodedString()
    }

    private func mergedJobNotes(existing: String?, completionNotes: String) -> String {
        let trimmedExisting = existing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedExisting.isEmpty {
            return completionNotes
        }
        if trimmedExisting.localizedCaseInsensitiveContains(completionNotes) {
            return trimmedExisting
        }
        return "\(trimmedExisting)\n\nCloseout Notes:\n\(completionNotes)"
    }
}

private struct DocumentationItemSelectorView: View {
    @Environment(\.dismiss) private var dismiss

    let items: [Item]
    @Binding var selectedItems: Set<UUID>

    @State private var searchText = ""

    private var filteredItems: [Item] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return items }
        return items.filter { item in
            item.name.lowercased().contains(query) ||
            (item.itemDescription?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                TextField("Search items", text: $searchText)
                    .textInputAutocapitalization(.never)

                if filteredItems.isEmpty {
                    Text("No matching items.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(filteredItems) { item in
                        Button {
                            if selectedItems.contains(item.id) {
                                selectedItems.remove(item.id)
                            } else {
                                selectedItems.insert(item.id)
                            }
                        } label: {
                            HStack {
                                Image(systemName: selectedItems.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(Color.brandGold)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name)
                                        .font(.headline)
                                    if let description = item.itemDescription, !description.isEmpty {
                                        Text(description)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    HStack(spacing: 8) {
                                        Text(item.itemType.rawValue)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        Text(item.isTaxable ? "Taxable" : "Non-taxable")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                Text(item.unitPrice, format: .currency(code: "USD"))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Select Items")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct DocumentationItemCreatorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let onCreated: (UUID) -> Void

    @State private var name = ""
    @State private var itemType: CatalogItemType = .service
    @State private var description = ""
    @State private var price = ""
    @State private var cost = ""
    @State private var isTaxable = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Item name", text: $name)
                Picker("Item Type", selection: $itemType) {
                    ForEach(CatalogItemType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                TextField("Description", text: $description, axis: .vertical)
                    .lineLimit(2...3)
                Toggle("Taxable", isOn: $isTaxable)
                TextField("Sales price", text: $price)
                    .keyboardType(.decimalPad)
                TextField("Cost", text: $cost)
                    .keyboardType(.decimalPad)
            }
            .navigationTitle("Create Item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveItem()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Double(price) == nil)
                }
            }
        }
    }

    private func saveItem() {
        guard let salesPrice = Double(price) else { return }
        let item = Item(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            itemType: itemType,
            unitPrice: salesPrice,
            purchaseCost: Double(cost),
            isTaxable: isTaxable,
            itemDescription: {
                let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }()
        )
        modelContext.insert(item)
        onCreated(item.id)
        dismiss()
    }
}

private struct SignaturePad: View {
    @Binding var strokes: [[CGPoint]]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4]))
                Path { path in
                    for stroke in strokes where !stroke.isEmpty {
                        path.move(to: stroke[0])
                        for point in stroke.dropFirst() {
                            path.addLine(to: point)
                        }
                    }
                }
                .stroke(Color.primary, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let point = CGPoint(
                            x: min(max(0, value.location.x), geometry.size.width),
                            y: min(max(0, value.location.y), geometry.size.height)
                        )
                        if strokes.isEmpty || value.startLocation == value.location {
                            strokes.append([point])
                        } else if let lastIndex = strokes.indices.last {
                            strokes[lastIndex].append(point)
                        }
                    }
            )
        }
    }
}

private enum SignatureRenderer {
    static func image(from strokes: [[CGPoint]], size: CGSize = CGSize(width: 600, height: 240)) -> UIImage? {
        let validStrokes = strokes.filter { !$0.isEmpty }
        guard !validStrokes.isEmpty else { return nil }

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.label.setStroke()
            let bezier = UIBezierPath()
            bezier.lineWidth = 3
            bezier.lineCapStyle = .round
            bezier.lineJoinStyle = .round

            for stroke in validStrokes {
                guard let first = stroke.first else { continue }
                let scaledFirst = CGPoint(x: first.x * (size.width / 320), y: first.y * (size.height / 180))
                bezier.move(to: scaledFirst)
                for point in stroke.dropFirst() {
                    let scaledPoint = CGPoint(x: point.x * (size.width / 320), y: point.y * (size.height / 180))
                    bezier.addLine(to: scaledPoint)
                }
            }

            bezier.stroke()
        }
    }
}

private enum BillingDocumentKind: String, CaseIterable, Identifiable {
    case estimate = "Estimate"
    case invoice = "Invoice"

    var id: String { rawValue }
}

#Preview {
    BillingDocumentsView()
}
