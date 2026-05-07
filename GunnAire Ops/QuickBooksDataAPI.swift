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
}

final class QuickBooksDataAPI: ObservableObject {
    static let shared = QuickBooksDataAPI()

    @Published private(set) var tokens: QuickBooksOAuthTokens?
    @Published private(set) var storedRealmID: String?

    private let clientId = Config.QuickBooks.clientID
    private let clientSecret = Config.QuickBooks.clientSecret
    private let realmIDKey = "QuickBooksRealmID"
    private let tokenStorageKey = "QuickBooksOAuthTokens"
    private let keychainAccount = "QuickBooksOAuthPayload"
    private let minorVersion = "75"

    private var baseURL: String {
        if Config.QuickBooks.environment.lowercased() == "sandbox" {
            return "https://sandbox-quickbooks.api.intuit.com/v3/company/"
        }
        return "https://quickbooks.api.intuit.com/v3/company/"
    }

    var realmID: String? {
        storedRealmID
    }

    var isAuthenticated: Bool {
        Config.QuickBooks.isConfigured && tokens != nil && storedRealmID != nil
    }

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
            tokens = payload.tokens
            storedRealmID = payload.realmID
            return
        }

        if let data = UserDefaults.standard.data(forKey: tokenStorageKey),
           let tokens = try? JSONDecoder().decode(QuickBooksOAuthTokens.self, from: data),
           let realmID = UserDefaults.standard.string(forKey: realmIDKey) {
            storeTokens(tokens, realmID: realmID)
        }
    }

    func clearTokens() {
        tokens = nil
        storedRealmID = nil
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

    private func resolveHTTPError(data: Data?, response: URLResponse?) -> QBError? {
        guard let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) else {
            return nil
        }

        if let data,
           let apiError = try? JSONDecoder().decode(QuickBooksFaultEnvelope.self, from: data),
           let firstError = apiError.Fault.Error.first {
            return .api(statusCode: http.statusCode, detail: "\(firstError.Message): \(firstError.Detail)")
        }

        if let data,
           let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return .httpDetail(statusCode: http.statusCode, detail: raw)
        }

        return .http(statusCode: http.statusCode)
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
    let LinkedTxn: [QuickBooksLinkedTxn]
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
    let Active: Bool?

    var id: String { Id }

    private enum CodingKeys: String, CodingKey {
        case Id, Name, Description, UnitPrice, Active
        case ItemType = "Type"
    }
}

struct QuickBooksItemCreate: Codable {
    let Name: String
    let ItemType: String
    let Description: String?
    let UnitPrice: Double?
    let IncomeAccountRef: QuickBooksReference?

    private enum CodingKeys: String, CodingKey {
        case Name, Description, UnitPrice, IncomeAccountRef
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
}

struct QuickBooksPayment: Codable, Identifiable {
    let Id: String
    let CustomerRef: QuickBooksReference?
    let TotalAmt: Double
    let TxnDate: String?
    let PrivateNote: String?
    let Line: [QuickBooksPaymentLine]?

    var id: String { Id }

    private enum CodingKeys: String, CodingKey {
        case Id, CustomerRef, TotalAmt, TxnDate, PrivateNote, Line
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        Id = try container.decodeIfPresent(String.self, forKey: .Id) ?? UUID().uuidString
        CustomerRef = try container.decodeIfPresent(QuickBooksReference.self, forKey: .CustomerRef)
        TotalAmt = try container.decodeIfPresent(Double.self, forKey: .TotalAmt) ?? 0
        TxnDate = try container.decodeIfPresent(String.self, forKey: .TxnDate)
        PrivateNote = try container.decodeIfPresent(String.self, forKey: .PrivateNote)
        Line = try container.decodeIfPresent([QuickBooksPaymentLine].self, forKey: .Line)
    }
}

struct QuickBooksPaymentCreate: Codable {
    let CustomerRef: QuickBooksReference?
    let TotalAmt: Double
    let PrivateNote: String?
    let PaymentRefNum: String?
    let Line: [QuickBooksPaymentLine]?
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

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
