import Foundation
import Testing
@testable import GunnAire_Ops

@MainActor
struct GoogleIntegrationIdentityTests {
    @MainActor private final class Identity {
        let email = "oauth-fixture@gunnaire.com"
        var session: CompanyWorkspaceSession?
        var stamp: CompanyWorkspaceOperationStamp?
        var invalidations = 0
        weak var auth: GoogleAuthManager?

        init(bootstrap: Bool = false) {
            guard !bootstrap else { return }
            let proof = CompanyWorkspaceSession(backendOrigin: "https://fixture.invalid", email: email,
                tokenFingerprint: "original-business-proof", expiresAt: .distantFuture)
            session = proof
            stamp = .init(generation: UUID(), session: proof)
        }
    }

    @MainActor private final class Provider {
        var profileEmail = "oauth-fixture@gunnaire.com"
        var profileDomain = Config.Google.allowedHostedDomain
        var holdsProfile = false
        var candidateRefreshToken = "candidate-refresh"
        var holdsRefresh = false
        private(set) var requests: [URLRequest] = []
        private var profileReply: CheckedContinuation<Void, Never>?
        private var profileWaiter: CheckedContinuation<Void, Never>?
        private var refreshReply: CheckedContinuation<Void, Never>?
        private var refreshWaiter: CheckedContinuation<Void, Never>?

        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            let url = try #require(request.url)
            let payload: Data
            if url.absoluteString == Config.Google.tokenEndpoint {
                let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                if body.contains("grant_type=refresh_token") {
                    if holdsRefresh {
                        await withCheckedContinuation { continuation in
                            refreshReply = continuation
                            refreshWaiter?.resume()
                            refreshWaiter = nil
                        }
                    }
                    payload = Data("{\"access_token\":\"late-old-access\",\"id_token\":\"late-old-id\",\"expires_in\":3600,\"scope\":\"old-scope\"}".utf8)
                } else {
                    let candidate: [String: Any] = [
                        "access_token": "candidate-access", "refresh_token": candidateRefreshToken,
                        "id_token": "candidate-id", "expires_in": 3600, "scope": "openid email"
                    ]
                    payload = try JSONSerialization.data(withJSONObject: candidate)
                }
            } else {
                #expect(url.path == "/oauth2/v3/userinfo")
                if holdsProfile {
                    await withCheckedContinuation { continuation in
                        profileReply = continuation
                        profileWaiter?.resume()
                        profileWaiter = nil
                    }
                }
                payload = try JSONSerialization.data(withJSONObject: [
                    "sub": "synthetic-subject", "email": profileEmail, "hd": profileDomain
                ])
            }
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (payload, response)
        }

        func waitForProfile() async {
            guard profileReply == nil else { return }
            await withCheckedContinuation { profileWaiter = $0 }
        }

        func releaseProfile() {
            profileReply?.resume()
            profileReply = nil
        }

        func waitForRefresh() async {
            guard refreshReply == nil else { return }
            await withCheckedContinuation { refreshWaiter = $0 }
        }

        func releaseRefresh() {
            refreshReply?.resume()
            refreshReply = nil
        }
    }

    private func manager(_ identity: Identity, _ provider: Provider, expired: Bool = false) -> GoogleAuthManager {
        let originalSession: GunnAireGoogleApplicationSession? = identity.session.map { proof in
            .init(token: "original-business-token", expiresAt: "2099-01-01T00:00:00Z",
                  email: proof.email, googleUserIdentifier: "original-subject")
        }
        let auth = GoogleAuthManager(testTokens: .init(accessToken: "original-access",
            refreshToken: "original-refresh", idToken: "original-id", expiration: expired ? .distantPast : .distantFuture),
            email: identity.email,
            // Reproduce the Google-only AppIdentity lookup that used to follow
            // a just-published provider email before checking business ownership.
            businessEmail: { identity.auth?.signedInEmail },
            mutationInvalidation: { identity.invalidations += 1 },
            workspaceStamp: { identity.stamp }, businessSession: { identity.session },
            applicationSession: originalSession, transport: { try await provider.send($0) })
        identity.auth = auth
        return auth
    }

    private func callback(_ auth: GoogleAuthManager) throws -> URL {
        let authorization = try #require(auth.beginTestAuthorization())
        let parts = try #require(URLComponents(url: authorization, resolvingAgainstBaseURL: false))
        let state = try #require(parts.queryItems?.first { $0.name == "state" }?.value)
        var result = URLComponents()
        result.scheme = GoogleAuthManager.callbackScheme
        result.path = "/oauth2redirect"
        result.queryItems = [.init(name: "code", value: "synthetic-code"), .init(name: "state", value: state)]
        return try #require(result.url)
    }

    private func complete(_ auth: GoogleAuthManager, _ callback: URL) async -> Result<Void, Error> {
        await withCheckedContinuation { continuation in
            auth.completeTestAuthorization(url: callback) { continuation.resume(returning: $0) }
        }
    }

    @Test func wrongGoogleOnlyAccountNeverPublishesCandidateCredentialsOrIdentity() async throws {
        let identity = Identity(), provider = Provider()
        provider.profileEmail = "different-fixture@gunnaire.com"
        provider.holdsProfile = true
        let auth = manager(identity, provider)
        let originalStamp = identity.stamp
        let originalProof = auth.workspaceSessionProof
        let invalidations = identity.invalidations
        let url = try callback(auth)
        let task = Task { await complete(auth, url) }
        await provider.waitForProfile()
        #expect(auth.accessToken == "original-access")
        #expect(auth.signedInEmail == identity.email)
        #expect(provider.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer candidate-access")
        provider.releaseProfile()
        let result = await task.value
        guard case .failure(let error) = result, let authError = error as? GoogleAuthError,
              case .businessAccountMismatch = authError else {
            Issue.record("Wrong Google account escaped the original business binding"); return
        }
        #expect(auth.accessToken == "original-access")
        #expect(auth.refreshToken == "original-refresh")
        #expect(auth.idToken == "original-id")
        #expect(auth.signedInEmail == identity.email)
        #expect(auth.applicationSessionToken == "original-business-token")
        #expect(auth.workspaceSessionProof == originalProof)
        #expect(identity.stamp == originalStamp)
        #expect(identity.invalidations == invalidations)
    }

    @Test func matchingReauthorizationPublishesOnlyAfterProfileValidationAndKeepsBusinessSession() async throws {
        let identity = Identity(), provider = Provider()
        provider.holdsProfile = true
        let auth = manager(identity, provider)
        let proof = auth.workspaceSessionProof
        let url = try callback(auth)
        let task = Task { await complete(auth, url) }
        await provider.waitForProfile()
        #expect(auth.accessToken == "original-access")
        provider.releaseProfile()
        try await task.value.get()
        #expect(auth.accessToken == "candidate-access")
        #expect(auth.refreshToken == "candidate-refresh")
        #expect(auth.signedInEmail == identity.email)
        #expect(auth.applicationSessionToken == "original-business-token")
        #expect(auth.workspaceSessionProof == proof)
        #expect(provider.requests.count == 2)
    }

    @Test func sessionChangeWhileBrowserIsOpenRejectsBeforeTokenExchange() async throws {
        let identity = Identity(), provider = Provider()
        let auth = manager(identity, provider)
        let url = try callback(auth)
        identity.stamp = .init(generation: UUID(), session: try #require(identity.session))
        let result = await complete(auth, url)
        guard case .failure(let error) = result else { Issue.record("Changed workspace accepted OAuth"); return }
        #expect(error as? WorkspaceProviderAccessError == .changed(mayHaveReachedProvider: false))
        #expect(provider.requests.isEmpty)
        #expect(auth.accessToken == "original-access")
        #expect(auth.applicationSessionToken == "original-business-token")
    }

    @Test func lateRefreshCannotReplaceValidatedOAuthCredentialsWithTheSameRefreshToken() async throws {
        let identity = Identity(), provider = Provider()
        provider.holdsRefresh = true
        provider.candidateRefreshToken = "original-refresh"
        let auth = manager(identity, provider, expired: true)
        let proof = auth.workspaceSessionProof
        let stamp = identity.stamp
        let url = try callback(auth)
        let refresh = Task {
            await withCheckedContinuation { continuation in
                auth.refreshTokensIfNeeded { continuation.resume(returning: $0) }
            }
        }
        await provider.waitForRefresh()
        try await complete(auth, url).get()
        #expect(auth.accessToken == "candidate-access")
        #expect(auth.refreshToken == "original-refresh")
        provider.releaseRefresh()
        let result = await refresh.value
        guard case .failure(let error) = result else {
            Issue.record("Refresh from the replaced OAuth generation overwrote candidate credentials"); return
        }
        #expect(error as? WorkspaceProviderAccessError == .changed(mayHaveReachedProvider: false))
        #expect(auth.accessToken == "candidate-access")
        #expect(auth.idToken == "candidate-id")
        #expect(auth.grantedScopeSignature == Config.Google.scopeSignature(for: ["openid email"]))
        #expect(auth.applicationSessionToken == "original-business-token")
        #expect(auth.workspaceSessionProof == proof)
        #expect(identity.stamp == stamp)
        #expect(provider.requests.count == 3)
    }

    @Test func sessionLossDuringProfileValidationRejectsLateCredentials() async throws {
        let identity = Identity(), provider = Provider()
        provider.holdsProfile = true
        let auth = manager(identity, provider)
        let url = try callback(auth)
        let task = Task { await complete(auth, url) }
        await provider.waitForProfile()
        identity.session = nil
        identity.stamp = nil
        provider.releaseProfile()
        let result = await task.value
        guard case .failure(let error) = result else { Issue.record("Expired business session accepted OAuth"); return }
        #expect(error as? WorkspaceProviderAccessError == .changed(mayHaveReachedProvider: false))
        #expect(auth.accessToken == "original-access")
        #expect(auth.signedInEmail == identity.email)
        #expect(auth.applicationSessionToken == "original-business-token")
    }

    @Test func firstLoginWithoutBusinessWorkspaceCanEstablishItsApprovedGoogleIdentity() async throws {
        let identity = Identity(bootstrap: true), provider = Provider()
        provider.profileEmail = "first-login-fixture@gunnaire.com"
        let auth = manager(identity, provider)
        auth.signOut()
        #expect(!auth.isAuthenticated)
        try await complete(auth, try callback(auth)).get()
        #expect(auth.signedInEmail == provider.profileEmail)
        #expect(auth.accessToken == "candidate-access")
        #expect(auth.applicationSessionToken == nil)
        #expect(auth.workspaceSessionProof == nil)
        let profile: GoogleUserProfile = try await withCheckedThrowingContinuation { continuation in
            auth.validateSignedInDomain { continuation.resume(with: $0) }
        }
        #expect(profile.email == provider.profileEmail)
    }

    @Test func firstLoginStillRejectsAnUnapprovedHostedDomain() async throws {
        let identity = Identity(bootstrap: true), provider = Provider()
        provider.profileEmail = "fixture@unapproved.invalid"
        provider.profileDomain = "unapproved.invalid"
        let auth = manager(identity, provider)
        auth.signOut()
        let result = await complete(auth, try callback(auth))
        guard case .failure(let error) = result, let authError = error as? GoogleAuthError,
              case .domainNotAllowed = authError else {
            Issue.record("Unapproved Google domain accepted"); return
        }
        #expect(auth.accessToken == nil)
        #expect(auth.signedInEmail == nil)
        #expect(auth.applicationSessionToken == nil)
    }
}
