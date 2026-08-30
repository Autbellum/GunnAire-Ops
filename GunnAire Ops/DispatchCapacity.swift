import Foundation

enum DispatchDayCapacityStatus: Equatable, Sendable {
    case unconfigured
    case available
    case tight
    case full
    case overbooked
}

struct DispatchDayCapacitySnapshot: Equatable, Sendable {
    let dayStart: Date
    let dayEnd: Date
    let configuredTechnicianCount: Int
    let unconfiguredTechnicianCount: Int
    let staffedRegularMinutes: Int
    let bookedConfiguredMinutes: Int
    let openRegularMinutes: Int
    let overbookedMinutes: Int
    let onCallCapacityMinutes: Int
    let openOnCallMinutes: Int
    let bookedUnconfiguredMinutes: Int
    let unassignedJobCount: Int
    let unassignedMinutes: Int
    let status: DispatchDayCapacityStatus

    var regularUtilization: Double {
        guard staffedRegularMinutes > 0 else { return 0 }
        let consumed = max(staffedRegularMinutes - openRegularMinutes, 0)
        return min(max(Double(consumed) / Double(staffedRegularMinutes), 0), 1)
    }
}

struct DispatchTechnicianCapacitySnapshot: Equatable, Identifiable, Sendable {
    let technicianID: UUID
    let technicianName: String
    let isConfigured: Bool
    let staffedRegularMinutes: Int
    let bookedMinutes: Int
    let openRegularMinutes: Int
    let overbookedMinutes: Int
    let onCallCapacityMinutes: Int
    let openOnCallMinutes: Int
    let unavailableMinutes: Int
    let assignedBookingCount: Int
    let status: DispatchDayCapacityStatus

    var id: UUID { technicianID }

    var regularUtilization: Double {
        guard staffedRegularMinutes > 0 else { return 0 }
        let consumed = max(staffedRegularMinutes - openRegularMinutes, 0)
        return min(max(Double(consumed) / Double(staffedRegularMinutes), 0), 1)
    }
}

/// A read-only capacity forecast derived from records that already synchronize
/// through SwiftData and CloudKit. It never moves work or invents travel time.
enum DispatchCapacityPolicy {
    static func snapshot(
        for day: Date,
        technicians: [Technician],
        serviceCalls: [ServiceCall],
        availabilityBlocks: [TechnicianAvailabilityBlock],
        workShifts: [TechnicianWorkShift],
        calendar: Calendar = .current
    ) -> DispatchDayCapacitySnapshot {
        let context = dayContext(
            for: day,
            technicians: technicians,
            serviceCalls: serviceCalls,
            workShifts: workShifts,
            calendar: calendar
        )
        let technicianCapacity = makeTechnicianSnapshots(
            technicians: technicians,
            availabilityBlocks: availabilityBlocks,
            workShifts: workShifts,
            context: context
        )
        let configuredCapacity = technicianCapacity.filter(\.isConfigured)
        let staffedRegularMinutes = configuredCapacity.reduce(0) { $0 + $1.staffedRegularMinutes }
        let bookedConfiguredMinutes = configuredCapacity.reduce(0) { $0 + $1.bookedMinutes }
        let openRegularMinutes = configuredCapacity.reduce(0) { $0 + $1.openRegularMinutes }
        let overbookedMinutes = configuredCapacity.reduce(0) { $0 + $1.overbookedMinutes }
        let onCallCapacityMinutes = configuredCapacity.reduce(0) { $0 + $1.onCallCapacityMinutes }
        let openOnCallMinutes = configuredCapacity.reduce(0) { $0 + $1.openOnCallMinutes }

        let bookedUnconfiguredMinutes = context.activeDayCalls.reduce(into: 0) { result, booking in
            let unconfiguredAssignmentCount = booking.call.assignedCrewTechnicianIDs.reduce(into: 0) { count, technicianID in
                if !context.configuredTechnicianIDs.contains(technicianID) {
                    count += 1
                }
            }
            result += minutes(in: [booking.interval]) * unconfiguredAssignmentCount
        }

        let unassignedBookings = context.activeDayCalls.filter { booking in
            booking.call.assignedCrewTechnicianIDs.isEmpty &&
                booking.call.status != .completed &&
                booking.call.status != .invoiced &&
                booking.call.type != .meeting &&
                booking.call.type != .reminder
        }
        let unassignedJobCount = unassignedBookings.count
        let unassignedMinutes = minutes(
            in: unassignedBookings.map(\.interval),
            mergingFirst: false
        )
        let status = capacityStatus(
            configuredTechnicianCount: context.configuredTechnicianIDs.count,
            staffedRegularMinutes: staffedRegularMinutes,
            openRegularMinutes: openRegularMinutes,
            overbookedMinutes: overbookedMinutes,
            bookedUnconfiguredMinutes: bookedUnconfiguredMinutes,
            unassignedMinutes: unassignedMinutes
        )

        return DispatchDayCapacitySnapshot(
            dayStart: context.dayStart,
            dayEnd: context.dayEnd,
            configuredTechnicianCount: context.configuredTechnicianIDs.count,
            unconfiguredTechnicianCount: technicians.count - context.configuredTechnicianIDs.count,
            staffedRegularMinutes: staffedRegularMinutes,
            bookedConfiguredMinutes: bookedConfiguredMinutes,
            openRegularMinutes: openRegularMinutes,
            overbookedMinutes: overbookedMinutes,
            onCallCapacityMinutes: onCallCapacityMinutes,
            openOnCallMinutes: openOnCallMinutes,
            bookedUnconfiguredMinutes: bookedUnconfiguredMinutes,
            unassignedJobCount: unassignedJobCount,
            unassignedMinutes: unassignedMinutes,
            status: status
        )
    }

    static func technicianSnapshots(
        for day: Date,
        technicians: [Technician],
        serviceCalls: [ServiceCall],
        availabilityBlocks: [TechnicianAvailabilityBlock],
        workShifts: [TechnicianWorkShift],
        calendar: Calendar = .current
    ) -> [DispatchTechnicianCapacitySnapshot] {
        let context = dayContext(
            for: day,
            technicians: technicians,
            serviceCalls: serviceCalls,
            workShifts: workShifts,
            calendar: calendar
        )
        return makeTechnicianSnapshots(
            technicians: technicians,
            availabilityBlocks: availabilityBlocks,
            workShifts: workShifts,
            context: context
        )
    }

    private struct DayContext {
        let dayStart: Date
        let dayEnd: Date
        let dayInterval: DateInterval
        let configuredTechnicianIDs: Set<UUID>
        let activeDayCalls: [DayBooking]
    }

    private struct DayBooking {
        let call: ServiceCall
        let interval: DateInterval
    }

    private static func dayContext(
        for day: Date,
        technicians: [Technician],
        serviceCalls: [ServiceCall],
        workShifts: [TechnicianWorkShift],
        calendar: Calendar
    ) -> DayContext {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 60 * 60)
        let dayInterval = DateInterval(start: dayStart, end: dayEnd)
        let configuredTechnicianIDs = Set(technicians.compactMap { technician in
            TechnicianWorkShiftPolicy.hasConfiguredSchedule(
                technicianID: technician.id,
                shifts: workShifts
            ) ? technician.id : nil
        })
        let activeDayCalls = serviceCalls.compactMap { call -> DayBooking? in
            guard call.status != .cancelled,
                  let interval = clippedCallInterval(call, to: dayInterval) else { return nil }
            return DayBooking(call: call, interval: interval)
        }
        return DayContext(
            dayStart: dayStart,
            dayEnd: dayEnd,
            dayInterval: dayInterval,
            configuredTechnicianIDs: configuredTechnicianIDs,
            activeDayCalls: activeDayCalls
        )
    }

    private static func makeTechnicianSnapshots(
        technicians: [Technician],
        availabilityBlocks: [TechnicianAvailabilityBlock],
        workShifts: [TechnicianWorkShift],
        context: DayContext
    ) -> [DispatchTechnicianCapacitySnapshot] {
        technicians.map { technician in
            technicianSnapshot(
                technician: technician,
                isConfigured: context.configuredTechnicianIDs.contains(technician.id),
                availabilityBlocks: availabilityBlocks,
                workShifts: workShifts,
                context: context
            )
        }
    }

    private static func technicianSnapshot(
        technician: Technician,
        isConfigured: Bool,
        availabilityBlocks: [TechnicianAvailabilityBlock],
        workShifts: [TechnicianWorkShift],
        context: DayContext
    ) -> DispatchTechnicianCapacitySnapshot {
        let technicianBookings = context.activeDayCalls.filter {
            $0.call.assignedCrewTechnicianIDs.contains(technician.id)
        }
        let allBookingIntervals = technicianBookings.map(\.interval)
        let totalBooked = minutes(in: allBookingIntervals, mergingFirst: false)

        guard isConfigured else {
            return DispatchTechnicianCapacitySnapshot(
                technicianID: technician.id,
                technicianName: technician.name,
                isConfigured: false,
                staffedRegularMinutes: 0,
                bookedMinutes: totalBooked,
                openRegularMinutes: 0,
                overbookedMinutes: totalBooked,
                onCallCapacityMinutes: 0,
                openOnCallMinutes: 0,
                unavailableMinutes: 0,
                assignedBookingCount: technicianBookings.count,
                status: .unconfigured
            )
        }

        let shiftIntervals = TechnicianWorkShiftPolicy.intervals(
            technicianID: technician.id,
            from: context.dayStart,
            through: context.dayEnd,
            shifts: workShifts,
            includeOnCall: true
        )
        let regularPlan = merged(shiftIntervals.compactMap { interval in
            guard interval.kind == .regular else { return nil }
            return clipped(DateInterval(start: interval.start, end: interval.end), to: context.dayInterval)
        })
        let onCallPlan = merged(shiftIntervals.compactMap { interval in
            guard interval.kind == .onCall else { return nil }
            return clipped(DateInterval(start: interval.start, end: interval.end), to: context.dayInterval)
        })
        let unavailable = merged(availabilityBlocks.compactMap { block in
            guard block.technicianID == technician.id, block.isActive else { return nil }
            return clipped(DateInterval(start: block.startsAt, end: block.endsAt), to: context.dayInterval)
        })

        let regularAvailable = subtracting(unavailable, from: regularPlan)
        // On-call that overlaps the regular plan is not additional capacity.
        let distinctOnCallPlan = subtracting(regularPlan, from: onCallPlan)
        let onCallAvailable = subtracting(unavailable, from: distinctOnCallPlan)
        let onCallEligibleIntervals = technicianBookings.compactMap { booking in
            switch booking.call.dispatchUrgency {
            case .priority, .emergency:
                booking.interval
            case .normal:
                nil
            }
        }
        let regularConsumed = intersections(allBookingIntervals, regularAvailable)
        let onCallConsumed = intersections(onCallEligibleIntervals, onCallAvailable)
        // Every booking makes the technician unavailable, even when a
        // normal-priority booking is outside the on-call policy. Keep that
        // work in `overbookedMinutes`, while still reducing the reserve a
        // dispatcher can actually use for another urgent call.
        let onCallOccupied = intersections(allBookingIntervals, onCallAvailable)
        let regularCapacity = minutes(in: regularAvailable)
        let onCallCapacity = minutes(in: onCallAvailable)
        let openRegular = max(regularCapacity - minutes(in: regularConsumed), 0)
        let eligibleConsumed = minutes(in: regularConsumed) + minutes(in: onCallConsumed)
        let overbooked = max(totalBooked - eligibleConsumed, 0)
        let plannedMinutes = minutes(in: regularPlan) + minutes(in: distinctOnCallPlan)
        let unavailableMinutes = max(plannedMinutes - regularCapacity - onCallCapacity, 0)

        return DispatchTechnicianCapacitySnapshot(
            technicianID: technician.id,
            technicianName: technician.name,
            isConfigured: true,
            staffedRegularMinutes: regularCapacity,
            bookedMinutes: totalBooked,
            openRegularMinutes: openRegular,
            overbookedMinutes: overbooked,
            onCallCapacityMinutes: onCallCapacity,
            openOnCallMinutes: max(onCallCapacity - minutes(in: onCallOccupied), 0),
            unavailableMinutes: unavailableMinutes,
            assignedBookingCount: technicianBookings.count,
            status: technicianCapacityStatus(
                staffedRegularMinutes: regularCapacity,
                openRegularMinutes: openRegular,
                overbookedMinutes: overbooked
            )
        )
    }

    private static func capacityStatus(
        configuredTechnicianCount: Int,
        staffedRegularMinutes: Int,
        openRegularMinutes: Int,
        overbookedMinutes: Int,
        bookedUnconfiguredMinutes: Int,
        unassignedMinutes: Int
    ) -> DispatchDayCapacityStatus {
        guard configuredTechnicianCount > 0 else { return .unconfigured }
        if overbookedMinutes > 0 { return .overbooked }
        if staffedRegularMinutes == 0 || openRegularMinutes == 0 { return .full }
        if bookedUnconfiguredMinutes > 0 || unassignedMinutes > openRegularMinutes {
            return .tight
        }
        if openRegularMinutes * 5 <= staffedRegularMinutes {
            return .tight
        }
        return .available
    }

    private static func technicianCapacityStatus(
        staffedRegularMinutes: Int,
        openRegularMinutes: Int,
        overbookedMinutes: Int
    ) -> DispatchDayCapacityStatus {
        if overbookedMinutes > 0 { return .overbooked }
        if staffedRegularMinutes == 0 || openRegularMinutes == 0 { return .full }
        if openRegularMinutes * 5 <= staffedRegularMinutes { return .tight }
        return .available
    }

    private static func clippedCallInterval(
        _ call: ServiceCall,
        to dayInterval: DateInterval
    ) -> DateInterval? {
        let end = call.scheduledDate.addingTimeInterval(max(call.duration, 60))
        return clipped(DateInterval(start: call.scheduledDate, end: end), to: dayInterval)
    }

    private static func clipped(_ interval: DateInterval, to bounds: DateInterval) -> DateInterval? {
        let start = max(interval.start, bounds.start)
        let end = min(interval.end, bounds.end)
        guard start < end else { return nil }
        return DateInterval(start: start, end: end)
    }

    private static func merged(_ intervals: [DateInterval]) -> [DateInterval] {
        let ordered = intervals
            .filter { $0.start < $0.end }
            .sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.end < $1.end
            }
        guard var current = ordered.first else { return [] }
        var result: [DateInterval] = []
        for interval in ordered.dropFirst() {
            if interval.start <= current.end {
                current = DateInterval(start: current.start, end: max(current.end, interval.end))
            } else {
                result.append(current)
                current = interval
            }
        }
        result.append(current)
        return result
    }

    private static func subtracting(
        _ exclusions: [DateInterval],
        from intervals: [DateInterval]
    ) -> [DateInterval] {
        let exclusions = merged(exclusions)
        return merged(intervals).flatMap { interval -> [DateInterval] in
            var cursor = interval.start
            var pieces: [DateInterval] = []
            for exclusion in exclusions where exclusion.end > cursor && exclusion.start < interval.end {
                if exclusion.start > cursor {
                    pieces.append(DateInterval(start: cursor, end: min(exclusion.start, interval.end)))
                }
                cursor = max(cursor, exclusion.end)
                if cursor >= interval.end { break }
            }
            if cursor < interval.end {
                pieces.append(DateInterval(start: cursor, end: interval.end))
            }
            return pieces
        }
    }

    private static func intersections(
        _ lhs: [DateInterval],
        _ rhs: [DateInterval]
    ) -> [DateInterval] {
        merged(lhs.flatMap { left in
            rhs.compactMap { right in clipped(left, to: right) }
        })
    }

    private static func minutes(
        in intervals: [DateInterval],
        mergingFirst: Bool = true
    ) -> Int {
        let intervals = mergingFirst ? merged(intervals) : intervals
        let seconds = intervals.reduce(0.0) { $0 + max($1.duration, 0) }
        return Int((seconds / 60).rounded())
    }
}
