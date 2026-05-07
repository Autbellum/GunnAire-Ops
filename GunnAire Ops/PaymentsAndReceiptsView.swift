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
    @State private var selectedInvoiceID: UUID?
    @State private var amountText = ""
    @State private var selectedMethod: PaymentMethod = .card
    @State private var cardLast4 = ""
    @State private var authorizationReference = ""
    @State private var paymentNotes = ""
    @State private var tapToPayMessage = ""
    @State private var actionMessage = ""
    @State private var syncingPaymentID: UUID?

    private let liveAPI = QuickBooksDataAPI.shared

    private var selectedInvoice: Invoice? {
        guard let selectedInvoiceID else { return nil }
        return invoices.first { $0.id == selectedInvoiceID }
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
                                        Text(payment.quickBooksID == nil ? "Not synced to QuickBooks" : "QuickBooks ID: \(payment.quickBooksID ?? "")")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        Button(syncingPaymentID == payment.id ? "Syncing..." : "Sync") {
                                            syncPaymentToQuickBooks(payment)
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(payment.quickBooksID != nil || syncingPaymentID != nil || !isQuickBooksConnected)
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
                                    if let processorDisplayName = payment.processorDisplayName {
                                        Text("Processor: \(processorDisplayName)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    if let notes = payment.notes, !notes.isEmpty {
                                        Text(notes)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
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

                        TextField("Card last 4", text: $cardLast4)
                            .keyboardType(.numberPad)
                        TextField("Authorization ref", text: $authorizationReference)
                    }

                    TextField("Payment notes", text: $paymentNotes, axis: .vertical)
                        .lineLimit(2...4)

                    if selectedMethod == .card, enableOnsitePayments, OnsitePaymentManager.shared.tapToPayAvailableInCurrentBuild {
                        Text(onsitePaymentManager.processorStatusDetail())
                            .font(.caption)
                            .foregroundColor(.secondary)
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
                    Button("Save") {
                        savePaymentRecord()
                    }
                    .disabled(selectedInvoice == nil || Double(amountText) == nil)
                }
            }
        }
        .tint(Color.brandGold)
    }

    private var isQuickBooksConnected: Bool {
        liveAPI.tokens != nil && liveAPI.realmID != nil
    }

    private func preparePaymentForm() {
        if let firstUnpaid = invoices.first(where: { $0.status != "paid" }) ?? invoices.first {
            preparePaymentForm(for: firstUnpaid)
        }
    }

    private func preparePaymentForm(for invoice: Invoice, preferredMethod: PaymentMethod = .card) {
        selectedInvoiceID = invoice.id
        amountText = String(format: "%.2f", outstandingBalance(for: invoice))
        selectedMethod = preferredMethod
        tapToPayMessage = ""
        cardLast4 = ""
        authorizationReference = ""
        paymentNotes = ""
    }

    private func savePaymentRecord() {
        guard let invoice = selectedInvoice, let amount = Double(amountText), amount > 0 else {
            return
        }
        modelContext.insert(
            Payment(
                invoice: invoice,
                amount: amount,
                method: selectedMethod.apiValue,
                cardLast4: cardLast4.nilIfBlank,
                authorizationReference: authorizationReference.nilIfBlank,
                notes: paymentNotes.nilIfBlank,
                processor: selectedMethod == .card ? (authorizationReference.nilIfBlank == nil ? "manual-entry" : selectedProcessor.rawValue) : nil
            )
        )
        let updatedBalance = max(outstandingBalance(for: invoice) - amount, 0)
        invoice.status = updatedBalance == 0 ? "paid" : "partial"
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
        // Build payment lines linking to the invoice in QuickBooks when available
        let paymentLines: [QuickBooksPaymentLine]?
        if let invoiceQBID = payment.invoice.quickBooksID, !invoiceQBID.isEmpty {
            paymentLines = [
                QuickBooksPaymentLine(
                    Amount: payment.amount,
                    LinkedTxn: [QuickBooksLinkedTxn(TxnId: invoiceQBID, TxnType: "Invoice")]
                )
            ]
        } else {
            // No QuickBooks invoice ID; create an unapplied payment linked only to the customer
            paymentLines = nil
        }
        let payload = QuickBooksPaymentCreate(
            CustomerRef: QuickBooksReference(value: customerID, name: payment.invoice.customer.name),
            TotalAmt: payment.amount,
            PrivateNote: nil,
            PaymentRefNum: "Payment for invoice #\(payment.invoice.id.uuidString.prefix(8)) from \(payment.invoice.customer.name)",
            Line: paymentLines
        )
        liveAPI.createPayment(payload) { result in
            DispatchQueue.main.async {
                syncingPaymentID = nil
                switch result {
                case .success(let quickBooksPayment):
                    payment.quickBooksID = quickBooksPayment.Id
                    actionMessage = "Payment synced to QuickBooks: \(quickBooksPayment.Id)."
                case .failure(let error):
                    actionMessage = "QuickBooks payment sync failed: \(error.localizedDescription)"
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
