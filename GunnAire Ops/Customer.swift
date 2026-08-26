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
    /// JSON-encoded, non-sensitive processor references. Full card numbers,
    /// CVC values, and one-time card tokens are never stored in SwiftData.
    var storedPaymentMethodsJSON: String?
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
        communicationConsentUpdatedAt: Date? = nil,
        storedPaymentMethods: [StoredPaymentMethodReference] = []
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
        self.storedPaymentMethodsJSON = Self.encodeStoredPaymentMethods(storedPaymentMethods)
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

    var storedPaymentMethods: [StoredPaymentMethodReference] {
        guard let storedPaymentMethodsJSON,
              let data = storedPaymentMethodsJSON.data(using: .utf8),
              let methods = try? JSONDecoder().decode([StoredPaymentMethodReference].self, from: data) else {
            return []
        }
        return methods.sorted { lhs, rhs in
            if lhs.active != rhs.active { return lhs.active && !rhs.active }
            return lhs.displayLabel.localizedCaseInsensitiveCompare(rhs.displayLabel) == .orderedAscending
        }
    }

    var activeStoredPaymentMethods: [StoredPaymentMethodReference] {
        storedPaymentMethods.filter(\.active)
    }

    func upsertStoredPaymentMethod(_ method: StoredPaymentMethodReference) {
        guard !method.id.isEmpty, !method.provider.isEmpty, !method.providerCustomerID.isEmpty else { return }
        var methods = storedPaymentMethods
        if let index = methods.firstIndex(where: { $0.id == method.id && $0.provider == method.provider }) {
            methods[index] = method
        } else {
            methods.append(method)
        }
        storedPaymentMethodsJSON = Self.encodeStoredPaymentMethods(methods)
    }

    func reconcileQuickBooksStoredPaymentMethods(
        _ currentMethods: [StoredPaymentMethodReference],
        providerCustomerID: String,
        reconciledAt: Date = Date()
    ) {
        let currentIDs = Set(currentMethods.map(\.id))
        var methods = storedPaymentMethods.map { method in
            guard method.provider == StoredPaymentMethodReference.quickBooksPaymentsProvider,
                  method.providerCustomerID == providerCustomerID,
                  !currentIDs.contains(method.id) else { return method }
            var inactive = method
            inactive.active = false
            inactive.updatedAt = reconciledAt
            return inactive
        }
        for method in currentMethods {
            if let index = methods.firstIndex(where: { $0.id == method.id && $0.provider == method.provider }) {
                methods[index] = method
            } else {
                methods.append(method)
            }
        }
        storedPaymentMethodsJSON = Self.encodeStoredPaymentMethods(methods)
    }

    var preferredContactMethod: CustomerContactMethod {
        get { CustomerContactMethod(rawValue: preferredContactMethodRaw) ?? .email }
        set { preferredContactMethodRaw = newValue.rawValue }
    }

    private static func encodeStoredPaymentMethods(_ methods: [StoredPaymentMethodReference]) -> String? {
        guard !methods.isEmpty,
              let data = try? JSONEncoder().encode(methods.sorted { lhs, rhs in
                  if lhs.provider != rhs.provider { return lhs.provider < rhs.provider }
                  return lhs.id < rhs.id
              }) else { return nil }
        return String(data: data, encoding: .utf8)
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
