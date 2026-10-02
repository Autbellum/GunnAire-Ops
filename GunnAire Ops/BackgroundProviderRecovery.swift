import BackgroundTasks
import Foundation
import SwiftData

/// Callback-based Calendar requests create their own Swift task. This shared
/// lifetime closes their provider fence when iOS expires the parent refresh.
nonisolated final class BackgroundRefreshLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false
    private var completed = false

    var isExpired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expired
    }

    func expire(_ task: BGTask) {
        lock.lock()
        expired = true
        let shouldComplete = !completed
        completed = true
        lock.unlock()
        if shouldComplete { task.setTaskCompleted(success: false) }
    }

    func complete(_ task: BGTask, success: Bool) {
        lock.lock()
        let shouldComplete = !completed
        completed = true
        lock.unlock()
        if shouldComplete { task.setTaskCompleted(success: success) }
    }
}

/// iOS chooses when to launch a refresh and may give no launch at all. Every
/// provider mutation remains in its original durable, identity-checked outbox.
@MainActor
final class BackgroundProviderRecovery {
    static let shared = BackgroundProviderRecovery()
    nonisolated static let identifier = "com.gunnaire.ops.provider-recovery"

    private var registered = false

    private init() {}

    func registerAtLaunch() {
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                await BackgroundProviderRecovery.shared.handle(refresh)
            }
        }
        if !registered { NSLog("Background provider refresh registration is unavailable for this app build.") }
    }

    func scheduleAfterBackgrounding() {
        guard registered, BusinessLoginSelection.selected != nil,
              CompanyWorkspaceAccessController.shared.authorizedContainer != nil else { return }
        scheduleNext()
    }

    private func scheduleNext() {
        guard registered else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        do {
            // Apple replaces an earlier request with the same identifier.
            try BGTaskScheduler.shared.submit(request)
        } catch {
            NSLog("Background provider refresh could not be scheduled: %@", String(describing: error))
        }
    }

    private func handle(_ refresh: BGAppRefreshTask) async {
        if BusinessLoginSelection.selected != nil { scheduleNext() }
        let lifetime = BackgroundRefreshLifetime()
        let worker = Task { @MainActor in await runOnce(lifetime: lifetime) }
        refresh.expirationHandler = {
            lifetime.expire(refresh)
            worker.cancel()
        }
        let completed = await worker.value
        refresh.expirationHandler = nil
        lifetime.complete(refresh, success: completed && !worker.isCancelled && !lifetime.isExpired)
    }

    private func runOnce(lifetime: BackgroundRefreshLifetime) async -> Bool {
        guard let selected = BusinessLoginSelection.selected,
              !Task.isCancelled, !lifetime.isExpired else { return false }
        async let appleRestore: Void = AppleAuthManager.shared.restoreStoredSession()
        async let googleRestore: Void = GoogleAuthManager.shared.restoreStoredSession()
        _ = await (appleRestore, googleRestore)
        guard !Task.isCancelled, !lifetime.isExpired,
              BusinessLoginSelection.selected == selected,
              BusinessLoginSelection.resolvedProvider(
                selected: selected,
                appleBusinessSessionAvailable: AppleAuthManager.shared.isAuthenticated &&
                    AppleAuthManager.shared.workspaceSessionProof != nil,
                googleBusinessSessionAvailable: GoogleAuthManager.shared.isAuthenticated &&
                    GoogleAuthManager.shared.workspaceSessionProof != nil
              ) == selected else { return false }
        if selected == .apple {
            guard await AppleAuthManager.shared.validateCredentialState(),
                  !Task.isCancelled, !lifetime.isExpired else { return false }
        }

        let access = CompanyWorkspaceAccessController.shared
        await access.refreshIfStale(maxAge: CompanyWorkspaceAccessController.verificationInterval)
        guard !Task.isCancelled, !lifetime.isExpired,
              let container = access.authorizedContainer,
              let stamp = access.operationStamp,
              access.verifiedUser?.isActive == true else { return false }
        let businessEmail = AppAccess.normalizedEmail(AppIdentity.currentEmail)
        guard !businessEmail.isEmpty,
              businessEmail == AppAccess.normalizedEmail(access.verifiedUser?.email) else { return false }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let stillAuthorized: @MainActor () -> Bool = {
            !Task.isCancelled && !lifetime.isExpired && BusinessLoginSelection.selected == selected &&
                access.authorizedContainer === container && access.operationStamp == stamp &&
                AppAccess.normalizedEmail(AppIdentity.currentEmail) == businessEmail &&
                AppAccess.normalizedEmail(access.verifiedUser?.email) == businessEmail
        }
        guard let companyID = access.verifiedCompanyID else { return false }
        let turnKey = "GunnAireBackgroundProviderTurn.\(companyID.uuidString.lowercased())"
        let turn = max(0, UserDefaults.standard.integer(forKey: turnKey)) % RecoveryProvider.allCases.count
        UserDefaults.standard.set((turn + 1) % RecoveryProvider.allCases.count, forKey: turnKey)
        return await Self.runVerifiedProviders(
            stillAuthorized: stillAuthorized,
            order: Self.recoveryOrder(start: turn),
            calendar: {
                guard GoogleAuthManager.shared.googleCalendarAuthorizationState == .ready else { return true }
                let result = await GoogleCalendarScheduleSync.backgroundPublishPending(
                    auth: GoogleAuthManager.shared, context: context, signedInEmail: businessEmail,
                    isExpired: { lifetime.isExpired })
                if case .success = result { return true }
                return false
            },
            drive: {
                guard GoogleAuthManager.shared.googleDriveAuthorizationState == .ready,
                      access.verifiedRole == .admin else { return true }
                return await AutomaticGoogleDriveArchive.shared.recoverOneBackground(context: context)
            },
            quickBooks: {
                await recoverOnePreparedEstimate(container: container,
                    actorEmail: businessEmail, stillAuthorized: stillAuthorized)
            }
        )
    }

    /// Recheck the exact lease and business identity between providers. The
    /// outbox workers additionally fence each individual remote operation.
    nonisolated enum RecoveryProvider: Int, CaseIterable, Sendable {
        case calendar, drive, quickBooks
    }

    nonisolated static func recoveryOrder(start: Int) -> [RecoveryProvider] {
        let providers = RecoveryProvider.allCases
        let first = ((start % providers.count) + providers.count) % providers.count
        return (0..<providers.count).map { providers[(first + $0) % providers.count] }
    }

    static func runVerifiedProviders(
        stillAuthorized: @MainActor () -> Bool,
        order: [RecoveryProvider] = [.calendar, .drive, .quickBooks],
        calendar: @MainActor () async -> Bool,
        drive: @MainActor () async -> Bool,
        quickBooks: @MainActor () async -> Bool
    ) async -> Bool {
        guard order.count == RecoveryProvider.allCases.count,
              Set(order).count == RecoveryProvider.allCases.count else { return false }
        var allCompleted = true
        for provider in order {
            guard stillAuthorized() else { return false }
            let completed: Bool
            switch provider {
            case .calendar: completed = await calendar()
            case .drive: completed = await drive()
            case .quickBooks: completed = await quickBooks()
            }
            allCompleted = allCompleted && completed
        }
        return stillAuthorized() && allCompleted
    }

    nonisolated struct EstimateCandidate: Sendable {
        let id: UUID
        let customerID: UUID
        let createdAt: Date
        let serviceCallID: UUID?
        let customerRecordID: PersistentIdentifier
    }

    nonisolated struct EstimatePage: Sendable {
        let candidates: [EstimateCandidate]
        let nextOffset: Int
    }

    nonisolated static func estimatePage(container: ModelContainer, offset: Int,
                                         likelyUnlinkedOnly: Bool = false) async throws -> EstimatePage {
        try await Task.detached(priority: .utility) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let sort = [SortDescriptor(\Estimate.createdAt), SortDescriptor(\Estimate.id)]
            var query: FetchDescriptor<Estimate>
            if likelyUnlinkedOnly {
                query = FetchDescriptor<Estimate>(predicate: #Predicate {
                    $0.quickBooksID == nil || $0.quickBooksID == ""
                }, sortBy: sort)
            } else {
                // The second lane keeps legacy whitespace-only links reachable.
                query = FetchDescriptor<Estimate>(sortBy: sort)
            }
            query.fetchLimit = 16
            query.fetchOffset = offset
            let estimates = try context.fetch(query)
            return EstimatePage(candidates: estimates.compactMap { estimate in
                guard estimate.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
                      let customer = estimate.customer else { return nil }
                return EstimateCandidate(id: estimate.id, customerID: customer.id, createdAt: estimate.createdAt,
                    serviceCallID: estimate.serviceCallID, customerRecordID: customer.persistentModelID)
            }, nextOffset: estimates.count == 16 ? offset + 16 : 0)
        }.value
    }

    private func recoverOnePreparedEstimate(container: ModelContainer, actorEmail: String,
        stillAuthorized: @escaping @MainActor () -> Bool) async -> Bool {
        guard stillAuthorized(), let companyID = CompanyWorkspaceAccessController.shared.verifiedCompanyID,
              let role = CompanyWorkspaceAccessController.shared.verifiedRole else { return false }
        let laneKey = "GunnAireBackgroundEstimateLane.\(companyID.uuidString.lowercased())"
        let likelyUnlinkedOnly = UserDefaults.standard.integer(forKey: laneKey) % 2 == 0
        let cursorKey = "GunnAireBackgroundEstimateCursor.\(likelyUnlinkedOnly ? "unlinked" : "legacy").\(companyID.uuidString.lowercased())"
        let offset = max(0, UserDefaults.standard.integer(forKey: cursorKey))
        let page: EstimatePage
        do { page = try await Self.estimatePage(container: container, offset: offset,
            likelyUnlinkedOnly: likelyUnlinkedOnly) }
        catch { return false }
        guard stillAuthorized() else { return false }
        UserDefaults.standard.set(page.nextOffset, forKey: cursorKey)
        UserDefaults.standard.set(likelyUnlinkedOnly ? 1 : 0, forKey: laneKey)
        for candidate in page.candidates {
            guard stillAuthorized() else { return false }
            let identity = AutomaticOutboundSync.RealmRecord(companyID: companyID,
                documentType: "estimate", documentID: candidate.id, customerID: candidate.customerID,
                createdAt: candidate.createdAt, realmID: nil, environment: nil)
            do {
                guard let saved = try await QuickBooksDocumentRealmProofStore.shared.savedRecord(identity),
                      let bound = saved.boundScope, saved.intendedScope == nil || saved.intendedScope == bound else {
                    continue
                }
                let boundIdentity = AutomaticOutboundSync.RealmRecord(companyID: companyID,
                    documentType: "estimate", documentID: candidate.id, customerID: candidate.customerID,
                    createdAt: candidate.createdAt, realmID: bound.realmID, environment: bound.environment)
                let scope = BillingNativeJournalScope(document: .init(companyID: companyID,
                    realmID: bound.realmID, environment: bound.environment, documentType: .estimate,
                    localDocumentID: candidate.id), actorEmail: actorEmail)
                let store = BillingNativeJournalStore.device
                let journal = try store.read(scope)
                guard let pending = journal.pending, pending.backgroundState == .queueRequested,
                      !pending.settled, let proof = pending.queueProof,
                      proof.actorRole == role,
                      pending.request.scope == scope.document,
                      pending.request.localCustomerID == candidate.customerID,
                      pending.request.serviceCallID == candidate.serviceCallID,
                      pending.request.draftRevision == pending.draftRevision else { continue }
                try await Self.checkPreparedEstimate(container: container, request: pending.request,
                    proof: proof, identity: boundIdentity, customerRecordID: candidate.customerRecordID,
                    actorEmail: actorEmail, role: role, stillAuthorized: stillAuthorized)
                let sharedIdentity = SharedBillingIdentity(companyID: companyID, documentType: .estimate,
                    localDocumentID: candidate.id, localCustomerID: candidate.customerID,
                    serviceCallID: candidate.serviceCallID, projectMilestoneID: nil)
                let operation = try WorkspaceProviderOperation.capture(providerIsCurrent: stillAuthorized)
                let transport = GunnAireBackendService.billingPublicationClient.transport
                try operation.check()
                let data = try await transport(sharedIdentity.path, "GET", nil)
                try operation.check()
                guard stillAuthorized(), data.count <= 16_384 else { return false }
                let connection = try await SharedBillingConnection.decodeAsync(data)
                try connection.validate(sharedIdentity)
                guard connection.estimateQueueVersion == 1,
                      connection.realmID == bound.realmID,
                      connection.environment == bound.environment,
                      connection.connectionRevision == pending.request.connectionRevision else { return false }
                let checkProof: () async throws -> Void = {
                    try operation.check()
                    try await Self.checkPreparedEstimate(container: container, request: pending.request,
                        proof: proof, identity: boundIdentity, customerRecordID: candidate.customerRecordID,
                        actorEmail: actorEmail, role: role, stillAuthorized: stillAuthorized)
                    try operation.check()
                }
                let client = BillingPublicationClient { path, method, body in
                    try await checkProof()
                    let result = try await transport(path, method, body)
                    try await checkProof()
                    return result
                }
                let api = QuickBooksDataAPI(sharedBilling: connection, operation: operation,
                    billingPublisher: client, catalogPublisher: { _ in throw CatalogPublicationError.accessRequired },
                    customerPublisher: { _ in throw CustomerPublicationError.accessRequired })
                let workflow = try api.captureWorkspaceWorkflow(isCurrent: stillAuthorized)
                let publication = try BillingNativePublication(scope: scope, client: client,
                    workflow: workflow, store: store) {
                    guard stillAuthorized() else { throw CancellationError() }
                }
                _ = try await publication.enqueueOriginal(revision: pending.draftRevision,
                    checkRevision: { pending.draftRevision }, checkProof: checkProof)
                return stillAuthorized()
            } catch {
                guard stillAuthorized() else { return false }
                NSLog("Prepared estimate background recovery deferred: %@", String(describing: error))
            }
        }
        return stillAuthorized()
    }

    private static func checkPreparedEstimate(container: ModelContainer,
        request: BillingPublicationRequest, proof: BillingNativeQueueProof,
        identity: AutomaticOutboundSync.RealmRecord, customerRecordID: PersistentIdentifier,
        actorEmail: String, role: AppUserRole,
        stillAuthorized: @MainActor () -> Bool) async throws {
        guard stillAuthorized(), CompanyWorkspaceAccessController.shared.verifiedRole == role else {
            throw BillingPublicationError.accessRequired
        }
        guard request.scope.companyID == identity.companyID,
              request.scope.localDocumentID == identity.documentID,
              request.localCustomerID == identity.customerID,
              request.realmID == identity.realmID, request.environment == identity.environment else {
            throw BillingPublicationError.accessRequired
        }
        try await QuickBooksDocumentRealmProofStore.shared.requireProceed([identity])
        try await proof.checkPersisted(container: container, request: request)
        let jobID = request.serviceCallID
        let mirror = try await Task.detached(priority: .utility) {
            let first = try QuickBooksBillingAccessPolicy.readMirror(container: container,
                email: actorEmail, jobID: jobID, customerID: customerRecordID)
            let second = try QuickBooksBillingAccessPolicy.readMirror(container: container,
                email: actorEmail, jobID: jobID, customerID: customerRecordID)
            guard first == second else { throw BillingPublicationError.accessRequired }
            return second
        }.value
        guard stillAuthorized(), CompanyWorkspaceAccessController.shared.verifiedRole == role,
              mirror.allActive, !mirror.roles.isEmpty, mirror.roles.allSatisfy({ $0 == role }) else {
            throw BillingPublicationError.accessRequired
        }
        switch role {
        case .admin, .dispatcher: break
        case .fieldTechnician: guard mirror.assigned else { throw BillingPublicationError.accessRequired }
        case .accounting, .standard: throw BillingPublicationError.accessRequired
        }
    }
}
