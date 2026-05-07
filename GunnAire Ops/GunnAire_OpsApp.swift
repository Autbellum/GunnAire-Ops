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
            return .ready(try ModelContainer(for: schema, configurations: [modelConfiguration]))
        } catch {
            logger.error("Primary SwiftData store load failed: \(error.localizedDescription, privacy: .public)")
            resetKnownStoreArtifacts()
            do {
                return .ready(try ModelContainer(for: schema, configurations: [modelConfiguration]))
            } catch {
                logger.error("Persistent SwiftData retry failed: \(error.localizedDescription, privacy: .public)")
                do {
                    logger.notice("Falling back to in-memory SwiftData store for this launch.")
                    let inMemoryConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                    return .ready(try ModelContainer(for: schema, configurations: [inMemoryConfiguration]))
                } catch {
                    logger.fault("In-memory SwiftData fallback failed: \(error.localizedDescription, privacy: .public)")
                    return .failed(
                        "The app could not start its local data store. Restart the app, then free device storage or reinstall if the problem continues."
                    )
                }
            }
        }
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

    private enum StartupState {
        case ready(ModelContainer)
        case failed(String)
    }
}

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
