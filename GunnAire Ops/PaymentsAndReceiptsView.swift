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
    @Query(sort: \Invoice.createdAt, order: .reverse) private var invoices: [Invoice]
    @Query(sort: \Payment.date, order: .reverse) private var payments: [Payment]

    @State private var showingRecordPaymentSheet = false
    @State private var selectedInvoiceID: UUID?
    @State private var amountText = ""
    @State private var selectedMethod: PaymentMethod = .card
    @State private var cardLast4 = ""
    @State private var authorizationReference = ""
    @State private var paymentNotes = ""
    @State private var actionMessage = ""
    @State private var syncingPaymentID: UUID?

    private let liveAPI = QuickBooksDataAPI.shared

    private var selectedInvoice: Invoice? {
        guard let selectedInvoiceID else { return nil }
        return invoices.first { $0.id == selectedInvoiceID }
    }

    var body: some View {
        ZStack {
            WatermarkBackground()
            NavigationStack {
                List {
                    Section("Payment Status") {
                        Text("QuickBooks: \(isQuickBooksConnected ? "Connected" : "Not Connected")")
                            .foregroundColor(isQuickBooksConnected ? .green : .secondary)
                        Text("The QuickBooks Online accounting API records payments against customers and invoices. It does not run card-present Tap to Pay on this device.")
                            .font(.caption)
                            .foregroundColor(.secondary)
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
                                            Text("\(payment.method.capitalized) - \(payment.date.formatted(date: .abbreviated, time: .shortened))")
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
                                    if let notes = payment.notes, !notes.isEmpty {
                                        Text(notes)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
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
                        TextField("Card last 4", text: $cardLast4)
                            .keyboardType(.numberPad)
                        TextField("Authorization ref", text: $authorizationReference)
                    }

                    TextField("Payment notes", text: $paymentNotes, axis: .vertical)
                        .lineLimit(2...4)
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
            selectedInvoiceID = firstUnpaid.id
            amountText = String(format: "%.2f", firstUnpaid.amount)
        }
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
                processor: selectedMethod == .card ? "manual-entry" : nil
            )
        )
        invoice.status = amount >= invoice.amount ? "paid" : "partial"
        actionMessage = "Payment recorded for \(invoice.customer.name)."
        resetPaymentForm()
        showingRecordPaymentSheet = false
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
