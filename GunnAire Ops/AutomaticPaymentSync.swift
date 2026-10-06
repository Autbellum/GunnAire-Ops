import Foundation
import SwiftData

/// Reconciles saved manual collections with QuickBooks accounting. This never
/// initiates or repeats a card/ACH charge; the accounting service recovers by
/// the original local payment ID before it creates a payment record.
@MainActor
final class AutomaticPaymentSync {
    static let shared = AutomaticPaymentSync()

    enum SyncError: LocalizedError {
        case alreadyRunning
        case accessChanged
        case realmMismatch
        case unverifiedRealm

        var errorDescription: String? {
            switch self {
            case .alreadyRunning: "This payment is already syncing to QuickBooks. Check its status shortly."
            case .accessChanged: "The company or QuickBooks connection changed. Reopen the original payment and retry."
            case .realmMismatch: "This payment belongs to a different QuickBooks company. Reconnect the original company before syncing it."
            case .unverifiedRealm: "The original QuickBooks company for this payment is not verified on this device. Review the original invoice and payment with an administrator before posting accounting."
            }
        }
    }

    /// Device-bound proof adds no CloudKit schema field. A missing proof after
    /// upgrade, reinstall, or work on another device is a manual-review state.
    nonisolated struct RealmProof: Codable, Equatable, Sendable {
        let companyID: UUID
        let paymentID: UUID
        let invoiceID: UUID
        let customerID: UUID
        let quickBooksInvoiceID: String
        let quickBooksCustomerID: String
        let realmID: String
        let environment: String

        nonisolated static func account(companyID: UUID, paymentID: UUID) -> String {
            "GunnAirePaymentRealm.v1.\(companyID.uuidString.lowercased()).\(paymentID.uuidString.lowercased())"
        }
    }

    private var activeTokens: [UUID: UUID] = [:]
    private var proofClaims: Set<String> = []
    private var recoveryToken: UUID?
    private var containerID: ObjectIdentifier?
    private var operationStamp: CompanyWorkspaceOperationStamp?
    private var realmID: String?
    private(set) var generation = UUID()
    private var pageOffset = 0
    private var deferredUntil: [UUID: Date] = [:]
    private var lastRecoveryAt: Date?

    init() {}

    /// Persist the original provider scope before scheduling an accounting
    /// write. Keychain I/O runs off the main actor and survives app restarts.
    @discardableResult
    func recordRealmProof(for payment: Payment, context: ModelContext) async throws -> Bool {
        guard workspaceAuthorized(context), QuickBooksDataAPI.shared.isAuthenticated else { return false }
        adopt(context)
        guard payment.modelContext?.container === context.container,
              let proof = currentProof(for: payment) else { return false }
        let expectedGeneration = generation
        let account = RealmProof.account(companyID: proof.companyID, paymentID: proof.paymentID)
        guard proofClaims.insert(account).inserted else { return false }
        defer { proofClaims.remove(account) }
        let existing = try await Task.detached(priority: .utility) {
            try KeychainStore.loadCodable(RealmProof.self, account: account)
        }.value
        guard expectedGeneration == generation, workspaceAuthorized(context) else {
            throw SyncError.accessChanged
        }
        if let existing {
            guard existing == proof else { throw SyncError.realmMismatch }
            return true
        }
        try await Task.detached(priority: .utility) {
            try KeychainStore.saveCodable(proof, account: account)
        }.value
        guard expectedGeneration == generation, workspaceAuthorized(context) else {
            throw SyncError.accessChanged
        }
        return true
    }

    private func currentProof(for payment: Payment) -> RealmProof? {
        guard let companyID = CompanyWorkspaceAccessController.shared.verifiedCompanyID,
              let realmID = QuickBooksDataAPI.shared.realmID,
              !realmID.isEmpty, let invoice = payment.invoice,
              let customer = invoice.customer,
              let quickBooksInvoiceID = invoice.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !quickBooksInvoiceID.isEmpty,
              let quickBooksCustomerID = customer.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !quickBooksCustomerID.isEmpty else { return nil }
        return RealmProof(companyID: companyID, paymentID: payment.id,
            invoiceID: invoice.id, customerID: customer.id,
            quickBooksInvoiceID: quickBooksInvoiceID,
            quickBooksCustomerID: quickBooksCustomerID,
            realmID: realmID, environment: QuickBooksDataAPI.shared.currentEnvironment)
    }

    private func storedProof(for payment: Payment, companyID: UUID) async throws -> RealmProof? {
        let account = RealmProof.account(companyID: companyID, paymentID: payment.id)
        return try await Task.detached(priority: .utility) {
            try KeychainStore.loadCodable(RealmProof.self, account: account)
        }.value
    }

    /// Only an already recorded, uncharged manual collection is eligible.
    /// Shared-company queue upload may change processorSyncStatus independently,
    /// so accounting eligibility cannot depend on that label.
    /// Provider captures and refunds have separate attempt/receipt recovery.
    static func shouldRecover(_ payment: Payment, proof: RealmProof?, companyID: UUID?,
                              realmID: String?, environment: String) -> Bool {
        let status = payment.quickBooksAccountingSyncStatus?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let proof, let companyID, let realmID,
              let invoice = payment.invoice, let customer = invoice.customer,
              let quickBooksInvoiceID = invoice.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines),
              let quickBooksCustomerID = customer.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines),
              proof == RealmProof(companyID: companyID, paymentID: payment.id,
                  invoiceID: invoice.id, customerID: customer.id,
                  quickBooksInvoiceID: quickBooksInvoiceID,
                  quickBooksCustomerID: quickBooksCustomerID,
                  realmID: realmID, environment: environment) else { return false }
        guard status == "pending" || status == "needs_attention",
              payment.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
              !payment.isRefund, payment.collectionAttemptID == nil,
              payment.quickBooksChargeID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
              payment.quickBooksClientTransID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
              payment.amount.isFinite, payment.amount > 0, payment.amount <= 1_000_000,
              invoice.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              customer.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return false
        }
        return true
    }

    func recoverPending(context: ModelContext, force: Bool = false) {
        guard authorized(context), QuickBooksDataAPI.shared.isAuthenticated else { return }
        adopt(context)
        let now = Date()
        if !force, let lastRecoveryAt, now.timeIntervalSince(lastRecoveryAt) < 60 { return }
        lastRecoveryAt = now
        guard recoveryToken == nil else { return }
        let runToken = UUID()
        recoveryToken = runToken
        let expectedGeneration = generation
        Task { @MainActor in
            defer { if recoveryToken == runToken { recoveryToken = nil } }
            do {
                var page = FetchDescriptor<Payment>(
                    predicate: #Predicate {
                        $0.quickBooksAccountingSyncStatus == "pending" ||
                            $0.quickBooksAccountingSyncStatus == "needs_attention"
                    },
                    sortBy: [SortDescriptor(\.date), SortDescriptor(\.id)])
                page.fetchLimit = 100
                page.fetchOffset = pageOffset
                var payments = try context.fetch(page)
                if payments.isEmpty, pageOffset > 0 {
                    pageOffset = 0
                    page.fetchOffset = 0
                    payments = try context.fetch(page)
                }
                pageOffset = payments.count < 100 ? 0 : pageOffset + payments.count
                var attempted = 0
                for payment in payments where attempted < 10 {
                    guard generation == expectedGeneration, authorized(context),
                          QuickBooksDataAPI.shared.isAuthenticated else { return }
                    guard activeTokens[payment.id] == nil,
                          (deferredUntil[payment.id] ?? .distantPast) <= Date() else { continue }
                    guard let companyID = CompanyWorkspaceAccessController.shared.verifiedCompanyID else { return }
                    let proof: RealmProof?
                    do { proof = try await storedProof(for: payment, companyID: companyID) }
                    catch {
                        deferredUntil[payment.id] = Date().addingTimeInterval(5 * 60)
                        continue
                    }
                    guard generation == expectedGeneration,
                          Self.shouldRecover(payment, proof: proof, companyID: companyID,
                              realmID: QuickBooksDataAPI.shared.realmID,
                              environment: QuickBooksDataAPI.shared.currentEnvironment) else { continue }
                    attempted += 1
                    do {
                        _ = try await perform(payment, context: context, manual: true)
                    } catch {
                        guard generation == expectedGeneration else { return }
                        deferredUntil[payment.id] = Date().addingTimeInterval(5 * 60)
                        if error is URLError ||
                            (error as? WorkspaceProviderAccessError) != nil { return }
                    }
                }
            } catch {
                // The saved payment remains pending and a later activation or
                // connectivity event repeats this bounded scan.
            }
        }
    }

    func enqueue(_ payment: Payment, context: ModelContext) {
        guard authorized(context), QuickBooksDataAPI.shared.isAuthenticated else { return }
        adopt(context)
        guard activeTokens[payment.id] == nil,
              let companyID = CompanyWorkspaceAccessController.shared.verifiedCompanyID else { return }
        let expectedGeneration = generation
        Task { @MainActor in
            do {
                let proof = try await storedProof(for: payment, companyID: companyID)
                guard generation == expectedGeneration,
                      Self.shouldRecover(payment, proof: proof, companyID: companyID,
                          realmID: QuickBooksDataAPI.shared.realmID,
                          environment: QuickBooksDataAPI.shared.currentEnvironment) else { return }
                _ = try await perform(payment, context: context, manual: true)
            }
            catch {
                if generation == expectedGeneration {
                    deferredUntil[payment.id] = Date().addingTimeInterval(5 * 60)
                }
            }
        }
    }

    /// Explicit Sync and the automatic drain share one in-flight claim per
    /// original local payment; neither can race the other into a second POST.
    func perform(_ payment: Payment, context: ModelContext, manual: Bool) async throws -> QuickBooksWorkspaceResult<String> {
        guard authorized(context, automatic: false), QuickBooksDataAPI.shared.isAuthenticated else {
            throw SyncError.accessChanged
        }
        adopt(context)
        guard let expectedProof = currentProof(for: payment) else { throw SyncError.accessChanged }
        let expectedGeneration = generation
        let proof = try await storedProof(for: payment, companyID: expectedProof.companyID)
        guard generation == expectedGeneration,
              authorized(context, automatic: false),
              QuickBooksDataAPI.shared.isAuthenticated,
              currentProof(for: payment) == expectedProof else { throw SyncError.accessChanged }
        // A provider capture has a separate immutable attempt journal that the
        // service verifies before its accounting retry. A legacy manual record
        // has no such provenance, even when the user taps explicit Retry.
        if proof == nil && (manual || payment.collectionAttemptID == nil) {
            throw SyncError.unverifiedRealm
        }
        if let proof, proof != expectedProof {
            throw SyncError.realmMismatch
        }
        guard payment.modelContext?.container === context.container else { throw SyncError.accessChanged }
        let claim = try claim(payment.id)
        defer { release(payment.id, token: claim) }
        let result = try await QuickBooksPaymentsService.shared
            .syncAndRecordAccountingFollowUp(for: payment, manual: manual)
        guard generation == expectedGeneration, authorized(context, automatic: false) else {
            throw SyncError.accessChanged
        }
        try result.validateWorkspace()
        deferredUntil.removeValue(forKey: payment.id)
        return result
    }

    static func permitsAccountingPublication(role: AppUserRole?, automatic: Bool) -> Bool {
        role == .admin || (!automatic && role == .accounting)
    }

    private func authorized(_ context: ModelContext, automatic: Bool = true) -> Bool {
        workspaceAuthorized(context) &&
            Self.permitsAccountingPublication(
                role: CompanyWorkspaceAccessController.shared.verifiedRole, automatic: automatic)
    }

    private func workspaceAuthorized(_ context: ModelContext) -> Bool {
        !GunnAireCloudKit.usesTestDatabase &&
            CompanyWorkspaceAccessController.shared.authorizedContainer === context.container &&
            CompanyWorkspaceAccessController.shared.operationStamp != nil
    }

    private func adopt(_ context: ModelContext) {
        adoptScope(containerID: ObjectIdentifier(context.container),
            operationStamp: CompanyWorkspaceAccessController.shared.operationStamp,
            realmID: QuickBooksDataAPI.shared.realmID)
    }

    /// A workspace rotation invalidates scans, but an already issued provider
    /// write still owns its payment until the original task actually returns.
    func adoptScope(containerID nextContainer: ObjectIdentifier,
                    operationStamp nextStamp: CompanyWorkspaceOperationStamp?,
                    realmID nextRealm: String?) {
        guard containerID != nextContainer || operationStamp != nextStamp || realmID != nextRealm else { return }
        generation = UUID()
        recoveryToken = nil
        pageOffset = 0
        deferredUntil.removeAll()
        lastRecoveryAt = nil
        containerID = nextContainer
        operationStamp = nextStamp
        realmID = nextRealm
    }

    @discardableResult
    func claim(_ paymentID: UUID) throws -> UUID {
        guard activeTokens[paymentID] == nil else { throw SyncError.alreadyRunning }
        let token = UUID()
        activeTokens[paymentID] = token
        return token
    }

    func release(_ paymentID: UUID, token: UUID) {
        if activeTokens[paymentID] == token { activeTokens.removeValue(forKey: paymentID) }
    }
}
