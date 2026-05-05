import Foundation
import Combine
import AuthenticationServices

/// Model representing OAuth2 tokens
struct QuickBooksOAuthTokens: Codable {
    let accessToken: String
    let refreshToken: String
    let expiration: Date
}

private struct QuickBooksKeychainPayload: Codable {
    let tokens: QuickBooksOAuthTokens
    let realmID: String
}

/// Singleton QuickBooks API client
final class QuickBooksDataAPI: ObservableObject {
    static let shared = QuickBooksDataAPI()
    
    @Published private(set) var tokens: QuickBooksOAuthTokens?
    @Published private(set) var storedRealmID: String?
    private let clientId = Config.QuickBooks.clientID
    private let clientSecret = Config.QuickBooks.clientSecret
    private var baseURL: String {
        if Config.QuickBooks.environment.lowercased() == "sandbox" {
            return "https://sandbox-quickbooks.api.intuit.com/v3/company/"
        }
        return "https://quickbooks.api.intuit.com/v3/company/"
    }
    private let realmIDKey = "QuickBooksRealmID"
    
    // Storage keys
    private let tokenStorageKey = "QuickBooksOAuthTokens"
    private let keychainAccount = "QuickBooksOAuthPayload"
    private let minorVersion = "75"
    
    var realmID: String? {
        storedRealmID
    }

    // MARK: - OAuth Token Management
    func storeTokens(_ tokens: QuickBooksOAuthTokens, realmID: String) {
        self.tokens = tokens
        self.storedRealmID = realmID
        try? KeychainStore.saveCodable(QuickBooksKeychainPayload(tokens: tokens, realmID: realmID), account: keychainAccount)
        UserDefaults.standard.set(realmID, forKey: realmIDKey)
        if let data = try? JSONEncoder().encode(tokens) {
            UserDefaults.standard.set(data, forKey: tokenStorageKey)
        }
    }
    
    func loadTokens() {
        if let payload = try? KeychainStore.loadCodable(QuickBooksKeychainPayload.self, account: keychainAccount) {
            self.tokens = payload.tokens
            self.storedRealmID = payload.realmID
            return
        }

        // Backward-compat migration from UserDefaults.
        if let data = UserDefaults.standard.data(forKey: tokenStorageKey),
           let tokens = try? JSONDecoder().decode(QuickBooksOAuthTokens.self, from: data),
           let realmID = UserDefaults.standard.string(forKey: realmIDKey) {
            self.tokens = tokens
            self.storedRealmID = realmID
            storeTokens(tokens, realmID: realmID)
        }
    }
    
    func clearTokens() {
        self.tokens = nil
        self.storedRealmID = nil
        try? KeychainStore.remove(account: keychainAccount)
        UserDefaults.standard.removeObject(forKey: tokenStorageKey)
        UserDefaults.standard.removeObject(forKey: realmIDKey)
    }

    // MARK: - Token Refresh
    func refreshTokensIfNeeded(completion: @escaping (Bool) -> Void) {
        guard let tokens = tokens else {
            completeOnMain(completion, value: false)
            return
        }
        guard tokens.expiration < Date() else {
            completeOnMain(completion, value: true)
            return
        }
        refreshAccessToken(refreshToken: tokens.refreshToken, completion: completion)
    }
    
    private func refreshAccessToken(refreshToken: String, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer") else {
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
        let base64Creds = credData.base64EncodedString()
        request.setValue("Basic \(base64Creds)", forHTTPHeaderField: "Authorization")
        let escapedToken = refreshToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? refreshToken
        let bodyString = "grant_type=refresh_token&refresh_token=\(escapedToken)"
        request.httpBody = bodyString.data(using: .utf8)
        URLSession.shared.dataTask(with: request) { data, resp, error in
            if error != nil {
                self.completeOnMain(completion, value: false)
                return
            }
            if let httpResponse = resp as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                self.completeOnMain(completion, value: false)
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String:Any],
                  let access = json["access_token"] as? String,
                  let refresh = json["refresh_token"] as? String,
                  let expires = json["expires_in"] as? Double,
                  let realmID = self.realmID else {
                self.completeOnMain(completion, value: false)
                return
            }
            let newTokens = QuickBooksOAuthTokens(
                accessToken: access,
                refreshToken: refresh,
                expiration: Date().addingTimeInterval(expires)
            )
            self.storeTokens(newTokens, realmID: realmID)
            self.completeOnMain(completion, value: true)
        }.resume()
    }

    private func completeOnMain(_ completion: @escaping (Bool) -> Void, value: Bool) {
        DispatchQueue.main.async {
            completion(value)
        }
    }

    // MARK: - API Request
    private func authorizedRequest(path: String, queryItems: [URLQueryItem] = [], method: String = "GET", body: Data? = nil, contentType: String? = nil) -> URLRequest? {
        guard let tokens = tokens, let realmID = realmID else {
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
        if let contentType = contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }

    private func makeQueryRequest(_ sql: String) -> URLRequest? {
        authorizedRequest(path: "query", queryItems: [URLQueryItem(name: "query", value: sql)])
    }

    private func resolveHTTPError(data: Data?, response: URLResponse?) -> QBError? {
        guard let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) else {
            return nil
        }
        if let data,
           let apiError = try? JSONDecoder().decode(QuickBooksFaultEnvelope.self, from: data),
           let firstError = apiError.Fault.Error.first {
            return .api(statusCode: http.statusCode, detail: "\(firstError.Message): \(firstError.Detail)")
        }
        return .http(statusCode: http.statusCode)
    }
    
    // MARK: - Public API Methods (examples; fill out for all QuickBooks endpoints)
    
    /// Fetches all invoices.
    func fetchInvoices(completion: @escaping (Result<[QuickBooksInvoice],Error>) -> Void) {
        refreshTokensIfNeeded { ok in
            guard ok, let request = self.makeQueryRequest("SELECT * FROM Invoice") else {
                completion(.failure(QBError.unauthorized))
                return
            }
            URLSession.shared.dataTask(with: request) { data, resp, error in
                Task { @MainActor in
                    if let error = error { completion(.failure(error)); return }
                    if let httpError = self.resolveHTTPError(data: data, response: resp) { completion(.failure(httpError)); return }
                    guard let data = data else { completion(.failure(QBError.noData)); return }
                    let invoices = (try? JSONDecoder().decode(QuickBooksInvoiceQueryResponse.self, from: data))?.QueryResponse.Invoice ?? []
                    completion(.success(invoices))
                }
            }.resume()
        }
    }
    
    /// Creates a new invoice.
    func createInvoice(_ invoice: QuickBooksInvoiceCreate, completion: @escaping (Result<QuickBooksInvoice,Error>) -> Void) {
        refreshTokensIfNeeded { ok in
            guard ok, let request = self.authorizedRequest(path: "invoice", method: "POST", body: try? JSONEncoder().encode(invoice), contentType: "application/json") else {
                completion(.failure(QBError.unauthorized))
                return
            }
            URLSession.shared.dataTask(with: request) { data, resp, error in
                Task { @MainActor in
                    if let error = error { completion(.failure(error)); return }
                    if let httpError = self.resolveHTTPError(data: data, response: resp) { completion(.failure(httpError)); return }
                    guard let data = data else { completion(.failure(QBError.noData)); return }
                    guard let invoice = try? JSONDecoder().decode(QuickBooksInvoiceResponse.self, from: data).Invoice else {
                        completion(.failure(QBError.decoding))
                        return
                    }
                    completion(.success(invoice))
                }
            }.resume()
        }
    }
    
    /// Fetches all bills.
    func fetchBills(completion: @escaping (Result<[QuickBooksBill],Error>) -> Void) {
        refreshTokensIfNeeded { ok in
            guard ok, let request = self.makeQueryRequest("SELECT * FROM Bill") else {
                completion(.failure(QBError.unauthorized))
                return
            }
            URLSession.shared.dataTask(with: request) { data, resp, error in
                Task { @MainActor in
                    if let error = error { completion(.failure(error)); return }
                    if let httpError = self.resolveHTTPError(data: data, response: resp) { completion(.failure(httpError)); return }
                    guard let data = data else { completion(.failure(QBError.noData)); return }
                    let bills = (try? JSONDecoder().decode(QuickBooksBillQueryResponse.self, from: data))?.QueryResponse.Bill ?? []
                    completion(.success(bills))
                }
            }.resume()
        }
    }
    
    /// Creates a new bill.
    func createBill(_ bill: QuickBooksBillCreate, completion: @escaping (Result<QuickBooksBill,Error>) -> Void) {
        refreshTokensIfNeeded { ok in
            guard ok, let request = self.authorizedRequest(path: "bill", method: "POST", body: try? JSONEncoder().encode(bill), contentType: "application/json") else {
                completion(.failure(QBError.unauthorized))
                return
            }
            URLSession.shared.dataTask(with: request) { data, resp, error in
                Task { @MainActor in
                    if let error = error { completion(.failure(error)); return }
                    if let httpError = self.resolveHTTPError(data: data, response: resp) { completion(.failure(httpError)); return }
                    guard let data = data else { completion(.failure(QBError.noData)); return }
                    guard let bill = try? JSONDecoder().decode(QuickBooksBillResponse.self, from: data).Bill else {
                        completion(.failure(QBError.decoding))
                        return
                    }
                    completion(.success(bill))
                }
            }.resume()
        }
    }
    
    /// Fetches all vendors.
    func fetchVendors(completion: @escaping (Result<[QuickBooksVendor],Error>) -> Void) {
        refreshTokensIfNeeded { ok in
            guard ok, let request = self.makeQueryRequest("SELECT * FROM Vendor") else {
                completion(.failure(QBError.unauthorized))
                return
            }
            URLSession.shared.dataTask(with: request) { data, resp, error in
                Task { @MainActor in
                    if let error = error { completion(.failure(error)); return }
                    if let httpError = self.resolveHTTPError(data: data, response: resp) { completion(.failure(httpError)); return }
                    guard let data = data else { completion(.failure(QBError.noData)); return }
                    let vendors = (try? JSONDecoder().decode(QuickBooksVendorQueryResponse.self, from: data))?.QueryResponse.Vendor ?? []
                    completion(.success(vendors))
                }
            }.resume()
        }
    }
    
    /// Creates a new vendor.
    func createVendor(_ vendor: QuickBooksVendorCreate, completion: @escaping (Result<QuickBooksVendor,Error>) -> Void) {
        refreshTokensIfNeeded { ok in
            guard ok, let request = self.authorizedRequest(path: "vendor", method: "POST", body: try? JSONEncoder().encode(vendor), contentType: "application/json") else {
                completion(.failure(QBError.unauthorized))
                return
            }
            URLSession.shared.dataTask(with: request) { data, resp, error in
                Task { @MainActor in
                    if let error = error { completion(.failure(error)); return }
                    if let httpError = self.resolveHTTPError(data: data, response: resp) { completion(.failure(httpError)); return }
                    guard let data = data else { completion(.failure(QBError.noData)); return }
                    guard let vendor = try? JSONDecoder().decode(QuickBooksVendorResponse.self, from: data).Vendor else {
                        completion(.failure(QBError.decoding))
                        return
                    }
                    completion(.success(vendor))
                }
            }.resume()
        }
    }
    
    /// Fetches all payments.
    func fetchPayments(completion: @escaping (Result<[QuickBooksPayment],Error>) -> Void) {
        refreshTokensIfNeeded { ok in
            guard ok, let request = self.makeQueryRequest("SELECT * FROM Payment") else {
                completion(.failure(QBError.unauthorized))
                return
            }
            URLSession.shared.dataTask(with: request) { data, resp, error in
                Task { @MainActor in
                    if let error = error { completion(.failure(error)); return }
                    if let httpError = self.resolveHTTPError(data: data, response: resp) { completion(.failure(httpError)); return }
                    guard let data = data else { completion(.failure(QBError.noData)); return }
                    let payments = (try? JSONDecoder().decode(QuickBooksPaymentQueryResponse.self, from: data))?.QueryResponse.Payment ?? []
                    completion(.success(payments))
                }
            }.resume()
        }
    }
    
    /// Creates a new payment.
    func createPayment(_ payment: QuickBooksPaymentCreate, completion: @escaping (Result<QuickBooksPayment,Error>) -> Void) {
        refreshTokensIfNeeded { ok in
            guard ok, let request = self.authorizedRequest(path: "payment", method: "POST", body: try? JSONEncoder().encode(payment), contentType: "application/json") else {
                completion(.failure(QBError.unauthorized))
                return
            }
            URLSession.shared.dataTask(with: request) { data, resp, error in
                Task { @MainActor in
                    if let error = error { completion(.failure(error)); return }
                    if let httpError = self.resolveHTTPError(data: data, response: resp) { completion(.failure(httpError)); return }
                    guard let data = data else { completion(.failure(QBError.noData)); return }
                    guard let payment = try? JSONDecoder().decode(QuickBooksPaymentResponse.self, from: data).Payment else {
                        completion(.failure(QBError.decoding))
                        return
                    }
                    completion(.success(payment))
                }
            }.resume()
        }
    }

    /// Uploads a document to QuickBooks (receipt, bill image, PDF).
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

            URLSession.shared.dataTask(with: request) { data, resp, error in
                Task { @MainActor in
                    if let error = error {
                        completion(.failure(error))
                        return
                    }
                    if let httpError = self.resolveHTTPError(data: data, response: resp) {
                        completion(.failure(httpError))
                        return
                    }
                    guard let data = data else {
                        completion(.failure(QBError.noData))
                        return
                    }
                    if let parsed = try? JSONDecoder().decode(QuickBooksUploadResponse.self, from: data),
                       let attachable = parsed.AttachableResponse.first {
                        completion(.success(attachable.Id))
                        return
                    }
                    // Return a stable success marker when QuickBooks accepts upload but response shape differs.
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
    
    // Placeholder for future implementation of receipt upload
    /*
    /// Uploads a receipt file (image/pdf) for a transaction.
    func uploadReceipt(forTransactionId txnId: String, fileData: Data, fileName: String, completion: @escaping (Result<ReceiptUploadResponse, Error>) -> Void) {
        // Implementation will involve multipart form-data POST to the appropriate endpoint
    }
    */
    
    // Example error types
    enum QBError: Error, LocalizedError {
        case unauthorized
        case noData
        case decoding
        case http(statusCode: Int)
        case api(statusCode: Int, detail: String)

        var errorDescription: String? {
            switch self {
            case .unauthorized:
                return "QuickBooks access token is missing or expired."
            case .noData:
                return "QuickBooks returned no data."
            case .decoding:
                return "QuickBooks response decoding failed."
            case .http(let statusCode):
                return "QuickBooks request failed (HTTP \(statusCode))."
            case .api(let statusCode, let detail):
                return "QuickBooks API error (HTTP \(statusCode)): \(detail)"
            }
        }
    }
}

// MARK: - QuickBooks Models (simplified; expand for all needed fields)
struct QuickBooksInvoiceQueryResponse: Codable {
    let QueryResponse: QuickBooksInvoiceList
}
struct QuickBooksInvoiceList: Codable {
    let Invoice: [QuickBooksInvoice]?
}
struct QuickBooksInvoice: Codable, Identifiable {
    let Id: String
    let CustomerRef: QuickBooksReference
    let TotalAmt: Double
    let TxnDate: String
    var id: String { Id }
}
struct QuickBooksReference: Codable {
    let value: String
    let name: String?

    init(value: String, name: String?) {
        self.value = value
        self.name = name
    }
}
struct QuickBooksInvoiceCreate: Codable {
    let CustomerRef: QuickBooksReference
    let Line: [QuickBooksLineItem]

    init(CustomerRef: QuickBooksReference, Line: [QuickBooksLineItem]) {
        self.CustomerRef = CustomerRef
        self.Line = Line
    }
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
struct QuickBooksInvoiceResponse: Codable {
    let Invoice: QuickBooksInvoice
}

// Bills
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
    let TxnDate: String
    var id: String { Id }
}
struct QuickBooksBillCreate: Codable {
    let VendorRef: QuickBooksReference
    let Line: [QuickBooksLineItem]
}
struct QuickBooksBillResponse: Codable {
    let Bill: QuickBooksBill
}
// Vendors
struct QuickBooksVendorQueryResponse: Codable {
    let QueryResponse: QuickBooksVendorList
}
struct QuickBooksVendorList: Codable {
    let Vendor: [QuickBooksVendor]?
}
struct QuickBooksVendor: Codable, Identifiable {
    let Id: String
    let DisplayName: String
    var id: String { Id }
}
struct QuickBooksVendorCreate: Codable {
    let DisplayName: String
}
struct QuickBooksVendorResponse: Codable {
    let Vendor: QuickBooksVendor
}

// Payments
struct QuickBooksPaymentQueryResponse: Codable {
    let QueryResponse: QuickBooksPaymentList
}
struct QuickBooksPaymentList: Codable {
    let Payment: [QuickBooksPayment]?
}
struct QuickBooksPayment: Codable, Identifiable {
    let Id: String
    let CustomerRef: QuickBooksReference?
    let TotalAmt: Double
    let TxnDate: String
    var id: String { Id }
}
struct QuickBooksPaymentCreate: Codable {
    let CustomerRef: QuickBooksReference?
    let TotalAmt: Double
    let Line: [QuickBooksLineItem]?
}
struct QuickBooksPaymentResponse: Codable {
    let Payment: QuickBooksPayment
}

struct QuickBooksFaultEnvelope: Codable {
    let Fault: QuickBooksFault
}

struct QuickBooksFault: Codable {
    let Error: [QuickBooksFaultError]
}

struct QuickBooksFaultError: Codable {
    let Message: String
    let Detail: String
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

// ... More models as needed (Receipts, etc.)

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
