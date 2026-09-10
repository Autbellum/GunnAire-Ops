import SwiftUI
import Combine

struct StaffWorkspaceFieldEditorView: View {
    let title: String
    let field: String
    @StateObject private var editor: StaffWorkspaceFieldEditorController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var discarding = false
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    init(hosted: StaffWorkspaceOperationalHostedStore, row: StaffWorkspaceOperationalProjectionRecord, field: String) {
        title = StaffWorkspaceOperationalDetail.summary(for: row).title
        self.field = field
        _editor = .init(wrappedValue: StaffWorkspaceFieldEditorController(dependencies: .live(
            hosted: hosted, kind: row.kind, recordID: row.recordID, revision: row.revision, field: field)))
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
                        if schema.nullable && (schema.type == .date || schema.type == .flag) {
                            Toggle("Not set", isOn: $editor.input.isNull)
                        }
                        if !editor.input.isNull || [.text, .integer, .number].contains(schema.type) { input(schema) }
                        if schema.nullable && !editor.input.isNull { Button("Clear Value") { editor.clearValue() } }
                        Button("Save on Device and Send") { Task { await editor.save() } }
                            .disabled(!editor.canSave)
                            .accessibilityIdentifier("StaffFieldEditorSave")
                        Text("Only this field is submitted. Office review is separate from saving it here.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if editor.hasUnsavedChanges && !editor.canSave && !editor.isRunning {
                            Text("Enter a valid new value. Keep notes short enough to send as one finding.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }.disabled(!editor.available || editor.isRunning)
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
                    Button("Close") { if editor.hasUnsavedChanges { discarding = true } else { dismiss() } }
                }
            }
        }
        .interactiveDismissDisabled(editor.hasUnsavedChanges)
        .alert("Discard unsaved changes?", isPresented: $discarding) {
            Button("Discard Unsaved Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        } message: { Text("Only text or values you have not saved will be discarded. Saved submissions remain on this device.") }
        .task { editor.open() }
        .onReceive(timer) { _ in editor.checkLifetime() }
        .onChange(of: CloudKitStaffSetupStamp.current) { _, _ in editor.checkLifetime() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { editor.checkLifetime() } }
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
        case .flag: Toggle(StaffWorkspacePublicationReview.label(field), isOn: $editor.input.flag)
        case .date: DatePicker("Date and time", selection: $editor.input.date, displayedComponents: [.date, .hourAndMinute])
        case .integer, .number: TextField("Value", text: Binding(get: { editor.input.text }, set: editor.setText)).autocorrectionDisabled()
        case .identifier: Text("Use the related-record workflow to change this field.")
        }
    }
}
