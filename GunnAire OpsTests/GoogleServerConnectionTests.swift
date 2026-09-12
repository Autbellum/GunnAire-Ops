import Foundation
import Testing
@testable import GunnAire_Ops

@MainActor
@Suite("Shared Google approval and recovery")
struct GoogleServerConnectionTests {
    @MainActor final class Fixture {
        let scope = GoogleServerScope(companyID: UUID(), backendOrigin: "https://backend.example.invalid", actorEmail: "tech@example.invalid")
        var fingerprint = "original-session"
        var allowed = true
        var storageAvailable = true
        var saved: GoogleServerPending?
        var serverAttempt: GoogleServerAttempt?
        var grantID: UUID?
        var grantState: GoogleServerSnapshot.State = .disconnected
        var requests: [(String, String)] = []
        var browserCount = 0
        var stopCount = 0
        var onRequest: (String, String) throws -> Void = { _, _ in }
        var afterMutation: () throws -> Void = {}
        var onBrowse: (() throws -> URL)?
        var overrideResponse: Data?
        var overridePrepared: String?
        var responseScope: GoogleServerScope?
        var grantedFeatures: [GoogleServerFeature] = [.mail]

        var dependencies: GoogleServerConnectionDependencies {
            .init(scope: scope, sessionFingerprint: fingerprint, check: { [self] in
                if !allowed { throw GoogleServerConnectionError.access }
            }, read: { [self] in
                if !storageAvailable { throw GoogleServerConnectionError.storage }; return saved
            }, replace: { [self] expected, next in
                if !storageAvailable { throw GoogleServerConnectionError.storage }
                guard saved == expected else { throw GoogleServerConnectionError.changed }
                saved = next
            }, request: { [self] path, method, body in try transport(path, method, body) }, browse: { [self] _ in
                browserCount += 1
                if let onBrowse { return try onBrowse() }
                complete()
                return URL(string: "gunnaireops://oauth/google/connection?attemptID=" + (serverAttempt?.id.uuidString ?? "missing"))!
            }, stopBrowser: { [self] in stopCount += 1 })
        }
        func controller() -> GoogleServerConnectionController { .init(dependencies: dependencies) }
        func seedPending() {
            saved = .init(id: UUID(), scope: scope, action: .authorize, features: [.mail, .calendar], sessionFingerprint: fingerprint)
            serverAttempt = attempt(saved!.id, features: saved!.features, state: .pending)
        }
        func attempt(_ id: UUID, features: [GoogleServerFeature], state: GoogleServerAttempt.State, grant: UUID? = nil) -> GoogleServerAttempt {
            let identity = responseScope ?? scope
            return .init(id: id, companyID: identity.companyID, actorEmail: identity.actorEmail, features: features, state: state, grantID: grant)
        }
        func snapshot() -> GoogleServerSnapshot {
            let identity = responseScope ?? scope
            return .init(id: grantID, companyID: identity.companyID, actorEmail: identity.actorEmail, state: grantState,
                features: grantState == .active ? grantedFeatures : [], pendingAttempt: serverAttempt?.finished == false ? serverAttempt : nil)
        }
        func complete() {
            guard let original = serverAttempt else { return }
            grantID = UUID(); grantState = .active
            serverAttempt = attempt(original.id, features: original.features, state: .connected, grant: grantID)
        }
        func prepared(_ id: UUID, features: [GoogleServerFeature]) throws -> Data {
            var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            let scopes = features.reduce(into: Set(["openid", "https://www.googleapis.com/auth/userinfo.email"])) { $0.formUnion($1.scopes) }
            let params = ["client_id": "fixture.apps.googleusercontent.com", "redirect_uri": scope.backendOrigin + "/api/google/oauth/callback",
                "response_type": "code", "scope": scopes.sorted().joined(separator: " "), "access_type": "offline", "prompt": "consent",
                "include_granted_scopes": "true", "state": String(repeating: "s", count: 64), "nonce": String(repeating: "n", count: 43),
                "login_hint": scope.actorEmail, "hd": "example.invalid", "code_challenge_method": "S256", "code_challenge": String(repeating: "c", count: 43)]
            url.queryItems = params.sorted(by: { $0.key < $1.key }).map { .init(name: $0.key, value: $0.value) }
            return try JSONSerialization.data(withJSONObject: ["id": id.uuidString, "companyID": scope.companyID.uuidString,
                "actorEmail": scope.actorEmail, "state": "pending", "authorizationURL": overridePrepared ?? url.string!])
        }
        func transport(_ path: String, _ method: String, _ body: Data?) throws -> Data {
            requests.append((path, method)); try onRequest(path, method)
            if let overrideResponse { return overrideResponse }
            if path.hasPrefix("/api/google/connection?") { return try JSONEncoder().encode(snapshot()) }
            if method == "GET" {
                guard let serverAttempt else { throw GunnAireBackendError.server(statusCode: 404, message: "private") }
                return try JSONEncoder().encode(serverAttempt)
            }
            let payload = try JSONSerialization.jsonObject(with: body ?? Data()) as! [String: Any]
            if path == "/api/google/authorizations" {
                let id = UUID(uuidString: payload["id"] as! String)!
                let features = (payload["features"] as! [String]).compactMap(GoogleServerFeature.init(rawValue:))
                serverAttempt = attempt(id, features: features, state: .pending)
                try afterMutation()
                return try prepared(id, features: features)
            }
            if path.hasSuffix("/cancel") {
                let id = UUID(uuidString: path.components(separatedBy: "/")[4])!
                if serverAttempt?.state != .connected {
                    serverAttempt = attempt(id, features: saved?.features ?? [.mail], state: .cancelled)
                }
                try afterMutation()
                return try JSONEncoder().encode(serverAttempt!)
            }
            if path.hasSuffix("/disconnect") {
                let id = UUID(uuidString: payload["grantID"] as! String)!
                guard id == grantID else { throw GoogleServerConnectionError.changed }
                grantState = .disconnected; try afterMutation()
                return try JSONEncoder().encode(snapshot())
            }
            throw GoogleServerConnectionError.invalid
        }
        var posts: Int { requests.filter { $0.1 == "POST" }.count }
    }

    @Test func approvalRequiresConfirmedStatusAndDoesNotExposeSynchronizationAsReady() async {
        let f = Fixture(); let c = f.controller()
        await c.authorize(features: [.mail]); #expect(f.posts == 0)
        await c.refresh(); await c.authorize(features: [.mail, .calendar])
        #expect(f.posts == 1); #expect(f.browserCount == 1)
        #expect(c.snapshot?.state == .active); #expect(c.snapshot?.features == [.mail])
        #expect(c.pending == nil); #expect(f.saved == nil)
    }
    @Test func journalIsSavedBeforeHTTPAndContainsNoOAuthSecrets() async throws {
        let f = Fixture(); let c = f.controller(); await c.refresh()
        f.onRequest = { _, method in
            if method == "POST" {
                #expect(f.saved != nil)
                let text = String(decoding: try JSONEncoder().encode(f.saved), as: UTF8.self)
                for forbidden in ["authorizationURL", "code_verifier", "access_token", "refresh_token", "nonce", "state"] { #expect(!text.contains(forbidden)) }
            }
        }
        await c.authorize(features: [.mail])
        #expect(f.posts == 1)
    }
    @Test func storageFailurePreventsAllNetworkAndBrowserWork() async {
        let f = Fixture(); let c = f.controller(); await c.refresh(); f.storageAvailable = false
        let previous = f.requests.count
        await c.authorize(features: [.mail]); #expect(f.requests.count == previous); #expect(f.browserCount == 0)
    }
    @Test func lostPrepareReplySurvivesNewControllerAndRecoversWithoutAnotherPost() async {
        let f = Fixture(); let c = f.controller(); await c.refresh()
        f.afterMutation = { throw GoogleServerConnectionError.network }
        await c.authorize(features: [.mail]); let original = f.saved
        #expect(original != nil); #expect(f.browserCount == 0)
        f.afterMutation = {}; f.complete()
        let recovered = f.controller(); await recovered.refresh()
        #expect(recovered.snapshot?.id == f.grantID); #expect(recovered.pending == nil); #expect(f.posts == 1)
    }
    @Test func originalPreparationCanBeExplicitlyResumedAfterReplyLoss() async {
        let f = Fixture(); let c = f.controller(); await c.refresh()
        f.afterMutation = { throw GoogleServerConnectionError.network }; await c.authorize(features: [.mail])
        let original = f.saved?.id; f.afterMutation = {}
        let recovered = f.controller(); await recovered.refresh(); await recovered.continueApproval()
        #expect(f.serverAttempt?.id == original); #expect(f.browserCount == 1); #expect(f.posts == 2)
    }
    @Test func missingPrepareCanBeCancelledWithoutStartingOAuth() async {
        let f = Fixture(); f.seedPending(); f.serverAttempt = nil
        let c = f.controller(); await c.refresh(); #expect(c.pending != nil)
        await c.cancelApproval()
        #expect(f.serverAttempt?.state == .cancelled); #expect(c.pending == nil); #expect(f.posts == 1); #expect(f.browserCount == 0)
    }
    @Test func cancelLostReplyRetainsTheOriginalForReadOnlyRecovery() async {
        let f = Fixture(); f.seedPending(); let c = f.controller(); await c.refresh()
        f.afterMutation = { throw GoogleServerConnectionError.network }; await c.cancelApproval()
        #expect(f.saved != nil); #expect(f.serverAttempt?.state == .cancelled)
        f.afterMutation = {}; let recovered = f.controller(); await recovered.refresh()
        #expect(recovered.pending == nil); #expect(f.posts == 1)
    }
    @Test func cancellationRacingCompletedConsentRecoversRealApproval() async {
        let f = Fixture(); f.seedPending(); let c = f.controller(); await c.refresh(); f.complete()
        await c.cancelApproval()
        #expect(c.snapshot?.state == .active); #expect(c.snapshot?.id == f.grantID); #expect(c.pending == nil)
    }
    @Test func browserCancellationCancelsTheServerAttemptNotDeviceCredentials() async {
        let f = Fixture(); let c = f.controller(); await c.refresh()
        f.onBrowse = { throw GoogleServerConnectionError.cancelled }; await c.authorize(features: [.mail])
        #expect(f.serverAttempt?.state == .cancelled); #expect(f.posts == 2); #expect(c.pending == nil)
    }
    @Test func browserPresentationFailureRetainsOriginalApproval() async {
        let f = Fixture(); let c = f.controller(); await c.refresh()
        f.onBrowse = { throw GoogleServerConnectionError.presentation }; await c.authorize(features: [.mail])
        #expect(f.saved != nil); #expect(f.posts == 1); #expect(c.pending != nil)
    }
    @Test func mismatchedCallbackCannotConfirmOrClearOriginal() async {
        let f = Fixture(); let c = f.controller(); await c.refresh()
        f.onBrowse = { f.complete(); return URL(string: "gunnaireops://oauth/google/connection?attemptID=" + UUID().uuidString)! }
        await c.authorize(features: [.mail])
        #expect(c.pending != nil); #expect(c.snapshot?.state == .disconnected)
        await c.refresh(); #expect(c.pending == nil); #expect(c.snapshot?.state == .active)
    }
    @Test func changedWorkspaceAfterBrowserNeverShowsOrCancelsAnotherAccount() async {
        let f = Fixture(); let c = f.controller(); await c.refresh()
        f.onBrowse = { f.allowed = false; throw GoogleServerConnectionError.cancelled }
        await c.authorize(features: [.mail]); #expect(f.posts == 1); #expect(f.saved != nil); #expect(c.snapshot == nil)
    }
    @Test func closingThePagePreservesRecoveryAndIgnoresLateBrowserCompletion() async {
        let f = Fixture(); let c = f.controller(); await c.refresh()
        f.onBrowse = { c.leave(); f.complete(); return URL(string: "gunnaireops://oauth/google/connection?attemptID=" + f.serverAttempt!.id.uuidString)! }
        await c.authorize(features: [.mail]); #expect(f.saved != nil); #expect(c.snapshot == nil); #expect(f.stopCount == 1)
    }
    @Test func newBusinessSessionCanRecoverOrCancelButCannotReopenOldConsent() async {
        let f = Fixture(); f.seedPending(); let original = f.saved
        f.fingerprint = "new-session"; let c = f.controller(); await c.refresh()
        #expect(!c.canContinue); await c.continueApproval(); #expect(f.posts == 0); #expect(f.saved == original)
        await c.cancelApproval(); #expect(c.pending == nil); #expect(f.posts == 1)
    }
    @Test func remotePendingRequestIsAdoptedWithoutAReplayableSession() async {
        let f = Fixture(); f.seedPending(); let original = f.saved; f.saved = nil
        let c = f.controller(); await c.refresh()
        #expect(c.pending?.id == original?.id); #expect(c.pending?.sessionFingerprint == nil); #expect(!c.canContinue)
        await c.authorize(features: [.drive]); #expect(f.posts == 0)
        await c.cancelApproval(); #expect(c.pending == nil)
    }
    @Test func staleWindowCannotEraseTheNewerPendingRecord() async {
        let f = Fixture(); f.seedPending(); let c = f.controller()
        f.onRequest = { path, _ in if path.hasPrefix("/api/google/connection?") { f.seedPending() } }
        await c.refresh(); #expect(c.snapshot == nil); #expect(f.saved != nil); #expect(f.posts == 0)
    }
    @Test func mismatchedScopeResponseCannotBePresented() async {
        let f = Fixture(); let c = f.controller()
        f.responseScope = .init(companyID: UUID(), backendOrigin: f.scope.backendOrigin, actorEmail: f.scope.actorEmail)
        await c.refresh(); #expect(c.snapshot == nil); #expect(f.posts == 0)
    }
    @Test func backendErrorsAreSafeAndNeverDisplayProviderOrAccountData() async {
        let f = Fixture(); let c = f.controller()
        f.onRequest = { _, _ in throw GunnAireBackendError.server(statusCode: 503, message: "private@example.invalid access_token=secret") }
        await c.refresh()
        #expect(c.message == GoogleServerConnectionError.unavailable.localizedDescription)
        #expect(c.message?.contains("private") == false)
    }
    @Test func exchangingStateNeverReplaysAuthorization() async {
        let f = Fixture(); f.seedPending(); let original = f.saved!
        f.serverAttempt = f.attempt(original.id, features: original.features, state: .exchanging)
        let c = f.controller(); await c.refresh(); #expect(!c.canContinue)
        await c.continueApproval(); #expect(f.posts == 0); #expect(f.saved == original)
    }
    @Test func disconnectLostReplyCanBeReadBackWithoutAnotherMutation() async {
        let f = Fixture(); f.grantID = UUID(); f.grantState = .active
        let c = f.controller(); await c.refresh(); f.afterMutation = { throw GoogleServerConnectionError.network }
        await c.disconnect(); #expect(c.pending?.action == .disconnect); #expect(f.posts == 1)
        f.afterMutation = {}; let recovered = f.controller(); await recovered.refresh()
        #expect(recovered.pending == nil); #expect(recovered.snapshot?.state == .disconnected); #expect(f.posts == 1)
    }
    @Test func reconnectElsewhereProtectsNewGrantFromStaleDisconnectRetry() async {
        let f = Fixture(); f.grantID = UUID(); f.grantState = .active
        let c = f.controller(); await c.refresh(); f.afterMutation = { throw GoogleServerConnectionError.network }
        await c.disconnect(); f.afterMutation = {}; f.grantID = UUID(); f.grantState = .active
        await c.disconnect(); #expect(f.grantState == .active)
        let recovered = f.controller(); await recovered.refresh(); #expect(recovered.pending == nil); #expect(f.grantState == .active)
    }
    @Test func completedOldApprovalDoesNotClaimANewerGrantAsItsOwn() async {
        let f = Fixture(); f.seedPending(); f.complete(); f.grantID = UUID()
        let c = f.controller(); await c.refresh()
        #expect(c.pending == nil); #expect(c.message?.contains("access changed") == true); #expect(f.posts == 0)
    }
    @Test(arguments: ["gunnaireops://oauth/other?attemptID=ID", "https://oauth/google/connection?attemptID=ID", "gunnaireops://other/google/connection?attemptID=ID", "gunnaireops://oauth/google/connection?attemptID=ID&code=private", "gunnaireops://oauth/google/connection?attemptID=ID&attemptID=ID", "gunnaireops://oauth/google/connection?attemptID=ID#fragment"])
    func callbackRequiresTheExactNonsecretRoute(template: String) throws {
        let id = UUID(); let url = try #require(URL(string: template.replacingOccurrences(of: "ID", with: id.uuidString)))
        #expect(throws: GoogleServerConnectionError.invalid) { try GoogleServerPrepared.validateCallback(url, attemptID: id) }
    }
    @Test(arguments: ["https://attacker.invalid/", "https://accounts.google.com.evil.invalid/o/oauth2/v2/auth", "http://accounts.google.com/o/oauth2/v2/auth", "https://accounts.google.com/o/oauth2/v2/auth?scope=all"])
    func untrustedAuthorizationURLsNeverOpen(url: String) async {
        let f = Fixture(); let c = f.controller(); await c.refresh(); f.overridePrepared = url
        await c.authorize(features: [.mail]); #expect(f.browserCount == 0); #expect(f.saved != nil)
    }
    @Test func oversizedOrMalformedResponseCannotDiscardPendingWork() async {
        for data in [Data("not-json".utf8), Data(repeating: 65, count: 32769)] {
            let f = Fixture(); f.seedPending(); let original = f.saved; f.overrideResponse = data
            let c = f.controller(); await c.refresh(); #expect(c.snapshot == nil); #expect(f.saved == original)
        }
    }
}
