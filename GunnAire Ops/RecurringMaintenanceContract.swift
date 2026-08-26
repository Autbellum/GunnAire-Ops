// RecurringMaintenanceContract.swift
// Model for recurring maintenance contracts
import Foundation
import SwiftData

@Model
final class RecurringMaintenanceContract {
    var id: UUID = UUID()
    var customer: Customer!
    var planName: String?
    var schedulePattern: String = "every 6 months" // e.g., 'every 6 months'
    var nextDate: Date = Date()
    var active: Bool = true
    var termEndsOn: Date?
    var pricePerVisit: Double?
    var includedVisitsPerTerm: Int?
    var renewalReminderDays: Int = 30
    var coveredEquipmentIDsJSON: String?
    
    init(
        id: UUID = UUID(),
        customer: Customer,
        planName: String? = nil,
        schedulePattern: String,
        nextDate: Date,
        active: Bool = true,
        termEndsOn: Date? = nil,
        pricePerVisit: Double? = nil,
        includedVisitsPerTerm: Int? = nil,
        renewalReminderDays: Int = 30,
        coveredEquipmentIDs: Set<UUID> = []
    ) {
        self.id = id
        self.customer = customer
        self.planName = planName
        self.schedulePattern = schedulePattern
        self.nextDate = nextDate
        self.active = active
        self.termEndsOn = termEndsOn
        self.pricePerVisit = pricePerVisit
        self.includedVisitsPerTerm = includedVisitsPerTerm
        self.renewalReminderDays = max(1, renewalReminderDays)
        self.coveredEquipmentIDsJSON = Self.encodeCoveredEquipmentIDs(coveredEquipmentIDs)
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

    var displayName: String {
        let value = planName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Maintenance Agreement" : value
    }

    var coveredEquipmentIDs: Set<UUID> {
        guard let coveredEquipmentIDsJSON,
              let data = coveredEquipmentIDsJSON.data(using: .utf8),
              let values = try? JSONDecoder().decode([UUID].self, from: data) else { return [] }
        return Set(values)
    }

    var renewalReminderDate: Date? {
        guard let termEndsOn else { return nil }
        return Calendar.current.date(byAdding: .day, value: -max(1, renewalReminderDays), to: termEndsOn)
    }

    var isExpired: Bool {
        guard let termEndsOn else { return false }
        return termEndsOn < Calendar.current.startOfDay(for: Date())
    }

    var needsRenewalAttention: Bool {
        guard active, !isExpired, let renewalReminderDate else { return false }
        return renewalReminderDate <= Date()
    }

    var canScheduleVisit: Bool {
        active && !isExpired
    }

    func updateCoveredEquipmentIDs(_ ids: Set<UUID>) {
        coveredEquipmentIDsJSON = Self.encodeCoveredEquipmentIDs(ids)
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

    private static func encodeCoveredEquipmentIDs(_ ids: Set<UUID>) -> String? {
        guard !ids.isEmpty,
              let data = try? JSONEncoder().encode(ids.sorted { $0.uuidString < $1.uuidString }) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
