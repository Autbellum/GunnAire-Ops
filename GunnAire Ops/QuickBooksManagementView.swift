import SwiftUI

struct QuickBooksManagementView: View {
    private let termsURL = URL(string: "https://gunnaire.com/terms-of-service/")!

    @ObservedObject private var qbAPI = QBStubAPIClient.shared
    private let liveAPI = QuickBooksAPI.shared

    @State private var showingNewInvoiceSheet = false
    @State private var showingLiveInvoiceSheet = false
    @State private var showingNewBillSheet = false
    @State private var showingNewVendorSheet = false
    @State private var showingNewPaymentSheet = false

    @State private var syncStatusMessage: String = "Sandbox ready."
    @State private var isSyncing = false
    @State private var useLiveInvoiceAPI = false
    @State private var isLoadingLiveInvoices = false
    @State private var liveInvoiceError: String?
    @State private var liveInvoices: [QuickBooksInvoice] = []
    @State private var liveActionMessage: String?
    @State private var activePaymentInvoiceID: String?

    private var totalInvoiceAmount: Double {
        qbAPI.invoices.compactMap { $0.TotalAmt }.reduce(0, +)
    }

    private var totalBillAmount: Double {
        qbAPI.bills.map(\.totalAmt).reduce(0, +)
    }

    private var totalPaymentAmount: Double {
        qbAPI.payments.map(\.amount).reduce(0, +)
    }

    var body: some View {
        ZStack {
            WatermarkBackground()
            NavigationStack {
                Form {
                    Section("QuickBooks Sandbox Summary") {
                        Text("Invoices: \(qbAPI.invoices.count) | Bills: \(qbAPI.bills.count)")
                        Text("Vendors: \(qbAPI.vendors.count) | Payments: \(qbAPI.payments.count)")
                        Text("Invoiced: \(totalInvoiceAmount, format: .currency(code: "USD"))")
                        Text("Bills Due: \(totalBillAmount, format: .currency(code: "USD"))")
                        Text("Payments Received: \(totalPaymentAmount, format: .currency(code: "USD"))")
                    }

                    Section(header: Text("Invoices").foregroundColor(Color.brandGold)) {
                        if isLoadingLiveInvoices {
                            ProgressView()
                                .tint(Color.brandGold)
                        } else if let liveInvoiceError {
                            Text("Live invoice API error: \(liveInvoiceError)")
                                .foregroundColor(.red)
                                .italic()
                        } else if useLiveInvoiceAPI {
                            if liveInvoices.isEmpty {
                                Text("No live invoices found.")
                                    .foregroundColor(.secondary)
                                    .italic()
                            } else {
                                ForEach(liveInvoices) { invoice in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Invoice #: \(invoice.Id)")
                                            .font(.headline)
                                            .foregroundColor(Color.brandGold)
                                        Text("Customer: \(invoice.CustomerRef.name ?? invoice.CustomerRef.value)")
                                            .font(.subheadline)
                                        Text("Total: \(invoice.TotalAmt, format: .currency(code: "USD"))")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Text("Date: \(invoice.TxnDate)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        Text("Terms: \(termsURL.absoluteString)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        HStack {
                                            Button(activePaymentInvoiceID == invoice.Id ? "Processing..." : "Take Customer Payment") {
                                                takeLiveCustomerPayment(for: invoice)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .tint(Color.brandGold)
                                            .foregroundStyle(Color.primaryBlack)
                                            .disabled(activePaymentInvoiceID != nil)

                                            if let invoiceURL = liveInvoiceURL(for: invoice) {
                                                Link("Open Invoice PDF", destination: invoiceURL)
                                                    .font(.caption)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        } else if qbAPI.isLoadingInvoices {
                            ProgressView()
                                .tint(Color.brandGold)
                        } else if let error = qbAPI.invoiceError {
                            Text("Error loading invoices: \(error.localizedDescription)")
                                .foregroundColor(.red)
                                .italic()
                        } else if qbAPI.invoices.isEmpty {
                            Text("No invoices found.")
                                .foregroundColor(.secondary)
                                .italic()
                        } else {
                            ForEach(qbAPI.invoices, id: \.Id) { invoice in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Invoice #: \(invoice.DocNumber ?? "N/A")")
                                        .font(.headline)
                                        .foregroundColor(Color.brandGold)
                                    Text("Customer: \(invoice.CustomerRef?.name ?? "Unknown")")
                                        .font(.subheadline)
                                    Text("Total: \((invoice.TotalAmt ?? 0), format: .currency(code: "USD"))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("Date: \(invoice.TxnDate ?? "N/A")")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text("Terms: \(termsURL.absoluteString)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }

                        Button(useLiveInvoiceAPI ? "Create New Invoice (Live API)" : "Create New Invoice") {
                            if useLiveInvoiceAPI {
                                showingLiveInvoiceSheet = true
                            } else {
                                showingNewInvoiceSheet = true
                            }
                        }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                        Link("View Terms of Service", destination: termsURL)
                        if let liveActionMessage {
                            Text(liveActionMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Section(header: Text("Bills").foregroundColor(Color.brandGold)) {
                        if qbAPI.bills.isEmpty {
                            Text("No bills found.")
                                .foregroundColor(.secondary)
                                .italic()
                        } else {
                            ForEach(qbAPI.bills) { bill in
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(bill.vendorName)
                                            .font(.headline)
                                        Text("Due: \(bill.dueDate) | \(bill.status.capitalized)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Text(bill.totalAmt, format: .currency(code: "USD"))
                                        .font(.subheadline)
                                }
                            }
                        }

                        Button("Create New Bill") { showingNewBillSheet = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                    }

                    Section(header: Text("Vendors").foregroundColor(Color.brandGold)) {
                        if qbAPI.vendors.isEmpty {
                            Text("No vendors found.")
                                .foregroundColor(.secondary)
                                .italic()
                        } else {
                            ForEach(qbAPI.vendors) { vendor in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(vendor.displayName)
                                        .font(.headline)
                                    if let email = vendor.email { Text(email).font(.caption).foregroundColor(.secondary) }
                                    if let phone = vendor.phone { Text(phone).font(.caption2).foregroundColor(.secondary) }
                                }
                                .padding(.vertical, 2)
                            }
                        }

                        Button("Add New Vendor") { showingNewVendorSheet = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                    }

                    Section(header: Text("Payments").foregroundColor(Color.brandGold)) {
                        if qbAPI.payments.isEmpty {
                            Text("No payments found.")
                                .foregroundColor(.secondary)
                                .italic()
                        } else {
                            ForEach(qbAPI.payments) { payment in
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(payment.customerName)
                                            .font(.headline)
                                        Text("\(payment.method) | \(payment.paidDate)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Text(payment.amount, format: .currency(code: "USD"))
                                        .font(.subheadline)
                                }
                            }
                        }

                        Button("Add New Payment") { showingNewPaymentSheet = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                    }

                    Section(header: Text("Sync Status").foregroundColor(Color.brandGold)) {
                        if isSyncing { ProgressView() }
                        Text(syncStatusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button("Sync All Transactions with QuickBooks") {
                            syncAllTransactions()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.brandGold)
                        .foregroundStyle(Color.primaryBlack)
                        .disabled(isSyncing)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.primaryBlack)
                .navigationTitle("QuickBooks Management")
                .sheet(isPresented: $showingNewInvoiceSheet) {
                    NewInvoiceView(dismiss: {
                        showingNewInvoiceSheet = false
                        qbAPI.fetchInvoices()
                    })
                    .environmentObject(qbAPI)
                    .tint(Color.brandGold)
                }
                .sheet(isPresented: $showingLiveInvoiceSheet) {
                    LiveInvoiceCreateView(
                        customerRefs: liveCustomerRefs,
                        onCreate: { customerRef, amount, note in
                            createLiveInvoice(customerRef: customerRef, amount: amount, note: note)
                        }
                    )
                    .tint(Color.brandGold)
                }
                .sheet(isPresented: $showingNewBillSheet) {
                    NewBillView(
                        dismiss: { showingNewBillSheet = false },
                        onCreate: { payload in
                            qbAPI.createBill(payload) { _ in qbAPI.fetchBills() }
                        }
                    )
                    .tint(Color.brandGold)
                }
                .sheet(isPresented: $showingNewVendorSheet) {
                    NewVendorView(
                        dismiss: { showingNewVendorSheet = false },
                        onAdd: { payload in
                            qbAPI.createVendor(payload) { _ in qbAPI.fetchVendors() }
                        }
                    )
                    .tint(Color.brandGold)
                }
                .sheet(isPresented: $showingNewPaymentSheet) {
                    NewPaymentView(
                        dismiss: { showingNewPaymentSheet = false },
                        onAdd: { payload in
                            qbAPI.createPayment(payload) { _ in qbAPI.fetchPayments() }
                        }
                    )
                    .tint(Color.brandGold)
                }
                .onAppear {
                    QuickBooksDataAPI.shared.loadTokens()
                    useLiveInvoiceAPI = QuickBooksDataAPI.shared.tokens != nil && QuickBooksDataAPI.shared.realmID != nil
                    qbAPI.fetchInvoices()
                    qbAPI.fetchBills()
                    qbAPI.fetchVendors()
                    qbAPI.fetchPayments()
                    if useLiveInvoiceAPI {
                        fetchLiveInvoices()
                    }
                }
            }
        }
    }

    private func syncAllTransactions() {
        isSyncing = true
        if useLiveInvoiceAPI {
            syncStatusMessage = "Syncing live invoices from QuickBooks API..."
            fetchLiveInvoices {
                syncStatusMessage = "Live invoice sync complete. Loaded \(liveInvoices.count) invoice(s)."
                isSyncing = false
            }
        } else {
            syncStatusMessage = "Syncing transactions with QuickBooks sandbox..."
            qbAPI.simulateFullSync { summary in
                syncStatusMessage = summary
                isSyncing = false
            }
        }
    }

    private func fetchLiveInvoices(completion: (() -> Void)? = nil) {
        isLoadingLiveInvoices = true
        liveInvoiceError = nil
        liveAPI.fetchInvoices { result in
            DispatchQueue.main.async {
                isLoadingLiveInvoices = false
                switch result {
                case .success(let invoices):
                    liveInvoices = invoices
                case .failure(let error):
                    liveInvoiceError = error.localizedDescription
                }
                completion?()
            }
        }
    }

    private var liveCustomerRefs: [QuickBooksReference] {
        var unique: [String: QuickBooksReference] = [:]
        for invoice in liveInvoices {
            unique[invoice.CustomerRef.value] = invoice.CustomerRef
        }
        return unique.values.sorted { ($0.name ?? $0.value) < ($1.name ?? $1.value) }
    }

    private func createLiveInvoice(customerRef: QuickBooksReference, amount: Double, note: String?) {
        let itemRef = QuickBooksReference(value: Config.QuickBooks.defaultSalesItemRef, name: nil)
        let lineItem = QuickBooksLineItem(
            Amount: amount,
            DetailType: "SalesItemLineDetail",
            Description: note?.isEmpty == false ? note : nil,
            SalesItemLineDetail: QuickBooksSalesItemLineDetail(ItemRef: itemRef)
        )
        let payload = QuickBooksInvoiceCreate(CustomerRef: customerRef, Line: [lineItem])

        isSyncing = true
        syncStatusMessage = "Creating invoice via QuickBooks API..."
        liveAPI.createInvoice(payload) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let invoice):
                    liveActionMessage = "Live invoice created: \(invoice.Id)"
                    fetchLiveInvoices()
                case .failure(let error):
                    liveActionMessage = "Live invoice create failed: \(error.localizedDescription)"
                }
                isSyncing = false
            }
        }
    }

    private func takeLiveCustomerPayment(for invoice: QuickBooksInvoice) {
        activePaymentInvoiceID = invoice.Id
        let payload = QuickBooksPaymentCreate(
            CustomerRef: invoice.CustomerRef,
            TotalAmt: invoice.TotalAmt,
            Line: nil
        )
        liveAPI.createPayment(payload) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let payment):
                    liveActionMessage = "Payment created: \(payment.Id) for invoice \(invoice.Id)"
                case .failure(let error):
                    liveActionMessage = "Payment failed for invoice \(invoice.Id): \(error.localizedDescription)"
                }
                activePaymentInvoiceID = nil
            }
        }
    }

    private func liveInvoiceURL(for invoice: QuickBooksInvoice) -> URL? {
        guard let realmID = QuickBooksDataAPI.shared.realmID else { return nil }
        return URL(string: "https://app.qbo.intuit.com/app/invoice?txnId=\(invoice.Id)&txnType=Invoice&companyId=\(realmID)")
    }
}

#Preview {
    QuickBooksManagementView()
}

private struct LiveInvoiceCreateView: View {
    @Environment(\.dismiss) private var dismiss

    let customerRefs: [QuickBooksReference]
    let onCreate: (QuickBooksReference, Double, String?) -> Void

    @State private var selectedCustomerIndex = 0
    @State private var amountText = ""
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Live Invoice Details") {
                    if customerRefs.isEmpty {
                        Text("No customers found in live invoices yet. Sync first.")
                            .foregroundColor(.secondary)
                    } else {
                        Picker("Customer", selection: $selectedCustomerIndex) {
                            ForEach(customerRefs.indices, id: \.self) { index in
                                Text(customerRefs[index].name ?? customerRefs[index].value).tag(index)
                            }
                        }
                    }
                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                    TextField("Notes", text: $note)
                }
            }
            .navigationTitle("Create Live Invoice")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        guard !customerRefs.isEmpty, let amount = Double(amountText), amount > 0 else { return }
                        onCreate(customerRefs[selectedCustomerIndex], amount, note.isEmpty ? nil : note)
                        dismiss()
                    }
                    .disabled(customerRefs.isEmpty || Double(amountText) == nil)
                }
            }
        }
    }
}
