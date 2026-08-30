import Foundation

enum BillingTaxCalculationStatus: String, Codable, Equatable {
    case notApplicable = "not_applicable"
    case pendingQuickBooks = "pending_quickbooks"
    case calculatedByQuickBooks = "calculated_by_quickbooks"
    case needsAttention = "needs_attention"

    var blocksCustomerCommitment: Bool {
        self == .pendingQuickBooks || self == .needsAttention
    }

    var displayName: String {
        switch self {
        case .notApplicable:
            "Not applicable"
        case .pendingQuickBooks:
            "Awaiting QuickBooks tax"
        case .calculatedByQuickBooks:
            "Calculated by QuickBooks"
        case .needsAttention:
            "Tax total needs review"
        }
    }
}

struct BillingTaxReconciliation: Equatable {
    let subtotal: Double
    let salesTax: Double
    let total: Double
    let status: BillingTaxCalculationStatus
    let attentionDetail: String?
}

/// QuickBooks remains the sales-tax authority for customer-facing documents.
/// GunnAire sends the immutable taxable/non-taxable line treatment, then stores
/// the returned tax and total so estimates, invoices, PDFs, CloudKit, and field
/// collection all use the same amount.
enum BillingTaxPolicy {
    static func snapshotSubtotal(_ snapshotJSON: String?) -> Double? {
        let snapshots = CatalogLineItemSnapshot.decoded(from: snapshotJSON)
        guard !snapshots.isEmpty else { return nil }
        let subtotal = snapshots.reduce(0) { $0 + ($1.unitPrice * $1.quantity) }
        guard subtotal.isFinite, subtotal >= 0 else { return nil }
        return subtotal
    }

    static func hasTaxableLines(_ snapshotJSON: String?) -> Bool {
        CatalogLineItemSnapshot.decoded(from: snapshotJSON).contains(where: \.isTaxable)
    }

    static func resolvedStatus(
        storedRawValue: String?,
        snapshotJSON: String?,
        quickBooksID: String?
    ) -> BillingTaxCalculationStatus {
        if let storedRawValue,
           let stored = BillingTaxCalculationStatus(rawValue: storedRawValue) {
            return stored
        }
        guard hasTaxableLines(snapshotJSON) else { return .notApplicable }
        let hasQuickBooksDocument = quickBooksID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        return hasQuickBooksDocument ? .calculatedByQuickBooks : .pendingQuickBooks
    }

    static func customerCommitmentBlockedMessage(
        status: BillingTaxCalculationStatus,
        documentName: String
    ) -> String? {
        switch status {
        case .notApplicable, .calculatedByQuickBooks:
            nil
        case .pendingQuickBooks:
            "QuickBooks must calculate sales tax before this \(documentName) can be approved or collected. Connect QuickBooks and publish the current line items first."
        case .needsAttention:
            "This \(documentName)'s QuickBooks tax total needs office review before approval or collection. Refresh QuickBooks after the taxable lines and service address are corrected."
        }
    }

    static func reconcile(
        snapshotJSON: String?,
        quickBooksTotal: Double,
        reportedTax: Double?
    ) -> BillingTaxReconciliation {
        let safeTotal = quickBooksTotal.isFinite && quickBooksTotal >= 0 ? quickBooksTotal : 0
        let snapshots = CatalogLineItemSnapshot.decoded(from: snapshotJSON)
        let snapshotSubtotal = snapshots.isEmpty
            ? nil
            : snapshots.reduce(0) { $0 + ($1.unitPrice * $1.quantity) }
        let hasTaxableLines = snapshots.contains(where: \.isTaxable)
        let validReportedTax = reportedTax.flatMap { value in
            value.isFinite && value >= 0 ? value : nil
        }

        guard let snapshotSubtotal,
              snapshotSubtotal.isFinite,
              snapshotSubtotal >= 0 else {
            let tax = min(validReportedTax ?? 0, safeTotal)
            return BillingTaxReconciliation(
                subtotal: max(safeTotal - tax, 0),
                salesTax: tax,
                total: safeTotal,
                status: .calculatedByQuickBooks,
                attentionDetail: nil
            )
        }

        let derivedTax = max(safeTotal - snapshotSubtotal, 0)
        let tax = validReportedTax ?? derivedTax
        let expectedTotal = snapshotSubtotal + tax
        var issue: String?

        if safeTotal + 0.009 < snapshotSubtotal {
            issue = "QuickBooks returned a total below the immutable line-item subtotal."
        } else if currencyCents(safeTotal) != currencyCents(expectedTotal) {
            issue = "QuickBooks tax plus the immutable line-item subtotal does not equal the returned document total."
        } else if !hasTaxableLines && tax > 0.009 {
            issue = "QuickBooks applied sales tax even though every immutable line is non-taxable."
        }

        return BillingTaxReconciliation(
            subtotal: snapshotSubtotal,
            salesTax: max(min(tax, safeTotal), 0),
            total: safeTotal,
            status: issue == nil
                ? (hasTaxableLines ? .calculatedByQuickBooks : .notApplicable)
                : .needsAttention,
            attentionDetail: issue
        )
    }

    static func quickBooksTaxCodeValue(isTaxable: Bool) -> String {
        isTaxable ? "TAX" : "NON"
    }

    private static func currencyCents(_ amount: Double) -> Int64? {
        guard amount.isFinite,
              amount >= 0,
              amount <= Double(Int64.max) / 100 else { return nil }
        return Int64((amount * 100).rounded())
    }
}
