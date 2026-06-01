import Foundation
import SwiftData

struct BackendAppUserRecord: Codable, Identifiable {
    let email: String
    let role: String
    let isActive: Bool
    let createdAt: String?

    var id: String { email }
}

struct BackendDocumentUploadResponse: Codable {
    let id: String
    let filename: String
    let storedPath: String?
    let createdAt: String?
}

struct BackendPaymentUploadResponse: Codable {
    let id: String
    let paymentID: String
    let createdAt: String?
}

enum GunnAireBackendError: LocalizedError {
    case notConfigured
    case invalidURL(String)
    case invalidResponse
    case server(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "The GunnAire backend is not configured."
        case .invalidURL(let path):
            return "The GunnAire backend URL is invalid for \(path)."
        case .invalidResponse:
            return "The GunnAire backend returned an invalid response."
        case .server(let statusCode, let message):
            return "The GunnAire backend returned HTTP \(statusCode): \(message)"
        }
    }
}

enum GunnAireBackendService {
    private struct UsersResponse: Codable {
        let users: [BackendAppUserRecord]
    }

    private struct UserPayload: Codable {
        let email: String
        let role: String
        let isActive: Bool
    }

    private struct DocumentUploadPayload: Codable {
        let filename: String
        let contentType: String
        let kind: String
        let serviceCallID: String?
        let customerName: String?
        let dataBase64: String
    }

    private struct PaymentCollectionPayload: Codable {
        let paymentID: String
        let invoiceID: String
        let invoiceQuickBooksID: String?
        let customerName: String
        let customerEmail: String?
        let amount: Double
        let method: String
        let cardLast4: String?
        let authorizationReference: String?
        let processor: String?
        let notes: String?
        let collectedBy: String?
        let collectedAt: String
    }

    static var isConfigured: Bool {
        Config.Backend.isConfigured
    }

    static func fetchUsers() async throws -> [BackendAppUserRecord] {
        let data = try await send(path: "/api/users", method: "GET")
        return try JSONDecoder().decode(UsersResponse.self, from: data).users
    }

    @discardableResult
    @MainActor
    static func refreshUsers(
        into modelContext: ModelContext,
        currentUsers: [AppUser],
        technicians: [Technician]
    ) async throws -> [AppUser] {
        let remoteUsers = try await fetchUsers()
        var knownTechnicians = technicians

        for remoteUser in remoteUsers {
            let email = AppAccess.normalizedEmail(remoteUser.email)
            guard !email.isEmpty else { continue }
            let role = AppUserRole.allCases.first {
                $0.rawValue.caseInsensitiveCompare(remoteUser.role) == .orderedSame
            } ?? .standard

            if let existing = currentUsers.first(where: { $0.email == email }) {
                existing.role = role
                existing.isActive = remoteUser.isActive
                if remoteUser.isActive {
                    let technician = AppAccess.ensureTechnicianRecord(
                        for: email,
                        technicians: knownTechnicians,
                        modelContext: modelContext
                    )
                    knownTechnicians.append(technician)
                }
            } else {
                let user = AppUser(email: email, role: role, isActive: remoteUser.isActive)
                modelContext.insert(user)
                if remoteUser.isActive {
                    let technician = AppAccess.ensureTechnicianRecord(
                        for: email,
                        technicians: knownTechnicians,
                        modelContext: modelContext
                    )
                    knownTechnicians.append(technician)
                }
            }
        }

        if !currentUsers.contains(where: { $0.email == AppAccess.primaryAdminEmail }) &&
            !remoteUsers.contains(where: { AppAccess.normalizedEmail($0.email) == AppAccess.primaryAdminEmail }) {
            let admin = AppUser(email: AppAccess.primaryAdminEmail, role: .admin)
            modelContext.insert(admin)
            let technician = AppAccess.ensureTechnicianRecord(
                for: admin.email,
                technicians: knownTechnicians,
                modelContext: modelContext
            )
            knownTechnicians.append(technician)
        }

        try? modelContext.save()
        let descriptor = FetchDescriptor<AppUser>(sortBy: [SortDescriptor(\AppUser.email)])
        return (try? modelContext.fetch(descriptor)) ?? currentUsers
    }

    @discardableResult
    static func upsertUser(email: String, role: AppUserRole, isActive: Bool) async throws -> BackendAppUserRecord {
        let payload = UserPayload(
            email: AppAccess.normalizedEmail(email),
            role: role.rawValue,
            isActive: isActive
        )
        let body = try JSONEncoder().encode(payload)
        let data = try await send(path: "/api/users", method: "POST", body: body)
        return try JSONDecoder().decode(BackendAppUserRecord.self, from: data)
    }

    static func deactivateUser(email: String) async throws {
        let encodedEmail = AppAccess.normalizedEmail(email).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? email
        _ = try await send(path: "/api/users/\(encodedEmail)", method: "DELETE")
    }

    @discardableResult
    static func uploadDocument(
        data: Data,
        filename: String,
        contentType: String,
        kind: String,
        serviceCallID: UUID?,
        customerName: String?
    ) async throws -> BackendDocumentUploadResponse {
        let payload = DocumentUploadPayload(
            filename: filename,
            contentType: contentType,
            kind: kind,
            serviceCallID: serviceCallID?.uuidString,
            customerName: customerName,
            dataBase64: data.base64EncodedString()
        )
        let body = try JSONEncoder().encode(payload)
        let responseData = try await send(path: "/api/documents", method: "POST", body: body)
        return try JSONDecoder().decode(BackendDocumentUploadResponse.self, from: responseData)
    }

    @discardableResult
    static func uploadPaymentCollection(_ payment: Payment, collectedBy: String?) async throws -> BackendPaymentUploadResponse {
        let payload = PaymentCollectionPayload(
            paymentID: payment.id.uuidString,
            invoiceID: payment.invoice.id.uuidString,
            invoiceQuickBooksID: payment.invoice.quickBooksID,
            customerName: payment.invoice.customer.name,
            customerEmail: payment.invoice.customer.email,
            amount: payment.amount,
            method: payment.method,
            cardLast4: payment.cardLast4,
            authorizationReference: payment.authorizationReference,
            processor: payment.processor,
            notes: payment.notes,
            collectedBy: AppAccess.normalizedEmail(collectedBy).nilIfBlank,
            collectedAt: ISO8601DateFormatter().string(from: payment.date)
        )
        let body = try JSONEncoder().encode(payload)
        let responseData = try await send(path: "/api/payments", method: "POST", body: body)
        return try JSONDecoder().decode(BackendPaymentUploadResponse.self, from: responseData)
    }

    private static func send(path: String, method: String, body: Data? = nil) async throws -> Data {
        let request = try makeRequest(path: path, method: method, body: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GunnAireBackendError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw GunnAireBackendError.server(statusCode: httpResponse.statusCode, message: message)
        }
        return data
    }

    private static func makeRequest(path: String, method: String, body: Data?) throws -> URLRequest {
        guard Config.Backend.isConfigured else {
            throw GunnAireBackendError.notConfigured
        }
        let baseURL = Config.Backend.normalizedBaseURL
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw GunnAireBackendError.invalidURL(path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(Config.Backend.apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
