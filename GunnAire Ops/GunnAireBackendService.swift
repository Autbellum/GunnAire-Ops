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

struct BackendApplicationSessionResponse: Codable {
    let sessionToken: String
    let expiresAt: String
    let providerSubject: String
    let user: BackendAppUserRecord
}

typealias BackendAppleSessionResponse = BackendApplicationSessionResponse

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
    let maintenanceContractID: String?
    let customerEquipmentID: String?
    let equipmentName: String?
    let customerName: String?
    let storedPath: String?
    let createdAt: String?

    init(
        id: String,
        filename: String,
        contentType: String,
        kind: String,
        serviceCallID: String?,
        invoiceID: String?,
        estimateID: String?,
        maintenanceContractID: String? = nil,
        customerEquipmentID: String?,
        equipmentName: String?,
        customerName: String?,
        storedPath: String?,
        createdAt: String?
    ) {
        self.id = id
        self.filename = filename
        self.contentType = contentType
        self.kind = kind
        self.serviceCallID = serviceCallID
        self.invoiceID = invoiceID
        self.estimateID = estimateID
        self.maintenanceContractID = maintenanceContractID
        self.customerEquipmentID = customerEquipmentID
        self.equipmentName = equipmentName
        self.customerName = customerName
        self.storedPath = storedPath
        self.createdAt = createdAt
    }

    var serviceCallUUID: UUID? {
        serviceCallID.flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    var invoiceUUID: UUID? {
        invoiceID.flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    var estimateUUID: UUID? {
        estimateID.flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    var maintenanceContractUUID: UUID? {
        maintenanceContractID.flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
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
    let assignmentUpdates: [BackendFieldPaymentAssignmentUpdate]?
}

struct BackendFieldPaymentAssignmentUpdate: Codable {
    let id: String
    let status: String
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
    let collectedAmount: Double?
    let completedAt: String?
    let completedBy: String?
    let completionPaymentID: String?

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
    static let announcedIDsDefaultsKey = "GunnAireAnnouncedFieldPaymentAssignmentIDs"

    static func nextUnannouncedPendingAssignment(
        from assignments: [BackendFieldPaymentAssignmentRecord],
        announcedIDs: Set<String>
    ) -> BackendFieldPaymentAssignmentRecord? {
        assignments
            .filter { $0.status == "pending" && !announcedIDs.contains($0.id) }
            .min { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.id < rhs.id
            }
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

enum FieldCollectionInvoiceRouteDecision: Equatable {
    case waitingForAuthorizedInvoice
    case waitingForAuthoritativeTotal(String)
    case collect
    case alreadySettled
}

/// Keeps a backend assignment route durable while CloudKit finishes delivering
/// the authorized operational graph. A missing invoice is never treated as
/// authorization; the route opens only after the ordinary field-visibility
/// filter supplies the invoice locally.
enum FieldCollectionInvoiceRouteResolver {
    static func decision(
        invoiceID: UUID,
        visibleInvoices: [Invoice],
        payments: [Payment]
    ) -> FieldCollectionInvoiceRouteDecision {
        guard let invoice = visibleInvoices.first(where: { $0.id == invoiceID }) else {
            return .waitingForAuthorizedInvoice
        }
        if let blockedMessage = invoice.paymentCollectionBlockedMessage {
            return .waitingForAuthoritativeTotal(blockedMessage)
        }
        return Invoice.outstandingBalance(for: invoice, payments: payments) > 0.005
            ? .collect
            : .alreadySettled
    }
}

struct BackendCustomerCommunicationRecord: Codable, Identifiable {
    let id: String
    let customerName: String
    let customerEmail: String?
    let serviceCallID: String?
    let invoiceID: String?
    let estimateID: String?
    let maintenanceContractID: String?
    let channel: String
    let direction: String
    let recipient: String
    let subject: String
    let deliveryStatus: String
    let workflow: String?
    let templateVersion: String?
    let actorEmail: String?
    let consentSnapshot: CustomerCommunicationConsentSnapshot?
    let providerStatusDetail: String?
    let deliveredAt: String?
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
    let source: String?
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

struct BackendStaffPushDeviceRecord: Codable, Equatable {
    let installationID: String
    let platform: String
    let environment: String
    let bundleID: String
    let appVersion: String?
    let appBuild: String?
    let registeredAt: String
    let updatedAt: String
    let isActive: Bool
}

struct BackendStaffPushRegistrationResponse: Codable, Equatable {
    let registered: Bool
    let device: BackendStaffPushDeviceRecord?
}

struct BackendStaffPushDeactivationResponse: Codable, Equatable {
    let installationID: String
    let deactivated: Bool
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
    let estimateID: String?
    let estimateLabel: String?
    let estimateAmount: Double?
    let estimateRevision: String?
    let estimateResponseID: String?
    let estimateResponseName: String?
    let estimateRespondedAt: String?
    let estimateResolutionStatus: String?
    let estimateResolutionDetail: String?
    let estimateResolvedAt: String?
    let estimateResolvedBy: String?
    let expiresAt: String
    let revokedAt: String?
    let openedCount: Int?
    let lastOpenedAt: String?
    let createdAt: String
    let createdBy: String
}

enum GunnAireBackendError: LocalizedError {
    case notConfigured
    case invalidURL(String)
    case invalidResponse
    case server(statusCode: Int, message: String)
    case missingBusinessIdentity
    case invalidPaymentMethod(String)

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
        case .missingBusinessIdentity:
            return "Sign in with Apple or Google again before accessing the shared business server."
        case .invalidPaymentMethod(let method):
            return "The payment method \(method) cannot be uploaded to the shared company queue."
        }
    }
}

enum GunnAireBackendService {
    private struct AppleIdentityPayload: Codable {
        let identityToken: String
        let nonce: String
    }
    private struct GoogleIdentityPayload: Codable {
        let identityToken: String
    }
    private struct StaffPushDevicePayload: Codable {
        let installationID: String
        let deviceToken: String
        let platform: String
        let environment: String
        let bundleID: String
        let appVersion: String
        let appBuild: String
    }
    private struct QuickBooksCodePayload: Codable {
        let code: String
        let realmID: String
        let environment: String
    }
    private struct QuickBooksRefreshPayload: Codable {
        let realmID: String
        let environment: String
    }
    private struct QuickBooksAccountingConfigurationPayload: Codable {
        let defaultSalesItemRef: String
        let defaultSalesItemName: String
        let defaultSalesItemType: String
        let defaultIncomeAccountRef: String
        let defaultIncomeAccountName: String
        let defaultIncomeAccountType: String
        let defaultExpenseAccountRef: String
        let defaultExpenseAccountName: String
        let defaultExpenseAccountType: String
        let defaultAPAccountRef: String
        let defaultAPAccountName: String
        let defaultAPAccountType: String
        let defaultBankAccountRef: String
        let defaultBankAccountName: String
        let defaultBankAccountType: String
        let defaultCreditCardAccountRef: String
        let defaultCreditCardAccountName: String
        let defaultCreditCardAccountType: String
    }
    private struct QuickBooksAccountingConfigurationResponse: Codable {
        let realmID: String
        let environment: String
        let configuration: BackendQuickBooksAccountingConfiguration?
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

    private struct SupplierConnectorsResponse: Codable {
        let connectors: [SupplierConnectorReadiness]
    }

    private struct SupplierOrderPayload: Codable {
        struct Line: Codable {
            let lineID: String
            let itemName: String
            let internalSKU: String?
            let supplierPartNumber: String?
            let quantity: Double
            let expectedUnitCost: Double
        }

        let contractVersion: Int
        let connectorKind: SupplierConnectorKind
        let purchaseOrderID: String
        let purchaseOrderNumber: String
        let serviceCallID: String?
        let vendorName: String
        let lines: [Line]
        let expectedShippingCost: Double
        let currencyCode: String
        let supplierLocation: String?
        let priceAvailabilityCheckedAt: String?
        let orderNotes: String?
    }

    private struct SupplierOrderAcceptanceWire: Codable {
        struct ConfirmedLine: Codable {
            let lineID: String
            let supplierPartNumber: String?
            let confirmedQuantity: Double
            let confirmedUnitCost: Double
        }

        let contractVersion: Int
        let purchaseOrderID: String
        let purchaseOrderNumber: String
        let connectorKind: SupplierConnectorKind
        let externalOrderID: String
        let reference: String
        let supplierLocation: String?
        let confirmedLines: [ConfirmedLine]
        let confirmedShippingCost: Double
        let currencyCode: String
        let confirmedByEmail: String
        let confirmedAt: String
        let priceAvailabilityCheckedAt: String
        let idempotencyKey: String
        let replayed: Bool
    }

    private struct SupplierOrderResponse: Codable {
        let acceptance: SupplierOrderAcceptanceWire
    }

    private struct ServerErrorResponse: Codable {
        let error: String
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
        let maintenanceContractID: String?
        let channel: String
        let direction: String
        let recipient: String
        let subject: String
        let deliveryStatus: String
        let workflow: String
        let templateVersion: String
        let consentSnapshot: CustomerCommunicationConsentSnapshot?
        let providerStatusDetail: String?
        let deliveredAt: String?
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
        let maintenanceContractID: String?
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
        let estimateID: String?
        let estimateLabel: String?
        let estimateAmount: Double?
        let estimateRevision: String?
        let expiresInDays: Int
    }

    private struct CustomerPortalEstimateResolutionPayload: Codable {
        let responseID: String
        let status: String
        let detail: String?
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

    static func fetchQuickBooksAccountingConfiguration() async throws -> BackendQuickBooksAccountingConfiguration? {
        let data = try await send(path: "/api/qbo/accounting-config", method: "GET")
        return try JSONDecoder().decode(
            QuickBooksAccountingConfigurationResponse.self,
            from: data
        ).configuration
    }

    static func updateQuickBooksAccountingConfiguration(
        _ configuration: BackendQuickBooksAccountingConfiguration
    ) async throws -> BackendQuickBooksAccountingConfiguration {
        let payload = QuickBooksAccountingConfigurationPayload(
            defaultSalesItemRef: configuration.defaultSalesItemRef,
            defaultSalesItemName: configuration.defaultSalesItemName,
            defaultSalesItemType: configuration.defaultSalesItemType,
            defaultIncomeAccountRef: configuration.defaultIncomeAccountRef,
            defaultIncomeAccountName: configuration.defaultIncomeAccountName,
            defaultIncomeAccountType: configuration.defaultIncomeAccountType,
            defaultExpenseAccountRef: configuration.defaultExpenseAccountRef,
            defaultExpenseAccountName: configuration.defaultExpenseAccountName,
            defaultExpenseAccountType: configuration.defaultExpenseAccountType,
            defaultAPAccountRef: configuration.defaultAPAccountRef,
            defaultAPAccountName: configuration.defaultAPAccountName,
            defaultAPAccountType: configuration.defaultAPAccountType,
            defaultBankAccountRef: configuration.defaultBankAccountRef,
            defaultBankAccountName: configuration.defaultBankAccountName,
            defaultBankAccountType: configuration.defaultBankAccountType,
            defaultCreditCardAccountRef: configuration.defaultCreditCardAccountRef,
            defaultCreditCardAccountName: configuration.defaultCreditCardAccountName,
            defaultCreditCardAccountType: configuration.defaultCreditCardAccountType
        )
        let body = try JSONEncoder().encode(payload)
        let data = try await send(path: "/api/qbo/accounting-config", method: "POST", body: body)
        let response = try JSONDecoder().decode(QuickBooksAccountingConfigurationResponse.self, from: data)
        guard let saved = response.configuration else {
            throw GunnAireBackendError.invalidResponse
        }
        return saved
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

    static func fetchCompanyWorkspace() async throws -> BackendCompanyWorkspaceResponse {
        let data = try await send(path: "/api/workspace", method: "GET")
        return try JSONDecoder().decode(BackendCompanyWorkspaceResponse.self, from: data)
    }

    /// Call only from explicit administrator onboarding, never as a side effect
    /// of login or record discovery. The server rechecks recent authentication
    /// and makes the first binding immutable. Existing data must be reviewed
    /// before the UI passes ownership confirmation.
    static func approveCompanyCloudKitWorkspace(
        _ approval: CompanyCloudKitApprovalRequest
    ) async throws -> CompanyCloudKitBinding {
        let body = try JSONEncoder().encode(approval)
        let data = try await send(path: "/api/workspace/bind", method: "POST", body: body)
        let result = try JSONDecoder().decode(BackendCompanyCloudKitApprovalResponse.self, from: data).binding
        guard result.isValid,
              result.companyID.uuidString.lowercased() == approval.expectedCompanyID,
              result.containerID == approval.containerID,
              result.environment == approval.environment,
              result.cloudAccountHash == approval.cloudAccountHash else {
            throw GunnAireBackendError.invalidResponse
        }
        return result
    }

    static func exchangeAppleIdentity(
        identityToken: String,
        nonce: String
    ) async throws -> BackendApplicationSessionResponse {
        let payload = AppleIdentityPayload(identityToken: identityToken, nonce: nonce)
        let body = try JSONEncoder().encode(payload)
        let data = try await sendUnauthenticated(path: "/api/auth/apple", method: "POST", body: body)
        return try JSONDecoder().decode(BackendApplicationSessionResponse.self, from: data)
    }

    static func exchangeGoogleIdentity(
        identityToken: String
    ) async throws -> BackendApplicationSessionResponse {
        let payload = GoogleIdentityPayload(identityToken: identityToken)
        let body = try JSONEncoder().encode(payload)
        let data = try await sendUnauthenticated(path: "/api/auth/google", method: "POST", body: body)
        return try JSONDecoder().decode(BackendApplicationSessionResponse.self, from: data)
    }

    static func revokeApplicationSession(_ token: String) async throws {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        _ = try await sendWithBearerToken(
            path: "/api/auth/logout",
            method: "POST",
            token: token
        )
    }

    static func registerStaffPushDevice(
        installationID: UUID,
        deviceToken: String,
        platform: String,
        environment: String,
        bundleID: String,
        appVersion: String,
        appBuild: String
    ) async throws -> BackendStaffPushRegistrationResponse {
        let payload = StaffPushDevicePayload(
            installationID: installationID.uuidString,
            deviceToken: deviceToken,
            platform: platform,
            environment: environment,
            bundleID: bundleID,
            appVersion: appVersion,
            appBuild: appBuild
        )
        let body = try JSONEncoder().encode(payload)
        let data = try await send(path: "/api/push-devices", method: "POST", body: body)
        return try JSONDecoder().decode(BackendStaffPushRegistrationResponse.self, from: data)
    }

    static func fetchCurrentStaffPushDevice(
        installationID: UUID
    ) async throws -> BackendStaffPushRegistrationResponse {
        let encodedID = installationID.uuidString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            ?? installationID.uuidString
        let data = try await send(
            path: "/api/push-devices/current?installationID=\(encodedID)",
            method: "GET"
        )
        return try JSONDecoder().decode(BackendStaffPushRegistrationResponse.self, from: data)
    }

    static func deactivateStaffPushDevice(installationID: UUID) async throws -> Bool {
        let encodedID = installationID.uuidString.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? installationID.uuidString
        let data = try await send(path: "/api/push-devices/\(encodedID)", method: "DELETE")
        return try JSONDecoder().decode(BackendStaffPushDeactivationResponse.self, from: data).deactivated
    }

    static func deactivateStaffPushDevice(
        installationID: UUID,
        applicationSessionToken: String
    ) async throws -> Bool {
        let encodedID = installationID.uuidString.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? installationID.uuidString
        let data = try await sendWithBearerToken(
            path: "/api/push-devices/\(encodedID)",
            method: "DELETE",
            token: applicationSessionToken
        )
        return try JSONDecoder().decode(BackendStaffPushDeactivationResponse.self, from: data).deactivated
    }

    @discardableResult
    @MainActor
    static func applyVerifiedUser(
        _ remoteUser: BackendAppUserRecord,
        into modelContext: ModelContext,
        currentUsers: [AppUser],
        technicians: [Technician]
    ) -> [AppUser] {
        let email = AppAccess.normalizedEmail(remoteUser.email)
        guard !email.isEmpty else { return currentUsers }
        let role = AppUserRole.allCases.first {
            $0.rawValue.caseInsensitiveCompare(remoteUser.role) == .orderedSame
        } ?? .standard
        let matches = currentUsers.filter { AppAccess.normalizedEmail($0.email) == email }
        let user = matches.first ?? AppUser(email: email, role: role, isActive: remoteUser.isActive)
        if matches.isEmpty {
            modelContext.insert(user)
        }
        for match in matches.isEmpty ? [user] : matches {
            match.email = email
            match.role = role
            match.isActive = remoteUser.isActive
        }
        if remoteUser.isActive {
            _ = AppAccess.ensureTechnicianRecord(for: email, technicians: technicians, modelContext: modelContext)
        }
        try? modelContext.save()
        _ = AppUserDataMaintenance.collapseCloudKitDuplicates(
            matches.isEmpty ? currentUsers + [user] : currentUsers,
            modelContext: modelContext
        )
        let descriptor = FetchDescriptor<AppUser>(sortBy: [SortDescriptor(\AppUser.email)])
        return (try? modelContext.fetch(descriptor)) ?? currentUsers
    }

    @discardableResult
    @MainActor
    static func refreshCurrentUser(
        into modelContext: ModelContext,
        currentUsers: [AppUser],
        technicians: [Technician]
    ) async throws -> [AppUser] {
        let remoteUser = try await fetchCurrentUser()
        return applyVerifiedUser(
            remoteUser,
            into: modelContext,
            currentUsers: currentUsers,
            technicians: technicians
        )
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

    static func fetchCustomerFinancingReadiness() async throws -> CustomerFinancingReadiness {
        let data = try await send(path: "/api/customer-financing", method: "GET")
        return try decodeCustomerFinancingReadiness(from: data)
    }

    static func decodeCustomerFinancingReadiness(from data: Data) throws -> CustomerFinancingReadiness {
        try JSONDecoder().decode(CustomerFinancingReadiness.self, from: data)
    }

    static func fetchSupplierConnectors() async throws -> [SupplierConnectorReadiness] {
        let data = try await send(path: "/api/supplier-connectors", method: "GET")
        return try JSONDecoder().decode(SupplierConnectorsResponse.self, from: data).connectors
    }

    static func decodeSupplierConnectors(from data: Data) throws -> [SupplierConnectorReadiness] {
        try JSONDecoder().decode(SupplierConnectorsResponse.self, from: data).connectors
    }

    static func submitSupplierOrder(
        _ order: PurchaseOrder,
        connectorKind: SupplierConnectorKind,
        supplierLocation: String?
    ) async throws -> SupplierConnectorOrderAcceptance {
        let payload = SupplierOrderPayload(
            contractVersion: SupplierConnectorContract.currentVersion,
            connectorKind: connectorKind,
            purchaseOrderID: order.id.uuidString.lowercased(),
            purchaseOrderNumber: order.number,
            serviceCallID: order.serviceCallID?.uuidString.lowercased(),
            vendorName: order.vendorName,
            lines: order.purchaseOrderLines.map { line in
                SupplierOrderPayload.Line(
                    lineID: line.id.uuidString.lowercased(),
                    itemName: line.itemName,
                    internalSKU: line.itemSKU?.nilIfBlank,
                    supplierPartNumber: line.vendorPartNumber?.nilIfBlank,
                    quantity: line.quantity,
                    expectedUnitCost: line.unitCost
                )
            },
            expectedShippingCost: order.shippingCost,
            currencyCode: "USD",
            supplierLocation: supplierLocation?.nilIfBlank,
            priceAvailabilityCheckedAt: nil,
            orderNotes: order.userNotes
        )
        let body = try JSONEncoder().encode(payload)
        let idempotencyKey = "po:\(order.id.uuidString.lowercased()):\(Int(order.updatedAt.timeIntervalSince1970 * 1_000))"
        let data = try await send(
            path: "/api/supplier-connectors/orders",
            method: "POST",
            body: body,
            headers: ["Idempotency-Key": idempotencyKey]
        )
        let wire = try JSONDecoder().decode(SupplierOrderResponse.self, from: data).acceptance
        guard let purchaseOrderID = UUID(uuidString: wire.purchaseOrderID),
              let confirmedAt = supplierConnectorDate(from: wire.confirmedAt),
              let priceAvailabilityCheckedAt = supplierConnectorDate(from: wire.priceAvailabilityCheckedAt),
              wire.confirmedLines.allSatisfy({ UUID(uuidString: $0.lineID) != nil }) else {
            throw GunnAireBackendError.invalidResponse
        }
        return SupplierConnectorOrderAcceptance(
            contractVersion: wire.contractVersion,
            purchaseOrderID: purchaseOrderID,
            purchaseOrderNumber: wire.purchaseOrderNumber,
            connectorKind: wire.connectorKind,
            externalOrderID: wire.externalOrderID,
            reference: wire.reference,
            supplierLocation: wire.supplierLocation,
            confirmedLines: wire.confirmedLines.compactMap { line in
                guard let lineID = UUID(uuidString: line.lineID) else { return nil }
                return SupplierConnectorAcceptedLine(
                    lineID: lineID,
                    supplierPartNumber: line.supplierPartNumber,
                    confirmedQuantity: line.confirmedQuantity,
                    confirmedUnitCost: line.confirmedUnitCost
                )
            },
            confirmedShippingCost: wire.confirmedShippingCost,
            currencyCode: wire.currencyCode,
            confirmedByEmail: wire.confirmedByEmail,
            confirmedAt: confirmedAt,
            priceAvailabilityCheckedAt: priceAvailabilityCheckedAt,
            idempotencyKey: wire.idempotencyKey,
            replayed: wire.replayed
        )
    }

    private static func supplierConnectorDate(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
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
        estimate: Estimate? = nil,
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
            title: estimate != nil
                ? "Your GunnAire estimate and service update"
                : (invoice == nil ? "Your GunnAire service update" : "Your GunnAire appointment and invoice"),
            appointmentSummary: serviceCall.customerAppointmentSummary,
            invoiceReference: invoiceReference,
            balanceDue: balanceDue,
            estimateID: estimate?.id.uuidString,
            estimateLabel: estimate?.proposalLabel,
            estimateAmount: estimate?.amount,
            estimateRevision: estimate?.customerPortalRevision,
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

    static func resolveCustomerPortalEstimateResponse(
        linkID: String,
        responseID: String,
        status: String,
        detail: String? = nil
    ) async throws -> BackendCustomerPortalLinkRecord {
        let encodedID = linkID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? linkID
        let payload = CustomerPortalEstimateResolutionPayload(
            responseID: responseID,
            status: status,
            detail: detail
        )
        let data = try JSONEncoder().encode(payload)
        let responseData = try await send(
            path: "/api/customer-portal-links/\(encodedID)/estimate-response-resolution",
            method: "POST",
            body: data
        )
        return try JSONDecoder().decode(BackendCustomerPortalLinkRecord.self, from: responseData)
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
            let source = remote.source.flatMap(ServiceRequestSource.init(rawValue:)) ?? .website
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
                source: source,
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
            maintenanceContractID: communication.maintenanceContractID?.uuidString,
            channel: communication.channel,
            direction: communication.direction,
            recipient: communication.recipient,
            subject: communication.subject,
            deliveryStatus: communication.deliveryStatus,
            workflow: communication.workflow.rawValue,
            templateVersion: communication.templateVersion,
            consentSnapshot: communication.consentSnapshot,
            providerStatusDetail: communication.providerStatusDetail,
            deliveredAt: communication.deliveredAt.map { ISO8601DateFormatter().string(from: $0) },
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
        maintenanceContractID: UUID? = nil,
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
            maintenanceContractID: maintenanceContractID?.uuidString,
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
    static func uploadPaymentCollection(_ payment: Payment) async throws -> BackendPaymentUploadResponse {
        guard let method = payment.backendCollectionMethod else {
            throw GunnAireBackendError.invalidPaymentMethod(payment.method)
        }
        let payload = PaymentCollectionPayload(
            paymentID: payment.id.uuidString,
            invoiceID: payment.invoice.id.uuidString,
            invoiceQuickBooksID: payment.invoice.quickBooksID,
            customerName: payment.invoice.customer.name,
            customerEmail: payment.invoice.customer.email,
            amount: payment.amount,
            method: method,
            cardLast4: payment.cardLast4,
            authorizationReference: payment.authorizationReference,
            processor: payment.processor,
            notes: payment.notes,
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
            maintenanceContractID: attachment.maintenanceContractID,
            customerEquipmentID: attachment.customerEquipmentID,
            customerName: attachment.customer?.name
        )
    }

    private static func send(
        path: String,
        method: String,
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> Data {
        let request = try makeRequest(path: path, method: method, body: body, headers: headers)
        return try await perform(request)
    }

    private static func sendUnauthenticated(path: String, method: String, body: Data?) async throws -> Data {
        let request = try baseRequest(path: path, method: method, body: body)
        return try await perform(request)
    }

    private static func sendWithBearerToken(
        path: String,
        method: String,
        token: String
    ) async throws -> Data {
        var request = try baseRequest(path: path, method: method, body: nil)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await perform(request)
    }

    private static func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GunnAireBackendError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(ServerErrorResponse.self, from: data).error)
                ?? String(data: data, encoding: .utf8)
                ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw GunnAireBackendError.server(statusCode: httpResponse.statusCode, message: message)
        }
        return data
    }

    private static func makeRequest(
        path: String,
        method: String,
        body: Data?,
        headers: [String: String] = [:]
    ) throws -> URLRequest {
        var request = try baseRequest(path: path, method: method, body: body)
        if Config.Backend.usesBusinessIdentity {
            if let sessionToken = AppleAuthManager.shared.sessionToken,
               !sessionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
            } else if let sessionToken = GoogleAuthManager.shared.applicationSessionToken,
                      !sessionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
            } else if let idToken = GoogleAuthManager.shared.idToken,
                      !idToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                request.setValue(idToken, forHTTPHeaderField: "X-GunnAire-Google-ID-Token")
            } else {
                throw GunnAireBackendError.missingBusinessIdentity
            }
        } else {
            request.setValue("Bearer \(Config.Backend.apiToken)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private static func baseRequest(path: String, method: String, body: Data?) throws -> URLRequest {
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
