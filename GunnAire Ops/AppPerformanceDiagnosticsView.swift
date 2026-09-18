import SwiftUI

/// Shows what the app has recorded about its own speed and stability, so a
/// report of "it is slow and it crashes" can be answered with dates, durations
/// and the screen it happened on.
struct AppPerformanceDiagnosticsView: View {
    @ObservedObject private var diagnostics = AppPerformanceDiagnostics.shared
    @State private var showingClearConfirmation = false

    var body: some View {
        List {
            Section("This Launch") {
                if let seconds = diagnostics.lastLaunchSeconds {
                    LabeledContent("Time to first screen", value: String(format: "%.1f seconds", seconds))
                } else {
                    Text("Still measuring.")
                        .foregroundStyle(.secondary)
                }
                if let summary = diagnostics.recentLaunchSummary {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if diagnostics.faults.isEmpty {
                Section("Problems") {
                    Text("Nothing recorded yet. Freezes are logged the moment they happen. Crashes and hangs arrive from Apple once a day, so a crash today usually appears tomorrow.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Problems") {
                    ForEach(diagnostics.faults) { event in
                        AppPerformanceEventRow(event: event)
                    }
                }
            }

            Section {
                ShareLink(item: diagnostics.exportText()) {
                    Label("Share this record", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    Label("Clear the record", systemImage: "trash")
                }
            } footer: {
                Text("Kept on this iPad only. Nothing here is sent anywhere on its own.")
            }
        }
        .navigationTitle("App Performance")
        .confirmationDialog(
            "Clear everything recorded about app performance?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) { diagnostics.removeAll() }
            Button("Keep", role: .cancel) { }
        }
    }
}

private struct AppPerformanceEventRow: View {
    let event: AppPerformanceEvent
    @State private var showingDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(event.kind.label)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(event.occurredAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(event.headline)
                .font(.body)
            if !event.detail.isEmpty {
                Button(showingDetail ? "Hide details" : "Show details") {
                    showingDetail.toggle()
                }
                .font(.caption)
                if showingDetail {
                    Text(event.detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Text("App version \(event.appVersion)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch event.kind {
        case .crash: return "exclamationmark.octagon.fill"
        case .hang, .stall: return "hourglass"
        case .slowLaunch: return "clock.badge.exclamationmark"
        case .cpuException: return "cpu"
        case .diskWriteException: return "internaldrive"
        case .launch: return "bolt"
        }
    }

    private var tint: Color {
        switch event.kind {
        case .crash: return .red
        case .hang, .stall, .slowLaunch: return .orange
        case .cpuException, .diskWriteException: return .yellow
        case .launch: return .secondary
        }
    }
}

/// The entry point placed in Sync & Integrations, where the other
/// connection-health readouts already live.
struct AppPerformanceDiagnosticsSection: View {
    @ObservedObject private var diagnostics = AppPerformanceDiagnostics.shared

    var body: some View {
        Section("App Performance") {
            NavigationLink {
                AppPerformanceDiagnosticsView()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Speed and stability record")
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(faultCount > 0 ? .orange : .secondary)
                }
            }
        }
    }

    private var faultCount: Int { diagnostics.faults.count }

    private var summary: String {
        var parts: [String] = []
        if let seconds = diagnostics.lastLaunchSeconds {
            parts.append(String(format: "Launched in %.1fs", seconds))
        }
        parts.append(faultCount == 0 ? "No problems recorded" : "\(faultCount) recorded")
        return parts.joined(separator: " · ")
    }
}
