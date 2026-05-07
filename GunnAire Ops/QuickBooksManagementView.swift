import SwiftUI
import SwiftData

struct QuickBooksManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Invoice.createdAt, order: .reverse) private var localInvoices: [Invoice]
    @Query(sort: \Payment.date, order: .reverse) private var localPayments: [Payment]
    private let liveAPI = QuickBooksAPI.shared

    @State private var customers: [QuickBooksCustomer] = []
    @State private var items: [QuickBooksItem] = []
    @State private var estimates: [QuickBooksEstimate] = []
    @State private var invoices: [QuickBooksInvoice] = []
    @State private var bills: [QuickBooksBill] = []
    @State private var vendors: [QuickBooksVendor] = []
    @State private var payments: [QuickBooksPayment] = []

    @State private var showingNewCustomerSheet = false
    @State private var showingNewCatalogItemSheet = false
    @State private var showingNewEstimateSheet = false
    @State private var showingNewInvoiceSheet = false
    @State private var showingNewBillSheet = false
    @State private var showingNewVendorSheet = false
    @State private var showingNewPaymentSheet = false
    @State private var showingProcessCardPaymentSheet = false
    @State private var showingRefundPaymentSheet = false

    @State private var isLoading = false
    @State private var statusMessage = "Connect QuickBooks in Settings to start live sync."
    @State private var actionMessage: String?
    @State private var activePaymentInvoiceID: String?
    @State private var paymentToRefund: Payment?

    private var isAuthenticated: Bool {
        QuickBooksDataAPI.shared.isAuthenticated
    }

    private var quickBooksConfigReady: Bool {
        Config.QuickBooks.isConfigured
    }

    private var salesItemConfigReady: Bool {
        Config.QuickBooks.hasExplicitDefaultSalesItemRef
    }

    private var totalInvoiceAmount: Double {
        invoices.reduce(0) { $0 + $1.TotalAmt }
    }

    private var totalEstimateAmount: Double {
        estimates.reduce(0) { $0 + $1.TotalAmt }
    }

    private var totalBillAmount: Double {
        bills.reduce(0) { $0 + $1.TotalAmt }
    }

    private var totalPaymentAmount: Double {
        payments.reduce(0) { $0 + $1.TotalAmt }
    }

    private var quickBooksChargePayments: [Payment] {
        localPayments.filter { $0.quickBooksChargeID?.isEmpty == false }
    }

    private var collectibleQuickBooksInvoices: [QuickBooksInvoice] {
        invoices.filter { outstandingQuickBooksBalance(for: $0) > 0 }
    }

    private var collectibleLocalInvoices: [Invoice] {
        localInvoices.filter { localOutstandingBalance(for: $0) > 0 }
    }

    private var quickBooksCompanyURL: URL? {
        guard let realmID = QuickBooksDataAPI.shared.realmID else { return nil }
        return URL(string: "https://app.qbo.intuit.com/app/homepage?companyId=\(realmID)")
    }

    var body: some View {
        ZStack {
            WatermarkBackground()
            NavigationStack {
                Form {
                    Section("Connection") {
                        connectionRow(
                            title: "Environment",
                            value: Config.QuickBooks.environment.capitalized
                        )
                        connectionRow(
                            title: "Company Realm",
                            value: QuickBooksDataAPI.shared.realmID ?? "Not connected"
                        )
                        connectionRow(
                            title: "Status",
                            value: isAuthenticated ? "Connected" : "Disconnected"
                        )

                        if let quickBooksCompanyURL {
                            Link("Open QuickBooks Online", destination: quickBooksCompanyURL)
                        }

                        if !isAuthenticated {
                            Text("Open Settings and connect QuickBooks before using live sync.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if !quickBooksConfigReady {
                            Text(
                                isAuthenticated
                                ? "QuickBooks is connected with a saved session. Reconnecting or refreshing this connection on this Mac still requires `QB_CLIENT_ID` and `QB_CLIENT_SECRET` in `Config/Local.xcconfig`."
                                : "QuickBooks credentials are not configured on this Mac. Update `QB_CLIENT_ID` and `QB_CLIENT_SECRET` in `Config/Local.xcconfig` before connecting."
                            )
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }
                    }

                    Section("Summary") {
                        summaryRow(title: "Customers", count: customers.count)
                        summaryRow(title: "Catalog Items", count: items.count)
                        summaryRow(title: "Estimates", count: estimates.count, amount: totalEstimateAmount)
                        summaryRow(title: "Invoices", count: invoices.count, amount: totalInvoiceAmount)
                        summaryRow(title: "Bills", count: bills.count, amount: totalBillAmount)
                        summaryRow(title: "Vendors", count: vendors.count)
                        summaryRow(title: "Payments", count: payments.count, amount: totalPaymentAmount)
                    }

                    Section(header: Text("Customers").foregroundColor(Color.brandGold)) {
                        if customers.isEmpty {
                            emptyState("No QuickBooks customers loaded.")
                        } else {
                            ForEach(customers) { customer in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(customer.DisplayName)
                                        .font(.headline)
                                    if let email = customer.PrimaryEmailAddr?.Address, !email.isEmpty {
                                        Text(email)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    if let phone = customer.PrimaryPhone?.FreeFormNumber, !phone.isEmpty {
                                        Text(phone)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }

                        Button("Add Customer") { showingNewCustomerSheet = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .disabled(!isAuthenticated)
                    }

                    Section(header: Text("Product Catalog").foregroundColor(Color.brandGold)) {
                        if items.isEmpty {
                            emptyState("No QuickBooks products or services loaded.")
                        } else {
                            ForEach(items) { item in
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.Name)
                                            .font(.headline)
                                        if let description = item.Description, !description.isEmpty {
                                            Text(description)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        Text(item.ItemType ?? "Unknown")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if let price = item.UnitPrice {
                                        Text(price, format: .currency(code: "USD"))
                                            .font(.subheadline)
                                    }
                                }
                            }
                        }

                        if Config.QuickBooks.defaultIncomeAccountRef.isEmpty {
                            Text("Set `QB_DEFAULT_INCOME_ACCOUNT_REF` before creating live catalog items.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Button("Add Catalog Item") { showingNewCatalogItemSheet = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .disabled(!isAuthenticated || Config.QuickBooks.defaultIncomeAccountRef.isEmpty)
                    }

                    Section(header: Text("Estimates").foregroundColor(Color.brandGold)) {
                        if estimates.isEmpty {
                            emptyState("No QuickBooks estimates loaded.")
                        } else {
                            ForEach(estimates) { estimate in
                                transactionBlock(
                                    title: estimate.DocNumber ?? estimate.Id,
                                    name: estimate.CustomerRef.displayName,
                                    amount: estimate.TotalAmt,
                                    dateText: estimate.TxnDate
                                )
                            }
                        }

                        if !salesItemConfigReady {
                            Text("Set `QB_DEFAULT_ITEM_REF` to a valid QuickBooks sales item before creating live estimates.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Button("Create Estimate") { showingNewEstimateSheet = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .disabled(!isAuthenticated || customers.isEmpty || !salesItemConfigReady)
                    }

                    Section(header: Text("Invoices").foregroundColor(Color.brandGold)) {
                        if invoices.isEmpty {
                            emptyState("No QuickBooks invoices loaded.")
                        } else {
                            ForEach(invoices) { invoice in
                                VStack(alignment: .leading, spacing: 6) {
                                    transactionBlock(
                                        title: invoice.DocNumber ?? invoice.Id,
                                        name: invoice.CustomerRef.displayName,
                                        amount: invoice.TotalAmt,
                                        dateText: invoice.TxnDate
                                    )

                                    Text("Balance due: \(outstandingQuickBooksBalance(for: invoice), format: .currency(code: "USD"))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)

                                    HStack {
                                        Button(activePaymentInvoiceID == invoice.Id ? "Processing..." : "Take Payment") {
                                            takeLiveCustomerPayment(for: invoice)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(Color.brandGold)
                                        .foregroundStyle(Color.primaryBlack)
                                        .disabled(activePaymentInvoiceID != nil || outstandingQuickBooksBalance(for: invoice) <= 0)

                                        if let invoiceURL = liveInvoiceURL(for: invoice) {
                                            Link("Open in QuickBooks", destination: invoiceURL)
                                                .font(.caption)
                                        }
                                    }
                                }
                            }
                        }

                        if !salesItemConfigReady {
                            Text("Set `QB_DEFAULT_ITEM_REF` to a valid QuickBooks sales item before creating live invoices.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Button("Create Invoice") { showingNewInvoiceSheet = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .disabled(!isAuthenticated || customers.isEmpty || !salesItemConfigReady)
                    }

                    Section(header: Text("Bills").foregroundColor(Color.brandGold)) {
                        if bills.isEmpty {
                            emptyState("No QuickBooks bills loaded.")
                        } else {
                            ForEach(bills) { bill in
                                transactionBlock(
                                    title: bill.Id,
                                    name: bill.VendorRef.displayName,
                                    amount: bill.TotalAmt,
                                    dateText: bill.DueDate ?? bill.TxnDate
                                )
                            }
                        }

                        if Config.QuickBooks.defaultExpenseAccountRef.isEmpty {
                            Text("Set `QB_DEFAULT_EXPENSE_ACCOUNT_REF` before creating live bills.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Button("Create Bill") { showingNewBillSheet = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .disabled(!isAuthenticated || vendors.isEmpty || Config.QuickBooks.defaultExpenseAccountRef.isEmpty)
                    }

                    Section(header: Text("Vendors").foregroundColor(Color.brandGold)) {
                        if vendors.isEmpty {
                            emptyState("No QuickBooks vendors loaded.")
                        } else {
                            ForEach(vendors) { vendor in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(vendor.DisplayName)
                                        .font(.headline)
                                    if let email = vendor.PrimaryEmailAddr?.Address, !email.isEmpty {
                                        Text(email)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    if let phone = vendor.PrimaryPhone?.FreeFormNumber, !phone.isEmpty {
                                        Text(phone)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }

                        Button("Add Vendor") { showingNewVendorSheet = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .disabled(!isAuthenticated)
                    }

                    Section(header: Text("Payments").foregroundColor(Color.brandGold)) {
                        if payments.isEmpty {
                            emptyState("No QuickBooks payments loaded.")
                        } else {
                            ForEach(payments) { payment in
                                transactionBlock(
                                    title: payment.Id,
                                    name: payment.CustomerRef?.displayName ?? "Unapplied payment",
                                    amount: payment.TotalAmt,
                                    dateText: payment.TxnDate
                                )
                            }
                        }

                        Button("Record Payment") { showingNewPaymentSheet = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .disabled(!isAuthenticated || collectibleQuickBooksInvoices.isEmpty)
                    }

                    Section(header: Text("QuickBooks Payments API").foregroundColor(Color.brandGold)) {
                        HStack {
                            Text("Connected local charges")
                            Spacer()
                            Text("\(quickBooksChargePayments.filter { !$0.isRefund }.count)")
                                .foregroundColor(.secondary)
                        }
                        HStack {
                            Text("Recorded refunds")
                            Spacer()
                            Text("\(quickBooksChargePayments.filter(\.isRefund).count)")
                                .foregroundColor(.secondary)
                        }

                        Button("Process Card Charge") {
                            showingProcessCardPaymentSheet = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.brandGold)
                        .foregroundStyle(Color.primaryBlack)
                        .disabled(!isAuthenticated || collectibleLocalInvoices.isEmpty)

                        if quickBooksChargePayments.isEmpty {
                            Text("No local QuickBooks Payments charges have been processed yet.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(quickBooksChargePayments.prefix(10)) { payment in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(payment.invoice.customer.name)
                                        .font(.headline)
                                    Text(payment.isRefund ? "Refund" : "Charge")
                                        .font(.caption)
                                        .foregroundColor(payment.isRefund ? .red : .secondary)
                                    Text(payment.amount, format: .currency(code: "USD"))
                                        .font(.subheadline)
                                    if let chargeID = payment.quickBooksChargeID, !chargeID.isEmpty {
                                        Text("Charge ID: \(chargeID)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    if let accountingID = payment.quickBooksID, !accountingID.isEmpty {
                                        Text("Accounting payment ID: \(accountingID)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    if let refundReceiptID = payment.quickBooksRefundReceiptID, !refundReceiptID.isEmpty {
                                        Text("Refund receipt ID: \(refundReceiptID)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    if !payment.isRefund, payment.amount > 0 {
                                        Button("Refund This Payment") {
                                            paymentToRefund = payment
                                            showingRefundPaymentSheet = true
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }

                    Section(header: Text("Sync Status").foregroundColor(Color.brandGold)) {
                        if isLoading {
                            ProgressView()
                        }
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if let actionMessage {
                            Text(actionMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Button("Sync All QuickBooks Data") {
                            syncAllQuickBooksData()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.brandGold)
                        .foregroundStyle(Color.primaryBlack)
                        .disabled(isLoading || !isAuthenticated || !quickBooksConfigReady)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.primaryBlack)
                .navigationTitle("QuickBooks Management")
                .sheet(isPresented: $showingNewCustomerSheet) {
                    QuickBooksCustomerComposeView { name, email, phone in
                        createCustomer(name: name, email: email, phone: phone)
                    }
                    .tint(Color.brandGold)
                }
                .sheet(isPresented: $showingNewCatalogItemSheet) {
                    QuickBooksCatalogItemComposeView { name, price, description in
                        createCatalogItem(name: name, price: price, description: description)
                    }
                    .tint(Color.brandGold)
                }
                .sheet(isPresented: $showingNewEstimateSheet) {
                    QuickBooksDocumentComposeView(
                        title: "Create Estimate",
                        customerRefs: customers.map(\.reference)
                    ) { customerRef, amount, note in
                        createEstimate(customerRef: customerRef, amount: amount, note: note)
                    }
                    .tint(Color.brandGold)
                }
                .sheet(isPresented: $showingNewInvoiceSheet) {
                    QuickBooksDocumentComposeView(
                        title: "Create Invoice",
                        customerRefs: customers.map(\.reference)
                    ) { customerRef, amount, note in
                        createInvoice(customerRef: customerRef, amount: amount, note: note)
                    }
                    .tint(Color.brandGold)
                }
                .sheet(isPresented: $showingNewBillSheet) {
                    QuickBooksBillComposeView(
                        vendorRefs: vendors.map(\.reference)
                    ) { vendorRef, amount, note in
                        createBill(vendorRef: vendorRef, amount: amount, note: note)
                    }
                    .tint(Color.brandGold)
                }
                .sheet(isPresented: $showingNewVendorSheet) {
                    QuickBooksVendorComposeView { name, email, phone in
                        createVendor(name: name, email: email, phone: phone)
                    }
                    .tint(Color.brandGold)
                }
                .sheet(isPresented: $showingNewPaymentSheet) {
                    QuickBooksPaymentComposeView(invoices: collectibleQuickBooksInvoices) { invoice, amount, note in
                        createPayment(for: invoice, amount: amount, note: note)
                    }
                    .tint(Color.brandGold)
                }
                .sheet(isPresented: $showingProcessCardPaymentSheet) {
                    QuickBooksCardChargeComposeView(
                        invoices: collectibleLocalInvoices,
                        payments: localPayments
                    ) { invoice, amount, cardInput, note in
                        processCardCharge(for: invoice, amount: amount, cardInput: cardInput, note: note)
                    }
                    .tint(Color.brandGold)
                }
                .sheet(isPresented: $showingRefundPaymentSheet, onDismiss: {
                    paymentToRefund = nil
                }) {
                    if let paymentToRefund {
                        QuickBooksRefundComposeView(payment: paymentToRefund) { amount, note in
                            refundPayment(paymentToRefund, amount: amount, note: note)
                        }
                        .tint(Color.brandGold)
                    }
                }
                .onAppear {
                    QuickBooksDataAPI.shared.loadTokens()
                    if !quickBooksConfigReady {
                        statusMessage = "QuickBooks client credentials are missing on this Mac. Update Config/Local.xcconfig, then reconnect QuickBooks."
                    } else if isAuthenticated {
                        syncAllQuickBooksData()
                    } else {
                        statusMessage = "QuickBooks is not connected. Open Settings to authenticate."
                    }
                }
            }
        }
    }

    private func syncAllQuickBooksData() {
        guard quickBooksConfigReady else {
            statusMessage = "QuickBooks client credentials are missing on this Mac. Update Config/Local.xcconfig, then reconnect QuickBooks."
            return
        }
        guard isAuthenticated else {
            statusMessage = "QuickBooks is not connected. Open Settings to authenticate."
            return
        }

        isLoading = true
        actionMessage = nil
        statusMessage = "Syncing customers, catalog, estimates, invoices, bills, vendors, and payments from QuickBooks..."

        let group = DispatchGroup()
        var failures: [String] = []

        group.enter()
        liveAPI.fetchCustomers { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let records):
                    customers = records.sorted { $0.DisplayName.localizedCaseInsensitiveCompare($1.DisplayName) == .orderedAscending }
                case .failure(let error):
                    failures.append("Customers: \(error.localizedDescription)")
                }
                group.leave()
            }
        }

        group.enter()
        liveAPI.fetchItems { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let records):
                    items = records.sorted { $0.Name.localizedCaseInsensitiveCompare($1.Name) == .orderedAscending }
                case .failure(let error):
                    failures.append("Catalog: \(error.localizedDescription)")
                }
                group.leave()
            }
        }

        group.enter()
        liveAPI.fetchEstimates { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let records):
                    estimates = records
                case .failure(let error):
                    failures.append("Estimates: \(error.localizedDescription)")
                }
                group.leave()
            }
        }

        group.enter()
        liveAPI.fetchInvoices { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let records):
                    invoices = records
                case .failure(let error):
                    failures.append("Invoices: \(error.localizedDescription)")
                }
                group.leave()
            }
        }

        group.enter()
        liveAPI.fetchBills { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let records):
                    bills = records
                case .failure(let error):
                    failures.append("Bills: \(error.localizedDescription)")
                }
                group.leave()
            }
        }

        group.enter()
        liveAPI.fetchVendors { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let records):
                    vendors = records.sorted { $0.DisplayName.localizedCaseInsensitiveCompare($1.DisplayName) == .orderedAscending }
                case .failure(let error):
                    failures.append("Vendors: \(error.localizedDescription)")
                }
                group.leave()
            }
        }

        group.enter()
        liveAPI.fetchPayments { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let records):
                    payments = records
                case .failure(let error):
                    failures.append("Payments: \(error.localizedDescription)")
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            isLoading = false
            do {
                try QuickBooksLocalSync.importSnapshot(
                    customers: customers,
                    items: items,
                    estimates: estimates,
                    invoices: invoices,
                    payments: payments,
                    vendors: vendors,
                    into: modelContext
                )
            } catch {
                failures.append("Local app sync: \(error.localizedDescription)")
            }
            if failures.isEmpty {
                statusMessage = "Sync complete. Loaded \(customers.count) customers, \(items.count) catalog items, \(estimates.count) estimates, \(invoices.count) invoices, \(bills.count) bills, \(vendors.count) vendors, and \(payments.count) payments."
            } else {
                statusMessage = failures.joined(separator: "\n")
            }
        }
    }

    private func createCustomer(name: String, email: String?, phone: String?) {
        let payload = QuickBooksCustomerCreate(
            DisplayName: name,
            PrimaryPhone: phone.map { QuickBooksPhoneNumber(FreeFormNumber: $0) },
            PrimaryEmailAddr: email.map { QuickBooksEmailAddress(Address: $0) },
            BillAddr: nil
        )

        performAction(message: "Creating customer in QuickBooks...") {
            liveAPI.createCustomer(payload) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let customer):
                        actionMessage = "Customer created: \(customer.DisplayName)"
                        syncAllQuickBooksData()
                    case .failure(let error):
                        actionMessage = "Customer creation failed: \(error.localizedDescription)"
                        isLoading = false
                    }
                }
            }
        }
    }

    private func createCatalogItem(name: String, price: Double, description: String?) {
        let payload = QuickBooksItemCreate(
            Name: name,
            ItemType: "Service",
            Description: description,
            UnitPrice: price,
            IncomeAccountRef: QuickBooksReference(value: Config.QuickBooks.defaultIncomeAccountRef, name: nil)
        )

        performAction(message: "Creating catalog item in QuickBooks...") {
            liveAPI.createItem(payload) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let item):
                        actionMessage = "Catalog item created: \(item.Name)"
                        syncAllQuickBooksData()
                    case .failure(let error):
                        actionMessage = "Catalog item creation failed: \(error.localizedDescription)"
                        isLoading = false
                    }
                }
            }
        }
    }

    private func createEstimate(customerRef: QuickBooksReference, amount: Double, note: String?) {
        let payload = QuickBooksEstimateCreate(
            CustomerRef: customerRef,
            Line: [salesLineItem(amount: amount, note: note)],
            PrivateNote: note
        )

        performAction(message: "Creating estimate in QuickBooks...") {
            liveAPI.createEstimate(payload) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let estimate):
                        actionMessage = "Estimate created: \(estimate.DocNumber ?? estimate.Id)"
                        syncAllQuickBooksData()
                    case .failure(let error):
                        actionMessage = "Estimate creation failed: \(error.localizedDescription)"
                        isLoading = false
                    }
                }
            }
        }
    }

    private func createInvoice(customerRef: QuickBooksReference, amount: Double, note: String?) {
        let payload = QuickBooksInvoiceCreate(
            CustomerRef: customerRef,
            Line: [salesLineItem(amount: amount, note: note)],
            PrivateNote: note
        )

        performAction(message: "Creating invoice in QuickBooks...") {
            liveAPI.createInvoice(payload) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let invoice):
                        actionMessage = "Invoice created: \(invoice.DocNumber ?? invoice.Id)"
                        syncAllQuickBooksData()
                    case .failure(let error):
                        actionMessage = "Invoice creation failed: \(error.localizedDescription)"
                        isLoading = false
                    }
                }
            }
        }
    }

    private func createBill(vendorRef: QuickBooksReference, amount: Double, note: String?) {
        let expenseAccount = QuickBooksReference(value: Config.QuickBooks.defaultExpenseAccountRef, name: nil)
        let payload = QuickBooksBillCreate(
            VendorRef: vendorRef,
            Line: [QuickBooksBillLine(amount: amount, description: note, accountRef: expenseAccount)],
            PrivateNote: note
        )

        performAction(message: "Creating bill in QuickBooks...") {
            liveAPI.createBill(payload) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let bill):
                        actionMessage = "Bill created: \(bill.Id)"
                        syncAllQuickBooksData()
                    case .failure(let error):
                        actionMessage = "Bill creation failed: \(error.localizedDescription)"
                        isLoading = false
                    }
                }
            }
        }
    }

    private func createVendor(name: String, email: String?, phone: String?) {
        let payload = QuickBooksVendorCreate(
            DisplayName: name,
            PrimaryEmailAddr: email.map { QuickBooksEmailAddress(Address: $0) },
            PrimaryPhone: phone.map { QuickBooksPhoneNumber(FreeFormNumber: $0) }
        )

        performAction(message: "Creating vendor in QuickBooks...") {
            liveAPI.createVendor(payload) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let vendor):
                        actionMessage = "Vendor created: \(vendor.DisplayName)"
                        syncAllQuickBooksData()
                    case .failure(let error):
                        actionMessage = "Vendor creation failed: \(error.localizedDescription)"
                        isLoading = false
                    }
                }
            }
        }
    }

    private func createPayment(for invoice: QuickBooksInvoice, amount: Double, note: String?) {
        let payload = QuickBooksPaymentCreate(
            CustomerRef: invoice.CustomerRef,
            TotalAmt: amount,
            PrivateNote: note,
            PaymentRefNum: nil,
            Line: [
                QuickBooksPaymentLine(
                    Amount: amount,
                    LinkedTxn: [QuickBooksLinkedTxn(TxnId: invoice.Id, TxnType: "Invoice")]
                )
            ]
        )

        performAction(message: "Recording payment in QuickBooks...") {
            liveAPI.createPayment(payload) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let payment):
                        actionMessage = "Payment created: \(payment.Id)"
                        syncAllQuickBooksData()
                    case .failure(let error):
                        actionMessage = "Payment creation failed: \(error.localizedDescription)"
                        isLoading = false
                    }
                }
            }
        }
    }

    private func takeLiveCustomerPayment(for invoice: QuickBooksInvoice) {
        let amountDue = outstandingQuickBooksBalance(for: invoice)
        guard amountDue > 0 else {
            actionMessage = "This QuickBooks invoice is already paid."
            return
        }
        activePaymentInvoiceID = invoice.Id
        let payload = QuickBooksPaymentCreate(
            CustomerRef: invoice.CustomerRef,
            TotalAmt: amountDue,
            PrivateNote: "Created from GunnAire Ops for invoice \(invoice.DocNumber ?? invoice.Id)",
            PaymentRefNum: nil,
            Line: [
                QuickBooksPaymentLine(
                    Amount: amountDue,
                    LinkedTxn: [QuickBooksLinkedTxn(TxnId: invoice.Id, TxnType: "Invoice")]
                )
            ]
        )

        liveAPI.createPayment(payload) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let payment):
                    actionMessage = "Payment created: \(payment.Id) for invoice \(invoice.DocNumber ?? invoice.Id)"
                    syncAllQuickBooksData()
                case .failure(let error):
                    actionMessage = "Payment failed for invoice \(invoice.DocNumber ?? invoice.Id): \(error.localizedDescription)"
                    isLoading = false
                }
                activePaymentInvoiceID = nil
            }
        }
    }

    private func processCardCharge(for invoice: Invoice, amount: Double, cardInput: QuickBooksPaymentsCardInput, note: String?) {
        performAction(message: "Processing QuickBooks card charge...") {
            Task {
                do {
                    let result = try await QuickBooksPaymentsService.shared.processCardPayment(
                        invoice: invoice,
                        amount: amount,
                        cardInput: cardInput,
                        note: note
                    )
                    let resolvedCardLast4 = result.charge.card?.number.flatMap { String($0.suffix(4)) }
                    await MainActor.run {
                        modelContext.insert(
                            Payment(
                                invoice: invoice,
                                quickBooksID: result.accountingPayment?.Id,
                                quickBooksChargeID: result.charge.id,
                                quickBooksClientTransID: result.charge.resolvedClientTransID,
                                amount: amount,
                                method: "card",
                                cardLast4: resolvedCardLast4,
                                authorizationReference: result.charge.authCode,
                                notes: note,
                                processor: OnsitePaymentProcessor.quickBooksPayments.rawValue
                            )
                        )
                        let localBalance = localOutstandingBalance(for: invoice)
                        invoice.status = localBalance == 0 ? "paid" : "partial"
                        if let accountingError = result.accountingError {
                            actionMessage = "Charge captured, but accounting sync still needs attention: \(accountingError)"
                        } else {
                            actionMessage = "Card charge captured in QuickBooks Payments."
                        }
                        syncAllQuickBooksData()
                    }
                } catch {
                    await MainActor.run {
                        actionMessage = "QuickBooks card charge failed: \(error.localizedDescription)"
                        isLoading = false
                    }
                }
            }
        }
    }

    private func refundPayment(_ payment: Payment, amount: Double, note: String?) {
        performAction(message: "Refunding QuickBooks payment...") {
            Task {
                do {
                    let result = try await QuickBooksPaymentsService.shared.refundPayment(
                        payment: payment,
                        amount: amount,
                        note: note
                    )
                    await MainActor.run {
                        modelContext.insert(
                            Payment(
                                invoice: payment.invoice,
                                quickBooksChargeID: result.refund.id,
                                quickBooksClientTransID: result.refund.resolvedClientTransID,
                                quickBooksRefundReceiptID: result.refundReceipt?.Id,
                                amount: -amount,
                                method: payment.method,
                                cardLast4: payment.cardLast4,
                                authorizationReference: result.refund.id,
                                notes: note,
                                processor: OnsitePaymentProcessor.quickBooksPayments.rawValue,
                                isRefund: true,
                                refundedPaymentID: payment.id
                            )
                        )
                        let localBalance = max(
                            payment.invoice.amount - localPayments.filter { $0.invoice.id == payment.invoice.id }.reduce(0) { $0 + $1.amount } + amount,
                            0
                        )
                        payment.invoice.status = localBalance == 0 ? "paid" : "partial"
                        if let accountingError = result.accountingError {
                            actionMessage = "Refund issued, but refund receipt sync still needs attention: \(accountingError)"
                        } else {
                            actionMessage = "QuickBooks refund completed."
                        }
                        syncAllQuickBooksData()
                    }
                } catch {
                    await MainActor.run {
                        actionMessage = "QuickBooks refund failed: \(error.localizedDescription)"
                        isLoading = false
                    }
                }
            }
        }
    }

    private func salesLineItem(amount: Double, note: String?) -> QuickBooksLineItem {
        QuickBooksLineItem(
            Amount: amount,
            DetailType: "SalesItemLineDetail",
            Description: note,
            SalesItemLineDetail: QuickBooksSalesItemLineDetail(
                ItemRef: QuickBooksReference(value: Config.QuickBooks.defaultSalesItemRef, name: nil)
            )
        )
    }

    private func performAction(message: String, work: @escaping () -> Void) {
        guard isAuthenticated else {
            actionMessage = "QuickBooks is not connected."
            return
        }
        isLoading = true
        actionMessage = nil
        statusMessage = message
        work()
    }

    private func outstandingQuickBooksBalance(for invoice: QuickBooksInvoice) -> Double {
        max(invoice.Balance ?? invoice.TotalAmt, 0)
    }

    private func localOutstandingBalance(for invoice: Invoice) -> Double {
        let netPayments = localPayments
            .filter { $0.invoice.id == invoice.id }
            .reduce(0) { partial, payment in
                partial + payment.amount
            }
        return max(invoice.amount - netPayments, 0)
    }

    private func liveInvoiceURL(for invoice: QuickBooksInvoice) -> URL? {
        guard let realmID = QuickBooksDataAPI.shared.realmID else { return nil }
        return URL(string: "https://app.qbo.intuit.com/app/invoice?txnId=\(invoice.Id)&txnType=Invoice&companyId=\(realmID)")
    }

    @ViewBuilder
    private func transactionBlock(title: String, name: String, amount: Double, dateText: String?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(name)
                    .font(.subheadline)
                if let dateText, !dateText.isEmpty {
                    Text(dateText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Text(amount, format: .currency(code: "USD"))
                .font(.subheadline)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func emptyState(_ text: String) -> some View {
        Text(text)
            .foregroundColor(.secondary)
            .italic()
    }

    @ViewBuilder
    private func summaryRow(title: String, count: Int, amount: Double? = nil) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let amount {
                Text("\(count) | \(amount.formatted(.currency(code: "USD")))")
                    .foregroundColor(.secondary)
            } else {
                Text("\(count)")
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func connectionRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

#Preview {
    QuickBooksManagementView()
}

private struct QuickBooksDocumentComposeView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let customerRefs: [QuickBooksReference]
    let onCreate: (QuickBooksReference, Double, String?) -> Void

    @State private var selectedCustomerIndex = 0
    @State private var amountText = ""
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(title) {
                    if customerRefs.isEmpty {
                        Text("Sync QuickBooks customers first.")
                            .foregroundColor(.secondary)
                    } else {
                        Picker("Customer", selection: $selectedCustomerIndex) {
                            ForEach(customerRefs.indices, id: \.self) { index in
                                Text(customerRefs[index].displayName).tag(index)
                            }
                        }
                    }

                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                    TextField("Notes", text: $note)
                }
            }
            .navigationTitle(title)
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

private struct QuickBooksBillComposeView: View {
    @Environment(\.dismiss) private var dismiss

    let vendorRefs: [QuickBooksReference]
    let onCreate: (QuickBooksReference, Double, String?) -> Void

    @State private var selectedVendorIndex = 0
    @State private var amountText = ""
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Create Bill") {
                    if vendorRefs.isEmpty {
                        Text("Sync QuickBooks vendors first.")
                            .foregroundColor(.secondary)
                    } else {
                        Picker("Vendor", selection: $selectedVendorIndex) {
                            ForEach(vendorRefs.indices, id: \.self) { index in
                                Text(vendorRefs[index].displayName).tag(index)
                            }
                        }
                    }

                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                    TextField("Notes", text: $note)
                }
            }
            .navigationTitle("Create Bill")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        guard !vendorRefs.isEmpty, let amount = Double(amountText), amount > 0 else { return }
                        onCreate(vendorRefs[selectedVendorIndex], amount, note.isEmpty ? nil : note)
                        dismiss()
                    }
                    .disabled(vendorRefs.isEmpty || Double(amountText) == nil)
                }
            }
        }
    }
}

private struct QuickBooksPaymentComposeView: View {
    @Environment(\.dismiss) private var dismiss

    let invoices: [QuickBooksInvoice]
    let onAdd: (QuickBooksInvoice, Double, String?) -> Void

    @State private var selectedInvoiceIndex = 0
    @State private var amountText = ""
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Record Payment") {
                    if invoices.isEmpty {
                        Text("Sync QuickBooks invoices first.")
                            .foregroundColor(.secondary)
                    } else {
                        Picker("Invoice", selection: $selectedInvoiceIndex) {
                            ForEach(invoices.indices, id: \.self) { index in
                                let invoice = invoices[index]
                                Text("\(invoice.DocNumber ?? invoice.Id) · \(invoice.CustomerRef.displayName)").tag(index)
                            }
                        }
                    }

                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                    TextField("Notes", text: $note)
                }
            }
            .navigationTitle("Record Payment")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        guard !invoices.isEmpty, let amount = Double(amountText), amount > 0 else { return }
                        onAdd(invoices[selectedInvoiceIndex], amount, note.isEmpty ? nil : note)
                        dismiss()
                    }
                    .disabled(invoices.isEmpty || Double(amountText) == nil)
                }
            }
            .onAppear {
                if let firstInvoice = invoices.first {
                    amountText = String(format: "%.2f", max(firstInvoice.Balance ?? firstInvoice.TotalAmt, 0))
                }
            }
            .onChange(of: selectedInvoiceIndex) { _, newValue in
                guard invoices.indices.contains(newValue) else { return }
                let invoice = invoices[newValue]
                amountText = String(format: "%.2f", max(invoice.Balance ?? invoice.TotalAmt, 0))
            }
        }
    }
}

private struct QuickBooksCardChargeComposeView: View {
    @Environment(\.dismiss) private var dismiss

    let invoices: [Invoice]
    let payments: [Payment]
    let onProcess: (Invoice, Double, QuickBooksPaymentsCardInput, String?) -> Void

    @State private var selectedInvoiceIndex = 0
    @State private var amountText = ""
    @State private var note = ""
    @State private var cardholderName = ""
    @State private var cardNumber = ""
    @State private var expirationMonth = ""
    @State private var expirationYear = ""
    @State private var cvc = ""
    @State private var postalCode = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Process Card Charge") {
                    if invoices.isEmpty {
                        Text("Create and sync an invoice first.")
                            .foregroundColor(.secondary)
                    } else {
                        Picker("Invoice", selection: $selectedInvoiceIndex) {
                            ForEach(invoices.indices, id: \.self) { index in
                                let invoice = invoices[index]
                                Text("\(invoice.customer.name) · \(invoice.amount.formatted(.currency(code: "USD")))")
                                    .tag(index)
                            }
                        }
                    }

                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                    TextField("Notes", text: $note)
                    TextField("Cardholder name", text: $cardholderName)
                    TextField("Card number", text: $cardNumber)
                        .keyboardType(.numberPad)
                    HStack {
                        TextField("Exp MM", text: $expirationMonth)
                            .keyboardType(.numberPad)
                        TextField("Exp YYYY", text: $expirationYear)
                            .keyboardType(.numberPad)
                        TextField("CVC", text: $cvc)
                            .keyboardType(.numberPad)
                    }
                    TextField("Billing ZIP", text: $postalCode)
                        .keyboardType(.numbersAndPunctuation)
                    Text("Card details are only used to create a QuickBooks Payments token for this transaction and are not saved locally.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Card Charge")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Process") {
                        guard !invoices.isEmpty, let amount = Double(amountText), amount > 0 else { return }
                        let invoice = invoices[selectedInvoiceIndex]
                        let input = QuickBooksPaymentsCardInput(
                            cardholderName: cardholderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? invoice.customer.name : cardholderName.trimmingCharacters(in: .whitespacesAndNewlines),
                            cardNumber: cardNumber.filter(\.isNumber),
                            expMonth: expirationMonth.filter(\.isNumber),
                            expYear: expirationYear.filter(\.isNumber),
                            cvc: cvc.filter(\.isNumber),
                            postalCode: postalCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : postalCode.trimmingCharacters(in: .whitespacesAndNewlines),
                            addressLine: invoice.customer.address,
                            city: nil,
                            region: nil,
                            country: "US"
                        )
                        onProcess(invoice, amount, input, note.nilIfBlank)
                        dismiss()
                    }
                    .disabled(
                        invoices.isEmpty ||
                        Double(amountText) == nil ||
                        cardNumber.filter(\.isNumber).count < 12 ||
                        expirationYear.filter(\.isNumber).count != 4 ||
                        cvc.filter(\.isNumber).count < 3
                    )
                }
            }
            .onAppear {
                guard let firstInvoice = invoices.first else { return }
                amountText = String(format: "%.2f", outstandingBalance(for: firstInvoice))
                cardholderName = firstInvoice.customer.name
            }
            .onChange(of: selectedInvoiceIndex) { _, newValue in
                guard invoices.indices.contains(newValue) else { return }
                let invoice = invoices[newValue]
                amountText = String(format: "%.2f", outstandingBalance(for: invoice))
                cardholderName = invoice.customer.name
            }
        }
    }

    private func outstandingBalance(for invoice: Invoice) -> Double {
        let netPayments = payments
            .filter { $0.invoice.id == invoice.id }
            .reduce(0) { partial, payment in
                partial + payment.amount
            }
        return max(invoice.amount - netPayments, 0)
    }
}

private struct QuickBooksRefundComposeView: View {
    @Environment(\.dismiss) private var dismiss

    let payment: Payment
    let onRefund: (Double, String?) -> Void

    @State private var amountText = ""
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Refund Payment") {
                    Text(payment.invoice.customer.name)
                    Text("Original payment: \(payment.amount.formatted(.currency(code: "USD")))")
                    TextField("Refund amount", text: $amountText)
                        .keyboardType(.decimalPad)
                    TextField("Notes", text: $note)
                }
            }
            .navigationTitle("Refund")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Refund") {
                        guard let amount = Double(amountText), amount > 0 else { return }
                        onRefund(amount, note.nilIfBlank)
                        dismiss()
                    }
                    .disabled(Double(amountText) == nil)
                }
            }
            .onAppear {
                amountText = String(format: "%.2f", payment.amount)
                note = payment.notes ?? ""
            }
        }
    }
}

private struct QuickBooksVendorComposeView: View {
    @Environment(\.dismiss) private var dismiss

    let onAdd: (String, String?, String?) -> Void

    @State private var name = ""
    @State private var email = ""
    @State private var phone = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Vendor") {
                    TextField("Vendor Name", text: $name)
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                    TextField("Phone", text: $phone)
                        .keyboardType(.phonePad)
                }
            }
            .navigationTitle("Add Vendor")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onAdd(
                            name.trimmingCharacters(in: .whitespacesAndNewlines),
                            email.nilIfBlank,
                            phone.nilIfBlank
                        )
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct QuickBooksCustomerComposeView: View {
    @Environment(\.dismiss) private var dismiss

    let onCreate: (String, String?, String?) -> Void

    @State private var name = ""
    @State private var email = ""
    @State private var phone = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Customer") {
                    TextField("Customer Name", text: $name)
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                    TextField("Phone", text: $phone)
                        .keyboardType(.phonePad)
                }
            }
            .navigationTitle("Add Customer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(
                            name.trimmingCharacters(in: .whitespacesAndNewlines),
                            email.nilIfBlank,
                            phone.nilIfBlank
                        )
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct QuickBooksCatalogItemComposeView: View {
    @Environment(\.dismiss) private var dismiss

    let onCreate: (String, Double, String?) -> Void

    @State private var name = ""
    @State private var price = ""
    @State private var description = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Catalog Item") {
                    TextField("Name", text: $name)
                    TextField("Price", text: $price)
                        .keyboardType(.decimalPad)
                    TextField("Description", text: $description)
                }
            }
            .navigationTitle("Add Catalog Item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        guard let amount = Double(price), amount >= 0 else { return }
                        onCreate(
                            name.trimmingCharacters(in: .whitespacesAndNewlines),
                            amount,
                            description.nilIfBlank
                        )
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Double(price) == nil)
                }
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
