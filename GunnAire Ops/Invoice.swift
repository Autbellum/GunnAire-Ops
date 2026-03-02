// Invoice.swift
// Model for invoices
import Foundation
import SwiftData

@Model
final class Invoice {
    @Attribute(.unique) var id: UUID
    var serviceCall: ServiceCall
    var quickBooksID: String?
    var amount: Double
    var status: String // unpaid, paid, overdue
    
    init(id: UUID = UUID(), serviceCall: ServiceCall, quickBooksID: String? = nil, amount: Double = 0, status: String = "unpaid") {
        self.id = id
        self.serviceCall = serviceCall
        self.quickBooksID = quickBooksID
        self.amount = amount
        self.status = status
    }
}
