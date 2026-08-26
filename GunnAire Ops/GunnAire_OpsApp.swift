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
            return .ready(try ModelContainer(for: schema, configurations: [modelConfiguration]))
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
