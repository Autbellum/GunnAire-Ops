import Foundation

struct GoogleCalendarReminders: Codable, Equatable {
    struct Override: Codable, Equatable {
        let method: String
        let minutes: Int
    }
    let useDefault: Bool
    var overrides: [Override]? = nil

    // An explicit reminder also works when the organizer has no calendar default.
    static let appointmentDefault = Self(useDefault: false, overrides: [.init(method: "popup", minutes: 30)])
}

/// Separate from the schedule-only patch: only the guarded staff-delivery path
/// may change guests. Customer communication is never authorized by this type.
struct GoogleCalendarStaffDeliveryPatch: Encodable {
    var attendees: [GoogleCalendarAttendee]?
    var reminders: GoogleCalendarReminders?
    var extendedProperties: GoogleCalendarExtendedProperties?
}

enum GoogleCalendarStaffDeliveryError: LocalizedError {
    case staffEmail, guestReview
    var errorDescription: String? {
        switch self {
        case .staffEmail: "An assigned technician or crew member needs a unique staff record and valid calendar email. Update the technician contact, then sync again."
        case .guestReview: "The Google event has external or incomplete guest details. Review its staff invitations in Google Calendar; no customer invitation was sent."
        }
    }
}

enum GoogleCalendarStaffDelivery {
    static let managedEmailsKey = "gunnaireStaffAttendees"

    static func email(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.range(of: #"^[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9.-]*[A-Z0-9])?\.[A-Z]{2,}$"#,
                               options: [.caseInsensitive, .regularExpression]) != nil else { return nil }
        return normalized
    }

    static func canNotify(_ event: GoogleCalendarEvent, knownStaff: Set<String>) -> Bool {
        guard event.attendeesOmitted != true, let attendees = event.attendees, !attendees.isEmpty else { return false }
        guard Set(attendees.compactMap { email($0.email) }).count == attendees.count else { return false }
        return attendees.allSatisfy { attendee in
            guard let address = email(attendee.email), attendee.resource != true else { return false }
            return knownStaff.contains(address)
        }
    }

    static func patch(remote: GoogleCalendarEvent, desired: [GoogleWritableCalendarAttendee],
                      knownStaff: Set<String>, restoreReminder: Bool) throws -> GoogleCalendarStaffDeliveryPatch? {
        let existing = remote.attendees ?? []
        let desiredEmails = Set(desired.map(\.email))
        guard desiredEmails.count == desired.count,
              desired.allSatisfy({ email($0.email) == $0.email && knownStaff.contains($0.email) }) else {
            throw GoogleCalendarStaffDeliveryError.staffEmail
        }
        let existingEmails = Set(existing.compactMap { email($0.email) })
        let properties = remote.extendedProperties?.privateProperties ?? [:]
        let previouslyManaged = Set((properties[managedEmailsKey] ?? "").split(separator: ",").map(String.init))
        let remove = previouslyManaged.subtracting(desiredEmails).intersection(existingEmails)
        let add = desiredEmails.subtracting(existingEmails)
        var patch = GoogleCalendarStaffDeliveryPatch()
        if !add.isEmpty || !remove.isEmpty {
            // PATCH replaces the guest array. Never act on an omitted guest list,
            // invite customers, or remove guests the app did not originally add.
            guard remote.attendeesOmitted != true,
                  existing.isEmpty || canNotify(remote, knownStaff: knownStaff) else {
                throw GoogleCalendarStaffDeliveryError.guestReview
            }
            patch.attendees = existing.filter { !remove.contains(email($0.email) ?? "") }
            for attendee in desired where add.contains(attendee.email) {
                patch.attendees?.append(.init(email: attendee.email, displayName: attendee.displayName,
                                              selfAttendee: nil, resource: nil))
            }
            var updated = properties
            updated[managedEmailsKey] = desiredEmails.sorted().joined(separator: ",")
            patch.extendedProperties = .init(privateProperties: updated)
        }
        // Preserve deliberate Google reminders (including a user's explicit off).
        if restoreReminder && remote.reminders == nil { patch.reminders = .appointmentDefault }
        return patch.attendees == nil && patch.reminders == nil ? nil : patch
    }
}
