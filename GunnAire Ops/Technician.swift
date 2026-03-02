// Technician.swift
// Model for technicians, ready for SwiftData
import Foundation
import SwiftData

@Model
final class Technician {
    @Attribute(.unique) var id: UUID
    var name: String
    var contactInfo: String?
    // Extend with skills, certifications, etc.
    
    // Extension: assign jobs via Google or QuickBooks integration
    
    // TODO: link with ServiceCall
    var jobsCount: Int {
        return 0
    }
    
    init(id: UUID = UUID(), name: String, contactInfo: String? = nil) {
        self.id = id
        self.name = name
        self.contactInfo = contactInfo
    }
}
