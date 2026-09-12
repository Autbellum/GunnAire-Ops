import Foundation
import Testing
@testable import GunnAire_Ops

@MainActor
struct WorkspaceProviderOperationTests {
    private func request(method: String = "GET") -> URLRequest {
        var request = URLRequest(url: URL(string: "https://provider.example.test/resource?requestid=retained-operation")!)
        request.httpMethod = method
        request.setValue("Bearer fixture-token", forHTTPHeaderField: "Authorization")
        request.setValue("retained-operation", forHTTPHeaderField: "Request-Id")
        if method != "GET" { request.httpBody = Data("fixture-payload".utf8) }
        return request
    }

    private func response(for request: URLRequest, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    @Test func deniedOperationNeverSendsCredentialsOrPayload() async {
        let operation = WorkspaceProviderOperation { false }
        var sent = 0
        do {
            _ = try await operation.data(for: request(method: "POST")) { request in
                sent += 1
                return (Data(), response(for: request))
            }
            Issue.record("Denied operation reached transport")
        } catch {
            #expect(error as? WorkspaceProviderAccessError == .changed(mayHaveReachedProvider: false))
        }
        #expect(sent == 0 && !operation.mayHaveReachedProvider)
    }

    @Test func successfulResponsePreservesOriginalRequestAndRemainsReadable() async throws {
        let operation = WorkspaceProviderOperation { true }
        let original = request(method: "POST")
        let payload = Data("{\"id\":\"fixture-result\"}".utf8)
        let (data, reply) = try await operation.data(for: original) { sent in
            #expect(sent == original)
            return (payload, response(for: sent))
        }
        #expect(data == payload && (reply as? HTTPURLResponse)?.statusCode == 200)
        #expect(operation.mayHaveReachedProvider)
    }

    @Test func changedSessionDiscardsEveryProviderResponseBeforeDelivery() async {
        for endpoint in [
            "https://quickbooks.api.intuit.com/v3/company/fixture/query",
            "https://api.intuit.com/quickbooks/v4/payments/charges",
            "https://gmail.googleapis.com/gmail/v1/users/me/messages",
            "https://www.googleapis.com/calendar/v3/calendars/primary/events",
            "https://www.googleapis.com/drive/v3/files/fixture"
        ] {
            var current = true
            let operation = WorkspaceProviderOperation { current }
            var request = request(); request.url = URL(string: endpoint)!
            do {
                _ = try await operation.data(for: request) { sent in
                    current = false
                    return (Data("old-private-response".utf8), response(for: sent))
                }
                Issue.record("Stale response escaped")
            } catch {
                #expect(error as? WorkspaceProviderAccessError == .changed(mayHaveReachedProvider: false))
            }
        }
    }

    @Test func sentWritesRemainUnconfirmedWhenTheWorkspaceChanges() async {
        for method in ["POST", "PATCH", "PUT", "DELETE"] {
            var current = true
            let operation = WorkspaceProviderOperation { current }
            do {
                _ = try await operation.data(for: request(method: method)) { sent in
                    current = false
                    return (Data("{\"success\":true}".utf8), response(for: sent))
                }
                Issue.record("A stale write was reported as successful")
            } catch {
                #expect(error as? WorkspaceProviderAccessError == .changed(mayHaveReachedProvider: true))
                #expect(error.localizedDescription.contains("before retrying"))
            }
        }
    }

    @Test func oldNetworkFailureCannotBeMistakenForTheNewConnectionsFailure() async {
        var current = true
        let operation = WorkspaceProviderOperation { current }
        do {
            _ = try await operation.data(for: request(method: "POST")) { _ in
                current = false
                throw URLError(.networkConnectionLost)
            }
            Issue.record("Expected an unresolved old operation")
        } catch {
            #expect(error as? WorkspaceProviderAccessError == .changed(mayHaveReachedProvider: true))
        }
    }

    @Test func unchangedConnectionPreservesNetworkErrorsForExistingRecovery() async {
        let operation = WorkspaceProviderOperation { true }
        do {
            _ = try await operation.data(for: request()) { _ in throw URLError(.notConnectedToInternet) }
            Issue.record("Expected transport error")
        } catch {
            #expect((error as? URLError)?.code == .notConnectedToInternet)
        }
    }

    @Test func oldRetryAndUploadContinuationCannotSendIntoAReplacementConnection() async throws {
        for method in ["GET", "POST", "PUT"] {
            var generation = UUID()
            let originalGeneration = generation
            let operation = WorkspaceProviderOperation { generation == originalGeneration }
            var sent = 0
            let transport: WorkspaceProviderOperation.Transport = { request in
                sent += 1
                return (Data(), self.response(for: request, status: method == "PUT" ? 308 : 429))
            }
            _ = try await operation.data(for: request(method: method), transport: transport)
            generation = UUID()
            do {
                _ = try await operation.data(for: request(method: method), transport: transport)
                Issue.record("Old operation retried after replacement")
            } catch {
                #expect(error as? WorkspaceProviderAccessError == .changed(mayHaveReachedProvider: method != "GET"))
            }
            #expect(sent == 1)
        }
    }

    @Test func bearerRefreshKeepsOperationIdentityAndPayload() async throws {
        let operation = WorkspaceProviderOperation { true }
        let context = QuickBooksRetryContext(realmID: "fixture-realm", environment: "sandbox")
        let original = request(method: "POST")
        let refreshed = try #require(QuickBooksRateLimitRetryPolicy.requestForRetry(
            original, accessToken: "fixture-refreshed-token", originalContext: context, currentContext: context
        ))
        var attempts: [URLRequest] = []
        let transport: WorkspaceProviderOperation.Transport = { sent in
            attempts.append(sent)
            return (Data(), self.response(for: sent))
        }
        _ = try await operation.data(for: original, transport: transport)
        _ = try await operation.data(for: refreshed, transport: transport)
        #expect(attempts.count == 2)
        #expect(attempts[0].url == attempts[1].url)
        #expect(attempts[0].httpBody == attempts[1].httpBody)
        #expect(attempts[0].value(forHTTPHeaderField: "Request-Id") == attempts[1].value(forHTTPHeaderField: "Request-Id"))
        #expect(attempts[1].value(forHTTPHeaderField: "Authorization") == "Bearer fixture-refreshed-token")
    }
}
