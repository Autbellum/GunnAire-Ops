// Payment.swift
// Model for payments
import Foundation
import SwiftData

@Model
final class Payment {
    @Attribute(.unique) var id: UUID
    var invoice: Invoice
    var quickBooksID: String?
    var amount: Double
    var date: Date
    var method: String // cash, check, card
    
    init(id: UUID = UUID(), invoice: Invoice, quickBooksID: String? = nil, amount: Double, date: Date = Date(), method: String = "cash") {
        self.id = id
        self.invoice = invoice
        self.quickBooksID = quickBooksID
        self.amount = amount
        self.date = date
        self.method = method
    }
}
