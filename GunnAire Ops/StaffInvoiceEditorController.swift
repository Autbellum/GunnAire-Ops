import Foundation
import Combine

@MainActor final class StaffInvoiceEditorController: ObservableObject {
    @Published private(set) var source: StaffInvoiceSource?
    @Published private(set) var journal: StaffInvoiceJournal?
    @Published private(set) var draft: StaffInvoiceDraft?
    @Published private(set) var available = false
    @Published private(set) var isRunning = false
    @Published private(set) var message = "Opening invoice requests…"
    @Published private(set) var draftMessage = ""
    let client: StaffInvoiceClient
    private var generation = UUID()
    nonisolated deinit {}
    init(client: StaffInvoiceClient) { self.client = client }
    var entries: [StaffInvoiceJournal.Entry] { journal?.entries ?? [] }
    var needsReview: Bool { draft != nil && draft?.origin != source?.origin }
    var hasUnprotectedChanges: Bool { draft != journal?.draft }
    var canStage: Bool {
        guard available, !isRunning, !needsReview, !hasUnprotectedChanges, let source, let draft,
              entries.count < 128, let request = try? draft.request() else { return false }
        return (try? source.validate(request)) != nil
    }
    func open() {
        guard !available else { checkLifetime(); return }
        do {
            source = try client.source(); journal = try client.load(); draft = journal?.draft; available = true
            message = "Requests go to office review. Your saved invoice and QuickBooks are unchanged."
            if draft != nil { draftMessage = "Draft restored from this device." }
            else if entries.isEmpty && source?.editable == true { begin() }
        } catch { invalidate(); message = "Refresh the shared workspace to access this invoice. Saved drafts are retained." }
    }
    func begin() {
        guard available, !isRunning, draft == nil, entries.count < 128 else { return }
        do {
            let current = try client.source()
            guard current.editable else { throw StaffReplicaDeliveryError.changed }
            source = current
            var next = StaffInvoiceDraft(origin: current.origin, commandID: client.dependencies.operation().uuidString.lowercased(),
                                         newItemID: client.dependencies.operation().uuidString.lowercased())
            next.mode = current.catalog.isEmpty ? "new" : "catalog"
            draft = next; persist()
        } catch { message = "A new line cannot be added to this shared invoice. Ask the office to review it." }
    }
    func change(_ change: (inout StaffInvoiceDraft) -> Void) {
        guard available, !isRunning, var next = draft else { return }
        change(&next); draft = next; persist()
    }
    func selectCatalog(_ line: StaffInvoiceLine) -> Bool {
        guard available, !isRunning, source?.catalog.contains(line) == true else {
            message = "This catalog item changed. Review its current values before selecting it."; return false
        }
        change { $0.catalog = line }; return true
    }
    func persist() {
        guard available, !isRunning, hasUnprotectedChanges else { return }
        do {
            journal = try client.draft(draft, expected: journal)
            draftMessage = "Saved on this device. Not submitted."
        } catch {
            draftMessage = "Latest input could not be saved. Keep this screen open and retry; another window may have changed the draft."
        }
    }
    func checkLifetime() {
        guard available else { return }
        do { source = try client.source(local: true) }
        catch { invalidate(); message = "Staff access changed. Previously saved work remains on this device." }
    }
    func invalidate() {
        generation = UUID(); available = false; isRunning = false
        source = nil; journal = nil; draft = nil; draftMessage = ""
    }
    /// User-confirmed replacement of an unsent draft only; queued originals are immutable.
    func discardDraft() -> Bool {
        guard available, !isRunning else { return false }
        do { journal = try client.draft(nil, expected: journal); draft = nil; draftMessage = ""; return true }
        catch { message = "The saved draft changed. Reload it before discarding anything."; return false }
    }
    func reloadSaved() {
        guard available, !isRunning else { return }
        do {
            source = try client.source(local: true); journal = try client.load(); draft = journal?.draft
            draftMessage = "Loaded the last saved draft."
        } catch { message = "Saved work could not be verified. Keep this screen open and try again." }
    }
    func useCurrentInvoice(reviewed: StaffInvoiceSource) {
        guard available, !isRunning, var draft else { return }
        do {
            let current = try client.source()
            guard current == reviewed, current.editable else { throw StaffReplicaDeliveryError.changed }
            // Never silently adopt a new catalog price. Require a fresh explicit selection.
            draft.origin = current.origin; draft.catalog = nil
            self.draft = draft; source = current; persist()
            message = "Draft kept with the current invoice. Choose the catalog item again before submitting."
        } catch { message = "The shared invoice changed again. Refresh and review before continuing." }
    }
    func submit() async {
        guard canStage, let original = journal, let id = draft?.commandID else { return }
        do {
            journal = try client.stage(expected: original); draft = nil; draftMessage = ""
        } catch {
            // A committed journal with a lost acknowledgment must be recovered, not replaced.
            if let recovered = try? client.load(), recovered.entries.contains(where: { $0.id == id }), recovered.draft == nil {
                journal = recovered; draft = nil
            }
            message = "Keep the original saved request. Refresh this invoice or retry its saved submission."
            return
        }
        await retry(id: id)
    }
    func retry(id: String) async {
        guard available, !isRunning, entries.contains(where: { $0.id == id && $0.receipt == nil }) else { return }
        let token = generation; isRunning = true
        let preserveInput = hasUnprotectedChanges
        defer { if generation == token { isRunning = false } }
        do {
            let result = try await client.send(id: id)
            guard token == generation else { return }
            journal = result
            // A second window may have saved another unfinished draft during transmission.
            if !preserveInput { draft = result.draft }
            message = "Received for office review. The invoice has not been changed or published to QuickBooks."
        } catch {
            guard token == generation else { return }
            checkLifetime()
            guard available else { return }
            // Receipt persistence can also lose its acknowledgment. Read, never resubmit new intent.
            if let recovered = try? client.load(), recovered.entries.contains(where: { $0.id == id && $0.receipt != nil }) {
                journal = recovered; if !preserveInput { draft = recovered.draft }
                message = "Office receipt recovered. The request is saved for review."
            } else {
                message = "Not confirmed by office. The original request is saved on this device; retry it when connected."
            }
        }
    }
}
