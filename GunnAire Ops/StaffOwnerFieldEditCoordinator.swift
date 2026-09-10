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
                    check: {
                        try StaffReplicaSourceDependencies.verify(context)
                        try StaffOwnerFieldHandoffFence.checkWrite(context.scope, id: edit.id, store: StaffWorkspaceSourceStaging.device)
                    })
            }, title: { edit, context in
                let modelContext = ModelContext(try container(context)); modelContext.autosaveEnabled = false
                return try StaffOwnerFieldEditModels.target(edit, context: modelContext).title
            })
    }
}

struct StaffOwnerFieldEditPending: Codable, Equatable {
    let edit: StaffOwnerFieldEdit
    let request: StaffOwnerFieldEditPrepare
    var phase: String
    var application: StaffOwnerFieldEditApplication?
    var writeBoundaryVersion: Int? = nil
}
struct StaffOwnerFieldEditJournal: Codable {
    let version: Int
    let scope: StaffReplicaSourceScope
    var queue: [String] = []
    var after: String?
    var lastAttempted: String?
    var pending: [String: StaffOwnerFieldEditPending] = [:]
    var keepOffice: [String: StaffOwnerFieldEditKeepPending]? = nil
    var observations: [String: StaffOwnerFieldObservationPending]? = nil
}
struct StaffOwnerFieldEditReview: Identifiable {
    let edit: StaffOwnerFieldEdit
    let title: String
    let officeValue: StaffWorkspaceValue?
    let message: String
    let canApplyReviewed: Bool
    var canKeepOffice: Bool = false
    var canConfirmObserved: Bool = false
    var canRelease: Bool = false
    var id: String { edit.id }
}

@MainActor final class StaffOwnerFieldEditCoordinator: ObservableObject {
    static let shared = StaffOwnerFieldEditCoordinator()
    let dependencies: StaffOwnerFieldEditDependencies
    @Published private(set) var reviews: [StaffOwnerFieldEditReview] = []
    @Published private(set) var message = "Check for saved field updates."
    @Published private(set) var hasMore = false
    private var displayScope: StaffReplicaSourceScope?
    init(dependencies: StaffOwnerFieldEditDependencies? = nil) { self.dependencies = dependencies ?? .live }
    static func key(_ scope: StaffReplicaSourceScope) -> String { "owner-field-edits-v1\n" + scope.key }
    func clearDisplay() { reviews = []; displayScope = nil; hasMore = false; message = "Check for saved field updates." }
    private func load(_ context: StaffReplicaSourceContext) throws -> StaffOwnerFieldEditJournal {
        try dependencies.check(context)
        guard let bytes = try dependencies.store.read(Self.key(context.scope)) else { return .init(version: 1, scope: context.scope) }
        let value = try StaffOwnerFieldEditWire.decode(StaffOwnerFieldEditJournal.self, from: bytes, maximum: 64 * 1024 * 1024)
        try validate(value, context)
        return value
    }
    private func validate(_ value: StaffOwnerFieldEditJournal, _ context: StaffReplicaSourceContext) throws {
        guard value.version == 1, value.scope == context.scope, value.queue.count <= 50,
              value.queue == Set(value.queue).sorted(), value.queue.allSatisfy(CloudKitStaffSetupPolicy.canonicalID),
              value.after.map(CloudKitStaffSetupPolicy.canonicalID) ?? true,
              value.lastAttempted.map(CloudKitStaffSetupPolicy.canonicalID) ?? true, value.pending.count <= 32,
              (value.keepOffice?.count ?? 0) <= 32, (value.observations?.count ?? 0) <= 32 else {
            throw StaffReplicaSourceSyncError.storage
        }
        for (id, pending) in value.pending {
            try pending.request.validate(edit: pending.edit, scope: context.scope)
            guard id == pending.edit.id, ["prepared", "applying", "saved"].contains(pending.phase),
                  pending.phase == "prepared" || pending.application != nil,
                  pending.writeBoundaryVersion == nil || pending.writeBoundaryVersion == 1,
                  pending.phase != "applying" || pending.writeBoundaryVersion == 1 else { throw StaffReplicaSourceSyncError.storage }
            try pending.application?.validate(pending.request, scope: context.scope)
        }
        for (id, pending) in value.keepOffice ?? [:] {
            guard id == pending.edit.id else { throw StaffReplicaSourceSyncError.storage }
            try pending.request.validate(context.scope, edit: pending.edit)
        }
        for (id, pending) in value.observations ?? [:] {
            guard id == pending.edit.id, value.pending[id] == nil, value.keepOffice?[id] == nil else { throw StaffReplicaSourceSyncError.storage }
            try pending.request.validate(context.scope, edit: pending.edit)
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
        return try StaffOwnerFieldEditWire.decode(type, from: bytes)
    }
    private func detail(_ id: String, _ context: StaffReplicaSourceContext) async throws -> StaffOwnerFieldEdit {
        let edit = try await request(StaffOwnerFieldEdit.self, path: StaffOwnerFieldEditTransport.path(context.scope, id: id), context: context)
        try edit.validate(context.scope)
        guard edit.id == id else { throw StaffReplicaSourceSyncError.invalid }
        return edit
    }
    private func review(_ edit: StaffOwnerFieldEdit, context: StaffReplicaSourceContext, message: String) {
        let local = try? dependencies.read(edit, context)
        let state = try? load(context)
        let matchesOffice = edit.current?.deleted == false && local != nil && local == edit.current?.value
        let observing = state?.observations?[edit.id] != nil
        let writable = (try? StaffOwnerFieldHandoffFence.checkWrite(context.scope, id: edit.id, store: dependencies.store)) != nil
        let fenced = try? StaffOwnerFieldHandoffFence.load(context.scope, id: edit.id, store: dependencies.store)
        let canResolveFenced = fenced.map { $0.edit.application == edit.application && edit.application?.state == "prepared" } ?? false
        let canApply = writable && state != nil && !observing && state?.keepOffice?[edit.id] == nil && edit.eligible && edit.application == nil && matchesOffice
        let claimOwned = edit.application.map { $0.ownerEmail == context.scope.actorEmail && $0.ownerStoreID == context.scope.storeUUID.lowercased() } ?? true
        let canKeep = (writable || canResolveFenced) && state != nil && !observing && edit.resolution == nil && edit.application?.state != "published" && claimOwned && matchesOffice
        let canObserve = writable && state != nil && state?.pending[edit.id] == nil && state?.keepOffice?[edit.id] == nil && matchesOffice
            && edit.application?.state == "prepared"
            && (try? StaffOwnerFieldObservationRequest(edit: edit, scope: context.scope, operation: UUID())) != nil
        reviews.removeAll { $0.id == edit.id }
        let title = (try? dependencies.title?(edit, context)) ?? StaffWorkspacePublicationReview.label(edit.request.recordKind)
        let canRelease = writable && !observing && state?.keepOffice?[edit.id] == nil && matchesOffice &&
            state?.pending[edit.id].map { pending in
                guard let request = try? StaffOwnerFieldHandoffRequest(edit: edit, scope: context.scope, operation: UUID()) else { return false }
                return (try? StaffOwnerFieldHandoffFence(version: 1, scope: context.scope, edit: edit, pending: pending, request: request).validate(context.scope)) != nil
            } == true
        reviews.append(.init(edit: edit, title: title, officeValue: local, message: message, canApplyReviewed: canApply,
                             canKeepOffice: canKeep, canConfirmObserved: canObserve, canRelease: canRelease))
    }
    private func apply(_ edit: StaffOwnerFieldEdit, reviewed: Bool, state: inout StaffOwnerFieldEditJournal,
                       context: StaffReplicaSourceContext) async throws {
        if let fence = try StaffOwnerFieldHandoffFence.load(context.scope, id: edit.id, store: dependencies.store) {
            guard fence.edit.request == edit.request, fence.edit.receipt == edit.receipt, fence.edit.baseValue == edit.baseValue else { throw StaffReplicaSourceSyncError.storage }
            if edit.resolution != nil { try finishResolution(edit, state: &state, context: context); return }
            if let pending = state.keepOffice?[edit.id] { try await retryKeep(pending, state: &state, context: context); return }
            try await retryHandoff(fence, state: &state, context: context); return
        }
        if let pending = state.observations?[edit.id] { try await retryObservation(pending, current: edit, state: &state, context: context); return }
        if edit.resolution != nil { try finishResolution(edit, state: &state, context: context); return }
        if let pending = state.keepOffice?[edit.id] { try await retryKeep(pending, state: &state, context: context); return }
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
            state.pending[edit.id] = .init(edit: edit, request: original, phase: "prepared", application: nil, writeBoundaryVersion: edit.application == nil ? 1 : nil)
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
        try StaffOwnerFieldHandoffFence.checkWrite(context.scope, id: edit.id, store: dependencies.store)
        // Durable entry into the save boundary precedes any model callback.
        // Legacy/uncertain work never gains evidence that no save was attempted.
        if pending.writeBoundaryVersion == 1 {
            pending.phase = "applying"; state.pending[edit.id] = pending; try save(state, context)
        }
        try StaffOwnerFieldHandoffFence.checkWrite(context.scope, id: edit.id, store: dependencies.store)
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
        let ids = Set(state.queue).union(state.pending.keys).union((state.keepOffice ?? [:]).keys).union((state.observations ?? [:]).keys).sorted()
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
                // Only a new before-save intent needs a post-failure claim
                // refresh for handoff. Ordinary review backlogs remain one
                // detail read per command, preserving their bounded work.
                let needsClaimReview = state.pending[id]?.phase == "prepared" && state.pending[id]?.writeBoundaryVersion == 1
                let latest = needsClaimReview ? ((try? await detail(id, context)) ?? edit) : edit
                try dependencies.check(context)
                review(latest, context: context, message: (error as? StaffOwnerFieldEditError)?.localizedDescription ?? "This field edit needs another sync or review. Its original was retained.")
            }
            state.queue.removeAll { $0 == id }; state.lastAttempted = id; try save(state, context)
        }
        hasMore = !state.queue.isEmpty || state.after != nil
        message = hasMore ? "More field updates remain to be checked." : (reviews.isEmpty ? "Field updates checked." : "\(reviews.count) field updates need confirmation or review.")
    }

    func confirmPublished(_ context: StaffReplicaSourceContext) async throws {
        let key = Self.key(context.scope), lock = try SharedTimeMutationGate.begin(key)
        defer { SharedTimeMutationGate.finish(key, id: lock) }
        var state = try load(context)
        for id in state.pending.keys.sorted() where state.pending[id]?.phase == "saved" && state.keepOffice?[id] == nil {
            try StaffOwnerFieldHandoffFence.checkWrite(context.scope, id: id, store: dependencies.store)
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
        message = hasMore ? "More field updates remain to be checked." : (reviews.isEmpty ? "Field updates checked; saved changes confirmed." : "\(reviews.count) field updates still need confirmation or review.")
    }

    func applyReviewed(_ review: StaffOwnerFieldEditReview, context: StaffReplicaSourceContext) async throws {
        let key = Self.key(context.scope), lock = try SharedTimeMutationGate.begin(key)
        defer { SharedTimeMutationGate.finish(key, id: lock) }
        try dependencies.check(context)
        try StaffOwnerFieldHandoffFence.checkWrite(context.scope, id: review.id, store: dependencies.store)
        guard displayScope == context.scope, review.canApplyReviewed,
              try dependencies.read(review.edit, context) == review.officeValue else { throw StaffOwnerFieldEditError.conflict }
        let current = try await detail(review.id, context)
        guard current == review.edit else { throw StaffOwnerFieldEditError.conflict }
        var state = try load(context)
        guard state.keepOffice?[review.id] == nil, state.observations?[review.id] == nil else { throw StaffOwnerFieldEditError.conflict }
        try await apply(current, reviewed: true, state: &state, context: context)
    }

    static func keepArchiveKey(_ scope: StaffReplicaSourceScope, operationID: String) -> String {
        "owner-field-keep-history-v1\n" + scope.key + "\n" + operationID
    }
    private func archiveKeep(_ pending: StaffOwnerFieldEditKeepPending, application: StaffOwnerFieldEditPending?,
                             resolution: StaffOwnerFieldEditResolution? = nil, supersededAt: Int? = nil, supersededByClaim: String? = nil,
                             context: StaffReplicaSourceContext) throws {
        try dependencies.check(context)
        let archive = StaffOwnerFieldEditKeepArchive(version: 1, scope: context.scope, pending: pending,
            applicationIntent: application, resolution: resolution, supersededAtRevision: supersededAt, supersededByClaim: supersededByClaim)
        try archive.validate(context.scope)
        let bytes = try StaffWorkspacePublicationContract.encode(archive)
        guard bytes.count <= 64 * 1024 * 1024 else { throw StaffReplicaSourceSyncError.storage }
        let key = Self.keepArchiveKey(context.scope, operationID: pending.request.operationID)
        if let existing = try dependencies.store.read(key) {
            let original = try StaffWorkspacePublicationContract.decode(StaffOwnerFieldEditKeepArchive.self, from: existing, maximum: 64 * 1024 * 1024)
            try original.validate(context.scope)
            guard original.pending.request == pending.request,
                  original.pending.edit.request == pending.edit.request, original.pending.edit.receipt == pending.edit.receipt,
                  original.pending.edit.baseValue == pending.edit.baseValue, original.pending.edit.shareID == pending.edit.shareID,
                  original.resolution == resolution
            else { throw StaffReplicaSourceSyncError.storage }
        } else { try dependencies.store.write(key, bytes) }
        try dependencies.check(context)
    }
    private func finishResolution(_ edit: StaffOwnerFieldEdit, state: inout StaffOwnerFieldEditJournal,
                                  context: StaffReplicaSourceContext) throws {
        guard let resolution = edit.resolution else { throw StaffReplicaSourceSyncError.invalid }
        try resolution.validate(edit: edit, scope: context.scope)
        if let application = state.pending[edit.id], application.application != nil || edit.application != nil {
            guard application.request.operationID == resolution.request.claimOperationID,
                  application.request.ownerStoreID == resolution.request.ownerStoreID,
                  resolution.ownerEmail == context.scope.actorEmail else { throw StaffOwnerFieldEditError.otherDevice }
        }
        if let pending = state.keepOffice?[edit.id] {
            try resolution.validate(pending.request, edit: pending.edit, scope: context.scope)
            try archiveKeep(pending, application: state.pending[edit.id], resolution: resolution, context: context)
        } else if state.pending[edit.id] != nil {
            // Recovery after restoring an older local journal: the authenticated
            // server receipt carries the exact original decision, not a new ID
            // or a request rebased onto today's office value.
            let pending = StaffOwnerFieldEditKeepPending(edit: edit, request: resolution.request)
            try pending.request.validate(context.scope, edit: edit)
            try archiveKeep(pending, application: state.pending[edit.id], resolution: resolution, context: context)
        }
        state.keepOffice?[edit.id] = nil; state.pending[edit.id] = nil
        try save(state, context); reviews.removeAll { $0.id == edit.id }
    }
    private func retryKeep(_ pending: StaffOwnerFieldEditKeepPending, state: inout StaffOwnerFieldEditJournal,
                           context: StaffReplicaSourceContext) async throws {
        try pending.request.validate(context.scope, edit: pending.edit)
        let resolution = try await request(StaffOwnerFieldEditResolution.self,
            path: StaffOwnerFieldEditTransport.root + "/" + pending.edit.id + "/keep-office", method: "POST",
            body: StaffWorkspacePublicationContract.encode(pending.request), context: context)
        try resolution.validate(pending.request, edit: pending.edit, scope: context.scope)
        try archiveKeep(pending, application: state.pending[pending.edit.id], resolution: resolution, context: context)
        state.keepOffice?[pending.edit.id] = nil; state.pending[pending.edit.id] = nil
        try save(state, context); reviews.removeAll { $0.id == pending.edit.id }
    }
    func keepOffice(_ review: StaffOwnerFieldEditReview, context: StaffReplicaSourceContext) async throws {
        let key = Self.key(context.scope), lock = try SharedTimeMutationGate.begin(key)
        defer { SharedTimeMutationGate.finish(key, id: lock) }
        try dependencies.check(context)
        guard displayScope == context.scope, review.canKeepOffice,
              try dependencies.read(review.edit, context) == review.officeValue else { throw StaffOwnerFieldEditError.conflict }
        let current = try await detail(review.id, context)
        guard current == review.edit, try dependencies.read(current, context) == current.current?.value else { throw StaffOwnerFieldEditError.conflict }
        if let fence = try StaffOwnerFieldHandoffFence.load(context.scope, id: review.id, store: dependencies.store) {
            // A rejected/stale release may still be closed without writing any
            // model field. Never remove its write fence or resolve a new claim.
            guard current.application == fence.edit.application, current.application?.state == "prepared" else { throw StaffOwnerFieldEditError.released }
        }
        var state = try load(context)
        guard state.observations?[review.id] == nil else { throw StaffOwnerFieldEditError.conflict }
        if let original = state.keepOffice?[review.id] {
            let claim = current.application?.operationID ?? ""
            if original.request.expectedRevision == current.current?.revision && original.request.claimOperationID == claim {
                try await retryKeep(original, state: &state, context: context); return
            }
            guard current.resolution == nil, let revision = current.current?.revision else { throw StaffOwnerFieldEditError.conflict }
            let advanced = revision > original.request.expectedRevision
            let claimed = original.request.claimOperationID.isEmpty && !claim.isEmpty
            guard advanced || claimed else { throw StaffOwnerFieldEditError.conflict }
            // The server source revision cannot go backwards; the superseded
            // exact request can no longer pass its expected-revision fence.
            try archiveKeep(original, application: state.pending[review.id], supersededAt: advanced ? revision : nil,
                supersededByClaim: advanced ? nil : claim, context: context)
        }
        guard (state.keepOffice?.count ?? 0) < 32 || state.keepOffice?[review.id] != nil else { throw StaffReplicaSourceSyncError.storage }
        let pending = StaffOwnerFieldEditKeepPending(edit: current,
            request: try .init(edit: current, scope: context.scope, operation: dependencies.operation()))
        if state.keepOffice == nil { state.keepOffice = [:] }
        state.keepOffice?[review.id] = pending; try save(state, context)
        try await retryKeep(pending, state: &state, context: context)
        message = "Office value kept. The original field update remains in the audit history."
    }

    static func observationArchiveKey(_ scope: StaffReplicaSourceScope, operationID: String) -> String {
        "owner-field-observation-history-v1\n" + scope.key + "\n" + operationID
    }
    private func archiveObservation(_ archive: StaffOwnerFieldObservationArchive, context: StaffReplicaSourceContext) throws {
        try dependencies.check(context); try archive.validate(context.scope)
        let key = Self.observationArchiveKey(context.scope, operationID: archive.pending.request.operationID)
            + (archive.supersededAtRevision != nil ? "\nsuperseded" : "")
        if let bytes = try dependencies.store.read(key) {
            let original = try StaffWorkspacePublicationContract.decode(StaffOwnerFieldObservationArchive.self, from: bytes, maximum: 64 * 1024 * 1024)
            try original.validate(context.scope)
            guard original.pending == archive.pending else { throw StaffReplicaSourceSyncError.storage }
            if let revision = original.supersededAtRevision {
                guard let newer = archive.supersededAtRevision, newer >= revision else { throw StaffReplicaSourceSyncError.storage }
            } else {
                guard archive.supersededAtRevision == nil,
                      (original.receipt?.application ?? original.publishedElsewhere) == (archive.receipt?.application ?? archive.publishedElsewhere)
                else { throw StaffReplicaSourceSyncError.storage }
                if let receipt = original.receipt, let received = archive.receipt {
                    guard receipt == received else { throw StaffReplicaSourceSyncError.storage }
                }
            }
        } else {
            let bytes = try StaffWorkspacePublicationContract.encode(archive)
            guard bytes.count <= 64 * 1024 * 1024 else { throw StaffReplicaSourceSyncError.storage }
            try dependencies.store.write(key, bytes)
        }
        try dependencies.check(context)
    }
    private func retryObservation(_ pending: StaffOwnerFieldObservationPending, current: StaffOwnerFieldEdit,
                                  state: inout StaffOwnerFieldEditJournal, context: StaffReplicaSourceContext) async throws {
        try pending.request.validate(context.scope, edit: pending.edit)
        guard current.request == pending.edit.request, current.receipt == pending.edit.receipt,
              current.shareID == pending.edit.shareID, current.baseValue == pending.edit.baseValue,
              current.resolution == nil else { throw StaffReplicaSourceSyncError.invalid }
        var archive = StaffOwnerFieldObservationArchive(version: 1, scope: context.scope, pending: pending)
        do {
            let receipt = try await request(StaffOwnerFieldObservationReceipt.self,
                path: StaffOwnerFieldEditTransport.root + "/" + current.id + "/confirm-observed", method: "POST",
                body: StaffWorkspacePublicationContract.encode(pending.request), context: context)
            try receipt.validate(pending, scope: context.scope); archive.receipt = receipt
        } catch {
            try dependencies.check(context)
            // The authenticated detail can prove the original claim completed
            // elsewhere even when today's field has moved on. This is NOT a
            // fabricated witness for an unacknowledged observation request.
            guard let application = current.application, application.state == "published" else { throw error }
            try application.validatePublication(of: pending.edit); archive.publishedElsewhere = application
        }
        try archiveObservation(archive, context: context)
        state.observations?[current.id] = nil; try save(state, context)
        reviews.removeAll { $0.id == current.id }
    }
    func confirmObserved(_ review: StaffOwnerFieldEditReview, context: StaffReplicaSourceContext) async throws {
        let key = Self.key(context.scope), lock = try SharedTimeMutationGate.begin(key)
        defer { SharedTimeMutationGate.finish(key, id: lock) }
        try dependencies.check(context)
        try StaffOwnerFieldHandoffFence.checkWrite(context.scope, id: review.id, store: dependencies.store)
        guard displayScope == context.scope, review.canConfirmObserved,
              try dependencies.read(review.edit, context) == review.officeValue else { throw StaffOwnerFieldEditError.conflict }
        let current = try await detail(review.id, context)
        guard current == review.edit, try dependencies.read(current, context) == current.current?.value else { throw StaffOwnerFieldEditError.conflict }
        var state = try load(context)
        guard state.pending[review.id] == nil, state.keepOffice?[review.id] == nil else { throw StaffOwnerFieldEditError.conflict }
        if let original = state.observations?[review.id] {
            if original.request.expectedRevision == current.current?.revision {
                try await retryObservation(original, current: current, state: &state, context: context); return
            }
            guard let revision = current.current?.revision, revision > original.request.expectedRevision else { throw StaffOwnerFieldEditError.conflict }
            try archiveObservation(.init(version: 1, scope: context.scope, pending: original, supersededAtRevision: revision), context: context)
        }
        guard (state.observations?.count ?? 0) < 32 || state.observations?[review.id] != nil else { throw StaffReplicaSourceSyncError.storage }
        let pending = StaffOwnerFieldObservationPending(edit: current,
            request: try .init(edit: current, scope: context.scope, operation: dependencies.operation()))
        if state.observations == nil { state.observations = [:] }
        state.observations?[review.id] = pending; try save(state, context)
        try await retryObservation(pending, current: current, state: &state, context: context)
        message = "Existing company update confirmed. No field value was reapplied."
    }

    private func retryHandoff(_ fence: StaffOwnerFieldHandoffFence, state: inout StaffOwnerFieldEditJournal,
                              context: StaffReplicaSourceContext) async throws {
        try dependencies.check(context); try fence.validate(context.scope)
        let key = StaffOwnerFieldHandoffFence.key(context.scope, id: fence.edit.id) + "\nreceipt"
        if let bytes = try dependencies.store.read(key) {
            let original = try StaffOwnerFieldEditWire.decode(StaffOwnerFieldHandoffReceipt.self, from: bytes)
            try original.validate(fence)
        } else {
            let receipt = try await request(StaffOwnerFieldHandoffReceipt.self,
                path: StaffOwnerFieldEditTransport.root + "/" + fence.edit.id + "/release", method: "POST",
                body: StaffWorkspacePublicationContract.encode(fence.request), context: context)
            try receipt.validate(fence)
            let bytes = try StaffWorkspacePublicationContract.encode(receipt)
            guard bytes.count <= StaffOwnerFieldEditTransport.maximumResponseBytes else { throw StaffReplicaSourceSyncError.storage }
            try dependencies.store.write(key, bytes)
            try dependencies.check(context)
            guard let durable = try dependencies.store.read(key),
                  try StaffOwnerFieldEditWire.decode(StaffOwnerFieldHandoffReceipt.self, from: durable) == receipt
            else { throw StaffReplicaSourceSyncError.storage }
        }
        // The immutable fence retains the complete original intent after queue
        // cleanup. A deleted/rebuilt queue still cannot authorize a local write.
        if state.pending[fence.edit.id] != nil { state.pending[fence.edit.id] = nil; try save(state, context) }
        reviews.removeAll { $0.id == fence.edit.id }
    }

    func release(_ review: StaffOwnerFieldEditReview, context: StaffReplicaSourceContext) async throws {
        let key = Self.key(context.scope), lock = try SharedTimeMutationGate.begin(key)
        defer { SharedTimeMutationGate.finish(key, id: lock) }
        try dependencies.check(context)
        guard displayScope == context.scope, review.canRelease,
              try dependencies.read(review.edit, context) == review.officeValue else { throw StaffOwnerFieldEditError.conflict }
        var state = try load(context)
        if let fence = try StaffOwnerFieldHandoffFence.load(context.scope, id: review.id, store: dependencies.store) {
            try await retryHandoff(fence, state: &state, context: context); return
        }
        let current = try await detail(review.id, context)
        guard current == review.edit, try dependencies.read(current, context) == current.current?.value,
              state.keepOffice?[review.id] == nil, state.observations?[review.id] == nil,
              let pending = state.pending[review.id] else { throw StaffOwnerFieldEditError.conflict }
        let fence = StaffOwnerFieldHandoffFence(version: 1, scope: context.scope, edit: current, pending: pending,
            request: try .init(edit: current, scope: context.scope, operation: dependencies.operation()))
        try fence.validate(context.scope)
        let bytes = try StaffWorkspacePublicationContract.encode(fence)
        guard bytes.count <= 64 * 1024 * 1024 else { throw StaffReplicaSourceSyncError.storage }
        try dependencies.store.write(StaffOwnerFieldHandoffFence.key(context.scope, id: review.id), bytes)
        try dependencies.check(context)
        guard try StaffOwnerFieldHandoffFence.load(context.scope, id: review.id, store: dependencies.store) == fence else { throw StaffReplicaSourceSyncError.storage }
        try await retryHandoff(fence, state: &state, context: context)
        message = "Field update handed off. Continue on another approved owner device; this device will not apply it."
    }
}
