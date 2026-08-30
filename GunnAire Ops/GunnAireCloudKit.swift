import Foundation
import SwiftData
import CloudKit
import CoreData
import Combine
import os

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

    static var usesTestDatabase: Bool {
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
        if usesTestDatabase {
            return ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
        }

        #if DEBUG
        if GunnAireCloudKitSchemaBootstrap.isRequested {
            return GunnAireCloudKitSchemaBootstrap.modelConfiguration(for: schema)
        }
        #endif

        return productionModelConfiguration(for: schema)
    }
}

enum CloudKitMirroringOperation: String, CaseIterable, Codable, Hashable, Sendable {
    case setup
    case importRecords
    case exportRecords

    var activityDescription: String {
        switch self {
        case .setup:
            "preparing cloud sync"
        case .importRecords:
            "receiving updates"
        case .exportRecords:
            "uploading saved work"
        }
    }

    fileprivate var attentionPriority: Int {
        switch self {
        case .exportRecords: 0
        case .setup: 1
        case .importRecords: 2
        }
    }
}

enum CloudKitMirroringOutcome: Equatable, Sendable {
    case running
    case succeeded
    case failed
}

struct CloudKitMirroringEventSnapshot: Equatable, Sendable {
    let identifier: UUID
    let operation: CloudKitMirroringOperation
    let outcome: CloudKitMirroringOutcome
    let occurredAt: Date

    init(
        identifier: UUID = UUID(),
        operation: CloudKitMirroringOperation,
        outcome: CloudKitMirroringOutcome,
        occurredAt: Date = Date()
    ) {
        self.identifier = identifier
        self.operation = operation
        self.outcome = outcome
        self.occurredAt = occurredAt
    }

    init?(_ event: NSPersistentCloudKitContainer.Event) {
        let operation: CloudKitMirroringOperation
        switch event.type {
        case .setup:
            operation = .setup
        case .import:
            operation = .importRecords
        case .export:
            operation = .exportRecords
        @unknown default:
            return nil
        }

        let outcome: CloudKitMirroringOutcome
        if event.endDate == nil {
            outcome = .running
        } else if event.succeeded {
            outcome = .succeeded
        } else {
            outcome = .failed
        }

        self.init(
            identifier: event.identifier,
            operation: operation,
            outcome: outcome,
            occurredAt: event.endDate ?? event.startDate
        )
    }
}

struct CloudKitMirroringFailure: Codable, Equatable, Sendable {
    let operation: CloudKitMirroringOperation
    let occurredAt: Date

    var title: String {
        switch operation {
        case .setup:
            "Cloud sync setup failed"
        case .importRecords:
            "Cloud updates need attention"
        case .exportRecords:
            "Changes waiting for CloudKit"
        }
    }

    var statusDetail: String {
        switch operation {
        case .setup:
            "CloudKit could not finish preparing this device for cross-device operations."
        case .importRecords:
            "CloudKit could not receive the latest changes from another company device."
        case .exportRecords:
            "CloudKit could not upload the latest work saved on this device."
        }
    }

    var recoveryDetail: String {
        switch operation {
        case .setup:
            "Existing local data was not removed. Confirm this is an approved company device signed in to the business iCloud account, use a stable network, and check again before relying on another device."
        case .importRecords:
            "Keep this app open on a stable network and check again. Do not assume another device's newer schedule, invoice, or job changes are present until this warning clears."
        case .exportRecords:
            "Your work remains saved on this device. Keep the app open on a stable network and check again before signing out, reinstalling, or relying on another device."
        }
    }
}

struct CloudKitMirroringState: Codable, Equatable, Sendable {
    private(set) var runningOperations: Set<CloudKitMirroringOperation> = []
    private(set) var failures: [CloudKitMirroringOperation: CloudKitMirroringFailure] = [:]
    private(set) var latestSuccessAt: [CloudKitMirroringOperation: Date] = [:]

    mutating func apply(_ event: CloudKitMirroringEventSnapshot) {
        switch event.outcome {
        case .running:
            runningOperations.insert(event.operation)
        case .succeeded:
            runningOperations.remove(event.operation)
            failures.removeValue(forKey: event.operation)
            latestSuccessAt[event.operation] = event.occurredAt
        case .failed:
            runningOperations.remove(event.operation)
            failures[event.operation] = CloudKitMirroringFailure(
                operation: event.operation,
                occurredAt: event.occurredAt
            )
        }
    }

    var attentionFailure: CloudKitMirroringFailure? {
        failures.values.sorted { lhs, rhs in
            if lhs.occurredAt != rhs.occurredAt {
                return lhs.occurredAt > rhs.occurredAt
            }
            return lhs.operation.attentionPriority < rhs.operation.attentionPriority
        }.first
    }

    var needsAttention: Bool {
        attentionFailure != nil
    }

    var operatorStatusDetail: String {
        if let failure = attentionFailure {
            return "\(failure.statusDetail) \(failure.recoveryDetail)"
        }
        if !runningOperations.isEmpty {
            let activities = runningOperations
                .sorted { $0.attentionPriority < $1.attentionPriority }
                .map(\.activityDescription)
            return "CloudKit is \(activities.joined(separator: " and "))."
        }
        if !latestSuccessAt.isEmpty {
            return "The latest observed CloudKit transfer completed successfully."
        }
        return "No CloudKit transfer failure has been reported in this app session."
    }

    /// Failures must survive relaunch so staff cannot mistake a restart for a
    /// successful upload. In-progress operations are intentionally discarded;
    /// they either emit a completion event or are restarted by CloudKit.
    var durableSnapshot: Self {
        var snapshot = self
        snapshot.runningOperations = []
        return snapshot
    }
}

/// Observes the mirroring events emitted by the persistent CloudKit container.
/// The reducer stores no customer data and keeps successful routine sync quiet.
final class GunnAireCloudKitEventMonitor: ObservableObject {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "GunnAireOps",
        category: "CloudKitContinuity"
    )

    @Published private(set) var state = CloudKitMirroringState()

    private let notificationCenter: NotificationCenter
    private let userDefaults: UserDefaults
    private let persistenceEnabled: Bool
    private var eventObserver: NSObjectProtocol?
    private var retainedContainer: CKContainer?

    private static let persistedStateKey = "GunnAireCloudKitMirroringStateV1"

    init(
        notificationCenter: NotificationCenter = .default,
        userDefaults: UserDefaults = .standard,
        isEnabled: Bool = !GunnAireCloudKit.usesTestDatabase
    ) {
        self.notificationCenter = notificationCenter
        self.userDefaults = userDefaults
        self.persistenceEnabled = isEnabled
        guard isEnabled else { return }

        if let data = userDefaults.data(forKey: Self.persistedStateKey),
           let restored = try? JSONDecoder().decode(CloudKitMirroringState.self, from: data) {
            state = restored.durableSnapshot
        }

        // Retaining the named container ensures CloudKit posts account-change
        // notifications while SwiftData owns the private-database mirroring.
        retainedContainer = CKContainer(identifier: GunnAireCloudKit.containerIdentifier)
        eventObserver = notificationCenter.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event,
                  let snapshot = CloudKitMirroringEventSnapshot(event) else { return }

            if let error = event.error {
                let nsError = error as NSError
                Self.logger.error(
                    "CloudKit \(snapshot.operation.rawValue, privacy: .public) failed: \(nsError.domain, privacy: .public)#\(nsError.code, privacy: .public)"
                )
            }
            self?.record(snapshot)
        }
    }

    deinit {
        if let eventObserver {
            notificationCenter.removeObserver(eventObserver)
        }
    }

    func record(_ event: CloudKitMirroringEventSnapshot) {
        state.apply(event)
        guard persistenceEnabled,
              let data = try? JSONEncoder().encode(state.durableSnapshot) else { return }
        userDefaults.set(data, forKey: Self.persistedStateKey)
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
    static let schemaVersion = 15

    private static let marker = "__GUNNAIRE_CLOUDKIT_SCHEMA_BOOTSTRAP__"
    private static let bootstrapEmail = "schema-bootstrap@gunnaire.invalid"
    private static let completionKey = "GunnAireCloudKitSchemaBootstrapV\(schemaVersion)"
    static let storeFileName = "GunnAireCloudKitSchemaBootstrapV\(schemaVersion).store"

    static var isRequested: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains(initializeArgument) || arguments.contains(cleanupArgument)
    }

    /// Keeps schema publishing and marker cleanup away from the developer's
    /// normal app store. A stale local Debug store must never prevent a newer
    /// CloudKit schema from being initialized or its marker graph removed.
    static func modelConfiguration(for schema: Schema) -> ModelConfiguration {
        ModelConfiguration(
            "GunnAireCloudKitSchemaBootstrapV\(schemaVersion)",
            schema: schema,
            url: FileManager.default.temporaryDirectory.appendingPathComponent(storeFileName),
            allowsSave: true,
            cloudKitDatabase: .private(GunnAireCloudKit.containerIdentifier)
        )
    }

    static func runIfRequested(in modelContext: ModelContext) throws {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains(initializeArgument) {
            try initialize(in: modelContext)
        } else if arguments.contains(cleanupArgument) {
            do {
                try cleanup(in: modelContext)
            } catch {
                debugLog("initial cleanup failed: \(String(describing: error))")
                throw error
            }
            scheduleFollowUpCleanup(in: modelContext)
        }
    }

    /// CloudKit can finish its first import after startup cleanup has already
    /// run, temporarily restoring a bootstrap marker from the development
    /// database. Repeat the idempotent marker-only cleanup after that import
    /// window so the corresponding deletions are exported as well.
    private static func scheduleFollowUpCleanup(in modelContext: ModelContext) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            runFollowUpCleanup(in: modelContext, pass: 1)
            try? await Task.sleep(for: .seconds(6))
            runFollowUpCleanup(in: modelContext, pass: 2)
        }
    }

    private static func runFollowUpCleanup(in modelContext: ModelContext, pass: Int) {
        do {
            try cleanup(in: modelContext)
            debugLog("follow-up cleanup pass \(pass) saved")
        } catch {
            debugLog("follow-up cleanup pass \(pass) failed: \(error.localizedDescription)")
        }
    }

    private static func debugLog(_ message: String) {
        FileHandle.standardError.write(Data("[GunnAireCloudKitSchemaBootstrap] \(message)\n".utf8))
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
        let assemblyComponentItem = Item(
            quickBooksID: "SCHEMA-BOOTSTRAP-COMPONENT",
            quickBooksSyncStatus: "synced",
            name: marker,
            itemType: .nonInventory,
            unitPrice: 0,
            purchaseCost: 0,
            itemDescription: marker,
            sku: "SCHEMA-COMPONENT",
            tracksInventory: true,
            reorderPoint: 0,
            defaultInventoryLocation: marker,
            createdAt: now
        )
        let assemblyDefinition = CatalogAssemblyDefinition(
            revision: 1,
            presentation: .flatRate,
            components: [
                CatalogAssemblyComponentDefinition(itemID: assemblyComponentItem.id, quantity: 1)
            ]
        )
        let item = Item(
            quickBooksID: "SCHEMA-BOOTSTRAP-ITEM",
            quickBooksSyncStatus: "synced",
            quickBooksSyncDetail: marker,
            quickBooksLastSyncedAt: now,
            pricebookReviewStatus: .approved,
            pricebookCreatedByEmail: bootstrapEmail,
            pricebookReviewedByEmail: bootstrapEmail,
            pricebookReviewedAt: now,
            name: marker,
            itemType: .service,
            unitPrice: 0,
            purchaseCost: 0,
            itemDescription: marker,
            sku: "SCHEMA-PACKAGE",
            preferredVendorName: marker,
            preferredVendorQuickBooksID: "SCHEMA-BOOTSTRAP-VENDOR",
            vendorPartNumber: marker,
            purchaseURL: "https://example.invalid/schema-bootstrap",
            purchaseDescription: marker,
            tracksInventory: true,
            reorderPoint: 0,
            defaultInventoryLocation: marker,
            flatRateAssemblyJSON: assemblyDefinition.encodedJSON,
            createdAt: now
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
            amount: 1.08,
            salesTaxAmount: 0.08,
            taxCalculationStatus: .calculatedByQuickBooks,
            taxCalculatedAt: now,
            projectMilestoneID: UUID(),
            projectMilestoneSequence: 0,
            projectMilestoneTitle: marker,
            projectContractAmount: 1,
            projectBillingPercent: 100,
            dueDate: now,
            notes: marker
        )
        let estimate = Estimate(
            serviceCallID: serviceCall.id,
            serviceLocationID: serviceLocation.id,
            siteAddress: serviceLocation.address,
            scheduledServiceCallID: correctiveFollowUp.id,
            customer: customer,
            amount: 1.08,
            salesTaxAmount: 0.08,
            taxCalculationStatus: .calculatedByQuickBooks,
            taxCalculatedAt: now,
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
        let projectMilestone = ProjectMilestone(
            projectServiceCallID: serviceCall.id,
            estimateID: estimate.id,
            sequence: 0,
            title: marker,
            plannedDate: now,
            billingPercent: 100,
            plannedAmount: 1,
            billingTrigger: .customerApproval,
            status: .invoiced,
            invoiceID: invoice.id,
            completedAt: now,
            completedByEmail: bootstrapEmail,
            createdAt: now,
            createdByEmail: bootstrapEmail
        )
        invoice.projectMilestoneID = projectMilestone.id
        let maintenanceAgreement = RecurringMaintenanceContract(
            customer: customer,
            planName: marker,
            schedulePattern: "Annual",
            nextDate: now,
            active: false
        )
        maintenanceAgreement.configureDraft(
            agreementPrice: 1,
            billingInterval: .annual,
            memberDiscountPercent: 1,
            autoRenews: true,
            termsSummary: marker,
            createdByEmail: bootstrapEmail,
            sourceServiceCallID: serviceCall.id,
            createdAt: now
        )
        let maintenanceAgreementDocument = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCall.id,
            maintenanceContractID: maintenanceAgreement.id,
            kind: .maintenanceAgreement,
            displayName: marker,
            localFilePath: "/tmp/gunnaire-cloudkit-schema-bootstrap-agreement",
            contentType: "application/pdf",
            fileSizeBytes: 0
        )

        let models: [any PersistentModel] = [
            item,
            assemblyComponentItem,
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
            maintenanceAgreement,
            invoice,
            estimate,
            Payment(invoice: invoice, amount: 0, notes: marker),
            TimeEntry(
                userEmail: bootstrapEmail,
                clockIn: now,
                clockOut: now,
                serviceCall: serviceCall,
                notes: marker,
                reviewStatus: .approved,
                reviewedByEmail: bootstrapEmail,
                reviewedAt: now,
                reviewNote: marker,
                reviewAuditJSON: TimeEntryReviewAudit.appending(
                    TimeEntryReviewEvent(
                        action: .approved,
                        actorEmail: bootstrapEmail,
                        occurredAt: now,
                        detail: marker
                    ),
                    to: nil
                )
            ),
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
            maintenanceAgreementDocument,
            CustomerEquipment(customer: customer, serviceLocationID: serviceLocation.id, name: marker),
            CustomerCommunication(
                customer: customer,
                serviceCallID: serviceCall.id,
                maintenanceContractID: UUID(),
                recipient: bootstrapEmail,
                subject: marker,
                deliveryStatus: "sent",
                workflow: .appointmentConfirmation,
                actorEmail: bootstrapEmail,
                consentSnapshot: CustomerCommunicationConsentSnapshot(customer: customer),
                providerStatusDetail: marker,
                deliveredAt: now
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
            projectMilestone,
            template,
            FieldFormResponse(serviceCallID: serviceCall.id, template: template, answers: [:], completedByEmail: bootstrapEmail),
        ]

        for model in models {
            modelContext.insert(model)
        }
        try modelContext.save()
    }

    private static func cleanup(in modelContext: ModelContext) throws {
        let projectMilestones = try modelContext.fetch(FetchDescriptor<ProjectMilestone>())
        debugLog("cleanup found \(projectMilestones.filter { $0.title == marker }.count) project milestone marker(s)")
        for value in projectMilestones where value.title == marker {
            modelContext.delete(value)
        }
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
        debugLog("cleanup save completed")
    }
}
#endif
