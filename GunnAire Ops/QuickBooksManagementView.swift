import SwiftUI
import SwiftData

private enum QuickBooksSyncState: String {
    case idle = "Idle"
    case syncing = "Syncing"
    case success = "Synced"
    case warning = "Warning"
    case failed = "Failed"

    var tint: Color {
        switch self {
        case .idle: return .secondary
        case .syncing: return .blue
        case .success: return .green
        case .warning: return .orange
        case .failed: return .red
        }
    }

    var icon: String {
        switch self {
        case .idle: return "circle"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }
}

private struct QuickBooksSyncResourceStatus: Identifiable {
    let id: String
    let name: String
    let lane: String
    let required: Bool
    var state: QuickBooksSyncState
    var detail: String
    var count: Int?
    var updatedAt: Date?
}

struct QuickBooksInvoicePublicationInputs {
    let customerRef: QuickBooksReference
    let lines: [QuickBooksLineItem]
    let billEmail: QuickBooksEmailAddress?
    let privateNote: String?
    let shipAddress: QuickBooksAddress?
}

enum QuickBooksDocumentLinePublicationError: LocalizedError, Equatable {
    case missingCatalogSnapshot
    case missingCatalogItem(String)
    case pricebookReviewRequired(String)
    case missingQuickBooksItemMapping(String)
    case invalidLineAmount(String)
    case amountMismatch(expected: Double, mapped: Double)

    var errorDescription: String? {
        switch self {
        case .missingCatalogSnapshot:
            return "This document has no durable catalog snapshot. Open Job Billing and review its line items before retrying."
        case .missingCatalogItem(let name):
            return "The local catalog item for \(name) is missing. Open Job Billing and replace that line before retrying."
        case .pricebookReviewRequired(let name):
            return "\(name) needs administrator pricebook review before this document can publish to QuickBooks."
        case .missingQuickBooksItemMapping(let name):
            return "\(name) is not linked to a QuickBooks product or service. Review and publish the catalog item first."
        case .invalidLineAmount(let name):
            return "\(name) has an invalid quantity or price. Correct the line in Job Billing before publishing to QuickBooks."
        case .amountMismatch(let expected, let mapped):
            return "The local document subtotal \(expected.formatted(.currency(code: "USD"))) does not match its mapped QuickBooks lines \(mapped.formatted(.currency(code: "USD"))). Review the line items before retrying."
        }
    }
}

/// Builds QuickBooks sales lines only from the immutable document snapshot and
/// the current, administrator-approved one-to-one catalog mapping. Recovery
/// paths use this same gate so an offline retry cannot bypass pricebook review,
/// reuse an ambiguous QBO Item ID, or publish a different total than the local
/// customer document.
enum QuickBooksDocumentLinePublication {
    static func lines(
        snapshotJSON: String?,
        expectedSubtotal: Double,
        catalogItems: [Item]
    ) throws -> [QuickBooksLineItem] {
        let snapshots = CatalogLineItemSnapshot.decoded(from: snapshotJSON)
        guard !snapshots.isEmpty else {
            throw QuickBooksDocumentLinePublicationError.missingCatalogSnapshot
        }

        let itemsByID = Dictionary(catalogItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let documentItems = try snapshots.map { snapshot in
            guard let item = itemsByID[snapshot.catalogItemID] else {
                throw QuickBooksDocumentLinePublicationError.missingCatalogItem(snapshot.name)
            }
            guard !item.requiresPricebookReview else {
                throw QuickBooksDocumentLinePublicationError.pricebookReviewRequired(snapshot.name)
            }
            return item
        }
        try QuickBooksCatalogMappingIntegrity.validateDocumentItems(documentItems, against: catalogItems)

        let lines = try zip(snapshots, documentItems).map { snapshot, item in
            guard snapshot.quantity.isFinite,
                  snapshot.quantity > 0,
                  snapshot.unitPrice.isFinite,
                  snapshot.unitPrice >= 0 else {
                throw QuickBooksDocumentLinePublicationError.invalidLineAmount(snapshot.name)
            }
            guard let quickBooksItemID = item.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !quickBooksItemID.isEmpty else {
                throw QuickBooksDocumentLinePublicationError.missingQuickBooksItemMapping(snapshot.name)
            }
            let extendedAmount = snapshot.unitPrice * snapshot.quantity
            guard extendedAmount.isFinite, extendedAmount >= 0 else {
                throw QuickBooksDocumentLinePublicationError.invalidLineAmount(snapshot.name)
            }
            return QuickBooksLineItem(
                Amount: extendedAmount,
                DetailType: "SalesItemLineDetail",
                Description: snapshot.quickBooksDescription,
                SalesItemLineDetail: QuickBooksSalesItemLineDetail(
                    ItemRef: QuickBooksReference(value: quickBooksItemID, name: snapshot.name),
                    Qty: snapshot.quantity,
                    UnitPrice: snapshot.unitPrice,
                    TaxCodeRef: QuickBooksReference(
                        value: BillingTaxPolicy.quickBooksTaxCodeValue(isTaxable: snapshot.isTaxable),
                        name: nil
                    )
                )
            )
        }

        let mappedTotal = lines.reduce(0) { $0 + $1.Amount }
        guard currencyCents(expectedSubtotal) != nil,
              currencyCents(expectedSubtotal) == currencyCents(mappedTotal) else {
            throw QuickBooksDocumentLinePublicationError.amountMismatch(
                expected: expectedSubtotal,
                mapped: mappedTotal
            )
        }
        return lines
    }

    private static func currencyCents(_ amount: Double) -> Int64? {
        guard amount.isFinite,
              amount >= 0,
              amount <= Double(Int64.max) / 100 else { return nil }
        return Int64((amount * 100).rounded())
    }
}

enum QuickBooksInvoicePublicationRecoveryError: LocalizedError, Equatable {
    case protectedHistory(String)
    case missingCustomerMapping
    case ambiguousRemoteMarker

    var errorDescription: String? {
        switch self {
        case .protectedHistory(let detail):
            return detail
        case .missingCustomerMapping:
            return "Publish this invoice from Job Billing first so the customer can be linked to QuickBooks."
        case .ambiguousRemoteMarker:
            return "More than one QuickBooks invoice has this GunnAire operation marker. Review the duplicates in QuickBooks before retrying."
        }
    }
}

enum QuickBooksInvoicePublicationRecovery {
    static func queuedInvoices(from invoices: [Invoice]) -> [Invoice] {
        invoices
            .filter { $0.quickBooksSyncState != "synced" }
            .sorted { lhs, rhs in
                if lhs.needsQuickBooksAttention != rhs.needsQuickBooksAttention {
                    return lhs.needsQuickBooksAttention && !rhs.needsQuickBooksAttention
                }
                return lhs.createdAt > rhs.createdAt
            }
    }

    static func publicationInputs(
        for invoice: Invoice,
        catalogItems: [Item],
        payments: [Payment]
    ) throws -> QuickBooksInvoicePublicationInputs {
        if invoice.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
           let blockedMessage = BillingInvoiceMutationPolicy.blockedMessage(for: invoice, payments: payments) {
            throw QuickBooksInvoicePublicationRecoveryError.protectedHistory(blockedMessage)
        }

        guard let customerID = invoice.customer.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !customerID.isEmpty else {
            throw QuickBooksInvoicePublicationRecoveryError.missingCustomerMapping
        }

        let lines = try QuickBooksDocumentLinePublication.lines(
            snapshotJSON: invoice.catalogSnapshotJSON,
            expectedSubtotal: invoice.subtotalAmount,
            catalogItems: catalogItems
        )

        return QuickBooksInvoicePublicationInputs(
            customerRef: QuickBooksReference(value: customerID, name: invoice.customer.name),
            lines: lines,
            billEmail: invoice.customer.email.flatMap { email in
                let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : QuickBooksEmailAddress(Address: trimmed)
            },
            privateNote: QuickBooksInvoiceLineage.appendingLineage(
                to: BillingPriceAdjustmentAudit.quickBooksPrivateNote(
                    existing: invoice.accountingPrivateNote,
                    snapshotJSON: invoice.catalogSnapshotJSON
                ),
                for: invoice
            ),
            shipAddress: invoice.siteAddress.flatMap { address in
                let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : QuickBooksAddress(Line1: trimmed)
            }
        )
    }

    static func matchingRemoteInvoice(
        for invoice: Invoice,
        in remoteInvoices: [QuickBooksInvoice]
    ) throws -> QuickBooksInvoice? {
        let matches = QuickBooksInvoiceLineage.matchingRemoteInvoices(
            for: invoice,
            in: remoteInvoices
        )
        guard matches.count <= 1 else {
            throw QuickBooksInvoicePublicationRecoveryError.ambiguousRemoteMarker
        }
        return matches.first
    }
}

struct QuickBooksEstimatePublicationInputs {
    let customerRef: QuickBooksReference
    let lines: [QuickBooksLineItem]
    let billEmail: QuickBooksEmailAddress?
    let privateNote: String
    let shipAddress: QuickBooksAddress?
}

enum QuickBooksEstimatePublicationRecoveryError: LocalizedError, Equatable {
    case missingCustomerMapping
    case ambiguousRemoteMarker

    var errorDescription: String? {
        switch self {
        case .missingCustomerMapping:
            return "Publish this estimate from Job Billing first so the customer can be linked to QuickBooks."
        case .ambiguousRemoteMarker:
            return "More than one QuickBooks estimate has this GunnAire operation marker. Review the duplicates in QuickBooks before retrying."
        }
    }
}

enum QuickBooksEstimatePublicationRecovery {
    static func queuedEstimates(from estimates: [Estimate]) -> [Estimate] {
        let closedStatuses = Set(["rejected", "invoiced", "not-selected"])
        return estimates
            .filter { estimate in
                estimate.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false &&
                    !closedStatuses.contains(estimate.status.lowercased())
            }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    static func publicationInputs(
        for estimate: Estimate,
        catalogItems: [Item]
    ) throws -> QuickBooksEstimatePublicationInputs {
        guard let customerID = estimate.customer.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !customerID.isEmpty else {
            throw QuickBooksEstimatePublicationRecoveryError.missingCustomerMapping
        }

        let lines = try QuickBooksDocumentLinePublication.lines(
            snapshotJSON: estimate.catalogSnapshotJSON,
            expectedSubtotal: estimate.subtotalAmount,
            catalogItems: catalogItems
        )

        let adjustedNote = BillingPriceAdjustmentAudit.quickBooksPrivateNote(
            existing: estimate.notes,
            snapshotJSON: estimate.catalogSnapshotJSON
        )
        return QuickBooksEstimatePublicationInputs(
            customerRef: QuickBooksReference(value: customerID, name: estimate.customer.name),
            lines: lines,
            billEmail: estimate.customer.email.flatMap { email in
                let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : QuickBooksEmailAddress(Address: trimmed)
            },
            privateNote: QuickBooksEstimateLineage.appendingLineage(to: adjustedNote, for: estimate),
            shipAddress: estimate.siteAddress.flatMap { address in
                let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : QuickBooksAddress(Line1: trimmed)
            }
        )
    }

    static func matchingRemoteEstimate(
        for estimate: Estimate,
        in remoteEstimates: [QuickBooksEstimate]
    ) throws -> QuickBooksEstimate? {
        let matches = QuickBooksEstimateLineage.matchingRemoteEstimates(for: estimate, in: remoteEstimates)
        guard matches.count <= 1 else {
            throw QuickBooksEstimatePublicationRecoveryError.ambiguousRemoteMarker
        }
        return matches.first
    }
}

enum PricebookReviewPublicationError: LocalizedError, Equatable {
    case ambiguousRemoteMatch(String)

    var errorDescription: String? {
        switch self {
        case .ambiguousRemoteMatch(let name):
            return "More than one QuickBooks catalog item matches \(name). Link the correct item manually before publishing."
        }
    }
}

enum PricebookReviewPublication {
    static func matchingRemoteItem(
        for localItem: Item,
        in remoteItems: [QuickBooksItem]
    ) throws -> QuickBooksItem? {
        let normalizedName = normalize(localItem.name)
        let normalizedSKU = normalize(localItem.sku ?? "")
        let candidates = remoteItems.filter { remote in
            guard normalize(remote.Name) == normalizedName else { return false }
            let remoteSKU = normalize(remote.Sku ?? "")
            return normalizedSKU.isEmpty || remoteSKU.isEmpty || normalizedSKU == remoteSKU
        }
        guard candidates.count <= 1 else {
            throw PricebookReviewPublicationError.ambiguousRemoteMatch(localItem.name)
        }
        return candidates.first
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct PricebookReviewDocumentImpact: Equatable {
    let estimateCount: Int
    let invoiceCount: Int

    var totalCount: Int {
        estimateCount + invoiceCount
    }

    var summary: String {
        guard totalCount > 0 else {
            return "Not currently required by an estimate or invoice waiting for QuickBooks."
        }
        let estimateSummary = estimateCount == 0
            ? nil
            : "\(estimateCount) \(estimateCount == 1 ? "estimate" : "estimates")"
        let invoiceSummary = invoiceCount == 0
            ? nil
            : "\(invoiceCount) \(invoiceCount == 1 ? "invoice" : "invoices")"
        return "Required by \([estimateSummary, invoiceSummary].compactMap { $0 }.joined(separator: " and ")) waiting for QuickBooks."
    }
}

enum PricebookReviewQueue {
    static func queuedItems(
        from items: [Item],
        estimates: [Estimate],
        invoices: [Invoice]
    ) -> [Item] {
        items
            .filter(\.requiresPricebookReview)
            .sorted { lhs, rhs in
                let lhsImpact = documentImpact(for: lhs, estimates: estimates, invoices: invoices)
                let rhsImpact = documentImpact(for: rhs, estimates: estimates, invoices: invoices)
                if lhsImpact.totalCount != rhsImpact.totalCount {
                    return lhsImpact.totalCount > rhsImpact.totalCount
                }
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    static func documentImpact(
        for item: Item,
        estimates: [Estimate],
        invoices: [Invoice]
    ) -> PricebookReviewDocumentImpact {
        let closedEstimateStatuses = Set(["rejected", "invoiced", "not-selected"])
        let estimateCount = estimates.filter { estimate in
            estimate.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false &&
            !closedEstimateStatuses.contains(estimate.status.lowercased()) &&
            references(item, snapshotJSON: estimate.catalogSnapshotJSON)
        }.count
        let invoiceCount = invoices.filter { invoice in
            invoice.quickBooksSyncState != "synced" &&
            references(item, snapshotJSON: invoice.catalogSnapshotJSON)
        }.count
        return PricebookReviewDocumentImpact(
            estimateCount: estimateCount,
            invoiceCount: invoiceCount
        )
    }

    private static func references(_ item: Item, snapshotJSON: String?) -> Bool {
        CatalogLineItemSnapshot.decoded(from: snapshotJSON)
            .contains { snapshot in
                snapshot.catalogItemID == item.id ||
                snapshot.assembly?.components.contains(where: { $0.itemID == item.id }) == true
            }
    }
}

enum QuickBooksCatalogPublicationRecovery {
    static func queuedItems(from items: [Item]) -> [Item] {
        items
            .filter { item in
                !item.requiresPricebookReview &&
                item.quickBooksCatalogSyncState != "synced" &&
                !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted { lhs, rhs in
                if lhs.needsQuickBooksAttention != rhs.needsQuickBooksAttention {
                    return lhs.needsQuickBooksAttention
                }
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
}

struct QuickBooksCatalogFieldDifference: Identifiable, Equatable {
    let field: String
    let gunnAireValue: String
    let quickBooksValue: String

    var id: String { field }
}

struct QuickBooksCatalogReconciliationEntry: Identifiable {
    let localItem: Item
    let remoteItem: QuickBooksItem
    let differences: [QuickBooksCatalogFieldDifference]

    var id: UUID { localItem.id }
}

enum QuickBooksCatalogReconciliationError: LocalizedError, Equatable {
    case identifierMismatch
    case missingSyncToken
    case invalidName
    case invalidAmount
    case itemTypeConflict(local: String, quickBooks: String)
    case preferredVendorRemovalUnsupported

    var errorDescription: String? {
        switch self {
        case .identifierMismatch:
            "The GunnAire item is not linked to this QuickBooks catalog record. Refresh and review the mapping before publishing."
        case .missingSyncToken:
            "QuickBooks did not return the current catalog SyncToken. Refresh accounting data before publishing so a newer change is not overwritten."
        case .invalidName:
            "Enter a catalog name between 1 and 100 characters before publishing."
        case .invalidAmount:
            "Sales price and purchase cost must be finite values of zero or more."
        case .itemTypeConflict(let local, let quickBooks):
            "QuickBooks item type is \(quickBooks), while GunnAire is \(local). Use the QuickBooks version or create a new item instead of changing an accounting item type."
        case .preferredVendorRemovalUnsupported:
            "This change would remove the QuickBooks preferred vendor. Choose a replacement vendor or use the QuickBooks version."
        }
    }
}

enum QuickBooksCatalogReconciliation {
    static func entries(
        localItems: [Item],
        remoteItems: [QuickBooksItem]
    ) -> [QuickBooksCatalogReconciliationEntry] {
        let conflictedLocalItemIDs = Set(
            QuickBooksCatalogMappingIntegrity.conflicts(in: localItems)
                .flatMap(\.localItems)
                .map(\.id)
        )
        let remoteByID = Dictionary(
            remoteItems.map { (normalized($0.Id), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return localItems.compactMap { localItem in
            guard !conflictedLocalItemIDs.contains(localItem.id),
                  localItem.hasPendingQuickBooksCatalogUpdate,
                  let quickBooksID = localItem.quickBooksID,
                  let remoteItem = remoteByID[normalized(quickBooksID)] else { return nil }
            let itemDifferences = differences(localItem: localItem, remoteItem: remoteItem)
            guard !itemDifferences.isEmpty else { return nil }
            return QuickBooksCatalogReconciliationEntry(
                localItem: localItem,
                remoteItem: remoteItem,
                differences: itemDifferences
            )
        }
        .sorted { lhs, rhs in
            if lhs.localItem.needsQuickBooksAttention != rhs.localItem.needsQuickBooksAttention {
                return lhs.localItem.needsQuickBooksAttention
            }
            return lhs.localItem.name.localizedCaseInsensitiveCompare(rhs.localItem.name) == .orderedAscending
        }
    }

    static func differences(
        localItem: Item,
        remoteItem: QuickBooksItem
    ) -> [QuickBooksCatalogFieldDifference] {
        var result: [QuickBooksCatalogFieldDifference] = []
        appendTextDifference("Name", localItem.name, remoteItem.Name, to: &result)
        appendTextDifference("Type", localItem.itemType.rawValue, remoteItem.ItemType, to: &result)
        appendTextDifference("Description", localItem.itemDescription, remoteItem.Description, to: &result)
        appendTextDifference("SKU", localItem.sku, remoteItem.Sku, to: &result)
        appendMoneyDifference("Sales price", localItem.unitPrice, remoteItem.UnitPrice ?? 0, to: &result)
        appendMoneyDifference("Purchase cost", localItem.purchaseCost ?? 0, remoteItem.PurchaseCost ?? 0, to: &result)
        if localItem.isTaxable != (remoteItem.Taxable ?? false) {
            result.append(
                QuickBooksCatalogFieldDifference(
                    field: "Tax treatment",
                    gunnAireValue: localItem.isTaxable ? "Taxable" : "Non-taxable",
                    quickBooksValue: (remoteItem.Taxable ?? false) ? "Taxable" : "Non-taxable"
                )
            )
        }
        appendTextDifference("Purchase description", localItem.purchaseDescription, remoteItem.PurchaseDesc, to: &result)

        let localVendorID = normalized(localItem.preferredVendorQuickBooksID ?? "")
        let remoteVendorID = normalized(remoteItem.PrefVendorRef?.value ?? "")
        if localVendorID != remoteVendorID {
            result.append(
                QuickBooksCatalogFieldDifference(
                    field: "Preferred vendor",
                    gunnAireValue: display(localItem.preferredVendorName ?? localItem.preferredVendorQuickBooksID),
                    quickBooksValue: display(remoteItem.PrefVendorRef?.displayName ?? remoteItem.PrefVendorRef?.value)
                )
            )
        }
        return result
    }

    static func updatePayload(
        localItem: Item,
        currentRemoteItem: QuickBooksItem
    ) throws -> QuickBooksItemUpdate {
        guard normalized(localItem.quickBooksID ?? "") == normalized(currentRemoteItem.Id) else {
            throw QuickBooksCatalogReconciliationError.identifierMismatch
        }
        guard let syncToken = currentRemoteItem.SyncToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !syncToken.isEmpty else {
            throw QuickBooksCatalogReconciliationError.missingSyncToken
        }
        let name = localItem.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else {
            throw QuickBooksCatalogReconciliationError.invalidName
        }
        let purchaseCost = localItem.purchaseCost ?? 0
        guard localItem.unitPrice.isFinite, localItem.unitPrice >= 0,
              purchaseCost.isFinite, purchaseCost >= 0 else {
            throw QuickBooksCatalogReconciliationError.invalidAmount
        }
        let remoteType = currentRemoteItem.ItemType ?? localItem.itemType.rawValue
        guard normalized(remoteType) == normalized(localItem.itemType.rawValue) else {
            throw QuickBooksCatalogReconciliationError.itemTypeConflict(
                local: localItem.itemType.rawValue,
                quickBooks: remoteType
            )
        }
        let localVendorID = localItem.preferredVendorQuickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if localVendorID?.isEmpty != false,
           currentRemoteItem.PrefVendorRef?.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            throw QuickBooksCatalogReconciliationError.preferredVendorRemovalUnsupported
        }
        return QuickBooksItemUpdate(
            Id: currentRemoteItem.Id,
            SyncToken: syncToken,
            Name: name,
            Description: trimmed(localItem.itemDescription),
            Sku: trimmed(localItem.sku),
            PurchaseDesc: trimmed(localItem.purchaseDescription),
            UnitPrice: localItem.unitPrice,
            PurchaseCost: purchaseCost,
            Taxable: localItem.isTaxable,
            PrefVendorRef: localVendorID.flatMap { id in
                id.isEmpty ? nil : QuickBooksReference(value: id, name: localItem.preferredVendorName)
            }
        )
    }

    static func canPublish(localItem: Item, currentRemoteItem: QuickBooksItem) -> Bool {
        (try? updatePayload(localItem: localItem, currentRemoteItem: currentRemoteItem)) != nil
    }

    private static func appendTextDifference(
        _ field: String,
        _ local: String?,
        _ remote: String?,
        to result: inout [QuickBooksCatalogFieldDifference]
    ) {
        let localValue = trimmed(local)
        let remoteValue = trimmed(remote)
        guard localValue != remoteValue else { return }
        result.append(
            QuickBooksCatalogFieldDifference(
                field: field,
                gunnAireValue: display(localValue),
                quickBooksValue: display(remoteValue)
            )
        )
    }

    private static func appendMoneyDifference(
        _ field: String,
        _ local: Double,
        _ remote: Double,
        to result: inout [QuickBooksCatalogFieldDifference]
    ) {
        guard abs(local - remote) >= 0.005 else { return }
        result.append(
            QuickBooksCatalogFieldDifference(
                field: field,
                gunnAireValue: local.formatted(.currency(code: "USD")),
                quickBooksValue: remote.formatted(.currency(code: "USD"))
            )
        )
    }

    private static func trimmed(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func display(_ value: String?) -> String {
        let value = trimmed(value)
        return value.isEmpty ? "None" : value
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// The subset of a GunnAire pricebook item that is represented by the
/// QuickBooks Item API. GunnAire-only service-package metadata is deliberately
/// excluded so editing a package does not manufacture a pending accounting
/// change when every QuickBooks field is unchanged.
struct QuickBooksCatalogAccountingSnapshot: Equatable {
    let name: String
    let itemType: CatalogItemType
    let itemDescription: String
    let sku: String
    let unitPrice: Double
    let purchaseCost: Double
    let isTaxable: Bool
    let purchaseDescription: String
    let preferredVendorQuickBooksID: String

    init(item: Item) {
        self.init(
            name: item.name,
            itemType: item.itemType,
            itemDescription: item.itemDescription,
            sku: item.sku,
            unitPrice: item.unitPrice,
            purchaseCost: item.purchaseCost,
            isTaxable: item.isTaxable,
            purchaseDescription: item.purchaseDescription,
            preferredVendorQuickBooksID: item.preferredVendorQuickBooksID
        )
    }

    init(
        name: String,
        itemType: CatalogItemType,
        itemDescription: String?,
        sku: String?,
        unitPrice: Double,
        purchaseCost: Double?,
        isTaxable: Bool,
        purchaseDescription: String?,
        preferredVendorQuickBooksID: String?
    ) {
        self.name = Self.trimmed(name)
        self.itemType = itemType
        self.itemDescription = Self.trimmed(itemDescription)
        self.sku = Self.trimmed(sku)
        self.unitPrice = unitPrice
        self.purchaseCost = purchaseCost ?? 0
        self.isTaxable = isTaxable
        self.purchaseDescription = Self.trimmed(purchaseDescription)
        self.preferredVendorQuickBooksID = Self.trimmed(preferredVendorQuickBooksID).lowercased()
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name &&
        lhs.itemType == rhs.itemType &&
        lhs.itemDescription == rhs.itemDescription &&
        lhs.sku == rhs.sku &&
        abs(lhs.unitPrice - rhs.unitPrice) < 0.005 &&
        abs(lhs.purchaseCost - rhs.purchaseCost) < 0.005 &&
        lhs.isTaxable == rhs.isTaxable &&
        lhs.purchaseDescription == rhs.purchaseDescription &&
        lhs.preferredVendorQuickBooksID == rhs.preferredVendorQuickBooksID
    }

    private static func trimmed(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

enum QuickBooksCatalogStagingPolicy {
    static func requiresQuickBooksStaging(
        current item: Item,
        proposed: QuickBooksCatalogAccountingSnapshot
    ) -> Bool {
        guard item.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return true
        }
        return QuickBooksCatalogAccountingSnapshot(item: item) != proposed
    }
}

struct QuickBooksManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var quickBooksDataAPI = QuickBooksDataAPI.shared
    @ObservedObject private var accountingConfigurationStore = QuickBooksAccountingConfigurationStore.shared
    @Query(sort: \ServiceCall.scheduledDate, order: .reverse) private var serviceCalls: [ServiceCall]
    @Query(sort: \Customer.name, order: .forward) private var localCustomers: [Customer]
    @Query(sort: \Item.name, order: .forward) private var localCatalogItems: [Item]
    @Query(sort: \Estimate.createdAt, order: .reverse) private var localEstimates: [Estimate]
    @Query(sort: \Invoice.createdAt, order: .reverse) private var localInvoices: [Invoice]
    @Query(sort: \Payment.date, order: .reverse) private var localPayments: [Payment]
    private let liveAPI = QuickBooksAPI.shared

    @State private var customers: [QuickBooksCustomer] = []
    @State private var items: [QuickBooksItem] = []
    @State private var accounts: [QuickBooksAccount] = []
    @State private var estimates: [QuickBooksEstimate] = []
    @State private var invoices: [QuickBooksInvoice] = []
    @State private var bills: [QuickBooksBill] = []
    @State private var vendorCredits: [QuickBooksVendorCredit] = []
    @State private var purchases: [QuickBooksPurchase] = []
    @State private var vendors: [QuickBooksVendor] = []
    @State private var payments: [QuickBooksPayment] = []
    @State private var salesReceipts: [QuickBooksSalesReceipt] = []
    @State private var deposits: [QuickBooksDeposit] = []
    @State private var paymentMethods: [QuickBooksPaymentMethod] = []
    @State private var storedCards: [QuickBooksPaymentsCardRecord] = []
    @State private var paymentReceipts: [String: QuickBooksPaymentsPaymentReceipt] = [:]

    @State private var showingNewCustomerSheet = false
    @State private var showingNewCatalogItemSheet = false
    @State private var showingNewEstimateSheet = false
    @State private var showingNewInvoiceSheet = false
    @State private var showingNewSalesReceiptSheet = false
    @State private var showingNewBillSheet = false
    @State private var showingNewPurchaseSheet = false
    @State private var showingNewVendorSheet = false
    @State private var showingNewPaymentSheet = false
    @State private var showingProcessCardPaymentSheet = false
    @State private var showingRefundPaymentSheet = false
    @State private var showingStoreCardSheet = false
    @State private var showingAccountingMappingSheet = false

    @State private var isLoading = false
    @State private var statusMessage = "Connect QuickBooks in Settings to start live sync."
    @State private var actionMessage: String?
    @State private var syncResourceStatuses: [QuickBooksSyncResourceStatus] = Self.defaultSyncResourceStatuses
    @State private var lastSuccessfulSyncAt: Date? = UserDefaults.standard.object(forKey: "QuickBooksLastSuccessfulSyncAt") as? Date
    @State private var lastSyncStartedAt: Date?
    @State private var activePaymentInvoiceID: String?
    @State private var activeEmailEstimateID: String?
    @State private var activeEmailInvoiceID: String?
    @State private var activeLocalEstimatePublicationID: UUID?
    @State private var activeLocalInvoicePublicationID: UUID?
    @State private var activePricebookReviewID: UUID?
    @State private var activeCatalogPublicationID: UUID?
    @State private var activeCatalogReconciliationID: UUID?
    @State private var catalogMappingResolutionCandidateID: UUID?
    @State private var catalogItemBeingEdited: Item?
    @State private var paymentToRefund: Payment?
    @State private var quickBooksReconnectRequired = false
    @State private var showCustomersList = false
    @State private var showCatalogList = false
    @State private var showEstimatePublicationQueue = false
    @State private var showCatalogPublicationQueue = false
    @State private var showCatalogReconciliationQueue = false
    @State private var showEstimatesList = false
    @State private var showInvoicesList = false
    @State private var customerSearchText = ""
    @State private var catalogSearchText = ""
    @State private var estimateSearchText = ""
    @State private var invoiceSearchText = ""
    @State private var selectedWorkspace: QuickBooksManagementWorkspace = .overview
    @State private var quickBooksWebhookEvents: [BackendQuickBooksWebhookEvent] = []
    @State private var activeSyncWebhookEventIDs: Set<String> = []
    @State private var isLoadingWebhookEvents = false
    @State private var webhookStatusMessage: String?
    @State private var showWebhookEventDetails = false

    private var isAuthenticated: Bool {
        quickBooksDataAPI.isAuthenticated
    }

    #if DEBUG
    private var catalogReconciliationFixtureRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestSeedCatalogReconciliation") ||
        ProcessInfo.processInfo.arguments.contains("-uiTestSeedCatalogMappingConflict")
    }

    private var accountingMappingFixtureRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestSeedQBOAccountingMappings")
    }

    private static let accountingMappingFixtureRealmID = "9341455327810551"

    private static var accountingMappingFixtureItems: [QuickBooksItem] {
        let data = Data(#"[{"Id":"1","Name":"HVAC Service","Type":"Service","Active":true,"IncomeAccountRef":{"value":"79","name":"Service Income"}}]"#.utf8)
        return (try? JSONDecoder().decode([QuickBooksItem].self, from: data)) ?? []
    }

    private static var accountingMappingFixtureAccounts: [QuickBooksAccount] {
        let data = Data(#"[{"Id":"79","Name":"Service Income","FullyQualifiedName":"Service Income","AccountType":"Income","Active":true},{"Id":"80","Name":"HVAC Materials","FullyQualifiedName":"HVAC Materials","AccountType":"Cost of Goods Sold","Active":true},{"Id":"33","Name":"Accounts Payable","FullyQualifiedName":"Accounts Payable","AccountType":"Accounts Payable","Active":true},{"Id":"35","Name":"Operating Checking","FullyQualifiedName":"Operating Checking","AccountType":"Bank","Active":true},{"Id":"36","Name":"Company Card","FullyQualifiedName":"Company Card","AccountType":"Credit Card","Active":true}]"#.utf8)
        return (try? JSONDecoder().decode([QuickBooksAccount].self, from: data)) ?? []
    }

    private static var accountingMappingFixtureConfiguration: BackendQuickBooksAccountingConfiguration {
        BackendQuickBooksAccountingConfiguration(
            realmID: accountingMappingFixtureRealmID,
            environment: Config.QuickBooks.environment,
            defaultSalesItemRef: "1",
            defaultSalesItemName: "HVAC Service",
            defaultSalesItemType: "Service",
            defaultIncomeAccountRef: "79",
            defaultIncomeAccountName: "Service Income",
            defaultIncomeAccountType: "Income",
            defaultExpenseAccountRef: "80",
            defaultExpenseAccountName: "HVAC Materials",
            defaultExpenseAccountType: "Cost of Goods Sold",
            defaultAPAccountRef: "33",
            defaultAPAccountName: "Accounts Payable",
            defaultAPAccountType: "Accounts Payable",
            defaultBankAccountRef: "35",
            defaultBankAccountName: "Operating Checking",
            defaultBankAccountType: "Bank",
            defaultCreditCardAccountRef: "36",
            defaultCreditCardAccountName: "Company Card",
            defaultCreditCardAccountType: "Credit Card",
            updatedAt: "2026-08-28T00:00:00Z",
            updatedBy: "admin@gunnaire.com"
        )
    }

    private static var catalogReconciliationFixtureItems: [QuickBooksItem] {
        let data = Data(#"{"Id":"QBO-UI-CATALOG-RECONCILE","SyncToken":"12","Name":"HVAC Diagnostic Service","Type":"Service","Description":"Diagnostic visit and system evaluation","UnitPrice":189,"PurchaseCost":42,"Taxable":false}"#.utf8)
        return (try? JSONDecoder().decode(QuickBooksItem.self, from: data)).map { [$0] } ?? []
    }
    #endif

    private var quickBooksPaymentsEnabled: Bool {
        quickBooksDataAPI.canUseQuickBooksPaymentsAPI
    }

    private var customersWithStoredPaymentMethods: [Customer] {
        localCustomers
            .filter { !$0.activeStoredPaymentMethods.isEmpty }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var linkedStoredPaymentMethodCount: Int {
        customersWithStoredPaymentMethods.reduce(0) { $0 + $1.activeStoredPaymentMethods.count }
    }

    private var quickBooksPaymentsUnavailableMessage: String {
        if let diagnostic = quickBooksDataAPI.paymentsAuthorizationDiagnostic {
            return diagnostic
        }
        return Config.QuickBooks.enablePaymentsScope
            ? "QuickBooks Payments is not authorized for this connection yet."
            : "Enable the QuickBooks Payments scope before using live payment endpoints."
    }

    private var quickBooksConfigReady: Bool {
        quickBooksDataAPI.canStartOAuthFlow
    }

    private var accountingConfigurationRealmID: String? {
        #if DEBUG
        if accountingMappingFixtureRequested { return Self.accountingMappingFixtureRealmID }
        #endif
        return quickBooksDataAPI.realmID
    }

    private var accountingConfiguration: BackendQuickBooksAccountingConfiguration? {
        guard let configuration = accountingConfigurationStore.configuration,
              configuration.matches(
                realmID: accountingConfigurationRealmID,
                environment: quickBooksDataAPI.currentEnvironment
              ) else { return nil }
        return configuration
    }

    private var quickBooksConfigurationWarnings: [String] {
        var warnings = Config.QuickBooks.configurationWarnings
        if let diagnostic = quickBooksDataAPI.scopeReauthorizationDiagnostic {
            warnings.append(diagnostic)
        } else if Config.QuickBooks.enablePaymentsScope,
                  quickBooksDataAPI.isAuthenticated,
                  !quickBooksDataAPI.savedSessionIncludesPaymentsScope {
            warnings.append("QuickBooks Payments features are enabled. Reconnect QuickBooks so Intuit can authorize the \(Config.QuickBooks.paymentsScope) scope for this company.")
        }
        return warnings
    }

    private var totalInvoiceAmount: Double {
        invoices.reduce(0) { $0 + $1.TotalAmt }
    }

    private var totalEstimateAmount: Double {
        estimates.reduce(0) { $0 + $1.TotalAmt }
    }

    private var totalBillAmount: Double {
        bills.reduce(0) { $0 + $1.TotalAmt }
    }

    private var totalVendorCreditAmount: Double {
        vendorCredits.reduce(0) { $0 + $1.TotalAmt }
    }

    private var totalPurchaseAmount: Double {
        purchases.reduce(0) { $0 + $1.TotalAmt }
    }

    private var totalPaymentAmount: Double {
        payments.reduce(0) { $0 + $1.TotalAmt }
    }

    private var totalSalesReceiptAmount: Double {
        salesReceipts.reduce(0) { $0 + $1.TotalAmt }
    }

    private var totalDepositAmount: Double {
        deposits.reduce(0) { $0 + $1.TotalAmt }
    }

    private var hasQuickBooksCardMethod: Bool {
        paymentMethods.contains { $0.Name.caseInsensitiveCompare("QuickBooks Card") == .orderedSame }
    }

    private var hasQuickBooksACHMethod: Bool {
        paymentMethods.contains { $0.Name.caseInsensitiveCompare("QuickBooks ACH") == .orderedSame }
    }

    private var quickBooksChargePayments: [Payment] {
        localPayments.filter { $0.quickBooksChargeID?.isEmpty == false }
    }

    private var collectibleQuickBooksInvoices: [QuickBooksInvoice] {
        invoices.filter { outstandingQuickBooksBalance(for: $0) > 0 }
    }

    private var collectibleLocalInvoices: [Invoice] {
        localInvoices.filter { localOutstandingBalance(for: $0) > 0 }
    }

    private var localInvoicePublicationQueue: [Invoice] {
        QuickBooksInvoicePublicationRecovery.queuedInvoices(from: localInvoices)
    }

    private var localEstimatePublicationQueue: [Estimate] {
        QuickBooksEstimatePublicationRecovery.queuedEstimates(from: localEstimates)
    }

    private var pendingPricebookReviewItems: [Item] {
        PricebookReviewQueue.queuedItems(
            from: localCatalogItems,
            estimates: localEstimates,
            invoices: localInvoices
        )
    }

    private var localCatalogPublicationQueue: [Item] {
        QuickBooksCatalogPublicationRecovery.queuedItems(from: localCatalogItems)
    }

    private var catalogReconciliationEntries: [QuickBooksCatalogReconciliationEntry] {
        QuickBooksCatalogReconciliation.entries(
            localItems: localCatalogItems,
            remoteItems: items
        )
    }

    private var catalogMappingConflicts: [QuickBooksCatalogMappingConflict] {
        QuickBooksCatalogMappingIntegrity.conflicts(in: localCatalogItems)
    }

    private var selectedCatalogMappingResolution: (conflict: QuickBooksCatalogMappingConflict, item: Item)? {
        guard let catalogMappingResolutionCandidateID else { return nil }
        for conflict in catalogMappingConflicts {
            if let item = conflict.localItems.first(where: { $0.id == catalogMappingResolutionCandidateID }) {
                return (conflict, item)
            }
        }
        return nil
    }

    private var filteredCustomers: [QuickBooksCustomer] {
        filtered(customers, query: customerSearchText) { customer in
            [
                customer.DisplayName,
                customer.PrimaryEmailAddr?.Address,
                customer.PrimaryPhone?.FreeFormNumber
            ]
        }
    }

    private var filteredItems: [QuickBooksItem] {
        filtered(items, query: catalogSearchText) { item in
            [
                item.Name,
                item.Description,
                item.Sku,
                item.PrefVendorRef?.displayName,
                item.ItemType
            ]
        }
    }

    private var filteredEstimates: [QuickBooksEstimate] {
        filtered(estimates, query: estimateSearchText) { estimate in
            [
                estimate.DocNumber,
                estimate.Id,
                estimate.CustomerRef.displayName,
                estimate.EmailStatus
            ]
        }
    }

    private var filteredInvoices: [QuickBooksInvoice] {
        filtered(invoices, query: invoiceSearchText) { invoice in
            [
                invoice.DocNumber,
                invoice.Id,
                invoice.CustomerRef.displayName,
                invoice.EmailStatus
            ]
        }
    }

    private var quickBooksCompanyURL: URL? {
        guard let realmID = quickBooksDataAPI.realmID else { return nil }
        return URL(string: "https://app.qbo.intuit.com/app/homepage?companyId=\(realmID)")
    }

    private var syncFailureCount: Int {
        syncResourceStatuses.filter { $0.state == .failed }.count
    }

    private var syncWarningCount: Int {
        syncResourceStatuses.filter { $0.state == .warning }.count
    }

    private var accountingStatuses: [QuickBooksSyncResourceStatus] {
        syncResourceStatuses.filter { $0.lane == "Accounting" }
    }

    private var paymentStatuses: [QuickBooksSyncResourceStatus] {
        syncResourceStatuses.filter { $0.lane == "Payments" }
    }

    var body: some View {
        ZStack {
            WatermarkBackground()
            NavigationStack {
                Form {
                    Section("QuickBooks Workspace") {
                        Picker("Workspace", selection: $selectedWorkspace) {
                            ForEach(QuickBooksManagementWorkspace.allCases) { workspace in
                                Text(workspace.label).tag(workspace)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("QuickBooksWorkspacePicker")

                        Label(selectedWorkspace.guidance, systemImage: selectedWorkspace.systemImage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if selectedWorkspace == .overview {
                    Section("Connection") {
                        connectionRow(
                            title: "Environment",
                            value: Config.QuickBooks.environment.capitalized
                        )
                        connectionRow(
                            title: "Company Realm",
                            value: quickBooksDataAPI.realmID ?? "Not connected"
                        )
                        connectionRow(
                            title: "Status",
                            value: isAuthenticated ? "Connected" : "Disconnected"
                        )

                        if let quickBooksCompanyURL {
                            Link("Open QuickBooks Online", destination: quickBooksCompanyURL)
                        }

                        if !isAuthenticated {
                            Text("Open Settings and connect QuickBooks before using live sync.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if !quickBooksConfigReady {
                            Text(
                                isAuthenticated
                                ? "QuickBooks is connected with a saved session. Reconnecting or refreshing requires the configured backend OAuth bridge and `QB_CLIENT_ID` in this app."
                                : "QuickBooks is not ready. Configure `QB_CLIENT_ID`, the HTTPS redirect URI, and the backend OAuth bridge before connecting."
                            )
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }

                        ForEach(quickBooksConfigurationWarnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    Section("Accounting Mappings") {
                        Label(
                            accountingConfiguration == nil ? "Setup required" : "Ready for this company",
                            systemImage: accountingConfiguration == nil
                                ? "exclamationmark.triangle.fill"
                                : "checkmark.circle.fill"
                        )
                        .foregroundStyle(accountingConfiguration == nil ? Color.orange : Color.green)
                        .accessibilityIdentifier("QBOAccountingMappingStatus")

                        if let accountingConfiguration {
                            LabeledContent(
                                "Sales",
                                value: "\(accountingConfiguration.defaultSalesItemName) → \(accountingConfiguration.defaultIncomeAccountName)"
                            )
                            LabeledContent("Costs", value: accountingConfiguration.defaultExpenseAccountName)
                            LabeledContent("Accounts Payable", value: accountingConfiguration.defaultAPAccountName)
                            LabeledContent(
                                "Purchases",
                                value: "\(accountingConfiguration.defaultBankAccountName) • \(accountingConfiguration.defaultCreditCardAccountName)"
                            )
                        } else {
                            Text("Choose verified QuickBooks defaults before publishing new pricebook items, bills, or purchases. The saved mapping is shared with approved field devices.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            showingAccountingMappingSheet = true
                        } label: {
                            Label(
                                accountingConfiguration == nil ? "Set Up Accounting Mappings" : "Review Accounting Mappings",
                                systemImage: "slider.horizontal.3"
                            )
                        }
                        .disabled(accountingConfigurationRealmID == nil || items.isEmpty || accounts.isEmpty)
                        .accessibilityIdentifier("QBOAccountingMappingsButton")

                        if items.isEmpty || accounts.isEmpty {
                            Text("Sync the QuickBooks catalog and chart of accounts to enable mapping choices.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if let statusMessage = accountingConfigurationStore.statusMessage {
                            Text(statusMessage)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Sync Health") {
                        connectionRow(
                            title: "Last Successful Sync",
                            value: lastSuccessfulSyncAt?.formatted(date: .abbreviated, time: .shortened) ?? "Not yet"
                        )
                        connectionRow(
                            title: "Token Expires",
                            value: quickBooksDataAPI.tokenExpiration?.formatted(date: .abbreviated, time: .shortened) ?? "No active token"
                        )
                        connectionRow(
                            title: "Sync Issues",
                            value: "\(syncFailureCount) failed • \(syncWarningCount) warnings"
                        )
                        connectionRow(
                            title: "QBO Changes",
                            value: isLoadingWebhookEvents
                                ? "Checking…"
                                : "\(quickBooksWebhookEvents.count) pending"
                        )
                        .accessibilityIdentifier("QuickBooksWebhookPendingCount")

                        if !quickBooksWebhookEvents.isEmpty {
                            Label(
                                "QuickBooks changed outside GunnAire. Run a full sync before relying on balances or catalog data.",
                                systemImage: "arrow.triangle.2.circlepath.circle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)

                            Button {
                                syncAllQuickBooksData()
                            } label: {
                                Label("Sync QBO Changes", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .disabled(isLoading || !isAuthenticated)
                            .accessibilityIdentifier("QuickBooksWebhookSyncButton")

                            DisclosureGroup("Pending change details", isExpanded: $showWebhookEventDetails) {
                                ForEach(quickBooksWebhookEvents.prefix(8)) { event in
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(event.summary)
                                        Spacer()
                                        Text("ID \(event.entityID)")
                                            .foregroundStyle(.secondary)
                                    }
                                    .font(.caption)
                                }
                                if quickBooksWebhookEvents.count > 8 {
                                    Text("\(quickBooksWebhookEvents.count - 8) additional changes will be included in the next sync.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else if let webhookStatusMessage {
                            Text(webhookStatusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(quickBooksDataAPI.connectionDiagnosticSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let environmentMismatch = quickBooksDataAPI.environmentMismatchDiagnostic {
                            Label(environmentMismatch, systemImage: "arrow.triangle.2.circlepath.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        if let scopeReauthorization = quickBooksDataAPI.scopeReauthorizationDiagnostic {
                            Label(scopeReauthorization, systemImage: "key.horizontal")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        if let paymentsAuthorization = quickBooksDataAPI.paymentsAuthorizationDiagnostic {
                            Label(paymentsAuthorization, systemImage: "creditcard.trianglebadge.exclamationmark")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        if quickBooksReconnectRequired {
                            Label(
                                "Reconnect QuickBooks in Settings with a company admin, then retry sync.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)

                            if let reconnectDetail = quickBooksDataAPI.lastRefreshFailureDetail
                                ?? quickBooksDataAPI.lastAuthorizationFailureDetail {
                                Text(reconnectDetail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if syncResourceStatuses.contains(where: { $0.state != .idle }) {
                            ForEach(accountingStatuses) { status in
                                syncResourceRow(status)
                            }
                            ForEach(paymentStatuses) { status in
                                syncResourceRow(status)
                            }
                        }
                    }

                    Section("Summary") {
                        summaryRow(title: "Customers", count: customers.count)
                        summaryRow(title: "Catalog Items", count: items.count)
                        summaryRow(title: "Estimates", count: estimates.count, amount: totalEstimateAmount)
                        summaryRow(title: "Invoices", count: invoices.count, amount: totalInvoiceAmount)
                        summaryRow(title: "Bills", count: bills.count, amount: totalBillAmount)
                        summaryRow(title: "Vendor Credits", count: vendorCredits.count, amount: totalVendorCreditAmount)
                        summaryRow(title: "Purchases", count: purchases.count, amount: totalPurchaseAmount)
                        summaryRow(title: "Vendors", count: vendors.count)
                        summaryRow(title: "Payments", count: payments.count, amount: totalPaymentAmount)
                        summaryRow(title: "Sales Receipts", count: salesReceipts.count, amount: totalSalesReceiptAmount)
                        summaryRow(title: "Deposits", count: deposits.count, amount: totalDepositAmount)
                        summaryRow(title: "Payment Methods", count: paymentMethods.count)
                        summaryRow(title: "Stored Cards", count: storedCards.count)
                    }
                    }

                    if selectedWorkspace == .sales {
                    Section(header: Text("Local Estimate Publication").foregroundColor(Color.brandGold)) {
                        if localEstimatePublicationQueue.isEmpty {
                            Label("All open local estimates are linked to QuickBooks.", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Text("Recover or publish open estimates without creating a duplicate after an uncertain QuickBooks response.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            DisclosureGroup(isExpanded: $showEstimatePublicationQueue) {
                                ForEach(localEstimatePublicationQueue) { estimate in
                                    VStack(alignment: .leading, spacing: 7) {
                                        HStack(alignment: .firstTextBaseline) {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(estimate.customer.name)
                                                    .font(.headline)
                                                Text(estimate.isProposalOption
                                                     ? estimate.proposalOptionDisplayDetail
                                                     : (estimate.lineItemSummary.isEmpty ? "Estimate \(estimate.id.uuidString.prefix(8))" : estimate.lineItemSummary))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(2)
                                            }
                                            Spacer()
                                            Text(estimate.amount, format: .currency(code: "USD"))
                                                .font(.subheadline.weight(.semibold))
                                        }

                                        HStack {
                                            Button(activeLocalEstimatePublicationID == estimate.id ? "Checking QuickBooks..." : "Recover or Publish") {
                                                retryLocalEstimatePublication(estimate)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .tint(Color.brandGold)
                                            .foregroundStyle(Color.primaryBlack)
                                            .disabled(!isAuthenticated || activeLocalEstimatePublicationID != nil)

                                            if let call = localServiceCall(for: estimate) {
                                                Button("Open Job Billing") {
                                                    GunnAireAppIntentRouter.storeInvoiceBuilderRoute(call.id)
                                                }
                                                .buttonStyle(.bordered)
                                            } else {
                                                Button("Open Estimates") {
                                                    GunnAireAppIntentRouter.store(.estimates)
                                                }
                                                .buttonStyle(.bordered)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 3)
                                }
                            } label: {
                                Label(
                                    "Review \(localEstimatePublicationQueue.count) open \(localEstimatePublicationQueue.count == 1 ? "estimate" : "estimates")",
                                    systemImage: "doc.badge.arrow.up"
                                )
                            }
                        }
                    }
                    .accessibilityIdentifier("QuickBooksLocalEstimatePublicationQueue")

                    Section(header: Text("Local Invoice Publication").foregroundColor(Color.brandGold)) {
                        if localInvoicePublicationQueue.isEmpty {
                            Label("All local invoices are published to QuickBooks.", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Text("Review local invoices that are pending or need attention before relying on QuickBooks balances and reporting.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            ForEach(localInvoicePublicationQueue) { invoice in
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack(alignment: .firstTextBaseline) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(invoice.customer.name)
                                                .font(.headline)
                                            Text(invoice.lineItemSummary.isEmpty ? "Invoice \(invoice.id.uuidString.prefix(8))" : invoice.lineItemSummary)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                        Spacer()
                                        Text(invoice.amount, format: .currency(code: "USD"))
                                            .font(.subheadline.weight(.semibold))
                                    }

                                    Label(
                                        invoice.needsQuickBooksAttention ? "Needs attention" : "Publication pending",
                                        systemImage: invoice.needsQuickBooksAttention ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath"
                                    )
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(invoice.needsQuickBooksAttention ? Color.orange : Color.secondary)

                                    if let detail = invoice.quickBooksSyncDetail?.trimmingCharacters(in: .whitespacesAndNewlines),
                                       !detail.isEmpty {
                                        Text(detail)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }

                                    HStack {
                                        Button(activeLocalInvoicePublicationID == invoice.id ? "Retrying..." : "Retry Publication") {
                                            retryLocalInvoicePublication(invoice)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(Color.brandGold)
                                        .foregroundStyle(Color.primaryBlack)
                                        .disabled(!isAuthenticated || activeLocalInvoicePublicationID != nil)

                                        if let call = localServiceCall(for: invoice) {
                                            Button("Open Job Billing") {
                                                GunnAireAppIntentRouter.storeInvoiceBuilderRoute(call.id)
                                            }
                                            .buttonStyle(.bordered)
                                        } else {
                                            Button("Open Invoices") {
                                                GunnAireAppIntentRouter.store(.invoices)
                                            }
                                            .buttonStyle(.bordered)
                                        }
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                    .accessibilityIdentifier("QuickBooksLocalInvoicePublicationQueue")

                    Section(
                        header: Text("Catalog Publication")
                            .foregroundColor(Color.brandGold)
                            .accessibilityIdentifier("QuickBooksCatalogPublicationQueue")
                    ) {
                        if localCatalogPublicationQueue.isEmpty {
                            Label("All approved local catalog items are linked to QuickBooks.", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Text("Retries first reconcile one unique QuickBooks name and SKU match. A new item is created only when no match exists.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            DisclosureGroup(isExpanded: $showCatalogPublicationQueue) {
                                ForEach(localCatalogPublicationQueue) { item in
                                    VStack(alignment: .leading, spacing: 7) {
                                        HStack(alignment: .firstTextBaseline) {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(item.name)
                                                    .font(.headline)
                                                Text([
                                                    item.sku.map { "SKU \($0)" },
                                                    item.itemType.rawValue
                                                ].compactMap { $0 }.joined(separator: " • "))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Text(item.unitPrice, format: .currency(code: "USD"))
                                                .font(.subheadline.weight(.semibold))
                                        }

                                        Label(
                                            item.needsQuickBooksAttention ? "Needs attention" : "Publication pending",
                                            systemImage: item.needsQuickBooksAttention ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath"
                                        )
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(item.needsQuickBooksAttention ? Color.orange : Color.secondary)

                                        if let detail = item.quickBooksSyncDetail?.trimmingCharacters(in: .whitespacesAndNewlines),
                                           !detail.isEmpty {
                                            Text(detail)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }

                                        Button(activeCatalogPublicationID == item.id ? "Retrying..." : "Retry Catalog Publication") {
                                            retryCatalogPublication(item)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(Color.brandGold)
                                        .foregroundStyle(Color.primaryBlack)
                                        .disabled(
                                            !isAuthenticated ||
                                            activeCatalogPublicationID != nil ||
                                            activePricebookReviewID != nil
                                        )
                                        .accessibilityIdentifier("RetryCatalogPublication-\(item.id.uuidString)")
                                    }
                                    .padding(.vertical, 3)
                                }
                            } label: {
                                Label(
                                    "Review \(localCatalogPublicationQueue.count) approved \(localCatalogPublicationQueue.count == 1 ? "item" : "items")",
                                    systemImage: "shippingbox.and.arrow.backward"
                                )
                            }
                            .accessibilityIdentifier("QuickBooksCatalogPublicationDisclosure")
                        }
                    }

                    if !catalogMappingConflicts.isEmpty {
                        Section(
                            header: Text("Catalog Mapping Conflicts")
                                .foregroundColor(Color.brandGold)
                                .accessibilityIdentifier("QuickBooksCatalogMappingConflictQueue")
                        ) {
                            Text("A QuickBooks product or service can belong to only one reusable GunnAire pricebook record. Choose the authoritative local record; the others stay local and return to the publication queue with no QuickBooks changes.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            ForEach(catalogMappingConflicts) { conflict in
                                VStack(alignment: .leading, spacing: 10) {
                                    Label("QBO \(conflict.quickBooksID)", systemImage: "link.badge.plus")
                                        .font(.headline)
                                    Text("Linked to \(conflict.localItems.count) GunnAire items")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)

                                    ForEach(conflict.localItems) { item in
                                        HStack(alignment: .center, spacing: 12) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(item.name)
                                                    .font(.subheadline.weight(.semibold))
                                                Text(item.unitPrice.formatted(.currency(code: "USD")))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Button("Keep This Mapping") {
                                                catalogMappingResolutionCandidateID = item.id
                                            }
                                            .buttonStyle(.bordered)
                                            .accessibilityIdentifier("KeepCatalogMapping-\(item.id.uuidString)")
                                        }
                                    }
                                }
                                .padding(.vertical, 5)
                            }
                        }
                    }

                    if !catalogReconciliationEntries.isEmpty {
                        Section(
                            header: Text("Catalog Reconciliation")
                                .foregroundColor(Color.brandGold)
                                .accessibilityIdentifier("QuickBooksCatalogReconciliationQueue")
                        ) {
                            Text("Review the live QuickBooks version before choosing a direction. GunnAire never overwrites a linked accounting item silently.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            DisclosureGroup(isExpanded: $showCatalogReconciliationQueue) {
                                ForEach(catalogReconciliationEntries) { entry in
                                    VStack(alignment: .leading, spacing: 10) {
                                        HStack(alignment: .firstTextBaseline) {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(entry.localItem.name)
                                                    .font(.headline)
                                                Text("QBO \(entry.remoteItem.Id) • \(entry.differences.count) changed \(entry.differences.count == 1 ? "field" : "fields")")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            if entry.localItem.needsQuickBooksAttention {
                                                Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
                                                    .font(.caption2.weight(.semibold))
                                                    .foregroundStyle(.orange)
                                            }
                                        }

                                        ForEach(entry.differences) { difference in
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(difference.field)
                                                    .font(.caption.weight(.semibold))
                                                HStack(alignment: .top, spacing: 12) {
                                                    reconciliationValue(
                                                        label: "GunnAire",
                                                        value: difference.gunnAireValue
                                                    )
                                                    reconciliationValue(
                                                        label: "QuickBooks",
                                                        value: difference.quickBooksValue
                                                    )
                                                }
                                            }
                                        }

                                        if !QuickBooksCatalogReconciliation.canPublish(
                                            localItem: entry.localItem,
                                            currentRemoteItem: entry.remoteItem
                                        ), let reason = catalogPublishBlockedReason(for: entry) {
                                            Label(reason, systemImage: "lock.trianglebadge.exclamationmark")
                                                .font(.caption)
                                                .foregroundStyle(.orange)
                                        }

                                        ViewThatFits(in: .horizontal) {
                                            HStack {
                                                catalogReconciliationButtons(for: entry)
                                            }
                                            VStack(alignment: .leading) {
                                                catalogReconciliationButtons(for: entry)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 5)
                                }
                            } label: {
                                Label(
                                    "Review \(catalogReconciliationEntries.count) staged \(catalogReconciliationEntries.count == 1 ? "item" : "items")",
                                    systemImage: "arrow.left.arrow.right.square"
                                )
                            }
                        }
                    }

                    Section(header: Text("Pricebook Review").foregroundColor(Color.brandGold)) {
                        if pendingPricebookReviewItems.isEmpty {
                            Label("No field-created catalog items need review.", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Text("Field-created items can remain on their originating job, but only an administrator can promote them to the reusable company catalog and QuickBooks.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            ForEach(pendingPricebookReviewItems) { item in
                                pricebookReviewRow(for: item)
                            }
                        }
                    }

                    Section(header: Text("Customers").foregroundColor(Color.brandGold)) {
                        DisclosureGroup("Customers (\(customers.count))", isExpanded: $showCustomersList) {
                            if customers.isEmpty {
                                emptyState("No QuickBooks customers loaded.")
                            } else {
                                TextField("Search customers", text: $customerSearchText)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                ForEach(filteredCustomers) { customer in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(customer.DisplayName)
                                            .font(.headline)
                                        if let email = customer.PrimaryEmailAddr?.Address, !email.isEmpty {
                                            Text(email)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        if let phone = customer.PrimaryPhone?.FreeFormNumber, !phone.isEmpty {
                                            Text(phone)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        if let linkedCustomer = localCustomer(for: customer) {
                                            HStack {
                                                Button("Open Customer") {
                                                    GunnAireAppIntentRouter.storeCustomerRoute(linkedCustomer.id)
                                                }
                                                .buttonStyle(.bordered)

                                                if let nextCall = serviceCalls
                                                    .filter({ $0.customer.id == linkedCustomer.id && $0.status != .completed && $0.status != .cancelled })
                                                    .sorted(by: { $0.scheduledDate < $1.scheduledDate })
                                                    .first {
                                                    Button("Open Job") {
                                                        GunnAireAppIntentRouter.storeDocumentationRoute(nextCall.id)
                                                    }
                                                    .buttonStyle(.bordered)
                                                }
                                            }
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }

                        Button("Add Customer") { showingNewCustomerSheet = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .disabled(!isAuthenticated)
                    }

                    Section(header: Text("Product Catalog").foregroundColor(Color.brandGold)) {
                        DisclosureGroup("Product Catalog (\(items.count))", isExpanded: $showCatalogList) {
                            if items.isEmpty {
                                emptyState("No QuickBooks products or services loaded.")
                            } else {
                                TextField("Search catalog", text: $catalogSearchText)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                ForEach(filteredItems) { item in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(item.Name)
                                                .font(.headline)
                                            if let description = item.Description, !description.isEmpty {
                                                Text(description)
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                            }
                                            let meta = [
                                                item.Sku.map { "SKU \($0)" },
                                                item.PrefVendorRef?.displayName,
                                                item.PurchaseCost.map { "Cost \($0.formatted(.currency(code: "USD")))" }
                                            ]
                                            .compactMap { value in
                                                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                                                return trimmed?.isEmpty == false ? trimmed : nil
                                            }
                                            if !meta.isEmpty {
                                                Text(meta.joined(separator: " • "))
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                            }
                                            Text(item.ItemType ?? "Unknown")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        if let price = item.UnitPrice {
                                            Text(price, format: .currency(code: "USD"))
                                                .font(.subheadline)
                                        }
                                        if let localItem = localCatalogItem(for: item) {
                                            Button {
                                                catalogItemBeingEdited = localItem
                                            } label: {
                                                Image(systemName: "pencil")
                                            }
                                            .buttonStyle(.bordered)
                                            .accessibilityLabel("Edit \(item.Name)")
                                            .accessibilityHint("Stages reviewed GunnAire pricebook changes before any QuickBooks update.")
                                        }
                                    }
                                }
                            }
                        }

                        Button("Add Catalog Item") { showingNewCatalogItemSheet = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .disabled(!isAuthenticated)
                    }

                    Section(header: Text("Estimates").foregroundColor(Color.brandGold)) {
                        DisclosureGroup("Estimates (\(estimates.count))", isExpanded: $showEstimatesList) {
                            if estimates.isEmpty {
                                emptyState("No QuickBooks estimates loaded.")
                            } else {
                                TextField("Search estimates", text: $estimateSearchText)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                ForEach(filteredEstimates) { estimate in
                                    VStack(alignment: .leading, spacing: 6) {
                                        transactionBlock(
                                            title: estimate.DocNumber ?? estimate.Id,
                                            name: estimate.CustomerRef.displayName,
                                            amount: estimate.TotalAmt,
                                            dateText: estimate.TxnDate
                                        )

                                        if let emailStatus = estimate.EmailStatus, !emailStatus.isEmpty {
                                            Text("Email: \(emailStatus)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }

                                        Button(activeEmailEstimateID == estimate.Id ? "Sending..." : "Email Estimate") {
                                            sendEstimateEmail(estimate)
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(activeEmailEstimateID != nil || estimateEmailAddress(for: estimate) == nil)
                                    }
                                }
                            }
                        }

                        Button("Create Estimate") { showingNewEstimateSheet = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .disabled(!isAuthenticated || customers.isEmpty)
                    }

                    Section(header: Text("Invoices").foregroundColor(Color.brandGold)) {
                        DisclosureGroup("Invoices (\(invoices.count))", isExpanded: $showInvoicesList) {
                            if invoices.isEmpty {
                                emptyState("No QuickBooks invoices loaded.")
                            } else {
                                TextField("Search invoices", text: $invoiceSearchText)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                ForEach(filteredInvoices) { invoice in
                                    VStack(alignment: .leading, spacing: 6) {
                                        transactionBlock(
                                            title: invoice.DocNumber ?? invoice.Id,
                                            name: invoice.CustomerRef.displayName,
                                            amount: invoice.TotalAmt,
                                            dateText: invoice.TxnDate
                                        )

                                        Text("Balance due: \(outstandingQuickBooksBalance(for: invoice), format: .currency(code: "USD"))")
                                            .font(.caption)
                                            .foregroundColor(.secondary)

                                        if let dueDate = invoice.DueDate {
                                            Text("Due: \(dueDate)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }

                                        if let emailStatus = invoice.EmailStatus, !emailStatus.isEmpty {
                                            Text("Email: \(emailStatus)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }

                                        HStack {
                                            Button(activePaymentInvoiceID == invoice.Id ? "Processing..." : "Record QB Payment") {
                                                takeLiveCustomerPayment(for: invoice)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .tint(Color.brandGold)
                                            .foregroundStyle(Color.primaryBlack)
                                            .disabled(activePaymentInvoiceID != nil || outstandingQuickBooksBalance(for: invoice) <= 0)

                                            if let invoiceURL = liveInvoiceURL(for: invoice) {
                                                Link("Open in QuickBooks", destination: invoiceURL)
                                                    .font(.caption)
                                            }

                                            Button(activeEmailInvoiceID == invoice.Id ? "Sending..." : "Email Invoice") {
                                                sendInvoiceEmail(invoice)
                                            }
                                            .buttonStyle(.bordered)
                                            .disabled(activeEmailInvoiceID != nil || invoiceEmailAddress(for: invoice) == nil)

                                            if let localInvoice = localInvoice(for: invoice) {
                                                Button("Open Local Collections") {
                                                    GunnAireAppIntentRouter.storePaymentCollectionRoute(localInvoice.id)
                                                }
                                                .buttonStyle(.bordered)
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Button("Create Invoice") { showingNewInvoiceSheet = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .disabled(!isAuthenticated || customers.isEmpty)
                    }

                    Section(header: Text("Sales Receipts").foregroundColor(Color.brandGold)) {
                        if salesReceipts.isEmpty {
                            emptyState("No QuickBooks sales receipts loaded.")
                        } else {
                            ForEach(salesReceipts) { salesReceipt in
                                VStack(alignment: .leading, spacing: 6) {
                                    transactionBlock(
                                        title: salesReceipt.DocNumber ?? salesReceipt.Id,
                                        name: salesReceipt.CustomerRef?.displayName ?? "Walk-in customer",
                                        amount: salesReceipt.TotalAmt,
                                        dateText: salesReceipt.TxnDate
                                    )

                                    if let paymentMethod = salesReceipt.PaymentMethodRef?.displayName,
                                       !paymentMethod.isEmpty {
                                        Text("Payment method: \(paymentMethod)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }

                        Text("Use Sales Receipts only for walk-in or no-invoice sales. Invoice collections must use a QuickBooks Payment linked to the invoice.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button("Create Walk-In / No-Invoice Sale") { showingNewSalesReceiptSheet = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .disabled(!isAuthenticated || customers.isEmpty)
                    }
                    }

                    if selectedWorkspace == .expenses {
                    Section(header: Text("Bills").foregroundColor(Color.brandGold)) {
                        if bills.isEmpty {
                            emptyState("No QuickBooks bills loaded.")
                        } else {
                            ForEach(bills) { bill in
                                transactionBlock(
                                    title: bill.DocNumber ?? bill.Id,
                                    name: bill.VendorRef.displayName,
                                    amount: bill.TotalAmt,
                                    dateText: bill.DueDate ?? bill.TxnDate
                                )
                            }
                        }

                        Button("Create Bill") { showingNewBillSheet = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .disabled(!isAuthenticated || vendors.isEmpty)
                    }

                    Section(header: Text("Purchases").foregroundColor(Color.brandGold)) {
                        if purchases.isEmpty {
                            emptyState("No QuickBooks purchases loaded.")
                        } else {
                            ForEach(purchases) { purchase in
                                VStack(alignment: .leading, spacing: 6) {
                                    transactionBlock(
                                        title: purchase.Id,
                                        name: purchase.EntityRef?.displayName ?? "Expense purchase",
                                        amount: purchase.TotalAmt,
                                        dateText: purchase.TxnDate
                                    )
                                    if let paymentType = purchase.PaymentType, !paymentType.isEmpty {
                                        Text("Payment type: \(paymentType)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }

                        Button("Create Purchase") { showingNewPurchaseSheet = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .disabled(!isAuthenticated || vendors.isEmpty)
                    }

                    Section(header: Text("Vendor Credits").foregroundColor(Color.brandGold)) {
                        if vendorCredits.isEmpty {
                            emptyState("No QuickBooks vendor credits loaded.")
                        } else {
                            ForEach(vendorCredits) { vendorCredit in
                                transactionBlock(
                                    title: vendorCredit.DocNumber ?? vendorCredit.Id,
                                    name: vendorCredit.VendorRef.displayName,
                                    amount: vendorCredit.TotalAmt,
                                    dateText: vendorCredit.TxnDate
                                )
                            }
                        }

                        Text("Create supplier-return credits from Receipts & Bills → Purchasing after the received credit memo matches the return evidence. This list is read-only so ad hoc credits cannot bypass review.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section(header: Text("Vendors").foregroundColor(Color.brandGold)) {
                        if vendors.isEmpty {
                            emptyState("No QuickBooks vendors loaded.")
                        } else {
                            ForEach(vendors) { vendor in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(vendor.DisplayName)
                                        .font(.headline)
                                    if let email = vendor.PrimaryEmailAddr?.Address, !email.isEmpty {
                                        Text(email)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    if let phone = vendor.PrimaryPhone?.FreeFormNumber, !phone.isEmpty {
                                        Text(phone)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }

                        Button("Add Vendor") { showingNewVendorSheet = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .disabled(!isAuthenticated)
                    }
                    }

                    if selectedWorkspace == .payments {
                    Section(header: Text("Payments").foregroundColor(Color.brandGold)) {
                        if payments.isEmpty {
                            emptyState("No QuickBooks payments loaded.")
                        } else {
                            ForEach(payments) { payment in
                                VStack(alignment: .leading, spacing: 6) {
                                    transactionBlock(
                                        title: payment.Id,
                                        name: payment.CustomerRef?.displayName ?? "Unapplied payment",
                                        amount: payment.TotalAmt,
                                        dateText: payment.TxnDate
                                    )

                                    if let paymentMethod = payment.PaymentMethodRef?.displayName,
                                       !paymentMethod.isEmpty {
                                        Text("Payment method: \(paymentMethod)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }

                        Button("Record Payment") { showingNewPaymentSheet = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .disabled(!isAuthenticated || collectibleQuickBooksInvoices.isEmpty)
                    }

                    Section(header: Text("Payment Methods").foregroundColor(Color.brandGold)) {
                        if paymentMethods.isEmpty {
                            emptyState("No QuickBooks payment methods loaded.")
                        } else {
                            ForEach(paymentMethods) { method in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(method.Name)
                                        .font(.headline)
                                    Text(method.methodType ?? "Unspecified")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(method.Active == false ? "Inactive" : "Active")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }

                        Button("Ensure Card and ACH Methods") {
                            ensureStandardPaymentMethods()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.brandGold)
                        .foregroundStyle(Color.primaryBlack)
                        .disabled(!isAuthenticated || (hasQuickBooksCardMethod && hasQuickBooksACHMethod))
                    }

                    Section(header: Text("Deposits").foregroundColor(Color.brandGold)) {
                        if deposits.isEmpty {
                            emptyState("No QuickBooks deposits loaded.")
                        } else {
                            ForEach(deposits) { deposit in
                                VStack(alignment: .leading, spacing: 6) {
                                    transactionBlock(
                                        title: deposit.Id,
                                        name: deposit.DepositToAccountRef?.displayName ?? "Undeposited Funds",
                                        amount: deposit.TotalAmt,
                                        dateText: deposit.TxnDate
                                    )

                                    if let note = deposit.PrivateNote, !note.isEmpty {
                                        Text(note)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }

                    Section(header: Text("QuickBooks Payments API").foregroundColor(Color.brandGold)) {
                        HStack {
                            Text("Connected local charges")
                            Spacer()
                            Text("\(quickBooksChargePayments.filter { !$0.isRefund }.count)")
                                .foregroundColor(.secondary)
                        }
                        HStack {
                            Text("Recorded refunds")
                            Spacer()
                            Text("\(quickBooksChargePayments.filter(\.isRefund).count)")
                                .foregroundColor(.secondary)
                        }
                        HStack {
                            Text("Linked payment methods")
                            Spacer()
                            Text("\(linkedStoredPaymentMethodCount)")
                                .foregroundColor(.secondary)
                        }

                        Button("Process Card Charge") {
                            showingProcessCardPaymentSheet = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.brandGold)
                        .foregroundStyle(Color.primaryBlack)
                        .disabled(!quickBooksPaymentsEnabled || collectibleLocalInvoices.isEmpty)

                        Button("Store Card") {
                            showingStoreCardSheet = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.brandGold)
                        .foregroundStyle(Color.primaryBlack)
                        .disabled(!quickBooksPaymentsEnabled || customers.isEmpty)

                        Text("QuickBooks holds the payment credentials. GunnAire stores only the customer link, card brand, last four digits, and expiration for operational readiness.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if !customersWithStoredPaymentMethods.isEmpty {
                            DisclosureGroup("Linked customer payment methods") {
                                ForEach(customersWithStoredPaymentMethods.prefix(10)) { customer in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(customer.name)
                                            .font(.headline)
                                        ForEach(customer.activeStoredPaymentMethods) { method in
                                            HStack {
                                                Text(method.displayLabel)
                                                Spacer()
                                                if let expirationLabel = method.expirationLabel {
                                                    Text(expirationLabel)
                                                        .foregroundColor(.secondary)
                                                }
                                            }
                                            .font(.caption)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                            .accessibilityIdentifier("QuickBooksLinkedPaymentMethods")
                        }

                        if storedCards.isEmpty {
                            Text("No stored QuickBooks payment cards loaded.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(storedCards.prefix(10)) { card in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(card.safeDisplayLabel)
                                        .font(.headline)
                                    if let name = card.name, !name.isEmpty {
                                        Text(name)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }

                        if quickBooksChargePayments.isEmpty {
                            Text("No local QuickBooks Payments charges have been processed yet.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(quickBooksChargePayments.prefix(10)) { payment in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(payment.invoice.customer.name)
                                        .font(.headline)
                                    Text(payment.isRefund ? "Refund" : "Charge")
                                        .font(.caption)
                                        .foregroundColor(payment.isRefund ? .red : .secondary)
                                    Text(payment.amount, format: .currency(code: "USD"))
                                        .font(.subheadline)
                                    if let chargeID = payment.quickBooksChargeID, !chargeID.isEmpty {
                                        Text("Charge ID: \(chargeID)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    if let accountingID = payment.quickBooksID, !accountingID.isEmpty {
                                        Text("Accounting payment ID: \(accountingID)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    if let refundReceiptID = payment.quickBooksRefundReceiptID, !refundReceiptID.isEmpty {
                                        Text("Refund receipt ID: \(refundReceiptID)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    if let chargeID = payment.quickBooksChargeID,
                                       let receipt = paymentReceipts[chargeID] {
                                        if let amount = receipt.amount, !amount.isEmpty {
                                            Text("Receipt amount: \(amount)")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        if let link = receipt.links?.first(where: { ($0.rel ?? "").localizedCaseInsensitiveContains("receipt") || ($0.rel ?? "").localizedCaseInsensitiveContains("self") }),
                                           let href = link.href,
                                           let url = URL(string: href) {
                                            Link("Open Payment Receipt", destination: url)
                                                .font(.caption2)
                                        }
                                    } else if payment.quickBooksChargeID?.isEmpty == false {
                                        Button("Load Payment Receipt") {
                                            loadPaymentReceipt(for: payment)
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(!quickBooksPaymentsEnabled)
                                    }
                                    if payment.needsQuickBooksAttention,
                                       let detail = payment.quickBooksAccountingSyncDetail,
                                       !detail.isEmpty {
                                        Text("Needs follow-up: \(detail)")
                                            .font(.caption2)
                                            .foregroundColor(.orange)
                                    }
                                    if payment.needsQuickBooksAttention {
                                        Button("Retry QuickBooks Sync") {
                                            retryQuickBooksFollowUp(for: payment)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(Color.brandGold)
                                        .foregroundStyle(Color.primaryBlack)
                                    }
                                    if !payment.isRefund, payment.amount > 0 {
                                        Button("Refund This Payment") {
                                            paymentToRefund = payment
                                            showingRefundPaymentSheet = true
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(!quickBooksPaymentsEnabled)
                                    }
                                    HStack {
                                        Button("Open Customer") {
                                            GunnAireAppIntentRouter.storeCustomerRoute(payment.invoice.customer.id)
                                        }
                                        .buttonStyle(.bordered)

                                        if let linkedCall = localServiceCall(for: payment.invoice) {
                                            Button("Open Job") {
                                                GunnAireAppIntentRouter.storeDocumentationRoute(linkedCall.id)
                                            }
                                            .buttonStyle(.bordered)
                                        }

                                        Button("Open Collections") {
                                            GunnAireAppIntentRouter.storePaymentCollectionRoute(payment.invoice.id)
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    }

                    if selectedWorkspace == .overview {
                    Section(header: Text("Sync Status").foregroundColor(Color.brandGold)) {
                        if isLoading {
                            ProgressView()
                        }
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if let actionMessage {
                            Text(actionMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Button("Sync All QuickBooks Data") {
                            syncAllQuickBooksData()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.brandGold)
                        .foregroundStyle(Color.primaryBlack)
                        .disabled(isLoading || !isAuthenticated || !quickBooksConfigReady)
                    }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.primaryBlack)
                .navigationTitle("QuickBooks Management")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            syncAllQuickBooksData()
                        } label: {
                            Label(isLoading ? "Syncing" : "Sync", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(isLoading || !isAuthenticated || !quickBooksConfigReady)
                        .accessibilityHint("Refreshes all supported QuickBooks resources for the connected company realm.")
                    }
                }
                .sheet(isPresented: $showingNewCustomerSheet) {
                    QuickBooksCustomerComposeView { name, email, phone in
                        createCustomer(name: name, email: email, phone: phone)
                    }
                    .tint(Color.brandGold)
                }
                .sheet(isPresented: $showingAccountingMappingSheet) {
                    if let realmID = accountingConfigurationRealmID {
                        QuickBooksAccountingMappingView(
                            realmID: realmID,
                            environment: quickBooksDataAPI.currentEnvironment,
                            items: items,
                            accounts: accounts,
                            existingConfiguration: accountingConfiguration
                        ) { candidate in
                            #if DEBUG
                            if accountingMappingFixtureRequested {
                                accountingConfigurationStore.installFixture(candidate)
                                return
                            }
                            #endif
                            _ = try await accountingConfigurationStore.save(
                                candidate,
                                realmID: realmID,
                                environment: quickBooksDataAPI.currentEnvironment
                            )
                        }
                    } else {
                        ContentUnavailableView(
                            "Connect QuickBooks",
                            systemImage: "link.badge.plus",
                            description: Text("Connect the approved QuickBooks company before choosing accounting mappings.")
                        )
                    }
                }
                .sheet(isPresented: $showingNewCatalogItemSheet) {
                    QuickBooksCatalogItemComposeView(vendors: vendors) { draft in
                        createCatalogItem(draft)
                    }
                    .tint(Color.brandGold)
                }
                .sheet(item: $catalogItemBeingEdited) { item in
                    QuickBooksLocalCatalogItemEditView(
                        item: item,
                        catalogItems: localCatalogItems,
                        vendors: vendors
                    ) {
                        do {
                            try modelContext.save()
                            if item.requiresPricebookReview {
                                actionMessage = "Updated \(item.name). Review the final details, then approve it for the company pricebook and QuickBooks."
                            } else if item.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                                actionMessage = "Updated \(item.name). QuickBooks publication remains pending."
                                showCatalogPublicationQueue = true
                            } else {
                                actionMessage = "Staged \(item.name) for QuickBooks catalog review. Choose a direction in Catalog Reconciliation."
                                showCatalogReconciliationQueue = true
                            }
                        } catch {
                            actionMessage = "Could not stage \(item.name): \(error.localizedDescription)"
                        }
                    }
                    .tint(Color.brandGold)
                }
                .sheet(isPresented: $showingNewEstimateSheet) {
                    QuickBooksEstimateComposeView(customers: customers) { customer, amount, note, email, sendAfterCreate in
                        createEstimate(
                            customer: customer,
                            amount: amount,
                            note: note,
                            emailAddress: email,
                            sendAfterCreate: sendAfterCreate
                        )
                    }
                    .tint(Color.brandGold)
                }
                .sheet(isPresented: $showingNewInvoiceSheet) {
                    QuickBooksInvoiceComposeView(customers: customers) { customer, amount, note, email, sendAfterCreate in
                        createInvoice(
                            customer: customer,
                            amount: amount,
                            note: note,
                            emailAddress: email,
                            sendAfterCreate: sendAfterCreate
                        )
                    }
                    .tint(Color.brandGold)
                }
                .sheet(isPresented: $showingNewSalesReceiptSheet) {
                    QuickBooksDocumentComposeView(
                        title: "Create Walk-In / No-Invoice Sale",
                        customerRefs: customers.map(\.reference)
                    ) { customerRef, amount, note in
                        createSalesReceipt(customerRef: customerRef, amount: amount, note: note)
                    }
                    .tint(Color.brandGold)
                }
                .sheet(isPresented: $showingNewBillSheet) {
                    QuickBooksBillComposeView(
                        vendorRefs: vendors.map(\.reference)
                    ) { vendorRef, amount, note in
                        createBill(vendorRef: vendorRef, amount: amount, note: note)
                    }
                    .tint(Color.brandGold)
                }
                .sheet(isPresented: $showingNewPurchaseSheet) {
                    QuickBooksPurchaseComposeView(vendorRefs: vendors.map(\.reference)) { vendorRef, amount, note, paymentType in
                        createPurchase(vendorRef: vendorRef, amount: amount, note: note, paymentType: paymentType)
                    }
                    .tint(Color.brandGold)
                }
                .sheet(isPresented: $showingNewVendorSheet) {
                    QuickBooksVendorComposeView { name, email, phone in
                        createVendor(name: name, email: email, phone: phone)
                    }
                    .tint(Color.brandGold)
                }
                .sheet(isPresented: $showingNewPaymentSheet) {
                    QuickBooksPaymentComposeView(
                        invoices: collectibleQuickBooksInvoices,
                        paymentMethods: paymentMethods
                    ) { invoice, amount, note, paymentMethodRef in
                        createPayment(for: invoice, amount: amount, note: note, paymentMethodRef: paymentMethodRef)
                    }
                    .tint(Color.brandGold)
                }
                .sheet(isPresented: $showingProcessCardPaymentSheet) {
                    QuickBooksCardChargeComposeView(
                        invoices: collectibleLocalInvoices,
                        payments: localPayments
                    ) { invoice, amount, cardInput, note in
                        processCardCharge(for: invoice, amount: amount, cardInput: cardInput, note: note)
                    }
                    .tint(Color.brandGold)
                }
                .sheet(isPresented: $showingRefundPaymentSheet, onDismiss: {
                    paymentToRefund = nil
                }) {
                    if let paymentToRefund {
                        QuickBooksRefundComposeView(payment: paymentToRefund) { amount, note in
                            refundPayment(paymentToRefund, amount: amount, note: note)
                        }
                        .tint(Color.brandGold)
                    }
                }
                .sheet(isPresented: $showingStoreCardSheet) {
                    QuickBooksStoreCardComposeView(customers: customers) { customer, input in
                        storeCard(input, for: customer)
                    }
                    .tint(Color.brandGold)
                }
                .confirmationDialog(
                    "Keep this QuickBooks mapping?",
                    isPresented: Binding(
                        get: { selectedCatalogMappingResolution != nil },
                        set: { if !$0 { catalogMappingResolutionCandidateID = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("Keep QBO Link") {
                        if let selectedCatalogMappingResolution {
                            resolveCatalogMappingConflict(
                                selectedCatalogMappingResolution.conflict,
                                keeping: selectedCatalogMappingResolution.item
                            )
                        }
                    }
                    Button("Cancel", role: .cancel) {
                        catalogMappingResolutionCandidateID = nil
                    }
                } message: {
                    if let selectedCatalogMappingResolution {
                        Text("\(selectedCatalogMappingResolution.item.name) will remain linked to QBO \(selectedCatalogMappingResolution.conflict.quickBooksID). The other GunnAire records keep their prices and descriptions but must be reviewed before separate QuickBooks publication.")
                    }
                }
                .onAppear {
                    if let pendingWorkspace = GunnAireAppIntentRouter.consumePendingQuickBooksWorkspace() {
                        selectedWorkspace = pendingWorkspace
                    }
                    #if DEBUG
                    if catalogReconciliationFixtureRequested {
                        items = Self.catalogReconciliationFixtureItems
                        showCatalogReconciliationQueue = true
                    }
                    if accountingMappingFixtureRequested {
                        items = Self.accountingMappingFixtureItems
                        accounts = Self.accountingMappingFixtureAccounts
                        accountingConfigurationStore.installFixture(Self.accountingMappingFixtureConfiguration)
                    }
                    #endif
                    QuickBooksDataAPI.shared.loadTokens()
                    #if DEBUG
                    if catalogReconciliationFixtureRequested || accountingMappingFixtureRequested {
                        statusMessage = accountingMappingFixtureRequested
                            ? "Accounting mapping preview loaded."
                            : "Catalog reconciliation preview loaded."
                        return
                    }
                    #endif
                    Task { await loadQuickBooksWebhookEvents() }
                    Task {
                        await accountingConfigurationStore.refresh(
                            realmID: accountingConfigurationRealmID,
                            environment: quickBooksDataAPI.currentEnvironment
                        )
                    }
                    if isAuthenticated {
                        syncAllQuickBooksData()
                    } else if !quickBooksConfigReady {
                        statusMessage = "QuickBooks client credentials are missing on this Mac. Add them in Config/Local.xcconfig, then reconnect QuickBooks."
                    } else {
                        statusMessage = "QuickBooks is not connected. Open Settings to authenticate."
                    }
                }
            }
        }
    }

    private func syncAllQuickBooksData() {
        guard isAuthenticated else {
            statusMessage = quickBooksConfigReady
                ? "QuickBooks is not connected. Open Settings to authenticate."
                : "QuickBooks client credentials are missing on this Mac. Add them in Config/Local.xcconfig, then reconnect QuickBooks."
            return
        }

        isLoading = true
        actionMessage = nil
        quickBooksReconnectRequired = false
        lastSyncStartedAt = Date()
        activeSyncWebhookEventIDs = Set(quickBooksWebhookEvents.map(\.id))
        resetSyncStatusesForRun()
        statusMessage = "Syncing customers, catalog, accounts, estimates, invoices, sales receipts, bills, purchases, vendors, payments, payment methods, stored cards, and deposits from QuickBooks..."

        QuickBooksDataAPI.shared.refreshTokensIfNeeded { tokenReady in
            guard tokenReady else {
                let detail = QuickBooksDataAPI.shared.lastRefreshFailureDetail
                    ?? "Reconnect QuickBooks. The saved token could not be refreshed."
                isLoading = false
                quickBooksReconnectRequired = true
                markAllSyncStatusesFailed(detail)
                statusMessage = "QuickBooks reconnect required. \(detail)"
                return
            }

            runQuickBooksResourceSync()
        }
    }

    private func runQuickBooksResourceSync() {
        Task { @MainActor in
            var failures: [String] = []

            @MainActor
            func run<T>(
                id: String,
                required: Bool,
                fetch: (@escaping (Result<[T], Error>) -> Void) -> Void,
                apply: @escaping ([T]) -> Void
            ) async -> Bool {
                guard !quickBooksReconnectRequired else {
                    return false
                }

                updateSyncStatus(id: id, state: .syncing, detail: "Loading...", count: nil)
                let result: Result<[T], Error> = await withCheckedContinuation { continuation in
                    fetch { result in
                        DispatchQueue.main.async {
                            continuation.resume(returning: result)
                        }
                    }
                }

                switch result {
                case .success(let records):
                    apply(records)
                    updateSyncStatus(id: id, state: .success, detail: "Loaded \(records.count) records.", count: records.count)
                    return true
                case .failure(let error):
                    let message = userFacingQuickBooksMessage(for: error)
                    if let qbError = error as? QuickBooksDataAPI.QBError,
                       qbError.requiresReconnect {
                        quickBooksReconnectRequired = true
                        updateSyncStatus(id: id, state: .failed, detail: message, count: nil)
                        markPendingSyncStatusesFailed("Reconnect QuickBooks. The saved QuickBooks session was rejected before this resource could sync.")
                    } else {
                        updateSyncStatus(id: id, state: required ? .failed : .warning, detail: message, count: nil)
                    }
                    let prefix = syncResourceStatuses.first(where: { $0.id == id })?.name ?? id
                    failures.append("\(prefix): \(message)")
                    return !quickBooksReconnectRequired
                }
            }

            guard await run(id: "customers", required: true, fetch: liveAPI.fetchCustomers, apply: { records in
                customers = records.sorted { $0.DisplayName.localizedCaseInsensitiveCompare($1.DisplayName) == .orderedAscending }
            }) else { finishQuickBooksResourceSync(with: failures); return }

            guard await run(id: "catalog", required: true, fetch: liveAPI.fetchItems, apply: { records in
                items = records.sorted { $0.Name.localizedCaseInsensitiveCompare($1.Name) == .orderedAscending }
            }) else { finishQuickBooksResourceSync(with: failures); return }

            guard await run(id: "accounts", required: true, fetch: { completion in
                quickBooksDataAPI.fetchAccounts(completion: completion)
            }, apply: { records in
                accounts = records.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            }) else { finishQuickBooksResourceSync(with: failures); return }

            await accountingConfigurationStore.refresh(
                realmID: accountingConfigurationRealmID,
                environment: quickBooksDataAPI.currentEnvironment,
                force: true
            )
            if accountingConfiguration != nil {
                updateSyncStatus(
                    id: "mappings",
                    state: .success,
                    detail: "Loaded realm-specific accounting defaults.",
                    count: 6
                )
            } else {
                updateSyncStatus(
                    id: "mappings",
                    state: .warning,
                    detail: accountingConfigurationStore.statusMessage
                        ?? "An administrator must choose accounting defaults for this company.",
                    count: 0
                )
            }

            guard await run(id: "estimates", required: true, fetch: liveAPI.fetchEstimates, apply: { records in estimates = records }) else { finishQuickBooksResourceSync(with: failures); return }
            guard await run(id: "invoices", required: true, fetch: liveAPI.fetchInvoices, apply: { records in invoices = records }) else { finishQuickBooksResourceSync(with: failures); return }
            guard await run(id: "bills", required: true, fetch: liveAPI.fetchBills, apply: { records in bills = records }) else { finishQuickBooksResourceSync(with: failures); return }
            guard await run(id: "vendorCredits", required: true, fetch: liveAPI.fetchVendorCredits, apply: { records in vendorCredits = records }) else { finishQuickBooksResourceSync(with: failures); return }
            guard await run(id: "purchases", required: true, fetch: liveAPI.fetchPurchases, apply: { records in purchases = records }) else { finishQuickBooksResourceSync(with: failures); return }

            guard await run(id: "vendors", required: true, fetch: liveAPI.fetchVendors, apply: { records in
                vendors = records.sorted { $0.DisplayName.localizedCaseInsensitiveCompare($1.DisplayName) == .orderedAscending }
            }) else { finishQuickBooksResourceSync(with: failures); return }

            guard await run(id: "payments", required: true, fetch: liveAPI.fetchPayments, apply: { records in payments = records }) else { finishQuickBooksResourceSync(with: failures); return }

            guard await run(id: "paymentMethods", required: true, fetch: liveAPI.fetchPaymentMethods, apply: { records in
                paymentMethods = records.sorted { $0.Name.localizedCaseInsensitiveCompare($1.Name) == .orderedAscending }
            }) else { finishQuickBooksResourceSync(with: failures); return }

            if QuickBooksDataAPI.shared.canUseQuickBooksPaymentsAPI {
                guard await run(id: "storedCards", required: false, fetch: { completion in
                    liveAPI.fetchCards(forCustomerIDs: customers.map(\.Id), completion: completion)
                }, apply: { records in
                    storedCards = records
                    reconcileStoredPaymentMethodReferences(records)
                }) else { finishQuickBooksResourceSync(with: failures); return }
            } else if Config.QuickBooks.enablePaymentsScope {
                storedCards = []
                updateSyncStatus(
                    id: "storedCards",
                    state: .warning,
                    detail: "Skipped because this QuickBooks token is not authorized for \(Config.QuickBooks.paymentsScope). Accounting sync remains active.",
                    count: 0
                )
            } else {
                updateSyncStatus(
                    id: "storedCards",
                    state: .warning,
                    detail: "Skipped because QB_ENABLE_PAYMENTS_SCOPE is off for Accounting-only login.",
                    count: 0
                )
            }

            guard await run(id: "salesReceipts", required: true, fetch: liveAPI.fetchSalesReceipts, apply: { records in salesReceipts = records }) else { finishQuickBooksResourceSync(with: failures); return }
            guard await run(id: "deposits", required: true, fetch: liveAPI.fetchDeposits, apply: { records in deposits = records }) else { finishQuickBooksResourceSync(with: failures); return }

            finishQuickBooksResourceSync(with: failures)
        }
    }

    private func createCustomer(name: String, email: String?, phone: String?) {
        let payload = QuickBooksCustomerCreate(
            DisplayName: name,
            PrimaryPhone: phone.map { QuickBooksPhoneNumber(FreeFormNumber: $0) },
            PrimaryEmailAddr: email.map { QuickBooksEmailAddress(Address: $0) },
            BillAddr: nil
        )

        performAction(message: "Creating customer in QuickBooks...") {
            liveAPI.createCustomer(payload) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let customer):
                        actionMessage = "Customer created: \(customer.DisplayName)"
                        syncAllQuickBooksData()
                    case .failure(let error):
                        actionMessage = "Customer creation failed: \(error.localizedDescription)"
                        isLoading = false
                    }
                }
            }
        }
    }

    private func createCatalogItem(_ draft: QuickBooksCatalogItemDraft) {
        guard let incomeAccountRef = QuickBooksItemAccountResolver.incomeAccountRef(
            from: items,
            configuration: accountingConfiguration
        ) else {
            actionMessage = "Open Overview → Accounting Mappings and choose an income account before creating catalog items."
            return
        }

        let payload = QuickBooksItemCreate(
            Name: draft.name,
            ItemType: draft.itemType.rawValue,
            Description: draft.description,
            Sku: draft.sku,
            PurchaseDesc: draft.purchaseDescription ?? draft.description,
            UnitPrice: draft.price,
            PurchaseCost: draft.purchaseCost,
            Taxable: nil,
            IncomeAccountRef: incomeAccountRef,
            ExpenseAccountRef: QuickBooksItemAccountResolver.configuredExpenseAccountRef(
                configuration: accountingConfiguration
            ),
            PrefVendorRef: draft.vendorRef
        )

        performAction(message: "Creating catalog item in QuickBooks...") {
            liveAPI.createItem(payload) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let item):
                        actionMessage = "Catalog item created: \(item.Name)"
                        syncAllQuickBooksData()
                    case .failure(let error):
                        actionMessage = "Catalog item creation failed: \(error.localizedDescription)"
                        isLoading = false
                    }
                }
            }
        }
    }

    private func approvePricebookItem(_ item: Item) {
        let reviewerEmail = AppIdentity.currentEmail
        item.approveForPricebook(by: reviewerEmail)
        activePricebookReviewID = item.id
        do {
            try modelContext.save()
        } catch {
            activePricebookReviewID = nil
            actionMessage = "Could not save the pricebook approval: \(error.localizedDescription)"
            return
        }

        guard isAuthenticated else {
            activePricebookReviewID = nil
            actionMessage = "\(item.name) is approved for the company pricebook. Connect QuickBooks to publish it."
            return
        }

        publishApprovedCatalogItem(item)
    }

    private func retryCatalogPublication(_ item: Item) {
        guard !item.requiresPricebookReview,
              item.quickBooksCatalogSyncState != "synced" else { return }

        activeCatalogPublicationID = item.id
        item.quickBooksSyncStatus = "pending"
        item.quickBooksSyncDetail = "QuickBooks publication retry is in progress."
        do {
            try modelContext.save()
        } catch {
            activeCatalogPublicationID = nil
            actionMessage = "Could not save the catalog publication retry: \(error.localizedDescription)"
            return
        }

        guard isAuthenticated else {
            activeCatalogPublicationID = nil
            actionMessage = "Connect QuickBooks before retrying \(item.name)."
            return
        }

        publishApprovedCatalogItem(item)
    }

    private func publishApprovedCatalogItem(_ item: Item) {
        actionMessage = "Approved \(item.name). Checking QuickBooks for an existing match..."
        liveAPI.fetchItems { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    markApprovedPricebookPublicationFailure(item, error: error)
                case .success(let remoteItems):
                    do {
                        if let existing = try PricebookReviewPublication.matchingRemoteItem(for: item, in: remoteItems) {
                            try QuickBooksCatalogMappingIntegrity.validateAssignment(
                                of: existing.Id,
                                to: item,
                                in: localCatalogItems
                            )
                            applyApprovedQuickBooksItem(existing, to: item)
                            finishApprovedPricebookPublication(item, message: "Approved and linked \(item.name) to its existing QuickBooks catalog item.")
                            return
                        }
                    } catch {
                        markApprovedPricebookPublicationFailure(item, error: error)
                        return
                    }
                    createApprovedPricebookItem(item, remoteItems: remoteItems)
                }
            }
        }
    }

    private func createApprovedPricebookItem(_ item: Item, remoteItems: [QuickBooksItem]) {
        guard let incomeAccountRef = QuickBooksItemAccountResolver.incomeAccountRef(
            from: remoteItems,
            configuration: accountingConfiguration
        ) else {
            markApprovedPricebookPublicationFailure(
                item,
                error: QuickBooksDataAPI.QBError.missingDefaultIncomeAccountRef
            )
            return
        }
        let payload = QuickBooksItemCreate(
            Name: item.name,
            ItemType: item.itemType.rawValue,
            Description: item.itemDescription,
            Sku: item.sku,
            PurchaseDesc: item.purchaseDescription ?? item.itemDescription,
            UnitPrice: item.unitPrice,
            PurchaseCost: item.purchaseCost,
            Taxable: item.isTaxable,
            IncomeAccountRef: incomeAccountRef,
            ExpenseAccountRef: QuickBooksItemAccountResolver.configuredExpenseAccountRef(
                configuration: accountingConfiguration
            ),
            PrefVendorRef: item.preferredVendorQuickBooksID.flatMap { quickBooksID in
                quickBooksID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : QuickBooksReference(value: quickBooksID, name: item.preferredVendorName)
            }
        )
        liveAPI.createItem(payload) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    markApprovedPricebookPublicationFailure(item, error: error)
                case .success(let quickBooksItem):
                    applyApprovedQuickBooksItem(quickBooksItem, to: item)
                    finishApprovedPricebookPublication(item, message: "Approved and published \(item.name) to QuickBooks.")
                    syncAllQuickBooksData()
                }
            }
        }
    }

    private func applyApprovedQuickBooksItem(_ quickBooksItem: QuickBooksItem, to item: Item) {
        item.quickBooksID = quickBooksItem.Id.trimmingCharacters(in: .whitespacesAndNewlines)
        item.quickBooksSyncStatus = "synced"
        item.quickBooksSyncDetail = nil
        item.quickBooksLastSyncedAt = Date()
        item.name = quickBooksItem.Name
        item.itemTypeRawValue = quickBooksItem.ItemType ?? item.itemTypeRawValue
        item.unitPrice = quickBooksItem.UnitPrice ?? item.unitPrice
        item.purchaseCost = quickBooksItem.PurchaseCost ?? item.purchaseCost
        item.isTaxable = quickBooksItem.Taxable ?? item.isTaxable
        item.itemDescription = quickBooksItem.Description ?? item.itemDescription
        item.sku = quickBooksItem.Sku ?? item.sku
        item.purchaseDescription = quickBooksItem.PurchaseDesc ?? item.purchaseDescription
        item.preferredVendorName = quickBooksItem.PrefVendorRef?.name ?? item.preferredVendorName
        item.preferredVendorQuickBooksID = quickBooksItem.PrefVendorRef?.value ?? item.preferredVendorQuickBooksID
    }

    private func finishApprovedPricebookPublication(_ item: Item, message: String) {
        activePricebookReviewID = nil
        activeCatalogPublicationID = nil
        do {
            try modelContext.save()
            actionMessage = message
        } catch {
            actionMessage = "QuickBooks accepted \(item.name), but the local catalog link could not be saved: \(error.localizedDescription)"
        }
    }

    private func markApprovedPricebookPublicationFailure(_ item: Item, error: Error) {
        activePricebookReviewID = nil
        activeCatalogPublicationID = nil
        item.quickBooksSyncStatus = "needs_attention"
        item.quickBooksSyncDetail = error.localizedDescription
        item.quickBooksLastSyncedAt = Date()
        try? modelContext.save()
        actionMessage = "\(item.name) is approved locally, but QuickBooks publication needs attention: \(error.localizedDescription)"
    }

    private func createEstimate(
        customer: QuickBooksCustomer,
        amount: Double,
        note: String?,
        emailAddress: String?,
        sendAfterCreate: Bool
    ) {
        guard let salesItemRef = QuickBooksItemAccountResolver.defaultSalesItemRef(
            configuration: accountingConfiguration
        ) else {
            actionMessage = "Open Overview → Accounting Mappings and choose a default sales item before creating estimates."
            return
        }
        let trimmedEmail = emailAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
        let estimateEmail = trimmedEmail?.isEmpty == false ? trimmedEmail : nil
        if sendAfterCreate, estimateEmail == nil {
            actionMessage = "Add an email address before sending this estimate."
            return
        }

        let payload = QuickBooksEstimateCreate(
            CustomerRef: customer.reference,
            Line: [salesLineItem(amount: amount, note: note, itemRef: salesItemRef)],
            PrivateNote: note,
            BillEmail: estimateEmail.map { QuickBooksEmailAddress(Address: $0) },
            GlobalTaxCalculation: "TaxExcluded"
        )

        performAction(message: "Creating estimate in QuickBooks...") {
            liveAPI.createEstimate(payload) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let estimate):
                        if sendAfterCreate {
                            actionMessage = "Estimate created. Sending email..."
                            sendCreatedEstimateEmail(estimate, to: estimateEmail)
                        } else {
                            actionMessage = "Estimate created: \(estimate.DocNumber ?? estimate.Id)"
                            syncAllQuickBooksData()
                        }
                    case .failure(let error):
                        actionMessage = "Estimate creation failed: \(error.localizedDescription)"
                        isLoading = false
                    }
                }
            }
        }
    }

    private func createInvoice(
        customer: QuickBooksCustomer,
        amount: Double,
        note: String?,
        emailAddress: String?,
        sendAfterCreate: Bool
    ) {
        guard let salesItemRef = QuickBooksItemAccountResolver.defaultSalesItemRef(
            configuration: accountingConfiguration
        ) else {
            actionMessage = "Open Overview → Accounting Mappings and choose a default sales item before creating invoices."
            return
        }
        let trimmedEmail = emailAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
        let invoiceEmail = trimmedEmail?.isEmpty == false ? trimmedEmail : nil
        if sendAfterCreate, invoiceEmail == nil {
            actionMessage = "Add an email address before sending this invoice."
            return
        }

        let payload = QuickBooksInvoiceCreate(
            CustomerRef: customer.reference,
            Line: [salesLineItem(amount: amount, note: note, itemRef: salesItemRef)],
            PrivateNote: note,
            BillEmail: invoiceEmail.map { QuickBooksEmailAddress(Address: $0) },
            DueDate: QuickBooksDateOnly.string(from: Date()),
            GlobalTaxCalculation: "TaxExcluded"
        )

        performAction(message: "Creating invoice in QuickBooks...") {
            liveAPI.createInvoice(payload) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let invoice):
                        if sendAfterCreate {
                            actionMessage = "Invoice created. Sending email..."
                            sendCreatedInvoiceEmail(invoice, to: invoiceEmail)
                        } else {
                            actionMessage = "Invoice created: \(invoice.DocNumber ?? invoice.Id)"
                            syncAllQuickBooksData()
                        }
                    case .failure(let error):
                        actionMessage = "Invoice creation failed: \(error.localizedDescription)"
                        isLoading = false
                    }
                }
            }
        }
    }

    private func createSalesReceipt(customerRef: QuickBooksReference, amount: Double, note: String?) {
        guard let salesItemRef = QuickBooksItemAccountResolver.defaultSalesItemRef(
            configuration: accountingConfiguration
        ) else {
            actionMessage = "Open Overview → Accounting Mappings and choose a default sales item before creating sales receipts."
            return
        }

        let payload = QuickBooksSalesReceiptCreate(
            CustomerRef: customerRef,
            Line: [salesLineItem(amount: amount, note: note, itemRef: salesItemRef)],
            PrivateNote: [note, "GunnAire no-invoice sale. Do not use this path for invoice collections."].compactMap { $0 }.joined(separator: "\n"),
            PaymentMethodRef: nil,
            CreditCardPayment: nil
        )

        performAction(message: "Creating sales receipt in QuickBooks...") {
            liveAPI.createSalesReceipt(payload) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let salesReceipt):
                        actionMessage = "Sales receipt created: \(salesReceipt.DocNumber ?? salesReceipt.Id)"
                        syncAllQuickBooksData()
                    case .failure(let error):
                        actionMessage = "Sales receipt creation failed: \(error.localizedDescription)"
                        isLoading = false
                    }
                }
            }
        }
    }

    private func createBill(vendorRef: QuickBooksReference, amount: Double, note: String?) {
        guard let expenseAccount = QuickBooksItemAccountResolver.configuredExpenseAccountRef(
            configuration: accountingConfiguration
        ) else {
            actionMessage = "Open Overview → Accounting Mappings and choose the expense and Accounts Payable accounts before creating bills."
            return
        }
        guard let accountsPayable = accountingConfiguration?.accountsPayableReference,
              !accountsPayable.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            actionMessage = "Open Overview → Accounting Mappings and choose Accounts Payable before creating bills."
            return
        }
        let payload = QuickBooksBillCreate(
            VendorRef: vendorRef,
            APAccountRef: accountsPayable,
            Line: [QuickBooksBillLine(amount: amount, description: note, accountRef: expenseAccount)],
            TxnDate: QuickBooksDateOnly.string(from: Date()),
            DocNumber: nil,
            PrivateNote: note
        )

        performAction(message: "Creating bill in QuickBooks...") {
            liveAPI.createBill(payload) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let bill):
                        actionMessage = "Bill created: \(bill.Id)"
                        syncAllQuickBooksData()
                    case .failure(let error):
                        actionMessage = "Bill creation failed: \(error.localizedDescription)"
                        isLoading = false
                    }
                }
            }
        }
    }

    private func createPurchase(vendorRef: QuickBooksReference, amount: Double, note: String?, paymentType: String) {
        guard let expenseAccount = QuickBooksItemAccountResolver.configuredExpenseAccountRef(
            configuration: accountingConfiguration
        ) else {
            actionMessage = "Open Overview → Accounting Mappings and choose an expense account before creating purchases."
            return
        }
        guard let paymentAccount = QuickBooksItemAccountResolver.paymentAccountRef(
            for: paymentType,
            configuration: accountingConfiguration
        ) else {
            actionMessage = "Open Overview → Accounting Mappings and choose the matching bank and credit-card accounts before creating purchases."
            return
        }
        let payload = QuickBooksPurchaseCreate(
            AccountRef: paymentAccount,
            EntityRef: vendorRef,
            Line: [QuickBooksBillLine(amount: amount, description: note, accountRef: expenseAccount)],
            PaymentType: paymentType,
            PrivateNote: note
        )

        performAction(message: "Creating purchase in QuickBooks...") {
            liveAPI.createPurchase(payload) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let purchase):
                        actionMessage = "Purchase created: \(purchase.Id)"
                        syncAllQuickBooksData()
                    case .failure(let error):
                        actionMessage = "Purchase creation failed: \(error.localizedDescription)"
                        isLoading = false
                    }
                }
            }
        }
    }

    private func createVendor(name: String, email: String?, phone: String?) {
        let payload = QuickBooksVendorCreate(
            DisplayName: name,
            PrimaryEmailAddr: email.map { QuickBooksEmailAddress(Address: $0) },
            PrimaryPhone: phone.map { QuickBooksPhoneNumber(FreeFormNumber: $0) }
        )

        performAction(message: "Creating vendor in QuickBooks...") {
            liveAPI.createVendor(payload) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let vendor):
                        actionMessage = "Vendor created: \(vendor.DisplayName)"
                        syncAllQuickBooksData()
                    case .failure(let error):
                        actionMessage = "Vendor creation failed: \(error.localizedDescription)"
                        isLoading = false
                    }
                }
            }
        }
    }

    private func createPayment(for invoice: QuickBooksInvoice, amount: Double, note: String?, paymentMethodRef: QuickBooksReference?) {
        let payload = QuickBooksPaymentCreate(
            CustomerRef: invoice.CustomerRef,
            TotalAmt: amount,
            PrivateNote: note,
            PaymentRefNum: nil,
            Line: [
                QuickBooksPaymentLine(
                    Amount: amount,
                    LinkedTxn: [QuickBooksLinkedTxn(TxnId: invoice.Id, TxnType: "Invoice")]
                )
            ],
            PaymentMethodRef: paymentMethodRef,
            CreditCardPayment: nil
        )

        performAction(message: "Recording payment in QuickBooks...") {
            liveAPI.createPayment(payload) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let payment):
                        actionMessage = "Payment created: \(payment.Id)"
                        syncAllQuickBooksData()
                    case .failure(let error):
                        actionMessage = "Payment creation failed: \(error.localizedDescription)"
                        isLoading = false
                    }
                }
            }
        }
    }

    private func ensureStandardPaymentMethods() {
        performAction(message: "Ensuring QuickBooks payment methods...") {
            let group = DispatchGroup()
            var failures: [String] = []

            if !hasQuickBooksCardMethod {
                group.enter()
                liveAPI.createPaymentMethod(
                    QuickBooksPaymentMethodCreate(Name: "QuickBooks Card", methodType: "CREDIT_CARD")
                ) { result in
                    DispatchQueue.main.async {
                        if case .failure(let error) = result {
                            failures.append("Card method: \(error.localizedDescription)")
                        }
                        group.leave()
                    }
                }
            }

            if !hasQuickBooksACHMethod {
                group.enter()
                liveAPI.createPaymentMethod(
                    QuickBooksPaymentMethodCreate(Name: "QuickBooks ACH", methodType: "NON_CREDIT_CARD")
                ) { result in
                    DispatchQueue.main.async {
                        if case .failure(let error) = result {
                            failures.append("ACH method: \(error.localizedDescription)")
                        }
                        group.leave()
                    }
                }
            }

            group.notify(queue: .main) {
                if failures.isEmpty {
                    actionMessage = "QuickBooks payment methods are ready."
                } else {
                    actionMessage = failures.joined(separator: "\n")
                }
                syncAllQuickBooksData()
            }
        }
    }

    private func takeLiveCustomerPayment(for invoice: QuickBooksInvoice) {
        let amountDue = outstandingQuickBooksBalance(for: invoice)
        guard amountDue > 0 else {
            actionMessage = "This QuickBooks invoice is already paid."
            return
        }
        activePaymentInvoiceID = invoice.Id
        let payload = QuickBooksPaymentCreate(
            CustomerRef: invoice.CustomerRef,
            TotalAmt: amountDue,
            PrivateNote: "Created from GunnAire Ops for invoice \(invoice.DocNumber ?? invoice.Id)",
            PaymentRefNum: nil,
            Line: [
                QuickBooksPaymentLine(
                    Amount: amountDue,
                    LinkedTxn: [QuickBooksLinkedTxn(TxnId: invoice.Id, TxnType: "Invoice")]
                )
            ],
            PaymentMethodRef: nil,
            CreditCardPayment: nil
        )

        liveAPI.createPayment(payload) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let payment):
                    actionMessage = "Payment created: \(payment.Id) for invoice \(invoice.DocNumber ?? invoice.Id)"
                    syncAllQuickBooksData()
                case .failure(let error):
                    actionMessage = "Payment failed for invoice \(invoice.DocNumber ?? invoice.Id): \(error.localizedDescription)"
                    isLoading = false
                }
                activePaymentInvoiceID = nil
            }
        }
    }

    private func processCardCharge(for invoice: Invoice, amount: Double, cardInput: QuickBooksPaymentsCardInput, note: String?) {
        guard quickBooksPaymentsEnabled else {
            actionMessage = quickBooksPaymentsUnavailableMessage
            return
        }

        performAction(message: "Processing QuickBooks card charge...") {
            Task {
                do {
                    let result = try await QuickBooksPaymentsService.shared.processCardPayment(
                        invoice: invoice,
                        amount: amount,
                        cardInput: cardInput,
                        note: note,
                        catalogItems: localCatalogItems
                    )
                    let resolvedCardLast4 = result.charge.card?.number.flatMap { String($0.suffix(4)) }
                    await MainActor.run {
                        modelContext.insert(
                            Payment(
                                invoice: invoice,
                                quickBooksID: result.accountingPayment?.Id,
                                quickBooksChargeID: result.charge.id,
                                quickBooksClientTransID: result.clientTransactionID,
                                quickBooksAccountingSyncStatus: result.accountingError == nil ? "synced" : "needs_attention",
                                quickBooksAccountingSyncDetail: result.accountingError,
                                processorSyncStatus: "captured",
                                processorSyncDetail: nil,
                                amount: amount,
                                method: "card",
                                cardLast4: resolvedCardLast4,
                                authorizationReference: result.charge.authCode,
                                notes: note,
                                processor: OnsitePaymentProcessor.quickBooksPayments.rawValue
                            )
                        )
                        invoice.applyLocalPaymentAmount(amount)
                        let localBalance = localOutstandingBalance(for: invoice)
                        invoice.status = localBalance == 0 ? "paid" : "partial"
                        if let accountingError = result.accountingError {
                            actionMessage = "Charge captured, but accounting sync still needs attention: \(accountingError)"
                        } else {
                            actionMessage = "Card charge captured in QuickBooks Payments."
                        }
                        syncAllQuickBooksData()
                    }
                } catch {
                    await MainActor.run {
                        actionMessage = "QuickBooks card charge failed: \(error.localizedDescription)"
                        isLoading = false
                    }
                }
            }
        }
    }

    private func storeCard(_ input: QuickBooksPaymentsCardInput, for customer: QuickBooksCustomer) {
        guard quickBooksPaymentsEnabled else {
            actionMessage = quickBooksPaymentsUnavailableMessage
            return
        }

        performAction(message: "Storing QuickBooks card for \(customer.DisplayName)...") {
            Task {
                do {
                    let token = try await QuickBooksPaymentsService.shared.createStandaloneCardToken(input)
                    let card = try await withCheckedThrowingContinuation { continuation in
                        liveAPI.createStoredCard(QuickBooksPaymentsStoredCardCreateRequest(value: token.value), forCustomerID: customer.Id) { result in
                            continuation.resume(with: result)
                        }
                    }
                    await MainActor.run {
                        let customerScopedCard = card.associated(withCustomerID: customer.Id)
                        if let localCustomer = unambiguousLocalCustomer(for: customer),
                           let reference = customerScopedCard.storedPaymentMethodReference() {
                            localCustomer.upsertStoredPaymentMethod(reference)
                            do {
                                try modelContext.save()
                                actionMessage = "Stored and linked \(reference.displayLabel) for \(localCustomer.name). Full card details were not saved in GunnAire."
                            } catch {
                                actionMessage = "The card was stored in QuickBooks, but its safe GunnAire customer link could not be saved. Sync and link the customer before recurring billing setup."
                            }
                        } else {
                            actionMessage = "The card was stored in QuickBooks, but no unique local customer mapping was available. Sync or link the customer before recurring billing setup."
                        }
                        syncAllQuickBooksData()
                    }
                } catch {
                    await MainActor.run {
                        actionMessage = "Store card failed: \(error.localizedDescription)"
                        isLoading = false
                    }
                }
            }
        }
    }

    private func refundPayment(_ payment: Payment, amount: Double, note: String?) {
        guard quickBooksPaymentsEnabled else {
            actionMessage = quickBooksPaymentsUnavailableMessage
            return
        }

        performAction(message: "Refunding QuickBooks payment...") {
            Task {
                do {
                    let result = try await QuickBooksPaymentsService.shared.refundPayment(
                        payment: payment,
                        amount: amount,
                        note: note
                    )
                    await MainActor.run {
                        modelContext.insert(
                            Payment(
                                invoice: payment.invoice,
                                quickBooksChargeID: result.refund.id,
                                quickBooksClientTransID: result.clientTransactionID,
                                quickBooksRefundReceiptID: result.refundReceipt?.Id,
                                quickBooksAccountingSyncStatus: result.accountingError == nil ? "synced" : "needs_attention",
                                quickBooksAccountingSyncDetail: result.accountingError,
                                amount: -amount,
                                method: payment.method,
                                cardLast4: payment.cardLast4,
                                authorizationReference: result.refund.id,
                                notes: note,
                                processor: OnsitePaymentProcessor.quickBooksPayments.rawValue,
                                isRefund: true,
                                refundedPaymentID: payment.id
                            )
                        )
                        payment.invoice.applyLocalPaymentAmount(amount, isRefund: true)
                        let localBalance = localOutstandingBalance(for: payment.invoice)
                        payment.invoice.status = localBalance == 0 ? "paid" : "partial"
                        if let accountingError = result.accountingError {
                            actionMessage = "Refund issued, but refund receipt sync still needs attention: \(accountingError)"
                        } else {
                            actionMessage = "QuickBooks refund completed."
                        }
                        syncAllQuickBooksData()
                    }
                } catch {
                    await MainActor.run {
                        actionMessage = "QuickBooks refund failed: \(error.localizedDescription)"
                        isLoading = false
                    }
                }
            }
        }
    }

    private func retryQuickBooksFollowUp(for payment: Payment) {
        performAction(message: "Retrying QuickBooks follow-up...") {
            Task {
                do {
                    if payment.isRefund {
                        let receipt = try await QuickBooksPaymentsService.shared.retryRefundReceiptSync(for: payment)
                        await MainActor.run {
                            payment.quickBooksRefundReceiptID = receipt.Id
                            payment.quickBooksAccountingSyncStatus = "synced"
                            payment.quickBooksAccountingSyncDetail = nil
                            actionMessage = "QuickBooks refund receipt sync completed."
                            syncAllQuickBooksData()
                        }
                    } else {
                        let accountingPayment = try await QuickBooksPaymentsService.shared.retryAccountingSync(for: payment)
                        await MainActor.run {
                            payment.quickBooksID = accountingPayment.Id
                            payment.quickBooksAccountingSyncStatus = "synced"
                            payment.quickBooksAccountingSyncDetail = nil
                            actionMessage = "QuickBooks accounting payment sync completed."
                            syncAllQuickBooksData()
                        }
                    }
                } catch {
                    await MainActor.run {
                        payment.quickBooksAccountingSyncStatus = "needs_attention"
                        payment.quickBooksAccountingSyncDetail = error.localizedDescription
                        actionMessage = "QuickBooks follow-up retry failed: \(error.localizedDescription)"
                        isLoading = false
                    }
                }
            }
        }
    }

    private func loadPaymentReceipt(for payment: Payment) {
        guard let chargeID = payment.quickBooksChargeID?.trimmingCharacters(in: .whitespacesAndNewlines), !chargeID.isEmpty else {
            actionMessage = "This payment does not have a QuickBooks charge ID."
            return
        }
        guard quickBooksPaymentsEnabled else {
            actionMessage = quickBooksPaymentsUnavailableMessage
            return
        }

        performAction(message: "Loading QuickBooks payment receipt...") {
            liveAPI.fetchPaymentReceipt(id: chargeID) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let receipt):
                        paymentReceipts[chargeID] = receipt
                        actionMessage = "Payment receipt loaded."
                    case .failure(let error):
                        actionMessage = "Payment receipt lookup failed: \(error.localizedDescription)"
                    }
                    isLoading = false
                }
            }
        }
    }

    private func salesLineItem(
        amount: Double,
        note: String?,
        itemRef: QuickBooksReference
    ) -> QuickBooksLineItem {
        QuickBooksLineItem(
            Amount: amount,
            DetailType: "SalesItemLineDetail",
            Description: note,
            SalesItemLineDetail: QuickBooksSalesItemLineDetail(
                ItemRef: itemRef
            )
        )
    }

    private func performAction(message: String, work: @escaping () -> Void) {
        guard isAuthenticated else {
            actionMessage = "QuickBooks is not connected."
            return
        }
        isLoading = true
        actionMessage = nil
        statusMessage = message
        work()
    }

    private func outstandingQuickBooksBalance(for invoice: QuickBooksInvoice) -> Double {
        max(invoice.Balance ?? invoice.TotalAmt, 0)
    }

    private func localOutstandingBalance(for invoice: Invoice) -> Double {
        Invoice.outstandingBalance(for: invoice, payments: localPayments)
    }

    private func localCustomer(for quickBooksCustomer: QuickBooksCustomer) -> Customer? {
        localCustomers.first {
            ($0.quickBooksID == quickBooksCustomer.Id) ||
            $0.name.caseInsensitiveCompare(quickBooksCustomer.DisplayName) == .orderedSame
        }
    }

    private func localCatalogItem(for quickBooksItem: QuickBooksItem) -> Item? {
        let quickBooksID = quickBooksItem.Id.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = QuickBooksCatalogMappingIntegrity.linkedItems(to: quickBooksID, in: localCatalogItems)
        return matches.count == 1 ? matches[0] : nil
    }

    private func resolveCatalogMappingConflict(
        _ conflict: QuickBooksCatalogMappingConflict,
        keeping canonicalItem: Item
    ) {
        catalogMappingResolutionCandidateID = nil
        do {
            let unlinkedItems = try QuickBooksCatalogMappingIntegrity.resolve(
                conflict,
                keeping: canonicalItem
            )
            try modelContext.save()
            showCatalogReconciliationQueue = true
            showCatalogPublicationQueue = true
            let unlinkedNames = unlinkedItems.map(\.name).joined(separator: ", ")
            actionMessage = "Kept \(canonicalItem.name) as the only GunnAire link to QBO \(conflict.quickBooksID). Unlinked for separate review: \(unlinkedNames)."
        } catch {
            actionMessage = "Could not resolve the catalog mapping: \(error.localizedDescription)"
        }
    }

    private func reconciliationValue(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func pricebookReviewRow(for item: Item) -> some View {
        let documentImpact = PricebookReviewQueue.documentImpact(
            for: item,
            estimates: localEstimates,
            invoices: localInvoices
        )
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.headline)
                    if let description = item.itemDescription, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(item.unitPrice, format: .currency(code: "USD"))
                    .font(.subheadline.weight(.semibold))
            }

            Text(pricebookReviewDetails(for: item).joined(separator: " • "))
                .font(.caption2)
                .foregroundStyle(.secondary)

            Label(
                documentImpact.summary,
                systemImage: documentImpact.totalCount == 0
                    ? "doc.badge.ellipsis"
                    : "doc.badge.clock"
            )
            .font(.caption)
            .foregroundStyle(documentImpact.totalCount == 0 ? Color.secondary : Color.orange)
            .accessibilityIdentifier("PricebookReviewImpact-\(item.id.uuidString)")

            ViewThatFits(in: .horizontal) {
                HStack {
                    pricebookReviewButtons(for: item)
                }
                VStack(alignment: .leading) {
                    pricebookReviewButtons(for: item)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func pricebookReviewDetails(for item: Item) -> [String] {
        let details: [String?] = [
            item.itemType.rawValue,
            item.sku.map { "SKU \($0)" },
            item.purchaseCost.map { "Cost \($0.formatted(.currency(code: "USD")))" },
            item.isTaxable ? "Taxable" : "Non-taxable",
            item.pricebookCreatedByEmail.map { "Created by \($0)" }
        ]
        return details.compactMap { $0 }
    }

    @ViewBuilder
    private func pricebookReviewButtons(for item: Item) -> some View {
        Button("Review & Edit") {
            catalogItemBeingEdited = item
        }
        .buttonStyle(.bordered)
        .disabled(activePricebookReviewID != nil || activeCatalogPublicationID != nil)
        .accessibilityIdentifier("ReviewPricebookItem-\(item.id.uuidString)")

        Button(
            activePricebookReviewID == item.id
                ? "Approving..."
                : (isAuthenticated ? "Approve & Publish" : "Approve for Pricebook")
        ) {
            approvePricebookItem(item)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.brandGold)
        .foregroundStyle(Color.primaryBlack)
        .disabled(activePricebookReviewID != nil || activeCatalogPublicationID != nil)
        .accessibilityIdentifier("ApprovePricebookItem-\(item.id.uuidString)")
    }

    @ViewBuilder
    private func catalogReconciliationButtons(for entry: QuickBooksCatalogReconciliationEntry) -> some View {
        Button("Edit Staged Changes") {
            catalogItemBeingEdited = entry.localItem
        }
        .buttonStyle(.bordered)

        Button("Use QuickBooks Version") {
            useQuickBooksCatalogVersion(entry)
        }
        .buttonStyle(.bordered)
        .disabled(activeCatalogReconciliationID != nil)
        .accessibilityIdentifier("UseQuickBooksCatalogVersion-\(entry.localItem.id.uuidString)")

        Button(activeCatalogReconciliationID == entry.localItem.id ? "Publishing..." : "Publish GunnAire Version") {
            publishGunnAireCatalogVersion(entry)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.brandGold)
        .foregroundStyle(Color.primaryBlack)
        .disabled(
            !isAuthenticated ||
            activeCatalogReconciliationID != nil ||
            !QuickBooksCatalogReconciliation.canPublish(
                localItem: entry.localItem,
                currentRemoteItem: entry.remoteItem
            )
        )
        .accessibilityIdentifier("PublishGunnAireCatalogVersion-\(entry.localItem.id.uuidString)")
    }

    private func catalogPublishBlockedReason(for entry: QuickBooksCatalogReconciliationEntry) -> String? {
        do {
            _ = try QuickBooksCatalogReconciliation.updatePayload(
                localItem: entry.localItem,
                currentRemoteItem: entry.remoteItem
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func useQuickBooksCatalogVersion(_ entry: QuickBooksCatalogReconciliationEntry) {
        if let conflict = QuickBooksCatalogMappingIntegrity.conflict(
            containing: entry.localItem,
            in: localCatalogItems
        ) {
            actionMessage = QuickBooksCatalogMappingIntegrityError.ambiguousIdentifier(
                quickBooksID: conflict.quickBooksID,
                localItemNames: conflict.localItems.map(\.name)
            ).localizedDescription
            return
        }
        activeCatalogReconciliationID = entry.localItem.id
        applyApprovedQuickBooksItem(entry.remoteItem, to: entry.localItem)
        do {
            try modelContext.save()
            actionMessage = "Applied the reviewed QuickBooks version of \(entry.remoteItem.Name) to GunnAire."
        } catch {
            entry.localItem.quickBooksSyncStatus = "needs_attention"
            entry.localItem.quickBooksSyncDetail = "QuickBooks version was selected, but the local catalog could not be saved: \(error.localizedDescription)"
            actionMessage = entry.localItem.quickBooksSyncDetail
        }
        activeCatalogReconciliationID = nil
    }

    private func publishGunnAireCatalogVersion(_ entry: QuickBooksCatalogReconciliationEntry) {
        let localItem = entry.localItem
        if let conflict = QuickBooksCatalogMappingIntegrity.conflict(
            containing: localItem,
            in: localCatalogItems
        ) {
            markCatalogReconciliationFailure(
                localItem,
                error: QuickBooksCatalogMappingIntegrityError.ambiguousIdentifier(
                    quickBooksID: conflict.quickBooksID,
                    localItemNames: conflict.localItems.map(\.name)
                )
            )
            return
        }
        guard let quickBooksID = localItem.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !quickBooksID.isEmpty else {
            markCatalogReconciliationFailure(
                localItem,
                error: QuickBooksCatalogReconciliationError.identifierMismatch
            )
            return
        }
        activeCatalogReconciliationID = localItem.id
        actionMessage = "Refreshing \(localItem.name) from QuickBooks before publishing..."

        liveAPI.fetchItem(id: quickBooksID) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    markCatalogReconciliationFailure(localItem, error: error)
                case .success(let currentRemoteItem):
                    guard !QuickBooksCatalogReconciliation.differences(
                        localItem: localItem,
                        remoteItem: currentRemoteItem
                    ).isEmpty else {
                        applyApprovedQuickBooksItem(currentRemoteItem, to: localItem)
                        finishCatalogReconciliation(
                            localItem,
                            message: "\(localItem.name) already matches QuickBooks."
                        )
                        return
                    }
                    do {
                        let payload = try QuickBooksCatalogReconciliation.updatePayload(
                            localItem: localItem,
                            currentRemoteItem: currentRemoteItem
                        )
                        actionMessage = "Publishing the reviewed GunnAire version of \(localItem.name) to QuickBooks..."
                        liveAPI.updateItem(payload) { updateResult in
                            DispatchQueue.main.async {
                                switch updateResult {
                                case .failure(let error):
                                    markCatalogReconciliationFailure(localItem, error: error)
                                case .success(let updatedItem):
                                    applyApprovedQuickBooksItem(updatedItem, to: localItem)
                                    if let index = items.firstIndex(where: { $0.Id == updatedItem.Id }) {
                                        items[index] = updatedItem
                                    }
                                    finishCatalogReconciliation(
                                        localItem,
                                        message: "Published and reconciled \(updatedItem.Name) with QuickBooks."
                                    )
                                }
                            }
                        }
                    } catch {
                        markCatalogReconciliationFailure(localItem, error: error)
                    }
                }
            }
        }
    }

    private func finishCatalogReconciliation(_ item: Item, message: String) {
        activeCatalogReconciliationID = nil
        do {
            try modelContext.save()
            actionMessage = message
        } catch {
            item.quickBooksSyncStatus = "needs_attention"
            item.quickBooksSyncDetail = "QuickBooks accepted the catalog update, but the local confirmation could not be saved: \(error.localizedDescription)"
            actionMessage = item.quickBooksSyncDetail
        }
    }

    private func markCatalogReconciliationFailure(_ item: Item, error: Error) {
        activeCatalogReconciliationID = nil
        item.quickBooksSyncStatus = "needs_attention"
        item.quickBooksSyncDetail = error.localizedDescription
        try? modelContext.save()
        actionMessage = "Catalog reconciliation needs attention: \(error.localizedDescription)"
    }

    private func unambiguousLocalCustomer(for quickBooksCustomer: QuickBooksCustomer) -> Customer? {
        if let exact = localCustomers.first(where: { $0.quickBooksID == quickBooksCustomer.Id }) {
            return exact
        }
        let nameMatches = localCustomers.filter {
            $0.name.caseInsensitiveCompare(quickBooksCustomer.DisplayName) == .orderedSame
        }
        return nameMatches.count == 1 ? nameMatches[0] : nil
    }

    private func reconcileStoredPaymentMethodReferences(_ cards: [QuickBooksPaymentsCardRecord]) {
        let reconciledAt = Date()
        let referencesByCustomerID = Dictionary(
            grouping: cards.compactMap { $0.storedPaymentMethodReference(updatedAt: reconciledAt) },
            by: \.providerCustomerID
        )
        for quickBooksCustomer in customers {
            guard let localCustomer = unambiguousLocalCustomer(for: quickBooksCustomer) else { continue }
            localCustomer.reconcileQuickBooksStoredPaymentMethods(
                referencesByCustomerID[quickBooksCustomer.Id] ?? [],
                providerCustomerID: quickBooksCustomer.Id,
                reconciledAt: reconciledAt
            )
        }
        do {
            try modelContext.save()
        } catch {
            actionMessage = "Stored cards loaded, but their safe customer links could not be saved. Retry Sync before relying on payment-method readiness."
        }
    }

    private func localInvoice(for quickBooksInvoice: QuickBooksInvoice) -> Invoice? {
        localInvoices.first {
            ($0.quickBooksID == quickBooksInvoice.Id) ||
            (($0.quickBooksID == quickBooksInvoice.DocNumber) && !(quickBooksInvoice.DocNumber ?? "").isEmpty)
        }
    }

    private func retryLocalEstimatePublication(_ estimate: Estimate) {
        guard isAuthenticated else {
            actionMessage = "Reconnect QuickBooks before retrying local estimate publication."
            return
        }
        guard activeLocalEstimatePublicationID == nil else { return }

        let inputs: QuickBooksEstimatePublicationInputs
        do {
            inputs = try QuickBooksEstimatePublicationRecovery.publicationInputs(
                for: estimate,
                catalogItems: localCatalogItems
            )
        } catch {
            actionMessage = error.localizedDescription
            return
        }

        activeLocalEstimatePublicationID = estimate.id
        actionMessage = "Checking QuickBooks for \(estimate.customer.name)'s estimate before publishing..."
        liveAPI.fetchEstimates { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    activeLocalEstimatePublicationID = nil
                    actionMessage = "QuickBooks estimate reconciliation failed, so no new estimate was created: \(error.localizedDescription)"
                case .success(let remoteEstimates):
                    do {
                        if let recovered = try QuickBooksEstimatePublicationRecovery.matchingRemoteEstimate(
                            for: estimate,
                            in: remoteEstimates
                        ) {
                            completeLocalEstimatePublication(
                                .success(recovered),
                                localEstimate: estimate,
                                recoveredExisting: true
                            )
                            return
                        }
                    } catch {
                        activeLocalEstimatePublicationID = nil
                        actionMessage = error.localizedDescription
                        return
                    }

                    let payload = QuickBooksEstimateCreate(
                        CustomerRef: inputs.customerRef,
                        Line: inputs.lines,
                        PrivateNote: inputs.privateNote,
                        BillEmail: inputs.billEmail,
                        ShipAddr: inputs.shipAddress,
                        GlobalTaxCalculation: "TaxExcluded"
                    )
                    liveAPI.createEstimate(payload) { createResult in
                        DispatchQueue.main.async {
                            completeLocalEstimatePublication(
                                createResult,
                                localEstimate: estimate,
                                recoveredExisting: false
                            )
                        }
                    }
                }
            }
        }
    }

    private func completeLocalEstimatePublication(
        _ result: Result<QuickBooksEstimate, Error>,
        localEstimate: Estimate,
        recoveredExisting: Bool
    ) {
        defer { activeLocalEstimatePublicationID = nil }
        switch result {
        case .failure(let error):
            actionMessage = "QuickBooks estimate publication failed: \(error.localizedDescription)"
        case .success(let quickBooksEstimate):
            localEstimate.quickBooksID = quickBooksEstimate.Id
            let taxIssue = localEstimate.applyQuickBooksTaxResult(
                total: quickBooksEstimate.TotalAmt,
                reportedTax: quickBooksEstimate.TxnTaxDetail?.TotalTax
            )
            if let index = estimates.firstIndex(where: { $0.Id == quickBooksEstimate.Id }) {
                estimates[index] = quickBooksEstimate
            } else {
                estimates.insert(quickBooksEstimate, at: 0)
            }

            if let call = localServiceCall(for: localEstimate) {
                let actor = AppIdentity.currentEmail
                ServiceCallActivity.record(
                    for: call,
                    action: recoveredExisting ? "QuickBooks estimate link recovered" : "QuickBooks estimate published",
                    detail: "QuickBooks estimate \(quickBooksEstimate.DocNumber ?? quickBooksEstimate.Id) confirmed from the local publication queue.",
                    actorEmail: actor,
                    in: modelContext
                )
            }

            do {
                try modelContext.save()
                if let taxIssue {
                    actionMessage = "QuickBooks confirmed the estimate, but its tax total needs review: \(taxIssue)"
                } else {
                    actionMessage = recoveredExisting
                        ? "Existing QuickBooks estimate recovered without creating a duplicate."
                        : "Estimate created and confirmed in QuickBooks."
                }
            } catch {
                actionMessage = "QuickBooks confirmed the estimate, but its local link could not be saved: \(error.localizedDescription)"
            }
        }
    }

    private func retryLocalInvoicePublication(_ invoice: Invoice) {
        guard isAuthenticated else {
            actionMessage = "Reconnect QuickBooks before retrying local invoice publication."
            return
        }
        guard activeLocalInvoicePublicationID == nil else { return }

        let inputs: QuickBooksInvoicePublicationInputs
        do {
            inputs = try QuickBooksInvoicePublicationRecovery.publicationInputs(
                for: invoice,
                catalogItems: localCatalogItems,
                payments: localPayments
            )
        } catch {
            markLocalInvoicePublicationFailure(invoice, error: error)
            actionMessage = error.localizedDescription
            return
        }

        activeLocalInvoicePublicationID = invoice.id
        actionMessage = "Retrying QuickBooks publication for \(invoice.customer.name)..."

        if let quickBooksID = invoice.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !quickBooksID.isEmpty {
            quickBooksDataAPI.fetchInvoice(id: quickBooksID) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .failure(let error):
                        markLocalInvoicePublicationFailure(invoice, error: error)
                        actionMessage = "QuickBooks invoice refresh failed: \(error.localizedDescription)"
                        activeLocalInvoicePublicationID = nil
                    case .success(let currentInvoice):
                        guard let syncToken = currentInvoice.SyncToken?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !syncToken.isEmpty else {
                            let error = QuickBooksDataAPI.QBError.missingSyncToken(entity: "invoice \(quickBooksID)")
                            markLocalInvoicePublicationFailure(invoice, error: error)
                            actionMessage = error.localizedDescription
                            activeLocalInvoicePublicationID = nil
                            return
                        }
                        let payload = QuickBooksInvoiceUpdate(
                            Id: quickBooksID,
                            SyncToken: syncToken,
                            CustomerRef: inputs.customerRef,
                            Line: inputs.lines,
                            PrivateNote: inputs.privateNote,
                            BillEmail: inputs.billEmail,
                            ShipAddr: inputs.shipAddress,
                            DueDate: QuickBooksDateOnly.string(from: invoice.effectiveDueDate()),
                            GlobalTaxCalculation: "TaxExcluded"
                        )
                        quickBooksDataAPI.updateInvoice(payload) { updateResult in
                            DispatchQueue.main.async {
                                completeLocalInvoicePublication(updateResult, localInvoice: invoice, wasUpdate: true)
                            }
                        }
                    }
                }
            }
        } else {
            let payload = QuickBooksInvoiceCreate(
                CustomerRef: inputs.customerRef,
                Line: inputs.lines,
                PrivateNote: inputs.privateNote,
                BillEmail: inputs.billEmail,
                ShipAddr: inputs.shipAddress,
                DueDate: QuickBooksDateOnly.string(from: invoice.effectiveDueDate()),
                GlobalTaxCalculation: "TaxExcluded"
            )
            quickBooksDataAPI.fetchInvoices { fetchResult in
                DispatchQueue.main.async {
                    switch fetchResult {
                    case .failure(let error):
                        markLocalInvoicePublicationFailure(invoice, error: error)
                        actionMessage = "QuickBooks invoice reconciliation failed, so no duplicate-prone create was attempted: \(error.localizedDescription)"
                        activeLocalInvoicePublicationID = nil
                    case .success(let remoteInvoices):
                        do {
                            if let recovered = try QuickBooksInvoicePublicationRecovery.matchingRemoteInvoice(
                                for: invoice,
                                in: remoteInvoices
                            ) {
                                completeLocalInvoicePublication(
                                    .success(recovered),
                                    localInvoice: invoice,
                                    wasUpdate: false,
                                    recoveredExisting: true
                                )
                                return
                            }
                        } catch {
                            markLocalInvoicePublicationFailure(invoice, error: error)
                            actionMessage = error.localizedDescription
                            activeLocalInvoicePublicationID = nil
                            return
                        }

                        quickBooksDataAPI.createInvoice(
                            payload,
                            requestID: QuickBooksInvoiceLineage.createRequestID(for: invoice)
                        ) { result in
                            DispatchQueue.main.async {
                                completeLocalInvoicePublication(
                                    result,
                                    localInvoice: invoice,
                                    wasUpdate: false
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func completeLocalInvoicePublication(
        _ result: Result<QuickBooksInvoice, Error>,
        localInvoice: Invoice,
        wasUpdate: Bool,
        recoveredExisting: Bool = false
    ) {
        defer { activeLocalInvoicePublicationID = nil }
        switch result {
        case .failure(let error):
            markLocalInvoicePublicationFailure(localInvoice, error: error)
            actionMessage = "QuickBooks invoice publication failed: \(error.localizedDescription)"
        case .success(let quickBooksInvoice):
            localInvoice.quickBooksID = quickBooksInvoice.Id
            localInvoice.quickBooksBalanceDue = quickBooksInvoice.Balance
            if let rawDueDate = quickBooksInvoice.DueDate,
               let dueDate = QuickBooksDateOnly.date(from: rawDueDate) {
                localInvoice.dueDate = dueDate
            }
            let taxIssue = localInvoice.applyQuickBooksTaxResult(
                total: quickBooksInvoice.TotalAmt,
                reportedTax: quickBooksInvoice.TxnTaxDetail?.TotalTax
            )
            localInvoice.quickBooksSyncStatus = taxIssue == nil ? "synced" : "needs_attention"
            localInvoice.quickBooksSyncDetail = taxIssue
            localInvoice.quickBooksLastSyncedAt = Date()

            if let call = localServiceCall(for: localInvoice) {
                let actor = AppIdentity.currentEmail
                ServiceCallActivity.record(
                    for: call,
                    action: recoveredExisting
                        ? "QuickBooks invoice link recovered"
                        : (wasUpdate ? "QuickBooks invoice republished" : "QuickBooks invoice published"),
                    detail: recoveredExisting
                        ? "Recovered QuickBooks invoice \(quickBooksInvoice.DocNumber ?? quickBooksInvoice.Id) by its GunnAire operation marker without creating another transaction."
                        : "QuickBooks invoice \(quickBooksInvoice.DocNumber ?? quickBooksInvoice.Id) confirmed from the local publication queue.",
                    actorEmail: actor,
                    in: modelContext
                )
            }

            if let index = invoices.firstIndex(where: { $0.Id == quickBooksInvoice.Id }) {
                invoices[index] = quickBooksInvoice
            } else {
                invoices.insert(quickBooksInvoice, at: 0)
            }
            saveLocalInvoicePublicationState()
            if let taxIssue {
                actionMessage = "QuickBooks confirmed the invoice, but its tax total needs review: \(taxIssue)"
            } else {
                actionMessage = recoveredExisting
                    ? "Existing QuickBooks invoice recovered without creating a duplicate."
                    : (wasUpdate
                        ? "Invoice line items updated and confirmed in QuickBooks."
                        : "Invoice created and confirmed in QuickBooks.")
            }
        }
    }

    private func markLocalInvoicePublicationFailure(_ invoice: Invoice, error: Error) {
        invoice.quickBooksSyncStatus = "needs_attention"
        invoice.quickBooksSyncDetail = error.localizedDescription
        saveLocalInvoicePublicationState()
    }

    private func saveLocalInvoicePublicationState() {
        do {
            try modelContext.save()
        } catch {
            actionMessage = "QuickBooks responded, but the local publication state could not be saved: \(error.localizedDescription)"
        }
    }

    private func quickBooksCustomer(for estimate: QuickBooksEstimate) -> QuickBooksCustomer? {
        customers.first { $0.Id == estimate.CustomerRef.value }
    }

    private func estimateEmailAddress(for estimate: QuickBooksEstimate) -> String? {
        let candidates = [
            estimate.BillEmail?.Address,
            quickBooksCustomer(for: estimate)?.PrimaryEmailAddr?.Address
        ]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private func sendEstimateEmail(_ estimate: QuickBooksEstimate) {
        guard let emailAddress = estimateEmailAddress(for: estimate) else {
            actionMessage = "Add an email address to this QuickBooks customer before sending the estimate."
            return
        }
        activeEmailEstimateID = estimate.Id
        actionMessage = "Sending estimate \(estimate.DocNumber ?? estimate.Id) to \(emailAddress)..."
        sendCreatedEstimateEmail(estimate, to: emailAddress)
    }

    private func sendCreatedEstimateEmail(_ estimate: QuickBooksEstimate, to emailAddress: String?) {
        let trimmedEmail = emailAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
        liveAPI.sendEstimate(id: estimate.Id, to: trimmedEmail) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let sentEstimate):
                    actionMessage = "Estimate \(sentEstimate.DocNumber ?? sentEstimate.Id) emailed to \(trimmedEmail ?? "the customer")."
                    syncAllQuickBooksData()
                case .failure(let error):
                    actionMessage = "Estimate email failed: \(error.localizedDescription)"
                    isLoading = false
                }
                activeEmailEstimateID = nil
            }
        }
    }

    private func quickBooksCustomer(for invoice: QuickBooksInvoice) -> QuickBooksCustomer? {
        customers.first { $0.Id == invoice.CustomerRef.value }
    }

    private func invoiceEmailAddress(for invoice: QuickBooksInvoice) -> String? {
        let candidates = [
            invoice.BillEmail?.Address,
            quickBooksCustomer(for: invoice)?.PrimaryEmailAddr?.Address
        ]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private func sendInvoiceEmail(_ invoice: QuickBooksInvoice) {
        guard let emailAddress = invoiceEmailAddress(for: invoice) else {
            actionMessage = "Add an email address to this QuickBooks customer before sending the invoice."
            return
        }
        activeEmailInvoiceID = invoice.Id
        actionMessage = "Sending invoice \(invoice.DocNumber ?? invoice.Id) to \(emailAddress)..."
        sendCreatedInvoiceEmail(invoice, to: emailAddress)
    }

    private func sendCreatedInvoiceEmail(_ invoice: QuickBooksInvoice, to emailAddress: String?) {
        let trimmedEmail = emailAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
        liveAPI.sendInvoice(id: invoice.Id, to: trimmedEmail) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let sentInvoice):
                    actionMessage = "Invoice \(sentInvoice.DocNumber ?? sentInvoice.Id) emailed to \(trimmedEmail ?? "the customer")."
                    syncAllQuickBooksData()
                case .failure(let error):
                    actionMessage = "Invoice email failed: \(error.localizedDescription)"
                    isLoading = false
                }
                activeEmailInvoiceID = nil
            }
        }
    }

    private func localServiceCall(for invoice: Invoice) -> ServiceCall? {
        guard let serviceCallID = invoice.serviceCallID else { return nil }
        return serviceCalls.first(where: { $0.id == serviceCallID })
    }

    private func localServiceCall(for estimate: Estimate) -> ServiceCall? {
        guard let serviceCallID = estimate.serviceCallID else { return nil }
        return serviceCalls.first(where: { $0.id == serviceCallID })
    }

    private func liveInvoiceURL(for invoice: QuickBooksInvoice) -> URL? {
        guard let realmID = QuickBooksDataAPI.shared.realmID else { return nil }
        return URL(string: "https://app.qbo.intuit.com/app/invoice?txnId=\(invoice.Id)&txnType=Invoice&companyId=\(realmID)")
    }

    @ViewBuilder
    private func transactionBlock(title: String, name: String, amount: Double, dateText: String?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(name)
                    .font(.subheadline)
                if let dateText, !dateText.isEmpty {
                    Text(dateText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Text(amount, format: .currency(code: "USD"))
                .font(.subheadline)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func emptyState(_ text: String) -> some View {
        Text(text)
            .foregroundColor(.secondary)
            .italic()
    }

    private func filtered<T>(_ values: [T], query: String, text: (T) -> [String?]) -> [T] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedQuery.isEmpty else { return values }
        return values.filter { value in
            text(value)
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(trimmedQuery) }
        }
    }

    private static var defaultSyncResourceStatuses: [QuickBooksSyncResourceStatus] {
        [
            QuickBooksSyncResourceStatus(id: "customers", name: "Customers", lane: "Accounting", required: true, state: .idle, detail: "Not synced this session.", count: nil, updatedAt: nil),
            QuickBooksSyncResourceStatus(id: "catalog", name: "Catalog", lane: "Accounting", required: true, state: .idle, detail: "Not synced this session.", count: nil, updatedAt: nil),
            QuickBooksSyncResourceStatus(id: "accounts", name: "Chart of Accounts", lane: "Accounting", required: true, state: .idle, detail: "Not synced this session.", count: nil, updatedAt: nil),
            QuickBooksSyncResourceStatus(id: "mappings", name: "Accounting Mappings", lane: "Accounting", required: false, state: .idle, detail: "Not checked this session.", count: nil, updatedAt: nil),
            QuickBooksSyncResourceStatus(id: "estimates", name: "Estimates", lane: "Accounting", required: true, state: .idle, detail: "Not synced this session.", count: nil, updatedAt: nil),
            QuickBooksSyncResourceStatus(id: "invoices", name: "Invoices", lane: "Accounting", required: true, state: .idle, detail: "Not synced this session.", count: nil, updatedAt: nil),
            QuickBooksSyncResourceStatus(id: "vendors", name: "Vendors", lane: "Accounting", required: true, state: .idle, detail: "Not synced this session.", count: nil, updatedAt: nil),
            QuickBooksSyncResourceStatus(id: "payments", name: "Payments", lane: "Accounting", required: true, state: .idle, detail: "Not synced this session.", count: nil, updatedAt: nil),
            QuickBooksSyncResourceStatus(id: "salesReceipts", name: "Sales Receipts", lane: "Accounting", required: true, state: .idle, detail: "Not synced this session.", count: nil, updatedAt: nil),
            QuickBooksSyncResourceStatus(id: "deposits", name: "Deposits", lane: "Accounting", required: true, state: .idle, detail: "Not synced this session.", count: nil, updatedAt: nil),
            QuickBooksSyncResourceStatus(id: "bills", name: "Bills", lane: "Accounting", required: true, state: .idle, detail: "Not synced this session.", count: nil, updatedAt: nil),
            QuickBooksSyncResourceStatus(id: "vendorCredits", name: "Vendor Credits", lane: "Accounting", required: true, state: .idle, detail: "Not synced this session.", count: nil, updatedAt: nil),
            QuickBooksSyncResourceStatus(id: "purchases", name: "Purchases", lane: "Accounting", required: true, state: .idle, detail: "Not synced this session.", count: nil, updatedAt: nil),
            QuickBooksSyncResourceStatus(id: "paymentMethods", name: "Payment Methods", lane: "Accounting", required: true, state: .idle, detail: "Not synced this session.", count: nil, updatedAt: nil),
            QuickBooksSyncResourceStatus(id: "storedCards", name: "Stored Cards", lane: "Payments", required: false, state: .idle, detail: "Not synced this session.", count: nil, updatedAt: nil)
        ]
    }

    private func resetSyncStatusesForRun() {
        let now = Date()
        syncResourceStatuses = Self.defaultSyncResourceStatuses.map { status in
            QuickBooksSyncResourceStatus(
                id: status.id,
                name: status.name,
                lane: status.lane,
                required: status.required,
                state: .syncing,
                detail: "Waiting for QuickBooks...",
                count: nil,
                updatedAt: now
            )
        }
    }

    private func markAllSyncStatusesFailed(_ detail: String) {
        let now = Date()
        syncResourceStatuses = syncResourceStatuses.map { status in
            QuickBooksSyncResourceStatus(
                id: status.id,
                name: status.name,
                lane: status.lane,
                required: status.required,
                state: status.required ? .failed : .warning,
                detail: detail,
                count: nil,
                updatedAt: now
            )
        }
    }

    private func markPendingSyncStatusesFailed(_ detail: String) {
        let now = Date()
        syncResourceStatuses = syncResourceStatuses.map { status in
            guard status.state == .idle || status.state == .syncing else { return status }
            return QuickBooksSyncResourceStatus(
                id: status.id,
                name: status.name,
                lane: status.lane,
                required: status.required,
                state: status.required ? .failed : .warning,
                detail: detail,
                count: nil,
                updatedAt: now
            )
        }
    }

    private func updateSyncStatus(id: String, state: QuickBooksSyncState, detail: String, count: Int?) {
        guard let index = syncResourceStatuses.firstIndex(where: { $0.id == id }) else { return }
        syncResourceStatuses[index].state = state
        syncResourceStatuses[index].detail = detail
        syncResourceStatuses[index].count = count
        syncResourceStatuses[index].updatedAt = Date()
    }

    private func finishQuickBooksResourceSync(with failures: [String]) {
        isLoading = false

        guard !quickBooksReconnectRequired else {
            let company = QuickBooksDataAPI.shared.lastRejectedRealmID
                ?? QuickBooksDataAPI.shared.realmID
                ?? "the selected QuickBooks company"
            let environment = QuickBooksDataAPI.shared.lastRejectedEnvironment
                ?? QuickBooksDataAPI.shared.currentEnvironment
            statusMessage = "QuickBooks authorization needs reconnect. Open Settings, disconnect and reconnect QuickBooks with a company admin, confirm company \(company) authorized the \(environment) app, then retry sync."
            actionMessage = failures.first ?? "QuickBooks rejected the saved app session. The app cleared the rejected token so the next sync starts from a fresh reconnect."
            return
        }

        var completedFailures = failures
        do {
            try QuickBooksLocalSync.importSnapshot(
                customers: customers,
                items: items,
                estimates: estimates,
                invoices: invoices,
                payments: payments,
                vendors: vendors,
                into: modelContext
            )
        } catch {
            completedFailures.append("Local app sync: \(error.localizedDescription)")
        }

        if completedFailures.isEmpty {
            let now = Date()
            lastSuccessfulSyncAt = now
            UserDefaults.standard.set(now, forKey: "QuickBooksLastSuccessfulSyncAt")
            statusMessage = "All QuickBooks features synced successfully. Loaded \(customers.count) customers, \(items.count) catalog items, \(estimates.count) estimates, \(invoices.count) invoices, \(salesReceipts.count) sales receipts, \(bills.count) bills, \(purchases.count) purchases, \(vendors.count) vendors, \(payments.count) payments, \(paymentMethods.count) payment methods, \(storedCards.count) stored cards, and \(deposits.count) deposits."
            let acknowledgedEventIDs = Array(activeSyncWebhookEventIDs)
            activeSyncWebhookEventIDs.removeAll()
            if !acknowledgedEventIDs.isEmpty {
                Task { await acknowledgeQuickBooksWebhookEvents(acknowledgedEventIDs) }
            }
        } else {
            statusMessage = "QuickBooks sync incomplete. Required features must sync successfully.\n" + completedFailures.joined(separator: "\n")
        }
    }

    @MainActor
    private func loadQuickBooksWebhookEvents() async {
        guard GunnAireBackendService.isConfigured else {
            webhookStatusMessage = "Shared-server change alerts are not configured."
            return
        }
        isLoadingWebhookEvents = true
        defer { isLoadingWebhookEvents = false }
        do {
            quickBooksWebhookEvents = try await GunnAireBackendService.fetchQuickBooksWebhookEvents()
            webhookStatusMessage = quickBooksWebhookEvents.isEmpty
                ? "No pending QuickBooks changes reported by the server."
                : nil
        } catch {
            webhookStatusMessage = "QuickBooks change alerts need attention in Shared Server Readiness."
        }
    }

    @MainActor
    private func acknowledgeQuickBooksWebhookEvents(_ eventIDs: [String]) async {
        do {
            try await GunnAireBackendService.acknowledgeQuickBooksWebhookEvents(ids: eventIDs)
            quickBooksWebhookEvents.removeAll { eventIDs.contains($0.id) }
            webhookStatusMessage = quickBooksWebhookEvents.isEmpty
                ? "All QuickBooks changes included in the successful sync are reconciled."
                : "New QuickBooks changes arrived during sync. Run sync again to include them."
            await loadQuickBooksWebhookEvents()
        } catch {
            webhookStatusMessage = "QuickBooks data synced, but the server change queue could not be cleared. Refresh and try again."
        }
    }

    private func userFacingQuickBooksMessage(for error: Error) -> String {
        if let qbError = error as? QuickBooksDataAPI.QBError {
            return qbError.localizedDescription
        }
        return error.localizedDescription
    }

    @ViewBuilder
    private func syncResourceRow(_ status: QuickBooksSyncResourceStatus) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: status.state.icon)
                .foregroundStyle(status.state.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(status.name)
                        .font(.subheadline)
                    Spacer()
                    if let count = status.count {
                        Text("\(count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(status.state == .failed ? .red : .secondary)
                    .lineLimit(3)
            }
        }
    }

    @ViewBuilder
    private func summaryRow(title: String, count: Int, amount: Double? = nil) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let amount {
                Text("\(count) | \(amount.formatted(.currency(code: "USD")))")
                    .foregroundColor(.secondary)
            } else {
                Text("\(count)")
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func connectionRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

enum QuickBooksManagementWorkspace: String, CaseIterable, Identifiable {
    case overview
    case sales
    case expenses
    case payments

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview: "Overview"
        case .sales: "Sales"
        case .expenses: "Expenses"
        case .payments: "Payments"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"
        case .sales: "doc.text"
        case .expenses: "cart"
        case .payments: "creditcard"
        }
    }

    var guidance: String {
        switch self {
        case .overview:
            "Review the company realm, authorization health, resource status, and latest sync."
        case .sales:
            "Work with customers, catalog items, estimates, invoices, and walk-in sales."
        case .expenses:
            "Review vendors, bills, and purchases without mixing them into sales activity."
        case .payments:
            "Review invoice payments, methods, deposits, stored cards, charges, and refunds."
        }
    }
}

#Preview {
    QuickBooksManagementView()
}

private struct QuickBooksDocumentComposeView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let customerRefs: [QuickBooksReference]
    let onCreate: (QuickBooksReference, Double, String?) -> Void

    @State private var selectedCustomerID: String?
    @State private var amountText = ""
    @State private var note = ""

    private var customerOptions: [SearchableDropdownOption] {
        customerRefs.map { SearchableDropdownOption(id: $0.value, title: $0.displayName, subtitle: $0.value) }
    }

    private var selectedCustomer: QuickBooksReference? {
        if let selectedCustomerID, let match = customerRefs.first(where: { $0.value == selectedCustomerID }) {
            return match
        }
        return customerRefs.first
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(title) {
                    if customerRefs.isEmpty {
                        Text("Sync QuickBooks customers first.")
                            .foregroundColor(.secondary)
                    } else {
                        SearchableDropdownPicker(
                            title: "Customer",
                            options: customerOptions,
                            selectedID: $selectedCustomerID,
                            placeholder: "Choose customer"
                        )
                    }

                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                    TextField("Notes", text: $note)
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        guard let selectedCustomer, let amount = Double(amountText), amount > 0 else { return }
                        onCreate(selectedCustomer, amount, note.isEmpty ? nil : note)
                        dismiss()
                    }
                    .disabled(selectedCustomer == nil || Double(amountText) == nil)
                }
            }
            .onAppear {
                selectedCustomerID = selectedCustomerID ?? customerRefs.first?.value
            }
        }
    }
}

private struct QuickBooksEstimateComposeView: View {
    @Environment(\.dismiss) private var dismiss

    let customers: [QuickBooksCustomer]
    let onCreate: (QuickBooksCustomer, Double, String?, String?, Bool) -> Void

    @State private var selectedCustomerID: String?
    @State private var amountText = ""
    @State private var note = ""
    @State private var emailAddress = ""
    @State private var sendAfterCreate = true

    private var selectedCustomer: QuickBooksCustomer? {
        if let selectedCustomerID, let match = customers.first(where: { $0.Id == selectedCustomerID }) {
            return match
        }
        return customers.first
    }

    private var customerOptions: [SearchableDropdownOption] {
        customers.map { customer in
            SearchableDropdownOption(
                id: customer.Id,
                title: customer.DisplayName,
                subtitle: customer.PrimaryEmailAddr?.Address ?? customer.PrimaryPhone?.FreeFormNumber
            )
        }
    }

    private var canCreate: Bool {
        guard let amount = Double(amountText), amount > 0 else { return false }
        return selectedCustomer != nil &&
        (sendAfterCreate == false || !emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Create Estimate") {
                    if customers.isEmpty {
                        Text("Sync QuickBooks customers first.")
                            .foregroundColor(.secondary)
                    } else {
                        SearchableDropdownPicker(
                            title: "Customer",
                            options: customerOptions,
                            selectedID: $selectedCustomerID,
                            placeholder: "Choose customer"
                        )
                    }

                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                    TextField("Notes", text: $note)
                }

                Section("Delivery") {
                    Toggle("Email estimate after creating", isOn: $sendAfterCreate)
                    TextField("Customer email", text: $emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Create Estimate")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sendAfterCreate ? "Create & Send" : "Create") {
                        guard let selectedCustomer, let amount = Double(amountText), amount > 0 else { return }
                        onCreate(
                            selectedCustomer,
                            amount,
                            note.isEmpty ? nil : note,
                            emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : emailAddress,
                            sendAfterCreate
                        )
                        dismiss()
                    }
                    .disabled(!canCreate)
                }
            }
            .onAppear {
                selectedCustomerID = selectedCustomerID ?? customers.first?.Id
                emailAddress = selectedCustomer?.PrimaryEmailAddr?.Address ?? emailAddress
            }
            .onChange(of: selectedCustomerID) { _, _ in
                emailAddress = selectedCustomer?.PrimaryEmailAddr?.Address ?? ""
            }
        }
    }
}

private struct QuickBooksInvoiceComposeView: View {
    @Environment(\.dismiss) private var dismiss

    let customers: [QuickBooksCustomer]
    let onCreate: (QuickBooksCustomer, Double, String?, String?, Bool) -> Void

    @State private var selectedCustomerID: String?
    @State private var amountText = ""
    @State private var note = ""
    @State private var emailAddress = ""
    @State private var sendAfterCreate = true

    private var selectedCustomer: QuickBooksCustomer? {
        if let selectedCustomerID, let match = customers.first(where: { $0.Id == selectedCustomerID }) {
            return match
        }
        return customers.first
    }

    private var customerOptions: [SearchableDropdownOption] {
        customers.map { customer in
            SearchableDropdownOption(
                id: customer.Id,
                title: customer.DisplayName,
                subtitle: customer.PrimaryEmailAddr?.Address ?? customer.PrimaryPhone?.FreeFormNumber
            )
        }
    }

    private var canCreate: Bool {
        guard let amount = Double(amountText), amount > 0 else { return false }
        return selectedCustomer != nil &&
        (sendAfterCreate == false || !emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Create Invoice") {
                    if customers.isEmpty {
                        Text("Sync QuickBooks customers first.")
                            .foregroundColor(.secondary)
                    } else {
                        SearchableDropdownPicker(
                            title: "Customer",
                            options: customerOptions,
                            selectedID: $selectedCustomerID,
                            placeholder: "Choose customer"
                        )
                    }

                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                    TextField("Notes", text: $note)
                }

                Section("Delivery") {
                    Toggle("Email invoice after creating", isOn: $sendAfterCreate)
                    TextField("Customer email", text: $emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Create Invoice")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sendAfterCreate ? "Create & Send" : "Create") {
                        guard let selectedCustomer, let amount = Double(amountText), amount > 0 else { return }
                        onCreate(
                            selectedCustomer,
                            amount,
                            note.isEmpty ? nil : note,
                            emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : emailAddress,
                            sendAfterCreate
                        )
                        dismiss()
                    }
                    .disabled(!canCreate)
                }
            }
            .onAppear {
                selectedCustomerID = selectedCustomerID ?? customers.first?.Id
                emailAddress = selectedCustomer?.PrimaryEmailAddr?.Address ?? emailAddress
            }
            .onChange(of: selectedCustomerID) { _, _ in
                emailAddress = selectedCustomer?.PrimaryEmailAddr?.Address ?? ""
            }
        }
    }
}

private struct QuickBooksBillComposeView: View {
    @Environment(\.dismiss) private var dismiss

    let vendorRefs: [QuickBooksReference]
    let onCreate: (QuickBooksReference, Double, String?) -> Void

    @State private var selectedVendorID: String?
    @State private var amountText = ""
    @State private var note = ""
    @State private var showingCreateConfirmation = false

    private var vendorOptions: [SearchableDropdownOption] {
        vendorRefs.map { SearchableDropdownOption(id: $0.value, title: $0.displayName, subtitle: $0.value) }
    }

    private var selectedVendor: QuickBooksReference? {
        if let selectedVendorID, let match = vendorRefs.first(where: { $0.value == selectedVendorID }) {
            return match
        }
        return vendorRefs.first
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Create Bill") {
                    Text("Use this only for an ad hoc expense that has no GunnAire purchase order. For supplier invoices tied to received material, use Receipts & Bills → Purchasing so three-way review and duplicate recovery are preserved.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    if vendorRefs.isEmpty {
                        Text("Sync QuickBooks vendors first.")
                            .foregroundColor(.secondary)
                    } else {
                        SearchableDropdownPicker(
                            title: "Vendor",
                            options: vendorOptions,
                            selectedID: $selectedVendorID,
                            placeholder: "Choose vendor"
                        )
                    }

                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                    TextField("Notes", text: $note)
                }
            }
            .navigationTitle("Create Bill")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Review") {
                        showingCreateConfirmation = true
                    }
                    .disabled(selectedVendor == nil || (Double(amountText) ?? 0) <= 0)
                }
            }
            .onAppear {
                selectedVendorID = selectedVendorID ?? vendorRefs.first?.value
            }
            .confirmationDialog(
                "Create ad hoc QuickBooks Bill?",
                isPresented: $showingCreateConfirmation,
                titleVisibility: .visible
            ) {
                Button("Create Bill") {
                    guard let selectedVendor, let amount = Double(amountText), amount > 0 else { return }
                    onCreate(selectedVendor, amount, note.isEmpty ? nil : note)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Vendor: \(selectedVendor?.displayName ?? "Not selected")\nAmount: \((Double(amountText) ?? 0).formatted(.currency(code: "USD")))\n\nThis creates an unpaid bill directly in QuickBooks and is not linked to a GunnAire purchase order.")
            }
        }
    }
}

private struct QuickBooksPurchaseComposeView: View {
    @Environment(\.dismiss) private var dismiss

    let vendorRefs: [QuickBooksReference]
    let onCreate: (QuickBooksReference, Double, String?, String) -> Void

    @State private var selectedVendorID: String?
    @State private var amountText = ""
    @State private var note = ""
    @State private var paymentType = "Cash"

    private var vendorOptions: [SearchableDropdownOption] {
        vendorRefs.map { SearchableDropdownOption(id: $0.value, title: $0.displayName, subtitle: $0.value) }
    }

    private var selectedVendor: QuickBooksReference? {
        if let selectedVendorID, let match = vendorRefs.first(where: { $0.value == selectedVendorID }) {
            return match
        }
        return vendorRefs.first
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Create Purchase") {
                    if vendorRefs.isEmpty {
                        Text("Sync QuickBooks vendors first.")
                            .foregroundColor(.secondary)
                    } else {
                        SearchableDropdownPicker(
                            title: "Vendor",
                            options: vendorOptions,
                            selectedID: $selectedVendorID,
                            placeholder: "Choose vendor"
                        )
                    }

                    Menu {
                        Button("Cash") { paymentType = "Cash" }
                        Button("Check") { paymentType = "Check" }
                        Button("Credit Card") { paymentType = "CreditCard" }
                    } label: {
                        HStack {
                            Text("Payment Type")
                            Spacer()
                            Text(paymentType == "CreditCard" ? "Credit Card" : paymentType)
                                .foregroundColor(.secondary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                        }
                    }

                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                    TextField("Notes", text: $note)
                }
            }
            .navigationTitle("Create Purchase")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        guard let selectedVendor, let amount = Double(amountText), amount > 0 else { return }
                        onCreate(selectedVendor, amount, note.isEmpty ? nil : note, paymentType)
                        dismiss()
                    }
                    .disabled(selectedVendor == nil || Double(amountText) == nil)
                }
            }
            .onAppear {
                selectedVendorID = selectedVendorID ?? vendorRefs.first?.value
            }
        }
    }
}

private struct QuickBooksPaymentComposeView: View {
    @Environment(\.dismiss) private var dismiss

    let invoices: [QuickBooksInvoice]
    let paymentMethods: [QuickBooksPaymentMethod]
    let onAdd: (QuickBooksInvoice, Double, String?, QuickBooksReference?) -> Void

    @State private var selectedInvoiceID: String?
    @State private var selectedPaymentMethodID: String?
    @State private var amountText = ""
    @State private var note = ""

    private var invoiceOptions: [SearchableDropdownOption] {
        invoices.map { invoice in
            let title = "\(invoice.DocNumber ?? invoice.Id) · \(invoice.CustomerRef.displayName)"
            let balance = invoice.Balance ?? invoice.TotalAmt
            return SearchableDropdownOption(
                id: invoice.Id,
                title: title,
                subtitle: balance.formatted(.currency(code: "USD"))
            )
        }
    }

    private var paymentMethodOptions: [SearchableDropdownOption] {
        paymentMethods.map { SearchableDropdownOption(id: $0.Id, title: $0.Name) }
    }

    private var selectedInvoice: QuickBooksInvoice? {
        if let selectedInvoiceID, let match = invoices.first(where: { $0.Id == selectedInvoiceID }) {
            return match
        }
        return invoices.first
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Record Payment") {
                    if invoices.isEmpty {
                        Text("Sync QuickBooks invoices first.")
                            .foregroundColor(.secondary)
                    } else {
                        SearchableDropdownPicker(
                            title: "Invoice",
                            options: invoiceOptions,
                            selectedID: $selectedInvoiceID,
                            placeholder: "Choose invoice"
                        )

                        SearchableDropdownPicker(
                            title: "Payment Method",
                            options: paymentMethodOptions,
                            selectedID: $selectedPaymentMethodID,
                            placeholder: "None",
                            showsClearButton: true
                        )
                    }

                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                    TextField("Notes", text: $note)
                }
            }
            .navigationTitle("Record Payment")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        guard let selectedInvoice, let amount = Double(amountText), amount > 0 else { return }
                        let paymentMethodRef = paymentMethods.first(where: { $0.Id == selectedPaymentMethodID })?.reference
                        onAdd(selectedInvoice, amount, note.isEmpty ? nil : note, paymentMethodRef)
                        dismiss()
                    }
                    .disabled(selectedInvoice == nil || Double(amountText) == nil)
                }
            }
            .onAppear {
                selectedInvoiceID = selectedInvoiceID ?? invoices.first?.Id
                if let selectedInvoice, amountText.isEmpty {
                    amountText = String(format: "%.2f", max(selectedInvoice.Balance ?? selectedInvoice.TotalAmt, 0))
                }
                if selectedPaymentMethodID == nil {
                    selectedPaymentMethodID = paymentMethods.first(where: { $0.Name.caseInsensitiveCompare("QuickBooks Card") == .orderedSame })?.Id
                        ?? paymentMethods.first?.Id
                }
            }
            .onChange(of: selectedInvoiceID) { _, _ in
                guard let invoice = selectedInvoice else { return }
                amountText = String(format: "%.2f", max(invoice.Balance ?? invoice.TotalAmt, 0))
            }
        }
    }
}

private struct QuickBooksStoreCardComposeView: View {
    @Environment(\.dismiss) private var dismiss

    let customers: [QuickBooksCustomer]
    let onStore: (QuickBooksCustomer, QuickBooksPaymentsCardInput) -> Void

    @State private var selectedCustomerID: String?
    @State private var cardholderName = ""
    @State private var cardNumber = ""
    @State private var expirationMonth = ""
    @State private var expirationYear = ""
    @State private var cvc = ""
    @State private var streetAddress = ""
    @State private var city = ""
    @State private var region = ""
    @State private var postalCode = ""

    private var selectedCustomer: QuickBooksCustomer? {
        if let selectedCustomerID, let match = customers.first(where: { $0.Id == selectedCustomerID }) {
            return match
        }
        return customers.first
    }

    private var customerOptions: [SearchableDropdownOption] {
        customers.map { customer in
            SearchableDropdownOption(
                id: customer.Id,
                title: customer.DisplayName,
                subtitle: customer.PrimaryEmailAddr?.Address ?? customer.PrimaryPhone?.FreeFormNumber
            )
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Customer") {
                    if customers.isEmpty {
                        Text("Sync QuickBooks customers before storing a card.")
                            .foregroundColor(.secondary)
                    } else {
                        SearchableDropdownPicker(
                            title: "QuickBooks Customer",
                            options: customerOptions,
                            selectedID: $selectedCustomerID,
                            placeholder: "Choose customer"
                        )
                    }
                }

                Section("Store Card") {
                    TextField("Cardholder name", text: $cardholderName)
                    SecureField("Card number", text: $cardNumber)
                        .keyboardType(.numberPad)
                        .privacySensitive()
                    TextField("Exp MM", text: $expirationMonth)
                        .keyboardType(.numberPad)
                    TextField("Exp YYYY", text: $expirationYear)
                        .keyboardType(.numberPad)
                    SecureField("CVC", text: $cvc)
                        .keyboardType(.numberPad)
                        .privacySensitive()
                    TextField("Street Address", text: $streetAddress)
                    TextField("City", text: $city)
                    TextField("State", text: $region)
                    TextField("Postal Code", text: $postalCode)
                        .keyboardType(.numbersAndPunctuation)
                    Text("QuickBooks requires stored cards to be attached to a customer. Card number and CVC are only used to create a Payments token and are not saved locally.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Store Card")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Store") {
                        guard let selectedCustomer else { return }
                        onStore(
                            selectedCustomer,
                            QuickBooksPaymentsCardInput(
                                cardholderName: cardholderName,
                                cardNumber: cardNumber.filter(\.isNumber),
                                expMonth: expirationMonth.filter(\.isNumber),
                                expYear: expirationYear.filter(\.isNumber),
                                cvc: cvc.filter(\.isNumber),
                                postalCode: postalCode.nilIfBlank,
                                addressLine: streetAddress.nilIfBlank,
                                city: city.nilIfBlank,
                                region: region.nilIfBlank,
                                country: "US"
                            )
                        )
                        dismiss()
                    }
                    .disabled(
                        selectedCustomer == nil ||
                        cardholderName.isEmpty ||
                        cardNumber.filter(\.isNumber).count < 12 ||
                        expirationMonth.filter(\.isNumber).isEmpty ||
                        expirationYear.filter(\.isNumber).count != 4 ||
                        cvc.filter(\.isNumber).count < 3
                    )
                }
            }
            .onAppear {
                selectedCustomerID = selectedCustomerID ?? customers.first?.Id
                if let selectedCustomer, cardholderName.isEmpty {
                    cardholderName = selectedCustomer.DisplayName
                }
            }
            .onChange(of: selectedCustomerID) { _, _ in
                if let selectedCustomer, cardholderName.isEmpty {
                    cardholderName = selectedCustomer.DisplayName
                }
            }
        }
    }
}

private struct QuickBooksCardChargeComposeView: View {
    @Environment(\.dismiss) private var dismiss

    let invoices: [Invoice]
    let payments: [Payment]
    let onProcess: (Invoice, Double, QuickBooksPaymentsCardInput, String?) -> Void

    @State private var selectedInvoiceID: String?
    @State private var amountText = ""
    @State private var note = ""
    @State private var cardholderName = ""
    @State private var cardNumber = ""
    @State private var expirationMonth = ""
    @State private var expirationYear = ""
    @State private var cvc = ""
    @State private var postalCode = ""

    private var selectedInvoice: Invoice? {
        if let selectedInvoiceID, let match = invoices.first(where: { $0.id.uuidString == selectedInvoiceID }) {
            return match
        }
        return invoices.first
    }

    private var invoiceOptions: [SearchableDropdownOption] {
        invoices.map { invoice in
            SearchableDropdownOption(
                id: invoice.id.uuidString,
                title: "\(invoice.customer.name) · \(invoice.amount.formatted(.currency(code: "USD")))",
                subtitle: invoice.quickBooksID.map { "QBO \($0)" }
            )
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Process Card Charge") {
                    if invoices.isEmpty {
                        Text("Create and sync an invoice first.")
                            .foregroundColor(.secondary)
                    } else {
                        SearchableDropdownPicker(
                            title: "Invoice",
                            options: invoiceOptions,
                            selectedID: $selectedInvoiceID,
                            placeholder: "Choose invoice"
                        )
                    }

                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                    TextField("Notes", text: $note)
                    TextField("Cardholder name", text: $cardholderName)
                    SecureField("Card number", text: $cardNumber)
                        .keyboardType(.numberPad)
                        .privacySensitive()
                    HStack {
                        TextField("Exp MM", text: $expirationMonth)
                            .keyboardType(.numberPad)
                        TextField("Exp YYYY", text: $expirationYear)
                            .keyboardType(.numberPad)
                        SecureField("CVC", text: $cvc)
                            .keyboardType(.numberPad)
                            .privacySensitive()
                    }
                    TextField("Billing ZIP", text: $postalCode)
                        .keyboardType(.numbersAndPunctuation)
                    Text("Card details are only used to create a QuickBooks Payments token for this transaction and are not saved locally.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Card Charge")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Process") {
                        guard let invoice = selectedInvoice, let amount = Double(amountText), amount > 0 else { return }
                        let input = QuickBooksPaymentsCardInput(
                            cardholderName: cardholderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? invoice.customer.name : cardholderName.trimmingCharacters(in: .whitespacesAndNewlines),
                            cardNumber: cardNumber.filter(\.isNumber),
                            expMonth: expirationMonth.filter(\.isNumber),
                            expYear: expirationYear.filter(\.isNumber),
                            cvc: cvc.filter(\.isNumber),
                            postalCode: postalCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : postalCode.trimmingCharacters(in: .whitespacesAndNewlines),
                            addressLine: invoice.customer.address,
                            city: nil,
                            region: nil,
                            country: "US"
                        )
                        onProcess(invoice, amount, input, note.nilIfBlank)
                        dismiss()
                    }
                    .disabled(
                        selectedInvoice == nil ||
                        Double(amountText) == nil ||
                        cardNumber.filter(\.isNumber).count < 12 ||
                        expirationYear.filter(\.isNumber).count != 4 ||
                        cvc.filter(\.isNumber).count < 3
                    )
                }
            }
            .onAppear {
                selectedInvoiceID = selectedInvoiceID ?? invoices.first?.id.uuidString
                guard let selectedInvoice else { return }
                amountText = String(format: "%.2f", outstandingBalance(for: selectedInvoice))
                cardholderName = selectedInvoice.customer.name
            }
            .onChange(of: selectedInvoiceID) { _, _ in
                guard let invoice = selectedInvoice else { return }
                amountText = String(format: "%.2f", outstandingBalance(for: invoice))
                cardholderName = invoice.customer.name
            }
        }
    }

    private func outstandingBalance(for invoice: Invoice) -> Double {
        Invoice.outstandingBalance(for: invoice, payments: payments)
    }
}

private struct QuickBooksRefundComposeView: View {
    @Environment(\.dismiss) private var dismiss

    let payment: Payment
    let onRefund: (Double, String?) -> Void

    @State private var amountText = ""
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Refund Payment") {
                    Text(payment.invoice.customer.name)
                    Text("Original payment: \(payment.amount.formatted(.currency(code: "USD")))")
                    TextField("Refund amount", text: $amountText)
                        .keyboardType(.decimalPad)
                    TextField("Notes", text: $note)
                }
            }
            .navigationTitle("Refund")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Refund") {
                        guard let amount = Double(amountText), amount > 0 else { return }
                        onRefund(amount, note.nilIfBlank)
                        dismiss()
                    }
                    .disabled(Double(amountText) == nil)
                }
            }
            .onAppear {
                amountText = String(format: "%.2f", payment.amount)
                note = payment.notes ?? ""
            }
        }
    }
}

private struct QuickBooksVendorComposeView: View {
    @Environment(\.dismiss) private var dismiss

    let onAdd: (String, String?, String?) -> Void

    @State private var name = ""
    @State private var email = ""
    @State private var phone = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Vendor") {
                    TextField("Vendor Name", text: $name)
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                    TextField("Phone", text: $phone)
                        .keyboardType(.phonePad)
                }
            }
            .navigationTitle("Add Vendor")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onAdd(
                            name.trimmingCharacters(in: .whitespacesAndNewlines),
                            email.nilIfBlank,
                            phone.nilIfBlank
                        )
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct QuickBooksCustomerComposeView: View {
    @Environment(\.dismiss) private var dismiss

    let onCreate: (String, String?, String?) -> Void

    @State private var name = ""
    @State private var email = ""
    @State private var phone = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Customer") {
                    TextField("Customer Name", text: $name)
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                    TextField("Phone", text: $phone)
                        .keyboardType(.phonePad)
                }
            }
            .navigationTitle("Add Customer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(
                            name.trimmingCharacters(in: .whitespacesAndNewlines),
                            email.nilIfBlank,
                            phone.nilIfBlank
                        )
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct QuickBooksLocalCatalogItemEditView: View {
    @Environment(\.dismiss) private var dismiss

    let item: Item
    let catalogItems: [Item]
    let vendors: [QuickBooksVendor]
    let onSaved: () -> Void

    @State private var name: String
    @State private var itemType: CatalogItemType
    @State private var description: String
    @State private var sku: String
    @State private var unitPrice: String
    @State private var purchaseCost: String
    @State private var isTaxable: Bool
    @State private var purchaseDescription: String
    @State private var preferredVendorID: String
    @State private var isAssemblyEnabled: Bool
    @State private var assemblyPresentation: CatalogAssemblyPresentation
    @State private var assemblyComponents: [CatalogAssemblyComponentDefinition]
    @State private var assemblySearchText = ""
    @State private var assemblyValidationMessage: String?

    init(
        item: Item,
        catalogItems: [Item],
        vendors: [QuickBooksVendor],
        onSaved: @escaping () -> Void
    ) {
        self.item = item
        self.catalogItems = catalogItems
        self.vendors = vendors
        self.onSaved = onSaved
        let assembly = item.assemblyDefinition
        _name = State(initialValue: item.name)
        _itemType = State(initialValue: item.itemType)
        _description = State(initialValue: item.itemDescription ?? "")
        _sku = State(initialValue: item.sku ?? "")
        _unitPrice = State(initialValue: String(format: "%.2f", item.unitPrice))
        _purchaseCost = State(initialValue: item.purchaseCost.map { String(format: "%.2f", $0) } ?? "")
        _isTaxable = State(initialValue: item.isTaxable)
        _purchaseDescription = State(initialValue: item.purchaseDescription ?? "")
        _preferredVendorID = State(initialValue: item.preferredVendorQuickBooksID ?? "")
        _isAssemblyEnabled = State(initialValue: assembly != nil)
        _assemblyPresentation = State(initialValue: assembly?.presentation ?? .flatRate)
        _assemblyComponents = State(initialValue: assembly?.components ?? [])
    }

    private var parsedUnitPrice: Double? {
        Double(unitPrice.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var parsedPurchaseCost: Double? {
        let value = purchaseCost.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : Double(value)
    }

    private var isUnlinkedPricebookReview: Bool {
        item.requiresPricebookReview &&
        item.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }

    private var editableItemType: CatalogItemType {
        isUnlinkedPricebookReview ? itemType : item.itemType
    }

    private var canSave: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 100,
              let parsedUnitPrice, parsedUnitPrice.isFinite, parsedUnitPrice >= 0 else { return false }
        if !purchaseCost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let parsedPurchaseCost, parsedPurchaseCost.isFinite, parsedPurchaseCost >= 0 else { return false }
        }
        guard description.count <= 4_000,
              sku.count <= 100,
              purchaseDescription.count <= 4_000 else { return false }
        if isAssemblyEnabled {
            guard editableItemType == .service,
                  !assemblyComponents.isEmpty,
                  assemblyComponents.count <= CatalogAssemblyPolicy.maximumComponentCount,
                  assemblyComponents.allSatisfy({
                      $0.quantity.isFinite &&
                      $0.quantity > 0 &&
                      $0.quantity <= CatalogAssemblyPolicy.maximumComponentQuantity
                  }) else { return false }
        }
        return true
    }

    private var selectedPreferredVendor: QuickBooksVendor? {
        vendors.first(where: { $0.Id == preferredVendorID })
    }

    private var proposedAccountingSnapshot: QuickBooksCatalogAccountingSnapshot? {
        guard let parsedUnitPrice else { return nil }
        return QuickBooksCatalogAccountingSnapshot(
            name: name,
            itemType: editableItemType,
            itemDescription: nilIfBlank(description),
            sku: nilIfBlank(sku),
            unitPrice: parsedUnitPrice,
            purchaseCost: parsedPurchaseCost,
            isTaxable: isTaxable,
            purchaseDescription: nilIfBlank(purchaseDescription),
            preferredVendorQuickBooksID: selectedPreferredVendor?.Id ?? item.preferredVendorQuickBooksID
        )
    }

    private var quickBooksFieldsRequireStaging: Bool {
        guard let proposedAccountingSnapshot else { return true }
        return QuickBooksCatalogStagingPolicy.requiresQuickBooksStaging(
            current: item,
            proposed: proposedAccountingSnapshot
        )
    }

    private var availableAssemblyItems: [Item] {
        let selectedIDs = Set(assemblyComponents.map(\.itemID))
        let query = assemblySearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return catalogItems
            .filter { candidate in
                guard candidate.id != item.id,
                      candidate.assemblyDefinition == nil,
                      !selectedIDs.contains(candidate.id) else { return false }
                if query.isEmpty { return true }
                return [candidate.name, candidate.sku, candidate.itemDescription]
                    .compactMap { $0?.lowercased() }
                    .joined(separator: " ")
                    .contains(query)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .prefix(8)
            .map { $0 }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Sales") {
                    TextField("Item name", text: $name)
                        .accessibilityIdentifier("CatalogEditName")
                    if isUnlinkedPricebookReview {
                        Picker("Item Type", selection: $itemType) {
                            ForEach(CatalogItemType.allCases) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("PricebookReviewItemType")
                        .onChange(of: itemType) { _, newType in
                            if newType != .service {
                                isAssemblyEnabled = false
                            }
                        }
                    } else {
                        LabeledContent("Item type", value: item.itemType.rawValue)
                        Text("Changing a linked QuickBooks item type can alter accounting behavior. Create a new item when the type must change.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                    TextField("SKU", text: $sku)
                        .textInputAutocapitalization(.characters)
                    TextField("Sales price", text: $unitPrice)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("CatalogEditSalesPrice")
                    Toggle("Taxable", isOn: $isTaxable)
                }

                Section("Purchasing") {
                    TextField("Purchase cost", text: $purchaseCost)
                        .keyboardType(.decimalPad)
                    TextField("Purchase description", text: $purchaseDescription, axis: .vertical)
                        .lineLimit(2...4)
                    Picker("Preferred vendor", selection: $preferredVendorID) {
                        if item.preferredVendorQuickBooksID?.isEmpty == false {
                            Text(item.preferredVendorName ?? "Current vendor")
                                .tag(item.preferredVendorQuickBooksID ?? "")
                        } else {
                            Text("None").tag("")
                        }
                        ForEach(vendors) { vendor in
                            Text(vendor.DisplayName).tag(vendor.Id)
                        }
                    }
                    Text("A linked preferred vendor can be replaced here. Removing it requires review in QuickBooks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if editableItemType == .service {
                    Section("Service Package") {
                        Toggle("Reusable service package", isOn: $isAssemblyEnabled)
                            .accessibilityIdentifier("CatalogAssemblyEnabled")

                        if isAssemblyEnabled {
                            Picker("Customer presentation", selection: $assemblyPresentation) {
                                ForEach(CatalogAssemblyPresentation.allCases) { presentation in
                                    Text(presentation.label).tag(presentation)
                                }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier("CatalogAssemblyPresentation")

                            Text(assemblyPresentation.explanation)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if assemblyComponents.isEmpty {
                                Label(
                                    "Add at least one approved labor, material, or equipment item.",
                                    systemImage: "shippingbox"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            } else {
                                ForEach(assemblyComponents) { component in
                                    HStack(alignment: .center, spacing: 10) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(assemblyItemName(component.itemID))
                                            if let sku = assemblyItem(component.itemID)?.sku,
                                               !sku.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                                Text("SKU \(sku)")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        Stepper(
                                            "Qty \(component.quantity.formatted(.number.precision(.fractionLength(0...2))))",
                                            value: assemblyQuantityBinding(for: component.itemID),
                                            in: 0.25...CatalogAssemblyPolicy.maximumComponentQuantity,
                                            step: 0.25
                                        )
                                        .labelsHidden()
                                        .accessibilityLabel("Quantity for \(assemblyItemName(component.itemID))")
                                        Button(role: .destructive) {
                                            assemblyComponents.removeAll { $0.itemID == component.itemID }
                                        } label: {
                                            Image(systemName: "minus.circle")
                                        }
                                        .buttonStyle(.borderless)
                                        .accessibilityLabel("Remove \(assemblyItemName(component.itemID))")
                                    }
                                }
                            }

                            TextField("Search pricebook items to include", text: $assemblySearchText)
                                .textInputAutocapitalization(.never)
                                .accessibilityIdentifier("CatalogAssemblySearch")

                            ForEach(availableAssemblyItems) { candidate in
                                Button {
                                    assemblyComponents.append(
                                        CatalogAssemblyComponentDefinition(itemID: candidate.id, quantity: 1)
                                    )
                                } label: {
                                    HStack {
                                        Label(candidate.name, systemImage: "plus.circle")
                                        Spacer()
                                        Text(candidate.itemType.rawValue)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.primary)
                            }

                            Text("Package revisions are copied into each estimate and invoice. Later pricebook changes never rewrite sold work.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let assemblyValidationMessage {
                            Label(assemblyValidationMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section {
                    Label(
                        isUnlinkedPricebookReview
                            ? "Save keeps this item in administrator review. QuickBooks is not changed until you approve and publish it."
                            : quickBooksFieldsRequireStaging
                                ? "Save stages the accounting-field changes in GunnAire. QuickBooks is not changed until an administrator reviews the comparison and publishes it."
                                : "Save updates GunnAire service-package details while preserving the current QuickBooks sync state.",
                        systemImage: "checkmark.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(isUnlinkedPricebookReview ? "Review Pricebook Item" : "Edit Catalog Item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        isUnlinkedPricebookReview
                            ? "Save Review Changes"
                            : quickBooksFieldsRequireStaging ? "Stage Changes" : "Save GunnAire Changes"
                    ) {
                        save()
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier(
                        isUnlinkedPricebookReview
                            ? "SavePricebookReviewChanges"
                            : "StageCatalogChanges"
                    )
                }
            }
        }
    }

    private func assemblyItem(_ itemID: UUID) -> Item? {
        catalogItems.first { $0.id == itemID }
    }

    private func assemblyItemName(_ itemID: UUID) -> String {
        assemblyItem(itemID)?.name ?? "Missing pricebook item"
    }

    private func assemblyQuantityBinding(for itemID: UUID) -> Binding<Double> {
        Binding(
            get: {
                assemblyComponents.first(where: { $0.itemID == itemID })?.quantity ?? 1
            },
            set: { quantity in
                guard let index = assemblyComponents.firstIndex(where: { $0.itemID == itemID }) else { return }
                assemblyComponents[index] = CatalogAssemblyComponentDefinition(
                    itemID: itemID,
                    quantity: min(max(quantity, 0.25), CatalogAssemblyPolicy.maximumComponentQuantity)
                )
            }
        )
    }

    private func candidateAssemblyDefinition() -> CatalogAssemblyDefinition? {
        guard isAssemblyEnabled else { return nil }
        let existing = item.assemblyDefinition
        let contentIsUnchanged = existing?.presentation == assemblyPresentation &&
            existing?.components == assemblyComponents
        let revision = contentIsUnchanged
            ? (existing?.revision ?? 1)
            : ((existing?.revision ?? 0) + 1)
        return CatalogAssemblyDefinition(
            revision: revision,
            presentation: assemblyPresentation,
            components: assemblyComponents
        )
    }

    private func save() {
        guard canSave,
              let parsedUnitPrice,
              let proposedAccountingSnapshot else { return }
        let shouldStageQuickBooksUpdate = QuickBooksCatalogStagingPolicy.requiresQuickBooksStaging(
            current: item,
            proposed: proposedAccountingSnapshot
        )
        let assemblyDefinition = candidateAssemblyDefinition()
        if let assemblyDefinition {
            do {
                _ = try CatalogAssemblyPolicy.resolve(
                    root: item,
                    definition: assemblyDefinition,
                    catalogItems: catalogItems,
                    rootItemType: editableItemType
                )
            } catch {
                assemblyValidationMessage = error.localizedDescription
                return
            }
        }
        assemblyValidationMessage = nil
        item.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if isUnlinkedPricebookReview {
            item.itemType = itemType
        }
        item.itemDescription = nilIfBlank(description)
        item.sku = nilIfBlank(sku)
        item.unitPrice = parsedUnitPrice
        item.purchaseCost = parsedPurchaseCost
        item.isTaxable = isTaxable
        item.purchaseDescription = nilIfBlank(purchaseDescription)
        if let selectedVendor = selectedPreferredVendor {
            item.preferredVendorQuickBooksID = selectedVendor.Id
            item.preferredVendorName = selectedVendor.DisplayName
        }
        item.assemblyDefinition = assemblyDefinition
        if shouldStageQuickBooksUpdate {
            item.stageQuickBooksCatalogUpdate()
        } else {
            item.timestamp = Date()
        }
        onSaved()
        dismiss()
    }

    private func nilIfBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct QuickBooksCatalogItemDraft {
    let name: String
    let itemType: CatalogItemType
    let sku: String?
    let price: Double
    let purchaseCost: Double?
    let description: String?
    let purchaseDescription: String?
    let vendorRef: QuickBooksReference?
}

private struct QuickBooksCatalogItemComposeView: View {
    @Environment(\.dismiss) private var dismiss

    let vendors: [QuickBooksVendor]
    let onCreate: (QuickBooksCatalogItemDraft) -> Void

    @State private var name = ""
    @State private var itemType: CatalogItemType = .service
    @State private var sku = ""
    @State private var price = ""
    @State private var purchaseCost = ""
    @State private var description = ""
    @State private var purchaseDescription = ""
    @State private var selectedVendorID = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Sales") {
                    TextField("Name", text: $name)
                    TextField("SKU", text: $sku)
                        .textInputAutocapitalization(.characters)
                    Picker("Item Type", selection: $itemType) {
                        ForEach(CatalogItemType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    TextField("Price (optional)", text: $price)
                        .keyboardType(.decimalPad)
                    TextField("Description", text: $description)
                }

                Section("Purchasing") {
                    TextField("Purchase price", text: $purchaseCost)
                        .keyboardType(.decimalPad)
                    if !vendors.isEmpty {
                        Picker("Preferred vendor", selection: $selectedVendorID) {
                            Text("None").tag("")
                            ForEach(vendors) { vendor in
                                Text(vendor.DisplayName).tag(vendor.Id)
                            }
                        }
                    }
                    TextField("Purchase notes", text: $purchaseDescription, axis: .vertical)
                        .lineLimit(2...3)
                }
            }
            .navigationTitle("Add Catalog Item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        guard let amount = QuickBooksCatalogAmountParser.parseRequiredOrZero(price), amount >= 0 else { return }
                        let vendorRef = vendors.first { $0.Id == selectedVendorID }?.reference
                        onCreate(QuickBooksCatalogItemDraft(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            itemType: itemType,
                            sku: sku.nilIfBlank,
                            price: amount,
                            purchaseCost: QuickBooksCatalogAmountParser.parseOptional(purchaseCost),
                            description: description.nilIfBlank,
                            purchaseDescription: purchaseDescription.nilIfBlank,
                            vendorRef: vendorRef
                        )
                        )
                        dismiss()
                    }
                    .disabled(
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        QuickBooksCatalogAmountParser.parseRequiredOrZero(price) == nil ||
                        !QuickBooksCatalogAmountParser.isValidOptionalAmount(purchaseCost)
                    )
                }
            }
        }
    }
}

private enum QuickBooksCatalogAmountParser {
    static func parseRequiredOrZero(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let normalized = trimmed
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
        return Double(normalized)
    }

    static func parseOptional(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return parseRequiredOrZero(trimmed)
    }

    static func isValidOptionalAmount(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || parseRequiredOrZero(trimmed) != nil
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
