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
            logger.error("Primary SwiftData store load failed: \(error.localizedDescription, privacy: .public)")
            resetKnownStoreArtifacts()
            do {
                return try ModelContainer(for: schema, configurations: [modelConfiguration])
            } catch {
                logger.error("Persistent SwiftData retry failed: \(error.localizedDescription, privacy: .public)")
                do {
                    logger.notice("Falling back to in-memory SwiftData store for this launch.")
                    let inMemoryConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                    return try ModelContainer(for: schema, configurations: [inMemoryConfiguration])
                } catch {
                    logger.fault("In-memory SwiftData fallback failed: \(error.localizedDescription, privacy: .public)")
                    fatalError("Could not create any ModelContainer: \(error)")
                }
            }
        }
    }()

    init() {
        Task { @MainActor in
            GunnAireAppShortcuts.updateAppShortcutParameters()
        }
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
        .modelContainer(sharedModelContainer)
    }

    private static func resetKnownStoreArtifacts() {
        let fileManager = FileManager.default
        let roots = [
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
        ]
        .compactMap { $0 }

        let candidateNames = [
            "default.store",
            "default.store-shm",
            "default.store-wal",
            "GunnAireOps.store",
            "GunnAireOps.store-shm",
            "GunnAireOps.store-wal"
        ]

        for root in roots {
            for name in candidateNames {
                let url = root.appendingPathComponent(name)
                guard fileManager.fileExists(atPath: url.path) else { continue }
                do {
                    try fileManager.removeItem(at: url)
                    logger.notice("Removed SwiftData store artifact at \(url.path, privacy: .public)")
                } catch {
                    logger.error("Failed removing SwiftData store artifact at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
