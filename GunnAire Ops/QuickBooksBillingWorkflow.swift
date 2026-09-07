import Foundation
import SwiftData

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
        // QBO adds a computed subtotal row; it is not an additional sold item.
        let rows = reported.filter { $0.DetailType != "SubTotalLineDetail" }
        guard rows.count == expected.count else { return false }
        return zip(expected, rows).allSatisfy { left, right in
            guard left.DetailType == right.DetailType, right.hasExplicitAmount, right.Amount.isFinite,
                  abs(left.Amount - right.Amount) <= 0.009 else { return false }
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
                    \.projectMilestoneTitle, \.taxCalculationStatusRawValue, \.quickBooksSyncDetail]),
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

    init(document: QuickBooksBillingDocument, context: ModelContext, api: QuickBooksDataAPI,
         lifecycle: QuickBooksSyncLifecycle,
         validateAccess: (() throws -> Void)? = nil,
         validateCatalogAccess: (() throws -> Void)? = nil,
         save: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws {
        guard lifecycle.activeID == nil else { throw QuickBooksBillingWorkflowError.busy }
        guard let customer = document.customer else { throw QuickBooksBillingWorkflowError.changed }
        let validate = validateAccess ?? { try QuickBooksBillingAccessPolicy.validate(context: context, document: document) }
        try validate()
        self.document = document; self.context = context; self.api = api; self.lifecycle = lifecycle
        self.customer = customer; self.customerDraft = QuickBooksCustomerCreateOperation.draft(for: customer)
        actorEmail = AppIdentity.currentEmail
        customerID = customer.quickBooksID
        self.save = save
        self.validateCatalogAccess = validateCatalogAccess ?? { try QuickBooksSyncAccessPolicy.validate(context: context) }
        validateDocument = document.validation(context: context)
        try validateDocument()
        let allItems = try context.fetch(FetchDescriptor<Item>())
        let selectedIDs = Set(CatalogLineItemSnapshot.decoded(from: document.snapshotJSON).map(\.catalogItemID))
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
        guard !snapshots.isEmpty, snapshots.allSatisfy({ snapshot in
            items.filter { $0.id == snapshot.catalogItemID }.count == 1 &&
            snapshot.quantity.isFinite && snapshot.quantity > 0 && snapshot.unitPrice.isFinite && snapshot.unitPrice >= 0
        }) else { throw QuickBooksBillingWorkflowError.changed }
        if !completed, case .invoice(let invoice) = document,
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
            return try await self.publishDocument()
        }
    }

    private func prepareCustomer() async throws {
        guard customerID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
            try validateCustomerAssignment(customerID!)
            return
        }
        let remotes = try await run.receive(api.fetchCustomers)
        try check()
        let remote: QuickBooksCustomer
        if let existing = try QuickBooksCustomerCreateOperation.matchingRemoteCustomer(for: customerDraft, in: remotes) {
            remote = existing
        } else {
            attemptedWrite = true
            remote = try await run.receive { api.recoverOrCreateCustomer(customerDraft, remoteCustomers: remotes, completion: $0) }
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
        switch document {
        case .invoice(let invoice):
            let inputs = try QuickBooksInvoicePublicationRecovery.publicationInputs(for: invoice, catalogItems: catalog,
                payments: context.fetch(FetchDescriptor<Payment>()).filter { $0.invoice != nil })
            let payload = QuickBooksInvoiceCreate(CustomerRef: inputs.customerRef, Line: inputs.lines,
                PrivateNote: inputs.privateNote, BillEmail: inputs.billEmail, ShipAddr: inputs.shipAddress,
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
                    BillEmail: payload.BillEmail, ShipAddr: payload.ShipAddr, DueDate: payload.DueDate,
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
                    PrivateNote: inputs.privateNote, BillEmail: inputs.billEmail, ShipAddr: inputs.shipAddress,
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
                let bytes = try Data(contentsOf: attachment.localFileURL)
                let validate = {
                    try self.check()
                    let matches = try self.context.fetch(FetchDescriptor<ServiceDocumentAttachment>()).filter { $0.id == identifier }
                    guard matches.count == 1, matches.first === attachment, attachment.customer === customer,
                          attachment.invoiceID == invoiceID, attachment.estimateID == estimateID,
                          attachment.localFilePath == path, attachment.caption == caption, attachment.kindRaw == kind,
                          attachment.quickBooksAttachableID == oldID, attachment.quickBooksAttachedEntityKeysRaw == oldKeys,
                          attachment.quickBooksSyncError == oldError,
                          try Data(contentsOf: attachment.localFileURL) == bytes else {
                        throw QuickBooksBillingWorkflowError.changed
                    }
                }
                let owner = QuickBooksSyncLifecycle()
                let upload = try owner.begin(api: self.api, validateAccess: validate)
                defer { owner.finish(upload) }
                do {
                    let attachableID: String = try await upload.receive {
                        self.api.uploadDocument(fileURL: attachment.localFileURL, note: caption,
                                                attachableReferences: references, completion: $0)
                    }
                    try validate()
                    attachment.quickBooksAttachableID = attachableID
                    attachment.markQuickBooksAttached(to: references)
                    attachment.quickBooksSyncError = nil
                    do { try self.save(self.context) }
                    catch {
                        attachment.quickBooksAttachableID = oldID
                        attachment.quickBooksAttachedEntityKeysRaw = oldKeys
                        attachment.quickBooksSyncError = oldError
                        throw QuickBooksBillingWorkflowError.saveFailed
                    }
                } catch {
                    // Do not label a replacement/edited file with an old result.
                    try validate()
                    attachment.quickBooksSyncError = "QuickBooks file upload is unconfirmed. Review this file before retrying. " + error.localizedDescription
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
