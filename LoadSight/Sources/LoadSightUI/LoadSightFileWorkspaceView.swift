import SwiftUI
import UniformTypeIdentifiers
import LoadSightKit

/// Embedded host with account-scoped local recovery and explicit portable export.
public struct LoadSightFileWorkspaceView: View {
    static func documentStorage(localRecoveryEnabled: Bool) -> LoadSightDocumentStorage {
        localRecoveryEnabled ? .recoverableProject : .exportedProject
    }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var recovery: WorkspaceRecoverySession
    @State private var document = LoadSightDocument()
    @State private var hasDocument = false
    @State private var baseline: JSONValue = .null
    @State private var importing = false
    @State private var exporting = false
    @State private var projectExport = DocumentExportSession()
    @State private var exportType = LoadSightDocument.projectType
    @State private var error: String?
    @State private var discard = false
    @State private var working = false
    @State private var pendingAction: HostAction = .close
    private enum HostAction: Equatable { case create, open, close }
    private let opsContexts: [OpsProjectContext]
    private let catalogMaterials: [OpsMaterialCatalogSnapshot]
    public init(opsContexts: [OpsProjectContext] = [], recoveryScope: String? = nil, catalogMaterials: [OpsMaterialCatalogSnapshot] = []) {
        self.opsContexts = opsContexts; self.catalogMaterials = catalogMaterials
        _recovery = StateObject(wrappedValue: WorkspaceRecoverySession(scope: recoveryScope))
    }
    private var dirty: Bool { hasDocument && document.project.root != baseline }
    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("LoadSight").font(.headline)
                if dirty {
                    Text(!recovery.enabled ? "Changes not exported" : (recovery.isSaved(project: document.project, drawings: document.drawings) ? "Draft saved on this device" : "Changes not yet saved locally"))
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("MechanicalRecoveryStatus")
                }
                Spacer()
                Menu("Project") {
                    Button("New mechanical project") { request(.create) }
                    Button("Open project") { request(.open) }
                    if hasDocument {
                        Button("Export project package") { export(LoadSightDocument.projectType) }.disabled(projectExport.isExporting)
                        Button("Export portable JSON") { export(.json) }.disabled(projectExport.isExporting)
                    }
                }.disabled(!recovery.ready || recovery.pendingDraft != nil || recovery.requiresRecoveryDecision)
                Button("Done") { request(.close) }
            }.padding()
            if hasDocument, let issue = recovery.issue {
                HStack {
                    Text(issue).font(.caption).foregroundStyle(.red)
                    if recovery.enabled { Button("Retry local save") { saveRecovery() } }
                }.padding(.horizontal)
            }
            Divider()
            if !recovery.ready { ProgressView("Checking local recovery") }
            else if let draft = recovery.pendingDraft {
                ContentUnavailableView {
                    Label("Recover mechanical work", systemImage: "arrow.counterclockwise")
                } description: {
                    Text("A local draft of \(draft.project["name"].string ?? "this project") was saved at \(draft.savedAt). Restore it to continue, then export a project copy when ready.")
                } actions: {
                    Button("Restore local draft") { restore(draft) }.accessibilityIdentifier("RestoreMechanicalDraft")
                    Button("Discard local draft", role: .destructive) { discard = true }.accessibilityIdentifier("DiscardMechanicalDraft")
                }
            } else if recovery.requiresRecoveryDecision {
                ContentUnavailableView {
                    Label("Unable to read local recovery", systemImage: "exclamationmark.triangle")
                } description: { Text(recovery.issue ?? "The saved draft remains on this device.") }
                actions: {
                    Button("Try recovery again") { Task { await recovery.retryLoad() } }
                    Button("Continue without local recovery") { recovery.continueWithoutRecovery() }
                }
            } else if hasDocument {
                AnyView(LoadSightWorkspaceView(document: $document, opsContexts: opsContexts, catalogMaterials: catalogMaterials)
                    .environment(\.loadSightDocumentStorage, Self.documentStorage(localRecoveryEnabled: recovery.enabled))
                    .id(document.editSessionID))
            } else {
                ContentUnavailableView {
                    Label("Mechanical project workspace", systemImage: "ruler")
                } description: {
                    Text(Self.documentStorage(localRecoveryEnabled: recovery.enabled).openingGuidance)
                } actions: {
                    Button("Open LoadSight project") { request(.open) }
                    Button("New mechanical project") { request(.create) }
                }
            }
        }
        .disabled(working)
        .interactiveDismissDisabled(dirty || recovery.pendingDraft != nil || working)
        .task { await recovery.load() }
        .onChange(of: document.project.root) { _, _ in
            if dirty { saveRecovery() } else if hasDocument { recovery.currentProjectIsClean() }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { saveRecovery() } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [LoadSightDocument.projectType, .json]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let loaded = try LoadSightDocument(wrapper: FileWrapper(url: url, options: .immediate))
                document = loaded; baseline = loaded.project.root; hasDocument = true
            } catch { self.error = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: projectExport.snapshot, contentTypes: [exportType], defaultFilename: "LoadSight-Project") { result in
            guard let snapshot = projectExport.finish(for: document.editSessionID) else { return }
            switch result {
            case .success:
                baseline = snapshot.project.root
                if document.project.root == snapshot.project.root { recovery.currentProjectIsClean() }
                else { recovery.exported(projectRoot: snapshot.project.root); saveRecovery() }
            case .failure(let error): self.error = error.localizedDescription
            }
        } onCancellation: {
            projectExport.cancel()
        }
        .alert(recovery.pendingDraft != nil ? "Discard saved local draft?" : "Project changes are not exported", isPresented: $discard) {
            if recovery.pendingDraft == nil && pendingAction == .close && recovery.enabled {
                Button("Keep draft and close") { keepAndClose() }.accessibilityIdentifier("KeepMechanicalDraftAndClose")
            }
            Button("Discard changes", role: .destructive) { discardAndPerform() }
            Button("Keep editing", role: .cancel) {}
        } message: { Text("Export a project copy for a portable record. Discard removes the local recovery draft.") }
        .alert("Unable to complete project action", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
    private func saveRecovery() {
        guard dirty else { return }
        recovery.save(project: document.project, drawings: document.drawings)
    }
    private func restore(_ draft: WorkspaceRecoveryDraft) {
        do {
            let restored = try LoadSightDocument(recoveryDraft: draft)
            recovery.restored(project: restored.project, drawings: restored.drawings)
            document = restored; baseline = .null; hasDocument = true
        } catch { self.error = error.localizedDescription }
    }
    private func request(_ action: HostAction) {
        if recovery.pendingDraft != nil && action == .close { dismiss(); return }
        if dirty { pendingAction = action; discard = true } else { perform(action) }
    }
    private func perform(_ action: HostAction) {
        switch action {
        case .create: document = LoadSightDocument(); baseline = document.project.root; hasDocument = true
        case .open: importing = true
        case .close:
            working = true
            document.invalidatePendingEdits()
            dismiss()
        }
    }
    private func discardAndPerform() {
        working = true
        let recovering = recovery.pendingDraft != nil
        Task {
            let removed = await recovery.discard()
            working = false
            guard removed else { error = recovery.issue; return }
            if recovering { return }
            if pendingAction == .open {
                document.invalidatePendingEdits()
                hasDocument = false; baseline = .null
            }
            perform(pendingAction)
        }
    }
    private func keepAndClose() {
        working = true
        Task {
            _ = await recovery.flush(project: document.project, drawings: document.drawings)
            // An import may have changed the binding during the awaited save.
            // Only the current document's saved state permits closing.
            if recovery.isSaved(project: document.project, drawings: document.drawings) {
                perform(.close)
            } else {
                working = false
                error = recovery.issue ?? "The latest project changes are not saved locally. Export the project, keep editing, or try again."
            }
        }
    }
    private func export(_ type: UTType) {
        do {
            try projectExport.begin(document)
            exportType = type; exporting = true
        } catch { self.error = error.localizedDescription }
    }
}
