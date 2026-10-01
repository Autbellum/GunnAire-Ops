import Foundation
import SwiftData

private actor AutomaticOutboundRealmStore {
    func markNew(_ record: AutomaticOutboundSync.RealmRecord) throws {
        let account = record.account
        if let existing = try KeychainStore.loadCodable(AutomaticOutboundSync.RealmRecord.self, account: account) {
            guard existing.sameDocument(as: record) else { throw AutomaticOutboundSync.RealmError.reviewRequired }
            return
        }
        try KeychainStore.saveCodable(record, account: account)
    }

    func cachedScope(companyID: UUID) throws -> AutomaticOutboundSync.RealmScope? {
        let value = try KeychainStore.loadCodable(AutomaticOutboundSync.RealmScope.self,
            account: AutomaticOutboundSync.RealmScope.account(companyID: companyID))
        guard value?.companyID == companyID else { return nil }
        return value
    }

    func bindSaved(_ expected: AutomaticOutboundSync.RealmRecord) throws {
        guard let stored = try KeychainStore.loadCodable(AutomaticOutboundSync.RealmRecord.self,
            account: expected.account), stored.sameDocument(as: expected) else {
            throw AutomaticOutboundSync.RealmError.reviewRequired
        }
        guard stored.realmID == nil && stored.environment == nil || stored == expected else {
            throw AutomaticOutboundSync.RealmError.wrongRealm
        }
        try KeychainStore.saveCodable(expected, account: expected.account)
    }

    func remember(_ scope: AutomaticOutboundSync.RealmScope) throws {
        try KeychainStore.saveCodable(scope, account: AutomaticOutboundSync.RealmScope.account(companyID: scope.companyID))
    }

    func hasBoundProof(_ identity: AutomaticOutboundSync.RealmRecord) throws -> Bool {
        guard let stored = try KeychainStore.loadCodable(AutomaticOutboundSync.RealmRecord.self,
            account: identity.account), stored.sameDocument(as: identity),
              let realmID = stored.realmID, !realmID.isEmpty,
              let environment = stored.environment, ["sandbox", "production"].contains(environment) else {
            return false
        }
        return true
    }

    func verifyOrBind(_ expected: AutomaticOutboundSync.RealmRecord, explicitReview: Bool) throws {
        let stored = try KeychainStore.loadCodable(AutomaticOutboundSync.RealmRecord.self, account: expected.account)
        switch AutomaticOutboundSync.realmDecision(stored: stored, expected: expected, explicitReview: explicitReview) {
        case .proceed:
            return
        case .bind:
            try KeychainStore.saveCodable(expected, account: expected.account)
        case .reviewRequired:
            throw AutomaticOutboundSync.RealmError.reviewRequired
        case .wrongRealm:
            throw AutomaticOutboundSync.RealmError.wrongRealm
        }
    }
}

/// Keeps provider publication alive after the editor that saved a record closes.
/// The SwiftData context and every provider operation remain bound to the same
/// verified workspace; pending records are rediscovered after a process restart.
@MainActor
final class AutomaticOutboundSync {
    static let shared = AutomaticOutboundSync()

    nonisolated struct RealmRecord: Codable, Equatable, Sendable {
        let companyID: UUID
        let documentType: String
        let documentID: UUID
        let customerID: UUID
        let createdAt: Date
        let realmID: String?
        let environment: String?

        nonisolated var account: String {
            "GunnAireBillingRealm.v1.\(companyID.uuidString.lowercased()).\(documentType).\(documentID.uuidString.lowercased())"
        }

        nonisolated func sameDocument(as other: Self) -> Bool {
            companyID == other.companyID && documentType == other.documentType &&
                documentID == other.documentID && customerID == other.customerID && createdAt == other.createdAt
        }
    }

    nonisolated struct RealmScope: Codable, Equatable, Sendable {
        let companyID: UUID
        let realmID: String
        let environment: String

        nonisolated static func account(companyID: UUID) -> String {
            "GunnAireBillingVerifiedRealm.v1.\(companyID.uuidString.lowercased())"
        }
    }

    nonisolated enum RealmDecision: Equatable, Sendable {
        case proceed, bind, reviewRequired, wrongRealm
    }

    nonisolated enum RealmError: LocalizedError {
        case reviewRequired, wrongRealm

        nonisolated var errorDescription: String? {
            switch self {
            case .reviewRequired:
                "The original QuickBooks company for this saved document is not verified on this device. Review the document and choose Sync Saved Document before publishing it."
            case .wrongRealm:
                "This document was first prepared for a different QuickBooks company. Reconnect that company and review the original document before syncing."
            }
        }
    }

    nonisolated static func realmDecision(stored: RealmRecord?, expected: RealmRecord,
                                          explicitReview: Bool) -> RealmDecision {
        guard let stored else { return explicitReview ? .bind : .reviewRequired }
        guard stored.sameDocument(as: expected) else { return .reviewRequired }
        if stored.realmID == nil && stored.environment == nil {
            return explicitReview ? .bind : .reviewRequired
        }
        guard let realmID = stored.realmID, let environment = stored.environment,
              !realmID.isEmpty, !environment.isEmpty else { return .reviewRequired }
        return realmID == expected.realmID && environment == expected.environment ? .proceed : .wrongRealm
    }

    enum DocumentKey: Hashable {
        case customer(UUID)
        case invoice(UUID)
        case estimate(UUID)
    }

    private struct PublicationFailure: LocalizedError {
        let underlying: Error
        let mayHaveWritten: Bool

        var errorDescription: String? {
            mayHaveWritten
                ? "QuickBooks may have accepted the original request. Its saved identity will be reconciled before another create. \(underlying.localizedDescription)"
                : underlying.localizedDescription
        }
    }

    private var pending: [DocumentKey] = []
    private var preparations: [DocumentKey: SharedBillingPreparation] = [:]
    private var explicitReviewKeys: Set<DocumentKey> = []
    private var deferredUntil: [DocumentKey: Date] = [:]
    private var completions: [DocumentKey: [(Result<String, Error>) -> Void]] = [:]
    private var currentKey: DocumentKey?
    private var running = false
    private var queueContainer: ObjectIdentifier?
    private var queueStamp: CompanyWorkspaceOperationStamp?
    private var queueRealmID: String?
    private var queueContext: ModelContext?
    private var queueGeneration = UUID()
    private var invoiceOffset = 0
    private var estimateOffset = 0
    private var customerOffset = 0
    private var calendarRunning = false
    private var calendarQueued = false
    private var lastRecoveryAt: Date?
    private let recoveryInterval: TimeInterval = 60
    private let realmStore = AutomaticOutboundRealmStore()

    private init() {}

    @discardableResult
    func recordNewlySaved(_ document: QuickBooksBillingDocument, context: ModelContext) async throws -> Bool {
        guard isAuthorized(context), let record = realmRecord(for: document, realmID: nil, environment: nil) else {
            throw BillingPublicationError.accessRequired
        }
        let stamp = CompanyWorkspaceAccessController.shared.operationStamp
        try await realmStore.markNew(record)
        guard isAuthorized(context), CompanyWorkspaceAccessController.shared.operationStamp == stamp else {
            throw BillingPublicationError.accessRequired
        }
        if let cached = try await realmStore.cachedScope(companyID: record.companyID) {
            let bound = RealmRecord(companyID: record.companyID, documentType: record.documentType,
                documentID: record.documentID, customerID: record.customerID, createdAt: record.createdAt,
                realmID: cached.realmID, environment: cached.environment)
            try await realmStore.bindSaved(bound)
            guard isAuthorized(context), CompanyWorkspaceAccessController.shared.operationStamp == stamp else {
                throw BillingPublicationError.accessRequired
            }
            return true
        }
        guard let customer = document.customer else { throw BillingPublicationError.accessRequired }
        let identity = SharedBillingIdentity(companyID: record.companyID,
            documentType: document.label == "Invoice" ? .invoice : .estimate,
            localDocumentID: document.id, localCustomerID: customer.id,
            serviceCallID: document.serviceCallID, projectMilestoneID: document.projectMilestoneID)
        let connection: SharedBillingConnection
        do {
            let data = try await GunnAireBackendService.billingPublicationClient.transport(identity.path, "GET", nil)
            guard data.count <= 16_384 else { return false }
            connection = try await SharedBillingConnection.decodeAsync(data)
            try connection.validate(identity)
        } catch {
            guard isAuthorized(context), CompanyWorkspaceAccessController.shared.operationStamp == stamp else {
                throw BillingPublicationError.accessRequired
            }
            return false
        }
        guard isAuthorized(context), CompanyWorkspaceAccessController.shared.operationStamp == stamp else {
            throw BillingPublicationError.accessRequired
        }
        let bound = RealmRecord(companyID: record.companyID, documentType: record.documentType,
            documentID: record.documentID, customerID: record.customerID, createdAt: record.createdAt,
            realmID: connection.realmID, environment: connection.environment)
        try await realmStore.bindSaved(bound)
        try await realmStore.remember(RealmScope(companyID: record.companyID,
            realmID: connection.realmID, environment: connection.environment))
        guard isAuthorized(context), CompanyWorkspaceAccessController.shared.operationStamp == stamp else {
            throw BillingPublicationError.accessRequired
        }
        return true
    }

    private func realmRecord(for document: QuickBooksBillingDocument, realmID: String?,
                             environment: String?) -> RealmRecord? {
        guard let companyID = CompanyWorkspaceAccessController.shared.verifiedCompanyID,
              let customer = document.customer else { return nil }
        let createdAt: Date
        switch document {
        case .invoice(let value): createdAt = value.createdAt
        case .estimate(let value): createdAt = value.createdAt
        }
        return RealmRecord(companyID: companyID, documentType: document.label.lowercased(),
            documentID: document.id, customerID: customer.id, createdAt: createdAt,
            realmID: realmID, environment: environment)
    }

    static func pendingDocumentKeys(invoices: [Invoice], estimates: [Estimate]) -> [DocumentKey] {
        QuickBooksEstimatePublicationRecovery.queuedEstimates(from: estimates).map { .estimate($0.id) }
            + QuickBooksInvoicePublicationRecovery.queuedInvoices(from: invoices).map { .invoice($0.id) }
    }

    static func pendingCustomerKeys(_ customers: [Customer]) -> [DocumentKey] {
        customers.filter { $0.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false }
            .map { .customer($0.id) }
    }

    static func pendingRecoveryKeys(invoices: [Invoice], estimates: [Estimate],
                                    customers: [Customer], includeCustomers: Bool) -> [DocumentKey] {
        pendingDocumentKeys(invoices: invoices, estimates: estimates) +
            (includeCustomers ? pendingCustomerKeys(customers) : [])
    }

    func publish(_ document: QuickBooksBillingDocument, context: ModelContext,
                 explicitReview: Bool = false,
                 completion: ((Result<String, Error>) -> Void)? = nil) {
        let key: DocumentKey = document.label == "Invoice" ? .invoice(document.id) : .estimate(document.id)
        guard isAuthorized(context) else {
            completion?(.failure(BillingPublicationError.accessRequired))
            return
        }
        adopt(context)
        deferredUntil.removeValue(forKey: key)
        if explicitReview { explicitReviewKeys.insert(key) }
        guard !pending.contains(key), currentKey != key else {
            if let completion { completions[key, default: []].append(completion) }
            return
        }
        let generation = queueGeneration
        let stamp = queueStamp
        do {
            preparations[key] = try SharedBillingPreparation(document: document, context: context,
                isCurrent: { [weak self] in
                    self?.queueGeneration == generation && self?.isAuthorized(context) == true &&
                        CompanyWorkspaceAccessController.shared.operationStamp == stamp &&
                        self?.queueRealmID == QuickBooksDataAPI.shared.realmID
                })
        } catch {
            completion?(.failure(error))
            return
        }
        if let completion { completions[key, default: []].append(completion) }
        pending.append(key)
        Task { await drain(context: context) }
    }

    func recoverPending(context: ModelContext, force: Bool = false) {
        guard isAuthorized(context) else { return }
        adopt(context)
        let now = Date()
        if !force, let lastRecoveryAt, now.timeIntervalSince(lastRecoveryAt) < recoveryInterval { return }
        lastRecoveryAt = now
        do {
            // Each pass scans one bounded page per record type. Cursors rotate
            // across launches/reconnects so a permanently blocked first page
            // cannot hide every later pending record.
            let invoiceFetch = FetchDescriptor<Invoice>(predicate: #Predicate { $0.quickBooksSyncStatus != "synced" },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse), SortDescriptor(\.id)])
            let estimateFetch = FetchDescriptor<Estimate>(predicate: #Predicate {
                $0.quickBooksID == nil || $0.quickBooksID == ""
            }, sortBy: [SortDescriptor(\.createdAt, order: .reverse), SortDescriptor(\.id)])
            let invoices = try Self.nextPage(invoiceFetch, context: context, offset: &invoiceOffset)
            let estimates = try Self.nextPage(estimateFetch, context: context, offset: &estimateOffset)
            let canRecoverCustomers: Bool
            if QuickBooksDataAPI.shared.isAuthenticated {
                do {
                    try QuickBooksSyncAccessPolicy.validate(context: context)
                    canRecoverCustomers = true
                } catch {
                    canRecoverCustomers = false
                }
            } else {
                canRecoverCustomers = false
            }
            let customers: [Customer]
            if canRecoverCustomers {
                let customerFetch = FetchDescriptor<Customer>(predicate: #Predicate {
                    $0.quickBooksID == nil || $0.quickBooksID == ""
                }, sortBy: [SortDescriptor(\.name), SortDescriptor(\.id)])
                customers = try Self.nextPage(customerFetch, context: context, offset: &customerOffset)
            } else {
                customers = []
            }
            let keys = Self.pendingRecoveryKeys(invoices: invoices, estimates: estimates,
                customers: customers, includeCustomers: canRecoverCustomers)
            for key in keys where !pending.contains(key) && currentKey != key &&
                (deferredUntil[key] ?? .distantPast) <= now {
                pending.append(key)
            }
            Task { await drain(context: context) }
        } catch {
            // The original records remain local and are reconsidered on the
            // next foreground or connectivity transition.
        }
    }

    static func nextPage<Model: PersistentModel>(
        _ descriptor: FetchDescriptor<Model>, context: ModelContext, offset: inout Int
    ) throws -> [Model] {
        var page = descriptor
        page.fetchLimit = 100
        page.fetchOffset = offset
        var values = try context.fetch(page)
        if values.isEmpty, offset > 0 {
            offset = 0
            page.fetchOffset = 0
            values = try context.fetch(page)
        }
        offset = values.count < 100 ? 0 : offset + values.count
        return values
    }

    func recoverCalendar(context: ModelContext, auth: GoogleAuthManager) {
        guard auth.googleCalendarAuthorizationState == .ready else {
            auth.calendarSyncMessage = auth.googleCalendarAuthorizationState.detail
            return
        }
        guard isAuthorized(context) else {
            auth.calendarSyncMessage = "Google Calendar is waiting for a verified company workspace. Saved appointments remain on this device until access is restored."
            return
        }
        if calendarRunning { calendarQueued = true; return }
        calendarRunning = true
        GoogleCalendarScheduleSync.sync(auth: auth, modelContext: context,
            signedInEmail: AppIdentity.currentEmail, isAdminUser: false) { [weak self] _ in
                guard let self else { return }
                self.calendarRunning = false
                if self.calendarQueued {
                    self.calendarQueued = false
                    self.recoverCalendar(context: context, auth: auth)
                }
            }
    }

    private func isAuthorized(_ context: ModelContext) -> Bool {
        !GunnAireCloudKit.usesTestDatabase &&
            CompanyWorkspaceAccessController.shared.authorizedContainer === context.container &&
            CompanyWorkspaceAccessController.shared.operationStamp != nil
    }

    private func adopt(_ context: ModelContext) {
        let identifier = ObjectIdentifier(context.container)
        let stamp = CompanyWorkspaceAccessController.shared.operationStamp
        let realmID = QuickBooksDataAPI.shared.realmID
        if queueContainer != identifier || queueStamp != stamp || queueRealmID != realmID {
            queueGeneration = UUID()
            lastRecoveryAt = nil
            currentKey = nil
            invoiceOffset = 0
            estimateOffset = 0
            customerOffset = 0
            pending.removeAll()
            preparations.removeAll()
            explicitReviewKeys.removeAll()
            deferredUntil.removeAll()
            let callbacks = completions.values.flatMap { $0 }
            completions.removeAll()
            callbacks.forEach { $0(.failure(BillingPublicationError.accessRequired)) }
            queueContainer = identifier
            queueStamp = stamp
            queueRealmID = realmID
        }
        queueContext = context
    }

    private func document(for key: DocumentKey, context: ModelContext) throws -> QuickBooksBillingDocument? {
        switch key {
        case .customer:
            return nil
        case .invoice(let id):
            var fetch = FetchDescriptor<Invoice>(predicate: #Predicate { $0.id == id })
            fetch.fetchLimit = 1
            return try context.fetch(fetch).first.map(QuickBooksBillingDocument.invoice)
        case .estimate(let id):
            var fetch = FetchDescriptor<Estimate>(predicate: #Predicate { $0.id == id })
            fetch.fetchLimit = 1
            return try context.fetch(fetch).first.map(QuickBooksBillingDocument.estimate)
        }
    }

    private func drain(context: ModelContext) async {
        guard !running, isAuthorized(context),
              queueStamp == CompanyWorkspaceAccessController.shared.operationStamp,
              queueRealmID == QuickBooksDataAPI.shared.realmID else { return }
        running = true
        let generation = queueGeneration
        var pausedForConnectivity = false
        defer {
            running = false
            if !pausedForConnectivity, !pending.isEmpty,
               let nextContext = queueContext, isAuthorized(nextContext) {
                Task { await drain(context: nextContext) }
            } else if pending.isEmpty {
                queueContext = nil
            }
        }
        var processed = 0
        while !pending.isEmpty, processed < 10, isAuthorized(context),
              queueStamp == CompanyWorkspaceAccessController.shared.operationStamp,
              queueRealmID == QuickBooksDataAPI.shared.realmID,
              queueGeneration == generation {
            let next = pending.removeFirst()
            currentKey = next
            let explicitReview = explicitReviewKeys.remove(next) != nil
            processed += 1
            do {
                if case .customer(let id) = next {
                    try await publishCustomer(id, context: context)
                    guard queueGeneration == generation else { currentKey = nil; break }
                    let callbacks = completions.removeValue(forKey: next) ?? []
                    callbacks.forEach { $0(.success("Customer linked to QuickBooks.")) }
                    currentKey = nil
                    continue
                }
                guard let document = try document(for: next, context: context) else {
                    preparations.removeValue(forKey: next)
                    let callbacks = completions.removeValue(forKey: next) ?? []
                    callbacks.forEach { $0(.failure(QuickBooksBillingWorkflowError.changed)) }
                    currentKey = nil
                    continue
                }
                if !explicitReview {
                    guard let identity = realmRecord(for: document, realmID: nil, environment: nil),
                          try await realmStore.hasBoundProof(identity) else {
                        // The proof can only be added through explicit review
                        // or a new-document save on this device. Do not read
                        // the same missing Keychain entry on every timer pass.
                        deferredUntil[next] = .distantFuture
                        let callbacks = completions.removeValue(forKey: next) ?? []
                        callbacks.forEach { $0(.failure(RealmError.reviewRequired)) }
                        currentKey = nil
                        continue
                    }
                    guard queueGeneration == generation else { currentKey = nil; break }
                }
                let capturedPreparation = preparations.removeValue(forKey: next)
                let result = try await publish(document, context: context,
                    preparation: capturedPreparation, explicitReview: explicitReview)
                guard queueGeneration == generation else { currentKey = nil; break }
                let callbacks = completions.removeValue(forKey: next) ?? []
                callbacks.forEach { $0(.success(result)) }
                deferredUntil.removeValue(forKey: next)
                currentKey = nil
            } catch {
                currentKey = nil
                guard queueGeneration == generation else { break }
                let failure = error as? PublicationFailure
                let underlying = failure?.underlying ?? error
                let reported: Error = failure ?? underlying
                let callbacks = completions.removeValue(forKey: next) ?? []
                callbacks.forEach { $0(.failure(reported)) }
                if failure?.mayHaveWritten == true {
                    deferredUntil[next] = Date().addingTimeInterval(5 * 60)
                }
                // The original document retains its journal/attention state.
                // A single rejected draft cannot starve unrelated records.
                if Self.shouldPauseAfterFailure(underlying) {
                    pausedForConnectivity = true
                    let remaining = completions.values.flatMap { $0 }
                    completions.removeAll()
                    remaining.forEach { $0(.failure(reported)) }
                    break
                }
            }
        }
    }

    static func shouldPauseAfterFailure(_ error: Error) -> Bool {
        error is URLError || (error as? SharedBillingConnectionError) == .unavailable
    }

    private func publish(_ document: QuickBooksBillingDocument, context: ModelContext,
                         preparation capturedPreparation: SharedBillingPreparation?,
                         explicitReview: Bool) async throws -> String {
        let lifecycle = QuickBooksSyncLifecycle()
        defer { lifecycle.cancel() }
        let stamp = CompanyWorkspaceAccessController.shared.operationStamp
        let workflow: QuickBooksBillingWorkflow
        do {
            let preparation = try capturedPreparation ?? SharedBillingPreparation(document: document, context: context,
                isCurrent: { [weak self] in
                    self?.isAuthorized(context) == true &&
                        CompanyWorkspaceAccessController.shared.operationStamp == stamp &&
                        self?.queueRealmID == QuickBooksDataAPI.shared.realmID
                })
            workflow = try await preparation.makeWorkflow(lifecycle: lifecycle)
        } catch {
            throw PublicationFailure(underlying: error, mayHaveWritten: false)
        }
        do {
            guard let realmID = workflow.run.workflow.realmID,
                  let companyID = workflow.run.workflow.companyID,
                  let record = realmRecord(for: document, realmID: realmID,
                    environment: workflow.run.workflow.environment),
                  record.companyID == companyID else { throw BillingPublicationError.accessRequired }
            try await realmStore.verifyOrBind(record, explicitReview: explicitReview)
            if explicitReview {
                try await realmStore.remember(RealmScope(companyID: companyID,
                    realmID: realmID, environment: workflow.run.workflow.environment))
            }
            try workflow.check()
            try await workflow.run.perform {
                await QuickBooksAccountingConfigurationStore.shared.refresh(
                    realmID: workflow.run.workflow.realmID,
                    environment: workflow.run.workflow.environment,
                    validate: workflow.check)
            }
            let configuration = QuickBooksAccountingConfigurationStore.shared.configuration(
                for: workflow.run.workflow.realmID, environment: workflow.run.workflow.environment)
            let outcome = try await workflow.execute(configuration: configuration)
            do {
                try await workflow.uploadLinkedAttachments()
                return outcome.message
            } catch {
                return outcome.message + " Supporting files remain pending: " + error.localizedDescription
            }
        } catch {
            try? workflow.recordFailure(error)
            throw PublicationFailure(underlying: error, mayHaveWritten: workflow.attemptedWrite)
        }
    }

    private func publishCustomer(_ id: UUID, context: ModelContext) async throws {
        let workflow: CustomerPublicationWorkflow
        do {
            guard QuickBooksDataAPI.shared.isAuthenticated else {
                throw BillingPublicationError.accessRequired
            }
            var fetch = FetchDescriptor<Customer>(predicate: #Predicate { $0.id == id })
            fetch.fetchLimit = 1
            guard let customer = try context.fetch(fetch).first,
                  customer.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else { return }
            workflow = try CustomerPublicationWorkflow(customer: customer, context: context, api: .shared)
        } catch {
            throw PublicationFailure(underlying: error, mayHaveWritten: false)
        }
        do { try await workflow.publish() }
        catch { throw PublicationFailure(underlying: error, mayHaveWritten: true) }
    }
}
