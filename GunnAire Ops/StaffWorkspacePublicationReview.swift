import SwiftUI

enum StaffWorkspacePublicationReview {
    static func changedFields(_ conflict: StaffWorkspacePublicationConflict) -> [String] {
        Set(conflict.local?.fields.keys.map { $0 } ?? []).union(conflict.remote.fields.keys)
            .filter { conflict.local?.fields[$0] != conflict.remote.fields[$0] }.sorted()
    }
    static func label(_ field: String) -> String {
        let base = field.hasSuffix("JSON") ? String(field.dropLast(4)) : field
        return base.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
    }
    static func value(_ value: StaffWorkspaceValue?, field: String) -> String {
        switch value {
        case .text(let text):
            if text.isEmpty { return "Not set" }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if field.hasSuffix("JSON") || trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                return "Saved structured details. Review these in the original workspace before replacing this copy."
            }
            return text.count > 2000 ? String(text.prefix(2000)) + "… (continued in the original record)" : text
        case .number(let number): return number.formatted()
        case .integer(let number): return number.formatted()
        case .flag(let value): return value ? "Yes" : "No"
        case .date(let date): return date.formatted(date: .abbreviated, time: .shortened)
        case .identifier(let id): return "Saved record ending in " + id.uuidString.suffix(6)
        case .null: return "Not set"
        case nil: return "Not present"
        }
    }
    static func action(_ conflict: StaffWorkspacePublicationConflict) -> String {
        if conflict.deletion { return "Apply Saved Deletion" }
        return conflict.remote.deleted ? "Restore Server Copy" : "Use This Device's Version"
    }
}

/// Owner-only secondary review. Ordinary business screens never show transport
/// payloads, serialized billing details, account footers or sync diagnostics.
struct StaffWorkspacePublicationReviewView: View {
    @ObservedObject var source: StaffReplicaSourceCoordinator
    @State private var selected: StaffWorkspacePublicationConflict?
    var body: some View {
        List {
            Section {
                Text(source.message).accessibilityIdentifier("OwnerWorkspaceCopyStatus")
                Text("This is the administrator-only server copy of saved company records. It does not replace your live iCloud workspace, change QuickBooks, or grant staff access.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Check Again") { Task { await source.sync() } }.disabled(source.isRunning)
                if source.isRunning { ProgressView("Checking saved records…") }
            }
            if source.workspaceConflicts.isEmpty {
                Text("No owner-version conflicts are currently listed. Check Again to refresh the review.")
                    .foregroundStyle(.secondary)
            }
            ForEach(source.workspaceConflicts) { conflict in
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(conflict.title).font(.headline)
                        Text(StaffWorkspacePublicationReview.label(conflict.remote.kind) + " • " + conflict.remote.id.suffix(6))
                            .font(.caption).foregroundStyle(.secondary)
                        if conflict.deletion {
                            Text("This device saved a deletion, but the server has a different version.")
                        } else if conflict.remote.deleted {
                            Text("The server copy was removed. Restoring it requires your confirmation.")
                        } else { Text("This device and the server have different saved versions.") }
                    }
                    DisclosureGroup("Compare Saved Details") {
                        ForEach(StaffWorkspacePublicationReview.changedFields(conflict), id: \.self) { field in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(StaffWorkspacePublicationReview.label(field)).font(.subheadline.bold())
                                Text("This device: " + StaffWorkspacePublicationReview.value(conflict.local?.fields[field], field: field))
                                Text("Server copy: " + StaffWorkspacePublicationReview.value(conflict.remote.fields[field], field: field))
                                    .foregroundStyle(.secondary)
                            }.accessibilityElement(children: .combine).textSelection(.enabled)
                        }
                    }
                    Button(StaffWorkspacePublicationReview.action(conflict)) { selected = conflict }
                        .disabled(source.isRunning)
                }
            }
        }
        .navigationTitle("Company Workspace Review")
        .alert("Update the server copy?", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let selected {
                Button(StaffWorkspacePublicationReview.action(selected), role: selected.deletion ? .destructive : nil) {
                    let decision = selected; self.selected = nil
                    Task { await source.approveWorkspace(decision) }
                }
                Button("Cancel", role: .cancel) { self.selected = nil }
            }
        } message: {
            Text("Apply the entire saved version you reviewed, including its structured details. Newer local or server edits require review again. Your live iCloud records and QuickBooks are not changed.")
        }
    }
}
