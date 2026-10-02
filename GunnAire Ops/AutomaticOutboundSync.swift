import Foundation
import SwiftData

/// Device-bound proof of the QuickBooks company/environment each saved billing
/// document was first prepared for. One shared actor serializes every Keychain
/// read and write off the main actor for publication and file uploads alike.
actor QuickBooksDocumentRealmProofStore {
    static let shared = QuickBooksDocumentRealmProofStore()

    func markNew(_ record: AutomaticOutboundSync.RealmRecord, replacingOrphan: Bool = false) throws {
        guard record.hasValidIntent else { throw AutomaticOutboundSync.RealmError.reviewRequired }
        let account = record.account
        if let existing = try KeychainStore.loadCodable(AutomaticOutboundSync.RealmRecord.self, account: account) {
            if existing.sameDocument(as: record) {
                guard existing.intendedScope == record.intendedScope,
                      existing.boundScope == nil || existing.boundScope == record.boundScope else {
                    throw AutomaticOutboundSync.RealmError.wrongRealm
                }
                return
            }
            guard replacingOrphan, existing.sameDocumentKeyAndCustomer(as: record),
                  existing.createdAt != record.createdAt,
                  existing.originalScope == record.originalScope else {
                throw AutomaticOutboundSync.RealmError.reviewRequired
            }
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
        guard let expectedScope = expected.boundScope,
              stored.intendedScope == expectedScope,
              stored.boundScope == nil || stored.boundScope == expectedScope else {
            throw AutomaticOutboundSync.RealmError.wrongRealm
        }
        try KeychainStore.saveCodable(expected.boundWithIntent(from: stored), account: expected.account)
    }

    func remember(_ scope: AutomaticOutboundSync.RealmScope) throws {
        try KeychainStore.saveCodable(scope, account: AutomaticOutboundSync.RealmScope.account(companyID: scope.companyID))
    }

    func hasBoundProof(_ identity: AutomaticOutboundSync.RealmRecord) throws -> Bool {
        guard let stored = try KeychainStore.loadCodable(AutomaticOutboundSync.RealmRecord.self,
            account: identity.account), stored.sameDocument(as: identity),
              let bound = stored.boundScope,
              stored.intendedScope == nil || stored.intendedScope == bound else {
            return false
        }
        return true
    }

    func hasNewMarker(_ identity: AutomaticOutboundSync.RealmRecord) throws -> Bool {
        let stored = try KeychainStore.loadCodable(AutomaticOutboundSync.RealmRecord.self,
            account: identity.account)
        return AutomaticOutboundSync.isNewMarker(stored, for: identity)
    }

    func bindNewMarker(_ expected: AutomaticOutboundSync.RealmRecord) throws {
        guard let realmID = expected.realmID, QuickBooksProviderReference.isValid(realmID),
              let environment = expected.environment,
              ["sandbox", "production"].contains(environment) else {
            throw AutomaticOutboundSync.RealmError.reviewRequired
        }
        guard let stored = try KeychainStore.loadCodable(AutomaticOutboundSync.RealmRecord.self,
            account: expected.account), stored.sameDocument(as: expected) else {
            throw AutomaticOutboundSync.RealmError.reviewRequired
        }
        guard let expectedScope = expected.boundScope,
              stored.intendedScope == expectedScope else {
            throw AutomaticOutboundSync.RealmError.wrongRealm
        }
        if stored.boundScope == expectedScope { return }
        guard stored.boundScope == nil else { throw AutomaticOutboundSync.RealmError.wrongRealm }
        try KeychainStore.saveCodable(expected.boundWithIntent(from: stored), account: expected.account)
    }

    func savedRecord(_ identity: AutomaticOutboundSync.RealmRecord) throws -> AutomaticOutboundSync.RealmRecord? {
        guard let stored = try KeychainStore.loadCodable(AutomaticOutboundSync.RealmRecord.self,
            account: identity.account), stored.sameDocument(as: identity) else { return nil }
        return stored
    }

    func verifyOrBind(_ expected: AutomaticOutboundSync.RealmRecord, explicitReview: Bool) throws {
        let stored = try KeychainStore.loadCodable(AutomaticOutboundSync.RealmRecord.self, account: expected.account)
        switch AutomaticOutboundSync.realmDecision(stored: stored, expected: expected, explicitReview: explicitReview) {
        case .proceed:
            return
        case .bind:
            if let stored {
                try KeychainStore.saveCodable(expected.boundWithIntent(from: stored), account: expected.account)
            } else {
                try KeychainStore.saveCodable(expected, account: expected.account)
            }
        case .reviewRequired:
            throw AutomaticOutboundSync.RealmError.reviewRequired
        case .wrongRealm:
            throw AutomaticOutboundSync.RealmError.wrongRealm
        }
    }

    /// File uploads never bind. Every saved document must already carry proof
    /// for exactly this company and environment before a new provider write.
    func requireProceed(_ expected: [AutomaticOutboundSync.RealmRecord]) throws {
        guard !expected.isEmpty else { throw AutomaticOutboundSync.RealmError.reviewRequired }
        for record in expected {
            let stored = try KeychainStore.loadCodable(AutomaticOutboundSync.RealmRecord.self, account: record.account)
            switch AutomaticOutboundSync.realmDecision(stored: stored, expected: record, explicitReview: false) {
            case .proceed: continue
            case .wrongRealm: throw AutomaticOutboundSync.RealmError.wrongRealm
            case .bind, .reviewRequired: throw AutomaticOutboundSync.RealmError.reviewRequired
            }
        }
    }
}

/// Keeps provider publication alive after the editor that saved a record closes.
/// The SwiftData context and every provider operation remain bound to the same
/// verified workspace; pending records are rediscovered after a process restart.
@MainActor
final class AutomaticOutboundSync {
    static let shared = AutomaticOutboundSync()
    static let estimateProofDidChange = Notification.Name("GunnAireEstimateQuickBooksProofDidChange")

    nonisolated struct RealmRecord: Codable, Equatable, Sendable {
        let companyID: UUID
        let documentType: String
        let documentID: UUID
        let customerID: UUID
        let createdAt: Date
        let realmID: String?
        let environment: String?
        let intendedRealmID: String?
        let intendedEnvironment: String?

        nonisolated init(companyID: UUID, documentType: String, documentID: UUID,
                         customerID: UUID, createdAt: Date, realmID: String?, environment: String?,
                         intendedRealmID: String? = nil, intendedEnvironment: String? = nil) {
            self.companyID = companyID
            self.documentType = documentType
            self.documentID = documentID
            self.customerID = customerID
            self.createdAt = createdAt
            self.realmID = realmID
            self.environment = environment
            self.intendedRealmID = intendedRealmID
            self.intendedEnvironment = intendedEnvironment
        }

        private enum CodingKeys: String, CodingKey {
            case companyID, documentType, documentID, customerID, createdAt
            case realmID, environment, intendedRealmID, intendedEnvironment
        }

        nonisolated init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(companyID: try values.decode(UUID.self, forKey: .companyID),
                documentType: try values.decode(String.self, forKey: .documentType),
                documentID: try values.decode(UUID.self, forKey: .documentID),
                customerID: try values.decode(UUID.self, forKey: .customerID),
                createdAt: try values.decode(Date.self, forKey: .createdAt),
                realmID: try values.decodeIfPresent(String.self, forKey: .realmID),
                environment: try values.decodeIfPresent(String.self, forKey: .environment),
                intendedRealmID: try values.decodeIfPresent(String.self, forKey: .intendedRealmID),
                intendedEnvironment: try values.decodeIfPresent(String.self, forKey: .intendedEnvironment))
        }

        nonisolated var account: String {
            "GunnAireBillingRealm.v1.\(companyID.uuidString.lowercased()).\(documentType).\(documentID.uuidString.lowercased())"
        }

        nonisolated func sameDocument(as other: Self) -> Bool {
            companyID == other.companyID && documentType == other.documentType &&
                documentID == other.documentID && customerID == other.customerID && createdAt == other.createdAt
        }

        nonisolated func sameDocumentKeyAndCustomer(as other: Self) -> Bool {
            companyID == other.companyID && documentType == other.documentType &&
                documentID == other.documentID && customerID == other.customerID
        }

        nonisolated var boundScope: RealmScope? {
            guard let realmID, QuickBooksProviderReference.isValid(realmID),
                  let environment, ["sandbox", "production"].contains(environment) else { return nil }
            return RealmScope(companyID: companyID, realmID: realmID, environment: environment)
        }

        nonisolated var intendedScope: RealmScope? {
            guard let intendedRealmID, QuickBooksProviderReference.isValid(intendedRealmID),
                  let intendedEnvironment, ["sandbox", "production"].contains(intendedEnvironment) else { return nil }
            return RealmScope(companyID: companyID, realmID: intendedRealmID,
                environment: intendedEnvironment)
        }

        nonisolated var originalScope: RealmScope? { intendedScope ?? boundScope }
        nonisolated func boundWithIntent(from stored: Self) -> Self {
            Self(companyID: companyID, documentType: documentType, documentID: documentID,
                customerID: customerID, createdAt: createdAt, realmID: realmID, environment: environment,
                intendedRealmID: stored.intendedRealmID, intendedEnvironment: stored.intendedEnvironment)
        }
        nonisolated var hasValidIntent: Bool {
            guard let intendedScope else { return false }
            return (realmID == nil && environment == nil) || boundScope == intendedScope
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
            if let intended = stored.intendedScope {
                guard intended == expected.boundScope else { return .wrongRealm }
            } else if stored.intendedRealmID != nil || stored.intendedEnvironment != nil {
                return .reviewRequired
            }
            return explicitReview ? .bind : .reviewRequired
        }
        guard let bound = stored.boundScope,
              stored.intendedScope == nil || stored.intendedScope == bound else { return .reviewRequired }
        return bound == expected.boundScope ? .proceed : .wrongRealm
    }

    nonisolated static func isNewMarker(_ stored: RealmRecord?, for identity: RealmRecord) -> Bool {
        guard let stored else { return false }
        return stored.sameDocument(as: identity) && stored.hasValidIntent &&
            stored.realmID == nil && stored.environment == nil
    }

    nonisolated enum EstimateReviewState: Equatable, Sendable {
        case published
        case automaticPending
        case queueUnconfirmed
        case serverQueued
        case reviewRequired
        case unavailable
    }

    /// A missing or mismatched device proof cannot be promoted by a later
    /// connection. This is the same fail-closed decision the automatic queue
    /// makes before publishing, exposed for saved-estimate review.
    nonisolated static func estimateReviewState(quickBooksID: String?, stored: RealmRecord?,
                                                identity: RealmRecord, activeScope: RealmScope?) -> EstimateReviewState {
        if quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return .published
        }
        guard let stored, stored.sameDocument(as: identity) else { return .reviewRequired }
        let bound = stored.boundScope
        let hasBoundProof = bound != nil && (stored.intendedScope == nil || stored.intendedScope == bound)
        let hasFirstSaveMarker = isNewMarker(stored, for: identity)
        guard hasBoundProof || hasFirstSaveMarker else { return .reviewRequired }
        if let activeScope, stored.originalScope != activeScope { return .reviewRequired }
        return .automaticPending
    }

    enum DocumentKey: Hashable {
        case catalog(UUID)
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
    private var proofChecksInFlight: Set<DocumentKey> = []
    private var boundDuringProofCheck: Set<DocumentKey> = []
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
    private var catalogOffset = 0
    private var customerOffset = 0
    private var attachmentOffset = 0
    private var attachmentTasks: [UUID: Task<Void, Never>] = [:]
    private var attachmentDeferredUntil: [UUID: Date] = [:]
    private var calendarRunning = false
    private var calendarQueued = false
    private struct CalendarVerificationScope: Equatable {
        let container: ObjectIdentifier
        let workspace: CompanyWorkspaceOperationStamp
        let googleEmail: String
    }
    private var calendarVerificationScope: CalendarVerificationScope?
    private var calendarVerificationOffset = 0
    private var lastCalendarVerificationAt: Date?
    private let calendarVerificationInterval: TimeInterval = 10 * 60
    private var lastRecoveryAt: Date?
    private let recoveryInterval: TimeInterval = 60
    private let realmStore = QuickBooksDocumentRealmProofStore.shared

    private init() {}

    nonisolated enum ProofWakeDisposition: Equatable, Sendable {
        case ignore
        case handoff
        case enqueue
    }

    nonisolated static func proofWakeDisposition(_ deferred: Date?,
                                                 sameGeneration: Bool,
                                                 sameContainer: Bool,
                                                 proofMatches: Bool,
                                                 checkingProof: Bool) -> ProofWakeDisposition {
        guard sameGeneration, sameContainer, proofMatches else { return .ignore }
        if checkingProof { return .handoff }
        return deferred == Date.distantFuture ? .enqueue : .ignore
    }

    static func requeueAfterProofCheck(_ key: DocumentKey, pending: inout [DocumentKey],
                                       handoffs: inout Set<DocumentKey>,
                                       explicitReviews: Set<DocumentKey>) -> Bool {
        let boundDuringCheck = handoffs.remove(key) != nil
        guard boundDuringCheck || explicitReviews.contains(key), !pending.contains(key) else { return false }
        pending.append(key)
        return true
    }

    private func resumeAfterVerifiedBinding(_ document: QuickBooksBillingDocument,
                                            context: ModelContext, generation: UUID,
                                            stamp: CompanyWorkspaceOperationStamp?) {
        let key: DocumentKey = document.label == "Invoice" ? .invoice(document.id) : .estimate(document.id)
        let sameGeneration = queueGeneration == generation && queueStamp == stamp &&
            queueRealmID == QuickBooksDataAPI.shared.realmID
        let sameContainer = queueContainer == ObjectIdentifier(context.container) && isAuthorized(context)
        switch Self.proofWakeDisposition(deferredUntil[key], sameGeneration: sameGeneration,
            sameContainer: sameContainer, proofMatches: true,
            checkingProof: proofChecksInFlight.contains(key)) {
        case .ignore:
            return
        case .handoff:
            boundDuringProofCheck.insert(key)
        case .enqueue:
            deferredUntil.removeValue(forKey: key)
            if !pending.contains(key), currentKey != key {
                pending.append(key)
            }
            Task { await drain(context: context) }
        }
    }

    /// Write the intended realm before the first local save. An active device
    /// credential supplies intent only; a cached, backend-verified scope may
    /// also supply bound proof when it agrees with that credential.
    func markFirstSave(_ document: QuickBooksBillingDocument, context: ModelContext) async throws {
        guard isAuthorized(context),
              let identity = realmRecord(for: document, realmID: nil, environment: nil),
              let stamp = CompanyWorkspaceAccessController.shared.operationStamp else {
            throw BillingPublicationError.accessRequired
        }
        let api = QuickBooksDataAPI.shared
        let activeScope: RealmScope?
        if api.isAuthenticated, !api.savedSessionEnvironmentDiffersFromCurrentBuild,
           let realmID = api.realmID, QuickBooksProviderReference.isValid(realmID),
           ["sandbox", "production"].contains(api.currentEnvironment) {
            activeScope = RealmScope(companyID: identity.companyID, realmID: realmID,
                environment: api.currentEnvironment)
        } else {
            activeScope = nil
        }
        let cached = try await realmStore.cachedScope(companyID: identity.companyID)
        guard isAuthorized(context), CompanyWorkspaceAccessController.shared.operationStamp == stamp,
              realmRecord(for: document, realmID: nil, environment: nil)?.sameDocument(as: identity) == true,
              currentActiveRealmScope(companyID: identity.companyID) == activeScope,
              let intended = activeScope ?? cached,
              QuickBooksProviderReference.isValid(intended.realmID),
              ["sandbox", "production"].contains(intended.environment) else {
            throw RealmError.reviewRequired
        }
        let verifiedAtSave = cached == intended
        let record = RealmRecord(companyID: identity.companyID, documentType: identity.documentType,
            documentID: identity.documentID, customerID: identity.customerID, createdAt: identity.createdAt,
            realmID: verifiedAtSave ? intended.realmID : nil,
            environment: verifiedAtSave ? intended.environment : nil,
            intendedRealmID: intended.realmID, intendedEnvironment: intended.environment)
        let replacingOrphan = try !Self.hasPersistedDocument(for: document, context: context)
        try await realmStore.markNew(record, replacingOrphan: replacingOrphan)
        guard isAuthorized(context), CompanyWorkspaceAccessController.shared.operationStamp == stamp,
              realmRecord(for: document, realmID: nil, environment: nil)?.sameDocument(as: identity) == true,
              currentActiveRealmScope(companyID: identity.companyID) == activeScope else {
            throw BillingPublicationError.accessRequired
        }
    }

    private func currentActiveRealmScope(companyID: UUID) -> RealmScope? {
        let api = QuickBooksDataAPI.shared
        guard api.isAuthenticated, !api.savedSessionEnvironmentDiffersFromCurrentBuild,
              let realmID = api.realmID, QuickBooksProviderReference.isValid(realmID),
              ["sandbox", "production"].contains(api.currentEnvironment) else { return nil }
        return RealmScope(companyID: companyID, realmID: realmID, environment: api.currentEnvironment)
    }

    func estimateReviewState(for estimate: Estimate, context: ModelContext) async -> EstimateReviewState {
        let originalQuickBooksID = estimate.quickBooksID
        if originalQuickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return .published
        }
        guard isAuthorized(context), estimate.modelContext === context, !estimate.isDeleted,
              let identity = realmRecord(for: .estimate(estimate), realmID: nil, environment: nil),
              let stamp = CompanyWorkspaceAccessController.shared.operationStamp else {
            return .unavailable
        }
        let originalRealmID = QuickBooksDataAPI.shared.realmID
        let activeScope = currentActiveRealmScope(companyID: identity.companyID)
        let stored: RealmRecord?
        do {
            // The proof store actor performs the Keychain read away from the UI actor.
            stored = try await realmStore.savedRecord(identity)
        } catch {
            return .unavailable
        }
        guard isAuthorized(context), CompanyWorkspaceAccessController.shared.operationStamp == stamp,
              CompanyWorkspaceAccessController.shared.verifiedCompanyID == identity.companyID,
              QuickBooksDataAPI.shared.realmID == originalRealmID,
              currentActiveRealmScope(companyID: identity.companyID) == activeScope,
              estimate.modelContext === context, !estimate.isDeleted,
              estimate.quickBooksID == originalQuickBooksID,
              realmRecord(for: .estimate(estimate), realmID: nil, environment: nil)?.sameDocument(as: identity) == true else {
            return .unavailable
        }
        if let bound = stored?.boundScope,
           stored?.intendedScope == nil || stored?.intendedScope == bound {
            let actorEmail = AppAccess.normalizedEmail(AppIdentity.currentEmail)
            if !actorEmail.isEmpty {
                let scope = BillingNativeJournalScope(document: .init(companyID: identity.companyID,
                    realmID: bound.realmID, environment: bound.environment, documentType: .estimate,
                    localDocumentID: identity.documentID), actorEmail: actorEmail)
                do {
                    let background = try await Task.detached(priority: .utility) {
                        try BillingNativeJournalStore.device.read(scope).pending?.backgroundState
                    }.value
                    guard isAuthorized(context), CompanyWorkspaceAccessController.shared.operationStamp == stamp,
                          estimate.quickBooksID == originalQuickBooksID else { return .unavailable }
                    if background == .queueRequested { return .queueUnconfirmed }
                    if background == .queued { return .serverQueued }
                } catch { return .unavailable }
            }
        }
        return Self.estimateReviewState(quickBooksID: originalQuickBooksID, stored: stored,
            identity: identity, activeScope: activeScope)
    }

    /// A fresh context sees only committed records, so inserted drafts cannot
    /// hide a persisted collision with the same deterministic document ID.
    static func hasPersistedDocument(for document: QuickBooksBillingDocument,
                                     context: ModelContext) throws -> Bool {
        let committed = ModelContext(context.container)
        switch document {
        case .invoice(let invoice):
            let id = invoice.id
            var fetch = FetchDescriptor<Invoice>(predicate: #Predicate { $0.id == id })
            fetch.fetchLimit = 1
            let saved = try !committed.fetch(fetch).isEmpty
            return saved || context.deletedModelsArray.contains {
                ($0 as? Invoice)?.id == invoice.id
            }
        case .estimate(let estimate):
            let id = estimate.id
            var fetch = FetchDescriptor<Estimate>(predicate: #Predicate { $0.id == id })
            fetch.fetchLimit = 1
            let saved = try !committed.fetch(fetch).isEmpty
            return saved || context.deletedModelsArray.contains {
                ($0 as? Estimate)?.id == estimate.id
            }
        }
    }

    private func isPendingInsertion(_ document: QuickBooksBillingDocument, context: ModelContext) -> Bool {
        let modelID: PersistentIdentifier
        switch document {
        case .invoice(let value): modelID = value.persistentModelID
        case .estimate(let value): modelID = value.persistentModelID
        }
        return context.insertedModelsArray.contains { $0.persistentModelID == modelID }
    }

    @discardableResult
    func recordNewlySaved(_ document: QuickBooksBillingDocument, context: ModelContext) async throws -> Bool {
        guard isAuthorized(context), let record = realmRecord(for: document, realmID: nil, environment: nil) else {
            throw BillingPublicationError.accessRequired
        }
        adopt(context)
        let generation = queueGeneration
        let stamp = CompanyWorkspaceAccessController.shared.operationStamp
        guard let stored = try await realmStore.savedRecord(record) else { return false }
        guard isAuthorized(context), CompanyWorkspaceAccessController.shared.operationStamp == stamp else {
            throw BillingPublicationError.accessRequired
        }
        if let bound = stored.boundScope {
            guard stored.intendedScope == nil || stored.intendedScope == bound else {
                throw RealmError.reviewRequired
            }
            resumeAfterVerifiedBinding(document, context: context, generation: generation, stamp: stamp)
            return true
        }
        guard let intended = stored.intendedScope, stored.hasValidIntent else { return false }
        if let cached = try await realmStore.cachedScope(companyID: record.companyID) {
            if cached == intended {
                let bound = RealmRecord(companyID: record.companyID, documentType: record.documentType,
                    documentID: record.documentID, customerID: record.customerID, createdAt: record.createdAt,
                    realmID: cached.realmID, environment: cached.environment)
                try await realmStore.bindSaved(bound)
                guard isAuthorized(context), CompanyWorkspaceAccessController.shared.operationStamp == stamp else {
                    throw BillingPublicationError.accessRequired
                }
                resumeAfterVerifiedBinding(document, context: context, generation: generation, stamp: stamp)
                return true
            }
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
        resumeAfterVerifiedBinding(document, context: context, generation: generation, stamp: stamp)
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

    /// The saved-document proof expected for one prepared workflow. Every
    /// field comes from the original local document and the workflow's own
    /// captured company, realm and environment.
    static func realmRecord(for workflow: QuickBooksBillingWorkflow) throws -> RealmRecord {
        let document = workflow.document
        guard let companyID = workflow.run.workflow.companyID,
              let realmID = workflow.run.workflow.realmID, !realmID.isEmpty,
              let customer = document.customer else { throw BillingPublicationError.accessRequired }
        let createdAt: Date
        switch document {
        case .invoice(let value): createdAt = value.createdAt
        case .estimate(let value): createdAt = value.createdAt
        }
        return RealmRecord(companyID: companyID, documentType: document.label.lowercased(),
            documentID: document.id, customerID: customer.id, createdAt: createdAt,
            realmID: realmID, environment: workflow.run.workflow.environment)
    }

    static func requireBoundProof(for workflow: QuickBooksBillingWorkflow) async throws {
        try workflow.check()
        let record = try realmRecord(for: workflow)
        if !GunnAireCloudKit.usesTestDatabase {
            try await QuickBooksDocumentRealmProofStore.shared.requireProceed([record])
        }
        try workflow.check()
    }

    /// Operator-started publication (manual retry or the review page) binds or
    /// verifies the original company before any provider write, exactly as an
    /// explicit Sync Saved Document does. A document first prepared for another
    /// company stops here with nothing sent.
    static func bindExplicitlyReviewed(
        _ workflow: QuickBooksBillingWorkflow,
        bind: ((RealmRecord) async throws -> Void)? = nil
    ) async throws {
        try workflow.check()
        let record = try realmRecord(for: workflow)
        if let bind { try await bind(record) } else { try await bindInDeviceProofStore(record) }
        try workflow.check()
        if case .estimate = workflow.document {
            NotificationCenter.default.post(name: estimateProofDidChange, object: workflow.document.id)
        }
    }

    private static func bindInDeviceProofStore(_ record: RealmRecord) async throws {
        let store = QuickBooksDocumentRealmProofStore.shared
        try await store.verifyOrBind(record, explicitReview: true)
        if let realmID = record.realmID, let environment = record.environment {
            try await store.remember(RealmScope(companyID: record.companyID, realmID: realmID, environment: environment))
        }
    }

    static func pendingDocumentKeys(invoices: [Invoice], estimates: [Estimate]) -> [DocumentKey] {
        QuickBooksEstimatePublicationRecovery.queuedEstimates(from: estimates).map { .estimate($0.id) }
            + QuickBooksInvoicePublicationRecovery.queuedInvoices(from: invoices).map { .invoice($0.id) }
    }

    static func pendingCustomerKeys(_ customers: [Customer]) -> [DocumentKey] {
        customers.filter { $0.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false }
            .map { .customer($0.id) }
    }

    static func pendingCatalogKeys(_ items: [Item]) -> [DocumentKey] {
        QuickBooksCatalogPublicationRecovery.queuedItems(from: items).map { .catalog($0.id) }
    }

    static func pendingRecoveryKeys(invoices: [Invoice], estimates: [Estimate],
                                    customers: [Customer], includeCustomers: Bool,
                                    catalogItems: [Item] = [], includeCatalog: Bool = false) -> [DocumentKey] {
        (includeCatalog ? pendingCatalogKeys(catalogItems) : []) +
            pendingDocumentKeys(invoices: invoices, estimates: estimates) +
            (includeCustomers ? pendingCustomerKeys(customers) : [])
    }

    func publish(_ document: QuickBooksBillingDocument, context: ModelContext,
                 explicitReview: Bool = false,
                 selectedItemCapture: QuickBooksSelectedItemCapture? = nil,
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
                }, selectedItemCapture: selectedItemCapture)
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
            let canRecoverCatalog = (try? QuickBooksSyncAccessPolicy.validate(context: context)) != nil
            let catalogItems: [Item]
            if canRecoverCatalog {
                catalogItems = try Self.nextCatalogPage(context: context, offset: &catalogOffset)
            } else {
                catalogItems = []
            }
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
                customers: customers, includeCustomers: canRecoverCustomers,
                catalogItems: catalogItems, includeCatalog: canRecoverCatalog)
            for key in keys where !pending.contains(key) && currentKey != key &&
                (deferredUntil[key] ?? .distantPast) <= now {
                pending.append(key)
            }
            Task { await drain(context: context) }
            if canRecoverCustomers {
                do {
                    let workflow = try QuickBooksDataAPI.shared.captureWorkspaceWorkflow()
                    guard let realmID = workflow.realmID,
                          let companyID = workflow.companyID,
                          companyID == CompanyWorkspaceAccessController.shared.verifiedCompanyID else { return }
                    let uploads = try QuickBooksInvoiceAttachmentSync.pendingLinkedUploadPage(
                        context: context, offset: &attachmentOffset)
                    let generation = queueGeneration
                    let stamp = queueStamp
                    for upload in uploads {
                        let id = upload.attachment.id
                        guard attachmentTasks[id] == nil,
                              (attachmentDeferredUntil[id] ?? .distantPast) <= now else { continue }
                        let records = upload.documents.compactMap {
                            realmRecord(for: $0, realmID: realmID, environment: workflow.environment)
                        }
                        guard records.count == upload.documents.count,
                              records.allSatisfy({ $0.companyID == companyID }) else { continue }
                        attachmentDeferredUntil[id] = now.addingTimeInterval(300)
                        attachmentTasks[id] = Task { [weak self] in
                            guard let self else { return }
                            defer {
                                if self.queueGeneration == generation { self.attachmentTasks.removeValue(forKey: id) }
                            }
                            do {
                                for record in records {
                                    try await self.realmStore.verifyOrBind(record, explicitReview: false)
                                }
                                try workflow.check()
                                guard self.queueGeneration == generation,
                                      self.queueStamp == stamp,
                                      self.queueRealmID == realmID,
                                      self.isAuthorized(context) else { return }
                                if let uploadTask = QBODocumentNativeWorkflow.enqueue(upload.attachment,
                                    references: upload.references, context: context) {
                                    await uploadTask.value
                                }
                            } catch {
                                guard self.queueGeneration == generation,
                                      self.queueStamp == stamp,
                                      self.isAuthorized(context) else { return }
                                let message = (error as? RealmError)?.localizedDescription ??
                                    "The saved QuickBooks company for this file could not be verified. Review the original billing document before uploading its file."
                                if upload.attachment.quickBooksSyncError != message {
                                    let previous = upload.attachment.quickBooksSyncError
                                    upload.attachment.quickBooksSyncError = message
                                    do { try context.save() }
                                    catch { upload.attachment.quickBooksSyncError = previous }
                                }
                            }
                        }
                    }
                } catch {
                    // Billing documents already queued above still drain; files
                    // remain local and are reconsidered on the next pass.
                }
            }
        } catch {
            // The original records remain local and are reconsidered on the
            // next foreground or connectivity transition.
        }
    }

    static func nextPage<Model: PersistentModel>(
        _ descriptor: FetchDescriptor<Model>, context: ModelContext, offset: inout Int, pageSize: Int = 100
    ) throws -> [Model] {
        guard pageSize > 0 else { return [] }
        var page = descriptor
        page.fetchLimit = pageSize
        page.fetchOffset = offset
        var values = try context.fetch(page)
        if values.isEmpty, offset > 0 {
            offset = 0
            page.fetchOffset = 0
            values = try context.fetch(page)
        }
        offset = values.count < pageSize ? 0 : offset + values.count
        return values
    }

    static func nextCatalogPage(context: ModelContext, offset: inout Int) throws -> [Item] {
        // Queue eligibility trims provider IDs; scanning a bounded page of
        // all items also finds legacy whitespace-only IDs.
        let descriptor = FetchDescriptor<Item>(sortBy: [
            SortDescriptor(\.createdAt), SortDescriptor(\.id)
        ])
        return try nextPage(descriptor, context: context, offset: &offset, pageSize: 250)
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
        guard let stamp = CompanyWorkspaceAccessController.shared.operationStamp else { return }
        let scope = CalendarVerificationScope(container: ObjectIdentifier(context.container),
            workspace: stamp, googleEmail: AppAccess.normalizedEmail(auth.signedInEmail))
        if calendarVerificationScope != scope {
            calendarVerificationScope = scope
            calendarVerificationOffset = 0
            lastCalendarVerificationAt = nil
        }
        let now = Date()
        var verifyConfirmedCalls: [ServiceCall] = []
        if Self.calendarVerificationIsDue(lastAttempt: lastCalendarVerificationAt, now: now,
                                          interval: calendarVerificationInterval) {
            lastCalendarVerificationAt = now
            if let page = try? GoogleCalendarScheduleSync.automaticVerificationPage(
                context: context, now: now, offset: calendarVerificationOffset) {
                calendarVerificationOffset = page.nextOffset
                verifyConfirmedCalls = page.calls
            }
        }
        calendarRunning = true
        let signedInEmail = AppIdentity.currentEmail
        GoogleCalendarScheduleSync.sync(auth: auth, modelContext: context,
            signedInEmail: signedInEmail, isAdminUser: false,
            verifyConfirmedCalls: verifyConfirmedCalls) { [weak self] result in
                guard let self else { return }
                self.calendarRunning = false
                let queued = self.calendarQueued
                self.calendarQueued = false
                var hasPendingOutbound = false
                if case .failure = result {
                    hasPendingOutbound = GoogleCalendarScheduleSync.hasPotentialOutboundSync(in: context)
                }
                switch Self.calendarRecoveryFollowUp(result: result, queued: queued,
                                                     hasPendingOutbound: hasPendingOutbound) {
                case .queuedPass:
                    self.recoverCalendar(context: context, auth: auth)
                case .retryPending:
                    GoogleCalendarScheduleSync.retryPendingAfterAutomaticFailure(
                        auth: auth, modelContext: context, signedInEmail: signedInEmail)
                case .none:
                    break
                }
            }
    }

    enum CalendarRecoveryFollowUp: Equatable {
        case queuedPass
        case retryPending
        case none
    }

    static func calendarRecoveryFollowUp<Value>(result: Result<Value, Error>, queued: Bool,
                                                hasPendingOutbound: Bool) -> CalendarRecoveryFollowUp {
        if queued { return .queuedPass }
        if case .failure = result, hasPendingOutbound { return .retryPending }
        return .none
    }

    static func calendarVerificationIsDue(lastAttempt: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard let lastAttempt else { return true }
        let elapsed = now.timeIntervalSince(lastAttempt)
        return elapsed < 0 || elapsed >= interval
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
            catalogOffset = 0
            customerOffset = 0
            attachmentOffset = 0
            attachmentTasks.removeAll()
            attachmentDeferredUntil.removeAll()
            pending.removeAll()
            preparations.removeAll()
            explicitReviewKeys.removeAll()
            deferredUntil.removeAll()
            proofChecksInFlight.removeAll()
            boundDuringProofCheck.removeAll()
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
        case .catalog, .customer:
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
            var proofCheckInProgress = false
            var hasNewMarkerForCurrentDocument = false
            do {
                if case .catalog(let id) = next {
                    try await publishCatalog(id, context: context)
                    guard queueGeneration == generation else { currentKey = nil; break }
                    deferredUntil.removeValue(forKey: next)
                    currentKey = nil
                    continue
                }
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
                if isPendingInsertion(document, context: context) {
                    deferredUntil[next] = Date().addingTimeInterval(recoveryInterval)
                    currentKey = nil
                    continue
                }
                if !explicitReview {
                    guard let identity = realmRecord(for: document, realmID: nil, environment: nil) else {
                        deferredUntil[next] = .distantFuture
                        let callbacks = completions.removeValue(forKey: next) ?? []
                        callbacks.forEach { $0(.failure(RealmError.reviewRequired)) }
                        currentKey = nil
                        continue
                    }
                    proofChecksInFlight.insert(next)
                    proofCheckInProgress = true
                    let hasProof = try await realmStore.hasBoundProof(identity)
                    let hasNewMarker = hasProof ? false : try await realmStore.hasNewMarker(identity)
                    hasNewMarkerForCurrentDocument = hasNewMarker
                    guard queueGeneration == generation else { break }
                    proofChecksInFlight.remove(next)
                    proofCheckInProgress = false
                    if !hasProof && !hasNewMarker {
                        if Self.requeueAfterProofCheck(next, pending: &pending,
                            handoffs: &boundDuringProofCheck, explicitReviews: explicitReviewKeys) {
                            currentKey = nil
                            continue
                        }
                        // The proof can only be added through explicit review
                        // or a new-document save on this device. Do not read
                        // the same missing Keychain entry on every timer pass.
                        deferredUntil[next] = .distantFuture
                        let callbacks = completions.removeValue(forKey: next) ?? []
                        callbacks.forEach { $0(.failure(RealmError.reviewRequired)) }
                        currentKey = nil
                        continue
                    }
                    boundDuringProofCheck.remove(next)
                    explicitReviewKeys.remove(next)
                }
                let capturedPreparation = preparations.removeValue(forKey: next)
                let result = try await publish(document, context: context,
                    preparation: capturedPreparation, explicitReview: explicitReview,
                    allowNewMarker: !explicitReview && hasNewMarkerForCurrentDocument)
                guard queueGeneration == generation else { currentKey = nil; break }
                let callbacks = completions.removeValue(forKey: next) ?? []
                callbacks.forEach { $0(.success(result)) }
                deferredUntil.removeValue(forKey: next)
                explicitReviewKeys.remove(next)
                currentKey = nil
            } catch {
                guard queueGeneration == generation else { break }
                currentKey = nil
                proofChecksInFlight.remove(next)
                if proofCheckInProgress,
                   Self.requeueAfterProofCheck(next, pending: &pending,
                       handoffs: &boundDuringProofCheck, explicitReviews: explicitReviewKeys) {
                    continue
                }
                boundDuringProofCheck.remove(next)
                explicitReviewKeys.remove(next)
                let failure = error as? PublicationFailure
                let underlying = failure?.underlying ?? error
                let reported: Error = failure ?? underlying
                let callbacks = completions.removeValue(forKey: next) ?? []
                callbacks.forEach { $0(.failure(reported)) }
                if case .catalog = next {
                    deferredUntil[next] = Self.catalogRetryDelay(after: underlying)
                        .map { Date().addingTimeInterval($0) } ?? .distantFuture
                } else if failure?.mayHaveWritten == true {
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

    /// Unknown server attempts can become verifiable later, but a rejected
    /// proposal must wait for human correction. The backend journal prevents
    /// a retry of the same local item from sending a second provider create.
    static func catalogRetryDelay(after error: Error) -> TimeInterval? {
        if let error = error as? CatalogPublicationError {
            switch error {
            case .needsReview: return 10 * 60
            case .accessRequired, .unavailable: return 5 * 60
            case .invalidResponse, .invalidProposal: return nil
            }
        }
        if let error = error as? QuickBooksCatalogWorkflowError {
            switch error {
            case .itemChanged, .saveFailed, .busy: return 5 * 60
            case .reviewChanged, .invalidItem, .remoteIdentity, .invalidResponse: return nil
            }
        }
        return 5 * 60
    }

    private func publish(_ document: QuickBooksBillingDocument, context: ModelContext,
                         preparation capturedPreparation: SharedBillingPreparation?,
                         explicitReview: Bool, allowNewMarker: Bool) async throws -> String {
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
            if allowNewMarker {
                try await realmStore.bindNewMarker(record)
            } else {
                try await realmStore.verifyOrBind(record, explicitReview: explicitReview)
            }
            if explicitReview {
                try await realmStore.remember(RealmScope(companyID: companyID,
                    realmID: realmID, environment: workflow.run.workflow.environment))
                if case .estimate = document {
                    NotificationCenter.default.post(name: Self.estimateProofDidChange, object: document.id)
                }
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
            if outcome.queued { return outcome.message }
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

    private func publishCatalog(_ id: UUID, context: ModelContext) async throws {
        let lifecycle = QuickBooksSyncLifecycle()
        defer { lifecycle.cancel() }
        let preparation: SharedCatalogPreparation
        do {
            var fetch = FetchDescriptor<Item>(predicate: #Predicate { $0.id == id })
            fetch.fetchLimit = 1
            guard let item = try context.fetch(fetch).first,
                  !Self.pendingCatalogKeys([item]).isEmpty else { return }
            let generation = queueGeneration
            let stamp = queueStamp
            preparation = try SharedCatalogPreparation(item: item, context: context,
                isCurrent: { [weak self] in
                    self?.queueGeneration == generation && self?.queueStamp == stamp &&
                        self?.isAuthorized(context) == true
                })
        } catch {
            throw PublicationFailure(underlying: error, mayHaveWritten: false)
        }
        var workflow: QuickBooksCatalogWorkflow?
        do {
            let prepared = try await preparation.makeWorkflow(lifecycle: lifecycle, mode: .publish)
            workflow = prepared
            _ = try await prepared.execute()
        } catch {
            if let workflow { try? workflow.recordFailure(error) }
            throw PublicationFailure(underlying: error, mayHaveWritten: workflow?.attemptedWrite == true)
        }
    }
}
