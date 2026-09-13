import Foundation

/// Only an Invoice response can establish QBO's outstanding accounting balance.
/// A Payment query may be partial and excludes other balance-affecting entries.
enum QuickBooksBalanceReconciliation {
    static let reviewState = "balance_needs_refresh"
    static let refreshMessage = "Refresh QuickBooks to confirm this invoice's balance before collecting payment or sending a statement. The last confirmed balance and saved payment history have been preserved."

    static func markForRefresh(_ invoice: Invoice, detail: String = refreshMessage) {
        guard invoice.quickBooksIdentityReviewMessage == nil else { return }
        invoice.quickBooksSyncStatus = reviewState
        invoice.quickBooksSyncDetail = detail
    }

    @discardableResult
    static func apply(_ source: QuickBooksInvoice, to invoice: Invoice, at date: Date = Date()) -> Bool {
        guard source.TotalAmt.isFinite, source.TotalAmt >= 0,
              let balance = source.Balance, balance.isFinite,
              balance >= 0, balance <= source.TotalAmt + 0.009 else {
            markForRefresh(invoice)
            return false
        }
        invoice.quickBooksBalanceDue = balance
        invoice.quickBooksLastSyncedAt = date
        invoice.status = balance <= 0.009 ? "paid"
            : (balance < source.TotalAmt - 0.009 ? "partial" : "unpaid")
        return true
    }
}

/// Retained screen contents are not evidence that a resource refreshed this run.
enum QuickBooksSnapshotImportPolicy {
    static func records<T>(_ cached: [T], resource: String, successfulResourceIDs: Set<String>) -> [T] {
        successfulResourceIDs.contains(resource) ? cached : []
    }
}
