import Foundation
import Testing
@testable import GunnAire_Ops

@MainActor
struct QuickBooksWorkspaceTransportTests {
    private enum Family: CaseIterable { case accounting, cards, tokens, charge, attachment
        var isWrite: Bool { self != .accounting && self != .cards }
        var payload: Data {
            let text: String
            switch self {
            case .accounting: text = "{\"QueryResponse\":{\"Customer\":[]}}"
            case .cards: text = "[]"
            case .tokens: text = "{\"value\":\"fixture-token-result\"}"
            case .charge: text = "{\"id\":\"fixture-charge\",\"status\":\"CAPTURED\",\"amount\":\"1.23\"}"
            case .attachment: text = "{\"AttachableResponse\":[{\"Attachable\":{\"Id\":\"fixture-attachment\"}}]}"
            }
            return Data(text.utf8)
        }
    }

    private func api(transport: @escaping WorkspaceProviderOperation.Transport) -> QuickBooksDataAPI {
        QuickBooksDataAPI(
            testTokens: QuickBooksOAuthTokens(accessToken: "fixture-bearer", expiration: .distantFuture),
            realmID: "fixture-realm", environment: Config.QuickBooks.environment,
            transport: transport
        )
    }

    private func invoke(_ family: Family, api: QuickBooksDataAPI, file: URL,
                        completion: @escaping (Result<Void, Error>) -> Void) {
        switch family {
        case .accounting: api.fetchCustomers { completion($0.map { _ in () }) }
        case .cards: api.fetchCards(forCustomerID: "fixture-customer") { completion($0.map { _ in () }) }
        case .tokens: api.createCardToken(QuickBooksPaymentsTokenCreateRequest(card: nil, bankAccount: nil)) { completion($0.map { _ in () }) }
        case .charge:
            api.createCharge(QuickBooksPaymentsChargeCreate(amount: "1.23", currency: "USD", capture: true, token: "fixture-token", description: "Fixture only", context: nil, paymentMode: nil, checkNumber: nil)) { completion($0.map { _ in () }) }
        case .attachment: api.uploadDocument(fileURL: file) { completion($0.map { _ in () }) }
        }
    }

    private func fixtureFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("provider-fixture.txt")
        try Data("Non-customer fixture".utf8).write(to: file)
        return file
    }

    @Test func everyRequestFamilyRejectsLateResponsesWithoutClearingReplacementCredentials() async throws {
        guard Config.QuickBooks.enablePaymentsScope else {
            Issue.record("This transport fixture run requires the Payments-enabled test configuration")
            return
        }
        let file = try fixtureFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        for family in Family.allCases {
            for reconnect in [false, true] {
                let (started, signal) = AsyncStream<Void>.makeStream()
                var pending: CheckedContinuation<(Data, URLResponse), Never>?
                var sentRequest: URLRequest?
                var count = 0
                let api = api { request in
                    count += 1
                    sentRequest = request
                    return await withCheckedContinuation { continuation in
                        pending = continuation
                        signal.yield(())
                    }
                }
                let work = Task {
                    await withCheckedContinuation { continuation in
                        invoke(family, api: api, file: file) { continuation.resume(returning: $0) }
                    }
                }
                for await _ in started { break }
                if reconnect {
                    api.storeTokens(QuickBooksOAuthTokens(accessToken: "replacement-fixture-bearer", expiration: .distantFuture), realmID: "fixture-realm")
                } else { api.clearTokens() }
                let request = try #require(sentRequest)
                pending?.resume(returning: (
                    Data("{\"Fault\":{\"Error\":[{\"Message\":\"old authorization failure\"}]}}".utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                ))
                switch await work.value {
                case .success: Issue.record("Late provider response escaped for \(family)")
                case .failure(let error):
                    #expect(error as? WorkspaceProviderAccessError == .changed(mayHaveReachedProvider: family.isWrite))
                }
                #expect(count == 1)
                #expect(api.tokens?.accessToken == (reconnect ? "replacement-fixture-bearer" : nil))
                #expect(api.lastAuthorizationFailureDetail == nil)
            }
        }
    }

    @Test func disconnectDuringQueuedTokenReadinessPreventsTheInitialSend() async {
        var count = 0
        let api = api { request in
            count += 1
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let result: Result<[QuickBooksCustomer], Error> = await withCheckedContinuation { continuation in
            api.fetchCustomers { continuation.resume(returning: $0) }
            api.clearTokens()
        }
        #expect(count == 0)
        if case .failure(let error) = result {
            #expect(error as? WorkspaceProviderAccessError == .changed(mayHaveReachedProvider: false))
        } else { Issue.record("Disconnected request succeeded") }
    }

    @Test func everyRequestFamilyRetries429WithTheExactRetainedMutation() async throws {
        guard Config.QuickBooks.enablePaymentsScope else {
            Issue.record("This transport fixture run requires the Payments-enabled test configuration")
            return
        }
        let file = try fixtureFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        for family in Family.allCases {
            var requests: [URLRequest] = []
            let api = api { request in
                requests.append(request)
                let status = requests.count == 1 ? 429 : 200
                return (
                    status == 200 ? family.payload : Data(),
                    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "0.001"])!
                )
            }
            let result = await withCheckedContinuation { continuation in
                invoke(family, api: api, file: file) { continuation.resume(returning: $0) }
            }
            if case .failure(let error) = result { Issue.record("Fixture \(family) failed: \(error)") }
            #expect(requests.count == 2)
            guard requests.count == 2 else { continue }
            #expect(requests[0] == requests[1])
        }
    }

    @Test func nestedUploadFaultsAndAmbiguousResultsNeverConfirmAnAttachment() throws {
        let invalid = [
            #"{"AttachableResponse":[{"Id":"flat-not-provider-format"}]}"#,
            #"{"AttachableResponse":[{}]}"#,
            #"{"AttachableResponse":[{"Attachable":{}}]}"#,
            #"{"AttachableResponse":[{"Fault":{"Error":[{"Message":"Rejected","code":"6000"}]}}]}"#,
            #"{"AttachableResponse":[{"Attachable":{"Id":"one"},"Fault":{}}]}"#,
            #"{"AttachableResponse":[{"Attachable":{"Id":"one"}},{"Attachable":{"Id":"two"}}]}"#
        ]
        for payload in invalid {
            #expect(throws: QuickBooksProviderResponseError.self) {
                try QuickBooksUploadResponsePolicy.attachmentID(from: Data(payload.utf8))
            }
        }
    }
}
