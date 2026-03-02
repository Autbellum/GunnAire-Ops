import Foundation
import Combine
import AuthenticationServices

/// Model representing OAuth2 tokens
struct QuickBooksOAuthTokens: Codable {
    let accessToken: String
    let refreshToken: String
    let expiration: Date
}

/// Singleton QuickBooks API client
final class QuickBooksDataAPI: ObservableObject {
    static let shared = QuickBooksDataAPI()
    
    @Published private(set) var tokens: QuickBooksOAuthTokens?
    private let clientId = Config.QuickBooks.clientID
    private let clientSecret = Config.QuickBooks.clientSecret
    private let baseURL = "https://quickbooks.api.intuit.com/v3/company/"
    private let realmIDKey = "QuickBooksRealmID"
    
    // Storage keys
    private let tokenStorageKey = "QuickBooksOAuthTokens"
    
    var realmID: String? {
        UserDefaults.standard.string(forKey: realmIDKey)
    }

    // MARK: - OAuth Token Management
    func storeTokens(_ tokens: QuickBooksOAuthTokens, realmID: String) {
        self.tokens = tokens
        UserDefaults.standard.set(realmID, forKey: realmIDKey)
        if let data = try? JSONEncoder().encode(tokens) {
            UserDefaults.standard.set(data, forKey: tokenStorageKey)
        }
    }
    
    func loadTokens() {
        if let data = UserDefaults.standard.data(forKey: tokenStorageKey),
           let tokens = try? JSONDecoder().decode(QuickBooksOAuthTokens.self, from: data) {
            self.tokens = tokens
        }
    }
    
    func clearTokens() {
        self.tokens = nil
        UserDefaults.standard.removeObject(forKey: tokenStorageKey)
        UserDefaults.standard.removeObject(forKey: realmIDKey)
    }

    // MARK: - Token Refresh
    func refreshTokensIfNeeded(completion: @escaping (Bool) -> Void) {
        guard let tokens = tokens, tokens.expiration < Date() else {
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
    private func authorizedRequest(path: String, method: String = "GET", body: Data? = nil, contentType: String? = nil) -> URLRequest? {
        guard let tokens = tokens, let realmID = realmID, let url = URL(string: baseURL + "\(realmID)/\(path)") else {
            return nil
        }
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
    
    // MARK: - Public API Methods (examples; fill out for all QuickBooks endpoints)
    
    /// Fetches all invoices.
    func fetchInvoices(completion: @escaping (Result<[QuickBooksInvoice],Error>) -> Void) {
        refreshTokensIfNeeded { ok in
            guard ok, let request = self.authorizedRequest(path: "query?query=SELECT * FROM Invoice") else {
                completion(.failure(QBError.unauthorized))
                return
            }
            URLSession.shared.dataTask(with: request) { data, resp, error in
                if let error = error { completion(.failure(error)); return }
                guard let data = data else { completion(.failure(QBError.noData)); return }
                // Decode response
                let invoices = (try? JSONDecoder().decode(QuickBooksInvoiceQueryResponse.self, from: data))?.QueryResponse.Invoice ?? []
                DispatchQueue.main.async { completion(.success(invoices)) }
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
                if let error = error { completion(.failure(error)); return }
                guard let data = data else { completion(.failure(QBError.noData)); return }
                guard let invoice = try? JSONDecoder().decode(QuickBooksInvoiceResponse.self, from: data).Invoice else {
                    completion(.failure(QBError.decoding))
                    return
                }
                DispatchQueue.main.async { completion(.success(invoice)) }
            }.resume()
        }
    }
    
    /// Fetches all bills.
    func fetchBills(completion: @escaping (Result<[QuickBooksBill],Error>) -> Void) {
        refreshTokensIfNeeded { ok in
            guard ok, let request = self.authorizedRequest(path: "query?query=SELECT * FROM Bill") else {
                completion(.failure(QBError.unauthorized))
                return
            }
            URLSession.shared.dataTask(with: request) { data, resp, error in
                if let error = error { completion(.failure(error)); return }
                guard let data = data else { completion(.failure(QBError.noData)); return }
                let bills = (try? JSONDecoder().decode(QuickBooksBillQueryResponse.self, from: data))?.QueryResponse.Bill ?? []
                DispatchQueue.main.async { completion(.success(bills)) }
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
                if let error = error { completion(.failure(error)); return }
                guard let data = data else { completion(.failure(QBError.noData)); return }
                guard let bill = try? JSONDecoder().decode(QuickBooksBillResponse.self, from: data).Bill else {
                    completion(.failure(QBError.decoding))
                    return
                }
                DispatchQueue.main.async { completion(.success(bill)) }
            }.resume()
        }
    }
    
    /// Fetches all vendors.
    func fetchVendors(completion: @escaping (Result<[QuickBooksVendor],Error>) -> Void) {
        refreshTokensIfNeeded { ok in
            guard ok, let request = self.authorizedRequest(path: "query?query=SELECT * FROM Vendor") else {
                completion(.failure(QBError.unauthorized))
                return
            }
            URLSession.shared.dataTask(with: request) { data, resp, error in
                if let error = error { completion(.failure(error)); return }
                guard let data = data else { completion(.failure(QBError.noData)); return }
                let vendors = (try? JSONDecoder().decode(QuickBooksVendorQueryResponse.self, from: data))?.QueryResponse.Vendor ?? []
                DispatchQueue.main.async { completion(.success(vendors)) }
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
                if let error = error { completion(.failure(error)); return }
                guard let data = data else { completion(.failure(QBError.noData)); return }
                guard let vendor = try? JSONDecoder().decode(QuickBooksVendorResponse.self, from: data).Vendor else {
                    completion(.failure(QBError.decoding))
                    return
                }
                DispatchQueue.main.async { completion(.success(vendor)) }
            }.resume()
        }
    }
    
    /// Fetches all payments.
    func fetchPayments(completion: @escaping (Result<[QuickBooksPayment],Error>) -> Void) {
        refreshTokensIfNeeded { ok in
            guard ok, let request = self.authorizedRequest(path: "query?query=SELECT * FROM Payment") else {
                completion(.failure(QBError.unauthorized))
                return
            }
            URLSession.shared.dataTask(with: request) { data, resp, error in
                if let error = error { completion(.failure(error)); return }
                guard let data = data else { completion(.failure(QBError.noData)); return }
                let payments = (try? JSONDecoder().decode(QuickBooksPaymentQueryResponse.self, from: data))?.QueryResponse.Payment ?? []
                DispatchQueue.main.async { completion(.success(payments)) }
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
                if let error = error { completion(.failure(error)); return }
                guard let data = data else { completion(.failure(QBError.noData)); return }
                guard let payment = try? JSONDecoder().decode(QuickBooksPaymentResponse.self, from: data).Payment else {
                    completion(.failure(QBError.decoding))
                    return
                }
                DispatchQueue.main.async { completion(.success(payment)) }
            }.resume()
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
    enum QBError: Error {
        case unauthorized, noData, decoding
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

// ... More models as needed (Receipts, etc.)
