import Foundation
import Testing
@testable import GunnAire_Ops

nonisolated private final class OAuthStateMemoryStorage: @unchecked Sendable {
    enum Failure: Error, Equatable { case unavailable }

    private let lock = NSLock()
    private var bytes: Data?
    private var failsRemoval = false
    private var ignoresRemoval = false
    private var usedMainThread = false

    var dependencies: QuickBooksOAuthStateStorage {
        .init(read: { [self] in
            lock.withLock {
                usedMainThread = usedMainThread || Thread.isMainThread
                return bytes
            }
        }, write: { [self] data in
            lock.withLock {
                usedMainThread = usedMainThread || Thread.isMainThread
                bytes = data
            }
        }, remove: { [self] in
            try lock.withLock {
                usedMainThread = usedMainThread || Thread.isMainThread
                if failsRemoval { throw Failure.unavailable }
                if !ignoresRemoval { bytes = nil }
            }
        })
    }

    func setRemovalFailure(_ value: Bool) { lock.withLock { failsRemoval = value } }
    func setRemovalIgnored(_ value: Bool) { lock.withLock { ignoresRemoval = value } }
    func storedBytes() -> Data? { lock.withLock { bytes } }
    func touchedMainThread() -> Bool { lock.withLock { usedMainThread } }
}

@MainActor
@Suite("Durable QuickBooks OAuth state")
struct QuickBooksOAuthStateTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let binding = "synthetic-business-session-and-configuration"

    private func callback(_ record: QuickBooksOAuthStateRecord, realmName: String = "realmId") throws -> URL {
        var parts = URLComponents()
        parts.scheme = "gunnaireops"
        parts.host = "oauth"
        parts.queryItems = [URLQueryItem(name: "state", value: record.state),
                            URLQueryItem(name: "code", value: "synthetic-code"),
                            URLQueryItem(name: realmName, value: "12345")]
        return try #require(parts.url)
    }

    private func dataAPI() -> QuickBooksDataAPI {
        QuickBooksDataAPI(testTokens: .init(accessToken: "existing-synthetic-token", expiration: .distantFuture),
                         realmID: "existing-synthetic-realm", environment: Config.QuickBooks.environment,
                         revokeConnection: { Issue.record("OAuth must not revoke the existing connection."); return false },
                         transport: { _ in throw URLError(.notConnectedToInternet) })
    }

    @Test func freshStoreRestoresPersistedFlowAndConsumesBeforeExchange() async throws {
        let memory = OAuthStateMemoryStorage()
        let record = QuickBooksOAuthStateRecord(binding: binding, createdAt: now)
        try await QuickBooksOAuthStateStore(storage: memory.dependencies).save(record)
        let persisted = try #require(memory.storedBytes())
        #expect(try JSONDecoder().decode(QuickBooksOAuthStateRecord.self, from: persisted) == record)
        #expect(record.expiresAt.timeIntervalSince(record.createdAt) == 600)

        let restoredStore = QuickBooksOAuthStateStore(storage: memory.dependencies)
        let consumed = try await restoredStore.consume(state: record.state, binding: binding, now: now)
        #expect(consumed == record)
        #expect(memory.storedBytes() == nil)
        #expect(!memory.touchedMainThread())

        let restartedAgain = QuickBooksOAuthStateStore(storage: memory.dependencies)
        await #expect(throws: QuickBooksOAuthStateError.missing) {
            try await restartedAgain.consume(state: record.state, binding: binding, now: now)
        }
    }

    @Test func onlyOneConcurrentCallbackCanConsume() async throws {
        let memory = OAuthStateMemoryStorage()
        let store = QuickBooksOAuthStateStore(storage: memory.dependencies)
        let record = QuickBooksOAuthStateRecord(binding: binding, createdAt: now)
        try await store.save(record)
        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<8 {
                group.addTask { [binding, now] in
                    do {
                        _ = try await store.consume(state: record.state, binding: binding, now: now)
                        return true
                    } catch { return false }
                }
            }
            var count = 0
            for await succeeded in group where succeeded { count += 1 }
            return count
        }
        #expect(successes == 1)
    }

    @Test func expiryRejectsBoundaryButAcceptsLastValidSecond() async throws {
        let memory = OAuthStateMemoryStorage()
        let store = QuickBooksOAuthStateStore(storage: memory.dependencies)
        let record = QuickBooksOAuthStateRecord(binding: binding, createdAt: now)
        try await store.save(record)
        await #expect(throws: QuickBooksOAuthStateError.expired) {
            try await store.consume(state: record.state, binding: binding, now: record.expiresAt)
        }
        #expect(memory.storedBytes() != nil)
        let consumed = try await store.consume(
            state: record.state, binding: binding, now: record.expiresAt.addingTimeInterval(-1)
        )
        #expect(consumed == record)
    }

    @Test func clockRollbackDoesNotAuthorizeExchange() async throws {
        let memory = OAuthStateMemoryStorage()
        let store = QuickBooksOAuthStateStore(storage: memory.dependencies)
        let record = QuickBooksOAuthStateRecord(binding: binding, createdAt: now)
        try await store.save(record)
        await #expect(throws: QuickBooksOAuthStateError.clockRollback) {
            try await store.consume(state: record.state, binding: binding, now: now.addingTimeInterval(-1))
        }
        #expect(memory.storedBytes() != nil)
    }

    @Test func wrongStateOrBindingPreservesTheMatchingFlow() async throws {
        let memory = OAuthStateMemoryStorage()
        let store = QuickBooksOAuthStateStore(storage: memory.dependencies)
        let record = QuickBooksOAuthStateRecord(binding: binding, createdAt: now)
        try await store.save(record)
        let originalBytes = memory.storedBytes()
        for state in [UUID().uuidString, "", " " + record.state, record.state + "," + record.state] {
            await #expect(throws: QuickBooksOAuthStateError.mismatchedState) {
                try await store.consume(state: state, binding: binding, now: now)
            }
            #expect(memory.storedBytes() == originalBytes)
        }
        await #expect(throws: QuickBooksOAuthStateError.changedBinding) {
            try await store.consume(state: record.state, binding: "different-session", now: now)
        }
        #expect(memory.storedBytes() == originalBytes)
        #expect(try await store.consume(state: record.state, binding: binding, now: now) == record)
    }

    @Test func deletionFailurePreventsTokenExchangeAndCanBeRetried() async throws {
        let memory = OAuthStateMemoryStorage()
        let store = QuickBooksOAuthStateStore(storage: memory.dependencies)
        let record = QuickBooksOAuthStateRecord(binding: binding, createdAt: now)
        try await store.save(record)
        memory.setRemovalFailure(true)
        var exchanges = 0
        do {
            _ = try await store.consume(state: record.state, binding: binding, now: now)
            exchanges += 1
            Issue.record("Removal failure unexpectedly authorized token exchange.")
        } catch let error as OAuthStateMemoryStorage.Failure {
            #expect(error == .unavailable)
        }
        #expect(exchanges == 0)
        #expect(memory.storedBytes() != nil)
        memory.setRemovalFailure(false)
        _ = try await store.consume(state: record.state, binding: binding, now: now)
        exchanges += 1
        #expect(exchanges == 1)
        #expect(memory.storedBytes() == nil)
    }

    @Test func successfulDeleteWithoutDurableRemovalStillPreventsExchange() async throws {
        let memory = OAuthStateMemoryStorage()
        let store = QuickBooksOAuthStateStore(storage: memory.dependencies)
        let record = QuickBooksOAuthStateRecord(binding: binding, createdAt: now)
        try await store.save(record)
        memory.setRemovalIgnored(true)
        await #expect(throws: QuickBooksOAuthStateError.removalNotConfirmed) {
            try await store.consume(state: record.state, binding: binding, now: now)
        }
        #expect(memory.storedBytes() != nil)
    }

    @Test func cancellingOlderBrowserPreservesNewerPendingFlow() async throws {
        let memory = OAuthStateMemoryStorage()
        let store = QuickBooksOAuthStateStore(storage: memory.dependencies)
        let older = QuickBooksOAuthStateRecord(binding: binding, createdAt: now)
        let newer = QuickBooksOAuthStateRecord(binding: binding, createdAt: now)
        try await store.save(older)
        try await store.save(newer)
        #expect(try await store.cancel(state: older.state) == false)
        await #expect(throws: QuickBooksOAuthStateError.mismatchedState) {
            try await store.consume(state: older.state, binding: binding, now: now)
        }
        #expect(try await store.consume(state: newer.state, binding: binding, now: now) == newer)
        try await store.save(newer)
        #expect(try await store.cancel(state: newer.state))
        #expect(memory.storedBytes() == nil)
    }

    @Test func callbackParserAcceptsBothDocumentedRealmSpellings() throws {
        let record = QuickBooksOAuthStateRecord(binding: binding, createdAt: now)
        for name in ["realmId", "realmid"] {
            let parsed = try QuickBooksOAuthCallback.parse(callback(record, realmName: name), expectedScheme: "gunnaireops")
            #expect(parsed.state == record.state)
            #expect(parsed.code == "synthetic-code")
            #expect(parsed.realmID == "12345")
        }
    }

    @Test func callbackParserRejectsSchemeAndParameterAmbiguity() throws {
        let record = QuickBooksOAuthStateRecord(binding: binding, createdAt: now)
        let url = try callback(record)
        for extra in ["&state=" + record.state, "&code=second", "&realmId=54321", "&realmid=12345", "#fragment"] {
            let invalid = try #require(URL(string: url.absoluteString + extra))
            #expect(throws: QBOError.self) { try QuickBooksOAuthCallback.parse(invalid, expectedScheme: "gunnaireops") }
        }
        var parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        parts.scheme = "otherapp"
        let wrongScheme = try #require(parts.url)
        #expect(throws: QBOError.invalidCallback) { try QuickBooksOAuthCallback.parse(wrongScheme, expectedScheme: "gunnaireops") }
        for name in ["state", "code", "realmId"] {
            parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            parts.queryItems = parts.queryItems?.filter { $0.name != name }
            let missing = try #require(parts.url)
            #expect(throws: QBOError.self) { try QuickBooksOAuthCallback.parse(missing, expectedScheme: "gunnaireops") }
        }
    }

    @Test func callbackConsumesBeforeExchangeAndPublishesOnlyVerifiedResult() async throws {
        let memory = OAuthStateMemoryStorage()
        let store = QuickBooksOAuthStateStore(storage: memory.dependencies)
        let record = QuickBooksOAuthStateRecord(binding: binding, createdAt: now)
        try await store.save(record)
        let data = dataAPI()
        var exchanges = 0
        let auth = QuickBooksAuthAPI(testDataAPI: data, stateStore: store, currentBinding: { binding }, exchangeCode: { code, realm in
            #expect(memory.storedBytes() == nil)
            #expect(data.tokens?.accessToken == "existing-synthetic-token")
            #expect(code == "synthetic-code")
            #expect(realm == "12345")
            exchanges += 1
            return .init(accessToken: "replacement-synthetic-token", expiration: .distantFuture)
        }, now: { now })
        try await auth.completeAuthCallback(url: callback(record))
        #expect(exchanges == 1)
        #expect(auth.isAuthenticated)
        #expect(data.tokens?.accessToken == "replacement-synthetic-token")
        await #expect(throws: QBOError.invalidState) { try await auth.completeAuthCallback(url: callback(record)) }
        #expect(exchanges == 1)
    }

    @Test func changedSessionBeforeCallbackDoesNotExchangeOrErasePendingFlow() async throws {
        let memory = OAuthStateMemoryStorage()
        let store = QuickBooksOAuthStateStore(storage: memory.dependencies)
        let record = QuickBooksOAuthStateRecord(binding: binding, createdAt: now)
        try await store.save(record)
        let original = memory.storedBytes()
        let data = dataAPI()
        let auth = QuickBooksAuthAPI(testDataAPI: data, stateStore: store, currentBinding: { "different-business-session" },
                                    exchangeCode: { _, _ in Issue.record("Changed binding reached exchange."); throw QBOError.unknown }, now: { now })
        await #expect(throws: QBOError.sessionChanged) { try await auth.completeAuthCallback(url: callback(record)) }
        #expect(memory.storedBytes() == original)
        #expect(data.tokens?.accessToken == "existing-synthetic-token")
    }

    @Test func signOutDuringExchangePreventsLateTokenPublication() async throws {
        let memory = OAuthStateMemoryStorage()
        let store = QuickBooksOAuthStateStore(storage: memory.dependencies)
        let record = QuickBooksOAuthStateRecord(binding: binding, createdAt: now)
        try await store.save(record)
        let data = dataAPI()
        var instance: QuickBooksAuthAPI?
        let auth = QuickBooksAuthAPI(testDataAPI: data, stateStore: store, currentBinding: { binding }, exchangeCode: { _, _ in
            instance?.signOut()
            return .init(accessToken: "late-synthetic-token", expiration: .distantFuture)
        }, now: { now })
        instance = auth
        await #expect(throws: QBOError.sessionChanged) { try await auth.completeAuthCallback(url: callback(record)) }
        #expect(!auth.isAuthenticated)
        #expect(data.tokens == nil)
        await auth.finishPendingCancellationForTesting()
    }

    @Test func changedBindingDuringExchangePreservesExistingConnection() async throws {
        let memory = OAuthStateMemoryStorage()
        let store = QuickBooksOAuthStateStore(storage: memory.dependencies)
        let record = QuickBooksOAuthStateRecord(binding: binding, createdAt: now)
        try await store.save(record)
        let data = dataAPI()
        var current = binding
        let auth = QuickBooksAuthAPI(testDataAPI: data, stateStore: store, currentBinding: { current }, exchangeCode: { _, _ in
            current = "replacement-business-session"
            return .init(accessToken: "late-synthetic-token", expiration: .distantFuture)
        }, now: { now })
        await #expect(throws: QBOError.sessionChanged) { try await auth.completeAuthCallback(url: callback(record)) }
        #expect(data.tokens?.accessToken == "existing-synthetic-token")
    }

    @Test func restartCallbackRestoresBusinessSessionBeforeExchange() async throws {
        let memory = OAuthStateMemoryStorage()
        let record = QuickBooksOAuthStateRecord(binding: binding, createdAt: now)
        try await QuickBooksOAuthStateStore(storage: memory.dependencies).save(record)
        var restored = false
        var exchanges = 0
        let data = dataAPI()
        let auth = QuickBooksAuthAPI(testDataAPI: data, stateStore: QuickBooksOAuthStateStore(storage: memory.dependencies),
                                    currentBinding: { restored ? binding : nil }, exchangeCode: { _, _ in
            #expect(restored)
            #expect(memory.storedBytes() == nil)
            exchanges += 1
            return .init(accessToken: "restored-synthetic-token", expiration: .distantFuture)
        }, restoreBusinessSession: { restored = true }, now: { now })
        await auth.resumeAuthorization(from: try callback(record))
        #expect(exchanges == 1)
        #expect(auth.isAuthenticated)
        #expect(auth.callbackErrorMessage == nil)
    }

    @Test func restartSignOutCancelsPersistedBindingAndCannotResumeItAgain() async throws {
        let memory = OAuthStateMemoryStorage()
        let record = QuickBooksOAuthStateRecord(binding: binding, createdAt: now)
        try await QuickBooksOAuthStateStore(storage: memory.dependencies).save(record)
        let store = QuickBooksOAuthStateStore(storage: memory.dependencies)
        let auth = QuickBooksAuthAPI(testDataAPI: dataAPI(), stateStore: store, currentBinding: { binding }, now: { now })
        auth.signOut()
        await auth.finishPendingCancellationForTesting()
        #expect(memory.storedBytes() == nil)
        var exchanges = 0
        let restarted = QuickBooksAuthAPI(testDataAPI: dataAPI(), stateStore: QuickBooksOAuthStateStore(storage: memory.dependencies),
                                         currentBinding: { binding }, exchangeCode: { _, _ in
            exchanges += 1
            return .init(accessToken: "forbidden-token", expiration: .distantFuture)
        }, now: { now })
        await restarted.resumeAuthorization(from: try callback(record))
        #expect(exchanges == 0)
        #expect(!restarted.isAuthenticated)
        #expect(restarted.callbackErrorMessage != nil)
        #expect(restarted.callbackErrorMessage?.contains("synthetic-code") == false)
    }

    @Test func signOutDuringRestorePreventsResumeAndPreservesAnotherSessionsFlow() async throws {
        let memory = OAuthStateMemoryStorage()
        let record = QuickBooksOAuthStateRecord(binding: "different-business-session", createdAt: now)
        let store = QuickBooksOAuthStateStore(storage: memory.dependencies)
        try await store.save(record)
        let data = dataAPI()
        var instance: QuickBooksAuthAPI?
        let auth = QuickBooksAuthAPI(testDataAPI: data, stateStore: store, currentBinding: { binding },
                                    exchangeCode: { _, _ in Issue.record("Signed-out restore reached exchange."); throw QBOError.unknown },
                                    restoreBusinessSession: { instance?.signOut() }, now: { now })
        instance = auth
        await auth.resumeAuthorization(from: try callback(record))
        await auth.finishPendingCancellationForTesting()
        #expect(memory.storedBytes() != nil)
        #expect(data.tokens == nil)
        #expect(!auth.isAuthenticated)
    }
}
