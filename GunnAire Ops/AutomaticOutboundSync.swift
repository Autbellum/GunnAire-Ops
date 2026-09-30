import Foundation
import SwiftData

/// Keeps provider publication alive after the editor that saved a record closes.
/// The SwiftData context and every provider operation remain bound to the same
/// verified workspace; pending records are rediscovered after a process restart.
@MainActor
final class AutomaticOutboundSync {
    static let shared = AutomaticOutboundSync()

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

    private init() {}

    static func pendingDocumentKeys(invoices: [Invoice], estimates: [Estimate]) -> [DocumentKey] {
        QuickBooksEstimatePublicationRecovery.queuedEstimates(from: estimates).map { .estimate($0.id) }
            + QuickBooksInvoicePublicationRecovery.queuedInvoices(from: invoices).map { .invoice($0.id) }
    }

    static func pendingCustomerKeys(_ customers: [Customer]) -> [DocumentKey] {
        customers.filter { $0.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false }
            .map { .customer($0.id) }
    }

    func publish(_ document: QuickBooksBillingDocument, context: ModelContext,
                 completion: ((Result<String, Error>) -> Void)? = nil) {
        let key: DocumentKey = document.label == "Invoice" ? .invoice(document.id) : .estimate(document.id)
        guard isAuthorized(context) else {
            completion?(.failure(BillingPublicationError.accessRequired))
            return
        }
        adopt(context)
        deferredUntil.removeValue(forKey: key)
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
        guard isAuthorized(context), QuickBooksDataAPI.shared.isAuthenticated else { return }
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
            let customerFetch = FetchDescriptor<Customer>(predicate: #Predicate {
                $0.quickBooksID == nil || $0.quickBooksID == ""
            }, sortBy: [SortDescriptor(\.name), SortDescriptor(\.id)])
            let invoices = try Self.nextPage(invoiceFetch, context: context, offset: &invoiceOffset)
            let estimates = try Self.nextPage(estimateFetch, context: context, offset: &estimateOffset)
            let customers = try Self.nextPage(customerFetch, context: context, offset: &customerOffset)
            let keys = Self.pendingDocumentKeys(invoices: invoices, estimates: estimates) +
                Self.pendingCustomerKeys(customers)
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
        guard auth.isAuthenticated, isAuthorized(context) else { return }
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
                let capturedPreparation = preparations.removeValue(forKey: next)
                let result = try await publish(document, context: context, preparation: capturedPreparation)
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
                         preparation capturedPreparation: SharedBillingPreparation?) async throws -> String {
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
