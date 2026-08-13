// Invoice.swift
// Model for invoices
import Foundation
import SwiftData

@Model
final class Invoice {
    @Attribute(.unique) var id: UUID
    var serviceCallID: UUID?
    var customer: Customer
    var quickBooksID: String?
    var quickBooksBalanceDue: Double?
    var lineItemSummary: String
    var amount: Double
    var status: String // unpaid, paid, overdue
    var notes: String?
    var customerSignatureName: String?
    var customerSignatureImageBase64: String?
    var customerSignedAt: Date?
    var completionNotes: String?
    var finalizedAt: Date?
    var createdAt: Date
    
    init(
        id: UUID = UUID(),
        serviceCallID: UUID? = nil,
        customer: Customer,
        quickBooksID: String? = nil,
        quickBooksBalanceDue: Double? = nil,
        lineItemSummary: String = "",
        amount: Double = 0,
        status: String = "unpaid",
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
        self.customer = customer
        self.quickBooksID = quickBooksID
        self.quickBooksBalanceDue = quickBooksBalanceDue
        self.lineItemSummary = lineItemSummary
        self.amount = amount
        self.status = status
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

    var hasQuickBooksBalance: Bool {
        quickBooksBalanceDue != nil && quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
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
        if let quickBooksID = invoice.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !quickBooksID.isEmpty {
            return "qb:\(quickBooksID.lowercased())"
        }
        if let serviceCallID = invoice.serviceCallID {
            return "call:\(serviceCallID.uuidString.lowercased()):\(String(format: "%.2f", invoice.amount))"
        }
        let customerKey = invoice.customer.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let day = Calendar.current.startOfDay(for: invoice.createdAt).timeIntervalSince1970
        return "local:\(customerKey):\(String(format: "%.2f", invoice.amount)):\(Int(day))"
    }

    private static func preferredDisplayInvoice(_ lhs: Invoice, _ rhs: Invoice) -> Invoice {
        let lhsHasQuickBooks = lhs.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let rhsHasQuickBooks = rhs.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if lhsHasQuickBooks != rhsHasQuickBooks {
            return rhsHasQuickBooks ? rhs : lhs
        }
        let lhsRank = rank(for: lhs.status)
        let rhsRank = rank(for: rhs.status)
        if lhsRank != rhsRank {
            return rhsRank > lhsRank ? rhs : lhs
        }
        return rhs.createdAt > lhs.createdAt ? rhs : lhs
    }
}
