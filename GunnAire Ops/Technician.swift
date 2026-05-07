// Technician.swift
// Model for technicians, ready for SwiftData
import Foundation
import SwiftData

@Model
final class Technician {
    @Attribute(.unique) var id: UUID
    var name: String
    var contactInfo: String?
    @Relationship(inverse: \ServiceCall.assignedTechnician) var assignedServiceCalls: [ServiceCall] = []

    var jobsCount: Int {
        assignedServiceCalls.filter { $0.status != .cancelled }.count
    }
    
    init(id: UUID = UUID(), name: String, contactInfo: String? = nil) {
        self.id = id
        self.name = name
        self.contactInfo = contactInfo
    }
}
