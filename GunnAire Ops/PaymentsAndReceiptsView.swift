import SwiftUI
import SwiftData
import UIKit

struct PaymentsAndReceiptsView: View {
    private enum PaymentMethod: String, CaseIterable, Identifiable {
        case card = "Card"
        case ach = "ACH"
        case cash = "Cash"
        case check = "Check"

        var id: String { rawValue }
        var apiValue: String { rawValue.lowercased() }
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(\.gunnaireReduceMotion) private var reduceMotion
    @AppStorage("enableOnsitePayments") private var enableOnsitePayments = false
    @AppStorage("onsitePaymentProcessor") private var onsitePaymentProcessor = OnsitePaymentProcessor.none.rawValue
    @Query(sort: \ServiceCall.scheduledDate, order: .reverse) private var serviceCalls: [ServiceCall]
    @Query(sort: \Invoice.createdAt, order: .reverse) private var invoices: [Invoice]
    @Query(sort: \Payment.date, order: .reverse) private var payments: [Payment]
    @Query(sort: \Item.name, order: .forward) private var catalogItems: [Item]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @Query(sort: \Technician.name, order: .forward) private var technicians: [Technician]

    @StateObject private var onsitePaymentManager = OnsitePaymentManager.shared
    @StateObject private var fieldPaymentHandoff = FieldPaymentHandoff.shared
    @State private var selectedWorkspace: PaymentsWorkspace = .overview
    @State private var showingRecordPaymentSheet = false
    @State private var showingContactlessPaymentGuide = false
    @State private var showingRefundSheet = false
    @State private var selectedInvoiceID: UUID?
    @State private var refundPaymentID: UUID?
    @State private var amountText = ""
    @State private var refundAmountText = ""
    @State private var selectedMethod: PaymentMethod = .card
    @State private var cardLast4 = ""
    @State private var authorizationReference = ""
    @State private var paymentNotes = ""
    @State private var refundNotes = ""
    @State private var tapToPayMessage = ""
    @State private var fieldHandoffMessage = ""
    @State private var isShowingFieldHandoffHelp = false
    @State private var actionMessage = ""
    @State private var backendUploadMessage = ""
    @State private var sharedPaymentCollections: [BackendPaymentCollectionRecord] = []
    @State private var sharedPaymentCollectionMessage = ""
    @State private var isLoadingSharedPaymentCollections = false
    @State private var fieldPaymentAssignments: [BackendFieldPaymentAssignmentRecord] = []
    @State private var fieldPaymentAssignmentMessage = ""
    @State private var isLoadingFieldPaymentAssignments = false
    @State private var deferredCollectionInvoiceID: UUID?
    @State private var deferredCollectionPrefersContactlessGuide = false
    @State private var deferredCollectionExpiresAt: Date?
    @State private var contactlessGuideMessage = ""
    @State private var isShowingContactlessCollectionSteps = false
    @State private var isVerifyingContactlessPayment = false
    @State private var syncingPaymentID: UUID?
    @State private var isProcessingQuickBooksPayment = false
    @State private var isProcessingQuickBooksRefund = false
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
    @State private var quickBooksPaymentReceipts: [String: QuickBooksPaymentsPaymentReceipt] = [:]

    private let liveAPI = QuickBooksDataAPI.shared
    private let googleAuth = GoogleAuthManager.shared
    private let collectionActionColumns = [
        GridItem(.adaptive(minimum: 185), spacing: 8, alignment: .leading)
    ]

    private var selectedInvoice: Invoice? {
        guard let selectedInvoiceID else { return nil }
        return visibleInvoices.first { $0.id == selectedInvoiceID }
    }

    private var selectedRefundPayment: Payment? {
        guard let refundPaymentID else { return nil }
        return visiblePayments.first { $0.id == refundPaymentID }
    }

    private var selectedProcessor: OnsitePaymentProcessor {
        OnsitePaymentProcessor(rawValue: onsitePaymentProcessor) ?? .none
    }

    private var isAdminUser: Bool {
        AppAccess.canViewFinancialManagement(email: signedInEmail, users: users)
    }

    private var canManageQuickBooks: Bool {
        AppAccess.canAccessSidebarItem(.quickBooksManagement, email: signedInEmail, users: users)
    }

    private var visibleInvoiceIDsForFieldUser: Set<UUID> {
        AppAccess.visibleFieldPaymentInvoiceIDs(
            email: signedInEmail,
            users: users,
            serviceCalls: serviceCalls,
            invoices: invoices,
            technicians: technicians
        )
    }

    private var visibleInvoices: [Invoice] {
        // CloudKit can resolve an invoice before its customer relationship. Such
        // records stay visible in Sync Recovery but must never expose payment or
        // customer actions until the relationship is complete.
        let relationshipCompleteInvoices = invoices.filter { $0.customer != nil }
        guard !isAdminUser else { return relationshipCompleteInvoices }
        let visibleIDs = visibleInvoiceIDsForFieldUser
        return relationshipCompleteInvoices.filter { visibleIDs.contains($0.id) }
    }

    private var visiblePayments: [Payment] {
        let relationshipCompletePayments = payments.filter {
            $0.invoice?.customer != nil
        }
        guard !isAdminUser else { return relationshipCompletePayments }
        let visibleIDs = visibleInvoiceIDsForFieldUser
        return relationshipCompletePayments.filter {
            guard let invoiceID = $0.invoice?.id else { return false }
            return visibleIDs.contains(invoiceID)
        }
    }

    private var companyQueueRetryPayments: [Payment] {
        visiblePayments.filter(\.needsSharedCompanyQueueUpload)
    }

    private var processorIsReady: Bool {
        enableOnsitePayments && selectedProcessor.supportsTapToPay && onsitePaymentManager.processorReady()
    }

    private var quickBooksPaymentsEnabled: Bool {
        QuickBooksDataAPI.shared.canUseQuickBooksPaymentsAPI
    }

    private var quickBooksPaymentsUnavailableMessage: String {
        if let diagnostic = QuickBooksDataAPI.shared.paymentsAuthorizationDiagnostic {
            return diagnostic
        }
        return Config.QuickBooks.enablePaymentsScope
            ? "QuickBooks Payments is not authorized for this connection yet."
            : "Enable the QuickBooks Payments scope before using live payment endpoints."
    }

    private var signedInEmail: String? {
        AppIdentity.currentEmail
    }

    private var outstandingInvoices: [(invoice: Invoice, balanceDue: Double)] {
        visibleInvoices
            .compactMap { invoice in
                let balance = outstandingBalance(for: invoice)
                return balance > 0 ? (invoice, balance) : nil
            }
            .sorted { lhs, rhs in
                if lhs.balanceDue == rhs.balanceDue {
                    return lhs.invoice.createdAt > rhs.invoice.createdAt
                }
                return lhs.balanceDue > rhs.balanceDue
            }
    }

    private var totalOutstandingBalance: Double {
        outstandingInvoices.reduce(0) { $0 + $1.balanceDue }
    }

    private var collectibleOutstandingInvoices: [(invoice: Invoice, balanceDue: Double)] {
        outstandingInvoices.filter { $0.invoice.isReadyForPaymentCollection }
    }

    private var activeFieldCollectionTechnicians: [AppUser] {
        users
            .filter { $0.isActive && $0.role == .fieldTechnician }
            .sorted { $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending }
    }

    private var overdueInvoiceCount: Int {
        outstandingInvoices.filter { isOverdue($0.invoice) }.count
    }

    private var collectedToday: Double {
        let calendar = Calendar.current
        return visiblePayments
            .filter { calendar.isDateInToday($0.date) }
            .reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        ZStack {
            WatermarkBackground()
            NavigationStack {
                List {
                    Section("Payments Workspace") {
                        Picker("Workspace", selection: $selectedWorkspace) {
                            ForEach(PaymentsWorkspace.allCases) { workspace in
                                Text(workspace.label).tag(workspace)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("PaymentsWorkspacePicker")

                        Label(selectedWorkspace.guidance, systemImage: selectedWorkspace.systemImage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !actionMessage.isEmpty ||
                        !fieldHandoffMessage.isEmpty ||
                        fieldPaymentHandoff.activeInvoiceID != nil {
                        Section("Action Status") {
                            if !actionMessage.isEmpty {
                                Text(actionMessage)
                                    .font(.caption)
                                    .foregroundStyle(actionMessage.localizedCaseInsensitiveContains("failed") ? .orange : .secondary)
                            }
                            if !fieldHandoffMessage.isEmpty {
                                Text(fieldHandoffMessage)
                                    .font(.caption)
                                    .foregroundStyle(fieldHandoffMessage.localizedCaseInsensitiveContains("could not") ? .red : .secondary)
                            }
                            if fieldPaymentHandoff.activeInvoiceID != nil {
                                Label("Ready for nearby iPhone", systemImage: "iphone.and.arrow.forward")
                                    .foregroundStyle(Color.green)
                                    .accessibilityElement(children: .combine)
                                    .accessibilityIdentifier("ActiveFieldPaymentHandoffStatus")

                                Text("Open GunnAire Ops from Handoff within 30 minutes. This invoice's contactless collection guide opens automatically.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                DisclosureGroup(
                                    "Handoff help",
                                    isExpanded: $isShowingFieldHandoffHelp
                                ) {
                                    Text(FieldPaymentHandoff.requirementsDetail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .accessibilityIdentifier("ActiveFieldPaymentHandoffHelp")

                                Button("Stop Field Handoff", role: .cancel) {
                                    fieldPaymentHandoff.end()
                                    isShowingFieldHandoffHelp = false
                                    fieldHandoffMessage = "Payment handoff stopped. Send the invoice again if it still needs field collection."
                                }
                                .buttonStyle(.bordered)
                                .accessibilityHint("Stops advertising the current invoice to nearby company devices.")
                            }
                        }
                    }

                    if selectedWorkspace == .overview {
                    Section("Collections Dashboard") {
                        metricRow(title: isAdminUser ? "Outstanding Balance" : "Assigned Balance", value: totalOutstandingBalance.formatted(.currency(code: "USD")))
                        metricRow(title: isAdminUser ? "Overdue Invoices" : "Assigned Overdue", value: "\(overdueInvoiceCount)")
                        metricRow(title: isAdminUser ? "Collected Today" : "Your Collections Today", value: collectedToday.formatted(.currency(code: "USD")))
                        if !isAdminUser {
                            Text("Field users only see invoice collection records linked to assigned jobs.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Section("Payment Status") {
                        if isAdminUser {
                            Text("QuickBooks: \(isQuickBooksConnected ? "Connected" : "Not Connected")")
                                .foregroundColor(isQuickBooksConnected ? .green : .secondary)
                        } else {
                            Text("Company payment queue: \(GunnAireBackendService.isConfigured ? "Enabled" : "Offline")")
                                .foregroundColor(GunnAireBackendService.isConfigured ? .green : .secondary)
                        }
                        if OnsitePaymentManager.shared.tapToPayAvailableInCurrentBuild {
                            Text("Tap to Pay on iPhone: \(processorIsReady ? selectedProcessor.displayName : "Not Ready")")
                                .foregroundColor(processorIsReady ? .green : .secondary)
                            Text(onsitePaymentManager.processorStatusDetail())
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Card, check, and cash payments can be recorded here. For contactless payment, use QuickBooks Mobile or GoPayment on the field iPhone after handoff.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    }

                    if selectedWorkspace == .collect {
                        if deferredCollectionInvoiceID != nil {
                            deferredCollectionHandoffSection
                        }

                        if GunnAireBackendService.isConfigured {
                            fieldPaymentAssignmentSection
                        }

                    Section("Outstanding Invoices") {
                        if outstandingInvoices.isEmpty {
                            Text("No unpaid or partially paid invoices.")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(outstandingInvoices, id: \.invoice.id) { entry in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(entry.invoice.customer.name)
                                                .font(.headline)
                                            Text(entry.invoice.lineItemSummary.isEmpty ? "Invoice \(entry.invoice.id.uuidString.prefix(8))" : entry.invoice.lineItemSummary)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            Text(Invoice.dueStatusDetail(for: entry.invoice, payments: payments))
                                                .font(.caption2)
                                                .foregroundColor(isOverdue(entry.invoice) ? .red : .secondary)
                                            if let blockedMessage = entry.invoice.paymentCollectionBlockedMessage {
                                                Label(entry.invoice.taxCalculationStatus.displayName, systemImage: "building.columns")
                                                    .font(.caption2)
                                                    .foregroundStyle(Color.orange)
                                                Text(blockedMessage)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 4) {
                                            Text(entry.balanceDue, format: .currency(code: "USD"))
                                                .font(.headline)
                                            Text(balanceStatusLabel(for: entry.invoice, balanceDue: entry.balanceDue))
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }

                                    LazyVGrid(columns: collectionActionColumns, alignment: .leading, spacing: 8) {
                                        Button("Open Invoice") {
                                            selectedInvoiceID = entry.invoice.id
                                        }
                                        .buttonStyle(.bordered)

                                        if let linkedCall = serviceCall(for: entry.invoice) {
                                            Button("Open Job") {
                                                GunnAireAppIntentRouter.storeDocumentationRoute(linkedCall.id)
                                            }
                                            .buttonStyle(.bordered)
                                        }

                                        Button("Open Customer") {
                                            GunnAireAppIntentRouter.storeCustomerRoute(entry.invoice.customer.id)
                                        }
                                        .buttonStyle(.bordered)

                                        if entry.invoice.isReadyForPaymentCollection {
                                            Button("Collect") {
                                                preparePaymentForm(for: entry.invoice)
                                                showingRecordPaymentSheet = true
                                            }
                                            .buttonStyle(.bordered)
                                        }

                                        if entry.invoice.isReadyForPaymentCollection,
                                           isAdminUser,
                                           !activeFieldCollectionTechnicians.isEmpty {
                                            Menu {
                                                ForEach(activeFieldCollectionTechnicians, id: \.id) { technician in
                                                    Button(technician.email) {
                                                        Task {
                                                            await assignFieldCollection(
                                                                invoice: entry.invoice,
                                                                amount: entry.balanceDue,
                                                                technicianEmail: technician.email
                                                            )
                                                        }
                                                    }
                                                }
                                            } label: {
                                                Label("Assign Field Collection", systemImage: "person.badge.plus")
                                            }
                                            .accessibilityHint("Creates a server-authorized collection task for the selected field technician.")
                                        }

                                        if entry.invoice.isReadyForPaymentCollection,
                                           fieldPaymentHandoff.canStartFromCurrentDevice {
                                            Button("Send to Field iPhone") {
                                                let didStart = fieldPaymentHandoff.begin(
                                                    invoiceID: entry.invoice.id,
                                                    amount: entry.balanceDue
                                                )
                                                isShowingFieldHandoffHelp = false
                                                fieldHandoffMessage = didStart
                                                    ? ""
                                                    : "Payment handoff could not start on this device."
                                            }
                                            .buttonStyle(.bordered)
                                            .accessibilityHint(FieldPaymentHandoff.requirementsDetail)
                                        }

                                        if entry.invoice.isReadyForPaymentCollection, processorIsReady {
                                            Button("Tap to Pay on iPhone") {
                                                preparePaymentForm(for: entry.invoice, preferredMethod: .card)
                                                showingRecordPaymentSheet = true
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .tint(Color.brandGold)
                                            .foregroundStyle(Color.primaryBlack)
                                        }
                                    }
                                    .accessibilityIdentifier("InvoiceCollectionActions-\(entry.invoice.id.uuidString)")

                                    HStack {
                                        if let phoneURL = customerPhoneURL(for: entry.invoice) {
                                            Button("Call") {
                                                openURL(phoneURL)
                                            }
                                            .buttonStyle(.bordered)
                                        }

                                        if let reminderURL = reminderEmailURL(for: entry.invoice, balanceDue: entry.balanceDue) {
                                            Button("Draft Reminder") {
                                                openReminderEmail(for: entry.invoice, balanceDue: entry.balanceDue, fallbackURL: reminderURL)
                                            }
                                            .buttonStyle(.bordered)
                                        }
                                    }

                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }

                    Section("Record Payment") {
                        Button("Record Invoice Payment") {
                            preparePaymentForm()
                            showingRecordPaymentSheet = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.brandGold)
                        .foregroundStyle(Color.primaryBlack)
                        .disabled(collectibleOutstandingInvoices.isEmpty)

                        if collectibleOutstandingInvoices.isEmpty {
                            Text(outstandingInvoices.isEmpty
                                ? "No unpaid or partially paid invoices are available for collection."
                                : "Open invoices are waiting for an authoritative QuickBooks tax total before collection.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if !backendUploadMessage.isEmpty {
                            Text(backendUploadMessage)
                                .font(.caption)
                                .foregroundColor(backendUploadMessage.localizedCaseInsensitiveContains("failed") ? .orange : .secondary)
                        }
                        if !companyQueueRetryPayments.isEmpty {
                            Button(syncingPaymentID == nil ? "Retry Company Queue Uploads" : "Retrying Company Queue...") {
                                Task {
                                    await retryCompanyQueueUploads(companyQueueRetryPayments)
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(syncingPaymentID != nil || !GunnAireBackendService.isConfigured)

                            Text("\(companyQueueRetryPayments.count) payment\(companyQueueRetryPayments.count == 1 ? "" : "s") still need shared company storage upload.")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                    }

                    if selectedWorkspace == .history {
                    if isAdminUser {
                        Section("Shared Field Collections") {
                            HStack {
                                Button(isLoadingSharedPaymentCollections ? "Refreshing..." : "Refresh Shared Collections") {
                                    Task {
                                        await refreshSharedPaymentCollections()
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(isLoadingSharedPaymentCollections || !GunnAireBackendService.isConfigured)

                                Spacer()

                                Text("\(sharedPaymentCollections.count)")
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                            }

                            if !GunnAireBackendService.isConfigured {
                                Text("Shared company storage is not configured for this build.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else if sharedPaymentCollections.isEmpty {
                                Text(sharedPaymentCollectionMessage.isEmpty ? "No shared field payment collections loaded." : sharedPaymentCollectionMessage)
                                    .font(.caption)
                                    .foregroundColor(sharedPaymentCollectionMessage.localizedCaseInsensitiveContains("failed") ? .orange : .secondary)
                            } else {
                                ForEach(sharedPaymentCollections.prefix(12)) { collection in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(collection.customerName)
                                                .font(.headline)
                                            Spacer()
                                            Text(collection.amount, format: .currency(code: "USD"))
                                                .font(.headline)
                                        }
                                        Text(sharedCollectionDetail(for: collection))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        if let invoiceQuickBooksID = collection.invoiceQuickBooksID, !invoiceQuickBooksID.isEmpty {
                                            Text("QBO Invoice: \(invoiceQuickBooksID)")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        if let notes = collection.notes, !notes.isEmpty {
                                            Text(notes)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                                if !sharedPaymentCollectionMessage.isEmpty {
                                    Text(sharedPaymentCollectionMessage)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }

                    Section("Payment History") {
                        if visiblePayments.isEmpty {
                            Text("No payments recorded yet.")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(visiblePayments) { payment in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(payment.invoice.customer.name)
                                                .font(.headline)
                                            Text("\(payment.methodSummary) - \(payment.date.formatted(date: .abbreviated, time: .shortened))")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Text(payment.amount, format: .currency(code: "USD"))
                                    }

                                    HStack {
                                        if isAdminUser {
                                            Text(payment.quickBooksID == nil ? "Not synced to QuickBooks accounting" : "QuickBooks ID: \(payment.quickBooksID ?? "")")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            Spacer()
                                            Button(syncingPaymentID == payment.id ? "Syncing..." : "Sync") {
                                                syncPaymentToQuickBooks(payment)
                                            }
                                            .buttonStyle(.bordered)
                                            .disabled(payment.quickBooksID != nil || syncingPaymentID != nil || !isQuickBooksConnected || payment.isRefund || payment.amount <= 0)
                                            if payment.needsQuickBooksAttention {
                                                Button("Retry QB Sync") {
                                                    retryQuickBooksFollowUp(for: payment)
                                                }
                                                .buttonStyle(.borderedProminent)
                                                .disabled(syncingPaymentID != nil || !isQuickBooksConnected)
                                            }
                                        }
                                    }
                                    if let cardLast4 = payment.cardLast4, !cardLast4.isEmpty {
                                        Text("Card ending in \(cardLast4)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    if let authorizationReference = payment.authorizationReference, !authorizationReference.isEmpty {
                                        Text("Authorization: \(authorizationReference)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    if isAdminUser {
                                        if let chargeID = payment.quickBooksChargeID, !chargeID.isEmpty {
                                            Text(payment.isRefund ? "Refund charge ID: \(chargeID)" : "Charge ID: \(chargeID)")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        if let refundReceiptID = payment.quickBooksRefundReceiptID, !refundReceiptID.isEmpty {
                                            Text("Refund receipt ID: \(refundReceiptID)")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    if let processorDisplayName = payment.processorDisplayName {
                                        Text("Processor: \(processorDisplayName)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    if payment.needsSharedCompanyQueueUpload {
                                        Text(payment.processorSyncDetail ?? "Shared company payment queue upload needs attention.")
                                            .font(.caption2)
                                            .foregroundColor(.orange)
                                    }
                                    if isAdminUser,
                                       payment.needsQuickBooksAttention,
                                       let detail = payment.quickBooksAccountingSyncDetail,
                                       !detail.isEmpty {
                                        Text("QuickBooks follow-up: \(detail)")
                                            .font(.caption2)
                                            .foregroundColor(.orange)
                                    }
                                    if let notes = payment.notes, !notes.isEmpty {
                                        Text(notes)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    if let chargeID = payment.quickBooksChargeID,
                                       let receipt = quickBooksPaymentReceipts[chargeID] {
                                        if let amount = receipt.amount, !amount.isEmpty {
                                            Text("Receipt amount: \(amount)")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        if let link = receipt.links?.first(where: { ($0.rel ?? "").localizedCaseInsensitiveContains("receipt") || ($0.rel ?? "").localizedCaseInsensitiveContains("self") }),
                                           let href = link.href,
                                           let url = URL(string: href) {
                                            Link("Open QB Receipt", destination: url)
                                                .font(.caption2)
                                        }
                                    }

                                    HStack {
                                        Button("Open Invoice") {
                                            selectedInvoiceID = payment.invoice.id
                                        }
                                        .buttonStyle(.bordered)

                                        if let linkedCall = serviceCall(for: payment.invoice) {
                                            Button("Open Job") {
                                                GunnAireAppIntentRouter.storeDocumentationRoute(linkedCall.id)
                                            }
                                            .buttonStyle(.bordered)
                                        }

                                        Button("Open Customer") {
                                            GunnAireAppIntentRouter.storeCustomerRoute(payment.invoice.customer.id)
                                        }
                                        .buttonStyle(.bordered)

                                        if let receiptURL = receiptEmailURL(for: payment) {
                                            Button("Send Receipt") {
                                                openReceiptEmail(for: payment, fallbackURL: receiptURL)
                                            }
                                            .buttonStyle(.bordered)
                                        }

                                        if let phoneURL = customerPhoneURL(for: payment.invoice) {
                                            Button("Call Customer") {
                                                openURL(phoneURL)
                                            }
                                            .buttonStyle(.bordered)
                                        }

                                        if isAdminUser,
                                           payment.quickBooksChargeID?.isEmpty == false,
                                           !payment.isRefund,
                                           payment.amount > 0 {
                                            Button("Refund") {
                                                prepareRefundForm(for: payment)
                                                showingRefundSheet = true
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .tint(.red)
                                            .disabled(!quickBooksPaymentsEnabled)
                                        }

                                        if payment.quickBooksChargeID?.isEmpty == false,
                                           quickBooksPaymentReceipts[payment.quickBooksChargeID ?? ""] == nil {
                                            Button("Load QB Receipt") {
                                                loadQuickBooksPaymentReceipt(for: payment)
                                            }
                                            .buttonStyle(.bordered)
                                            .disabled(syncingPaymentID != nil || !quickBooksPaymentsEnabled)
                                        }

                                        if payment.needsSharedCompanyQueueUpload {
                                            Button(syncingPaymentID == payment.id ? "Queueing..." : "Retry Queue") {
                                                Task {
                                                    await retryCompanyQueueUploads([payment])
                                                }
                                            }
                                            .buttonStyle(.bordered)
                                            .disabled(syncingPaymentID != nil || !GunnAireBackendService.isConfigured)
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    }
                }
                .navigationTitle("Payments")
            }
        }
        .sheet(isPresented: $showingRecordPaymentSheet) {
            paymentSheet
        }
        .sheet(isPresented: $showingContactlessPaymentGuide) {
            contactlessPaymentGuide
        }
        .sheet(isPresented: $showingRefundSheet) {
            refundSheet
        }
        .onAppear {
            if !isAdminUser, selectedWorkspace == .overview {
                selectedWorkspace = .collect
            }
            applyPendingIntentInvoiceIfNeeded()
            if isAdminUser, GunnAireBackendService.isConfigured, sharedPaymentCollections.isEmpty {
                Task {
                    await refreshSharedPaymentCollections()
                }
            }
            if GunnAireBackendService.isConfigured, fieldPaymentAssignments.isEmpty {
                Task {
                    await refreshFieldPaymentAssignments()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GunnAireRouteDidChange"))) { _ in
            applyPendingIntentInvoiceIfNeeded()
        }
        .onChange(of: visibleInvoices.map(\.id)) { _, _ in
            resolveDeferredCollectionRouteIfPossible()
        }
        .task(id: deferredCollectionExpiresAt) {
            await waitForDeferredCollectionExpiration()
        }
    }

    @ViewBuilder
    private var deferredCollectionHandoffSection: some View {
        Section("Collection Handoff") {
            Label(
                "Waiting for the assigned invoice",
                systemImage: "iphone.and.arrow.forward"
            )
            .foregroundStyle(Color.orange)

            Text("The task is preserved while company sync confirms that this invoice belongs to your account. It will open automatically when the authorized job and invoice arrive.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Retry") {
                    resolveDeferredCollectionRouteIfPossible()
                }
                .buttonStyle(.bordered)

                Button("Dismiss", role: .cancel) {
                    deferredCollectionInvoiceID = nil
                    deferredCollectionPrefersContactlessGuide = false
                    deferredCollectionExpiresAt = nil
                    GunnAireAppIntentRouter.clearDeferredPaymentCollectionRoute()
                    actionMessage = "Collection handoff dismissed. The server task remains available in Your Field Collection Tasks."
                }
                .buttonStyle(.bordered)
            }
        }
        .accessibilityIdentifier("DeferredFieldCollectionHandoff")
    }

    @ViewBuilder
    private var fieldPaymentAssignmentSection: some View {
        Section(isAdminUser ? "Field Collection Assignments" : "Your Field Collection Tasks") {
            HStack {
                Button(isLoadingFieldPaymentAssignments ? "Refreshing..." : "Refresh Tasks") {
                    Task {
                        await refreshFieldPaymentAssignments()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isLoadingFieldPaymentAssignments)

                Spacer()

                Text("\(fieldPaymentAssignments.count)")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }

            if fieldPaymentAssignments.isEmpty {
                Text(fieldPaymentAssignmentMessage.isEmpty ? "No active field collection tasks." : fieldPaymentAssignmentMessage)
                    .font(.caption)
                    .foregroundColor(fieldPaymentAssignmentMessage.localizedCaseInsensitiveContains("failed") ? .orange : .secondary)
            } else {
                ForEach(fieldPaymentAssignments) { assignment in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(assignment.customerName)
                                .font(.headline)
                            Spacer()
                            Text(assignment.amount, format: .currency(code: "USD"))
                                .font(.headline)
                        }
                        Text("\(assignment.status.capitalized) • Assigned to \(assignment.assignedTo)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if let collectedAmount = assignment.collectedAmount, collectedAmount > 0 {
                            Text("Collected \(collectedAmount.formatted(.currency(code: "USD"))) of \(assignment.amount.formatted(.currency(code: "USD")))")
                                .font(.caption2)
                                .foregroundColor(assignment.status == "completed" ? .green : .secondary)
                        }
                        if assignment.status == "completed",
                           let completedBy = assignment.completedBy,
                           !completedBy.isEmpty {
                            Text("Completed by \(completedBy)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            if !isAdminUser, assignment.status == "pending" {
                                Button("Accept") {
                                    Task {
                                        await acceptFieldCollection(assignment)
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                            }

                            if let invoiceID = assignment.invoiceUUID,
                               visibleInvoices.contains(where: { $0.id == invoiceID }),
                               assignment.isActionable {
                                Button("Open Collection") {
                                    GunnAireAppIntentRouter.storePaymentCollectionRoute(
                                        invoiceID,
                                        prefersContactlessGuide: true
                                    )
                                }
                                .buttonStyle(.bordered)
                            } else if !isAdminUser, assignment.isActionable {
                                Text("Job details will appear after company sync finishes on this device.")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            if isAdminUser, assignment.isActionable {
                                Button("Cancel", role: .destructive) {
                                    Task {
                                        await cancelFieldCollection(assignment)
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private var paymentSheet: some View {
        NavigationStack {
            Form {
                Section("Payment Details") {
                    Picker("Invoice", selection: $selectedInvoiceID) {
                        Text("Select Invoice").tag(UUID?.none)
                        ForEach(outstandingInvoices, id: \.invoice.id) { entry in
                            Text("\(entry.invoice.customer.name) - \(entry.balanceDue, format: .currency(code: "USD"))")
                                .tag(UUID?.some(entry.invoice.id))
                        }
                    }

                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)

                    Picker("Method", selection: $selectedMethod) {
                        ForEach(PaymentMethod.allCases) { method in
                            Text(method.rawValue).tag(method)
                        }
                    }

                    if selectedMethod == .card {
                        if enableOnsitePayments && OnsitePaymentManager.shared.tapToPayAvailableInCurrentBuild {
                            Button(onsitePaymentManager.isProcessing ? "Processing Tap to Pay on iPhone..." : "Start Tap to Pay on iPhone") {
                                Task {
                                    await runTapToPay()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .disabled(onsitePaymentManager.isProcessing || Double(amountText) == nil || !processorIsReady)

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
                            TextField("Authorization ref", text: $authorizationReference)
                            Text(Config.QuickBooks.enablePaymentsScope ? "QuickBooks Payments is not connected. This card entry will only record a manual payment note." : "QuickBooks Payments scope is disabled. This card entry will only record a manual payment note.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    if selectedMethod == .ach, quickBooksPaymentsEnabled {
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

                    if selectedMethod == .card, enableOnsitePayments, OnsitePaymentManager.shared.tapToPayAvailableInCurrentBuild {
                        Text(onsitePaymentManager.processorStatusDetail())
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if !actionMessage.isEmpty {
                        Text(actionMessage)
                            .font(.caption)
                            .foregroundColor(actionMessage.localizedCaseInsensitiveContains("failed") ? .red : .secondary)
                    }
                }
            }
            .navigationTitle("Record Payment")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        resetPaymentForm()
                        showingRecordPaymentSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(paymentConfirmationTitle) {
                        Task {
                            await savePaymentRecord()
                        }
                    }
                    .disabled(selectedInvoice == nil || Double(amountText) == nil || isProcessingQuickBooksPayment || !paymentFormIsValid)
                }
            }
        }
        .tint(Color.brandGold)
    }

    private var contactlessPaymentGuide: some View {
        NavigationStack {
            Form {
                if let invoice = selectedInvoice {
                    let balance = outstandingBalance(for: invoice)
                    let quickBooksReference = FieldPaymentHandoff.quickBooksInvoiceReference(invoice.quickBooksID)

                    Section("Collection") {
                        LabeledContent("Customer", value: invoice.customer.name)
                        LabeledContent("Authorized balance", value: balance.formatted(.currency(code: "USD")))
                    }

                    if let quickBooksReference {
                        Section("QuickBooks Invoice") {
                            LabeledContent("Invoice ID", value: quickBooksReference)
                                .accessibilityIdentifier("ContactlessQuickBooksInvoiceID")
                        }

                        Section("Use Tap to Pay on iPhone in QuickBooks") {
                            Button {
                                openQuickBooksPaymentApp(
                                    url: FieldPaymentHandoff.quickBooksMobileAppStoreURL,
                                    invoiceReference: quickBooksReference,
                                    appName: "QuickBooks"
                                )
                            } label: {
                                Label("Copy Invoice ID & Open QuickBooks", systemImage: "arrow.up.forward.app")
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("CopyInvoiceIDAndOpenQuickBooks")

                            Button {
                                openQuickBooksPaymentApp(
                                    url: FieldPaymentHandoff.goPaymentAppStoreURL,
                                    invoiceReference: quickBooksReference,
                                    appName: "GoPayment"
                                )
                            } label: {
                                Label("Copy Invoice ID & Open GoPayment", systemImage: "arrow.up.forward.app")
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("CopyInvoiceIDAndOpenGoPayment")

                            DisclosureGroup(
                                "Show collection steps",
                                isExpanded: $isShowingContactlessCollectionSteps
                            ) {
                                ForEach(Array(FieldPaymentHandoff.quickBooksTapToPaySteps.enumerated()), id: \.offset) { index, step in
                                    HStack(alignment: .top, spacing: 10) {
                                        Text("\(index + 1)")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(Color.primaryBlack)
                                            .frame(width: 24, height: 24)
                                            .background(Color.brandGold, in: Circle())
                                        Text(step)
                                    }
                                }

                                Text("QuickBooks does not provide a supported link to one specific invoice. Use the QBO invoice ID above; no customer or card data is placed in Handoff.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityIdentifier("ContactlessQuickBooksCollectionSteps")
                        }

                        Section("Confirm Payment") {
                            Text("Return here after QuickBooks confirms payment. The app handoff alone never marks this invoice paid.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if isAdminUser {
                                if isQuickBooksConnected {
                                    Button(isVerifyingContactlessPayment ? "Checking QuickBooks..." : "Check QuickBooks for Payment") {
                                        Task {
                                            await verifyContactlessPayment(for: invoice)
                                        }
                                    }
                                    .disabled(isVerifyingContactlessPayment)
                                    .accessibilityIdentifier("VerifyContactlessQuickBooksPayment")
                                } else if canManageQuickBooks {
                                    Button {
                                        openQuickBooksConnectionFromContactlessGuide()
                                    } label: {
                                        Label("Connect QuickBooks to Verify", systemImage: "link.badge.plus")
                                    }
                                    .accessibilityIdentifier("ConnectQuickBooksForContactlessVerification")
                                } else {
                                    Text("An administrator must connect QuickBooks on this device before Accounting can verify the payment.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .accessibilityIdentifier("ContactlessQuickBooksAdminConnectionInstruction")
                                }
                            } else {
                                Text("Leave the invoice open. Accounting will verify QuickBooks before another payment attempt.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("ContactlessAccountingVerificationInstruction")
                            }

                            Button("Record Cash, Check, or Another Verified Payment") {
                                openVerifiedPaymentEntryFromContactlessGuide()
                            }
                        }
                    } else {
                        Section("QuickBooks Invoice Required") {
                            Label(
                                "Contactless collection is waiting for QuickBooks publication.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(Color.orange)

                            Text("Ask the office to publish this invoice to QuickBooks, then reopen the collection task. GunnAire Ops will not present a local identifier as though QuickBooks could find it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Button("Record Cash, Check, or Another Verified Payment") {
                                openVerifiedPaymentEntryFromContactlessGuide()
                            }
                        }
                    }

                    if !contactlessGuideMessage.isEmpty {
                        Section("Status") {
                            Text(contactlessGuideMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "Invoice Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text("The invoice is no longer available to this business account.")
                    )
                }
            }
            .navigationTitle("Contactless Payment")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showingContactlessPaymentGuide = false
                    }
                }
            }
        }
        .tint(Color.brandGold)
    }

    private func openVerifiedPaymentEntryFromContactlessGuide() {
        showingContactlessPaymentGuide = false
        Task { @MainActor in
            await Task.yield()
            showingRecordPaymentSheet = true
        }
    }

    private func openQuickBooksPaymentApp(
        url: URL,
        invoiceReference: String,
        appName: String
    ) {
        UIPasteboard.general.string = invoiceReference
        contactlessGuideMessage = "Invoice ID copied. In \(appName), choose Receive payment, find this invoice, then choose Charge and Tap to Pay."
        openURL(url)
    }

    private func openQuickBooksConnectionFromContactlessGuide() {
        showingContactlessPaymentGuide = false
        Task { @MainActor in
            await Task.yield()
            GunnAireAppIntentRouter.store(.sync)
        }
    }

    private func verifyContactlessPayment(for invoice: Invoice) async {
        guard isAdminUser else {
            contactlessGuideMessage = "Only Accounting or an administrator can verify QuickBooks payment records."
            return
        }
        guard isQuickBooksConnected else {
            contactlessGuideMessage = "Connect QuickBooks on this device before checking this payment."
            return
        }
        guard let quickBooksInvoiceID = invoice.quickBooksID?.nilIfBlank else {
            contactlessGuideMessage = "Publish this invoice to QuickBooks before checking its payment."
            return
        }

        let previousBalance = outstandingBalance(for: invoice)
        let knownQuickBooksPaymentIDs = Set(
            payments
                .filter { $0.invoice?.id == invoice.id }
                .compactMap { $0.quickBooksID?.nilIfBlank }
        )
        isVerifyingContactlessPayment = true
        defer { isVerifyingContactlessPayment = false }

        do {
            let remoteInvoice = try await fetchQuickBooksInvoiceForContactlessVerification(
                id: quickBooksInvoiceID
            )
            guard remoteInvoice.Id == quickBooksInvoiceID else {
                contactlessGuideMessage = "QuickBooks did not return this invoice. Reconnect the approved company or review the invoice in QuickBooks before collecting again."
                return
            }

            let remotePayments = try await fetchQuickBooksPaymentsForContactlessVerification()
            let linkedPayments = remotePayments.filter { payment in
                QuickBooksPaymentAllocation.amountApplied(
                    by: payment,
                    toInvoiceID: quickBooksInvoiceID
                ) > 0.009
            }
            let newlyLinkedPaymentAmount = linkedPayments
                .filter { !knownQuickBooksPaymentIDs.contains($0.Id) }
                .reduce(0) {
                    $0 + QuickBooksPaymentAllocation.amountApplied(
                        by: $1,
                        toInvoiceID: quickBooksInvoiceID
                    )
                }

            try QuickBooksLocalSync.importSnapshot(
                customers: [],
                items: [],
                estimates: [],
                invoices: [remoteInvoice],
                payments: linkedPayments,
                vendors: [],
                into: modelContext
            )

            let refreshedPayments = try modelContext.fetch(FetchDescriptor<Payment>())
            let refreshedBalance = Invoice.outstandingBalance(
                for: invoice,
                payments: refreshedPayments
            )
            let outcome = FieldPaymentVerificationOutcome.resolve(
                previousBalance: previousBalance,
                refreshedBalance: refreshedBalance,
                newlyLinkedPaymentAmount: newlyLinkedPaymentAmount
            )
            contactlessGuideMessage = outcome.statusMessage
            if outcome.confirmsCollection {
                fieldPaymentHandoff.end(invoiceID: invoice.id)
            }
        } catch {
            contactlessGuideMessage = "QuickBooks could not be checked. No payment status was changed. Try again, or review this invoice in QuickBooks before collecting again."
        }
    }

    private func fetchQuickBooksInvoiceForContactlessVerification(id: String) async throws -> QuickBooksInvoice {
        try await withCheckedThrowingContinuation { continuation in
            liveAPI.fetchInvoice(id: id) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func fetchQuickBooksPaymentsForContactlessVerification() async throws -> [QuickBooksPayment] {
        try await withCheckedThrowingContinuation { continuation in
            liveAPI.fetchPayments { result in
                continuation.resume(with: result)
            }
        }
    }

    private var paymentConfirmationTitle: String {
        if isProcessingQuickBooksPayment {
            return "Processing..."
        }
        if selectedMethod == .card, quickBooksPaymentsEnabled {
            return "Process Card Payment"
        }
        if selectedMethod == .ach, quickBooksPaymentsEnabled {
            return "Process ACH Payment"
        }
        return "Save Payment"
    }

    private var refundSheet: some View {
        NavigationStack {
            Form {
                Section("Refund") {
                    if let selectedRefundPayment {
                        Text(selectedRefundPayment.invoice.customer.name)
                        Text("Original payment: \(selectedRefundPayment.amount.formatted(.currency(code: "USD")))")
                        Text("Invoice balance after refund: \((outstandingBalance(for: selectedRefundPayment.invoice) + refundAmountValue).formatted(.currency(code: "USD")))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    TextField("Refund amount", text: $refundAmountText)
                        .keyboardType(.decimalPad)
                    TextField("Refund notes", text: $refundNotes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle("Refund Payment")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        resetRefundForm()
                        showingRefundSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isProcessingQuickBooksRefund ? "Refunding..." : "Refund") {
                        Task {
                            await submitRefund()
                        }
                    }
                    .disabled(selectedRefundPayment == nil || refundAmountValue <= 0 || isProcessingQuickBooksRefund)
                }
            }
        }
        .tint(Color.brandGold)
    }

    private var refundAmountValue: Double {
        Double(refundAmountText) ?? 0
    }

    private var paymentFormIsValid: Bool {
        guard let invoice = selectedInvoice,
              let amount = Double(amountText),
              PaymentCollectionGuard.validationMessage(invoice: invoice, amount: amount, payments: payments) == nil else {
            return false
        }
        if selectedMethod == .card, quickBooksPaymentsEnabled {
            return !cardholderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                cardNumber.filter(\.isNumber).count >= 12 &&
                expirationMonth.filter(\.isNumber).count >= 1 &&
                expirationYear.filter(\.isNumber).count == 4 &&
                cardCVC.filter(\.isNumber).count >= 3
        }
        if selectedMethod == .ach, quickBooksPaymentsEnabled {
            return !achAccountHolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                achAccountHolderName.trimmingCharacters(in: .whitespacesAndNewlines).count <= 64 &&
                (4...17).contains(achAccountNumber.filter(\.isNumber).count) &&
                achRoutingNumber.filter(\.isNumber).count == 9 &&
                achPhone.filter(\.isNumber).count == 10
        }
        return true
    }

    private var isQuickBooksConnected: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTestForceQuickBooksConnected") {
            return true
        }
        if ProcessInfo.processInfo.arguments.contains("-uiTestForceQuickBooksDisconnected") {
            return false
        }
        #endif
        return liveAPI.isAuthenticated
    }

    private func preparePaymentForm() {
        if let firstOutstanding = collectibleOutstandingInvoices.first?.invoice {
            preparePaymentForm(for: firstOutstanding)
        }
    }

    private func applyPendingIntentInvoiceIfNeeded() {
        let newlyRequestedRoute = GunnAireAppIntentRouter.consumePendingPaymentCollectionRoute()
        if let newlyRequestedRoute {
            GunnAireAppIntentRouter.storeDeferredPaymentCollectionRoute(
                newlyRequestedRoute.invoiceID,
                ownerEmail: signedInEmail,
                prefersContactlessGuide: newlyRequestedRoute.prefersContactlessGuide,
                expiresAt: newlyRequestedRoute.expiresAt
            )
        }
        let pendingRoute = newlyRequestedRoute ?? GunnAireAppIntentRouter.deferredPaymentCollectionRoute(
            ownerEmail: signedInEmail
        )
        guard let pendingRoute else { return }
        selectedWorkspace = .collect
        deferredCollectionInvoiceID = pendingRoute.invoiceID
        deferredCollectionPrefersContactlessGuide = pendingRoute.prefersContactlessGuide
        deferredCollectionExpiresAt = pendingRoute.expiresAt
        resolveDeferredCollectionRouteIfPossible()
    }

    private func resolveDeferredCollectionRouteIfPossible() {
        guard let invoiceID = deferredCollectionInvoiceID else { return }
        if let deferredCollectionExpiresAt,
           deferredCollectionExpiresAt <= Date() {
            expireDeferredCollectionRoute()
            return
        }
        selectedWorkspace = .collect

        switch FieldCollectionInvoiceRouteResolver.decision(
            invoiceID: invoiceID,
            visibleInvoices: visibleInvoices,
            payments: payments
        ) {
        case .waitingForAuthorizedInvoice:
            actionMessage = "The assigned invoice is not available to this account yet. The handoff is preserved while company sync confirms the job assignment."
        case .waitingForAuthoritativeTotal(let message):
            actionMessage = message
        case .alreadySettled:
            deferredCollectionInvoiceID = nil
            deferredCollectionPrefersContactlessGuide = false
            deferredCollectionExpiresAt = nil
            GunnAireAppIntentRouter.clearDeferredPaymentCollectionRoute()
            actionMessage = "This invoice no longer has an open balance. Refresh payment history before collecting again."
        case .collect:
            guard let invoice = visibleInvoices.first(where: { $0.id == invoiceID }) else { return }
            let presentsContactlessGuide = deferredCollectionPrefersContactlessGuide
            deferredCollectionInvoiceID = nil
            deferredCollectionPrefersContactlessGuide = false
            deferredCollectionExpiresAt = nil
            GunnAireAppIntentRouter.clearDeferredPaymentCollectionRoute()
            withAnimation(GunnAireAccessibilityMotionPolicy.easeInOut(duration: 0.2, reduceMotion: reduceMotion)) {
                preparePaymentForm(for: invoice)
                if presentsContactlessGuide {
                    contactlessGuideMessage = ""
                    showingContactlessPaymentGuide = true
                } else {
                    showingRecordPaymentSheet = true
                }
            }
        }
    }

    private func waitForDeferredCollectionExpiration() async {
        guard let expiresAt = deferredCollectionExpiresAt else { return }
        let remaining = expiresAt.timeIntervalSinceNow
        if remaining > 0 {
            do {
                try await Task.sleep(for: .seconds(remaining))
            } catch {
                return
            }
        }
        guard !Task.isCancelled,
              deferredCollectionExpiresAt == expiresAt else { return }
        expireDeferredCollectionRoute()
    }

    private func expireDeferredCollectionRoute() {
        deferredCollectionInvoiceID = nil
        deferredCollectionPrefersContactlessGuide = false
        deferredCollectionExpiresAt = nil
        GunnAireAppIntentRouter.clearDeferredPaymentCollectionRoute()
        actionMessage = "This nearby-device handoff expired. Send the invoice again, or open its server task in Your Field Collection Tasks."
    }

    private func preparePaymentForm(for invoice: Invoice, preferredMethod: PaymentMethod = .card) {
        guard invoice.isReadyForPaymentCollection else {
            selectedInvoiceID = nil
            amountText = ""
            actionMessage = invoice.paymentCollectionBlockedMessage ?? "This invoice is not ready for collection."
            return
        }
        selectedInvoiceID = invoice.id
        amountText = String(format: "%.2f", outstandingBalance(for: invoice))
        selectedMethod = preferredMethod
        tapToPayMessage = ""
        actionMessage = ""
        cardLast4 = ""
        authorizationReference = ""
        paymentNotes = ""
        cardholderName = invoice.customer.name
        cardNumber = ""
        expirationMonth = ""
        expirationYear = ""
        cardCVC = ""
        billingPostalCode = ""
        achAccountHolderName = invoice.customer.name
        achAccountNumber = ""
        achRoutingNumber = ""
        achPhone = invoice.customer.phone ?? ""
        achCheckNumber = ""
        achAccountType = .businessChecking
    }

    private func prepareRefundForm(for payment: Payment) {
        refundPaymentID = payment.id
        refundAmountText = String(format: "%.2f", payment.amount)
        refundNotes = payment.notes ?? ""
    }

    @discardableResult
    private func saveLocalPayment(
        id: UUID = UUID(),
        invoice: Invoice,
        amount: Double,
        quickBooksPaymentID: String? = nil,
        quickBooksChargeID: String? = nil,
        quickBooksClientTransID: String? = nil,
        quickBooksAccountingSyncStatus: String? = nil,
        quickBooksAccountingSyncDetail: String? = nil,
        processorSyncStatus: String? = nil,
        processorSyncDetail: String? = nil,
        quickBooksDepositID: String? = nil,
        quickBooksSalesReceiptID: String? = nil,
        settlementBatchID: String? = nil,
        storedCardID: String? = nil,
        processorOverride: String? = nil
    ) -> Payment {
        let payment = Payment(
                id: id,
                invoice: invoice,
                quickBooksID: quickBooksPaymentID,
                quickBooksChargeID: quickBooksChargeID,
                quickBooksClientTransID: quickBooksClientTransID,
                quickBooksDepositID: quickBooksDepositID,
                quickBooksSalesReceiptID: quickBooksSalesReceiptID,
                quickBooksAccountingSyncStatus: quickBooksAccountingSyncStatus,
                quickBooksAccountingSyncDetail: quickBooksAccountingSyncDetail,
                processorSyncStatus: processorSyncStatus,
                processorSyncDetail: processorSyncDetail,
                settlementBatchID: settlementBatchID,
                storedCardID: storedCardID,
                amount: amount,
                method: selectedMethod.apiValue,
                cardLast4: cardLast4.nilIfBlank,
                authorizationReference: authorizationReference.nilIfBlank,
                notes: paymentNotes.nilIfBlank,
                processor: processorOverride ?? (selectedMethod == .card ? (authorizationReference.nilIfBlank == nil ? "manual-entry" : selectedProcessor.rawValue) : nil)
        )
        modelContext.insert(payment)
        invoice.applyLocalPaymentAmount(amount)
        return payment
    }

    private func queueFieldPaymentWithBackend(_ payment: Payment) async {
        guard GunnAireBackendService.isConfigured else {
            payment.markSharedCompanyQueueUnavailable()
            backendUploadMessage = "Payment saved locally. Shared company queue is not configured."
            return
        }

        do {
            let upload = try await GunnAireBackendService.uploadPaymentCollection(payment)
            payment.markSharedCompanyQueued()
            if let updates = upload.assignmentUpdates, !updates.isEmpty {
                await refreshFieldPaymentAssignments()
                backendUploadMessage = updates.contains(where: { $0.status == "completed" })
                    ? "Payment queued and the field collection task was completed."
                    : "Payment queued and the field collection task now shows the partial amount."
            } else {
                backendUploadMessage = "Payment queued to shared company storage."
            }
        } catch {
            payment.markSharedCompanyQueueFailed(error.localizedDescription)
            backendUploadMessage = "Payment saved locally, but company queue upload failed: \(error.localizedDescription)"
        }
    }

    private func retryCompanyQueueUploads(_ retryPayments: [Payment]) async {
        guard GunnAireBackendService.isConfigured else {
            backendUploadMessage = "Shared company storage is not configured."
            return
        }

        var queuedCount = 0
        var failedCount = 0
        for payment in retryPayments where payment.needsSharedCompanyQueueUpload {
            syncingPaymentID = payment.id
            await queueFieldPaymentWithBackend(payment)
            if payment.needsSharedCompanyQueueUpload {
                failedCount += 1
            } else {
                queuedCount += 1
            }
        }
        syncingPaymentID = nil

        if failedCount > 0 {
            backendUploadMessage = "Company queue retry uploaded \(queuedCount) payment\(queuedCount == 1 ? "" : "s"); \(failedCount) still need attention."
        } else {
            backendUploadMessage = "Company queue retry uploaded \(queuedCount) payment\(queuedCount == 1 ? "" : "s")."
        }
    }

    private func refreshSharedPaymentCollections() async {
        guard GunnAireBackendService.isConfigured else {
            sharedPaymentCollectionMessage = "Shared company storage is not configured."
            return
        }

        isLoadingSharedPaymentCollections = true
        defer { isLoadingSharedPaymentCollections = false }
        do {
            sharedPaymentCollections = try await GunnAireBackendService.fetchPaymentCollections()
            sharedPaymentCollectionMessage = "Loaded \(sharedPaymentCollections.count) shared field collection\(sharedPaymentCollections.count == 1 ? "" : "s")."
        } catch {
            sharedPaymentCollectionMessage = "Shared field collection refresh failed: \(error.localizedDescription)"
        }
    }

    private func refreshFieldPaymentAssignments() async {
        guard GunnAireBackendService.isConfigured else { return }
        isLoadingFieldPaymentAssignments = true
        defer { isLoadingFieldPaymentAssignments = false }
        do {
            let assignments = try await GunnAireBackendService.fetchFieldPaymentAssignments()
            fieldPaymentAssignments = assignments
            fieldPaymentAssignmentMessage = fieldPaymentAssignments.isEmpty
                ? "No active field collection tasks."
                : "Loaded \(fieldPaymentAssignments.count) field collection assignment\(fieldPaymentAssignments.count == 1 ? "" : "s")."
        } catch {
            fieldPaymentAssignmentMessage = "Field collection task refresh failed: \(error.localizedDescription)"
        }
    }

    private func assignFieldCollection(invoice: Invoice, amount: Double, technicianEmail: String) async {
        if let blockedMessage = invoice.paymentCollectionBlockedMessage {
            actionMessage = blockedMessage
            return
        }
        guard GunnAireBackendService.isConfigured else {
            actionMessage = "Configure shared company storage before assigning a field collection."
            return
        }
        do {
            let assignment = try await GunnAireBackendService.createFieldPaymentAssignment(
                invoice: invoice,
                amount: amount,
                assignedTo: technicianEmail
            )
            await refreshFieldPaymentAssignments()
            actionMessage = "Assigned \(assignment.customerName)'s \(assignment.amount.formatted(.currency(code: "USD"))) collection to \(assignment.assignedTo)."
        } catch {
            actionMessage = "Could not assign field collection: \(error.localizedDescription)"
        }
    }

    private func acceptFieldCollection(_ assignment: BackendFieldPaymentAssignmentRecord) async {
        do {
            _ = try await GunnAireBackendService.acceptFieldPaymentAssignment(id: assignment.id)
            await refreshFieldPaymentAssignments()
            actionMessage = "Field collection accepted."
        } catch {
            actionMessage = "Could not accept field collection: \(error.localizedDescription)"
        }
    }

    private func cancelFieldCollection(_ assignment: BackendFieldPaymentAssignmentRecord) async {
        do {
            _ = try await GunnAireBackendService.cancelFieldPaymentAssignment(id: assignment.id)
            await refreshFieldPaymentAssignments()
            actionMessage = "Field collection cancelled."
        } catch {
            actionMessage = "Could not cancel field collection: \(error.localizedDescription)"
        }
    }

    private func sharedCollectionDetail(for collection: BackendPaymentCollectionRecord) -> String {
        let method = collection.method.capitalized
        let collector = collection.collectedBy?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? collection.collectedBy!
            : "unknown collector"
        let collectedAt = Self.sharedCollectionDateFormatter.string(from: Self.sharedCollectionDate(from: collection.collectedAt))
        return "\(method) by \(collector) on \(collectedAt)"
    }

    private static let sharedCollectionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static func sharedCollectionDate(from value: String) -> Date {
        ISO8601DateFormatter().date(from: value) ?? Date(timeIntervalSince1970: 0)
    }

    private func updateInvoiceStatusAfterPayment(_ invoice: Invoice) {
        let updatedBalance = max(outstandingBalance(for: invoice), 0)
        invoice.status = updatedBalance == 0 ? "paid" : "partial"
    }

    private func quickBooksCardInput(for invoice: Invoice) -> QuickBooksPaymentsCardInput {
        QuickBooksPaymentsCardInput(
            cardholderName: cardholderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? invoice.customer.name : cardholderName.trimmingCharacters(in: .whitespacesAndNewlines),
            cardNumber: cardNumber.filter(\.isNumber),
            expMonth: expirationMonth.filter(\.isNumber),
            expYear: expirationYear.filter(\.isNumber),
            cvc: cardCVC.filter(\.isNumber),
            postalCode: billingPostalCode.nilIfBlank,
            addressLine: invoice.customer.address,
            city: nil,
            region: nil,
            country: "US"
        )
    }

    private func savePaymentRecord() async {
        guard let invoice = selectedInvoice, let amount = Double(amountText), amount > 0 else {
            actionMessage = "Select an invoice and enter a valid payment amount."
            return
        }
        if let issue = PaymentCollectionGuard.validationMessage(invoice: invoice, amount: amount, payments: payments) {
            actionMessage = issue
            return
        }

        if selectedMethod == .card, quickBooksPaymentsEnabled {
            isProcessingQuickBooksPayment = true
            defer { isProcessingQuickBooksPayment = false }

            do {
                let localPaymentID = UUID()
                let result = try await QuickBooksPaymentsService.shared.processCardPayment(
                    localPaymentID: localPaymentID,
                    invoice: invoice,
                    amount: amount,
                    cardInput: quickBooksCardInput(for: invoice),
                    note: paymentNotes.nilIfBlank,
                    catalogItems: catalogItems
                )
                if let masked = result.charge.card?.number?.suffix(4), cardLast4.nilIfBlank == nil {
                    cardLast4 = String(masked)
                }
                authorizationReference = result.charge.authCode ?? authorizationReference
                let payment = saveLocalPayment(
                    id: localPaymentID,
                    invoice: invoice,
                    amount: amount,
                    quickBooksPaymentID: result.accountingPayment?.Id,
                    quickBooksChargeID: result.charge.id,
                    quickBooksClientTransID: result.clientTransactionID,
                    quickBooksAccountingSyncStatus: result.accountingError == nil ? "synced" : "needs_attention",
                    quickBooksAccountingSyncDetail: result.accountingError,
                    processorSyncStatus: "captured",
                    processorSyncDetail: nil,
                    processorOverride: OnsitePaymentProcessor.quickBooksPayments.rawValue
                )
                updateInvoiceStatusAfterPayment(invoice)
                await queueFieldPaymentWithBackend(payment)
                if let accountingError = result.accountingError {
                    actionMessage = "Charge captured in QuickBooks Payments, but accounting sync still needs attention: \(accountingError)"
                } else {
                    actionMessage = "QuickBooks payment processed for \(invoice.customer.name)."
                }
                resetPaymentForm()
                showingRecordPaymentSheet = false
            } catch {
                actionMessage = "QuickBooks payment failed: \(error.localizedDescription)"
            }
            return
        }

        if selectedMethod == .ach, quickBooksPaymentsEnabled {
            isProcessingQuickBooksPayment = true
            defer { isProcessingQuickBooksPayment = false }

            do {
                let localPaymentID = UUID()
                let result = try await QuickBooksPaymentsService.shared.processBankPayment(
                    localPaymentID: localPaymentID,
                    invoice: invoice,
                    amount: amount,
                    bankInput: QuickBooksPaymentsBankAccountInput(
                        accountHolderName: achAccountHolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? invoice.customer.name : achAccountHolderName.trimmingCharacters(in: .whitespacesAndNewlines),
                        accountNumber: achAccountNumber.filter(\.isNumber),
                        routingNumber: achRoutingNumber.filter(\.isNumber),
                        phone: achPhone.filter(\.isNumber),
                        accountType: achAccountType,
                        checkNumber: achCheckNumber.nilIfBlank
                    ),
                    note: paymentNotes.nilIfBlank,
                    catalogItems: catalogItems
                )
                authorizationReference = result.charge.authCode ?? authorizationReference
                let payment = saveLocalPayment(
                    id: localPaymentID,
                    invoice: invoice,
                    amount: amount,
                    quickBooksPaymentID: result.accountingPayment?.Id,
                    quickBooksChargeID: result.charge.id,
                    quickBooksClientTransID: result.clientTransactionID,
                    quickBooksAccountingSyncStatus: result.accountingError == nil ? "synced" : "needs_attention",
                    quickBooksAccountingSyncDetail: result.accountingError,
                    processorSyncStatus: "submitted",
                    processorSyncDetail: nil,
                    processorOverride: OnsitePaymentProcessor.quickBooksPayments.rawValue
                )
                updateInvoiceStatusAfterPayment(invoice)
                await queueFieldPaymentWithBackend(payment)
                if let accountingError = result.accountingError {
                    actionMessage = "ACH payment submitted, but accounting sync still needs attention: \(accountingError)"
                } else {
                    actionMessage = "QuickBooks ACH payment processed for \(invoice.customer.name)."
                }
                resetPaymentForm()
                showingRecordPaymentSheet = false
            } catch {
                actionMessage = "QuickBooks ACH payment failed: \(error.localizedDescription)"
            }
            return
        }

        let payment = saveLocalPayment(
            invoice: invoice,
            amount: amount,
            quickBooksAccountingSyncStatus: isQuickBooksConnected ? "pending" : nil,
            processorSyncStatus: "recorded"
        )
        updateInvoiceStatusAfterPayment(invoice)
        await queueFieldPaymentWithBackend(payment)
        actionMessage = "Payment recorded for \(invoice.customer.name)."
        resetPaymentForm()
        showingRecordPaymentSheet = false
    }

    private func runTapToPay() async {
        guard let invoice = selectedInvoice else {
            tapToPayMessage = "Select an invoice before starting Tap to Pay on iPhone."
            return
        }
        guard let amount = Double(amountText), amount > 0 else {
            tapToPayMessage = "Enter a valid amount before starting Tap to Pay on iPhone."
            return
        }
        if let issue = PaymentCollectionGuard.validationMessage(invoice: invoice, amount: amount, payments: payments) {
            tapToPayMessage = issue
            return
        }

        do {
            let result = try await onsitePaymentManager.startTapToPay(amount: amount, customerName: invoice.customer.name)
            cardLast4 = result.cardLast4
            authorizationReference = result.authorizationCode
            paymentNotes = result.paymentSummary
            tapToPayMessage = "\(result.processorName) approved \(result.amount.formatted(.currency(code: "USD")))."
        } catch {
            tapToPayMessage = error.localizedDescription
        }
    }

    private func outstandingBalance(for invoice: Invoice) -> Double {
        Invoice.outstandingBalance(for: invoice, payments: payments)
    }

    private func isOverdue(_ invoice: Invoice) -> Bool {
        Invoice.isOverdue(invoice, payments: payments)
    }

    private func balanceStatusLabel(for invoice: Invoice, balanceDue: Double) -> String {
        if balanceDue <= 0 || Invoice.isPaid(invoice, payments: payments) {
            return "Paid"
        }
        if balanceDue < invoice.amount {
            return "Partial"
        }
        return "Open"
    }

    private func serviceCall(for invoice: Invoice) -> ServiceCall? {
        guard let serviceCallID = invoice.serviceCallID else { return nil }
        return invoice.customer.serviceCalls.first(where: { $0.id == serviceCallID })
    }

    private func customerPhoneURL(for invoice: Invoice) -> URL? {
        guard let phone = invoice.customer.phone?.trimmingCharacters(in: .whitespacesAndNewlines),
              !phone.isEmpty else { return nil }
        let digits = phone.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        return URL(string: "tel://\(digits)")
    }

    private func reminderEmailURL(for invoice: Invoice, balanceDue: Double) -> URL? {
        guard let draft = reminderEmailDraft(for: invoice, balanceDue: balanceDue) else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = draft.to
        components.queryItems = [
            URLQueryItem(name: "subject", value: draft.subject),
            URLQueryItem(name: "body", value: draft.body)
        ]
        return components.url
    }

    private func reminderEmailDraft(for invoice: Invoice, balanceDue: Double) -> (to: String, subject: String, body: String)? {
        guard let email = invoice.customer.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else { return nil }
        return (
            to: email,
            subject: "Invoice Balance Due - \(invoiceReference(for: invoice))",
            body: """
Hello \(invoice.customer.name),

This is a reminder that your current invoice balance is \(balanceDue.formatted(.currency(code: "USD"))).

Invoice reference: \(invoiceReference(for: invoice))
Due date: \(invoice.effectiveDueDate().formatted(date: .long, time: .omitted))

Thank you,
GunnAire
"""
        )
    }

    private func receiptEmailURL(for payment: Payment) -> URL? {
        guard let draft = receiptEmailDraft(for: payment) else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = draft.to
        components.queryItems = [
            URLQueryItem(name: "subject", value: draft.subject),
            URLQueryItem(name: "body", value: draft.body)
        ]
        return components.url
    }

    private func receiptEmailDraft(for payment: Payment) -> (to: String, subject: String, body: String)? {
        guard let email = payment.invoice.customer.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else { return nil }
        let remainingBalance = outstandingBalance(for: payment.invoice)
        return (
            to: email,
            subject: "Payment Receipt - \(invoiceReference(for: payment.invoice))",
            body: """
Hello \(payment.invoice.customer.name),

We received your payment of \(payment.amount.formatted(.currency(code: "USD"))) on \(payment.date.formatted(date: .abbreviated, time: .shortened)).

Payment method: \(payment.methodSummary)
Remaining balance: \(remainingBalance.formatted(.currency(code: "USD")))

Thank you,
GunnAire
"""
        )
    }

    private func openReminderEmail(for invoice: Invoice, balanceDue: Double, fallbackURL: URL) {
        if googleAuth.isAuthenticated, let draft = reminderEmailDraft(for: invoice, balanceDue: balanceDue) {
            GunnAireAppIntentRouter.storeMailDraftRoute(
                to: draft.to,
                subject: draft.subject,
                body: draft.body,
                customerID: invoice.customer.id,
                serviceCallID: invoice.serviceCallID,
                invoiceID: invoice.id,
                workflow: .paymentReminder
            )
        } else {
            openURL(fallbackURL)
        }
    }

    private func openReceiptEmail(for payment: Payment, fallbackURL: URL) {
        if googleAuth.isAuthenticated, let draft = receiptEmailDraft(for: payment) {
            GunnAireAppIntentRouter.storeMailDraftRoute(
                to: draft.to,
                subject: draft.subject,
                body: draft.body,
                customerID: payment.invoice.customer.id,
                serviceCallID: payment.invoice.serviceCallID,
                invoiceID: payment.invoice.id,
                workflow: .receipt
            )
        } else {
            openURL(fallbackURL)
        }
    }

    private func invoiceReference(for invoice: Invoice) -> String {
        if let quickBooksID = invoice.quickBooksID, !quickBooksID.isEmpty {
            return quickBooksID
        }
        return String(invoice.id.uuidString.prefix(8))
    }

    private func syncPaymentToQuickBooks(_ payment: Payment) {
        guard isQuickBooksConnected else {
            actionMessage = "Connect QuickBooks before syncing payments."
            return
        }
        guard let customerID = payment.invoice.customer.quickBooksID, !customerID.isEmpty else {
            actionMessage = "This customer needs a QuickBooks customer ID before the payment can sync."
            return
        }
        guard payment.invoice.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            actionMessage = "Sync this invoice to QuickBooks before syncing its payment. This prevents unapplied payments and duplicate sales receipts."
            return
        }

        syncingPaymentID = payment.id
        Task {
            do {
                let quickBooksPayment = try await QuickBooksPaymentsService.shared.syncManualAccountingPayment(for: payment)
                await MainActor.run {
                    syncingPaymentID = nil
                    payment.quickBooksID = quickBooksPayment.Id
                    payment.quickBooksAccountingSyncStatus = "synced"
                    payment.quickBooksAccountingSyncDetail = nil
                    actionMessage = "Payment synced to QuickBooks: \(quickBooksPayment.Id)."
                }
            } catch {
                await MainActor.run {
                    syncingPaymentID = nil
                    payment.quickBooksAccountingSyncStatus = "needs_attention"
                    payment.quickBooksAccountingSyncDetail = error.localizedDescription
                    actionMessage = "QuickBooks payment sync failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func retryQuickBooksFollowUp(for payment: Payment) {
        guard isQuickBooksConnected else {
            actionMessage = "Connect QuickBooks before retrying QuickBooks follow-up."
            return
        }

        syncingPaymentID = payment.id
        Task {
            do {
                if payment.isRefund {
                    let receipt = try await QuickBooksPaymentsService.shared.retryRefundReceiptSync(for: payment)
                    await MainActor.run {
                        payment.quickBooksRefundReceiptID = receipt.Id
                        payment.quickBooksAccountingSyncStatus = "synced"
                        payment.quickBooksAccountingSyncDetail = nil
                        syncingPaymentID = nil
                        actionMessage = "QuickBooks refund receipt sync completed."
                    }
                } else {
                    let accountingPayment = try await QuickBooksPaymentsService.shared.retryAccountingSync(for: payment)
                    await MainActor.run {
                        payment.quickBooksID = accountingPayment.Id
                        payment.quickBooksAccountingSyncStatus = "synced"
                        payment.quickBooksAccountingSyncDetail = nil
                        syncingPaymentID = nil
                        actionMessage = "QuickBooks accounting payment sync completed."
                    }
                }
            } catch {
                await MainActor.run {
                    payment.quickBooksAccountingSyncStatus = "needs_attention"
                    payment.quickBooksAccountingSyncDetail = error.localizedDescription
                    syncingPaymentID = nil
                    actionMessage = "QuickBooks follow-up retry failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func loadQuickBooksPaymentReceipt(for payment: Payment) {
        guard let chargeID = payment.quickBooksChargeID?.trimmingCharacters(in: .whitespacesAndNewlines), !chargeID.isEmpty else {
            actionMessage = "This payment does not have a QuickBooks charge ID."
            return
        }
        guard quickBooksPaymentsEnabled else {
            actionMessage = quickBooksPaymentsUnavailableMessage
            return
        }

        syncingPaymentID = payment.id
        liveAPI.fetchPaymentReceipt(id: chargeID) { result in
            DispatchQueue.main.async {
                syncingPaymentID = nil
                switch result {
                case .success(let receipt):
                    quickBooksPaymentReceipts[chargeID] = receipt
                    actionMessage = "QuickBooks payment receipt loaded."
                case .failure(let error):
                    actionMessage = "QuickBooks payment receipt lookup failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func resetPaymentForm() {
        selectedInvoiceID = nil
        amountText = ""
        selectedMethod = .card
        cardLast4 = ""
        authorizationReference = ""
        paymentNotes = ""
        tapToPayMessage = ""
        cardholderName = ""
        cardNumber = ""
        expirationMonth = ""
        expirationYear = ""
        cardCVC = ""
        billingPostalCode = ""
        achAccountHolderName = ""
        achAccountNumber = ""
        achRoutingNumber = ""
        achPhone = ""
        achCheckNumber = ""
        achAccountType = .businessChecking
    }

    private func resetRefundForm() {
        refundPaymentID = nil
        refundAmountText = ""
        refundNotes = ""
    }

    private func submitRefund() async {
        guard let payment = selectedRefundPayment, refundAmountValue > 0 else {
            return
        }
        guard quickBooksPaymentsEnabled else {
            actionMessage = quickBooksPaymentsUnavailableMessage
            return
        }

        isProcessingQuickBooksRefund = true
        defer { isProcessingQuickBooksRefund = false }

        do {
            let result = try await QuickBooksPaymentsService.shared.refundPayment(
                payment: payment,
                amount: refundAmountValue,
                note: refundNotes.nilIfBlank
            )

            modelContext.insert(
                Payment(
                    invoice: payment.invoice,
                    quickBooksChargeID: result.refund.id,
                    quickBooksClientTransID: result.clientTransactionID,
                    quickBooksRefundReceiptID: result.refundReceipt?.Id,
                    quickBooksAccountingSyncStatus: result.accountingError == nil ? "synced" : "needs_attention",
                    quickBooksAccountingSyncDetail: result.accountingError,
                    processorSyncStatus: "refunded",
                    processorSyncDetail: nil,
                    amount: -abs(refundAmountValue),
                    method: payment.method,
                    cardLast4: payment.cardLast4,
                    authorizationReference: result.refund.id,
                    notes: refundNotes.nilIfBlank,
                    processor: OnsitePaymentProcessor.quickBooksPayments.rawValue,
                    isRefund: true,
                    refundedPaymentID: payment.id
                )
            )
            payment.invoice.applyLocalPaymentAmount(refundAmountValue, isRefund: true)
            payment.invoice.status = outstandingBalance(for: payment.invoice) > 0 ? "partial" : "paid"
            if let accountingError = result.accountingError {
                actionMessage = "Refund issued, but refund receipt sync still needs attention: \(accountingError)"
            } else {
                actionMessage = "Refund recorded for \(payment.invoice.customer.name)."
            }
            resetRefundForm()
            showingRefundSheet = false
        } catch {
            actionMessage = "Refund failed: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private func metricRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundColor(Color.brandGold)
        }
    }
}

enum PaymentsWorkspace: String, CaseIterable, Identifiable {
    case overview
    case collect
    case history

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview: "Overview"
        case .collect: "Collect"
        case .history: "History"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"
        case .collect: "dollarsign.arrow.circlepath"
        case .history: "clock.arrow.circlepath"
        }
    }

    var guidance: String {
        switch self {
        case .overview:
            "Review outstanding balances, overdue work, collection totals, and payment readiness."
        case .collect:
            "Work assigned field tasks, open unpaid invoices, and start a guarded collection."
        case .history:
            "Review payment records, company uploads, receipts, refunds, and QuickBooks follow-up."
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#Preview {
    PaymentsAndReceiptsView()
}
