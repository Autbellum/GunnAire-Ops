import SwiftUI
import Combine

struct StaffWorkspaceFieldEditorView: View {
    let title: String
    let field: String
    @StateObject private var editor: StaffWorkspaceFieldEditorController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var discarding = false
    @State private var closingUnverified = false
    @State private var reviewing = false
    @State private var reviewSnapshot: StaffWorkspaceFieldEditorSnapshot?
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    init(title: String, field: String, editor: StaffWorkspaceFieldEditorController) {
        self.title = title
        self.field = field
        _editor = .init(wrappedValue: editor)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(title).font(.headline)
                    Text(editor.message).font(.subheadline).foregroundStyle(.secondary)
                    if editor.isRunning { ProgressView("Sending saved update…") }
                }
                if editor.isEditing, let schema = editor.schema {
                    Section(StaffWorkspacePublicationReview.label(field)) {
                        Text(editor.draftMessage).font(.footnote).foregroundStyle(.secondary)
                        if schema.nullable && (schema.type == .date || schema.type == .flag) {
                            Toggle("Not set", isOn: Binding(get: { editor.input.isNull }, set: editor.setNull))
                        }
                        if !editor.input.isNull || [.text, .integer, .number].contains(schema.type) { input(schema) }
                        if schema.nullable && !editor.input.isNull { Button("Clear Value") { editor.clearValue() } }
                        if editor.hasUnprotectedChanges {
                            Button("Retry Draft Save") { editor.persistDraft() }
                        }
                        Button("Submit for Office Review") { Task { await editor.save() } }
                            .disabled(!editor.canSave)
                            .accessibilityIdentifier("StaffFieldEditorSave")
                        Text("Drafts stay on this device. Submitting sends only this field for office review.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if editor.hasUnsavedChanges && !editor.canSave && !editor.isRunning && !editor.needsReview {
                            Text("Enter a valid new value. Keep notes short enough to send as one finding.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }.disabled(!editor.available || editor.isRunning)
                    if editor.needsReview {
                        Section("Review changed record") {
                            Button("Refresh Shared Record") { editor.checkLifetime(forceRefresh: true) }
                                .disabled(!editor.available || editor.isRunning)
                            if let previous = editor.snapshot, let current = editor.currentSnapshot {
                                LabeledContent("Original field", value: StaffWorkspacePublicationReview.value(previous.candidate.currentValue, field: field))
                                LabeledContent("Current field", value: StaffWorkspacePublicationReview.value(current.candidate.currentValue, field: field))
                                Button("Use Draft with Current Record") { reviewSnapshot = current; reviewing = true }
                                    .disabled(!editor.available || editor.isRunning)
                            }
                            Text("Your draft was kept with its original record version. Review before submitting it against the updated record.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Button("Discard Draft", role: .destructive) { discarding = true }
                        .disabled(!editor.available || editor.isRunning)
                }
                if !editor.saved.isEmpty {
                    Section("Saved updates") {
                        ForEach(editor.visibleSaved, id: \.request.commandID) { original in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(StaffWorkspacePublicationReview.value(original.request.value, field: field))
                                    .textSelection(.enabled)
                                Text(original.state == "recorded" ? "Submitted · office review pending or completed" : "Saved on device · not yet confirmed by office")
                                    .font(.caption).foregroundStyle(.secondary)
                                if original.state == "pending" {
                                    Button("Retry Saved Update") { Task { await editor.retry(original) } }
                                        .disabled(!editor.available || editor.isRunning)
                                }
                            }.padding(.vertical, 4)
                        }
                        if !editor.isEditing && !editor.saved.contains(where: { $0.state == "pending" }) {
                            Button("Create Another Update") { editor.newUpdate() }.disabled(!editor.available || editor.isRunning)
                        }
                    }
                }
                Section {
                    Text("Check Submitted Updates in the staff workspace for the office outcome. This device does not replace office records or change QuickBooks directly.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(StaffWorkspacePublicationReview.label(field))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(editor.hasUnsavedChanges && !editor.hasUnprotectedChanges ? "Keep Draft and Close" : "Close") {
                        if editor.hasUnprotectedChanges { closingUnverified = true } else { dismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(editor.hasUnprotectedChanges)
        .alert("Discard this draft?", isPresented: $discarding) {
            Button("Discard Draft", role: .destructive) { if editor.discardDraft() { dismiss() } }
            Button("Keep Editing", role: .cancel) {}
        } message: { Text("This unfinished draft will be discarded. Already submitted updates are unchanged.") }
        .alert("Latest changes are not saved", isPresented: $closingUnverified) {
            Button("Keep Editing", role: .cancel) {}
            Button("Close Without Latest Changes", role: .destructive) { dismiss() }
        } message: { Text("Closing may lose your latest input. Any previously verified draft will remain on this device.") }
        .alert("Use draft with this record?", isPresented: $reviewing) {
            Button("Use Draft") {
                if let reviewSnapshot { editor.useDraftWithCurrentRecord(reviewed: reviewSnapshot) }
            }
            Button("Keep Reviewing", role: .cancel) {}
        } message: { Text("This creates a new local intent against the displayed current record. It does not submit or change the office record yet.") }
        .task { editor.open() }
        .onReceive(timer) { _ in editor.checkLifetime() }
        .onChange(of: CloudKitStaffSetupStamp.current) { _, _ in editor.checkLifetime() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { editor.checkLifetime(forceRefresh: true) } else { editor.persistDraft() } }
        .onDisappear { editor.invalidate() }
        .accessibilityIdentifier("StaffFieldEditor")
    }

    @ViewBuilder private func input(_ schema: StaffWorkspaceFieldSchema) -> some View {
        switch schema.type {
        case .text:
            if let choices = schema.enumeration {
                Picker("Value", selection: Binding(get: { editor.input.text }, set: editor.setText)) {
                    if editor.input.isNull { Text("Choose a value").tag("") }
                    ForEach(choices, id: \.self) { Text($0).tag($0) }
                }
            } else {
                TextField("Your finding", text: Binding(get: { editor.input.text }, set: editor.setText), axis: .vertical)
                    .lineLimit(4...12).accessibilityLabel(StaffWorkspacePublicationReview.label(field))
            }
        case .flag: Toggle(StaffWorkspacePublicationReview.label(field), isOn: Binding(get: { editor.input.flag }, set: editor.setFlag))
        case .date: DatePicker("Date and time", selection: Binding(get: { editor.input.date }, set: editor.setDate), displayedComponents: [.date, .hourAndMinute])
        case .integer, .number: TextField("Value", text: Binding(get: { editor.input.text }, set: editor.setText)).autocorrectionDisabled()
        case .identifier: Text("Use the related-record workflow to change this field.")
        }
    }
}
