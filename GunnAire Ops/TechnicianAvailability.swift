import Foundation
import SwiftData

enum TechnicianWeekday: Int, Codable, CaseIterable, Identifiable, Sendable {
    case sunday = 1
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday

    var id: Int { rawValue }

    static let ordered: [TechnicianWeekday] = [
        .monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday,
    ]

    var displayName: String {
        switch self {
        case .sunday: "Sunday"
        case .monday: "Monday"
        case .tuesday: "Tuesday"
        case .wednesday: "Wednesday"
        case .thursday: "Thursday"
        case .friday: "Friday"
        case .saturday: "Saturday"
        }
    }

    var shortName: String { String(displayName.prefix(3)) }

    fileprivate var mondayBasedIndex: Int {
        switch self {
        case .monday: 0
        case .tuesday: 1
        case .wednesday: 2
        case .thursday: 3
        case .friday: 4
        case .saturday: 5
        case .sunday: 6
        }
    }
}

enum TechnicianWorkShiftKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case regular
    case onCall = "on_call"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .regular: "Regular"
        case .onCall: "On Call"
        }
    }
}

enum TechnicianWorkShiftCoverage: Equatable, Sendable {
    case unconfigured
    case regular
    case onCall
    case offDuty
}

enum TechnicianWorkShiftValidationError: LocalizedError, Equatable {
    case actorRequired
    case technicianRequired
    case weekdayRequired
    case invalidTime
    case invalidDuration
    case invalidEffectiveRange
    case invalidTimeZone
    case overlappingRule(String)
    case alreadyRetired
    case retirementReasonRequired

    var errorDescription: String? {
        switch self {
        case .actorRequired: "A signed-in Dispatch or Admin account is required."
        case .technicianRequired: "Choose a technician before adding scheduled hours."
        case .weekdayRequired: "Choose at least one weekday."
        case .invalidTime: "Choose a valid start and end time."
        case .invalidDuration: "A recurring shift must be between 1 hour and 24 hours."
        case .invalidEffectiveRange: "The schedule end date cannot precede its start date."
        case .invalidTimeZone: "The company time zone could not be verified."
        case .overlappingRule(let day):
            "This \(day) shift overlaps another active shift of the same type. Retire the older rule or choose different hours."
        case .alreadyRetired: "This recurring shift is already retired."
        case .retirementReasonRequired: "Add a reason before retiring scheduled hours."
        }
    }
}

/// One immutable weekly recurrence rule. Changing expected hours retires the
/// old rule and creates a new one, preserving who changed capacity and when.
@Model
final class TechnicianWorkShift {
    var id: UUID = UUID()
    var creationOperationID: UUID = UUID()
    var technicianID: UUID = UUID()
    var technicianNameSnapshot: String = ""
    /// Foundation Calendar weekday: Sunday = 1 through Saturday = 7.
    var weekdayRawValue: Int = TechnicianWeekday.monday.rawValue
    var startMinute: Int = 8 * 60
    var durationMinutes: Int = 9 * 60
    var kindRawValue: String = TechnicianWorkShiftKind.regular.rawValue
    var effectiveFrom: Date = Date()
    var effectiveUntil: Date?
    var timeZoneIdentifier: String = TimeZone.current.identifier
    var note: String?
    var createdAt: Date = Date()
    var createdByEmail: String = ""
    var retiredAt: Date?
    var retiredByEmail: String?
    var retirementReason: String?
    var retirementOperationID: UUID?

    init(
        id: UUID = UUID(),
        creationOperationID: UUID = UUID(),
        technicianID: UUID,
        technicianNameSnapshot: String,
        weekday: TechnicianWeekday,
        startMinute: Int,
        durationMinutes: Int,
        kind: TechnicianWorkShiftKind,
        effectiveFrom: Date,
        effectiveUntil: Date? = nil,
        timeZoneIdentifier: String,
        note: String? = nil,
        createdAt: Date = Date(),
        createdByEmail: String
    ) {
        self.id = id
        self.creationOperationID = creationOperationID
        self.technicianID = technicianID
        self.technicianNameSnapshot = TechnicianTimeOffPolicy.boundedText(
            technicianNameSnapshot,
            limit: TechnicianTimeOffPolicy.snapshotLimit
        )
        self.weekdayRawValue = weekday.rawValue
        self.startMinute = startMinute
        self.durationMinutes = durationMinutes
        self.kindRawValue = kind.rawValue
        self.effectiveFrom = effectiveFrom
        self.effectiveUntil = effectiveUntil
        self.timeZoneIdentifier = timeZoneIdentifier
        self.note = TechnicianTimeOffPolicy.optionalText(note, limit: TechnicianTimeOffPolicy.noteLimit)
        self.createdAt = createdAt
        self.createdByEmail = AppAccess.normalizedEmail(createdByEmail)
    }

    var weekday: TechnicianWeekday {
        TechnicianWeekday(rawValue: weekdayRawValue) ?? .monday
    }

    var kind: TechnicianWorkShiftKind {
        TechnicianWorkShiftKind(rawValue: kindRawValue) ?? .regular
    }

    var isActive: Bool { retiredAt == nil }

    var endsNextDay: Bool { startMinute + durationMinutes > 24 * 60 }

    var publicScheduleSummary: String {
        "\(weekday.shortName) \(timeLabel(for: startMinute))–\(timeLabel(for: (startMinute + durationMinutes) % (24 * 60)))\(endsNextDay ? " +1" : "")"
    }

    var effectiveDateSummary: String {
        let start = effectiveFrom.formatted(date: .abbreviated, time: .omitted)
        if let effectiveUntil {
            return "\(start)–\(effectiveUntil.formatted(date: .abbreviated, time: .omitted))"
        }
        return "From \(start)"
    }

    private func timeLabel(for minute: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        let base = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1)) ?? Date(timeIntervalSinceReferenceDate: 0)
        let date = calendar.date(byAdding: .minute, value: minute, to: base) ?? base
        return date.formatted(date: .omitted, time: .shortened)
    }
}

struct TechnicianWorkShiftInterval: Equatable, Sendable {
    let ruleID: UUID
    let kind: TechnicianWorkShiftKind
    let start: Date
    let end: Date
}

enum TechnicianWorkShiftPolicy {
    static let minimumDurationMinutes = 60
    static let maximumDurationMinutes = 24 * 60
    static let recommendationHorizonDays = 42

    static func makeShifts(
        technicianID: UUID,
        technicianName: String,
        weekdays: Set<TechnicianWeekday>,
        startMinute: Int,
        durationMinutes: Int,
        kind: TechnicianWorkShiftKind,
        effectiveFrom: Date,
        effectiveUntil: Date?,
        timeZoneIdentifier: String,
        note: String?,
        actorEmail: String,
        existingShifts: [TechnicianWorkShift],
        now: Date = Date(),
        operationIDProvider: () -> UUID = UUID.init
    ) throws -> [TechnicianWorkShift] {
        let actor = AppAccess.normalizedEmail(actorEmail)
        guard !actor.isEmpty else { throw TechnicianWorkShiftValidationError.actorRequired }
        let name = TechnicianTimeOffPolicy.boundedText(technicianName, limit: TechnicianTimeOffPolicy.snapshotLimit)
        guard !name.isEmpty else { throw TechnicianWorkShiftValidationError.technicianRequired }
        guard !weekdays.isEmpty else { throw TechnicianWorkShiftValidationError.weekdayRequired }
        guard (0..<(24 * 60)).contains(startMinute) else {
            throw TechnicianWorkShiftValidationError.invalidTime
        }
        guard (minimumDurationMinutes...maximumDurationMinutes).contains(durationMinutes) else {
            throw TechnicianWorkShiftValidationError.invalidDuration
        }
        guard effectiveUntil == nil || effectiveUntil! >= effectiveFrom else {
            throw TechnicianWorkShiftValidationError.invalidEffectiveRange
        }
        guard TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw TechnicianWorkShiftValidationError.invalidTimeZone
        }

        let candidates = weekdays
            .sorted { $0.mondayBasedIndex < $1.mondayBasedIndex }
            .map { weekday in
                TechnicianWorkShift(
                    creationOperationID: operationIDProvider(),
                    technicianID: technicianID,
                    technicianNameSnapshot: name,
                    weekday: weekday,
                    startMinute: startMinute,
                    durationMinutes: durationMinutes,
                    kind: kind,
                    effectiveFrom: effectiveFrom,
                    effectiveUntil: effectiveUntil,
                    timeZoneIdentifier: timeZoneIdentifier,
                    note: note,
                    createdAt: now,
                    createdByEmail: actor
                )
            }

        for candidate in candidates {
            if existingShifts.contains(where: { rulesOverlap($0, candidate) }) {
                throw TechnicianWorkShiftValidationError.overlappingRule(candidate.weekday.displayName)
            }
        }
        return candidates
    }

    static func retire(
        _ shift: TechnicianWorkShift,
        actorEmail: String,
        reason: String,
        now: Date = Date(),
        operationID: UUID = UUID()
    ) throws {
        guard shift.isActive else { throw TechnicianWorkShiftValidationError.alreadyRetired }
        let actor = AppAccess.normalizedEmail(actorEmail)
        guard !actor.isEmpty else { throw TechnicianWorkShiftValidationError.actorRequired }
        guard let reason = TechnicianTimeOffPolicy.optionalText(reason, limit: TechnicianTimeOffPolicy.noteLimit) else {
            throw TechnicianWorkShiftValidationError.retirementReasonRequired
        }
        shift.retiredAt = now
        shift.retiredByEmail = actor
        shift.retirementReason = reason
        shift.retirementOperationID = operationID
    }

    static func ordered(_ shifts: [TechnicianWorkShift]) -> [TechnicianWorkShift] {
        shifts.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            if lhs.weekday.mondayBasedIndex != rhs.weekday.mondayBasedIndex {
                return lhs.weekday.mondayBasedIndex < rhs.weekday.mondayBasedIndex
            }
            if lhs.startMinute != rhs.startMinute { return lhs.startMinute < rhs.startMinute }
            if lhs.kind != rhs.kind { return lhs.kind == .regular }
            return lhs.createdAt > rhs.createdAt
        }
    }

    static func hasConfiguredSchedule(
        technicianID: UUID,
        shifts: [TechnicianWorkShift]
    ) -> Bool {
        // Once a technician has schedule history, retiring every active rule
        // means off duty until new hours are added; it must not silently restore
        // the legacy around-the-clock fallback.
        shifts.contains { $0.technicianID == technicianID }
    }

    static func coverage(
        technicianID: UUID,
        start: Date,
        end: Date,
        shifts: [TechnicianWorkShift],
        allowOnCall: Bool
    ) -> TechnicianWorkShiftCoverage {
        guard hasConfiguredSchedule(technicianID: technicianID, shifts: shifts) else {
            return .unconfigured
        }
        let intervals = intervals(
            technicianID: technicianID,
            from: start,
            through: end,
            shifts: shifts,
            includeOnCall: true
        )
        if intervals.contains(where: { $0.kind == .regular && start >= $0.start && end <= $0.end }) {
            return .regular
        }
        if intervals.contains(where: { $0.kind == .onCall && start >= $0.start && end <= $0.end }) {
            return allowOnCall ? .onCall : .offDuty
        }
        return .offDuty
    }

    static func intervals(
        technicianID: UUID,
        from start: Date,
        through end: Date,
        shifts: [TechnicianWorkShift],
        includeOnCall: Bool
    ) -> [TechnicianWorkShiftInterval] {
        shifts
            .filter {
                $0.technicianID == technicianID &&
                    $0.isActive &&
                    (includeOnCall || $0.kind == .regular)
            }
            .flatMap { shift -> [TechnicianWorkShiftInterval] in
                guard let timeZone = TimeZone(identifier: shift.timeZoneIdentifier) else { return [] }
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = timeZone
                let startDay = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: start)) ?? start
                let endDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end
                var day = startDay
                var result: [TechnicianWorkShiftInterval] = []
                while day <= endDay {
                    if calendar.component(.weekday, from: day) == shift.weekdayRawValue,
                       isEffective(shift, on: day, calendar: calendar),
                       let intervalStart = calendar.date(byAdding: .minute, value: shift.startMinute, to: day),
                       let intervalEnd = calendar.date(byAdding: .minute, value: shift.durationMinutes, to: intervalStart),
                       intervalEnd > start,
                       intervalStart < end {
                        result.append(TechnicianWorkShiftInterval(
                            ruleID: shift.id,
                            kind: shift.kind,
                            start: intervalStart,
                            end: intervalEnd
                        ))
                    }
                    guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day), nextDay > day else { break }
                    day = nextDay
                }
                return result
            }
            .sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.kind != $1.kind { return $0.kind == .regular }
                return $0.end < $1.end
            }
    }

    private static func isEffective(
        _ shift: TechnicianWorkShift,
        on localDay: Date,
        calendar: Calendar
    ) -> Bool {
        let day = calendar.startOfDay(for: localDay)
        let firstDay = calendar.startOfDay(for: shift.effectiveFrom)
        guard day >= firstDay else { return false }
        guard let effectiveUntil = shift.effectiveUntil else { return true }
        return day <= calendar.startOfDay(for: effectiveUntil)
    }

    private static func rulesOverlap(
        _ existing: TechnicianWorkShift,
        _ candidate: TechnicianWorkShift
    ) -> Bool {
        guard existing.isActive,
              existing.technicianID == candidate.technicianID,
              existing.kind == candidate.kind,
              effectiveRangesOverlap(existing, candidate) else { return false }

        let existingSegments = weeklySegments(for: existing)
        let candidateSegments = weeklySegments(for: candidate)
        return existingSegments.contains { lhs in
            candidateSegments.contains { rhs in lhs.0 < rhs.1 && lhs.1 > rhs.0 }
        }
    }

    private static func effectiveRangesOverlap(
        _ lhs: TechnicianWorkShift,
        _ rhs: TechnicianWorkShift
    ) -> Bool {
        let lhsEnd = lhs.effectiveUntil ?? .distantFuture
        let rhsEnd = rhs.effectiveUntil ?? .distantFuture
        return lhs.effectiveFrom <= rhsEnd && rhs.effectiveFrom <= lhsEnd
    }

    private static func weeklySegments(for shift: TechnicianWorkShift) -> [(Int, Int)] {
        let weekMinutes = 7 * 24 * 60
        let start = shift.weekday.mondayBasedIndex * 24 * 60 + shift.startMinute
        let end = start + shift.durationMinutes
        if end <= weekMinutes { return [(start, end)] }
        return [(start, weekMinutes), (0, end - weekMinutes)]
    }
}

enum TechnicianAvailabilityKind: String, Codable, CaseIterable, Identifiable {
    case timeOff = "time_off"
    case breakPeriod = "break"
    case training
    case unavailable

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .timeOff: "Time off"
        case .breakPeriod: "Break"
        case .training: "Training"
        case .unavailable: "Unavailable"
        }
    }
}

/// A dispatcher-managed period when a technician must not be auto-scheduled.
/// This is intentionally separate from a service call so leave, training, and
/// breaks stay visible without becoming billable customer work.
@Model
final class TechnicianAvailabilityBlock {
    var id: UUID = UUID()
    var creationOperationID: UUID = UUID()
    var technicianID: UUID = UUID()
    var startsAt: Date = Date()
    var endsAt: Date = Date()
    var kindRawValue: String = TechnicianAvailabilityKind.unavailable.rawValue
    var reason: String?
    var createdAt: Date = Date()
    var createdByEmail: String = ""
    var sourceTimeOffRequestID: UUID?
    var cancelledAt: Date?
    var cancelledByEmail: String?
    var cancellationReason: String?
    var cancellationOperationID: UUID?

    init(
        id: UUID = UUID(),
        creationOperationID: UUID = UUID(),
        technicianID: UUID,
        startsAt: Date,
        endsAt: Date,
        kind: TechnicianAvailabilityKind = .unavailable,
        reason: String? = nil,
        createdAt: Date = Date(),
        createdByEmail: String = "",
        sourceTimeOffRequestID: UUID? = nil
    ) {
        self.id = id
        self.creationOperationID = creationOperationID
        self.technicianID = technicianID
        self.startsAt = startsAt
        self.endsAt = max(endsAt, startsAt.addingTimeInterval(60))
        self.kindRawValue = kind.rawValue
        self.reason = TechnicianTimeOffPolicy.optionalText(reason, limit: TechnicianTimeOffPolicy.noteLimit)
        self.createdAt = createdAt
        self.createdByEmail = AppAccess.normalizedEmail(createdByEmail)
        self.sourceTimeOffRequestID = sourceTimeOffRequestID
    }

    var kind: TechnicianAvailabilityKind {
        get { TechnicianAvailabilityKind(rawValue: kindRawValue) ?? .unavailable }
        set { kindRawValue = newValue.rawValue }
    }

    var dispatchLabel: String {
        let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        return [kind.displayName, reason].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ": ")
    }

    var isActive: Bool { cancelledAt == nil }

    func overlaps(start: Date, end: Date) -> Bool {
        isActive && start < endsAt && end > startsAt
    }
}

enum TechnicianDispatchAvailability {
    static func nextAvailableStart(
        technicianID: UUID,
        proposedStart: Date,
        duration: TimeInterval,
        serviceCalls: [ServiceCall],
        availabilityBlocks: [TechnicianAvailabilityBlock],
        workShifts: [TechnicianWorkShift] = [],
        urgency: ServiceRequestUrgency = .normal
    ) -> Date? {
        let minimumDuration = max(duration, 60)
        let callBusyPeriods = serviceCalls.compactMap { call -> (Date, Date)? in
            guard call.includesAssignedTechnician(technicianID),
                  call.status != .cancelled,
                  call.status != .completed else { return nil }
            return (call.scheduledDate, call.scheduledDate.addingTimeInterval(max(call.duration, 60)))
        }
        let availabilityBusyPeriods = availabilityBlocks
            .filter { $0.technicianID == technicianID && $0.isActive }
            .map { ($0.startsAt, $0.endsAt) }
        let busyPeriods = (callBusyPeriods + availabilityBusyPeriods)
            .sorted { $0.0 < $1.0 }

        guard TechnicianWorkShiftPolicy.hasConfiguredSchedule(
            technicianID: technicianID,
            shifts: workShifts
        ) else {
            var candidateStart = proposedStart
            while true {
                let candidateEnd = candidateStart.addingTimeInterval(minimumDuration)
                guard let conflict = busyPeriods.first(where: { candidateStart < $0.1 && candidateEnd > $0.0 }) else {
                    return candidateStart
                }
                candidateStart = conflict.1
            }
        }

        let allowOnCall = urgency == .priority || urgency == .emergency
        let horizonEnd = Calendar.current.date(
            byAdding: .day,
            value: TechnicianWorkShiftPolicy.recommendationHorizonDays,
            to: proposedStart
        ) ?? proposedStart.addingTimeInterval(TimeInterval(TechnicianWorkShiftPolicy.recommendationHorizonDays * 86_400))
        let eligibleIntervals = TechnicianWorkShiftPolicy.intervals(
            technicianID: technicianID,
            from: proposedStart,
            through: horizonEnd,
            shifts: workShifts,
            includeOnCall: allowOnCall
        )

        var candidate = proposedStart
        for interval in eligibleIntervals where interval.end > candidate {
            candidate = max(candidate, interval.start)
            while candidate.addingTimeInterval(minimumDuration) <= interval.end {
                let candidateEnd = candidate.addingTimeInterval(minimumDuration)
                guard let conflict = busyPeriods.first(where: { candidate < $0.1 && candidateEnd > $0.0 }) else {
                    return candidate
                }
                candidate = max(candidate, conflict.1)
            }
        }
        return nil
    }
}

import SwiftUI

struct TechnicianAvailabilityView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Technician.name, order: .forward) private var technicians: [Technician]
    @Query(sort: \TechnicianAvailabilityBlock.startsAt, order: .forward) private var availabilityBlocks: [TechnicianAvailabilityBlock]
    @Query(sort: \TechnicianWorkShift.createdAt, order: .reverse) private var workShifts: [TechnicianWorkShift]
    @Query(sort: \TechnicianTimeOffRequest.createdAt, order: .reverse) private var timeOffRequests: [TechnicianTimeOffRequest]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]

    @State private var selectedTechnicianID: UUID?
    @State private var showingAddBlock = false
    @State private var showingAddWorkShift = false
    @State private var blockToCancel: TechnicianAvailabilityBlock?
    @State private var workShiftToRetire: TechnicianWorkShift?

    private var selectedTechnician: Technician? {
        technicians.first { $0.id == selectedTechnicianID } ?? technicians.first
    }

    private var visibleBlocks: [TechnicianAvailabilityBlock] {
        guard let technician = selectedTechnician else { return [] }
        return availabilityBlocks.filter { $0.technicianID == technician.id }
    }

    private var activeBlocks: [TechnicianAvailabilityBlock] { visibleBlocks.filter(\.isActive) }
    private var cancelledBlocks: [TechnicianAvailabilityBlock] { visibleBlocks.filter { !$0.isActive } }
    private var visibleWorkShifts: [TechnicianWorkShift] {
        guard let technician = selectedTechnician else { return [] }
        return TechnicianWorkShiftPolicy.ordered(workShifts.filter { $0.technicianID == technician.id })
    }
    private var activeWorkShifts: [TechnicianWorkShift] { visibleWorkShifts.filter(\.isActive) }
    private var retiredWorkShifts: [TechnicianWorkShift] { visibleWorkShifts.filter { !$0.isActive } }
    private var pendingRequestCount: Int { timeOffRequests.filter { $0.status == .pending }.count }

    private var canManageAvailability: Bool {
        AppAccess.canPerformScheduleMutation(
            .manageAvailability,
            email: AppIdentity.currentEmail,
            users: users
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if canManageAvailability {
                    List {
                        Section("Requests") {
                            NavigationLink {
                                TechnicianTimeOffWorkspaceView()
                            } label: {
                                HStack {
                                    Label("Review Time-Off Requests", systemImage: "calendar.badge.clock")
                                    Spacer()
                                    if pendingRequestCount > 0 {
                                        Text("\(pendingRequestCount)")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.orange)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(.orange.opacity(0.12), in: Capsule())
                                    }
                                }
                            }
                            .accessibilityIdentifier("ReviewTimeOffRequests")
                        }

                        Section("Technician") {
                            if technicians.isEmpty {
                                ContentUnavailableView("No technicians", systemImage: "person.badge.plus", description: Text("Add a technician before recording time off, breaks, or training."))
                            } else {
                                Picker("Technician", selection: Binding(
                                    get: { selectedTechnician?.id ?? UUID() },
                                    set: { selectedTechnicianID = $0 }
                                )) {
                                    ForEach(technicians) { technician in
                                        Text(technician.name).tag(technician.id)
                                    }
                                }

                                Button {
                                    selectedTechnicianID = selectedTechnician?.id
                                    showingAddBlock = true
                                } label: {
                                    Label("Add unavailable time", systemImage: "plus.circle")
                                }
                                .disabled(selectedTechnician == nil)
                            }
                        }

                        Section {
                            if activeWorkShifts.isEmpty {
                                Text(
                                    visibleWorkShifts.isEmpty
                                        ? "No recurring hours are configured. Dispatch recommendations use existing jobs and unavailable time until the first shift is added."
                                        : "No active recurring hours. Dispatch treats this technician as off duty until new hours are added."
                                )
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(activeWorkShifts) { shift in
                                    workShiftRow(shift, includesRetirement: false)
                                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                            Button("Retire", role: .destructive) { workShiftToRetire = shift }
                                        }
                                }
                            }

                            Button {
                                selectedTechnicianID = selectedTechnician?.id
                                showingAddWorkShift = true
                            } label: {
                                Label("Add Recurring Shift", systemImage: "calendar.badge.plus")
                            }
                            .disabled(selectedTechnician == nil)
                            .accessibilityIdentifier("AddRecurringTechnicianShift")

                            if !retiredWorkShifts.isEmpty {
                                DisclosureGroup("Retired History") {
                                    ForEach(retiredWorkShifts) { shift in
                                        workShiftRow(shift, includesRetirement: true)
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Text("Recurring Work Schedule")
                                Spacer()
                                Text("\(activeWorkShifts.count) active")
                                    .accessibilityIdentifier("ActiveTechnicianWorkShiftCount")
                            }
                        }

                        Section("Unavailable time") {
                            if activeBlocks.isEmpty {
                                Text("No breaks, time off, training, or unavailable time recorded for this technician.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(activeBlocks) { block in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(block.dispatchLabel)
                                            .font(.headline)
                                        Text("\(block.startsAt.formatted(date: .abbreviated, time: .shortened)) – \(block.endsAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 2)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button("Cancel", role: .destructive) { blockToCancel = block }
                                    }
                                }
                            }
                        }

                        if !cancelledBlocks.isEmpty {
                            Section("Cancelled History") {
                                ForEach(cancelledBlocks) { block in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(block.dispatchLabel).font(.subheadline.weight(.semibold))
                                        Text("\(block.startsAt.formatted(date: .abbreviated, time: .shortened)) – \(block.endsAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if let cancellationReason = block.cancellationReason {
                                            Text("Cancelled: \(cancellationReason)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }

                        Section {
                            Text("Dispatch moves a proposed assignment past recorded unavailable time. It remains a recommendation: a dispatcher can still review and deliberately change the appointment.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "Dispatch Access Required",
                        systemImage: "person.badge.shield.checkmark",
                        description: Text("Only a dispatcher or administrator can change technician availability.")
                    )
                }
            }
            .navigationTitle("Technician Availability")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingAddBlock) {
                if canManageAvailability, let technician = selectedTechnician {
                    AddTechnicianAvailabilityBlockView(technician: technician)
                        .tint(Color.brandGold)
                }
            }
            .sheet(isPresented: $showingAddWorkShift) {
                if canManageAvailability, let technician = selectedTechnician {
                    AddTechnicianWorkShiftView(technician: technician)
                        .tint(Color.brandGold)
                }
            }
            .sheet(item: $blockToCancel) { block in
                CancelTechnicianAvailabilityBlockView(block: block)
                    .tint(Color.brandGold)
            }
            .sheet(item: $workShiftToRetire) { shift in
                RetireTechnicianWorkShiftView(shift: shift)
                    .tint(Color.brandGold)
            }
            .onAppear {
                if selectedTechnicianID == nil {
                    selectedTechnicianID = technicians.first?.id
                }
            }
            .onChange(of: canManageAvailability) { _, isAllowed in
                if !isAllowed {
                    showingAddBlock = false
                    showingAddWorkShift = false
                    blockToCancel = nil
                    workShiftToRetire = nil
                }
            }
        }
    }

    @ViewBuilder
    private func workShiftRow(_ shift: TechnicianWorkShift, includesRetirement: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(shift.publicScheduleSummary)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(shift.kind.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(shift.kind == .onCall ? .orange : .secondary)
            }
            Text(shift.effectiveDateSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let note = shift.note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if includesRetirement, let reason = shift.retirementReason {
                Text("Retired: \(reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("TechnicianWorkShift-\(shift.id.uuidString)")
    }

}

private struct AddTechnicianWorkShiftView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TechnicianWorkShift.createdAt, order: .reverse) private var workShifts: [TechnicianWorkShift]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]

    let technician: Technician
    @State private var selectedWeekdays: Set<TechnicianWeekday>
    @State private var kind: TechnicianWorkShiftKind = .regular
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var effectiveFrom: Date
    @State private var usesEndDate = false
    @State private var effectiveUntil: Date
    @State private var note = ""
    @State private var errorMessage: String?

    init(technician: Technician) {
        self.technician = technician
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        _selectedWeekdays = State(initialValue: Set([.monday, .tuesday, .wednesday, .thursday, .friday]))
        _startTime = State(initialValue: calendar.date(bySettingHour: 8, minute: 0, second: 0, of: today) ?? today)
        _endTime = State(initialValue: calendar.date(bySettingHour: 17, minute: 0, second: 0, of: today) ?? today)
        _effectiveFrom = State(initialValue: today)
        _effectiveUntil = State(initialValue: calendar.date(byAdding: .month, value: 3, to: today) ?? today)
    }

    private var canManageAvailability: Bool {
        AppAccess.canPerformScheduleMutation(
            .manageAvailability,
            email: AppIdentity.currentEmail,
            users: users
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Recurring Shift") {
                    LabeledContent("Technician", value: technician.name)
                    Picker("Type", selection: $kind) {
                        ForEach(TechnicianWorkShiftKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    DatePicker("Starts", selection: $startTime, displayedComponents: .hourAndMinute)
                    DatePicker("Ends", selection: $endTime, displayedComponents: .hourAndMinute)
                    Text("An end time earlier than the start creates an overnight shift. On-call hours are recommended only for Priority or Emergency work.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Repeats") {
                    ForEach(TechnicianWeekday.ordered) { weekday in
                        Toggle(weekday.displayName, isOn: Binding(
                            get: { selectedWeekdays.contains(weekday) },
                            set: { isSelected in
                                if isSelected {
                                    selectedWeekdays.insert(weekday)
                                } else {
                                    selectedWeekdays.remove(weekday)
                                }
                            }
                        ))
                        .accessibilityIdentifier("RecurringShiftDay-\(weekday.rawValue)")
                    }
                }

                Section("Effective Dates") {
                    DatePicker("Starts", selection: $effectiveFrom, displayedComponents: .date)
                    Toggle("Set an end date", isOn: $usesEndDate)
                    if usesEndDate {
                        DatePicker("Ends", selection: $effectiveUntil, in: effectiveFrom..., displayedComponents: .date)
                    }
                    Text("Times use \(TimeZone.current.identifier). Retire a rule when expected hours change; the old record remains in history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Internal Note") {
                    TextField("Optional scheduling context", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .disabled(!canManageAvailability)
            .navigationTitle("Recurring Work Shift")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add Shifts", action: save)
                        .disabled(!canManageAvailability || selectedWeekdays.isEmpty || shiftDurationMinutes == 0)
                        .accessibilityIdentifier("SaveRecurringTechnicianShift")
                }
            }
            .onChange(of: canManageAvailability) { _, allowed in if !allowed { dismiss() } }
            .alert("Recurring Shift Not Saved", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "") }
        }
    }

    private var startMinute: Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: startTime)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private var endMinute: Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: endTime)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private var shiftDurationMinutes: Int {
        guard startMinute != endMinute else { return 0 }
        return endMinute > startMinute
            ? endMinute - startMinute
            : (24 * 60 - startMinute) + endMinute
    }

    private func save() {
        guard canManageAvailability else { return }
        do {
            let shifts = try TechnicianWorkShiftPolicy.makeShifts(
                technicianID: technician.id,
                technicianName: technician.name,
                weekdays: selectedWeekdays,
                startMinute: startMinute,
                durationMinutes: shiftDurationMinutes,
                kind: kind,
                effectiveFrom: Calendar.current.startOfDay(for: effectiveFrom),
                effectiveUntil: usesEndDate ? Calendar.current.startOfDay(for: effectiveUntil) : nil,
                timeZoneIdentifier: TimeZone.current.identifier,
                note: note,
                actorEmail: AppIdentity.currentEmail ?? "",
                existingShifts: workShifts
            )
            shifts.forEach(modelContext.insert)
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }
}

private struct RetireTechnicianWorkShiftView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]

    let shift: TechnicianWorkShift
    @State private var reason = ""
    @State private var errorMessage: String?

    private var canManageAvailability: Bool {
        AppAccess.canPerformScheduleMutation(
            .manageAvailability,
            email: AppIdentity.currentEmail,
            users: users
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Retire Recurring Shift") {
                    LabeledContent("Technician", value: shift.technicianNameSnapshot)
                    LabeledContent("Hours", value: shift.publicScheduleSummary)
                    LabeledContent("Type", value: shift.kind.displayName)
                    TextField("Reason", text: $reason, axis: .vertical)
                        .lineLimit(2...4)
                        .accessibilityIdentifier("RecurringShiftRetirementReason")
                }
                Section {
                    Text("Retirement removes this rule from future capacity recommendations. The original rule, actor, reason, and operation identity remain available for audit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!canManageAvailability)
            .navigationTitle("Retire Work Shift")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Keep") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Retire", role: .destructive, action: retire)
                        .disabled(!canManageAvailability || TechnicianTimeOffPolicy.optionalText(reason, limit: TechnicianTimeOffPolicy.noteLimit) == nil)
                        .accessibilityIdentifier("ConfirmRecurringShiftRetirement")
                }
            }
            .onChange(of: canManageAvailability) { _, allowed in if !allowed { dismiss() } }
            .alert("Recurring Shift Not Retired", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "") }
        }
    }

    private func retire() {
        guard canManageAvailability else { return }
        do {
            try TechnicianWorkShiftPolicy.retire(
                shift,
                actorEmail: AppIdentity.currentEmail ?? "",
                reason: reason
            )
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }
}

private struct AddTechnicianAvailabilityBlockView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]

    let technician: Technician
    @State private var kind: TechnicianAvailabilityKind = .timeOff
    @State private var startsAt = Date()
    @State private var endsAt = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
    @State private var reason = ""
    @State private var errorMessage: String?

    private var canManageAvailability: Bool {
        AppAccess.canPerformScheduleMutation(
            .manageAvailability,
            email: AppIdentity.currentEmail,
            users: users
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Availability") {
                    LabeledContent("Technician", value: technician.name)
                    Picker("Type", selection: $kind) {
                        ForEach(TechnicianAvailabilityKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    DatePicker("Starts", selection: $startsAt)
                    DatePicker("Ends", selection: $endsAt, in: startsAt...)
                    TextField("Reason (optional)", text: $reason, axis: .vertical)
                        .lineLimit(2...3)
                }
            }
            .disabled(!canManageAvailability)
            .navigationTitle("Unavailable Time")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard canManageAvailability else {
                            dismiss()
                            return
                        }
                        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                        let block = TechnicianAvailabilityBlock(
                            technicianID: technician.id,
                            startsAt: startsAt,
                            endsAt: endsAt,
                            kind: kind,
                            reason: trimmedReason.isEmpty ? nil : trimmedReason,
                            createdByEmail: AppIdentity.currentEmail ?? ""
                        )
                        modelContext.insert(block)
                        modelContext.insert(TechnicianTimeOffPolicy.makeDirectBlockEvent(
                            block: block,
                            technicianName: technician.name,
                            actorEmail: AppIdentity.currentEmail ?? ""
                        ))
                        do {
                            try modelContext.save()
                            dismiss()
                        } catch {
                            modelContext.rollback()
                            errorMessage = error.localizedDescription
                        }
                    }
                    .disabled(endsAt <= startsAt || !canManageAvailability)
                }
            }
            .onAppear {
                if !canManageAvailability { dismiss() }
            }
            .onChange(of: canManageAvailability) { _, isAllowed in
                if !isAllowed { dismiss() }
            }
            .alert("Unavailable Time Not Saved", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "") }
        }
    }
}

private struct CancelTechnicianAvailabilityBlockView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TechnicianTimeOffRequest.createdAt, order: .reverse) private var requests: [TechnicianTimeOffRequest]
    @Query(sort: \Technician.name, order: .forward) private var technicians: [Technician]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]

    let block: TechnicianAvailabilityBlock
    @State private var reason = ""
    @State private var errorMessage: String?

    private var currentEmail: String { AppAccess.normalizedEmail(AppIdentity.currentEmail) }
    private var canCancel: Bool { AppAccess.canCancelAvailabilityBlock(email: currentEmail, users: users) }
    private var sourceRequest: TechnicianTimeOffRequest? {
        guard let requestID = block.sourceTimeOffRequestID else { return nil }
        return requests.first { $0.id == requestID }
    }
    private var technicianName: String {
        technicians.first { $0.id == block.technicianID }?.name ?? sourceRequest?.technicianNameSnapshot ?? "Technician"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Cancel Unavailable Time") {
                    LabeledContent("Technician", value: technicianName)
                    LabeledContent("Period", value: "\(block.startsAt.formatted(date: .abbreviated, time: .shortened)) – \(block.endsAt.formatted(date: .abbreviated, time: .shortened))")
                    TextField("Cancellation reason", text: $reason, axis: .vertical)
                        .lineLimit(2...4)
                        .accessibilityIdentifier("AvailabilityCancellationReason")
                }
                Section {
                    Text("Cancellation removes this block from capacity calculations but retains the original record and event history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!canCancel)
            .navigationTitle("Cancel Availability")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Keep") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cancel Block", role: .destructive, action: cancel)
                        .disabled(!canCancel || TechnicianTimeOffPolicy.optionalText(reason, limit: TechnicianTimeOffPolicy.noteLimit) == nil)
                        .accessibilityIdentifier("ConfirmAvailabilityCancellation")
                }
            }
            .alert("Availability Not Cancelled", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "") }
            .onChange(of: canCancel) { _, allowed in if !allowed { dismiss() } }
        }
    }

    private func cancel() {
        guard canCancel else { return }
        do {
            let event = try TechnicianTimeOffPolicy.cancel(
                block: block,
                sourceRequest: sourceRequest,
                technicianName: technicianName,
                actorEmail: currentEmail,
                reason: reason
            )
            modelContext.insert(event)
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }
}
