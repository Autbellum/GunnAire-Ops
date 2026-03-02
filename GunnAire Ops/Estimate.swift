// Estimate.swift
// Model for service estimates
import Foundation
import SwiftData

@Model
final class Estimate {
    @Attribute(.unique) var id: UUID
    var serviceCall: ServiceCall
    var quickBooksID: String?
    var amount: Double
    var status: String // pending, accepted, rejected, invoiced, etc.
    // You can extend with lineItems
    
    init(id: UUID = UUID(), serviceCall: ServiceCall, quickBooksID: String? = nil, amount: Double = 0, status: String = "pending") {
        self.id = id
        self.serviceCall = serviceCall
        self.quickBooksID = quickBooksID
        self.amount = amount
        self.status = status
    }
}
