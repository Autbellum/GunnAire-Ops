//
//  GunnAire_OpsApp.swift
//  GunnAire Ops
//
//  Created by Eric Gunn on 2/23/26.
//
//  See Config.swift for app configuration and API setup.
//

import SwiftUI
import SwiftData
import os
import AppIntents

@main
struct GunnAire_OpsApp: App {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GunnAireOps", category: "AppStartup")
    @UIApplicationDelegateAdaptor(GunnAireApplicationDelegate.self) private var applicationDelegate
    private let startupState: StartupState
    @StateObject private var cloudKitEventMonitor: GunnAireCloudKitEventMonitor

    init() {
        let cloudKitEventMonitor = GunnAireCloudKitEventMonitor()
        _cloudKitEventMonitor = StateObject(wrappedValue: cloudKitEventMonitor)
        self.startupState = Self.buildStartupState()
        Task { @MainActor in
            GunnAireAppShortcuts.updateAppShortcutParameters()
        }
    }

    var body: some Scene {
        WindowGroup {
            switch startupState {
            case .ready(let sharedModelContainer):
                AppRootView()
                    .modelContainer(sharedModelContainer)
                    .environmentObject(cloudKitEventMonitor)
            case .failed(let message):
                StartupFailureView(message: message)
            }
        }
        .commands {
            GunnAireNavigationCommands()
        }
    }

    private static func buildStartupState() -> StartupState {
        let schema = GunnAireModelSchema.schema
        let modelConfiguration = GunnAireCloudKit.modelConfiguration(for: schema)

        do {
            let modelContainer = try ModelContainer(for: schema, configurations: [modelConfiguration])
            FieldFormTemplate.ensureStarterTemplates(in: modelContainer.mainContext)
            try modelContainer.mainContext.save()
            #if DEBUG
            try GunnAireCloudKitSchemaBootstrap.runIfRequested(in: modelContainer.mainContext)
            try GunnAireUITestFixtures.prepareIfRequested(in: modelContainer.mainContext)
            #endif
            return .ready(modelContainer)
        } catch {
            logger.error("Persistent SwiftData store load failed: \(error.localizedDescription, privacy: .public)")
            return .failed(
                "The app could not access its local data store. Your existing data was not changed. Restart the app, check available device storage, and contact GunnAire support before reinstalling."
            )
        }
    }

    private enum StartupState {
        case ready(ModelContainer)
        case failed(String)
    }
}

/// A deliberately short list of the destinations used repeatedly from an
/// attached iPad keyboard or a Mac. Route authorization remains centralized in
/// `ContentView`, so a shortcut never bypasses the signed-in business role.
struct GunnAireNavigationCommandDefinition: Equatable, Identifiable {
    let route: GunnAireAppRoute
    let title: String
    let systemImage: String
    let key: Character

    var id: String { route.rawValue }

    static let primary: [Self] = [
        .init(route: .commandCenter, title: "Command Center", systemImage: "rectangle.3.group", key: "1"),
        .init(route: .schedule, title: "Schedule & Jobs", systemImage: "calendar", key: "2"),
        .init(route: .customers, title: "Customers", systemImage: "person.3", key: "3"),
        .init(route: .documentation, title: "Onsite Documentation", systemImage: "book", key: "4"),
        .init(route: .invoices, title: "Invoices", systemImage: "doc.text", key: "5"),
        .init(route: .payments, title: "Payments", systemImage: "creditcard", key: "6")
    ]
}

struct GunnAireNavigationCommands: Commands {
    var body: some Commands {
        CommandMenu("Navigate") {
            ForEach(GunnAireNavigationCommandDefinition.primary) { command in
                Button(command.title, systemImage: command.systemImage) {
                    GunnAireAppIntentRouter.store(command.route)
                }
                .keyboardShortcut(KeyEquivalent(command.key), modifiers: .command)
            }

            Divider()

            Button("Business Reports", systemImage: "chart.bar.xaxis") {
                GunnAireAppIntentRouter.store(.reports)
            }
            .keyboardShortcut("7", modifiers: .command)
        }
    }
}

#if DEBUG
private enum GunnAireUITestFixtures {
    private static let customerID = UUID(uuidString: "A1000000-0000-4000-8000-000000000001")!
    private static let serviceCallID = UUID(uuidString: "A1000000-0000-4000-8000-000000000002")!
    private static let invoiceID = UUID(uuidString: "A1000000-0000-4000-8000-000000000003")!
    private static let standardUserID = UUID(uuidString: "A1000000-0000-4000-8000-000000000004")!
    private static let technicianUserID = UUID(uuidString: "A1000000-0000-4000-8000-000000000005")!
    private static let technicianID = UUID(uuidString: "A1000000-0000-4000-8000-000000000006")!
    private static let catalogItemID = UUID(uuidString: "A1000000-0000-4000-8000-000000000007")!
    private static let correctiveSourceCallID = UUID(uuidString: "A1000000-0000-4000-8000-000000000008")!
    private static let correctiveFollowUpCallID = UUID(uuidString: "A1000000-0000-4000-8000-000000000009")!
    private static let equipmentID = UUID(uuidString: "A1000000-0000-4000-8000-000000000010")!
    private static let maintenanceAgreementID = UUID(uuidString: "A1000000-0000-4000-8000-000000000011")!
    private static let maintenanceServiceCallID = UUID(uuidString: "A1000000-0000-4000-8000-000000000012")!
    private static let inventoryItemID = UUID(uuidString: "A1000000-0000-4000-8000-000000000013")!
    private static let inventoryReceiptID = UUID(uuidString: "A1000000-0000-4000-8000-000000000014")!
    private static let inventoryReservationID = UUID(uuidString: "A1000000-0000-4000-8000-000000000015")!
    private static let estimateID = UUID(uuidString: "A1000000-0000-4000-8000-000000000016")!
    private static let serviceLocationID = UUID(uuidString: "A1000000-0000-4000-8000-000000000017")!
    private static let purchaseOrderID = UUID(uuidString: "A1000000-0000-4000-8000-000000000018")!
    private static let serviceRequestID = UUID(uuidString: "A1000000-0000-4000-8000-000000000019")!
    private static let projectServiceCallID = UUID(uuidString: "A1000000-0000-4000-8000-000000000020")!
    private static let projectEstimateID = UUID(uuidString: "A1000000-0000-4000-8000-000000000021")!
    private static let projectCatalogItemID = UUID(uuidString: "A1000000-0000-4000-8000-000000000022")!
    private static let projectDepositMilestoneID = UUID(uuidString: "A1000000-0000-4000-8000-000000000023")!
    private static let projectInstallationMilestoneID = UUID(uuidString: "A1000000-0000-4000-8000-000000000024")!
    private static let projectHandoffMilestoneID = UUID(uuidString: "A1000000-0000-4000-8000-000000000025")!
    private static let submittedTimeEntryID = UUID(uuidString: "A1000000-0000-4000-8000-000000000026")!
    private static let communicationID = UUID(uuidString: "A1000000-0000-4000-8000-000000000027")!
    private static let duplicateCatalogMappingItemID = UUID(uuidString: "A1000000-0000-4000-8000-000000000028")!
    private static let unassignedScheduleServiceCallID = UUID(uuidString: "A1000000-0000-4000-8000-000000000029")!
    private static let equipmentDecisionHistoryCallID = UUID(uuidString: "A1000000-0000-4000-8000-000000000030")!
    private static let servicePackageComponentItemID = UUID(uuidString: "A1000000-0000-4000-8000-000000000031")!
    private static let servicePackageItemID = UUID(uuidString: "A1000000-0000-4000-8000-000000000032")!
    private static let openJobTimeEntryID = UUID(uuidString: "A1000000-0000-4000-8000-000000000033")!
    private static let purchaseOrderPrimaryLineID = UUID(uuidString: "A1000000-0000-4000-8000-000000000034")!
    private static let purchaseOrderSecondaryLineID = UUID(uuidString: "A1000000-0000-4000-8000-000000000035")!
    private static let warrantyEvidenceID = UUID(uuidString: "A1000000-0000-4000-8000-000000000036")!
    private static let warrantyClaimID = UUID(uuidString: "A1000000-0000-4000-8000-000000000037")!
    private static let accountingUserID = UUID(uuidString: "A1000000-0000-4000-8000-000000000038")!

    static func prepareIfRequested(in context: ModelContext) throws {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-disableCloudKitForTesting") else { return }
        let isScreenshotFixture = arguments.contains("-appStoreScreenshotFixtures")
        let isMultiLinePurchaseOrderFixture = arguments.contains("-uiTestSeedMultiLinePurchaseOrderDraft")
        let isSerializedPurchaseOrderFixture = arguments.contains("-uiTestSeedSerializedPurchaseOrderDraft")
        let isPurchaseOrderDraftFixture = arguments.contains("-uiTestSeedPurchaseOrderDraft") ||
            isMultiLinePurchaseOrderFixture ||
            isSerializedPurchaseOrderFixture
        let isWarrantyClaimFixture = arguments.contains("-uiTestSeedWarrantyClaim")
        let isInventoryShortageFixture = arguments.contains("-uiTestSeedInventoryShortage")
        let isInventoryFixture = arguments.contains("-uiTestSeedInventoryJob") || isInventoryShortageFixture || isPurchaseOrderDraftFixture || isWarrantyClaimFixture
        let isPendingEstimateFixture = arguments.contains("-uiTestSeedPendingEstimate")
        let isAcceptedStandaloneEstimateFixture = arguments.contains("-uiTestSeedAcceptedStandaloneEstimate")
        let isPricebookReviewFixture = arguments.contains("-uiTestSeedPricebookReview")
        let isCatalogReconciliationFixture = arguments.contains("-uiTestSeedCatalogReconciliation")
        let isCatalogMappingConflictFixture = arguments.contains("-uiTestSeedCatalogMappingConflict")
        let isSyncRecoveryFixture = arguments.contains("-uiTestSeedSyncRecovery")
        let isServiceRequestFixture = arguments.contains("-uiTestSeedServiceRequest")
        let isProjectMilestoneFixture = arguments.contains("-uiTestSeedProjectMilestones")
        let isTeamTimeReviewFixture = arguments.contains("-uiTestSeedTeamTimeReview")
        let isTimeClassificationFixture = arguments.contains("-uiTestSeedTimeClassification")
        let isOpenJobTimeFixture = arguments.contains("-uiTestSeedOpenJobTime")
        let isCommunicationFixture = arguments.contains("-uiTestSeedCustomerCommunication")
        let isMaintenanceReportingFixture = arguments.contains("-uiTestSeedMaintenanceReporting")
        let isAgreementBillingFixture = arguments.contains("-uiTestSeedAgreementBilling")
        let isScheduleAuthorizationFixture = arguments.contains("-uiTestSeedScheduleAuthorization")
        let isPendingTaxFixture = arguments.contains("-uiTestSeedPendingQuickBooksTax")
        let isQuickBooksLinkedCollectionFixture = arguments.contains("-uiTestSeedQuickBooksLinkedCollection")
        let isEquipmentDecisionFixture = arguments.contains("-uiTestSeedEquipmentDecision")
        let isQualificationReviewFixture = arguments.contains("-uiTestSeedQualificationReview")
        let isServicePackageFixture = arguments.contains("-uiTestSeedServicePackage")

        let appUsers = try context.fetch(FetchDescriptor<AppUser>())
        for user in appUsers where
            user.id == standardUserID ||
            user.id == technicianUserID ||
            user.id == accountingUserID ||
            user.email == GunnAireUITestIdentity.standardEmail ||
            user.email == GunnAireUITestIdentity.technicianEmail ||
            user.email == GunnAireUITestIdentity.accountingEmail {
            context.delete(user)
        }
        if arguments.contains("-uiTestAuthenticatedStandard") {
            context.insert(AppUser(id: standardUserID, email: GunnAireUITestIdentity.standardEmail, role: .standard))
        }
        if arguments.contains("-uiTestAuthenticatedTechnician") {
            context.insert(AppUser(id: technicianUserID, email: GunnAireUITestIdentity.technicianEmail, role: .fieldTechnician))
        }
        if arguments.contains("-uiTestAuthenticatedAccounting") {
            context.insert(AppUser(id: accountingUserID, email: GunnAireUITestIdentity.accountingEmail, role: .accounting))
        }

        let payments = try context.fetch(FetchDescriptor<Payment>())
        for payment in payments where payment.invoice?.id == invoiceID {
            context.delete(payment)
        }
        let invoices = try context.fetch(FetchDescriptor<Invoice>())
        for invoice in invoices where
            invoice.id == invoiceID ||
            invoice.serviceCallID == projectServiceCallID ||
            invoice.projectMilestoneID == projectDepositMilestoneID ||
            invoice.projectMilestoneID == projectInstallationMilestoneID ||
            invoice.projectMilestoneID == projectHandoffMilestoneID ||
            (isAgreementBillingFixture && invoice.serviceCallID == nil && invoice.lineItemSummary.contains("Comfort Care")) ||
            (isPricebookReviewFixture && CatalogLineItemSnapshot.decoded(from: invoice.catalogSnapshotJSON).contains { $0.catalogItemID == catalogItemID }) {
            context.delete(invoice)
        }
        let estimates = try context.fetch(FetchDescriptor<Estimate>())
        for estimate in estimates where
            estimate.id == estimateID ||
            estimate.id == projectEstimateID ||
            (isPricebookReviewFixture && CatalogLineItemSnapshot.decoded(from: estimate.catalogSnapshotJSON).contains { $0.catalogItemID == catalogItemID }) {
            context.delete(estimate)
        }
        let calls = try context.fetch(FetchDescriptor<ServiceCall>())
        let fixtureCallIDs = Set(calls.compactMap { call in
            call.id == serviceCallID ||
            call.id == correctiveSourceCallID ||
            call.id == correctiveFollowUpCallID ||
            call.id == maintenanceServiceCallID ||
            call.id == projectServiceCallID ||
            call.id == unassignedScheduleServiceCallID ||
            call.id == equipmentDecisionHistoryCallID ||
            call.linkedEstimateID == estimateID ? call.id : nil
        })
        for call in calls where fixtureCallIDs.contains(call.id) {
            context.delete(call)
        }
        let timeEntries = try context.fetch(FetchDescriptor<TimeEntry>())
        for entry in timeEntries where entry.id == submittedTimeEntryID ||
            entry.id == openJobTimeEntryID ||
            (isTimeClassificationFixture && AppAccess.normalizedEmail(entry.userEmail) == GunnAireUITestIdentity.technicianEmail) {
            context.delete(entry)
        }
        let activities = try context.fetch(FetchDescriptor<ServiceCallActivity>())
        for activity in activities where fixtureCallIDs.contains(activity.serviceCallID) {
            context.delete(activity)
        }
        let projectMilestones = try context.fetch(FetchDescriptor<ProjectMilestone>())
        for milestone in projectMilestones where
            milestone.projectServiceCallID == projectServiceCallID ||
            milestone.id == projectDepositMilestoneID ||
            milestone.id == projectInstallationMilestoneID ||
            milestone.id == projectHandoffMilestoneID {
            context.delete(milestone)
        }
        let maintenanceAgreements = try context.fetch(FetchDescriptor<RecurringMaintenanceContract>())
        for agreement in maintenanceAgreements where agreement.id == maintenanceAgreementID {
            context.delete(agreement)
        }
        let equipmentProfiles = try context.fetch(FetchDescriptor<CustomerEquipment>())
        for equipment in equipmentProfiles where equipment.id == equipmentID {
            context.delete(equipment)
        }
        let documentAttachments = try context.fetch(FetchDescriptor<ServiceDocumentAttachment>())
        for attachment in documentAttachments where attachment.id == warrantyEvidenceID {
            context.delete(attachment)
        }
        let serviceLocations = try context.fetch(FetchDescriptor<CustomerServiceLocation>())
        for location in serviceLocations where location.id == serviceLocationID {
            context.delete(location)
        }
        let communications = try context.fetch(FetchDescriptor<CustomerCommunication>())
        for communication in communications where communication.id == communicationID {
            context.delete(communication)
        }
        let customers = try context.fetch(FetchDescriptor<Customer>())
        for customer in customers where customer.id == customerID {
            context.delete(customer)
        }
        let technicians = try context.fetch(FetchDescriptor<Technician>())
        for technician in technicians where technician.id == technicianID || technician.contactInfo == GunnAireUITestIdentity.technicianEmail {
            context.delete(technician)
        }
        let inventoryMovements = try context.fetch(FetchDescriptor<InventoryMovement>())
        for movement in inventoryMovements where movement.itemID == inventoryItemID || movement.id == inventoryReceiptID || movement.id == inventoryReservationID {
            context.delete(movement)
        }
        let purchaseOrders = try context.fetch(FetchDescriptor<PurchaseOrder>())
        for order in purchaseOrders where order.id == purchaseOrderID || (order.serviceCallID == serviceCallID && (order.itemSKU == "CAP-45-5" || order.itemName == "45/5 Dual Run Capacitor")) {
            context.delete(order)
        }
        let catalogItems = try context.fetch(FetchDescriptor<Item>())
        for item in catalogItems where
            item.id == catalogItemID ||
            item.id == inventoryItemID ||
            item.id == projectCatalogItemID ||
            item.id == duplicateCatalogMappingItemID ||
            item.id == servicePackageComponentItemID ||
            item.id == servicePackageItemID ||
            item.name == "UI Test Added Repair" {
            context.delete(item)
        }
        let serviceRequests = try context.fetch(FetchDescriptor<ServiceRequest>())
        for request in serviceRequests where request.id == serviceRequestID {
            context.delete(request)
        }
        if isServiceRequestFixture {
            context.insert(ServiceRequest(
                id: serviceRequestID,
                customerName: "Google Lead Customer",
                phone: "555-0199",
                email: "lead@example.com",
                address: "199 Comfort Lane",
                requestedServiceType: .estimate,
                urgency: .priority,
                summary: "Replace aging heat pump",
                source: .googleBusinessProfile,
                createdByEmail: AppAccess.primaryAdminEmail
            ))
        }
        try context.save()

        guard arguments.contains("-uiTestSeedCollectibleJob") ||
            isPendingTaxFixture ||
            isScreenshotFixture ||
            isSyncRecoveryFixture ||
            isProjectMilestoneFixture ||
            isTeamTimeReviewFixture ||
            isCommunicationFixture ||
            isScheduleAuthorizationFixture ||
            isAgreementBillingFixture ||
            isQualificationReviewFixture ||
            isServicePackageFixture ||
            isWarrantyClaimFixture else { return }

        let customer = Customer(
            id: customerID,
            quickBooksID: "QBO-UI-CUSTOMER",
            name: isScreenshotFixture ? "Blue Ridge Dental" : "UI Test Collectible Customer",
            phone: isScreenshotFixture ? "(336) 555-0148" : "555-0100",
            email: isScreenshotFixture ? "office@example.com" : "uitest@gunnaire.com",
            address: isScreenshotFixture ? "2450 Robinhood Rd, Winston-Salem, NC" : "100 Test Air Way",
            storedPaymentMethods: [
                StoredPaymentMethodReference(
                    id: "QBO-UI-CARD",
                    providerCustomerID: "QBO-UI-CUSTOMER",
                    cardholderName: isScreenshotFixture ? "Blue Ridge Dental" : "UI Test Collectible Customer",
                    cardBrand: "Visa",
                    lastFour: "4242",
                    expirationMonth: "12",
                    expirationYear: "2030"
                )
            ]
        )
        let technician = Technician(
            id: technicianID,
            name: isScreenshotFixture ? "Jordan Lee" : "UI Test Technician",
            contactInfo: GunnAireUITestIdentity.technicianEmail,
            supportedEquipmentTypes: isQualificationReviewFixture ? [.heatPump] : [],
            qualificationReviewedAt: isQualificationReviewFixture
                ? Calendar.current.date(byAdding: .year, value: -1, to: Date())
                : nil,
            qualificationReviewDueAt: isQualificationReviewFixture
                ? Calendar.current.date(byAdding: .day, value: -1, to: Date())
                : nil,
            qualificationReviewedByEmail: isQualificationReviewFixture
                ? AppAccess.primaryAdminEmail
                : nil
        )
        let catalogItem = Item(
            id: catalogItemID,
            quickBooksID: (isCatalogReconciliationFixture || isCatalogMappingConflictFixture) ? "QBO-UI-CATALOG-RECONCILE" : nil,
            quickBooksSyncStatus: isPricebookReviewFixture
                ? "needs_review"
                : (isCatalogReconciliationFixture ? "pending_update" : (isSyncRecoveryFixture ? "needs_attention" : nil)),
            quickBooksSyncDetail: isPricebookReviewFixture
                ? "Administrator pricebook review is required before QuickBooks publication."
                : (isCatalogReconciliationFixture
                    ? "Administrator-approved price and description changes are waiting for explicit QuickBooks publication."
                    : (isSyncRecoveryFixture ? "QuickBooks catalog publication failed and is ready to retry." : nil)),
            pricebookReviewStatus: isPricebookReviewFixture ? .needsReview : .approved,
            pricebookCreatedByEmail: isPricebookReviewFixture ? GunnAireUITestIdentity.technicianEmail : nil,
            name: "HVAC Diagnostic Service",
            itemType: .service,
            unitPrice: isCatalogReconciliationFixture ? 219 : 189,
            purchaseCost: 42,
            isTaxable: isPendingTaxFixture,
            itemDescription: isCatalogReconciliationFixture
                ? "Priority diagnostic visit and complete system evaluation"
                : "Diagnostic visit and system evaluation"
        )
        let duplicateCatalogMappingItem = Item(
            id: duplicateCatalogMappingItemID,
            quickBooksID: " QBO-UI-CATALOG-RECONCILE ",
            quickBooksSyncStatus: "synced",
            name: "After-Hours HVAC Diagnostic",
            itemType: .service,
            unitPrice: 269,
            purchaseCost: 42,
            itemDescription: "After-hours diagnostic visit and system evaluation"
        )
        let inventoryItem = Item(
            id: inventoryItemID,
            name: "45/5 Dual Run Capacitor",
            itemType: .nonInventory,
            unitPrice: 50,
            purchaseCost: 18.50,
            itemDescription: "Field replacement capacitor",
            sku: "CAP-45-5",
            preferredVendorName: "Johnstone Supply",
            preferredVendorQuickBooksID: "QBO-UI-JOHNSTONE",
            vendorPartNumber: "27W84",
            tracksInventory: true,
            reorderPoint: 1,
            defaultInventoryLocation: "Truck – UI Test Technician"
        )
        let servicePackageComponent = Item(
            id: servicePackageComponentItemID,
            quickBooksID: "QBO-UI-PACKAGE-FILTER",
            quickBooksSyncStatus: "synced",
            name: "Premium Pleated Filter",
            itemType: .nonInventory,
            unitPrice: 65,
            purchaseCost: 18,
            itemDescription: "Replacement filter included with the cooling tune-up",
            sku: "UI-MERV-11",
            preferredVendorName: "Johnstone Supply",
            preferredVendorQuickBooksID: "QBO-UI-JOHNSTONE",
            tracksInventory: true,
            reorderPoint: 1,
            defaultInventoryLocation: "Truck – UI Test Technician"
        )
        let servicePackage = Item(
            id: servicePackageItemID,
            quickBooksID: "QBO-UI-COOLING-TUNE-UP",
            quickBooksSyncStatus: "synced",
            name: "Cooling Tune-Up Package",
            itemType: .service,
            unitPrice: 329,
            purchaseCost: 60,
            itemDescription: "Flat-rate cooling maintenance with diagnostic labor and filter"
        )
        servicePackage.assemblyDefinition = CatalogAssemblyDefinition(
            revision: 1,
            presentation: .flatRate,
            components: [
                CatalogAssemblyComponentDefinition(itemID: catalogItem.id, quantity: 1),
                CatalogAssemblyComponentDefinition(itemID: servicePackageComponent.id, quantity: 1)
            ]
        )
        let serviceLocation = CustomerServiceLocation(
            id: serviceLocationID,
            customer: customer,
            name: isScreenshotFixture ? "Main Office" : "Primary Service Location",
            address: customer.address ?? "100 Test Air Way",
            contactName: isScreenshotFixture ? "Morgan Reed" : nil,
            contactPhone: customer.phone,
            accessNotes: isScreenshotFixture ? "Check in at the front desk before entering mechanical areas." : nil,
            isPrimary: true
        )
        let equipment = CustomerEquipment(
            id: equipmentID,
            customer: customer,
            serviceLocationID: serviceLocationID,
            equipmentType: .heatPump,
            name: isScreenshotFixture ? "Main Office Heat Pump" : "Test Heat Pump",
            manufacturer: isScreenshotFixture ? "Lennox" : "GunnAire Test",
            modelNumber: isScreenshotFixture ? "EL18XPV-036" : "UIT-100",
            serialNumber: isScreenshotFixture ? "DEMO-2408" : "UITEST100",
            location: isScreenshotFixture ? "Main Office" : "Test Location",
            installDate: Calendar.current.date(byAdding: .year, value: isEquipmentDecisionFixture ? -12 : -3, to: Date()),
            warrantyExpiration: Calendar.current.date(byAdding: .year, value: 7, to: Date()),
            filterSize: "20 x 25 x 1",
            notes: isScreenshotFixture ? "Variable-capacity heat pump with communicating controls." : nil
        )
        let fixtureNow = Date()
        let scheduledDate = isEquipmentDecisionFixture
            ? fixtureNow.addingTimeInterval(-60 * 60)
            : Calendar.current.date(
                bySettingHour: 9,
                minute: 0,
                second: 0,
                of: fixtureNow
            ) ?? fixtureNow
        let call = ServiceCall(
            id: serviceCallID,
            googleEventManagedByApp: true,
            eventTitle: isScreenshotFixture ? "Cooling system diagnostic" : "Collectible HVAC service",
            siteAddress: customer.address,
            serviceLocationID: serviceLocationID,
            equipmentName: isScreenshotFixture ? "Main Office Heat Pump" : "Test Heat Pump",
            equipmentManufacturer: isScreenshotFixture ? "Lennox" : "GunnAire Test",
            equipmentModel: isScreenshotFixture ? "EL18XPV-036" : "UIT-100",
            equipmentSerialNumber: isScreenshotFixture ? "DEMO-2408" : "UITEST100",
            customerEquipmentID: equipmentID,
            equipmentTypeRaw: isQualificationReviewFixture ? HVACEquipmentType.heatPump.rawValue : nil,
            type: isSerializedPurchaseOrderFixture ? .replacement : .service,
            scheduledDate: scheduledDate,
            assignedTechnician: technician,
            customer: customer,
            status: .invoiced,
            workCompletedChecklist: true,
            documentationChecklist: true,
            linkedEstimateID: (isPendingEstimateFixture || isSyncRecoveryFixture) ? estimateID : nil,
            linkedInvoiceID: invoiceID
        )
        let equipmentDecisionHistoryCall: ServiceCall? = isEquipmentDecisionFixture
            ? ServiceCall(
                id: equipmentDecisionHistoryCallID,
                googleEventManagedByApp: true,
                eventTitle: "Prior compressor diagnostic",
                siteAddress: customer.address,
                serviceLocationID: serviceLocationID,
                equipmentName: equipment.name,
                equipmentManufacturer: equipment.manufacturer,
                equipmentModel: equipment.modelNumber,
                equipmentSerialNumber: equipment.serialNumber,
                customerEquipmentID: equipment.id,
                equipmentTypeRaw: HVACEquipmentType.heatPump.rawValue,
                type: .service,
                scheduledDate: Calendar.current.date(byAdding: .day, value: -90, to: scheduledDate) ?? scheduledDate.addingTimeInterval(-90 * 86_400),
                assignedTechnician: technician,
                customer: customer,
                status: .completed,
                findingsSummary: "Intermittent compressor starting concern documented.",
                recommendedWorkSummary: "Monitor operation and review repair history at the next visit."
            )
            : nil
        let estimate = Estimate(
            id: estimateID,
            serviceCallID: isAcceptedStandaloneEstimateFixture ? nil : serviceCallID,
            serviceLocationID: serviceLocationID,
            siteAddress: customer.address,
            customer: customer,
            lineItemSummary: "Replace failed dual run capacitor and verify operation",
            catalogSnapshotJSON: CatalogLineItemSnapshot.encoded(from: [catalogItem]),
            amount: isSyncRecoveryFixture ? 189 : 425,
            status: isAcceptedStandaloneEstimateFixture ? "accepted" : "pending",
            customerApprovedByName: isAcceptedStandaloneEstimateFixture ? "UI Test Customer" : nil,
            customerApprovedAt: isAcceptedStandaloneEstimateFixture ? Date() : nil,
            customerApprovalMethodRaw: isAcceptedStandaloneEstimateFixture ? EstimateApprovalMethod.phoneVerbal.rawValue : nil,
            customerApprovalReference: isAcceptedStandaloneEstimateFixture ? "Approved during UI test call" : nil,
            customerApprovalRecordedByEmail: isAcceptedStandaloneEstimateFixture ? AppAccess.primaryAdminEmail : nil,
            notes: "Customer authorization required before repair."
        )
        let invoice = Invoice(
            id: invoiceID,
            serviceCallID: serviceCallID,
            serviceLocationID: serviceLocationID,
            siteAddress: customer.address,
            customer: customer,
            quickBooksID: isQuickBooksLinkedCollectionFixture ? "QBO-UI-INVOICE-189" : nil,
            quickBooksBalanceDue: isQuickBooksLinkedCollectionFixture ? 189 : nil,
            quickBooksSyncStatus: isSyncRecoveryFixture ? "needs_attention" : nil,
            quickBooksSyncDetail: isSyncRecoveryFixture ? "QuickBooks rejected the last invoice publication attempt." : nil,
            workType: .service,
            lineItemSummary: isInventoryFixture
                ? "HVAC Diagnostic Service - $189.00\n45/5 Dual Run Capacitor - $50.00"
                : "HVAC Diagnostic Service - $189.00",
            catalogSnapshotJSON: CatalogLineItemSnapshot.encoded(
                from: isInventoryFixture ? [catalogItem, inventoryItem] : [catalogItem]
            ),
            amount: isInventoryFixture ? 239 : 189,
            status: "unpaid",
            dueDate: Calendar.current.date(byAdding: .day, value: 7, to: scheduledDate)
        )
        let maintenanceDueDate = isScheduleAuthorizationFixture
            ? scheduledDate.addingTimeInterval(60 * 60)
            : ((isMaintenanceReportingFixture || isAgreementBillingFixture)
                ? Date()
                : (Calendar.current.date(byAdding: .day, value: 1, to: scheduledDate) ?? scheduledDate))
        let maintenanceAgreement = RecurringMaintenanceContract(
            id: maintenanceAgreementID,
            customer: customer,
            planName: "Comfort Care",
            schedulePattern: "every 6 months",
            nextDate: maintenanceDueDate,
            active: true,
            termEndsOn: Calendar.current.date(byAdding: .year, value: 1, to: maintenanceDueDate),
            pricePerVisit: 89,
            includedVisitsPerTerm: 2,
            coveredEquipmentIDs: [equipmentID]
        )
        let maintenanceCall = ServiceCall(
            id: maintenanceServiceCallID,
            googleEventManagedByApp: true,
            eventTitle: "Comfort Care maintenance",
            siteAddress: customer.address,
            serviceLocationID: serviceLocationID,
            equipmentName: equipment.name,
            equipmentManufacturer: equipment.manufacturer,
            equipmentModel: equipment.modelNumber,
            equipmentSerialNumber: equipment.serialNumber,
            customerEquipmentID: equipment.id,
            type: .maintenance,
            scheduledDate: maintenanceDueDate,
            duration: 90 * 60,
            assignedTechnician: technician,
            customer: customer,
            status: .scheduled,
            notes: "Scheduled from Comfort Care: every 6 months",
            maintenanceAgreementID: maintenanceAgreementID,
            maintenanceAgreementDueDate: maintenanceDueDate
        )
        if isAgreementBillingFixture {
            maintenanceAgreement.configureDraft(
                agreementPrice: 49,
                billingInterval: .monthly,
                billingCatalogItemID: catalogItemID,
                billingAnchorDate: Calendar.current.startOfDay(for: Date()),
                memberDiscountPercent: 10,
                autoRenews: true,
                termsSummary: "Two preventive-maintenance visits and a 10% member repair discount.",
                createdByEmail: AppAccess.primaryAdminEmail,
                sourceServiceCallID: nil,
                createdAt: Date().addingTimeInterval(-3_600)
            )
            maintenanceAgreement.markPendingApproval(
                offeredByEmail: AppAccess.primaryAdminEmail,
                offeredAt: Date().addingTimeInterval(-3_000)
            )
            try maintenanceAgreement.recordCustomerApproval(
                customerName: customer.name,
                method: .email,
                reference: "UI-AGREEMENT-BILLING-APPROVAL",
                signatureImageBase64: nil,
                recordedByEmail: AppAccess.primaryAdminEmail,
                approvedAt: Date().addingTimeInterval(-2_400)
            )
        }
        context.insert(customer)
        context.insert(technician)
        context.insert(catalogItem)
        if isCatalogMappingConflictFixture {
            context.insert(duplicateCatalogMappingItem)
        }
        if isInventoryFixture {
            context.insert(inventoryItem)
            context.insert(InventoryMovement(
                id: inventoryReceiptID,
                item: inventoryItem,
                type: .receive,
                quantity: isInventoryShortageFixture ? 0.5 : 3,
                destinationLocation: "Truck – UI Test Technician",
                notes: "UI test truck stock.",
                createdByEmail: GunnAireUITestIdentity.technicianEmail
            ))
            context.insert(InventoryMovement(
                id: inventoryReservationID,
                item: inventoryItem,
                type: .reserve,
                quantity: 1,
                sourceLocation: "Truck – UI Test Technician",
                serviceCallID: serviceCallID,
                notes: "Reserved for UI test job.",
                createdByEmail: GunnAireUITestIdentity.technicianEmail
            ))
        }
        if isServicePackageFixture || isMultiLinePurchaseOrderFixture {
            context.insert(servicePackageComponent)
        }
        if isServicePackageFixture {
            context.insert(servicePackage)
        }
        context.insert(equipment)
        context.insert(serviceLocation)
        context.insert(call)
        if isWarrantyClaimFixture {
            let evidence = ServiceDocumentAttachment(
                id: warrantyEvidenceID,
                customer: customer,
                serviceCallID: serviceCallID,
                customerEquipmentID: equipmentID,
                kind: .warrantyEvidence,
                displayName: "UI Warranty Failure Evidence.jpg",
                caption: "Failed capacitor and equipment data plate",
                localFilePath: "/tmp/ui-warranty-failure-evidence.jpg",
                contentType: "image/jpeg",
                fileSizeBytes: 1_024
            )
            context.insert(evidence)
            let claim = try EquipmentWarrantyClaimPolicy.request(
                id: warrantyClaimID,
                for: equipment,
                submission: EquipmentWarrantyClaimRequest(
                    manufacturer: equipment.manufacturer ?? "GunnAire Test",
                    distributorName: "Johnstone Supply",
                    equipmentSerialNumber: equipment.serialNumber ?? "UITEST100",
                    issueDescription: "Dual run capacitor failed measured capacitance and visual inspection.",
                    failedPartName: "45/5 Dual Run Capacitor",
                    failedPartNumber: "27W84",
                    failedPartSerialNumber: nil,
                    quantity: 1,
                    originatingServiceCallID: serviceCallID,
                    originalPurchaseOrderID: nil,
                    originalPurchaseOrderLineID: nil,
                    evidenceAttachmentIDs: [warrantyEvidenceID]
                ),
                actorEmail: GunnAireUITestIdentity.technicianEmail
            )
            equipment.upsertWarrantyClaim(claim)
        }
        if let equipmentDecisionHistoryCall {
            context.insert(equipmentDecisionHistoryCall)
        }
        if isScheduleAuthorizationFixture {
            context.insert(ServiceCall(
                id: unassignedScheduleServiceCallID,
                googleEventManagedByApp: true,
                eventTitle: "Unassigned confidential dispatch job",
                siteAddress: "299 Dispatch Only Drive",
                type: .estimate,
                scheduledDate: scheduledDate.addingTimeInterval(2 * 60 * 60),
                customer: customer,
                status: .scheduled
            ))
        }
        context.insert(invoice)
        if isTeamTimeReviewFixture {
            let clockOut = Date().addingTimeInterval(-60 * 60)
            context.insert(TimeEntry(
                id: submittedTimeEntryID,
                userEmail: GunnAireUITestIdentity.technicianEmail,
                clockIn: clockOut.addingTimeInterval(-95 * 60),
                clockOut: clockOut,
                serviceCall: call,
                notes: "Diagnosed and replaced the failed capacitor.",
                activity: .job,
                reviewStatus: .submitted
            ))
        }
        if isOpenJobTimeFixture {
            context.insert(TimeEntry(
                id: openJobTimeEntryID,
                userEmail: GunnAireUITestIdentity.technicianEmail,
                clockIn: Date().addingTimeInterval(-45 * 60),
                serviceCall: call,
                notes: "Open job timer for closeout UI verification.",
                activity: .job
            ))
        }
        if isPurchaseOrderDraftFixture {
            let lineItems: [PurchaseOrderLine]?
            if isSerializedPurchaseOrderFixture {
                lineItems = [
                    PurchaseOrderLine(
                        id: purchaseOrderPrimaryLineID,
                        catalogItemID: nil,
                        itemName: "Lennox Elite Heat Pump",
                        itemSKU: "HP-ELITE-3T",
                        vendorPartNumber: "ML17XP1-036",
                        quantity: 1,
                        unitCost: 3_100,
                        serialTrackingRequired: true
                    )
                ]
            } else if isMultiLinePurchaseOrderFixture {
                lineItems = [
                    PurchaseOrderLine(
                        id: purchaseOrderPrimaryLineID,
                        catalogItemID: inventoryItem.id,
                        itemName: inventoryItem.name,
                        itemSKU: inventoryItem.sku,
                        vendorPartNumber: inventoryItem.vendorPartNumber,
                        quantity: 2,
                        unitCost: 18.50
                    ),
                    PurchaseOrderLine(
                        id: purchaseOrderSecondaryLineID,
                        catalogItemID: servicePackageComponent.id,
                        itemName: servicePackageComponent.name,
                        itemSKU: servicePackageComponent.sku,
                        vendorPartNumber: servicePackageComponent.vendorPartNumber,
                        quantity: 1,
                        unitCost: 18
                    )
                ]
            } else {
                lineItems = nil
            }
            let primaryLine = lineItems?.first
            context.insert(PurchaseOrder(
                id: purchaseOrderID,
                number: "PO-UI-CONFIRM",
                vendorName: "Johnstone Supply",
                vendorQuickBooksID: "QBO-UI-JOHNSTONE",
                serviceCallID: serviceCallID,
                itemName: primaryLine?.itemName ?? inventoryItem.name,
                itemSKU: primaryLine?.itemSKU ?? inventoryItem.sku,
                vendorPartNumber: primaryLine?.vendorPartNumber ?? inventoryItem.vendorPartNumber,
                quantity: primaryLine?.quantity ?? 2,
                unitCost: primaryLine?.unitCost ?? 18.50,
                shippingCost: 4,
                status: .draft,
                notes: "No substitutions without approval.",
                createdByEmail: AppAccess.primaryAdminEmail,
                lineItems: lineItems
            ))
        }
        if isPendingEstimateFixture || isAcceptedStandaloneEstimateFixture || isSyncRecoveryFixture {
            context.insert(estimate)
        }
        context.insert(maintenanceAgreement)
        context.insert(maintenanceCall)

        if isCommunicationFixture {
            let deliveredAt = scheduledDate.addingTimeInterval(-15 * 60)
            context.insert(CustomerCommunication(
                id: communicationID,
                customer: customer,
                serviceCallID: serviceCallID,
                recipient: customer.email ?? "uitest@gunnaire.com",
                subject: "Your GunnAire appointment is confirmed",
                deliveryStatus: "sent",
                workflow: .appointmentConfirmation,
                actorEmail: AppAccess.primaryAdminEmail,
                consentSnapshot: CustomerCommunicationConsentSnapshot(customer: customer),
                deliveredAt: deliveredAt,
                providerMessageID: "gmail-ui-confirmation-27",
                backendCommunicationID: "shared-ui-confirmation-27",
                createdAt: deliveredAt
            ))
        }

        if isProjectMilestoneFixture {
            let projectItem = Item(
                id: projectCatalogItemID,
                quickBooksID: "QBO-UI-PROJECT",
                name: "Complete Heat Pump Replacement",
                itemType: .service,
                unitPrice: 18_500,
                purchaseCost: 10_250,
                itemDescription: "Equipment, installation, startup, commissioning, and customer handoff"
            )
            let projectCall = ServiceCall(
                id: projectServiceCallID,
                googleEventManagedByApp: true,
                eventTitle: "Approved heat pump replacement project",
                siteAddress: customer.address,
                serviceLocationID: serviceLocationID,
                equipmentName: equipment.name,
                equipmentManufacturer: equipment.manufacturer,
                equipmentModel: equipment.modelNumber,
                equipmentSerialNumber: equipment.serialNumber,
                customerEquipmentID: equipment.id,
                type: .install,
                scheduledDate: scheduledDate,
                duration: 8 * 60 * 60,
                assignedTechnician: technician,
                customer: customer,
                status: .scheduled,
                notes: "Approved replacement project with staged billing.",
                linkedEstimateID: projectEstimateID
            )
            let projectEstimate = Estimate(
                id: projectEstimateID,
                serviceCallID: projectServiceCallID,
                serviceLocationID: serviceLocationID,
                siteAddress: customer.address,
                scheduledServiceCallID: projectServiceCallID,
                customer: customer,
                lineItemSummary: "Complete Heat Pump Replacement - $18,500.00",
                catalogSnapshotJSON: CatalogLineItemSnapshot.encoded(from: [projectItem]),
                amount: 18_500,
                status: "accepted",
                customerApprovedByName: "UI Test Customer",
                customerApprovedAt: scheduledDate.addingTimeInterval(-3_600),
                customerApprovalMethodRaw: EstimateApprovalMethod.email.rawValue,
                customerApprovalReference: "UI-PROJECT-APPROVAL-18500",
                customerApprovalRecordedByEmail: AppAccess.primaryAdminEmail,
                notes: "Customer approved the replacement proposal and 30/50/20 billing schedule."
            )
            let projectDates = [
                scheduledDate,
                Calendar.current.date(byAdding: .day, value: 1, to: scheduledDate) ?? scheduledDate,
                Calendar.current.date(byAdding: .day, value: 2, to: scheduledDate) ?? scheduledDate
            ]
            let projectMilestones = [
                ProjectMilestone(
                    id: projectDepositMilestoneID,
                    projectServiceCallID: projectServiceCallID,
                    estimateID: projectEstimateID,
                    sequence: 0,
                    title: "Deposit & Equipment Reservation",
                    milestoneDescription: "Customer-approved deposit and equipment commitment.",
                    plannedDate: projectDates[0],
                    billingPercent: 30,
                    plannedAmount: 5_550,
                    billingTrigger: .customerApproval,
                    status: .readyForBilling,
                    createdByEmail: AppAccess.primaryAdminEmail
                ),
                ProjectMilestone(
                    id: projectInstallationMilestoneID,
                    projectServiceCallID: projectServiceCallID,
                    estimateID: projectEstimateID,
                    sequence: 1,
                    title: "Installation & Startup",
                    milestoneDescription: "Equipment installation, startup, and operating checks.",
                    plannedDate: projectDates[1],
                    billingPercent: 50,
                    plannedAmount: 9_250,
                    billingTrigger: .milestoneCompletion,
                    createdByEmail: AppAccess.primaryAdminEmail
                ),
                ProjectMilestone(
                    id: projectHandoffMilestoneID,
                    projectServiceCallID: projectServiceCallID,
                    estimateID: projectEstimateID,
                    sequence: 2,
                    title: "Commissioning & Customer Handoff",
                    milestoneDescription: "Final commissioning, documentation, and customer handoff.",
                    plannedDate: projectDates[2],
                    billingPercent: 20,
                    plannedAmount: 3_700,
                    billingTrigger: .milestoneCompletion,
                    createdByEmail: AppAccess.primaryAdminEmail
                )
            ]
            context.insert(projectItem)
            context.insert(projectCall)
            context.insert(projectEstimate)
            for milestone in projectMilestones { context.insert(milestone) }
        }

        if arguments.contains("-uiTestSeedCorrectiveLineage") {
            let sourceDate = Calendar.current.date(
                bySettingHour: 11,
                minute: 0,
                second: 0,
                of: Date()
            ) ?? Date()
            let followUpDate = Calendar.current.date(
                bySettingHour: 14,
                minute: 0,
                second: 0,
                of: Date()
            ) ?? Date()
            let source = ServiceCall(
                id: correctiveSourceCallID,
                googleEventManagedByApp: true,
                eventTitle: "Corrective source job",
                siteAddress: customer.address,
                equipmentName: "Test Heat Pump",
                equipmentSerialNumber: "UITEST100",
                type: .service,
                scheduledDate: sourceDate,
                assignedTechnician: technician,
                customer: customer,
                status: .completed,
                visitDisposition: .callback,
                visitDispositionNotes: "Original repair concern returned.",
                scheduledFollowUpServiceCallID: correctiveFollowUpCallID,
                correctiveWorkReason: .workmanship
            )
            let followUp = ServiceCall(
                id: correctiveFollowUpCallID,
                googleEventManagedByApp: true,
                eventTitle: "Corrective follow-up job",
                siteAddress: customer.address,
                equipmentName: "Test Heat Pump",
                equipmentSerialNumber: "UITEST100",
                type: .service,
                scheduledDate: followUpDate,
                assignedTechnician: technician,
                customer: customer,
                status: .scheduled,
                visitDisposition: .callback,
                originatingServiceCallID: correctiveSourceCallID,
                correctiveWorkReason: .workmanship
            )
            context.insert(source)
            context.insert(followUp)
        }
        try context.save()
    }
}
#endif

private struct StartupFailureView: View {
    let message: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.09, green: 0.12, blue: 0.18), Color(red: 0.04, green: 0.05, blue: 0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 110, height: 110)

                Text("Startup Issue")
                    .font(.title.bold())
                    .foregroundStyle(.white)

                Text(message)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(maxWidth: 380)

                Text("No data was changed. Once storage is available again, relaunch the app.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.68))
                    .frame(maxWidth: 380)
            }
            .padding(32)
        }
    }
}
