import Foundation
import SwiftData
import CloudKit

/// The private database is the durable SwiftData replica for the company-owned
/// iPad and Mac signed in to the same approved business iCloud account.
/// Company-user authorization remains enforced by the GunnAire backend.
enum GunnAireCloudKit {
    static let containerIdentifier = "iCloud.com.gunnaire.businesssuite"

    enum AccountReadiness: Equatable, Sendable {
        case available
        case unavailable
        case restricted
        case couldNotDetermine

        var isReady: Bool {
            self == .available
        }

        var statusTitle: String {
            switch self {
            case .available:
                "Ready"
            case .unavailable:
                "Sign in required"
            case .restricted:
                "Restricted"
            case .couldNotDetermine:
                "Check required"
            }
        }

        var userFacingDetail: String {
            switch self {
            case .available:
                "This device is signed in to iCloud and can use the GunnAire CloudKit container."
            case .unavailable:
                "Sign in to the approved business iCloud account in Settings, then reopen GunnAire Ops before relying on cross-device continuity."
            case .restricted:
                "iCloud access is restricted on this device. Remove the restriction or use an approved company device before relying on cross-device continuity."
            case .couldNotDetermine:
                "GunnAire Ops could not verify iCloud on this device. Check the network and iCloud account, then refresh this screen."
            }
        }
    }

    static func accountReadiness() async -> AccountReadiness {
        // An unsigned XCTest host has no CloudKit entitlement. Constructing a
        // named CKContainer in that process traps before Swift can catch an
        // error, so mirror the test-store policy and report an indeterminate
        // state without touching CloudKit.
        if usesTestDatabase {
            return .couldNotDetermine
        }
        do {
            switch try await CKContainer(identifier: containerIdentifier).accountStatus() {
            case .available:
                return .available
            case .noAccount:
                return .unavailable
            case .restricted:
                return .restricted
            case .couldNotDetermine, .temporarilyUnavailable:
                return .couldNotDetermine
            @unknown default:
                return .couldNotDetermine
            }
        } catch {
            return .couldNotDetermine
        }
    }

    private static var usesTestDatabase: Bool {
        #if DEBUG
        // UI tests run in an unsigned simulator process without the production
        // CloudKit entitlement. This switch is compiled out of release builds.
        let processInfo = ProcessInfo.processInfo
        if processInfo.arguments.contains("-disableCloudKitForTesting") ||
            processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        #endif
        return false
    }

    private static var database: ModelConfiguration.CloudKitDatabase {
        if usesTestDatabase {
            return .none
        }
        return .private(containerIdentifier)
    }

    /// Always uses the signed app's production private database. This is kept
    /// separate so automated tests can prove release configuration without
    /// attempting to attach an unsigned XCTest host to iCloud.
    static func productionModelConfiguration(for schema: Schema) -> ModelConfiguration {
        ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .private(containerIdentifier)
        )
    }

    static func modelConfiguration(for schema: Schema) -> ModelConfiguration {
        guard usesTestDatabase else {
            return productionModelConfiguration(for: schema)
        }
        return ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
    }
}

#if DEBUG
/// Development-only tooling for making SwiftData publish every production
/// entity to the CloudKit development schema. SwiftData creates CloudKit
/// record types lazily, so launching an empty store only creates types for
/// entities that are actually saved. This path is never compiled into Release.
@MainActor
enum GunnAireCloudKitSchemaBootstrap {
    static let initializeArgument = "-initializeCloudKitSchema"
    static let cleanupArgument = "-cleanupCloudKitSchemaBootstrap"

    private static let marker = "__GUNNAIRE_CLOUDKIT_SCHEMA_BOOTSTRAP__"
    private static let bootstrapEmail = "schema-bootstrap@gunnaire.invalid"
    private static let completionKey = "GunnAireCloudKitSchemaBootstrapV8"

    static func runIfRequested(in modelContext: ModelContext) throws {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains(initializeArgument) {
            try initialize(in: modelContext)
        } else if arguments.contains(cleanupArgument) {
            try cleanup(in: modelContext)
        }
    }

    private static func initialize(in modelContext: ModelContext) throws {
        guard !UserDefaults.standard.bool(forKey: completionKey) else { return }

        try seedDevelopmentSchema(in: modelContext)
        UserDefaults.standard.set(true, forKey: completionKey)
    }

    /// Keeps the Debug-only CloudKit migration seed directly testable without
    /// changing the process arguments or completion state used by the app.
    static func seedDevelopmentSchemaForTesting(in modelContext: ModelContext) throws {
        try seedDevelopmentSchema(in: modelContext)
    }

    private static func seedDevelopmentSchema(in modelContext: ModelContext) throws {
        // Versioned bootstraps can be run repeatedly as the shared schema grows.
        // Remove only prior marker records so one migration does not leave a
        // second synthetic company graph in the Development database.
        try cleanup(in: modelContext)

        let now = Date()
        let customer = Customer(
            name: marker,
            storedPaymentMethods: [
                StoredPaymentMethodReference(
                    id: "SCHEMA-BOOTSTRAP-PAYMENT-METHOD",
                    providerCustomerID: "SCHEMA-BOOTSTRAP-CUSTOMER",
                    cardBrand: "Test",
                    lastFour: "0000",
                    active: false,
                    updatedAt: now
                )
            ]
        )
        let technician = Technician(
            name: marker,
            contactInfo: bootstrapEmail,
            quickBooksTimeEntityKind: .employee,
            quickBooksTimeEntityRef: "SCHEMA-BOOTSTRAP"
        )
        let item = Item(
            quickBooksSyncStatus: "synced",
            pricebookReviewStatus: .approved,
            pricebookCreatedByEmail: bootstrapEmail,
            pricebookReviewedByEmail: bootstrapEmail,
            pricebookReviewedAt: now,
            name: marker,
            unitPrice: 0
        )
        let serviceLocation = CustomerServiceLocation(
            customer: customer,
            name: marker,
            address: "1 Schema Bootstrap Way",
            contactName: marker,
            contactPhone: "000-000-0000",
            accessNotes: marker,
            isPrimary: true,
            isActive: false,
            createdAt: now,
            updatedAt: now
        )
        let serviceCall = ServiceCall(
            eventTitle: marker,
            siteAddress: serviceLocation.address,
            serviceLocationID: serviceLocation.id,
            type: .service,
            scheduledDate: now,
            assignedTechnician: technician,
            customer: customer,
            notes: marker,
            visitDisposition: .callback,
            maintenanceAgreementID: UUID(),
            maintenanceAgreementDueDate: now,
            correctiveWorkReason: .unresolvedConcern
        )
        let correctiveFollowUp = ServiceCall(
            eventTitle: marker,
            type: .service,
            scheduledDate: now.addingTimeInterval(3_600),
            assignedTechnician: technician,
            customer: customer,
            notes: marker,
            visitDisposition: .callback,
            originatingServiceCallID: serviceCall.id,
            correctiveWorkReason: .unresolvedConcern
        )
        serviceCall.scheduledFollowUpServiceCallID = correctiveFollowUp.id
        let invoice = Invoice(
            serviceLocationID: serviceLocation.id,
            siteAddress: serviceLocation.address,
            customer: customer,
            notes: marker
        )
        let estimate = Estimate(
            serviceCallID: serviceCall.id,
            serviceLocationID: serviceLocation.id,
            siteAddress: serviceLocation.address,
            scheduledServiceCallID: correctiveFollowUp.id,
            customer: customer,
            status: "accepted",
            customerApprovedByName: marker,
            customerApprovedAt: now,
            customerApprovalMethodRaw: EstimateApprovalMethod.inPersonSignature.rawValue,
            customerApprovalReference: marker,
            customerApprovalRecordedByEmail: bootstrapEmail,
            customerApprovalSignatureImageBase64: Data(marker.utf8).base64EncodedString(),
            notes: marker
        )
        let template = FieldFormTemplate(title: marker, questions: [])

        let models: [any PersistentModel] = [
            item,
            serviceLocation,
            serviceCall,
            correctiveFollowUp,
            customer,
            technician,
            TechnicianAvailabilityBlock(
                technicianID: technician.id,
                startsAt: now,
                endsAt: now.addingTimeInterval(3_600),
                reason: marker
            ),
            RecurringMaintenanceContract(
                customer: customer,
                planName: marker,
                schedulePattern: "Annual",
                nextDate: now
            ),
            invoice,
            estimate,
            Payment(invoice: invoice, amount: 0, notes: marker),
            TimeEntry(userEmail: bootstrapEmail, clockIn: now, clockOut: now, serviceCall: serviceCall, notes: marker),
            Vendor(name: marker),
            AppUser(email: bootstrapEmail),
            ServiceDocumentAttachment(
                customer: customer,
                serviceCallID: serviceCall.id,
                kind: .other,
                displayName: marker,
                localFilePath: "/tmp/gunnaire-cloudkit-schema-bootstrap",
                contentType: "application/octet-stream",
                fileSizeBytes: 0
            ),
            CustomerEquipment(customer: customer, serviceLocationID: serviceLocation.id, name: marker),
            CustomerCommunication(
                customer: customer,
                serviceCallID: serviceCall.id,
                recipient: bootstrapEmail,
                subject: marker,
                deliveryStatus: "development_schema_bootstrap"
            ),
            PurchaseOrder(
                vendorName: marker,
                serviceCallID: serviceCall.id,
                itemName: marker,
                quantity: 1,
                unitCost: 0,
                notes: marker,
                createdByEmail: bootstrapEmail
            ),
            InventoryMovement(item: item, type: .adjust, quantity: 0, notes: marker, createdByEmail: bootstrapEmail),
            ServiceRequest(customerName: marker, summary: marker, createdByEmail: bootstrapEmail),
            ServiceCallActivity(serviceCallID: serviceCall.id, action: marker, detail: marker, actorEmail: bootstrapEmail),
            template,
            FieldFormResponse(serviceCallID: serviceCall.id, template: template, answers: [:], completedByEmail: bootstrapEmail),
        ]

        for model in models {
            modelContext.insert(model)
        }
        try modelContext.save()
    }

    private static func cleanup(in modelContext: ModelContext) throws {
        for value in try modelContext.fetch(FetchDescriptor<CustomerServiceLocation>()) where value.name == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<ServiceDocumentAttachment>()) where value.displayName == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<CustomerCommunication>()) where value.subject == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<Payment>()) where value.notes == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<TimeEntry>()) where value.notes == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<FieldFormResponse>()) where value.templateTitle == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<ServiceCallActivity>()) where value.action == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<InventoryMovement>()) where value.notes == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<PurchaseOrder>()) where value.notes == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<RecurringMaintenanceContract>()) where value.planName == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<Invoice>()) where value.notes == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<Estimate>()) where value.notes == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<ServiceCall>()) where value.eventTitle == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<CustomerEquipment>()) where value.name == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<TechnicianAvailabilityBlock>()) where value.reason == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<ServiceRequest>()) where value.summary == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<FieldFormTemplate>()) where value.title == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<Item>()) where value.name == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<Vendor>()) where value.name == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<Technician>()) where value.name == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<AppUser>()) where value.email == bootstrapEmail {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<Customer>()) where value.name == marker {
            modelContext.delete(value)
        }

        try modelContext.save()
    }
}
#endif
