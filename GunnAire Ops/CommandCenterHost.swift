import SwiftUI

/// Mounts Command Center only when CloudKit is not actively importing records.
///
/// Every import merge invalidates the dashboard's 23 root queries and re-runs its
/// body. On the owner's iPad with his real data that body took 17 to 26 seconds,
/// so a catch-up import (after an install, a store reset, or a long time offline)
/// pinned the main thread for minutes and iOS's watchdog killed the app. While an
/// import is running this shows a light placeholder with no queries at all, so
/// each merge costs nothing to draw and the import finishes quickly; the real
/// dashboard mounts the moment the import ends.
///
/// Two escape hatches guard against a missed "import finished" event: the owner
/// can open the dashboard anyway, and the placeholder gives up on its own after
/// `automaticReleaseAfter`.
struct CommandCenterHost: View {
    @Binding var showingCommandPalette: Bool
    @EnvironmentObject private var cloudKitAttention: GunnAireCloudKitAttentionMonitor
    @State private var openedDuringImport = false
    @State private var releasedAutomatically = false

    /// Long enough for a real catch-up import, short enough that a stuck flag
    /// never hides the dashboard for a working day.
    static let automaticReleaseAfter: Duration = .seconds(180)

    var body: some View {
        if cloudKitAttention.isImportingRecords && !openedDuringImport && !releasedAutomatically {
            CommandCenterSyncingPlaceholder(
                openAnyway: { openedDuringImport = true }
            )
            .task {
                try? await Task.sleep(for: Self.automaticReleaseAfter)
                guard !Task.isCancelled else { return }
                releasedAutomatically = true
            }
        } else {
            OperationsDashboardView(showingCommandPalette: $showingCommandPalette)
                .onChange(of: cloudKitAttention.isImportingRecords) { _, importing in
                    // A finished import resets the hatches so the next catch-up
                    // import is gated again.
                    if !importing {
                        openedDuringImport = false
                        releasedAutomatically = false
                    }
                }
        }
    }
}

/// Deliberately trivial: no queries, no environment reads beyond the button.
struct CommandCenterSyncingPlaceholder: View {
    let openAnyway: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Receiving company updates")
                .font(.title3.weight(.semibold))
            Text("Command Center will open as soon as the latest schedule, invoice, and job changes have arrived. Opening it now is allowed, but the screen will pause while updates keep coming in.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button("Open Command Center anyway", action: openAnyway)
                .buttonStyle(.bordered)
                .tint(Color.brandGold)
                .accessibilityIdentifier("CommandCenterOpenDuringImportButton")
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Command Center")
        .accessibilityIdentifier("CommandCenterSyncingPlaceholder")
    }
}
