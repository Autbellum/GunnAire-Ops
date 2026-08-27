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
    private let startupState: StartupState

    init() {
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
            case .failed(let message):
                StartupFailureView(message: message)
            }
        }
    }

    private static func buildStartupState() -> StartupState {
        let schema = GunnAireModelSchema.schema
        let modelConfiguration = GunnAireCloudKit.modelConfiguration(for: schema)

        do {
            let modelContainer = try ModelContainer(for: schema, configurations: [modelConfiguration])
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

    static func prepareIfRequested(in context: ModelContext) throws {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-disableCloudKitForTesting") else { return }
        let isScreenshotFixture = arguments.contains("-appStoreScreenshotFixtures")
        let isInventoryShortageFixture = arguments.contains("-uiTestSeedInventoryShortage")
        let isInventoryFixture = arguments.contains("-uiTestSeedInventoryJob") || isInventoryShortageFixture
        let isPendingEstimateFixture = arguments.contains("-uiTestSeedPendingEstimate")
        let isAcceptedStandaloneEstimateFixture = arguments.contains("-uiTestSeedAcceptedStandaloneEstimate")
        let isPricebookReviewFixture = arguments.contains("-uiTestSeedPricebookReview")

        let appUsers = try context.fetch(FetchDescriptor<AppUser>())
        for user in appUsers where
            user.id == standardUserID ||
            user.id == technicianUserID ||
            user.email == GunnAireUITestIdentity.standardEmail ||
            user.email == GunnAireUITestIdentity.technicianEmail {
            context.delete(user)
        }
        if arguments.contains("-uiTestAuthenticatedStandard") {
            context.insert(AppUser(id: standardUserID, email: GunnAireUITestIdentity.standardEmail, role: .standard))
        }
        if arguments.contains("-uiTestAuthenticatedTechnician") {
            context.insert(AppUser(id: technicianUserID, email: GunnAireUITestIdentity.technicianEmail, role: .fieldTechnician))
        }

        let payments = try context.fetch(FetchDescriptor<Payment>())
        for payment in payments where payment.invoice.id == invoiceID {
            context.delete(payment)
        }
        let invoices = try context.fetch(FetchDescriptor<Invoice>())
        for invoice in invoices where invoice.id == invoiceID {
            context.delete(invoice)
        }
        let estimates = try context.fetch(FetchDescriptor<Estimate>())
        for estimate in estimates where estimate.id == estimateID {
            context.delete(estimate)
        }
        let calls = try context.fetch(FetchDescriptor<ServiceCall>())
        let fixtureCallIDs = Set(calls.compactMap { call in
            call.id == serviceCallID ||
            call.id == correctiveSourceCallID ||
            call.id == correctiveFollowUpCallID ||
            call.id == maintenanceServiceCallID ||
            call.linkedEstimateID == estimateID ? call.id : nil
        })
        for call in calls where fixtureCallIDs.contains(call.id) {
            context.delete(call)
        }
        let activities = try context.fetch(FetchDescriptor<ServiceCallActivity>())
        for activity in activities where fixtureCallIDs.contains(activity.serviceCallID) {
            context.delete(activity)
        }
        let maintenanceAgreements = try context.fetch(FetchDescriptor<RecurringMaintenanceContract>())
        for agreement in maintenanceAgreements where agreement.id == maintenanceAgreementID {
            context.delete(agreement)
        }
        let equipmentProfiles = try context.fetch(FetchDescriptor<CustomerEquipment>())
        for equipment in equipmentProfiles where equipment.id == equipmentID {
            context.delete(equipment)
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
        for order in purchaseOrders where order.serviceCallID == serviceCallID && (order.itemSKU == "CAP-45-5" || order.itemName == "45/5 Dual Run Capacitor") {
            context.delete(order)
        }
        let catalogItems = try context.fetch(FetchDescriptor<Item>())
        for item in catalogItems where item.id == catalogItemID || item.id == inventoryItemID || item.name == "UI Test Added Repair" {
            context.delete(item)
        }
        try context.save()

        guard arguments.contains("-uiTestSeedCollectibleJob") || isScreenshotFixture else { return }

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
            contactInfo: GunnAireUITestIdentity.technicianEmail
        )
        let catalogItem = Item(
            id: catalogItemID,
            quickBooksSyncStatus: isPricebookReviewFixture ? "needs_review" : nil,
            quickBooksSyncDetail: isPricebookReviewFixture ? "Administrator pricebook review is required before QuickBooks publication." : nil,
            pricebookReviewStatus: isPricebookReviewFixture ? .needsReview : .approved,
            pricebookCreatedByEmail: isPricebookReviewFixture ? GunnAireUITestIdentity.technicianEmail : nil,
            name: "HVAC Diagnostic Service",
            itemType: .service,
            unitPrice: 189,
            purchaseCost: 42,
            itemDescription: "Diagnostic visit and system evaluation"
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
        let equipment = CustomerEquipment(
            id: equipmentID,
            customer: customer,
            equipmentType: .heatPump,
            name: isScreenshotFixture ? "Main Office Heat Pump" : "Test Heat Pump",
            manufacturer: isScreenshotFixture ? "Lennox" : "GunnAire Test",
            modelNumber: isScreenshotFixture ? "EL18XPV-036" : "UIT-100",
            serialNumber: isScreenshotFixture ? "DEMO-2408" : "UITEST100",
            location: isScreenshotFixture ? "Main Office" : "Test Location",
            installDate: Calendar.current.date(byAdding: .year, value: -3, to: Date()),
            warrantyExpiration: Calendar.current.date(byAdding: .year, value: 7, to: Date()),
            filterSize: "20 x 25 x 1",
            notes: isScreenshotFixture ? "Variable-capacity heat pump with communicating controls." : nil
        )
        let scheduledDate = Calendar.current.date(
            bySettingHour: 9,
            minute: 0,
            second: 0,
            of: Date()
        ) ?? Date()
        let call = ServiceCall(
            id: serviceCallID,
            googleEventManagedByApp: true,
            eventTitle: isScreenshotFixture ? "Cooling system diagnostic" : "Collectible HVAC service",
            siteAddress: customer.address,
            equipmentName: isScreenshotFixture ? "Main Office Heat Pump" : "Test Heat Pump",
            equipmentManufacturer: isScreenshotFixture ? "Lennox" : "GunnAire Test",
            equipmentModel: isScreenshotFixture ? "EL18XPV-036" : "UIT-100",
            equipmentSerialNumber: isScreenshotFixture ? "DEMO-2408" : "UITEST100",
            customerEquipmentID: equipmentID,
            type: .service,
            scheduledDate: scheduledDate,
            assignedTechnician: technician,
            customer: customer,
            status: .invoiced,
            workCompletedChecklist: true,
            documentationChecklist: true,
            linkedEstimateID: isPendingEstimateFixture ? estimateID : nil,
            linkedInvoiceID: invoiceID
        )
        let estimate = Estimate(
            id: estimateID,
            serviceCallID: isAcceptedStandaloneEstimateFixture ? nil : serviceCallID,
            customer: customer,
            lineItemSummary: "Replace failed dual run capacitor and verify operation",
            amount: 425,
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
            customer: customer,
            workType: .service,
            lineItemSummary: isInventoryFixture
                ? "HVAC Diagnostic Service - $189.00\n45/5 Dual Run Capacitor - $50.00"
                : "HVAC Diagnostic Service - $189.00",
            catalogSnapshotJSON: CatalogLineItemSnapshot.encoded(
                from: isInventoryFixture ? [catalogItem, inventoryItem] : [catalogItem]
            ),
            amount: isInventoryFixture ? 239 : 189,
            status: "unpaid"
        )
        let maintenanceDueDate = Calendar.current.date(byAdding: .day, value: 1, to: scheduledDate) ?? scheduledDate
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
        context.insert(customer)
        context.insert(technician)
        context.insert(catalogItem)
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
        context.insert(equipment)
        context.insert(call)
        context.insert(invoice)
        if isPendingEstimateFixture || isAcceptedStandaloneEstimateFixture {
            context.insert(estimate)
        }
        context.insert(maintenanceAgreement)
        context.insert(maintenanceCall)

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
