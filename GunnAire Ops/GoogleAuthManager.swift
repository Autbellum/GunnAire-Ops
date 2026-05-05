// GoogleAuthManager.swift
// Handles OAuth 2.0 login and basic Google API access.
import Foundation
import AuthenticationServices
import Combine

struct GoogleOAuthTokens: Codable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiration: Date
}

struct GoogleUserProfile: Codable {
    let sub: String
    let email: String?
    let hd: String?
    let name: String?
    let picture: String?
}

struct GoogleCalendarListResponse: Codable {
    let items: [GoogleCalendar]
}

struct GoogleCalendar: Codable, Identifiable {
    let id: String
    let summary: String?
    let timeZone: String?
}

struct GoogleCalendarEventsResponse: Codable {
    let items: [GoogleCalendarEvent]
}

struct GoogleCalendarEvent: Codable, Identifiable {
    let id: String
    let summary: String?
    let description: String?
    let htmlLink: String?
    let start: GoogleCalendarEventDate
    let end: GoogleCalendarEventDate
}

struct GoogleCalendarEventDate: Codable {
    let date: String?
    let dateTime: String?
}

final class GoogleAuthManager: NSObject, ObservableObject {
    static let shared = GoogleAuthManager()

    @Published private(set) var isAuthenticated: Bool = false
    @Published private(set) var accessToken: String?
    @Published private(set) var refreshToken: String?
    @Published private(set) var idToken: String?
    @Published private(set) var tokenExpiry: Date?
    @Published private(set) var signedInEmail: String?

    private var activeAuthSession: ASWebAuthenticationSession?
    private var pendingOAuthState: String?

    private let tokenStorageKey = "GoogleOAuthTokens"
    private let keychainAccount = "GoogleOAuthTokens"

    private override init() {
        super.init()
        loadTokens()
    }

    func signOut() {
        isAuthenticated = false
        accessToken = nil
        refreshToken = nil
        idToken = nil
        tokenExpiry = nil
        signedInEmail = nil
        pendingOAuthState = nil
        activeAuthSession = nil
        try? KeychainStore.remove(account: keychainAccount)
        UserDefaults.standard.removeObject(forKey: tokenStorageKey)
        UserDefaults.standard.removeObject(forKey: "SignedInGoogleEmail")
    }

    func startSignIn(presentationContext: ASWebAuthenticationPresentationContextProviding, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !Config.Google.clientID.hasPrefix("YOUR_"), !Config.Google.clientSecret.hasPrefix("YOUR_"), !Config.Google.redirectURI.hasPrefix("YOUR_") else {
            completion(.failure(GoogleAuthError.missingConfiguration))
            return
        }
        guard let authURL = makeAuthURL() else {
            completion(.failure(GoogleAuthError.invalidAuthURL))
            return
        }
        let configuredCallbackScheme = Config.Google.callbackScheme
        let callbackScheme = configuredCallbackScheme.isEmpty ? (URL(string: Config.Google.redirectURI)?.scheme ?? "") : configuredCallbackScheme
        guard !callbackScheme.isEmpty else {
            completion(.failure(GoogleAuthError.invalidRedirectURI(Config.Google.redirectURI)))
            return
        }
        guard isCallbackSchemeRegistered(callbackScheme) else {
            completion(.failure(GoogleAuthError.callbackSchemeNotRegistered(callbackScheme)))
            return
        }

        let session = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: callbackScheme
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
        var components = URLComponents(string: Config.Google.authorizationEndpoint)
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
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            completion(.failure(GoogleAuthError.unknown))
            return
        }

        if let oauthError = components.queryItems?.first(where: { $0.name == "error" })?.value {
            let description = components.queryItems?.first(where: { $0.name == "error_description" })?.value
            completion(.failure(GoogleAuthError.providerError(oauthError, description)))
            return
        }

        guard
            let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
            !code.isEmpty
        else {
            completion(.failure(GoogleAuthError.missingAuthCode))
            return
        }
        guard let state = components.queryItems?.first(where: { $0.name == "state" })?.value,
              state == pendingOAuthState else {
            completion(.failure(GoogleAuthError.invalidState))
            return
        }
        pendingOAuthState = nil

        exchangeAuthorizationCode(code: code) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let tokens):
                    self.storeTokens(tokens)
                    completion(.success(()))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    private func exchangeAuthorizationCode(code: String, completion: @escaping (Result<GoogleOAuthTokens, Error>) -> Void) {
        guard let url = URL(string: Config.Google.tokenEndpoint) else {
            completion(.failure(GoogleAuthError.invalidEndpoint))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params = [
            "code": code,
            "client_id": Config.Google.clientID,
            "client_secret": Config.Google.clientSecret,
            "redirect_uri": Config.Google.redirectURI,
            "grant_type": "authorization_code"
        ]
        request.httpBody = params.percentEncoded().data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(GoogleAuthError.unknown))
                return
            }
            guard let data else {
                completion(.failure(GoogleAuthError.noData))
                return
            }
            guard (200...299).contains(http.statusCode) else {
                completion(.failure(self.parseProviderError(data: data, fallbackStatus: http.statusCode)))
                return
            }
            guard
                let payload = try? JSONDecoder().decode(GoogleTokenResponse.self, from: data)
            else {
                completion(.failure(GoogleAuthError.decoding))
                return
            }
            let tokens = GoogleOAuthTokens(
                accessToken: payload.access_token,
                refreshToken: payload.refresh_token,
                idToken: payload.id_token,
                expiration: Date().addingTimeInterval(payload.expires_in)
            )
            completion(.success(tokens))
        }.resume()
    }

    func refreshTokensIfNeeded(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let expiry = tokenExpiry else {
            completion(.failure(GoogleAuthError.noRefreshToken))
            return
        }
        if expiry > Date().addingTimeInterval(60), accessToken != nil {
            completion(.success(()))
            return
        }
        guard let refreshToken else {
            completion(.failure(GoogleAuthError.noRefreshToken))
            return
        }
        refreshAccessToken(refreshToken: refreshToken, completion: completion)
    }

    private func refreshAccessToken(refreshToken: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: Config.Google.tokenEndpoint) else {
            completion(.failure(GoogleAuthError.invalidEndpoint))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = [
            "client_id": Config.Google.clientID,
            "client_secret": Config.Google.clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ].percentEncoded().data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(GoogleAuthError.unknown))
                return
            }
            guard let data else {
                completion(.failure(GoogleAuthError.noData))
                return
            }
            guard (200...299).contains(http.statusCode) else {
                completion(.failure(self.parseProviderError(data: data, fallbackStatus: http.statusCode)))
                return
            }
            guard let payload = try? JSONDecoder().decode(GoogleRefreshResponse.self, from: data) else {
                completion(.failure(GoogleAuthError.decoding))
                return
            }

            let merged = GoogleOAuthTokens(
                accessToken: payload.access_token,
                refreshToken: self.refreshToken,
                idToken: payload.id_token ?? self.idToken,
                expiration: Date().addingTimeInterval(payload.expires_in)
            )
            DispatchQueue.main.async {
                self.storeTokens(merged)
                completion(.success(()))
            }
        }.resume()
    }

    func fetchUserProfile(completion: @escaping (Result<GoogleUserProfile, Error>) -> Void) {
        authorizedGET("https://www.googleapis.com/oauth2/v3/userinfo", completion: completion)
    }

    func validateSignedInDomain(completion: @escaping (Result<GoogleUserProfile, Error>) -> Void) {
        fetchUserProfile { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let profile):
                    guard self.isAllowed(profile: profile) else {
                        self.signOut()
                        completion(.failure(GoogleAuthError.domainNotAllowed(Config.Google.allowedHostedDomain)))
                        return
                    }
                    self.signedInEmail = profile.email
                    if let email = profile.email {
                        UserDefaults.standard.set(email, forKey: "SignedInGoogleEmail")
                    }
                    completion(.success(profile))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    func fetchCalendars(completion: @escaping (Result<[GoogleCalendar], Error>) -> Void) {
        authorizedGET("https://www.googleapis.com/calendar/v3/users/me/calendarList") { (result: Result<GoogleCalendarListResponse, Error>) in
            switch result {
            case .success(let response): completion(.success(response.items))
            case .failure(let error): completion(.failure(error))
            }
        }
    }

    func fetchCalendarEvents(calendarID: String, timeMin: Date? = nil, timeMax: Date? = nil, completion: @escaping (Result<[GoogleCalendarEvent], Error>) -> Void) {
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarID)/events")
        var queryItems = [URLQueryItem(name: "singleEvents", value: "true"), URLQueryItem(name: "orderBy", value: "startTime")]
        let iso = ISO8601DateFormatter()
        if let timeMin {
            queryItems.append(URLQueryItem(name: "timeMin", value: iso.string(from: timeMin)))
        }
        if let timeMax {
            queryItems.append(URLQueryItem(name: "timeMax", value: iso.string(from: timeMax)))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else {
            completion(.failure(GoogleAuthError.invalidEndpoint))
            return
        }
        authorizedGET(url.absoluteString) { (result: Result<GoogleCalendarEventsResponse, Error>) in
            switch result {
            case .success(let response): completion(.success(response.items))
            case .failure(let error): completion(.failure(error))
            }
        }
    }

    private func authorizedGET<T: Decodable>(_ absoluteURL: String, completion: @escaping (Result<T, Error>) -> Void) {
        refreshTokensIfNeeded { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                guard let token = self.accessToken, let url = URL(string: absoluteURL) else {
                    completion(.failure(GoogleAuthError.notAuthenticated))
                    return
                }
                var request = URLRequest(url: url)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Accept")

                URLSession.shared.dataTask(with: request) { data, response, error in
                    if let error {
                        completion(.failure(error))
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        completion(.failure(GoogleAuthError.unknown))
                        return
                    }
                    guard let data else {
                        completion(.failure(GoogleAuthError.noData))
                        return
                    }
                    guard (200...299).contains(http.statusCode) else {
                        completion(.failure(self.parseProviderError(data: data, fallbackStatus: http.statusCode)))
                        return
                    }
                    guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
                        completion(.failure(GoogleAuthError.decoding))
                        return
                    }
                    completion(.success(decoded))
                }.resume()
            }
        }
    }

    private func loadTokens() {
        if let stored = try? KeychainStore.loadCodable(GoogleOAuthTokens.self, account: keychainAccount) {
            applyTokens(stored)
            return
        }

        // Backward-compat migration from UserDefaults.
        guard let data = UserDefaults.standard.data(forKey: tokenStorageKey),
              let stored = try? JSONDecoder().decode(GoogleOAuthTokens.self, from: data) else {
            return
        }
        try? KeychainStore.saveCodable(stored, account: keychainAccount)
        applyTokens(stored)
    }

    private func storeTokens(_ tokens: GoogleOAuthTokens) {
        try? KeychainStore.saveCodable(tokens, account: keychainAccount)
        if let encoded = try? JSONEncoder().encode(tokens) {
            UserDefaults.standard.set(encoded, forKey: tokenStorageKey)
        }
        applyTokens(tokens)
    }

    private func applyTokens(_ tokens: GoogleOAuthTokens) {
        accessToken = tokens.accessToken
        refreshToken = tokens.refreshToken
        idToken = tokens.idToken
        tokenExpiry = tokens.expiration
        isAuthenticated = true
        signedInEmail = UserDefaults.standard.string(forKey: "SignedInGoogleEmail")
    }

    private func isAllowed(profile: GoogleUserProfile) -> Bool {
        let allowedDomain = Config.Google.allowedHostedDomain.lowercased()
        if profile.hd?.lowercased() == allowedDomain {
            return true
        }
        guard let email = profile.email?.lowercased() else {
            return false
        }
        return email.hasSuffix("@\(allowedDomain)")
    }

    private func parseProviderError(data: Data, fallbackStatus: Int) -> GoogleAuthError {
        if let decoded = try? JSONDecoder().decode(GoogleErrorEnvelope.self, from: data) {
            return .providerError("\(decoded.error.code)", decoded.error.message)
        }
        return .http(statusCode: fallbackStatus)
    }

    private func isCallbackSchemeRegistered(_ scheme: String) -> Bool {
        guard let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] else {
            return false
        }
        let configured = urlTypes
            .compactMap { $0["CFBundleURLSchemes"] as? [String] }
            .flatMap { $0 }
        return configured.contains { $0.caseInsensitiveCompare(scheme) == .orderedSame }
    }
}

enum GoogleAuthError: Error, LocalizedError {
    case invalidAuthURL
    case missingAuthCode
    case invalidState
    case missingConfiguration
    case invalidRedirectURI(String)
    case callbackSchemeNotRegistered(String)
    case invalidEndpoint
    case notAuthenticated
    case noRefreshToken
    case noData
    case decoding
    case http(statusCode: Int)
    case providerError(String, String?)
    case domainNotAllowed(String)
    case unknown

    var errorDescription: String? {
        switch self {
        case .invalidAuthURL: return "Could not build Google authorization URL."
        case .missingAuthCode: return "Authorization code was not returned."
        case .invalidState: return "OAuth state validation failed."
        case .missingConfiguration: return "Google OAuth credentials are missing in Config/environment variables."
        case .invalidRedirectURI(let uri): return "Google redirect URI is invalid: \(uri)"
        case .callbackSchemeNotRegistered(let scheme): return "Google callback scheme '\(scheme)' is not registered in app URL Types."
        case .invalidEndpoint: return "Google endpoint is invalid."
        case .notAuthenticated: return "You are not signed in to Google."
        case .noRefreshToken: return "Google refresh token is not available."
        case .noData: return "Google returned no data."
        case .decoding: return "Google response decoding failed."
        case .http(let statusCode): return "Google request failed (HTTP \(statusCode))."
        case .providerError(let code, let description): return "Google OAuth/API error: \(code)\(description.map { " - \($0)" } ?? "")"
        case .domainNotAllowed(let domain): return "Access is restricted to \(domain) Google accounts."
        case .unknown: return "An unknown error occurred."
        }
    }
}

private struct GoogleTokenResponse: Codable {
    let access_token: String
    let expires_in: TimeInterval
    let refresh_token: String?
    let id_token: String?
}

private struct GoogleRefreshResponse: Codable {
    let access_token: String
    let expires_in: TimeInterval
    let id_token: String?
}

private struct GoogleErrorEnvelope: Codable {
    let error: GoogleErrorPayload
}

private struct GoogleErrorPayload: Codable {
    let code: Int
    let message: String
}

private extension Dictionary where Key == String, Value == String {
    func percentEncoded() -> String {
        map { key, value in
            let escapedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let escapedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(escapedKey)=\(escapedValue)"
        }
        .joined(separator: "&")
    }
}
