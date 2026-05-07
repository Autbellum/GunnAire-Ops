// Customer.swift
// Model for customers, ready for SwiftData
import Foundation
import SwiftData

@Model
final class Customer {
    @Attribute(.unique) var id: UUID
    var quickBooksID: String?
    var name: String
    var phone: String?
    var email: String?
    var address: String?
    @Relationship(inverse: \RecurringMaintenanceContract.customer) var recurringContracts: [RecurringMaintenanceContract] = []
    @Relationship(inverse: \ServiceCall.customer) var serviceCalls: [ServiceCall] = []
    @Relationship(inverse: \Invoice.customer) var invoices: [Invoice] = []
    
    init(id: UUID = UUID(), quickBooksID: String? = nil, name: String, phone: String? = nil, email: String? = nil, address: String? = nil) {
        self.id = id
        self.quickBooksID = quickBooksID
        self.name = name
        self.phone = phone
        self.email = email
        self.address = address
    }
}

extension Customer {
    var activeContractsCount: Int {
        recurringContracts.filter(\.active).count
    }
}
