import Foundation
import SwiftData

@Model
final class TimeEntry {
    @Attribute(.unique) var id: UUID
    var userEmail: String
    var clockIn: Date
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
