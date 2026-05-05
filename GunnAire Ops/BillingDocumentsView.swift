import SwiftUI
import SwiftData

struct BillingDocumentsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Customer.name, order: .forward) private var customers: [Customer]
    @Query(sort: \Item.name, order: .forward) private var items: [Item]
    @Query(sort: \Invoice.createdAt, order: .reverse) private var invoices: [Invoice]
    @Query(sort: \Estimate.createdAt, order: .reverse) private var estimates: [Estimate]
    @Query(sort: \Payment.date, order: .reverse) private var payments: [Payment]

    @State private var selectedDocumentKind: BillingDocumentKind = .estimate
    @State private var selectedCustomerID: UUID?
    @State private var selectedItems: Set<UUID> = []
    @State private var notes = ""
    @State private var newCustomerName = ""
    @State private var newItemName = ""
    @State private var newItemPrice = ""
    @State private var paymentInvoice: Invoice?

    private var selectedTotal: Double {
        items
            .filter { selectedItems.contains($0.id) }
            .reduce(0) { $0 + $1.unitPrice }
    }

    private var selectedCustomer: Customer? {
        guard let selectedCustomerID else { return nil }
        return customers.first { $0.id == selectedCustomerID }
    }

    private var selectedSummary: String {
        items
            .filter { selectedItems.contains($0.id) }
            .map { "\($0.name) - \($0.unitPrice.formatted(.currency(code: "USD")))" }
            .joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Create") {
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

                    if customers.isEmpty {
                        Text("Create a customer before making invoices or estimates.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...5)

                    Text("Total: \(selectedTotal, format: .currency(code: "USD"))")
                        .font(.headline)

                    Button("Create \(selectedDocumentKind.rawValue)") {
                        createDocument()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandGold)
                    .foregroundStyle(Color.primaryBlack)
                    .disabled(selectedCustomer == nil || selectedItems.isEmpty)
                }

                Section("Items") {
                    if items.isEmpty {
                        Text("No items yet. Add one below.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(items) { item in
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
                                    }
                                    Spacer()
                                    Text(item.unitPrice, format: .currency(code: "USD"))
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack {
                        TextField("New item", text: $newItemName)
                        TextField("Price", text: $newItemPrice)
                            .keyboardType(.decimalPad)
                            .frame(maxWidth: 110)
                        Button {
                            addItem()
                        } label: {
                            Label("Add Item", systemImage: "plus")
                        }
                        .disabled(newItemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Double(newItemPrice) == nil)
                    }
                }

                Section("Customers") {
                    HStack {
                        TextField("New customer", text: $newCustomerName)
                        Button {
                            addCustomer()
                        } label: {
                            Label("Add Customer", systemImage: "person.badge.plus")
                        }
                        .disabled(newCustomerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                                Button(invoice.status == "paid" ? "Paid" : "Take Payment") {
                                    paymentInvoice = invoice
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
                                    Text("\(payment.method.capitalized) - \(payment.date.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Text(payment.amount, format: .currency(code: "USD"))
                            }
                        }
                    }
                }
            }
            .navigationTitle("Invoices & Estimates")
            .sheet(item: $paymentInvoice) { invoice in
                RecordInvoicePaymentView(invoice: invoice)
            }
        }
    }

    private func addCustomer() {
        let name = newCustomerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let customer = Customer(name: name)
        modelContext.insert(customer)
        selectedCustomerID = customer.id
        newCustomerName = ""
    }

    private func addItem() {
        guard let price = Double(newItemPrice) else { return }
        let item = Item(name: newItemName.trimmingCharacters(in: .whitespacesAndNewlines), unitPrice: price)
        modelContext.insert(item)
        selectedItems.insert(item.id)
        newItemName = ""
        newItemPrice = ""
    }

    private func toggleItem(_ item: Item) {
        if selectedItems.contains(item.id) {
            selectedItems.remove(item.id)
        } else {
            selectedItems.insert(item.id)
        }
    }

    private func createDocument() {
        guard let selectedCustomer else { return }
        switch selectedDocumentKind {
        case .estimate:
            modelContext.insert(Estimate(customer: selectedCustomer, lineItemSummary: selectedSummary, amount: selectedTotal, notes: notes.isEmpty ? nil : notes))
        case .invoice:
            modelContext.insert(Invoice(customer: selectedCustomer, lineItemSummary: selectedSummary, amount: selectedTotal, notes: notes.isEmpty ? nil : notes))
        }
        selectedItems.removeAll()
        notes = ""
    }

    private func convertEstimate(_ estimate: Estimate) {
        let invoice = Invoice(
            customer: estimate.customer,
            lineItemSummary: estimate.lineItemSummary,
            amount: estimate.amount,
            notes: estimate.notes
        )
        estimate.status = "invoiced"
        modelContext.insert(invoice)
    }
}

private struct RecordInvoicePaymentView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let invoice: Invoice
    @State private var amount: String
    @State private var method = "card"

    init(invoice: Invoice) {
        self.invoice = invoice
        _amount = State(initialValue: String(format: "%.2f", invoice.amount))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Payment") {
                    Text(invoice.customer.name)
                    TextField("Amount", text: $amount)
                        .keyboardType(.decimalPad)
                    Picker("Method", selection: $method) {
                        Text("Card").tag("card")
                        Text("ACH").tag("ach")
                        Text("Cash").tag("cash")
                        Text("Check").tag("check")
                    }
                }
            }
            .navigationTitle("Take Payment")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let paidAmount = Double(amount), paidAmount > 0 else { return }
                        modelContext.insert(Payment(invoice: invoice, amount: paidAmount, method: method))
                        invoice.status = paidAmount >= invoice.amount ? "paid" : "partial"
                        dismiss()
                    }
                    .disabled(Double(amount) == nil)
                }
            }
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
