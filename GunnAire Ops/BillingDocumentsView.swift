import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

struct BillingDocumentsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Customer.name, order: .forward) private var customers: [Customer]
    @Query(sort: \Item.name, order: .forward) private var items: [Item]
    @Query(sort: \Vendor.name, order: .forward) private var vendors: [Vendor]
    @Query(sort: \ServiceCall.scheduledDate, order: .reverse) private var serviceCalls: [ServiceCall]
    @Query(sort: \Invoice.createdAt, order: .reverse) private var invoices: [Invoice]
    @Query(sort: \Estimate.createdAt, order: .reverse) private var estimates: [Estimate]
    @Query(sort: \Payment.date, order: .reverse) private var payments: [Payment]
    @Query(sort: \ServiceDocumentAttachment.createdAt, order: .reverse) private var attachments: [ServiceDocumentAttachment]
    @Query(sort: \CustomerEquipment.name, order: .forward) private var equipmentProfiles: [CustomerEquipment]

    private let initialServiceCall: ServiceCall?
    private let showsDismissButton: Bool
    private let dismissButtonTitle: String
    private let liveAPI = QuickBooksDataAPI.shared
    private let googleAuth = GoogleAuthManager.shared
    private let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    @State private var selectedDocumentKind: BillingDocumentKind
    @State private var selectedCustomerID: UUID?
    @State private var selectedItems: Set<UUID> = []
    @State private var notes = ""
    @State private var customerSearchText = ""
    @State private var customerName = ""
    @State private var customerPhone = ""
    @State private var customerEmail = ""
    @State private var customerAddress = ""
    @State private var itemSearchText = ""
    @State private var catalogFilter: DocumentationCatalogFilter = .recommended
    @State private var newlyCreatedLineItems: [UUID: Item] = [:]
    @State private var newItemName = ""
    @State private var newItemType: CatalogItemType = .service
    @State private var newItemSKU = ""
    @State private var newItemDescription = ""
    @State private var newItemPrice = ""
    @State private var newItemCost = ""
    @State private var newItemPreferredVendor = ""
    @State private var newItemVendorPartNumber = ""
    @State private var newItemPurchaseURL = ""
    @State private var newItemPurchaseDescription = ""
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
    @State private var selectedInvoiceForCloseout: Invoice?
    @State private var generatedCustomerDocumentURL: URL?
    @State private var showingDocumentationFileImporter = false
    @State private var showingDocumentationCamera = false
    @State private var attachmentKind: ServiceDocumentAttachmentKind = .diagnosticPhoto
    @State private var attachmentCaption = ""
    @State private var attachmentMessage: String?
    private let workspaceMode: BillingWorkspaceMode

    init(
        initialServiceCall: ServiceCall? = nil,
        workspaceMode: BillingWorkspaceMode = .all,
        openCloseoutOnAppear: Bool = false,
        openTapToPayOnAppear: Bool = false,
        showsDismissButton: Bool = false,
        dismissButtonTitle: String = "Minimize"
    ) {
        self.initialServiceCall = initialServiceCall
        self.showsDismissButton = showsDismissButton
        self.dismissButtonTitle = dismissButtonTitle
        self.workspaceMode = workspaceMode
        let initialKind: BillingDocumentKind
        if let initialServiceCall {
            initialKind = initialServiceCall.type == .estimate ? .estimate : .invoice
        } else {
            initialKind = workspaceMode.defaultDocumentKind
        }
        _selectedDocumentKind = State(initialValue: initialKind)
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

    private var filteredCustomers: [Customer] {
        let query = customerSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return customers }
        return customers.filter { customer in
            customer.name.lowercased().contains(query) ||
            (customer.phone?.lowercased().contains(query) ?? false) ||
            (customer.email?.lowercased().contains(query) ?? false) ||
            (customer.address?.lowercased().contains(query) ?? false)
        }
    }

    private var selectedLineItems: [Item] {
        var selectedByID: [UUID: Item] = [:]
        for item in items where selectedItems.contains(item.id) {
            selectedByID[item.id] = item
        }
        for item in newlyCreatedLineItems.values where selectedItems.contains(item.id) {
            selectedByID[item.id] = item
        }
        return Array(selectedByID.values)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
            let haystack = [
                item.name,
                item.sku,
                item.itemDescription,
                item.preferredVendorName,
                item.vendorPartNumber,
                item.purchaseDescription
            ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
            let matchesQuery = query.isEmpty || haystack.contains(query)
            return matchesQuery && matchesCatalogFilter(item)
        }
    }

    private var builderItemResults: [Item] {
        Array(filteredItems.prefix(8))
    }

    private var canAddInlineItem: Bool {
        !newItemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        CatalogItemAmountParser.parseRequiredOrZero(newItemPrice) != nil &&
        CatalogItemAmountParser.isValidOptionalAmount(newItemCost)
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

    private var estimateMetrics: (pending: Int, accepted: Int, followUp: Int) {
        let pending = estimates.filter { $0.status == "pending" }.count
        let accepted = estimates.filter { $0.status == "accepted" }.count
        let followUp = estimates.filter { $0.status == "follow-up" }.count
        return (pending, accepted, followUp)
    }

    private var invoiceMetrics: (open: Int, overdue: Int, outstandingBalance: Double) {
        let openInvoices = invoices.filter { invoice in
            invoiceBalanceDue(for: invoice) > 0.009
        }
        let overdueInvoices = openInvoices.filter(isInvoiceOverdue)
        let balance = openInvoices.reduce(0) { partial, invoice in
            partial + invoiceBalanceDue(for: invoice)
        }
        return (openInvoices.count, overdueInvoices.count, balance)
    }

    private var estimatesNeedingFollowUp: [Estimate] {
        estimates.filter { estimate in
            estimate.status == "pending" || estimate.status == "follow-up"
        }
    }

    private var acceptedEstimatesReadyToSchedule: [Estimate] {
        estimates.filter { $0.status == "accepted" }
    }

    private var collectibleInvoices: [Invoice] {
        invoices.filter { invoice in
            invoiceBalanceDue(for: invoice) > 0.009
        }
    }

    private var overdueInvoices: [Invoice] {
        collectibleInvoices.filter(isInvoiceOverdue)
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
        guard let estimate = currentJobEstimate else { return nil }
        return followUpEmailURL(for: estimate)
    }

    private func followUpEmailDraft(for estimate: Estimate) -> (to: String, subject: String, body: String)? {
        guard let email = estimate.customer.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else { return nil }
        let reference = estimate.quickBooksID?.isEmpty == false ? estimate.quickBooksID! : String(estimate.id.uuidString.prefix(8))
        return (
            to: email,
            subject: "Estimate Follow-Up - \(reference)",
            body: """
Hello \(estimate.customer.name),

Following up on your estimate for \(estimate.amount.formatted(.currency(code: "USD"))).

Please let us know if you would like to move forward or if you have any questions.

Thank you,
GunnAire
"""
        )
    }

    private func followUpEmailURL(for estimate: Estimate) -> URL? {
        guard let draft = followUpEmailDraft(for: estimate) else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = draft.to
        components.queryItems = [
            URLQueryItem(name: "subject", value: draft.subject),
            URLQueryItem(name: "body", value: draft.body)
        ]
        return components.url
    }

    private func openEstimateFollowUpEmail(for estimate: Estimate, fallbackURL: URL) {
        if googleAuth.isAuthenticated, let draft = followUpEmailDraft(for: estimate) {
            GunnAireAppIntentRouter.storeMailDraftRoute(to: draft.to, subject: draft.subject, body: draft.body)
        } else {
            openURL(fallbackURL)
        }
    }

    private func paymentReminderEmailDraft(for invoice: Invoice) -> (to: String, subject: String, body: String)? {
        guard let email = invoice.customer.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else { return nil }
        return (
            to: email,
            subject: "Payment Reminder From GunnAire",
            body: """
Hello \(invoice.customer.name),

This is a reminder that \(invoiceBalanceDue(for: invoice).formatted(.currency(code: "USD"))) remains due on your GunnAire invoice.

Please let us know if you would like us to take payment or if you have any questions.

Thank you,
GunnAire
"""
        )
    }

    private func paymentReminderEmailURL(for invoice: Invoice) -> URL? {
        guard let draft = paymentReminderEmailDraft(for: invoice) else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = draft.to
        components.queryItems = [
            URLQueryItem(name: "subject", value: draft.subject),
            URLQueryItem(name: "body", value: draft.body)
        ]
        return components.url
    }

    private func openPaymentReminderEmail(for invoice: Invoice, fallbackURL: URL) {
        if googleAuth.isAuthenticated, let draft = paymentReminderEmailDraft(for: invoice) {
            GunnAireAppIntentRouter.storeMailDraftRoute(to: draft.to, subject: draft.subject, body: draft.body)
        } else {
            openURL(fallbackURL)
        }
    }

    private var isJobDocumentationMode: Bool {
        activeServiceCall != nil
    }

    private var navigationTitle: String {
        if isJobDocumentationMode {
            return "Job Documentation"
        }
        return workspaceMode.navigationTitle
    }

    private var allowsDocumentSwitching: Bool {
        workspaceMode == .all || isJobDocumentationMode
    }

    private var activeJobAttachments: [ServiceDocumentAttachment] {
        guard let call = activeServiceCall else { return [] }
        return attachments.filter { $0.serviceCallID == call.id }
    }

    private var activeCustomerEquipmentProfiles: [CustomerEquipment] {
        guard let call = activeServiceCall else { return [] }
        return equipmentProfiles.filter { $0.customer?.id == call.customer.id && $0.isActive }
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
                        Text("Job Type: \(call.type.displayName)")
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

                    technicalServiceReportSection(for: call)
                    attachmentSection(for: call)

                    Section("Documentation Builder") {
                        if allowsDocumentSwitching {
                            Picker("Document", selection: $selectedDocumentKind) {
                                ForEach(BillingDocumentKind.allCases) { kind in
                                    Text(kind.rawValue).tag(kind)
                                }
                            }
                            .pickerStyle(.segmented)
                        } else {
                            HStack {
                                Text("Document")
                                Spacer()
                                Text(selectedDocumentKind.rawValue)
                                    .foregroundColor(.secondary)
                            }
                        }

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

                        if workspaceMode.showsEstimateBuilder {
                            Button(isCreatingDocument && selectedDocumentKind == .estimate ? "Creating Estimate..." : "Create Estimate") {
                                selectedDocumentKind = .estimate
                                createDocument()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .disabled(isCreatingDocument || customerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedItems.isEmpty)
                        }

                        if workspaceMode.showsInvoiceBuilder {
                            Button(isCreatingDocument && selectedDocumentKind == .invoice ? "Creating Invoice..." : "Create Invoice") {
                                selectedDocumentKind = .invoice
                                createDocument()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .disabled(isCreatingDocument || customerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedItems.isEmpty)
                        }

                        if !actionMessage.isEmpty {
                            Text(actionMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Section("Customer Documents") {
                        Button {
                            generateOnsiteReport(for: call)
                        } label: {
                            Label("Generate Onsite Report", systemImage: "doc.badge.gearshape")
                        }
                        .buttonStyle(.bordered)

                        if let estimate = currentJobEstimate {
                            Button {
                                generateEstimateDocument(estimate)
                            } label: {
                                Label("Generate Estimate PDF", systemImage: "doc.text")
                            }
                            .buttonStyle(.bordered)
                        }

                        if let invoice = currentJobInvoice, isInvoicePaid(invoice) || (currentJobBalanceDue ?? invoiceBalanceDue(for: invoice)) <= 0.009 {
                            Button {
                                generatePaidInvoiceDocument(invoice)
                            } label: {
                                Label("Generate Paid Invoice PDF", systemImage: "doc.text.fill")
                            }
                            .buttonStyle(.bordered)
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

                if !isJobDocumentationMode {
                    Section("Workspace Snapshot") {
                        switch workspaceMode {
                        case .all:
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Billing Overview")
                                    .font(.headline)
                                HStack {
                                    workspaceMetricView(title: "Pending Estimates", value: "\(estimateMetrics.pending)")
                                    Spacer()
                                    workspaceMetricView(title: "Open Invoices", value: "\(invoiceMetrics.open)")
                                }
                                HStack {
                                    workspaceMetricView(title: "Estimate Follow-Up", value: "\(estimateMetrics.followUp)")
                                    Spacer()
                                    workspaceMetricView(title: "Outstanding", value: invoiceMetrics.outstandingBalance.formatted(.currency(code: "USD")))
                                }
                            }
                        case .estimates:
                            HStack {
                                workspaceMetricView(title: "Pending", value: "\(estimateMetrics.pending)")
                                Spacer()
                                workspaceMetricView(title: "Accepted", value: "\(estimateMetrics.accepted)")
                                Spacer()
                                workspaceMetricView(title: "Follow-Up", value: "\(estimateMetrics.followUp)")
                            }
                        case .invoices:
                            HStack {
                                workspaceMetricView(title: "Open", value: "\(invoiceMetrics.open)")
                                Spacer()
                                workspaceMetricView(title: "Overdue", value: "\(invoiceMetrics.overdue)")
                                Spacer()
                                workspaceMetricView(title: "Outstanding", value: invoiceMetrics.outstandingBalance.formatted(.currency(code: "USD")))
                            }
                        }
                    }
                }

                if !isJobDocumentationMode, let generatedCustomerDocumentURL {
                    Section("Customer Documents") {
                        ShareLink(item: generatedCustomerDocumentURL) {
                            Label("Share Last Generated Document", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.brandGold)
                        .foregroundStyle(Color.primaryBlack)
                    }
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

                                Button("Generate Estimate PDF") {
                                    generateEstimateDocument(estimate)
                                }
                                .buttonStyle(.bordered)

                                Button("Send Estimate Through QuickBooks") {
                                    sendEstimateThroughQuickBooks(estimate)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.blue)
                                .disabled(!QuickBooksDataAPI.shared.isAuthenticated || estimate.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)

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

                                if estimate.status == "accepted", let call = activeServiceCall {
                                    Button("Schedule Approved Work") {
                                        scheduleApprovedWork(from: call)
                                    }
                                    .buttonStyle(.bordered)
                                }

                                if let estimateFollowUpEmailURL {
                                    Button("Send Estimate Follow-Up") {
                                        openEstimateFollowUpEmail(for: estimate, fallbackURL: estimateFollowUpEmailURL)
                                        estimate.status = "follow-up"
                                        activeServiceCall?.followUpRequired = true
                                        activeServiceCall?.followUpAction = "Follow up on estimate"
                                        activeServiceCall?.followUpDueDate = Calendar.current.date(byAdding: .day, value: 3, to: Date())
                                    }
                                    .buttonStyle(.bordered)
                                }

                                if currentJobInvoice == nil {
                                    Button("Create Invoice From Estimate") {
                                        createInvoiceFromEstimate(estimate)
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
                                Text("\(invoice.amount, format: .currency(code: "USD")) • \(invoiceDisplayStatus(for: invoice))")
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
                                Button(isInvoicePaid(invoice) ? "Invoice Paid" : "Collect Payment") {
                                    openInvoiceCloseout(invoice)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Color.brandGold)
                                .foregroundStyle(Color.primaryBlack)
                                .disabled(isInvoicePaid(invoice))

                                Button("Resume Invoice") {
                                    openInvoiceCloseout(invoice)
                                }
                                .buttonStyle(.bordered)

                                Button("Send Invoice Through QuickBooks") {
                                    sendInvoiceThroughQuickBooks(invoice)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.blue)
                                .disabled(!QuickBooksDataAPI.shared.isAuthenticated || invoice.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)

                                if isInvoicePaid(invoice) || (currentJobBalanceDue ?? invoiceBalanceDue(for: invoice)) <= 0.009 {
                                    Button("Generate Paid Invoice PDF") {
                                        generatePaidInvoiceDocument(invoice)
                                    }
                                    .buttonStyle(.bordered)
                                }

                                if !isInvoicePaid(invoice) {
                                    Button("Record Additional Payment") {
                                        openInvoiceCloseout(invoice)
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
                                    Text("\(recentCall.type.displayName) • \(recentCall.status.rawValue.capitalized)")
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

                if !isJobDocumentationMode && workspaceMode.showsEstimates && !estimatesNeedingFollowUp.isEmpty {
                    Section("Estimate Follow-Up") {
                        ForEach(estimatesNeedingFollowUp.prefix(6)) { estimate in
                            let linkedCall = serviceCall(for: estimate)
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(estimate.customer.name)
                                            .font(.headline)
                                        Text("\(estimate.amount, format: .currency(code: "USD")) • \(estimate.status.capitalized)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Text(estimate.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Text(estimate.lineItemSummary)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                HStack {
                                    Button("Load Estimate") {
                                        loadEstimateIntoBuilder(estimate)
                                    }
                                    .buttonStyle(.bordered)

                                    if let linkedCall {
                                        Button("Open Job") {
                                            openDocumentation(for: linkedCall)
                                        }
                                        .buttonStyle(.bordered)
                                    }

                                    if let followUpURL = followUpEmailURL(for: estimate) {
                                        Button("Send Follow-Up") {
                                            openEstimateFollowUpEmail(for: estimate, fallbackURL: followUpURL)
                                            if let linkedCall {
                                                markEstimateFollowUp(on: linkedCall)
                                            }
                                        }
                                        .buttonStyle(.bordered)
                                    }

                                    Button("Create Invoice") {
                                        createInvoiceFromEstimate(estimate)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(Color.brandGold)
                                    .foregroundStyle(Color.primaryBlack)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if !isJobDocumentationMode && workspaceMode.showsEstimates && !acceptedEstimatesReadyToSchedule.isEmpty {
                    Section("Accepted Estimates") {
                        ForEach(acceptedEstimatesReadyToSchedule.prefix(6)) { estimate in
                            let linkedCall = serviceCall(for: estimate)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(estimate.customer.name)
                                    .font(.headline)
                                Text("\(estimate.amount, format: .currency(code: "USD")) • Accepted")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(linkedCall == nil
                                     ? "This accepted estimate is ready to become scheduled work."
                                     : "This accepted estimate can move straight into scheduled work.")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                HStack {
                                    if let linkedCall {
                                        Button("Open Job") {
                                            openDocumentation(for: linkedCall)
                                        }
                                        .buttonStyle(.bordered)

                                        Button("Schedule Work") {
                                            scheduleApprovedWork(from: linkedCall)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(Color.brandGold)
                                        .foregroundStyle(Color.primaryBlack)
                                    }

                                    Button("Create Invoice") {
                                        createInvoiceFromEstimate(estimate)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if !isJobDocumentationMode && workspaceMode.showsInvoices && !collectibleInvoices.isEmpty {
                    Section("Collections Queue") {
                        ForEach(collectibleInvoices.prefix(8)) { invoice in
                            let linkedCall = serviceCall(for: invoice)
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(invoice.customer.name)
                                            .font(.headline)
                                        Text("Balance due: \(invoiceBalanceDue(for: invoice), format: .currency(code: "USD"))")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Text(invoice.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                HStack {
                                    Button("Open Invoice") {
                                        openInvoiceCloseout(invoice)
                                    }
                                    .buttonStyle(.bordered)

                                    if let linkedCall {
                                        Button("Open Job") {
                                            openDocumentation(for: linkedCall)
                                        }
                                        .buttonStyle(.bordered)
                                    }

                                    if let reminderURL = paymentReminderEmailURL(for: invoice) {
                                        Button("Send Reminder") {
                                            openPaymentReminderEmail(for: invoice, fallbackURL: reminderURL)
                                            if let linkedCall {
                                                markPaymentFollowUp(on: linkedCall)
                                            }
                                        }
                                        .buttonStyle(.bordered)
                                    }

                                    Button("Collect Payment") {
                                        openInvoiceCloseout(invoice)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.green)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if !isJobDocumentationMode && workspaceMode.showsInvoices && !overdueInvoices.isEmpty {
                    Section("Overdue Invoices") {
                        ForEach(overdueInvoices.prefix(6)) { invoice in
                            let linkedCall = serviceCall(for: invoice)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(invoice.customer.name)
                                    .font(.headline)
                                Text("Overdue • \(invoiceBalanceDue(for: invoice), format: .currency(code: "USD")) due")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                Text(invoice.lineItemSummary)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                HStack {
                                    Button("Open Invoice") {
                                        openInvoiceCloseout(invoice)
                                    }
                                    .buttonStyle(.bordered)

                                    if let linkedCall {
                                        Button("Open Job") {
                                            openDocumentation(for: linkedCall)
                                        }
                                        .buttonStyle(.bordered)
                                    }

                                    if let reminderURL = paymentReminderEmailURL(for: invoice) {
                                        Button("Send Reminder") {
                                            openPaymentReminderEmail(for: invoice, fallbackURL: reminderURL)
                                            if let linkedCall {
                                                markPaymentFollowUp(on: linkedCall)
                                            }
                                        }
                                        .buttonStyle(.bordered)
                                    }

                                    Button("Collect Payment") {
                                        openInvoiceCloseout(invoice)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.green)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if !relatedEquipmentCalls.isEmpty {
                    Section("Equipment History") {
                        ForEach(relatedEquipmentCalls.prefix(5)) { historyCall in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(historyCall.type.displayName) • \(historyCall.status.rawValue.capitalized)")
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

                    TextField("Search customers", text: $customerSearchText)
                        .textInputAutocapitalization(.never)

                    Picker("Customer", selection: $selectedCustomerID) {
                        Text("Select Customer").tag(UUID?.none)
                        ForEach(filteredCustomers) { customer in
                            Text(customer.name).tag(UUID?.some(customer.id))
                        }
                    }

                    if !customerSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       filteredCustomers.isEmpty {
                        Text("No customers match that search. Fill in the customer fields below to create one.")
                            .font(.caption)
                            .foregroundColor(.secondary)
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

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Line Items")
                                .font(.headline)
                            Spacer()
                            if isQuickBooksConnected {
                                Button(isImportingQuickBooksItems ? "Importing..." : "Sync Catalog") {
                                    importQuickBooksItems()
                                }
                                .font(.caption)
                                .disabled(isImportingQuickBooksItems)
                            }
                        }

                        TextField("Search items to add", text: $itemSearchText)
                            .textInputAutocapitalization(.never)

                        Picker("Catalog Filter", selection: $catalogFilter) {
                            ForEach(DocumentationCatalogFilter.allCases) { filter in
                                Text(filter.label).tag(filter)
                            }
                        }
                        .pickerStyle(.segmented)

                        if items.isEmpty {
                            Text("No catalog items yet. Add one below.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else if builderItemResults.isEmpty {
                            Text("No items match that search.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if let suggestedItemName = nonBlank(itemSearchText) {
                                Button {
                                    newItemName = suggestedItemName
                                    catalogFilter = .selected
                                    showingItemCreator = true
                                } label: {
                                    Label("Create \"\(suggestedItemName)\"", systemImage: "plus.circle")
                                }
                                .buttonStyle(.bordered)
                                .tint(Color.brandGold)
                            }
                        } else {
                            ForEach(builderItemResults) { item in
                                Button {
                                    toggleItem(item)
                                } label: {
                                    HStack {
                                        Image(systemName: selectedItems.contains(item.id) ? "checkmark.circle.fill" : "plus.circle")
                                            .foregroundColor(Color.brandGold)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.name)
                                                .font(.subheadline.weight(.semibold))
                                            if let description = item.itemDescription, !description.isEmpty {
                                                Text(description)
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                            }
                                            itemMetaText(for: item)
                                        }
                                        Spacer()
                                        Text(item.unitPrice, format: .currency(code: "USD"))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if !selectedLineItems.isEmpty {
                            Divider()
                            ForEach(selectedLineItems) { item in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name)
                                        if let description = item.itemDescription, !description.isEmpty {
                                            Text(description)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                        }
                                        itemMetaText(for: item)
                                    }
                                    Spacer()
                                    Text(item.unitPrice, format: .currency(code: "USD"))
                                        .foregroundColor(.secondary)
                                    Button {
                                        selectedItems.remove(item.id)
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }

                        DisclosureGroup("Create Item") {
                            TextField("New item", text: $newItemName)
                            TextField("SKU", text: $newItemSKU)
                                .textInputAutocapitalization(.characters)
                            Picker("Item Type", selection: $newItemType) {
                                ForEach(CatalogItemType.allCases) { type in
                                    Text(type.rawValue).tag(type)
                                }
                            }
                            .pickerStyle(.segmented)
                            TextField("Description", text: $newItemDescription, axis: .vertical)
                                .lineLimit(2...3)
                            Toggle("Taxable", isOn: $newItemTaxable)
                            HStack {
                                TextField("Price (optional)", text: $newItemPrice)
                                    .keyboardType(.decimalPad)
                                TextField("Cost", text: $newItemCost)
                                    .keyboardType(.decimalPad)
                            }
                            TextField("Typical purchase source", text: $newItemPreferredVendor)
                            if !vendors.isEmpty {
                                Menu("Use Saved Vendor") {
                                    ForEach(vendors) { vendor in
                                        Button(vendor.name) {
                                            newItemPreferredVendor = vendor.name
                                        }
                                    }
                                }
                            }
                            TextField("Vendor part #", text: $newItemVendorPartNumber)
                            TextField("Purchase URL", text: $newItemPurchaseURL)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                            TextField("Purchase notes", text: $newItemPurchaseDescription, axis: .vertical)
                                .lineLimit(2...3)
                            Button {
                                addItem()
                            } label: {
                                Label("Add Item", systemImage: "plus.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .disabled(!canAddInlineItem)
                        }
                    }

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
                        Text("New customers saved here create a QuickBooks customer immediately. Items and documents sync when the estimate or invoice is created.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if !isJobDocumentationMode && workspaceMode.showsEstimates {
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
                                    Button("Create Invoice") {
                                        createInvoiceFromEstimate(estimate)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(estimate.status == "invoiced")

                                    Button("Generate Estimate PDF") {
                                        generateEstimateDocument(estimate)
                                    }
                                    .buttonStyle(.bordered)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }

                if !isJobDocumentationMode && workspaceMode.showsInvoices {
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
                                            Text("\(invoiceDisplayStatus(for: invoice)) - \(invoice.createdAt.formatted(date: .abbreviated, time: .shortened))")
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
                                    Button("Open Invoice") {
                                        openInvoiceCloseout(invoice)
                                    }
                                    .buttonStyle(.bordered)

                                    Button(isInvoicePaid(invoice) ? "Paid" : "Collect Payment") {
                                        openInvoiceCloseout(invoice)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(Color.brandGold)
                                    .foregroundStyle(Color.primaryBlack)
                                    .disabled(isInvoicePaid(invoice))

                                    if isInvoicePaid(invoice) || invoiceBalanceDue(for: invoice) <= 0.009 {
                                        Button("Generate Paid Invoice PDF") {
                                            generatePaidInvoiceDocument(invoice)
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }

                if !isJobDocumentationMode && workspaceMode.showsPayments {
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
            }
            .navigationTitle(navigationTitle)
            .toolbar {
                if showsDismissButton {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(dismissButtonTitle) {
                            dismiss()
                        }
                    }
                }
            }
            .sheet(isPresented: $showingItemSelector) {
                DocumentationItemSelectorView(items: items, selectedItems: $selectedItems)
            }
            .sheet(isPresented: $showingItemCreator) {
                DocumentationItemCreatorView(
                    initialName: itemCreatorInitialName,
                    vendors: vendors,
                    onCreated: handleCreatedItem
                )
            }
            .sheet(isPresented: $showingDocumentationCamera) {
                JobDocumentationCameraPicker(sourceType: .camera) { image in
                    handleCapturedDocumentationImage(image)
                }
            }
            .sheet(item: $selectedInvoiceForCloseout) { invoice in
                RecordInvoicePaymentView(invoice: invoice)
                    .tint(Color.brandGold)
            }
            .fileImporter(
                isPresented: $showingDocumentationFileImporter,
                allowedContentTypes: [.image, .pdf, .plainText, .data],
                allowsMultipleSelection: true
            ) { result in
                handleImportedDocumentationFiles(result)
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

    @ViewBuilder
    private func itemMetaText(for item: Item) -> some View {
        let meta = [
            item.sku.map { "SKU \($0)" },
            item.preferredVendorName,
            item.vendorPartNumber.map { "Vendor # \($0)" }
        ]
        .compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }

        if !meta.isEmpty {
            Text(meta.joined(separator: " • "))
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    private func populateCustomerFields(from customer: Customer) {
        customerSearchText = customer.name
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
        if isQuickBooksConnected, customer.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            syncCustomerToQuickBooks(customer)
        } else {
            actionMessage = customer.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? "\(customer.name) saved and linked to QuickBooks."
                : "\(customer.name) saved locally."
        }
    }

    private func syncCustomerToQuickBooks(_ customer: Customer) {
        actionMessage = "Creating \(customer.name) in QuickBooks..."
        let payload = QuickBooksCustomerCreate(
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
        liveAPI.createCustomer(payload) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let quickBooksCustomer):
                    customer.quickBooksID = quickBooksCustomer.Id
                    actionMessage = "\(customer.name) created in QuickBooks."
                case .failure(let error):
                    actionMessage = "\(customer.name) saved locally. QuickBooks customer sync failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func syncNotesToJob() {
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        activeServiceCall?.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        actionMessage = trimmedNotes.isEmpty ? "Cleared job notes." : "Saved documentation notes back to the job."
    }

    @ViewBuilder
    private func technicalServiceReportSection(for call: ServiceCall) -> some View {
        Section("Technical HVAC Report") {
            if !activeCustomerEquipmentProfiles.isEmpty {
                Picker("Customer Equipment", selection: Binding(
                    get: { call.customerEquipmentID },
                    set: { selectedID in
                        call.customerEquipmentID = selectedID
                        if let selectedID,
                           let equipment = activeCustomerEquipmentProfiles.first(where: { $0.id == selectedID }) {
                            applyEquipmentProfile(equipment, to: call)
                        }
                    }
                )) {
                    Text("No linked equipment").tag(UUID?.none)
                    ForEach(activeCustomerEquipmentProfiles) { equipment in
                        Text(equipment.displayName).tag(UUID?.some(equipment.id))
                    }
                }
            }

            Picker("Equipment Type", selection: Binding(
                get: { call.equipmentType ?? .splitSystemAC },
                set: { newValue in
                    call.equipmentType = newValue
                    call.diagnosticsCaptured = true
                }
            )) {
                ForEach(HVACEquipmentType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.menu)

            TextField("Equipment Name", text: optionalServiceCallTextBinding(call, \.equipmentName))
            TextField("Manufacturer", text: optionalServiceCallTextBinding(call, \.equipmentManufacturer))
            TextField("Model", text: optionalServiceCallTextBinding(call, \.equipmentModel))
            TextField("Serial Number", text: optionalServiceCallTextBinding(call, \.equipmentSerialNumber))
            TextField("Equipment Location", text: optionalServiceCallTextBinding(call, \.equipmentLocation))
            if call.equipmentInstallDate == nil {
                Button("Set Install Date") {
                    call.equipmentInstallDate = Date()
                    call.diagnosticsCaptured = true
                }
                .buttonStyle(.bordered)
            } else {
                DatePicker(
                    "Install Date",
                    selection: optionalServiceCallDateBinding(call, \.equipmentInstallDate),
                    displayedComponents: .date
                )
                Button("Clear Install Date") {
                    call.equipmentInstallDate = nil
                }
                .buttonStyle(.bordered)
            }

            Button(call.customerEquipmentID == nil ? "Save as Customer Equipment" : "Update Customer Equipment") {
                saveCurrentEquipmentProfile(for: call)
            }
            .buttonStyle(.bordered)
            .disabled(call.equipmentName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)

            ForEach(call.technicalReadingDefinitions) { definition in
                technicalReadingInput(for: call, definition: definition)
            }

            HStack {
                Button("Calculate Temp Split") {
                    calculateTemperatureSplit(for: call)
                }
                .buttonStyle(.bordered)

                Spacer()

                let split = call.technicalReading(for: "temperature_split")
                if !split.isEmpty {
                    Text("\(split) F")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            TextField("Filter Size", text: optionalServiceCallTextBinding(call, \.filterSize))
            serviceReportOptionPicker(
                "Filter Condition",
                selection: optionalServiceCallTextBinding(call, \.filterCondition),
                options: ["New", "Clean", "Dirty", "Replaced", "Needs Replacement", "Not Applicable"]
            )
            serviceReportOptionPicker(
                "Indoor Coil Condition",
                selection: optionalServiceCallTextBinding(call, \.indoorCoilCondition),
                options: ["Clean", "Light Dust", "Dirty", "Impacted", "Frozen", "Damaged", "Not Accessible", "Not Applicable"]
            )
            serviceReportOptionPicker(
                "Outdoor Coil Condition",
                selection: optionalServiceCallTextBinding(call, \.outdoorCoilCondition),
                options: ["Clean", "Light Dust", "Dirty", "Impacted", "Damaged", "Washed", "Not Accessible", "Not Applicable"]
            )
            serviceReportOptionPicker(
                "Drain Line Condition",
                selection: optionalServiceCallTextBinding(call, \.drainLineCondition),
                options: ["Clear", "Slow", "Clogged", "Cleared", "Treated", "Needs Repair", "Not Applicable"]
            )
            serviceReportOptionPicker(
                "Thermostat Operation",
                selection: optionalServiceCallTextBinding(call, \.thermostatOperation),
                options: ["Normal", "Calibrated", "Battery Replaced", "Faulty", "Needs Replacement", "Not Tested"]
            )
            TextField("Service Report Summary", text: optionalServiceCallTextBinding(call, \.serviceReportSummary), axis: .vertical)
                .lineLimit(2...5)

            if !call.populatedTechnicalReadingRows.isEmpty {
                Text("\(call.populatedTechnicalReadingRows.count) technical reading\(call.populatedTechnicalReadingRows.count == 1 ? "" : "s") captured")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func technicalReadingInput(for call: ServiceCall, definition: HVACTechnicalReadingDefinition) -> some View {
        if definition.options.isEmpty {
            TextField(definition.displayLabel, text: technicalReadingBinding(for: call, key: definition.key))
                .keyboardType(.numbersAndPunctuation)
        } else {
            serviceReportOptionPicker(
                definition.displayLabel,
                selection: technicalReadingBinding(for: call, key: definition.key),
                options: definition.options
            )
        }
    }

    private func serviceReportOptionPicker(_ title: String, selection: Binding<String>, options: [String]) -> some View {
        Picker(title, selection: selection) {
            Text("Not Set").tag("")
            ForEach(options, id: \.self) { option in
                Text(option).tag(option)
            }
        }
        .pickerStyle(.menu)
    }

    private func optionalServiceCallTextBinding(_ call: ServiceCall, _ keyPath: ReferenceWritableKeyPath<ServiceCall, String?>) -> Binding<String> {
        Binding(
            get: { call[keyPath: keyPath] ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                call[keyPath: keyPath] = trimmed.isEmpty ? nil : trimmed
                if !trimmed.isEmpty {
                    call.diagnosticsCaptured = true
                }
            }
        )
    }

    private func optionalServiceCallDateBinding(_ call: ServiceCall, _ keyPath: ReferenceWritableKeyPath<ServiceCall, Date?>) -> Binding<Date> {
        Binding(
            get: { call[keyPath: keyPath] ?? Date() },
            set: { newValue in
                call[keyPath: keyPath] = newValue
                call.diagnosticsCaptured = true
            }
        )
    }

    private func technicalReadingBinding(for call: ServiceCall, key: String) -> Binding<String> {
        Binding(
            get: { call.technicalReading(for: key) },
            set: { call.setTechnicalReading($0, for: key) }
        )
    }

    private func applyEquipmentProfile(_ equipment: CustomerEquipment, to call: ServiceCall) {
        equipment.apply(to: call)
        if call.filterSize?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            call.filterSize = equipment.filterSize
        }
        call.equipmentVerifiedChecklist = true
        call.diagnosticsCaptured = true
        actionMessage = "Loaded equipment profile for this job."
    }

    private func saveCurrentEquipmentProfile(for call: ServiceCall) {
        let equipmentName = call.equipmentName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let equipmentName, !equipmentName.isEmpty else {
            actionMessage = "Enter equipment name before saving a customer equipment profile."
            return
        }

        let equipment: CustomerEquipment
        if let existingID = call.customerEquipmentID,
           let existing = equipmentProfiles.first(where: { $0.id == existingID }) {
            equipment = existing
        } else if let serial = call.equipmentSerialNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !serial.isEmpty,
                  let existing = equipmentProfiles.first(where: {
                      $0.customer?.id == call.customer.id &&
                      $0.serialNumber?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(serial) == .orderedSame
                  }) {
            equipment = existing
            call.customerEquipmentID = existing.id
        } else {
            equipment = CustomerEquipment(customer: call.customer, name: equipmentName)
            modelContext.insert(equipment)
            call.customerEquipmentID = equipment.id
        }

        equipment.updateFrom(
            equipmentType: call.equipmentType ?? .splitSystemAC,
            name: equipmentName,
            manufacturer: call.equipmentManufacturer,
            modelNumber: call.equipmentModel,
            serialNumber: call.equipmentSerialNumber,
            location: call.equipmentLocation,
            installDate: call.equipmentInstallDate,
            warrantyExpiration: call.equipmentWarrantyExpiration,
            filterSize: call.filterSize,
            notes: equipment.notes,
            isActive: true
        )
        call.equipmentVerifiedChecklist = true
        try? modelContext.save()
        actionMessage = "Saved equipment profile to \(call.customer.name)."
    }

    private func calculateTemperatureSplit(for call: ServiceCall) {
        let returnTemp = Double(call.technicalReading(for: "return_air_temp").replacingOccurrences(of: ",", with: "."))
        let supplyTemp = Double(call.technicalReading(for: "supply_air_temp").replacingOccurrences(of: ",", with: "."))
        guard let returnTemp, let supplyTemp else {
            actionMessage = "Enter return and supply air temperatures before calculating temperature split."
            return
        }
        let split = abs(returnTemp - supplyTemp)
        call.setTechnicalReading(String(format: "%.1f", split), for: "temperature_split")
        actionMessage = "Temperature split calculated."
    }

    @ViewBuilder
    private func attachmentSection(for call: ServiceCall) -> some View {
        Section("Photos & Attachments") {
            Picker("Type", selection: $attachmentKind) {
                ForEach(ServiceDocumentAttachmentKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }

            TextField("Caption or note", text: $attachmentCaption)

            HStack {
                Button {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        showingDocumentationCamera = true
                    } else {
                        attachmentMessage = "Camera is not available on this device."
                    }
                } label: {
                    Label("Camera", systemImage: "camera")
                }
                .buttonStyle(.bordered)

                Button {
                    showingDocumentationFileImporter = true
                } label: {
                    Label("Files", systemImage: "paperclip")
                }
                .buttonStyle(.bordered)
            }

            if let attachmentMessage {
                Text(attachmentMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if activeJobAttachments.isEmpty {
                Text("No photos or documents attached to this job yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(activeJobAttachments.prefix(8)) { attachment in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: attachment.isImage ? "photo" : "doc")
                                .foregroundStyle(Color.brandGold)
                            Text(attachment.displayName)
                                .lineLimit(1)
                            Spacer()
                            Text(attachment.kind.label)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        if let caption = attachment.caption, !caption.isEmpty {
                            Text(caption)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                        HStack {
                            Text(byteCountFormatter.string(fromByteCount: Int64(attachment.fileSizeBytes)))
                            if attachment.backendDocumentID != nil {
                                Text("Company storage")
                            }
                            if attachment.quickBooksAttachableID != nil {
                                Text("QuickBooks")
                            }
                        }
                        .font(.caption2)
                        .foregroundColor(.secondary)

                        ShareLink(item: attachment.localFileURL) {
                            Label("Open Attachment", systemImage: attachment.isImage ? "photo.on.rectangle" : "doc.text.magnifyingglass")
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }

    private func handleCapturedDocumentationImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            attachmentMessage = "Could not encode camera image."
            return
        }
        let filename = "job-photo-\(UUID().uuidString).jpg"
        saveDocumentationAttachment(data: data, filename: filename, contentType: "image/jpeg")
    }

    private func handleImportedDocumentationFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            attachmentMessage = "File import failed: \(error.localizedDescription)"
        case .success(let urls):
            guard !urls.isEmpty else { return }
            var savedCount = 0
            var lastError: String?
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    let data = try Data(contentsOf: url)
                    saveDocumentationAttachment(
                        data: data,
                        filename: url.lastPathComponent,
                        contentType: contentType(for: url)
                    )
                    savedCount += 1
                } catch {
                    lastError = error.localizedDescription
                }
            }
            if let lastError, savedCount == 0 {
                attachmentMessage = "Could not import file: \(lastError)"
            } else if savedCount > 1 {
                attachmentMessage = "Attached \(savedCount) files."
            }
        }
    }

    private func saveDocumentationAttachment(data: Data, filename: String, contentType: String) {
        guard let call = activeServiceCall else {
            attachmentMessage = "Open a job before attaching files."
            return
        }
        do {
            let storedURL = try persistAttachmentData(data, originalFilename: filename)
            let attachment = ServiceDocumentAttachment(
                customer: call.customer,
                serviceCallID: call.id,
                invoiceID: call.linkedInvoiceID,
                estimateID: call.linkedEstimateID,
                kind: attachmentKind,
                displayName: storedURL.lastPathComponent,
                caption: nilIfBlank(attachmentCaption),
                localFilePath: storedURL.path,
                contentType: contentType,
                fileSizeBytes: data.count
            )
            modelContext.insert(attachment)
            applyAttachmentProgress(attachment, to: call)
            try modelContext.save()
            attachmentCaption = ""
            attachmentMessage = "Attached \(attachment.displayName)."
            syncAttachmentIfPossible(attachment, data: data)
        } catch {
            attachmentMessage = "Could not save attachment: \(error.localizedDescription)"
        }
    }

    private func persistAttachmentData(_ data: Data, originalFilename: String) throws -> URL {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let folder = documents.appendingPathComponent("GunnAire Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sanitizedName = sanitizeAttachmentFilename(originalFilename)
        let url = folder.appendingPathComponent("\(UUID().uuidString)-\(sanitizedName)")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func sanitizeAttachmentFilename(_ filename: String) -> String {
        let base = filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "attachment" : filename
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return base.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
    }

    private func applyAttachmentProgress(_ attachment: ServiceDocumentAttachment, to call: ServiceCall) {
        switch attachment.kind {
        case .beforePhoto:
            call.beforePhotoCount += 1
        case .afterPhoto:
            call.afterPhotoCount += 1
        case .serviceReport, .diagnosticPhoto, .customerDocument, .invoiceSupport, .estimateSupport, .receipt, .other:
            break
        }
        call.documentationStartedAt = call.documentationStartedAt ?? Date()
        call.documentationChecklist = true
    }

    private func syncAttachmentIfPossible(_ attachment: ServiceDocumentAttachment, data: Data) {
        if GunnAireBackendService.isConfigured {
            Task {
                do {
                    let response = try await GunnAireBackendService.uploadDocument(
                        data: data,
                        filename: attachment.displayName,
                        contentType: attachment.contentType,
                        kind: attachment.kindRaw,
                        serviceCallID: attachment.serviceCallID,
                        customerName: attachment.customer?.name
                    )
                    attachment.backendDocumentID = response.id
                    try? modelContext.save()
                } catch {
                    attachmentMessage = "Attachment saved locally. Company storage upload failed: \(error.localizedDescription)"
                }
            }
        }

        let resolvedInvoiceID = attachment.invoiceID ?? activeServiceCall?.linkedInvoiceID
        guard let invoiceID = resolvedInvoiceID,
              let invoice = invoices.first(where: { $0.id == invoiceID }) else {
            return
        }

        syncAttachmentToQuickBooksInvoiceIfPossible(attachment, invoice: invoice)
    }

    private func linkExistingServiceReports(to invoice: Invoice, serviceCallID: UUID?) {
        guard let serviceCallID else { return }
        let reportAttachments = attachments.filter {
            $0.serviceCallID == serviceCallID && $0.canLinkToInvoiceReport
        }
        guard !reportAttachments.isEmpty else { return }

        for attachment in reportAttachments {
            attachment.linkToInvoiceIfNeeded(invoice)
        }
        try? modelContext.save()
        syncLinkedServiceReportsToQuickBooks(invoice)
    }

    private func syncLinkedServiceReportsToQuickBooks(_ invoice: Invoice) {
        let reportAttachments = attachments.filter {
            $0.invoiceID == invoice.id && $0.canLinkToInvoiceReport
        }
        for attachment in reportAttachments {
            syncAttachmentToQuickBooksInvoiceIfPossible(attachment, invoice: invoice)
        }
    }

    private func syncAttachmentToQuickBooksInvoiceIfPossible(_ attachment: ServiceDocumentAttachment, invoice: Invoice) {
        guard attachment.quickBooksAttachableID == nil,
              let quickBooksID = invoice.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !quickBooksID.isEmpty,
              QuickBooksDataAPI.shared.isAuthenticated else {
            return
        }

        QuickBooksDataAPI.shared.uploadDocument(
            fileURL: attachment.localFileURL,
            note: attachment.caption,
            attachToEntityType: .invoice,
            attachToEntityID: quickBooksID
        ) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let attachableID):
                    attachment.quickBooksAttachableID = attachableID
                    try? modelContext.save()
                case .failure(let error):
                    attachment.quickBooksSyncError = error.localizedDescription
                    try? modelContext.save()
                }
            }
        }
    }

    private func contentType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "pdf": return "application/pdf"
        default: return "application/octet-stream"
        }
    }

    private func nilIfBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func loadPendingIntentServiceCallIfNeeded() {
        guard initialServiceCall == nil, pendingIntentServiceCallID == nil else { return }
        pendingIntentServiceCallID = GunnAireAppIntentRouter.consumePendingServiceCallID()
        if let call = activeServiceCall {
            selectedDocumentKind = call.type == .estimate ? .estimate : .invoice
        }
    }

    private func addItem() {
        guard let price = CatalogItemAmountParser.parseRequiredOrZero(newItemPrice) else { return }
        let cost = CatalogItemAmountParser.parseOptional(newItemCost)
        let preferredVendorName = nonBlank(newItemPreferredVendor)
        let preferredVendorQuickBooksID = preferredVendorName.flatMap { vendorName in
            vendors.first { $0.name.caseInsensitiveCompare(vendorName) == .orderedSame }?.quickBooksID
        }
        let item = Item(
            name: newItemName.trimmingCharacters(in: .whitespacesAndNewlines),
            itemType: newItemType,
            unitPrice: price,
            purchaseCost: cost,
            isTaxable: newItemTaxable,
            itemDescription: nonBlank(newItemDescription),
            sku: nonBlank(newItemSKU),
            preferredVendorName: preferredVendorName,
            preferredVendorQuickBooksID: preferredVendorQuickBooksID,
            vendorPartNumber: nonBlank(newItemVendorPartNumber),
            purchaseURL: nonBlank(newItemPurchaseURL),
            purchaseDescription: nonBlank(newItemPurchaseDescription)
        )
        modelContext.insert(item)
        do {
            try modelContext.save()
            selectCreatedItem(item)
            actionMessage = "Added \(item.name) to this \(selectedDocumentKind.rawValue.lowercased())."
        } catch {
            actionMessage = "Could not save \(item.name): \(error.localizedDescription)"
        }
        itemSearchText = ""
        newItemName = ""
        newItemType = .service
        newItemSKU = ""
        newItemDescription = ""
        newItemPrice = ""
        newItemCost = ""
        newItemPreferredVendor = ""
        newItemVendorPartNumber = ""
        newItemPurchaseURL = ""
        newItemPurchaseDescription = ""
        newItemTaxable = false
    }

    private func selectCreatedItem(_ item: Item) {
        newlyCreatedLineItems[item.id] = item
        selectedItems.insert(item.id)
        catalogFilter = .selected
    }

    private var itemCreatorInitialName: String {
        nonBlank(newItemName) ?? nonBlank(itemSearchText) ?? ""
    }

    private func handleCreatedItem(_ item: Item) {
        selectCreatedItem(item)
        itemSearchText = ""
        newItemName = ""
        actionMessage = "Added \(item.name) to this \(selectedDocumentKind.rawValue.lowercased())."
    }

    private func nonBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
                            applyQuickBooksItem(quickBooksItem, to: existing)
                            continue
                        }

                        let localItem = Item(
                            quickBooksID: normalizedID,
                            name: quickBooksItem.Name,
                            itemType: CatalogItemType(rawValue: quickBooksItem.ItemType ?? "") ?? .service,
                            unitPrice: quickBooksItem.UnitPrice ?? 0,
                            purchaseCost: quickBooksItem.PurchaseCost,
                            isTaxable: quickBooksItem.Taxable ?? false,
                            itemDescription: quickBooksItem.Description,
                            sku: quickBooksItem.Sku,
                            preferredVendorName: quickBooksItem.PrefVendorRef?.name,
                            preferredVendorQuickBooksID: quickBooksItem.PrefVendorRef?.value,
                            purchaseDescription: quickBooksItem.PurchaseDesc
                        )
                        modelContext.insert(localItem)
                        imported += 1
                    }
                    saveQuickBooksSyncState()
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

    private func applyQuickBooksItem(_ quickBooksItem: QuickBooksItem, to item: Item) {
        item.quickBooksID = quickBooksItem.Id.trimmingCharacters(in: .whitespacesAndNewlines)
        item.name = quickBooksItem.Name
        if let itemType = quickBooksItem.ItemType {
            item.itemTypeRawValue = itemType
        }
        item.unitPrice = quickBooksItem.UnitPrice ?? item.unitPrice
        item.purchaseCost = quickBooksItem.PurchaseCost ?? item.purchaseCost
        item.isTaxable = quickBooksItem.Taxable ?? item.isTaxable
        item.itemDescription = quickBooksItem.Description ?? item.itemDescription
        item.sku = quickBooksItem.Sku ?? item.sku
        item.purchaseDescription = quickBooksItem.PurchaseDesc ?? item.purchaseDescription
        item.preferredVendorName = quickBooksItem.PrefVendorRef?.name ?? item.preferredVendorName
        item.preferredVendorQuickBooksID = quickBooksItem.PrefVendorRef?.value ?? item.preferredVendorQuickBooksID
    }

    private func saveQuickBooksSyncState() {
        do {
            try modelContext.save()
        } catch {
            actionMessage = "QuickBooks sync saved remotely, but the app could not save the updated local IDs: \(error.localizedDescription)"
        }
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

    private func createInvoiceFromEstimate(_ estimate: Estimate) {
        if let existingInvoice = invoice(for: estimate) {
            selectedInvoiceForCloseout = existingInvoice
            actionMessage = "Opened the existing invoice for this estimate."
            return
        }

        let invoice = convertEstimate(estimate)
        selectedInvoiceForCloseout = invoice
        let restoredItems = items.filter { matchingItemIDs(from: estimate.lineItemSummary).contains($0.id) }
        if isQuickBooksConnected, !restoredItems.isEmpty {
            actionMessage = "Invoice created from estimate. Syncing to QuickBooks..."
            syncInvoiceIfNeeded(invoice, customer: estimate.customer, items: restoredItems)
        } else if isQuickBooksConnected {
            actionMessage = "Invoice created from estimate. QuickBooks sync skipped because the estimate lines do not match local catalog items."
        } else {
            actionMessage = "Invoice created from estimate."
        }
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

    private func generateOnsiteReport(for serviceCall: ServiceCall) {
        do {
            let url = try CustomerDocumentExporter.exportOnsiteReport(
                serviceCall: serviceCall,
                estimate: currentJobEstimate,
                invoice: currentJobInvoice,
                payments: currentJobPayments,
                attachments: activeJobAttachments
            )
            generatedCustomerDocumentURL = url
            serviceCall.documentationChecklist = true
            serviceCall.documentationCompletedAt = serviceCall.documentationCompletedAt ?? Date()
            persistGeneratedOnsiteReport(url, for: serviceCall)
        } catch {
            actionMessage = "Could not generate onsite report: \(error.localizedDescription)"
        }
    }

    private func persistGeneratedOnsiteReport(_ url: URL, for serviceCall: ServiceCall) {
        do {
            let data = try Data(contentsOf: url)
            let invoice = currentJobInvoice
            let estimate = currentJobEstimate
            let invoiceID = invoice?.id ?? serviceCall.linkedInvoiceID
            let estimateID = estimate?.id ?? serviceCall.linkedEstimateID
            let caption = "Generated onsite \(serviceCall.type.displayName.lowercased()) report"
            let attachment: ServiceDocumentAttachment
            if let reusable = ServiceDocumentAttachment.reusableGeneratedServiceReport(
                in: attachments,
                serviceCallID: serviceCall.id,
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
                attachment = reusable
            } else {
                let generated = ServiceDocumentAttachment(
                    customer: serviceCall.customer,
                    serviceCallID: serviceCall.id,
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
            syncAttachmentIfPossible(attachment, data: data)
            if invoice?.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                actionMessage = "Onsite report generated and queued for QuickBooks invoice attachment."
            } else {
                actionMessage = "Onsite report generated and saved to this job."
            }
        } catch {
            actionMessage = "Onsite report generated, but could not save it as a job attachment: \(error.localizedDescription)"
        }
    }

    private func generateEstimateDocument(_ estimate: Estimate) {
        do {
            let url = try CustomerDocumentExporter.exportEstimate(estimate, serviceCall: serviceCall(for: estimate))
            generatedCustomerDocumentURL = url
            actionMessage = "Estimate PDF generated."
        } catch {
            actionMessage = "Could not generate estimate PDF: \(error.localizedDescription)"
        }
    }

    private func generatePaidInvoiceDocument(_ invoice: Invoice) {
        do {
            let invoicePayments = payments.filter { $0.invoice.id == invoice.id }
            let url = try CustomerDocumentExporter.exportPaidInvoice(
                invoice,
                serviceCall: serviceCall(for: invoice),
                payments: invoicePayments
            )
            generatedCustomerDocumentURL = url
            actionMessage = "Paid invoice PDF generated."
        } catch {
            actionMessage = "Could not generate paid invoice PDF: \(error.localizedDescription)"
        }
    }

    private func sendEstimateThroughQuickBooks(_ estimate: Estimate) {
        guard QuickBooksDataAPI.shared.isAuthenticated else {
            actionMessage = "Connect QuickBooks before sending the estimate."
            return
        }
        guard let quickBooksID = estimate.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !quickBooksID.isEmpty else {
            actionMessage = "Create or sync this estimate to QuickBooks before sending it."
            return
        }
        let email = estimate.customer.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        actionMessage = "Sending estimate through QuickBooks..."
        QuickBooksDataAPI.shared.sendEstimate(id: quickBooksID, to: email?.isEmpty == false ? email : nil) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    if estimate.status.caseInsensitiveCompare("accepted") != .orderedSame &&
                        estimate.status.caseInsensitiveCompare("rejected") != .orderedSame {
                        estimate.status = "sent"
                    }
                    try? modelContext.save()
                    actionMessage = email?.isEmpty == false
                        ? "Estimate sent through QuickBooks to \(email!)."
                        : "Estimate sent through QuickBooks."
                case .failure(let error):
                    actionMessage = "QuickBooks estimate send failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func sendInvoiceThroughQuickBooks(_ invoice: Invoice) {
        guard QuickBooksDataAPI.shared.isAuthenticated else {
            actionMessage = "Connect QuickBooks before sending the invoice."
            return
        }
        guard let quickBooksID = invoice.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !quickBooksID.isEmpty else {
            actionMessage = "Create or sync this invoice to QuickBooks before sending it."
            return
        }
        let email = invoice.customer.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        actionMessage = "Sending invoice through QuickBooks..."
        QuickBooksDataAPI.shared.sendInvoice(id: quickBooksID, to: email?.isEmpty == false ? email : nil) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    if invoice.status.caseInsensitiveCompare("paid") != .orderedSame &&
                        invoice.status.caseInsensitiveCompare("partial") != .orderedSame {
                        invoice.status = "sent"
                    }
                    try? modelContext.save()
                    actionMessage = email?.isEmpty == false
                        ? "Invoice sent through QuickBooks to \(email!)."
                        : "Invoice sent through QuickBooks."
                case .failure(let error):
                    actionMessage = "QuickBooks invoice send failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func serviceCall(for estimate: Estimate) -> ServiceCall? {
        guard let serviceCallID = estimate.serviceCallID else { return nil }
        return serviceCalls.first(where: { $0.id == serviceCallID })
    }

    private func serviceCall(for invoice: Invoice) -> ServiceCall? {
        guard let serviceCallID = invoice.serviceCallID else { return nil }
        return serviceCalls.first(where: { $0.id == serviceCallID })
    }

    private func invoice(for estimate: Estimate) -> Invoice? {
        if let serviceCallID = estimate.serviceCallID,
           let linkedInvoiceID = serviceCalls.first(where: { $0.id == serviceCallID })?.linkedInvoiceID {
            return invoices.first(where: { $0.id == linkedInvoiceID })
        }
        return invoices.first { invoice in
            invoice.customer.id == estimate.customer.id &&
            invoice.lineItemSummary == estimate.lineItemSummary &&
            abs(invoice.amount - estimate.amount) < 0.01
        }
    }

    private func openDocumentation(for serviceCall: ServiceCall) {
        GunnAireAppIntentRouter.storeDocumentationRoute(serviceCall.id)
    }

    private func markEstimateFollowUp(on serviceCall: ServiceCall) {
        serviceCall.followUpRequired = true
        serviceCall.followUpAction = "Follow up on estimate"
        serviceCall.followUpDueDate = Calendar.current.date(byAdding: .day, value: 3, to: Date())
    }

    private func markPaymentFollowUp(on serviceCall: ServiceCall) {
        serviceCall.followUpRequired = true
        serviceCall.followUpAction = "Collect payment"
        serviceCall.followUpDueDate = Calendar.current.date(byAdding: .day, value: 1, to: Date())
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

    private func invoiceBalanceDue(for invoice: Invoice) -> Double {
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
        invoice.status.caseInsensitiveCompare("paid") == .orderedSame || invoiceBalanceDueIgnoringStatus(for: invoice) <= 0.009
    }

    private func isInvoiceOverdue(_ invoice: Invoice) -> Bool {
        guard invoiceBalanceDue(for: invoice) > 0.009 else { return false }
        let daysOpen = Calendar.current.dateComponents([.day], from: invoice.createdAt, to: Date()).day ?? 0
        return daysOpen >= 30
    }

    private func invoiceDisplayStatus(for invoice: Invoice) -> String {
        if isInvoicePaid(invoice) { return "Paid" }
        if isInvoiceOverdue(invoice) { return "Overdue" }
        let balance = invoiceBalanceDue(for: invoice)
        if balance > 0.009 && balance < invoice.amount { return "Partial" }
        return "Open"
    }

    private func invoiceBalanceDueIgnoringStatus(for invoice: Invoice) -> Double {
        let paid = payments
            .filter { $0.invoice.id == invoice.id }
            .reduce(0) { partial, payment in
                partial + payment.amount
            }
        return max(invoice.amount - paid, 0)
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

    private func scheduleApprovedWork(from sourceCall: ServiceCall) {
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
        actionMessage = "Scheduled approved work for \(approvedWorkCall.scheduledDate.formatted(date: .abbreviated, time: .shortened))."
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
        case .meeting, .reminder, .siteVisit, .other:
            return item.itemType == .service ||
                haystack.contains("labor") ||
                haystack.contains("trip") ||
                haystack.contains("consult")
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
            guard saveBillingContext(failureMessage: "Could not save estimate locally") else {
                isCreatingDocument = false
                return
            }
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
            linkExistingServiceReports(to: invoice, serviceCallID: activeServiceCall?.id)
            actionMessage = isQuickBooksConnected ? "Invoice created locally. Syncing to QuickBooks..." : "Invoice created locally."
            guard saveBillingContext(failureMessage: "Could not save invoice locally") else {
                isCreatingDocument = false
                return
            }
            syncInvoiceIfNeeded(invoice, customer: customer, items: selectedLineItems)
            selectedItems.removeAll()
            notes = ""
        }
        isCreatingDocument = false
    }

    private func saveBillingContext(failureMessage: String) -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            actionMessage = "\(failureMessage): \(error.localizedDescription)"
            return false
        }
    }

    private func openPaymentsForInvoice(_ invoice: Invoice) {
        GunnAireAppIntentRouter.storePaymentCollectionRoute(invoice.id)
    }

    private func openInvoiceCloseout(_ invoice: Invoice) {
        selectedInvoiceForCloseout = invoice
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
                            saveQuickBooksSyncState()
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
                            saveQuickBooksSyncState()
                            syncLinkedServiceReportsToQuickBooks(invoice)
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
                prepareQuickBooksItemsForDocument(items, completion: completion)
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
                    saveQuickBooksSyncState()
                    completion(.success(()))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    private func prepareQuickBooksItemsForDocument(
        _ items: [Item],
        completion: @escaping (Result<[Item], Error>) -> Void
    ) {
        guard items.contains(where: itemNeedsQuickBooksSync) else {
            completion(.success(items))
            return
        }

        liveAPI.fetchItems { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let quickBooksItems):
                    let quickBooksItemsByName = Dictionary(
                        quickBooksItems
                            .filter { $0.Active != false }
                            .map { (normalizedItemLookupKey($0.Name), $0) },
                        uniquingKeysWith: { first, _ in first }
                    )

                    for item in items where itemNeedsQuickBooksSync(item) {
                        let key = normalizedItemLookupKey(item.name)
                        if let quickBooksItem = quickBooksItemsByName[key] {
                            applyQuickBooksItem(quickBooksItem, to: item)
                        }
                    }

                    let remainingLocalItems = items.filter(itemNeedsQuickBooksSync)
                    guard !remainingLocalItems.isEmpty else {
                        saveQuickBooksSyncState()
                        completion(.success(items))
                        return
                    }

                    guard let incomeAccountRef = QuickBooksItemAccountResolver.incomeAccountRef(from: quickBooksItems) else {
                        completion(.failure(QuickBooksDataAPI.QBError.missingDefaultIncomeAccountRef))
                        return
                    }

                    ensureQuickBooksItems(
                        items,
                        index: 0,
                        incomeAccountRef: incomeAccountRef,
                        expenseAccountRef: QuickBooksItemAccountResolver.configuredExpenseAccountRef(),
                        synced: [],
                        completion: completion
                    )
                }
            }
        }
    }

    private func itemNeedsQuickBooksSync(_ item: Item) -> Bool {
        item.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }

    private func ensureQuickBooksItems(
        _ items: [Item],
        index: Int,
        incomeAccountRef: QuickBooksReference,
        expenseAccountRef: QuickBooksReference?,
        synced: [Item],
        completion: @escaping (Result<[Item], Error>) -> Void
    ) {
        guard index < items.count else {
            completion(.success(synced))
            return
        }

        let item = items[index]
        if let quickBooksID = item.quickBooksID, !quickBooksID.isEmpty {
            ensureQuickBooksItems(
                items,
                index: index + 1,
                incomeAccountRef: incomeAccountRef,
                expenseAccountRef: expenseAccountRef,
                synced: synced + [item],
                completion: completion
            )
            return
        }

        let payload = QuickBooksItemCreate(
            Name: item.name,
            ItemType: item.itemType.rawValue,
            Description: item.itemDescription,
            Sku: item.sku,
            PurchaseDesc: item.purchaseDescription ?? item.itemDescription,
            UnitPrice: item.unitPrice,
            PurchaseCost: item.purchaseCost,
            Taxable: item.isTaxable,
            IncomeAccountRef: incomeAccountRef,
            ExpenseAccountRef: expenseAccountRef,
            PrefVendorRef: item.preferredVendorQuickBooksID.flatMap { quickBooksID in
                quickBooksID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : QuickBooksReference(value: quickBooksID, name: item.preferredVendorName)
            }
        )
        liveAPI.createItem(payload) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let quickBooksItem):
                    item.quickBooksID = quickBooksItem.Id
                    saveQuickBooksSyncState()
                    ensureQuickBooksItems(
                        items,
                        index: index + 1,
                        incomeAccountRef: incomeAccountRef,
                        expenseAccountRef: expenseAccountRef,
                        synced: synced + [item],
                        completion: completion
                    )
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    private func quickBooksLineItems(for items: [Item]) -> [QuickBooksLineItem] {
        items.compactMap { item in
            let explicitQuickBooksID = item.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let quickBooksID = explicitQuickBooksID, !quickBooksID.isEmpty else { return nil }
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

    @discardableResult
    private func convertEstimate(_ estimate: Estimate) -> Invoice {
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
        linkExistingServiceReports(to: invoice, serviceCallID: estimate.serviceCallID)
        return invoice
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
            case .meeting, .reminder, .siteVisit, .other:
                Toggle("Arrival confirmed", isOn: Binding(
                    get: { call.arrivalConfirmed },
                    set: { call.arrivalConfirmed = $0 }
                ))
                Toggle("Action items documented", isOn: Binding(
                    get: { call.workCompletedChecklist },
                    set: { call.workCompletedChecklist = $0 }
                ))
                Toggle("Notes completed", isOn: Binding(
                    get: { call.documentationChecklist },
                    set: { call.documentationChecklist = $0 }
                ))
                Text("General appointments should capture attendance, action items, and notes before closeout.")
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
        case .meeting:
            return "Meeting Workflow"
        case .reminder:
            return "Reminder Workflow"
        case .siteVisit:
            return "Site Visit Workflow"
        case .other:
            return "General Workflow"
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

@ViewBuilder
private func workspaceMetricView(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(title)
            .font(.caption)
            .foregroundColor(.secondary)
        Text(value)
            .font(.headline)
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
        _shouldRecordPayment = State(initialValue: invoice.status.caseInsensitiveCompare("paid") != .orderedSame)
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
        if invoice.status.caseInsensitiveCompare("paid") == .orderedSame {
            return invoice.amount
        }
        return payments
            .filter { $0.invoice.id == invoice.id }
            .reduce(0) { partial, payment in
                partial + payment.amount
            }
    }

    private var selectedProcessor: OnsitePaymentProcessor {
        OnsitePaymentProcessor(rawValue: onsitePaymentProcessor) ?? .none
    }

    private var quickBooksPaymentsEnabled: Bool {
        QuickBooksDataAPI.shared.canUseQuickBooksPaymentsAPI
    }

    private var closeoutPaymentFormIsValid: Bool {
        guard shouldRecordPayment else { return true }
        if method == "card", quickBooksPaymentsEnabled {
            return !cardholderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                cardNumber.filter(\.isNumber).count >= 12 &&
                expirationMonth.filter(\.isNumber).count >= 1 &&
                expirationYear.filter(\.isNumber).count == 4 &&
                cardCVC.filter(\.isNumber).count >= 3
        }
        if method == "ach", quickBooksPaymentsEnabled {
            return !achAccountHolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                achAccountHolderName.trimmingCharacters(in: .whitespacesAndNewlines).count <= 64 &&
                (4...17).contains(achAccountNumber.filter(\.isNumber).count) &&
                achRoutingNumber.filter(\.isNumber).count == 9 &&
                achPhone.filter(\.isNumber).count == 10
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

                            if quickBooksPaymentsEnabled {
                                Text("QuickBooks card processing")
                                    .font(.subheadline.weight(.semibold))
                                TextField("Cardholder name", text: $cardholderName)
                                SecureField("Card number", text: $cardNumber)
                                    .keyboardType(.numberPad)
                                    .privacySensitive()
                                HStack {
                                    TextField("Exp MM", text: $expirationMonth)
                                        .keyboardType(.numberPad)
                                    TextField("Exp YYYY", text: $expirationYear)
                                        .keyboardType(.numberPad)
                                    SecureField("CVC", text: $cardCVC)
                                        .keyboardType(.numberPad)
                                        .privacySensitive()
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
                                Text(Config.QuickBooks.enablePaymentsScope ? "QuickBooks Payments is not connected. This card entry will only record a manual payment note." : "QuickBooks Payments scope is disabled. This card entry will only record a manual payment note.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        if method == "ach", quickBooksPaymentsEnabled {
                            TextField("Account holder name", text: $achAccountHolderName)
                            SecureField("Bank account number", text: $achAccountNumber)
                                .keyboardType(.numberPad)
                                .privacySensitive()
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
        processCardWithQuickBooks = quickBooksPaymentsEnabled && method == "card"
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
            if method == "card", quickBooksPaymentsEnabled {
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
            } else if method == "ach", quickBooksPaymentsEnabled {
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
            call.status = invoice.status.caseInsensitiveCompare("paid") == .orderedSame ? .completed : .invoiced
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
            [
                item.name,
                item.sku,
                item.itemDescription,
                item.preferredVendorName,
                item.vendorPartNumber,
                item.purchaseDescription
            ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
            .contains(query)
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
                                    let meta = [
                                        item.sku.map { "SKU \($0)" },
                                        item.preferredVendorName,
                                        item.vendorPartNumber.map { "Vendor # \($0)" }
                                    ]
                                    .compactMap { value in
                                        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                                        return trimmed?.isEmpty == false ? trimmed : nil
                                    }
                                    if !meta.isEmpty {
                                        Text(meta.joined(separator: " • "))
                                            .font(.caption2)
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

private enum CatalogItemAmountParser {
    static func parse(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = trimmed
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")

        if normalized.hasPrefix("("), normalized.hasSuffix(")") {
            let start = normalized.index(after: normalized.startIndex)
            let end = normalized.index(before: normalized.endIndex)
            return Double(String(normalized[start..<end])).map { -$0 }
        }

        return Double(normalized)
    }

    static func parseRequiredOrZero(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return parse(trimmed)
    }

    static func parseOptional(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return parse(trimmed)
    }

    static func isValidOptionalAmount(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || parse(trimmed) != nil
    }
}

private struct DocumentationItemCreatorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let vendors: [Vendor]
    let onCreated: (Item) -> Void

    @State private var name: String
    @State private var itemType: CatalogItemType = .service
    @State private var sku = ""
    @State private var description = ""
    @State private var price = ""
    @State private var cost = ""
    @State private var preferredVendor = ""
    @State private var vendorPartNumber = ""
    @State private var purchaseURL = ""
    @State private var purchaseDescription = ""
    @State private var isTaxable = false
    @State private var creationMessage = ""

    init(initialName: String = "", vendors: [Vendor] = [], onCreated: @escaping (Item) -> Void) {
        self.vendors = vendors
        self.onCreated = onCreated
        _name = State(initialValue: initialName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Sales") {
                    TextField("Item name", text: $name)
                    TextField("SKU", text: $sku)
                        .textInputAutocapitalization(.characters)
                    Picker("Item Type", selection: $itemType) {
                        ForEach(CatalogItemType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(2...3)
                    Toggle("Taxable", isOn: $isTaxable)
                    TextField("Sales price (optional)", text: $price)
                        .keyboardType(.decimalPad)
                }

                Section("Purchasing") {
                    TextField("Purchase price", text: $cost)
                        .keyboardType(.decimalPad)
                    TextField("Typical purchase source", text: $preferredVendor)
                    if !vendors.isEmpty {
                        Picker("Saved vendor", selection: $preferredVendor) {
                            Text("Manual / none").tag("")
                            ForEach(vendors) { vendor in
                                Text(vendor.name).tag(vendor.name)
                            }
                        }
                    }
                    TextField("Vendor part #", text: $vendorPartNumber)
                    TextField("Purchase URL", text: $purchaseURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField("Purchase notes", text: $purchaseDescription, axis: .vertical)
                        .lineLimit(2...3)
                }

                if !creationMessage.isEmpty {
                    Text(creationMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
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
                    .disabled(
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        CatalogItemAmountParser.parseRequiredOrZero(price) == nil ||
                        !CatalogItemAmountParser.isValidOptionalAmount(cost)
                    )
                }
            }
        }
    }

    private func saveItem() {
        guard let salesPrice = CatalogItemAmountParser.parseRequiredOrZero(price) else { return }
        let preferredVendorName = nonBlank(preferredVendor)
        let preferredVendorQuickBooksID = preferredVendorName.flatMap { vendorName in
            vendors.first { $0.name.caseInsensitiveCompare(vendorName) == .orderedSame }?.quickBooksID
        }
        let item = Item(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            itemType: itemType,
            unitPrice: salesPrice,
            purchaseCost: CatalogItemAmountParser.parseOptional(cost),
            isTaxable: isTaxable,
            itemDescription: nonBlank(description),
            sku: nonBlank(sku),
            preferredVendorName: preferredVendorName,
            preferredVendorQuickBooksID: preferredVendorQuickBooksID,
            vendorPartNumber: nonBlank(vendorPartNumber),
            purchaseURL: nonBlank(purchaseURL),
            purchaseDescription: nonBlank(purchaseDescription)
        )
        modelContext.insert(item)
        do {
            try modelContext.save()
            onCreated(item)
            dismiss()
        } catch {
            creationMessage = "Could not save item: \(error.localizedDescription)"
        }
    }

    private func nonBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

private struct JobDocumentationCameraPicker: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let onImagePicked: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: JobDocumentationCameraPicker

        init(_ parent: JobDocumentationCameraPicker) {
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

private enum BillingDocumentKind: String, CaseIterable, Identifiable {
    case estimate = "Estimate"
    case invoice = "Invoice"

    var id: String { rawValue }
}

enum BillingWorkspaceMode {
    case all
    case estimates
    case invoices

    fileprivate var defaultDocumentKind: BillingDocumentKind {
        switch self {
        case .all, .invoices:
            return .invoice
        case .estimates:
            return .estimate
        }
    }

    var navigationTitle: String {
        switch self {
        case .all:
            return "Invoices & Estimates"
        case .estimates:
            return "Estimates"
        case .invoices:
            return "Invoices"
        }
    }

    var showsEstimates: Bool {
        switch self {
        case .all, .estimates:
            return true
        case .invoices:
            return false
        }
    }

    var showsInvoices: Bool {
        switch self {
        case .all, .invoices:
            return true
        case .estimates:
            return false
        }
    }

    var showsPayments: Bool {
        switch self {
        case .all, .invoices:
            return true
        case .estimates:
            return false
        }
    }

    var showsEstimateBuilder: Bool {
        switch self {
        case .all, .estimates:
            return true
        case .invoices:
            return false
        }
    }

    var showsInvoiceBuilder: Bool {
        switch self {
        case .all, .invoices:
            return true
        case .estimates:
            return false
        }
    }
}

#Preview {
    BillingDocumentsView()
}
