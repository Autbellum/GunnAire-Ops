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
    private let callbackScheme = Config.QuickBooks.callbackScheme
    private let environment = Config.QuickBooks.environment
    private var activeAuthSession: ASWebAuthenticationSession?
    private var pendingOAuthState: String?
    
    @Published private(set) var isAuthenticated: Bool = false
    @Published private var accessToken: String?
    @Published private var refreshToken: String?
    @Published private var realmID: String?
    @Published private var tokenExpiry: Date?

    private init() {
        QuickBooksDataAPI.shared.loadTokens()
        if let stored = QuickBooksDataAPI.shared.tokens {
            accessToken = stored.accessToken
            refreshToken = stored.refreshToken
            tokenExpiry = stored.expiration
            realmID = QuickBooksDataAPI.shared.realmID
            isAuthenticated = (realmID != nil)
        }
    }
    
    // MARK: - OAuth2 Flow
    func startSignIn(presentationContext: ASWebAuthenticationPresentationContextProviding, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !clientID.hasPrefix("YOUR_"), !clientSecret.hasPrefix("YOUR_"), !redirectURI.hasPrefix("YOUR_") else {
            completion(.failure(QBOError.missingConfiguration))
            return
        }
        guard let authURL = makeAuthURL() else {
            completion(.failure(QBOError.invalidAuthURL))
            return
        }
        let resolvedCallbackScheme = callbackScheme.isEmpty ? (URL(string: redirectURI)?.scheme ?? "") : callbackScheme
        guard !resolvedCallbackScheme.isEmpty else {
            completion(.failure(QBOError.invalidRedirectURI(redirectURI)))
            return
        }
        guard isCallbackSchemeRegistered(resolvedCallbackScheme) else {
            completion(.failure(QBOError.callbackSchemeNotRegistered(resolvedCallbackScheme)))
            return
        }
        let session = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: resolvedCallbackScheme
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

    func signOut() {
        isAuthenticated = false
        accessToken = nil
        refreshToken = nil
        realmID = nil
        tokenExpiry = nil
        pendingOAuthState = nil
        activeAuthSession = nil
        QuickBooksDataAPI.shared.clearTokens()
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
        // QBO OAuth endpoint
        var components = URLComponents(string: "https://appcenter.intuit.com/connect/oauth2")
        let scopes = [
            "com.intuit.quickbooks.accounting",
            "com.intuit.quickbooks.payment",
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
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            completion(.failure(QBOError.unknown))
            return
        }

        if let oauthError = components.queryItems?.first(where: { $0.name == "error" })?.value {
            let description = components.queryItems?.first(where: { $0.name == "error_description" })?.value
            completion(.failure(QBOError.providerError(oauthError, description)))
            return
        }

        guard
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
        let realmID = components.queryItems?.first(where: { $0.name == "realmId" })?.value
            ?? components.queryItems?.first(where: { $0.name == "realmid" })?.value
        guard let realmID,
              !realmID.isEmpty else {
            completion(.failure(QBOError.missingRealmID))
            return
        }
        pendingOAuthState = nil
        self.realmID = realmID

        exchangeAuthorizationCode(code: code, realmID: realmID) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let tokens):
                    self.accessToken = tokens.accessToken
                    self.refreshToken = tokens.refreshToken
                    self.tokenExpiry = tokens.expiration
                    self.isAuthenticated = true
                    QuickBooksDataAPI.shared.storeTokens(tokens, realmID: realmID)
                    completion(.success(()))
                case .failure(let error):
                    self.isAuthenticated = false
                    completion(.failure(error))
                }
            }
        }
    }

    private func exchangeAuthorizationCode(code: String, realmID: String, completion: @escaping (Result<QuickBooksOAuthTokens, Error>) -> Void) {
        guard let url = URL(string: Config.QuickBooks.tokenEndpoint) else {
            completion(.failure(QBOError.invalidEndpoint))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let credentials = "\(clientID):\(clientSecret)"
        guard let credData = credentials.data(using: .utf8) else {
            completion(.failure(QBOError.unknown))
            return
        }
        request.setValue("Basic \(credData.base64EncodedString())", forHTTPHeaderField: "Authorization")

        let escapedCode = code.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? code
        let escapedRedirect = redirectURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? redirectURI
        let body = "grant_type=authorization_code&code=\(escapedCode)&redirect_uri=\(escapedRedirect)"
        request.httpBody = body.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }

            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), let data else {
                completion(.failure(QBOError.unknown))
                return
            }

            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let access = json["access_token"] as? String,
                let refresh = json["refresh_token"] as? String,
                let expiresIn = json["expires_in"] as? Double
            else {
                completion(.failure(QBOError.unknown))
                return
            }

            _ = realmID
            let tokens = QuickBooksOAuthTokens(
                accessToken: access,
                refreshToken: refresh,
                expiration: Date().addingTimeInterval(expiresIn)
            )
            completion(.success(tokens))
        }.resume()
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
    case invalidAuthURL, missingAuthCode, missingRealmID, invalidState, notAuthenticated, invalidEndpoint, invalidRedirectURI(String), callbackSchemeNotRegistered(String), missingConfiguration, providerError(String, String?), unknown
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
        case .missingConfiguration: return "QuickBooks OAuth credentials are missing in Config/environment variables."
        case .providerError(let code, let description): return "QuickBooks OAuth error: \(code)\(description.map { " - \($0)" } ?? "")"
        case .unknown: return "An unknown error occurred."
        }
    }
}
