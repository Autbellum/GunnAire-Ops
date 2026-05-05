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

    init(id: UUID = UUID(), userEmail: String, clockIn: Date = Date(), clockOut: Date? = nil, serviceCall: ServiceCall? = nil, notes: String? = nil) {
        self.id = id
        self.userEmail = userEmail
        self.clockIn = clockIn
        self.clockOut = clockOut
        self.serviceCall = serviceCall
        self.notes = notes
    }

    var isOpen: Bool {
        clockOut == nil
    }
}
