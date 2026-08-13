// GoogleAuthManager.swift
// Handles OAuth 2.0 login and basic Google API access.
import Foundation
import AuthenticationServices
import Combine
import CryptoKit

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
    let accessRole: String?

    var normalizedID: String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isWritable: Bool {
        switch accessRole?.lowercased() {
        case "owner", "writer":
            return true
        default:
            return id == "primary"
        }
    }

    var normalizedSummary: String {
        summary?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    var displayLabel: String {
        if id == "primary" {
            if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "\(summary) (Primary)"
            }
            return "Primary Calendar"
        }
        if let summary,
           !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           normalizedSummary != normalizedID {
            return "\(summary) (\(id))"
        }
        return id
    }

    func matchesTechnicianEmail(_ email: String?) -> Bool {
        let normalizedEmail = AppAccess.normalizedEmail(email)
        guard !normalizedEmail.isEmpty else { return false }
        return normalizedID == normalizedEmail || normalizedSummary == normalizedEmail
    }
}

struct GoogleCalendarEventsResponse: Codable {
    let items: [GoogleCalendarEvent]
}

struct GoogleCalendarEvent: Codable, Identifiable {
    let id: String
    let summary: String?
    let description: String?
    let location: String?
    let htmlLink: String?
    let attendees: [GoogleCalendarAttendee]?
    let extendedProperties: GoogleCalendarExtendedProperties?
    let start: GoogleCalendarEventDate
    let end: GoogleCalendarEventDate

    var isManagedByGunnAire: Bool {
        let properties = extendedProperties?.privateProperties
        return properties?["gunnaireManaged"] == "true" &&
            properties?["gunnaireManagedVersion"] == "3" &&
            properties?["gunnaireOrigin"] == "ios-app"
    }
}

struct GoogleCalendarAttendee: Codable {
    let email: String?
    let displayName: String?
    let selfAttendee: Bool?
    let resource: Bool?

    private enum CodingKeys: String, CodingKey {
        case email
        case displayName
        case selfAttendee = "self"
        case resource
    }
}

struct GoogleCalendarEventDate: Codable {
    let date: String?
    let dateTime: String?
    let timeZone: String?
}

struct GoogleWritableCalendarEventDate: Codable {
    let dateTime: String
    let timeZone: String
}

struct GoogleWritableCalendarEvent: Codable {
    let summary: String
    let description: String?
    let location: String?
    let start: GoogleWritableCalendarEventDate
    let end: GoogleWritableCalendarEventDate
    let attendees: [GoogleWritableCalendarAttendee]?
    let extendedProperties: GoogleCalendarExtendedProperties?
}

struct GoogleCalendarEventPatch: Codable {
    let start: GoogleWritableCalendarEventDate?
    let end: GoogleWritableCalendarEventDate?

    private enum CodingKeys: String, CodingKey {
        case start
        case end
    }
}

struct GoogleCalendarExtendedProperties: Codable {
    let privateProperties: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case privateProperties = "private"
    }
}

struct GoogleWritableCalendarAttendee: Codable {
    let email: String
    let displayName: String?
}

struct GmailMessageListResponse: Codable {
    let messages: [GmailMessageReference]?
    let nextPageToken: String?
}

struct GmailMessageReference: Codable, Identifiable {
    let id: String
    let threadId: String
}

struct GmailMessageDetail: Codable, Identifiable {
    let id: String
    let threadId: String?
    let labelIds: [String]?
    let snippet: String?
    let internalDate: String?
    let payload: GmailMessagePayload?
}

struct GmailMessagePayload: Codable {
    let headers: [GmailMessageHeader]?
    let mimeType: String?
    let body: GmailMessageBody?
    let parts: [GmailMessagePayload]?
    let filename: String?
}

struct GmailMessageHeader: Codable {
    let name: String
    let value: String
}

struct GmailMessageBody: Codable {
    let data: String?
    let size: Int?
}

struct GmailSendRequest: Codable {
    let raw: String
    let threadId: String?
}

struct GmailAttachment: Identifiable {
    let id = UUID()
    let fileName: String
    let mimeType: String
    let data: Data
}

struct GmailThreadResponse: Codable {
    let id: String
    let messages: [GmailMessageDetail]
}

final class GoogleAuthManager: NSObject, ObservableObject {
    static let shared = GoogleAuthManager()
    static var callbackScheme: String {
        if !Config.Google.reversedClientID.hasPrefix("YOUR_") {
            return Config.Google.reversedClientID
        }
        let clientID = Config.Google.clientID
        guard clientID.hasSuffix(".apps.googleusercontent.com") else {
            return "com.googleusercontent.apps"
        }
        return "com.googleusercontent.apps.\(clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: ""))"
    }

    static var redirectURI: String {
        "\(callbackScheme):/oauth2redirect"
    }

    @Published private(set) var isAuthenticated: Bool = false
    @Published private(set) var accessToken: String?
    @Published private(set) var refreshToken: String?
    @Published private(set) var idToken: String?
    @Published private(set) var tokenExpiry: Date?
    @Published private(set) var signedInEmail: String?

    private static let signedInEmailStorageKey = "SignedInGoogleEmail"

    private var activeAuthSession: ASWebAuthenticationSession?
    private var pendingOAuthState: String?
    private var pendingCodeVerifier: String?

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
        UserDefaults.standard.removeObject(forKey: Self.signedInEmailStorageKey)
    }

    func startSignIn(presentationContext: ASWebAuthenticationPresentationContextProviding, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !Config.Google.clientID.hasPrefix("YOUR_") else {
            completion(.failure(GoogleAuthError.missingConfiguration))
            return
        }
        guard !Self.callbackScheme.hasPrefix("YOUR_"), Self.callbackScheme.contains(Config.Google.clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")) else {
            completion(.failure(GoogleAuthError.invalidNativeClientConfiguration))
            return
        }
        guard let authURL = makeAuthURL() else {
            completion(.failure(GoogleAuthError.invalidAuthURL))
            return
        }
        guard !Self.callbackScheme.isEmpty else {
            completion(.failure(GoogleAuthError.invalidRedirectURI(Self.redirectURI)))
            return
        }
        guard isCallbackSchemeRegistered(Self.callbackScheme) else {
            completion(.failure(GoogleAuthError.callbackSchemeNotRegistered("\(Self.callbackScheme). Registered schemes: \(registeredCallbackSchemes().joined(separator: ", "))")))
            return
        }

        let session = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: Self.callbackScheme
        ) { [weak self] callbackURL, error in
            defer { self?.activeAuthSession = nil }
            if let error = error as? ASWebAuthenticationSessionError,
               error.code == .canceledLogin {
                completion(.failure(GoogleAuthError.authenticationSessionCanceled))
                return
            }
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
        let codeVerifier = Self.makeCodeVerifier()
        pendingOAuthState = state
        pendingCodeVerifier = codeVerifier
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: Config.Google.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: codeVerifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "hd", value: Config.Google.allowedHostedDomain),
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
        guard let codeVerifier = pendingCodeVerifier else {
            completion(.failure(GoogleAuthError.invalidState))
            return
        }
        pendingCodeVerifier = nil

        exchangeAuthorizationCode(code: code, codeVerifier: codeVerifier) { result in
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

    private func exchangeAuthorizationCode(code: String, codeVerifier: String, completion: @escaping (Result<GoogleOAuthTokens, Error>) -> Void) {
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
            "redirect_uri": Self.redirectURI,
            "code_verifier": codeVerifier,
            "grant_type": "authorization_code"
        ]
        request.httpBody = params.percentEncoded().data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, response, error in
            Task { @MainActor in
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
            }
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
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ].percentEncoded().data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, response, error in
            Task { @MainActor in
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
                self.storeTokens(merged)
                completion(.success(()))
            }
        }.resume()
    }

    func fetchUserProfile(completion: @escaping (Result<GoogleUserProfile, Error>) -> Void) {
        authorizedGET("https://www.googleapis.com/oauth2/v3/userinfo") { (result: Result<GoogleUserProfile, Error>) in
            switch result {
            case .success(let profile):
                DispatchQueue.main.async {
                    self.rememberSignedInEmail(profile.email)
                    completion(.success(profile))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
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
                    self.rememberSignedInEmail(profile.email)
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
        var queryItems = [
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxAttendees", value: "20")
        ]
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

    func createCalendarEvent(calendarID: String = "primary", event: GoogleWritableCalendarEvent, completion: @escaping (Result<GoogleCalendarEvent, Error>) -> Void) {
        let encodedCalendarID = calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarID
        guard let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendarID)/events") else {
            completion(.failure(GoogleAuthError.invalidEndpoint))
            return
        }
        authorizedJSONRequest(url: url, method: "POST", body: event, completion: completion)
    }

    @available(*, unavailable, message: "Use patchCalendarEvent with the schedule-only GoogleCalendarEventPatch so existing Google details are preserved.")
    func updateCalendarEvent(calendarID: String = "primary", eventID: String, event: GoogleWritableCalendarEvent, completion: @escaping (Result<GoogleCalendarEvent, Error>) -> Void) {
        let encodedCalendarID = calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarID
        let encodedEventID = eventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventID
        guard let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendarID)/events/\(encodedEventID)") else {
            completion(.failure(GoogleAuthError.invalidEndpoint))
            return
        }
        authorizedJSONRequest(url: url, method: "PATCH", body: event, completion: completion)
    }

    func patchCalendarEvent(calendarID: String = "primary", eventID: String, patch: GoogleCalendarEventPatch, completion: @escaping (Result<GoogleCalendarEvent, Error>) -> Void) {
        let encodedCalendarID = calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarID
        let encodedEventID = eventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventID
        guard let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendarID)/events/\(encodedEventID)") else {
            completion(.failure(GoogleAuthError.invalidEndpoint))
            return
        }
        authorizedJSONRequest(url: url, method: "PATCH", body: patch, completion: completion)
    }

    func deleteCalendarEvent(calendarID: String = "primary", eventID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let encodedCalendarID = calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarID
        let encodedEventID = eventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventID
        guard let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendarID)/events/\(encodedEventID)") else {
            completion(.failure(GoogleAuthError.invalidEndpoint))
            return
        }
        authorizedEmptyRequest(url: url, method: "DELETE", completion: completion)
    }

    func fetchGmailMessages(maxResults: Int = 25, query: String? = nil, completion: @escaping (Result<[GmailMessageDetail], Error>) -> Void) {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")
        var queryItems = [URLQueryItem(name: "maxResults", value: String(maxResults))]
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "q", value: query))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else {
            completion(.failure(GoogleAuthError.invalidEndpoint))
            return
        }

        authorizedGET(url.absoluteString) { (result: Result<GmailMessageListResponse, Error>) in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let response):
                let references = response.messages ?? []
                self.fetchGmailMessageDetails(references: references, completion: completion)
            }
        }
    }

    func fetchGmailMessage(id: String, completion: @escaping (Result<GmailMessageDetail, Error>) -> Void) {
        let escapedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(escapedID)?format=full"
        authorizedGET(url, completion: completion)
    }

    func fetchGmailThread(id: String, completion: @escaping (Result<[GmailMessageDetail], Error>) -> Void) {
        let escapedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let url = "https://gmail.googleapis.com/gmail/v1/users/me/threads/\(escapedID)?format=full"
        authorizedGET(url) { (result: Result<GmailThreadResponse, Error>) in
            switch result {
            case .success(let response):
                completion(.success(response.messages))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func sendGmailMessage(
        to: String,
        subject: String,
        body: String,
        threadID: String? = nil,
        attachments: [GmailAttachment] = [],
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let message = Self.makeGmailRawMessage(
            to: to,
            subject: subject,
            body: body,
            attachments: attachments
        )

        guard let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send") else {
            completion(.failure(GoogleAuthError.invalidEndpoint))
            return
        }

        let payload = GmailSendRequest(raw: Data(message.utf8).base64URLEncodedString(), threadId: threadID)
        authorizedJSONRequest(url: url, method: "POST", body: payload) { (result: Result<GmailMessageReference, Error>) in
            switch result {
            case .success:
                completion(.success(()))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    static func makeGmailRawMessage(
        to: String,
        subject: String,
        body: String,
        attachments: [GmailAttachment] = []
    ) -> String {
        let escapedSubject = subject.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        guard !attachments.isEmpty else {
            return [
                "To: \(to)",
                "Subject: \(escapedSubject)",
                "Content-Type: text/plain; charset=utf-8",
                "",
                body
            ].joined(separator: "\r\n")
        }

        let boundary = "gunnaire-\(UUID().uuidString)"
        var lines: [String] = [
            "To: \(to)",
            "Subject: \(escapedSubject)",
            "MIME-Version: 1.0",
            "Content-Type: multipart/mixed; boundary=\"\(boundary)\"",
            "",
            "--\(boundary)",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: 7bit",
            "",
            body
        ]

        for attachment in attachments {
            let safeFileName = attachment.fileName
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            lines.append(contentsOf: [
                "--\(boundary)",
                "Content-Type: \(attachment.mimeType); name=\"\(safeFileName)\"",
                "Content-Disposition: attachment; filename=\"\(safeFileName)\"",
                "Content-Transfer-Encoding: base64",
                "",
                attachment.data.base64EncodedString(options: [.lineLength76Characters])
            ])
        }

        lines.append("--\(boundary)--")
        return lines.joined(separator: "\r\n")
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

    private func fetchGmailMessageDetails(references: [GmailMessageReference], completion: @escaping (Result<[GmailMessageDetail], Error>) -> Void) {
        guard !references.isEmpty else {
            completion(.success([]))
            return
        }

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "GmailMessageDetails")
        var details: [GmailMessageDetail] = []
        var firstError: Error?

        for reference in references {
            group.enter()
            let escapedID = reference.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? reference.id
            let url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(escapedID)?format=metadata&metadataHeaders=From&metadataHeaders=Subject&metadataHeaders=Date&metadataHeaders=To"
            authorizedGET(url) { (result: Result<GmailMessageDetail, Error>) in
                queue.async {
                    switch result {
                    case .success(let detail):
                        details.append(detail)
                    case .failure(let error):
                        if firstError == nil {
                            firstError = error
                        }
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            if let firstError {
                completion(.failure(firstError))
            } else {
                let sorted = details.sorted { ($0.internalDate ?? "") > ($1.internalDate ?? "") }
                completion(.success(sorted))
            }
        }
    }

    private func authorizedJSONRequest<T: Decodable, Body: Encodable>(
        url: URL,
        method: String,
        body: Body,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        refreshTokensIfNeeded { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                guard let token = self.accessToken else {
                    completion(.failure(GoogleAuthError.notAuthenticated))
                    return
                }
                var request = URLRequest(url: url)
                request.httpMethod = method
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                guard let data = try? JSONEncoder().encode(body) else {
                    completion(.failure(GoogleAuthError.decoding))
                    return
                }
                request.httpBody = data

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

    private func authorizedEmptyRequest(
        url: URL,
        method: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        refreshTokensIfNeeded { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                guard let token = self.accessToken else {
                    completion(.failure(GoogleAuthError.notAuthenticated))
                    return
                }
                var request = URLRequest(url: url)
                request.httpMethod = method
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
                    guard (200...299).contains(http.statusCode) else {
                        completion(.failure(self.parseProviderError(data: data ?? Data(), fallbackStatus: http.statusCode)))
                        return
                    }
                    completion(.success(()))
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
        let restoredEmail = UserDefaults.standard.string(forKey: Self.signedInEmailStorageKey)
            ?? Self.extractEmail(fromIDToken: tokens.idToken)
        rememberSignedInEmail(restoredEmail)
    }

    private func rememberSignedInEmail(_ email: String?) {
        let normalizedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        signedInEmail = normalizedEmail
        if let normalizedEmail, !normalizedEmail.isEmpty {
            UserDefaults.standard.set(normalizedEmail, forKey: Self.signedInEmailStorageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.signedInEmailStorageKey)
        }
    }

    private static func extractEmail(fromIDToken token: String?) -> String? {
        guard let token else { return nil }
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder != 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard
            let data = Data(base64Encoded: payload),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object["email"] as? String
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
        return configured.contains { registeredScheme in
            let resolvedScheme = Self.resolvedInfoPlistScheme(registeredScheme)
            return resolvedScheme.caseInsensitiveCompare(scheme) == .orderedSame
        }
    }

    private func registeredCallbackSchemes() -> [String] {
        guard let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] else {
            return []
        }
        return urlTypes
            .compactMap { $0["CFBundleURLSchemes"] as? [String] }
            .flatMap { $0 }
            .map { Self.resolvedInfoPlistScheme($0) }
    }

    private static func resolvedInfoPlistScheme(_ scheme: String) -> String {
        if scheme == "$(GOOGLE_CALLBACK_SCHEME)" || scheme == "$(GOOGLE_REVERSED_CLIENT_ID)" {
            return callbackScheme
        }
        return scheme
    }

    private static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

enum GoogleAuthError: Error, LocalizedError {
    case invalidAuthURL
    case missingAuthCode
    case invalidState
    case missingConfiguration
    case invalidNativeClientConfiguration
    case authenticationSessionCanceled
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
        case .invalidNativeClientConfiguration: return "Google iOS client configuration is invalid. Check the client ID and reversed client ID."
        case .authenticationSessionCanceled: return "Google sign-in was canceled."
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

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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
