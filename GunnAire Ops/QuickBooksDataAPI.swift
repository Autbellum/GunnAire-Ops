import Foundation
import Combine

struct QuickBooksOAuthTokens: Codable {
    let accessToken: String
    let refreshToken: String
    let expiration: Date
}

private struct QuickBooksKeychainPayload: Codable {
    let tokens: QuickBooksOAuthTokens
    let realmID: String
    let environment: String?
}

final class QuickBooksDataAPI: ObservableObject {
    static let shared = QuickBooksDataAPI()

    @Published private(set) var tokens: QuickBooksOAuthTokens?
    @Published private(set) var storedRealmID: String?
    @Published private(set) var storedEnvironment: String?

    private let clientId = Config.QuickBooks.clientID
    private let clientSecret = Config.QuickBooks.clientSecret
    private let realmIDKey = "QuickBooksRealmID"
    private let tokenStorageKey = "QuickBooksOAuthTokens"
    private let keychainAccount = "QuickBooksOAuthPayload"
    private let minorVersion = "75"

    private var baseURL: String {
        let env = (storedEnvironment ?? Config.QuickBooks.environment).lowercased()
        if env == "sandbox" {
            return "https://sandbox-quickbooks.api.intuit.com/v3/company/"
        }
        return "https://quickbooks.api.intuit.com/v3/company/"
    }

    private var paymentsBaseURL: String {
        let env = (storedEnvironment ?? Config.QuickBooks.environment).lowercased()
        if env == "sandbox" {
            return "https://sandbox.api.intuit.com/quickbooks/v4/payments"
        }
        return "https://api.intuit.com/quickbooks/v4/payments"
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
        return "Environment: \(currentEnvironment.capitalized) • Realm: \(company) • Token expires: \(expiration)"
    }

    var canStartOAuthFlow: Bool {
        Config.QuickBooks.isConfigured
    }

    func storeTokens(_ tokens: QuickBooksOAuthTokens, realmID: String) {
        let normalizedRealmID = realmID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tokens = tokens
        self.storedRealmID = normalizedRealmID.isEmpty ? nil : normalizedRealmID
        self.storedEnvironment = Config.QuickBooks.environment
        guard !normalizedRealmID.isEmpty else {
            UserDefaults.standard.removeObject(forKey: realmIDKey)
            return
        }
        try? KeychainStore.saveCodable(QuickBooksKeychainPayload(tokens: tokens, realmID: normalizedRealmID, environment: self.storedEnvironment), account: keychainAccount)
        UserDefaults.standard.set(normalizedRealmID, forKey: realmIDKey)
        if let data = try? JSONEncoder().encode(tokens) {
            UserDefaults.standard.set(data, forKey: tokenStorageKey)
        }
    }

    func loadTokens() {
        if let payload = try? KeychainStore.loadCodable(QuickBooksKeychainPayload.self, account: keychainAccount) {
            tokens = payload.tokens
            storedEnvironment = payload.environment ?? Config.QuickBooks.environment
            let keychainRealmID = payload.realmID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !keychainRealmID.isEmpty {
                storedRealmID = keychainRealmID
            } else {
                storedRealmID = UserDefaults.standard.string(forKey: realmIDKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return
        }

        if let data = UserDefaults.standard.data(forKey: tokenStorageKey),
           let tokens = try? JSONDecoder().decode(QuickBooksOAuthTokens.self, from: data),
           let realmID = UserDefaults.standard.string(forKey: realmIDKey) {
            storeTokens(tokens, realmID: realmID)
            storedEnvironment = Config.QuickBooks.environment
        }
    }

    func clearTokens() {
        tokens = nil
        storedRealmID = nil
        storedEnvironment = nil
        try? KeychainStore.remove(account: keychainAccount)
        UserDefaults.standard.removeObject(forKey: tokenStorageKey)
        UserDefaults.standard.removeObject(forKey: realmIDKey)
    }

    func refreshTokensIfNeeded(completion: @escaping (Bool) -> Void) {
        guard let tokens else {
            completeOnMain(completion, value: false)
            return
        }

        if tokens.expiration > Date().addingTimeInterval(60) {
            completeOnMain(completion, value: true)
            return
        }

        refreshAccessToken(refreshToken: tokens.refreshToken, completion: completion)
    }

    private func refreshAccessToken(refreshToken: String, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: Config.QuickBooks.tokenEndpoint) else {
            completeOnMain(completion, value: false)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let credentials = "\(clientId):\(clientSecret)"
        guard let credData = credentials.data(using: .utf8) else {
            completeOnMain(completion, value: false)
            return
        }
        request.setValue("Basic \(credData.base64EncodedString())", forHTTPHeaderField: "Authorization")

        let escapedToken = refreshToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? refreshToken
        request.httpBody = "grant_type=refresh_token&refresh_token=\(escapedToken)".data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, response, error in
            Task { @MainActor in
                if error != nil {
                    self.completeOnMain(completion, value: false)
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                    if let httpResponse = response as? HTTPURLResponse, [400, 401, 403].contains(httpResponse.statusCode) {
                        self.clearTokens()
                    }
                    self.completeOnMain(completion, value: false)
                    return
                }

                guard let data,
                      let payload = try? JSONDecoder().decode(QuickBooksRefreshTokenResponse.self, from: data),
                      let realmID = self.realmID else {
                    self.completeOnMain(completion, value: false)
                    return
                }

                let refreshed = QuickBooksOAuthTokens(
                    accessToken: payload.access_token,
                    refreshToken: payload.refresh_token,
                    expiration: Date().addingTimeInterval(payload.expires_in)
                )
                self.storeTokens(refreshed, realmID: realmID)
                self.completeOnMain(completion, value: true)
            }
        }.resume()
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
        components.queryItems = mergedQueryItems

        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
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
        guard let tokens else {
            return nil
        }

        let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let url = URL(string: "\(paymentsBaseURL)/\(trimmedPath)") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body
        return request
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
                return .authorizationFailed(statusCode: http.statusCode, detail: paymentsAuthorizationFailureMessage(detail: description))
            }
            return .httpDetail(statusCode: http.statusCode, detail: description)
        }

        if let data,
           let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            if http.statusCode == 401 || http.statusCode == 403 {
                return .authorizationFailed(statusCode: http.statusCode, detail: paymentsAuthorizationFailureMessage(detail: raw))
            }
            return .httpDetail(statusCode: http.statusCode, detail: raw)
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            return .authorizationFailed(statusCode: http.statusCode, detail: paymentsAuthorizationFailureMessage(detail: "QuickBooks Payments rejected this app session."))
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
        let company = realmID ?? "the selected QuickBooks company"
        return "QuickBooks rejected this app session for \(company). Reconnect QuickBooks with a company admin, confirm the app is authorized for \(currentEnvironment), then retry sync."
    }

    private func paymentsAuthorizationFailureMessage(detail: String) -> String {
        "QuickBooks Payments rejected this app session. Reconnect QuickBooks and confirm Payments access is enabled for this company before retrying card, stored-card, or payment-method sync."
    }

    private func clearRejectedSessionIfNeeded(_ error: QBError) {
        guard error.requiresReconnect else { return }
        clearTokens()
    }

    private func performAuthorizedDecodingRequest<T: Decodable>(
        _ requestBuilder: @escaping () -> URLRequest?,
        decode type: T.Type,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        refreshTokensIfNeeded { ok in
            guard ok, let request = requestBuilder() else {
                completion(.failure(QBError.unauthorized))
                return
            }

            URLSession.shared.dataTask(with: request) { data, response, error in
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
                    guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
                        completion(.failure(QBError.decoding))
                        return
                    }
                    completion(.success(decoded))
                }
            }.resume()
        }
    }

    private func performPaymentsDecodingRequest<T: Decodable>(
        _ requestBuilder: @escaping () -> URLRequest?,
        decode type: T.Type,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        refreshTokensIfNeeded { ok in
            guard ok, let request = requestBuilder() else {
                completion(.failure(QBError.unauthorized))
                return
            }

            URLSession.shared.dataTask(with: request) { data, response, error in
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
                    guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
                        completion(.failure(QBError.decoding))
                        return
                    }
                    completion(.success(decoded))
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

    func fetchInvoices(completion: @escaping (Result<[QuickBooksInvoice], Error>) -> Void) {
        performAuthorizedDecodingRequest(
            { self.makeQueryRequest("SELECT * FROM Invoice") },
            decode: QuickBooksInvoiceQueryResponse.self
        ) { result in
            completion(result.map { $0.QueryResponse.Invoice ?? [] })
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

    func createCardToken(_ tokenRequest: QuickBooksPaymentsTokenCreateRequest, completion: @escaping (Result<QuickBooksPaymentsTokenResponse, Error>) -> Void) {
        let body = try? JSONEncoder().encode(tokenRequest)
        performPaymentsDecodingRequest(
            { self.authorizedPaymentsRequest(path: "tokens", method: "POST", body: body, contentType: "application/json") },
            decode: QuickBooksPaymentsTokenResponse.self,
            completion: completion
        )
    }

    func createCharge(_ charge: QuickBooksPaymentsChargeCreate, completion: @escaping (Result<QuickBooksPaymentsChargeResponse, Error>) -> Void) {
        let body = try? JSONEncoder().encode(charge)
        performPaymentsDecodingRequest(
            { self.authorizedPaymentsRequest(path: "charges", method: "POST", body: body, contentType: "application/json") },
            decode: QuickBooksPaymentsChargeResponse.self,
            completion: completion
        )
    }

    func fetchCards(completion: @escaping (Result<[QuickBooksPaymentsCardRecord], Error>) -> Void) {
        performPaymentsDecodingRequest(
            { self.authorizedPaymentsRequest(path: "cards") },
            decode: QuickBooksPaymentsCardsResponse.self
        ) { result in
            completion(result.map(\.items))
        }
    }

    func createStoredCard(_ card: QuickBooksPaymentsStoredCardCreateRequest, completion: @escaping (Result<QuickBooksPaymentsCardRecord, Error>) -> Void) {
        let body = try? JSONEncoder().encode(card)
        performPaymentsDecodingRequest(
            { self.authorizedPaymentsRequest(path: "cards", method: "POST", body: body, contentType: "application/json") },
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
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        refreshTokensIfNeeded { ok in
            guard ok else {
                completion(.failure(QBError.unauthorized))
                return
            }

            let filename = fileURL.lastPathComponent
            let contentType = Self.mimeType(for: fileURL)
            let boundary = "Boundary-\(UUID().uuidString)"
            let attachableRefs: [QuickBooksAttachableReference]
            if let attachToEntityType, let attachToEntityID, !attachToEntityID.isEmpty {
                attachableRefs = [
                    QuickBooksAttachableReference(
                        EntityRef: QuickBooksAttachableEntityRef(
                            type: attachToEntityType.rawValue,
                            value: attachToEntityID
                        ),
                        IncludeOnSend: true
                    )
                ]
            } else {
                attachableRefs = []
            }

            let metadata = QuickBooksUploadMetadata(
                FileName: filename,
                ContentType: contentType,
                Note: note ?? "Uploaded from GunnAire Ops",
                AttachableRef: attachableRefs.isEmpty ? nil : attachableRefs
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
        body.append("Content-Disposition: form-data; name=\"file_metadata_01\"\(lineBreak)")
        body.append("Content-Type: application/json\(lineBreak)\(lineBreak)")
        body.append("\(metadataJSON)\(lineBreak)")

        body.append("--\(boundary)\(lineBreak)")
        body.append("Content-Disposition: form-data; name=\"file_content_01\"; filename=\"\(filename)\"\(lineBreak)")
        body.append("Content-Type: \(contentType)\(lineBreak)\(lineBreak)")
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

    enum QBError: Error, LocalizedError {
        case unauthorized
        case missingConfiguration
        case noData
        case decoding
        case http(statusCode: Int)
        case api(statusCode: Int, detail: String)
        case httpDetail(statusCode: Int, detail: String)
        case authorizationFailed(statusCode: Int, detail: String)

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
                return "QuickBooks client credentials are not configured on this Mac. Set QB_CLIENT_ID and QB_CLIENT_SECRET in Config/Local.xcconfig before reconnecting or refreshing the QuickBooks session."
            case .noData:
                return "QuickBooks returned no data."
            case .decoding:
                return "QuickBooks response decoding failed."
            case .http(let statusCode):
                return "QuickBooks request failed (HTTP \(statusCode))."
            case .api(let statusCode, let detail):
                return "QuickBooks API error (HTTP \(statusCode)): \(detail)"
            case .httpDetail(let statusCode, let detail):
                return "QuickBooks request failed (HTTP \(statusCode)): \(detail)"
            case .authorizationFailed(let statusCode, let detail):
                return "QuickBooks authorization needs attention (HTTP \(statusCode)). \(detail) Reconnect QuickBooks, then retry sync."
            }
        }
    }
}

private struct QuickBooksRefreshTokenResponse: Codable {
    let access_token: String
    let refresh_token: String
    let expires_in: Double
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
    let UnitPrice: Double?
    let PurchaseCost: Double?
    let Taxable: Bool?
    let Active: Bool?

    var id: String { Id }

    private enum CodingKeys: String, CodingKey {
        case Id, Name, Description, UnitPrice, PurchaseCost, Taxable, Active
        case ItemType = "Type"
    }
}

struct QuickBooksItemCreate: Codable {
    let Name: String
    let ItemType: String
    let Description: String?
    let PurchaseDesc: String?
    let UnitPrice: Double?
    let PurchaseCost: Double?
    let Taxable: Bool?
    let IncomeAccountRef: QuickBooksReference?
    let ExpenseAccountRef: QuickBooksReference?

    private enum CodingKeys: String, CodingKey {
        case Name, Description, PurchaseDesc, UnitPrice, PurchaseCost, Taxable, IncomeAccountRef, ExpenseAccountRef
        case ItemType = "Type"
    }
}

struct QuickBooksItemResponse: Codable {
    let Item: QuickBooksItem
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

    var id: String { Id }
}

struct QuickBooksEstimateCreate: Codable {
    let CustomerRef: QuickBooksReference
    let Line: [QuickBooksLineItem]
    let PrivateNote: String?
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
    let DocNumber: String?
    let CustomerRef: QuickBooksReference
    let TotalAmt: Double
    let Balance: Double?
    let TxnDate: String?
    let PrivateNote: String?

    var id: String { Id }

    private enum CodingKeys: String, CodingKey {
        case Id, DocNumber, CustomerRef, TotalAmt, Balance, TxnDate, PrivateNote
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        Id = try container.decodeIfPresent(String.self, forKey: .Id) ?? UUID().uuidString
        DocNumber = try container.decodeIfPresent(String.self, forKey: .DocNumber)
        CustomerRef = try container.decodeIfPresent(QuickBooksReference.self, forKey: .CustomerRef)
            ?? QuickBooksReference(value: "", name: "Unknown Customer")
        TotalAmt = try container.decodeIfPresent(Double.self, forKey: .TotalAmt) ?? 0
        Balance = try container.decodeIfPresent(Double.self, forKey: .Balance)
        TxnDate = try container.decodeIfPresent(String.self, forKey: .TxnDate)
        PrivateNote = try container.decodeIfPresent(String.self, forKey: .PrivateNote)
    }
}

struct QuickBooksInvoiceCreate: Codable {
    let CustomerRef: QuickBooksReference
    let Line: [QuickBooksLineItem]
    let PrivateNote: String?
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
}

struct QuickBooksDepositCreate: Codable {
    let DepositToAccountRef: QuickBooksReference
    let Line: [QuickBooksDepositLine]
    let PrivateNote: String?
}

struct QuickBooksDepositResponse: Codable {
    let Deposit: QuickBooksDeposit
}

struct QuickBooksPaymentsCardAddress: Codable {
    let region: String?
    let postalCode: String?
    let streetAddress: String?
    let country: String?
    let city: String?
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

struct QuickBooksPaymentsTokenResponse: Codable {
    let value: String
}

struct QuickBooksPaymentsStoredCardCreateRequest: Codable {
    let value: String
}

struct QuickBooksPaymentsCardRecord: Codable, Identifiable {
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
}

struct QuickBooksPaymentsChargeContext: Codable {
    let deviceInfo: QuickBooksPaymentsDeviceInfo?
    let recurring: Bool?
    let tax: Double?
    let clientTransID: String?

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
            clientTransID: clientTransID
        )
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
    let amount: Double
}

struct QuickBooksPaymentsMaskedCard: Codable {
    let number: String?
    let name: String?
    let expMonth: String?
    let expYear: String?
    let address: QuickBooksPaymentsCardAddress?
}

struct QuickBooksPaymentsChargeCaptureDetail: Codable {
    let created: String?
    let amount: String?
    let context: QuickBooksPaymentsChargeContext?
}

struct QuickBooksPaymentsChargeResponse: Codable {
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

    var resolvedClientTransID: String? {
        clientTransID ?? context?.clientTransID
    }
}

struct QuickBooksPaymentsResponseContext: Codable {
    let tax: String?
    let recurring: Bool?
    let paymentGroupingCode: String?
    let txnAuthorizationStamp: String?
    let clientTransID: String?
    let mobile: Bool?
    let deviceInfo: QuickBooksPaymentsDeviceInfo?
}

struct QuickBooksPaymentsRefundRequest: Codable {
    let amount: Double
    let description: String?
    let context: QuickBooksPaymentsChargeContext?
}

struct QuickBooksPaymentsRefundResponse: Codable {
    let created: String?
    let status: String?
    let amount: String?
    let description: String?
    let id: String
    let context: QuickBooksPaymentsResponseContext?
    let type: String?

    var resolvedClientTransID: String? {
        context?.clientTransID
    }
}

struct QuickBooksPaymentsPaymentReceipt: Codable {
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
}

struct QuickBooksPaymentsLink: Codable, Identifiable {
    let rel: String?
    let href: String?

    var id: String { href ?? UUID().uuidString }
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
