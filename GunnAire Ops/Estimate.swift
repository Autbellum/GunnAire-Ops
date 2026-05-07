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
}
