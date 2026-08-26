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
    var channel: String = "email"
    var direction: String = "outbound"
    var recipient: String = ""
    var subject: String = ""
    var deliveryStatus: String = "pending"
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
        channel: String = "email",
        direction: String = "outbound",
        recipient: String,
        subject: String,
        deliveryStatus: String,
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
        self.channel = channel
        self.direction = direction
        self.recipient = recipient
        self.subject = subject
        self.deliveryStatus = deliveryStatus
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
}
