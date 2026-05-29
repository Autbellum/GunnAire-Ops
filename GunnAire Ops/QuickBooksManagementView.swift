import SwiftUI
import SwiftData

private enum QuickBooksSyncState: String {
    case idle = "Idle"
    case syncing = "Syncing"
    case success = "Synced"
    case warning = "Warning"
    case failed = "Failed"

    var tint: Color {
        switch self {
        case .idle: return .secondary
        case .syncing: return .blue
        case .success: return .green
        case .warning: return .orange
        case .failed: return .red
        }
    }

    var icon: String {
        switch self {
        case .idle: return "circle"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }
}

private struct QuickBooksSyncResourceStatus: Identifiable {
    let id: String
    let name: String
    let lane: String
    let required: Bool
    var state: QuickBooksSyncState
    var detail: String
    var count: Int?
    var updatedAt: Date?
}

struct QuickBooksManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var quickBooksDataAPI = QuickBooksDataAPI.shared
    @Query(sort: \ServiceCall.scheduledDate, order: .reverse) private var serviceCalls: [ServiceCall]
    @Query(sort: \Customer.name, order: .forward) private var localCustomers: [Customer]
    @Query(sort: \Invoice.createdAt, order: .reverse) private var localInvoices: [Invoice]
    @Query(sort: \Payment.date, order: .reverse) private var localPayments: [Payment]
    private let liveAPI = QuickBooksAPI.shared

    @State private var customers: [QuickBooksCustomer] = []
    @State private var items: [QuickBooksItem] = []
    @State private var estimates: [QuickBooksEstimate] = []
    @State private var invoices: [QuickBooksInvoice] = []
    @State private var bills: [QuickBooksBill] = []
    @State private var purchases: [QuickBooksPurchase] = []
    @State private var vendors: [QuickBooksVendor] = []
    @State private var payments: [QuickBooksPayment] = []
    @State private var salesReceipts: [QuickBooksSalesReceipt] = []
    @State private var deposits: [QuickBooksDeposit] = []
    @State private var paymentMethods: [QuickBooksPaymentMethod] = []
    @State private var storedCards: [QuickBooksPaymentsCardRecord] = []
    @State private var paymentReceipts: [String: QuickBooksPaymentsPaymentReceipt] = [:]

    @State private var showingNewCustomerSheet = false
    @State private var showingNewCatalogItemSheet = false
    @State private var showingNewEstimateSheet = false
    @State private var showingNewInvoiceSheet = false
    @State private var showingNewSalesReceiptSheet = false
    @State private var showingNewBillSheet = false
    @State private var showingNewPurchaseSheet = false
    @State private var showingNewVendorSheet = false
    @State private var showingNewPaymentSheet = false
    @State private var showingProcessCardPaymentSheet = false
    @State private var showingRefundPaymentSheet = false
    @State private var showingStoreCardSheet = false

    @State private var isLoading = false
    @State private var statusMessage = "Connect QuickBooks in Settings to start live sync."
    @State private var actionMessage: String?
    @State private var syncResourceStatuses: [QuickBooksSyncResourceStatus] = Self.defaultSyncResourceStatuses
    @State private var lastSuccessfulSyncAt: Date? = UserDefaults.standard.object(forKey: "QuickBooksLastSuccessfulSyncAt") as? Date
    @State private var lastSyncStartedAt: Date?
    @State private var activePaymentInvoiceID: String?
    @State private var paymentToRefund: Payment?
    @State private var quickBooksReconnectRequired = false

    private var isAuthenticated: Bool {
        quickBooksDataAPI.isAuthenticated
    }

    private var quickBooksPaymentsEnabled: Bool {
        quickBooksDataAPI.canUseQuickBooksPaymentsAPI
    }

    private var quickBooksPaymentsUnavailableMessage: String {
        if let diagnostic = quickBooksDataAPI.paymentsAuthorizationDiagnostic {
            return diagnostic
        }
        return Config.QuickBooks.enablePaymentsScope
            ? "QuickBooks Payments is not authorized for this connection yet."
            : "Enable the QuickBooks Payments scope before using live payment endpoints."
    }

    private var quickBooksConfigReady: Bool {
        quickBooksDataAPI.canStartOAuthFlow
    }

    private var quickBooksConfigurationWarnings: [String] {
        var warnings = Config.QuickBooks.configurationWarnings
        if let diagnostic = quickBooksDataAPI.scopeReauthorizationDiagnostic {
            warnings.append(diagnostic)
        } else if Config.QuickBooks.enablePaymentsScope,
                  quickBooksDataAPI.isAuthenticated,
                  !quickBooksDataAPI.savedSessionIncludesPaymentsScope {
            warnings.append("QuickBooks Payments features are enabled. Reconnect QuickBooks so Intuit can authorize the \(Config.QuickBooks.paymentsScope) scope for this company.")
        }
        return warnings
    }

    private var salesItemConfigReady: Bool {
        Config.QuickBooks.hasExplicitDefaultSalesItemRef
    }

    private var expenseAccountConfigReady: Bool {
        Config.QuickBooks.hasExplicitDefaultExpenseAccountRef
    }

    private var paymentAccountConfigReady: Bool {
        Config.QuickBooks.hasExplicitDefaultPaymentAccountRef
    }

    private var catalogItemCreationReady: Bool {
        QuickBooksItemAccountResolver.incomeAccountRef(from: items) != nil
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

    private var totalPurchaseAmount: Double {
        purchases.reduce(0) { $0 + $1.TotalAmt }
    }

    private var totalPaymentAmount: Double {
        payments.reduce(0) { $0 + $1.TotalAmt }
    }

    private var totalSalesReceiptAmount: Double {
        salesReceipts.reduce(0) { $0 + $1.TotalAmt }
    }

    private var totalDepositAmount: Double {
        deposits.reduce(0) { $0 + $1.TotalAmt }
    }

    private var hasQuickBooksCardMethod: Bool {
        paymentMethods.contains { $0.Name.caseInsensitiveCompare("QuickBooks Card") == .orderedSame }
    }

    private var hasQuickBooksACHMethod: Bool {
        paymentMethods.contains { $0.Name.caseInsensitiveCompare("QuickBooks ACH") == .orderedSame }
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
        guard let realmID = quickBooksDataAPI.realmID else { return nil }
        return URL(string: "https://app.qbo.intuit.com/app/homepage?companyId=\(realmID)")
    }

    private var syncFailureCount: Int {
        syncResourceStatuses.filter { $0.state == .failed }.count
    }

    private var syncWarningCount: Int {
        syncResourceStatuses.filter { $0.state == .warning }.count
    }

    private var accountingStatuses: [QuickBooksSyncResourceStatus] {
        syncResourceStatuses.filter { $0.lane == "Accounting" }
    }

    private var paymentStatuses: [QuickBooksSyncResourceStatus] {
        syncResourceStatuses.filter { $0.lane == "Payments" }
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
                            value: quickBooksDataAPI.realmID ?? "Not connected"
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

                        ForEach(quickBooksConfigurationWarnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    Section("Sync Health") {
                        connectionRow(
                            title: "Last Successful Sync",
                            value: lastSuccessfulSyncAt?.formatted(date: .abbreviated, time: .shortened) ?? "Not yet"
                        )
                        connectionRow(
                            title: "Token Expires",
                            value: quickBooksDataAPI.tokenExpiration?.formatted(date: .abbreviated, time: .shortened) ?? "No active token"
                        )
                        connectionRow(
                            title: "Sync Issues",
                            value: "\(syncFailureCount) failed • \(syncWarningCount) warnings"
                        )
                        Text(quickBooksDataAPI.connectionDiagnosticSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let environmentMismatch = quickBooksDataAPI.environmentMismatchDiagnostic {
                            Label(environmentMismatch, systemImage: "arrow.triangle.2.circlepath.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        if let scopeReauthorization = quickBooksDataAPI.scopeReauthorizationDiagnostic {
                            Label(scopeReauthorization, systemImage: "key.horizontal")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        if let paymentsAuthorization = quickBooksDataAPI.paymentsAuthorizationDiagnostic {
                            Label(paymentsAuthorization, systemImage: "creditcard.trianglebadge.exclamationmark")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        if quickBooksReconnectRequired {
                            Label(
                                "Reconnect QuickBooks in Settings with a company admin, then retry sync.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)

                            if let reconnectDetail = quickBooksDataAPI.lastRefreshFailureDetail
                                ?? quickBooksDataAPI.lastAuthorizationFailureDetail {
                                Text(reconnectDetail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if syncResourceStatuses.contains(where: { $0.state != .idle }) {
                            ForEach(accountingStatuses) { status in
                                syncResourceRow(status)
                            }
                            ForEach(paymentStatuses) { status in
                                syncResourceRow(status)
                            }
                        }
                    }

                    Section("Summary") {
                        summaryRow(title: "Customers", count: customers.count)
                        summaryRow(title: "Catalog Items", count: items.count)
                        summaryRow(title: "Estimates", count: estimates.count, amount: totalEstimateAmount)
                        summaryRow(title: "Invoices", count: invoices.count, amount: totalInvoiceAmount)
                        summaryRow(title: "Bills", count: bills.count, amount: totalBillAmount)
                        summaryRow(title: "Purchases", count: purchases.count, amount: totalPurchaseAmount)
                        summaryRow(title: "Vendors", count: vendors.count)
                        summaryRow(title: "Payments", count: payments.count, amount: totalPaymentAmount)
                        summaryRow(title: "Sales Receipts", count: salesReceipts.count, amount: totalSalesReceiptAmount)
                        summaryRow(title: "Deposits", count: deposits.count, amount: totalDepositAmount)
                        summaryRow(title: "Payment Methods", count: paymentMethods.count)
                        summaryRow(title: "Stored Cards", count: storedCards.count)
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
                                    if let linkedCustomer = localCustomer(for: customer) {
                                        HStack {
                                            Button("Open Customer") {
                                                GunnAireAppIntentRouter.storeCustomerRoute(linkedCustomer.id)
                                            }
                                            .buttonStyle(.bordered)

                                            if let nextCall = serviceCalls
                                                .filter({ $0.customer.id == linkedCustomer.id && $0.status != .completed && $0.status != .cancelled })
                                                .sorted(by: { $0.scheduledDate < $1.scheduledDate })
                                                .first {
                                                Button("Open Job") {
                                                    GunnAireAppIntentRouter.storeDocumentationRoute(nextCall.id)
                                                }
                                                .buttonStyle(.bordered)
                                            }
                                        }
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
                                        let meta = [
                                            item.Sku.map { "SKU \($0)" },
                                            item.PrefVendorRef?.displayName,
                                            item.PurchaseCost.map { "Cost \($0.formatted(.currency(code: "USD")))" }
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

                        Button("Add Catalog Item") { showingNewCatalogItemSheet = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .disabled(!isAuthenticated)
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

                        Button("Create Estimate") { showingNewEstimateSheet = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .disabled(!isAuthenticated || customers.isEmpty)
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
                                        Button(activePaymentInvoiceID == invoice.Id ? "Processing..." : "Record QB Payment") {
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

                                        if let localInvoice = localInvoice(for: invoice) {
                                            Button("Open Local Collections") {
                                                GunnAireAppIntentRouter.storePaymentCollectionRoute(localInvoice.id)
                                            }
                                            .buttonStyle(.bordered)
                                        }
                                    }
                                }
                            }
                        }

                        Button("Create Invoice") { showingNewInvoiceSheet = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .disabled(!isAuthenticated || customers.isEmpty)
                    }

                    Section(header: Text("Sales Receipts").foregroundColor(Color.brandGold)) {
                        if salesReceipts.isEmpty {
                            emptyState("No QuickBooks sales receipts loaded.")
                        } else {
                            ForEach(salesReceipts) { salesReceipt in
                                VStack(alignment: .leading, spacing: 6) {
                                    transactionBlock(
                                        title: salesReceipt.DocNumber ?? salesReceipt.Id,
                                        name: salesReceipt.CustomerRef?.displayName ?? "Walk-in customer",
                                        amount: salesReceipt.TotalAmt,
                                        dateText: salesReceipt.TxnDate
                                    )

                                    if let paymentMethod = salesReceipt.PaymentMethodRef?.displayName,
                                       !paymentMethod.isEmpty {
                                        Text("Payment method: \(paymentMethod)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }

                        Text("Use Sales Receipts only for walk-in or no-invoice sales. Invoice collections must use a QuickBooks Payment linked to the invoice.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button("Create Walk-In / No-Invoice Sale") { showingNewSalesReceiptSheet = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .disabled(!isAuthenticated || customers.isEmpty)
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

                        Button("Create Bill") { showingNewBillSheet = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .disabled(!isAuthenticated || vendors.isEmpty)
                    }

                    Section(header: Text("Purchases").foregroundColor(Color.brandGold)) {
                        if purchases.isEmpty {
                            emptyState("No QuickBooks purchases loaded.")
                        } else {
                            ForEach(purchases) { purchase in
                                VStack(alignment: .leading, spacing: 6) {
                                    transactionBlock(
                                        title: purchase.Id,
                                        name: purchase.EntityRef?.displayName ?? "Expense purchase",
                                        amount: purchase.TotalAmt,
                                        dateText: purchase.TxnDate
                                    )
                                    if let paymentType = purchase.PaymentType, !paymentType.isEmpty {
                                        Text("Payment type: \(paymentType)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }

                        Button("Create Purchase") { showingNewPurchaseSheet = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .disabled(!isAuthenticated || vendors.isEmpty)
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
                                VStack(alignment: .leading, spacing: 6) {
                                    transactionBlock(
                                        title: payment.Id,
                                        name: payment.CustomerRef?.displayName ?? "Unapplied payment",
                                        amount: payment.TotalAmt,
                                        dateText: payment.TxnDate
                                    )

                                    if let paymentMethod = payment.PaymentMethodRef?.displayName,
                                       !paymentMethod.isEmpty {
                                        Text("Payment method: \(paymentMethod)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }

                        Button("Record Payment") { showingNewPaymentSheet = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .disabled(!isAuthenticated || collectibleQuickBooksInvoices.isEmpty)
                    }

                    Section(header: Text("Payment Methods").foregroundColor(Color.brandGold)) {
                        if paymentMethods.isEmpty {
                            emptyState("No QuickBooks payment methods loaded.")
                        } else {
                            ForEach(paymentMethods) { method in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(method.Name)
                                        .font(.headline)
                                    Text(method.methodType ?? "Unspecified")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(method.Active == false ? "Inactive" : "Active")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }

                        Button("Ensure Card and ACH Methods") {
                            ensureStandardPaymentMethods()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.brandGold)
                        .foregroundStyle(Color.primaryBlack)
                        .disabled(!isAuthenticated || (hasQuickBooksCardMethod && hasQuickBooksACHMethod))
                    }

                    Section(header: Text("Deposits").foregroundColor(Color.brandGold)) {
                        if deposits.isEmpty {
                            emptyState("No QuickBooks deposits loaded.")
                        } else {
                            ForEach(deposits) { deposit in
                                VStack(alignment: .leading, spacing: 6) {
                                    transactionBlock(
                                        title: deposit.Id,
                                        name: deposit.DepositToAccountRef?.displayName ?? "Undeposited Funds",
                                        amount: deposit.TotalAmt,
                                        dateText: deposit.TxnDate
                                    )

                                    if let note = deposit.PrivateNote, !note.isEmpty {
                                        Text(note)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
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
                        .disabled(!quickBooksPaymentsEnabled || collectibleLocalInvoices.isEmpty)

                        Button("Store Card") {
                            showingStoreCardSheet = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.brandGold)
                        .foregroundStyle(Color.primaryBlack)
                        .disabled(!quickBooksPaymentsEnabled || customers.isEmpty)

                        Text("Stored cards are fetched and created with the customer-scoped QuickBooks Payments Cards API.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if storedCards.isEmpty {
                            Text("No stored QuickBooks payment cards loaded.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(storedCards.prefix(10)) { card in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(card.name ?? "Stored Card")
                                        .font(.headline)
                                    Text(card.number ?? "Masked number unavailable")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    if let cardType = card.cardType, !cardType.isEmpty {
                                        Text(cardType)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }

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
                                    if let chargeID = payment.quickBooksChargeID,
                                       let receipt = paymentReceipts[chargeID] {
                                        if let amount = receipt.amount, !amount.isEmpty {
                                            Text("Receipt amount: \(amount)")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        if let link = receipt.links?.first(where: { ($0.rel ?? "").localizedCaseInsensitiveContains("receipt") || ($0.rel ?? "").localizedCaseInsensitiveContains("self") }),
                                           let href = link.href,
                                           let url = URL(string: href) {
                                            Link("Open Payment Receipt", destination: url)
                                                .font(.caption2)
                                        }
                                    } else if payment.quickBooksChargeID?.isEmpty == false {
                                        Button("Load Payment Receipt") {
                                            loadPaymentReceipt(for: payment)
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(!quickBooksPaymentsEnabled)
                                    }
                                    if payment.needsQuickBooksAttention,
                                       let detail = payment.quickBooksAccountingSyncDetail,
                                       !detail.isEmpty {
                                        Text("Needs follow-up: \(detail)")
                                            .font(.caption2)
                                            .foregroundColor(.orange)
                                    }
                                    if payment.needsQuickBooksAttention {
                                        Button("Retry QuickBooks Sync") {
                                            retryQuickBooksFollowUp(for: payment)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(Color.brandGold)
                                        .foregroundStyle(Color.primaryBlack)
                                    }
                                    if !payment.isRefund, payment.amount > 0 {
                                        Button("Refund This Payment") {
                                            paymentToRefund = payment
                                            showingRefundPaymentSheet = true
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(!quickBooksPaymentsEnabled)
                                    }
                                    HStack {
                                        Button("Open Customer") {
                                            GunnAireAppIntentRouter.storeCustomerRoute(payment.invoice.customer.id)
                                        }
                                        .buttonStyle(.bordered)

                                        if let linkedCall = localServiceCall(for: payment.invoice) {
                                            Button("Open Job") {
                                                GunnAireAppIntentRouter.storeDocumentationRoute(linkedCall.id)
                                            }
                                            .buttonStyle(.bordered)
                                        }

                                        Button("Open Collections") {
                                            GunnAireAppIntentRouter.storePaymentCollectionRoute(payment.invoice.id)
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
                    QuickBooksCatalogItemComposeView(vendors: vendors) { draft in
                        createCatalogItem(draft)
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
                .sheet(isPresented: $showingNewSalesReceiptSheet) {
                    QuickBooksDocumentComposeView(
                        title: "Create Walk-In / No-Invoice Sale",
                        customerRefs: customers.map(\.reference)
                    ) { customerRef, amount, note in
                        createSalesReceipt(customerRef: customerRef, amount: amount, note: note)
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
                .sheet(isPresented: $showingNewPurchaseSheet) {
                    QuickBooksPurchaseComposeView(vendorRefs: vendors.map(\.reference)) { vendorRef, amount, note, paymentType in
                        createPurchase(vendorRef: vendorRef, amount: amount, note: note, paymentType: paymentType)
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
                    QuickBooksPaymentComposeView(
                        invoices: collectibleQuickBooksInvoices,
                        paymentMethods: paymentMethods
                    ) { invoice, amount, note, paymentMethodRef in
                        createPayment(for: invoice, amount: amount, note: note, paymentMethodRef: paymentMethodRef)
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
                .sheet(isPresented: $showingStoreCardSheet) {
                    QuickBooksStoreCardComposeView(customers: customers) { customer, input in
                        storeCard(input, for: customer)
                    }
                    .tint(Color.brandGold)
                }
                .onAppear {
                    QuickBooksDataAPI.shared.loadTokens()
                    if isAuthenticated {
                        syncAllQuickBooksData()
                    } else if !quickBooksConfigReady {
                        statusMessage = "QuickBooks client credentials are missing on this Mac. Add them in Config/Local.xcconfig, then reconnect QuickBooks."
                    } else {
                        statusMessage = "QuickBooks is not connected. Open Settings to authenticate."
                    }
                }
            }
        }
    }

    private func syncAllQuickBooksData() {
        guard isAuthenticated else {
            statusMessage = quickBooksConfigReady
                ? "QuickBooks is not connected. Open Settings to authenticate."
                : "QuickBooks client credentials are missing on this Mac. Add them in Config/Local.xcconfig, then reconnect QuickBooks."
            return
        }

        isLoading = true
        actionMessage = nil
        quickBooksReconnectRequired = false
        lastSyncStartedAt = Date()
        resetSyncStatusesForRun()
        statusMessage = "Syncing customers, catalog, estimates, invoices, sales receipts, bills, purchases, vendors, payments, payment methods, stored cards, and deposits from QuickBooks..."

        QuickBooksDataAPI.shared.refreshTokensIfNeeded { tokenReady in
            guard tokenReady else {
                let detail = QuickBooksDataAPI.shared.lastRefreshFailureDetail
                    ?? "Reconnect QuickBooks. The saved token could not be refreshed."
                isLoading = false
                quickBooksReconnectRequired = true
                markAllSyncStatusesFailed(detail)
                statusMessage = "QuickBooks reconnect required. \(detail)"
                return
            }

            runQuickBooksResourceSync()
        }
    }

    private func runQuickBooksResourceSync() {
        Task { @MainActor in
            var failures: [String] = []

            @MainActor
            func run<T>(
                id: String,
                required: Bool,
                fetch: (@escaping (Result<[T], Error>) -> Void) -> Void,
                apply: @escaping ([T]) -> Void
            ) async -> Bool {
                guard !quickBooksReconnectRequired else {
                    return false
                }

                updateSyncStatus(id: id, state: .syncing, detail: "Loading...", count: nil)
                let result: Result<[T], Error> = await withCheckedContinuation { continuation in
                    fetch { result in
                        DispatchQueue.main.async {
                            continuation.resume(returning: result)
                        }
                    }
                }

                switch result {
                case .success(let records):
                    apply(records)
                    updateSyncStatus(id: id, state: .success, detail: "Loaded \(records.count) records.", count: records.count)
                    return true
                case .failure(let error):
                    let message = userFacingQuickBooksMessage(for: error)
                    if let qbError = error as? QuickBooksDataAPI.QBError,
                       qbError.requiresReconnect {
                        quickBooksReconnectRequired = true
                        updateSyncStatus(id: id, state: .failed, detail: message, count: nil)
                        markPendingSyncStatusesFailed("Reconnect QuickBooks. The saved QuickBooks session was rejected before this resource could sync.")
                    } else {
                        updateSyncStatus(id: id, state: required ? .failed : .warning, detail: message, count: nil)
                    }
                    let prefix = syncResourceStatuses.first(where: { $0.id == id })?.name ?? id
                    failures.append("\(prefix): \(message)")
                    return !quickBooksReconnectRequired
                }
            }

            guard await run(id: "customers", required: true, fetch: liveAPI.fetchCustomers, apply: { records in
                customers = records.sorted { $0.DisplayName.localizedCaseInsensitiveCompare($1.DisplayName) == .orderedAscending }
            }) else { finishQuickBooksResourceSync(with: failures); return }

            guard await run(id: "catalog", required: true, fetch: liveAPI.fetchItems, apply: { records in
                items = records.sorted { $0.Name.localizedCaseInsensitiveCompare($1.Name) == .orderedAscending }
            }) else { finishQuickBooksResourceSync(with: failures); return }

            guard await run(id: "estimates", required: true, fetch: liveAPI.fetchEstimates, apply: { records in estimates = records }) else { finishQuickBooksResourceSync(with: failures); return }
            guard await run(id: "invoices", required: true, fetch: liveAPI.fetchInvoices, apply: { records in invoices = records }) else { finishQuickBooksResourceSync(with: failures); return }
            guard await run(id: "bills", required: true, fetch: liveAPI.fetchBills, apply: { records in bills = records }) else { finishQuickBooksResourceSync(with: failures); return }
            guard await run(id: "purchases", required: true, fetch: liveAPI.fetchPurchases, apply: { records in purchases = records }) else { finishQuickBooksResourceSync(with: failures); return }

            guard await run(id: "vendors", required: true, fetch: liveAPI.fetchVendors, apply: { records in
                vendors = records.sorted { $0.DisplayName.localizedCaseInsensitiveCompare($1.DisplayName) == .orderedAscending }
            }) else { finishQuickBooksResourceSync(with: failures); return }

            guard await run(id: "payments", required: true, fetch: liveAPI.fetchPayments, apply: { records in payments = records }) else { finishQuickBooksResourceSync(with: failures); return }

            guard await run(id: "paymentMethods", required: true, fetch: liveAPI.fetchPaymentMethods, apply: { records in
                paymentMethods = records.sorted { $0.Name.localizedCaseInsensitiveCompare($1.Name) == .orderedAscending }
            }) else { finishQuickBooksResourceSync(with: failures); return }

            if QuickBooksDataAPI.shared.canUseQuickBooksPaymentsAPI {
                guard await run(id: "storedCards", required: false, fetch: { completion in
                    liveAPI.fetchCards(forCustomerIDs: customers.map(\.Id), completion: completion)
                }, apply: { records in
                    storedCards = records
                }) else { finishQuickBooksResourceSync(with: failures); return }
            } else if Config.QuickBooks.enablePaymentsScope {
                storedCards = []
                updateSyncStatus(
                    id: "storedCards",
                    state: .warning,
                    detail: "Skipped because this QuickBooks token is not authorized for \(Config.QuickBooks.paymentsScope). Accounting sync remains active.",
                    count: 0
                )
            } else {
                updateSyncStatus(
                    id: "storedCards",
                    state: .warning,
                    detail: "Skipped because QB_ENABLE_PAYMENTS_SCOPE is off for Accounting-only login.",
                    count: 0
                )
            }

            guard await run(id: "salesReceipts", required: true, fetch: liveAPI.fetchSalesReceipts, apply: { records in salesReceipts = records }) else { finishQuickBooksResourceSync(with: failures); return }
            guard await run(id: "deposits", required: true, fetch: liveAPI.fetchDeposits, apply: { records in deposits = records }) else { finishQuickBooksResourceSync(with: failures); return }

            finishQuickBooksResourceSync(with: failures)
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

    private func createCatalogItem(_ draft: QuickBooksCatalogItemDraft) {
        guard let incomeAccountRef = QuickBooksItemAccountResolver.incomeAccountRef(from: items) else {
            actionMessage = QuickBooksDataAPI.QBError.missingDefaultIncomeAccountRef.localizedDescription
            return
        }

        let payload = QuickBooksItemCreate(
            Name: draft.name,
            ItemType: draft.itemType.rawValue,
            Description: draft.description,
            Sku: draft.sku,
            PurchaseDesc: draft.purchaseDescription ?? draft.description,
            UnitPrice: draft.price,
            PurchaseCost: draft.purchaseCost,
            Taxable: nil,
            IncomeAccountRef: incomeAccountRef,
            ExpenseAccountRef: QuickBooksItemAccountResolver.configuredExpenseAccountRef(),
            PrefVendorRef: draft.vendorRef
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
        guard salesItemConfigReady else {
            actionMessage = "Set QB_DEFAULT_ITEM_REF to a valid QuickBooks sales item before creating estimates."
            return
        }

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
        guard salesItemConfigReady else {
            actionMessage = "Set QB_DEFAULT_ITEM_REF to a valid QuickBooks sales item before creating invoices."
            return
        }

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

    private func createSalesReceipt(customerRef: QuickBooksReference, amount: Double, note: String?) {
        guard salesItemConfigReady else {
            actionMessage = "Set QB_DEFAULT_ITEM_REF to a valid QuickBooks sales item before creating sales receipts."
            return
        }

        let payload = QuickBooksSalesReceiptCreate(
            CustomerRef: customerRef,
            Line: [salesLineItem(amount: amount, note: note)],
            PrivateNote: [note, "GunnAire no-invoice sale. Do not use this path for invoice collections."].compactMap { $0 }.joined(separator: "\n"),
            PaymentMethodRef: nil,
            CreditCardPayment: nil
        )

        performAction(message: "Creating sales receipt in QuickBooks...") {
            liveAPI.createSalesReceipt(payload) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let salesReceipt):
                        actionMessage = "Sales receipt created: \(salesReceipt.DocNumber ?? salesReceipt.Id)"
                        syncAllQuickBooksData()
                    case .failure(let error):
                        actionMessage = "Sales receipt creation failed: \(error.localizedDescription)"
                        isLoading = false
                    }
                }
            }
        }
    }

    private func createBill(vendorRef: QuickBooksReference, amount: Double, note: String?) {
        guard expenseAccountConfigReady else {
            actionMessage = "Set QB_DEFAULT_EXPENSE_ACCOUNT_REF to a valid QBO expense Account.Id before creating bills."
            return
        }

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

    private func createPurchase(vendorRef: QuickBooksReference, amount: Double, note: String?, paymentType: String) {
        guard expenseAccountConfigReady else {
            actionMessage = "Set QB_DEFAULT_EXPENSE_ACCOUNT_REF to a valid QBO expense Account.Id before creating purchases."
            return
        }
        guard paymentAccountConfigReady else {
            actionMessage = "Set QB_DEFAULT_PAYMENT_ACCOUNT_REF to a valid QBO bank or credit-card Account.Id before creating purchases."
            return
        }

        let expenseAccount = QuickBooksReference(value: Config.QuickBooks.defaultExpenseAccountRef, name: nil)
        let paymentAccount = QuickBooksReference(value: Config.QuickBooks.defaultPaymentAccountRef, name: nil)
        let payload = QuickBooksPurchaseCreate(
            AccountRef: paymentAccount,
            EntityRef: vendorRef,
            Line: [QuickBooksBillLine(amount: amount, description: note, accountRef: expenseAccount)],
            PaymentType: paymentType,
            PrivateNote: note
        )

        performAction(message: "Creating purchase in QuickBooks...") {
            liveAPI.createPurchase(payload) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let purchase):
                        actionMessage = "Purchase created: \(purchase.Id)"
                        syncAllQuickBooksData()
                    case .failure(let error):
                        actionMessage = "Purchase creation failed: \(error.localizedDescription)"
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

    private func createPayment(for invoice: QuickBooksInvoice, amount: Double, note: String?, paymentMethodRef: QuickBooksReference?) {
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
            ],
            PaymentMethodRef: paymentMethodRef,
            CreditCardPayment: nil
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

    private func ensureStandardPaymentMethods() {
        performAction(message: "Ensuring QuickBooks payment methods...") {
            let group = DispatchGroup()
            var failures: [String] = []

            if !hasQuickBooksCardMethod {
                group.enter()
                liveAPI.createPaymentMethod(
                    QuickBooksPaymentMethodCreate(Name: "QuickBooks Card", methodType: "CREDIT_CARD")
                ) { result in
                    DispatchQueue.main.async {
                        if case .failure(let error) = result {
                            failures.append("Card method: \(error.localizedDescription)")
                        }
                        group.leave()
                    }
                }
            }

            if !hasQuickBooksACHMethod {
                group.enter()
                liveAPI.createPaymentMethod(
                    QuickBooksPaymentMethodCreate(Name: "QuickBooks ACH", methodType: "NON_CREDIT_CARD")
                ) { result in
                    DispatchQueue.main.async {
                        if case .failure(let error) = result {
                            failures.append("ACH method: \(error.localizedDescription)")
                        }
                        group.leave()
                    }
                }
            }

            group.notify(queue: .main) {
                if failures.isEmpty {
                    actionMessage = "QuickBooks payment methods are ready."
                } else {
                    actionMessage = failures.joined(separator: "\n")
                }
                syncAllQuickBooksData()
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
            ],
            PaymentMethodRef: nil,
            CreditCardPayment: nil
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
        guard quickBooksPaymentsEnabled else {
            actionMessage = quickBooksPaymentsUnavailableMessage
            return
        }

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
                                quickBooksClientTransID: result.clientTransactionID,
                                quickBooksAccountingSyncStatus: result.accountingError == nil ? "synced" : "needs_attention",
                                quickBooksAccountingSyncDetail: result.accountingError,
                                processorSyncStatus: "captured",
                                processorSyncDetail: nil,
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

    private func storeCard(_ input: QuickBooksPaymentsCardInput, for customer: QuickBooksCustomer) {
        guard quickBooksPaymentsEnabled else {
            actionMessage = quickBooksPaymentsUnavailableMessage
            return
        }

        performAction(message: "Storing QuickBooks card for \(customer.DisplayName)...") {
            Task {
                do {
                    let token = try await QuickBooksPaymentsService.shared.createStandaloneCardToken(input)
                    let card = try await withCheckedThrowingContinuation { continuation in
                        liveAPI.createStoredCard(QuickBooksPaymentsStoredCardCreateRequest(value: token.value), forCustomerID: customer.Id) { result in
                            continuation.resume(with: result)
                        }
                    }
                    await MainActor.run {
                        actionMessage = "Stored QuickBooks card for \(customer.DisplayName): \(card.number ?? card.id). Next step: add a local StoredPaymentMethod model to persist the customer-card mapping before using this card for recurring billing."
                        syncAllQuickBooksData()
                    }
                } catch {
                    await MainActor.run {
                        actionMessage = "Store card failed: \(error.localizedDescription)"
                        isLoading = false
                    }
                }
            }
        }
    }

    private func refundPayment(_ payment: Payment, amount: Double, note: String?) {
        guard quickBooksPaymentsEnabled else {
            actionMessage = quickBooksPaymentsUnavailableMessage
            return
        }

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
                                quickBooksClientTransID: result.clientTransactionID,
                                quickBooksRefundReceiptID: result.refundReceipt?.Id,
                                quickBooksAccountingSyncStatus: result.accountingError == nil ? "synced" : "needs_attention",
                                quickBooksAccountingSyncDetail: result.accountingError,
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

    private func retryQuickBooksFollowUp(for payment: Payment) {
        performAction(message: "Retrying QuickBooks follow-up...") {
            Task {
                do {
                    if payment.isRefund {
                        let receipt = try await QuickBooksPaymentsService.shared.retryRefundReceiptSync(for: payment)
                        await MainActor.run {
                            payment.quickBooksRefundReceiptID = receipt.Id
                            payment.quickBooksAccountingSyncStatus = "synced"
                            payment.quickBooksAccountingSyncDetail = nil
                            actionMessage = "QuickBooks refund receipt sync completed."
                            syncAllQuickBooksData()
                        }
                    } else {
                        let accountingPayment = try await QuickBooksPaymentsService.shared.retryAccountingSync(for: payment)
                        await MainActor.run {
                            payment.quickBooksID = accountingPayment.Id
                            payment.quickBooksAccountingSyncStatus = "synced"
                            payment.quickBooksAccountingSyncDetail = nil
                            actionMessage = "QuickBooks accounting payment sync completed."
                            syncAllQuickBooksData()
                        }
                    }
                } catch {
                    await MainActor.run {
                        payment.quickBooksAccountingSyncStatus = "needs_attention"
                        payment.quickBooksAccountingSyncDetail = error.localizedDescription
                        actionMessage = "QuickBooks follow-up retry failed: \(error.localizedDescription)"
                        isLoading = false
                    }
                }
            }
        }
    }

    private func loadPaymentReceipt(for payment: Payment) {
        guard let chargeID = payment.quickBooksChargeID?.trimmingCharacters(in: .whitespacesAndNewlines), !chargeID.isEmpty else {
            actionMessage = "This payment does not have a QuickBooks charge ID."
            return
        }
        guard quickBooksPaymentsEnabled else {
            actionMessage = quickBooksPaymentsUnavailableMessage
            return
        }

        performAction(message: "Loading QuickBooks payment receipt...") {
            liveAPI.fetchPaymentReceipt(id: chargeID) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let receipt):
                        paymentReceipts[chargeID] = receipt
                        actionMessage = "Payment receipt loaded."
                    case .failure(let error):
                        actionMessage = "Payment receipt lookup failed: \(error.localizedDescription)"
                    }
                    isLoading = false
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
        if invoice.status.caseInsensitiveCompare("paid") == .orderedSame {
            return 0
        }
        let netPayments = localPayments
            .filter { $0.invoice.id == invoice.id }
            .reduce(0) { partial, payment in
                partial + payment.amount
            }
        return max(invoice.amount - netPayments, 0)
    }

    private func localCustomer(for quickBooksCustomer: QuickBooksCustomer) -> Customer? {
        localCustomers.first {
            ($0.quickBooksID == quickBooksCustomer.Id) ||
            $0.name.caseInsensitiveCompare(quickBooksCustomer.DisplayName) == .orderedSame
        }
    }

    private func localInvoice(for quickBooksInvoice: QuickBooksInvoice) -> Invoice? {
        localInvoices.first {
            ($0.quickBooksID == quickBooksInvoice.Id) ||
            (($0.quickBooksID == quickBooksInvoice.DocNumber) && !(quickBooksInvoice.DocNumber ?? "").isEmpty)
        }
    }

    private func localServiceCall(for invoice: Invoice) -> ServiceCall? {
        guard let serviceCallID = invoice.serviceCallID else { return nil }
        return serviceCalls.first(where: { $0.id == serviceCallID })
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

    private static var defaultSyncResourceStatuses: [QuickBooksSyncResourceStatus] {
        [
            QuickBooksSyncResourceStatus(id: "customers", name: "Customers", lane: "Accounting", required: true, state: .idle, detail: "Not synced this session.", count: nil, updatedAt: nil),
            QuickBooksSyncResourceStatus(id: "catalog", name: "Catalog", lane: "Accounting", required: true, state: .idle, detail: "Not synced this session.", count: nil, updatedAt: nil),
            QuickBooksSyncResourceStatus(id: "estimates", name: "Estimates", lane: "Accounting", required: true, state: .idle, detail: "Not synced this session.", count: nil, updatedAt: nil),
            QuickBooksSyncResourceStatus(id: "invoices", name: "Invoices", lane: "Accounting", required: true, state: .idle, detail: "Not synced this session.", count: nil, updatedAt: nil),
            QuickBooksSyncResourceStatus(id: "vendors", name: "Vendors", lane: "Accounting", required: true, state: .idle, detail: "Not synced this session.", count: nil, updatedAt: nil),
            QuickBooksSyncResourceStatus(id: "payments", name: "Payments", lane: "Accounting", required: true, state: .idle, detail: "Not synced this session.", count: nil, updatedAt: nil),
            QuickBooksSyncResourceStatus(id: "salesReceipts", name: "Sales Receipts", lane: "Accounting", required: true, state: .idle, detail: "Not synced this session.", count: nil, updatedAt: nil),
            QuickBooksSyncResourceStatus(id: "deposits", name: "Deposits", lane: "Accounting", required: true, state: .idle, detail: "Not synced this session.", count: nil, updatedAt: nil),
            QuickBooksSyncResourceStatus(id: "bills", name: "Bills", lane: "Accounting", required: true, state: .idle, detail: "Not synced this session.", count: nil, updatedAt: nil),
            QuickBooksSyncResourceStatus(id: "purchases", name: "Purchases", lane: "Accounting", required: true, state: .idle, detail: "Not synced this session.", count: nil, updatedAt: nil),
            QuickBooksSyncResourceStatus(id: "paymentMethods", name: "Payment Methods", lane: "Accounting", required: true, state: .idle, detail: "Not synced this session.", count: nil, updatedAt: nil),
            QuickBooksSyncResourceStatus(id: "storedCards", name: "Stored Cards", lane: "Payments", required: false, state: .idle, detail: "Not synced this session.", count: nil, updatedAt: nil)
        ]
    }

    private func resetSyncStatusesForRun() {
        let now = Date()
        syncResourceStatuses = Self.defaultSyncResourceStatuses.map { status in
            QuickBooksSyncResourceStatus(
                id: status.id,
                name: status.name,
                lane: status.lane,
                required: status.required,
                state: .syncing,
                detail: "Waiting for QuickBooks...",
                count: nil,
                updatedAt: now
            )
        }
    }

    private func markAllSyncStatusesFailed(_ detail: String) {
        let now = Date()
        syncResourceStatuses = syncResourceStatuses.map { status in
            QuickBooksSyncResourceStatus(
                id: status.id,
                name: status.name,
                lane: status.lane,
                required: status.required,
                state: status.required ? .failed : .warning,
                detail: detail,
                count: nil,
                updatedAt: now
            )
        }
    }

    private func markPendingSyncStatusesFailed(_ detail: String) {
        let now = Date()
        syncResourceStatuses = syncResourceStatuses.map { status in
            guard status.state == .idle || status.state == .syncing else { return status }
            return QuickBooksSyncResourceStatus(
                id: status.id,
                name: status.name,
                lane: status.lane,
                required: status.required,
                state: status.required ? .failed : .warning,
                detail: detail,
                count: nil,
                updatedAt: now
            )
        }
    }

    private func updateSyncStatus(id: String, state: QuickBooksSyncState, detail: String, count: Int?) {
        guard let index = syncResourceStatuses.firstIndex(where: { $0.id == id }) else { return }
        syncResourceStatuses[index].state = state
        syncResourceStatuses[index].detail = detail
        syncResourceStatuses[index].count = count
        syncResourceStatuses[index].updatedAt = Date()
    }

    private func finishQuickBooksResourceSync(with failures: [String]) {
        isLoading = false

        guard !quickBooksReconnectRequired else {
            let company = QuickBooksDataAPI.shared.lastRejectedRealmID
                ?? QuickBooksDataAPI.shared.realmID
                ?? "the selected QuickBooks company"
            let environment = QuickBooksDataAPI.shared.lastRejectedEnvironment
                ?? QuickBooksDataAPI.shared.currentEnvironment
            statusMessage = "QuickBooks authorization needs reconnect. Open Settings, disconnect and reconnect QuickBooks with a company admin, confirm company \(company) authorized the \(environment) app, then retry sync."
            actionMessage = failures.first ?? "QuickBooks rejected the saved app session. The app cleared the rejected token so the next sync starts from a fresh reconnect."
            return
        }

        var completedFailures = failures
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
            completedFailures.append("Local app sync: \(error.localizedDescription)")
        }

        if completedFailures.isEmpty {
            let now = Date()
            lastSuccessfulSyncAt = now
            UserDefaults.standard.set(now, forKey: "QuickBooksLastSuccessfulSyncAt")
            statusMessage = "All QuickBooks features synced successfully. Loaded \(customers.count) customers, \(items.count) catalog items, \(estimates.count) estimates, \(invoices.count) invoices, \(salesReceipts.count) sales receipts, \(bills.count) bills, \(purchases.count) purchases, \(vendors.count) vendors, \(payments.count) payments, \(paymentMethods.count) payment methods, \(storedCards.count) stored cards, and \(deposits.count) deposits."
        } else {
            statusMessage = "QuickBooks sync incomplete. Required features must sync successfully.\n" + completedFailures.joined(separator: "\n")
        }
    }

    private func userFacingQuickBooksMessage(for error: Error) -> String {
        if let qbError = error as? QuickBooksDataAPI.QBError {
            return qbError.localizedDescription
        }
        return error.localizedDescription
    }

    @ViewBuilder
    private func syncResourceRow(_ status: QuickBooksSyncResourceStatus) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: status.state.icon)
                .foregroundStyle(status.state.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(status.name)
                        .font(.subheadline)
                    Spacer()
                    if let count = status.count {
                        Text("\(count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(status.state == .failed ? .red : .secondary)
                    .lineLimit(3)
            }
        }
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

    @State private var selectedCustomerID: String?
    @State private var amountText = ""
    @State private var note = ""

    private var customerOptions: [SearchableDropdownOption] {
        customerRefs.map { SearchableDropdownOption(id: $0.value, title: $0.displayName, subtitle: $0.value) }
    }

    private var selectedCustomer: QuickBooksReference? {
        if let selectedCustomerID, let match = customerRefs.first(where: { $0.value == selectedCustomerID }) {
            return match
        }
        return customerRefs.first
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(title) {
                    if customerRefs.isEmpty {
                        Text("Sync QuickBooks customers first.")
                            .foregroundColor(.secondary)
                    } else {
                        SearchableDropdownPicker(
                            title: "Customer",
                            options: customerOptions,
                            selectedID: $selectedCustomerID,
                            placeholder: "Choose customer"
                        )
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
                        guard let selectedCustomer, let amount = Double(amountText), amount > 0 else { return }
                        onCreate(selectedCustomer, amount, note.isEmpty ? nil : note)
                        dismiss()
                    }
                    .disabled(selectedCustomer == nil || Double(amountText) == nil)
                }
            }
            .onAppear {
                selectedCustomerID = selectedCustomerID ?? customerRefs.first?.value
            }
        }
    }
}

private struct QuickBooksBillComposeView: View {
    @Environment(\.dismiss) private var dismiss

    let vendorRefs: [QuickBooksReference]
    let onCreate: (QuickBooksReference, Double, String?) -> Void

    @State private var selectedVendorID: String?
    @State private var amountText = ""
    @State private var note = ""

    private var vendorOptions: [SearchableDropdownOption] {
        vendorRefs.map { SearchableDropdownOption(id: $0.value, title: $0.displayName, subtitle: $0.value) }
    }

    private var selectedVendor: QuickBooksReference? {
        if let selectedVendorID, let match = vendorRefs.first(where: { $0.value == selectedVendorID }) {
            return match
        }
        return vendorRefs.first
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Create Bill") {
                    if vendorRefs.isEmpty {
                        Text("Sync QuickBooks vendors first.")
                            .foregroundColor(.secondary)
                    } else {
                        SearchableDropdownPicker(
                            title: "Vendor",
                            options: vendorOptions,
                            selectedID: $selectedVendorID,
                            placeholder: "Choose vendor"
                        )
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
                        guard let selectedVendor, let amount = Double(amountText), amount > 0 else { return }
                        onCreate(selectedVendor, amount, note.isEmpty ? nil : note)
                        dismiss()
                    }
                    .disabled(selectedVendor == nil || Double(amountText) == nil)
                }
            }
            .onAppear {
                selectedVendorID = selectedVendorID ?? vendorRefs.first?.value
            }
        }
    }
}

private struct QuickBooksPurchaseComposeView: View {
    @Environment(\.dismiss) private var dismiss

    let vendorRefs: [QuickBooksReference]
    let onCreate: (QuickBooksReference, Double, String?, String) -> Void

    @State private var selectedVendorID: String?
    @State private var amountText = ""
    @State private var note = ""
    @State private var paymentType = "Cash"

    private var vendorOptions: [SearchableDropdownOption] {
        vendorRefs.map { SearchableDropdownOption(id: $0.value, title: $0.displayName, subtitle: $0.value) }
    }

    private var selectedVendor: QuickBooksReference? {
        if let selectedVendorID, let match = vendorRefs.first(where: { $0.value == selectedVendorID }) {
            return match
        }
        return vendorRefs.first
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Create Purchase") {
                    if vendorRefs.isEmpty {
                        Text("Sync QuickBooks vendors first.")
                            .foregroundColor(.secondary)
                    } else {
                        SearchableDropdownPicker(
                            title: "Vendor",
                            options: vendorOptions,
                            selectedID: $selectedVendorID,
                            placeholder: "Choose vendor"
                        )
                    }

                    Menu {
                        Button("Cash") { paymentType = "Cash" }
                        Button("Check") { paymentType = "Check" }
                        Button("Credit Card") { paymentType = "CreditCard" }
                    } label: {
                        HStack {
                            Text("Payment Type")
                            Spacer()
                            Text(paymentType == "CreditCard" ? "Credit Card" : paymentType)
                                .foregroundColor(.secondary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                        }
                    }

                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                    TextField("Notes", text: $note)
                }
            }
            .navigationTitle("Create Purchase")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        guard let selectedVendor, let amount = Double(amountText), amount > 0 else { return }
                        onCreate(selectedVendor, amount, note.isEmpty ? nil : note, paymentType)
                        dismiss()
                    }
                    .disabled(selectedVendor == nil || Double(amountText) == nil)
                }
            }
            .onAppear {
                selectedVendorID = selectedVendorID ?? vendorRefs.first?.value
            }
        }
    }
}

private struct QuickBooksPaymentComposeView: View {
    @Environment(\.dismiss) private var dismiss

    let invoices: [QuickBooksInvoice]
    let paymentMethods: [QuickBooksPaymentMethod]
    let onAdd: (QuickBooksInvoice, Double, String?, QuickBooksReference?) -> Void

    @State private var selectedInvoiceID: String?
    @State private var selectedPaymentMethodID: String?
    @State private var amountText = ""
    @State private var note = ""

    private var invoiceOptions: [SearchableDropdownOption] {
        invoices.map { invoice in
            let title = "\(invoice.DocNumber ?? invoice.Id) · \(invoice.CustomerRef.displayName)"
            let balance = invoice.Balance ?? invoice.TotalAmt
            return SearchableDropdownOption(
                id: invoice.Id,
                title: title,
                subtitle: balance.formatted(.currency(code: "USD"))
            )
        }
    }

    private var paymentMethodOptions: [SearchableDropdownOption] {
        paymentMethods.map { SearchableDropdownOption(id: $0.Id, title: $0.Name) }
    }

    private var selectedInvoice: QuickBooksInvoice? {
        if let selectedInvoiceID, let match = invoices.first(where: { $0.Id == selectedInvoiceID }) {
            return match
        }
        return invoices.first
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Record Payment") {
                    if invoices.isEmpty {
                        Text("Sync QuickBooks invoices first.")
                            .foregroundColor(.secondary)
                    } else {
                        SearchableDropdownPicker(
                            title: "Invoice",
                            options: invoiceOptions,
                            selectedID: $selectedInvoiceID,
                            placeholder: "Choose invoice"
                        )

                        SearchableDropdownPicker(
                            title: "Payment Method",
                            options: paymentMethodOptions,
                            selectedID: $selectedPaymentMethodID,
                            placeholder: "None",
                            showsClearButton: true
                        )
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
                        guard let selectedInvoice, let amount = Double(amountText), amount > 0 else { return }
                        let paymentMethodRef = paymentMethods.first(where: { $0.Id == selectedPaymentMethodID })?.reference
                        onAdd(selectedInvoice, amount, note.isEmpty ? nil : note, paymentMethodRef)
                        dismiss()
                    }
                    .disabled(selectedInvoice == nil || Double(amountText) == nil)
                }
            }
            .onAppear {
                selectedInvoiceID = selectedInvoiceID ?? invoices.first?.Id
                if let selectedInvoice, amountText.isEmpty {
                    amountText = String(format: "%.2f", max(selectedInvoice.Balance ?? selectedInvoice.TotalAmt, 0))
                }
                if selectedPaymentMethodID == nil {
                    selectedPaymentMethodID = paymentMethods.first(where: { $0.Name.caseInsensitiveCompare("QuickBooks Card") == .orderedSame })?.Id
                        ?? paymentMethods.first?.Id
                }
            }
            .onChange(of: selectedInvoiceID) { _, _ in
                guard let invoice = selectedInvoice else { return }
                amountText = String(format: "%.2f", max(invoice.Balance ?? invoice.TotalAmt, 0))
            }
        }
    }
}

private struct QuickBooksStoreCardComposeView: View {
    @Environment(\.dismiss) private var dismiss

    let customers: [QuickBooksCustomer]
    let onStore: (QuickBooksCustomer, QuickBooksPaymentsCardInput) -> Void

    @State private var selectedCustomerID: String?
    @State private var cardholderName = ""
    @State private var cardNumber = ""
    @State private var expirationMonth = ""
    @State private var expirationYear = ""
    @State private var cvc = ""
    @State private var streetAddress = ""
    @State private var city = ""
    @State private var region = ""
    @State private var postalCode = ""

    private var selectedCustomer: QuickBooksCustomer? {
        if let selectedCustomerID, let match = customers.first(where: { $0.Id == selectedCustomerID }) {
            return match
        }
        return customers.first
    }

    private var customerOptions: [SearchableDropdownOption] {
        customers.map { customer in
            SearchableDropdownOption(
                id: customer.Id,
                title: customer.DisplayName,
                subtitle: customer.PrimaryEmailAddr?.Address ?? customer.PrimaryPhone?.FreeFormNumber
            )
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Customer") {
                    if customers.isEmpty {
                        Text("Sync QuickBooks customers before storing a card.")
                            .foregroundColor(.secondary)
                    } else {
                        SearchableDropdownPicker(
                            title: "QuickBooks Customer",
                            options: customerOptions,
                            selectedID: $selectedCustomerID,
                            placeholder: "Choose customer"
                        )
                    }
                }

                Section("Store Card") {
                    TextField("Cardholder name", text: $cardholderName)
                    SecureField("Card number", text: $cardNumber)
                        .keyboardType(.numberPad)
                        .privacySensitive()
                    TextField("Exp MM", text: $expirationMonth)
                        .keyboardType(.numberPad)
                    TextField("Exp YYYY", text: $expirationYear)
                        .keyboardType(.numberPad)
                    SecureField("CVC", text: $cvc)
                        .keyboardType(.numberPad)
                        .privacySensitive()
                    TextField("Street Address", text: $streetAddress)
                    TextField("City", text: $city)
                    TextField("State", text: $region)
                    TextField("Postal Code", text: $postalCode)
                        .keyboardType(.numbersAndPunctuation)
                    Text("QuickBooks requires stored cards to be attached to a customer. Card number and CVC are only used to create a Payments token and are not saved locally.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Store Card")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Store") {
                        guard let selectedCustomer else { return }
                        onStore(
                            selectedCustomer,
                            QuickBooksPaymentsCardInput(
                                cardholderName: cardholderName,
                                cardNumber: cardNumber.filter(\.isNumber),
                                expMonth: expirationMonth.filter(\.isNumber),
                                expYear: expirationYear.filter(\.isNumber),
                                cvc: cvc.filter(\.isNumber),
                                postalCode: postalCode.nilIfBlank,
                                addressLine: streetAddress.nilIfBlank,
                                city: city.nilIfBlank,
                                region: region.nilIfBlank,
                                country: "US"
                            )
                        )
                        dismiss()
                    }
                    .disabled(
                        selectedCustomer == nil ||
                        cardholderName.isEmpty ||
                        cardNumber.filter(\.isNumber).count < 12 ||
                        expirationMonth.filter(\.isNumber).isEmpty ||
                        expirationYear.filter(\.isNumber).count != 4 ||
                        cvc.filter(\.isNumber).count < 3
                    )
                }
            }
            .onAppear {
                selectedCustomerID = selectedCustomerID ?? customers.first?.Id
                if let selectedCustomer, cardholderName.isEmpty {
                    cardholderName = selectedCustomer.DisplayName
                }
            }
            .onChange(of: selectedCustomerID) { _, _ in
                if let selectedCustomer, cardholderName.isEmpty {
                    cardholderName = selectedCustomer.DisplayName
                }
            }
        }
    }
}

private struct QuickBooksCardChargeComposeView: View {
    @Environment(\.dismiss) private var dismiss

    let invoices: [Invoice]
    let payments: [Payment]
    let onProcess: (Invoice, Double, QuickBooksPaymentsCardInput, String?) -> Void

    @State private var selectedInvoiceID: String?
    @State private var amountText = ""
    @State private var note = ""
    @State private var cardholderName = ""
    @State private var cardNumber = ""
    @State private var expirationMonth = ""
    @State private var expirationYear = ""
    @State private var cvc = ""
    @State private var postalCode = ""

    private var selectedInvoice: Invoice? {
        if let selectedInvoiceID, let match = invoices.first(where: { $0.id.uuidString == selectedInvoiceID }) {
            return match
        }
        return invoices.first
    }

    private var invoiceOptions: [SearchableDropdownOption] {
        invoices.map { invoice in
            SearchableDropdownOption(
                id: invoice.id.uuidString,
                title: "\(invoice.customer.name) · \(invoice.amount.formatted(.currency(code: "USD")))",
                subtitle: invoice.quickBooksID.map { "QBO \($0)" }
            )
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Process Card Charge") {
                    if invoices.isEmpty {
                        Text("Create and sync an invoice first.")
                            .foregroundColor(.secondary)
                    } else {
                        SearchableDropdownPicker(
                            title: "Invoice",
                            options: invoiceOptions,
                            selectedID: $selectedInvoiceID,
                            placeholder: "Choose invoice"
                        )
                    }

                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                    TextField("Notes", text: $note)
                    TextField("Cardholder name", text: $cardholderName)
                    SecureField("Card number", text: $cardNumber)
                        .keyboardType(.numberPad)
                        .privacySensitive()
                    HStack {
                        TextField("Exp MM", text: $expirationMonth)
                            .keyboardType(.numberPad)
                        TextField("Exp YYYY", text: $expirationYear)
                            .keyboardType(.numberPad)
                        SecureField("CVC", text: $cvc)
                            .keyboardType(.numberPad)
                            .privacySensitive()
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
                        guard let invoice = selectedInvoice, let amount = Double(amountText), amount > 0 else { return }
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
                        selectedInvoice == nil ||
                        Double(amountText) == nil ||
                        cardNumber.filter(\.isNumber).count < 12 ||
                        expirationYear.filter(\.isNumber).count != 4 ||
                        cvc.filter(\.isNumber).count < 3
                    )
                }
            }
            .onAppear {
                selectedInvoiceID = selectedInvoiceID ?? invoices.first?.id.uuidString
                guard let selectedInvoice else { return }
                amountText = String(format: "%.2f", outstandingBalance(for: selectedInvoice))
                cardholderName = selectedInvoice.customer.name
            }
            .onChange(of: selectedInvoiceID) { _, _ in
                guard let invoice = selectedInvoice else { return }
                amountText = String(format: "%.2f", outstandingBalance(for: invoice))
                cardholderName = invoice.customer.name
            }
        }
    }

    private func outstandingBalance(for invoice: Invoice) -> Double {
        if invoice.status.caseInsensitiveCompare("paid") == .orderedSame {
            return 0
        }
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

private struct QuickBooksCatalogItemDraft {
    let name: String
    let itemType: CatalogItemType
    let sku: String?
    let price: Double
    let purchaseCost: Double?
    let description: String?
    let purchaseDescription: String?
    let vendorRef: QuickBooksReference?
}

private struct QuickBooksCatalogItemComposeView: View {
    @Environment(\.dismiss) private var dismiss

    let vendors: [QuickBooksVendor]
    let onCreate: (QuickBooksCatalogItemDraft) -> Void

    @State private var name = ""
    @State private var itemType: CatalogItemType = .service
    @State private var sku = ""
    @State private var price = ""
    @State private var purchaseCost = ""
    @State private var description = ""
    @State private var purchaseDescription = ""
    @State private var selectedVendorID = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Sales") {
                    TextField("Name", text: $name)
                    TextField("SKU", text: $sku)
                        .textInputAutocapitalization(.characters)
                    Picker("Item Type", selection: $itemType) {
                        ForEach(CatalogItemType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    TextField("Price (optional)", text: $price)
                        .keyboardType(.decimalPad)
                    TextField("Description", text: $description)
                }

                Section("Purchasing") {
                    TextField("Purchase price", text: $purchaseCost)
                        .keyboardType(.decimalPad)
                    if !vendors.isEmpty {
                        Picker("Preferred vendor", selection: $selectedVendorID) {
                            Text("None").tag("")
                            ForEach(vendors) { vendor in
                                Text(vendor.DisplayName).tag(vendor.Id)
                            }
                        }
                    }
                    TextField("Purchase notes", text: $purchaseDescription, axis: .vertical)
                        .lineLimit(2...3)
                }
            }
            .navigationTitle("Add Catalog Item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        guard let amount = QuickBooksCatalogAmountParser.parseRequiredOrZero(price), amount >= 0 else { return }
                        let vendorRef = vendors.first { $0.Id == selectedVendorID }?.reference
                        onCreate(QuickBooksCatalogItemDraft(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            itemType: itemType,
                            sku: sku.nilIfBlank,
                            price: amount,
                            purchaseCost: QuickBooksCatalogAmountParser.parseOptional(purchaseCost),
                            description: description.nilIfBlank,
                            purchaseDescription: purchaseDescription.nilIfBlank,
                            vendorRef: vendorRef
                        )
                        )
                        dismiss()
                    }
                    .disabled(
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        QuickBooksCatalogAmountParser.parseRequiredOrZero(price) == nil ||
                        !QuickBooksCatalogAmountParser.isValidOptionalAmount(purchaseCost)
                    )
                }
            }
        }
    }
}

private enum QuickBooksCatalogAmountParser {
    static func parseRequiredOrZero(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let normalized = trimmed
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
        return Double(normalized)
    }

    static func parseOptional(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return parseRequiredOrZero(trimmed)
    }

    static func isValidOptionalAmount(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || parseRequiredOrZero(trimmed) != nil
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
