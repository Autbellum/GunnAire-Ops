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
    
    init(id: UUID = UUID(), quickBooksID: String? = nil, name: String, phone: String? = nil, email: String? = nil, address: String? = nil) {
        self.id = id
        self.quickBooksID = quickBooksID
        self.name = name
        self.phone = phone
        self.email = email
        self.address = address
    }
}
// Extension for syncing contact info with Google Contacts or QuickBooks
extension Customer {
    /// TODO: Return the number of active contracts for this customer
    var activeContractsCount: Int {
        return 0
    }
}

