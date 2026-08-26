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

    static func prepareIfRequested(in context: ModelContext) throws {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-disableCloudKitForTesting") else { return }
        let isScreenshotFixture = arguments.contains("-appStoreScreenshotFixtures")

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
        let calls = try context.fetch(FetchDescriptor<ServiceCall>())
        for call in calls where call.id == serviceCallID || call.id == correctiveSourceCallID || call.id == correctiveFollowUpCallID {
            context.delete(call)
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
        let catalogItems = try context.fetch(FetchDescriptor<Item>())
        for item in catalogItems where item.id == catalogItemID || item.name == "UI Test Added Repair" {
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
            name: "HVAC Diagnostic Service",
            itemType: .service,
            unitPrice: 189,
            purchaseCost: 42,
            itemDescription: "Diagnostic visit and system evaluation"
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
            linkedInvoiceID: invoiceID
        )
        let invoice = Invoice(
            id: invoiceID,
            serviceCallID: serviceCallID,
            customer: customer,
            workType: .service,
            lineItemSummary: "HVAC Diagnostic Service - $189.00",
            catalogSnapshotJSON: CatalogLineItemSnapshot.encoded(from: [catalogItem]),
            amount: 189,
            status: "unpaid"
        )
        context.insert(customer)
        context.insert(technician)
        context.insert(catalogItem)
        context.insert(equipment)
        context.insert(call)
        context.insert(invoice)

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
