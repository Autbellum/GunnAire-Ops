import SwiftUI
import SwiftData

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
    @AppStorage("enableOnsitePayments") private var enableOnsitePayments = false
    @AppStorage("onsitePaymentProcessor") private var onsitePaymentProcessor = OnsitePaymentProcessor.none.rawValue
    @Query(sort: \Invoice.createdAt, order: .reverse) private var invoices: [Invoice]
    @Query(sort: \Payment.date, order: .reverse) private var payments: [Payment]

    @StateObject private var onsitePaymentManager = OnsitePaymentManager.shared
    @State private var showingRecordPaymentSheet = false
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
    @State private var actionMessage = ""
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
    @State private var didLoadPendingIntentInvoice = false
    @State private var quickBooksPaymentReceipts: [String: QuickBooksPaymentsPaymentReceipt] = [:]

    private let liveAPI = QuickBooksDataAPI.shared

    private var selectedInvoice: Invoice? {
        guard let selectedInvoiceID else { return nil }
        return invoices.first { $0.id == selectedInvoiceID }
    }

    private var selectedRefundPayment: Payment? {
        guard let refundPaymentID else { return nil }
        return payments.first { $0.id == refundPaymentID }
    }

    private var selectedProcessor: OnsitePaymentProcessor {
        OnsitePaymentProcessor(rawValue: onsitePaymentProcessor) ?? .none
    }

    private var processorIsReady: Bool {
        enableOnsitePayments && selectedProcessor.supportsTapToPay && onsitePaymentManager.processorReady()
    }

    private var outstandingInvoices: [(invoice: Invoice, balanceDue: Double)] {
        invoices
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

    private var overdueInvoiceCount: Int {
        outstandingInvoices.filter { isOverdue($0.invoice) }.count
    }

    private var collectedToday: Double {
        let calendar = Calendar.current
        return payments
            .filter { calendar.isDateInToday($0.date) }
            .reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        ZStack {
            WatermarkBackground()
            NavigationStack {
                List {
                    Section("Collections Dashboard") {
                        metricRow(title: "Outstanding Balance", value: totalOutstandingBalance.formatted(.currency(code: "USD")))
                        metricRow(title: "Overdue Invoices", value: "\(overdueInvoiceCount)")
                        metricRow(title: "Collected Today", value: collectedToday.formatted(.currency(code: "USD")))
                    }

                    Section("Payment Status") {
                        Text("QuickBooks: \(isQuickBooksConnected ? "Connected" : "Not Connected")")
                            .foregroundColor(isQuickBooksConnected ? .green : .secondary)
                        if OnsitePaymentManager.shared.tapToPayAvailableInCurrentBuild {
                            Text("Tap to Pay: \(processorIsReady ? selectedProcessor.displayName : "Not Ready")")
                                .foregroundColor(processorIsReady ? .green : .secondary)
                            Text(onsitePaymentManager.processorStatusDetail())
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Card, check, and cash payments can still be recorded from this screen.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
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
                                            Text(isOverdue(entry.invoice) ? "Overdue follow-up needed" : "Awaiting collection")
                                                .font(.caption2)
                                                .foregroundColor(isOverdue(entry.invoice) ? .red : .secondary)
                                        }
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 4) {
                                            Text(entry.balanceDue, format: .currency(code: "USD"))
                                                .font(.headline)
                                            Text(entry.invoice.status.capitalized)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }

                                    HStack {
                                        Button("Collect") {
                                            preparePaymentForm(for: entry.invoice)
                                            showingRecordPaymentSheet = true
                                        }
                                        .buttonStyle(.bordered)

                                        if processorIsReady {
                                            Button("Tap to Pay") {
                                                preparePaymentForm(for: entry.invoice, preferredMethod: .card)
                                                showingRecordPaymentSheet = true
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .tint(Color.brandGold)
                                            .foregroundStyle(Color.primaryBlack)
                                        }
                                    }

                                    HStack {
                                        if let phoneURL = customerPhoneURL(for: entry.invoice) {
                                            Button("Call") {
                                                openURL(phoneURL)
                                            }
                                            .buttonStyle(.bordered)
                                        }

                                        if let reminderURL = reminderEmailURL(for: entry.invoice, balanceDue: entry.balanceDue) {
                                            Button("Email Reminder") {
                                                openURL(reminderURL)
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
                        .disabled(invoices.isEmpty)

                        if invoices.isEmpty {
                            Text("Create an invoice before recording a payment.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if !actionMessage.isEmpty {
                            Text(actionMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Section("Payments") {
                        if payments.isEmpty {
                            Text("No payments recorded yet.")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(payments) { payment in
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
                                    if let processorDisplayName = payment.processorDisplayName {
                                        Text("Processor: \(processorDisplayName)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    if payment.needsQuickBooksAttention,
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
                                        if let receiptURL = receiptEmailURL(for: payment) {
                                            Button("Send Receipt") {
                                                openURL(receiptURL)
                                            }
                                            .buttonStyle(.bordered)
                                        }

                                        if let phoneURL = customerPhoneURL(for: payment.invoice) {
                                            Button("Call Customer") {
                                                openURL(phoneURL)
                                            }
                                            .buttonStyle(.bordered)
                                        }

                                        if payment.quickBooksChargeID?.isEmpty == false,
                                           !payment.isRefund,
                                           payment.amount > 0 {
                                            Button("Refund") {
                                                prepareRefundForm(for: payment)
                                                showingRefundSheet = true
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .tint(.red)
                                        }

                                        if payment.quickBooksChargeID?.isEmpty == false,
                                           quickBooksPaymentReceipts[payment.quickBooksChargeID ?? ""] == nil {
                                            Button("Load QB Receipt") {
                                                loadQuickBooksPaymentReceipt(for: payment)
                                            }
                                            .buttonStyle(.bordered)
                                            .disabled(syncingPaymentID != nil || !isQuickBooksConnected)
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
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
        .sheet(isPresented: $showingRefundSheet) {
            refundSheet
        }
        .onAppear(perform: applyPendingIntentInvoiceIfNeeded)
    }

    private var paymentSheet: some View {
        NavigationStack {
            Form {
                Section("Payment Details") {
                    Picker("Invoice", selection: $selectedInvoiceID) {
                        Text("Select Invoice").tag(UUID?.none)
                        ForEach(invoices) { invoice in
                            Text("\(invoice.customer.name) - \(invoice.amount, format: .currency(code: "USD"))")
                                .tag(UUID?.some(invoice.id))
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
                            Button(onsitePaymentManager.isProcessing ? "Processing Tap to Pay..." : "Start Tap to Pay") {
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

                        if isQuickBooksConnected {
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
                            TextField("Authorization ref", text: $authorizationReference)
                            Text("QuickBooks Payments is not connected. This card entry will only record a manual payment note.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    if selectedMethod == .ach, isQuickBooksConnected {
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

    private var paymentConfirmationTitle: String {
        if isProcessingQuickBooksPayment {
            return "Processing..."
        }
        if selectedMethod == .card, isQuickBooksConnected {
            return "Process Card Payment"
        }
        if selectedMethod == .ach, isQuickBooksConnected {
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
        guard Double(amountText) != nil else { return false }
        if selectedMethod == .card, isQuickBooksConnected {
            return !cardholderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                cardNumber.filter(\.isNumber).count >= 12 &&
                expirationMonth.filter(\.isNumber).count >= 1 &&
                expirationYear.filter(\.isNumber).count == 4 &&
                cardCVC.filter(\.isNumber).count >= 3
        }
        if selectedMethod == .ach, isQuickBooksConnected {
            return !achAccountHolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                achAccountNumber.filter(\.isNumber).count >= 4 &&
                achRoutingNumber.filter(\.isNumber).count == 9 &&
                achPhone.filter(\.isNumber).count >= 10
        }
        return true
    }

    private var isQuickBooksConnected: Bool {
        liveAPI.tokens != nil && liveAPI.realmID != nil
    }

    private func preparePaymentForm() {
        if let firstUnpaid = invoices.first(where: { $0.status != "paid" }) ?? invoices.first {
            preparePaymentForm(for: firstUnpaid)
        }
    }

    private func applyPendingIntentInvoiceIfNeeded() {
        guard !didLoadPendingIntentInvoice else { return }
        didLoadPendingIntentInvoice = true
        guard let pendingInvoiceID = GunnAireAppIntentRouter.consumePendingInvoiceCollectionID(),
              let invoice = invoices.first(where: { $0.id == pendingInvoiceID }) else {
            return
        }
        preparePaymentForm(for: invoice)
        showingRecordPaymentSheet = true
    }

    private func preparePaymentForm(for invoice: Invoice, preferredMethod: PaymentMethod = .card) {
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

    private func saveLocalPayment(
        invoice: Invoice,
        amount: Double,
        quickBooksPaymentID: String? = nil,
        quickBooksChargeID: String? = nil,
        quickBooksClientTransID: String? = nil,
        quickBooksAccountingSyncStatus: String? = nil,
        quickBooksAccountingSyncDetail: String? = nil,
        processorOverride: String? = nil
    ) {
        modelContext.insert(
            Payment(
                invoice: invoice,
                quickBooksID: quickBooksPaymentID,
                quickBooksChargeID: quickBooksChargeID,
                quickBooksClientTransID: quickBooksClientTransID,
                quickBooksAccountingSyncStatus: quickBooksAccountingSyncStatus,
                quickBooksAccountingSyncDetail: quickBooksAccountingSyncDetail,
                amount: amount,
                method: selectedMethod.apiValue,
                cardLast4: cardLast4.nilIfBlank,
                authorizationReference: authorizationReference.nilIfBlank,
                notes: paymentNotes.nilIfBlank,
                processor: processorOverride ?? (selectedMethod == .card ? (authorizationReference.nilIfBlank == nil ? "manual-entry" : selectedProcessor.rawValue) : nil)
            )
        )
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

        if selectedMethod == .card, isQuickBooksConnected {
            isProcessingQuickBooksPayment = true
            defer { isProcessingQuickBooksPayment = false }

            do {
                let result = try await QuickBooksPaymentsService.shared.processCardPayment(
                    invoice: invoice,
                    amount: amount,
                    cardInput: quickBooksCardInput(for: invoice),
                    note: paymentNotes.nilIfBlank
                )
                if let masked = result.charge.card?.number?.suffix(4), cardLast4.nilIfBlank == nil {
                    cardLast4 = String(masked)
                }
                authorizationReference = result.charge.authCode ?? authorizationReference
                saveLocalPayment(
                    invoice: invoice,
                    amount: amount,
                    quickBooksPaymentID: result.accountingPayment?.Id,
                    quickBooksChargeID: result.charge.id,
                    quickBooksClientTransID: result.clientTransactionID,
                    quickBooksAccountingSyncStatus: result.accountingError == nil ? "synced" : "needs_attention",
                    quickBooksAccountingSyncDetail: result.accountingError,
                    processorOverride: OnsitePaymentProcessor.quickBooksPayments.rawValue
                )
                updateInvoiceStatusAfterPayment(invoice)
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

        if selectedMethod == .ach, isQuickBooksConnected {
            isProcessingQuickBooksPayment = true
            defer { isProcessingQuickBooksPayment = false }

            do {
                let result = try await QuickBooksPaymentsService.shared.processBankPayment(
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
                    note: paymentNotes.nilIfBlank
                )
                authorizationReference = result.charge.authCode ?? authorizationReference
                saveLocalPayment(
                    invoice: invoice,
                    amount: amount,
                    quickBooksPaymentID: result.accountingPayment?.Id,
                    quickBooksChargeID: result.charge.id,
                    quickBooksClientTransID: result.clientTransactionID,
                    quickBooksAccountingSyncStatus: result.accountingError == nil ? "synced" : "needs_attention",
                    quickBooksAccountingSyncDetail: result.accountingError,
                    processorOverride: OnsitePaymentProcessor.quickBooksPayments.rawValue
                )
                updateInvoiceStatusAfterPayment(invoice)
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

        saveLocalPayment(invoice: invoice, amount: amount)
        updateInvoiceStatusAfterPayment(invoice)
        actionMessage = "Payment recorded for \(invoice.customer.name)."
        resetPaymentForm()
        showingRecordPaymentSheet = false
    }

    private func runTapToPay() async {
        guard let invoice = selectedInvoice else {
            tapToPayMessage = "Select an invoice before starting Tap to Pay."
            return
        }
        guard let amount = Double(amountText), amount > 0 else {
            tapToPayMessage = "Enter a valid amount before starting Tap to Pay."
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
        let paid = payments
            .filter { $0.invoice.id == invoice.id }
            .reduce(0) { $0 + $1.amount }
        return max(invoice.amount - paid, 0)
    }

    private func isOverdue(_ invoice: Invoice) -> Bool {
        guard outstandingBalance(for: invoice) > 0 else { return false }
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) else { return false }
        return invoice.createdAt < cutoff
    }

    private func customerPhoneURL(for invoice: Invoice) -> URL? {
        guard let phone = invoice.customer.phone?.trimmingCharacters(in: .whitespacesAndNewlines),
              !phone.isEmpty else { return nil }
        let digits = phone.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        return URL(string: "tel://\(digits)")
    }

    private func reminderEmailURL(for invoice: Invoice, balanceDue: Double) -> URL? {
        guard let email = invoice.customer.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Invoice Balance Due - \(invoiceReference(for: invoice))"),
            URLQueryItem(name: "body", value: """
Hello \(invoice.customer.name),

This is a reminder that your current invoice balance is \(balanceDue.formatted(.currency(code: "USD"))).

Invoice reference: \(invoiceReference(for: invoice))

Thank you,
GunnAire
""")
        ]
        return components.url
    }

    private func receiptEmailURL(for payment: Payment) -> URL? {
        guard let email = payment.invoice.customer.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else { return nil }
        let remainingBalance = outstandingBalance(for: payment.invoice)
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Payment Receipt - \(invoiceReference(for: payment.invoice))"),
            URLQueryItem(name: "body", value: """
Hello \(payment.invoice.customer.name),

We received your payment of \(payment.amount.formatted(.currency(code: "USD"))) on \(payment.date.formatted(date: .abbreviated, time: .shortened)).

Payment method: \(payment.methodSummary)
Remaining balance: \(remainingBalance.formatted(.currency(code: "USD")))

Thank you,
GunnAire
""")
        ]
        return components.url
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

        syncingPaymentID = payment.id
        Task {
            do {
                let quickBooksPayment = try await QuickBooksPaymentsService.shared.syncManualAccountingPayment(for: payment)
                await MainActor.run {
                    syncingPaymentID = nil
                    payment.quickBooksID = quickBooksPayment.Id
                    actionMessage = "Payment synced to QuickBooks: \(quickBooksPayment.Id)."
                }
            } catch {
                await MainActor.run {
                    syncingPaymentID = nil
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
        guard isQuickBooksConnected else {
            actionMessage = "Connect QuickBooks before loading the payment receipt."
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
                    amount: -refundAmountValue,
                    method: payment.method,
                    cardLast4: payment.cardLast4,
                    authorizationReference: result.refund.id,
                    notes: refundNotes.nilIfBlank,
                    processor: OnsitePaymentProcessor.quickBooksPayments.rawValue,
                    isRefund: true,
                    refundedPaymentID: payment.id
                )
            )
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

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#Preview {
    PaymentsAndReceiptsView()
}
