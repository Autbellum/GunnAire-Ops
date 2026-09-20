import Foundation
import Testing
@testable import GunnAire_Ops

/// Team Review lists "This Week" by `weekOfYear` of the device calendar and
/// the shared-time UI fixture clocks its entry in four hours before an anchor.
/// These pin that the anchor keeps the entry inside the current week at any
/// hour, so the UI tests do not fail in the first hours of a week (CI runs in
/// UTC and did exactly that on Sunday 2026-09-20 between 00:00 and 04:00).
struct SharedTimeUIFixtureTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        calendar.locale = Locale(identifier: "en_US")
        calendar.firstWeekday = 1
        return calendar
    }

    private func date(_ iso: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        return try #require(formatter.date(from: iso))
    }

    @Test func anchorIsNowOnceTheWeekIsFourHoursOld() throws {
        let saturdayEvening = try date("2026-09-19T21:40:00Z")
        #expect(SharedTimeUIFixture.reviewAnchor(now: saturdayEvening, calendar: calendar) == saturdayEvening)
        let sundayNoon = try date("2026-09-20T12:00:00Z")
        #expect(SharedTimeUIFixture.reviewAnchor(now: sundayNoon, calendar: calendar) == sundayNoon)
        let exactlyFourHours = try date("2026-09-20T04:00:00Z")
        #expect(SharedTimeUIFixture.reviewAnchor(now: exactlyFourHours, calendar: calendar) == exactlyFourHours)
    }

    @Test func anchorMovesIntoTheWeekDuringItsFirstFourHours() throws {
        let weekStart = try date("2026-09-20T00:00:00Z")
        for iso in ["2026-09-20T00:00:00Z", "2026-09-20T00:56:00Z", "2026-09-20T01:26:00Z", "2026-09-20T03:59:59Z"] {
            let now = try date(iso)
            let anchor = SharedTimeUIFixture.reviewAnchor(now: now, calendar: calendar)
            #expect(anchor == weekStart.addingTimeInterval(4 * 3600))
            let clockIn = anchor.addingTimeInterval(-4 * 3600)
            #expect(clockIn >= weekStart, "clock-in must stay inside the current week for \(iso)")
            #expect(calendar.dateInterval(of: .weekOfYear, for: clockIn)?.start == weekStart)
        }
    }

    @Test func anchorFollowsTheCalendarsWeekStart() throws {
        var monday = calendar
        monday.firstWeekday = 2 // ISO-style weeks: Monday 2026-09-21 starts the week.
        let mondayEarly = try date("2026-09-21T01:00:00Z")
        let anchor = SharedTimeUIFixture.reviewAnchor(now: mondayEarly, calendar: monday)
        #expect(anchor == (try date("2026-09-21T04:00:00Z")))
        let sundayEarly = try date("2026-09-20T01:00:00Z")
        #expect(SharedTimeUIFixture.reviewAnchor(now: sundayEarly, calendar: monday) == sundayEarly)
    }
}
