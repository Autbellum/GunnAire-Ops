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

    static func prepareIfRequested(in context: ModelContext) throws {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-disableCloudKitForTesting") else { return }

        let appUsers = try context.fetch(FetchDescriptor<AppUser>())
        for user in appUsers where user.id == standardUserID || user.email == GunnAireUITestIdentity.standardEmail {
            context.delete(user)
        }
        if arguments.contains("-uiTestAuthenticatedStandard") {
            context.insert(AppUser(id: standardUserID, email: GunnAireUITestIdentity.standardEmail, role: .standard))
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
        for call in calls where call.id == serviceCallID {
            context.delete(call)
        }
        let customers = try context.fetch(FetchDescriptor<Customer>())
        for customer in customers where customer.id == customerID {
            context.delete(customer)
        }
        try context.save()

        guard arguments.contains("-uiTestSeedCollectibleJob") else { return }

        let customer = Customer(
            id: customerID,
            name: "UI Test Collectible Customer",
            phone: "555-0100",
            email: "uitest@gunnaire.com",
            address: "100 Test Air Way"
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
            eventTitle: "Collectible HVAC service",
            siteAddress: customer.address,
            equipmentName: "Test Heat Pump",
            equipmentManufacturer: "GunnAire Test",
            equipmentModel: "UIT-100",
            equipmentSerialNumber: "UITEST100",
            type: .service,
            scheduledDate: scheduledDate,
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
            lineItemSummary: "HVAC diagnostic service",
            amount: 189,
            status: "unpaid"
        )
        context.insert(customer)
        context.insert(call)
        context.insert(invoice)
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
