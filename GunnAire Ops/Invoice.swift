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
}
