import Foundation
import SwiftData
import Combine

/// Connects actual saved dispatch edits to server-owned billing authority.
/// There are no provider/accounting writes here. Assignment POSTs are replayed
/// only with their original operation ID, expected revision and connection.
@MainActor
final class JobBillingDispatch: ObservableObject {
    static let shared = JobBillingDispatch()
    @Published private(set) var generation = 0
    private let store: JobBillingJournalStore
    private let api: QuickBooksDataAPI?
    private let bootstrapStore: JobBillingBootstrapStore
    private let fixtureCompanyID: UUID?
    private let client: BillingPublicationClient
    private let actor: () -> String
    private let validateAccess: (ModelContext, String) throws -> Void
    private let fixture: Bool
    private var running: Set<String> = []

    init(store: JobBillingJournalStore? = nil, api: QuickBooksDataAPI? = nil,
         client: BillingPublicationClient? = nil, actor: (() -> String)? = nil,
         validateAccess: ((ModelContext, String) throws -> Void)? = nil, fixture: Bool = false,
         bootstrapStore: JobBillingBootstrapStore? = nil, fixtureCompanyID: UUID? = nil) {
        // Resolve actor-isolated defaults inside this MainActor initializer,
        // not in the caller's default-argument evaluation context.
        self.store = store ?? .device
        // Device OAuth is supported only by explicit legacy test fixtures.
        precondition(api == nil || fixture)
        precondition(fixtureCompanyID == nil || (fixture && GunnAireCloudKit.usesTestDatabase))
        self.api = api
        self.bootstrapStore = bootstrapStore ?? .device
        self.fixtureCompanyID = fixtureCompanyID
        self.client = client ?? GunnAireBackendService.billingPublicationClient
        self.actor = actor ?? { AppAccess.normalizedEmail(AppIdentity.currentEmail) }
        self.validateAccess = validateAccess ?? { try GoogleCalendarWorkflow.requireDispatchAccess(context: $0, email: $1) }
        self.fixture = fixture
    }

    struct Handle {
        let scope: JobBillingQueueScope
        let workflow: QuickBooksDataAPI.CapturedWorkspaceWorkflow
    }

    struct Review {
        let scope: JobBillingQueueScope
        let snapshot: JobBillingAssignmentSnapshot
        let localRevision: JobBillingLocalRevision
        let target: JobBillingTarget
        let record: JobBillingQueueRecord
    }

    private func business(_ context: ModelContext) throws -> JobBillingBusinessScope {
        guard !GunnAireCloudKit.usesTestDatabase || fixture,
              let company = fixtureCompanyID ?? CompanyWorkspaceAccessController.shared.verifiedCompanyID else {
            throw JobBillingDispatchError.access
        }
        let value = JobBillingBusinessScope(companyID: company, actorEmail: actor())
        try value.validate(); try validateAccess(context, value.actorEmail)
        return value
    }

    private func bootstrap(_ business: JobBillingBusinessScope) throws -> JobBillingBootstrap {
        let value = try bootstrapStore.read(business)
        try value.validate(business)
        return value
    }

    private func businessOperation(_ context: ModelContext, business: JobBillingBusinessScope) throws -> WorkspaceProviderOperation {
        try WorkspaceProviderOperation.capture {
            do { return try self.business(context) == business } catch { return false }
        }
    }

    private func handle(_ connection: SharedJobBillingConnection, business: JobBillingBusinessScope,
                        operation: WorkspaceProviderOperation) throws -> Handle {
        try connection.validate(business.companyID); try operation.check()
        let api = QuickBooksDataAPI(sharedCompanyID: business.companyID, realmID: connection.realmID,
            environment: connection.environment, connectionRevision: connection.connectionRevision,
            operation: operation, billingPublisher: client)
        return .init(scope: connection.scope(business), workflow: try api.captureWorkspaceWorkflow())
    }

    /// No cached descriptor authorizes network work. Every new run checks the
    /// server, retaining the initiating workspace/actor through suspension.
    func discover(context: ModelContext, original: Handle? = nil,
                  preparation: WorkspaceProviderOperation? = nil,
                  isCurrent: @escaping () -> Bool = { true }) async throws -> Handle {
        try preparation?.check(); try original?.workflow.check()
        guard isCurrent() else { throw JobBillingDispatchError.changed }
        if let api {
            let captured = try capture(context: context)
            return .init(scope: captured.scope, workflow: try api.captureWorkspaceWorkflow(isCurrent: isCurrent))
        }
        let business = try business(context)
        let parent = try preparation ?? businessOperation(context, business: business)
        let operation = WorkspaceProviderOperation(parent: parent, isCurrent: isCurrent)
        try operation.check()
        let path = "/api/job-billing-assignments/connection?companyID=" + business.companyID.uuidString.lowercased()
        let connection: SharedJobBillingConnection
        do {
            let data = try await client.transport(path, "GET", nil)
            try operation.check(); try original?.workflow.check()
            guard data.count <= 16_384 else { throw JobBillingDispatchError.connection }
            connection = try JSONDecoder().decode(SharedJobBillingConnection.self, from: data)
            try connection.validate(business.companyID)
        } catch {
            try operation.check(); try original?.workflow.check()
            if case GunnAireBackendError.server(let status, _) = error {
                if status == 404 { throw JobBillingDispatchError.serverUpdate }
                if status == 401 || status == 403 { throw JobBillingDispatchError.access }
            }
            throw JobBillingDispatchError.connection
        }
        // Do not strand or move older realm-bound requests after reconnecting
        // to a different accounting company. Restore/review that original link.
        var saved = try bootstrap(business)
        if let prior = saved.connection, prior.scope(business) != connection.scope(business) {
            throw JobBillingDispatchError.connection
        }
        saved.connection = connection
        try bootstrapStore.write(saved)
        try importBootstrap(business, connection: connection)
        return try handle(connection, business: business, operation: operation)
    }

    private func importBootstrap(_ business: JobBillingBusinessScope, connection: SharedJobBillingConnection) throws {
        var saved = try bootstrap(business)
        let scope = connection.scope(business)
        for record in saved.records {
            guard let edit = record.pending else { throw JobBillingDispatchError.storage }
            try update(scope, jobID: record.id) { bound in
                if bound.importedBootstrapEditID == edit.id { return }
                if let customer = bound.confirmed?.assignment?.localCustomerID ?? bound.pending?.desired.localCustomerID,
                   customer != edit.desired.localCustomerID { throw JobBillingDispatchError.changed }
                let older = (bound.pending?.supersededRequests ?? []) + [bound.pending?.request].compactMap { $0 }
                bound.pending = .init(id: edit.id, original: edit.original, desired: edit.desired,
                    localRevision: edit.localRevision, baseline: nil,
                    state: bound.pending != nil || !older.isEmpty ? .review : edit.state,
                    supersededRequests: older)
                bound.importedBootstrapEditID = edit.id
            }
        }
        if !saved.records.isEmpty {
            saved.records.removeAll()
            try bootstrapStore.write(saved)
            generation &+= 1
        }
    }

    private func saveUnbound(_ call: ServiceCall, original: JobBillingTarget?, context: ModelContext,
                             saveLocal: (ModelContext) throws -> Void, startSync: Bool) throws -> UUID {
        let business = try business(context)
        let operation = try businessOperation(context, business: business)
        let (revision, target) = try JobBillingTarget.capture(call, context: context)
        let jobID = call.id
        var value = try bootstrap(business)
        let prior = value.records.first { $0.id == jobID }?.pending
        if let prior, prior.desired.localCustomerID != target.localCustomerID { throw JobBillingDispatchError.changed }
        let same = prior?.desired == target && prior?.localRevision == revision
        let editID = same ? prior!.id : UUID()
        let pending = JobBillingPendingEdit(id: editID, original: prior?.original ?? original, desired: target,
            localRevision: revision, baseline: nil, state: .prepared, supersededRequests: [])
        value.records.removeAll { $0.id == jobID }
        value.records.append(.init(id: jobID, pending: pending))
        try value.validate(business); try bootstrapStore.write(value)
        let activity = same ? nil : ServiceCallActivity.record(for: call, action: "Job billing access queued",
            detail: "The saved crew's field billing access is pending the business connection check.",
            actorEmail: business.actorEmail, in: context)
        do { try saveLocal(context) }
        catch {
            if let activity { context.delete(activity) }
            throw JobBillingDispatchError.save
        }
        // A post-save storage failure never reports that the job failed to save.
        do {
            try operation.check()
            value = try bootstrap(business)
            guard let index = value.records.firstIndex(where: { $0.id == jobID && $0.pending?.id == editID }) else {
                throw JobBillingDispatchError.changed
            }
            value.records[index].pending?.state = .queued
            try bootstrapStore.write(value)
        } catch { generation &+= 1; return editID }
        generation &+= 1
        if startSync {
            Task {
                do {
                    let handle = try await discover(context: context, preparation: operation)
                    try verifySaved(call, context: context, revision: revision, target: target)
                    guard try queue(handle.scope).records.first(where: { $0.id == jobID })?.pending?.id == editID else {
                        throw JobBillingDispatchError.changed
                    }
                    _ = try await synchronize(call, context: context, handle: handle, allowInitialBinding: true, send: true)
                } catch { /* Retain first-use intent; never guess another connection. */ }
            }
        }
        return editID
    }

    func capture(context: ModelContext) throws -> Handle {
        guard !GunnAireCloudKit.usesTestDatabase || fixture else { throw JobBillingDispatchError.connection }
        let email = actor()
        try validateAccess(context, email)
        guard !email.isEmpty else { throw JobBillingDispatchError.access }
        if api == nil {
            let business = try business(context)
            let saved = try bootstrap(business)
            guard let connection = saved.connection else { throw JobBillingDispatchError.connection }
            try importBootstrap(business, connection: connection)
            return try handle(connection, business: business, operation: businessOperation(context, business: business))
        }
        let workflow = try api!.captureWorkspaceWorkflow()
        guard let companyID = workflow.companyID, let realmID = workflow.realmID else { throw JobBillingDispatchError.connection }
        let scope = JobBillingQueueScope(companyID: companyID, realmID: realmID,
                                        environment: workflow.environment, actorEmail: email)
        try scope.validate()
        return Handle(scope: scope, workflow: workflow)
    }

    private func check(_ handle: Handle, context: ModelContext) throws {
        try handle.workflow.check()
        guard actor() == handle.scope.actorEmail else { throw JobBillingDispatchError.access }
        try validateAccess(context, handle.scope.actorEmail)
    }

    func record(jobID: UUID, context: ModelContext) throws -> JobBillingQueueRecord? {
        if api == nil {
            let saved = try bootstrap(business(context))
            if let unbound = saved.records.first(where: { $0.id == jobID }) { return unbound }
            guard let connection = saved.connection else { return nil }
            return try queue(connection.scope(saved.business)).records.first { $0.id == jobID }
        }
        let handle = try capture(context: context)
        return try queue(handle.scope).records.first { $0.id == jobID }
    }

    private func queue(_ scope: JobBillingQueueScope) throws -> JobBillingQueue {
        let result = try store.read(scope)
        try result.validate(scope)
        return result
    }

    private func update(_ scope: JobBillingQueueScope, jobID: UUID, observedConnection: String? = nil,
                        _ mutate: (inout JobBillingQueueRecord) throws -> Void) throws {
        var value = try queue(scope)
        let index: Int
        if let found = value.records.firstIndex(where: { $0.id == jobID }) { index = found }
        else { value.records.append(.init(id: jobID)); index = value.records.count - 1 }
        try mutate(&value.records[index])
        if let observedConnection { value.connectionRevision = observedConnection }
        try value.validate(scope)
        try store.write(value)
        generation &+= 1
    }

    /// Called after the form's own mutations, before any external follow-up.
    /// The prepared journal is durable before the model save. On failure it
    /// remains prepared and cannot dispatch until a fresh stored model agrees.
    @discardableResult
    func save(_ call: ServiceCall, original: JobBillingTarget?, context: ModelContext,
              saveLocal: (ModelContext) throws -> Void = { try $0.save() },
              startSync: Bool = true) throws -> UUID? {
        // Ordinary UI fixtures must never load a real journal or provider.
        if GunnAireCloudKit.usesTestDatabase && !fixture {
            do { try saveLocal(context); return nil } catch { throw JobBillingDispatchError.save }
        }
        try validateAccess(context, actor())
        if api == nil, try bootstrap(business(context)).connection == nil {
            return try saveUnbound(call, original: original, context: context, saveLocal: saveLocal, startSync: startSync)
        }
        let handle = try capture(context: context)
        let (revision, desired) = try JobBillingTarget.capture(call, context: context)
        let savedQueue = try queue(handle.scope)
        let prior = savedQueue.records.first { $0.id == call.id }
        if prior?.pending == nil, original == desired, desired.matches(prior?.confirmed?.assignment) {
            do { try saveLocal(context); return nil } catch { throw JobBillingDispatchError.save }
        }
        var editID = UUID()
        var stagedNewEdit = false
        try update(handle.scope, jobID: call.id) { record in
            if let old = record.pending, old.desired == desired, old.localRevision == revision {
                editID = old.id
                return
            }
            // A billed/approved job cannot be moved to another customer. Keep
            // the original authority visible instead of trying another ID.
            if let customerID = record.confirmed?.assignment?.localCustomerID ?? record.pending?.desired.localCustomerID,
               customerID != desired.localCustomerID { throw JobBillingDispatchError.changed }
            let old = record.pending
            let previous = (old?.supersededRequests ?? []) + [old?.request].compactMap { $0 }
            stagedNewEdit = true
            let baseline = old?.baseline ?? record.confirmed ?? savedQueue.connectionRevision.map {
                JobBillingAssignmentSnapshot(assignment: nil, connectionRevision: $0)
            }
            record.pending = .init(id: editID, original: old?.original ?? original,
                desired: desired, localRevision: revision, baseline: baseline,
                state: previous.isEmpty && old?.state != .review ? .prepared : .review,
                supersededRequests: previous)
        }
        let activity = stagedNewEdit ? ServiceCallActivity.record(for: call, action: "Job billing access queued",
            detail: desired.enabled ? "The saved crew's field billing access is pending server confirmation." : "Field billing access is being turned off for this saved job.",
            actorEmail: handle.scope.actorEmail, in: context) : nil
        do { try saveLocal(context) }
        catch {
            if let activity { context.delete(activity) }
            throw JobBillingDispatchError.save
        }
        do {
            try check(handle, context: context)
            try update(handle.scope, jobID: call.id) { record in
                guard record.pending?.id == editID else { throw JobBillingDispatchError.changed }
                if record.pending?.state == .prepared { record.pending?.state = .queued }
            }
        } catch { return editID } // Job DID save; prepared intent remains for recovery.
        if startSync {
            Task {
                do {
                    let fresh = try await discover(context: context, original: handle)
                    try verifySaved(call, context: context, revision: revision, target: desired)
                    guard try queue(fresh.scope).records.first(where: { $0.id == call.id })?.pending?.id == editID else {
                        throw JobBillingDispatchError.changed
                    }
                    _ = try await synchronize(call, context: context, handle: fresh, allowInitialBinding: true, send: true)
                } catch { /* The original durable edit remains visible from the job. */ }
            }
        }
        return editID
    }

    /// Automatic recovery is scoped to the original signed-in office account.
    /// An unbound first edit from an earlier process needs explicit review.
    func resume(context: ModelContext) async {
        guard !GunnAireCloudKit.usesTestDatabase || fixture else { return }
        do {
            let handle = try await discover(context: context)
            let pending = try queue(handle.scope).records.filter { $0.pending != nil }
            for record in pending {
                try check(handle, context: context)
                let matches = try context.fetch(FetchDescriptor<ServiceCall>()).filter { $0.id == record.id }
                guard matches.count == 1 else { continue } // Never adopt another/deleted job.
                _ = try? await synchronize(matches[0], context: context, handle: handle, send: true)
            }
        } catch { /* Retained queue; the job's review link supplies recovery. */ }
    }

    func refresh(_ call: ServiceCall, context: ModelContext, isCurrent: @escaping () -> Bool = { true }) async throws -> Review {
        let original = try JobBillingTarget.capture(call, context: context)
        let handle = try await discover(context: context, isCurrent: isCurrent)
        try verifySaved(call, context: context, revision: original.0, target: original.1)
        return try await synchronize(call, context: context, handle: handle, send: false)
    }

    /// Explicit confirmation is tied to the snapshot the office actually saw.
    /// Refreshing a conflict never adopts its revision for a blind overwrite.
    func applySavedCrew(_ call: ServiceCall, context: ModelContext, reviewed: Review,
                       isCurrent: @escaping () -> Bool = { true }) async throws -> Review {
        let handle = try await discover(context: context, isCurrent: isCurrent)
        guard handle.scope == reviewed.scope else { throw JobBillingDispatchError.changed }
        let (revision, target) = try JobBillingTarget.capture(call, context: context)
        guard revision == reviewed.localRevision, target == reviewed.target else { throw JobBillingDispatchError.changed }
        return try await synchronize(call, context: context, handle: handle, send: true, approval: reviewed)
    }

    private func verifySaved(_ call: ServiceCall, context: ModelContext,
                             revision: JobBillingLocalRevision, target: JobBillingTarget) throws {
        let (currentRevision, currentTarget) = try JobBillingTarget.capture(call, context: context)
        guard currentRevision == revision, currentTarget == target else { throw JobBillingDispatchError.changed }
        // A new context reads committed rows, not unsaved values in the form.
        let storedContext = ModelContext(context.container)
        storedContext.autosaveEnabled = false
        let stored = try storedContext.fetch(FetchDescriptor<ServiceCall>()).filter { $0.id == call.id }
        guard stored.count == 1 else { throw JobBillingDispatchError.save }
        let (savedRevision, savedTarget) = try JobBillingTarget.capture(stored[0], context: storedContext)
        guard savedRevision == revision, savedTarget == target else { throw JobBillingDispatchError.save }
    }

    func synchronize(_ call: ServiceCall, context: ModelContext, handle: Handle,
                             allowInitialBinding: Bool = false, send: Bool,
                             approval: Review? = nil) async throws -> Review {
        try check(handle, context: context)
        let (revision, target) = try JobBillingTarget.capture(call, context: context)
        let jobID = call.id
        let lock = handle.scope.storageKey + jobID.uuidString
        guard running.insert(lock).inserted else { throw JobBillingDispatchError.changed }
        defer { running.remove(lock) }
        let startingEditID = try queue(handle.scope).records.first { $0.id == jobID }?.pending?.id
        func stillCurrent(_ editID: UUID?) throws {
            try check(handle, context: context)
            try verifySaved(call, context: context, revision: revision, target: target)
            guard try queue(handle.scope).records.first(where: { $0.id == jobID })?.pending?.id == editID else {
                throw JobBillingDispatchError.changed
            }
        }
        try stillCurrent(startingEditID)
        let snapshot = try await client.assignmentSnapshot(handle.scope.job(jobID), customerID: target.localCustomerID,
                                                           workflow: handle.workflow)
        try stillCurrent(startingEditID)
        if let approval, approval.snapshot != snapshot { throw BillingPublicationError.reviewRequired }
        try update(handle.scope, jobID: jobID, observedConnection: snapshot.connectionRevision) { record in
            record.confirmed = snapshot
            if target.matches(snapshot.assignment) {
                // Read-only recovery of an accepted/lost response, or another
                // office's identical newer decision. No replay is necessary.
                record.pending = nil
            } else if let approval {
                let older = (record.pending?.supersededRequests ?? []) + [record.pending?.request].compactMap { $0 }
                record.pending = .init(id: UUID(), original: target, desired: target, localRevision: revision,
                    baseline: approval.snapshot, state: .queued, supersededRequests: older)
            } else if record.pending?.localRevision != nil && record.pending?.localRevision != revision {
                record.pending?.state = .review
            }
        }
        var record = try queue(handle.scope).records.first { $0.id == jobID }!
        guard var edit = record.pending else {
            return .init(scope: handle.scope, snapshot: snapshot, localRevision: revision, target: target, record: record)
        }
        guard edit.localRevision == revision, edit.desired == target else { throw JobBillingDispatchError.changed }

        if edit.state == .prepared { edit.state = .queued } // Fresh stored rows were verified above.
        let currentRevision = snapshot.assignment?.revision ?? 0
        let sameEpoch = edit.baseline?.connectionRevision == snapshot.connectionRevision
        let sameBase = (edit.baseline?.assignment?.revision ?? 0) == currentRevision
        let firstLiveEdit = edit.baseline == nil && allowInitialBinding &&
            (snapshot.assignment == nil || edit.original?.matches(snapshot.assignment) == true)
        if edit.request == nil && approval == nil && (!sameEpoch || !sameBase) && !firstLiveEdit {
            edit.state = .review
        }
        // An unusable approval is not revived merely because its roster matches.
        if snapshot.assignment?.enabled == true && snapshot.assignment?.usable == false && approval == nil { edit.state = .review }
        if let request = edit.request,
           request.connectionRevision != snapshot.connectionRevision || request.expectedRevision != currentRevision {
            edit.state = .review
        }
        try update(handle.scope, jobID: jobID) { $0.pending = edit }
        guard send, edit.state != .review else {
            record.pending = edit
            return .init(scope: handle.scope, snapshot: snapshot, localRevision: revision, target: target, record: record)
        }
        if edit.request == nil {
            edit.request = .init(companyID: handle.scope.companyID, realmID: handle.scope.realmID,
                environment: handle.scope.environment, serviceCallID: jobID, localCustomerID: target.localCustomerID,
                technicianEmails: target.technicianEmails, enabled: target.enabled, expectedRevision: currentRevision,
                operationID: edit.id, connectionRevision: snapshot.connectionRevision)
            try update(handle.scope, jobID: jobID) { $0.pending = edit }
        }
        try stillCurrent(edit.id)
        do {
            let assignment = try await client.saveAssignment(edit.request!, workflow: handle.workflow)
            try stillCurrent(edit.id)
            let confirmed = JobBillingAssignmentSnapshot(assignment: assignment, connectionRevision: snapshot.connectionRevision)
            try update(handle.scope, jobID: jobID) { $0.confirmed = confirmed; $0.pending = nil }
            record = try queue(handle.scope).records.first { $0.id == jobID }!
            return .init(scope: handle.scope, snapshot: confirmed, localRevision: revision, target: target, record: record)
        } catch {
            // Never replace a newer local edit or discard an uncertain request.
            if case BillingPublicationError.reviewRequired = error {
                try update(handle.scope, jobID: jobID) { record in
                    if record.pending?.id == edit.id { record.pending?.state = .review }
                }
            }
            throw error
        }
    }
}
