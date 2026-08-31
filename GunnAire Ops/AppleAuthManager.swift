import AuthenticationServices
import Combine
import Foundation
import Security

struct GunnAireApplicationSession: Codable, Equatable {
    let token: String
    let expiresAt: String
    let email: String
    let appleUserIdentifier: String
}

enum AppleAuthError: LocalizedError {
    case canceled
    case invalidCredential
    case missingIdentityToken
    case missingNonce
    case identityMismatch
    case sessionStorageFailed

    var errorDescription: String? {
        switch self {
        case .canceled:
            return "Sign in with Apple was canceled."
        case .invalidCredential:
            return "Apple did not return a usable sign-in credential."
        case .missingIdentityToken:
            return "Apple did not return an identity token. Please try again."
        case .missingNonce:
            return "The Apple sign-in request could not be verified. Please try again."
        case .identityMismatch:
            return "Apple returned an identity that did not match the verified business session."
        case .sessionStorageFailed:
            return "The verified Apple session could not be secured on this device."
        }
    }
}

/// Owns the app session created after the backend verifies a Sign in with Apple
/// identity token. The Apple identity token itself is never persisted.
final class AppleAuthManager: ObservableObject {
    static let shared = AppleAuthManager()

    @Published private(set) var isAuthenticated = false
    @Published private(set) var signedInEmail: String?
    @Published private(set) var appleUserIdentifier: String?

    private(set) var sessionToken: String?
    private var pendingNonce: String?

    private let keychainAccount = "GunnAireAppleApplicationSession"
    private static let businessEmailStorageKey = "SignedInBusinessEmail"

    private init() {
        loadSession()
    }

    func prepare(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.makeNonce()
        pendingNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = nonce
    }

    @MainActor
    func complete(_ result: Result<ASAuthorization, Error>) async throws -> BackendAppUserRecord {
        let authorization: ASAuthorization
        switch result {
        case .success(let value):
            authorization = value
        case .failure(let error):
            if let authorizationError = error as? ASAuthorizationError,
               authorizationError.code == .canceled {
                throw AppleAuthError.canceled
            }
            throw error
        }

        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            throw AppleAuthError.invalidCredential
        }
        guard let identityTokenData = credential.identityToken,
              let identityToken = String(data: identityTokenData, encoding: .utf8),
              !identityToken.isEmpty else {
            throw AppleAuthError.missingIdentityToken
        }
        guard let nonce = pendingNonce, !nonce.isEmpty else {
            throw AppleAuthError.missingNonce
        }
        pendingNonce = nil

        let response = try await GunnAireBackendService.exchangeAppleIdentity(
            identityToken: identityToken,
            nonce: nonce
        )
        guard response.providerSubject == credential.user else {
            throw AppleAuthError.identityMismatch
        }

        let normalizedEmail = AppAccess.normalizedEmail(response.user.email)
        guard !normalizedEmail.isEmpty else {
            throw AppleAuthError.invalidCredential
        }
        let stored = GunnAireApplicationSession(
            token: response.sessionToken,
            expiresAt: response.expiresAt,
            email: normalizedEmail,
            appleUserIdentifier: credential.user
        )
        do {
            try KeychainStore.saveCodable(stored, account: keychainAccount)
        } catch {
            try? await GunnAireBackendService.revokeApplicationSession(response.sessionToken)
            throw AppleAuthError.sessionStorageFailed
        }
        apply(stored)
        return response.user
    }

    func signOut() {
        let tokenToRevoke = sessionToken
        clearLocalSession()
        if let tokenToRevoke, !tokenToRevoke.isEmpty {
            Task {
                try? await GunnAireBackendService.revokeApplicationSession(tokenToRevoke)
            }
        }
    }

    func validateCredentialState() async -> Bool {
        guard let userIdentifier = appleUserIdentifier, !userIdentifier.isEmpty else {
            return false
        }
        let state: ASAuthorizationAppleIDProvider.CredentialState = await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userIdentifier) { state, _ in
                continuation.resume(returning: state)
            }
        }
        switch state {
        case .authorized:
            return true
        case .revoked, .notFound, .transferred:
            clearLocalSession()
            return false
        @unknown default:
            return false
        }
    }

    private func loadSession() {
        guard let stored = try? KeychainStore.loadCodable(
            GunnAireApplicationSession.self,
            account: keychainAccount
        ), Self.isFuture(stored.expiresAt) else {
            clearLocalSession()
            return
        }
        apply(stored)
    }

    private func apply(_ session: GunnAireApplicationSession) {
        sessionToken = session.token
        signedInEmail = AppAccess.normalizedEmail(session.email)
        appleUserIdentifier = session.appleUserIdentifier
        isAuthenticated = !session.token.isEmpty && signedInEmail?.isEmpty == false
        if let signedInEmail, !signedInEmail.isEmpty {
            UserDefaults.standard.set(signedInEmail, forKey: Self.businessEmailStorageKey)
        }
    }

    private func clearLocalSession() {
        let previousEmail = signedInEmail
        sessionToken = nil
        signedInEmail = nil
        appleUserIdentifier = nil
        pendingNonce = nil
        isAuthenticated = false
        try? KeychainStore.remove(account: keychainAccount)
        if UserDefaults.standard.string(forKey: Self.businessEmailStorageKey) == previousEmail {
            UserDefaults.standard.removeObject(forKey: Self.businessEmailStorageKey)
        }
    }

    private static func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString + UUID().uuidString
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func isFuture(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        return parsed.map { $0 > Date() } ?? false
    }
}

enum AppIdentity {
    static var currentEmail: String? {
        #if DEBUG
        // UI-test roles must be deterministic even when the simulator clone
        // contains a previously persisted Apple or Google session.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-uiTestAuthenticatedAdmin") {
            return AppAccess.primaryAdminEmail
        }
        if arguments.contains("-uiTestAuthenticatedAccounting") {
            return GunnAireUITestIdentity.accountingEmail
        }
        if arguments.contains("-uiTestAuthenticatedTechnician") {
            return GunnAireUITestIdentity.technicianEmail
        }
        if arguments.contains("-uiTestAuthenticatedStandard") {
            return GunnAireUITestIdentity.standardEmail
        }
        if arguments.contains("-appStoreScreenshotFixtures") {
            return AppAccess.primaryAdminEmail
        }
        #endif

        let candidates = [
            AppleAuthManager.shared.signedInEmail,
            GoogleAuthManager.shared.signedInEmail,
            UserDefaults.standard.string(forKey: "SignedInBusinessEmail"),
            UserDefaults.standard.string(forKey: "SignedInGoogleEmail")
        ]
        return candidates
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .first(where: { !$0.isEmpty })
    }

    static var hasAuthenticatedProvider: Bool {
        AppleAuthManager.shared.isAuthenticated || GoogleAuthManager.shared.isAuthenticated
    }
}
