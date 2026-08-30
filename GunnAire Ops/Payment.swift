// Payment.swift
// Model for payments
import Foundation
import SwiftData

@Model
final class Payment {
    var id: UUID = UUID()
    /// CloudKit can deliver relationship records in either order. The invoice
    /// remains required by every payment initializer and creation workflow.
    var invoice: Invoice!
    var quickBooksID: String?
    var quickBooksChargeID: String?
    var quickBooksClientTransID: String?
    var quickBooksRefundReceiptID: String?
    var quickBooksDepositID: String?
    var quickBooksSalesReceiptID: String?
    var quickBooksAccountingSyncStatus: String?
    var quickBooksAccountingSyncDetail: String?
    var processorSyncStatus: String?
    var processorSyncDetail: String?
    var settlementBatchID: String?
    var storedCardID: String?
    var amount: Double = 0
    var date: Date = Date()
    var method: String = "cash" // cash, check, card
    var cardLast4: String?
    var authorizationReference: String?
    var notes: String?
    var processor: String?
    var isRefund: Bool = false
    var refundedPaymentID: UUID?
    
    init(
        id: UUID = UUID(),
        invoice: Invoice,
        quickBooksID: String? = nil,
        quickBooksChargeID: String? = nil,
        quickBooksClientTransID: String? = nil,
        quickBooksRefundReceiptID: String? = nil,
        quickBooksDepositID: String? = nil,
        quickBooksSalesReceiptID: String? = nil,
        quickBooksAccountingSyncStatus: String? = nil,
        quickBooksAccountingSyncDetail: String? = nil,
        processorSyncStatus: String? = nil,
        processorSyncDetail: String? = nil,
        settlementBatchID: String? = nil,
        storedCardID: String? = nil,
        amount: Double,
        date: Date = Date(),
        method: String = "cash",
        cardLast4: String? = nil,
        authorizationReference: String? = nil,
        notes: String? = nil,
        processor: String? = nil,
        isRefund: Bool = false,
        refundedPaymentID: UUID? = nil
    ) {
        self.id = id
        self.invoice = invoice
        self.quickBooksID = quickBooksID
        self.quickBooksChargeID = quickBooksChargeID
        self.quickBooksClientTransID = quickBooksClientTransID
        self.quickBooksRefundReceiptID = quickBooksRefundReceiptID
        self.quickBooksDepositID = quickBooksDepositID
        self.quickBooksSalesReceiptID = quickBooksSalesReceiptID
        self.quickBooksAccountingSyncStatus = quickBooksAccountingSyncStatus
        self.quickBooksAccountingSyncDetail = quickBooksAccountingSyncDetail
        self.processorSyncStatus = processorSyncStatus
        self.processorSyncDetail = processorSyncDetail
        self.settlementBatchID = settlementBatchID
        self.storedCardID = storedCardID
        self.amount = amount
        self.date = date
        self.method = method
        self.cardLast4 = cardLast4
        self.authorizationReference = authorizationReference
        self.notes = notes
        self.processor = processor
        self.isRefund = isRefund
        self.refundedPaymentID = refundedPaymentID
    }
}

extension Payment {
    /// Canonical trust-boundary value accepted by shared company storage.
    /// The durable local method may include masked display details.
    var backendCollectionMethod: String? {
        let normalized = method.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["card", "ach", "cash", "check"].first { code in
            normalized == code || normalized.hasPrefix("\(code) ")
        }
    }

    var processorDisplayName: String? {
        guard let processor, !processor.isEmpty else { return nil }
        switch processor {
        case OnsitePaymentProcessor.quickBooksPayments.rawValue:
            return OnsitePaymentProcessor.quickBooksPayments.displayName
        case "manual-entry":
            return "Manual Card Entry"
        case "onsite-recorded":
            return "On-Site Collection"
        default:
            return processor.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var methodSummary: String {
        if let processorDisplayName {
            return "\(method.capitalized) via \(processorDisplayName)"
        }
        return method.capitalized
    }

    var needsQuickBooksAttention: Bool {
        quickBooksAccountingSyncStatus == "needs_attention" ||
            (processorSyncStatus == "needs_attention" && !needsSharedCompanyQueueUpload)
    }

    var needsSharedCompanyQueueUpload: Bool {
        let status = processorSyncStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let detail = processorSyncDetail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if status == "local_only" {
            return true
        }
        return status == "needs_attention" && detail.contains("shared company payment queue")
    }

    var hasProcessorCapture: Bool {
        quickBooksChargeID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var hasAccountingPayment: Bool {
        quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func markSharedCompanyQueueUnavailable() {
        processorSyncStatus = processorSyncStatus ?? "local_only"
        processorSyncDetail = "Shared company payment queue is not configured on this build."
    }

    func markSharedCompanyQueued() {
        processorSyncStatus = "company_queued"
        processorSyncDetail = "Payment record uploaded to shared company storage for admin QuickBooks reconciliation."
    }

    func markSharedCompanyQueueFailed(_ errorDescription: String) {
        processorSyncStatus = "needs_attention"
        processorSyncDetail = "Shared company payment queue upload failed: \(errorDescription)"
    }
}

enum PaymentCollectionGuard {
    static func validationMessage(invoice: Invoice, amount: Double, payments: [Payment]) -> String? {
        if let blockedMessage = invoice.paymentCollectionBlockedMessage {
            return blockedMessage
        }
        guard amount > 0 else { return "Enter a payment amount greater than zero." }
        let balanceDue = Invoice.outstandingBalance(for: invoice, payments: payments)
        guard balanceDue > 0.005 else {
            return "This invoice has no open balance. Refresh the payment history before collecting again."
        }
        guard amount <= balanceDue + 0.005 else {
            return "The payment amount exceeds this invoice's open balance of \(balanceDue.formatted(.currency(code: "USD")))."
        }
        return nil
    }
}
