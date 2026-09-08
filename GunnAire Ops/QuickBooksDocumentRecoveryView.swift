import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct QBODocumentExport: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw QBODocumentError.file }
        data = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { .init(regularFileWithContents: data) }
}

struct QBODocumentRecoverySection: View {
    @Environment(\.modelContext) private var context
    @ObservedObject private var workspace = CompanyWorkspaceAccessController.shared
    @Query private var users: [AppUser]
    @State private var rows: [QBODocumentCapture] = []
    @State private var selected: QBODocumentCapture?
    @State private var message: String?
    @State private var working = false
    @State private var export: QBODocumentExport?
    @State private var showingExport = false
    @State private var confirmingCancel = false
    private struct SharedBrowser: Identifiable { let id = UUID(); let model: QBODocumentSharedRecovery }
    @State private var sharedBrowser: SharedBrowser?
    @State private var restoredRow: QBODocumentCapture?
    private let dependencies: QBODocumentNativeWorkflow.Dependencies
    private var store: QBODocumentCaptureStore { dependencies.store }

    init(dependencies: QBODocumentNativeWorkflow.Dependencies? = nil) {
        self.dependencies = dependencies ?? .live
    }

    private var allowed: Bool {
        AppAccess.isAdmin(email: AppIdentity.currentEmail, users: users) && (try? dependencies.owner(context)) != nil
    }
    private var pending: [QBODocumentCapture] { rows.filter(\.needsAttention) }
    private var hasLegacyQueue: Bool { UserDefaults.standard.data(forKey: "ReceiptsBillsPendingUploads.v1") != nil }

    var body: some View {
        // A Section is distributed across Form rows. Own the presentation on
        // one concrete container so opening a row cannot dismiss its own sheet.
        VStack(alignment: .leading, spacing: 16) {
            Text("File Recovery").font(.headline)
            if allowed {
                if pending.isEmpty {
                    Label("No uploads need attention", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pending) { row in rowButton(row) }
                }
                let completed = rows.filter { !$0.needsAttention }
                if !completed.isEmpty {
                    DisclosureGroup("Recent Uploads") {
                        ForEach(completed.prefix(30)) { row in rowButton(row) }
                    }
                }
                Button("Refresh Saved Uploads", systemImage: "arrow.clockwise") { load() }
                    .disabled(working)
                Button("Files from Other Devices", systemImage: "icloud") { browseShared() }
                    .disabled(working).accessibilityIdentifier("BrowseSharedOriginalFiles")
                if hasLegacyQueue {
                    Text("Older upload records on this device need review in the original QuickBooks account. Their files have not been removed, and they will not be retried automatically.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("LegacyUploadReviewNotice")
                }
            } else {
                Text("Verify administrator access to this business to review saved files.")
                    .foregroundStyle(.secondary)
            }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundColor(.primary)
        .buttonStyle(.borderless)
        .task(id: workspace.generation) { closePrivateDetail(); load() }
        .onChange(of: allowed) { _, _ in closePrivateDetail(); load() }
        .sheet(item: $selected) { row in detail(row) }
        .sheet(item: $sharedBrowser, onDismiss: {
            load()
            if let row = restoredRow, (try? verify(row)) != nil { selected = row }
            restoredRow = nil
        }) { browser in
            QBODocumentSharedRecoveryView(model: browser.model) { row in
                guard sharedBrowser?.id == browser.id else { return }
                restoredRow = row
            }
        }
    }

    private func rowButton(_ row: QBODocumentCapture) -> some View {
        Button { selected = row; message = nil } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.file.filename).foregroundStyle(.primary)
                Text(row.status).font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("OriginalUpload-\(row.id.uuidString)")
    }

    private func detail(_ row: QBODocumentCapture) -> some View {
        NavigationStack {
            Form {
                if allowed {
                    Section {
                        Text(row.file.filename).font(.headline).accessibilityIdentifier("OriginalUploadFilename")
                        Text(row.status).foregroundStyle(.secondary)
                            .accessibilityIdentifier("OriginalUploadStatus")
                        Text(ByteCountFormatter.string(fromByteCount: Int64(row.file.size), countStyle: .file))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if !row.targets.isEmpty {
                        DisclosureGroup("Original Destination") {
                            ForEach(row.targets, id: \.self) { target in
                                LabeledContent(target.type, value: target.id)
                            }
                            if row.jobDocument != nil { Text("This file remains linked to its original job and customer.").font(.footnote) }
                        }
                    }
                    Section {
                        if row.needsLocalApplication {
                            Button("Finish Local Link", systemImage: "link") { applyLocal(row) }
                                .accessibilityIdentifier("OriginalUploadApply")
                        }
                        if !row.cancelledLocally && row.server?.state != .cancelled {
                            if row.connectionRevision != nil || row.server != nil {
                                Button("Check Original Upload", systemImage: "arrow.clockwise") { run(row, action: .recover) }
                                    .accessibilityIdentifier("OriginalUploadCheck")
                            }
                            if !row.dispatchStarted && (row.server == nil || (row.server?.state == .reserved && row.server?.connectionChanged == false)) {
                                Button("Upload Original File", systemImage: "icloud.and.arrow.up") { run(row, action: .send) }
                                    .accessibilityIdentifier("OriginalUploadSend")
                            }
                        }
                        Button("Save Original File", systemImage: "square.and.arrow.down") {
                            do {
                                try verify(row)
                                export = .init(data: try store.bytes(row.owner, row.id)); showingExport = true
                            } catch { message = QBODocumentNativeWorkflow.message(error) }
                        }
                        .accessibilityIdentifier("OriginalUploadExport")
                        if !row.cancelledLocally && !row.dispatchStarted && (row.server?.state == .reserved || row.server == nil) {
                            Button("Cancel Unsent Upload", role: .destructive) { confirmingCancel = true }
                                .accessibilityIdentifier("OriginalUploadCancel")
                        }
                    }
                    .disabled(working)
                    if working { ProgressView("Checking original file…") }
                    if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                } else { Text("Sign in to the original business to review this file.") }
            }
            .navigationTitle("Original File")
            .foregroundColor(.primary)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { selected = nil; message = nil } } }
            .confirmationDialog("Cancel this unsent upload?", isPresented: $confirmingCancel, titleVisibility: .visible) {
                Button("Cancel Unsent Upload", role: .destructive) { run(row, action: .cancel) }
                Button("Keep Upload", role: .cancel) {}
            } message: { Text("The original file stays saved. A file already sent to QuickBooks cannot be cancelled here.") }
            .fileExporter(isPresented: $showingExport, document: export, contentType: UTType(mimeType: row.file.contentType) ?? .data,
                          defaultFilename: row.file.filename) { result in
                export = nil
                if case .failure = result { message = "The file was not exported. Its original remains saved here." }
            }
        }
    }

    private func verify(_ row: QBODocumentCapture) throws {
        guard allowed, try dependencies.owner(context) == row.owner,
              try store.read(row.owner, row.id) == row else { throw QBODocumentError.changed }
    }
    private func closePrivateDetail() {
        selected = nil; sharedBrowser = nil; restoredRow = nil
        export = nil; showingExport = false; confirmingCancel = false; message = nil
    }
    private func browseShared() {
        do {
            let captured = try dependencies.access(context, .shared), generation = workspace.generation
            let checked = QBODocumentNativeWorkflow.Access(owner: captured.owner, scope: captured.scope, check: {
                try captured.check()
                guard workspace.generation == generation, allowed,
                      try dependencies.owner(context) == captured.owner else { throw QBODocumentError.access }
            })
            sharedBrowser = SharedBrowser(model: try .init(access: checked, store: store, transport: dependencies.transport))
            message = nil
        } catch { message = QBODocumentNativeWorkflow.message(error) }
    }
    private func load() {
        do {
            let owner = try dependencies.owner(context)
            rows = try store.list(owner)
        } catch { rows = []; message = QBODocumentNativeWorkflow.message(error) }
    }
    private func applyLocal(_ row: QBODocumentCapture) {
        do {
            try verify(row)
            let session = try QBODocumentCaptureSession(record: row, store: store, check: { try verify(row) })
            try QBODocumentNativeWorkflow.applyConfirmed(row, context: context,
                retainedOriginal: store.bytes(row.owner, row.id))
            try session.markLocalApplied()
            selected = session.record; message = nil; load()
        } catch { message = QBODocumentNativeWorkflow.message(error) }
    }
    private func run(_ row: QBODocumentCapture, action: QBODocumentUploadClient.Action) {
        guard !working else { return }
        do {
            try verify(row)
            let access: () throws -> Void
            if action == .send {
                let original = try dependencies.access(context, .shared)
                guard original.owner == row.owner, original.scope == row.scope else { throw QBODocumentError.access }
                access = {
                    try original.check()
                    try QBODocumentNativeWorkflow.checkLocalOriginal(row, context: context,
                        retainedOriginal: row.sharedSource == nil ? nil : store.bytes(row.owner, row.id))
                }
            } else {
                let generation = workspace.generation
                access = {
                    guard workspace.generation == generation, allowed,
                          try dependencies.owner(context) == row.owner else { throw QBODocumentError.access }
                }
            }
            let session = try QBODocumentCaptureSession(record: row, store: store, check: access)
            let client = QBODocumentUploadClient(transport: dependencies.transport, check: access)
            working = true; message = nil
            Task { @MainActor in
                defer { working = false; load() }
                do {
                    switch action {
                    case .send: try await session.send(client: client)
                    case .recover: try await session.recover(client: client)
                    case .cancel: try await session.cancel(client: client)
                    }
                    try access()
                    try QBODocumentNativeWorkflow.applyConfirmed(session.record, context: context,
                        retainedOriginal: session.record.sharedSource == nil ? nil : store.bytes(row.owner, row.id))
                    try session.markLocalApplied()
                    if selected?.id == row.id { selected = session.record }
                } catch {
                    message = QBODocumentNativeWorkflow.message(error)
                    if (try? access()) != nil, selected?.id == row.id { selected = try? store.read(row.owner, row.id) }
                    else { selected = nil }
                }
            }
        } catch { message = QBODocumentNativeWorkflow.message(error) }
    }
}
