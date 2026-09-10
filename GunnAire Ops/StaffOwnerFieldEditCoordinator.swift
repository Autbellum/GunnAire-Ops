import Foundation
import Combine
import SwiftData

struct StaffOwnerFieldEditDependencies {
    let check: (StaffReplicaSourceContext) throws -> Void
    let request: (String, String, Data?) async throws -> Data
    let store: SharedTimeLocalStore
    let read: (StaffOwnerFieldEdit, StaffReplicaSourceContext) throws -> StaffWorkspaceValue
    let apply: (StaffOwnerFieldEdit, StaffWorkspaceValue, StaffReplicaSourceContext) throws -> Void
    var title: ((StaffOwnerFieldEdit, StaffReplicaSourceContext) throws -> String)? = nil
    var operation: () -> UUID = UUID.init
    static var live: Self {
        func container(_ context: StaffReplicaSourceContext) throws -> ModelContainer {
            try StaffReplicaSourceDependencies.verify(context)
            guard let container = CompanyWorkspaceAccessController.shared.authorizedContainer else { throw StaffReplicaSourceSyncError.access }
            return container
        }
        return .init(check: { try StaffReplicaSourceDependencies.verify($0) },
            request: { try await GunnAireBackendService.staffReplicaSourceRequest(path: $0, method: $1, body: $2) },
            store: StaffWorkspaceSourceStaging.device,
            read: { try StaffOwnerFieldEditModels.read($0, container: container($1)) },
            apply: { edit, expected, context in
                try StaffOwnerFieldEditModels.apply(edit, expected: expected, container: container(context),
                    check: { try StaffReplicaSourceDependencies.verify(context) })
            }, title: { edit, context in
                let modelContext = ModelContext(try container(context)); modelContext.autosaveEnabled = false
                return try StaffOwnerFieldEditModels.target(edit, context: modelContext).title
            })
    }
}

struct StaffOwnerFieldEditPending: Codable {
    let edit: StaffOwnerFieldEdit
    let request: StaffOwnerFieldEditPrepare
    var phase: String
    var application: StaffOwnerFieldEditApplication?
}
struct StaffOwnerFieldEditJournal: Codable {
    let version: Int
    let scope: StaffReplicaSourceScope
    var queue: [String] = []
    var after: String?
    var lastAttempted: String?
    var pending: [String: StaffOwnerFieldEditPending] = [:]
}
struct StaffOwnerFieldEditReview: Identifiable {
    let edit: StaffOwnerFieldEdit
    let title: String
    let officeValue: StaffWorkspaceValue?
    let message: String
    let canApplyReviewed: Bool
    var id: String { edit.id }
}

@MainActor final class StaffOwnerFieldEditCoordinator: ObservableObject {
    static let shared = StaffOwnerFieldEditCoordinator()
    let dependencies: StaffOwnerFieldEditDependencies
    @Published private(set) var reviews: [StaffOwnerFieldEditReview] = []
    @Published private(set) var message = "Check for saved field updates."
    private var displayScope: StaffReplicaSourceScope?
    init(dependencies: StaffOwnerFieldEditDependencies? = nil) { self.dependencies = dependencies ?? .live }
    static func key(_ scope: StaffReplicaSourceScope) -> String { "owner-field-edits-v1\n" + scope.key }
    func clearDisplay() { reviews = []; displayScope = nil; message = "Check for saved field updates." }
    private func load(_ context: StaffReplicaSourceContext) throws -> StaffOwnerFieldEditJournal {
        try dependencies.check(context)
        guard let bytes = try dependencies.store.read(Self.key(context.scope)) else { return .init(version: 1, scope: context.scope) }
        let value = try StaffWorkspacePublicationContract.decode(StaffOwnerFieldEditJournal.self, from: bytes, maximum: 64 * 1024 * 1024)
        try validate(value, context)
        return value
    }
    private func validate(_ value: StaffOwnerFieldEditJournal, _ context: StaffReplicaSourceContext) throws {
        guard value.version == 1, value.scope == context.scope, value.queue.count <= 50,
              value.queue == Set(value.queue).sorted(), value.queue.allSatisfy(CloudKitStaffSetupPolicy.canonicalID),
              value.after.map(CloudKitStaffSetupPolicy.canonicalID) ?? true,
              value.lastAttempted.map(CloudKitStaffSetupPolicy.canonicalID) ?? true, value.pending.count <= 32 else {
            throw StaffReplicaSourceSyncError.storage
        }
        for (id, pending) in value.pending {
            try pending.request.validate(edit: pending.edit, scope: context.scope)
            guard id == pending.edit.id, ["prepared", "saved"].contains(pending.phase),
                  pending.phase != "saved" || pending.application != nil else { throw StaffReplicaSourceSyncError.storage }
            try pending.application?.validate(pending.request, scope: context.scope)
        }
    }
    private func save(_ value: StaffOwnerFieldEditJournal, _ context: StaffReplicaSourceContext) throws {
        try dependencies.check(context)
        try validate(value, context)
        let bytes = try StaffWorkspacePublicationContract.encode(value)
        guard bytes.count <= 64 * 1024 * 1024 else { throw StaffReplicaSourceSyncError.storage }
        try dependencies.store.write(Self.key(context.scope), bytes)
        try dependencies.check(context)
    }
    private func request<T: Codable>(_ type: T.Type, path: String, method: String = "GET", body: Data? = nil,
                                    context: StaffReplicaSourceContext) async throws -> T {
        try dependencies.check(context)
        guard StaffOwnerFieldEditTransport.allows(path: path, method: method, body: body) else { throw StaffReplicaSourceSyncError.invalid }
        let bytes = try await dependencies.request(path, method, body)
        try dependencies.check(context)
        return try StaffWorkspacePublicationContract.decode(type, from: bytes, maximum: StaffOwnerFieldEditTransport.maximumResponseBytes)
    }
    private func detail(_ id: String, _ context: StaffReplicaSourceContext) async throws -> StaffOwnerFieldEdit {
        let edit = try await request(StaffOwnerFieldEdit.self, path: StaffOwnerFieldEditTransport.path(context.scope, id: id), context: context)
        try edit.validate(context.scope)
        guard edit.id == id else { throw StaffReplicaSourceSyncError.invalid }
        return edit
    }
    private func review(_ edit: StaffOwnerFieldEdit, context: StaffReplicaSourceContext, message: String) {
        let local = try? dependencies.read(edit, context)
        let canApply = edit.eligible && edit.application == nil && edit.current?.deleted == false && local != nil && local == edit.current?.value
        reviews.removeAll { $0.id == edit.id }
        let title = (try? dependencies.title?(edit, context)) ?? StaffWorkspacePublicationReview.label(edit.request.recordKind)
        reviews.append(.init(edit: edit, title: title, officeValue: local, message: message, canApplyReviewed: canApply))
    }
    private func apply(_ edit: StaffOwnerFieldEdit, reviewed: Bool, state: inout StaffOwnerFieldEditJournal,
                       context: StaffReplicaSourceContext) async throws {
        if edit.application?.state == "published" {
            if let pending = state.pending[edit.id] { try edit.application?.validate(pending.request, scope: context.scope) }
            state.pending[edit.id] = nil; try save(state, context); return
        }
        if state.pending[edit.id]?.phase == "saved" { return }
        guard edit.eligible, let current = edit.current, !current.deleted else { throw StaffOwnerFieldEditError.conflict }
        if state.pending[edit.id] == nil {
            guard state.pending.count < 32 else { throw StaffReplicaSourceSyncError.storage }
            let original: StaffOwnerFieldEditPrepare
            if let application = edit.application {
                original = try .init(edit: edit, scope: context.scope, application: application)
            } else {
                let local = try dependencies.read(edit, context)
                guard local == current.value, reviewed || local == edit.baseValue else { throw StaffOwnerFieldEditError.conflict }
                original = try .init(edit: edit, scope: context.scope, reviewed: reviewed, operation: dependencies.operation())
            }
            try original.validate(edit: edit, scope: context.scope)
            state.pending[edit.id] = .init(edit: edit, request: original, phase: "prepared", application: nil)
            try save(state, context) // Original intent durable before claiming or saving a model.
        }
        guard var pending = state.pending[edit.id], pending.edit.request == edit.request, pending.edit.receipt == edit.receipt,
              pending.edit.baseValue == edit.baseValue else { throw StaffReplicaSourceSyncError.storage }
        let application = try await request(StaffOwnerFieldEditApplication.self,
            path: StaffOwnerFieldEditTransport.root + "/" + edit.id + "/prepare", method: "POST",
            body: StaffWorkspacePublicationContract.encode(pending.request), context: context)
        try application.validate(pending.request, scope: context.scope)
        pending.application = application; state.pending[edit.id] = pending; try save(state, context)
        if application.state == "published" { state.pending[edit.id] = nil; try save(state, context); return }
        // Fresh authority and source-field fence after the claim reply, before
        // the synchronous, typed local save. Never import an entire archive.
        let fresh = try await detail(edit.id, context)
        guard fresh.request == edit.request, fresh.receipt == edit.receipt, fresh.baseValue == edit.baseValue,
              fresh.eligible, fresh.application == application, let latest = fresh.current, !latest.deleted,
              latest.value == pending.request.expectedValue || latest.value == edit.request.value
        else { throw StaffOwnerFieldEditError.conflict }
        try dependencies.check(context)
        try dependencies.apply(edit, pending.request.expectedValue, context)
        try dependencies.check(context)
        pending.phase = "saved"; state.pending[edit.id] = pending
        try save(state, context)
    }

    func synchronize(_ context: StaffReplicaSourceContext) async throws {
        let key = Self.key(context.scope), lock = try SharedTimeMutationGate.begin(key)
        defer { SharedTimeMutationGate.finish(key, id: lock) }
        try dependencies.check(context)
        if displayScope != context.scope { clearDisplay(); displayScope = context.scope }
        reviews = []
        var state = try load(context)
        if state.queue.isEmpty {
            let page = try await request(StaffOwnerFieldEditPage.self,
                path: StaffOwnerFieldEditTransport.path(context.scope, after: state.after), context: context)
            try page.validate(context.scope, after: state.after)
            state.queue = page.commandIDs; state.after = page.nextCursor; try save(state, context)
        }
        let ids = Set(state.queue).union(state.pending.keys).sorted()
        let ordered = ids.filter { $0 > (state.lastAttempted ?? "") } + ids.filter { $0 <= (state.lastAttempted ?? "") }
        for id in ordered.prefix(8) {
            let edit = try await detail(id, context)
            do {
                try await apply(edit, reviewed: false, state: &state, context: context)
                if state.pending[id]?.phase == "saved" { review(edit, context: context, message: "Saved to office records; awaiting source confirmation.") }
            } catch {
                try dependencies.check(context)
                // Re-read the durable journal after a failed write. An in-memory
                // phase must never be mistaken for a successfully saved intent.
                state = try load(context)
                review(edit, context: context, message: (error as? StaffOwnerFieldEditError)?.localizedDescription ?? "This field edit needs another sync or review. Its original was retained.")
            }
            state.queue.removeAll { $0 == id }; state.lastAttempted = id; try save(state, context)
        }
        message = reviews.isEmpty ? "Field updates checked." : "\(reviews.count) field updates need confirmation or review."
    }

    func confirmPublished(_ context: StaffReplicaSourceContext) async throws {
        let key = Self.key(context.scope), lock = try SharedTimeMutationGate.begin(key)
        defer { SharedTimeMutationGate.finish(key, id: lock) }
        var state = try load(context)
        for id in state.pending.keys.sorted() where state.pending[id]?.phase == "saved" {
            guard let pending = state.pending[id] else { throw StaffReplicaSourceSyncError.storage }
            do {
                let application = try await request(StaffOwnerFieldEditApplication.self,
                    path: StaffOwnerFieldEditTransport.root + "/" + id + "/confirm", method: "POST",
                    body: StaffWorkspacePublicationContract.encode(pending.request.confirmation), context: context)
                try application.validate(pending.request, scope: context.scope)
                guard application.state == "published" else { throw StaffReplicaSourceSyncError.invalid }
                state.pending[id] = nil; try save(state, context); reviews.removeAll { $0.id == id }
            } catch {
                try dependencies.check(context); state = try load(context)
                review(pending.edit, context: context, message: "Saved field update is awaiting source confirmation. The original receipt was retained.")
            }
        }
        message = reviews.isEmpty ? "Field updates are applied and confirmed in the company source." : "\(reviews.count) field updates still need confirmation or review."
    }

    func applyReviewed(_ review: StaffOwnerFieldEditReview, context: StaffReplicaSourceContext) async throws {
        let key = Self.key(context.scope), lock = try SharedTimeMutationGate.begin(key)
        defer { SharedTimeMutationGate.finish(key, id: lock) }
        try dependencies.check(context)
        guard displayScope == context.scope, review.canApplyReviewed,
              try dependencies.read(review.edit, context) == review.officeValue else { throw StaffOwnerFieldEditError.conflict }
        let current = try await detail(review.id, context)
        guard current == review.edit else { throw StaffOwnerFieldEditError.conflict }
        var state = try load(context)
        try await apply(current, reviewed: true, state: &state, context: context)
    }
}
