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
