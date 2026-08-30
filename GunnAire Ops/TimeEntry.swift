import Foundation
import SwiftData

enum TimeEntryActivity: String, Codable, CaseIterable, Identifiable, Sendable {
    case job
    case travel
    case supplyRun = "supply_run"
    case shopWarehouse = "shop_warehouse"
    case training
    case meeting
    case administrative
    case paidBreak = "paid_break"
    case unpaidBreak = "unpaid_break"
    case general

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .job: "Job Labor"
        case .travel: "Travel"
        case .supplyRun: "Supply Run"
        case .shopWarehouse: "Shop / Warehouse"
        case .training: "Training"
        case .meeting: "Meeting"
        case .administrative: "Administrative"
        case .paidBreak: "Paid Break"
        case .unpaidBreak: "Unpaid Break"
        case .general: "General"
        }
    }

    var systemImage: String {
        switch self {
        case .job: "wrench.and.screwdriver"
        case .travel: "car"
        case .supplyRun: "shippingbox"
        case .shopWarehouse: "building.2"
        case .training: "graduationcap"
        case .meeting: "person.3"
        case .administrative: "doc.text"
        case .paidBreak: "cup.and.saucer"
        case .unpaidBreak: "pause.circle"
        case .general: "clock"
        }
    }

    var requiresServiceCall: Bool { self == .job }

    /// Unpaid breaks remain visible in the audit and review timeline, but they
    /// are not included in approved work-hour totals or QBO TimeActivity writes.
    var countsTowardPayableTime: Bool { self != .unpaidBreak }

    var isQuickBooksPublishable: Bool { countsTowardPayableTime }
}

enum TimeEntryReviewStatus: String, Codable, CaseIterable {
    case submitted
    case correctionRequested = "correction_requested"
    case approved

    var displayName: String {
        switch self {
        case .submitted: "Ready for review"
        case .correctionRequested: "Correction requested"
        case .approved: "Approved"
        }
    }

    var systemImage: String {
        switch self {
        case .submitted: "clock.badge.questionmark"
        case .correctionRequested: "exclamationmark.bubble"
        case .approved: "checkmark.seal.fill"
        }
    }
}

enum TimeEntryReviewAction: String, Codable {
    case submitted
    case correctionRequested = "correction_requested"
    case correctedAndResubmitted = "corrected_and_resubmitted"
    case approved
}

struct TimeEntryReviewEvent: Codable, Equatable, Identifiable {
    let id: UUID
    let action: TimeEntryReviewAction
    let actorEmail: String
    let occurredAt: Date
    let detail: String?

    init(
        id: UUID = UUID(),
        action: TimeEntryReviewAction,
        actorEmail: String,
        occurredAt: Date,
        detail: String? = nil
    ) {
        self.id = id
        self.action = action
        self.actorEmail = actorEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.occurredAt = occurredAt
        let normalizedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.detail = normalizedDetail?.isEmpty == false ? String(normalizedDetail!.prefix(500)) : nil
    }
}

enum TimeEntryReviewAudit {
    private static let maximumEventCount = 100

    private struct Envelope: Codable {
        var version: Int = 1
        var activityRawValue: String?
        var events: [TimeEntryReviewEvent]
    }

    static func events(from json: String?) -> [TimeEntryReviewEvent] {
        envelope(from: json).events
    }

    static func activity(from json: String?) -> TimeEntryActivity? {
        guard let rawValue = envelope(from: json).activityRawValue else { return nil }
        return TimeEntryActivity(rawValue: rawValue)
    }

    static func settingActivity(_ activity: TimeEntryActivity, in json: String?) -> String? {
        var value = envelope(from: json)
        value.activityRawValue = activity.rawValue
        return encoded(value) ?? json
    }

    static func appending(_ event: TimeEntryReviewEvent, to json: String?) -> String? {
        var value = envelope(from: json)
        value.events = Array((value.events + [event]).suffix(maximumEventCount))
        return encoded(value) ?? json
    }

    private static func envelope(from json: String?) -> Envelope {
        guard let json, let data = json.data(using: .utf8) else {
            return Envelope(events: [])
        }
        if let value = try? JSONDecoder().decode(Envelope.self, from: data) {
            return value
        }
        if let legacyEvents = try? JSONDecoder().decode([TimeEntryReviewEvent].self, from: data) {
            return Envelope(events: legacyEvents)
        }
        return Envelope(events: [])
    }

    private static func encoded(_ envelope: Envelope) -> String? {
        guard let data = try? JSONEncoder().encode(envelope) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

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
    /// Completed time stays local until an authorized office reviewer approves
    /// it. The raw value is CloudKit-compatible and defaults legacy, completed
    /// records into the review queue unless they already have a QBO ID.
    var reviewStatusRawValue: String = TimeEntryReviewStatus.submitted.rawValue
    var reviewedByEmail: String?
    var reviewedAt: Date?
    var reviewNote: String?
    /// Versioned, bounded JSON retains the current activity classification and
    /// append-only review events without adding another CloudKit model field.
    var reviewAuditJSON: String?

    init(
        id: UUID = UUID(),
        userEmail: String,
        clockIn: Date = Date(),
        clockOut: Date? = nil,
        serviceCall: ServiceCall? = nil,
        notes: String? = nil,
        activity: TimeEntryActivity? = nil,
        quickBooksTimeActivityID: String? = nil,
        quickBooksTimeActivitySyncToken: String? = nil,
        quickBooksTimeActivitySyncedAt: Date? = nil,
        quickBooksTimeActivitySyncError: String? = nil,
        reviewStatus: TimeEntryReviewStatus = .submitted,
        reviewedByEmail: String? = nil,
        reviewedAt: Date? = nil,
        reviewNote: String? = nil,
        reviewAuditJSON: String? = nil
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
        reviewStatusRawValue = reviewStatus.rawValue
        let normalizedReviewer = reviewedByEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.reviewedByEmail = normalizedReviewer?.isEmpty == false ? normalizedReviewer : nil
        self.reviewedAt = reviewedAt
        self.reviewNote = Self.normalizedReviewNote(reviewNote)
        self.reviewAuditJSON = reviewAuditJSON
        if let activity {
            self.activity = activity
        }
    }

    var isOpen: Bool {
        clockOut == nil
    }

    var durationMinutes: Int? {
        guard let clockOut else { return nil }
        return max(1, Int((clockOut.timeIntervalSince(clockIn) / 60).rounded()))
    }

    /// Legacy entries infer their activity from the existing job relationship.
    /// New selections live in the existing CloudKit-backed review envelope, so
    /// this feature does not add a model field or require a schema migration.
    var activity: TimeEntryActivity {
        get {
            TimeEntryReviewAudit.activity(from: reviewAuditJSON)
                ?? (serviceCall == nil ? .general : .job)
        }
        set {
            reviewAuditJSON = TimeEntryReviewAudit.settingActivity(newValue, in: reviewAuditJSON)
        }
    }

    var payableDurationMinutes: Int? {
        guard let durationMinutes else { return nil }
        return activity.countsTowardPayableTime ? durationMinutes : 0
    }

    var reviewStatus: TimeEntryReviewStatus {
        get {
            let stored = TimeEntryReviewStatus(rawValue: reviewStatusRawValue) ?? .submitted
            // A QBO-linked record predating this approval workflow has already
            // crossed the accounting boundary. Treat it as approved legacy
            // evidence instead of incorrectly asking the office to approve and
            // publish it again.
            if stored == .submitted,
               reviewedAt == nil,
               quickBooksTimeActivityID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return .approved
            }
            return stored
        }
        set { reviewStatusRawValue = newValue.rawValue }
    }

    var reviewEvents: [TimeEntryReviewEvent] {
        TimeEntryReviewAudit.events(from: reviewAuditJSON)
    }

    var needsTeamReview: Bool {
        !isOpen && reviewStatus != .approved
    }

    var isApprovedForQuickBooksPublication: Bool {
        !isOpen && reviewStatus == .approved
    }

    var isEligibleForQuickBooksPublication: Bool {
        isApprovedForQuickBooksPublication && activity.isQuickBooksPublishable
    }

    func appendReviewEvent(
        _ action: TimeEntryReviewAction,
        actorEmail: String,
        at date: Date = Date(),
        detail: String? = nil
    ) {
        reviewAuditJSON = TimeEntryReviewAudit.appending(
            TimeEntryReviewEvent(
                action: action,
                actorEmail: actorEmail,
                occurredAt: date,
                detail: detail
            ),
            to: reviewAuditJSON
        )
    }

    private static func normalizedReviewNote(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized?.isEmpty == false ? String(normalized!.prefix(500)) : nil
    }
}

struct TimeEntryCorrectionDraft: Equatable {
    var clockIn: Date
    var clockOut: Date
    var activity: TimeEntryActivity
    var serviceCallID: UUID?
    var notes: String

    init(entry: TimeEntry) {
        clockIn = entry.clockIn
        clockOut = entry.clockOut ?? max(Date(), entry.clockIn.addingTimeInterval(60))
        activity = entry.activity
        serviceCallID = entry.serviceCall?.id
        notes = entry.notes ?? ""
    }
}

enum TimeEntryReviewError: LocalizedError, Equatable {
    case unauthorized
    case entryStillOpen
    case alreadyApproved
    case alreadyPublished
    case correctionStillRequired
    case missingCorrectionReason
    case invalidTimeRange
    case shiftTooLong
    case overlappingEntry
    case notesTooLong
    case jobActivityRequiresJob
    case nonJobActivityHasJob

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            "This account cannot review or change that time entry."
        case .entryStillOpen:
            "Clock out before submitting or approving this time entry."
        case .alreadyApproved:
            "This time entry is already approved and locked."
        case .alreadyPublished:
            "This time entry is already linked to QuickBooks and cannot be changed locally."
        case .correctionStillRequired:
            "Correct and resubmit this time entry before approval."
        case .missingCorrectionReason:
            "Explain what needs to be corrected."
        case .invalidTimeRange:
            "Clock-out must be later than clock-in."
        case .shiftTooLong:
            "A single time entry cannot exceed 24 hours. Split the time into separate entries."
        case .overlappingEntry:
            "This time overlaps another entry for the same team member."
        case .notesTooLong:
            "Keep time-entry notes to 1,000 characters or fewer."
        case .jobActivityRequiresJob:
            "Choose the service job for Job Labor time."
        case .nonJobActivityHasJob:
            "Only Job Labor time can be linked to a service job."
        }
    }
}

enum TimeEntryReviewPolicy {
    static let maximumShiftDuration: TimeInterval = 24 * 60 * 60

    static func submitAfterClockOut(
        _ entry: TimeEntry,
        actorEmail: String,
        at date: Date = Date()
    ) throws {
        guard let clockOut = entry.clockOut else { throw TimeEntryReviewError.entryStillOpen }
        guard clockOut > entry.clockIn else { throw TimeEntryReviewError.invalidTimeRange }
        guard clockOut.timeIntervalSince(entry.clockIn) <= maximumShiftDuration else {
            throw TimeEntryReviewError.shiftTooLong
        }
        try validateWorkContext(activity: entry.activity, serviceCall: entry.serviceCall)
        entry.reviewStatus = .submitted
        entry.reviewedByEmail = nil
        entry.reviewedAt = nil
        entry.reviewNote = nil
        entry.quickBooksTimeActivitySyncError = nil
        entry.appendReviewEvent(.submitted, actorEmail: actorEmail, at: date)
    }

    static func requestCorrection(
        for entry: TimeEntry,
        reason: String,
        actorEmail: String?,
        users: [AppUser],
        at date: Date = Date()
    ) throws {
        guard AppAccess.canReviewTeamTime(email: actorEmail, users: users) else {
            throw TimeEntryReviewError.unauthorized
        }
        guard !entry.isOpen else { throw TimeEntryReviewError.entryStillOpen }
        guard entry.quickBooksTimeActivityID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
            throw TimeEntryReviewError.alreadyPublished
        }
        guard entry.reviewStatus != .approved else { throw TimeEntryReviewError.alreadyApproved }
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedReason.isEmpty else { throw TimeEntryReviewError.missingCorrectionReason }

        let reviewer = AppAccess.normalizedEmail(actorEmail)
        let retainedReason = String(normalizedReason.prefix(500))
        entry.reviewStatus = .correctionRequested
        entry.reviewedByEmail = reviewer
        entry.reviewedAt = date
        entry.reviewNote = retainedReason
        entry.quickBooksTimeActivitySyncError = nil
        entry.appendReviewEvent(
            .correctionRequested,
            actorEmail: reviewer,
            at: date,
            detail: retainedReason
        )
    }

    static func applyCorrection(
        _ draft: TimeEntryCorrectionDraft,
        to entry: TimeEntry,
        serviceCall: ServiceCall?,
        allEntries: [TimeEntry],
        actorEmail: String?,
        users: [AppUser],
        at date: Date = Date()
    ) throws {
        let actor = AppAccess.normalizedEmail(actorEmail)
        let ownsEntry = actor == AppAccess.normalizedEmail(entry.userEmail)
        guard ownsEntry || AppAccess.canReviewTeamTime(email: actor, users: users) else {
            throw TimeEntryReviewError.unauthorized
        }
        guard entry.quickBooksTimeActivityID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
            throw TimeEntryReviewError.alreadyPublished
        }
        guard entry.reviewStatus != .approved else { throw TimeEntryReviewError.alreadyApproved }
        guard draft.clockOut > draft.clockIn else { throw TimeEntryReviewError.invalidTimeRange }
        guard draft.clockOut.timeIntervalSince(draft.clockIn) <= maximumShiftDuration else {
            throw TimeEntryReviewError.shiftTooLong
        }
        guard draft.notes.count <= 1_000 else { throw TimeEntryReviewError.notesTooLong }
        try validateWorkContext(activity: draft.activity, serviceCall: serviceCall)

        let overlaps = allEntries.contains { other in
            guard other.id != entry.id,
                  AppAccess.normalizedEmail(other.userEmail) == AppAccess.normalizedEmail(entry.userEmail) else {
                return false
            }
            let otherEnd = other.clockOut ?? .distantFuture
            return draft.clockIn < otherEnd && draft.clockOut > other.clockIn
        }
        guard !overlaps else { throw TimeEntryReviewError.overlappingEntry }

        let oldStart = entry.clockIn
        let oldEnd = entry.clockOut
        entry.clockIn = draft.clockIn
        entry.clockOut = draft.clockOut
        entry.serviceCall = serviceCall
        entry.activity = draft.activity
        let normalizedNotes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.notes = normalizedNotes.isEmpty ? nil : normalizedNotes
        entry.reviewStatus = .submitted
        entry.reviewedByEmail = nil
        entry.reviewedAt = nil
        entry.reviewNote = nil
        entry.quickBooksTimeActivitySyncError = nil
        let oldRange = "\(oldStart.formatted(date: .abbreviated, time: .shortened))–\(oldEnd?.formatted(date: .abbreviated, time: .shortened) ?? "open")"
        let newRange = "\(draft.clockIn.formatted(date: .abbreviated, time: .shortened))–\(draft.clockOut.formatted(date: .abbreviated, time: .shortened))"
        entry.appendReviewEvent(
            .correctedAndResubmitted,
            actorEmail: actor,
            at: date,
            detail: "Time corrected from \(oldRange) to \(newRange). Activity: \(draft.activity.displayName)."
        )
    }

    static func approve(
        _ entry: TimeEntry,
        actorEmail: String?,
        users: [AppUser],
        at date: Date = Date()
    ) throws {
        guard AppAccess.canReviewTeamTime(email: actorEmail, users: users) else {
            throw TimeEntryReviewError.unauthorized
        }
        guard let clockOut = entry.clockOut else { throw TimeEntryReviewError.entryStillOpen }
        guard clockOut > entry.clockIn else { throw TimeEntryReviewError.invalidTimeRange }
        guard clockOut.timeIntervalSince(entry.clockIn) <= maximumShiftDuration else {
            throw TimeEntryReviewError.shiftTooLong
        }
        try validateWorkContext(activity: entry.activity, serviceCall: entry.serviceCall)
        guard entry.reviewStatus != .approved else { throw TimeEntryReviewError.alreadyApproved }
        guard entry.reviewStatus != .correctionRequested else {
            throw TimeEntryReviewError.correctionStillRequired
        }

        let reviewer = AppAccess.normalizedEmail(actorEmail)
        entry.reviewStatus = .approved
        entry.reviewedByEmail = reviewer
        entry.reviewedAt = date
        entry.reviewNote = nil
        entry.quickBooksTimeActivitySyncError = nil
        entry.appendReviewEvent(.approved, actorEmail: reviewer, at: date)
    }

    private static func validateWorkContext(
        activity: TimeEntryActivity,
        serviceCall: ServiceCall?
    ) throws {
        if activity.requiresServiceCall, serviceCall == nil {
            throw TimeEntryReviewError.jobActivityRequiresJob
        }
        if !activity.requiresServiceCall, serviceCall != nil {
            throw TimeEntryReviewError.nonJobActivityHasJob
        }
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
        let completedMinutes = entries
            .filter { $0.activity == .job }
            .compactMap(\.payableDurationMinutes)
            .reduce(0, +)
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
            guard entry.activity == .job,
                  let minutes = entry.payableDurationMinutes,
                  minutes > 0 else { continue }
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
