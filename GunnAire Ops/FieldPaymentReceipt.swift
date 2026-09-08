import Foundation
import CryptoKit
import SwiftData

/// One atomic, bounded observation on the existing invoice record. This is not
/// a historical ledger, a new Payment, or evidence of processor settlement.
struct FieldPaymentReceipt: Codable, Equatable {
    let version: Int
    let snapshot: FieldPaymentReviewSnapshot
    let documentDigest: String
    let paymentDigest: String
}

enum FieldPaymentReceiptError: Error, LocalizedError, Equatable {
    case changed, history, newer, save
    var errorDescription: String? {
        switch self {
        case .changed: "The saved invoice changed or needs billing review. Ask Accounting to sync its original details before updating the balance."
        case .history: "Saved payment history needs reconciliation. No capture or receipt was changed. Ask Accounting to review the original records."
        case .newer: "A newer invoice check is already saved. Refresh this invoice before trying again."
        case .save: "The verified invoice could not be saved. Your previous balance and payment records were preserved. Retry when device storage is available."
        }
    }
}

enum FieldPaymentReceiptReconciliation {
    static let maximumBytes = 72 * 1024
    static let incompleteMessage = "This invoice's saved accounting check is incomplete or has changed. Refresh its shared payment check before collecting or sending a statement."

    private static func hash<T: Encodable>(_ value: T) throws -> String {
        SHA256.hash(data: try JSONEncoder().encode(value)).map { String(format: "%02x", $0) }.joined()
    }
    static func documentDigest(_ invoice: Invoice) throws -> String {
        // Balance/status are the result, not the original document. Never use
        // a number/date/amount as an identity or change tax/line-item evidence.
        try hash([invoice.id.uuidString, invoice.customer?.id.uuidString,
            invoice.customer?.quickBooksID, invoice.quickBooksID, invoice.serviceCallID?.uuidString,
            invoice.serviceLocationID?.uuidString, invoice.siteAddress, invoice.catalogSnapshotJSON,
            invoice.lineItemSummary, String(invoice.amount), String(invoice.salesTaxAmount),
            invoice.taxCalculationStatusRawValue, invoice.workTypeRaw, invoice.projectMilestoneID?.uuidString,
            invoice.milestoneDraftReceiptJSON, String(invoice.createdAt.timeIntervalSince1970),
            invoice.dueDate.map { String($0.timeIntervalSince1970) }])
    }

    @MainActor static func paymentDigest(invoice: Invoice, context: ModelContext) throws -> String {
        try paymentDigest(try context.fetch(FetchDescriptor<Payment>()).filter { $0.invoice?.id == invoice.id })
    }
    static func paymentDigest(_ payments: [Payment]) throws -> String {
        let values: [[String?]] = payments.sorted { $0.id.uuidString < $1.id.uuidString }.map {
            [$0.id.uuidString, $0.invoice?.id.uuidString, $0.quickBooksID, $0.quickBooksChargeID,
             $0.quickBooksClientTransID, $0.collectionAttemptID?.uuidString, $0.providerPaymentStatus,
             $0.quickBooksRefundReceiptID, String($0.amount), String($0.date.timeIntervalSince1970),
             $0.method, String($0.isRefund), $0.refundedPaymentID?.uuidString, $0.processor]
        }
        return try hash(values)
    }
    static func decode(_ raw: String?) -> FieldPaymentReceipt? {
        guard let raw, raw.utf8.count <= maximumBytes,
              let receipt = try? JSONDecoder().decode(FieldPaymentReceipt.self, from: Data(raw.utf8)), receipt.version == 1,
              let observed = CompanyWorkspaceClock.parse(receipt.snapshot.observedAt),
              (try? receipt.snapshot.validate(receipt.snapshot.scope, now: observed)) != nil,
              JobBillingAssignmentSnapshot.validConnectionRevision(receipt.documentDigest),
              JobBillingAssignmentSnapshot.validConnectionRevision(receipt.paymentDigest) else { return nil }
        return receipt
    }
    static func receipt(for invoice: Invoice) -> FieldPaymentReceipt? {
        guard let receipt = decode(invoice.quickBooksPaymentReviewJSON),
              receipt.snapshot.scope.invoiceID == invoice.id,
              receipt.snapshot.scope.localCustomerID == invoice.customer?.id,
              receipt.snapshot.scope.customerQuickBooksID == invoice.customer?.quickBooksID,
              receipt.snapshot.scope.invoiceQuickBooksID == invoice.quickBooksID,
              receipt.snapshot.scope.serviceCallID == invoice.serviceCallID,
              receipt.documentDigest == (try? documentDigest(invoice)) else { return nil }
        return receipt
    }
    static func reviewMessage(for invoice: Invoice) -> String? {
        guard invoice.quickBooksPaymentReviewJSON != nil else { return nil }
        guard let receipt = receipt(for: invoice), let observed = CompanyWorkspaceClock.parse(receipt.snapshot.observedAt),
              let saved = invoice.quickBooksLastSyncedAt else { return incompleteMessage }
        // A timestamp alone does not establish which writer supplied a mixed
        // CloudKit balance. Refresh the scoped observation to reconcile it.
        guard saved == observed, cents(invoice.quickBooksBalanceDue) == receipt.snapshot.balanceCents,
              invoice.status == status(receipt.snapshot),
              receipt.paymentDigest == (try? paymentDigest(invoice.payments)) else { return incompleteMessage }
        return receipt.snapshot.hasOpenAttempt ? "Another payment needs review. Open Payment Recovery before collecting again." : nil
    }
    static func cents(_ value: Double?) -> Int? {
        guard let value, value.isFinite, value >= 0, value <= 1_000_000,
              abs(value * 100 - (value * 100).rounded()) < 0.000001 else { return nil }
        return Int((value * 100).rounded())
    }
    private static func status(_ snapshot: FieldPaymentReviewSnapshot) -> String {
        snapshot.balanceCents == 0 ? "paid" : (snapshot.balanceCents < snapshot.totalCents ? "partial" : "unpaid")
    }
    private static func version(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { throw FieldPaymentReceiptError.changed }
        let digits = value.drop(while: { $0 == "0" })
        return digits.isEmpty ? "0" : String(digits)
    }
    private static func olderVersion(_ candidate: String, than previous: String) throws -> Bool {
        let next = try version(candidate), old = try version(previous)
        return next.count == old.count ? next < old : next.count < old.count
    }

    /// Called only after a fresh authorized read, synchronously on its original
    /// context. No provider send and no creation/deletion/edit of any Payment.
    @MainActor static func apply(_ snapshot: FieldPaymentReviewSnapshot, to invoice: Invoice,
                                identity: FieldPaymentReviewIdentity, context: ModelContext,
                                now: Date = Date(), check: () throws -> Void,
                                persist: () throws -> Void) throws {
        try check()
        try snapshot.scope.validate(identity)
        try snapshot.validate(snapshot.scope, now: now)
        let invoices = try context.fetch(FetchDescriptor<Invoice>())
        let customers = try context.fetch(FetchDescriptor<Customer>())
        guard invoice.modelContext === context, let customer = invoice.customer, customer.modelContext === context,
              invoice.id == identity.invoiceID, customer.id == identity.localCustomerID,
              invoice.quickBooksID == identity.invoiceQuickBooksID, customer.quickBooksID == identity.customerQuickBooksID,
              invoice.serviceCallID == identity.serviceCallID,
              invoices.filter({ $0.id == invoice.id || $0.quickBooksID == invoice.quickBooksID }).count == 1,
              customers.filter({ $0.id == customer.id || $0.quickBooksID == customer.quickBooksID }).count == 1,
              invoice.milestoneDraftReceiptJSON == nil, invoice.quickBooksIdentityReviewMessage == nil,
              invoice.quickBooksSyncState == "synced" || invoice.quickBooksSyncState == QuickBooksBalanceReconciliation.reviewState,
              BillingTaxPolicy.customerCommitmentBlockedMessage(status: invoice.taxCalculationStatus, documentName: "invoice") == nil,
              cents(invoice.amount) == snapshot.totalCents,
              let observed = CompanyWorkspaceClock.parse(snapshot.observedAt) else { throw FieldPaymentReceiptError.changed }

        let payments = try context.fetch(FetchDescriptor<Payment>()).filter { $0.invoice?.id == invoice.id }
        guard Set(payments.map(\.id)).count == payments.count,
              payments.allSatisfy({ $0.invoice === invoice && (cents($0.amount) ?? 0) > 0 && $0.date.timeIntervalSince1970.isFinite })
        else { throw FieldPaymentReceiptError.history }
        guard payments.filter(\.isRefund).allSatisfy({
            PaymentAttemptRecord.isReference($0.quickBooksRefundReceiptID ?? "") && !$0.needsQuickBooksAttention
        }) else { throw FieldPaymentReceiptError.history }
        // A local cash/capture without a matched accounting record cannot be
        // silently replaced by a remote balance that may not include it yet.
        let claims = payments.filter { !$0.isRefund }.compactMap(\.quickBooksID)
        guard Set(claims).count == claims.count else { throw FieldPaymentReceiptError.history }
        for payment in payments where !payment.isRefund {
            guard let allocation = snapshot.payments.first(where: { $0.paymentQuickBooksID == payment.quickBooksID }),
                  cents(payment.amount) == allocation.appliedCents else { throw FieldPaymentReceiptError.history }
        }
        if let previousRaw = invoice.quickBooksPaymentReviewJSON {
            guard let previous = decode(previousRaw), previous.snapshot.scope.identity == identity,
                  previous.snapshot.scope.realmID == snapshot.scope.realmID,
                  previous.snapshot.scope.environment == snapshot.scope.environment,
                  let previousDate = CompanyWorkspaceClock.parse(previous.snapshot.observedAt) else { throw FieldPaymentReceiptError.changed }
            if previousDate > observed { throw FieldPaymentReceiptError.newer }
            if previousDate == observed && previous.snapshot != snapshot { throw FieldPaymentReceiptError.newer }
            if try olderVersion(snapshot.syncToken, than: previous.snapshot.syncToken) { throw FieldPaymentReceiptError.newer }
            for payment in snapshot.payments {
                if let old = previous.snapshot.payments.first(where: { $0.paymentQuickBooksID == payment.paymentQuickBooksID }),
                   try olderVersion(payment.syncToken, than: old.syncToken) { throw FieldPaymentReceiptError.newer }
            }
        }
        _ = try version(snapshot.syncToken)
        for payment in snapshot.payments { _ = try version(payment.syncToken) }
        if let last = invoice.quickBooksLastSyncedAt, last > observed { throw FieldPaymentReceiptError.newer }
        let receipt = FieldPaymentReceipt(version: 1, snapshot: snapshot,
            documentDigest: try documentDigest(invoice), paymentDigest: try paymentDigest(payments))
        let raw = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        guard raw.utf8.count <= maximumBytes else { throw FieldPaymentReceiptError.changed }
        let previous = (invoice.quickBooksPaymentReviewJSON, invoice.quickBooksBalanceDue, invoice.status,
                        invoice.quickBooksLastSyncedAt, invoice.quickBooksSyncStatus, invoice.quickBooksSyncDetail)
        try check()
        invoice.quickBooksPaymentReviewJSON = raw
        invoice.quickBooksBalanceDue = Double(snapshot.balanceCents) / 100
        invoice.status = status(snapshot)
        invoice.quickBooksLastSyncedAt = observed
        if invoice.quickBooksSyncState == QuickBooksBalanceReconciliation.reviewState {
            invoice.quickBooksSyncStatus = "synced"; invoice.quickBooksSyncDetail = nil
        }
        do { try persist() }
        catch {
            // Do not roll back the shared context or discard unrelated edits.
            invoice.quickBooksPaymentReviewJSON = previous.0; invoice.quickBooksBalanceDue = previous.1
            invoice.status = previous.2; invoice.quickBooksLastSyncedAt = previous.3
            invoice.quickBooksSyncStatus = previous.4; invoice.quickBooksSyncDetail = previous.5
            throw FieldPaymentReceiptError.save
        }
    }
}
