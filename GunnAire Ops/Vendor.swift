// Vendor.swift
// Model for vendors
import Foundation
import SwiftData

@Model
final class Vendor {
    @Attribute(.unique) var id: UUID
    var quickBooksID: String?
    var name: String
    var contactInfo: String?
    
    init(id: UUID = UUID(), quickBooksID: String? = nil, name: String, contactInfo: String? = nil) {
        self.id = id
        self.quickBooksID = quickBooksID
        self.name = name
        self.contactInfo = contactInfo
    }
}
