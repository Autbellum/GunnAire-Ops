import SwiftUI
import LoadSightKit

@MainActor
final class WorkspaceRecoverySession: ObservableObject {
    @Published private(set) var ready = false
    @Published private(set) var pendingDraft: WorkspaceRecoveryDraft?
    @Published private(set) var issue: String?
    @Published private(set) var requiresRecoveryDecision = false
    @Published private(set) var isSaving = false
    private let scope: String?
    private let store: WorkspaceRecoveryStore
    private var disabled = false
    private var revision: UUID?
    private var savedRoot: JSONValue?
    private var savedDrawings: DrawingArchive?
    private var queuedRoot: JSONValue?
    private var queuedDrawings: DrawingArchive?
    private var task: Task<Void, Never>?
    private var outstanding = 0
    var enabled: Bool { scope != nil && !disabled }
    init(scope: String?, store: WorkspaceRecoveryStore = .shared) { self.scope = scope; self.store = store }
    func load() async {
        guard !ready else { return }
        defer { ready = true }
        guard let scope else { issue = "Local recovery is unavailable in this host. Export your project to retain edits."; return }
        do {
            let draft = try await store.load(scope: scope)
            pendingDraft = draft; revision = draft?.revision; issue = nil; requiresRecoveryDecision = false
        } catch { issue = error.localizedDescription; requiresRecoveryDecision = true }
    }
    func retryLoad() async { ready = false; await load() }
    func continueWithoutRecovery() {
        disabled = true; requiresRecoveryDecision = false
        issue = "Local recovery is off. Any earlier draft remains on this device. Export new work before closing."
    }
    func restored(project: ProjectDocument, drawings: DrawingArchive) {
        savedRoot = project.root; savedDrawings = drawings; pendingDraft = nil
    }
    func isSaved(project: ProjectDocument, drawings: DrawingArchive) -> Bool {
        enabled && revision != nil && savedRoot == project.root && savedDrawings == drawings && issue == nil
    }
    func save(project: ProjectDocument, drawings: DrawingArchive) {
        guard enabled, ready, pendingDraft == nil, let scope else { return }
        if issue == nil && ((queuedRoot == project.root && queuedDrawings == drawings) || (!isSaving && isSaved(project: project, drawings: drawings))) { return }
        queuedRoot = project.root; queuedDrawings = drawings
        enqueue {
            do {
                let draft = try await self.store.save(project: project, drawings: drawings, scope: scope, expectedRevision: self.revision)
                self.revision = draft.revision; self.savedRoot = project.root; self.savedDrawings = drawings; self.issue = nil
            } catch { self.issue = error.localizedDescription }
        }
    }
    func waitForPendingOperations() async { await task?.value }
    func flush(project: ProjectDocument, drawings: DrawingArchive) async -> Bool {
        save(project: project, drawings: drawings)
        await task?.value
        return isSaved(project: project, drawings: drawings)
    }
    func discard() async -> Bool {
        guard enabled, let scope else { return true }
        var succeeded = false
        let operation = enqueue {
            do {
                try await self.store.remove(scope: scope, expectedRevision: self.revision)
                self.resetSavedState(); self.pendingDraft = nil; self.issue = nil; succeeded = true
            } catch { self.issue = error.localizedDescription }
        }
        await operation.value
        return succeeded
    }
    func currentProjectIsClean() {
        guard enabled, ready, pendingDraft == nil, let scope else { return }
        enqueue {
            guard self.savedRoot != nil else { return }
            do {
                try await self.store.remove(scope: scope, expectedRevision: self.revision)
                self.resetSavedState(); self.issue = nil
            } catch { self.issue = error.localizedDescription }
        }
    }
    func exported(projectRoot: JSONValue) {
        guard enabled, let scope else { return }
        enqueue {
            // A delayed export callback must never clear a newer edited draft.
            guard self.savedRoot == projectRoot else { return }
            do {
                try await self.store.remove(scope: scope, expectedRevision: self.revision)
                self.resetSavedState(); self.issue = nil
            } catch { self.issue = error.localizedDescription }
        }
    }
    private func resetSavedState() {
        revision = nil; savedRoot = nil; savedDrawings = nil; queuedRoot = nil; queuedDrawings = nil
    }
    @discardableResult
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = task
        outstanding += 1; isSaving = true
        let next = Task {
            await previous?.value
            await operation()
            self.outstanding -= 1; self.isSaving = self.outstanding > 0
        }
        task = next
        return next
    }
}
