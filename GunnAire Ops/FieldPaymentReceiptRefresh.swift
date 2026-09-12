import Foundation
import SwiftData

/// Finish a saved accounting workflow with fresh invoice-scoped evidence.
/// Never synthesize an observation from a bulk import or a capture response.
@MainActor enum FieldPaymentReceiptRefresh {
    typealias ClientFactory = (Invoice) throws -> FieldPaymentReviewClient
    static let pendingMessage = "Records are saved, but this invoice's accounting check still needs review. In Invoices, expand Saved accounting check and choose Refresh accounting check before collecting again or sending a statement. If it still needs review, ask Accounting to reconcile the original records."

    static func ifSaved(invoice: Invoice, check: @escaping () throws -> Void,
                        makeClient: ClientFactory? = nil, now: () -> Date = Date.init,
                        persist: ((ModelContext) throws -> Void)? = nil) async throws -> String? {
        try check(); try Task.checkCancellation()
        guard let context = invoice.modelContext else {
            guard invoice.quickBooksPaymentReviewJSON == nil else { throw FieldPaymentReviewError.access }
            return nil
        }
        guard try context.fetch(FetchDescriptor<Invoice>()).contains(where: { $0 === invoice })
        else { throw FieldPaymentReviewError.access }
        guard invoice.quickBooksPaymentReviewJSON != nil else { return nil }
        let validateDocument = QuickBooksBillingDocument.invoice(invoice).validation(context: context)
        let previous = invoice.quickBooksPaymentReviewJSON
        let digest = try FieldPaymentReceiptReconciliation.paymentDigest(invoice: invoice, context: context)
        let validateOriginal = {
            try check(); try Task.checkCancellation(); try validateDocument()
            guard invoice.modelContext === context, invoice.quickBooksPaymentReviewJSON == previous,
                  try FieldPaymentReceiptReconciliation.paymentDigest(invoice: invoice, context: context) == digest
            else { throw FieldPaymentReviewError.changed }
        }
        do {
            let client = try makeClient?(invoice) ?? FieldPaymentReviewClient.live(invoice: invoice)
            let snapshot = try await client.review()
            try validateOriginal()
            try FieldPaymentReceiptReconciliation.apply(snapshot, to: invoice, identity: client.identity,
                context: context, now: now(), check: { try validateOriginal(); try client.check() },
                persist: { if let persist { try persist(context) } else { try context.save() } })
            // A successfully saved check can still report an open payment hold.
            return invoice.quickBooksReconciliationReviewMessage
        } catch {
            // An unavailable read does not undo or mark a confirmed payment as
            // failed. Revoked/cancelled initiating work must still stop outright.
            try check(); try Task.checkCancellation()
            return pendingMessage
        }
    }

    /// Refresh only original invoices touched by this run's successful resources.
    /// Each invoice has independent read/save evidence; a failure retains its hold
    /// and does not discard successful checks for other invoices.
    static func afterImport(context: ModelContext, invoiceIDs: Set<String>, check: @escaping () throws -> Void,
                            makeClient: ClientFactory? = nil, now: () -> Date = Date.init) async throws -> Int {
        try check(); try Task.checkCancellation()
        let candidates = try context.fetch(FetchDescriptor<Invoice>()).filter {
            $0.quickBooksPaymentReviewJSON != nil && invoiceIDs.contains($0.quickBooksID ?? "")
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        var pending = 0
        for invoice in candidates {
            try check(); try Task.checkCancellation()
            if try await ifSaved(invoice: invoice, check: check, makeClient: makeClient, now: now) != nil {
                pending += 1
            }
        }
        return pending
    }
}
