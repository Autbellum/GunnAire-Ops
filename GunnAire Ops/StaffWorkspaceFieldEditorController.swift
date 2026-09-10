import Foundation
import Combine

struct StaffWorkspaceFieldEditorInput: Equatable {
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
            queue: { try engine.queueFieldEditorUpdate($0, plan: $2, context: $1, commandID: $3, value: $4) },
            send: { try await engine.sendFieldEditorUpdate($0, plan: $2, context: $1) })
    }
}

@MainActor final class StaffWorkspaceFieldEditorController: ObservableObject {
    @Published var input = StaffWorkspaceFieldEditorInput(.text(""))
    @Published private(set) var snapshot: StaffWorkspaceFieldEditorSnapshot?
    @Published private(set) var saved: [StaffWorkspaceOperationalCommandJournal] = []
    @Published private(set) var isEditing = false
    @Published private(set) var isRunning = false
    @Published private(set) var available = false
    @Published private(set) var message = "Opening the shared field…"
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
    func setText(_ value: String) { input.text = value; input.isNull = false }
    func clearValue() { input.text = ""; input.isNull = true }
    var visibleSaved: [StaffWorkspaceOperationalCommandJournal] {
        let pending = saved.filter { $0.state == "pending" }
        return pending + (saved.last(where: { $0.state == "recorded" }).map { [$0] } ?? [])
    }
    var canSave: Bool { available && isEditing && !isRunning && (try? proposedValue()) != nil }
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
            snapshot = current; stamp = context.stamp
            saved = try dependencies.history(current, context, plan)
            available = true
            if saved.isEmpty { beginEditing(current.candidate.currentValue) }
            else { isEditing = false; message = saved.contains { $0.state == "pending" } ? "Saved updates still need office confirmation." : "Your last update was submitted for office review." }
        } catch { invalidate(); message = "This shared field is unavailable. Refresh the staff workspace and try again." }
    }
    private func beginEditing(_ value: StaffWorkspaceValue) {
        input = .init(value); initial = input; commandID = dependencies.operation(); isEditing = true
        message = "Save your finding on this device, then send it for office review."
    }
    func newUpdate() {
        guard !isRunning, !saved.contains(where: { $0.state == "pending" }) else { return }
        do {
            let (context, plan) = try authority()
            let current = try dependencies.snapshot(context, plan)
            snapshot = current; saved = try dependencies.history(current, context, plan)
            guard !saved.contains(where: { $0.state == "pending" }) else { return }
            available = true
            beginEditing(saved.last?.request.value ?? current.candidate.currentValue)
        } catch { checkLifetime(); message = "Refresh the shared record before creating another update. Saved originals are retained." }
    }
    func checkLifetime() {
        do { _ = try authority(); available = true }
        catch StaffReplicaDeliveryError.pending { available = false; message = "Staff access is refreshing. Your unsaved text is still here." }
        catch { invalidate(); message = "Staff access changed. Saved updates are retained on this device." }
    }
    func invalidate() {
        generation = UUID(); input = .init(.text("")); initial = input; snapshot = nil
        saved = []; stamp = nil; commandID = nil; isEditing = false; available = false; isRunning = false
    }
    func save() async {
        guard canSave, let snapshot, let commandID else { return }
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
