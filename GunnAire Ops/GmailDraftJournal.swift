import Foundation
import CryptoKit
import SwiftData
import Observation
import CoreData

enum GmailDraftError: LocalizedError, Equatable {
    case storage, changed, access, locked, limit, businessChanged
    var errorDescription: String? {
        switch self {
        case .storage: "Your draft could not be saved or verified. Keep this message open and try again. Existing drafts have not been cleared."
        case .changed: "This draft changed in another window. Close and reopen the original draft before editing."
        case .access: "Verify access to the original business and Google account before opening this draft."
        case .locked: "This message may already have been sent. Review Sent; another copy will not be sent from this draft."
        case .limit: "This device's draft storage is full. Keep this message open and review your saved drafts."
        case .businessChanged: "The original customer, work, or document source changed or could not be verified. Save any pending edits, return to the original record, regenerate its PDF if attached, and prepare an updated message. This draft was not sent."
        }
    }
}

struct GmailDraftScope: Codable, Equatable {
    let companyID: UUID
    let backendOrigin: String
    let actorEmail: String
    let googleEmail: String

    var storageKey: String {
        CompanyWorkspaceSession.digest([companyID.uuidString.lowercased(), backendOrigin, actorEmail, googleEmail].joined(separator: "\n"))
    }

    func validate() throws {
        guard let url = URL(string: backendOrigin), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              actorEmail == AppAccess.normalizedEmail(actorEmail), actorEmail == googleEmail,
              (try? GmailAddressList.parse(actorEmail)) == [actorEmail] else { throw GmailDraftError.access }
    }

    @MainActor static func capture(auth: GoogleAuthManager, context: ModelContext) throws -> Self {
        let controller = CompanyWorkspaceAccessController.shared
        guard controller.authorizedContainer === context.container,
              let company = controller.verifiedCompanyID,
              auth.canUseCurrentBusinessIdentity else { throw GmailDraftError.access }
        let scope = Self(companyID: company, backendOrigin: Config.Backend.normalizedBaseURL,
            actorEmail: AppAccess.normalizedEmail(AppIdentity.currentEmail), googleEmail: AppAccess.normalizedEmail(auth.signedInEmail))
        try scope.validate()
        return scope
    }
    @MainActor static func captureCompany(context: ModelContext) throws -> Self {
        let controller = CompanyWorkspaceAccessController.shared
        guard controller.authorizedContainer === context.container, let company = controller.verifiedCompanyID,
              let session = CompanyWorkspaceSession.current else { throw GmailDraftError.access }
        let scope = Self(companyID: company, backendOrigin: session.backendOrigin,
                         actorEmail: session.email, googleEmail: session.email)
        try scope.validate(); return scope
    }
}

struct GmailDraftFile: Codable, Equatable {
    let name: String
    let mimeType: String
    let data: Data
    init(_ file: GmailAttachment) { name = file.fileName; mimeType = file.mimeType; data = file.data }
    var attachment: GmailAttachment { .init(fileName: name, mimeType: mimeType, data: data) }
}

/// Incomplete addresses and subjects remain editable drafts. Sending still
/// uses GmailOutgoingMessage validation and the current business/consent gate.
struct GmailDraftContent: Codable, Equatable {
    var to: String
    var subject: String
    var body: String
    var files: [GmailDraftFile] = []
    var reply: GmailReplyContext?
    var business: GmailBusinessContext?
    var requiresBusinessContext = false
    var attachmentError: String?
    var businessSnapshot: [String]?

    var hasContent: Bool { !to.isEmpty || !subject.isEmpty || !body.isEmpty || !files.isEmpty || attachmentError != nil }
    func validate() throws {
        guard to.utf8.count <= 16_384, subject.utf8.count <= 16_384, body.utf8.count <= 2 * 1024 * 1024,
              (attachmentError?.utf8.count ?? 0) <= 4096 else { throw GmailDraftError.limit }
        try GmailOutgoingMessage.validateAttachments(files.map(\.attachment))
        guard (businessSnapshot?.count ?? 0) <= 100,
              (businessSnapshot?.reduce(0) { $0 + $1.utf8.count } ?? 0) <= 2 * 1024 * 1024 else { throw GmailDraftError.limit }
        if let reply {
            guard GoogleAuthManager.calendarPathComponent(reply.threadID) != nil,
                  GmailReplyContext.isValidMessageID(reply.messageID), reply.references.count <= 50,
                  reply.references.allSatisfy(GmailReplyContext.isValidMessageID), reply.subject.utf8.count <= 16_384 else {
                throw GmailDraftError.storage
            }
        }
    }
}

/// Stable domain values, never process-specific object identifiers. A reopened
/// draft cannot adopt changed sold prices, contact consent or linked work just
/// because the new send coordinator captured a fresh in-memory baseline.
enum GmailDraftBusinessSnapshot {
    static func capture(_ business: GmailBusinessContext?, context: ModelContext) throws -> [String]? {
        try AppPerformanceSignposts.measure("Mail Source Preparation") {
            try captureValues(business, context: context)
        }
    }

    private static func captureValues(_ business: GmailBusinessContext?, context: ModelContext) throws -> [String]? {
        guard let business else { return nil }
        let customerID = business.customerID
        let customers = try context.fetch(FetchDescriptor<Customer>(predicate: #Predicate { $0.id == customerID }))
        guard customers.count == 1 else { throw GmailDraftError.businessChanged }
        let customer = customers[0]
        var values = customerValues(customer)
        if business.workflow == .accountStatement {
            values += try accountStatementValues(accountStatementInputs(customerID: customerID, context: context))
        }
        var sourceCall: ServiceCall?
        var sourceInvoice: Invoice?
        var sourceEstimate: Estimate?
        if let id = business.serviceCallID {
            let rows = try context.fetch(FetchDescriptor<ServiceCall>(predicate: #Predicate { $0.id == id }))
            guard rows.count == 1, rows[0].customer === customer else { throw GmailDraftError.businessChanged }
            let row = rows[0]
            sourceCall = row
            values += [id.uuidString, row.status.rawValue, row.eventTitle ?? "", row.scheduledDate.description,
                String(row.duration), row.notes ?? "", row.assignedTechnician?.id.uuidString ?? "", row.additionalTechnicianIDsJSON ?? ""]
        }
        if let id = business.invoiceID {
            let rows = try context.fetch(FetchDescriptor<Invoice>(predicate: #Predicate { $0.id == id }))
            guard rows.count == 1, rows[0].customer === customer else { throw GmailDraftError.businessChanged }
            let row = rows[0]
            sourceInvoice = row
            values += [id.uuidString, row.status, String(row.amount), String(describing: row.quickBooksBalanceDue),
                row.catalogSnapshotJSON ?? "", row.quickBooksID ?? "", row.serviceCallID?.uuidString ?? ""]
            values.append(try digest([row.createdAt.description, row.dueDate?.description ?? "",
                row.lineItemSummary, row.notes ?? "", row.completionNotes ?? "", row.siteAddress ?? "",
                row.workTypeRaw, String(row.salesTaxAmount), row.taxCalculationStatusRawValue ?? "",
                row.taxCalculatedAt?.description ?? "", row.customerSignatureName ?? "",
                row.customerSignedAt?.description ?? "", row.finalizedAt?.description ?? "",
                row.projectMilestoneID?.uuidString ?? "", row.projectMilestoneTitle ?? "",
                String(describing: row.projectMilestoneSequence), String(describing: row.projectContractAmount),
                String(describing: row.projectBillingPercent)]))
        }
        if let id = business.estimateID {
            let rows = try context.fetch(FetchDescriptor<Estimate>(predicate: #Predicate { $0.id == id }))
            guard rows.count == 1, rows[0].customer === customer else { throw GmailDraftError.businessChanged }
            let row = rows[0]
            sourceEstimate = row
            values += [id.uuidString, row.status, String(row.amount), row.catalogSnapshotJSON ?? "", row.quickBooksID ?? "", row.serviceCallID?.uuidString ?? ""]
            values.append(try digest([row.createdAt.description, row.lineItemSummary, row.notes ?? "",
                row.siteAddress ?? "", String(row.salesTaxAmount), row.taxCalculationStatusRawValue ?? "",
                row.taxCalculatedAt?.description ?? "", row.parentEstimateID?.uuidString ?? "",
                row.changeOrderReason ?? "", row.proposalGroupID?.uuidString ?? "", row.proposalOption ?? "",
                String(row.proposalIsRecommended), row.customerApprovedByName ?? "",
                row.customerApprovedAt?.description ?? "", row.customerApprovalMethodRaw ?? "",
                row.customerApprovalReference ?? "", row.customerApprovalRecordedByEmail ?? ""]))
        }
        if let id = business.maintenanceContractID {
            let rows = try context.fetch(FetchDescriptor<RecurringMaintenanceContract>(predicate: #Predicate { $0.id == id }))
            guard rows.count == 1, rows[0].customer === customer else { throw GmailDraftError.businessChanged }
            values += [id.uuidString, String(rows[0].active)]
        }
        let payments: [Payment]
        if let sourceInvoice {
            let invoiceID = sourceInvoice.id
            payments = try boundedFetch(FetchDescriptor<Payment>(predicate: #Predicate { $0.invoice?.id == invoiceID }), context: context)
                .sorted { $0.id.uuidString < $1.id.uuidString }
            values.append(try FieldPaymentReceiptReconciliation.paymentDigest(payments))
        } else { payments = [] }
        // Receipts are text-only invoice/payment messages, not an onsite report.
        // Keep the document graph for origins which actually generate a PDF.
        if business.workflow != .receipt &&
            (sourceInvoice != nil || sourceEstimate != nil || business.workflow == .customerDocument) {
            let calls = try boundedFetch(FetchDescriptor<ServiceCall>(predicate: #Predicate { $0.customer?.id == customerID }), context: context)
            let attachments = try boundedFetch(FetchDescriptor<ServiceDocumentAttachment>(predicate: #Predicate { $0.customer?.id == customerID }), context: context)
            let equipment = try boundedFetch(FetchDescriptor<CustomerEquipment>(predicate: #Predicate { $0.customer?.id == customerID }), context: context)
            var formTemplates: [FieldFormTemplate] = []
            var formResponses: [FieldFormResponse] = []
            var entries: [TimeEntry] = []
            var activities: [ServiceCallActivity] = []
            let material: JobMaterialCloseoutSummary
            if let sourceCall {
                let callID = sourceCall.id
                formResponses = try boundedFetch(FetchDescriptor<FieldFormResponse>(predicate: #Predicate { $0.serviceCallID == callID }), context: context)
                let templateIDs = formResponses.map(\.templateID)
                formTemplates = try boundedFetch(FetchDescriptor<FieldFormTemplate>(predicate: #Predicate {
                    $0.isActive || templateIDs.contains($0.id)
                }), context: context)
                entries = try boundedFetch(FetchDescriptor<TimeEntry>(predicate: #Predicate { $0.serviceCall?.id == callID }), context: context)
                activities = try boundedFetch(FetchDescriptor<ServiceCallActivity>(predicate: #Predicate { $0.serviceCallID == callID }), context: context)
                let estimates = try boundedFetch(FetchDescriptor<Estimate>(predicate: #Predicate { $0.customer?.id == customerID }), context: context)
                let milestones = try boundedFetch(FetchDescriptor<ProjectMilestone>(predicate: #Predicate { $0.projectServiceCallID == callID }), context: context)
                let jobMovements = try boundedFetch(FetchDescriptor<InventoryMovement>(predicate: #Predicate { $0.serviceCallID == callID }), context: context)
                let projectEstimateID = milestones.sorted { $0.sequence < $1.sequence }.first?.estimateID ?? sourceCall.linkedEstimateID
                let projectEstimate = estimates.first { $0.id == projectEstimateID }
                let linkedEstimate = estimates.first { $0.id == sourceCall.linkedEstimateID }
                let materialEstimate = !milestones.isEmpty && projectEstimate != nil ? projectEstimate : (sourceInvoice == nil ? linkedEstimate : nil)
                let snapshots = materialEstimate?.catalogLineSnapshots ?? sourceInvoice?.catalogLineSnapshots ?? []
                let legacySummary = materialEstimate?.lineItemSummary ?? sourceInvoice?.lineItemSummary ?? ""
                let itemIDs = Array(Set(jobMovements.map(\.itemID) + snapshots.flatMap {
                    [$0.catalogItemID] + $0.soldLeaves.map(\.catalogItemID) + ($0.assembly?.components.map(\.itemID) ?? [])
                }))
                // Core Data cannot translate constant.contains(model.name).
                // The legacy policy accepts any catalog-name substring, including
                // service items with a ledger. Filter a capped superset in Swift;
                // reject an oversized catalog rather than omit a requirement.
                let normalizedSummary = legacySummary.lowercased()
                let materialItems = try boundedFetch(FetchDescriptor<Item>(), context: context).filter {
                    itemIDs.contains($0.id) || normalizedSummary.contains($0.name.lowercased())
                }
                let materialIDs = materialItems.map(\.id)
                let movements = try boundedFetch(FetchDescriptor<InventoryMovement>(predicate: #Predicate {
                    materialIDs.contains($0.itemID) || $0.serviceCallID == callID
                }), context: context)
                material = JobMaterialCloseoutPolicy.summary(for: sourceCall, invoice: sourceInvoice,
                    estimates: estimates, projectMilestones: milestones, items: materialItems, movements: movements)
            } else { material = .notApplicable }
            let source = CustomerDocumentExporter.mailSourceValues(estimate: sourceEstimate, invoice: sourceInvoice,
                serviceCall: sourceCall, payments: payments, attachments: attachments,
                equipmentProfiles: equipment, serviceCalls: calls,
                fieldFormTemplates: formTemplates,
                fieldFormResponses: formResponses,
                timeEntries: entries,
                materialReadiness: material,
                serviceCallActivities: activities,
                requireWorkPerformedLog: UserDefaults.standard.object(forKey: "requireWorkPerformedLogForCloseout") as? Bool ?? true)
            values.append(try digest(source))
        }
        return values
    }

    /// Create the projection and its source fence from the same bounded inputs.
    /// The returned projection retains its original cutoff/calendar; subsequent
    /// validation hashes saved inputs, never a new time-dependent projection.
    static func prepareAccountStatement(customer: Customer, context: ModelContext) throws
        -> (statement: CustomerAccountStatementSnapshot, sourceSnapshot: [String]) {
        let customerID = customer.id
        let rows = try context.fetch(FetchDescriptor<Customer>(predicate: #Predicate { $0.id == customerID }))
        guard rows.count == 1, rows.first === customer else { throw GmailDraftError.businessChanged }
        let inputs = try accountStatementInputs(customerID: customerID, context: context)
        let values = try customerValues(customer) + accountStatementValues(inputs)
        let statement = CustomerDocumentExporter.accountStatementSnapshot(for: customer,
            invoices: inputs.invoices, payments: inputs.payments)
        return (statement, values)
    }

    private static func customerValues(_ customer: Customer) -> [String] {
        ["customer-document-source-v2", customer.id.uuidString, customer.name, customer.email ?? "",
         customer.address ?? "", customer.phone ?? "", String(customer.allowsTransactionalEmail),
         String(customer.allowsMarketing), customer.communicationConsentUpdatedAt?.description ?? ""]
    }

    private static func accountStatementInputs(customerID: UUID, context: ModelContext) throws
        -> (invoices: [Invoice], payments: [Payment]) {
        let invoices = try boundedFetch(FetchDescriptor<Invoice>(predicate: #Predicate {
            $0.customer?.id == customerID
        }), context: context)
        guard !invoices.isEmpty else { throw GmailDraftError.businessChanged }
        // A chained optional relationship is not translatable by Core Data.
        // Use the already verified invoice identities with a single relationship.
        let invoiceIDs = invoices.map(\.id)
        let payments = try boundedFetch(FetchDescriptor<Payment>(predicate: #Predicate { payment in
            payment.invoice.flatMap { invoice in
                invoiceIDs.contains(invoice.id)
            } ?? false
        }), context: context)
        return (invoices, payments)
    }

    private static func accountStatementValues(_ inputs: (invoices: [Invoice], payments: [Payment])) throws -> [String] {
        // Include membership as well as totals: new/deleted invoices, refunds,
        // duplicate identities and reviewed milestone drafts change the source.
        var rows: [String] = []
        for invoice in inputs.invoices.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            rows += [invoice.id.uuidString, try BillingMilestoneReconciliation.digest(invoice),
                invoice.quickBooksID ?? "", String(describing: invoice.quickBooksBalanceDue),
                invoice.quickBooksLastSyncedAt?.description ?? "", invoice.quickBooksSyncStatus,
                invoice.quickBooksSyncDetail ?? "", invoice.quickBooksPaymentReviewJSON ?? "",
                invoice.taxCalculationStatusRawValue ?? "", invoice.taxCalculatedAt?.description ?? "",
                invoice.milestoneDraftReceiptJSON ?? ""]
        }
        return ["account-statement-inputs-v1", try digest(rows),
            try FieldPaymentReceiptReconciliation.paymentDigest(inputs.payments)]
    }

    private static func boundedFetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>, context: ModelContext) throws -> [T] {
        var descriptor = descriptor
        descriptor.fetchLimit = 2_001
        let rows = try context.fetch(descriptor)
        guard rows.count <= 2_000 else { throw GmailDraftError.businessChanged }
        return rows
    }

    private static func digest(_ values: [String]) throws -> String {
        let bytes = try JSONEncoder().encode(values)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func validate(_ expected: [String]?, business: GmailBusinessContext?, context: ModelContext) throws {
        guard try expected == capture(business, context: context) else { throw GmailDraftError.businessChanged }
    }
}

/// A history anchor is a value, never a UI context or managed model.
nonisolated struct GmailSourceHistoryAnchor: Sendable {
    let storeID: String
    let token: DefaultHistoryToken
    let transactionID: Int64
}

nonisolated enum GmailSourceHistoryReader {
    static func capture(_ container: ModelContainer) async throws -> GmailSourceHistoryAnchor? {
        try await Task.detached(priority: .userInitiated) {
            guard container.configurations.count == 1, let configuration = container.configurations.first else {
                throw GmailDraftError.businessChanged
            }
            if configuration.isStoredInMemoryOnly { return nil }
            guard let storeID = try CompanyWorkspaceStore.identity(at: configuration.url) else { throw GmailDraftError.businessChanged }
            let context = ModelContext(container); context.autosaveEnabled = false
            var descriptor = HistoryDescriptor<DefaultHistoryTransaction>(sortBy: [SortDescriptor(\.transactionIdentifier, order: .reverse)])
            descriptor.fetchLimit = 1
            guard let row = try context.fetchHistory(descriptor).first,
                  row.storeIdentifier.lowercased() == storeID.lowercased() else { throw GmailDraftError.businessChanged }
            return GmailSourceHistoryAnchor(storeID: storeID.lowercased(), token: row.token, transactionID: row.transactionIdentifier)
        }.value
    }

    /// Transaction count is bounded; a transaction's change payload can still
    /// be large, so all history materialization stays off the main actor.
    static func verify(_ anchor: GmailSourceHistoryAnchor, container: ModelContainer,
                       ownAuthor: String? = nil, allowedIDs: Set<PersistentIdentifier> = []) async throws -> GmailSourceHistoryAnchor {
        try await Task.detached(priority: .userInitiated) {
            guard container.configurations.count == 1, let configuration = container.configurations.first,
                  !configuration.isStoredInMemoryOnly,
                  try CompanyWorkspaceStore.identity(at: configuration.url)?.lowercased() == anchor.storeID else {
                throw GmailDraftError.businessChanged
            }
            let context = ModelContext(container); context.autosaveEnabled = false
            let identifier = anchor.transactionID
            var exact = HistoryDescriptor<DefaultHistoryTransaction>(predicate: #Predicate { $0.transactionIdentifier == identifier })
            exact.fetchLimit = 1
            guard let original = try context.fetchHistory(exact).first,
                  original.storeIdentifier.lowercased() == anchor.storeID,
                  original.token == anchor.token else { throw GmailDraftError.businessChanged }
            let previous = anchor.token
            var newer = HistoryDescriptor<DefaultHistoryTransaction>(predicate: #Predicate { $0.token > previous })
            newer.fetchLimit = ownAuthor == nil ? 1 : 2
            let rows = try context.fetchHistory(newer)
            guard try CompanyWorkspaceStore.identity(at: configuration.url)?.lowercased() == anchor.storeID else {
                throw GmailDraftError.businessChanged
            }
            guard let ownAuthor else {
                guard rows.isEmpty else { throw GmailDraftError.businessChanged }
                return anchor
            }
            guard rows.count == 1, let row = rows.first,
                  row.storeIdentifier.lowercased() == anchor.storeID, row.author == ownAuthor,
                  row.transactionIdentifier > anchor.transactionID, row.token > anchor.token,
                  !row.changes.isEmpty,
                  row.changes.allSatisfy({ allowedIDs.contains($0.changedPersistentIdentifier) }) else {
                throw GmailDraftError.businessChanged
            }
            return GmailSourceHistoryAnchor(storeID: anchor.storeID, token: row.token, transactionID: row.transactionIdentifier)
        }.value
    }
}

/// Synchronous checks inspect only observation, pending models and epochs.
/// Disk history is resolved asynchronously before an actual provider request.
@MainActor
final class GmailDraftSourceLease {
    let snapshot: [String]?
    private let invalidation: GmailDraftSourceInvalidation
    private let settings: [String]
    private let notificationCenter: NotificationCenter
    private var history: GmailSourceHistoryAnchor?
    private var verifiedRemoteEpoch: UInt64?

    /// Synchronous construction is restricted to genuinely in-memory stores.
    convenience init(business: GmailBusinessContext, context: ModelContext,
                     notificationCenter: NotificationCenter = .default,
                     validatePreparation: () throws -> Void = {}) throws {
        guard context.container.configurations.allSatisfy(\.isStoredInMemoryOnly) else { throw GmailDraftError.businessChanged }
        try self.init(business: business, context: context, history: nil,
            invalidation: GmailDraftSourceInvalidation(context: context, notificationCenter: notificationCenter),
            notificationCenter: notificationCenter, validatePreparation: validatePreparation)
        verifiedRemoteEpoch = invalidation.remoteEpoch
    }

    static func prepare(business: GmailBusinessContext, context: ModelContext,
                        notificationCenter: NotificationCenter = .default,
                        validatePreparation: () throws -> Void = {}) async throws -> GmailDraftSourceLease {
        try requireClean(context)
        let invalidation = GmailDraftSourceInvalidation(context: context, notificationCenter: notificationCenter)
        let history = try await GmailSourceHistoryReader.capture(context.container)
        try invalidation.check()
        let lease = try GmailDraftSourceLease(business: business, context: context, history: history,
            invalidation: invalidation, notificationCenter: notificationCenter, validatePreparation: validatePreparation)
        try await lease.validateHistory(context: context)
        return lease
    }

    private init(business: GmailBusinessContext, context: ModelContext, history: GmailSourceHistoryAnchor?,
                 invalidation: GmailDraftSourceInvalidation, notificationCenter: NotificationCenter,
                 validatePreparation: () throws -> Void) throws {
        self.invalidation = invalidation; self.history = history; self.notificationCenter = notificationCenter
        invalidation.setStoreID(history?.storeID)
        try validatePreparation()
        try Self.requireClean(context)
        settings = Self.currentSettings
        let captured = withObservationTracking {
            Result { try GmailDraftBusinessSnapshot.capture(business, context: context) }
        } onChange: { [weak invalidation] in invalidation?.sourceChanged() }
        snapshot = try captured.get()
        try check(context: context)
    }

    func check(context: ModelContext) throws {
        try invalidation.check()
        try Self.requireClean(context)
        guard settings == Self.currentSettings else { throw GmailDraftError.businessChanged }
    }

    func checkTransportPermit(context: ModelContext) throws {
        try check(context: context)
        guard verifiedRemoteEpoch == invalidation.remoteEpoch else { throw GmailDraftError.businessChanged }
    }

    func validateHistory(context: ModelContext) async throws {
        for _ in 0..<2 {
            try check(context: context)
            let epoch = invalidation.remoteEpoch
            if let history { _ = try await GmailSourceHistoryReader.verify(history, container: context.container) }
            try check(context: context)
            if epoch == invalidation.remoteEpoch {
                verifiedRemoteEpoch = epoch
                return
            }
        }
        throw GmailDraftError.businessChanged
    }

    /// The author is installed only around this synchronous save. After it is
    /// restored, the entire old-anchor interval must contain exactly that one
    /// transaction and only the model identities touched by this write.
    func replacingAfterHistoryWrite(business: GmailBusinessContext, context: ModelContext,
                                   expectedSnapshot: (() throws -> [String]?)? = nil,
                                   beforeWrite: () throws -> Void = {},
                                   validatePreparation: () throws -> Void,
                                   write: () throws -> Set<PersistentIdentifier>) async throws -> GmailDraftSourceLease {
        try await validateHistory(context: context)
        try checkTransportPermit(context: context)
        try beforeWrite()
        let author = "mail-history-" + UUID().uuidString.lowercased()
        let allowedIDs = try invalidation.withOwnSave {
            let previousAuthor = context.author
            context.author = author
            defer { context.author = previousAuthor }
            return try write()
        }
        // Establish fresh Observation before awaiting history; the old observer
        // is permanently retired and may have fired during inverse bookkeeping.
        let replacement = try GmailDraftSourceLease(business: business, context: context, history: history,
            invalidation: GmailDraftSourceInvalidation(context: context, notificationCenter: notificationCenter),
            notificationCenter: notificationCenter, validatePreparation: validatePreparation)
        let expected: [String]?
        if let expectedSnapshot { expected = try expectedSnapshot() } else { expected = snapshot }
        guard expected == replacement.snapshot,
              settings == Self.currentSettings else { throw GmailDraftError.businessChanged }
        if let history {
            replacement.history = try await GmailSourceHistoryReader.verify(history, container: context.container,
                ownAuthor: author, allowedIDs: allowedIDs)
            replacement.invalidation.setStoreID(replacement.history?.storeID)
        }
        try invalidation.checkAfterWrite()
        try replacement.check(context: context)
        try await replacement.validateHistory(context: context)
        try invalidation.checkAfterWrite()
        try validatePreparation()
        try replacement.checkTransportPermit(context: context)
        return replacement
    }

    private static func requireClean(_ context: ModelContext) throws {
        guard !context.hasChanges, context.insertedModelsArray.isEmpty,
              context.changedModelsArray.isEmpty, context.deletedModelsArray.isEmpty else { throw GmailDraftError.businessChanged }
    }

    private static var currentSettings: [String] {
        [String(UserDefaults.standard.object(forKey: "requireWorkPerformedLogForCloseout") as? Bool ?? true),
         Locale.current.identifier, TimeZone.current.identifier]
    }
}

/// Thread-safe epochs contain no context/model. Known store notifications ask
/// for history classification; unknown payloads and actual external context
/// saves/imports revoke immediately. No notification handler reads the database.
private nonisolated final class GmailDraftSourceInvalidation: @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false
    private var ownSave = false
    private var retired = false
    private var epoch: UInt64 = 0
    private var storeID: String?
    private var observers: [NSObjectProtocol] = []
    private let notificationCenter: NotificationCenter
    var remoteEpoch: UInt64 { lock.withLock { epoch } }

    @MainActor init(context: ModelContext, notificationCenter: NotificationCenter) {
        self.notificationCenter = notificationCenter
        let contextID = ObjectIdentifier(context)
        let containerID = ObjectIdentifier(context.container)
        let isInMemory = context.container.configurations.allSatisfy(\.isStoredInMemoryOnly)
        let configurationURLs = Set(context.container.configurations.map { $0.url.standardizedFileURL.resolvingSymlinksInPath() })
        for name in [ModelContext.willSave, ModelContext.didSave] {
            observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                guard let self else { return }
                guard let saving = notification.object as? ModelContext else { self.invalidate(); return }
                if ObjectIdentifier(saving.container) != containerID {
                    if isInMemory || saving.container.configurations.allSatisfy(\.isStoredInMemoryOnly) { return }
                    let savingURLs = Set(saving.container.configurations.map { $0.url.standardizedFileURL.resolvingSymlinksInPath() })
                    if !savingURLs.isEmpty, !configurationURLs.isEmpty,
                       savingURLs.isDisjoint(with: configurationURLs) { return }
                }
                self.lock.withLock {
                    if ObjectIdentifier(saving) != contextID || !self.ownSave { self.invalidated = true }
                }
            })
        }
        observers.append(notificationCenter.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: nil) { [weak self] notification in
            guard let self else { return }
            guard let coordinator = notification.object as? NSPersistentStoreCoordinator,
                  let url = notification.userInfo?[NSPersistentStoreURLKey] as? URL,
                  let uuid = notification.userInfo?[NSStoreUUIDKey] as? String,
                  notification.userInfo?[NSPersistentHistoryTokenKey] is NSPersistentHistoryToken else {
                self.invalidate(); return
            }
            let stores = coordinator.persistentStores
            // A SQLite coordinator cannot mutate a separate in-memory store,
            // even when SwiftData assigns both configurations the default URL.
            if isInMemory, !stores.isEmpty, stores.allSatisfy({ $0.type == NSSQLiteStoreType }) { return }
            self.lock.withLock {
                let sameID = self.storeID == uuid.lowercased()
                let sameURL = configurationURLs.contains(url.standardizedFileURL.resolvingSymlinksInPath())
                if let expected = self.storeID, sameURL, expected != uuid.lowercased() {
                    self.invalidated = true
                } else if sameID || sameURL {
                    if self.epoch == .max { self.invalidated = true } else { self.epoch += 1 }
                }
            }
        })
        observers.append(notificationCenter.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil, queue: nil) { [weak self] notification in
                guard let self else { return }
                guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                        as? NSPersistentCloudKitContainer.Event else { self.invalidate(); return }
                self.lock.withLock {
                    guard self.storeID == event.storeIdentifier.lowercased() else {
                        if self.storeID == nil, !isInMemory { self.invalidated = true }
                        return
                    }
                    if event.type == .import { self.invalidated = true }
                }
            })
    }

    deinit { observers.forEach { notificationCenter.removeObserver($0) } }
    func setStoreID(_ value: String?) { lock.withLock { storeID = value } }
    func invalidate() { lock.withLock { invalidated = true } }
    func sourceChanged() { lock.withLock { if !ownSave { invalidated = true } } }
    func check() throws {
        guard !lock.withLock({ invalidated || retired }) else { throw GmailDraftError.businessChanged }
    }
    func checkAfterWrite() throws {
        guard !lock.withLock({ invalidated }) else { throw GmailDraftError.businessChanged }
    }
    func withOwnSave<T>(_ body: () throws -> T) throws -> T {
        try check()
        lock.withLock { ownSave = true }
        defer { lock.withLock { ownSave = false; retired = true } }
        return try body()
    }
}

enum GmailDraftState: String, Codable { case editing, sending, review, sent, discarded }

struct GmailServerDraftAttempt: Codable, Equatable {
    let id: UUID
    let scope: GmailServerScope
}

/// Constructed only after the original server content, identity and result have
/// been checked below. Generic draft writes cannot manufacture this transition.
fileprivate struct GmailServerDraftResolution: Codable, Equatable {
    let attempt: GmailServerDraftAttempt
    let state: GmailServerOperationState
}

struct GmailDraftRecord: Codable, Equatable, Identifiable {
    var version = 1
    let id: UUID
    let scope: GmailDraftScope
    var revision = 0
    var content: GmailDraftContent
    var state: GmailDraftState = .editing
    var updatedAt = Date()
    var status: String?
    var serverAttempt: GmailServerDraftAttempt?
    var retiredServerAttempts: [GmailServerDraftAttempt]?
    fileprivate var serverResolution: GmailServerDraftResolution?
    init(id: UUID, scope: GmailDraftScope, content: GmailDraftContent) {
        self.id = id; self.scope = scope; self.content = content
    }
    var messageID: String { "<gunnaire-\((serverAttempt?.id ?? id).uuidString.lowercased())@gunnaire.com>" }
    var editable: Bool { state == .editing }
    func validate() throws {
        try scope.validate(); try content.validate()
        guard version == 1, revision >= 0, revision < Int.max, updatedAt.timeIntervalSince1970.isFinite,
              (status?.utf8.count ?? 0) <= 4096 else { throw GmailDraftError.storage }
        let attempts = (retiredServerAttempts ?? []) + (serverAttempt.map { [$0] } ?? [])
        guard attempts.count <= 100, Set(attempts.map(\.id)).count == attempts.count,
              attempts.allSatisfy({ $0.scope.draftScope == scope }) else { throw GmailDraftError.storage }
        if let serverResolution, !attempts.contains(serverResolution.attempt) { throw GmailDraftError.storage }
    }
}

struct GmailDraftSummary: Identifiable, Codable, Equatable {
    let id: UUID
    let subject: String
    let recipient: String
    let state: GmailDraftState
    let updatedAt: Date
    let business: GmailBusinessContext?
}

private struct GmailDraftIndex: Codable, Equatable {
    let revision: Int
    let summary: GmailDraftSummary
    init(_ record: GmailDraftRecord) {
        revision = record.revision
        summary = .init(id: record.id, subject: record.content.subject, recipient: record.content.to,
            state: record.state, updatedAt: record.updatedAt, business: record.content.business)
    }
}

/// All in-process readers/writers serialize on MainActor. CAS revisions prevent
/// stale windows from replacing content or unlocking an already-started send.
/// Individual encrypted files avoid rewriting every attachment on each edit.
@MainActor struct GmailDraftStore {
    let read: (GmailDraftScope, UUID) throws -> GmailDraftRecord?
    let write: (GmailDraftRecord, Int?) throws -> Void
    let list: (GmailDraftScope) throws -> [GmailDraftSummary]

    static func encrypted(directory: URL, activeDraftLimit: Int = 512, key: @escaping (Bool) throws -> Data) -> Self {
        func folder(_ scope: GmailDraftScope) -> URL { directory.appendingPathComponent(scope.storageKey, isDirectory: true) }
        func file(_ scope: GmailDraftScope, _ id: UUID) -> URL { folder(scope).appendingPathComponent(id.uuidString.lowercased() + ".sealed") }
        func aad(_ scope: GmailDraftScope, _ id: UUID) -> Data { Data((scope.storageKey + "/" + id.uuidString.lowercased()).utf8) }
        let magic = Data("GAMAIL1\n".utf8)
        func index(_ scope: GmailDraftScope, _ id: UUID, using secret: SymmetricKey) throws -> (GmailDraftIndex, Int) {
            let url = file(scope, id)
            let resource = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard resource.isRegularFile == true, resource.isSymbolicLink != true,
                  (resource.fileSize ?? Int.max) <= 40 * 1024 * 1024 + 65536 else { throw GmailDraftError.storage }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard let header = try handle.read(upToCount: 12), header.count == 12,
                  header.prefix(8) == magic else { throw GmailDraftError.storage }
            let size = header.suffix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard (28...65536).contains(size), let data = try handle.read(upToCount: size), data.count == size else { throw GmailDraftError.storage }
            let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: secret,
                authenticating: aad(scope, id) + Data("/index".utf8))
            let value = try JSONDecoder().decode(GmailDraftIndex.self, from: plaintext)
            guard value.summary.id == id, value.revision >= 0 else { throw GmailDraftError.storage }
            return (value, 12 + size)
        }
        func read(_ scope: GmailDraftScope, _ id: UUID) throws -> GmailDraftRecord? {
            try scope.validate()
            let url = file(scope, id)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            do {
                let secret = SymmetricKey(data: try key(false))
                let (metadata, offset) = try index(scope, id, using: secret)
                let data = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: url).dropFirst(offset)),
                    using: secret, authenticating: aad(scope, id))
                let record = try JSONDecoder().decode(GmailDraftRecord.self, from: data)
                try record.validate()
                guard record.scope == scope, record.id == id, GmailDraftIndex(record) == metadata else { throw GmailDraftError.storage }
                return record
            } catch { throw GmailDraftError.storage }
        }
        func ids(_ scope: GmailDraftScope) throws -> [UUID] {
            try scope.validate()
            guard FileManager.default.fileExists(atPath: folder(scope).path) else { return [] }
            do {
                let entries = try FileManager.default.contentsOfDirectory(at: folder(scope), includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "sealed" }
                guard entries.count <= 65536 else { throw GmailDraftError.limit }
                return try entries.map {
                    guard let id = UUID(uuidString: $0.deletingPathExtension().lastPathComponent),
                          $0.lastPathComponent == id.uuidString.lowercased() + ".sealed" else { throw GmailDraftError.storage }
                    return id
                }
            } catch let error as GmailDraftError { throw error }
            catch { throw GmailDraftError.storage }
        }
        func summaries(_ scope: GmailDraftScope) throws -> [GmailDraftSummary] {
            do {
                let identifiers = try ids(scope)
                guard !identifiers.isEmpty else { return [] }
                let secret = SymmetricKey(data: try key(false))
                var result: [GmailDraftSummary] = []
                for id in identifiers {
                    let (metadata, _) = try index(scope, id, using: secret)
                    if metadata.summary.state != .sent && metadata.summary.state != .discarded { result.append(metadata.summary) }
                }
                return result.sorted { $0.updatedAt > $1.updatedAt }
            } catch let error as GmailDraftError { throw error }
            catch { throw GmailDraftError.storage }
        }
        return Self(read: read, write: { record, expected in
            try record.validate()
            let previous = try read(record.scope, record.id)
            guard previous?.revision == expected, record.revision == (expected.map { $0 + 1 } ?? 0) else { throw GmailDraftError.changed }
            if let previous {
                let legal: Bool
                switch previous.state {
                case .editing: legal = [.editing, .sending, .discarded].contains(record.state)
                case .sending: legal = [.editing, .review, .sent].contains(record.state)
                case .review:
                    if let original = previous.serverAttempt, let resolution = record.serverResolution,
                       resolution.attempt == original {
                        switch resolution.state {
                        case .confirmed:
                            legal = record.state == .sent && record.serverAttempt == original
                        case .rejected, .cancelled:
                            legal = record.state == .editing && record.serverAttempt == nil &&
                                record.retiredServerAttempts == (previous.retiredServerAttempts ?? []) + [original]
                        default:
                            legal = record.state == .review && record.serverAttempt == original
                        }
                    } else { legal = false }
                case .sent, .discarded: legal = false
                }
                guard legal, previous.state == .editing || previous.content == record.content else { throw GmailDraftError.locked }
            } else {
                guard record.state == .editing else { throw GmailDraftError.locked }
                guard (1...512).contains(activeDraftLimit), try summaries(record.scope).count < activeDraftLimit,
                      try ids(record.scope).count < 65536 else { throw GmailDraftError.limit }
            }
            do {
                let plaintext = try JSONEncoder().encode(record)
                guard plaintext.count < 40 * 1024 * 1024 - 64 else { throw GmailDraftError.limit }
                // A lost key must never be regenerated while any encrypted
                // draft exists, including another account's retained drafts.
                let existingRoot = FileManager.default.fileExists(atPath: directory.path)
                let secret = SymmetricKey(data: try key(!existingRoot))
                let sealed = try AES.GCM.seal(plaintext, using: secret, authenticating: aad(record.scope, record.id))
                let metadata = try AES.GCM.seal(JSONEncoder().encode(GmailDraftIndex(record)), using: secret,
                    authenticating: aad(record.scope, record.id) + Data("/index".utf8))
                guard let payload = sealed.combined, let indexData = metadata.combined, indexData.count <= 65536 else { throw GmailDraftError.storage }
                var size = UInt32(indexData.count).bigEndian
                var data = magic
                withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
                data.append(indexData); data.append(payload)
                try FileManager.default.createDirectory(at: folder(record.scope), withIntermediateDirectories: true)
                var root = directory
                var resources = URLResourceValues(); resources.isExcludedFromBackup = true
                try root.setResourceValues(resources)
                try data.write(to: file(record.scope, record.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch let error as GmailDraftError { throw error }
            catch { throw GmailDraftError.storage }
        }, list: summaries)
    }

    static var device: Self {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return .init(read: { _, _ in throw GmailDraftError.storage }, write: { _, _ in throw GmailDraftError.storage }, list: { _ in throw GmailDraftError.storage })
        }
        let directory = root.appendingPathComponent("MailDrafts-v1", isDirectory: true)
        return encrypted(directory: directory) { create in
            let account = "MailDraftEncryption-v1"
            if let key = try KeychainStore.loadCodable(Data.self, account: account) {
                guard key.count == 32 else { throw GmailDraftError.storage }
                return key
            }
            guard create else { throw GmailDraftError.storage }
            let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try KeychainStore.saveCodable(key, account: account)
            return key
        }
    }
}

@MainActor final class GmailDraftSession {
    private(set) var record: GmailDraftRecord
    private let store: GmailDraftStore
    private let access: () throws -> Void
    private var ownsDispatch = false
    private(set) var serverCanCancel = false

    init(record: GmailDraftRecord, store: GmailDraftStore, access: @escaping () throws -> Void) throws {
        self.record = record; self.store = store; self.access = access
        try access(); try record.validate()
        if let saved = try store.read(record.scope, record.id) {
            guard saved == record else { throw GmailDraftError.changed }
        } else { try store.write(record, nil) }
    }

    func save(_ content: GmailDraftContent) throws {
        guard record.editable else { throw GmailDraftError.locked }
        var next = record; next.content = content; next.status = nil
        if content != record.content { retireAttempt(&next) }
        try update(next)
    }

    func prepareServerAttempt(scope: GmailServerScope) throws {
        try verify()
        guard record.editable, scope.draftScope == record.scope, record.content.business == nil,
              !record.content.requiresBusinessContext else { throw GmailDraftError.access }
        if let original = record.serverAttempt {
            guard original.scope == scope else { throw GmailDraftError.access }
            return
        }
        var next = record
        next.serverAttempt = .init(id: UUID(), scope: scope)
        next.serverResolution = nil
        try update(next)
    }

    private func retireAttempt(_ record: inout GmailDraftRecord) {
        if let original = record.serverAttempt {
            record.retiredServerAttempts = (record.retiredServerAttempts ?? []) + [original]
            record.serverAttempt = nil
        }
    }

    func verify() throws {
        try access()
        guard try store.read(record.scope, record.id) == record else { throw GmailDraftError.changed }
    }

    func begin() throws {
        guard record.editable else { throw GmailDraftError.locked }
        var next = record; next.state = .sending; next.status = GmailDraftError.locked.localizedDescription
        try update(next)
        ownsDispatch = true
    }

    func finish(_ outcome: GmailSendOutcome) throws {
        guard record.state == .sending, ownsDispatch else { throw GmailDraftError.locked }
        var next = record
        next.state = outcome.state == .sent ? .sent : outcome.canRetry ? .editing : .review
        next.status = outcome.message
        if outcome.canRetry { retireAttempt(&next) }
        try update(next)
        ownsDispatch = false
    }

    /// Only a read of the exact retained server content and original outcome
    /// can resolve an interrupted send. Never rebind it to a replacement grant.
    func recoverServer(provider: WorkspaceProviderOperation, cancelUnsent: Bool = false) async throws -> GmailSendOutcome {
        try verify(); try provider.check()
        guard !record.editable, record.state != .discarded, let attempt = record.serverAttempt,
              let server = provider.serverMail, server.scope == attempt.scope,
              record.content.business == nil, !record.content.requiresBusinessContext else { throw GmailDraftError.access }
        let original = record
        if original.state == .sent { return .init(state: .sent, message: "The original message is saved in Gmail Sent.") }
        let content = original.content
        let expected = try GmailServerMessage(GmailOutgoingMessage(to: content.to, subject: content.subject,
            body: content.body, attachments: content.files.map(\.attachment), reply: content.reply))
        guard try await server.savedMessage(id: attempt.id, operation: provider) == expected else { throw GmailDraftError.changed }
        try verify(); guard record == original else { throw GmailDraftError.changed }
        let response = try await (cancelUnsent ? server.cancel(id: attempt.id, operation: provider)
            : server.operation(id: attempt.id, recovery: true, operation: provider))
        try provider.check(); try verify(); guard record == original else { throw GmailDraftError.changed }
        var next = record
        next.serverResolution = .init(attempt: attempt, state: response.state)
        let result: GmailSendOutcome
        switch response.state {
        case .confirmed:
            next.state = .sent
            result = .init(state: .sent, message: "The original message is saved in Gmail Sent.")
        case .rejected, .cancelled:
            next.state = .editing; retireAttempt(&next)
            result = .init(state: .notSent, message: "The original message was not sent. You can edit this draft.")
        case .prepared:
            next.state = .review
            result = .init(state: .reviewRequired, message: "The original message is saved but has not been sent. Cancel the unsent request to edit this draft.")
        default:
            next.state = .review; result = .uncertain
        }
        serverCanCancel = response.state == .prepared
        next.status = result.message
        try update(next); ownsDispatch = false
        return result
    }

    func discard() throws {
        guard record.editable else { throw GmailDraftError.locked }
        var next = record; next.state = .discarded
        // Keep only a tombstone: stale windows cannot resurrect discarded work.
        next.content = .init(to: "", subject: "", body: ""); next.status = nil
        try update(next)
    }

    private func update(_ next: GmailDraftRecord) throws {
        try access()
        var next = next; next.revision += 1; next.updatedAt = Date()
        try store.write(next, record.revision)
        record = next
    }
}
