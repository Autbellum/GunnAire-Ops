import Foundation
import Testing
@testable import GunnAire_Ops

/// The approval stamp gates every role check in the app, so making it cheap to
/// parse must not change which stamps are accepted. A stamp that stops parsing
/// locks the owner out of his own workspace; one that starts parsing when it
/// should not weakens the boundary around financial data.
struct CompanyApprovalDateParserTests {

    private func parse(_ raw: String) -> Date? {
        // Each case is measured from a cold parser so a pass never depends on
        // the answer remembered from the case before it.
        CompanyApprovalDateParser.forgetMemoizedValue()
        return CompanyApprovalDateParser.date(from: raw)
    }

    @Test
    func internetDateTimeStampsAreAccepted() throws {
        let parsed = try #require(parse("2026-09-18T18:55:48Z"))
        #expect(parsed == Date(timeIntervalSince1970: 1_789_757_748))
    }

    /// The server writes fractional seconds; the original parser tried that
    /// form first, and that ordering has to survive.
    @Test
    func fractionalSecondStampsAreAccepted() throws {
        let parsed = try #require(parse("2026-09-18T18:55:48.250Z"))
        #expect(abs(parsed.timeIntervalSince1970 - 1_789_757_748.25) < 0.001)
    }

    @Test
    func offsetStampsAreAccepted() throws {
        let utc = try #require(parse("2026-09-18T18:55:48Z"))
        let offset = try #require(parse("2026-09-18T14:55:48-04:00"))
        #expect(utc == offset)
    }

    @Test
    func stampsThatAreNotDatesAreRejected() {
        for raw in ["", "not a date", "2026-09-18", "18/09/2026", "  ", "2026-13-45T99:99:99Z"] {
            #expect(parse(raw) == nil, "\(raw) should not parse as an approval stamp")
        }
    }

    /// The whole point of the change: the same stamp is parsed thousands of
    /// times inside one redraw, and the remembered answer has to match the one
    /// a cold parser produces.
    @Test
    func repeatedParsingOfOneStampAgreesWithAColdParse() throws {
        let raw = "2026-09-18T18:55:48.250Z"
        let cold = try #require(parse(raw))
        for _ in 0..<50 {
            #expect(CompanyApprovalDateParser.date(from: raw) == cold)
        }
    }

    /// A remembered answer must not leak onto a different stamp, including the
    /// case where a valid stamp is followed by an invalid one.
    @Test
    func aRememberedAnswerIsNotReusedForADifferentStamp() throws {
        CompanyApprovalDateParser.forgetMemoizedValue()
        let first = try #require(CompanyApprovalDateParser.date(from: "2026-09-18T18:55:48Z"))
        let second = try #require(CompanyApprovalDateParser.date(from: "2026-09-19T18:55:48Z"))
        #expect(second != first)
        #expect(CompanyApprovalDateParser.date(from: "not a date") == nil)
        #expect(CompanyApprovalDateParser.date(from: "2026-09-18T18:55:48Z") == first)
    }

    /// Reached through the binding itself, which is how the access check calls
    /// it, so the wiring is covered and not only the parser.
    @Test
    func bindingValidityStillDependsOnTheApprovalStamp() {
        func binding(approvedAt: String) -> CompanyCloudKitBinding {
            CompanyCloudKitBinding(
                companyID: UUID(),
                containerID: GunnAireCloudKit.containerIdentifier,
                environment: "production",
                replicaID: UUID(),
                cloudAccountHash: String(repeating: "a", count: 64),
                approvedAt: approvedAt
            )
        }
        #expect(binding(approvedAt: "2026-09-18T18:55:48.250Z").isValid)
        #expect(binding(approvedAt: "2026-09-18T18:55:48Z").isValid)
        #expect(!binding(approvedAt: "never").isValid)
        #expect(!binding(approvedAt: "").isValid)
    }
}
