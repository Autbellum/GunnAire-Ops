// ServiceCall.swift
// Model for scheduled jobs and service calls
import Foundation
import SwiftData

enum ServiceCallType: String, Codable, CaseIterable {
    case service, estimate, install, maintenance
}

enum JobStatus: String, Codable, CaseIterable {
    case scheduled, inProgress, completed, invoiced, cancelled
}

@Model
final class ServiceCall {
    @Attribute(.unique) var id: UUID
    var type: ServiceCallType
    var scheduledDate: Date
    var duration: TimeInterval
    var assignedTechnician: Technician?
    var customer: Customer
    var status: JobStatus
    var notes: String?
    
    init(id: UUID = UUID(), type: ServiceCallType, scheduledDate: Date, duration: TimeInterval = 3600, assignedTechnician: Technician? = nil, customer: Customer, status: JobStatus = .scheduled, notes: String? = nil) {
        self.id = id
        self.type = type
        self.scheduledDate = scheduledDate
        self.duration = duration
        self.assignedTechnician = assignedTechnician
        self.customer = customer
        self.status = status
        self.notes = notes
    }
    
    var isUpcomingThisWeek: Bool {
        let now = Date()
        let oneWeekLater = Calendar.current.date(byAdding: .day, value: 7, to: now)!
        return scheduledDate >= now && scheduledDate <= oneWeekLater
    }
    
    // Future extension: sync with QuickBooks or Google Calendar
}
