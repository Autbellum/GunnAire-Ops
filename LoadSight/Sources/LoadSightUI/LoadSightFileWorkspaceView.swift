import SwiftUI
import UniformTypeIdentifiers
import LoadSightKit

/// Embedded host for a user-selected project. Billing publication remains a separate workflow.
public struct LoadSightFileWorkspaceView: View {
    static let documentStorage = LoadSightDocumentStorage.exportedProject
    @Environment(\.dismiss) private var dismiss
    @State private var document = LoadSightDocument()
    @State private var hasDocument = false
    @State private var baseline: JSONValue = .null
    @State private var importing = false
    @State private var exporting = false
    @State private var exportSnapshot: LoadSightDocument?
    @State private var exportType = LoadSightDocument.projectType
    @State private var error: String?
    @State private var discard = false
    @State private var pendingAction: HostAction = .close
    private enum HostAction { case create, open, close }
    private let opsContexts: [OpsProjectContext]
    public init(opsContexts: [OpsProjectContext] = []) { self.opsContexts = opsContexts }
    private var dirty: Bool { hasDocument && document.project.root != baseline }
    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("LoadSight").font(.headline)
                if dirty { Text("Unsaved changes").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Menu("Project") {
                    Button("New mechanical project") { request(.create) }
                    Button("Open project") { request(.open) }
                    if hasDocument {
                        Button("Export project package") { export(LoadSightDocument.projectType) }
                        Button("Export portable JSON") { export(.json) }
                    }
                }
                Button("Done") { request(.close) }
            }.padding()
            Divider()
            if hasDocument {
                AnyView(LoadSightWorkspaceView(document: $document, opsContexts: opsContexts)
                    .environment(\.loadSightDocumentStorage, Self.documentStorage))
            } else {
                ContentUnavailableView {
                    Label("Mechanical project workspace", systemImage: "ruler")
                } description: {
                    Text("Open a LoadSight project or create a new one. Export your changes to retain them. Ops billing and approvals remain separate.")
                } actions: {
                    Button("Open LoadSight project") { request(.open) }
                    Button("New mechanical project") { request(.create) }
                }
            }
        }
        .interactiveDismissDisabled(dirty)
        .fileImporter(isPresented: $importing, allowedContentTypes: [LoadSightDocument.projectType, .json]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                // Decode fully before replacing the current working copy.
                let loaded = try LoadSightDocument(wrapper: FileWrapper(url: url, options: .immediate))
                document = loaded; baseline = loaded.project.root; hasDocument = true
            } catch { self.error = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: exportSnapshot, contentType: exportType, defaultFilename: "LoadSight-Project") { result in
            switch result {
            case .success:
                if let snapshot = exportSnapshot { baseline = snapshot.project.root }
            case .failure(let error): self.error = error.localizedDescription
            }
        }
        .alert("Discard unsaved project changes?", isPresented: $discard) {
            Button("Discard changes", role: .destructive) { perform(pendingAction) }
            Button("Keep editing", role: .cancel) {}
        } message: { Text("Export the project first if you want to retain these edits.") }
        .alert("Unable to complete project action", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
    private func request(_ action: HostAction) {
        if dirty { pendingAction = action; discard = true } else { perform(action) }
    }
    private func perform(_ action: HostAction) {
        switch action {
        case .create:
            document = LoadSightDocument(); baseline = document.project.root; hasDocument = true
        case .open: importing = true
        case .close: dismiss()
        }
    }
    private func export(_ type: UTType) {
        do {
            try document.validateMarkup()
            exportSnapshot = document; exportType = type; exporting = true
        } catch { self.error = error.localizedDescription }
    }
}
