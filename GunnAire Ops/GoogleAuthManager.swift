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
    /// Normalized scopes that were confirmed when this token set was issued.
    /// Legacy tokens decode with nil and must reconnect before a new capability
    /// such as Drive can be used.
    let scopeSignature: String?

    init(
        accessToken: String,
        refreshToken: String?,
        idToken: String?,
        expiration: Date,
        scopeSignature: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiration = expiration
        self.scopeSignature = scopeSignature
    }

    func grants(_ scope: String) -> Bool {
        let requested = scope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !requested.isEmpty, let scopeSignature else { return false }
        return Set(scopeSignature.split(separator: "|").map(String.init)).contains(requested)
    }
}

struct GunnAireGoogleApplicationSession: Codable, Equatable {
    let token: String
    let expiresAt: String
    let email: String
    let googleUserIdentifier: String
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
    let nextPageToken: String?

    private enum CodingKeys: String, CodingKey {
        case items
        case nextPageToken
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([GoogleCalendar].self, forKey: .items) ?? []
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
    }
}

struct GoogleCalendar: Codable, Identifiable {
    let id: String
    let summary: String?
    let timeZone: String?
    let accessRole: String?
    var primary: Bool? = nil

    var normalizedID: String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isWritable: Bool {
        switch accessRole?.lowercased() {
        case "owner", "writer":
            return true
        default:
            return false
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
    let nextPageToken: String?

    private enum CodingKeys: String, CodingKey {
        case items
        case nextPageToken
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([GoogleCalendarEvent].self, forKey: .items) ?? []
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
    }
}

enum GoogleCalendarPagination {
    /// A visible failure is safer than silently returning an incomplete schedule
    /// if Google ever returns a malformed or unexpectedly unbounded page chain.
    static let maximumPageCount = 100

    static func nextURL(
        currentURL: URL,
        nextPageToken: String?,
        seenPageTokens: inout Set<String>,
        completedPageCount: Int
    ) throws -> URL? {
        guard let nextPageToken else { return nil }
        let token = nextPageToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        guard completedPageCount < maximumPageCount else {
            throw GoogleAuthError.calendarPaginationLimit
        }
        guard seenPageTokens.insert(token).inserted else {
            throw GoogleAuthError.calendarPaginationLoop
        }
        guard var components = URLComponents(url: currentURL, resolvingAgainstBaseURL: false) else {
            throw GoogleAuthError.invalidEndpoint
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "pageToken" }
        queryItems.append(URLQueryItem(name: "pageToken", value: token))
        components.queryItems = queryItems
        guard let nextURL = components.url,
              nextURL.scheme?.lowercased() == "https",
              nextURL.host?.lowercased() == "www.googleapis.com" else {
            throw GoogleAuthError.invalidEndpoint
        }
        return nextURL
    }
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
    var etag: String? = nil
    var status: String? = nil

    var isManagedByGunnAire: Bool {
        let properties = extendedProperties?.privateProperties
        return properties?["gunnaireManaged"] == "true" &&
            properties?["gunnaireManagedVersion"] == "4" &&
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
    var id: String? = nil
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

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(start, forKey: .start)
        try container.encodeIfPresent(end, forKey: .end)
    }

    static func unsafeDetailKeys(in encodedPatch: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: encodedPatch) as? [String: Any] else {
            return []
        }
        let unsafeKeys = Set(["summary", "description", "location", "attendees", "extendedProperties"])
        return object.keys
            .filter { unsafeKeys.contains($0) }
            .sorted()
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
    var attachmentId: String? = nil
}

struct GmailSendRequest: Codable {
    let raw: String
    let threadId: String?
}

struct GmailLabelModificationRequest: Codable {
    let addLabelIds: [String]
    let removeLabelIds: [String]
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

enum GoogleAccountLinkPolicy {
    static func canUseIntegration(primaryBusinessEmail: String?, googleEmail: String?) -> Bool {
        let primary = AppAccess.normalizedEmail(primaryBusinessEmail)
        let google = AppAccess.normalizedEmail(googleEmail)
        return !primary.isEmpty && primary == google
    }
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
    @Published private(set) var grantedScopeSignature: String?
    @Published private(set) var signedInEmail: String?
    @Published private(set) var applicationSessionToken: String?

    private static let signedInEmailStorageKey = "SignedInGoogleEmail"

    private var activeAuthSession: ASWebAuthenticationSession?
    private var activePresentationContext: ASWebAuthenticationPresentationContextProviding?
    private var pendingOAuthState: String?
    private var pendingCodeVerifier: String?
    private var connectionGeneration = UUID()
    private let requestTransport: WorkspaceProviderOperation.Transport
    private let persistsCredentials: Bool
    private let businessEmailProvider: () -> String?

    private let tokenStorageKey = "GoogleOAuthTokens"
    private let keychainAccount = "GoogleOAuthTokens"
    private let applicationSessionKeychainAccount = "GunnAireGoogleApplicationSession"

    private override init() {
        requestTransport = { try await URLSession.shared.data(for: $0) }
        persistsCredentials = true
        businessEmailProvider = { AppIdentity.currentEmail }
        super.init()
        loadTokens()
        loadApplicationSession()
    }

#if DEBUG
    /// Isolated request-handler fixtures never load or modify real credentials.
    init(testTokens: GoogleOAuthTokens, email: String,
         businessEmail: @escaping () -> String?,
         transport: @escaping WorkspaceProviderOperation.Transport) {
        precondition(GunnAireCloudKit.usesTestDatabase)
        requestTransport = transport
        persistsCredentials = false
        businessEmailProvider = businessEmail
        super.init()
        signedInEmail = email
        applyTokens(testTokens)
    }
#endif

    var canUseCurrentBusinessIdentity: Bool {
        isAuthenticated && GoogleAccountLinkPolicy.canUseIntegration(
            primaryBusinessEmail: businessEmailProvider(),
            googleEmail: signedInEmail
        )
    }

    func hasGrantedScope(_ scope: String) -> Bool {
        GoogleOAuthTokens(
            accessToken: "",
            refreshToken: nil,
            idToken: nil,
            expiration: .distantFuture,
            scopeSignature: grantedScopeSignature
        ).grants(scope)
    }

    private var businessAccountLinkError: GoogleAuthError? {
        canUseCurrentBusinessIdentity ? nil : .businessAccountMismatch
    }

    func captureProviderOperation(requiresWorkspace: Bool = true) throws -> WorkspaceProviderOperation {
        let generation = connectionGeneration
        return try WorkspaceProviderOperation.capture(requiresWorkspace: requiresWorkspace) {
            self.isAuthenticated && self.connectionGeneration == generation &&
            (!requiresWorkspace || self.canUseCurrentBusinessIdentity)
        }
    }

    func signOut() {
        connectionGeneration = UUID()
        activeAuthSession?.cancel()
        let tokenToRevoke = applicationSessionToken
        isAuthenticated = false
        accessToken = nil
        refreshToken = nil
        idToken = nil
        tokenExpiry = nil
        grantedScopeSignature = nil
        signedInEmail = nil
        pendingOAuthState = nil
        activeAuthSession = nil
        activePresentationContext = nil
        if persistsCredentials {
            try? KeychainStore.remove(account: keychainAccount)
            UserDefaults.standard.removeObject(forKey: tokenStorageKey)
            UserDefaults.standard.removeObject(forKey: Self.signedInEmailStorageKey)
        }
        clearApplicationSession()
        if let tokenToRevoke, !tokenToRevoke.isEmpty {
            Task {
                try? await GunnAireBackendService.revokeApplicationSession(tokenToRevoke)
            }
        }
    }

    @MainActor
    func establishBusinessApplicationSession(
        for profile: GoogleUserProfile
    ) async throws -> BackendAppUserRecord {
        let generation = connectionGeneration
        guard let identityToken = idToken, !identityToken.isEmpty else {
            throw GoogleAuthError.missingIdentityToken
        }
        let response = try await GunnAireBackendService.exchangeGoogleIdentity(
            identityToken: identityToken
        )
        guard self.connectionGeneration == generation, self.idToken == identityToken else {
            try? await GunnAireBackendService.revokeApplicationSession(response.sessionToken)
            throw WorkspaceProviderAccessError.changed(mayHaveReachedProvider: false)
        }
        let profileEmail = AppAccess.normalizedEmail(profile.email)
        let responseEmail = AppAccess.normalizedEmail(response.user.email)
        guard response.providerSubject == profile.sub,
              !profileEmail.isEmpty,
              profileEmail == responseEmail else {
            try? await GunnAireBackendService.revokeApplicationSession(response.sessionToken)
            throw GoogleAuthError.businessSessionMismatch
        }
        let session = GunnAireGoogleApplicationSession(
            token: response.sessionToken,
            expiresAt: response.expiresAt,
            email: responseEmail,
            googleUserIdentifier: profile.sub
        )
        do {
            try KeychainStore.saveCodable(session, account: applicationSessionKeychainAccount)
        } catch {
            try? await GunnAireBackendService.revokeApplicationSession(response.sessionToken)
            throw GoogleAuthError.sessionStorageFailed
        }
        applicationSessionToken = session.token
        return response.user
    }

    func startSignIn(presentationContext: ASWebAuthenticationPresentationContextProviding, completion: @escaping (Result<Void, Error>) -> Void) {
        connectionGeneration = UUID()
        let generation = connectionGeneration
        activeAuthSession?.cancel()
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
            guard let self, self.connectionGeneration == generation else {
                completion(.failure(WorkspaceProviderAccessError.changed(mayHaveReachedProvider: false)))
                return
            }
            defer {
                self.activeAuthSession = nil
                self.activePresentationContext = nil
            }
            if let error = error as? ASWebAuthenticationSessionError,
               error.code == .canceledLogin {
                completion(.failure(GoogleAuthError.authenticationSessionCanceled))
                return
            }
            guard let callbackURL = callbackURL else {
                completion(.failure(error ?? GoogleAuthError.unknown))
                return
            }
            self.handleAuthCallback(url: callbackURL, completion: completion)
        }
        session.presentationContextProvider = presentationContext
        session.prefersEphemeralWebBrowserSession = true
        activePresentationContext = presentationContext
        activeAuthSession = session
        if !session.start() {
            activeAuthSession = nil
            activePresentationContext = nil
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

        let generation = connectionGeneration
        exchangeAuthorizationCode(code: code, codeVerifier: codeVerifier) { result in
            DispatchQueue.main.async {
                guard self.connectionGeneration == generation else {
                    completion(.failure(WorkspaceProviderAccessError.changed(mayHaveReachedProvider: false)))
                    return
                }
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

        sendOAuthRequest(request) { data, response, error in
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
                    expiration: Date().addingTimeInterval(payload.expires_in),
                    scopeSignature: payload.scope.map {
                        Config.Google.scopeSignature(for: [$0])
                    } ?? Config.Google.oauthScopeSignature
                )
                completion(.success(tokens))
            }
        }
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
        let generation = connectionGeneration
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

        sendOAuthRequest(request) { data, response, error in
            Task { @MainActor in
                guard self.connectionGeneration == generation, self.refreshToken == refreshToken else {
                    completion(.failure(WorkspaceProviderAccessError.changed(mayHaveReachedProvider: false)))
                    return
                }
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
                    expiration: Date().addingTimeInterval(payload.expires_in),
                    scopeSignature: payload.scope.map {
                        Config.Google.scopeSignature(for: [$0])
                    } ?? self.grantedScopeSignature
                )
                self.storeTokens(merged)
                completion(.success(()))
            }
        }
    }

    /// OAuth remains available before workspace proof. Only its initiating
    /// connection may send or receive the result, including after cancellation.
    private func sendOAuthRequest(
        _ request: URLRequest,
        completion: @escaping (Data?, URLResponse?, Error?) -> Void
    ) {
        let generation = connectionGeneration
        let operation = WorkspaceProviderOperation { self.connectionGeneration == generation }
        operation.send(request, transport: requestTransport, completion: completion)
    }

    func fetchUserProfile(completion: @escaping (Result<GoogleUserProfile, Error>) -> Void) {
        let generation = connectionGeneration
        authorizedGET("https://www.googleapis.com/oauth2/v3/userinfo", identityBootstrap: true) { (result: Result<GoogleUserProfile, Error>) in
            switch result {
            case .success(let profile):
                DispatchQueue.main.async {
                    guard self.connectionGeneration == generation else {
                        completion(.failure(WorkspaceProviderAccessError.changed(mayHaveReachedProvider: false)))
                        return
                    }
                    self.rememberSignedInEmail(profile.email)
                    completion(.success(profile))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func validateSignedInDomain(completion: @escaping (Result<GoogleUserProfile, Error>) -> Void) {
        let generation = connectionGeneration
        fetchUserProfile { result in
            DispatchQueue.main.async {
                guard self.connectionGeneration == generation else {
                    completion(.failure(WorkspaceProviderAccessError.changed(mayHaveReachedProvider: false)))
                    return
                }
                switch result {
                case .success(let profile):
                    guard self.isAllowed(profile: profile) else {
                        self.signOut()
                        completion(.failure(GoogleAuthError.domainNotAllowed(Config.Google.allowedHostedDomain)))
                        return
                    }
                    self.rememberSignedInEmail(profile.email)
                    guard GoogleAccountLinkPolicy.canUseIntegration(
                        primaryBusinessEmail: self.businessEmailProvider(),
                        googleEmail: profile.email
                    ) else {
                        self.signOut()
                        completion(.failure(GoogleAuthError.businessAccountMismatch))
                        return
                    }
                    completion(.success(profile))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    /// Provider identifiers are one opaque path component, never a route.
    static func calendarPathComponent(_ value: String) -> String? {
        guard !value.isEmpty, value != ".", value != "..",
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.contains("/"), value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return value.addingPercentEncoding(withAllowedCharacters:
            .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%")))
    }

    func fetchCalendars(operation: WorkspaceProviderOperation? = nil, completion: @escaping (Result<[GoogleCalendar], Error>) -> Void) {
        if let businessAccountLinkError {
            completion(.failure(businessAccountLinkError))
            return
        }
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")
        components?.queryItems = [URLQueryItem(name: "maxResults", value: "250")]
        guard let url = components?.url else {
            completion(.failure(GoogleAuthError.invalidEndpoint))
            return
        }
        fetchCalendarListPage(
            url: url,
            accumulated: [],
            seenPageTokens: [],
            completedPageCount: 0,
            existingOperation: operation,
            completion: completion
        )
    }

    func fetchCalendarEvents(calendarID: String, timeMin: Date? = nil, timeMax: Date? = nil, operation: WorkspaceProviderOperation? = nil, completion: @escaping (Result<[GoogleCalendarEvent], Error>) -> Void) {
        if let businessAccountLinkError {
            completion(.failure(businessAccountLinkError))
            return
        }
        guard let encodedCalendarID = Self.calendarPathComponent(calendarID) else {
            completion(.failure(GoogleAuthError.invalidEndpoint)); return
        }
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendarID)/events")
        var queryItems = [
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxAttendees", value: "20"),
            URLQueryItem(name: "maxResults", value: "2500")
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
        fetchCalendarEventsPage(
            url: url,
            accumulated: [],
            seenPageTokens: [],
            completedPageCount: 0,
            existingOperation: operation,
            completion: completion
        )
    }

    private func fetchCalendarListPage(
        url: URL,
        accumulated: [GoogleCalendar],
        seenPageTokens: Set<String>,
        completedPageCount: Int,
        existingOperation: WorkspaceProviderOperation? = nil,
        completion: @escaping (Result<[GoogleCalendar], Error>) -> Void
    ) {
        let operation: WorkspaceProviderOperation
        do { operation = try existingOperation ?? captureProviderOperation(); try operation.check() }
        catch { completion(.failure(error)); return }
        authorizedGET(url.absoluteString, existingOperation: operation) { (result: Result<GoogleCalendarListResponse, Error>) in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let response):
                let calendars = accumulated + response.items
                var nextSeenTokens = seenPageTokens
                do {
                    guard let nextURL = try GoogleCalendarPagination.nextURL(
                        currentURL: url,
                        nextPageToken: response.nextPageToken,
                        seenPageTokens: &nextSeenTokens,
                        completedPageCount: completedPageCount + 1
                    ) else {
                        completion(.success(calendars))
                        return
                    }
                    self.fetchCalendarListPage(
                        url: nextURL,
                        accumulated: calendars,
                        seenPageTokens: nextSeenTokens,
                        completedPageCount: completedPageCount + 1,
                        existingOperation: operation,
                        completion: completion
                    )
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    private func fetchCalendarEventsPage(
        url: URL,
        accumulated: [GoogleCalendarEvent],
        seenPageTokens: Set<String>,
        completedPageCount: Int,
        existingOperation: WorkspaceProviderOperation? = nil,
        completion: @escaping (Result<[GoogleCalendarEvent], Error>) -> Void
    ) {
        let operation: WorkspaceProviderOperation
        do { operation = try existingOperation ?? captureProviderOperation(); try operation.check() }
        catch { completion(.failure(error)); return }
        authorizedGET(url.absoluteString, existingOperation: operation) { (result: Result<GoogleCalendarEventsResponse, Error>) in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let response):
                let events = accumulated + response.items
                var nextSeenTokens = seenPageTokens
                do {
                    guard let nextURL = try GoogleCalendarPagination.nextURL(
                        currentURL: url,
                        nextPageToken: response.nextPageToken,
                        seenPageTokens: &nextSeenTokens,
                        completedPageCount: completedPageCount + 1
                    ) else {
                        completion(.success(events))
                        return
                    }
                    self.fetchCalendarEventsPage(
                        url: nextURL,
                        accumulated: events,
                        seenPageTokens: nextSeenTokens,
                        completedPageCount: completedPageCount + 1,
                        existingOperation: operation,
                        completion: completion
                    )
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    func fetchCalendarEvent(calendarID: String = "primary", eventID: String, operation: WorkspaceProviderOperation? = nil, completion: @escaping (Result<GoogleCalendarEvent, Error>) -> Void) {
        if let businessAccountLinkError {
            completion(.failure(businessAccountLinkError))
            return
        }
        guard let encodedCalendarID = Self.calendarPathComponent(calendarID) else {
            completion(.failure(GoogleAuthError.invalidEndpoint)); return
        }
        guard let encodedEventID = Self.calendarPathComponent(eventID) else {
            completion(.failure(GoogleAuthError.invalidEndpoint)); return
        }
        guard let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendarID)/events/\(encodedEventID)") else {
            completion(.failure(GoogleAuthError.invalidEndpoint))
            return
        }
        authorizedGET(url.absoluteString, existingOperation: operation, completion: completion)
    }

    func createCalendarEvent(calendarID: String = "primary", event: GoogleWritableCalendarEvent, operation: WorkspaceProviderOperation? = nil, completion: @escaping (Result<GoogleCalendarEvent, Error>) -> Void) {
        guard !persistsCredentials || (operation != nil && event.id?.isEmpty == false) else {
            completion(.failure(GoogleCalendarWorkflowError.needsReview)); return
        }
        if let businessAccountLinkError {
            completion(.failure(businessAccountLinkError))
            return
        }
        guard let encodedCalendarID = Self.calendarPathComponent(calendarID) else {
            completion(.failure(GoogleAuthError.invalidEndpoint)); return
        }
        guard let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendarID)/events") else {
            completion(.failure(GoogleAuthError.invalidEndpoint))
            return
        }
        authorizedJSONRequest(url: url, method: "POST", body: event, existingOperation: operation, completion: completion)
    }

    @available(*, unavailable, message: "Use patchCalendarEvent with the schedule-only GoogleCalendarEventPatch so existing Google details are preserved.")
    func updateCalendarEvent(calendarID: String = "primary", eventID: String, event: GoogleWritableCalendarEvent, completion: @escaping (Result<GoogleCalendarEvent, Error>) -> Void) {
        completion(.failure(GoogleAuthError.unsafeCalendarPatch("summary, description, location, attendees, extendedProperties")))
    }

    func patchCalendarEvent(calendarID: String = "primary", eventID: String, patch: GoogleCalendarEventPatch, ifMatch: String? = nil, operation: WorkspaceProviderOperation? = nil, completion: @escaping (Result<GoogleCalendarEvent, Error>) -> Void) {
        guard !persistsCredentials || (operation != nil && ifMatch?.isEmpty == false) else {
            completion(.failure(GoogleCalendarWorkflowError.needsReview)); return
        }
        if let businessAccountLinkError {
            completion(.failure(businessAccountLinkError))
            return
        }
        let encodedPatch: Data
        do {
            encodedPatch = try JSONEncoder().encode(patch)
        } catch {
            completion(.failure(GoogleAuthError.decoding))
            return
        }
        let unsafeKeys = GoogleCalendarEventPatch.unsafeDetailKeys(in: encodedPatch)
        guard unsafeKeys.isEmpty else {
            completion(.failure(GoogleAuthError.unsafeCalendarPatch(unsafeKeys.joined(separator: ", "))))
            return
        }
        guard let encodedCalendarID = Self.calendarPathComponent(calendarID) else {
            completion(.failure(GoogleAuthError.invalidEndpoint)); return
        }
        guard let encodedEventID = Self.calendarPathComponent(eventID) else {
            completion(.failure(GoogleAuthError.invalidEndpoint)); return
        }
        guard let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendarID)/events/\(encodedEventID)") else {
            completion(.failure(GoogleAuthError.invalidEndpoint))
            return
        }
        authorizedJSONDataRequest(url: url, method: "PATCH", body: encodedPatch, existingOperation: operation, ifMatch: ifMatch, completion: completion)
    }

    func deleteCalendarEvent(calendarID: String = "primary", eventID: String, ifMatch: String? = nil, operation: WorkspaceProviderOperation? = nil, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !persistsCredentials || (operation != nil && ifMatch?.isEmpty == false) else {
            completion(.failure(GoogleCalendarWorkflowError.needsReview)); return
        }
        if let businessAccountLinkError {
            completion(.failure(businessAccountLinkError))
            return
        }
        guard let encodedCalendarID = Self.calendarPathComponent(calendarID) else {
            completion(.failure(GoogleAuthError.invalidEndpoint)); return
        }
        guard let encodedEventID = Self.calendarPathComponent(eventID) else {
            completion(.failure(GoogleAuthError.invalidEndpoint)); return
        }
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendarID)/events/\(encodedEventID)")
        components?.queryItems = [URLQueryItem(name: "sendUpdates", value: "none")]
        guard let url = components?.url else {
            completion(.failure(GoogleAuthError.invalidEndpoint))
            return
        }
        authorizedEmptyRequest(url: url, method: "DELETE", existingOperation: operation, ifMatch: ifMatch, completion: completion)
    }

    func fetchGmailMessages(maxResults: Int = 25, query: String? = nil, completion: @escaping (Result<[GmailMessageDetail], Error>) -> Void) {
        fetchGmailMessagePage(folder: .allMail, query: query ?? "", maxResults: maxResults) {
            completion($0.map(\.messages))
        }
    }

    func fetchGmailMessagePage(folder: GmailMailboxFolder, query: String = "", pageToken: String? = nil,
                               maxResults: Int = 25, operation existingOperation: WorkspaceProviderOperation? = nil,
                               completion: @escaping (Result<GmailMailboxPage, Error>) -> Void) {
        let operation: WorkspaceProviderOperation
        do { operation = try existingOperation ?? captureProviderOperation(); try operation.check() }
        catch { completion(.failure(error)); return }
        if let businessAccountLinkError {
            completion(.failure(businessAccountLinkError))
            return
        }
        guard (1...50).contains(maxResults), GmailMailboxPage.validToken(pageToken), query.utf8.count <= 8_192,
              !query.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            completion(.failure(GoogleAuthError.invalidEndpoint)); return
        }
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")
        var queryItems = [URLQueryItem(name: "maxResults", value: String(maxResults)),
                          URLQueryItem(name: "includeSpamTrash", value: folder == .trash ? "true" : "false")]
        if let label = folder.labelID { queryItems.append(.init(name: "labelIds", value: label)) }
        if let pageToken { queryItems.append(.init(name: "pageToken", value: pageToken)) }
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "q", value: query))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else {
            completion(.failure(GoogleAuthError.invalidEndpoint))
            return
        }

        authorizedGET(url.absoluteString, existingOperation: operation) { (result: Result<GmailMessageListResponse, Error>) in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let response):
                let references = response.messages ?? []
                guard references.count <= maxResults, GmailMailboxPage.validToken(response.nextPageToken),
                      response.nextPageToken != pageToken || pageToken == nil,
                      Set(references.map(\.id)).count == references.count,
                      references.allSatisfy({ Self.calendarPathComponent($0.id) != nil && Self.calendarPathComponent($0.threadId) != nil }) else {
                    completion(.failure(GoogleAuthError.decoding)); return
                }
                self.fetchGmailMessageDetails(references: references, operation: operation) { result in
                    completion(result.map { GmailMailboxPage(messages: $0, nextPageToken: response.nextPageToken) })
                }
            }
        }
    }

    func fetchGmailMessage(id: String, operation: WorkspaceProviderOperation? = nil, completion: @escaping (Result<GmailMessageDetail, Error>) -> Void) {
        if let businessAccountLinkError {
            completion(.failure(businessAccountLinkError))
            return
        }
        guard let escapedID = Self.calendarPathComponent(id) else {
            completion(.failure(GoogleAuthError.invalidEndpoint)); return
        }
        let url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(escapedID)?format=full"
        authorizedGET(url, existingOperation: operation, completion: completion)
    }

    func fetchGmailAttachment(messageID: String, attachmentID: String, operation: WorkspaceProviderOperation,
                              completion: @escaping (Result<GmailMessageBody, Error>) -> Void) {
        guard let message = Self.calendarPathComponent(messageID),
              let attachment = Self.calendarPathComponent(attachmentID) else {
            completion(.failure(GoogleAuthError.invalidEndpoint)); return
        }
        authorizedGET("https://gmail.googleapis.com/gmail/v1/users/me/messages/\(message)/attachments/\(attachment)",
                      existingOperation: operation, completion: completion)
    }

    func fetchGmailThread(id: String, completion: @escaping (Result<[GmailMessageDetail], Error>) -> Void) {
        if let businessAccountLinkError {
            completion(.failure(businessAccountLinkError))
            return
        }
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

    func markGmailMessageRead(id: String, operation: WorkspaceProviderOperation? = nil, completion: @escaping (Result<Void, Error>) -> Void) {
        changeGmailMessage(id: id, action: .read, operation: operation) { completion($0.map { _ in () }) }
    }

    /// Gmail's recoverable delete action. Messages are moved to Trash instead
    /// of being permanently deleted so office staff can recover mistakes.
    func moveGmailMessageToTrash(id: String, operation: WorkspaceProviderOperation? = nil, completion: @escaping (Result<Void, Error>) -> Void) {
        changeGmailMessage(id: id, action: .trash, operation: operation) { completion($0.map { _ in () }) }
    }

    func changeGmailMessage(id: String, threadID: String? = nil, action: GmailMailboxAction,
                            operation: WorkspaceProviderOperation? = nil,
                            completion: @escaping (Result<GmailMessageDetail, Error>) -> Void) {
        if let businessAccountLinkError {
            completion(.failure(businessAccountLinkError))
            return
        }
        guard let escapedID = Self.calendarPathComponent(id),
              threadID.map({ Self.calendarPathComponent($0) != nil }) != false,
              let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(escapedID)/\(action.endpoint)") else {
            completion(.failure(GoogleAuthError.invalidEndpoint))
            return
        }
        let verified: (Result<GmailMessageDetail, Error>) -> Void = { result in
            completion(result.flatMap { value in
                value.id == id && (threadID == nil || value.threadId == threadID) && action.confirmed(by: value)
                    ? .success(value) : .failure(GoogleAuthError.decoding)
            })
        }
        if action == .trash || action == .restore {
            authorizedJSONDataRequest(url: url, method: "POST", body: Data(), existingOperation: operation, completion: verified)
        } else {
            authorizedJSONRequest(url: url, method: "POST", body: action.labels, existingOperation: operation, completion: verified)
        }
    }

    func sendGmailMessage(
        to: String,
        subject: String,
        body: String,
        threadID: String? = nil,
        attachments: [GmailAttachment] = [],
        reply: GmailReplyContext? = nil,
        messageID: String? = nil,
        operation: WorkspaceProviderOperation? = nil,
        completion: @escaping (Result<GmailMessageReference, Error>) -> Void
    ) {
        if let businessAccountLinkError {
            completion(.failure(businessAccountLinkError))
            return
        }
        let outgoing: GmailOutgoingMessage
        do {
            outgoing = try GmailOutgoingMessage(to: to, subject: subject, body: body, attachments: attachments, reply: reply)
            if persistsCredentials, operation == nil { throw GmailComposeError.access }
            if let messageID, !GmailReplyContext.isValidMessageID(messageID) { throw GmailComposeError.header }
            if let reply, (reply.threadID != threadID || Self.calendarPathComponent(reply.threadID) == nil ||
                           !GmailReplyContext.isValidMessageID(reply.messageID) ||
                           !reply.references.allSatisfy(GmailReplyContext.isValidMessageID)) { throw GmailComposeError.header }
        } catch { completion(.failure(error)); return }
        let message = Self.makeGmailRawMessage(
            to: outgoing.to,
            subject: subject,
            body: body,
            attachments: attachments,
            reply: outgoing.reply,
            messageID: messageID,
            from: signedInEmail
        )

        guard let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send") else {
            completion(.failure(GoogleAuthError.invalidEndpoint))
            return
        }

        let payload = GmailSendRequest(raw: Data(message.utf8).base64URLEncodedString(), threadId: outgoing.reply?.threadID)
        authorizedJSONRequest(url: url, method: "POST", body: payload, existingOperation: operation, reportHTTPStatus: true) { (result: Result<GmailMessageReference, Error>) in
            switch result {
            case .success(let sentMessage):
                completion(.success(sentMessage))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    static func makeGmailRawMessage(
        to: String,
        subject: String,
        body: String,
        attachments: [GmailAttachment] = [],
        reply: GmailReplyContext? = nil,
        messageID: String? = nil,
        from: String? = nil
    ) -> String {
        let escapedSubject = subject.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        let headerSubject: String
        if escapedSubject.unicodeScalars.allSatisfy(\.isASCII) { headerSubject = escapedSubject }
        else {
            var words: [String] = [], chunk = ""
            for scalar in escapedSubject.unicodeScalars {
                let next = String(scalar)
                if chunk.utf8.count + next.utf8.count > 42 {
                    words.append("=?UTF-8?B?\(Data(chunk.utf8).base64EncodedString())?=")
                    chunk = ""
                }
                chunk += next
            }
            if !chunk.isEmpty { words.append("=?UTF-8?B?\(Data(chunk.utf8).base64EncodedString())?=") }
            headerSubject = words.joined(separator: "\r\n ")
        }
        let safeTo = to.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        var headers = ["To: \(safeTo)", "Subject: \(headerSubject)", "Date: \(formatter.string(from: Date()))",
                       "Message-ID: \(messageID ?? "<gunnaire-\(UUID().uuidString.lowercased())@gunnaire.com>")", "MIME-Version: 1.0"]
        if let from, let addresses = try? GmailAddressList.parse(from), addresses.count == 1 {
            headers.insert("From: \(addresses[0])", at: 0)
        }
        if let reply, reply.subject == subject, GmailReplyContext.isValidMessageID(reply.messageID),
           reply.references.allSatisfy(GmailReplyContext.isValidMessageID) {
            headers += ["In-Reply-To: \(reply.messageID)", "References: \(reply.referenceHeader)"]
        }
        let encodedBody = Data(body.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        guard !attachments.isEmpty else {
            return (headers + [
                "Content-Type: text/plain; charset=utf-8",
                "Content-Transfer-Encoding: base64",
                "",
                encodedBody
            ]).joined(separator: "\r\n")
        }

        let boundary = "gunnaire-\(UUID().uuidString)"
        var lines: [String] = headers + [
            "Content-Type: multipart/mixed; boundary=\"\(boundary)\"",
            "",
            "--\(boundary)",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: base64",
            "",
            encodedBody
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
                attachment.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
            ])
        }

        lines.append("--\(boundary)--")
        return lines.joined(separator: "\r\n")
    }

    private func authorizedGET<T: Decodable>(_ absoluteURL: String, identityBootstrap: Bool = false, existingOperation: WorkspaceProviderOperation? = nil, completion: @escaping (Result<T, Error>) -> Void) {
        guard !identityBootstrap || absoluteURL == "https://www.googleapis.com/oauth2/v3/userinfo" else {
            completion(.failure(GoogleAuthError.invalidEndpoint)); return
        }
        let operation: WorkspaceProviderOperation
        do { operation = try existingOperation ?? captureProviderOperation(requiresWorkspace: !identityBootstrap); try operation.check() }
        catch { completion(.failure(error)); return }
        refreshTokensIfNeeded { result in
            if let error = operation.failure { completion(.failure(error)); return }
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

                operation.send(request, transport: self.requestTransport) { data, response, error in
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
                }
            }
        }
    }

    private func fetchGmailMessageDetails(references: [GmailMessageReference], operation: WorkspaceProviderOperation, completion: @escaping (Result<[GmailMessageDetail], Error>) -> Void) {
        if let error = operation.failure { completion(.failure(error)); return }
        guard !references.isEmpty else {
            completion(.success([]))
            return
        }

        let group = DispatchGroup()
        var details: [GmailMessageDetail] = []
        var firstError: Error?

        for reference in references {
            group.enter()
            guard let escapedID = Self.calendarPathComponent(reference.id) else {
                if firstError == nil { firstError = GoogleAuthError.invalidEndpoint }
                group.leave()
                continue
            }
            let url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(escapedID)?format=metadata&metadataHeaders=From&metadataHeaders=Subject&metadataHeaders=Date&metadataHeaders=To"
            authorizedGET(url, existingOperation: operation) { (result: Result<GmailMessageDetail, Error>) in
                // All authorized request callbacks are delivered on MainActor.
                switch result {
                case .success(let detail):
                    if detail.id == reference.id && detail.threadId == reference.threadId {
                        details.append(detail)
                    } else if firstError == nil { firstError = GoogleAuthError.decoding }
                case .failure(let error):
                    if firstError == nil { firstError = error }
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            if let error = operation.failure { completion(.failure(error)); return }
            if let firstError {
                completion(.failure(firstError))
            } else {
                let byID = Dictionary(uniqueKeysWithValues: details.map { ($0.id, $0) })
                let sorted = references.compactMap { byID[$0.id] }
                completion(.success(sorted))
            }
        }
    }

    private func authorizedJSONRequest<T: Decodable, Body: Encodable>(
        url: URL,
        method: String,
        body: Body,
        existingOperation: WorkspaceProviderOperation? = nil,
        reportHTTPStatus: Bool = false,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        let operation: WorkspaceProviderOperation
        do { operation = try existingOperation ?? captureProviderOperation(); try operation.check() }
        catch { completion(.failure(error)); return }
        refreshTokensIfNeeded { result in
            if let error = operation.failure { completion(.failure(error)); return }
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

                operation.send(request, transport: self.requestTransport) { data, response, error in
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
                        completion(.failure(reportHTTPStatus ? .http(statusCode: http.statusCode) :
                            self.parseProviderError(data: data, fallbackStatus: http.statusCode)))
                        return
                    }
                    guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
                        completion(.failure(GoogleAuthError.decoding))
                        return
                    }
                    completion(.success(decoded))
                }
            }
        }
    }

    private func authorizedJSONDataRequest<T: Decodable>(
        url: URL,
        method: String,
        body: Data,
        existingOperation: WorkspaceProviderOperation? = nil,
        ifMatch: String? = nil,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        let operation: WorkspaceProviderOperation
        do { operation = try existingOperation ?? captureProviderOperation(); try operation.check() }
        catch { completion(.failure(error)); return }
        refreshTokensIfNeeded { result in
            if let error = operation.failure { completion(.failure(error)); return }
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
                if let ifMatch { request.setValue(ifMatch, forHTTPHeaderField: "If-Match") }
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body

                operation.send(request, transport: self.requestTransport) { data, response, error in
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
                }
            }
        }
    }

    private func authorizedEmptyRequest(
        url: URL,
        method: String,
        existingOperation: WorkspaceProviderOperation? = nil,
        ifMatch: String? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let operation: WorkspaceProviderOperation
        do { operation = try existingOperation ?? captureProviderOperation(); try operation.check() }
        catch { completion(.failure(error)); return }
        refreshTokensIfNeeded { result in
            if let error = operation.failure { completion(.failure(error)); return }
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
                if let ifMatch { request.setValue(ifMatch, forHTTPHeaderField: "If-Match") }
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Accept")

                operation.send(request, transport: self.requestTransport) { data, response, error in
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
                }
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

    private func loadApplicationSession() {
        guard let stored = try? KeychainStore.loadCodable(
            GunnAireGoogleApplicationSession.self,
            account: applicationSessionKeychainAccount
        ), Self.isFutureApplicationSession(stored.expiresAt) else {
            clearApplicationSession()
            return
        }
        applicationSessionToken = stored.token
    }

    private func clearApplicationSession() {
        applicationSessionToken = nil
        if persistsCredentials { try? KeychainStore.remove(account: applicationSessionKeychainAccount) }
    }

    private static func isFutureApplicationSession(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        return parsed.map { $0 > Date() } ?? false
    }

    private func storeTokens(_ tokens: GoogleOAuthTokens) {
        if persistsCredentials {
            try? KeychainStore.saveCodable(tokens, account: keychainAccount)
            if let encoded = try? JSONEncoder().encode(tokens) {
                UserDefaults.standard.set(encoded, forKey: tokenStorageKey)
            }
        }
        applyTokens(tokens)
    }

    private func applyTokens(_ tokens: GoogleOAuthTokens) {
        accessToken = tokens.accessToken
        refreshToken = tokens.refreshToken
        idToken = tokens.idToken
        tokenExpiry = tokens.expiration
        grantedScopeSignature = tokens.scopeSignature
        isAuthenticated = true
        let restoredEmail = (persistsCredentials ? UserDefaults.standard.string(forKey: Self.signedInEmailStorageKey) : signedInEmail)
            ?? Self.extractEmail(fromIDToken: tokens.idToken)
        rememberSignedInEmail(restoredEmail)
    }

    private func rememberSignedInEmail(_ email: String?) {
        let normalizedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        signedInEmail = normalizedEmail
        guard persistsCredentials else { return }
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
        if [404, 409, 412].contains(fallbackStatus) { return .http(statusCode: fallbackStatus) }
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
    case businessAccountMismatch
    case missingIdentityToken
    case businessSessionMismatch
    case sessionStorageFailed
    case unsafeCalendarPatch(String)
    case calendarPaginationLoop
    case calendarPaginationLimit
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
        case .businessAccountMismatch: return "The connected Google account must match your signed-in GunnAire business email. Disconnect Google, then reconnect the matching account."
        case .missingIdentityToken: return "Google did not return a business identity token. Sign in with Google again."
        case .businessSessionMismatch: return "Google returned an identity that did not match the verified GunnAire business session."
        case .sessionStorageFailed: return "The verified Google business session could not be secured on this device."
        case .unsafeCalendarPatch(let keys): return "Blocked unsafe Google Calendar update that would overwrite event details: \(keys)."
        case .calendarPaginationLoop: return "Google Calendar returned a repeated page. Sync stopped without accepting an incomplete schedule."
        case .calendarPaginationLimit: return "Google Calendar returned too many pages in one sync. Narrow the schedule window and try again."
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
    let scope: String?
}

private struct GoogleRefreshResponse: Codable {
    let access_token: String
    let expires_in: TimeInterval
    let id_token: String?
    let scope: String?
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
