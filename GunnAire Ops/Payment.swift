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
    var cardLast4: String?
    var authorizationReference: String?
    var notes: String?
    var processor: String?
    
    init(
        id: UUID = UUID(),
        invoice: Invoice,
        quickBooksID: String? = nil,
        amount: Double,
        date: Date = Date(),
        method: String = "cash",
        cardLast4: String? = nil,
        authorizationReference: String? = nil,
        notes: String? = nil,
        processor: String? = nil
    ) {
        self.id = id
        self.invoice = invoice
        self.quickBooksID = quickBooksID
        self.amount = amount
        self.date = date
        self.method = method
        self.cardLast4 = cardLast4
        self.authorizationReference = authorizationReference
        self.notes = notes
        self.processor = processor
    }
}
