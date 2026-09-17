import Foundation
import Testing
@testable import GunnAire_Ops

@MainActor
struct QuickBooksChangeHistoryDiagnosticsTests {
    private let scope = QuickBooksChangeHistoryScope(companyID: UUID(), realmID: "fixture-realm", environment: "sandbox")

    /// Runs one Item capture through the real client against a failing
    /// transport and returns the safe error plus the recorded diagnostic.
    private func outcome(_ reply: @escaping QuickBooksChangeHistoryClient.Request) async throws
        -> (error: QuickBooksChangeHistoryError?, failure: QuickBooksChangeHistoryFailure?) {
        QuickBooksChangeHistoryDiagnostics.reset()
        let reader = try QuickBooksChangeHistoryClient(scope: scope, check: {}, request: reply)
        do {
            let _: [QuickBooksItem] = try await reader.records(entity: .item)
            Issue.record("Failed capture returned records")
            return (nil, nil)
        } catch {
            return (error as? QuickBooksChangeHistoryError, QuickBooksChangeHistoryDiagnostics.lastFailure)
        }
    }

    @Test func throttledServerReplyKeepsStatusCodeAndStaffMessage() async throws {
        let body = Data(#"{"error":"QuickBooks is busy. Retry this original capture later; its cursor has not advanced.","code":"provider_throttled"}"#.utf8)
        let result = try await outcome { _, _, _ in throw QuickBooksChangeHistoryServerFailure(status: 503, body: body) }
        #expect(result.error == .unavailable)
        let failure = try #require(result.failure)
        #expect(failure.kind == .server)
        #expect(failure.status == 503)
        #expect(failure.code == "provider_throttled")
        #expect(failure.entity == "Item")
        #expect(failure.summary == "Server: HTTP 503 provider_throttled - QuickBooks is busy. Retry this original capture later; its cursor has not advanced.")
        #expect(failure.detailSuffix == " Server: HTTP 503 provider_throttled - QuickBooks is busy. Retry this original capture later; its cursor has not advanced.")
        #expect(QuickBooksChangeHistoryDiagnostics.failuresByEntity["Item"] == failure)
    }

    @Test func gatewayFailureWithoutABodyStillShowsItsStatus() async throws {
        let result = try await outcome { _, _, _ in throw QuickBooksChangeHistoryServerFailure(status: 502, body: Data()) }
        #expect(result.error == .unavailable)
        let failure = try #require(result.failure)
        #expect(failure.status == 502)
        #expect(failure.code == nil)
        #expect(failure.summary == "Server: HTTP 502 - No error details were returned.")
    }

    @Test func deviceTimeoutIsReportedAsATransportCode() async throws {
        let result = try await outcome { _, _, _ in throw URLError(.timedOut) }
        #expect(result.error == .unavailable)
        let failure = try #require(result.failure)
        #expect(failure.kind == .transport)
        #expect(failure.status == nil)
        #expect(failure.code == "URLError -1001")
        #expect(failure.summary == "Transport: URLError -1001 timed out.")
    }

    @Test func malformedPageIsReportedByDecodingKindAndKeyOnly() async throws {
        let result = try await outcome { _, _, _ in Data("{}".utf8) }
        #expect(result.error == .invalid)
        let failure = try #require(result.failure)
        #expect(failure.kind == .response)
        #expect(failure.status == nil)
        #expect(failure.code == "DecodingError keyNotFound")
        #expect(failure.summary == "Response: DecodingError keyNotFound at companyID.")
    }

    @Test func plainBackendStatusIsStillRecordedWithoutACode() async throws {
        let result = try await outcome { _, _, _ in
            throw GunnAireBackendError.server(statusCode: 204, message: "Accounting history was not confirmed.")
        }
        #expect(result.error == .unavailable)
        #expect(result.failure?.summary == "Server: HTTP 204 - Accounting history was not confirmed.")
    }

    /// The client's own outcome errors record which check failed for which
    /// entity (they used to be silent, leaving every row with the generic
    /// sentence and no cause); access errors and cancellation stay silent.
    @Test func ownOutcomeErrorsRecordTheirCause() async throws {
        let result = try await outcome { _, _, _ in throw QuickBooksChangeHistoryError.changed }
        #expect(result.error == .changed)
        let failure = try #require(result.failure)
        #expect(failure.kind == .response)
        #expect(failure.status == nil)
        #expect(failure.code == "collection_changed")
        #expect(failure.entity == "Item")
        #expect(failure.summary == "Response: collection_changed The accounting connection or the collection revision changed during the run.")
        for own in [QuickBooksChangeHistoryError.invalid, .incomplete, .lifecycleReview, .unavailable, .limit] {
            let described = try #require(QuickBooksChangeHistoryDiagnostics.describe(own, entity: .customer))
            #expect(described.kind == .response && described.entity == "Customer" && described.code == own.diagnosticCause?.code)
        }
        #expect(QuickBooksChangeHistoryDiagnostics.describe(QuickBooksChangeHistoryError.access, entity: .item) == nil)
        #expect(QuickBooksChangeHistoryDiagnostics.describe(CancellationError(), entity: .item) == nil)
    }

    @Test func safeStatusMappingIsUnchanged() {
        func server(_ status: Int) -> GunnAireBackendError { .server(statusCode: status, message: "fixture") }
        func kept(_ status: Int) -> QuickBooksChangeHistoryServerFailure { .init(status: status, code: "fixture", message: "fixture") }
        for status in [500, 502, 503, 504, 404, 429] {
            #expect(QuickBooksChangeHistoryError.safe(server(status)) == .unavailable)
            #expect(QuickBooksChangeHistoryError.safe(kept(status)) == .unavailable)
        }
        #expect(QuickBooksChangeHistoryError.safe(server(409)) == .changed)
        #expect(QuickBooksChangeHistoryError.safe(kept(409)) == .changed)
        #expect(QuickBooksChangeHistoryError.safe(server(401)) == .access)
        #expect(QuickBooksChangeHistoryError.safe(kept(401)) == .access)
        #expect(QuickBooksChangeHistoryError.safe(server(403)) == .access)
        #expect(QuickBooksChangeHistoryError.safe(kept(403)) == .access)
        #expect(QuickBooksChangeHistoryError.safe(server(400)) == .invalid)
        #expect(QuickBooksChangeHistoryError.safe(kept(400)) == .invalid)
        #expect(QuickBooksChangeHistoryError.safe(URLError(.timedOut)) == .unavailable)
        #expect(QuickBooksChangeHistoryError.safe(QuickBooksChangeHistoryError.limit) == .limit)
        #expect(!QuickBooksChangeHistoryError.safe(kept(503)).localizedDescription.contains("fixture"))
    }

    @Test func serverBodiesAreBoundedAndSanitizedBeforeDisplay() {
        let control = QuickBooksChangeHistoryServerFailure(status: 503,
            body: Data("{\"error\":\"  line one\\nline\\ttwo  \",\"code\":\"bad code!\"}".utf8))
        #expect(control.message == "line one line two")
        #expect(control.code == nil)
        let long = QuickBooksChangeHistoryServerFailure(status: 500, code: "storage_unavailable",
            message: String(repeating: "x", count: 400))
        #expect(long.message?.count == QuickBooksChangeHistoryServerFailure.maximumMessageLength + 1)
        #expect(long.message?.hasSuffix("…") == true)
        #expect(long.code == "storage_unavailable")
        let html = QuickBooksChangeHistoryServerFailure(status: 502, body: Data("<html>Bad Gateway</html>".utf8))
        #expect(html.message == nil && html.code == nil)
        let typed = QuickBooksChangeHistoryServerFailure(status: 503, body: Data(#"{"error":5,"code":["x"]}"#.utf8))
        #expect(typed.message == nil && typed.code == nil)
        let oversized = QuickBooksChangeHistoryServerFailure(status: 503,
            body: Data(("{\"code\":\"provider_throttled\",\"error\":\"" + String(repeating: "y", count: 20_000) + "\"}").utf8))
        #expect(oversized.message == nil && oversized.code == nil)
        #expect(QuickBooksChangeHistoryServerFailure.observedStatusCodes.contains(200))
        #expect(QuickBooksChangeHistoryServerFailure.observedStatusCodes.contains(503))
        for code in [101, 201, 204, 301, 302, 304, 307] {
            #expect(!QuickBooksChangeHistoryServerFailure.observedStatusCodes.contains(code))
        }
    }
}
