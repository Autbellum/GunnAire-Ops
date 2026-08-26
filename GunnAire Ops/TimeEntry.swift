import Foundation
import SwiftData

@Model
final class TimeEntry {
    var id: UUID = UUID()
    var userEmail: String = ""
    var clockIn: Date = Date()
    var clockOut: Date?
    var serviceCall: ServiceCall?
    var notes: String?
    var quickBooksTimeActivityID: String?
    var quickBooksTimeActivitySyncToken: String?
    var quickBooksTimeActivitySyncedAt: Date?
    var quickBooksTimeActivitySyncError: String?

    init(
        id: UUID = UUID(),
        userEmail: String,
        clockIn: Date = Date(),
        clockOut: Date? = nil,
        serviceCall: ServiceCall? = nil,
        notes: String? = nil,
        quickBooksTimeActivityID: String? = nil,
        quickBooksTimeActivitySyncToken: String? = nil,
        quickBooksTimeActivitySyncedAt: Date? = nil,
        quickBooksTimeActivitySyncError: String? = nil
    ) {
        self.id = id
        self.userEmail = userEmail
        self.clockIn = clockIn
        self.clockOut = clockOut
        self.serviceCall = serviceCall
        self.notes = notes
        self.quickBooksTimeActivityID = quickBooksTimeActivityID
        self.quickBooksTimeActivitySyncToken = quickBooksTimeActivitySyncToken
        self.quickBooksTimeActivitySyncedAt = quickBooksTimeActivitySyncedAt
        self.quickBooksTimeActivitySyncError = quickBooksTimeActivitySyncError
    }

    var isOpen: Bool {
        clockOut == nil
    }

    var durationMinutes: Int? {
        guard let clockOut else { return nil }
        return max(1, Int((clockOut.timeIntervalSince(clockIn) / 60).rounded()))
    }
}

enum JobLaborCosting {
    struct Summary: Equatable {
        let totalCost: Double?
        let costedMinutes: Int
        let uncostedMinutes: Int

        var hasCompletedTime: Bool { costedMinutes + uncostedMinutes > 0 }
    }

    /// Returns nil when the office has not configured a loaded labor cost or no completed job time exists.
    static func cost(entries: [TimeEntry], hourlyCost: Double?) -> Double? {
        guard let hourlyCost, hourlyCost >= 0 else { return nil }
        let completedMinutes = entries.compactMap(\.durationMinutes).reduce(0, +)
        guard completedMinutes > 0 else { return nil }
        return (Double(completedMinutes) / 60) * hourlyCost
    }

    /// Costs each completed entry against the technician who recorded it. Entries
    /// without a configured technician rate remain visible as uncosted time so an
    /// office user does not mistake a partial margin for a final one.
    static func summary(entries: [TimeEntry], technicians: [Technician]) -> Summary {
        let ratesByEmail = technicians.reduce(into: [String: Double]()) { rates, technician in
            guard let rate = technician.laborCostPerHour, rate >= 0 else { return }
            let email = AppAccess.normalizedEmail(technician.contactInfo)
            guard !email.isEmpty else { return }
            rates[email] = rate
        }

        var costedMinutes = 0
        var uncostedMinutes = 0
        var totalCost = 0.0
        for entry in entries {
            guard let minutes = entry.durationMinutes else { continue }
            guard let rate = ratesByEmail[AppAccess.normalizedEmail(entry.userEmail)] else {
                uncostedMinutes += minutes
                continue
            }
            costedMinutes += minutes
            totalCost += (Double(minutes) / 60) * rate
        }
        return Summary(
            totalCost: costedMinutes > 0 ? totalCost : nil,
            costedMinutes: costedMinutes,
            uncostedMinutes: uncostedMinutes
        )
    }
}
