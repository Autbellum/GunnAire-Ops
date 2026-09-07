import Foundation
import SwiftData

enum QuickBooksCatalogWorkflowError: LocalizedError, Equatable {
    case busy, itemChanged, reviewChanged, invalidItem, remoteIdentity, invalidResponse, saveFailed

    var errorDescription: String? {
        switch self {
        case .busy: "Finish the current catalog action before starting another."
        case .itemChanged: "This item or its approval changed. Review the saved item before publishing again."
        case .reviewChanged: "QuickBooks changed since this comparison was shown. Refresh and review the new differences. No update was sent."
        case .invalidItem: "Review the item's name, type, price, cost and approval before publishing."
        case .remoteIdentity: "QuickBooks returned a different or conflicting item identity. Review the catalog before retrying."
        case .invalidResponse: "QuickBooks returned incomplete catalog values. The saved item has been retained for review."
        case .saveFailed: "The local confirmation could not be saved. Check QuickBooks before retrying; do not create another item."
        }
    }
}

/// Exact reviewed values, not the pricebook's approximate display comparison.
/// Also restores only the fields this workflow can mutate on a failed save.
struct QuickBooksCatalogItemRevision: Equatable {
    let id: UUID
    let quickBooksID: String?
    let values: QuickBooksItemCreate
    let rawType: String
    let purchaseDescription: String?
    let vendorID: String?
    let vendorName: String?
    let reviewStatus: String?
    let reviewer: String?
    let reviewedAt: Date?
    let syncStatus: String
    let syncDetail: String?
    let syncedAt: Date?
    let timestamp: Date

    init(_ item: Item) {
        id = item.id
        quickBooksID = item.quickBooksID
        values = QuickBooksCatalogCreateOperation.payload(for: item,
            incomeAccountRef: .init(value: "revision-only", name: nil), expenseAccountRef: nil)
        rawType = item.itemTypeRawValue
        purchaseDescription = item.purchaseDescription
        vendorID = item.preferredVendorQuickBooksID
        vendorName = item.preferredVendorName
        reviewStatus = item.pricebookReviewStatusRawValue
        reviewer = item.pricebookReviewedByEmail
        reviewedAt = item.pricebookReviewedAt
        syncStatus = item.quickBooksSyncStatus
        syncDetail = item.quickBooksSyncDetail
        syncedAt = item.quickBooksLastSyncedAt
        timestamp = item.timestamp
    }

    func restore(_ item: Item) {
        item.quickBooksID = quickBooksID
        item.name = values.Name
        item.itemTypeRawValue = rawType
        item.itemDescription = values.Description
        item.sku = values.Sku
        item.unitPrice = values.UnitPrice ?? 0
        item.purchaseCost = values.PurchaseCost
        item.isTaxable = values.Taxable ?? false
        item.purchaseDescription = purchaseDescription
        item.preferredVendorQuickBooksID = vendorID
        item.preferredVendorName = vendorName
        item.pricebookReviewStatusRawValue = reviewStatus
        item.pricebookReviewedByEmail = reviewer
        item.pricebookReviewedAt = reviewedAt
        item.quickBooksSyncStatus = syncStatus
        item.quickBooksSyncDetail = syncDetail
        item.quickBooksLastSyncedAt = syncedAt
        item.timestamp = timestamp
    }
}

/// The same service backs approval, retry, comparison and both reconciliation
/// directions. Captured before Task scheduling; all network callbacks, model
/// identity checks and local saves belong to the original run and context.
@MainActor
final class QuickBooksCatalogWorkflow {
    enum Mode { case publish, compare, update(QuickBooksItem), useProvider(QuickBooksItem) }
    struct Outcome {
        let remote: QuickBooksItem
        let link: ApprovedPricebookLinkOutcome
        let created: Bool
    }

    let run: QuickBooksSyncRun
    private let lifecycle: QuickBooksSyncLifecycle
    private let api: QuickBooksDataAPI
    private let context: ModelContext
    private let item: Item
    private let revision: QuickBooksCatalogItemRevision
    private let mode: Mode
    private let configuration: BackendQuickBooksAccountingConfiguration?
    private let save: (ModelContext) throws -> Void
    private(set) var attemptedWrite = false
    private var started = false

    init(item: Item, context: ModelContext, api: QuickBooksDataAPI,
         lifecycle: QuickBooksSyncLifecycle, mode: Mode,
         configuration: BackendQuickBooksAccountingConfiguration? = nil,
         validateAccess: (() throws -> Void)? = nil,
         save: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws {
        guard lifecycle.activeID == nil else { throw QuickBooksCatalogWorkflowError.busy }
        let validate = validateAccess ?? { try QuickBooksSyncAccessPolicy.validate(context: context) }
        try validate()
        self.item = item
        self.lifecycle = lifecycle
        self.context = context
        self.api = api
        self.mode = mode
        self.configuration = configuration
        self.save = save
        revision = QuickBooksCatalogItemRevision(item)
        try Self.validateItemValues(item)
        let matches = try context.fetch(FetchDescriptor<Item>()).filter { $0.id == item.id }
        guard matches.count == 1, matches.first === item else { throw QuickBooksCatalogWorkflowError.itemChanged }
        if case .publish = mode {
            guard item.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
                  !item.isCatalogArchived else { throw QuickBooksCatalogWorkflowError.invalidItem }
        } else {
            guard item.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw QuickBooksCatalogWorkflowError.remoteIdentity
            }
        }
        run = try lifecycle.begin(api: api, validateAccess: validate)
    }

    private static func validateItemValues(_ item: Item) throws {
        guard !item.requiresPricebookReview,
              CatalogItemType(rawValue: item.itemTypeRawValue) != nil,
              !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              item.name.count <= 100,
              item.unitPrice.isFinite, item.unitPrice >= 0,
              (item.purchaseCost ?? 0).isFinite, (item.purchaseCost ?? 0) >= 0 else {
            throw QuickBooksCatalogWorkflowError.invalidItem
        }
    }

    func checkItem() throws {
        try run.check()
        let matches = try context.fetch(FetchDescriptor<Item>()).filter { $0.id == revision.id }
        guard matches.count == 1, matches.first === item,
              QuickBooksCatalogItemRevision(item) == revision else {
            throw QuickBooksCatalogWorkflowError.itemChanged
        }
    }

    func execute() async throws -> Outcome {
        guard !started else { throw QuickBooksCatalogWorkflowError.busy }
        started = true
        let evidence: (QuickBooksItem, Bool) = try await run.perform {
            try self.checkItem()
            switch self.mode {
            case .publish:
                let remoteItems = try await self.run.receive(self.api.fetchItems)
                try self.checkItem()
                if let existing = try PricebookReviewPublication.matchingRemoteItem(for: self.item, in: remoteItems) {
                    return (existing, false)
                }
                guard let configuration = self.configuration,
                      configuration.matches(realmID: self.run.workflow.realmID,
                                            environment: self.run.workflow.environment),
                      let income = QuickBooksItemAccountResolver.incomeAccountRef(
                        from: remoteItems, configuration: configuration) else {
                    throw QuickBooksDataAPI.QBError.missingDefaultIncomeAccountRef
                }
                let payload = QuickBooksCatalogCreateOperation.payload(for: self.item, incomeAccountRef: income,
                    expenseAccountRef: QuickBooksItemAccountResolver.configuredExpenseAccountRef(configuration: configuration))
                self.attemptedWrite = true
                let created: QuickBooksItem = try await self.run.receive { completion in
                    self.api.createItem(payload, requestID: QuickBooksCatalogCreateOperation.requestID(for: self.revision.id),
                                        completion: completion)
                }
                return (created, true)
            case .compare, .update, .useProvider:
                guard let identifier = self.revision.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !identifier.isEmpty else { throw QuickBooksCatalogWorkflowError.remoteIdentity }
                let current: QuickBooksItem = try await self.run.receive { self.api.fetchItem(id: identifier, completion: $0) }
                try self.checkItem()
                guard current.Id == identifier else { throw QuickBooksCatalogWorkflowError.remoteIdentity }
                switch self.mode {
                case .update(let reviewed), .useProvider(let reviewed):
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = .sortedKeys
                    guard try encoder.encode(current) == encoder.encode(reviewed) else {
                        throw QuickBooksCatalogWorkflowError.reviewChanged
                    }
                default: break
                }
                if case .update = self.mode,
                   !QuickBooksCatalogReconciliation.differences(localItem: self.item, remoteItem: current).isEmpty {
                    let payload = try QuickBooksCatalogReconciliation.updatePayload(localItem: self.item, currentRemoteItem: current)
                    self.attemptedWrite = true
                    let updated: QuickBooksItem = try await self.run.receive { self.api.updateItem(payload, completion: $0) }
                    guard updated.Id == identifier else { throw QuickBooksCatalogWorkflowError.remoteIdentity }
                    return (updated, false)
                }
                return (current, false)
            }
        }
        try checkItem()
        let remote = evidence.0
        if case .publish = mode {
            guard try PricebookReviewPublication.matchingRemoteItem(for: item, in: [remote]) != nil else {
                throw QuickBooksCatalogWorkflowError.remoteIdentity
            }
        }
        guard !remote.Id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              CatalogItemType(rawValue: remote.ItemType ?? "") != nil,
              !remote.Name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (remote.UnitPrice ?? 0).isFinite, (remote.UnitPrice ?? 0) >= 0,
              (remote.PurchaseCost ?? 0).isFinite, (remote.PurchaseCost ?? 0) >= 0 else {
            throw QuickBooksCatalogWorkflowError.invalidResponse
        }
        var link = ApprovedPricebookLinkOutcome.synchronized
        try run.commit {
            try self.checkItem()
            try QuickBooksCatalogMappingIntegrity.validateAssignment(of: remote.Id, to: self.item,
                in: self.context.fetch(FetchDescriptor<Item>()))
            if case .useProvider = self.mode {
                QuickBooksCatalogSnapshotApplication.apply(remote, to: self.item)
            } else {
                // A replay may contain older values. Retain the approved local
                // proposal and stage differences, never silently overwrite it.
                link = PricebookReviewPublication.linkApprovedItem(self.item, to: remote)
            }
            do { try self.save(self.context) }
            catch {
                self.revision.restore(self.item)
                throw QuickBooksCatalogWorkflowError.saveFailed
            }
        }
        return Outcome(remote: remote, link: link, created: evidence.1)
    }

    func failureMessage(_ error: Error) -> String {
        let prefix = attemptedWrite
            ? "QuickBooks may have accepted the request. Review the original item before retrying. "
            : "Catalog action stopped. Saved work has been retained. "
        return prefix + error.localizedDescription
    }

    /// Never stamp an old workspace or a concurrently edited item with a late
    /// failure. Failure is not evidence of a successful sync timestamp.
    func recordFailure(_ error: Error) throws {
        try checkItem()
        item.quickBooksSyncStatus = "needs_attention"
        item.quickBooksSyncDetail = failureMessage(error)
        do { try save(context) }
        catch { revision.restore(item); throw QuickBooksCatalogWorkflowError.saveFailed }
    }
}
