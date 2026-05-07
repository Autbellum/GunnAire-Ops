// Payment.swift
// Model for payments
import Foundation
import SwiftData

@Model
final class Payment {
    @Attribute(.unique) var id: UUID
    var invoice: Invoice
    var quickBooksID: String?
    var quickBooksChargeID: String?
    var quickBooksClientTransID: String?
    var quickBooksRefundReceiptID: String?
    var quickBooksAccountingSyncStatus: String?
    var quickBooksAccountingSyncDetail: String?
    var amount: Double
    var date: Date
    var method: String // cash, check, card
    var cardLast4: String?
    var authorizationReference: String?
    var notes: String?
    var processor: String?
    var isRefund: Bool
    var refundedPaymentID: UUID?
    
    init(
        id: UUID = UUID(),
        invoice: Invoice,
        quickBooksID: String? = nil,
        quickBooksChargeID: String? = nil,
        quickBooksClientTransID: String? = nil,
        quickBooksRefundReceiptID: String? = nil,
        quickBooksAccountingSyncStatus: String? = nil,
        quickBooksAccountingSyncDetail: String? = nil,
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
        self.quickBooksAccountingSyncStatus = quickBooksAccountingSyncStatus
        self.quickBooksAccountingSyncDetail = quickBooksAccountingSyncDetail
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
        quickBooksAccountingSyncStatus == "needs_attention"
    }
}
