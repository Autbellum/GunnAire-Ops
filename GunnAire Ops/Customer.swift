// Customer.swift
// Model for customers, ready for SwiftData
import Foundation
import SwiftData

@Model
final class Customer {
    var id: UUID = UUID()
    var quickBooksID: String?
    var name: String = ""
    var phone: String?
    var email: String?
    var address: String?
    /// Transactional service, estimate, invoice, and appointment messages may be
    /// sent only while this preference is enabled. It defaults to true to preserve
    /// the existing customer relationship when an older local store is migrated.
    var allowsTransactionalEmail: Bool = true
    /// Captures the customer's preference before an SMS provider is enabled.
    /// The app does not send text messages until a consent-aware provider is added.
    var allowsServiceText: Bool = false
    /// Marketing is opt-in and intentionally kept separate from operational notices.
    var allowsMarketing: Bool = false
    var preferredContactMethodRaw: String = CustomerContactMethod.email.rawValue
    var communicationConsentUpdatedAt: Date?
    // CloudKit can deliver a parent and its related records separately. Keep
    // storage optional while exposing stable, empty-by-default collections to
    // the rest of the field-service UI.
    @Relationship(originalName: "recurringContracts", inverse: \RecurringMaintenanceContract.customer) private var storedRecurringContracts: [RecurringMaintenanceContract]?
    @Relationship(originalName: "serviceCalls", inverse: \ServiceCall.customer) private var storedServiceCalls: [ServiceCall]?
    @Relationship(originalName: "invoices", inverse: \Invoice.customer) private var storedInvoices: [Invoice]?
    @Relationship(originalName: "estimates", inverse: \Estimate.customer) private var storedEstimates: [Estimate]?
    @Relationship(originalName: "communications", inverse: \CustomerCommunication.customer) private var storedCommunications: [CustomerCommunication]?
    @Relationship(originalName: "documentAttachments", inverse: \ServiceDocumentAttachment.customer) private var storedDocumentAttachments: [ServiceDocumentAttachment]?
    @Relationship(originalName: "equipmentProfiles", inverse: \CustomerEquipment.customer) private var storedEquipmentProfiles: [CustomerEquipment]?
    
    init(
        id: UUID = UUID(),
        quickBooksID: String? = nil,
        name: String,
        phone: String? = nil,
        email: String? = nil,
        address: String? = nil,
        allowsTransactionalEmail: Bool = true,
        allowsServiceText: Bool = false,
        allowsMarketing: Bool = false,
        preferredContactMethod: CustomerContactMethod = .email,
        communicationConsentUpdatedAt: Date? = nil
    ) {
        self.id = id
        self.quickBooksID = quickBooksID
        self.name = name
        self.phone = phone
        self.email = email
        self.address = address
        self.allowsTransactionalEmail = allowsTransactionalEmail
        self.allowsServiceText = allowsServiceText
        self.allowsMarketing = allowsMarketing
        self.preferredContactMethodRaw = preferredContactMethod.rawValue
        self.communicationConsentUpdatedAt = communicationConsentUpdatedAt
    }
}

extension Customer {
    var recurringContracts: [RecurringMaintenanceContract] {
        get { storedRecurringContracts ?? [] }
        set { storedRecurringContracts = newValue }
    }

    var serviceCalls: [ServiceCall] {
        get { storedServiceCalls ?? [] }
        set { storedServiceCalls = newValue }
    }

    var invoices: [Invoice] {
        get { storedInvoices ?? [] }
        set { storedInvoices = newValue }
    }

    var estimates: [Estimate] {
        get { storedEstimates ?? [] }
        set { storedEstimates = newValue }
    }

    var communications: [CustomerCommunication] {
        get { storedCommunications ?? [] }
        set { storedCommunications = newValue }
    }

    var documentAttachments: [ServiceDocumentAttachment] {
        get { storedDocumentAttachments ?? [] }
        set { storedDocumentAttachments = newValue }
    }

    var equipmentProfiles: [CustomerEquipment] {
        get { storedEquipmentProfiles ?? [] }
        set { storedEquipmentProfiles = newValue }
    }

    var activeContractsCount: Int {
        recurringContracts.filter(\.active).count
    }

    var preferredContactMethod: CustomerContactMethod {
        get { CustomerContactMethod(rawValue: preferredContactMethodRaw) ?? .email }
        set { preferredContactMethodRaw = newValue.rawValue }
    }
}

enum CustomerContactMethod: String, CaseIterable, Identifiable {
    case email
    case text
    case phone

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .email: "Email"
        case .text: "Text message"
        case .phone: "Phone call"
        }
    }
}
