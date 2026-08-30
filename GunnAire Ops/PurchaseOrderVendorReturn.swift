import Foundation

enum PurchaseOrderVendorReturnStatus: String, Codable, CaseIterable, Identifiable {
    case pending
    case sent
    case returned
    case creditReceived = "credit_received"
    case cancelled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pending: "Pending"
        case .sent: "Sent"
        case .returned: "Returned"
        case .creditReceived: "Credit Received"
        case .cancelled: "Cancelled"
        }
    }

    var isTerminal: Bool {
        self == .creditReceived || self == .cancelled
    }
}

/// One purchase-order line committed to a supplier return. Serialized IDs are
/// required whenever a received line contains serialized equipment so the
/// physical asset cannot also be installed or included in another RMA.
struct PurchaseOrderVendorReturnLine: Codable, Equatable, Identifiable {
    let lineID: UUID
    let itemName: String
    let quantity: Double
    let serializedAssetIDs: [UUID]?

    var id: UUID { lineID }
}

/// Accounting evidence only. Recording it never creates or modifies a
/// QuickBooks VendorCredit; the optional provider ID links an independently
/// reviewed QuickBooks transaction back to the operational return.
struct PurchaseOrderVendorCreditEvidence: Codable, Equatable {
    let reference: String
    let creditDate: Date
    let creditAmount: Double
    let restockingFee: Double
    let taxCredit: Double
    let shippingCredit: Double
    let sourceDocumentName: String?
    let quickBooksVendorCreditID: String?
    let quickBooksPublishedByEmail: String?
    let quickBooksPublishedAt: Date?
    let note: String?
    let recordedByEmail: String
    let recordedAt: Date

    init(
        reference: String,
        creditDate: Date,
        creditAmount: Double,
        restockingFee: Double,
        taxCredit: Double,
        shippingCredit: Double,
        sourceDocumentName: String?,
        quickBooksVendorCreditID: String?,
        quickBooksPublishedByEmail: String? = nil,
        quickBooksPublishedAt: Date? = nil,
        note: String?,
        recordedByEmail: String,
        recordedAt: Date
    ) {
        self.reference = reference
        self.creditDate = creditDate
        self.creditAmount = creditAmount
        self.restockingFee = restockingFee
        self.taxCredit = taxCredit
        self.shippingCredit = shippingCredit
        self.sourceDocumentName = sourceDocumentName
        self.quickBooksVendorCreditID = quickBooksVendorCreditID
        self.quickBooksPublishedByEmail = quickBooksPublishedByEmail
        self.quickBooksPublishedAt = quickBooksPublishedAt
        self.note = note
        self.recordedByEmail = recordedByEmail
        self.recordedAt = recordedAt
    }

    func linkingQuickBooksVendorCredit(
        id quickBooksVendorCreditID: String,
        actorEmail: String,
        publishedAt: Date
    ) -> PurchaseOrderVendorCreditEvidence {
        PurchaseOrderVendorCreditEvidence(
            reference: reference,
            creditDate: creditDate,
            creditAmount: creditAmount,
            restockingFee: restockingFee,
            taxCredit: taxCredit,
            shippingCredit: shippingCredit,
            sourceDocumentName: sourceDocumentName,
            quickBooksVendorCreditID: quickBooksVendorCreditID,
            quickBooksPublishedByEmail: actorEmail,
            quickBooksPublishedAt: publishedAt,
            note: note,
            recordedByEmail: recordedByEmail,
            recordedAt: recordedAt
        )
    }
}

struct PurchaseOrderVendorReturnEvent: Codable, Equatable, Identifiable {
    let id: UUID
    let status: PurchaseOrderVendorReturnStatus
    let note: String?
    let recordedByEmail: String
    let recordedAt: Date
    let inventoryMovementIDs: [UUID]?
}

/// Immutable-in-practice reverse-procurement evidence. Status changes replace
/// this value with a copy that appends an event, preserving the complete audit
/// trail inside the existing CloudKit-backed PurchaseOrder notes envelope.
struct PurchaseOrderVendorReturn: Codable, Equatable, Identifiable {
    let id: UUID
    let reference: String
    let sourceLocation: String
    let reason: String
    let createdByEmail: String
    let createdAt: Date
    let lineAllocations: [PurchaseOrderVendorReturnLine]
    let events: [PurchaseOrderVendorReturnEvent]
    let creditEvidence: PurchaseOrderVendorCreditEvidence?

    var latestEvent: PurchaseOrderVendorReturnEvent? {
        events.max {
            if $0.recordedAt == $1.recordedAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.recordedAt < $1.recordedAt
        }
    }

    var status: PurchaseOrderVendorReturnStatus {
        latestEvent?.status ?? .pending
    }

    var totalQuantity: Double {
        lineAllocations.reduce(0) { $0 + max($1.quantity, 0) }
    }

    func replacing(
        events: [PurchaseOrderVendorReturnEvent]? = nil,
        creditEvidence: PurchaseOrderVendorCreditEvidence?? = nil
    ) -> PurchaseOrderVendorReturn {
        PurchaseOrderVendorReturn(
            id: id,
            reference: reference,
            sourceLocation: sourceLocation,
            reason: reason,
            createdByEmail: createdByEmail,
            createdAt: createdAt,
            lineAllocations: lineAllocations,
            events: events ?? self.events,
            creditEvidence: creditEvidence ?? self.creditEvidence
        )
    }
}

enum PurchaseOrderVendorCreditMatchState: String, Equatable {
    case awaitingCredit
    case matched
    case variance

    var displayName: String {
        switch self {
        case .awaitingCredit: "Vendor Credit Pending"
        case .matched: "Vendor Credit Matched"
        case .variance: "Vendor Credit Variance"
        }
    }
}

struct PurchaseOrderVendorCreditMatch: Equatable {
    let state: PurchaseOrderVendorCreditMatchState
    let merchandiseAmount: Double
    let restockingFee: Double
    let taxCredit: Double
    let shippingCredit: Double
    let expectedCreditAmount: Double
    let actualCreditAmount: Double?
    let varianceAmount: Double?

    var hasVariance: Bool { state == .variance }

    var summary: String {
        let expected = expectedCreditAmount.formatted(.currency(code: "USD"))
        guard let actualCreditAmount else {
            return "Expected \(expected)"
        }
        let actual = actualCreditAmount.formatted(.currency(code: "USD"))
        guard let varianceAmount, abs(varianceAmount) > 0.01 else {
            return "\(actual) credited • matched"
        }
        let variance = varianceAmount.formatted(
            .currency(code: "USD").sign(strategy: .always())
        )
        return "\(actual) credited vs \(expected) expected • \(variance)"
    }
}

enum PurchaseOrderVendorReturnError: LocalizedError, Equatable {
    case unauthorized
    case invalidOrderState
    case referenceRequired
    case referenceTooLong
    case duplicateReference
    case locationRequired
    case locationTooLong
    case reasonRequired
    case reasonTooLong
    case invalidLineAllocation
    case duplicateLineAllocation
    case exceedsReturnableQuantity
    case serializedQuantityMustBeWhole
    case serializedAssetCountMismatch
    case missingSerializedAsset
    case serializedAssetWrongLocation
    case serializedAssetInstalled
    case serializedAssetAlreadyCommitted
    case invalidTransition
    case noteTooLong
    case insufficientStock
    case creditReferenceRequired
    case creditReferenceTooLong
    case duplicateCreditReference
    case invalidCreditDate
    case invalidCreditAmount
    case documentNameTooLong
    case quickBooksIDTooLong
    case unableToStoreEvidence

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Only an administrator can manage supplier returns and vendor credits."
        case .invalidOrderState:
            "Create a supplier return only for items already received on this purchase order."
        case .referenceRequired:
            "Enter the supplier RMA or return reference."
        case .referenceTooLong:
            "Keep the supplier return reference to 120 characters or fewer."
        case .duplicateReference:
            "That supplier return reference is already recorded on this purchase order."
        case .locationRequired:
            "Enter the truck, warehouse, or job location sending the material back."
        case .locationTooLong:
            "Keep the return source location to 100 characters or fewer."
        case .reasonRequired:
            "Explain why the material or equipment is being returned."
        case .reasonTooLong:
            "Keep the supplier return reason to 240 characters or fewer."
        case .invalidLineAllocation:
            "Choose at least one received purchase-order item with a quantity greater than zero."
        case .duplicateLineAllocation:
            "A supplier return can include each purchase-order item only once."
        case .exceedsReturnableQuantity:
            "The return quantity exceeds what was received at this location and is not already committed to another return."
        case .serializedQuantityMustBeWhole:
            "Serialized equipment must be returned in whole units."
        case .serializedAssetCountMismatch:
            "Select one received serial number for every serialized unit being returned."
        case .missingSerializedAsset:
            "A selected serialized asset is not part of this purchase-order item."
        case .serializedAssetWrongLocation:
            "A selected serialized asset was not received at the return source location."
        case .serializedAssetInstalled:
            "Installed customer equipment cannot be returned to a supplier."
        case .serializedAssetAlreadyCommitted:
            "A selected serialized asset is already committed to another supplier return."
        case .invalidTransition:
            "That supplier-return status change is not allowed."
        case .noteTooLong:
            "Keep the return status note to 240 characters or fewer."
        case .insufficientStock:
            "The source location no longer has enough available stock. Reconcile the stock ledger before marking the return complete."
        case .creditReferenceRequired:
            "Enter the supplier credit memo or vendor credit reference."
        case .creditReferenceTooLong:
            "Keep the supplier credit reference to 120 characters or fewer."
        case .duplicateCreditReference:
            "That supplier credit reference is already recorded on this purchase order."
        case .invalidCreditDate:
            "The supplier credit date cannot be in the future."
        case .invalidCreditAmount:
            "Enter finite, non-negative credit, fee, tax, and freight amounts."
        case .documentNameTooLong:
            "Keep the source document name to 180 characters or fewer."
        case .quickBooksIDTooLong:
            "Keep the QuickBooks Vendor Credit ID to 80 characters or fewer."
        case .unableToStoreEvidence:
            "The supplier-return evidence could not be stored. The purchase order and stock ledger remain unchanged."
        }
    }
}

enum PurchaseOrderVendorReturnPolicy {
    @MainActor
    @discardableResult
    static func create(
        on order: PurchaseOrder,
        reference: String,
        sourceLocation: String,
        reason: String,
        lineAllocations: [PurchaseOrderVendorReturnLine],
        actorEmail: String?,
        users: [AppUser],
        at date: Date = Date(),
        returnID: UUID = UUID(),
        eventID: UUID = UUID()
    ) throws -> PurchaseOrderVendorReturn {
        try requireAdministrator(actorEmail: actorEmail, users: users)
        guard order.status == .partiallyReceived || order.status == .received,
              !order.purchaseOrderReceipts.isEmpty else {
            throw PurchaseOrderVendorReturnError.invalidOrderState
        }
        let actor = AppAccess.normalizedEmail(actorEmail)
        let normalizedReference = normalized(reference)
        guard !normalizedReference.isEmpty else {
            throw PurchaseOrderVendorReturnError.referenceRequired
        }
        guard normalizedReference.count <= 120 else {
            throw PurchaseOrderVendorReturnError.referenceTooLong
        }
        guard !order.vendorReturns.contains(where: {
            $0.reference.caseInsensitiveCompare(normalizedReference) == .orderedSame
        }) else {
            throw PurchaseOrderVendorReturnError.duplicateReference
        }
        let location = normalized(sourceLocation)
        guard !location.isEmpty else {
            throw PurchaseOrderVendorReturnError.locationRequired
        }
        guard location.count <= 100 else {
            throw PurchaseOrderVendorReturnError.locationTooLong
        }
        let normalizedReason = normalized(reason)
        guard !normalizedReason.isEmpty else {
            throw PurchaseOrderVendorReturnError.reasonRequired
        }
        guard normalizedReason.count <= 240 else {
            throw PurchaseOrderVendorReturnError.reasonTooLong
        }
        guard !lineAllocations.isEmpty else {
            throw PurchaseOrderVendorReturnError.invalidLineAllocation
        }
        let lineIDs = lineAllocations.map(\.lineID)
        guard Set(lineIDs).count == lineIDs.count else {
            throw PurchaseOrderVendorReturnError.duplicateLineAllocation
        }

        var normalizedAllocations: [PurchaseOrderVendorReturnLine] = []
        for allocation in lineAllocations {
            guard let line = order.line(for: allocation.lineID),
                  allocation.quantity.isFinite,
                  allocation.quantity > 0.0001 else {
                throw PurchaseOrderVendorReturnError.invalidLineAllocation
            }
            let returnable = order.returnableQuantity(for: line.id, at: location)
            guard allocation.quantity <= returnable + 0.0001 else {
                throw PurchaseOrderVendorReturnError.exceedsReturnableQuantity
            }

            let receivedAssets = order.receivedSerializedAssets(for: line.id)
            let selectedAssetIDs = allocation.serializedAssetIDs ?? []
            if !receivedAssets.isEmpty || line.serialTrackingRequired == true {
                let wholeQuantity = allocation.quantity.rounded()
                guard abs(allocation.quantity - wholeQuantity) <= 0.0001 else {
                    throw PurchaseOrderVendorReturnError.serializedQuantityMustBeWhole
                }
                guard selectedAssetIDs.count == Int(wholeQuantity),
                      Set(selectedAssetIDs).count == selectedAssetIDs.count else {
                    throw PurchaseOrderVendorReturnError.serializedAssetCountMismatch
                }
                let knownIDs = Set(receivedAssets.map(\.id))
                guard selectedAssetIDs.allSatisfy(knownIDs.contains) else {
                    throw PurchaseOrderVendorReturnError.missingSerializedAsset
                }
                for assetID in selectedAssetIDs {
                    guard order.receipt(containing: assetID).map({
                        sameLocation($0.destinationLocation, location)
                    }) == true else {
                        throw PurchaseOrderVendorReturnError.serializedAssetWrongLocation
                    }
                    guard order.installation(for: assetID) == nil else {
                        throw PurchaseOrderVendorReturnError.serializedAssetInstalled
                    }
                    guard order.vendorReturn(containing: assetID) == nil else {
                        throw PurchaseOrderVendorReturnError.serializedAssetAlreadyCommitted
                    }
                }
            } else if !selectedAssetIDs.isEmpty {
                throw PurchaseOrderVendorReturnError.missingSerializedAsset
            }

            normalizedAllocations.append(
                PurchaseOrderVendorReturnLine(
                    lineID: line.id,
                    itemName: line.itemName,
                    quantity: allocation.quantity,
                    serializedAssetIDs: selectedAssetIDs.isEmpty ? nil : selectedAssetIDs
                )
            )
        }

        let event = PurchaseOrderVendorReturnEvent(
            id: eventID,
            status: .pending,
            note: nil,
            recordedByEmail: actor,
            recordedAt: date,
            inventoryMovementIDs: nil
        )
        let vendorReturn = PurchaseOrderVendorReturn(
            id: returnID,
            reference: normalizedReference,
            sourceLocation: location,
            reason: normalizedReason,
            createdByEmail: actor,
            createdAt: date,
            lineAllocations: normalizedAllocations,
            events: [event],
            creditEvidence: nil
        )
        var returns = order.vendorReturns
        returns.append(vendorReturn)
        guard order.storeVendorReturns(returns) else {
            throw PurchaseOrderVendorReturnError.unableToStoreEvidence
        }
        order.updatedAt = date
        return vendorReturn
    }

    @MainActor
    static func markSent(
        returnID: UUID,
        on order: PurchaseOrder,
        note: String?,
        actorEmail: String?,
        users: [AppUser],
        at date: Date = Date(),
        eventID: UUID = UUID()
    ) throws {
        try transition(
            returnID: returnID,
            on: order,
            from: .pending,
            to: .sent,
            note: note,
            actorEmail: actorEmail,
            users: users,
            at: date,
            eventID: eventID
        )
    }

    @MainActor
    static func cancel(
        returnID: UUID,
        on order: PurchaseOrder,
        note: String?,
        actorEmail: String?,
        users: [AppUser],
        at date: Date = Date(),
        eventID: UUID = UUID()
    ) throws {
        try requireAdministrator(actorEmail: actorEmail, users: users)
        guard let vendorReturn = order.vendorReturn(withID: returnID),
              vendorReturn.status == .pending || vendorReturn.status == .sent else {
            throw PurchaseOrderVendorReturnError.invalidTransition
        }
        try replace(
            vendorReturn,
            on: order,
            withStatus: .cancelled,
            note: note,
            actorEmail: actorEmail,
            at: date,
            eventID: eventID,
            inventoryMovementIDs: nil
        )
    }

    @MainActor
    static func markReturned(
        returnID: UUID,
        on order: PurchaseOrder,
        catalogItems: [Item],
        inventoryMovements: [InventoryMovement],
        note: String?,
        actorEmail: String?,
        users: [AppUser],
        at date: Date = Date(),
        eventID: UUID = UUID()
    ) throws -> [InventoryMovement] {
        try requireAdministrator(actorEmail: actorEmail, users: users)
        guard let vendorReturn = order.vendorReturn(withID: returnID),
              vendorReturn.status == .sent else {
            throw PurchaseOrderVendorReturnError.invalidTransition
        }
        let actor = AppAccess.normalizedEmail(actorEmail)
        var movements: [InventoryMovement] = []
        for allocation in vendorReturn.lineAllocations {
            guard let item = PurchaseOrderReceiving.matchedItem(
                for: order,
                lineID: allocation.lineID,
                catalogItems: catalogItems
            ), item.tracksInventory else {
                continue
            }
            let available = InventoryLedger.availableQuantity(
                for: item.id,
                at: vendorReturn.sourceLocation,
                movements: inventoryMovements + movements
            )
            guard available + 0.0001 >= allocation.quantity else {
                throw PurchaseOrderVendorReturnError.insufficientStock
            }
            let serials = (allocation.serializedAssetIDs ?? []).compactMap { assetID in
                order.receivedSerializedAssets.first(where: { $0.id == assetID })?.serialNumber
            }
            let serialDetail = serials.isEmpty ? "" : " Serials: \(serials.joined(separator: ", "))."
            movements.append(
                InventoryMovement(
                    item: item,
                    type: .returnToVendor,
                    quantity: allocation.quantity,
                    sourceLocation: vendorReturn.sourceLocation,
                    serviceCallID: order.serviceCallID,
                    notes: "Returned to \(order.vendorName) on \(order.number), RMA \(vendorReturn.reference).\(serialDetail)",
                    createdByEmail: actor,
                    createdAt: date
                )
            )
        }
        try replace(
            vendorReturn,
            on: order,
            withStatus: .returned,
            note: note,
            actorEmail: actorEmail,
            at: date,
            eventID: eventID,
            inventoryMovementIDs: movements.map(\.id)
        )
        return movements
    }

    @MainActor
    @discardableResult
    static func recordCredit(
        returnID: UUID,
        on order: PurchaseOrder,
        reference: String,
        creditDate: Date,
        creditAmount: Double,
        restockingFee: Double,
        taxCredit: Double,
        shippingCredit: Double,
        sourceDocumentName: String?,
        quickBooksVendorCreditID: String?,
        note: String?,
        actorEmail: String?,
        users: [AppUser],
        recordedAt: Date = Date(),
        eventID: UUID = UUID()
    ) throws -> PurchaseOrderVendorCreditEvidence {
        try requireAdministrator(actorEmail: actorEmail, users: users)
        guard let vendorReturn = order.vendorReturn(withID: returnID),
              vendorReturn.status == .returned,
              vendorReturn.creditEvidence == nil else {
            throw PurchaseOrderVendorReturnError.invalidTransition
        }
        let normalizedReference = normalized(reference)
        guard !normalizedReference.isEmpty else {
            throw PurchaseOrderVendorReturnError.creditReferenceRequired
        }
        guard normalizedReference.count <= 120 else {
            throw PurchaseOrderVendorReturnError.creditReferenceTooLong
        }
        guard !order.vendorReturns.contains(where: {
            $0.creditEvidence?.reference.caseInsensitiveCompare(normalizedReference) == .orderedSame
        }) else {
            throw PurchaseOrderVendorReturnError.duplicateCreditReference
        }
        guard creditDate <= recordedAt else {
            throw PurchaseOrderVendorReturnError.invalidCreditDate
        }
        let moneyValues = [creditAmount, restockingFee, taxCredit, shippingCredit]
        guard moneyValues.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1_000_000_000 }) else {
            throw PurchaseOrderVendorReturnError.invalidCreditAmount
        }
        let documentName = normalized(sourceDocumentName)
        guard documentName.count <= 180 else {
            throw PurchaseOrderVendorReturnError.documentNameTooLong
        }
        let quickBooksID = normalized(quickBooksVendorCreditID)
        guard quickBooksID.count <= 80 else {
            throw PurchaseOrderVendorReturnError.quickBooksIDTooLong
        }
        let normalizedNote = normalized(note)
        guard normalizedNote.count <= 240 else {
            throw PurchaseOrderVendorReturnError.noteTooLong
        }
        let actor = AppAccess.normalizedEmail(actorEmail)
        let evidence = PurchaseOrderVendorCreditEvidence(
            reference: normalizedReference,
            creditDate: creditDate,
            creditAmount: creditAmount,
            restockingFee: restockingFee,
            taxCredit: taxCredit,
            shippingCredit: shippingCredit,
            sourceDocumentName: documentName.isEmpty ? nil : documentName,
            quickBooksVendorCreditID: quickBooksID.isEmpty ? nil : quickBooksID,
            note: normalizedNote.isEmpty ? nil : normalizedNote,
            recordedByEmail: actor,
            recordedAt: recordedAt
        )
        let event = PurchaseOrderVendorReturnEvent(
            id: eventID,
            status: .creditReceived,
            note: normalizedNote.isEmpty ? nil : normalizedNote,
            recordedByEmail: actor,
            recordedAt: recordedAt,
            inventoryMovementIDs: nil
        )
        let updated = vendorReturn.replacing(
            events: vendorReturn.events + [event],
            creditEvidence: .some(evidence)
        )
        guard order.replaceVendorReturn(updated) else {
            throw PurchaseOrderVendorReturnError.unableToStoreEvidence
        }
        order.updatedAt = recordedAt
        return evidence
    }

    @MainActor
    private static func transition(
        returnID: UUID,
        on order: PurchaseOrder,
        from expectedStatus: PurchaseOrderVendorReturnStatus,
        to newStatus: PurchaseOrderVendorReturnStatus,
        note: String?,
        actorEmail: String?,
        users: [AppUser],
        at date: Date,
        eventID: UUID
    ) throws {
        try requireAdministrator(actorEmail: actorEmail, users: users)
        guard let vendorReturn = order.vendorReturn(withID: returnID),
              vendorReturn.status == expectedStatus else {
            throw PurchaseOrderVendorReturnError.invalidTransition
        }
        try replace(
            vendorReturn,
            on: order,
            withStatus: newStatus,
            note: note,
            actorEmail: actorEmail,
            at: date,
            eventID: eventID,
            inventoryMovementIDs: nil
        )
    }

    @MainActor
    private static func replace(
        _ vendorReturn: PurchaseOrderVendorReturn,
        on order: PurchaseOrder,
        withStatus status: PurchaseOrderVendorReturnStatus,
        note: String?,
        actorEmail: String?,
        at date: Date,
        eventID: UUID,
        inventoryMovementIDs: [UUID]?
    ) throws {
        let normalizedNote = normalized(note)
        guard normalizedNote.count <= 240 else {
            throw PurchaseOrderVendorReturnError.noteTooLong
        }
        let event = PurchaseOrderVendorReturnEvent(
            id: eventID,
            status: status,
            note: normalizedNote.isEmpty ? nil : normalizedNote,
            recordedByEmail: AppAccess.normalizedEmail(actorEmail),
            recordedAt: date,
            inventoryMovementIDs: inventoryMovementIDs?.isEmpty == false ? inventoryMovementIDs : nil
        )
        let updated = vendorReturn.replacing(events: vendorReturn.events + [event])
        guard order.replaceVendorReturn(updated) else {
            throw PurchaseOrderVendorReturnError.unableToStoreEvidence
        }
        order.updatedAt = date
    }

    @MainActor
    private static func requireAdministrator(actorEmail: String?, users: [AppUser]) throws {
        guard AppAccess.isAdmin(email: actorEmail, users: users),
              !AppAccess.normalizedEmail(actorEmail).isEmpty else {
            throw PurchaseOrderVendorReturnError.unauthorized
        }
    }

    nonisolated private static func normalized(_ value: String?) -> String {
        value?
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ") ?? ""
    }

    nonisolated private static func sameLocation(_ lhs: String, _ rhs: String) -> Bool {
        normalized(lhs).caseInsensitiveCompare(normalized(rhs)) == .orderedSame
    }
}

extension PurchaseOrder {
    func receivedQuantity(for lineID: UUID, at location: String) -> Double {
        let primaryLineID = purchaseOrderLines.first?.id
        return purchaseOrderReceipts.reduce(0) { total, receipt in
            let receiptLineID = receipt.lineID ?? primaryLineID
            guard receiptLineID == lineID,
                  Self.sameVendorReturnLocation(receipt.destinationLocation, location) else {
                return total
            }
            return total + max(receipt.quantity, 0)
        }
    }

    func committedVendorReturnQuantity(for lineID: UUID, at location: String? = nil) -> Double {
        vendorReturns.reduce(0) { total, vendorReturn in
            guard vendorReturn.status != .cancelled,
                  location.map({ Self.sameVendorReturnLocation(vendorReturn.sourceLocation, $0) }) ?? true else {
                return total
            }
            return total + vendorReturn.lineAllocations.reduce(0) {
                $0 + ($1.lineID == lineID ? max($1.quantity, 0) : 0)
            }
        }
    }

    func returnableQuantity(for lineID: UUID, at location: String) -> Double {
        let available = receivedQuantity(for: lineID, at: location) -
            committedVendorReturnQuantity(for: lineID, at: location)
        return abs(available) <= 0.0001 ? 0 : max(available, 0)
    }

    func receivedSerializedAssets(for lineID: UUID) -> [PurchaseOrderReceivedAsset] {
        purchaseOrderReceipts.flatMap { receipt -> [PurchaseOrderReceivedAsset] in
            let receiptLineID = receipt.lineID ?? purchaseOrderLines.first?.id
            return receiptLineID == lineID ? (receipt.serializedAssets ?? []) : []
        }
    }

    func vendorReturn(containing assetID: UUID) -> PurchaseOrderVendorReturn? {
        vendorReturns.first { vendorReturn in
            vendorReturn.status != .cancelled && vendorReturn.lineAllocations.contains {
                $0.serializedAssetIDs?.contains(assetID) == true
            }
        }
    }

    func vendorCreditMatch(for vendorReturn: PurchaseOrderVendorReturn) -> PurchaseOrderVendorCreditMatch {
        let merchandise = vendorReturn.lineAllocations.reduce(0) { total, allocation in
            total + max(allocation.quantity, 0) * acceptedUnitCost(for: allocation.lineID)
        }
        let evidence = vendorReturn.creditEvidence
        let restockingFee = max(evidence?.restockingFee ?? 0, 0)
        let taxCredit = max(evidence?.taxCredit ?? 0, 0)
        let shippingCredit = max(evidence?.shippingCredit ?? 0, 0)
        let expected = max(merchandise + taxCredit + shippingCredit - restockingFee, 0)
        let actual = evidence.map { max($0.creditAmount, 0) }
        let variance = actual.map { $0 - expected }
        let state: PurchaseOrderVendorCreditMatchState
        if let variance {
            state = abs(variance) <= 0.01 ? .matched : .variance
        } else {
            state = .awaitingCredit
        }
        return PurchaseOrderVendorCreditMatch(
            state: state,
            merchandiseAmount: merchandise,
            restockingFee: restockingFee,
            taxCredit: taxCredit,
            shippingCredit: shippingCredit,
            expectedCreditAmount: expected,
            actualCreditAmount: actual,
            varianceAmount: variance
        )
    }

    var hasOpenVendorReturnAttention: Bool {
        vendorReturns.contains { vendorReturn in
            switch vendorReturn.status {
            case .pending, .sent, .returned:
                true
            case .creditReceived:
                vendorCreditMatch(for: vendorReturn).hasVariance
            case .cancelled:
                false
            }
        }
    }

    var hasReturnableVendorItems: Bool {
        purchaseOrderReceipts.contains { receipt in
            let lineID = receipt.lineID ?? purchaseOrderLines.first?.id
            guard let lineID else { return false }
            return returnableQuantity(
                for: lineID,
                at: receipt.destinationLocation
            ) > 0.0001
        }
    }

    fileprivate static func sameVendorReturnLocation(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        let right = rhs.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        return left.caseInsensitiveCompare(right) == .orderedSame
    }
}
