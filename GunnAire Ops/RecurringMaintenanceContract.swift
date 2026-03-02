// RecurringMaintenanceContract.swift
// Model for recurring maintenance contracts
import Foundation
import SwiftData

@Model
final class RecurringMaintenanceContract {
    @Attribute(.unique) var id: UUID
    var customer: Customer
    var schedulePattern: String // e.g., 'every 6 months'
    var nextDate: Date
    var active: Bool
    
    init(id: UUID = UUID(), customer: Customer, schedulePattern: String, nextDate: Date, active: Bool = true) {
        self.id = id
        self.customer = customer
        self.schedulePattern = schedulePattern
        self.nextDate = nextDate
        self.active = active
    }
    
    var isUpcoming: Bool {
        let now = Date()
        let thirtyDaysAhead = Calendar.current.date(byAdding: .day, value: 30, to: now)!
        return nextDate >= now && nextDate <= thirtyDaysAhead
    }
    
    // Future extension: Link contracts with Google Calendar or reminders
}
