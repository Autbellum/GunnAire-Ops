// GoogleAuthManager.swift
// Handles OAuth 2.0 login for Google
import Foundation
import AuthenticationServices
import Combine

final class GoogleAuthManager: NSObject, ObservableObject {
    static let shared = GoogleAuthManager()

    @Published private(set) var isAuthenticated: Bool = false
    @Published private(set) var accessToken: String?
    @Published private(set) var refreshToken: String?
    @Published private(set) var idToken: String?
    @Published private(set) var tokenExpiry: Date?
    private var activeAuthSession: ASWebAuthenticationSession?
    private var pendingOAuthState: String?

    func startSignIn(presentationContext: ASWebAuthenticationPresentationContextProviding, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let authURL = makeAuthURL() else {
            completion(.failure(GoogleAuthError.invalidAuthURL))
            return
        }
        let session = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: URL(string: Config.Google.redirectURI)?.scheme
        ) { [weak self] callbackURL, error in
            defer { self?.activeAuthSession = nil }
            guard let self = self, let callbackURL = callbackURL else {
                completion(.failure(error ?? GoogleAuthError.unknown))
                return
            }
            self.handleAuthCallback(url: callbackURL, completion: completion)
        }
        session.presentationContextProvider = presentationContext
        session.prefersEphemeralWebBrowserSession = true
        activeAuthSession = session
        if !session.start() {
            activeAuthSession = nil
            completion(.failure(GoogleAuthError.unknown))
        }
    }

    private func makeAuthURL() -> URL? {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        let scopes = Config.Google.scopes.joined(separator: " ")
        let state = UUID().uuidString
        pendingOAuthState = state
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: Config.Google.clientID),
            URLQueryItem(name: "redirect_uri", value: Config.Google.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state)
        ]
        return components?.url
    }

    private func handleAuthCallback(url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else {
            completion(.failure(GoogleAuthError.missingAuthCode))
            return
        }
        guard let state = components.queryItems?.first(where: { $0.name == "state" })?.value,
              state == pendingOAuthState else {
            completion(.failure(GoogleAuthError.invalidState))
            return
        }
        pendingOAuthState = nil
        isAuthenticated = true
        completion(.success(()))
    }
}

enum GoogleAuthError: Error, LocalizedError {
    case invalidAuthURL, missingAuthCode, invalidState, unknown
    var errorDescription: String? {
        switch self {
        case .invalidAuthURL: return "Could not build Google authorization URL."
        case .missingAuthCode: return "Authorization code was not returned."
        case .invalidState: return "OAuth state validation failed."
        case .unknown: return "An unknown error occurred."
        }
    }
}
