import Foundation
import SwiftData

/// Durable record of a customer-facing transactional message. Content is kept as a
/// short audit summary; full message bodies and mailbox data remain in Gmail.
@Model
final class CustomerCommunication {
    var id: UUID = UUID()
    var customer: Customer!
    var serviceCallID: UUID?
    var invoiceID: UUID?
    var estimateID: UUID?
    var maintenanceContractID: UUID?
    var channel: String = "email"
    var direction: String = "outbound"
    var recipient: String = ""
    var subject: String = ""
    var deliveryStatus: String = "pending"
    var workflowRawValue: String = GunnAireMailWorkflow.general.rawValue
    var templateVersion: String = GunnAireMailWorkflow.general.templateVersion
    var actorEmail: String?
    var consentSnapshotJSON: String?
    var providerStatusDetail: String?
    var deliveredAt: Date?
    var attachmentFileNamesJSON: String?
    var providerMessageID: String?
    var backendCommunicationID: String?
    var backendSyncError: String?
    var createdAt: Date = Date()

    init(
        id: UUID = UUID(),
        customer: Customer,
        serviceCallID: UUID? = nil,
        invoiceID: UUID? = nil,
        estimateID: UUID? = nil,
        maintenanceContractID: UUID? = nil,
        channel: String = "email",
        direction: String = "outbound",
        recipient: String,
        subject: String,
        deliveryStatus: String,
        workflow: GunnAireMailWorkflow = .general,
        templateVersion: String? = nil,
        actorEmail: String? = nil,
        consentSnapshot: CustomerCommunicationConsentSnapshot? = nil,
        providerStatusDetail: String? = nil,
        deliveredAt: Date? = nil,
        attachmentFileNames: [String] = [],
        providerMessageID: String? = nil,
        backendCommunicationID: String? = nil,
        backendSyncError: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.customer = customer
        self.serviceCallID = serviceCallID
        self.invoiceID = invoiceID
        self.estimateID = estimateID
        self.maintenanceContractID = maintenanceContractID
        self.channel = channel
        self.direction = direction
        self.recipient = recipient
        self.subject = subject
        self.deliveryStatus = deliveryStatus
        self.workflowRawValue = workflow.rawValue
        self.templateVersion = templateVersion ?? workflow.templateVersion
        self.actorEmail = Self.normalizedOptional(actorEmail)
        self.consentSnapshotJSON = Self.encodeConsentSnapshot(consentSnapshot)
        self.providerStatusDetail = Self.safeProviderStatusDetail(providerStatusDetail)
        self.deliveredAt = deliveredAt ?? (deliveryStatus == "sent" ? createdAt : nil)
        self.attachmentFileNamesJSON = try? String(data: JSONEncoder().encode(attachmentFileNames), encoding: .utf8)
        self.providerMessageID = providerMessageID
        self.backendCommunicationID = backendCommunicationID
        self.backendSyncError = backendSyncError
        self.createdAt = createdAt
    }

    var attachmentFileNames: [String] {
        guard let attachmentFileNamesJSON,
              let data = attachmentFileNamesJSON.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return names
    }

    var workflow: GunnAireMailWorkflow {
        GunnAireMailWorkflow(rawValue: workflowRawValue) ?? .general
    }

    var consentSnapshot: CustomerCommunicationConsentSnapshot? {
        guard let consentSnapshotJSON,
              let data = consentSnapshotJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CustomerCommunicationConsentSnapshot.self, from: data)
    }

    var needsSharedCompanySync: Bool {
        backendCommunicationID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }

    var normalizedDeliveryStatus: String {
        deliveryStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func markSharedCompanySynced(id: String) {
        backendCommunicationID = id
        backendSyncError = nil
    }

    func markSharedCompanySyncFailed(_ detail: String) {
        backendSyncError = Self.safeProviderStatusDetail(detail) ?? "Company history sync failed."
    }

    static func hasConfirmedDelivery(
        workflow: GunnAireMailWorkflow,
        serviceCallID: UUID? = nil,
        maintenanceContractID: UUID? = nil,
        in communications: [CustomerCommunication]
    ) -> Bool {
        communications.contains { communication in
            communication.workflow == workflow &&
            communication.normalizedDeliveryStatus == "sent" &&
            communication.serviceCallID == serviceCallID &&
            communication.maintenanceContractID == maintenanceContractID
        }
    }

    private static func encodeConsentSnapshot(_ snapshot: CustomerCommunicationConsentSnapshot?) -> String? {
        guard let snapshot,
              let data = try? JSONEncoder().encode(snapshot) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    static func safeProviderStatusDetail(_ value: String?) -> String? {
        let normalized = value?
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(400))
    }
}

nonisolated struct CustomerCommunicationConsentSnapshot: Codable, Equatable, Sendable {
    let allowsTransactionalEmail: Bool
    let allowsServiceText: Bool
    let allowsMarketing: Bool
    let preferredContactMethod: String
    let consentUpdatedAt: Date?

    @MainActor
    init(customer: Customer) {
        allowsTransactionalEmail = customer.allowsTransactionalEmail
        allowsServiceText = customer.allowsServiceText
        allowsMarketing = customer.allowsMarketing
        preferredContactMethod = customer.preferredContactMethod.rawValue
        consentUpdatedAt = customer.communicationConsentUpdatedAt
    }
}
