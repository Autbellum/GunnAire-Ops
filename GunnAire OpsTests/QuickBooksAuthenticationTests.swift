import Foundation
import Testing
@testable import GunnAire_Ops

@MainActor
struct QuickBooksAuthenticationTests {
    private func api(revoke: @escaping () async -> Bool) -> QuickBooksDataAPI {
        QuickBooksDataAPI(testTokens: .init(accessToken: "synthetic-token", expiration: .distantFuture),
            realmID: "synthetic-realm", environment: Config.QuickBooks.environment,
            revokeConnection: revoke, transport: { _ in throw URLError(.notConnectedToInternet) })
    }

    @Test func appSignOutStopsLocalWorkWithoutRevokingCompanyConnection() throws {
        var revocations = 0
        let data = api { revocations += 1; return true }
        let auth = QuickBooksAuthAPI(testDataAPI: data)
        let workflow = try data.captureWorkspaceWorkflow { true }
        auth.signOut()
        #expect(revocations == 0)
        #expect(data.tokens == nil)
        #expect(!auth.isAuthenticated)
        #expect(throws: WorkspaceProviderAccessError.self) { try workflow.check() }
    }

    @Test func explicitDisconnectRevokesOnceAndClearsLocalSession() async {
        var revocations = 0
        let data = api { revocations += 1; return true }
        let auth = QuickBooksAuthAPI(testDataAPI: data)
        let disconnected = await withCheckedContinuation { continuation in
            auth.disconnect { continuation.resume(returning: $0) }
        }
        #expect(disconnected)
        #expect(revocations == 1)
        #expect(data.tokens == nil)
    }

    @Test func failedDisconnectKeepsTheConnectionForRetry() async {
        var revocations = 0
        let data = api { revocations += 1; return false }
        let auth = QuickBooksAuthAPI(testDataAPI: data)
        let disconnected = await withCheckedContinuation { continuation in
            auth.disconnect { continuation.resume(returning: $0) }
        }
        #expect(!disconnected)
        #expect(revocations == 1)
        #expect(data.tokens?.accessToken == "synthetic-token")
        #expect(data.realmID == "synthetic-realm")
    }

    @Test func lateDisconnectCannotClearAReplacementConnection() async {
        var instance: QuickBooksDataAPI?
        let data = api {
            instance?.storeTokens(.init(accessToken: "replacement", expiration: .distantFuture), realmID: "new-realm")
            return true
        }
        instance = data
        let auth = QuickBooksAuthAPI(testDataAPI: data)
        let disconnected = await withCheckedContinuation { continuation in
            auth.disconnect { continuation.resume(returning: $0) }
        }
        #expect(!disconnected)
        #expect(data.tokens?.accessToken == "replacement")
        #expect(data.realmID == "new-realm")
    }

    @Test func queuedDisconnectCannotRevokeAfterAppSignOut() async {
        var revocations = 0
        let data = api { revocations += 1; return true }
        let auth = QuickBooksAuthAPI(testDataAPI: data)
        let disconnected = await withCheckedContinuation { continuation in
            auth.disconnect { continuation.resume(returning: $0) }
            auth.signOut()
        }
        #expect(!disconnected)
        #expect(revocations == 0)
        #expect(data.tokens == nil)
    }

    @Test func signOutStopsRefreshAndNotificationReloadUntilBusinessLogin() async {
        var revocations = 0
        let data = api { revocations += 1; return true }
        let auth = QuickBooksAuthAPI(testDataAPI: data)
        auth.signOut()
        await auth.reloadStoredSession()
        let refreshed = await data.refreshSessionIfPossible()
        #expect(!refreshed)
        #expect(!auth.isAuthenticated)
        #expect(data.tokens == nil)
        #expect(data.lastRefreshFailureDetail == nil)
        #expect(revocations == 0)
    }

    @Test func duplicateDisconnectRequestsSendOnlyOneRevocation() async {
        var revocations = 0
        let data = api { revocations += 1; return true }
        let results: [Bool] = await withCheckedContinuation { continuation in
            var replies: [Bool] = []
            let reply: (Bool) -> Void = { value in
                replies.append(value)
                if replies.count == 2 { continuation.resume(returning: replies) }
            }
            data.resetConnectionForReconnect(completion: reply)
            data.resetConnectionForReconnect(completion: reply)
        }
        #expect(revocations == 1)
        #expect(results.filter { $0 }.count == 1)
    }

    @Test func explicitDisconnectStillReachesServerWithoutADeviceCredential() async {
        var revocations = 0
        let data = api { revocations += 1; return true }
        data.suspendLocalSession()
        let disconnected = await withCheckedContinuation { continuation in
            data.resetConnectionForReconnect { continuation.resume(returning: $0) }
        }
        #expect(disconnected)
        #expect(revocations == 1)
    }
}
