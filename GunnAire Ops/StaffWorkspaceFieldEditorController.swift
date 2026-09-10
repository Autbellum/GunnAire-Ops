import Foundation
import Combine

struct StaffWorkspaceFieldEditorInput: Codable, Equatable {
    var text = ""
    var flag = false
    var date = Date()
    var isNull = false
    init(_ value: StaffWorkspaceValue) {
        switch value {
        case .text(let value): text = value
        case .number(let value): text = String(value)
        case .integer(let value): text = String(value)
        case .flag(let value): flag = value
        case .date(let value): date = value
        case .null: isNull = true
        case .identifier: break
        }
    }
    func value(schema: StaffWorkspaceFieldSchema) throws -> StaffWorkspaceValue {
        let value: StaffWorkspaceValue
        if isNull { value = .null }
        else {
            switch schema.type {
            case .text: value = .text(text)
            case .number:
                guard let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), number.isFinite else { throw StaffWorkspaceModelError.invalid }
                value = .number(number)
            case .integer:
                guard let number = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw StaffWorkspaceModelError.invalid }
                value = .integer(number)
            case .flag: value = .flag(flag)
            case .date: value = .date(date)
            case .identifier: throw StaffWorkspaceModelError.unsupported
            }
        }
        try schema.validateScalar(value)
        return value
    }
}

struct StaffWorkspaceFieldEditorDependencies {
    typealias Context = CloudKitStaffSetupController.Context
    let authority: () throws -> (Context, CloudKitStaffSharePlan)
    let snapshot: (Context, CloudKitStaffSharePlan) throws -> StaffWorkspaceFieldEditorSnapshot
    let history: (StaffWorkspaceFieldEditorSnapshot, Context, CloudKitStaffSharePlan) throws -> [StaffWorkspaceOperationalCommandJournal]
    let draft: (StaffWorkspaceFieldEditorSnapshot, Context, CloudKitStaffSharePlan) throws -> StaffWorkspaceFieldDraft?
    let persist: (StaffWorkspaceFieldDraft, StaffWorkspaceFieldDraft?, Bool, Context, CloudKitStaffSharePlan) throws -> StaffWorkspaceFieldDraft
    let queue: (StaffWorkspaceFieldEditorSnapshot, Context, CloudKitStaffSharePlan, UUID, StaffWorkspaceValue) throws -> StaffWorkspaceOperationalCommandJournal
    let send: (StaffWorkspaceOperationalCommandJournal, Context, CloudKitStaffSharePlan) async throws -> StaffWorkspaceOperationalCommandJournal
    var operation: () -> UUID = UUID.init
    static func live(hosted: StaffWorkspaceOperationalHostedStore, kind: String, recordID: String,
                     revision: Int, field: String) -> Self {
        let engine = StaffWorkspaceContentCoordinator(dependencies: .live)
        return .init(authority: { try StaffReplicaReceiveController.shared.fieldEditingAuthority(for: hosted) },
            snapshot: { context, plan in
                try engine.fieldEditorSnapshot(plan: plan, context: context, selectionID: hosted.journal.selectionID,
                    sourceSequence: hosted.journal.sourceSequence, contentSHA256: hosted.journal.contentSHA256,
                    kind: kind, recordID: recordID, revision: revision, field: field)
            }, history: { try engine.fieldEditorHistory($0, plan: $2, context: $1) },
            draft: { try engine.fieldEditorDraft($0, plan: $2, context: $1) },
            persist: { try engine.saveFieldEditorDraft($0, expected: $1, reviewing: $2, plan: $4, context: $3) },
            queue: { try engine.queueFieldEditorUpdate($0, plan: $2, context: $1, commandID: $3, value: $4) },
            send: { try await engine.sendFieldEditorUpdate($0, plan: $2, context: $1) })
    }
}

@MainActor final class StaffWorkspaceFieldEditorController: ObservableObject {
    @Published private(set) var input = StaffWorkspaceFieldEditorInput(.text(""))
    @Published private(set) var snapshot: StaffWorkspaceFieldEditorSnapshot?
    @Published private(set) var saved: [StaffWorkspaceOperationalCommandJournal] = []
    @Published private(set) var isEditing = false
    @Published private(set) var isRunning = false
    @Published private(set) var available = false
    @Published private(set) var message = "Opening the shared field…"
    @Published private(set) var draft: StaffWorkspaceFieldDraft?
    @Published private(set) var draftMessage = ""
    @Published private(set) var needsReview = false
    @Published private(set) var currentSnapshot: StaffWorkspaceFieldEditorSnapshot?
    private let dependencies: StaffWorkspaceFieldEditorDependencies
    private var stamp: CloudKitStaffSetupStamp?
    private var commandID: UUID?
    private var initial = StaffWorkspaceFieldEditorInput(.text(""))
    private var generation = UUID()
    init(dependencies: StaffWorkspaceFieldEditorDependencies) { self.dependencies = dependencies }
    // Release-only teardown; never run UI, storage or authorization work here.
    nonisolated deinit {}
    var schema: StaffWorkspaceFieldSchema? {
        guard let c = snapshot?.candidate else { return nil }
        return StaffWorkspaceModelCatalog.all.first { $0.kind == c.recordKind }?.fieldSchema[c.fieldName]
    }
    var hasUnsavedChanges: Bool { isEditing && input != initial }
    var hasUnprotectedChanges: Bool {
        hasUnsavedChanges && !(draft?.commandID == commandID && draft?.snapshot == snapshot && draft?.input == input)
    }
    func setText(_ value: String) { input.text = value; input.isNull = false; persistDraft() }
    func setFlag(_ value: Bool) { input.flag = value; persistDraft() }
    func setDate(_ value: Date) { input.date = value; persistDraft() }
    func setNull(_ value: Bool) { input.isNull = value; persistDraft() }
    func clearValue() { input.text = ""; input.isNull = true; persistDraft() }
    var visibleSaved: [StaffWorkspaceOperationalCommandJournal] {
        let pending = saved.filter { $0.state == "pending" }
        return pending + (saved.last(where: { $0.state == "recorded" }).map { [$0] } ?? [])
    }
    var canSave: Bool { available && isEditing && !isRunning && !needsReview && (try? proposedValue()) != nil }
    private func proposedValue() throws -> StaffWorkspaceValue {
        guard let schema, let snapshot, let commandID else { throw StaffReplicaDeliveryError.invalid }
        let value = try input.value(schema: schema)
        guard value != snapshot.candidate.currentValue, !snapshot.alreadySubmitted(value, history: saved) else { throw StaffReplicaDeliveryError.changed }
        let (_, plan) = try authority()
        _ = try snapshot.request(plan: plan, commandID: commandID, value: value)
        return value
    }
    private func authority() throws -> (StaffWorkspaceFieldEditorDependencies.Context, CloudKitStaffSharePlan) {
        let (context, plan) = try dependencies.authority()
        guard stamp == nil || context.stamp == stamp else { throw StaffReplicaDeliveryError.access }
        return (context, plan)
    }
    func open() {
        guard snapshot == nil else { checkLifetime(); return }
        do {
            let (context, plan) = try authority()
            let current = try dependencies.snapshot(context, plan)
            snapshot = current; currentSnapshot = current; stamp = context.stamp
            saved = try dependencies.history(current, context, plan)
            draft = try dependencies.draft(current, context, plan)
            available = true
            if let draft, let raw = draft.input,
               !saved.contains(where: { $0.request.commandID == draft.commandID.uuidString.lowercased() }) {
                snapshot = draft.snapshot; commandID = draft.commandID; input = raw; initial = draft.initial
                isEditing = true; needsReview = draft.snapshot != current
                draftMessage = "Draft restored from this device. It has not been submitted."
                message = needsReview ? "The shared record changed. Review your draft against the current field before submitting." : "Continue your unfinished finding."
            } else if saved.isEmpty { beginEditing(current.candidate.currentValue) }
            else { isEditing = false; message = saved.contains { $0.state == "pending" } ? "Saved updates still need office confirmation." : "Your last update was submitted for office review." }
        } catch { invalidate(); message = "This shared field is unavailable. Refresh the staff workspace and try again." }
    }
    private func beginEditing(_ value: StaffWorkspaceValue) {
        input = .init(value); initial = input; commandID = dependencies.operation(); isEditing = true
        needsReview = false
        message = "Save your finding on this device, then send it for office review."
        persistDraft()
    }
    func newUpdate() {
        guard !isEditing, !isRunning, !saved.contains(where: { $0.state == "pending" }) else { return }
        do {
            let (context, plan) = try authority()
            let current = try dependencies.snapshot(context, plan)
            snapshot = current; currentSnapshot = current; saved = try dependencies.history(current, context, plan)
            draft = try dependencies.draft(current, context, plan)
            if let draft, draft.input != nil,
               !saved.contains(where: { $0.request.commandID == draft.commandID.uuidString.lowercased() }) {
                message = "Another window has an unfinished draft. Reopen this field to restore it."; return
            }
            guard !saved.contains(where: { $0.state == "pending" }) else { return }
            available = true
            beginEditing(saved.last?.request.value ?? current.candidate.currentValue)
        } catch { checkLifetime(); message = "Refresh the shared record before creating another update. Saved originals are retained." }
    }
    func checkLifetime() {
        do {
            let (context, plan) = try authority(); available = true
            if isEditing {
                if let current = try? dependencies.snapshot(context, plan) {
                    currentSnapshot = current; needsReview = current != snapshot
                } else { needsReview = true }
                if hasUnprotectedChanges { persistDraft() }
            }
        }
        catch StaffReplicaDeliveryError.pending { available = false; message = "Staff access is refreshing. Your unsaved text is still here." }
        catch { invalidate(); message = "Staff access changed. Saved updates are retained on this device." }
    }
    func invalidate() {
        generation = UUID(); input = .init(.text("")); initial = input; snapshot = nil
        saved = []; stamp = nil; commandID = nil; isEditing = false; available = false; isRunning = false
        draft = nil; currentSnapshot = nil; needsReview = false; draftMessage = ""
    }

    @discardableResult func persistDraft() -> Bool {
        guard isEditing, !isRunning, let snapshot, let commandID else { return false }
        let next = StaffWorkspaceFieldDraft(snapshot: snapshot, commandID: commandID,
            revision: (draft?.revision).map { $0 + 1 } ?? 0, initial: initial, input: input)
        // Do not rewrite an already verified keystroke just to refresh status.
        if draft?.snapshot == snapshot, draft?.commandID == commandID, draft?.input == input { return true }
        return persist(next, reviewing: false)
    }
    private func persist(_ next: StaffWorkspaceFieldDraft, reviewing: Bool) -> Bool {
        do {
            let (context, plan) = try authority()
            do { draft = try dependencies.persist(next, draft, reviewing, context, plan) }
            catch {
                // An atomic write may have succeeded before its acknowledgement failed.
                _ = try authority()
                guard try dependencies.draft(next.snapshot, context, plan) == next else { throw error }
                draft = next
            }
            draftMessage = next.input == nil ? "Draft discarded. Submitted updates are unchanged." : "Draft saved on this device · not submitted"
            return true
        } catch {
            do { _ = try authority() }
            catch StaffReplicaDeliveryError.pending { available = false }
            catch { invalidate(); message = "Staff access changed. Previously saved drafts are retained on this device."; return false }
            draftMessage = "Draft save is not verified. Keep this view open and retry. If another window changed it, reopen the saved draft; this text has not replaced it."
            return false
        }
    }
    func useDraftWithCurrentRecord(reviewed: StaffWorkspaceFieldEditorSnapshot) {
        guard isEditing, needsReview, !isRunning, persistDraft(), let draft else { return }
        do {
            let (context, plan) = try authority()
            let current = try dependencies.snapshot(context, plan)
            guard current == reviewed else { throw StaffReplicaDeliveryError.changed }
            let next = StaffWorkspaceFieldDraft(snapshot: current, commandID: dependencies.operation(),
                revision: draft.revision + 1, initial: .init(current.candidate.currentValue), input: input)
            guard persist(next, reviewing: true) else { return }
            snapshot = current; currentSnapshot = current; commandID = next.commandID; initial = next.initial; needsReview = false
            message = "Draft reviewed against this shared record. Submit when you are ready."
        } catch { message = "Refresh the workspace before reviewing this draft. The original is retained." }
    }
    func discardDraft() -> Bool {
        guard isEditing, !isRunning else { return false }
        if let draft, draft.commandID == commandID, draft.input != nil {
            let next = StaffWorkspaceFieldDraft(snapshot: draft.snapshot, commandID: draft.commandID,
                revision: draft.revision + 1, initial: draft.initial, input: nil)
            guard persist(next, reviewing: false) else { return false }
        } else {
            // A never-acknowledged first write still must not erase another window's draft.
            guard let snapshot else { return false }
            do {
                let (context, plan) = try authority()
                guard try dependencies.draft(snapshot, context, plan) == draft else { throw StaffReplicaDeliveryError.changed }
            } catch { draftMessage = "The saved draft changed. Reopen it before discarding."; return false }
        }
        invalidate(); return true
    }
    func save() async {
        guard canSave, let snapshot, let commandID else { return }
        guard persistDraft() else { return }
        let run = generation
        do {
            let value = try proposedValue()
            let (context, plan) = try authority()
            _ = try dependencies.queue(snapshot, context, plan, commandID, value)
            saved = try dependencies.history(snapshot, context, plan)
            guard let original = saved.first(where: { $0.request.commandID == commandID.uuidString.lowercased() }) else { throw StaffReplicaDeliveryError.storage }
            isEditing = false
            await retry(original)
        } catch {
            guard generation == run else { return }
            do {
                let (context, plan) = try authority()
                saved = try dependencies.history(snapshot, context, plan)
                if saved.contains(where: { $0.request.commandID == commandID.uuidString.lowercased() }) {
                    isEditing = false; message = "Saved on this device. Retry to send the original update."
                } else { message = "Save could not be verified. Keep this view open and try again; your text has not been replaced." }
            } catch { checkLifetime(); if available { message = "Save could not be verified. Keep this view open and try again." } }
        }
    }
    func retry(_ original: StaffWorkspaceOperationalCommandJournal) async {
        guard !isRunning, let snapshot, original.state == "pending" else { return }
        let run = generation
        isRunning = true
        defer { if generation == run { isRunning = false } }
        message = "Saved on this device. Sending for office review…"
        do {
            let (context, plan) = try authority()
            _ = try await dependencies.send(original, context, plan)
            try Task.checkCancellation()
            guard generation == run else { return }
            _ = try authority()
            saved = try dependencies.history(snapshot, context, plan)
            message = "Submitted for office review. The office record has not been replaced by this device."
        } catch {
            guard generation == run else { return }
            checkLifetime()
            if available { message = "Saved on this device, but office receipt is not confirmed. Check your connection or workspace access, then retry." }
        }
    }
}
