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

    var isOverdue: Bool {
        nextDate < Calendar.current.startOfDay(for: Date())
    }

    var needsReminder: Bool {
        reminderDate <= Date() && nextDate >= Calendar.current.startOfDay(for: Date())
    }

    var reminderDate: Date {
        Calendar.current.date(byAdding: .day, value: -7, to: nextDate) ?? nextDate
    }

    func advanceNextDate() {
        let calendar = Calendar.current
        let lowercasedPattern = schedulePattern.lowercased()

        if lowercasedPattern.contains("quarter") || lowercasedPattern.contains("3 month") {
            nextDate = calendar.date(byAdding: .month, value: 3, to: nextDate) ?? nextDate
            return
        }
        if lowercasedPattern.contains("6 month") || lowercasedPattern.contains("semi") {
            nextDate = calendar.date(byAdding: .month, value: 6, to: nextDate) ?? nextDate
            return
        }
        if lowercasedPattern.contains("year") || lowercasedPattern.contains("annual") || lowercasedPattern.contains("12 month") {
            nextDate = calendar.date(byAdding: .year, value: 1, to: nextDate) ?? nextDate
            return
        }
        if lowercasedPattern.contains("month") {
            nextDate = calendar.date(byAdding: .month, value: 1, to: nextDate) ?? nextDate
            return
        }
        nextDate = calendar.date(byAdding: .month, value: 6, to: nextDate) ?? nextDate
    }
}
