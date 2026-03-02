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
    private let clientSecret = Config.QuickBooks.clientSecret
    private let redirectURI = Config.QuickBooks.redirectURI
    private let environment = Config.QuickBooks.environment
    private var activeAuthSession: ASWebAuthenticationSession?
    private var pendingOAuthState: String?
    
    @Published private(set) var isAuthenticated: Bool = false
    @Published private var accessToken: String?
    @Published private var refreshToken: String?
    @Published private var realmID: String?
    @Published private var tokenExpiry: Date?
    
    // MARK: - OAuth2 Flow
    func startSignIn(presentationContext: ASWebAuthenticationPresentationContextProviding, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let authURL = makeAuthURL() else {
            completion(.failure(QBOError.invalidAuthURL))
            return
        }
        let session = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: URL(string: redirectURI)?.scheme
        ) { [weak self] callbackURL, error in
            defer { self?.activeAuthSession = nil }
            guard let self = self, let callbackURL = callbackURL else {
                completion(.failure(error ?? QBOError.unknown))
                return
            }
            self.handleAuthCallback(url: callbackURL, completion: completion)
        }
        session.presentationContextProvider = presentationContext
        session.prefersEphemeralWebBrowserSession = true
        activeAuthSession = session
        if !session.start() {
            activeAuthSession = nil
            completion(.failure(QBOError.unknown))
        }
    }
    
    private func makeAuthURL() -> URL? {
        // QBO OAuth endpoint
        var components = URLComponents(string: "https://appcenter.intuit.com/connect/oauth2")
        let scopes = [
            "com.intuit.quickbooks.accounting",
            "openid",
            "profile",
            "email",
            "phone",
            "address"
        ].joined(separator: " ")
        let state = UUID().uuidString
        pendingOAuthState = state
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state)
        ]
        return components?.url
    }
    
    private func handleAuthCallback(url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        // Parse auth code and exchange for access/refresh tokens
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let codeItem = components.queryItems?.first(where: { $0.name == "code" }),
              let code = codeItem.value else {
            completion(.failure(QBOError.missingAuthCode))
            return
        }
        guard let state = components.queryItems?.first(where: { $0.name == "state" })?.value,
              state == pendingOAuthState else {
            completion(.failure(QBOError.invalidState))
            return
        }
        guard let realmID = components.queryItems?.first(where: { $0.name == "realmId" })?.value,
              !realmID.isEmpty else {
            completion(.failure(QBOError.missingRealmID))
            return
        }
        pendingOAuthState = nil
        self.realmID = realmID
        isAuthenticated = true
        // Exchange authorization code for access token (network call omitted for brevity)
        // Set accessToken, refreshToken, realmID, tokenExpiry, isAuthenticated, etc.
        _ = code
        completion(.success(()))
    }
    
    // MARK: - API Requests (scaffold)
    func fetchResource(_ resource: QBOResource, completion: @escaping (Result<Data, Error>) -> Void) {
        guard let accessToken = accessToken, let realmID = realmID else {
            completion(.failure(QBOError.notAuthenticated))
            return
        }
        let base = environment == "sandbox" ? "https://sandbox-quickbooks.api.intuit.com/v3/company/" : "https://quickbooks.api.intuit.com/v3/company/"
        guard let url = URL(string: base + realmID + "/query?query=select * from " + resource.rawValue.capitalized) else {
            completion(.failure(QBOError.invalidEndpoint))
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Perform network call (omitted for brevity)
        // Call completion(.success(data)) or completion(.failure(error))
    }
}

enum QBOError: Error, LocalizedError {
    case invalidAuthURL, missingAuthCode, missingRealmID, invalidState, notAuthenticated, invalidEndpoint, unknown
    var errorDescription: String? {
        switch self {
        case .invalidAuthURL: return "Could not build authorization URL."
        case .missingAuthCode: return "Authorization code was not returned."
        case .missingRealmID: return "QuickBooks realmId was not returned."
        case .invalidState: return "OAuth state validation failed."
        case .notAuthenticated: return "You are not signed in to QuickBooks."
        case .invalidEndpoint: return "API endpoint is invalid."
        case .unknown: return "An unknown error occurred."
        }
    }
}
