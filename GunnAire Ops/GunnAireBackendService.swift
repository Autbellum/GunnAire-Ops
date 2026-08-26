import Foundation
import SwiftData

struct BackendAppUserRecord: Codable, Identifiable {
    let email: String
    let role: String
    let isActive: Bool
    let createdAt: String?

    var id: String { email }
}

struct BackendSessionRecord: Codable {
    let user: BackendAppUserRecord
}

struct BackendDocumentUploadResponse: Codable {
    let id: String
    let filename: String
    let storedPath: String?
    let createdAt: String?
}

struct BackendDocumentRecord: Codable, Identifiable {
    let id: String
    let filename: String
    let contentType: String
    let kind: String
    let serviceCallID: String?
    let invoiceID: String?
    let estimateID: String?
    let customerEquipmentID: String?
    let equipmentName: String?
    let customerName: String?
    let storedPath: String?
    let createdAt: String?

    var serviceCallUUID: UUID? {
        serviceCallID.flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    var invoiceUUID: UUID? {
        invoiceID.flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    var estimateUUID: UUID? {
        estimateID.flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    var customerEquipmentUUID: UUID? {
        customerEquipmentID.flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    func matchesCustomerName(_ customerName: String) -> Bool {
        let expected = customerName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !expected.isEmpty else { return false }
        return self.customerName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == expected
    }

    func matchesCustomerDocumentSearch(_ query: String) -> Bool {
        let normalizedQuery = searchableText(query)
        guard !normalizedQuery.isEmpty else { return true }
        return [
            filename,
            contentType,
            kind,
            serviceCallID,
            invoiceID,
            estimateID,
            customerEquipmentID,
            equipmentName,
            createdAt
        ]
        .compactMap { $0 }
        .map(searchableText)
        .joined(separator: " ")
        .contains(normalizedQuery)
    }

    private func searchableText(_ value: String) -> String {
        value
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

struct BackendPaymentUploadResponse: Codable {
    let id: String
    let paymentID: String
    let createdAt: String?
}

struct BackendPaymentCollectionRecord: Codable, Identifiable {
    let id: String
    let paymentID: String
    let invoiceID: String?
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
    let createdAt: String?
}

/// A server-authorized field collection task. The assignment intentionally
/// carries only the minimum collection context; card data never enters this
/// record or the notification path.
struct BackendFieldPaymentAssignmentRecord: Codable, Identifiable {
    let id: String
    let invoiceID: String
    let customerName: String
    let amount: Double
    let assignedTo: String
    let assignedBy: String
    let status: String
    let createdAt: String
    let acceptedAt: String?
    let cancelledAt: String?

    var invoiceUUID: UUID? {
        UUID(uuidString: invoiceID.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var isActionable: Bool {
        status == "pending" || status == "accepted"
    }
}

/// Keeps the field collection prompt queue deterministic. Each newly seen
/// pending assignment is announced once, so technicians are not interrupted
/// repeatedly while still receiving every collection task assigned to them.
enum FieldPaymentAssignmentPromptQueue {
    static func nextUnannouncedPendingAssignment(
        from assignments: [BackendFieldPaymentAssignmentRecord],
        announcedIDs: Set<String>
    ) -> BackendFieldPaymentAssignmentRecord? {
        assignments.first { $0.status == "pending" && !announcedIDs.contains($0.id) }
    }

    static func recordingAnnouncement(
        for assignmentID: String,
        previouslyAnnouncedIDs: Set<String>,
        limit: Int = 200
    ) -> [String] {
        guard !assignmentID.isEmpty else { return Array(previouslyAnnouncedIDs).sorted() }
        let sortedIDs: [String] = Array(previouslyAnnouncedIDs.union([assignmentID])).sorted()
        return Array(sortedIDs.suffix(limit))
    }
}

struct BackendCustomerCommunicationRecord: Codable, Identifiable {
    let id: String
    let customerName: String
    let customerEmail: String?
    let serviceCallID: String?
    let invoiceID: String?
    let estimateID: String?
    let channel: String
    let direction: String
    let recipient: String
    let subject: String
    let deliveryStatus: String
    let attachmentFileNames: [String]
    let providerMessageID: String?
    let occurredAt: String
    let createdAt: String?
}

struct BackendServiceRequestRecord: Codable, Identifiable {
    let id: String
    let customerName: String
    let phone: String?
    let email: String?
    let address: String?
    let requestedServiceType: String
    let urgency: String
    let summary: String
    let preferredDate: String?
    let createdAt: String
}

struct BackendAuditEventRecord: Codable, Identifiable {
    let id: String
    let occurredAt: String
    let actorEmail: String
    let action: String
    let subjectType: String
    let subjectID: String?

    var summary: String {
        let subject = subjectID.map { " • \($0.prefix(8))" } ?? ""
        return "\(action.capitalized) \(subjectType.replacingOccurrences(of: "-", with: " "))\(subject)"
    }
}

struct BackendReadinessComponent: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let status: String
    let detail: String

    var isReady: Bool { status.caseInsensitiveCompare("ready") == .orderedSame }
    var isError: Bool { status.caseInsensitiveCompare("error") == .orderedSame }
}

struct BackendReadinessSnapshot: Codable, Equatable {
    let status: String
    let serviceVersion: String
    let checkedAt: String
    let components: [BackendReadinessComponent]

    var isReady: Bool { status.caseInsensitiveCompare("ready") == .orderedSame }
    var attentionCount: Int { components.filter { !$0.isReady }.count }
}

/// Non-sensitive QuickBooks change metadata received by the backend's signed
/// CloudEvents webhook. The raw provider payload and company realm stay on the server.
struct BackendQuickBooksWebhookEvent: Codable, Identifiable, Equatable {
    let id: String
    let entityType: String
    let entityID: String
    let operation: String
    let occurredAt: String
    let receivedAt: String

    var entityLabel: String {
        entityType
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    var summary: String {
        "\(entityLabel) \(operation.lowercased())"
    }
}

struct BackendCustomerPortalLink: Codable, Identifiable {
    let id: String
    let url: String
    let expiresAt: String
}

struct BackendCustomerPortalLinkRecord: Codable, Identifiable {
    let id: String
    let customerName: String
    let customerEmail: String
    let serviceCallID: String?
    let invoiceID: String?
    let title: String
    let appointmentSummary: String?
    let invoiceReference: String?
    let balanceDue: Double?
    let expiresAt: String
    let revokedAt: String?
    let createdAt: String
    let createdBy: String
}

enum GunnAireBackendError: LocalizedError {
    case notConfigured
    case invalidURL(String)
    case invalidResponse
    case server(statusCode: Int, message: String)
    case missingGoogleIdentityToken

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
        case .missingGoogleIdentityToken:
            return "Sign in with Google again before accessing the shared business server."
        }
    }
}

enum GunnAireBackendService {
    private struct QuickBooksCodePayload: Codable {
        let code: String
        let realmID: String
        let environment: String
    }
    private struct QuickBooksRefreshPayload: Codable {
        let realmID: String
        let environment: String
    }
    private struct QuickBooksTokenResponse: Codable {
        let accessToken: String
        let expiresIn: Double
    }
    private struct UsersResponse: Codable {
        let users: [BackendAppUserRecord]
    }

    private struct PaymentsResponse: Codable {
        let payments: [BackendPaymentCollectionRecord]
    }

    private struct FieldPaymentAssignmentsResponse: Codable {
        let assignments: [BackendFieldPaymentAssignmentRecord]
    }

    private struct FieldPaymentAssignmentResponse: Codable {
        let assignment: BackendFieldPaymentAssignmentRecord
    }

    private struct DocumentsResponse: Codable {
        let documents: [BackendDocumentRecord]
    }

    private struct CommunicationsResponse: Codable {
        let communications: [BackendCustomerCommunicationRecord]
    }

    private struct ServiceRequestsResponse: Codable {
        let serviceRequests: [BackendServiceRequestRecord]
    }

    private struct AuditEventsResponse: Codable {
        let events: [BackendAuditEventRecord]
    }

    private struct QuickBooksWebhookEventsResponse: Codable {
        let events: [BackendQuickBooksWebhookEvent]
    }

    private struct QuickBooksWebhookAcknowledgementPayload: Codable {
        let eventIDs: [String]
    }

    private struct CustomerPortalLinksResponse: Codable {
        let links: [BackendCustomerPortalLinkRecord]
    }

    private struct CustomerCommunicationPayload: Codable {
        let id: String
        let customerName: String
        let customerEmail: String?
        let serviceCallID: String?
        let invoiceID: String?
        let estimateID: String?
        let channel: String
        let direction: String
        let recipient: String
        let subject: String
        let deliveryStatus: String
        let attachmentFileNames: [String]
        let providerMessageID: String?
        let occurredAt: String
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
        let invoiceID: String?
        let estimateID: String?
        let customerEquipmentID: String?
        let equipmentName: String?
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

    private struct FieldPaymentAssignmentPayload: Codable {
        let invoiceID: String
        let customerName: String
        let amount: Double
        let assignedTo: String
    }

    private struct CustomerPortalLinkPayload: Codable {
        let customerName: String
        let customerEmail: String
        let serviceCallID: String?
        let invoiceID: String?
        let title: String
        let appointmentSummary: String?
        let invoiceReference: String?
        let balanceDue: Double?
        let expiresInDays: Int
    }

    static var isConfigured: Bool {
        Config.Backend.isConfigured
    }

    /// Exchanges an Intuit authorization code through the confidential backend bridge.
    /// The backend encrypts the rotating refresh token; the app receives only a
    /// short-lived access token for QBO requests.
    static func exchangeQuickBooksAuthorizationCode(_ code: String, realmID: String) async throws -> QuickBooksOAuthTokens {
        let data = try JSONEncoder().encode(
            QuickBooksCodePayload(code: code, realmID: realmID, environment: Config.QuickBooks.environment.lowercased())
        )
        let responseData = try await send(path: "/api/qbo/exchange", method: "POST", body: data)
        return try decodeQuickBooksTokens(from: responseData)
    }

    /// Requests a new short-lived access token from the backend's encrypted,
    /// server-side QBO connection. No refresh token leaves the backend.
    static func refreshQuickBooksAccessToken(realmID: String, environment: String) async throws -> QuickBooksOAuthTokens {
        let data = try JSONEncoder().encode(
            QuickBooksRefreshPayload(realmID: realmID, environment: environment.lowercased())
        )
        let responseData = try await send(path: "/api/qbo/refresh", method: "POST", body: data)
        return try decodeQuickBooksTokens(from: responseData)
    }

    static func revokeQuickBooksConnection() async throws {
        _ = try await send(path: "/api/qbo/revoke", method: "POST")
    }

    private static func decodeQuickBooksTokens(from data: Data) throws -> QuickBooksOAuthTokens {
        let response = try JSONDecoder().decode(QuickBooksTokenResponse.self, from: data)
        return QuickBooksOAuthTokens(
            accessToken: response.accessToken,
            expiration: Date().addingTimeInterval(response.expiresIn)
        )
    }

    static func fetchUsers() async throws -> [BackendAppUserRecord] {
        let data = try await send(path: "/api/users", method: "GET")
        return try JSONDecoder().decode(UsersResponse.self, from: data).users
    }

    static func fetchCurrentUser() async throws -> BackendAppUserRecord {
        let data = try await send(path: "/api/session", method: "GET")
        return try JSONDecoder().decode(BackendSessionRecord.self, from: data).user
    }

    @discardableResult
    @MainActor
    static func refreshCurrentUser(
        into modelContext: ModelContext,
        currentUsers: [AppUser],
        technicians: [Technician]
    ) async throws -> [AppUser] {
        let remoteUser = try await fetchCurrentUser()
        let email = AppAccess.normalizedEmail(remoteUser.email)
        guard !email.isEmpty else { return currentUsers }
        let role = AppUserRole.allCases.first {
            $0.rawValue.caseInsensitiveCompare(remoteUser.role) == .orderedSame
        } ?? .standard
        let user = currentUsers.first(where: { $0.email == email }) ?? AppUser(email: email, role: role, isActive: remoteUser.isActive)
        if user.modelContext == nil {
            modelContext.insert(user)
        }
        user.role = role
        user.isActive = remoteUser.isActive
        if remoteUser.isActive {
            _ = AppAccess.ensureTechnicianRecord(for: email, technicians: technicians, modelContext: modelContext)
        }
        try? modelContext.save()
        let descriptor = FetchDescriptor<AppUser>(sortBy: [SortDescriptor(\AppUser.email)])
        return (try? modelContext.fetch(descriptor)) ?? currentUsers
    }

    static func fetchPaymentCollections() async throws -> [BackendPaymentCollectionRecord] {
        let data = try await send(path: "/api/payments", method: "GET")
        return try decodePaymentCollections(from: data)
    }

    static func fetchFieldPaymentAssignments() async throws -> [BackendFieldPaymentAssignmentRecord] {
        let data = try await send(path: "/api/field-payment-assignments", method: "GET")
        return try JSONDecoder().decode(FieldPaymentAssignmentsResponse.self, from: data).assignments
    }

    static func createFieldPaymentAssignment(
        invoice: Invoice,
        amount: Double,
        assignedTo email: String
    ) async throws -> BackendFieldPaymentAssignmentRecord {
        let payload = FieldPaymentAssignmentPayload(
            invoiceID: invoice.id.uuidString,
            customerName: invoice.customer.name,
            amount: amount,
            assignedTo: AppAccess.normalizedEmail(email)
        )
        let data = try JSONEncoder().encode(payload)
        let responseData = try await send(path: "/api/field-payment-assignments", method: "POST", body: data)
        return try JSONDecoder().decode(FieldPaymentAssignmentResponse.self, from: responseData).assignment
    }

    static func acceptFieldPaymentAssignment(id: String) async throws -> BackendFieldPaymentAssignmentRecord {
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let data = try await send(path: "/api/field-payment-assignments/\(encodedID)/accept", method: "POST")
        return try JSONDecoder().decode(FieldPaymentAssignmentResponse.self, from: data).assignment
    }

    static func cancelFieldPaymentAssignment(id: String) async throws -> BackendFieldPaymentAssignmentRecord {
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let data = try await send(path: "/api/field-payment-assignments/\(encodedID)", method: "DELETE")
        return try JSONDecoder().decode(FieldPaymentAssignmentResponse.self, from: data).assignment
    }

    static func decodePaymentCollections(from data: Data) throws -> [BackendPaymentCollectionRecord] {
        try JSONDecoder().decode(PaymentsResponse.self, from: data).payments
    }

    static func fetchDocuments() async throws -> [BackendDocumentRecord] {
        let data = try await send(path: "/api/documents", method: "GET")
        return try decodeDocuments(from: data)
    }

    static func fetchCustomerCommunications() async throws -> [BackendCustomerCommunicationRecord] {
        let data = try await send(path: "/api/communications", method: "GET")
        return try JSONDecoder().decode(CommunicationsResponse.self, from: data).communications
    }

    static func fetchServiceRequests() async throws -> [BackendServiceRequestRecord] {
        let data = try await send(path: "/api/service-requests", method: "GET")
        return try JSONDecoder().decode(ServiceRequestsResponse.self, from: data).serviceRequests
    }

    static func fetchAuditEvents() async throws -> [BackendAuditEventRecord] {
        let data = try await send(path: "/api/audit-events", method: "GET")
        return try JSONDecoder().decode(AuditEventsResponse.self, from: data).events
    }

    static func fetchReadiness() async throws -> BackendReadinessSnapshot {
        let data = try await send(path: "/api/readiness", method: "GET")
        return try decodeReadiness(from: data)
    }

    static func decodeReadiness(from data: Data) throws -> BackendReadinessSnapshot {
        try JSONDecoder().decode(BackendReadinessSnapshot.self, from: data)
    }

    static func fetchQuickBooksWebhookEvents() async throws -> [BackendQuickBooksWebhookEvent] {
        let data = try await send(path: "/api/qbo/webhook-events", method: "GET")
        return try decodeQuickBooksWebhookEvents(from: data)
    }

    static func decodeQuickBooksWebhookEvents(from data: Data) throws -> [BackendQuickBooksWebhookEvent] {
        try JSONDecoder().decode(QuickBooksWebhookEventsResponse.self, from: data).events
    }

    static func acknowledgeQuickBooksWebhookEvents(ids: [String]) async throws {
        let uniqueIDs = Array(Set(ids.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })).sorted()
        guard !uniqueIDs.isEmpty else { return }
        let body = try JSONEncoder().encode(QuickBooksWebhookAcknowledgementPayload(eventIDs: uniqueIDs))
        _ = try await send(path: "/api/qbo/webhook-events/acknowledge", method: "POST", body: body)
    }

    static func claimServiceRequest(id: String) async throws {
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        _ = try await send(path: "/api/service-requests/\(encodedID)/claim", method: "POST")
    }

    static func createCustomerPortalLink(
        customer: Customer,
        serviceCall: ServiceCall,
        invoice: Invoice?,
        balanceDue: Double?,
        expiresInDays: Int
    ) async throws -> BackendCustomerPortalLink {
        guard let email = customer.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else {
            throw GunnAireBackendError.server(statusCode: 400, message: "The customer needs an email address before creating a portal link.")
        }
        let invoiceReference = invoice.map { $0.quickBooksID?.isEmpty == false ? $0.quickBooksID! : String($0.id.uuidString.prefix(8)) }
        let payload = CustomerPortalLinkPayload(
            customerName: customer.name,
            customerEmail: email,
            serviceCallID: serviceCall.id.uuidString,
            invoiceID: invoice?.id.uuidString,
            title: invoice == nil ? "Your GunnAire service update" : "Your GunnAire appointment and invoice",
            appointmentSummary: serviceCall.customerAppointmentSummary,
            invoiceReference: invoiceReference,
            balanceDue: balanceDue,
            expiresInDays: expiresInDays
        )
        let data = try JSONEncoder().encode(payload)
        let responseData = try await send(path: "/api/customer-portal-links", method: "POST", body: data)
        return try JSONDecoder().decode(BackendCustomerPortalLink.self, from: responseData)
    }

    static func fetchCustomerPortalLinks() async throws -> [BackendCustomerPortalLinkRecord] {
        let data = try await send(path: "/api/customer-portal-links", method: "GET")
        return try JSONDecoder().decode(CustomerPortalLinksResponse.self, from: data).links
    }

    static func revokeCustomerPortalLink(id: String) async throws {
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        _ = try await send(path: "/api/customer-portal-links/\(encodedID)", method: "DELETE")
    }

    @MainActor
    static func importServiceRequests(
        into modelContext: ModelContext,
        currentRequests: [ServiceRequest]
    ) async throws -> Int {
        let remoteRequests = try await fetchServiceRequests()
        let knownIDs = Set(currentRequests.compactMap(\.backendRequestID))
        let formatter = ISO8601DateFormatter()
        var imported = 0
        for remote in remoteRequests where !knownIDs.contains(remote.id) {
            let type = ServiceCallType(rawValue: remote.requestedServiceType) ?? .service
            let urgency = ServiceRequestUrgency(rawValue: remote.urgency) ?? .normal
            let request = ServiceRequest(
                backendRequestID: remote.id,
                customerName: remote.customerName,
                phone: remote.phone,
                email: remote.email,
                address: remote.address,
                requestedServiceType: type,
                urgency: urgency,
                summary: remote.summary,
                preferredDate: remote.preferredDate.flatMap(formatter.date(from:)),
                createdByEmail: "online-booking",
                createdAt: formatter.date(from: remote.createdAt) ?? Date()
            )
            modelContext.insert(request)
            imported += 1
        }
        if imported > 0 { try? modelContext.save() }
        return imported
    }

    @discardableResult
    static func uploadCustomerCommunication(_ communication: CustomerCommunication) async throws -> BackendCustomerCommunicationRecord {
        let payload = CustomerCommunicationPayload(
            id: communication.id.uuidString,
            customerName: communication.customer.name,
            customerEmail: communication.customer.email,
            serviceCallID: communication.serviceCallID?.uuidString,
            invoiceID: communication.invoiceID?.uuidString,
            estimateID: communication.estimateID?.uuidString,
            channel: communication.channel,
            direction: communication.direction,
            recipient: communication.recipient,
            subject: communication.subject,
            deliveryStatus: communication.deliveryStatus,
            attachmentFileNames: communication.attachmentFileNames,
            providerMessageID: communication.providerMessageID,
            occurredAt: ISO8601DateFormatter().string(from: communication.createdAt)
        )
        let data = try JSONEncoder().encode(payload)
        let responseData = try await send(path: "/api/communications", method: "POST", body: data)
        return try JSONDecoder().decode(BackendCustomerCommunicationRecord.self, from: responseData)
    }

    static func decodeDocuments(from data: Data) throws -> [BackendDocumentRecord] {
        try JSONDecoder().decode(DocumentsResponse.self, from: data).documents
    }

    static func downloadDocument(id: String) async throws -> Data {
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try await send(path: "/api/documents/\(encodedID)/download", method: "GET")
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
        invoiceID: UUID? = nil,
        estimateID: UUID? = nil,
        customerEquipmentID: UUID? = nil,
        equipmentName: String? = nil,
        customerName: String?
    ) async throws -> BackendDocumentUploadResponse {
        let payload = DocumentUploadPayload(
            filename: filename,
            contentType: contentType,
            kind: kind,
            serviceCallID: serviceCallID?.uuidString,
            invoiceID: invoiceID?.uuidString,
            estimateID: estimateID?.uuidString,
            customerEquipmentID: customerEquipmentID?.uuidString,
            equipmentName: equipmentName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
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

    @discardableResult
    static func retrySharedCompanyDocumentUpload(_ attachment: ServiceDocumentAttachment) async throws -> BackendDocumentUploadResponse {
        let data = try Data(contentsOf: attachment.localFileURL)
        return try await uploadDocument(
            data: data,
            filename: attachment.displayName,
            contentType: attachment.contentType,
            kind: attachment.kindRaw,
            serviceCallID: attachment.serviceCallID,
            invoiceID: attachment.invoiceID,
            estimateID: attachment.estimateID,
            customerEquipmentID: attachment.customerEquipmentID,
            customerName: attachment.customer?.name
        )
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
        if Config.Backend.usesGoogleIDToken {
            guard let idToken = GoogleAuthManager.shared.idToken,
                  !idToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GunnAireBackendError.missingGoogleIdentityToken
            }
            request.setValue(idToken, forHTTPHeaderField: "X-GunnAire-Google-ID-Token")
        } else {
            request.setValue("Bearer \(Config.Backend.apiToken)", forHTTPHeaderField: "Authorization")
        }
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
