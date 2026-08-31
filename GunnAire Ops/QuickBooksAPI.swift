// QuickBooksAPI.swift
// Scaffolds OAuth2 flow and API request handling for QuickBooks Online
import Foundation
import AuthenticationServices
import Combine

/// Enum for QBO resource endpoints
enum QBOResource: String {
    case customers = "customer"
    case invoices = "invoice"
    case payments = "payment"
    case vendors = "vendor"
    case estimates = "estimate"
}
final class QuickBooksAuthAPI: ObservableObject {
    // MARK: - OAuth2 Properties
    static let shared = QuickBooksAuthAPI()
    
    // OAuth client credentials and redirect URI referenced from Config.swift
    private let clientID = Config.QuickBooks.clientID
    private let redirectURI = Config.QuickBooks.redirectURI
    private let callbackScheme = Config.QuickBooks.callbackScheme
    private let environment = Config.QuickBooks.environment
    private var activeAuthSession: ASWebAuthenticationSession?
    private var activePresentationContext: ASWebAuthenticationPresentationContextProviding?
    private var pendingOAuthState: String?
    
    @Published private(set) var isAuthenticated: Bool = false
    @Published private var accessToken: String?
    @Published private var realmID: String?
    @Published private var tokenExpiry: Date?

    private init() {
        reloadStoredSession()
    }

    func reloadStoredSession() {
        QuickBooksDataAPI.shared.loadTokens()
        if let stored = QuickBooksDataAPI.shared.tokens {
            accessToken = stored.accessToken
            tokenExpiry = stored.expiration
            realmID = QuickBooksDataAPI.shared.realmID
            isAuthenticated = QuickBooksDataAPI.shared.isAuthenticated
        } else {
            accessToken = nil
            tokenExpiry = nil
            realmID = nil
            isAuthenticated = false
        }
    }
    
    // MARK: - OAuth2 Flow
    func startSignIn(presentationContext: ASWebAuthenticationPresentationContextProviding, completion: @escaping (Result<Void, Error>) -> Void) {
        if QuickBooksDataAPI.shared.tokens != nil {
            QuickBooksDataAPI.shared.resetConnectionForReconnect { [weak self] _ in
                self?.beginSignIn(presentationContext: presentationContext, completion: completion)
            }
            return
        }
        beginSignIn(presentationContext: presentationContext, completion: completion)
    }

    private func beginSignIn(presentationContext: ASWebAuthenticationPresentationContextProviding, completion: @escaping (Result<Void, Error>) -> Void) {
        guard Config.QuickBooks.isConfigured else {
            completion(Result<Void, Error>.failure(QBOError.missingConfiguration))
            return
        }
        if Config.QuickBooks.isProduction && !Config.QuickBooks.redirectURIIsHTTPS {
            completion(Result<Void, Error>.failure(QBOError.invalidRedirectURI(redirectURI)))
            return
        }
        guard let authURL = makeAuthURL() else {
            completion(Result<Void, Error>.failure(QBOError.invalidAuthURL))
            return
        }
        let resolvedCallbackScheme = callbackScheme.isEmpty ? (URL(string: redirectURI)?.scheme ?? "") : callbackScheme
        guard !resolvedCallbackScheme.isEmpty else {
            completion(Result<Void, Error>.failure(QBOError.invalidRedirectURI(redirectURI)))
            return
        }
        guard isCallbackSchemeRegistered(resolvedCallbackScheme) else {
            completion(Result<Void, Error>.failure(QBOError.callbackSchemeNotRegistered(resolvedCallbackScheme)))
            return
        }
        let session = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: resolvedCallbackScheme
        ) { [weak self] callbackURL, error in
            defer {
                self?.activeAuthSession = nil
                self?.activePresentationContext = nil
            }
            guard let self = self, let callbackURL = callbackURL else {
                completion(Result<Void, Error>.failure(error ?? QBOError.unknown))
                return
            }
            self.handleAuthCallback(url: callbackURL, completion: completion)
        }
        session.presentationContextProvider = presentationContext
        session.prefersEphemeralWebBrowserSession = false
        activePresentationContext = presentationContext
        activeAuthSession = session
        if !session.start() {
            activeAuthSession = nil
            activePresentationContext = nil
            completion(Result<Void, Error>.failure(QBOError.unknown))
        }
    }

    func signOut() {
        isAuthenticated = false
        accessToken = nil
        realmID = nil
        tokenExpiry = nil
        pendingOAuthState = nil
        activeAuthSession = nil
        activePresentationContext = nil
        QuickBooksDataAPI.shared.resetConnectionForReconnect()
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

    private func makeAuthURL() -> URL? {
        var components = URLComponents(string: Config.QuickBooks.authorizationEndpoint)
        let scopes = Config.QuickBooks.oauthScopes
        let state = UUID().uuidString
        pendingOAuthState = state
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state)
        ]
        return components?.url
    }
    
    private func handleAuthCallback(url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        // Parse auth code and exchange for access/refresh tokens
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            completion(Result<Void, Error>.failure(QBOError.unknown))
            return
        }

        if let oauthError = components.queryItems?.first(where: { $0.name == "error" })?.value {
            let description = components.queryItems?.first(where: { $0.name == "error_description" })?.value
            completion(Result<Void, Error>.failure(QBOError.providerError(oauthError, description)))
            return
        }

        guard
              let codeItem = components.queryItems?.first(where: { $0.name == "code" }),
              let code = codeItem.value else {
            completion(Result<Void, Error>.failure(QBOError.missingAuthCode))
            return
        }
        guard let state = components.queryItems?.first(where: { $0.name == "state" })?.value,
              state == pendingOAuthState else {
            completion(Result<Void, Error>.failure(QBOError.invalidState))
            return
        }
        let realmID = components.queryItems?.first(where: { $0.name == "realmId" })?.value
            ?? components.queryItems?.first(where: { $0.name == "realmid" })?.value
        guard let realmID,
              !realmID.isEmpty else {
            completion(Result<Void, Error>.failure(QBOError.missingRealmID))
            return
        }
        pendingOAuthState = nil
        self.realmID = realmID

        exchangeAuthorizationCode(code: code, realmID: realmID) { result in
            DispatchQueue.main.async(execute: {
                switch result {
                case .success(let tokens):
                    self.accessToken = tokens.accessToken
                    self.tokenExpiry = tokens.expiration
                    self.isAuthenticated = true
                    QuickBooksDataAPI.shared.storeTokens(tokens, realmID: realmID)
                    completion(Result<Void, Error>.success(()))
                case .failure(let error):
                    self.isAuthenticated = false
                    completion(Result<Void, Error>.failure(error))
                }
            })
        }
    }

    private func exchangeAuthorizationCode(code: String, realmID: String, completion: @escaping (Result<QuickBooksOAuthTokens, Error>) -> Void) {
        Task {
            do {
                let tokens = try await GunnAireBackendService.exchangeQuickBooksAuthorizationCode(code, realmID: realmID)
                completion(.success(tokens))
            } catch {
                completion(.failure(error))
            }
        }
    }
    
    // MARK: - API Requests (scaffold)
    func fetchResource(_ resource: QBOResource, completion: @escaping (Result<Data, Error>) -> Void) {
        guard let accessToken = accessToken, let realmID = realmID else {
            completion(Result<Data, Error>.failure(QBOError.notAuthenticated))
            return
        }
        let base = environment == "sandbox" ? "https://sandbox-quickbooks.api.intuit.com/v3/company/" : "https://quickbooks.api.intuit.com/v3/company/"
        guard var components = URLComponents(string: base + realmID + "/query") else {
            completion(Result<Data, Error>.failure(QBOError.invalidEndpoint))
            return
        }
        components.queryItems = [
            URLQueryItem(name: "query", value: "select * from \(resource.rawValue.capitalized)"),
            URLQueryItem(name: "minorversion", value: "75")
        ]
        guard let url = components.url else {
            completion(Result<Data, Error>.failure(QBOError.invalidEndpoint))
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = Config.QuickBooks.requestTimeoutSeconds
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Perform network call (omitted for brevity)
        // Call completion(.success(data)) or completion(.failure(error))
    }
}

enum QBOError: Error, LocalizedError {
    case invalidAuthURL, missingAuthCode, missingRealmID, invalidState, notAuthenticated, invalidEndpoint, invalidRedirectURI(String), callbackSchemeNotRegistered(String), missingConfiguration, providerError(String, String?), tokenExchangeFailed(Int, String?), unknown
    var errorDescription: String? {
        switch self {
        case .invalidAuthURL: return "Could not build authorization URL."
        case .missingAuthCode: return "Authorization code was not returned."
        case .missingRealmID: return "QuickBooks realmId was not returned."
        case .invalidState: return "OAuth state validation failed."
        case .notAuthenticated: return "You are not signed in to QuickBooks."
        case .invalidEndpoint: return "API endpoint is invalid."
        case .invalidRedirectURI(let uri): return "QuickBooks redirect URI is invalid: \(uri)"
        case .callbackSchemeNotRegistered(let scheme): return "QuickBooks callback scheme '\(scheme)' is not registered in app URL Types."
        case .missingConfiguration: return "QuickBooks OAuth credentials are missing. For production, set QB_ENVIRONMENT=production, the production Intuit client ID/secret, and the production HTTPS redirect URI from the Intuit Developer Portal."
        case .providerError(let code, let description): return "QuickBooks OAuth error: \(code)\(description.map { " - \($0)" } ?? ""). Confirm this build is using the production Intuit app credentials and production redirect URI."
        case .tokenExchangeFailed(let statusCode, let detail): return "QuickBooks token exchange failed (HTTP \(statusCode))\(detail.map { ": \($0)" } ?? ""). Confirm QB_ENVIRONMENT=production, the client ID/secret are from the Intuit production keys, and the redirect URI exactly matches the production Intuit Developer Portal entry."
        case .unknown: return "An unknown error occurred."
        }
    }
}
