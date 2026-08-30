import Foundation
import CryptoKit
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
    case employeeSignedOff = "employee_signed_off"
}

struct TimeEntryReviewEvent: Codable, Equatable, Identifiable {
    let id: UUID
    let action: TimeEntryReviewAction
    let actorEmail: String
    let occurredAt: Date
    let detail: String?
    let periodStart: Date?
    let periodEnd: Date?
    let snapshotDigest: String?

    init(
        id: UUID = UUID(),
        action: TimeEntryReviewAction,
        actorEmail: String,
        occurredAt: Date,
        detail: String? = nil,
        periodStart: Date? = nil,
        periodEnd: Date? = nil,
        snapshotDigest: String? = nil
    ) {
        self.id = id
        self.action = action
        self.actorEmail = actorEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.occurredAt = occurredAt
        let normalizedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedDetail, !normalizedDetail.isEmpty {
            self.detail = String(normalizedDetail.prefix(500))
        } else {
            self.detail = nil
        }
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        let normalizedDigest = snapshotDigest?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.snapshotDigest = normalizedDigest?.isEmpty == false ? normalizedDigest : nil
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

    func appendReviewEvent(_ event: TimeEntryReviewEvent) {
        reviewAuditJSON = TimeEntryReviewAudit.appending(event, to: reviewAuditJSON)
    }

    private static func normalizedReviewNote(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else { return nil }
        return String(normalized.prefix(500))
    }
}

enum TimesheetPayPeriod: String, Codable, CaseIterable, Identifiable, Sendable {
    case currentWeek = "current_week"
    case previousWeek = "previous_week"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .currentWeek: "This Week"
        case .previousWeek: "Last Week"
        }
    }

    func dateInterval(now: Date, calendar: Calendar = .current) -> DateInterval {
        let current = calendar.dateInterval(of: .weekOfYear, for: now)
            ?? DateInterval(start: calendar.startOfDay(for: now), duration: 7 * 24 * 60 * 60)
        switch self {
        case .currentWeek:
            return current
        case .previousWeek:
            let start = calendar.date(byAdding: .weekOfYear, value: -1, to: current.start)
                ?? current.start.addingTimeInterval(-7 * 24 * 60 * 60)
            return DateInterval(start: start, end: current.start)
        }
    }
}

struct TimesheetReadinessSnapshot: Equatable {
    let employeeEmail: String
    let interval: DateInterval
    let entryCount: Int
    let payableMinutes: Int
    let unpaidMinutes: Int
    let openEntryCount: Int
    let correctionRequiredCount: Int
    let invalidContextCount: Int
    let unapprovedEntryCount: Int
    let qboPendingCount: Int
    let qboAttentionCount: Int
    let employeeSignedOffAt: Date?

    var canEmployeeSignOff: Bool {
        entryCount > 0 && openEntryCount == 0 && correctionRequiredCount == 0 && invalidContextCount == 0
    }

    var isApprovedForTimeExport: Bool {
        canEmployeeSignOff && unapprovedEntryCount == 0 && employeeSignedOffAt != nil
    }
}

enum TimesheetAttestationError: LocalizedError, Equatable {
    case unauthorized
    case noEntries
    case invalidPeriodScope
    case openEntries
    case correctionRequired
    case invalidWorkContext

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Only the employee who recorded this time can sign the timesheet snapshot."
        case .noEntries:
            "There are no time entries in this period to sign."
        case .invalidPeriodScope:
            "Review the exact weekly period before signing its time snapshot."
        case .openEntries:
            "Clock out every open entry before signing this period."
        case .correctionRequired:
            "Correct and resubmit every returned entry before signing this period."
        case .invalidWorkContext:
            "Wait for every Job Labor entry to resolve its service job before signing this period."
        }
    }
}

enum TimesheetAttestationPolicy {
    private struct Snapshot: Codable {
        let version: Int
        let employeeEmail: String
        let periodStart: Date
        let periodEnd: Date
        let entries: [SnapshotEntry]
    }

    private struct SnapshotEntry: Codable {
        let id: UUID
        let clockIn: Date
        let clockOut: Date?
        let activity: String
        let serviceCallID: UUID?
        let notes: String?
        /// Employee submission and correction events are part of the signed
        /// record revision. Office approval, QBO publication, and the signature
        /// event itself remain outside the digest so those later handoffs do not
        /// invalidate an otherwise unchanged employee attestation.
        let workflowRevisionEventIDs: [UUID]
    }

    static func entries(
        for employeeEmail: String,
        interval: DateInterval,
        allEntries: [TimeEntry]
    ) -> [TimeEntry] {
        let normalizedEmail = AppAccess.normalizedEmail(employeeEmail)
        return allEntries
            .filter {
                AppAccess.normalizedEmail($0.userEmail) == normalizedEmail &&
                    $0.clockIn >= interval.start &&
                    $0.clockIn < interval.end
            }
            .sorted {
                if $0.clockIn != $1.clockIn { return $0.clockIn < $1.clockIn }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    static func snapshotDigest(
        employeeEmail: String,
        interval: DateInterval,
        entries: [TimeEntry]
    ) -> String {
        let snapshot = Snapshot(
            version: 1,
            employeeEmail: AppAccess.normalizedEmail(employeeEmail),
            periodStart: interval.start,
            periodEnd: interval.end,
            entries: entries
                .sorted { $0.id.uuidString < $1.id.uuidString }
                .map {
                    SnapshotEntry(
                        id: $0.id,
                        clockIn: $0.clockIn,
                        clockOut: $0.clockOut,
                        activity: $0.activity.rawValue,
                        serviceCallID: $0.serviceCall?.id,
                        notes: $0.notes,
                        workflowRevisionEventIDs: $0.reviewEvents.compactMap { event in
                            switch event.action {
                            case .submitted, .correctionRequested, .correctedAndResubmitted:
                                event.id
                            case .approved, .employeeSignedOff:
                                nil
                            }
                        }
                    )
                }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func currentAttestation(
        employeeEmail: String,
        interval: DateInterval,
        entries: [TimeEntry]
    ) -> TimeEntryReviewEvent? {
        guard !entries.isEmpty else { return nil }
        let normalizedEmail = AppAccess.normalizedEmail(employeeEmail)
        let digest = snapshotDigest(employeeEmail: normalizedEmail, interval: interval, entries: entries)
        guard !digest.isEmpty else { return nil }

        let matchingByEntry = entries.map { entry in
            entry.reviewEvents.filter { event in
                event.action == .employeeSignedOff &&
                    event.actorEmail == normalizedEmail &&
                    event.periodStart == interval.start &&
                    event.periodEnd == interval.end &&
                    event.snapshotDigest == digest
            }
        }
        guard var commonIDs = matchingByEntry.first.map({ Set($0.map(\.id)) }), !commonIDs.isEmpty else {
            return nil
        }
        for events in matchingByEntry.dropFirst() {
            commonIDs.formIntersection(events.map(\.id))
            if commonIDs.isEmpty { return nil }
        }
        return matchingByEntry
            .flatMap { $0 }
            .filter { commonIDs.contains($0.id) }
            .max { $0.occurredAt < $1.occurredAt }
    }

    @discardableResult
    static func signOff(
        employeeEmail: String,
        actorEmail: String,
        interval: DateInterval,
        entries: [TimeEntry],
        at date: Date = Date(),
        operationID: UUID = UUID()
    ) throws -> TimeEntryReviewEvent {
        let employee = AppAccess.normalizedEmail(employeeEmail)
        guard !employee.isEmpty, employee == AppAccess.normalizedEmail(actorEmail) else {
            throw TimesheetAttestationError.unauthorized
        }
        guard !entries.isEmpty,
              entries.allSatisfy({ AppAccess.normalizedEmail($0.userEmail) == employee }) else {
            throw TimesheetAttestationError.noEntries
        }
        guard entries.allSatisfy({ $0.clockIn >= interval.start && $0.clockIn < interval.end }) else {
            throw TimesheetAttestationError.invalidPeriodScope
        }
        guard !entries.contains(where: \.isOpen) else { throw TimesheetAttestationError.openEntries }
        guard !entries.contains(where: { $0.reviewStatus == .correctionRequested }) else {
            throw TimesheetAttestationError.correctionRequired
        }
        guard entries.allSatisfy({ entry in
            entry.activity.requiresServiceCall ? entry.serviceCall != nil : entry.serviceCall == nil
        }) else {
            throw TimesheetAttestationError.invalidWorkContext
        }
        if let existing = currentAttestation(
            employeeEmail: employee,
            interval: interval,
            entries: entries
        ) {
            return existing
        }

        let digest = snapshotDigest(employeeEmail: employee, interval: interval, entries: entries)
        guard !digest.isEmpty else { throw TimesheetAttestationError.invalidWorkContext }
        let event = TimeEntryReviewEvent(
            id: operationID,
            action: .employeeSignedOff,
            actorEmail: employee,
            occurredAt: date,
            detail: "Employee confirmed the complete time-entry snapshot for this period.",
            periodStart: interval.start,
            periodEnd: interval.end,
            snapshotDigest: digest
        )
        entries.forEach { $0.appendReviewEvent(event) }
        return event
    }

    static func readiness(
        employeeEmail: String,
        interval: DateInterval,
        entries: [TimeEntry]
    ) -> TimesheetReadinessSnapshot {
        let scopedEntries = Self.entries(
            for: employeeEmail,
            interval: interval,
            allEntries: entries
        )
        let signedOffAt = currentAttestation(
            employeeEmail: employeeEmail,
            interval: interval,
            entries: scopedEntries
        )?.occurredAt
        return TimesheetReadinessSnapshot(
            employeeEmail: AppAccess.normalizedEmail(employeeEmail),
            interval: interval,
            entryCount: scopedEntries.count,
            payableMinutes: scopedEntries.compactMap(\.payableDurationMinutes).reduce(0, +),
            unpaidMinutes: scopedEntries
                .filter { !$0.activity.countsTowardPayableTime }
                .compactMap(\.durationMinutes)
                .reduce(0, +),
            openEntryCount: scopedEntries.filter(\.isOpen).count,
            correctionRequiredCount: scopedEntries.filter { $0.reviewStatus == .correctionRequested }.count,
            invalidContextCount: scopedEntries.filter { entry in
                entry.activity.requiresServiceCall ? entry.serviceCall == nil : entry.serviceCall != nil
            }.count,
            unapprovedEntryCount: scopedEntries.filter { $0.reviewStatus != .approved }.count,
            qboPendingCount: scopedEntries.filter {
                $0.reviewStatus == .approved &&
                    $0.activity.isQuickBooksPublishable &&
                    $0.quickBooksTimeActivityID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            }.count,
            qboAttentionCount: scopedEntries.filter {
                $0.quickBooksTimeActivitySyncError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }.count,
            employeeSignedOffAt: signedOffAt
        )
    }
}

enum ApprovedTimesheetCSVError: LocalizedError, Equatable {
    case noEntries
    case notReady

    var errorDescription: String? {
        switch self {
        case .noEntries:
            "There are no time entries in this weekly period to export."
        case .notReady:
            "Every employee must sign the current snapshot and every entry must receive office approval before export."
        }
    }
}

enum ApprovedTimesheetCSV {
    static func render(
        interval: DateInterval,
        entries: [TimeEntry],
        employeeDisplayNames: [String: String]
    ) throws -> String {
        let scopedEntries = entries
            .filter { $0.clockIn >= interval.start && $0.clockIn < interval.end }
            .sorted {
                let leftEmail = AppAccess.normalizedEmail($0.userEmail)
                let rightEmail = AppAccess.normalizedEmail($1.userEmail)
                if leftEmail != rightEmail { return leftEmail < rightEmail }
                if $0.clockIn != $1.clockIn { return $0.clockIn < $1.clockIn }
                return $0.id.uuidString < $1.id.uuidString
            }
        let employeeEmails = Array(Set(scopedEntries.map { AppAccess.normalizedEmail($0.userEmail) })).sorted()
        guard !employeeEmails.isEmpty else { throw ApprovedTimesheetCSVError.noEntries }
        let readinessByEmail = Dictionary(uniqueKeysWithValues: employeeEmails.map { email in
            (
                email,
                TimesheetAttestationPolicy.readiness(
                    employeeEmail: email,
                    interval: interval,
                    entries: scopedEntries
                )
            )
        })
        guard readinessByEmail.values.allSatisfy(\.isApprovedForTimeExport) else {
            throw ApprovedTimesheetCSVError.notReady
        }
        var rows: [[String]] = [
            ["GunnAire Approved Time Export"],
            ["Period Start", iso8601(interval.start)],
            ["Period End", iso8601(interval.end)],
            ["Generated At", iso8601(Date())],
            ["Scope", "Entries are included by clock-in date; payable time excludes unpaid breaks."],
            ["Boundary", "Approved time evidence only; no wage, overtime, tax, commission, deduction, or net-pay calculation."],
            [],
            ["Employee Summary"],
            ["Employee Name", "Employee Email", "Entries", "Payable Minutes", "Unpaid Minutes", "Employee Signed At", "Export Readiness", "QBO Pending", "QBO Attention"]
        ]
        for email in employeeEmails {
            guard let readiness = readinessByEmail[email] else { continue }
            rows.append([
                employeeDisplayNames[email] ?? AppAccess.inferredDisplayName(fromEmail: email),
                email,
                String(readiness.entryCount),
                String(readiness.payableMinutes),
                String(readiness.unpaidMinutes),
                readiness.employeeSignedOffAt.map { iso8601($0) } ?? "Unsigned",
                readiness.isApprovedForTimeExport ? "Ready" : "Needs review",
                String(readiness.qboPendingCount),
                String(readiness.qboAttentionCount)
            ])
        }
        rows += [
            [],
            ["Approved Time Entries"],
            ["Employee Name", "Employee Email", "Entry ID", "Clock In", "Clock Out", "Activity", "Job ID", "Payable Minutes", "Unpaid Minutes", "Review Status", "Employee Signed At", "Office Reviewed By", "Office Reviewed At", "QBO TimeActivity ID", "QBO State"]
        ]
        for entry in scopedEntries {
            let email = AppAccess.normalizedEmail(entry.userEmail)
            let employeeEntries = TimesheetAttestationPolicy.entries(
                for: email,
                interval: interval,
                allEntries: scopedEntries
            )
            let signedAt = TimesheetAttestationPolicy.currentAttestation(
                employeeEmail: email,
                interval: interval,
                entries: employeeEntries
            )?.occurredAt
            let qboState: String
            if !entry.activity.isQuickBooksPublishable {
                qboState = "Not applicable"
            } else if entry.quickBooksTimeActivityID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                qboState = "Synced"
            } else if entry.quickBooksTimeActivitySyncError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                qboState = "Needs attention"
            } else {
                qboState = "Pending"
            }
            rows.append([
                employeeDisplayNames[email] ?? AppAccess.inferredDisplayName(fromEmail: email),
                email,
                entry.id.uuidString.uppercased(),
                iso8601(entry.clockIn),
                entry.clockOut.map { iso8601($0) } ?? "Open",
                entry.activity.displayName,
                entry.serviceCall?.id.uuidString.uppercased() ?? "",
                String(entry.payableDurationMinutes ?? 0),
                entry.activity.countsTowardPayableTime ? "0" : String(entry.durationMinutes ?? 0),
                entry.reviewStatus.displayName,
                signedAt.map { iso8601($0) } ?? "Unsigned",
                entry.reviewedByEmail ?? "",
                entry.reviewedAt.map { iso8601($0) } ?? "",
                entry.quickBooksTimeActivityID ?? "",
                qboState
            ])
        }
        return rows.map { row in
            row.map { escaped($0) }.joined(separator: ",")
        }.joined(separator: "\n") + "\n"
    }

    private static func iso8601(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    private static func escaped(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
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
