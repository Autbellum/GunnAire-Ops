// Invoice.swift
// Model for invoices
import Foundation
import SwiftData

@Model
final class Invoice {
    @Attribute(.unique) var id: UUID
    var customer: Customer
    var quickBooksID: String?
    var lineItemSummary: String
    var amount: Double
    var status: String // unpaid, paid, overdue
    var notes: String?
    var createdAt: Date
    
    init(id: UUID = UUID(), customer: Customer, quickBooksID: String? = nil, lineItemSummary: String = "", amount: Double = 0, status: String = "unpaid", notes: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.customer = customer
        self.quickBooksID = quickBooksID
        self.lineItemSummary = lineItemSummary
        self.amount = amount
        self.status = status
        self.notes = notes
        self.createdAt = createdAt
    }
}
