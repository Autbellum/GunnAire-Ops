import Foundation
import SwiftData
import CryptoKit

enum QuickBooksBillingWorkflowError: LocalizedError, Equatable {
    case busy, accessDenied, changed, customerConflict, remoteIdentity, remoteLines, paidRemoteInvoice, saveFailed

    var errorDescription: String? {
        switch self {
        case .busy: "This document is already syncing. Wait for its result before retrying."
        case .accessDenied: "Your current business access or job assignment does not allow publishing this document."
        case .changed: "The saved document, customer, items or payment history changed. Review the latest version before syncing again."
        case .customerConflict: "This QuickBooks customer is already linked to another local customer. Review the customer records before retrying."
        case .remoteIdentity: "QuickBooks returned a different or incomplete document identity. Review the original document before retrying."
        case .remoteLines: "QuickBooks has different or unconfirmed line items. Review the original document before retrying; do not create a second document."
        case .paidRemoteInvoice: "QuickBooks reports payment activity or an unconfirmed balance. Refresh and review this invoice before changing its lines."
        case .saveFailed: "QuickBooks may have accepted the request, but its confirmation could not be saved locally. Review the original document before retrying."
        }
    }
}


enum QuickBooksBillingLineEvidence {
    static func matches(expected: [QuickBooksLineItem], reported: [QuickBooksLineItem]?) -> Bool {
        guard let reported else { return false }
        guard (try? QuickBooksSalesLineContract.totals(expected)) != nil,
              (try? QuickBooksSalesLineContract.totals(reported, allowsSubtotal: true)) != nil else { return false }
        // QBO adds a computed subtotal row; it is not an additional sold item.
        let rows = reported.filter { $0.DetailType != "SubTotalLineDetail" }
        guard rows.count == expected.count else { return false }
        return zip(expected, rows).allSatisfy { left, right in
            guard left.DetailType == right.DetailType, (right.hasExplicitAmount || right.DetailType == "GroupLineDetail"), right.Amount.isFinite,
                  abs(left.Amount - right.Amount) <= 0.009 else { return false }
            if left.DetailType == "GroupLineDetail" {
                guard let a = left.GroupLineDetail, let b = right.GroupLineDetail else { return false }
                return a.GroupItemRef.value == b.GroupItemRef.value && a.Quantity == b.Quantity &&
                    matches(expected: a.Line, reported: b.Line)
            }
            if left.DetailType == "DiscountLineDetail" {
                return left.DiscountLineDetail?.PercentBased == right.DiscountLineDetail?.PercentBased &&
                    left.DiscountLineDetail?.DiscountPercent == right.DiscountLineDetail?.DiscountPercent
            }
            let a = left.SalesItemLineDetail, b = right.SalesItemLineDetail
            return a.ItemRef.value == b.ItemRef.value && a.Qty == b.Qty && a.UnitPrice == b.UnitPrice &&
                a.TaxCodeRef?.value == b.TaxCodeRef?.value
        }
    }
}


enum QuickBooksBillingDocument {
    case invoice(Invoice), estimate(Estimate)

    var id: UUID {
        switch self { case .invoice(let value): value.id; case .estimate(let value): value.id }
    }
    var customer: Customer? {
        switch self { case .invoice(let value): value.customer; case .estimate(let value): value.customer }
    }
    var serviceCallID: UUID? {
        switch self { case .invoice(let value): value.serviceCallID; case .estimate(let value): value.serviceCallID }
    }
    var snapshotJSON: String? {
        switch self { case .invoice(let value): value.catalogSnapshotJSON; case .estimate(let value): value.catalogSnapshotJSON }
    }
    var subtotal: Double {
        switch self { case .invoice(let value): value.subtotalAmount; case .estimate(let value): value.subtotalAmount }
    }
    var hasValidStoredAmounts: Bool {
        let amount: Double, tax: Double
        switch self {
        case .invoice(let value): amount = value.amount; tax = value.salesTaxAmount
        case .estimate(let value): amount = value.amount; tax = value.salesTaxAmount
        }
        return amount.isFinite && amount >= 0 && tax.isFinite && tax >= 0 && tax <= amount
    }
    var label: String {
        switch self { case .invoice: "Invoice"; case .estimate: "Estimate" }
    }
    var projectMilestoneID: UUID? {
        switch self { case .invoice(let value): value.projectMilestoneID; case .estimate: nil }
    }

    /// Capture values, not a closure that reads mutable "before" values later.
    private static func unchanged<M: AnyObject, V: Equatable>(_ model: M, _ paths: [KeyPath<M, V>]) -> () -> Bool {
        let values = paths.map { model[keyPath: $0] }
        return { paths.map { model[keyPath: $0] } == values }
    }

    func validation(context: ModelContext) -> () throws -> Void {
        let identifier = id
        let originalCustomer = customer
        let checks: [() -> Bool]
        let exists: () throws -> Bool
        switch self {
        case .invoice(let value):
            exists = {
                let matches = try context.fetch(FetchDescriptor<Invoice>()).filter { $0.id == identifier }
                return matches.count == 1 && matches.first === value && value.customer === originalCustomer
            }
            checks = [
                Self.unchanged(value, [\Invoice.id]),
                Self.unchanged(value, [\Invoice.serviceCallID, \.serviceLocationID, \.projectMilestoneID]),
                Self.unchanged(value, [\Invoice.siteAddress, \.quickBooksID, \.catalogSnapshotJSON, \.notes,
                    \.customerSignatureName, \.customerSignatureImageBase64, \.completionNotes,
                    \.projectMilestoneTitle, \.taxCalculationStatusRawValue, \.quickBooksSyncDetail, \.milestoneDraftReceiptJSON]),
                Self.unchanged(value, [\Invoice.status, \.workTypeRaw, \.lineItemSummary, \.quickBooksSyncStatus]),
                Self.unchanged(value, [\Invoice.amount, \.salesTaxAmount]),
                Self.unchanged(value, [\Invoice.quickBooksBalanceDue, \.projectContractAmount, \.projectBillingPercent]),
                Self.unchanged(value, [\Invoice.dueDate, \.customerSignedAt, \.finalizedAt, \.taxCalculatedAt, \.quickBooksLastSyncedAt]),
                Self.unchanged(value, [\Invoice.projectMilestoneSequence]),
                Self.unchanged(value, [\Invoice.createdAt])
            ]
        case .estimate(let value):
            exists = {
                let matches = try context.fetch(FetchDescriptor<Estimate>()).filter { $0.id == identifier }
                return matches.count == 1 && matches.first === value && value.customer === originalCustomer
            }
            checks = [
                Self.unchanged(value, [\Estimate.id]),
                Self.unchanged(value, [\Estimate.serviceCallID, \.serviceLocationID, \.scheduledServiceCallID,
                    \.parentEstimateID, \.proposalGroupID]),
                Self.unchanged(value, [\Estimate.siteAddress, \.quickBooksID, \.catalogSnapshotJSON, \.notes,
                    \.changeOrderReason, \.proposalOption, \.taxCalculationStatusRawValue,
                    \.customerApprovedByName, \.customerApprovalMethodRaw, \.customerApprovalReference,
                    \.customerApprovalRecordedByEmail, \.customerApprovalSignatureImageBase64]),
                Self.unchanged(value, [\Estimate.status, \.lineItemSummary]),
                Self.unchanged(value, [\Estimate.amount, \.salesTaxAmount]),
                Self.unchanged(value, [\Estimate.customerApprovedAt, \.taxCalculatedAt]),
                Self.unchanged(value, [\Estimate.proposalIsRecommended]),
                Self.unchanged(value, [\Estimate.createdAt])
            ]
        }
        return {
            guard try exists(), checks.allSatisfy({ $0() }) else { throw QuickBooksBillingWorkflowError.changed }
        }
    }

    /// Restore only this workflow's sync fields, never roll back the context or
    /// another record's unsaved work when a local confirmation fails to save.
    func syncRestoration() -> () -> Void {
        switch self {
        case .invoice(let value):
            let id = value.quickBooksID, detail = value.quickBooksSyncDetail, status = value.quickBooksSyncStatus
            let date = value.quickBooksLastSyncedAt, due = value.dueDate, taxDate = value.taxCalculatedAt
            let amount = value.amount, tax = value.salesTaxAmount, balance = value.quickBooksBalanceDue
            let taxStatus = value.taxCalculationStatusRawValue, paymentStatus = value.status
            return {
                value.quickBooksID = id; value.quickBooksSyncDetail = detail; value.quickBooksSyncStatus = status
                value.quickBooksLastSyncedAt = date; value.dueDate = due; value.taxCalculatedAt = taxDate
                value.amount = amount; value.salesTaxAmount = tax; value.quickBooksBalanceDue = balance
                value.taxCalculationStatusRawValue = taxStatus; value.status = paymentStatus
            }
        case .estimate(let value):
            let id = value.quickBooksID, status = value.taxCalculationStatusRawValue
            let amount = value.amount, tax = value.salesTaxAmount, date = value.taxCalculatedAt
            return {
                value.quickBooksID = id; value.taxCalculationStatusRawValue = status
                value.amount = amount; value.salesTaxAmount = tax; value.taxCalculatedAt = date
            }
        }
    }
}

enum QuickBooksBillingAccessPolicy {
    static func allows(email: String?, users: [AppUser], verifiedRole: AppUserRole?,
                       isInvoice: Bool, assignedToJob: Bool) -> Bool {
        let normalized = AppAccess.normalizedEmail(email)
        let matches = users.filter { AppAccess.normalizedEmail($0.email) == normalized }
        guard !normalized.isEmpty, let role = verifiedRole, !matches.isEmpty,
              matches.allSatisfy({ $0.isActive && $0.role == role }) else { return false }
        switch role {
        case .admin: return true
        case .accounting: return isInvoice
        case .dispatcher: return !isInvoice
        case .fieldTechnician: return assignedToJob
        case .standard: return false
        }
    }

    static func validate(context: ModelContext, document: QuickBooksBillingDocument) throws {
        // CloudKit may delete/invalidate a retained model while a request awaits.
        // Establish live object membership before reading any of its fields.
        let present: Bool
        switch document {
        case .invoice(let value): present = try context.fetch(FetchDescriptor<Invoice>()).contains { $0 === value }
        case .estimate(let value): present = try context.fetch(FetchDescriptor<Estimate>()).contains { $0 === value }
        }
        guard present else { throw QuickBooksBillingWorkflowError.accessDenied }
        let controller = CompanyWorkspaceAccessController.shared
        let users = try context.fetch(FetchDescriptor<AppUser>())
        let email = AppIdentity.currentEmail
        let normalized = AppAccess.normalizedEmail(email)
        let calls = try context.fetch(FetchDescriptor<ServiceCall>()).filter { $0.id == document.serviceCallID }
        let technicianIDs = Set(try context.fetch(FetchDescriptor<Technician>())
            .filter { AppAccess.normalizedEmail($0.contactInfo) == normalized }.map(\.id))
        let assigned = calls.count == 1 && calls.first.map {
            $0.customer === document.customer &&
            (AppAccess.normalizedEmail($0.assignedTechnician?.contactInfo) == normalized ||
             !technicianIDs.isDisjoint(with: $0.assignedCrewTechnicianIDs))
        } == true
        let isInvoice: Bool
        switch document { case .invoice: isInvoice = true; case .estimate: isInvoice = false }
        let fixture = GunnAireCloudKit.usesTestDatabase
        guard (fixture || controller.authorizedContainer === context.container),
              allows(email: email, users: users,
                     verifiedRole: fixture ? AppAccess.activeRole(email: email, users: users) : controller.verifiedRole,
                     isInvoice: isInvoice, assignedToJob: assigned) else {
            throw QuickBooksBillingWorkflowError.accessDenied
        }
    }
}

private struct QuickBooksBillingPaymentRevision: Equatable {
    let object: ObjectIdentifier
    let id: UUID
    let amount: Double
    let refund: Bool
    let providerState: String?
    let accountingID: String?
    let chargeID: String?
    init(_ value: Payment) {
        object = ObjectIdentifier(value); id = value.id; amount = value.amount; refund = value.isRefund
        providerState = value.providerPaymentStatus; accountingID = value.quickBooksID; chargeID = value.quickBooksChargeID
    }
}

/// A single capture covers customer recovery, approved item publication, the
/// accounting document request, and its local confirmation. All tests inject
/// fixture transport; this service never starts a customer email or payment.
@MainActor
final class QuickBooksBillingWorkflow {
    struct Outcome {
        let message: String
        let recovered: Bool
        var invoice: QuickBooksInvoice? = nil
        var estimate: QuickBooksEstimate? = nil
    }

    let run: QuickBooksSyncRun
    let document: QuickBooksBillingDocument
    private let lifecycle: QuickBooksSyncLifecycle
    private let api: QuickBooksDataAPI
    private let context: ModelContext
    private let customer: Customer
    private let customerDraft: QuickBooksCustomerCreateDraft
    private let actorEmail: String?
    private var customerID: String?
    private let items: [Item]
    private var itemRevisions: [ObjectIdentifier: QuickBooksCatalogItemRevision]
    private var validateDocument: () throws -> Void
    private let paymentRevisions: [QuickBooksBillingPaymentRevision]
    private let validateCatalogAccess: () throws -> Void
    private let save: (ModelContext) throws -> Void
    private var started = false
    private var completed = false
    private(set) var attemptedWrite = false
    private let billingJournal: BillingNativeJournalStore
    private let documentUploads: QBODocumentNativeWorkflow.Dependencies?
    private(set) var sharedPublication: BillingNativePublication?

    init(document: QuickBooksBillingDocument, context: ModelContext, api: QuickBooksDataAPI,
         lifecycle: QuickBooksSyncLifecycle,
         validateAccess: (() throws -> Void)? = nil,
         validateCatalogAccess: (() throws -> Void)? = nil,
         billingJournal: BillingNativeJournalStore? = nil,
         documentUploads: QBODocumentNativeWorkflow.Dependencies? = nil,
         save: @escaping (ModelContext) throws -> Void = { try $0.save() },
         actorEmail: String? = nil) throws {
        guard lifecycle.activeID == nil else { throw QuickBooksBillingWorkflowError.busy }
        guard let customer = document.customer else { throw QuickBooksBillingWorkflowError.changed }
        let validate = validateAccess ?? { try QuickBooksBillingAccessPolicy.validate(context: context, document: document) }
        try validate()
        self.document = document; self.context = context; self.api = api; self.lifecycle = lifecycle
        self.customer = customer; self.customerDraft = QuickBooksCustomerCreateOperation.draft(for: customer)
        self.actorEmail = actorEmail ?? AppIdentity.currentEmail
        customerID = customer.quickBooksID
        self.save = save
        self.billingJournal = billingJournal ?? .device
        self.documentUploads = documentUploads
        self.validateCatalogAccess = validateCatalogAccess ?? { try QuickBooksSyncAccessPolicy.validate(context: context) }
        validateDocument = document.validation(context: context)
        try validateDocument()
        let allItems = try context.fetch(FetchDescriptor<Item>())
        let selectedIDs = Set(CatalogLineItemSnapshot.decoded(from: document.snapshotJSON)
            .flatMap { [$0.catalogItemID] + $0.soldLeaves.map(\.catalogItemID) })
        items = allItems.filter { selectedIDs.contains($0.id) }
        itemRevisions = Dictionary(uniqueKeysWithValues: items.map { (ObjectIdentifier($0), QuickBooksCatalogItemRevision($0)) })
        paymentRevisions = try context.fetch(FetchDescriptor<Payment>()).filter { $0.invoice?.id == document.id }
            .sorted { $0.id.uuidString < $1.id.uuidString }.map(QuickBooksBillingPaymentRevision.init)
        run = try lifecycle.begin(api: api, validateAccess: validate)
        do { try check() } catch { lifecycle.finish(run); throw error }
    }

    func check() throws {
        try run.check()
        try validateDocument()
        guard document.hasValidStoredAmounts else { throw QuickBooksBillingWorkflowError.changed }
        try QuickBooksDocumentLinePublication.validateSnapshotTotals(snapshotJSON: document.snapshotJSON,
                                                                    expectedSubtotal: document.subtotal)
        let customers = try context.fetch(FetchDescriptor<Customer>()).filter { $0.id == customerDraft.localCustomerID }
        guard customers.count == 1, customers.first === customer,
              QuickBooksCustomerCreateOperation.draft(for: customer) == customerDraft,
              customer.quickBooksID == customerID else { throw QuickBooksBillingWorkflowError.changed }
        if let customerID, !customerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try validateCustomerAssignment(customerID)
        }
        let currentItems = try context.fetch(FetchDescriptor<Item>())
        for item in items {
            guard let revision = itemRevisions[ObjectIdentifier(item)] else { throw QuickBooksBillingWorkflowError.changed }
            let matches = currentItems.filter { $0.id == revision.id }
            guard matches.count == 1, matches.first === item,
                  QuickBooksCatalogItemRevision(item) == itemRevisions[ObjectIdentifier(item)] else {
                throw QuickBooksBillingWorkflowError.changed
            }
            if item.requiresPricebookReview { throw PricebookPublicationError.reviewRequired(item.name) }
            if item.isCatalogArchived { throw PricebookPublicationError.archived(item.name) }
        }
        let currentPayments = try context.fetch(FetchDescriptor<Payment>()).filter { $0.invoice?.id == document.id }
            .sorted { $0.id.uuidString < $1.id.uuidString }.map(QuickBooksBillingPaymentRevision.init)
        guard currentPayments == paymentRevisions else { throw QuickBooksBillingWorkflowError.changed }
        try QuickBooksCatalogMappingIntegrity.validateDocumentItems(items, against: currentItems)
        // Validate sold values before any customer/catalog write, while allowing
        // unmapped approved items to obtain their identity during preparation.
        let snapshots = CatalogLineItemSnapshot.decoded(from: document.snapshotJSON)
        if snapshots.contains(where: { $0.bundle != nil }) {
            guard let companyID = run.workflow.companyID, let realmID = run.workflow.realmID else {
                throw CatalogBundleError.originalBusiness
            }
            try CatalogBundlePolicy.validateScope(document.snapshotJSON,
                expected: .init(companyID: companyID, realmID: realmID, environment: run.workflow.environment))
        }
        guard !snapshots.isEmpty else { throw QuickBooksBillingWorkflowError.changed }
        var allSnapshots = snapshots
        for snapshot in snapshots where snapshot.bundle != nil { allSnapshots.append(contentsOf: snapshot.soldLeaves) }
        for snapshot in allSnapshots {
            let count = items.filter { $0.id == snapshot.catalogItemID }.count
            guard count == 1, snapshot.quantity.isFinite, snapshot.quantity > 0,
                  snapshot.unitPrice.isFinite, snapshot.unitPrice >= 0 else { throw QuickBooksBillingWorkflowError.changed }
        }
        if api.billingPublicationClient == nil, !completed, case .invoice(let invoice) = document,
           invoice.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
           let reason = BillingInvoiceMutationPolicy.blockedMessage(for: invoice,
                payments: try context.fetch(FetchDescriptor<Payment>()).filter { $0.invoice != nil }) {
            throw QuickBooksInvoicePublicationRecoveryError.protectedHistory(reason)
        }
    }

    func execute(configuration: BackendQuickBooksAccountingConfiguration? = nil) async throws -> Outcome {
        guard !started else { throw QuickBooksBillingWorkflowError.busy }
        started = true
        return try await run.perform {
            try self.check()
            if let client = self.api.billingPublicationClient {
                let journal = try self.makeSharedPublication(client)
                self.sharedPublication = journal
                if self.customerID?.isEmpty == false,
                   let original = try await self.originalMilestone(), original.localDocumentID != self.document.id {
                    throw BillingNativeError.milestoneOriginal(original.localDocumentID)
                }
                let revision = try self.billingDraftRevision()
                if let pending = journal.journal.pending,
                   !pending.settled || pending.draftRevision == revision {
                    let response = try await journal.recover(revision: revision)
                    return try self.applySharedConfirmation(invoice: response.invoice, estimate: response.estimate, recovered: true)
                }
                if let original = try await journal.original(customerID: self.customer.id) {
                    if journal.journal.pending == nil, original.proposal.draftRevision == revision {
                        try journal.adoptOriginal(original, revision: revision)
                        if [.sending, .unknown, .confirmed].contains(original.publication.state) {
                            let result = try await journal.recover(revision: revision)
                            return try self.applySharedConfirmation(invoice: result.invoice, estimate: result.estimate, recovered: true)
                        }
                    }
                    if [.reserved, .sending, .unknown].contains(original.publication.state) { throw BillingNativeError.pending }
                    let localProviderID: String?
                    switch self.document {
                    case .invoice(let value): localProviderID = value.quickBooksID
                    case .estimate(let value): localProviderID = value.quickBooksID
                    }
                    if original.proposal.draftRevision != nil, localProviderID?.isEmpty != false {
                        throw BillingNativeError.originalDraft
                    }
                }
            }
            // Check before any prerequisite customer/catalog write. Taxable
            // drafts remain offline-editable, but incomplete tax context cannot
            // be published using a guessed or inherited customer address.
            _ = try BillingTaxAddressContext.forPublication(self.document)
            try await self.prepareCustomer()
            for item in self.items {
                try self.check()
                guard item.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else { continue }
                try self.validateCatalogAccess()
                let owner = QuickBooksSyncLifecycle()
                let child = try QuickBooksCatalogWorkflow(item: item, context: self.context, api: self.api,
                    lifecycle: owner, mode: .publish, configuration: configuration,
                    validateAccess: { try self.check(); try self.validateCatalogAccess() }, save: self.save)
                defer { owner.finish(child.run) }
                do {
                    let result = try await child.execute()
                    self.attemptedWrite = self.attemptedWrite || child.attemptedWrite
                    guard let revision = child.committedRevision else { throw QuickBooksBillingWorkflowError.changed }
                    self.itemRevisions[ObjectIdentifier(item)] = revision
                    try self.check()
                    if result.remote.Active == false { throw PricebookPublicationError.inactiveQuickBooksMatch(item.name) }
                } catch {
                    self.attemptedWrite = self.attemptedWrite || child.attemptedWrite
                    throw error
                }
            }
            try self.check()
            if let shared = self.sharedPublication { return try await self.publishSharedDocument(shared) }
            return try await self.publishDocument() // Isolated legacy fixtures only.
        }
    }

    private func makeSharedPublication(_ client: BillingPublicationClient) throws -> BillingNativePublication {
        guard let companyID = run.workflow.companyID, let realmID = run.workflow.realmID else { throw BillingPublicationError.accessRequired }
        let actor = AppAccess.normalizedEmail(actorEmail)
        let scope = BillingNativeJournalScope(document: .init(companyID: companyID, realmID: realmID,
            environment: run.workflow.environment, documentType: document.label == "Invoice" ? .invoice : .estimate,
            localDocumentID: document.id), actorEmail: actor.isEmpty && GunnAireCloudKit.usesTestDatabase ? "fixture@example.invalid" : actor)
        return try .init(scope: scope, client: client, workflow: run.workflow, store: billingJournal) { [weak self] in
            guard let self else { throw CancellationError() }
            try self.check()
        }
    }

    func openSharedReview() throws -> BillingNativePublication {
        try check()
        if let sharedPublication { return sharedPublication }
        guard let client = api.billingPublicationClient else { throw BillingPublicationError.unavailable }
        let value = try makeSharedPublication(client)
        sharedPublication = value
        return value
    }

    /// Read-only cross-device handoff once the customer has a shared link. It never
    /// relabels this draft or substitutes another invoice's frozen allocation.
    func originalMilestone() async throws -> BillingMilestoneOriginal? {
        guard let milestoneID = document.projectMilestoneID else { return nil }
        let shared = try openSharedReview()
        let evidence = try await shared.client.context(shared.scope.document, customerID: customer.id,
            jobID: document.serviceCallID, milestoneID: milestoneID, workflow: run.workflow)
        try check()
        return evidence.milestone
    }

    var canApproveSharedDraft: Bool {
        guard let email = actorEmail, let users = try? context.fetch(FetchDescriptor<AppUser>()),
              let role = users.first(where: { AppAccess.normalizedEmail($0.email) == AppAccess.normalizedEmail(email) && $0.isActive })?.role else { return false }
        switch document {
        case .invoice: return role == .admin || role == .accounting
        case .estimate: return role == .admin || role == .dispatcher
        }
    }

    /// A local bookkeeping decision, not an accounting write. The current
    /// server scope must confirm office authority and the already-issued owner.
    func retainDuplicateMilestoneDraft() async throws {
        guard case .invoice(let draft) = document, let milestoneID = draft.projectMilestoneID,
              canApproveSharedDraft else { throw BillingMilestoneReconciliationError.accessRequired }
        let shared = try openSharedReview()
        guard shared.journal.pending == nil else { throw BillingMilestoneReconciliationError.reviewRequired }
        let scope = shared.scope.document
        let evidence = try await shared.client.context(scope, customerID: customer.id,
            jobID: draft.serviceCallID, milestoneID: milestoneID, workflow: run.workflow)
        try check()
        guard evidence.authority == "office", evidence.providerID == nil,
              let owner = evidence.milestone, owner.state == .confirmed,
              owner.localDocumentID != draft.id,
              let original = try owner.localInvoice(in: context, for: document) else {
            throw BillingMilestoneReconciliationError.originalRequired
        }
        let unchangedOriginal = QuickBooksBillingDocument.invoice(original).validation(context: context)
        try unchangedOriginal()
        let originalScope = BillingDocumentScope(companyID: scope.companyID, realmID: scope.realmID,
            environment: scope.environment, documentType: .invoice, localDocumentID: owner.localDocumentID)
        let publication = try await shared.client.original(owner.publicationID, scope: originalScope,
            customerID: customer.id, workflow: run.workflow)
        try check(); try unchangedOriginal()
        guard try await shared.original(customerID: customer.id) == nil else {
            throw BillingMilestoneReconciliationError.reviewRequired
        }
        try check(); try unchangedOriginal()
        // Revalidate authority and durable ownership after all awaited reads.
        let latest = try await shared.client.context(scope, customerID: customer.id,
            jobID: draft.serviceCallID, milestoneID: milestoneID, workflow: run.workflow)
        try check(); try unchangedOriginal()
        guard latest.authority == "office", latest.providerID == nil, latest.milestone == owner,
              canApproveSharedDraft, let email = actorEmail else {
            throw BillingMilestoneReconciliationError.accessRequired
        }
        let users = try context.fetch(FetchDescriptor<AppUser>()).filter {
            AppAccess.normalizedEmail($0.email) == AppAccess.normalizedEmail(email) && $0.isActive
        }
        guard users.count == 1, let reviewer = users.first else { throw BillingMilestoneReconciliationError.accessRequired }
        try BillingMilestoneReconciliation.save(draft: draft, original: original, evidence: owner,
            publication: publication, scope: scope, reviewer: reviewer, context: context,
            check: { try self.check(); try unchangedOriginal() }, persist: { try self.save(self.context) })
    }

    func resumeOriginalFromReview() async throws -> Outcome {
        let shared = try openSharedReview()
        guard let pending = shared.journal.pending, pending.draftRevision == (try billingDraftRevision()) else { throw BillingNativeError.originalDraft }
        try check()
        if case .invoice(let invoice) = document,
           let reason = BillingInvoiceMutationPolicy.blockedMessage(for: invoice,
               payments: try context.fetch(FetchDescriptor<Payment>()).filter { $0.invoice != nil },
               allowingInitialMilestonePublication: pending.request.operation == .create) {
            throw QuickBooksInvoicePublicationRecoveryError.protectedHistory(reason)
        }
        attemptedWrite = true
        let result = try await shared.submitOriginal()
        return try applySharedConfirmation(invoice: result.invoice, estimate: result.estimate, recovered: false)
    }

    func recoverOriginalFromReview() async throws -> Outcome {
        let shared = try openSharedReview()
        let result = try await shared.recover(revision: billingDraftRevision())
        return try applySharedConfirmation(invoice: result.invoice, estimate: result.estimate, recovered: true)
    }

    /// Durable draft identity excludes fields owned by synchronization (tax,
    /// sync messages and balance), but includes the sold snapshot, customer,
    /// location, dates, approvals, signatures and payment history.
    func billingDraftRevision() throws -> String {
        var values: [String?] = [document.label, document.id.uuidString, customer.id.uuidString,
            document.serviceCallID?.uuidString, document.snapshotJSON]
        func date(_ value: Date?) -> String? { value.map { String($0.timeIntervalSince1970) } }
        switch document {
        case .invoice(let value):
            values += [value.serviceLocationID?.uuidString, value.siteAddress, value.notes, value.workTypeRaw, value.status,
                date(value.createdAt), QuickBooksDateOnly.string(from: value.effectiveDueDate()),
                value.customerSignatureName, value.customerSignatureImageBase64, date(value.customerSignedAt),
                date(value.finalizedAt), value.completionNotes, value.projectMilestoneID?.uuidString,
                value.projectMilestoneTitle, value.projectContractAmount.map(String.init(describing:)),
                value.projectBillingPercent.map(String.init(describing:))]
        case .estimate(let value):
            values += [value.serviceLocationID?.uuidString, value.siteAddress, value.notes, date(value.createdAt), value.status,
                value.scheduledServiceCallID?.uuidString, value.parentEstimateID?.uuidString,
                value.proposalGroupID?.uuidString, value.changeOrderReason, value.proposalOption,
                value.customerApprovedByName, value.customerApprovalMethodRaw, value.customerApprovalReference,
                value.customerApprovalRecordedByEmail, value.customerApprovalSignatureImageBase64, date(value.customerApprovedAt)]
        }
        let payments = try context.fetch(FetchDescriptor<Payment>()).filter { $0.invoice?.id == document.id }.sorted { $0.id.uuidString < $1.id.uuidString }
        for payment in payments {
            values += [payment.id.uuidString, String(payment.amount), String(payment.isRefund), payment.providerPaymentStatus,
                       payment.quickBooksID, payment.quickBooksChargeID]
        }
        return SHA256.hash(data: try JSONEncoder().encode(values)).map { String(format: "%02x", $0) }.joined()
    }

    private func publishSharedDocument(_ shared: BillingNativePublication) async throws -> Outcome {
        let scope = shared.scope.document
        let evidence = try await shared.client.context(scope, customerID: customer.id, jobID: document.serviceCallID,
            milestoneID: document.projectMilestoneID, workflow: run.workflow)
        try check()
        if let original = evidence.milestone, original.localDocumentID != document.id {
            throw BillingNativeError.milestoneOriginal(original.localDocumentID)
        }
        guard evidence.customerProviderID == customerID else { throw BillingNativeError.mapping }
        let catalog = try context.fetch(FetchDescriptor<Item>())
        let tax = try BillingTaxAddressContext.forPublication(document)
        let proposal: BillingPublicationProposal
        let operation: BillingPublicationOperation
        switch document {
        case .invoice(let invoice):
            let inputs = try QuickBooksInvoicePublicationRecovery.publicationInputs(for: invoice, catalogItems: catalog,
                payments: context.fetch(FetchDescriptor<Payment>()).filter { $0.invoice != nil })
            let localID = invoice.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let localID, !localID.isEmpty, localID != evidence.providerID { throw BillingNativeError.mapping }
            if (localID?.isEmpty ?? true), let existing = evidence.invoice {
                guard QuickBooksBillingLineEvidence.matches(expected: inputs.lines, reported: existing.Line) else { throw QuickBooksBillingWorkflowError.remoteLines }
                return try applySharedConfirmation(invoice: existing, estimate: nil, recovered: true)
            }
            if let reason = BillingInvoiceMutationPolicy.blockedMessage(for: invoice,
                payments: try context.fetch(FetchDescriptor<Payment>()).filter { $0.invoice != nil },
                allowingInitialMilestonePublication: evidence.providerID == nil) {
                throw QuickBooksInvoicePublicationRecoveryError.protectedHistory(reason)
            }
            operation = evidence.providerID == nil ? .create : .update
            if let existing = evidence.invoice {
                guard let balance = existing.Balance, abs(balance - existing.TotalAmt) <= 0.009 else { throw QuickBooksBillingWorkflowError.paidRemoteInvoice }
            }
            proposal = .init(CustomerRef: inputs.customerRef, Line: inputs.lines,
                TxnDate: evidence.invoice?.TxnDate ?? QuickBooksDateOnly.string(from: invoice.createdAt),
                DueDate: QuickBooksDateOnly.string(from: invoice.effectiveDueDate()),
                PrivateNote: BillingPublicationProposal.userNote(inputs.privateNote), BillEmail: inputs.billEmail,
                ShipAddr: tax?.service, ShipFromAddr: tax?.origin, ApplyTaxAfterDiscount: invoice.documentDiscount == nil ? nil : true,
                Id: evidence.providerID, SyncToken: evidence.invoice?.SyncToken, sparse: operation == .update ? true : nil)
        case .estimate(let estimate):
            let inputs = try QuickBooksEstimatePublicationRecovery.publicationInputs(for: estimate, catalogItems: catalog)
            let localID = estimate.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let localID, !localID.isEmpty, localID != evidence.providerID { throw BillingNativeError.mapping }
            if let existing = evidence.estimate {
                guard QuickBooksBillingLineEvidence.matches(expected: inputs.lines, reported: existing.Line) else { throw QuickBooksBillingWorkflowError.remoteLines }
                return try applySharedConfirmation(invoice: nil, estimate: existing, recovered: true)
            }
            operation = .create
            proposal = .init(CustomerRef: inputs.customerRef, Line: inputs.lines, TxnDate: QuickBooksDateOnly.string(from: estimate.createdAt),
                PrivateNote: BillingPublicationProposal.userNote(inputs.privateNote), BillEmail: inputs.billEmail,
                ShipAddr: tax?.service, ShipFromAddr: tax?.origin, ApplyTaxAfterDiscount: estimate.documentDiscount == nil ? nil : true)
        }
        let request = BillingPublicationRequest(companyID: scope.companyID, realmID: scope.realmID, environment: scope.environment,
            documentType: scope.documentType, localDocumentID: document.id, localCustomerID: customer.id, operation: operation,
            document: proposal, connectionRevision: evidence.connectionRevision, serviceCallID: document.serviceCallID,
            assignmentRevision: evidence.authority == "assigned" ? evidence.assignment?.revision : nil,
            draftRevision: try billingDraftRevision(), projectMilestoneID: document.projectMilestoneID)
        try shared.prepare(request, revision: billingDraftRevision())
        attemptedWrite = true
        let result = try await shared.submitOriginal()
        return try applySharedConfirmation(invoice: result.invoice, estimate: result.estimate, recovered: false)
    }

    private func applySharedConfirmation(invoice remoteInvoice: QuickBooksInvoice?, estimate remoteEstimate: QuickBooksEstimate?, recovered: Bool) throws -> Outcome {
        try check()
        let restore = document.syncRestoration()
        let outcome: Outcome
        switch document {
        case .invoice(let value):
            guard let remote = remoteInvoice, remoteEstimate == nil else { throw BillingPublicationError.invalidResponse }
            try validateRemote(id: remote.Id, customerID: remote.CustomerRef.value, expectedID: value.quickBooksID)
            value.quickBooksID = remote.Id
            let taxIssue = value.applyQuickBooksTaxResult(total: remote.TotalAmt, reportedTax: remote.TxnTaxDetail?.TotalTax)
            value.quickBooksSyncStatus = taxIssue == nil ? "synced" : "needs_attention"; value.quickBooksSyncDetail = taxIssue
            let balance = QuickBooksBalanceReconciliation.apply(remote, to: value)
            outcome = .init(message: taxIssue != nil || !balance ? "Invoice linked. Review its tax or balance before collecting payment."
                : recovered ? "Original QuickBooks invoice recovered without another publication." : "Invoice saved and synced to QuickBooks.", recovered: recovered, invoice: remote)
        case .estimate(let value):
            guard let remote = remoteEstimate, remoteInvoice == nil else { throw BillingPublicationError.invalidResponse }
            try validateRemote(id: remote.Id, customerID: remote.CustomerRef.value, expectedID: value.quickBooksID)
            value.quickBooksID = remote.Id
            let issue = value.applyQuickBooksTaxResult(total: remote.TotalAmt, reportedTax: remote.TxnTaxDetail?.TotalTax)
            outcome = .init(message: issue != nil ? "Estimate linked. Review its tax total."
                : recovered ? "Original QuickBooks estimate recovered without another publication." : "Estimate saved and synced to QuickBooks.", recovered: recovered, estimate: remote)
        }
        do { try saveDocumentConfirmation(recovered: recovered) } catch { restore(); throw error }
        validateDocument = document.validation(context: context)
        completed = true
        if sharedPublication?.journal.pending?.publicationID != nil { try sharedPublication?.settle(revision: billingDraftRevision()) }
        return outcome
    }

    private func prepareCustomer() async throws {
        guard customerID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
            try validateCustomerAssignment(customerID!)
            return
        }
        let remote: QuickBooksCustomer
        if api.customerPublicationTransport != nil {
            attemptedWrite = true
            remote = try await run.receive { api.recoverOrCreateCustomer(customerDraft, completion: $0) }
        } else {
            // Isolated legacy transport fixtures only. Production always has
            // the server publisher and never trusts a device-only match.
            let remotes = try await run.receive(api.fetchCustomers)
            try check()
            if let existing = try QuickBooksCustomerCreateOperation.matchingRemoteCustomer(for: customerDraft, in: remotes) {
                remote = existing
            } else {
                attemptedWrite = true
                remote = try await run.receive { api.recoverOrCreateCustomer(customerDraft, remoteCustomers: remotes, completion: $0) }
            }
        }
        try check()
        guard try QuickBooksCustomerCreateOperation.matchingRemoteCustomer(for: customerDraft, in: [remote]) != nil else {
            throw QuickBooksBillingWorkflowError.customerConflict
        }
        try validateCustomerAssignment(remote.Id)
        let old = customerID
        customer.quickBooksID = remote.Id
        do { try save(context) }
        catch { customer.quickBooksID = old; throw QuickBooksBillingWorkflowError.saveFailed }
        customerID = remote.Id
    }

    private func validateCustomerAssignment(_ identifier: String) throws {
        let identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty,
              try !context.fetch(FetchDescriptor<Customer>()).contains(where: {
                  $0 !== customer && $0.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines) == identifier
              }) else { throw QuickBooksBillingWorkflowError.customerConflict }
    }

    private func publishDocument() async throws -> Outcome {
        let catalog = try context.fetch(FetchDescriptor<Item>())
        let taxAddresses = try BillingTaxAddressContext.forPublication(document)
        switch document {
        case .invoice(let invoice):
            let inputs = try QuickBooksInvoicePublicationRecovery.publicationInputs(for: invoice, catalogItems: catalog,
                payments: context.fetch(FetchDescriptor<Payment>()).filter { $0.invoice != nil })
            let payload = QuickBooksInvoiceCreate(CustomerRef: inputs.customerRef, Line: inputs.lines,
                PrivateNote: inputs.privateNote, BillEmail: inputs.billEmail,
                ShipAddr: taxAddresses?.service.quickBooksAddress ?? inputs.shipAddress,
                ShipFromAddr: taxAddresses?.origin.quickBooksAddress,
                DueDate: QuickBooksDateOnly.string(from: invoice.effectiveDueDate()), GlobalTaxCalculation: "TaxExcluded",
                ApplyTaxAfterDiscount: invoice.documentDiscount == nil ? nil : true)
            let remote: QuickBooksInvoice
            var recovered = false
            if let identifier = invoice.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines), !identifier.isEmpty {
                let current: QuickBooksInvoice = try await run.receive { api.fetchInvoice(id: identifier, completion: $0) }
                try check()
                try validateRemote(id: current.Id, customerID: current.CustomerRef.value, expectedID: identifier)
                guard let balance = current.Balance, balance.isFinite, balance >= 0,
                      abs(balance - current.TotalAmt) <= 0.009 else { throw QuickBooksBillingWorkflowError.paidRemoteInvoice }
                guard let token = current.SyncToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
                    throw QuickBooksDataAPI.QBError.missingSyncToken(entity: "invoice")
                }
                attemptedWrite = true
                remote = try await run.receive { api.updateInvoice(.init(Id: identifier, SyncToken: token,
                    CustomerRef: payload.CustomerRef, Line: payload.Line, PrivateNote: payload.PrivateNote,
                    BillEmail: payload.BillEmail, ShipAddr: payload.ShipAddr, ShipFromAddr: payload.ShipFromAddr, DueDate: payload.DueDate,
                    GlobalTaxCalculation: payload.GlobalTaxCalculation, ApplyTaxAfterDiscount: payload.ApplyTaxAfterDiscount), completion: $0) }
            } else {
                let remotes = try await run.receive(api.fetchInvoices)
                try check()
                if let existing = try QuickBooksInvoicePublicationRecovery.matchingRemoteInvoice(for: invoice, in: remotes) {
                    remote = existing; recovered = true
                } else {
                    attemptedWrite = true
                    remote = try await run.receive {
                        api.createInvoice(payload, requestID: QuickBooksInvoiceLineage.createRequestID(for: invoice), completion: $0)
                    }
                }
            }
            try check()
            try validateRemote(id: remote.Id, customerID: remote.CustomerRef.value, expectedID: invoice.quickBooksID)
            guard QuickBooksBillingLineEvidence.matches(expected: inputs.lines, reported: remote.Line) else {
                throw QuickBooksBillingWorkflowError.remoteLines
            }
            if invoice.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
               !QuickBooksInvoiceLineage.matches(invoice, remoteInvoice: remote) {
                throw QuickBooksBillingWorkflowError.remoteIdentity
            }
            let restore = document.syncRestoration()
            invoice.quickBooksID = remote.Id
            let taxIssue = invoice.applyQuickBooksTaxResult(total: remote.TotalAmt, reportedTax: remote.TxnTaxDetail?.TotalTax)
            invoice.quickBooksSyncStatus = taxIssue == nil ? "synced" : "needs_attention"
            invoice.quickBooksSyncDetail = taxIssue
            let validBalance = QuickBooksBalanceReconciliation.apply(remote, to: invoice)
            do { try saveDocumentConfirmation(recovered: recovered) } catch { restore(); throw error }
            validateDocument = document.validation(context: context)
            completed = true
            return Outcome(message: taxIssue != nil || !validBalance
                ? "Invoice linked to QuickBooks. Review its tax or balance before collecting payment."
                : (recovered ? "Existing QuickBooks invoice recovered without creating a duplicate." : "Invoice saved and synced to QuickBooks."),
                recovered: recovered, invoice: remote)
        case .estimate(let estimate):
            let inputs = try QuickBooksEstimatePublicationRecovery.publicationInputs(for: estimate, catalogItems: catalog)
            let remotes = try await run.receive(api.fetchEstimates)
            try check()
            let remote: QuickBooksEstimate
            let recovered: Bool
            if let existing = try QuickBooksEstimatePublicationRecovery.matchingRemoteEstimate(for: estimate, in: remotes) {
                remote = existing; recovered = true
            } else {
                guard estimate.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
                    throw QuickBooksBillingWorkflowError.remoteIdentity
                }
                attemptedWrite = true; recovered = false
                remote = try await run.receive { api.createEstimate(.init(CustomerRef: inputs.customerRef, Line: inputs.lines,
                    PrivateNote: inputs.privateNote, BillEmail: inputs.billEmail,
                    ShipAddr: taxAddresses?.service.quickBooksAddress ?? inputs.shipAddress,
                    ShipFromAddr: taxAddresses?.origin.quickBooksAddress,
                    GlobalTaxCalculation: "TaxExcluded", ApplyTaxAfterDiscount: estimate.documentDiscount == nil ? nil : true),
                    requestID: QuickBooksEstimateLineage.createRequestID(for: estimate), completion: $0) }
            }
            try check()
            try validateRemote(id: remote.Id, customerID: remote.CustomerRef.value, expectedID: estimate.quickBooksID)
            guard QuickBooksBillingLineEvidence.matches(expected: inputs.lines, reported: remote.Line) else {
                throw QuickBooksBillingWorkflowError.remoteLines
            }
            guard QuickBooksEstimateLineage.localEstimateID(from: remote.PrivateNote) == estimate.id else {
                throw QuickBooksBillingWorkflowError.remoteIdentity
            }
            guard remote.TotalAmt.isFinite, remote.TotalAmt >= 0 else { throw QuickBooksBillingWorkflowError.remoteIdentity }
            let restore = document.syncRestoration()
            estimate.quickBooksID = remote.Id
            let taxIssue = estimate.applyQuickBooksTaxResult(total: remote.TotalAmt, reportedTax: remote.TxnTaxDetail?.TotalTax)
            do { try saveDocumentConfirmation(recovered: recovered) } catch { restore(); throw error }
            validateDocument = document.validation(context: context)
            completed = true
            return Outcome(message: taxIssue != nil ? "Estimate linked to QuickBooks. Review its tax total."
                : (recovered ? "Existing QuickBooks estimate recovered without creating a duplicate." : "Estimate saved and synced to QuickBooks."),
                recovered: recovered, estimate: remote)
        }
    }

    private func saveDocumentConfirmation(recovered: Bool) throws {
        let calls = try context.fetch(FetchDescriptor<ServiceCall>()).filter {
            $0.id == document.serviceCallID && $0.customer === customer
        }
        let activity = calls.count == 1 ? ServiceCallActivity.record(for: calls[0],
            action: "QuickBooks \(document.label.lowercased()) \(recovered ? "link recovered" : "published")",
            detail: "The original customer, document lines and QuickBooks identity were confirmed.",
            actorEmail: actorEmail, in: context) : nil
        do { try save(context) }
        catch {
            if let activity { context.delete(activity) }
            throw QuickBooksBillingWorkflowError.saveFailed
        }
    }

    private func validateRemote(id: String, customerID: String, expectedID: String?) throws {
        let expected = expectedID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              customerID == self.customerID?.trimmingCharacters(in: .whitespacesAndNewlines),
              expected?.isEmpty != false || id == expected else { throw QuickBooksBillingWorkflowError.remoteIdentity }
        switch document {
        case .invoice(let value):
            guard try !context.fetch(FetchDescriptor<Invoice>()).contains(where: {
                $0 !== value && $0.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines) == id
            }) else { throw QuickBooksBillingWorkflowError.remoteIdentity }
        case .estimate(let value):
            guard try !context.fetch(FetchDescriptor<Estimate>()).contains(where: {
                $0 !== value && $0.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines) == id
            }) else { throw QuickBooksBillingWorkflowError.remoteIdentity }
        }
    }


    /// File follow-up is optional to financial publication, but never detached
    /// from its original account, document, actor, file contents or local save.
    func uploadLinkedAttachments() async throws {
        guard completed else { throw QuickBooksBillingWorkflowError.changed }
        try await run.perform {
            try self.check()
            let invoiceList: [Invoice]
            let estimateList: [Estimate]
            switch self.document {
            case .invoice(let value): invoiceList = [value]; estimateList = []
            case .estimate(let value): invoiceList = []; estimateList = [value]
            }
            let candidates = try self.context.fetch(FetchDescriptor<ServiceDocumentAttachment>()).map { ($0.id, $0) }
            for (identifier, attachment) in candidates {
                let current = try self.context.fetch(FetchDescriptor<ServiceDocumentAttachment>()).filter { $0.id == identifier }
                guard current.count == 1, current.first === attachment else { throw QuickBooksBillingWorkflowError.changed }
                let references = QuickBooksInvoiceAttachmentSync.missingQuickBooksAttachableReferences(
                    for: attachment, estimates: estimateList, invoices: invoiceList)
                guard !references.isEmpty else { continue }
                let customer = attachment.customer
                let invoiceID = attachment.invoiceID, estimateID = attachment.estimateID
                let path = attachment.localFilePath, caption = attachment.caption, kind = attachment.kindRaw
                let oldID = attachment.quickBooksAttachableID, oldKeys = attachment.quickBooksAttachedEntityKeysRaw
                let oldError = attachment.quickBooksSyncError
                let bytes = try QBODocumentNativeWorkflow.fileData(attachment.localFileURL)
                let validate = {
                    try self.check()
                    let matches = try self.context.fetch(FetchDescriptor<ServiceDocumentAttachment>()).filter { $0.id == identifier }
                    guard matches.count == 1, matches.first === attachment, attachment.customer === customer,
                          attachment.invoiceID == invoiceID, attachment.estimateID == estimateID,
                          attachment.localFilePath == path, attachment.caption == caption, attachment.kindRaw == kind,
                          attachment.quickBooksAttachableID == oldID, attachment.quickBooksAttachedEntityKeysRaw == oldKeys,
                          attachment.quickBooksSyncError == oldError,
                          try QBODocumentNativeWorkflow.fileData(attachment.localFileURL) == bytes else {
                        throw QuickBooksBillingWorkflowError.changed
                    }
                }
                do {
                    _ = try await QBODocumentNativeWorkflow.upload(attachment, references: references, context: self.context,
                        api: self.api, validate: validate, dependencies: self.documentUploads, save: self.save)
                } catch {
                    // Do not label a replacement/edited file with an old result.
                    try validate()
                    attachment.quickBooksSyncError = QBODocumentNativeWorkflow.message(error)
                    do { try self.save(self.context) }
                    catch { attachment.quickBooksSyncError = oldError; throw QuickBooksBillingWorkflowError.saveFailed }
                    throw error
                }
            }
        }
    }

    func failureMessage(_ error: Error) -> String {
        document.label + (attemptedWrite
            ? " is saved locally. QuickBooks may have accepted a request; review the original records before retrying. "
            : " is saved locally. QuickBooks sync stopped. ") + error.localizedDescription
    }

    func recordFailure(_ error: Error) throws {
        try check()
        guard !completed else { return }
        guard case .invoice(let invoice) = document else { return }
        let restore = document.syncRestoration()
        invoice.quickBooksSyncStatus = "needs_attention"
        invoice.quickBooksSyncDetail = failureMessage(error)
        do { try save(context) } catch { restore(); throw QuickBooksBillingWorkflowError.saveFailed }
        validateDocument = document.validation(context: context)
    }
}
