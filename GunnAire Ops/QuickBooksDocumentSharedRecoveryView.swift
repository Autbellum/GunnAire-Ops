import SwiftUI
import SwiftData

struct QBODocumentSharedRecoveryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: QBODocumentSharedRecovery
    let restored: (QBODocumentCapture) -> Void
    @State private var selected: QBODocumentUploadRecord?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Original files retained for this business's QuickBooks company. Files download only when you choose Restore.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if model.loaded && model.rows.isEmpty {
                        Text("No saved files on this page.").foregroundStyle(.secondary)
                    }
                    ForEach(model.rows) { row in
                        Button { selected = row; message = nil } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.file.filename).foregroundStyle(.primary)
                                Text(row.status).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("SharedOriginal-\(row.id.uuidString)")
                    }
                }
                Section {
                    HStack {
                        Button("Previous", systemImage: "chevron.left") { load(.previous) }
                            .disabled(!model.hasPrevious || model.working)
                        Spacer()
                        Text("Page \(model.pageNumber)").foregroundStyle(.secondary)
                        Spacer()
                        Button("Next", systemImage: "chevron.right") { load(.next) }
                            .disabled(model.nextCursor == nil || model.working)
                    }
                    Button("Refresh", systemImage: "arrow.clockwise") { load(.refresh) }.disabled(model.working)
                }
                feedback
            }
            .navigationTitle("Business Files")
            .navigationDestination(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil; message = nil } })) {
                if let row = selected { detail(row) }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .foregroundColor(.primary)
        .task { if !model.loaded { load(.refresh) } }
    }

    @ViewBuilder private var feedback: some View {
        if model.working { ProgressView("Checking original files…") }
        if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
    }

    private func detail(_ row: QBODocumentUploadRecord) -> some View {
        Form {
            Section {
                Text(row.file.filename).font(.headline)
                Text(row.status).foregroundStyle(.secondary).accessibilityIdentifier("SharedOriginalStatus")
                Text(ByteCountFormatter.string(fromByteCount: Int64(row.file.size), countStyle: .file))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !row.targets.isEmpty {
                DisclosureGroup("Original Destination") {
                    ForEach(row.targets, id: \.self) { target in LabeledContent(target.type, value: target.id) }
                    if row.jobDocument != nil { Text("The original job and customer links are preserved.").font(.footnote) }
                }
            }
            Section {
                Button("Restore on This Device", systemImage: "icloud.and.arrow.down") { restore(row) }
                    .accessibilityIdentifier("SharedOriginalRestore")
                if row.state != .cancelled {
                    Button("Check Original Upload", systemImage: "arrow.clockwise") { check(row) }
                        .accessibilityIdentifier("SharedOriginalCheck")
                }
            }
            .disabled(model.working)
            Section {
                Text("Restore keeps an encrypted original for offline recovery and export. It does not send another copy to QuickBooks or create a missing job record.")
                    .font(.footnote).foregroundStyle(.secondary)
                feedback
            }
        }
        .navigationTitle("Original File")
    }

    private func load(_ direction: QBODocumentSharedRecovery.Page) {
        guard !model.working else { return }
        message = nil
        Task { @MainActor in
            do { try await model.load(direction) }
            catch { message = QBODocumentNativeWorkflow.message(error) }
        }
    }
    private func check(_ row: QBODocumentUploadRecord) {
        message = nil
        Task { @MainActor in
            do { selected = try await model.check(row) }
            catch { message = QBODocumentNativeWorkflow.message(error) }
        }
    }
    private func restore(_ row: QBODocumentUploadRecord) {
        message = nil
        Task { @MainActor in
            do {
                var saved = try await model.restore(row)
                // Missing/pending local records leave the original attention
                // item intact. The parent detail owns subsequent reconciliation.
                if saved.needsLocalApplication, let applied = try? model.apply(saved, context: context) { saved = applied }
                try model.access.check()
                restored(saved); dismiss()
            } catch { message = QBODocumentNativeWorkflow.message(error) }
        }
    }
}
