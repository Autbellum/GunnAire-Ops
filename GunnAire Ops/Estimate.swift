// Estimate.swift
// Model for service estimates
import Foundation
import SwiftData

@Model
final class Estimate {
    @Attribute(.unique) var id: UUID
    var serviceCallID: UUID?
    var customer: Customer
    var quickBooksID: String?
    var lineItemSummary: String
    var amount: Double
    var status: String // pending, accepted, rejected, invoiced, etc.
    var notes: String?
    var createdAt: Date
    
    init(
        id: UUID = UUID(),
        serviceCallID: UUID? = nil,
        customer: Customer,
        quickBooksID: String? = nil,
        lineItemSummary: String = "",
        amount: Double = 0,
        status: String = "pending",
        notes: String? = nil,
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
        self.createdAt = createdAt
    }

    static func displayDeduplicated(_ estimates: [Estimate]) -> [Estimate] {
        var selectedByKey: [String: Estimate] = [:]
        for estimate in estimates {
            let key = displayDedupeKey(for: estimate)
            if let existing = selectedByKey[key] {
                selectedByKey[key] = preferredDisplayEstimate(existing, estimate)
            } else {
                selectedByKey[key] = estimate
            }
        }
        return selectedByKey.values.sorted { lhs, rhs in
            lhs.createdAt > rhs.createdAt
        }
    }

    private static func displayDedupeKey(for estimate: Estimate) -> String {
        if let serviceCallID = estimate.serviceCallID {
            return "call:\(serviceCallID.uuidString.lowercased()):\(String(format: "%.2f", estimate.amount))"
        }
        if let quickBooksID = estimate.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !quickBooksID.isEmpty {
            return "qb:\(quickBooksID.lowercased())"
        }
        let customerKey = estimate.customer.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let day = Calendar.current.startOfDay(for: estimate.createdAt).timeIntervalSince1970
        return "local:\(customerKey):\(String(format: "%.2f", estimate.amount)):\(Int(day))"
    }

    private static func preferredDisplayEstimate(_ lhs: Estimate, _ rhs: Estimate) -> Estimate {
        let lhsHasQuickBooks = lhs.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let rhsHasQuickBooks = rhs.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if lhsHasQuickBooks != rhsHasQuickBooks {
            return rhsHasQuickBooks ? rhs : lhs
        }
        return rhs.createdAt > lhs.createdAt ? rhs : lhs
    }
}
