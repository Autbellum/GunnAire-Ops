import Foundation
import Combine

extension Notification.Name {
    static let quickBooksAuthenticationDidChange = Notification.Name("QuickBooksAuthenticationDidChange")
}

struct QuickBooksOAuthTokens: Codable {
    let accessToken: String
    let expiration: Date
}

private struct QuickBooksKeychainPayload: Codable {
    let tokens: QuickBooksOAuthTokens
    let realmID: String
    let environment: String?
    let clientIDFingerprint: String?
    let redirectURI: String?
    let scopeSignature: String?
}

final class QuickBooksDataAPI: ObservableObject {
    static let shared = QuickBooksDataAPI()

    @Published private(set) var tokens: QuickBooksOAuthTokens?
    @Published private(set) var storedRealmID: String?
    @Published private(set) var storedEnvironment: String?
    @Published private(set) var storedScopeSignature: String?
    @Published private(set) var lastAuthorizationFailureDetail: String?
    @Published private(set) var lastRefreshFailureDetail: String?
    @Published private(set) var lastRejectedRealmID: String?
    @Published private(set) var lastRejectedEnvironment: String?

    private var tokenRefreshTimer: AnyCancellable?
    private let clientId = Config.QuickBooks.clientID
    private let realmIDKey = "QuickBooksRealmID"
    // Legacy builds stored a long-lived refresh token in this UserDefaults key.
    // It is retained only so the app can remove that insecure migration residue.
    private let legacyTokenStorageKey = "QuickBooksOAuthTokens"
    private let keychainAccount = "QuickBooksOAuthPayload"
    private let minorVersion = "75"

    private init() {
        loadTokens()
        startAutomaticTokenRefresh()
    }

    private var baseURL: String {
        let env = (storedEnvironment ?? Config.QuickBooks.environment).lowercased()
        if env == "sandbox" {
            return "https://sandbox-quickbooks.api.intuit.com/v3/company/"
        }
        return "https://quickbooks.api.intuit.com/v3/company/"
    }

    private var paymentsAPIRootURL: String {
        let env = (storedEnvironment ?? Config.QuickBooks.environment).lowercased()
        if env == "sandbox" {
            return "https://sandbox.api.intuit.com/quickbooks/v4"
        }
        return "https://api.intuit.com/quickbooks/v4"
    }

    private var paymentsBaseURL: String {
        "\(paymentsAPIRootURL)/payments"
    }

    var realmID: String? {
        guard let storedRealmID else { return nil }
        let normalizedRealmID = storedRealmID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedRealmID.isEmpty ? nil : normalizedRealmID
    }

    var isAuthenticated: Bool {
        tokens != nil && realmID != nil
    }

    var currentEnvironment: String {
        (storedEnvironment ?? Config.QuickBooks.environment).lowercased()
    }

    var tokenExpiration: Date? {
        tokens?.expiration
    }

    var connectionDiagnosticSummary: String {
        let company = realmID ?? "Not connected"
        let expiration = tokenExpiration?.formatted(date: .abbreviated, time: .shortened) ?? "No token"
        let authorizedScopes = storedScopeSignature?.isEmpty == false ? storedScopeSignature! : "Unknown"
        return "Environment: \(currentEnvironment.capitalized) • Realm: \(company) • Client: \(Self.currentClientIDFingerprint) • Requested scopes: \(Self.currentScopeSignature) • Authorized scopes: \(authorizedScopes) • Token expires: \(expiration)"
    }

    private static var currentClientIDFingerprint: String {
        stableFingerprint(Config.QuickBooks.clientID)
    }

    private static var currentScopeSignature: String {
        Config.QuickBooks.oauthScopes.sorted().joined(separator: " ")
    }

    var missingRequestedScopes: [String] {
        guard let storedScopeSignature, !storedScopeSignature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        let authorized = Self.scopeSet(from: storedScopeSignature)
        let requested = Set(Config.QuickBooks.oauthScopes)
        return requested.subtracting(authorized).sorted()
    }

    var savedSessionNeedsScopeReauthorization: Bool {
        !missingRequestedScopes.isEmpty
    }

    var savedSessionIncludesPaymentsScope: Bool {
        guard let storedScopeSignature, !storedScopeSignature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return Self.scopeSet(from: storedScopeSignature).contains(Config.QuickBooks.paymentsScope)
    }

    var canUseQuickBooksPaymentsAPI: Bool {
        Config.QuickBooks.enablePaymentsScope && isAuthenticated && savedSessionIncludesPaymentsScope
    }

    var scopeReauthorizationDiagnostic: String? {
        let missing = missingRequestedScopes
        guard !missing.isEmpty else { return nil }
        return "QuickBooks is connected for the previously authorized scopes, but this build now requests \(missing.joined(separator: ", ")). Reconnect QuickBooks to authorize the new scope set. Accounting sync can keep using the saved session until Intuit rejects it."
    }

    var paymentsAuthorizationDiagnostic: String? {
        guard Config.QuickBooks.enablePaymentsScope else { return nil }
        guard isAuthenticated else {
            return "QuickBooks Payments is off until QuickBooks Accounting is connected."
        }
        guard !savedSessionIncludesPaymentsScope else { return nil }
        return "QuickBooks Accounting is connected, but this saved token is not authorized for \(Config.QuickBooks.paymentsScope). Accounting sync will continue; card, stored-card, and charge endpoints stay disabled until Intuit grants Payments access for this company and a Payments-authorized token is saved."
    }

    private static func stableFingerprint(_ value: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(format: "%016llx", hash)
    }

    private static func scopeSet(from signature: String) -> Set<String> {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "|,"))
        return Set(signature.components(separatedBy: separators).filter { !$0.isEmpty })
    }

    private func savedPayloadMatchesCurrentConfiguration(_ payload: QuickBooksKeychainPayload) -> Bool {
        guard payload.environment?.lowercased() == Config.QuickBooks.environment.lowercased() else { return false }
        guard payload.clientIDFingerprint == Self.currentClientIDFingerprint else { return false }
        guard payload.redirectURI == Config.QuickBooks.redirectURI else { return false }
        return true
    }

    var savedSessionEnvironmentDiffersFromCurrentBuild: Bool {
        guard let storedEnvironment else { return false }
        return storedEnvironment.lowercased() != Config.QuickBooks.environment.lowercased()
    }

    var environmentMismatchDiagnostic: String? {
        guard savedSessionEnvironmentDiffersFromCurrentBuild else { return nil }
        return "Saved QuickBooks session was authorized for \(currentEnvironment.capitalized), but this build is configured for \(Config.QuickBooks.environment.capitalized). Disconnect and reconnect with the production Intuit app credentials after changing QB_ENVIRONMENT, client keys, or redirect URI."
    }

    var canStartOAuthFlow: Bool {
        Config.QuickBooks.isConfigured
    }

    func resetConnectionForReconnect(completion: ((Bool) -> Void)? = nil) {
        guard realmID != nil else {
            clearTokens()
            completion?(true)
            return
        }

        revoke { [weak self] ok in
            Task { @MainActor in
                self?.clearTokens()
                completion?(ok)
            }
        }
    }

    func storeTokens(_ tokens: QuickBooksOAuthTokens, realmID: String) {
        storeTokens(tokens, realmID: realmID, authorizedScopeSignature: QuickBooksDataAPI.currentScopeSignature)
    }

    private func storeTokens(_ tokens: QuickBooksOAuthTokens, realmID: String, authorizedScopeSignature: String?) {
        let normalizedRealmID = realmID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tokens = tokens
        self.storedRealmID = normalizedRealmID.isEmpty ? nil : normalizedRealmID
        self.storedEnvironment = Config.QuickBooks.environment
        self.storedScopeSignature = authorizedScopeSignature
        guard !normalizedRealmID.isEmpty else {
            UserDefaults.standard.removeObject(forKey: realmIDKey)
            return
        }
        try? KeychainStore.saveCodable(
            QuickBooksKeychainPayload(
                tokens: tokens,
                realmID: normalizedRealmID,
                environment: self.storedEnvironment,
                clientIDFingerprint: Self.currentClientIDFingerprint,
                redirectURI: Config.QuickBooks.redirectURI,
                scopeSignature: authorizedScopeSignature
            ),
            account: keychainAccount
        )
        UserDefaults.standard.set(normalizedRealmID, forKey: realmIDKey)
        NotificationCenter.default.post(name: .quickBooksAuthenticationDidChange, object: nil)
    }

    func loadTokens() {
        if let payload = try? KeychainStore.loadCodable(QuickBooksKeychainPayload.self, account: keychainAccount) {
            guard savedPayloadMatchesCurrentConfiguration(payload) else {
                lastAuthorizationFailureDetail = "Saved QuickBooks session was created by a different Intuit client, redirect URI, or sandbox/production environment. Reconnect once with the production Intuit app settings in this build."
                lastRejectedRealmID = payload.realmID.trimmingCharacters(in: .whitespacesAndNewlines)
                lastRejectedEnvironment = payload.environment
                clearTokens(clearAuthorizationFailure: false)
                return
            }

            tokens = payload.tokens
            storedEnvironment = payload.environment ?? Config.QuickBooks.environment
            storedScopeSignature = payload.scopeSignature
            let keychainRealmID = payload.realmID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !keychainRealmID.isEmpty {
                storedRealmID = keychainRealmID
            } else {
                storedRealmID = UserDefaults.standard.string(forKey: realmIDKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return
        }

        if UserDefaults.standard.data(forKey: legacyTokenStorageKey) != nil {
            // Do not migrate a refresh credential from UserDefaults. It will be
            // replaced by a server-encrypted QBO connection on the next sign-in.
            UserDefaults.standard.removeObject(forKey: legacyTokenStorageKey)
            lastAuthorizationFailureDetail = "A legacy device-stored QuickBooks credential was removed. Reconnect QuickBooks so the encrypted backend connection can be created."
            clearTokens(clearAuthorizationFailure: false)
        }
    }

    func clearTokens(clearAuthorizationFailure: Bool = true) {
        tokens = nil
        storedRealmID = nil
        storedEnvironment = nil
        storedScopeSignature = nil
        if clearAuthorizationFailure {
            lastAuthorizationFailureDetail = nil
            lastRefreshFailureDetail = nil
            lastRejectedRealmID = nil
            lastRejectedEnvironment = nil
        }
        try? KeychainStore.remove(account: keychainAccount)
        UserDefaults.standard.removeObject(forKey: legacyTokenStorageKey)
        UserDefaults.standard.removeObject(forKey: realmIDKey)
        NotificationCenter.default.post(name: .quickBooksAuthenticationDidChange, object: nil)
    }

    private func revoke(completion: @escaping (Bool) -> Void) {
        Task {
            completion((try? await GunnAireBackendService.revokeQuickBooksConnection()) != nil)
        }
    }

    func refreshTokensIfNeeded(completion: @escaping (Bool) -> Void) {
        if let tokens, tokens.expiration > Date().addingTimeInterval(60) {
            completeOnMain(completion, value: true)
            return
        }
        refreshAccessToken(completion: completion)
    }

    func refreshSessionIfPossible() async -> Bool {
        await withCheckedContinuation { continuation in
            refreshTokensIfNeeded { ok in
                continuation.resume(returning: ok)
            }
        }
    }

    private func startAutomaticTokenRefresh() {
        tokenRefreshTimer = Timer.publish(every: 15 * 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshTokensIfNeeded { _ in }
            }
    }

    private func refreshAccessToken(completion: @escaping (Bool) -> Void) {
        Task { @MainActor in
            do {
                guard let realmID = self.realmID else {
                    self.lastRefreshFailureDetail = "QuickBooks token refresh succeeded, but the app could not read the saved company realm. Reconnect QuickBooks."
                    self.clearTokens(clearAuthorizationFailure: false)
                    self.completeOnMain(completion, value: false)
                    return
                }
                let refreshed = try await GunnAireBackendService.refreshQuickBooksAccessToken(
                    realmID: realmID,
                    environment: self.currentEnvironment
                )
                self.lastRefreshFailureDetail = nil
                self.storeTokens(refreshed, realmID: realmID, authorizedScopeSignature: self.storedScopeSignature)
                self.completeOnMain(completion, value: true)
            } catch {
                self.lastRefreshFailureDetail = "QuickBooks token refresh through the secure backend failed: \(error.localizedDescription)"
                self.completeOnMain(completion, value: false)
            }
        }
    }

    private static func refreshFailureMessage(statusCode: Int, raw: String?) -> String {
        let detail = raw?.isEmpty == false ? " Intuit detail: \(String(raw!.prefix(700)))" : ""
        switch statusCode {
        case 400, 401, 403:
            return "QuickBooks token refresh was rejected (HTTP \(statusCode)). The saved refresh token is expired, revoked, already rotated, or belongs to different production credentials. Disconnect QuickBooks, then connect again with a QuickBooks company admin.\(detail)"
        case -1:
            return "QuickBooks token refresh failed because the app did not receive a valid HTTP response.\(detail)"
        default:
            return "QuickBooks token refresh failed (HTTP \(statusCode)).\(detail)"
        }
    }

    private func completeOnMain(_ completion: @escaping (Bool) -> Void, value: Bool) {
        DispatchQueue.main.async {
            completion(value)
        }
    }

    private func authorizedRequest(
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = nil
    ) -> URLRequest? {
        guard let tokens, let realmID else {
            return nil
        }

        let root = baseURL + "\(realmID)/\(path)"
        guard var components = URLComponents(string: root) else { return nil }
        var mergedQueryItems = components.queryItems ?? []
        mergedQueryItems.append(contentsOf: queryItems)
        if !mergedQueryItems.contains(where: { $0.name == "minorversion" }) {
            mergedQueryItems.append(URLQueryItem(name: "minorversion", value: minorVersion))
        }
        if method.uppercased() != "GET", !mergedQueryItems.contains(where: { $0.name.lowercased() == "requestid" }) {
            mergedQueryItems.append(URLQueryItem(name: "requestid", value: UUID().uuidString))
        }
        components.queryItems = mergedQueryItems

        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = Config.QuickBooks.requestTimeoutSeconds
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body
        return request
    }

    private func makeQueryRequest(_ sql: String) -> URLRequest? {
        authorizedRequest(path: "query", queryItems: [URLQueryItem(name: "query", value: sql)])
    }

    private func authorizedPaymentsRequest(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = nil
    ) -> URLRequest? {
        makeAuthorizedPaymentsRequest(baseURL: paymentsBaseURL, path: path, method: method, body: body, contentType: contentType)
    }

    private func authorizedPaymentsCustomerRequest(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = nil
    ) -> URLRequest? {
        makeAuthorizedPaymentsRequest(baseURL: paymentsAPIRootURL, path: path, method: method, body: body, contentType: contentType)
    }

    private func makeAuthorizedPaymentsRequest(
        baseURL: String,
        path: String,
        method: String,
        body: Data?,
        contentType: String?
    ) -> URLRequest? {
        guard let tokens else {
            return nil
        }

        let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let url = URL(string: "\(baseURL)/\(trimmedPath)") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = Config.QuickBooks.requestTimeoutSeconds
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "Request-Id")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body
        return request
    }
    private func retryDelayIfRateLimited(response: URLResponse?, attempt: Int) -> TimeInterval? {
        guard attempt < Config.QuickBooks.maxRetryAttempts,
              let http = response as? HTTPURLResponse,
              http.statusCode == 429 else {
            return nil
        }

        let retryAfter = (http.allHeaderFields["Retry-After"] as? String)
            ?? (http.allHeaderFields["retry-after"] as? String)
        if let retryAfter, let seconds = Double(retryAfter), seconds > 0 {
            return min(seconds, 30)
        }
        return min(pow(2.0, Double(attempt)), 30)
    }


    private func resolveHTTPError(data: Data?, response: URLResponse?) -> QBError? {
        guard let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) else {
            return nil
        }

        if let data,
           let apiError = try? JSONDecoder().decode(QuickBooksFaultEnvelope.self, from: data),
           let firstError = apiError.Fault.Error.first {
            let detail = [firstError.Message, firstError.Detail]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: ": ")
            if isApplicationAuthorizationFailure(statusCode: http.statusCode, detail: detail, code: firstError.code) {
                return .authorizationFailed(statusCode: http.statusCode, detail: authorizationFailureMessage(detail: detail))
            }
            return .api(statusCode: http.statusCode, detail: detail)
        }

        if let data,
           let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            if isApplicationAuthorizationFailure(statusCode: http.statusCode, detail: raw, code: nil) {
                return .authorizationFailed(statusCode: http.statusCode, detail: authorizationFailureMessage(detail: raw))
            }
            return .httpDetail(statusCode: http.statusCode, detail: raw)
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            return .authorizationFailed(statusCode: http.statusCode, detail: authorizationFailureMessage(detail: "QuickBooks rejected this app session."))
        }

        if http.statusCode == 429 {
            return .rateLimited(detail: "QuickBooks throttled this request. The app will retry automatically when possible; reduce simultaneous syncs if this persists.")
        }

        return .http(statusCode: http.statusCode)
    }

    private func resolvePaymentsHTTPError(data: Data?, response: URLResponse?) -> QBError? {
        guard let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) else {
            return nil
        }

        if let data,
           let apiError = try? JSONDecoder().decode(QuickBooksPaymentsErrorEnvelope.self, from: data),
           let description = apiError.firstProblemDescription {
            if http.statusCode == 401 || http.statusCode == 403 {
                return .paymentsAuthorizationFailed(statusCode: http.statusCode, detail: paymentsAuthorizationFailureMessage(detail: description))
            }
            return .httpDetail(statusCode: http.statusCode, detail: description)
        }

        if let data,
           let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            if http.statusCode == 401 || http.statusCode == 403 {
                return .paymentsAuthorizationFailed(statusCode: http.statusCode, detail: paymentsAuthorizationFailureMessage(detail: raw))
            }
            return .httpDetail(statusCode: http.statusCode, detail: raw)
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            return .paymentsAuthorizationFailed(statusCode: http.statusCode, detail: paymentsAuthorizationFailureMessage(detail: "QuickBooks Payments rejected this app session."))
        }

        if http.statusCode == 429 {
            return .rateLimited(detail: "QuickBooks Payments throttled this request. The app will retry automatically when possible; reduce simultaneous syncs if this persists.")
        }

        return .http(statusCode: http.statusCode)
    }

    private func isApplicationAuthorizationFailure(statusCode: Int, detail: String, code: String?) -> Bool {
        guard statusCode == 401 || statusCode == 403 else { return false }
        let normalized = detail.lowercased()
        return code == "3100"
            || normalized.contains("applicationauthorizationfailed")
            || normalized.contains("application authorization failed")
            || normalized.contains("errorcode=003100")
    }

    private func authorizationFailureMessage(detail: String) -> String {
        let company = realmID ?? lastRejectedRealmID ?? "the selected QuickBooks company"
        let environment = currentEnvironment
        let cleanedDetail = detail
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        let intuitDetail = cleanedDetail.isEmpty || cleanedDetail == "QuickBooks rejected this app session."
            ? ""
            : " Intuit detail: \(String(cleanedDetail.prefix(700)))"
        return "QuickBooks rejected the saved connection for company realm \(company) in \(environment). Your production keys can still be correct; this 403 means Intuit does not consider the current saved token authorized for QBO Accounting on that company. Use Disconnect QuickBooks, then Connect QuickBooks again with a QuickBooks company admin and accept the Accounting permission.\(intuitDetail)"
    }

    private func paymentsAuthorizationFailureMessage(detail: String) -> String {
        let cleanedDetail = detail
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        let intuitDetail = cleanedDetail.isEmpty || cleanedDetail == "QuickBooks Payments rejected this app session."
            ? ""
            : " Intuit detail: \(String(cleanedDetail.prefix(700)))"
        return "QuickBooks Payments rejected this app session. This means Accounting is connected, but this company/token is not authorized for the QuickBooks Payments API. Reconnect QuickBooks after confirming Payments access is enabled for this company in Intuit.\(intuitDetail)"
    }

    private func clearRejectedSessionIfNeeded(_ error: QBError) {
        guard error.requiresReconnect else { return }
        if case .authorizationFailed(_, let detail) = error {
            lastAuthorizationFailureDetail = detail
        } else {
            lastAuthorizationFailureDetail = error.localizedDescription
        }
        lastRejectedRealmID = realmID ?? storedRealmID
        lastRejectedEnvironment = currentEnvironment
        if case .unauthorized = error {
            clearTokens(clearAuthorizationFailure: false)
        }
    }

    private struct DecodableTypeBox<T: Decodable>: @unchecked Sendable {
        let type: T.Type
    }

    private func performAuthorizedDecodingRequest<T: Decodable>(
        _ requestBuilder: @escaping () -> URLRequest?,
        decode type: T.Type,
        completion: @escaping (Result<T, Error>) -> Void,
        attempt: Int = 0
    ) {
        let typeBox = DecodableTypeBox(type: type)
        refreshTokensIfNeeded { ok in
            guard ok, let request = requestBuilder() else {
                completion(.failure(QBError.unauthorized))
                return
            }

            URLSession.shared.dataTask(with: request) { data, response, error in
                if let delay = self.retryDelayIfRateLimited(response: response, attempt: attempt) {
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self.performAuthorizedDecodingRequest(requestBuilder, decode: typeBox.type, completion: completion, attempt: attempt + 1)
                    }
                    return
                }

                Task { @MainActor in
                    if let error {
                        completion(.failure(error))
                        return
                    }
                    if let httpError = self.resolveHTTPError(data: data, response: response) {
                        self.clearRejectedSessionIfNeeded(httpError)
                        completion(.failure(httpError))
                        return
                    }
                    guard let data else {
                        completion(.failure(QBError.noData))
                        return
                    }
                    do {
                        let decoded = try JSONDecoder().decode(T.self, from: data)
                        completion(.success(decoded))
                    } catch {
                        let raw = String(data: data, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let sample = raw.map { String($0.prefix(8000)) } ?? "No response body"
                        completion(.failure(QBError.decodingDetail("\(error.localizedDescription). Raw response: \(sample)")))
                    }
                }
            }.resume()
        }
    }

    private func performPaymentsDecodingRequest<T: Decodable>(
        _ requestBuilder: @escaping () -> URLRequest?,
        decode type: T.Type,
        completion: @escaping (Result<T, Error>) -> Void,
        attempt: Int = 0
    ) {
        if let scopeError = paymentsScopeReadinessError() {
            completion(.failure(scopeError))
            return
        }
        let typeBox = DecodableTypeBox(type: type)
        refreshTokensIfNeeded { ok in
            guard ok, let request = requestBuilder() else {
                completion(.failure(QBError.unauthorized))
                return
            }

            URLSession.shared.dataTask(with: request) { data, response, error in
                if let delay = self.retryDelayIfRateLimited(response: response, attempt: attempt) {
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self.performPaymentsDecodingRequest(requestBuilder, decode: typeBox.type, completion: completion, attempt: attempt + 1)
                    }
                    return
                }

                Task { @MainActor in
                    if let error {
                        completion(.failure(error))
                        return
                    }
                    if let httpError = self.resolvePaymentsHTTPError(data: data, response: response) {
                        self.clearRejectedSessionIfNeeded(httpError)
                        completion(.failure(httpError))
                        return
                    }
                    guard let data else {
                        completion(.failure(QBError.noData))
                        return
                    }
                    do {
                        let decoded = try JSONDecoder().decode(T.self, from: data)
                        completion(.success(decoded))
                    } catch {
                        let raw = String(data: data, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let sample = raw.map { String($0.prefix(8000)) } ?? "No response body"
                        completion(.failure(QBError.decodingDetail("\(error.localizedDescription). Raw response: \(sample)")))
                    }
                }
            }.resume()
        }
    }

    func fetchCustomers(completion: @escaping (Result<[QuickBooksCustomer], Error>) -> Void) {
        performAuthorizedDecodingRequest(
            { self.makeQueryRequest("SELECT * FROM Customer") },
            decode: QuickBooksCustomerQueryResponse.self
        ) { result in
            completion(result.map { $0.QueryResponse.Customer ?? [] })
        }
    }

    func validateAccountingConnection(completion: @escaping (Result<QuickBooksCompanyInfo, Error>) -> Void) {
        guard let realmID else {
            completion(.failure(QBError.unauthorized))
            return
        }
        performAuthorizedDecodingRequest(
            { self.authorizedRequest(path: "companyinfo/\(realmID)") },
            decode: QuickBooksCompanyInfoResponse.self
        ) { result in
            completion(result.map(\.CompanyInfo))
        }
    }

    func createCustomer(_ customer: QuickBooksCustomerCreate, completion: @escaping (Result<QuickBooksCustomer, Error>) -> Void) {
        let body = try? JSONEncoder().encode(customer)
        performAuthorizedDecodingRequest(
            { self.authorizedRequest(path: "customer", method: "POST", body: body, contentType: "application/json") },
            decode: QuickBooksCustomerResponse.self
        ) { result in
            completion(result.map(\.Customer))
        }
    }

    func fetchItems(completion: @escaping (Result<[QuickBooksItem], Error>) -> Void) {
        performAuthorizedDecodingRequest(
            { self.makeQueryRequest("SELECT * FROM Item") },
            decode: QuickBooksItemQueryResponse.self
        ) { result in
            completion(result.map { $0.QueryResponse.Item ?? [] })
        }
    }

    func createItem(_ item: QuickBooksItemCreate, completion: @escaping (Result<QuickBooksItem, Error>) -> Void) {
        let body = try? JSONEncoder().encode(item)
        performAuthorizedDecodingRequest(
            { self.authorizedRequest(path: "item", method: "POST", body: body, contentType: "application/json") },
            decode: QuickBooksItemResponse.self
        ) { result in
            completion(result.map(\.Item))
        }
    }

    func fetchEstimates(completion: @escaping (Result<[QuickBooksEstimate], Error>) -> Void) {
        performAuthorizedDecodingRequest(
            { self.makeQueryRequest("SELECT * FROM Estimate") },
            decode: QuickBooksEstimateQueryResponse.self
        ) { result in
            completion(result.map { $0.QueryResponse.Estimate ?? [] })
        }
    }

    func createEstimate(_ estimate: QuickBooksEstimateCreate, completion: @escaping (Result<QuickBooksEstimate, Error>) -> Void) {
        let body = try? JSONEncoder().encode(estimate)
        performAuthorizedDecodingRequest(
            { self.authorizedRequest(path: "estimate", method: "POST", body: body, contentType: "application/json") },
            decode: QuickBooksEstimateResponse.self
        ) { result in
            completion(result.map(\.Estimate))
        }
    }

    func sendEstimate(id: String, to emailAddress: String? = nil, completion: @escaping (Result<QuickBooksEstimate, Error>) -> Void) {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty,
              let encodedID = trimmedID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            completion(.failure(QBError.noData))
            return
        }
        let trimmedEmail = emailAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryItems = trimmedEmail?.isEmpty == false
            ? [URLQueryItem(name: "sendTo", value: trimmedEmail)]
            : []
        performAuthorizedDecodingRequest(
            { self.authorizedRequest(path: "estimate/\(encodedID)/send", queryItems: queryItems, method: "POST") },
            decode: QuickBooksEstimateResponse.self
        ) { result in
            completion(result.map(\.Estimate))
        }
    }

    func fetchInvoices(completion: @escaping (Result<[QuickBooksInvoice], Error>) -> Void) {
        performAuthorizedDecodingRequest(
            { self.makeQueryRequest("SELECT * FROM Invoice") },
            decode: QuickBooksInvoiceQueryResponse.self
        ) { result in
            completion(result.map { $0.QueryResponse.Invoice ?? [] })
        }
    }

    func fetchInvoice(id: String, completion: @escaping (Result<QuickBooksInvoice, Error>) -> Void) {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty,
              let encodedID = trimmedID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            completion(.failure(QBError.noData))
            return
        }
        performAuthorizedDecodingRequest(
            { self.authorizedRequest(path: "invoice/\(encodedID)") },
            decode: QuickBooksInvoiceResponse.self
        ) { result in
            completion(result.map(\.Invoice))
        }
    }

    func createInvoice(_ invoice: QuickBooksInvoiceCreate, completion: @escaping (Result<QuickBooksInvoice, Error>) -> Void) {
        let body = try? JSONEncoder().encode(invoice)
        performAuthorizedDecodingRequest(
            { self.authorizedRequest(path: "invoice", method: "POST", body: body, contentType: "application/json") },
            decode: QuickBooksInvoiceResponse.self
        ) { result in
            completion(result.map(\.Invoice))
        }
    }

    func updateInvoice(_ invoice: QuickBooksInvoiceUpdate, completion: @escaping (Result<QuickBooksInvoice, Error>) -> Void) {
        let body = try? JSONEncoder().encode(invoice)
        let requestID = UUID().uuidString
        performAuthorizedDecodingRequest(
            {
                self.authorizedRequest(
                    path: "invoice",
                    queryItems: [URLQueryItem(name: "requestid", value: requestID)],
                    method: "POST",
                    body: body,
                    contentType: "application/json"
                )
            },
            decode: QuickBooksInvoiceResponse.self
        ) { result in
            completion(result.map(\.Invoice))
        }
    }

    func sendInvoice(id: String, to emailAddress: String? = nil, completion: @escaping (Result<QuickBooksInvoice, Error>) -> Void) {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty,
              let encodedID = trimmedID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            completion(.failure(QBError.noData))
            return
        }
        let trimmedEmail = emailAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryItems = trimmedEmail?.isEmpty == false
            ? [URLQueryItem(name: "sendTo", value: trimmedEmail)]
            : []
        performAuthorizedDecodingRequest(
            { self.authorizedRequest(path: "invoice/\(encodedID)/send", queryItems: queryItems, method: "POST") },
            decode: QuickBooksInvoiceResponse.self
        ) { result in
            completion(result.map(\.Invoice))
        }
    }

    func fetchBills(completion: @escaping (Result<[QuickBooksBill], Error>) -> Void) {
        performAuthorizedDecodingRequest(
            { self.makeQueryRequest("SELECT * FROM Bill") },
            decode: QuickBooksBillQueryResponse.self
        ) { result in
            completion(result.map { $0.QueryResponse.Bill ?? [] })
        }
    }

    func createBill(_ bill: QuickBooksBillCreate, completion: @escaping (Result<QuickBooksBill, Error>) -> Void) {
        let body = try? JSONEncoder().encode(bill)
        performAuthorizedDecodingRequest(
            { self.authorizedRequest(path: "bill", method: "POST", body: body, contentType: "application/json") },
            decode: QuickBooksBillResponse.self
        ) { result in
            completion(result.map(\.Bill))
        }
    }

    func fetchPurchases(completion: @escaping (Result<[QuickBooksPurchase], Error>) -> Void) {
        performAuthorizedDecodingRequest(
            { self.makeQueryRequest("SELECT * FROM Purchase") },
            decode: QuickBooksPurchaseQueryResponse.self
        ) { result in
            completion(result.map { $0.QueryResponse.Purchase ?? [] })
        }
    }

    func createPurchase(_ purchase: QuickBooksPurchaseCreate, completion: @escaping (Result<QuickBooksPurchase, Error>) -> Void) {
        let body = try? JSONEncoder().encode(purchase)
        performAuthorizedDecodingRequest(
            { self.authorizedRequest(path: "purchase", method: "POST", body: body, contentType: "application/json") },
            decode: QuickBooksPurchaseResponse.self
        ) { result in
            completion(result.map(\.Purchase))
        }
    }

    func fetchVendors(completion: @escaping (Result<[QuickBooksVendor], Error>) -> Void) {
        performAuthorizedDecodingRequest(
            { self.makeQueryRequest("SELECT * FROM Vendor") },
            decode: QuickBooksVendorQueryResponse.self
        ) { result in
            completion(result.map { $0.QueryResponse.Vendor ?? [] })
        }
    }

    func createVendor(_ vendor: QuickBooksVendorCreate, completion: @escaping (Result<QuickBooksVendor, Error>) -> Void) {
        let body = try? JSONEncoder().encode(vendor)
        performAuthorizedDecodingRequest(
            { self.authorizedRequest(path: "vendor", method: "POST", body: body, contentType: "application/json") },
            decode: QuickBooksVendorResponse.self
        ) { result in
            completion(result.map(\.Vendor))
        }
    }

    func fetchTimeActivities(completion: @escaping (Result<[QuickBooksTimeActivity], Error>) -> Void) {
        performAuthorizedDecodingRequest(
            { self.makeQueryRequest("SELECT * FROM TimeActivity") },
            decode: QuickBooksTimeActivityQueryResponse.self
        ) { result in
            completion(result.map { $0.QueryResponse.TimeActivity ?? [] })
        }
    }

    func createTimeActivity(_ activity: QuickBooksTimeActivityCreate, completion: @escaping (Result<QuickBooksTimeActivity, Error>) -> Void) {
        let body = try? JSONEncoder().encode(activity)
        performAuthorizedDecodingRequest(
            { self.authorizedRequest(path: "timeactivity", method: "POST", body: body, contentType: "application/json") },
            decode: QuickBooksTimeActivityResponse.self
        ) { result in
            completion(result.map(\.TimeActivity))
        }
    }

    func fetchPayments(completion: @escaping (Result<[QuickBooksPayment], Error>) -> Void) {
        performAuthorizedDecodingRequest(
            { self.makeQueryRequest("SELECT * FROM Payment") },
            decode: QuickBooksPaymentQueryResponse.self
        ) { result in
            completion(result.map { $0.QueryResponse.Payment ?? [] })
        }
    }

    func createPayment(_ payment: QuickBooksPaymentCreate, completion: @escaping (Result<QuickBooksPayment, Error>) -> Void) {
        let body = try? JSONEncoder().encode(payment)
        performAuthorizedDecodingRequest(
            { self.authorizedRequest(path: "payment", method: "POST", body: body, contentType: "application/json") },
            decode: QuickBooksPaymentResponse.self
        ) { result in
            completion(result.map(\.Payment))
        }
    }

    func fetchSalesReceipts(completion: @escaping (Result<[QuickBooksSalesReceipt], Error>) -> Void) {
        performAuthorizedDecodingRequest(
            { self.makeQueryRequest("SELECT * FROM SalesReceipt") },
            decode: QuickBooksSalesReceiptQueryResponse.self
        ) { result in
            completion(result.map { $0.QueryResponse.SalesReceipt ?? [] })
        }
    }

    func createSalesReceipt(_ salesReceipt: QuickBooksSalesReceiptCreate, completion: @escaping (Result<QuickBooksSalesReceipt, Error>) -> Void) {
        let body = try? JSONEncoder().encode(salesReceipt)
        performAuthorizedDecodingRequest(
            { self.authorizedRequest(path: "salesreceipt", method: "POST", body: body, contentType: "application/json") },
            decode: QuickBooksSalesReceiptResponse.self
        ) { result in
            completion(result.map(\.SalesReceipt))
        }
    }

    func fetchPaymentMethods(completion: @escaping (Result<[QuickBooksPaymentMethod], Error>) -> Void) {
        performAuthorizedDecodingRequest(
            { self.makeQueryRequest("SELECT * FROM PaymentMethod") },
            decode: QuickBooksPaymentMethodQueryResponse.self
        ) { result in
            completion(result.map { $0.QueryResponse.PaymentMethod ?? [] })
        }
    }

    func createPaymentMethod(_ method: QuickBooksPaymentMethodCreate, completion: @escaping (Result<QuickBooksPaymentMethod, Error>) -> Void) {
        let body = try? JSONEncoder().encode(method)
        performAuthorizedDecodingRequest(
            { self.authorizedRequest(path: "paymentmethod", method: "POST", body: body, contentType: "application/json") },
            decode: QuickBooksPaymentMethodResponse.self
        ) { result in
            completion(result.map(\.PaymentMethod))
        }
    }

    func fetchDeposits(completion: @escaping (Result<[QuickBooksDeposit], Error>) -> Void) {
        performAuthorizedDecodingRequest(
            { self.makeQueryRequest("SELECT * FROM Deposit") },
            decode: QuickBooksDepositQueryResponse.self
        ) { result in
            completion(result.map { $0.QueryResponse.Deposit ?? [] })
        }
    }

    func createDeposit(_ deposit: QuickBooksDepositCreate, completion: @escaping (Result<QuickBooksDeposit, Error>) -> Void) {
        let body = try? JSONEncoder().encode(deposit)
        performAuthorizedDecodingRequest(
            { self.authorizedRequest(path: "deposit", method: "POST", body: body, contentType: "application/json") },
            decode: QuickBooksDepositResponse.self
        ) { result in
            completion(result.map(\.Deposit))
        }
    }

    func fetchAccounts(
        accountType: String? = nil,
        completion: @escaping (Result<[QuickBooksAccount], Error>) -> Void
    ) {
        let fields = "Id, Name, FullyQualifiedName, AccountType, AccountSubType, Classification, Active"
        var sql = "select \(fields) from Account where Active = true"
        if let accountType = accountType?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accountType.isEmpty {
            sql += " and AccountType = '\(Self.escapeQueryString(accountType))'"
        }
        sql += " order by FullyQualifiedName"

        performAuthorizedDecodingRequest(
            { self.makeQueryRequest(sql) },
            decode: QuickBooksAccountQueryResponse.self
        ) { result in
            completion(result.map { $0.QueryResponse.Account ?? [] })
        }
    }

    func createCardToken(_ tokenRequest: QuickBooksPaymentsTokenCreateRequest, completion: @escaping (Result<QuickBooksPaymentsTokenResponse, Error>) -> Void) {
        let body = try? JSONEncoder().encode(tokenRequest)
        performPaymentsTokenRequest(
            { self.authorizedPaymentsRequest(path: "tokens", method: "POST", body: body, contentType: "application/json") },
            completion: completion
        )
    }

    func createCharge(_ charge: QuickBooksPaymentsChargeCreate, completion: @escaping (Result<QuickBooksPaymentsChargeResponse, Error>) -> Void) {
        let body = try? JSONEncoder().encode(charge)
        performPaymentsChargeRequest(
            { self.authorizedPaymentsRequest(path: "charges", method: "POST", body: body, contentType: "application/json") },
            completion: completion
        )
    }

    func fetchCards(
        completion: @escaping (Result<[QuickBooksPaymentsCardRecord], Error>) -> Void
    ) {
        // QuickBooks Payments cards are customer-scoped. Use fetchCards(forCustomerID:) or
        // fetchCards(forCustomerIDs:) when a QBO customer ID is available.
        completion(.success([]))
    }

    func fetchCards(
        forCustomerID customerID: String,
        completion: @escaping (Result<[QuickBooksPaymentsCardRecord], Error>) -> Void
    ) {
        let trimmedID = customerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty,
              let encodedID = trimmedID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            completion(.failure(QBError.missingCustomerIDForStoredCards))
            return
        }

        performPaymentsDecodingRequest(
            { self.authorizedPaymentsCustomerRequest(path: "customers/\(encodedID)/cards") },
            decode: QuickBooksPaymentsCardsResponse.self
        ) { result in
            switch result {
            case .success(let response):
                completion(.success(response.items))
            case .failure(let error):
                if Self.isStoredCardsNotAvailable(error) {
                    completion(.success([]))
                    return
                }
                completion(.failure(error))
            }
        }
    }

    func fetchCards(
        forCustomerIDs customerIDs: [String],
        completion: @escaping (Result<[QuickBooksPaymentsCardRecord], Error>) -> Void
    ) {
        let uniqueIDs = Array(NSOrderedSet(array: customerIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })) as? [String] ?? []
        guard !uniqueIDs.isEmpty else {
            completion(.success([]))
            return
        }

        var aggregate: [QuickBooksPaymentsCardRecord] = []
        func fetchNext(_ index: Int) {
            guard index < uniqueIDs.count else {
                completion(.success(aggregate))
                return
            }
            fetchCards(forCustomerID: uniqueIDs[index]) { result in
                switch result {
                case .success(let cards):
                    aggregate.append(contentsOf: cards)
                    fetchNext(index + 1)
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
        fetchNext(0)
    }

    func createStoredCard(_ card: QuickBooksPaymentsStoredCardCreateRequest, completion: @escaping (Result<QuickBooksPaymentsCardRecord, Error>) -> Void) {
        completion(.failure(QBError.missingCustomerIDForStoredCards))
    }

    func createStoredCard(
        _ card: QuickBooksPaymentsStoredCardCreateRequest,
        forCustomerID customerID: String,
        completion: @escaping (Result<QuickBooksPaymentsCardRecord, Error>) -> Void
    ) {
        let trimmedID = customerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty,
              let encodedID = trimmedID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            completion(.failure(QBError.missingCustomerIDForStoredCards))
            return
        }

        let body = try? JSONEncoder().encode(card)
        performPaymentsDecodingRequest(
            { self.authorizedPaymentsCustomerRequest(path: "customers/\(encodedID)/cards/createFromToken", method: "POST", body: body, contentType: "application/json") },
            decode: QuickBooksPaymentsCardRecord.self,
            completion: completion
        )
    }

    func fetchPaymentReceipt(id: String, completion: @escaping (Result<QuickBooksPaymentsPaymentReceipt, Error>) -> Void) {
        performPaymentsDecodingRequest(
            { self.authorizedPaymentsRequest(path: "paymentreceipt/\(id)") },
            decode: QuickBooksPaymentsPaymentReceipt.self,
            completion: completion
        )
    }

    func captureCharge(id: String, amount: Double, completion: @escaping (Result<QuickBooksPaymentsChargeResponse, Error>) -> Void) {
        let body = try? JSONEncoder().encode(QuickBooksPaymentsChargeCaptureRequest(amount: amount))
        performPaymentsDecodingRequest(
            { self.authorizedPaymentsRequest(path: "charges/\(id)/capture", method: "POST", body: body, contentType: "application/json") },
            decode: QuickBooksPaymentsChargeResponse.self,
            completion: completion
        )
    }

    func refundCharge(
        id: String,
        amount: Double,
        description: String?,
        clientTransactionID: String? = nil,
        completion: @escaping (Result<QuickBooksPaymentsRefundResponse, Error>) -> Void
    ) {
        let body = try? JSONEncoder().encode(
            QuickBooksPaymentsRefundRequest(
                amount: amount,
                description: description,
                context: QuickBooksPaymentsChargeContext.forClientTransactionID(clientTransactionID)
            )
        )
        performPaymentsDecodingRequest(
            { self.authorizedPaymentsRequest(path: "charges/\(id)/refunds", method: "POST", body: body, contentType: "application/json") },
            decode: QuickBooksPaymentsRefundResponse.self,
            completion: completion
        )
    }

    func createRefundReceipt(_ receipt: QuickBooksRefundReceiptCreate, completion: @escaping (Result<QuickBooksRefundReceipt, Error>) -> Void) {
        let body = try? JSONEncoder().encode(receipt)
        performAuthorizedDecodingRequest(
            { self.authorizedRequest(path: "refundreceipt", method: "POST", body: body, contentType: "application/json") },
            decode: QuickBooksRefundReceiptResponse.self
        ) { result in
            completion(result.map(\.RefundReceipt))
        }
    }

    func uploadDocument(
        fileURL: URL,
        note: String? = nil,
        attachToEntityType: QuickBooksAttachableEntityType? = nil,
        attachToEntityID: String? = nil,
        completion: @escaping (Result<String, Error>) -> Void,
        attempt: Int = 0
    ) {
        let attachableReferences: [QuickBooksAttachableReference]
        if let attachToEntityType, let attachToEntityID, !attachToEntityID.isEmpty {
            attachableReferences = [
                QuickBooksAttachableReference(
                    EntityRef: QuickBooksAttachableEntityRef(
                        type: attachToEntityType.rawValue,
                        value: attachToEntityID
                    ),
                    IncludeOnSend: true
                )
            ]
        } else {
            attachableReferences = []
        }
        uploadDocument(
            fileURL: fileURL,
            note: note,
            attachableReferences: attachableReferences,
            completion: completion,
            attempt: attempt
        )
    }

    func uploadDocument(
        fileURL: URL,
        note: String? = nil,
        attachableReferences: [QuickBooksAttachableReference],
        completion: @escaping (Result<String, Error>) -> Void,
        attempt: Int = 0
    ) {
        refreshTokensIfNeeded { ok in
            guard ok else {
                completion(.failure(QBError.unauthorized))
                return
            }

            let filename = fileURL.lastPathComponent
            let contentType = Self.mimeType(for: fileURL)
            let boundary = "Boundary-\(UUID().uuidString)"

            let metadata = QuickBooksUploadMetadata(
                FileName: filename,
                ContentType: contentType,
                Note: note ?? "Uploaded from GunnAire Ops",
                AttachableRef: attachableReferences.isEmpty ? nil : attachableReferences
            )

            guard
                let fileData = try? Data(contentsOf: fileURL),
                let metadataData = try? JSONEncoder().encode(metadata),
                let metadataJSON = String(data: metadataData, encoding: .utf8)
            else {
                completion(.failure(QBError.noData))
                return
            }

            let body = Self.buildUploadBody(
                boundary: boundary,
                filename: filename,
                contentType: contentType,
                fileData: fileData,
                metadataJSON: metadataJSON
            )

            guard let request = self.authorizedRequest(
                path: "upload",
                method: "POST",
                body: body,
                contentType: "multipart/form-data; boundary=\(boundary)"
            ) else {
                completion(.failure(QBError.unauthorized))
                return
            }

            URLSession.shared.dataTask(with: request) { data, response, error in
                    if let delay = self.retryDelayIfRateLimited(response: response, attempt: attempt) {
                        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                            self.uploadDocument(
                                fileURL: fileURL,
                                note: note,
                                attachableReferences: attachableReferences,
                                completion: completion,
                                attempt: attempt + 1
                            )
                    }
                    return
                }
                Task { @MainActor in
                    if let error {
                        completion(.failure(error))
                        return
                    }
                    if let httpError = self.resolveHTTPError(data: data, response: response) {
                        self.clearRejectedSessionIfNeeded(httpError)
                        completion(.failure(httpError))
                        return
                    }
                    guard let data else {
                        completion(.failure(QBError.noData))
                        return
                    }
                    if let parsed = try? JSONDecoder().decode(QuickBooksUploadResponse.self, from: data),
                       let attachable = parsed.AttachableResponse.first {
                        completion(.success(attachable.Id))
                        return
                    }
                    completion(.success("uploaded-\(filename)"))
                }
            }.resume()
        }
    }

    static func buildUploadBody(boundary: String, filename: String, contentType: String, fileData: Data, metadataJSON: String) -> Data {
        var body = Data()
        let lineBreak = "\r\n"

        body.append("--\(boundary)\(lineBreak)")
        body.append("Content-Disposition: form-data; name=\"file_metadata_01\"; filename=\"attachment.json\"\(lineBreak)")
        body.append("Content-Type: application/json; charset=UTF-8\(lineBreak)")
        body.append("Content-Transfer-Encoding: 8bit\(lineBreak)\(lineBreak)")
        body.append("\(metadataJSON)\(lineBreak)")

        body.append("--\(boundary)\(lineBreak)")
        body.append("Content-Disposition: form-data; name=\"file_content_01\"; filename=\"\(filename)\"\(lineBreak)")
        body.append("Content-Type: \(contentType)\(lineBreak)")
        body.append("Content-Transfer-Encoding: binary\(lineBreak)\(lineBreak)")
        body.append(fileData)
        body.append(lineBreak)
        body.append("--\(boundary)--\(lineBreak)")
        return body
    }

    static func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        case "rtf": return "application/rtf"
        default: return "application/octet-stream"
        }
    }

    static func escapeQueryString(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "\\'")
    }

    enum QBError: Error, LocalizedError {
        case unauthorized
        case missingConfiguration
        case noData
        case decoding
        case decodingDetail(String)
        case http(statusCode: Int)
        case api(statusCode: Int, detail: String)
        case httpDetail(statusCode: Int, detail: String)
        case authorizationFailed(statusCode: Int, detail: String)
        case paymentsAuthorizationFailed(statusCode: Int, detail: String)
        case paymentsScopeDisabled
        case missingDefaultIncomeAccountRef
        case missingSyncToken(entity: String)
        case rateLimited(detail: String)
        case missingCustomerIDForStoredCards

        var requiresReconnect: Bool {
            switch self {
            case .unauthorized, .authorizationFailed:
                return true
            default:
                return false
            }
        }

        var errorDescription: String? {
            switch self {
            case .unauthorized:
                return "QuickBooks access token is missing or expired. Reconnect QuickBooks in Settings."
            case .missingConfiguration:
                return "QuickBooks is not configured. Set QB_CLIENT_ID and the HTTPS redirect URI in the app, then configure the QuickBooks client secret only in the backend environment."
            case .noData:
                return "QuickBooks returned no data."
            case .decoding:
                return "QuickBooks response decoding failed."
            case .decodingDetail(let detail):
                return "QuickBooks response decoding failed: \(detail)"
            case .http(let statusCode):
                return "QuickBooks request failed (HTTP \(statusCode))."
            case .api(let statusCode, let detail):
                return "QuickBooks API error (HTTP \(statusCode)): \(detail)"
            case .httpDetail(let statusCode, let detail):
                return "QuickBooks request failed (HTTP \(statusCode)): \(detail)"
            case .authorizationFailed(let statusCode, let detail):
                return "QuickBooks authorization needs attention (HTTP \(statusCode)). \(detail) Reconnect QuickBooks, then retry sync."
            case .paymentsAuthorizationFailed(let statusCode, let detail):
                return "QuickBooks Payments authorization needs attention (HTTP \(statusCode)). \(detail) Accounting sync can remain connected; reconnect only after enabling Payments access in Intuit."
            case .paymentsScopeDisabled:
                return "QuickBooks Payments scope is disabled for this build. Enable QB_ENABLE_PAYMENTS_SCOPE, authorize the Payments permission in Intuit, then reconnect QuickBooks before using live payment endpoints."
            case .missingDefaultIncomeAccountRef:
                return "QuickBooks needs an income account before the app can create new Products and Services. Set QB_DEFAULT_INCOME_ACCOUNT_REF to a valid QBO income Account.Id, or sync a default QuickBooks item that already has an IncomeAccountRef."
            case .missingSyncToken(let entity):
                return "QuickBooks did not return the current SyncToken for \(entity). Refresh accounting data, then retry so the app does not overwrite a newer change."
            case .rateLimited(let detail):
                return detail
            case .missingCustomerIDForStoredCards:
                return "QuickBooks stored cards require a QuickBooks Customer.Id. Select or sync a customer before storing or fetching cards."
            }
        }
    }
}

private extension QuickBooksDataAPI {
    func paymentsScopeReadinessError() -> QBError? {
        guard Config.QuickBooks.enablePaymentsScope else {
            return .paymentsScopeDisabled
        }
        guard !savedSessionIncludesPaymentsScope else {
            return nil
        }
        return .paymentsAuthorizationFailed(
            statusCode: 403,
            detail: "This saved QuickBooks session is not authorized for \(Config.QuickBooks.paymentsScope). Accounting can remain connected, but QuickBooks Payments calls require Intuit Payments access for this company and a Payments-authorized token."
        )
    }

    func performPaymentsTokenRequest(
        _ requestBuilder: @escaping () -> URLRequest?,
        completion: @escaping (Result<QuickBooksPaymentsTokenResponse, Error>) -> Void,
        attempt: Int = 0
    ) {
        if let scopeError = paymentsScopeReadinessError() {
            completion(.failure(scopeError))
            return
        }
        refreshTokensIfNeeded { ok in
            guard ok, let request = requestBuilder() else {
                completion(.failure(QBError.unauthorized))
                return
            }

            URLSession.shared.dataTask(with: request) { data, response, error in
                if let delay = self.retryDelayIfRateLimited(response: response, attempt: attempt) {
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self.performPaymentsTokenRequest(requestBuilder, completion: completion, attempt: attempt + 1)
                    }
                    return
                }
                Task { @MainActor in
                    if let error {
                        completion(.failure(error))
                        return
                    }
                    if let httpError = self.resolvePaymentsHTTPError(data: data, response: response) {
                        self.clearRejectedSessionIfNeeded(httpError)
                        completion(.failure(httpError))
                        return
                    }
                    guard let data, !data.isEmpty else {
                        completion(.failure(QBError.decodingDetail("QuickBooks Payments returned an empty token response. Headers: \(Self.headerSummary(response))")))
                        return
                    }
                    if let decoded = try? JSONDecoder().decode(QuickBooksPaymentsTokenResponse.self, from: data),
                       !decoded.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        completion(.success(decoded))
                        return
                    }
                    let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if let token = Self.firstStringValue(in: data, matching: ["value", "token", "id"]), !token.isEmpty {
                        completion(.success(QuickBooksPaymentsTokenResponse(value: token)))
                        return
                    }
                    completion(.failure(QBError.decodingDetail("Unable to find a token value in QuickBooks Payments response. Raw response: \(raw.prefix(8000))")))
                }
            }.resume()
        }
    }

    func performPaymentsChargeRequest(
        _ requestBuilder: @escaping () -> URLRequest?,
        completion: @escaping (Result<QuickBooksPaymentsChargeResponse, Error>) -> Void,
        attempt: Int = 0
    ) {
        if let scopeError = paymentsScopeReadinessError() {
            completion(.failure(scopeError))
            return
        }
        refreshTokensIfNeeded { ok in
            guard ok, let request = requestBuilder() else {
                completion(.failure(QBError.unauthorized))
                return
            }

            URLSession.shared.dataTask(with: request) { data, response, error in
                if let delay = self.retryDelayIfRateLimited(response: response, attempt: attempt) {
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self.performPaymentsChargeRequest(requestBuilder, completion: completion, attempt: attempt + 1)
                    }
                    return
                }
                Task { @MainActor in
                    if let error {
                        completion(.failure(error))
                        return
                    }
                    if let httpError = self.resolvePaymentsHTTPError(data: data, response: response) {
                        self.clearRejectedSessionIfNeeded(httpError)
                        completion(.failure(httpError))
                        return
                    }

                    let headerChargeID = Self.chargeIDFromHeaders(response)
                    guard let data, !data.isEmpty else {
                        if let headerChargeID {
                            completion(.success(QuickBooksPaymentsChargeResponse.placeholder(id: headerChargeID, status: "captured")))
                        } else {
                            completion(.failure(QBError.decodingDetail("QuickBooks Payments returned an empty charge response. Headers: \(Self.headerSummary(response))")))
                        }
                        return
                    }

                    if let decoded = try? JSONDecoder().decode(QuickBooksPaymentsChargeResponse.self, from: data) {
                        completion(.success(decoded))
                        return
                    }

                    let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if let charge = Self.chargeResponseFromRawJSON(data: data, fallbackID: headerChargeID) {
                        completion(.success(charge))
                        return
                    }

                    completion(.failure(QBError.decodingDetail("Unable to parse QuickBooks Payments charge response. Raw response: \(raw.prefix(8000)). Headers: \(Self.headerSummary(response))")))
                }
            }.resume()
        }
    }

    static func isStoredCardsNotAvailable(_ error: Error) -> Bool {
        guard let qbError = error as? QBError else { return false }
        switch qbError {
        case .http(let statusCode):
            return statusCode == 404
        case .httpDetail(let statusCode, let detail):
            return statusCode == 404 || detail.lowercased().contains("not found")
        case .api(let statusCode, let detail):
            return statusCode == 404 || detail.lowercased().contains("not found")
        default:
            return false
        }
    }

    static func headerSummary(_ response: URLResponse?) -> String {
        guard let http = response as? HTTPURLResponse else { return "No HTTP response" }
        return http.allHeaderFields.map { "\($0.key): \($0.value)" }.joined(separator: "; ")
    }

    static func chargeIDFromHeaders(_ response: URLResponse?) -> String? {
        guard let http = response as? HTTPURLResponse else { return nil }
        let candidates = ["Location", "location", "Intuit-Tid", "intuit_tid", "intuit_tid"]
        for key in candidates {
            if let value = http.allHeaderFields[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.contains("/") {
                    return trimmed.split(separator: "/").last.map(String.init)
                }
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    static func firstStringValue(in data: Data, matching keys: Set<String>) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return firstStringValue(in: json, matching: keys)
    }

    static func firstStringValue(in value: Any, matching keys: Set<String>) -> String? {
        if let dict = value as? [String: Any] {
            for (key, raw) in dict where keys.contains(key) {
                if let str = raw as? String, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return str }
                if let num = raw as? NSNumber { return num.stringValue }
            }
            for raw in dict.values {
                if let found = firstStringValue(in: raw, matching: keys) { return found }
            }
        } else if let array = value as? [Any] {
            for raw in array {
                if let found = firstStringValue(in: raw, matching: keys) { return found }
            }
        }
        return nil
    }

    static func firstBoolValue(in value: Any, matching keys: Set<String>) -> Bool? {
        if let dict = value as? [String: Any] {
            for (key, raw) in dict where keys.contains(key) {
                if let bool = raw as? Bool { return bool }
                if let num = raw as? NSNumber { return num.boolValue }
                if let str = raw as? String {
                    let normalized = str.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if ["true", "1", "yes", "y"].contains(normalized) { return true }
                    if ["false", "0", "no", "n"].contains(normalized) { return false }
                }
            }
            for raw in dict.values {
                if let found = firstBoolValue(in: raw, matching: keys) { return found }
            }
        } else if let array = value as? [Any] {
            for raw in array {
                if let found = firstBoolValue(in: raw, matching: keys) { return found }
            }
        }
        return nil
    }

    static func chargeResponseFromRawJSON(data: Data, fallbackID: String?) -> QuickBooksPaymentsChargeResponse? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let id = firstStringValue(in: json, matching: ["id", "chargeId", "chargeID", "paymentId", "paymentID", "txnId", "TxnId"]) ?? fallbackID
        guard let id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return QuickBooksPaymentsChargeResponse(
            created: firstStringValue(in: json, matching: ["created", "createdAt", "TxnDate", "txnDate"]),
            status: firstStringValue(in: json, matching: ["status", "Status"]),
            amount: firstStringValue(in: json, matching: ["amount", "Amount", "TotalAmt", "totalAmt"]),
            currency: firstStringValue(in: json, matching: ["currency", "Currency", "currencyCode"]),
            token: firstStringValue(in: json, matching: ["token", "value"]),
            capture: firstBoolValue(in: json, matching: ["capture", "captured"]),
            id: id,
            authCode: firstStringValue(in: json, matching: ["authCode", "authorizationCode", "authorization_code"]),
            clientTransID: firstStringValue(in: json, matching: ["clientTransID", "clientTransId", "clientTransactionID"]),
            card: nil,
            context: nil,
            captureDetail: nil
        )
    }
}

private struct QuickBooksRefreshTokenResponse: Codable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Double
}

struct QuickBooksCompanyInfoResponse: Codable {
    let CompanyInfo: QuickBooksCompanyInfo
}

struct QuickBooksCompanyInfo: Codable {
    let Id: String?
    let CompanyName: String?
    let LegalName: String?
    let Country: String?
    let Email: QuickBooksCompanyEmailAddress?
}

struct QuickBooksCompanyEmailAddress: Codable {
    let Address: String?
}

struct QuickBooksReference: Codable, Hashable {
    let value: String
    let name: String?

    init(value: String, name: String?) {
        self.value = value
        self.name = name
    }

    private enum CodingKeys: String, CodingKey {
        case value
        case name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name)
    }

    var displayName: String {
        if let name, !name.isEmpty {
            return name
        }
        return value
    }
}

struct QuickBooksEmailAddress: Codable {
    let Address: String
}

struct QuickBooksPhoneNumber: Codable {
    let FreeFormNumber: String
}

struct QuickBooksAddress: Codable {
    let Line1: String?
}

struct QuickBooksLineItem: Codable {
    let Amount: Double
    let DetailType: String
    let Description: String?
    let SalesItemLineDetail: QuickBooksSalesItemLineDetail
}

struct QuickBooksSalesItemLineDetail: Codable {
    let ItemRef: QuickBooksReference
    let Qty: Double?
    let UnitPrice: Double?

    init(ItemRef: QuickBooksReference, Qty: Double? = nil, UnitPrice: Double? = nil) {
        self.ItemRef = ItemRef
        self.Qty = Qty
        self.UnitPrice = UnitPrice
    }
}

struct QuickBooksAccountBasedExpenseLineDetail: Codable {
    let AccountRef: QuickBooksReference
}

struct QuickBooksBillLine: Codable {
    let Amount: Double
    let DetailType: String
    let Description: String?
    let AccountBasedExpenseLineDetail: QuickBooksAccountBasedExpenseLineDetail

    init(amount: Double, description: String?, accountRef: QuickBooksReference) {
        Amount = amount
        DetailType = "AccountBasedExpenseLineDetail"
        Description = description
        AccountBasedExpenseLineDetail = QuickBooksAccountBasedExpenseLineDetail(AccountRef: accountRef)
    }
}

struct QuickBooksLinkedTxn: Codable {
    let TxnId: String
    let TxnType: String
}

struct QuickBooksPaymentLine: Codable {
    let Amount: Double
    let LinkedTxn: [QuickBooksLinkedTxn]?

    private enum CodingKeys: String, CodingKey {
        case Amount, LinkedTxn
    }

    init(Amount: Double, LinkedTxn: [QuickBooksLinkedTxn]?) {
        self.Amount = Amount
        self.LinkedTxn = LinkedTxn
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        Amount = Self.decodeFlexibleDouble(container, key: .Amount) ?? 0
        LinkedTxn = try container.decodeIfPresent([QuickBooksLinkedTxn].self, forKey: .LinkedTxn)
    }

    private static func decodeFlexibleDouble(_ container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Double? {
        if let doubleValue = try? container.decodeIfPresent(Double.self, forKey: key) {
            return doubleValue
        }
        if let intValue = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Double(intValue)
        }
        if let stringValue = try? container.decodeIfPresent(String.self, forKey: key) {
            return Double(stringValue)
        }
        return nil
    }
}

struct QuickBooksCustomerQueryResponse: Codable {
    let QueryResponse: QuickBooksCustomerList
}

struct QuickBooksCustomerList: Codable {
    let Customer: [QuickBooksCustomer]?
}

struct QuickBooksCustomer: Codable, Identifiable {
    let Id: String
    let DisplayName: String
    let PrimaryPhone: QuickBooksPhoneNumber?
    let PrimaryEmailAddr: QuickBooksEmailAddress?
    let BillAddr: QuickBooksAddress?

    var id: String { Id }
    var reference: QuickBooksReference { QuickBooksReference(value: Id, name: DisplayName) }
}

struct QuickBooksCustomerCreate: Codable {
    let DisplayName: String
    let PrimaryPhone: QuickBooksPhoneNumber?
    let PrimaryEmailAddr: QuickBooksEmailAddress?
    let BillAddr: QuickBooksAddress?
}

struct QuickBooksCustomerResponse: Codable {
    let Customer: QuickBooksCustomer
}

struct QuickBooksAccountQueryResponse: Codable {
    let QueryResponse: QuickBooksAccountList
}

struct QuickBooksAccountList: Codable {
    let Account: [QuickBooksAccount]?
}

struct QuickBooksAccount: Codable, Identifiable {
    let Id: String
    let Name: String
    let FullyQualifiedName: String?
    let AccountType: String?
    let AccountSubType: String?
    let Classification: String?
    let Active: Bool?

    var id: String { Id }
    var displayName: String { FullyQualifiedName ?? Name }
    var reference: QuickBooksReference { QuickBooksReference(value: Id, name: displayName) }
}

struct QuickBooksItemQueryResponse: Codable {
    let QueryResponse: QuickBooksItemList
}

struct QuickBooksItemList: Codable {
    let Item: [QuickBooksItem]?
}

struct QuickBooksItem: Codable, Identifiable {
    let Id: String
    let Name: String
    let ItemType: String?
    let Description: String?
    let Sku: String?
    let PurchaseDesc: String?
    let UnitPrice: Double?
    let PurchaseCost: Double?
    let Taxable: Bool?
    let Active: Bool?
    let IncomeAccountRef: QuickBooksReference?
    let ExpenseAccountRef: QuickBooksReference?
    let PrefVendorRef: QuickBooksReference?

    var id: String { Id }

    private enum CodingKeys: String, CodingKey {
        case Id, Name, Description, Sku, PurchaseDesc, UnitPrice, PurchaseCost, Taxable, Active, IncomeAccountRef, ExpenseAccountRef, PrefVendorRef
        case ItemType = "Type"
    }
}

struct QuickBooksItemCreate: Codable {
    let Name: String
    let ItemType: String
    let Description: String?
    let Sku: String?
    let PurchaseDesc: String?
    let UnitPrice: Double?
    let PurchaseCost: Double?
    let Taxable: Bool?
    let IncomeAccountRef: QuickBooksReference?
    let ExpenseAccountRef: QuickBooksReference?
    let PrefVendorRef: QuickBooksReference?

    private enum CodingKeys: String, CodingKey {
        case Name, Description, Sku, PurchaseDesc, UnitPrice, PurchaseCost, Taxable, IncomeAccountRef, ExpenseAccountRef, PrefVendorRef
        case ItemType = "Type"
    }
}

struct QuickBooksItemResponse: Codable {
    let Item: QuickBooksItem
}

enum QuickBooksItemAccountResolver {
    static func configuredIncomeAccountRef() -> QuickBooksReference? {
        guard Config.QuickBooks.hasExplicitDefaultIncomeAccountRef else { return nil }
        return QuickBooksReference(value: Config.QuickBooks.defaultIncomeAccountRef, name: nil)
    }

    static func configuredExpenseAccountRef() -> QuickBooksReference? {
        guard Config.QuickBooks.hasExplicitDefaultExpenseAccountRef else { return nil }
        return QuickBooksReference(value: Config.QuickBooks.defaultExpenseAccountRef, name: nil)
    }

    static func incomeAccountRef(from quickBooksItems: [QuickBooksItem]) -> QuickBooksReference? {
        if let configured = configuredIncomeAccountRef() {
            return configured
        }

        let defaultItemID = Config.QuickBooks.defaultSalesItemRef.trimmingCharacters(in: .whitespacesAndNewlines)
        if !defaultItemID.isEmpty,
           let defaultItem = quickBooksItems.first(where: { $0.Id == defaultItemID }),
           let reference = usableReference(defaultItem.IncomeAccountRef) {
            return reference
        }

        return quickBooksItems
            .filter { $0.Active != false }
            .compactMap { usableReference($0.IncomeAccountRef) }
            .first
    }

    private static func usableReference(_ reference: QuickBooksReference?) -> QuickBooksReference? {
        guard let reference else { return nil }
        let value = reference.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return QuickBooksReference(value: value, name: reference.name)
    }
}

struct QuickBooksEstimateQueryResponse: Codable {
    let QueryResponse: QuickBooksEstimateList
}

struct QuickBooksEstimateList: Codable {
    let Estimate: [QuickBooksEstimate]?
}

struct QuickBooksEstimate: Codable, Identifiable {
    let Id: String
    let DocNumber: String?
    let CustomerRef: QuickBooksReference
    let TotalAmt: Double
    let TxnDate: String?
    let BillEmail: QuickBooksEmailAddress?
    let EmailStatus: String?

    var id: String { Id }
}

struct QuickBooksEstimateCreate: Codable {
    let CustomerRef: QuickBooksReference
    let Line: [QuickBooksLineItem]
    let PrivateNote: String?
    let BillEmail: QuickBooksEmailAddress?

    init(
        CustomerRef: QuickBooksReference,
        Line: [QuickBooksLineItem],
        PrivateNote: String?,
        BillEmail: QuickBooksEmailAddress? = nil
    ) {
        self.CustomerRef = CustomerRef
        self.Line = Line
        self.PrivateNote = PrivateNote
        self.BillEmail = BillEmail
    }
}

struct QuickBooksEstimateResponse: Codable {
    let Estimate: QuickBooksEstimate
}

struct QuickBooksInvoiceQueryResponse: Codable {
    let QueryResponse: QuickBooksInvoiceList
}

struct QuickBooksInvoiceList: Codable {
    let Invoice: [QuickBooksInvoice]?
}

struct QuickBooksInvoice: Codable, Identifiable {
    let Id: String
    let SyncToken: String?
    let DocNumber: String?
    let CustomerRef: QuickBooksReference
    let TotalAmt: Double
    let Balance: Double?
    let TxnDate: String?
    let PrivateNote: String?
    let BillEmail: QuickBooksEmailAddress?
    let EmailStatus: String?

    var id: String { Id }

    private enum CodingKeys: String, CodingKey {
        case Id, SyncToken, DocNumber, CustomerRef, TotalAmt, Balance, TxnDate, PrivateNote, BillEmail, EmailStatus
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        Id = try container.decodeIfPresent(String.self, forKey: .Id) ?? UUID().uuidString
        SyncToken = try container.decodeIfPresent(String.self, forKey: .SyncToken)
        DocNumber = try container.decodeIfPresent(String.self, forKey: .DocNumber)
        CustomerRef = try container.decodeIfPresent(QuickBooksReference.self, forKey: .CustomerRef)
            ?? QuickBooksReference(value: "", name: "Unknown Customer")
        TotalAmt = Self.decodeFlexibleDouble(container, key: .TotalAmt) ?? 0
        Balance = Self.decodeFlexibleDouble(container, key: .Balance)
        TxnDate = try container.decodeIfPresent(String.self, forKey: .TxnDate)
        PrivateNote = try container.decodeIfPresent(String.self, forKey: .PrivateNote)
        BillEmail = try container.decodeIfPresent(QuickBooksEmailAddress.self, forKey: .BillEmail)
        EmailStatus = try container.decodeIfPresent(String.self, forKey: .EmailStatus)
    }

    private static func decodeFlexibleDouble(_ container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Double? {
        if let doubleValue = try? container.decodeIfPresent(Double.self, forKey: key) {
            return doubleValue
        }
        if let intValue = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Double(intValue)
        }
        if let stringValue = try? container.decodeIfPresent(String.self, forKey: key) {
            return Double(stringValue)
        }
        return nil
    }
}

struct QuickBooksInvoiceCreate: Codable {
    let CustomerRef: QuickBooksReference
    let Line: [QuickBooksLineItem]
    let PrivateNote: String?
    let BillEmail: QuickBooksEmailAddress?

    init(
        CustomerRef: QuickBooksReference,
        Line: [QuickBooksLineItem],
        PrivateNote: String?,
        BillEmail: QuickBooksEmailAddress? = nil
    ) {
        self.CustomerRef = CustomerRef
        self.Line = Line
        self.PrivateNote = PrivateNote
        self.BillEmail = BillEmail
    }
}

struct QuickBooksInvoiceUpdate: Codable {
    let Id: String
    let SyncToken: String
    let sparse: Bool
    let CustomerRef: QuickBooksReference
    let Line: [QuickBooksLineItem]
    let PrivateNote: String?
    let BillEmail: QuickBooksEmailAddress?

    init(
        Id: String,
        SyncToken: String,
        CustomerRef: QuickBooksReference,
        Line: [QuickBooksLineItem],
        PrivateNote: String?,
        BillEmail: QuickBooksEmailAddress? = nil
    ) {
        self.Id = Id
        self.SyncToken = SyncToken
        self.sparse = true
        self.CustomerRef = CustomerRef
        self.Line = Line
        self.PrivateNote = PrivateNote
        self.BillEmail = BillEmail
    }
}

struct QuickBooksInvoiceResponse: Codable {
    let Invoice: QuickBooksInvoice
}

struct QuickBooksBillQueryResponse: Codable {
    let QueryResponse: QuickBooksBillList
}

struct QuickBooksBillList: Codable {
    let Bill: [QuickBooksBill]?
}

struct QuickBooksBill: Codable, Identifiable {
    let Id: String
    let VendorRef: QuickBooksReference
    let TotalAmt: Double
    let Balance: Double?
    let TxnDate: String?
    let DueDate: String?
    let PrivateNote: String?

    var id: String { Id }

    private enum CodingKeys: String, CodingKey {
        case Id, VendorRef, TotalAmt, Balance, TxnDate, DueDate, PrivateNote
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        Id = try container.decodeIfPresent(String.self, forKey: .Id) ?? UUID().uuidString
        VendorRef = try container.decodeIfPresent(QuickBooksReference.self, forKey: .VendorRef)
            ?? QuickBooksReference(value: "", name: "Unknown Vendor")
        TotalAmt = try container.decodeIfPresent(Double.self, forKey: .TotalAmt) ?? 0
        Balance = try container.decodeIfPresent(Double.self, forKey: .Balance)
        TxnDate = try container.decodeIfPresent(String.self, forKey: .TxnDate)
        DueDate = try container.decodeIfPresent(String.self, forKey: .DueDate)
        PrivateNote = try container.decodeIfPresent(String.self, forKey: .PrivateNote)
    }
}

struct QuickBooksBillCreate: Codable {
    let VendorRef: QuickBooksReference
    let Line: [QuickBooksBillLine]
    let PrivateNote: String?
}

struct QuickBooksBillResponse: Codable {
    let Bill: QuickBooksBill
}

struct QuickBooksPurchaseQueryResponse: Codable {
    let QueryResponse: QuickBooksPurchaseList
}

struct QuickBooksPurchaseList: Codable {
    let Purchase: [QuickBooksPurchase]?
}

struct QuickBooksPurchase: Codable, Identifiable {
    let Id: String
    let AccountRef: QuickBooksReference?
    let EntityRef: QuickBooksReference?
    let TotalAmt: Double
    let TxnDate: String?
    let PrivateNote: String?
    let PaymentType: String?

    var id: String { Id }
}

struct QuickBooksPurchaseCreate: Codable {
    let AccountRef: QuickBooksReference
    let EntityRef: QuickBooksReference?
    let Line: [QuickBooksBillLine]
    let PaymentType: String?
    let PrivateNote: String?
}

struct QuickBooksPurchaseResponse: Codable {
    let Purchase: QuickBooksPurchase
}

struct QuickBooksVendorQueryResponse: Codable {
    let QueryResponse: QuickBooksVendorList
}

struct QuickBooksVendorList: Codable {
    let Vendor: [QuickBooksVendor]?
}

struct QuickBooksVendor: Codable, Identifiable {
    let Id: String
    let DisplayName: String
    let PrimaryEmailAddr: QuickBooksEmailAddress?
    let PrimaryPhone: QuickBooksPhoneNumber?

    var id: String { Id }
    var reference: QuickBooksReference { QuickBooksReference(value: Id, name: DisplayName) }

    private enum CodingKeys: String, CodingKey {
        case Id, DisplayName, PrimaryEmailAddr, PrimaryPhone
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        Id = try container.decodeIfPresent(String.self, forKey: .Id) ?? UUID().uuidString
        DisplayName = try container.decodeIfPresent(String.self, forKey: .DisplayName) ?? "Unnamed Vendor"
        PrimaryEmailAddr = try container.decodeIfPresent(QuickBooksEmailAddress.self, forKey: .PrimaryEmailAddr)
        PrimaryPhone = try container.decodeIfPresent(QuickBooksPhoneNumber.self, forKey: .PrimaryPhone)
    }
}

struct QuickBooksVendorCreate: Codable {
    let DisplayName: String
    let PrimaryEmailAddr: QuickBooksEmailAddress?
    let PrimaryPhone: QuickBooksPhoneNumber?
}

struct QuickBooksVendorResponse: Codable {
    let Vendor: QuickBooksVendor
}

struct QuickBooksTimeActivityQueryResponse: Codable {
    let QueryResponse: QuickBooksTimeActivityList
}

struct QuickBooksTimeActivityList: Codable {
    let TimeActivity: [QuickBooksTimeActivity]?
}

struct QuickBooksTimeActivity: Codable, Identifiable {
    let Id: String
    let SyncToken: String?
    let TxnDate: String?
    let NameOf: String?
    let EmployeeRef: QuickBooksReference?
    let VendorRef: QuickBooksReference?
    let CustomerRef: QuickBooksReference?
    let ProjectRef: QuickBooksReference?
    let ItemRef: QuickBooksReference?
    let PayrollItemRef: QuickBooksReference?
    let Hours: Int?
    let Minutes: Int?
    let Description: String?

    var id: String { Id }
}

struct QuickBooksTimeActivityCreate: Codable {
    let TxnDate: String
    let NameOf: String
    let EmployeeRef: QuickBooksReference?
    let VendorRef: QuickBooksReference?
    let CustomerRef: QuickBooksReference?
    let ProjectRef: QuickBooksReference?
    let ItemRef: QuickBooksReference?
    let PayrollItemRef: QuickBooksReference?
    let Hours: Int
    let Minutes: Int
    let Description: String?
}

struct QuickBooksTimeActivityResponse: Codable {
    let TimeActivity: QuickBooksTimeActivity
}

struct QuickBooksPaymentQueryResponse: Codable {
    let QueryResponse: QuickBooksPaymentList
}

struct QuickBooksPaymentList: Codable {
    let Payment: [QuickBooksPayment]?

    private enum CodingKeys: String, CodingKey {
        case Payment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let array = try? container.decodeIfPresent([QuickBooksPayment].self, forKey: .Payment) {
            Payment = array
        } else if let single = try? container.decodeIfPresent(QuickBooksPayment.self, forKey: .Payment) {
            Payment = [single]
        } else {
            Payment = nil
        }
    }
}

struct QuickBooksPayment: Codable, Identifiable {
    let Id: String
    let CustomerRef: QuickBooksReference?
    let TotalAmt: Double
    let TxnDate: String?
    let PrivateNote: String?
    let PaymentRefNum: String?
    let Line: [QuickBooksPaymentLine]?
    let PaymentMethodRef: QuickBooksReference?
    let CreditCardPayment: QuickBooksCreditCardPayment?

    var id: String { Id }

    private enum CodingKeys: String, CodingKey {
        case Id, CustomerRef, TotalAmt, TxnDate, PrivateNote, PaymentRefNum, Line, PaymentMethodRef, CreditCardPayment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        Id = try container.decodeIfPresent(String.self, forKey: .Id) ?? UUID().uuidString
        CustomerRef = try container.decodeIfPresent(QuickBooksReference.self, forKey: .CustomerRef)
        TotalAmt = Self.decodeFlexibleDouble(container, key: .TotalAmt) ?? 0
        TxnDate = try container.decodeIfPresent(String.self, forKey: .TxnDate)
        PrivateNote = try container.decodeIfPresent(String.self, forKey: .PrivateNote)
        PaymentRefNum = try container.decodeIfPresent(String.self, forKey: .PaymentRefNum)
        Line = try container.decodeIfPresent([QuickBooksPaymentLine].self, forKey: .Line)
        PaymentMethodRef = try container.decodeIfPresent(QuickBooksReference.self, forKey: .PaymentMethodRef)
        CreditCardPayment = try container.decodeIfPresent(QuickBooksCreditCardPayment.self, forKey: .CreditCardPayment)
    }

    private static func decodeFlexibleDouble(_ container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Double? {
        if let doubleValue = try? container.decodeIfPresent(Double.self, forKey: key) {
            return doubleValue
        }
        if let intValue = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Double(intValue)
        }
        if let stringValue = try? container.decodeIfPresent(String.self, forKey: key) {
            return Double(stringValue)
        }
        return nil
    }
}

struct QuickBooksPaymentCreate: Codable {
    let CustomerRef: QuickBooksReference?
    let TotalAmt: Double
    let PrivateNote: String?
    let PaymentRefNum: String?
    let Line: [QuickBooksPaymentLine]?
    let PaymentMethodRef: QuickBooksReference?
    let CreditCardPayment: QuickBooksCreditCardPayment?
}

struct QuickBooksPaymentResponse: Codable {
    let Payment: QuickBooksPayment
}

struct QuickBooksSalesReceiptQueryResponse: Codable {
    let QueryResponse: QuickBooksSalesReceiptList
}

struct QuickBooksSalesReceiptList: Codable {
    let SalesReceipt: [QuickBooksSalesReceipt]?

    private enum CodingKeys: String, CodingKey {
        case SalesReceipt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let array = try? container.decodeIfPresent([QuickBooksSalesReceipt].self, forKey: .SalesReceipt) {
            SalesReceipt = array
        } else if let single = try? container.decodeIfPresent(QuickBooksSalesReceipt.self, forKey: .SalesReceipt) {
            SalesReceipt = [single]
        } else {
            SalesReceipt = nil
        }
    }
}

struct QuickBooksSalesReceipt: Codable, Identifiable {
    let Id: String
    let DocNumber: String?
    let CustomerRef: QuickBooksReference?
    let TotalAmt: Double
    let TxnDate: String?
    let PrivateNote: String?
    let PaymentMethodRef: QuickBooksReference?
    let CreditCardPayment: QuickBooksCreditCardPayment?

    var id: String { Id }

    private enum CodingKeys: String, CodingKey {
        case Id, DocNumber, CustomerRef, TotalAmt, TxnDate, PrivateNote, PaymentMethodRef, CreditCardPayment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        Id = try container.decodeIfPresent(String.self, forKey: .Id) ?? UUID().uuidString
        DocNumber = try container.decodeIfPresent(String.self, forKey: .DocNumber)
        CustomerRef = try container.decodeIfPresent(QuickBooksReference.self, forKey: .CustomerRef)
        TotalAmt = Self.decodeFlexibleDouble(container, key: .TotalAmt) ?? 0
        TxnDate = try container.decodeIfPresent(String.self, forKey: .TxnDate)
        PrivateNote = try container.decodeIfPresent(String.self, forKey: .PrivateNote)
        PaymentMethodRef = try container.decodeIfPresent(QuickBooksReference.self, forKey: .PaymentMethodRef)
        CreditCardPayment = try container.decodeIfPresent(QuickBooksCreditCardPayment.self, forKey: .CreditCardPayment)
    }

    private static func decodeFlexibleDouble(_ container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Double? {
        if let doubleValue = try? container.decodeIfPresent(Double.self, forKey: key) {
            return doubleValue
        }
        if let intValue = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Double(intValue)
        }
        if let stringValue = try? container.decodeIfPresent(String.self, forKey: key) {
            return Double(stringValue)
        }
        return nil
    }
}

struct QuickBooksSalesReceiptCreate: Codable {
    let CustomerRef: QuickBooksReference
    let Line: [QuickBooksLineItem]
    let PrivateNote: String?
    let PaymentMethodRef: QuickBooksReference?
    let CreditCardPayment: QuickBooksCreditCardPayment?
}

struct QuickBooksSalesReceiptResponse: Codable {
    let SalesReceipt: QuickBooksSalesReceipt
}

struct QuickBooksPaymentMethodQueryResponse: Codable {
    let QueryResponse: QuickBooksPaymentMethodList
}

struct QuickBooksPaymentMethodList: Codable {
    let PaymentMethod: [QuickBooksPaymentMethod]?
}

struct QuickBooksPaymentMethod: Codable, Identifiable {
    let Id: String
    let Name: String
    let methodType: String?
    let Active: Bool?

    var id: String { Id }
    var reference: QuickBooksReference { QuickBooksReference(value: Id, name: Name) }

    private enum CodingKeys: String, CodingKey {
        case Id, Name, Active
        case methodType = "Type"
    }
}

struct QuickBooksPaymentMethodCreate: Codable {
    let Name: String

    let methodType: String?

    private enum CodingKeys: String, CodingKey {
        case Name
        case methodType = "Type"
    }
}

struct QuickBooksPaymentMethodResponse: Codable {
    let PaymentMethod: QuickBooksPaymentMethod
}

struct QuickBooksDepositQueryResponse: Codable {
    let QueryResponse: QuickBooksDepositList
}

struct QuickBooksDepositList: Codable {
    let Deposit: [QuickBooksDeposit]?
}

struct QuickBooksDepositLineDetail: Codable {
    let LinkedTxn: [QuickBooksLinkedTxn]?
    let AccountRef: QuickBooksReference?
}

struct QuickBooksDepositLine: Codable {
    let Amount: Double
    let DetailType: String
    let Description: String?
    let DepositLineDetail: QuickBooksDepositLineDetail
}

struct QuickBooksDeposit: Codable, Identifiable {
    let Id: String
    let TxnDate: String?
    let TotalAmt: Double
    let PrivateNote: String?
    let DepositToAccountRef: QuickBooksReference?
    let Line: [QuickBooksDepositLine]?

    var id: String { Id }

    private enum CodingKeys: String, CodingKey {
        case Id
        case TxnDate
        case TotalAmt
        case PrivateNote
        case DepositToAccountRef
        case Line
    }

    init(
        Id: String,
        TxnDate: String?,
        TotalAmt: Double,
        PrivateNote: String?,
        DepositToAccountRef: QuickBooksReference?,
        Line: [QuickBooksDepositLine]?
    ) {
        self.Id = Id
        self.TxnDate = TxnDate
        self.TotalAmt = TotalAmt
        self.PrivateNote = PrivateNote
        self.DepositToAccountRef = DepositToAccountRef
        self.Line = Line
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        Id = try container.decodeIfPresent(String.self, forKey: .Id) ?? UUID().uuidString
        TxnDate = try container.decodeIfPresent(String.self, forKey: .TxnDate)
        TotalAmt = QuickBooksFlexibleDecoding.double(container, .TotalAmt) ?? 0
        PrivateNote = try container.decodeIfPresent(String.self, forKey: .PrivateNote)
        DepositToAccountRef = try? container.decodeIfPresent(QuickBooksReference.self, forKey: .DepositToAccountRef)
        Line = try? container.decodeIfPresent([QuickBooksDepositLine].self, forKey: .Line)
    }
}

struct QuickBooksDepositCreate: Codable {
    let DepositToAccountRef: QuickBooksReference
    let Line: [QuickBooksDepositLine]
    let PrivateNote: String?
}

struct QuickBooksDepositResponse: Codable {
    let Deposit: QuickBooksDeposit
}


private enum QuickBooksFlexibleDecoding {
    static func string<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> String? {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) {
            return value ? "true" : "false"
        }
        return nil
    }

    static func bool<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Bool? {
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "yes", "y"].contains(normalized) { return true }
            if ["false", "0", "no", "n"].contains(normalized) { return false }
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
        return nil
    }

    static func double<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return Double(value) }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) { return Double(value) }
        return nil
    }
}

struct QuickBooksPaymentsCardAddress: Codable {
    let region: String?
    let postalCode: String?
    let streetAddress: String?
    let country: String?
    let city: String?

    private enum CodingKeys: String, CodingKey {
        case region, postalCode, streetAddress, country, city
    }

    init(region: String?, postalCode: String?, streetAddress: String?, country: String?, city: String?) {
        self.region = region
        self.postalCode = postalCode
        self.streetAddress = streetAddress
        self.country = country
        self.city = city
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        region = QuickBooksFlexibleDecoding.string(container, .region)
        postalCode = QuickBooksFlexibleDecoding.string(container, .postalCode)
        streetAddress = QuickBooksFlexibleDecoding.string(container, .streetAddress)
        country = QuickBooksFlexibleDecoding.string(container, .country)
        city = QuickBooksFlexibleDecoding.string(container, .city)
    }
}

struct QuickBooksPaymentsCard: Codable {
    let expYear: String
    let expMonth: String
    let address: QuickBooksPaymentsCardAddress?
    let name: String
    let cvc: String
    let number: String
}

struct QuickBooksPaymentsBankAccount: Codable {
    let name: String
    let accountNumber: String
    let phone: String
    let routingNumber: String
    let accountType: String
}

struct QuickBooksPaymentsTokenCreateRequest: Codable {
    let card: QuickBooksPaymentsCard?
    let bankAccount: QuickBooksPaymentsBankAccount?
}

struct QuickBooksPaymentsTokenResponse: Decodable {
    let value: String

    init(value: String) {
        self.value = value
    }

    private enum CodingKeys: String, CodingKey {
        case value
        case token
        case id
        case card
        case bankAccount
    }

    private struct NestedToken: Decodable {
        let value: String?

        private enum CodingKeys: String, CodingKey {
            case value
            case token
            case id
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            value =
                QuickBooksFlexibleDecoding.string(container, .value) ??
                QuickBooksFlexibleDecoding.string(container, .token) ??
                QuickBooksFlexibleDecoding.string(container, .id)
        }
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let rawToken = try? single.decode(String.self),
           !rawToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            value = rawToken
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let direct =
            QuickBooksFlexibleDecoding.string(container, .value) ??
            QuickBooksFlexibleDecoding.string(container, .token) ??
            QuickBooksFlexibleDecoding.string(container, .id) {
            value = direct
            return
        }

        if let nestedCard = try? container.decodeIfPresent(NestedToken.self, forKey: .card),
           let nestedValue = nestedCard.value,
           !nestedValue.isEmpty {
            value = nestedValue
            return
        }

        if let nestedBank = try? container.decodeIfPresent(NestedToken.self, forKey: .bankAccount),
           let nestedValue = nestedBank.value,
           !nestedValue.isEmpty {
            value = nestedValue
            return
        }

        value = ""
    }
}

struct QuickBooksPaymentsStoredCardCreateRequest: Codable {
    let value: String
}

struct QuickBooksPaymentsCardRecord: Decodable, Identifiable {
    let id: String
    let name: String?
    let expMonth: String?
    let expYear: String?
    let cardType: String?
    let number: String?
    let address: QuickBooksPaymentsCardAddress?
    let context: QuickBooksPaymentsResponseContext?

    private enum CodingKeys: String, CodingKey {
        case id, name, expMonth, expYear, number, address, context
        case cardType = "cardType"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = QuickBooksFlexibleDecoding.string(container, .id) ?? UUID().uuidString
        name = QuickBooksFlexibleDecoding.string(container, .name)
        expMonth = QuickBooksFlexibleDecoding.string(container, .expMonth)
        expYear = QuickBooksFlexibleDecoding.string(container, .expYear)
        cardType = QuickBooksFlexibleDecoding.string(container, .cardType)
        number = QuickBooksFlexibleDecoding.string(container, .number)
        address = (try? container.decodeIfPresent(QuickBooksPaymentsCardAddress.self, forKey: .address)) ?? nil
        context = (try? container.decodeIfPresent(QuickBooksPaymentsResponseContext.self, forKey: .context)) ?? nil
    }
}

struct QuickBooksPaymentsCardsResponse: Decodable {
    let items: [QuickBooksPaymentsCardRecord]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let cards = try? container.decode([QuickBooksPaymentsCardRecord].self) {
            items = cards
            return
        }

        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        items = try keyed.decodeIfPresent([QuickBooksPaymentsCardRecord].self, forKey: .items)
            ?? keyed.decodeIfPresent([QuickBooksPaymentsCardRecord].self, forKey: .cards)
            ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case items
        case cards
    }
}

struct QuickBooksPaymentsDeviceInfo: Codable {
    let id: String?
    let type: String?
    let macAddress: String?
    let ipAddress: String?
    let longitude: String?
    let latitude: String?
    let phoneNumber: String?

    private enum CodingKeys: String, CodingKey {
        case id, type, macAddress, ipAddress, longitude, latitude, phoneNumber
    }

    init(id: String?, type: String?, macAddress: String?, ipAddress: String?, longitude: String?, latitude: String?, phoneNumber: String?) {
        self.id = id
        self.type = type
        self.macAddress = macAddress
        self.ipAddress = ipAddress
        self.longitude = longitude
        self.latitude = latitude
        self.phoneNumber = phoneNumber
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = QuickBooksFlexibleDecoding.string(container, .id)
        type = QuickBooksFlexibleDecoding.string(container, .type)
        macAddress = QuickBooksFlexibleDecoding.string(container, .macAddress)
        ipAddress = QuickBooksFlexibleDecoding.string(container, .ipAddress)
        longitude = QuickBooksFlexibleDecoding.string(container, .longitude)
        latitude = QuickBooksFlexibleDecoding.string(container, .latitude)
        phoneNumber = QuickBooksFlexibleDecoding.string(container, .phoneNumber)
    }
}

struct QuickBooksPaymentsChargeContext: Codable {
    let deviceInfo: QuickBooksPaymentsDeviceInfo?
    let recurring: Bool?
    let tax: Double?
    let clientTransID: String?
    let mobile: Bool?
    let isEcommerce: Bool?

    private enum CodingKeys: String, CodingKey {
        case deviceInfo, recurring, tax, clientTransID, mobile, isEcommerce
    }

    init(deviceInfo: QuickBooksPaymentsDeviceInfo?, recurring: Bool?, tax: Double?, clientTransID: String?, mobile: Bool? = nil, isEcommerce: Bool? = nil) {
        self.deviceInfo = deviceInfo
        self.recurring = recurring
        self.tax = tax
        self.clientTransID = clientTransID
        self.mobile = mobile
        self.isEcommerce = isEcommerce
    }

    static func forClientTransactionID(_ clientTransID: String?) -> QuickBooksPaymentsChargeContext {
        QuickBooksPaymentsChargeContext(
            deviceInfo: QuickBooksPaymentsDeviceInfo(
                id: "GunnAire-Ops",
                type: "iOS",
                macAddress: nil,
                ipAddress: nil,
                longitude: nil,
                latitude: nil,
                phoneNumber: nil
            ),
            recurring: false,
            tax: 0,
            clientTransID: clientTransID,
            mobile: false,
            isEcommerce: true
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceInfo = (try? container.decodeIfPresent(QuickBooksPaymentsDeviceInfo.self, forKey: .deviceInfo)) ?? nil
        recurring = QuickBooksFlexibleDecoding.bool(container, .recurring)
        tax = QuickBooksFlexibleDecoding.double(container, .tax)
        clientTransID = QuickBooksFlexibleDecoding.string(container, .clientTransID)
        mobile = QuickBooksFlexibleDecoding.bool(container, .mobile)
        isEcommerce = QuickBooksFlexibleDecoding.bool(container, .isEcommerce)
    }
}

struct QuickBooksPaymentsChargeCreate: Codable {
    let amount: String
    let currency: String?
    let capture: Bool?
    let token: String
    let description: String?
    let context: QuickBooksPaymentsChargeContext?
    let paymentMode: String?
    let checkNumber: String?
}

struct QuickBooksPaymentsChargeCaptureRequest: Codable {
    let amount: String

    init(amount: Double) {
        self.amount = String(format: "%.2f", amount)
    }
}

struct QuickBooksPaymentsMaskedCard: Decodable {
    let number: String?
    let name: String?
    let expMonth: String?
    let expYear: String?
    let address: QuickBooksPaymentsCardAddress?

    private enum CodingKeys: String, CodingKey {
        case number, name, expMonth, expYear, address
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = QuickBooksFlexibleDecoding.string(container, .number)
        name = QuickBooksFlexibleDecoding.string(container, .name)
        expMonth = QuickBooksFlexibleDecoding.string(container, .expMonth)
        expYear = QuickBooksFlexibleDecoding.string(container, .expYear)
        address = (try? container.decodeIfPresent(QuickBooksPaymentsCardAddress.self, forKey: .address)) ?? nil
    }
}

struct QuickBooksPaymentsChargeCaptureDetail: Decodable {
    let created: String?
    let amount: String?
    let context: QuickBooksPaymentsResponseContext?

    private enum CodingKeys: String, CodingKey {
        case created, amount, context
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        created = QuickBooksFlexibleDecoding.string(container, .created)
        amount = QuickBooksFlexibleDecoding.string(container, .amount)
        context = (try? container.decodeIfPresent(QuickBooksPaymentsResponseContext.self, forKey: .context)) ?? nil
    }
}

struct QuickBooksPaymentsChargeResponse: Decodable {
    let created: String?
    let status: String?
    let amount: String?
    let currency: String?
    let token: String?
    let capture: Bool?
    let id: String
    let authCode: String?
    let clientTransID: String?
    let card: QuickBooksPaymentsMaskedCard?
    let context: QuickBooksPaymentsResponseContext?
    let captureDetail: QuickBooksPaymentsChargeCaptureDetail?

    init(
        created: String?,
        status: String?,
        amount: String?,
        currency: String?,
        token: String?,
        capture: Bool?,
        id: String,
        authCode: String?,
        clientTransID: String?,
        card: QuickBooksPaymentsMaskedCard?,
        context: QuickBooksPaymentsResponseContext?,
        captureDetail: QuickBooksPaymentsChargeCaptureDetail?
    ) {
        self.created = created
        self.status = status
        self.amount = amount
        self.currency = currency
        self.token = token
        self.capture = capture
        self.id = id
        self.authCode = authCode
        self.clientTransID = clientTransID
        self.card = card
        self.context = context
        self.captureDetail = captureDetail
    }

    static func placeholder(id: String, status: String?) -> QuickBooksPaymentsChargeResponse {
        QuickBooksPaymentsChargeResponse(
            created: nil,
            status: status,
            amount: nil,
            currency: nil,
            token: nil,
            capture: true,
            id: id,
            authCode: nil,
            clientTransID: nil,
            card: nil,
            context: nil,
            captureDetail: nil
        )
    }

    private enum CodingKeys: String, CodingKey {
        case created, status, amount, currency, token, capture, id, authCode, clientTransID, card, context, captureDetail
    }

    var resolvedClientTransID: String? {
        clientTransID ?? context?.clientTransID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        created = QuickBooksFlexibleDecoding.string(container, .created)
        status = QuickBooksFlexibleDecoding.string(container, .status)
        amount = QuickBooksFlexibleDecoding.string(container, .amount)
        currency = QuickBooksFlexibleDecoding.string(container, .currency)
        token = QuickBooksFlexibleDecoding.string(container, .token)
        capture = QuickBooksFlexibleDecoding.bool(container, .capture)
        id = QuickBooksFlexibleDecoding.string(container, .id) ?? UUID().uuidString
        authCode = QuickBooksFlexibleDecoding.string(container, .authCode)
        clientTransID = QuickBooksFlexibleDecoding.string(container, .clientTransID)
        card = (try? container.decodeIfPresent(QuickBooksPaymentsMaskedCard.self, forKey: .card)) ?? nil
        context = (try? container.decodeIfPresent(QuickBooksPaymentsResponseContext.self, forKey: .context)) ?? nil
        captureDetail = (try? container.decodeIfPresent(QuickBooksPaymentsChargeCaptureDetail.self, forKey: .captureDetail)) ?? nil
    }
}

struct QuickBooksPaymentsResponseContext: Codable {
    let tax: String?
    let recurring: Bool?
    let paymentGroupingCode: String?
    let txnAuthorizationStamp: String?
    let clientTransID: String?
    let mobile: Bool?
    let isEcommerce: Bool?
    let deviceInfo: QuickBooksPaymentsDeviceInfo?

    private enum CodingKeys: String, CodingKey {
        case tax, recurring, paymentGroupingCode, txnAuthorizationStamp, clientTransID, mobile, isEcommerce, deviceInfo
    }

    init(tax: String?, recurring: Bool?, paymentGroupingCode: String?, txnAuthorizationStamp: String?, clientTransID: String?, mobile: Bool?, isEcommerce: Bool?, deviceInfo: QuickBooksPaymentsDeviceInfo?) {
        self.tax = tax
        self.recurring = recurring
        self.paymentGroupingCode = paymentGroupingCode
        self.txnAuthorizationStamp = txnAuthorizationStamp
        self.clientTransID = clientTransID
        self.mobile = mobile
        self.isEcommerce = isEcommerce
        self.deviceInfo = deviceInfo
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tax = QuickBooksFlexibleDecoding.string(container, .tax)
        recurring = QuickBooksFlexibleDecoding.bool(container, .recurring)
        paymentGroupingCode = QuickBooksFlexibleDecoding.string(container, .paymentGroupingCode)
        txnAuthorizationStamp = QuickBooksFlexibleDecoding.string(container, .txnAuthorizationStamp)
        clientTransID = QuickBooksFlexibleDecoding.string(container, .clientTransID)
        mobile = QuickBooksFlexibleDecoding.bool(container, .mobile)
        isEcommerce = QuickBooksFlexibleDecoding.bool(container, .isEcommerce)
        deviceInfo = (try? container.decodeIfPresent(QuickBooksPaymentsDeviceInfo.self, forKey: .deviceInfo)) ?? nil
    }
}

struct QuickBooksPaymentsRefundRequest: Codable {
    let amount: String
    let description: String?
    let context: QuickBooksPaymentsChargeContext?

    init(amount: Double, description: String?, context: QuickBooksPaymentsChargeContext?) {
        self.amount = String(format: "%.2f", amount)
        self.description = description
        self.context = context
    }
}

struct QuickBooksPaymentsRefundResponse: Decodable {
    let created: String?
    let status: String?
    let amount: String?
    let description: String?
    let id: String
    let context: QuickBooksPaymentsResponseContext?
    let type: String?

    private enum CodingKeys: String, CodingKey {
        case created, status, amount, description, id, context, type
    }

    var resolvedClientTransID: String? {
        context?.clientTransID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        created = QuickBooksFlexibleDecoding.string(container, .created)
        status = QuickBooksFlexibleDecoding.string(container, .status)
        amount = QuickBooksFlexibleDecoding.string(container, .amount)
        description = QuickBooksFlexibleDecoding.string(container, .description)
        id = QuickBooksFlexibleDecoding.string(container, .id) ?? UUID().uuidString
        context = (try? container.decodeIfPresent(QuickBooksPaymentsResponseContext.self, forKey: .context)) ?? nil
        type = QuickBooksFlexibleDecoding.string(container, .type)
    }
}

struct QuickBooksPaymentsPaymentReceipt: Decodable {
    let id: String?
    let receiptId: String?
    let paymentId: String?
    let chargeId: String?
    let authCode: String?
    let amount: String?
    let created: String?
    let card: QuickBooksPaymentsMaskedCard?
    let context: QuickBooksPaymentsResponseContext?
    let links: [QuickBooksPaymentsLink]?

    private enum CodingKeys: String, CodingKey {
        case id, receiptId, paymentId, chargeId, authCode, amount, created, card, context, links
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = QuickBooksFlexibleDecoding.string(container, .id)
        receiptId = QuickBooksFlexibleDecoding.string(container, .receiptId)
        paymentId = QuickBooksFlexibleDecoding.string(container, .paymentId)
        chargeId = QuickBooksFlexibleDecoding.string(container, .chargeId)
        authCode = QuickBooksFlexibleDecoding.string(container, .authCode)
        amount = QuickBooksFlexibleDecoding.string(container, .amount)
        created = QuickBooksFlexibleDecoding.string(container, .created)
        card = (try? container.decodeIfPresent(QuickBooksPaymentsMaskedCard.self, forKey: .card)) ?? nil
        context = (try? container.decodeIfPresent(QuickBooksPaymentsResponseContext.self, forKey: .context)) ?? nil
        links = (try? container.decodeIfPresent([QuickBooksPaymentsLink].self, forKey: .links)) ?? nil
    }
}

struct QuickBooksPaymentsLink: Decodable, Identifiable {
    let rel: String?
    let href: String?

    var id: String { href ?? UUID().uuidString }

    private enum CodingKeys: String, CodingKey {
        case rel, href
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rel = QuickBooksFlexibleDecoding.string(container, .rel)
        href = QuickBooksFlexibleDecoding.string(container, .href)
    }
}

struct QuickBooksCreditChargeInfo: Codable {
    let ProcessPayment: String?

    init(ProcessPayment: String?) {
        self.ProcessPayment = ProcessPayment
    }
}

struct QuickBooksCreditChargeResponse: Codable {
    let CCTransId: String?

    init(CCTransId: String?) {
        self.CCTransId = CCTransId
    }
}

struct QuickBooksCreditCardPayment: Codable {
    let CreditChargeInfo: QuickBooksCreditChargeInfo?
    let CreditChargeResponse: QuickBooksCreditChargeResponse?

    init(CreditChargeInfo: QuickBooksCreditChargeInfo?, CreditChargeResponse: QuickBooksCreditChargeResponse?) {
        self.CreditChargeInfo = CreditChargeInfo
        self.CreditChargeResponse = CreditChargeResponse
    }
}

struct QuickBooksRefundReceiptCreate: Codable {
    let Line: [QuickBooksLineItem]
    let CustomerRef: QuickBooksReference
    let CreditCardPayment: QuickBooksCreditCardPayment
    let TxnSource: String
    let PrivateNote: String?
}

struct QuickBooksRefundReceiptResponse: Codable {
    let RefundReceipt: QuickBooksRefundReceipt
}

struct QuickBooksRefundReceipt: Codable {
    let Id: String
}

struct QuickBooksFaultEnvelope: Decodable {
    let Fault: QuickBooksFault

    private enum CodingKeys: String, CodingKey {
        case Fault, fault
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        Fault = try container.decodeIfPresent(QuickBooksFault.self, forKey: .Fault)
            ?? container.decode(QuickBooksFault.self, forKey: .fault)
    }
}

struct QuickBooksFault: Decodable {
    let Error: [QuickBooksFaultError]

    private enum CodingKeys: String, CodingKey {
        case Error, error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        Error = try container.decodeIfPresent([QuickBooksFaultError].self, forKey: .Error)
            ?? container.decodeIfPresent([QuickBooksFaultError].self, forKey: .error)
            ?? []
    }
}

struct QuickBooksFaultError: Decodable {
    let Message: String
    let Detail: String
    let code: String?

    private enum CodingKeys: String, CodingKey {
        case Message, Detail, message, detail, code
    }

    init(Message: String, Detail: String) {
        self.Message = Message
        self.Detail = Detail
        self.code = nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let upperMessage = try container.decodeIfPresent(String.self, forKey: .Message)
        let lowerMessage = try container.decodeIfPresent(String.self, forKey: .message)
        let upperDetail = try container.decodeIfPresent(String.self, forKey: .Detail)
        let lowerDetail = try container.decodeIfPresent(String.self, forKey: .detail)
        self.Message = upperMessage ?? lowerMessage ?? "Unknown"
        self.Detail = upperDetail ?? lowerDetail ?? ""
        self.code = try container.decodeIfPresent(String.self, forKey: .code)
    }
}

struct QuickBooksPaymentsErrorEnvelope: Codable {
    let RestResponse: QuickBooksPaymentsRestResponse?

    var firstProblemDescription: String? {
        RestResponse?.Error?.Problem?.Desc ?? RestResponse?.Error?.Problem?.Message
    }
}

struct QuickBooksPaymentsRestResponse: Codable {
    let Error: QuickBooksPaymentsRestError?
}

struct QuickBooksPaymentsRestError: Codable {
    let Problem: QuickBooksPaymentsProblem?
}

struct QuickBooksPaymentsProblem: Codable {
    let Message: String?
    let Desc: String?
}

struct QuickBooksUploadMetadata: Codable {
    let FileName: String
    let ContentType: String
    let Note: String
    let AttachableRef: [QuickBooksAttachableReference]?
}

enum QuickBooksAttachableEntityType: String, CaseIterable {
    case estimate = "Estimate"
    case invoice = "Invoice"
    case bill = "Bill"
    case payment = "Payment"
    case salesReceipt = "SalesReceipt"
    case purchase = "Purchase"
}

struct QuickBooksAttachableReference: Codable {
    let EntityRef: QuickBooksAttachableEntityRef
    let IncludeOnSend: Bool
}

struct QuickBooksAttachableEntityRef: Codable {
    let type: String
    let value: String
}

struct QuickBooksUploadResponse: Codable {
    let AttachableResponse: [QuickBooksAttachable]
}

struct QuickBooksAttachable: Codable {
    let Id: String
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
