import Testing
import Foundation
@testable import GunnAire_Ops

@MainActor
struct ServerClockSyncTests {
    @Test func offsetAboveThresholdFlagsEntryForReview() throws {
        ServerClockSync.shared.resetForTesting()
        let deviceNow = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let serverDate = deviceNow.addingTimeInterval(-300) // device 300s ahead
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://example.com")!, statusCode: 200, httpVersion: nil,
            headerFields: ["Date": Self.rfc1123(serverDate)]))
        ServerClockSync.shared.record(from: response, deviceNow: deviceNow)
        let offset = try #require(ServerClockSync.shared.lastKnownOffsetSeconds)
        #expect(abs(offset - 300) < 1)
        #expect(abs(offset) > TimeEntryReviewPolicy.clockDriftFlagThresholdSeconds)
        ServerClockSync.shared.resetForTesting()
    }

    @Test func offsetBelowThresholdDoesNotFlag() throws {
        ServerClockSync.shared.resetForTesting()
        let deviceNow = Date(timeIntervalSinceReferenceDate: 2_000_000)
        let serverDate = deviceNow.addingTimeInterval(-5)
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://example.com")!, statusCode: 200, httpVersion: nil,
            headerFields: ["Date": Self.rfc1123(serverDate)]))
        ServerClockSync.shared.record(from: response, deviceNow: deviceNow)
        let offset = try #require(ServerClockSync.shared.lastKnownOffsetSeconds)
        #expect(abs(offset) < TimeEntryReviewPolicy.clockDriftFlagThresholdSeconds)
        ServerClockSync.shared.resetForTesting()
    }

    @Test func missingDateHeaderLeavesOffsetUnset() throws {
        ServerClockSync.shared.resetForTesting()
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://example.com")!, statusCode: 200, httpVersion: nil, headerFields: [:]))
        ServerClockSync.shared.record(from: response)
        #expect(ServerClockSync.shared.lastKnownOffsetSeconds == nil)
    }

    static func rfc1123(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.string(from: date)
    }
}

@MainActor
struct TimeEntryClockDriftFlagTests {
    @Test func submitAfterClockOutFlagsEntryWhenDriftExceedsThreshold() throws {
        ServerClockSync.shared.resetForTesting()
        let now = Date(timeIntervalSinceReferenceDate: 3_000_000)
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://example.com")!, statusCode: 200, httpVersion: nil,
            headerFields: ["Date": ServerClockSyncTests.rfc1123(now.addingTimeInterval(-600))]))
        ServerClockSync.shared.record(from: response, deviceNow: now)

        let entry = TimeEntry(id: UUID(), userEmail: "field.technician@gunnaire.com")
        entry.clockIn = now.addingTimeInterval(-3600)
        entry.clockOut = now
        try TimeEntryReviewPolicy.submitAfterClockOut(entry, actorEmail: "field.technician@gunnaire.com", at: now)

        #expect(entry.clockDriftFlaggedForReview)
        #expect(abs((entry.deviceClockDriftSeconds ?? 0) - 600) < 1)
        ServerClockSync.shared.resetForTesting()
    }

    @Test func submitAfterClockOutDoesNotFlagWithoutKnownDrift() throws {
        ServerClockSync.shared.resetForTesting()
        let now = Date(timeIntervalSinceReferenceDate: 4_000_000)
        let entry = TimeEntry(id: UUID(), userEmail: "field.technician@gunnaire.com")
        entry.clockIn = now.addingTimeInterval(-3600)
        entry.clockOut = now
        try TimeEntryReviewPolicy.submitAfterClockOut(entry, actorEmail: "field.technician@gunnaire.com", at: now)

        #expect(entry.clockDriftFlaggedForReview == false)
        #expect(entry.deviceClockDriftSeconds == nil)
    }
}

struct QuickBooksRefreshTokenHealthTests {
    @Test func staleAfterThresholdWithNoWarningBeforeIt() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let recordedAt = Date(timeIntervalSinceReferenceDate: 0)
        QuickBooksRefreshTokenHealth.recordSuccess(at: recordedAt, defaults: defaults)

        let justBeforeThreshold = recordedAt.addingTimeInterval(QuickBooksRefreshTokenHealth.staleWarningThreshold - 1)
        #expect(QuickBooksRefreshTokenHealth.isStale(now: justBeforeThreshold, defaults: defaults) == false)

        let justAfterThreshold = recordedAt.addingTimeInterval(QuickBooksRefreshTokenHealth.staleWarningThreshold + 1)
        #expect(QuickBooksRefreshTokenHealth.isStale(now: justAfterThreshold, defaults: defaults))
    }

    @Test func neverRefreshedIsNotReportedStale() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        #expect(QuickBooksRefreshTokenHealth.lastSuccessfulRefresh(defaults: defaults) == nil)
        #expect(QuickBooksRefreshTokenHealth.isStale(defaults: defaults) == false)
    }

    @Test func clearRemovesRecordedSuccess() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        QuickBooksRefreshTokenHealth.recordSuccess(defaults: defaults)
        QuickBooksRefreshTokenHealth.clear(defaults: defaults)
        #expect(QuickBooksRefreshTokenHealth.lastSuccessfulRefresh(defaults: defaults) == nil)
    }
}

struct DocumentationCriticalAttachmentKindTests {
    @Test func onlyDataPlateAndWarrantyEvidenceAreDocumentationCritical() {
        let critical: Set<ServiceDocumentAttachmentKind> = [.equipmentDataPlatePhoto, .warrantyEvidence]
        for kind in ServiceDocumentAttachmentKind.allCases {
            #expect(kind.isDocumentationCritical == critical.contains(kind))
        }
    }
}
