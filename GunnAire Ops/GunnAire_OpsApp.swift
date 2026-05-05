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

@main
struct GunnAire_OpsApp: App {
    @AppStorage("hasAuthenticatedUser") private var hasAuthenticatedUser = false
    @State private var testingBypassActive = false

    // Define schema with all model types
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
            ServiceCall.self,
            Customer.self,
            Technician.self,
            RecurringMaintenanceContract.self,
            Invoice.self,
            Estimate.self,
            Payment.self,
            TimeEntry.self,
            AppUser.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    init() {
        // Placeholder for launch-time setup
        // e.g., onboarding flow, first-run logic, initial data import
    }

    var body: some Scene {
        WindowGroup {
            if hasAuthenticatedUser || testingBypassActive {
                ContentView() // Main UI entry point
            } else {
                LoginView(
                    hasAuthenticatedUser: $hasAuthenticatedUser,
                    testingBypassActive: $testingBypassActive
                )
            }
        }
        .modelContainer(sharedModelContainer)
    }
}
