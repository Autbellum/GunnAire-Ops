// Invoice.swift
// Model for invoices
import Foundation
import SwiftData

enum InvoiceWorkType: String, Codable, CaseIterable, Identifiable {
    case service
    case repair
    case replacement

    var id: String { rawValue }

    var displayName: String { rawValue.capitalized }
    var documentTitle: String { "\(displayName) Invoice" }

    static func inferred(from serviceCall: ServiceCall?) -> InvoiceWorkType {
        switch serviceCall?.type {
        case .replacement, .install: .replacement
        case .repair: .repair
        case .service: .service
        case .maintenance, .estimate, .meeting, .reminder, .siteVisit, .other, .none: .service
        }
    }
}

enum InvoicePaymentTerms: String, Codable, CaseIterable, Identifiable {
    case dueOnReceipt = "due_on_receipt"
    case net7 = "net_7"
    case net15 = "net_15"
    case net30 = "net_30"
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dueOnReceipt: "Due on Receipt"
        case .net7: "Net 7"
        case .net15: "Net 15"
        case .net30: "Net 30"
        case .custom: "Custom Date"
        }
    }

    var dayCount: Int? {
        switch self {
        case .dueOnReceipt: 0
        case .net7: 7
        case .net15: 15
        case .net30: 30
        case .custom: nil
        }
    }

    func dueDate(from issueDate: Date, calendar: Calendar = .current) -> Date? {
        guard let dayCount else { return nil }
        return calendar.date(byAdding: .day, value: dayCount, to: calendar.startOfDay(for: issueDate))
    }

    static func inferred(
        issueDate: Date,
        dueDate: Date,
        calendar: Calendar = .current
    ) -> InvoicePaymentTerms {
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: issueDate),
            to: calendar.startOfDay(for: dueDate)
        ).day
        return allCases.first(where: { $0.dayCount == days }) ?? .custom
    }
}

@Model
final class Invoice {
    var id: UUID = UUID()
    var serviceCallID: UUID?
    var serviceLocationID: UUID?
    var siteAddress: String?
    /// Stored as an optional CloudKit relationship; all normal invoice creation
    /// paths still provide a customer.
    var customer: Customer!
    @Relationship(originalName: "payments", inverse: \Payment.invoice) private var storedPayments: [Payment]?
    var quickBooksID: String?
    var quickBooksBalanceDue: Double?
    var quickBooksSyncStatus: String = "pending"
    var quickBooksSyncDetail: String?
    var quickBooksLastSyncedAt: Date?
    var workTypeRaw: String = InvoiceWorkType.service.rawValue
    var lineItemSummary: String = ""
    var catalogSnapshotJSON: String?
    var amount: Double = 0
    /// QuickBooks is authoritative for jurisdictional sales tax. `amount` is
    /// the customer total; these fields preserve the returned tax evidence and
    /// prevent collection while a taxable draft still has only a subtotal.
    var salesTaxAmount: Double = 0
    var taxCalculationStatusRawValue: String?
    var taxCalculatedAt: Date?
    /// Progress invoices retain an explicit operational milestone and approved
    /// contract allocation. This prevents two equal draws on one job from being
    /// deduplicated and keeps QBO reconciliation traceable to field progress.
    var projectMilestoneID: UUID?
    var projectMilestoneSequence: Int?
    var projectMilestoneTitle: String?
    var projectContractAmount: Double?
    var projectBillingPercent: Double?
    var status: String = "unpaid" // unpaid, paid, overdue
    /// The date the customer is expected to pay. Legacy invoices without this
    /// additive field retain the former 30-day aging behavior through
    /// `effectiveDueDate`; every new invoice stores an explicit date and sends
    /// that same date to QuickBooks.
    var dueDate: Date?
    var notes: String?
    var customerSignatureName: String?
    var customerSignatureImageBase64: String?
    var customerSignedAt: Date?
    var completionNotes: String?
    var finalizedAt: Date?
    var createdAt: Date = Date()
    
    init(
        id: UUID = UUID(),
        serviceCallID: UUID? = nil,
        serviceLocationID: UUID? = nil,
        siteAddress: String? = nil,
        customer: Customer,
        quickBooksID: String? = nil,
        quickBooksBalanceDue: Double? = nil,
        quickBooksSyncStatus: String? = nil,
        quickBooksSyncDetail: String? = nil,
        quickBooksLastSyncedAt: Date? = nil,
        workType: InvoiceWorkType = .service,
        lineItemSummary: String = "",
        catalogSnapshotJSON: String? = nil,
        amount: Double = 0,
        salesTaxAmount: Double = 0,
        taxCalculationStatus: BillingTaxCalculationStatus? = nil,
        taxCalculatedAt: Date? = nil,
        projectMilestoneID: UUID? = nil,
        projectMilestoneSequence: Int? = nil,
        projectMilestoneTitle: String? = nil,
        projectContractAmount: Double? = nil,
        projectBillingPercent: Double? = nil,
        status: String = "unpaid",
        dueDate: Date? = nil,
        notes: String? = nil,
        customerSignatureName: String? = nil,
        customerSignatureImageBase64: String? = nil,
        customerSignedAt: Date? = nil,
        completionNotes: String? = nil,
        finalizedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.serviceCallID = serviceCallID
        self.serviceLocationID = serviceLocationID
        self.siteAddress = siteAddress
        self.customer = customer
        self.quickBooksID = quickBooksID
        self.quickBooksBalanceDue = quickBooksBalanceDue
        self.quickBooksSyncStatus = quickBooksSyncStatus ?? (quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? "synced" : "pending")
        self.quickBooksSyncDetail = quickBooksSyncDetail
        self.quickBooksLastSyncedAt = quickBooksLastSyncedAt
        self.workTypeRaw = workType.rawValue
        self.lineItemSummary = lineItemSummary
        self.catalogSnapshotJSON = catalogSnapshotJSON
        self.amount = amount
        self.salesTaxAmount = max(salesTaxAmount, 0)
        self.taxCalculationStatusRawValue = taxCalculationStatus?.rawValue
        self.taxCalculatedAt = taxCalculatedAt
        self.projectMilestoneID = projectMilestoneID
        self.projectMilestoneSequence = projectMilestoneSequence
        self.projectMilestoneTitle = projectMilestoneTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.projectContractAmount = projectContractAmount
        self.projectBillingPercent = projectBillingPercent
        self.status = status
        self.dueDate = dueDate
        self.notes = notes
        self.customerSignatureName = customerSignatureName
        self.customerSignatureImageBase64 = customerSignatureImageBase64
        self.customerSignedAt = customerSignedAt
        self.completionNotes = completionNotes
        self.finalizedAt = finalizedAt
        self.createdAt = createdAt
    }

    var normalizedStatus: String {
        let value = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "paid", "partial", "unpaid", "overdue":
            return value
        default:
            return value.isEmpty ? "unpaid" : value
        }
    }

    static let legacyPaymentTermDays = 30

    func effectiveDueDate(calendar: Calendar = .current) -> Date {
        if let dueDate {
            return calendar.startOfDay(for: dueDate)
        }
        return calendar.date(
            byAdding: .day,
            value: Self.legacyPaymentTermDays,
            to: calendar.startOfDay(for: createdAt)
        ) ?? createdAt
    }

    func paymentTerms(calendar: Calendar = .current) -> InvoicePaymentTerms {
        guard let dueDate else { return .net30 }
        return InvoicePaymentTerms.inferred(
            issueDate: createdAt,
            dueDate: dueDate,
            calendar: calendar
        )
    }

    var paymentTermsDisplayName: String {
        dueDate == nil ? "Legacy Net 30" : paymentTerms().displayName
    }

    static func isOverdue(
        _ invoice: Invoice,
        payments: [Payment],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard outstandingBalance(for: invoice, payments: payments) > 0.009 else { return false }
        return calendar.startOfDay(for: now) > invoice.effectiveDueDate(calendar: calendar)
    }

    static func dueStatusDetail(
        for invoice: Invoice,
        payments: [Payment],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        guard outstandingBalance(for: invoice, payments: payments) > 0.009 else { return "Paid" }
        let today = calendar.startOfDay(for: now)
        let due = invoice.effectiveDueDate(calendar: calendar)
        let dayDelta = calendar.dateComponents([.day], from: today, to: due).day ?? 0
        if dayDelta < 0 {
            let count = abs(dayDelta)
            return "Overdue by \(count) day\(count == 1 ? "" : "s")"
        }
        if dayDelta == 0 { return "Due today" }
        return "Due in \(dayDelta) day\(dayDelta == 1 ? "" : "s")"
    }

    var workType: InvoiceWorkType {
        get { InvoiceWorkType(rawValue: workTypeRaw) ?? .service }
        set { workTypeRaw = newValue.rawValue }
    }

    var payments: [Payment] {
        get { storedPayments ?? [] }
        set { storedPayments = newValue }
    }

    var catalogLineSnapshots: [CatalogLineItemSnapshot] {
        CatalogLineItemSnapshot.decoded(from: catalogSnapshotJSON)
    }

    var subtotalAmount: Double {
        if hasTaxableLines,
           let snapshotSubtotal = BillingTaxPolicy.snapshotSubtotal(catalogSnapshotJSON) {
            return snapshotSubtotal
        }
        return max(amount - salesTaxAmount, 0)
    }

    var hasTaxableLines: Bool {
        BillingTaxPolicy.hasTaxableLines(catalogSnapshotJSON)
    }

    var taxCalculationStatus: BillingTaxCalculationStatus {
        BillingTaxPolicy.resolvedStatus(
            storedRawValue: taxCalculationStatusRawValue,
            snapshotJSON: catalogSnapshotJSON,
            quickBooksID: quickBooksID
        )
    }

    var paymentCollectionBlockedMessage: String? {
        BillingTaxPolicy.customerCommitmentBlockedMessage(
            status: taxCalculationStatus,
            documentName: "invoice"
        )
    }

    var isReadyForPaymentCollection: Bool {
        paymentCollectionBlockedMessage == nil
    }

    @discardableResult
    func applyQuickBooksTaxResult(
        total: Double,
        reportedTax: Double?,
        at date: Date = Date()
    ) -> String? {
        let reconciliation = BillingTaxPolicy.reconcile(
            snapshotJSON: catalogSnapshotJSON,
            quickBooksTotal: total,
            reportedTax: reportedTax
        )
        taxCalculationStatusRawValue = reconciliation.status.rawValue
        taxCalculatedAt = date
        guard reconciliation.attentionDetail == nil else {
            return reconciliation.attentionDetail
        }
        amount = reconciliation.total
        salesTaxAmount = reconciliation.salesTax
        return reconciliation.attentionDetail
    }

    var isProjectProgressInvoice: Bool {
        projectMilestoneID != nil
    }

    var projectBillingDisplayTitle: String? {
        guard isProjectProgressInvoice else { return nil }
        if let sequence = projectMilestoneSequence {
            return "Progress Invoice \(sequence + 1)"
        }
        return "Progress Invoice"
    }

    var projectBillingAuditSummary: String? {
        guard isProjectProgressInvoice else { return nil }
        var details: [String] = []
        if let projectBillingDisplayTitle { details.append(projectBillingDisplayTitle) }
        if let projectMilestoneTitle, !projectMilestoneTitle.isEmpty { details.append(projectMilestoneTitle) }
        if let projectBillingPercent { details.append("\(projectBillingPercent.formatted(.number.precision(.fractionLength(0...2))))% of contract") }
        if let projectContractAmount { details.append("contract \(projectContractAmount.formatted(.currency(code: "USD")))") }
        return details.isEmpty ? nil : details.joined(separator: " • ")
    }

    /// QBO receives plain operator notes plus immutable project-allocation
    /// evidence. The local UUID is safe operational metadata, not a credential.
    var accountingPrivateNote: String? {
        let entries = [
            notes?.trimmingCharacters(in: .whitespacesAndNewlines),
            projectBillingAuditSummary.map { "GunnAire project billing: \($0); milestone ID \(projectMilestoneID?.uuidString ?? "unknown")" }
        ]
        .compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        return entries.isEmpty ? nil : String(entries.joined(separator: "\n").prefix(4_000))
    }

    static func draft(
        from estimate: Estimate,
        dueDate: Date? = nil,
        createdAt: Date = Date()
    ) -> Invoice {
        let hasTaxableLines = estimate.hasTaxableLines
        return Invoice(
            serviceCallID: estimate.serviceCallID,
            serviceLocationID: estimate.serviceLocationID,
            siteAddress: estimate.siteAddress,
            customer: estimate.customer,
            lineItemSummary: estimate.lineItemSummary,
            catalogSnapshotJSON: estimate.catalogSnapshotJSON,
            amount: hasTaxableLines ? estimate.subtotalAmount : estimate.amount,
            salesTaxAmount: 0,
            taxCalculationStatus: hasTaxableLines ? .pendingQuickBooks : .notApplicable,
            taxCalculatedAt: nil,
            dueDate: dueDate ?? InvoicePaymentTerms.dueOnReceipt.dueDate(from: createdAt),
            notes: estimate.notes,
            createdAt: createdAt
        )
    }

    var hasQuickBooksBalance: Bool {
        quickBooksBalanceDue != nil && quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var quickBooksSyncState: String {
        if quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
           quickBooksSyncStatus == "synced" {
            return "synced"
        }
        return quickBooksSyncStatus
    }

    var needsQuickBooksAttention: Bool {
        quickBooksSyncState == "needs_attention"
    }

    static func outstandingBalance(for invoice: Invoice, payments: [Payment]) -> Double {
        if let quickBooksBalanceDue = invoice.quickBooksBalanceDue,
           invoice.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return max(quickBooksBalanceDue, 0)
        }
        if invoice.status.caseInsensitiveCompare("paid") == .orderedSame {
            return 0
        }
        let netPaid = payments
            .filter { $0.invoice.id == invoice.id }
            .reduce(0) { partial, payment in
                partial + (payment.isRefund ? -payment.amount : payment.amount)
            }
        return max(invoice.amount - netPaid, 0)
    }

    static func isPaid(_ invoice: Invoice, payments: [Payment]) -> Bool {
        if invoice.hasQuickBooksBalance {
            return outstandingBalance(for: invoice, payments: payments) <= 0.009
        }
        return outstandingBalance(for: invoice, payments: payments) <= 0.009 ||
            invoice.status.caseInsensitiveCompare("paid") == .orderedSame
    }

    static func resolvedStatus(for invoice: Invoice, payments: [Payment]) -> String {
        let balance = outstandingBalance(for: invoice, payments: payments)
        if balance <= 0.009 {
            return "paid"
        }
        if balance < invoice.amount - 0.009 {
            return "partial"
        }
        return invoice.normalizedStatus == "overdue" ? "overdue" : "unpaid"
    }

    func applyLocalPaymentAmount(_ amount: Double, isRefund: Bool = false) {
        guard hasQuickBooksBalance, let quickBooksBalanceDue else { return }
        let adjustedBalance = isRefund
            ? quickBooksBalanceDue + amount
            : quickBooksBalanceDue - amount
        self.quickBooksBalanceDue = max(adjustedBalance, 0)
    }

    static func mostResolvedStatus(_ lhs: String, _ rhs: String) -> String {
        rank(for: lhs) >= rank(for: rhs) ? lhs : rhs
    }

    static func displayDeduplicated(_ invoices: [Invoice]) -> [Invoice] {
        var selectedByKey: [String: Invoice] = [:]
        for invoice in invoices {
            let key = displayDedupeKey(for: invoice)
            if let existing = selectedByKey[key] {
                selectedByKey[key] = preferredDisplayInvoice(existing, invoice)
            } else {
                selectedByKey[key] = invoice
            }
        }
        return selectedByKey.values.sorted { lhs, rhs in
            lhs.createdAt > rhs.createdAt
        }
    }

    private static func rank(for status: String) -> Int {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "paid":
            return 3
        case "partial":
            return 2
        case "unpaid", "overdue":
            return 1
        default:
            return 0
        }
    }

    private static func displayDedupeKey(for invoice: Invoice) -> String {
        if let projectMilestoneID = invoice.projectMilestoneID {
            return "milestone:\(projectMilestoneID.uuidString.lowercased())"
        }
        if let serviceCallID = invoice.serviceCallID {
            return "call:\(serviceCallID.uuidString.lowercased()):\(String(format: "%.2f", invoice.amount))"
        }
        if let quickBooksID = invoice.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !quickBooksID.isEmpty {
            return "qb:\(quickBooksID.lowercased())"
        }
        let customerKey = invoice.customer.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let day = Calendar.current.startOfDay(for: invoice.createdAt).timeIntervalSince1970
        return "local:\(customerKey):\(String(format: "%.2f", invoice.amount)):\(Int(day))"
    }

    private static func preferredDisplayInvoice(_ lhs: Invoice, _ rhs: Invoice) -> Invoice {
        let lhsRank = rank(for: resolvedStatus(for: lhs, payments: []))
        let rhsRank = rank(for: resolvedStatus(for: rhs, payments: []))
        if lhsRank != rhsRank {
            return rhsRank > lhsRank ? rhs : lhs
        }
        let lhsHasQuickBooks = lhs.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let rhsHasQuickBooks = rhs.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if lhsHasQuickBooks != rhsHasQuickBooks {
            return rhsHasQuickBooks ? rhs : lhs
        }
        return rhs.createdAt > lhs.createdAt ? rhs : lhs
    }
}
