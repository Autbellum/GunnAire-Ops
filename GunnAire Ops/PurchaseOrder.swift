import Foundation
import SwiftData

enum PurchaseOrderStatus: String, Codable, CaseIterable, Identifiable {
    case requested
    case draft
    case ordered
    case partiallyReceived = "partially_received"
    case received
    case cancelled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .requested: "Requested"
        case .draft: "Draft"
        case .ordered: "Ordered"
        case .partiallyReceived: "Partially Received"
        case .received: "Received"
        case .cancelled: "Cancelled"
        }
    }
}

enum SupplierOrderChannel: String, Codable, CaseIterable, Identifiable {
    case supplierPortal
    case email
    case phone
    case counter
    case approvedConnector
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .supplierPortal: "Supplier portal"
        case .email: "Email"
        case .phone: "Phone"
        case .counter: "Counter / branch"
        case .approvedConnector: "Approved connector"
        case .other: "Other approved channel"
        }
    }

    /// The connector channel is populated only by an approved server-side adapter.
    /// A person cannot claim that an electronic connector accepted an order.
    static var manualCases: [SupplierOrderChannel] {
        allCases.filter { $0 != .approvedConnector }
    }
}

/// Durable evidence that a supplier accepted an order. This remains distinct
/// from the accounting vendor and contains no supplier credentials.
struct SupplierOrderConfirmation: Codable, Equatable {
    let reference: String
    let channel: SupplierOrderChannel
    let supplierLocation: String?
    let confirmedUnitCost: Double
    let confirmedShippingCost: Double
    let confirmedByEmail: String
    let confirmedAt: Date
    let connectorKind: SupplierConnectorKind?
    let connectorContractVersion: Int?
    let priceAvailabilityCheckedAt: Date?
    let externalOrderID: String?
    let idempotencyKey: String?

    init(
        reference: String,
        channel: SupplierOrderChannel,
        supplierLocation: String?,
        confirmedUnitCost: Double,
        confirmedShippingCost: Double,
        confirmedByEmail: String,
        confirmedAt: Date,
        connectorKind: SupplierConnectorKind?,
        connectorContractVersion: Int? = nil,
        priceAvailabilityCheckedAt: Date?,
        externalOrderID: String? = nil,
        idempotencyKey: String? = nil
    ) {
        self.reference = reference
        self.channel = channel
        self.supplierLocation = supplierLocation
        self.confirmedUnitCost = confirmedUnitCost
        self.confirmedShippingCost = confirmedShippingCost
        self.confirmedByEmail = confirmedByEmail
        self.confirmedAt = confirmedAt
        self.connectorKind = connectorKind
        self.connectorContractVersion = connectorContractVersion
        self.priceAvailabilityCheckedAt = priceAvailabilityCheckedAt
        self.externalOrderID = externalOrderID
        self.idempotencyKey = idempotencyKey
    }
}

/// An immutable purchasing snapshot. Catalog edits made after the order is
/// created cannot rewrite what was ordered, received, or billed.
struct PurchaseOrderLine: Codable, Equatable, Identifiable {
    let id: UUID
    let catalogItemID: UUID?
    let itemName: String
    let itemSKU: String?
    let vendorPartNumber: String?
    let quantity: Double
    let unitCost: Double
    /// Optional so every version-4 and legacy line remains decodable. New
    /// equipment orders can require one physical serial for each whole unit at
    /// receiving without adding a CloudKit field to either Item or PurchaseOrder.
    let serialTrackingRequired: Bool?

    init(
        id: UUID,
        catalogItemID: UUID?,
        itemName: String,
        itemSKU: String?,
        vendorPartNumber: String?,
        quantity: Double,
        unitCost: Double,
        serialTrackingRequired: Bool? = nil
    ) {
        self.id = id
        self.catalogItemID = catalogItemID
        self.itemName = itemName
        self.itemSKU = itemSKU
        self.vendorPartNumber = vendorPartNumber
        self.quantity = quantity
        self.unitCost = unitCost
        self.serialTrackingRequired = serialTrackingRequired
    }

    var merchandiseTotal: Double {
        max(quantity, 0) * max(unitCost, 0)
    }
}

/// Physical equipment identity captured from the supplier shipment. Assets are
/// immutable receipt evidence; installation is recorded separately so receiving
/// history can never be rewritten when equipment is later assigned to a job.
struct PurchaseOrderReceivedAsset: Codable, Equatable, Identifiable {
    let id: UUID
    let serialNumber: String
    let manufacturer: String?
    let modelNumber: String?

    var displayName: String {
        let identity = [manufacturer, modelNumber]
            .compactMap { value -> String? in
                let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                return normalized?.isEmpty == false ? normalized : nil
            }
            .joined(separator: " ")
        return identity.isEmpty ? "Serial \(serialNumber)" : "\(identity) • Serial \(serialNumber)"
    }
}

/// Explicit handoff from a received serialized asset to an installed customer
/// system. The UUID links are durable across CloudKit relationship ordering and
/// preserve who made the assignment and when.
struct PurchaseOrderAssetInstallation: Codable, Equatable, Identifiable {
    let assetID: UUID
    let serviceCallID: UUID
    let customerEquipmentID: UUID
    let installedByEmail: String
    let installedAt: Date

    var id: UUID { assetID }
}

/// Accepted supplier pricing is kept separately from the draft snapshot so a
/// later three-way match can compare the bill with the actual acceptance.
struct PurchaseOrderLineUnitCost: Codable, Equatable, Identifiable {
    let lineID: UUID
    let unitCost: Double

    var id: UUID { lineID }
}

/// One immutable shipment received against a supplier-confirmed purchase order.
/// The inventory movement identifier is present only when a catalog match is
/// explicitly inventory-tracked; direct-ship and untracked receipts remain
/// traceable without inflating truck or warehouse stock.
struct PurchaseOrderReceipt: Codable, Equatable, Identifiable {
    let id: UUID
    let lineID: UUID?
    let itemName: String?
    let quantity: Double
    let destinationLocation: String
    let note: String?
    let receivedByEmail: String
    let receivedAt: Date
    let inventoryMovementID: UUID?
    let serializedAssets: [PurchaseOrderReceivedAsset]?

    init(
        id: UUID,
        lineID: UUID? = nil,
        itemName: String? = nil,
        quantity: Double,
        destinationLocation: String,
        note: String?,
        receivedByEmail: String,
        receivedAt: Date,
        inventoryMovementID: UUID?,
        serializedAssets: [PurchaseOrderReceivedAsset]? = nil
    ) {
        self.id = id
        self.lineID = lineID
        self.itemName = itemName
        self.quantity = quantity
        self.destinationLocation = destinationLocation
        self.note = note
        self.receivedByEmail = receivedByEmail
        self.receivedAt = receivedAt
        self.inventoryMovementID = inventoryMovementID
        self.serializedAssets = serializedAssets
    }

    var summary: String {
        let quantityText = quantity.formatted(.number.precision(.fractionLength(0...3)))
        let item = itemName.map { " \($0)" } ?? ""
        return "\(quantityText)\(item) to \(destinationLocation)"
    }

    var serialCount: Int { serializedAssets?.count ?? 0 }
}

struct PurchaseOrderReceiptOutcome {
    let receipt: PurchaseOrderReceipt
    let inventoryMovement: InventoryMovement?
}

enum PurchaseOrderAssetInstallationError: LocalizedError, Equatable {
    case unauthorized
    case jobMismatch
    case missingAsset
    case alreadyInstalled
    case assetCommittedToVendorReturn
    case duplicateCustomerSerial
    case nameRequired
    case valueTooLong
    case invalidDates
    case unableToStoreEvidence

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Only an administrator can add received equipment to a customer system."
        case .jobMismatch:
            "This purchase order is not linked to the selected installation job."
        case .missingAsset:
            "The received serialized asset could not be found on this purchase order."
        case .alreadyInstalled:
            "This serialized asset is already assigned to an installed customer system."
        case .assetCommittedToVendorReturn:
            "This serialized asset is committed to a supplier return and cannot be installed."
        case .duplicateCustomerSerial:
            "That serial number is already assigned to another customer system."
        case .nameRequired:
            "Enter a customer-facing equipment name."
        case .valueTooLong:
            "Keep the equipment name and location to 100 characters or fewer."
        case .invalidDates:
            "Install date cannot be in the future, and warranty expiration cannot be before installation."
        case .unableToStoreEvidence:
            "The installation evidence could not be stored. No customer system was created."
        }
    }
}

enum PurchaseOrderAssetInstallationPolicy {
    @MainActor
    static func install(
        assetID: UUID,
        from order: PurchaseOrder,
        on job: ServiceCall,
        equipmentType: HVACEquipmentType,
        name: String,
        location: String?,
        installDate: Date,
        warrantyExpiration: Date?,
        existingEquipment: [CustomerEquipment],
        actorEmail: String?,
        users: [AppUser],
        recordedAt: Date = Date(),
        equipmentID: UUID = UUID()
    ) throws -> CustomerEquipment {
        guard AppAccess.isAdmin(email: actorEmail, users: users) else {
            throw PurchaseOrderAssetInstallationError.unauthorized
        }
        guard order.serviceCallID == job.id, let customer = job.customer else {
            throw PurchaseOrderAssetInstallationError.jobMismatch
        }
        guard let asset = order.receivedSerializedAssets.first(where: { $0.id == assetID }) else {
            throw PurchaseOrderAssetInstallationError.missingAsset
        }
        guard order.installation(for: assetID) == nil else {
            throw PurchaseOrderAssetInstallationError.alreadyInstalled
        }
        guard order.vendorReturn(containing: assetID) == nil else {
            throw PurchaseOrderAssetInstallationError.assetCommittedToVendorReturn
        }
        let serialKey = EquipmentCodeLookup.normalizedSerial(asset.serialNumber)
        guard !existingEquipment.contains(where: {
            guard let serial = $0.serialNumber else { return false }
            return EquipmentCodeLookup.normalizedSerial(serial) == serialKey
        }) else {
            throw PurchaseOrderAssetInstallationError.duplicateCustomerSerial
        }
        let normalizedName = normalized(name)
        guard !normalizedName.isEmpty else {
            throw PurchaseOrderAssetInstallationError.nameRequired
        }
        let normalizedLocation = normalized(location)
        guard normalizedName.count <= 100, normalizedLocation.count <= 100 else {
            throw PurchaseOrderAssetInstallationError.valueTooLong
        }
        let lifecycle = EquipmentLifecyclePolicy.snapshot(
            installDate: installDate,
            warrantyExpiration: warrantyExpiration,
            now: recordedAt
        )
        guard lifecycle.validationMessage == nil else {
            throw PurchaseOrderAssetInstallationError.invalidDates
        }

        let equipment = CustomerEquipment(
            id: equipmentID,
            customer: customer,
            serviceLocationID: job.serviceLocationID,
            equipmentType: equipmentType,
            name: normalizedName,
            manufacturer: asset.manufacturer,
            modelNumber: asset.modelNumber,
            serialNumber: asset.serialNumber,
            location: normalizedLocation.isEmpty ? nil : normalizedLocation,
            installDate: installDate,
            warrantyExpiration: warrantyExpiration,
            notes: "Installed from \(order.number) for job \(job.id.uuidString)."
        )
        let installation = PurchaseOrderAssetInstallation(
            assetID: assetID,
            serviceCallID: job.id,
            customerEquipmentID: equipmentID,
            installedByEmail: AppAccess.normalizedEmail(actorEmail),
            installedAt: installDate
        )
        guard order.appendAssetInstallation(installation) else {
            throw PurchaseOrderAssetInstallationError.unableToStoreEvidence
        }
        equipment.apply(to: job)
        order.updatedAt = recordedAt
        return equipment
    }

    nonisolated private static func normalized(_ value: String?) -> String {
        value?
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ") ?? ""
    }
}

/// One line allocation from a supplier invoice. Freight, tax, and other
/// invoice-level charges remain on the parent bill so they are never counted
/// once per item.
struct PurchaseOrderBillLineAllocation: Codable, Equatable, Identifiable {
    let lineID: UUID
    let itemName: String
    let quantity: Double
    let unitCost: Double

    var id: UUID { lineID }

    var merchandiseAmount: Double {
        max(quantity, 0) * max(unitCost, 0)
    }
}

/// One immutable supplier invoice recorded against a purchase order. This is
/// operational reconciliation evidence only: storing it never creates or
/// changes a QuickBooks Bill. The optional provider ID and source filename
/// link the local decision trail to accounting/document evidence without
/// retaining credentials or the bill file inside the purchase-order record.
struct PurchaseOrderVendorBill: Codable, Equatable, Identifiable {
    let id: UUID
    let invoiceNumber: String
    let invoiceDate: Date
    let quantity: Double
    let unitCost: Double
    let shippingCost: Double
    let taxAmount: Double
    let otherCharges: Double
    let sourceDocumentName: String?
    let quickBooksBillID: String?
    let quickBooksPublishedByEmail: String?
    let quickBooksPublishedAt: Date?
    let note: String?
    let recordedByEmail: String
    let recordedAt: Date
    let lineAllocations: [PurchaseOrderBillLineAllocation]?

    init(
        id: UUID,
        invoiceNumber: String,
        invoiceDate: Date,
        quantity: Double,
        unitCost: Double,
        shippingCost: Double,
        taxAmount: Double,
        otherCharges: Double,
        sourceDocumentName: String?,
        quickBooksBillID: String?,
        quickBooksPublishedByEmail: String? = nil,
        quickBooksPublishedAt: Date? = nil,
        note: String?,
        recordedByEmail: String,
        recordedAt: Date,
        lineAllocations: [PurchaseOrderBillLineAllocation]? = nil
    ) {
        self.id = id
        self.invoiceNumber = invoiceNumber
        self.invoiceDate = invoiceDate
        self.quantity = quantity
        self.unitCost = unitCost
        self.shippingCost = shippingCost
        self.taxAmount = taxAmount
        self.otherCharges = otherCharges
        self.sourceDocumentName = sourceDocumentName
        self.quickBooksBillID = quickBooksBillID
        self.quickBooksPublishedByEmail = quickBooksPublishedByEmail
        self.quickBooksPublishedAt = quickBooksPublishedAt
        self.note = note
        self.recordedByEmail = recordedByEmail
        self.recordedAt = recordedAt
        self.lineAllocations = lineAllocations
    }

    var merchandiseAmount: Double {
        quantity * unitCost
    }

    var totalAmount: Double {
        merchandiseAmount + shippingCost + taxAmount + otherCharges
    }

    func linkingQuickBooksBill(
        id quickBooksBillID: String,
        actorEmail: String,
        publishedAt: Date
    ) -> PurchaseOrderVendorBill {
        PurchaseOrderVendorBill(
            id: id,
            invoiceNumber: invoiceNumber,
            invoiceDate: invoiceDate,
            quantity: quantity,
            unitCost: unitCost,
            shippingCost: shippingCost,
            taxAmount: taxAmount,
            otherCharges: otherCharges,
            sourceDocumentName: sourceDocumentName,
            quickBooksBillID: quickBooksBillID,
            quickBooksPublishedByEmail: actorEmail,
            quickBooksPublishedAt: publishedAt,
            note: note,
            recordedByEmail: recordedByEmail,
            recordedAt: recordedAt,
            lineAllocations: lineAllocations
        )
    }
}

enum PurchaseOrderBillMatchState: String, Codable, Equatable {
    case notRecorded
    case inProgress
    case awaitingReceipt
    case quantityVariance
    case costVariance
    case matched

    var displayName: String {
        switch self {
        case .notRecorded: "Vendor Bill Not Recorded"
        case .inProgress: "Bill Reconciliation In Progress"
        case .awaitingReceipt: "Bill Recorded — Awaiting Receipt"
        case .quantityVariance: "Vendor Bill Quantity Variance"
        case .costVariance: "Vendor Bill Cost Variance"
        case .matched: "Three-Way Matched"
        }
    }
}

struct PurchaseOrderBillMatch: Equatable {
    let state: PurchaseOrderBillMatchState
    let billedQuantity: Double
    let orderedQuantity: Double
    let receivedQuantity: Double
    let billedMerchandiseAmount: Double
    let expectedMerchandiseAmount: Double
    let billedShippingCost: Double
    let expectedShippingCost: Double
    let taxAmount: Double
    let otherCharges: Double
    let totalAmount: Double

    var hasVariance: Bool {
        state == .quantityVariance || state == .costVariance
    }

    var summary: String {
        let billed = billedQuantity.formatted(.number.precision(.fractionLength(0...3)))
        let ordered = orderedQuantity.formatted(.number.precision(.fractionLength(0...3)))
        let received = receivedQuantity.formatted(.number.precision(.fractionLength(0...3)))
        switch state {
        case .notRecorded:
            return "No vendor bill recorded"
        case .inProgress:
            return "\(billed) of \(ordered) billed"
        case .awaitingReceipt:
            return "\(billed) billed • \(received) received"
        case .quantityVariance:
            return "\(billed) billed vs \(ordered) ordered"
        case .costVariance:
            return "Billed cost differs from supplier acceptance"
        case .matched:
            return "\(billed) billed • received • matched"
        }
    }
}

enum PurchaseOrderBillRecordingError: LocalizedError, Equatable {
    case unauthorized
    case invalidState
    case missingSupplierConfirmation
    case invoiceNumberRequired
    case invoiceNumberTooLong
    case duplicateInvoiceNumber
    case invalidInvoiceDate
    case invalidQuantity
    case invalidLineAllocation
    case duplicateLineAllocation
    case invalidAmount
    case documentNameTooLong
    case quickBooksIDTooLong
    case noteTooLong
    case unableToStoreEvidence

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Only an administrator can record a vendor bill against a purchase order."
        case .invalidState:
            "Record vendor bills only after the supplier has accepted the purchase order."
        case .missingSupplierConfirmation:
            "Record the supplier's acceptance evidence before reconciling a vendor bill."
        case .invoiceNumberRequired:
            "Enter the supplier invoice or bill number."
        case .invoiceNumberTooLong:
            "Keep the supplier invoice number to 80 characters or fewer."
        case .duplicateInvoiceNumber:
            "That supplier invoice number is already recorded on this purchase order."
        case .invalidInvoiceDate:
            "The supplier invoice date cannot be in the future."
        case .invalidQuantity:
            "Enter a billed quantity greater than zero."
        case .invalidLineAllocation:
            "Each billed item must match a purchase-order line with a quantity greater than zero."
        case .duplicateLineAllocation:
            "A vendor bill can allocate each purchase-order line only once."
        case .invalidAmount:
            "Enter finite, non-negative unit cost, freight, tax, and other-charge amounts."
        case .documentNameTooLong:
            "Keep the source document name to 180 characters or fewer."
        case .quickBooksIDTooLong:
            "Keep the QuickBooks Bill ID to 80 characters or fewer."
        case .noteTooLong:
            "Keep the reconciliation note to 240 characters or fewer."
        case .unableToStoreEvidence:
            "The vendor bill evidence could not be stored. The purchase order remains unchanged."
        }
    }
}

enum PurchaseOrderBillReconciliationPolicy {
    @MainActor
    @discardableResult
    static func record(
        on order: PurchaseOrder,
        invoiceNumber: String,
        invoiceDate: Date,
        quantity: Double,
        unitCost: Double,
        shippingCost: Double,
        taxAmount: Double,
        otherCharges: Double,
        sourceDocumentName: String?,
        quickBooksBillID: String?,
        note: String?,
        actorEmail: String?,
        users: [AppUser],
        at recordedAt: Date = Date(),
        billID: UUID = UUID()
    ) throws -> PurchaseOrderVendorBill {
        guard let primaryLine = order.purchaseOrderLines.first else {
            throw PurchaseOrderBillRecordingError.invalidLineAllocation
        }
        return try record(
            on: order,
            invoiceNumber: invoiceNumber,
            invoiceDate: invoiceDate,
            lineAllocations: [
                PurchaseOrderBillLineAllocation(
                    lineID: primaryLine.id,
                    itemName: primaryLine.itemName,
                    quantity: quantity,
                    unitCost: unitCost
                )
            ],
            shippingCost: shippingCost,
            taxAmount: taxAmount,
            otherCharges: otherCharges,
            sourceDocumentName: sourceDocumentName,
            quickBooksBillID: quickBooksBillID,
            note: note,
            actorEmail: actorEmail,
            users: users,
            at: recordedAt,
            billID: billID
        )
    }

    @MainActor
    @discardableResult
    static func record(
        on order: PurchaseOrder,
        invoiceNumber: String,
        invoiceDate: Date,
        lineAllocations: [PurchaseOrderBillLineAllocation],
        shippingCost: Double,
        taxAmount: Double,
        otherCharges: Double,
        sourceDocumentName: String?,
        quickBooksBillID: String?,
        note: String?,
        actorEmail: String?,
        users: [AppUser],
        at recordedAt: Date = Date(),
        billID: UUID = UUID()
    ) throws -> PurchaseOrderVendorBill {
        guard AppAccess.isAdmin(email: actorEmail, users: users) else {
            throw PurchaseOrderBillRecordingError.unauthorized
        }
        guard order.status == .ordered ||
                order.status == .partiallyReceived ||
                order.status == .received else {
            throw PurchaseOrderBillRecordingError.invalidState
        }
        guard order.hasSupplierOrderConfirmation else {
            throw PurchaseOrderBillRecordingError.missingSupplierConfirmation
        }

        let normalizedInvoiceNumber = normalized(invoiceNumber)
        guard !normalizedInvoiceNumber.isEmpty else {
            throw PurchaseOrderBillRecordingError.invoiceNumberRequired
        }
        guard normalizedInvoiceNumber.count <= 80 else {
            throw PurchaseOrderBillRecordingError.invoiceNumberTooLong
        }
        guard !order.vendorBills.contains(where: {
            $0.invoiceNumber.caseInsensitiveCompare(normalizedInvoiceNumber) == .orderedSame
        }) else {
            throw PurchaseOrderBillRecordingError.duplicateInvoiceNumber
        }
        guard invoiceDate <= recordedAt.addingTimeInterval(24 * 60 * 60) else {
            throw PurchaseOrderBillRecordingError.invalidInvoiceDate
        }
        guard !lineAllocations.isEmpty else {
            throw PurchaseOrderBillRecordingError.invalidQuantity
        }
        let knownLines = Dictionary(uniqueKeysWithValues: order.purchaseOrderLines.map { ($0.id, $0) })
        let allocationIDs = lineAllocations.map(\.lineID)
        guard Set(allocationIDs).count == allocationIDs.count else {
            throw PurchaseOrderBillRecordingError.duplicateLineAllocation
        }
        guard lineAllocations.allSatisfy({ allocation in
            knownLines[allocation.lineID] != nil &&
                allocation.quantity.isFinite && allocation.quantity > 0.0001 &&
                allocation.unitCost.isFinite && allocation.unitCost >= 0
        }) else {
            throw PurchaseOrderBillRecordingError.invalidLineAllocation
        }
        guard [shippingCost, taxAmount, otherCharges].allSatisfy({
            $0.isFinite && $0 >= 0
        }) else {
            throw PurchaseOrderBillRecordingError.invalidAmount
        }

        let documentName = normalized(sourceDocumentName)
        guard documentName.count <= 180 else {
            throw PurchaseOrderBillRecordingError.documentNameTooLong
        }
        let qboBillID = normalized(quickBooksBillID)
        guard qboBillID.count <= 80 else {
            throw PurchaseOrderBillRecordingError.quickBooksIDTooLong
        }
        let normalizedNote = normalized(note)
        guard normalizedNote.count <= 240 else {
            throw PurchaseOrderBillRecordingError.noteTooLong
        }

        let normalizedAllocations = lineAllocations.map { allocation in
            PurchaseOrderBillLineAllocation(
                lineID: allocation.lineID,
                itemName: knownLines[allocation.lineID]?.itemName ?? allocation.itemName,
                quantity: allocation.quantity,
                unitCost: allocation.unitCost
            )
        }
        let totalQuantity = normalizedAllocations.reduce(0) { $0 + $1.quantity }
        let merchandiseAmount = normalizedAllocations.reduce(0) { $0 + $1.merchandiseAmount }
        let weightedUnitCost = totalQuantity > 0.0001 ? merchandiseAmount / totalQuantity : 0
        let bill = PurchaseOrderVendorBill(
            id: billID,
            invoiceNumber: normalizedInvoiceNumber,
            invoiceDate: invoiceDate,
            quantity: totalQuantity,
            unitCost: weightedUnitCost,
            shippingCost: shippingCost,
            taxAmount: taxAmount,
            otherCharges: otherCharges,
            sourceDocumentName: documentName.isEmpty ? nil : documentName,
            quickBooksBillID: qboBillID.isEmpty ? nil : qboBillID,
            note: normalizedNote.isEmpty ? nil : normalizedNote,
            recordedByEmail: AppAccess.normalizedEmail(actorEmail),
            recordedAt: recordedAt,
            lineAllocations: normalizedAllocations
        )
        guard order.appendVendorBill(bill) else {
            throw PurchaseOrderBillRecordingError.unableToStoreEvidence
        }
        order.updatedAt = recordedAt
        return bill
    }

    private static func normalized(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

enum PurchaseOrderReceivingError: LocalizedError, Equatable {
    case invalidState
    case missingSupplierConfirmation
    case actorRequired
    case locationRequired
    case locationTooLong
    case invalidQuantity
    case missingLine
    case exceedsRemainingQuantity
    case serialTrackingRequiresWholeQuantity
    case serialCountMismatch
    case duplicateSerialNumber
    case serialNumberTooLong
    case manufacturerTooLong
    case modelNumberTooLong
    case noteTooLong
    case unableToStoreEvidence

    var errorDescription: String? {
        switch self {
        case .invalidState:
            "Only an ordered or partially received purchase order can receive a shipment."
        case .missingSupplierConfirmation:
            "Record the supplier's acceptance evidence before receiving a shipment."
        case .actorRequired:
            "Sign in with an approved business account before receiving inventory."
        case .locationRequired:
            "Enter the truck, warehouse, job, or direct-ship destination."
        case .locationTooLong:
            "Keep the receipt destination to 100 characters or fewer."
        case .invalidQuantity:
            "Enter a received quantity greater than zero."
        case .missingLine:
            "Choose an open purchase-order item before receiving the shipment."
        case .exceedsRemainingQuantity:
            "The received quantity cannot exceed the open purchase-order quantity."
        case .serialTrackingRequiresWholeQuantity:
            "Serialized equipment must be received in whole units."
        case .serialCountMismatch:
            "Enter one serial number for every serialized equipment unit received."
        case .duplicateSerialNumber:
            "Each equipment serial number must be unique on this purchase order."
        case .serialNumberTooLong:
            "Keep each equipment serial number to 80 characters or fewer."
        case .manufacturerTooLong:
            "Keep the equipment manufacturer to 100 characters or fewer."
        case .modelNumberTooLong:
            "Keep the equipment model number to 100 characters or fewer."
        case .noteTooLong:
            "Keep the packing-slip or backorder note to 240 characters or fewer."
        case .unableToStoreEvidence:
            "The shipment evidence could not be stored. The purchase order and inventory remain unchanged."
        }
    }
}

enum PurchaseOrderConfirmationError: LocalizedError, Equatable {
    case unauthorized
    case invalidState
    case alreadyConfirmed
    case missingSupplier
    case invalidOrder
    case missingReference
    case referenceTooLong
    case locationTooLong
    case invalidCost
    case connectorRequiresServer
    case connectorLineMismatch
    case connectorVendorMismatch
    case serverOrderMismatch
    case staleConnectorPricing
    case invalidServerConfirmation
    case unableToStoreEvidence

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Only an administrator can confirm a supplier order."
        case .invalidState:
            "Only a draft or previously ordered legacy purchase order can receive supplier evidence."
        case .alreadyConfirmed:
            "This purchase order already has immutable supplier confirmation evidence."
        case .missingSupplier:
            "Choose a supplier before confirming the order."
        case .invalidOrder:
            "Enter a valid item and quantity before confirming the order."
        case .missingReference:
            "Enter the supplier confirmation, order, or acknowledgement reference."
        case .referenceTooLong:
            "Keep the supplier reference to 120 characters or fewer."
        case .locationTooLong:
            "Keep the supplier branch or location to 120 characters or fewer."
        case .invalidCost:
            "Enter valid confirmed unit and shipping costs of zero or more."
        case .connectorRequiresServer:
            "Electronic connector acceptance must come from the approved server-side supplier adapter."
        case .connectorLineMismatch:
            "The supplier acknowledgement does not match every submitted purchase-order line. Stop and reconcile the order with the supplier."
        case .connectorVendorMismatch:
            "The approved connector does not match this purchase order's supplier."
        case .serverOrderMismatch:
            "The server acknowledgement does not match this purchase order."
        case .staleConnectorPricing:
            "The supplier price or availability check is stale. Refresh the connector before ordering."
        case .invalidServerConfirmation:
            "The supplier acknowledgement is incomplete or cannot be reconciled safely."
        case .unableToStoreEvidence:
            "The supplier confirmation could not be stored. The purchase order remains unconfirmed."
        }
    }
}

enum PurchaseOrderOrderingPolicy {
    @MainActor
    static func confirmManualOrder(
        _ order: PurchaseOrder,
        channel: SupplierOrderChannel,
        reference: String,
        supplierLocation: String?,
        confirmedUnitCost: Double,
        confirmedShippingCost: Double,
        confirmedLineUnitCosts: [PurchaseOrderLineUnitCost]? = nil,
        actorEmail: String?,
        users: [AppUser],
        at date: Date = Date()
    ) throws {
        guard AppAccess.isAdmin(email: actorEmail, users: users) else {
            throw PurchaseOrderConfirmationError.unauthorized
        }
        guard order.status == .draft || order.status == .ordered else {
            throw PurchaseOrderConfirmationError.invalidState
        }
        guard order.supplierOrderConfirmation == nil else {
            throw PurchaseOrderConfirmationError.alreadyConfirmed
        }
        guard channel != .approvedConnector else {
            throw PurchaseOrderConfirmationError.connectorRequiresServer
        }
        guard !order.vendorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PurchaseOrderConfirmationError.missingSupplier
        }
        let orderLines = order.purchaseOrderLines
        guard !orderLines.isEmpty,
              orderLines.allSatisfy({
                  !$0.itemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                      $0.quantity.isFinite && $0.quantity > 0 &&
                      $0.unitCost.isFinite && $0.unitCost >= 0
              }) else {
            throw PurchaseOrderConfirmationError.invalidOrder
        }
        let normalizedReference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedReference.isEmpty else {
            throw PurchaseOrderConfirmationError.missingReference
        }
        guard normalizedReference.count <= 120 else {
            throw PurchaseOrderConfirmationError.referenceTooLong
        }
        let normalizedLocation = supplierLocation?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedLocation?.count ?? 0 <= 120 else {
            throw PurchaseOrderConfirmationError.locationTooLong
        }
        guard confirmedUnitCost.isFinite,
              confirmedUnitCost >= 0,
              confirmedShippingCost.isFinite,
              confirmedShippingCost >= 0 else {
            throw PurchaseOrderConfirmationError.invalidCost
        }
        var lineCosts = confirmedLineUnitCosts ?? orderLines.map {
            PurchaseOrderLineUnitCost(lineID: $0.id, unitCost: $0.unitCost)
        }
        if let primaryID = orderLines.first?.id,
           let index = lineCosts.firstIndex(where: { $0.lineID == primaryID }) {
            lineCosts[index] = PurchaseOrderLineUnitCost(lineID: primaryID, unitCost: confirmedUnitCost)
        }
        let knownLineIDs = Set(orderLines.map(\.id))
        guard lineCosts.count == knownLineIDs.count,
              Set(lineCosts.map(\.lineID)) == knownLineIDs,
              lineCosts.allSatisfy({ $0.unitCost.isFinite && $0.unitCost >= 0 }) else {
            throw PurchaseOrderConfirmationError.invalidCost
        }

        guard order.storeSupplierOrderConfirmation(
            SupplierOrderConfirmation(
                reference: normalizedReference,
                channel: channel,
                supplierLocation: normalizedLocation?.isEmpty == false ? normalizedLocation : nil,
                confirmedUnitCost: confirmedUnitCost,
                confirmedShippingCost: confirmedShippingCost,
                confirmedByEmail: AppAccess.normalizedEmail(actorEmail),
                confirmedAt: date,
                connectorKind: nil,
                priceAvailabilityCheckedAt: date
            ),
            confirmedLineUnitCosts: lineCosts
        ) else {
            throw PurchaseOrderConfirmationError.unableToStoreEvidence
        }
        order.unitCost = confirmedUnitCost
        order.shippingCost = confirmedShippingCost
        order.status = .ordered
        order.orderedAt = date
        order.updatedAt = date
    }

    @MainActor
    static func applyServerConnectorAcceptance(
        _ acceptance: SupplierConnectorOrderAcceptance,
        to order: PurchaseOrder,
        actorEmail: String?,
        users: [AppUser],
        at date: Date = Date()
    ) throws {
        guard AppAccess.isAdmin(email: actorEmail, users: users) else {
            throw PurchaseOrderConfirmationError.unauthorized
        }
        guard order.status == .draft else {
            throw PurchaseOrderConfirmationError.invalidState
        }
        guard order.supplierOrderConfirmation == nil else {
            throw PurchaseOrderConfirmationError.alreadyConfirmed
        }
        guard acceptance.purchaseOrderID == order.id,
              acceptance.purchaseOrderNumber == order.number else {
            throw PurchaseOrderConfirmationError.serverOrderMismatch
        }
        let normalizedVendor = order.vendorName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch acceptance.connectorKind {
        case .johnstoneDirectConnect, .johnstonePunchOut:
            guard normalizedVendor.contains("johnstone") else {
                throw PurchaseOrderConfirmationError.connectorVendorMismatch
            }
        case .lennoxPartner:
            guard normalizedVendor.contains("lennox") else {
                throw PurchaseOrderConfirmationError.connectorVendorMismatch
            }
        case .carrierEnterprise:
            guard normalizedVendor.contains("carrier") else {
                throw PurchaseOrderConfirmationError.connectorVendorMismatch
            }
        case .genericCatalog:
            break
        }
        let actor = AppAccess.normalizedEmail(actorEmail)
        let serverActor = AppAccess.normalizedEmail(acceptance.confirmedByEmail)
        let serverActorIsKnown = serverActor == AppAccess.primaryAdminEmail || users.contains {
            AppAccess.normalizedEmail($0.email) == serverActor
        }
        guard !actor.isEmpty,
              !serverActor.isEmpty,
              serverActorIsKnown,
              acceptance.contractVersion == SupplierConnectorContract.currentVersion,
              acceptance.currencyCode.caseInsensitiveCompare("USD") == .orderedSame,
              acceptance.confirmedShippingCost.isFinite,
              acceptance.confirmedShippingCost >= 0,
              acceptance.reference.isValidSupplierConnectorIdentifier(maximum: 120),
              acceptance.externalOrderID.isValidSupplierConnectorIdentifier(maximum: 200),
              acceptance.idempotencyKey.isValidSupplierIdempotencyKey,
              acceptance.supplierLocation?.isValidSupplierConnectorIdentifier(maximum: 120) ?? true,
              acceptance.confirmedAt <= date.addingTimeInterval(300) else {
            throw PurchaseOrderConfirmationError.invalidServerConfirmation
        }
        let priceAge = acceptance.confirmedAt.timeIntervalSince(acceptance.priceAvailabilityCheckedAt)
        guard priceAge >= -300, priceAge <= 24 * 60 * 60 else {
            throw PurchaseOrderConfirmationError.staleConnectorPricing
        }
        let orderLines = order.purchaseOrderLines
        let acceptedLines = acceptance.confirmedLines
        let acceptedLineIDs = acceptedLines.map(\.lineID)
        guard acceptedLines.count == orderLines.count,
              Set(acceptedLineIDs).count == acceptedLineIDs.count,
              Set(acceptedLineIDs) == Set(orderLines.map(\.id)) else {
            throw PurchaseOrderConfirmationError.connectorLineMismatch
        }
        let acceptedByLineID = Dictionary(uniqueKeysWithValues: acceptedLines.map { ($0.lineID, $0) })
        guard orderLines.allSatisfy({ line in
            guard let accepted = acceptedByLineID[line.id],
                  accepted.confirmedQuantity.isFinite,
                  abs(accepted.confirmedQuantity - line.quantity) <= 0.0001,
                  accepted.confirmedUnitCost.isFinite,
                  accepted.confirmedUnitCost >= 0,
                  accepted.supplierPartNumber?.isValidSupplierConnectorIdentifier(maximum: 120) ?? true else {
                return false
            }
            guard let confirmedPart = accepted.supplierPartNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !confirmedPart.isEmpty,
                  let requestedPart = line.vendorPartNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !requestedPart.isEmpty else {
                return true
            }
            return confirmedPart.caseInsensitiveCompare(requestedPart) == .orderedSame
        }), let primaryLine = orderLines.first,
              let primaryAcceptance = acceptedByLineID[primaryLine.id] else {
            throw PurchaseOrderConfirmationError.connectorLineMismatch
        }
        let confirmedLineCosts = orderLines.compactMap { line in
            acceptedByLineID[line.id].map {
                PurchaseOrderLineUnitCost(lineID: line.id, unitCost: $0.confirmedUnitCost)
            }
        }
        guard order.storeSupplierOrderConfirmation(
            SupplierOrderConfirmation(
                reference: acceptance.reference,
                channel: .approvedConnector,
                supplierLocation: acceptance.supplierLocation,
                confirmedUnitCost: primaryAcceptance.confirmedUnitCost,
                confirmedShippingCost: acceptance.confirmedShippingCost,
                confirmedByEmail: serverActor,
                confirmedAt: acceptance.confirmedAt,
                connectorKind: acceptance.connectorKind,
                connectorContractVersion: acceptance.contractVersion,
                priceAvailabilityCheckedAt: acceptance.priceAvailabilityCheckedAt,
                externalOrderID: acceptance.externalOrderID,
                idempotencyKey: acceptance.idempotencyKey
            ),
            confirmedLineUnitCosts: confirmedLineCosts
        ) else {
            throw PurchaseOrderConfirmationError.unableToStoreEvidence
        }
        order.unitCost = primaryAcceptance.confirmedUnitCost
        order.shippingCost = acceptance.confirmedShippingCost
        order.status = .ordered
        order.orderedAt = acceptance.confirmedAt
        order.updatedAt = acceptance.confirmedAt
    }
}

/// A locally durable purchase request/order. Supplier and QuickBooks credentials stay on
/// approved server-side connectors; this record preserves the job-cost decision trail.
@Model
final class PurchaseOrder {
    private struct NotesEnvelope: Codable {
        let version: Int
        let userNotes: String?
        let supplierOrderConfirmation: SupplierOrderConfirmation?
        let receipts: [PurchaseOrderReceipt]?
        let vendorBills: [PurchaseOrderVendorBill]?
        let lineItems: [PurchaseOrderLine]?
        let confirmedLineUnitCosts: [PurchaseOrderLineUnitCost]?
        let assetInstallations: [PurchaseOrderAssetInstallation]?
        let vendorReturns: [PurchaseOrderVendorReturn]?
    }

    private static let notesEnvelopePrefix = "GUNNAIRE_PO_METADATA_V1:"

    var id: UUID = UUID()
    var number: String = ""
    var vendorName: String = ""
    var vendorQuickBooksID: String?
    var serviceCallID: UUID?
    var itemName: String = ""
    var itemSKU: String?
    var vendorPartNumber: String?
    var quantity: Double = 0
    var unitCost: Double = 0
    var shippingCost: Double = 0
    var statusRaw: String = PurchaseOrderStatus.draft.rawValue
    var notes: String?
    var createdByEmail: String?
    var orderedAt: Date?
    var receivedAt: Date?
    var receivedToLocation: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        number: String = PurchaseOrder.nextNumber(),
        vendorName: String,
        vendorQuickBooksID: String? = nil,
        serviceCallID: UUID? = nil,
        itemName: String,
        itemSKU: String? = nil,
        vendorPartNumber: String? = nil,
        quantity: Double,
        unitCost: Double,
        shippingCost: Double = 0,
        status: PurchaseOrderStatus = .draft,
        notes: String? = nil,
        createdByEmail: String? = nil,
        createdAt: Date = Date(),
        lineItems: [PurchaseOrderLine]? = nil
    ) {
        self.id = id
        self.number = number
        self.vendorName = vendorName
        self.vendorQuickBooksID = vendorQuickBooksID
        self.serviceCallID = serviceCallID
        self.itemName = itemName
        self.itemSKU = itemSKU
        self.vendorPartNumber = vendorPartNumber
        self.quantity = quantity
        self.unitCost = unitCost
        self.shippingCost = shippingCost
        self.statusRaw = status.rawValue
        self.notes = notes
        self.createdByEmail = createdByEmail
        self.orderedAt = nil
        self.receivedAt = nil
        self.receivedToLocation = nil
        self.createdAt = createdAt
        self.updatedAt = createdAt
        if let lineItems, !lineItems.isEmpty {
            _ = storeLineItems(lineItems)
        }
    }

    var status: PurchaseOrderStatus {
        get { PurchaseOrderStatus(rawValue: statusRaw) ?? .draft }
        set {
            statusRaw = newValue.rawValue
            updatedAt = Date()
            switch newValue {
            case .ordered:
                orderedAt = orderedAt ?? updatedAt
            case .received:
                receivedAt = receivedAt ?? updatedAt
            case .requested, .draft, .partiallyReceived, .cancelled:
                break
            }
        }
    }

    var purchaseOrderLines: [PurchaseOrderLine] {
        if let lines = decodedNotesEnvelope?.lineItems, !lines.isEmpty {
            return lines
        }
        return [
            PurchaseOrderLine(
                id: id,
                catalogItemID: nil,
                itemName: itemName,
                itemSKU: itemSKU,
                vendorPartNumber: vendorPartNumber,
                quantity: quantity,
                unitCost: unitCost,
                serialTrackingRequired: nil
            )
        ]
    }

    var lineCount: Int { purchaseOrderLines.count }

    var orderedQuantity: Double {
        purchaseOrderLines.reduce(0) { $0 + max($1.quantity, 0) }
    }

    var merchandiseTotal: Double {
        purchaseOrderLines.reduce(0) { $0 + $1.merchandiseTotal }
    }

    var total: Double { merchandiseTotal + max(shippingCost, 0) }

    func line(for lineID: UUID) -> PurchaseOrderLine? {
        purchaseOrderLines.first { $0.id == lineID }
    }

    func acceptedUnitCost(for lineID: UUID) -> Double {
        if let accepted = decodedNotesEnvelope?.confirmedLineUnitCosts?.first(where: { $0.lineID == lineID }) {
            return max(accepted.unitCost, 0)
        }
        if lineID == purchaseOrderLines.first?.id, let confirmation = supplierOrderConfirmation {
            return max(confirmation.confirmedUnitCost, 0)
        }
        return max(line(for: lineID)?.unitCost ?? 0, 0)
    }

    /// User-entered notes remain readable after structured order evidence is
    /// stored in the existing CloudKit-backed notes field.
    var userNotes: String? {
        guard let envelope = decodedNotesEnvelope else {
            let normalized = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized?.isEmpty == false ? normalized : nil
        }
        let normalized = envelope.userNotes?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized?.isEmpty == false ? normalized : nil
    }

    var supplierOrderConfirmation: SupplierOrderConfirmation? {
        decodedNotesEnvelope?.supplierOrderConfirmation
    }

    var hasSupplierOrderConfirmation: Bool {
        supplierOrderConfirmation != nil
    }

    var purchaseOrderReceipts: [PurchaseOrderReceipt] {
        (decodedNotesEnvelope?.receipts ?? []).sorted {
            if $0.receivedAt == $1.receivedAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.receivedAt < $1.receivedAt
        }
    }

    var receivedSerializedAssets: [PurchaseOrderReceivedAsset] {
        purchaseOrderReceipts
            .flatMap { $0.serializedAssets ?? [] }
            .sorted { lhs, rhs in
                let comparison = lhs.serialNumber.localizedCaseInsensitiveCompare(rhs.serialNumber)
                return comparison == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : comparison == .orderedAscending
            }
    }

    var assetInstallations: [PurchaseOrderAssetInstallation] {
        (decodedNotesEnvelope?.assetInstallations ?? []).sorted {
            if $0.installedAt == $1.installedAt { return $0.assetID.uuidString < $1.assetID.uuidString }
            return $0.installedAt < $1.installedAt
        }
    }

    func installation(for assetID: UUID) -> PurchaseOrderAssetInstallation? {
        assetInstallations.first { $0.assetID == assetID }
    }

    func receipt(containing assetID: UUID) -> PurchaseOrderReceipt? {
        purchaseOrderReceipts.first { receipt in
            receipt.serializedAssets?.contains(where: { $0.id == assetID }) == true
        }
    }

    func line(containing assetID: UUID) -> PurchaseOrderLine? {
        guard let receipt = receipt(containing: assetID) else { return nil }
        return receipt.lineID.flatMap(line(for:)) ?? purchaseOrderLines.first
    }

    var receivedQuantity: Double {
        purchaseOrderLines.reduce(0) { $0 + receivedQuantity(for: $1.id) }
    }

    var remainingQuantity: Double {
        let remaining = orderedQuantity - receivedQuantity
        return abs(remaining) <= 0.0001 ? 0 : max(remaining, 0)
    }

    func receivedQuantity(for lineID: UUID) -> Double {
        guard let line = line(for: lineID) else { return 0 }
        let primaryLineID = purchaseOrderLines.first?.id
        let received = purchaseOrderReceipts.reduce(0) { total, receipt in
            let receiptLineID = receipt.lineID ?? primaryLineID
            return total + (receiptLineID == lineID ? max(receipt.quantity, 0) : 0)
        }
        return min(received, max(line.quantity, 0))
    }

    func remainingQuantity(for lineID: UUID) -> Double {
        guard let line = line(for: lineID) else { return 0 }
        let remaining = max(line.quantity, 0) - receivedQuantity(for: lineID)
        return abs(remaining) <= 0.0001 ? 0 : max(remaining, 0)
    }

    func billedQuantity(for lineID: UUID) -> Double {
        let primaryLineID = purchaseOrderLines.first?.id
        return vendorBills.reduce(0) { total, bill in
            if let allocations = bill.lineAllocations, !allocations.isEmpty {
                return total + allocations.reduce(0) {
                    $0 + ($1.lineID == lineID ? max($1.quantity, 0) : 0)
                }
            }
            return total + ((primaryLineID == lineID) ? max(bill.quantity, 0) : 0)
        }
    }

    var hasPartialReceipt: Bool {
        receivedQuantity > 0.0001 && remainingQuantity > 0.0001
    }

    var vendorBills: [PurchaseOrderVendorBill] {
        (decodedNotesEnvelope?.vendorBills ?? []).sorted {
            if $0.invoiceDate == $1.invoiceDate {
                if $0.recordedAt == $1.recordedAt { return $0.id.uuidString < $1.id.uuidString }
                return $0.recordedAt < $1.recordedAt
            }
            return $0.invoiceDate < $1.invoiceDate
        }
    }

    var vendorReturns: [PurchaseOrderVendorReturn] {
        (decodedNotesEnvelope?.vendorReturns ?? []).sorted {
            if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.createdAt < $1.createdAt
        }
    }

    func vendorReturn(withID returnID: UUID) -> PurchaseOrderVendorReturn? {
        vendorReturns.first { $0.id == returnID }
    }

    var billMatch: PurchaseOrderBillMatch {
        let bills = vendorBills
        let billedQuantity = purchaseOrderLines.reduce(0) { $0 + self.billedQuantity(for: $1.id) }
        let merchandise = bills.reduce(0) { $0 + max($1.merchandiseAmount, 0) }
        let shipping = bills.reduce(0) { $0 + max($1.shippingCost, 0) }
        let tax = bills.reduce(0) { $0 + max($1.taxAmount, 0) }
        let other = bills.reduce(0) { $0 + max($1.otherCharges, 0) }
        let orderedQuantity = self.orderedQuantity
        let confirmation = supplierOrderConfirmation
        let expectedMerchandise = purchaseOrderLines.reduce(0) { total, line in
            total + self.billedQuantity(for: line.id) * acceptedUnitCost(for: line.id)
        }
        let expectedShipping = max(confirmation?.confirmedShippingCost ?? shippingCost, 0)
        let moneyTolerance = 0.01
        let quantityTolerance = 0.0001

        let state: PurchaseOrderBillMatchState
        if bills.isEmpty {
            state = .notRecorded
        } else if purchaseOrderLines.contains(where: {
            self.billedQuantity(for: $0.id) > max($0.quantity, 0) + quantityTolerance
        }) {
            state = .quantityVariance
        } else {
            let merchandiseVariance = abs(merchandise - expectedMerchandise) > moneyTolerance
            let completesOrder = billedQuantity >= orderedQuantity - quantityTolerance
            let shippingVariance = shipping > expectedShipping + moneyTolerance ||
                (completesOrder && abs(shipping - expectedShipping) > moneyTolerance)
            if merchandiseVariance || shippingVariance || other > moneyTolerance {
                state = .costVariance
            } else if purchaseOrderLines.contains(where: {
                receivedQuantity(for: $0.id) + quantityTolerance < self.billedQuantity(for: $0.id)
            }) {
                state = .awaitingReceipt
            } else if !completesOrder {
                state = .inProgress
            } else if purchaseOrderLines.contains(where: {
                receivedQuantity(for: $0.id) + quantityTolerance < max($0.quantity, 0)
            }) {
                state = .awaitingReceipt
            } else {
                state = .matched
            }
        }

        return PurchaseOrderBillMatch(
            state: state,
            billedQuantity: billedQuantity,
            orderedQuantity: orderedQuantity,
            receivedQuantity: receivedQuantity,
            billedMerchandiseAmount: merchandise,
            expectedMerchandiseAmount: expectedMerchandise,
            billedShippingCost: shipping,
            expectedShippingCost: expectedShipping,
            taxAmount: tax,
            otherCharges: other,
            totalAmount: merchandise + shipping + tax + other
        )
    }

    var receivingSummary: String? {
        guard !purchaseOrderReceipts.isEmpty else { return nil }
        let received = receivedQuantity.formatted(.number.precision(.fractionLength(0...3)))
        let ordered = orderedQuantity.formatted(.number.precision(.fractionLength(0...3)))
        if remainingQuantity <= 0.0001 {
            return "\(received) of \(ordered) received"
        }
        let remaining = remainingQuantity.formatted(.number.precision(.fractionLength(0...3)))
        return "\(received) of \(ordered) received • \(remaining) backordered"
    }

    var supplierOrderConfirmationSummary: String? {
        guard let confirmation = supplierOrderConfirmation else { return nil }
        let location = confirmation.supplierLocation.map { " • \($0)" } ?? ""
        return "\(confirmation.channel.displayName) • Ref \(confirmation.reference)\(location)"
    }

    @discardableResult
    fileprivate func storeSupplierOrderConfirmation(
        _ confirmation: SupplierOrderConfirmation,
        confirmedLineUnitCosts: [PurchaseOrderLineUnitCost]? = nil
    ) -> Bool {
        let acceptedCosts = confirmedLineUnitCosts ?? decodedNotesEnvelope?.confirmedLineUnitCosts
        let acceptedByLineID = Dictionary(uniqueKeysWithValues: (acceptedCosts ?? []).map { ($0.lineID, $0.unitCost) })
        let acceptedLines = purchaseOrderLines.map { line in
            PurchaseOrderLine(
                id: line.id,
                catalogItemID: line.catalogItemID,
                itemName: line.itemName,
                itemSKU: line.itemSKU,
                vendorPartNumber: line.vendorPartNumber,
                quantity: line.quantity,
                unitCost: acceptedByLineID[line.id] ?? line.unitCost,
                serialTrackingRequired: line.serialTrackingRequired
            )
        }
        let envelope = NotesEnvelope(
            version: 6,
            userNotes: userNotes,
            supplierOrderConfirmation: confirmation,
            receipts: purchaseOrderReceipts,
            vendorBills: vendorBills,
            lineItems: acceptedLines,
            confirmedLineUnitCosts: acceptedCosts,
            assetInstallations: assetInstallations,
            vendorReturns: vendorReturns
        )
        guard let data = try? JSONEncoder().encode(envelope) else { return false }
        notes = Self.notesEnvelopePrefix + data.base64EncodedString()
        if let primary = acceptedLines.first {
            itemName = primary.itemName
            itemSKU = primary.itemSKU
            vendorPartNumber = primary.vendorPartNumber
            quantity = primary.quantity
            unitCost = primary.unitCost
        }
        return true
    }

    @discardableResult
    fileprivate func appendReceipt(_ receipt: PurchaseOrderReceipt) -> Bool {
        var receipts = purchaseOrderReceipts
        guard !receipts.contains(where: { $0.id == receipt.id }) else { return false }
        receipts.append(receipt)
        let envelope = NotesEnvelope(
            version: 6,
            userNotes: userNotes,
            supplierOrderConfirmation: supplierOrderConfirmation,
            receipts: receipts,
            vendorBills: vendorBills,
            lineItems: purchaseOrderLines,
            confirmedLineUnitCosts: decodedNotesEnvelope?.confirmedLineUnitCosts,
            assetInstallations: assetInstallations,
            vendorReturns: vendorReturns
        )
        guard let data = try? JSONEncoder().encode(envelope) else { return false }
        notes = Self.notesEnvelopePrefix + data.base64EncodedString()
        return true
    }

    @discardableResult
    fileprivate func appendVendorBill(_ bill: PurchaseOrderVendorBill) -> Bool {
        var bills = vendorBills
        guard !bills.contains(where: { $0.id == bill.id }) else { return false }
        bills.append(bill)
        let envelope = NotesEnvelope(
            version: 6,
            userNotes: userNotes,
            supplierOrderConfirmation: supplierOrderConfirmation,
            receipts: purchaseOrderReceipts,
            vendorBills: bills,
            lineItems: purchaseOrderLines,
            confirmedLineUnitCosts: decodedNotesEnvelope?.confirmedLineUnitCosts,
            assetInstallations: assetInstallations,
            vendorReturns: vendorReturns
        )
        guard let data = try? JSONEncoder().encode(envelope) else { return false }
        notes = Self.notesEnvelopePrefix + data.base64EncodedString()
        return true
    }

    @discardableResult
    func replaceVendorBill(_ updatedBill: PurchaseOrderVendorBill) -> Bool {
        var bills = vendorBills
        guard let index = bills.firstIndex(where: { $0.id == updatedBill.id }) else {
            return false
        }
        bills[index] = updatedBill
        let envelope = NotesEnvelope(
            version: 6,
            userNotes: userNotes,
            supplierOrderConfirmation: supplierOrderConfirmation,
            receipts: purchaseOrderReceipts,
            vendorBills: bills,
            lineItems: purchaseOrderLines,
            confirmedLineUnitCosts: decodedNotesEnvelope?.confirmedLineUnitCosts,
            assetInstallations: assetInstallations,
            vendorReturns: vendorReturns
        )
        guard let data = try? JSONEncoder().encode(envelope) else { return false }
        notes = Self.notesEnvelopePrefix + data.base64EncodedString()
        return true
    }

    @discardableResult
    fileprivate func storeLineItems(_ lines: [PurchaseOrderLine]) -> Bool {
        guard let primary = lines.first else { return false }
        let envelope = NotesEnvelope(
            version: 6,
            userNotes: userNotes,
            supplierOrderConfirmation: supplierOrderConfirmation,
            receipts: purchaseOrderReceipts,
            vendorBills: vendorBills,
            lineItems: lines,
            confirmedLineUnitCosts: decodedNotesEnvelope?.confirmedLineUnitCosts,
            assetInstallations: assetInstallations,
            vendorReturns: vendorReturns
        )
        guard let data = try? JSONEncoder().encode(envelope) else { return false }
        notes = Self.notesEnvelopePrefix + data.base64EncodedString()
        itemName = primary.itemName
        itemSKU = primary.itemSKU
        vendorPartNumber = primary.vendorPartNumber
        quantity = primary.quantity
        unitCost = primary.unitCost
        return true
    }

    @discardableResult
    fileprivate func appendAssetInstallation(_ installation: PurchaseOrderAssetInstallation) -> Bool {
        var installations = assetInstallations
        guard receivedSerializedAssets.contains(where: { $0.id == installation.assetID }),
              !installations.contains(where: { $0.assetID == installation.assetID }) else {
            return false
        }
        installations.append(installation)
        let envelope = NotesEnvelope(
            version: 6,
            userNotes: userNotes,
            supplierOrderConfirmation: supplierOrderConfirmation,
            receipts: purchaseOrderReceipts,
            vendorBills: vendorBills,
            lineItems: purchaseOrderLines,
            confirmedLineUnitCosts: decodedNotesEnvelope?.confirmedLineUnitCosts,
            assetInstallations: installations,
            vendorReturns: vendorReturns
        )
        guard let data = try? JSONEncoder().encode(envelope) else { return false }
        notes = Self.notesEnvelopePrefix + data.base64EncodedString()
        return true
    }

    @discardableResult
    func storeVendorReturns(_ returns: [PurchaseOrderVendorReturn]) -> Bool {
        guard Set(returns.map(\.id)).count == returns.count else { return false }
        let envelope = NotesEnvelope(
            version: 6,
            userNotes: userNotes,
            supplierOrderConfirmation: supplierOrderConfirmation,
            receipts: purchaseOrderReceipts,
            vendorBills: vendorBills,
            lineItems: purchaseOrderLines,
            confirmedLineUnitCosts: decodedNotesEnvelope?.confirmedLineUnitCosts,
            assetInstallations: assetInstallations,
            vendorReturns: returns
        )
        guard let data = try? JSONEncoder().encode(envelope) else { return false }
        notes = Self.notesEnvelopePrefix + data.base64EncodedString()
        return true
    }

    @discardableResult
    func replaceVendorReturn(_ updatedReturn: PurchaseOrderVendorReturn) -> Bool {
        var returns = vendorReturns
        guard let index = returns.firstIndex(where: { $0.id == updatedReturn.id }) else {
            return false
        }
        returns[index] = updatedReturn
        return storeVendorReturns(returns)
    }

    private var decodedNotesEnvelope: NotesEnvelope? {
        guard let notes,
              notes.hasPrefix(Self.notesEnvelopePrefix) else { return nil }
        let encoded = String(notes.dropFirst(Self.notesEnvelopePrefix.count))
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONDecoder().decode(NotesEnvelope.self, from: data)
    }

    /// A shareable, non-authoritative ordering summary for an approved supplier
    /// channel. It contains no supplier credentials and never transmits an order.
    var supplierOrderSummary: String {
        var lines = [
            "GunnAire Ops purchase order \(number)",
            "Vendor: \(vendorName)"
        ]
        if lineCount == 1, let line = purchaseOrderLines.first {
            lines.append("Part: \(line.itemName)")
            lines.append("Quantity: \(line.quantity.formatted())")
            lines.append("Expected unit cost: \(line.unitCost.formatted(.currency(code: "USD")))")
            lines.append("Expected total: \(total.formatted(.currency(code: "USD")))")
            if let vendorPartNumber = line.vendorPartNumber,
               !vendorPartNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("Supplier part #: \(vendorPartNumber)")
            }
            if let itemSKU = line.itemSKU,
               !itemSKU.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("Internal SKU: \(itemSKU)")
            }
        } else {
            lines.append("Items: \(lineCount)")
            lines.append("Expected total: \(total.formatted(.currency(code: "USD")))")
            for (index, line) in purchaseOrderLines.enumerated() {
                lines.append("Line \(index + 1): \(line.quantity.formatted()) × \(line.itemName) at \(line.unitCost.formatted(.currency(code: "USD")))")
                if let vendorPartNumber = line.vendorPartNumber,
                   !vendorPartNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append("Line \(index + 1) supplier part #: \(vendorPartNumber)")
                }
                if let itemSKU = line.itemSKU,
                   !itemSKU.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append("Line \(index + 1) internal SKU: \(itemSKU)")
                }
            }
        }
        if let userNotes {
            lines.append("Notes: \(userNotes)")
        }
        if let confirmation = supplierOrderConfirmation {
            lines.append("Supplier confirmation: \(confirmation.reference)")
            lines.append("Confirmed channel: \(confirmation.channel.displayName)")
            if let connectorKind = confirmation.connectorKind {
                lines.append("Connector: \(connectorKind.displayName)")
            }
            if let connectorContractVersion = confirmation.connectorContractVersion {
                lines.append("Connector contract: v\(connectorContractVersion)")
            }
            if let externalOrderID = confirmation.externalOrderID {
                lines.append("External order ID: \(externalOrderID)")
            }
            if let supplierLocation = confirmation.supplierLocation {
                lines.append("Supplier location: \(supplierLocation)")
            }
            lines.append("Confirmed by: \(confirmation.confirmedByEmail)")
        }
        if let receivingSummary {
            lines.append("Receiving: \(receivingSummary)")
            for receipt in purchaseOrderReceipts {
                let date = receipt.receivedAt.formatted(date: .abbreviated, time: .shortened)
                lines.append("Shipment: \(receipt.summary) • \(date) • \(receipt.receivedByEmail)")
                for asset in receipt.serializedAssets ?? [] {
                    lines.append("Received asset: \(asset.displayName)")
                    if let installation = installation(for: asset.id) {
                        lines.append("Installed asset: job \(installation.serviceCallID.uuidString) • equipment \(installation.customerEquipmentID.uuidString) • \(installation.installedByEmail)")
                    }
                }
                if let note = receipt.note {
                    lines.append("Shipment note: \(note)")
                }
            }
        }
        if !vendorBills.isEmpty {
            lines.append("Bill reconciliation: \(billMatch.state.displayName) • \(billMatch.summary)")
            for bill in vendorBills {
                lines.append("Vendor bill: \(bill.invoiceNumber) • \(bill.totalAmount.formatted(.currency(code: "USD")))")
                for allocation in effectiveAllocations(for: bill) {
                    lines.append("Bill line: \(allocation.quantity.formatted()) × \(allocation.itemName) at \(allocation.unitCost.formatted(.currency(code: "USD")))")
                }
                if let sourceDocumentName = bill.sourceDocumentName {
                    lines.append("Bill document: \(sourceDocumentName)")
                }
                if let quickBooksBillID = bill.quickBooksBillID {
                    lines.append("QuickBooks Bill ID: \(quickBooksBillID)")
                }
            }
        }
        if !vendorReturns.isEmpty {
            lines.append("Supplier returns: \(vendorReturns.count)")
            for vendorReturn in vendorReturns {
                let allocations = vendorReturn.lineAllocations.map {
                    "\($0.quantity.formatted()) × \($0.itemName)"
                }.joined(separator: ", ")
                lines.append("Return \(vendorReturn.reference): \(vendorReturn.status.displayName) • \(allocations) • from \(vendorReturn.sourceLocation)")
                if let credit = vendorReturn.creditEvidence {
                    let match = vendorCreditMatch(for: vendorReturn)
                    lines.append("Vendor credit \(credit.reference): \(match.state.displayName) • \(match.summary)")
                    if let sourceDocumentName = credit.sourceDocumentName {
                        lines.append("Credit document: \(sourceDocumentName)")
                    }
                    if let quickBooksVendorCreditID = credit.quickBooksVendorCreditID {
                        lines.append("QuickBooks Vendor Credit ID: \(quickBooksVendorCreditID)")
                    }
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    func effectiveAllocations(for bill: PurchaseOrderVendorBill) -> [PurchaseOrderBillLineAllocation] {
        if let allocations = bill.lineAllocations, !allocations.isEmpty {
            return allocations
        }
        guard let primary = purchaseOrderLines.first else { return [] }
        return [
            PurchaseOrderBillLineAllocation(
                lineID: primary.id,
                itemName: primary.itemName,
                quantity: bill.quantity,
                unitCost: bill.unitCost
            )
        ]
    }

    static func nextNumber(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "PO-\(formatter.string(from: now))-\(String(UUID().uuidString.prefix(4)))"
    }
}

private extension String {
    func isValidSupplierConnectorIdentifier(maximum: Int) -> Bool {
        let normalized = trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalized.isEmpty &&
            normalized.count <= maximum &&
            normalized.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
    }

    var isValidSupplierIdempotencyKey: Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:-"))
        return (16...128).contains(count) && unicodeScalars.allSatisfy(allowed.contains)
    }
}

/// Converts a field-observed stock shortage into office-reviewable procurement
/// work without pretending that a supplier order was transmitted. Requests use
/// the existing CloudKit-backed purchase-order record so the job, part, actor,
/// quantity, and eventual receiving trail stay connected without another schema.
enum InventoryReplenishment {
    static let vendorReviewName = "Supplier review required"

    static func suggestedQuantity(for item: Item, onHand: Double) -> Double {
        let target = max(item.reorderPoint ?? 0, 0)
        return max(target - onHand, 0)
    }

    static func openOrder(
        for item: Item,
        serviceCallID: UUID,
        purchaseOrders: [PurchaseOrder]
    ) -> PurchaseOrder? {
        purchaseOrders.first { order in
            order.serviceCallID == serviceCallID &&
                order.status != .received &&
                order.status != .cancelled &&
                matches(order, item: item)
        }
    }

    static func request(
        for item: Item,
        serviceCallID: UUID,
        sourceLocation: String,
        onHand: Double,
        actorEmail: String?
    ) -> PurchaseOrder? {
        let quantity = suggestedQuantity(for: item, onHand: onHand)
        guard quantity > 0.0001 else { return nil }
        let preferredVendor = item.preferredVendorName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let vendorName = preferredVendor.flatMap { $0.isEmpty ? nil : $0 } ?? vendorReviewName
        let target = max(item.reorderPoint ?? 0, 0)
        return PurchaseOrder(
            vendorName: vendorName,
            vendorQuickBooksID: item.preferredVendorQuickBooksID,
            serviceCallID: serviceCallID,
            itemName: item.name,
            itemSKU: item.sku,
            vendorPartNumber: item.vendorPartNumber,
            quantity: quantity,
            unitCost: max(item.purchaseCost ?? 0, 0),
            status: .requested,
            notes: "Restock \(sourceLocation) from \(onHand.formatted()) on hand to the \(target.formatted()) reorder point. Requested from job material use.",
            createdByEmail: actorEmail
        )
    }

    /// Promotes a field request to an office-owned draft only after the pricebook
    /// identifies a supplier. It still does not transmit or mark the order placed.
    @discardableResult
    static func prepareDraft(_ order: PurchaseOrder, catalogItems: [Item]) -> Bool {
        guard order.status == .requested,
              let item = catalogItems.first(where: { matches(order, item: $0) }),
              let preferredVendor = item.preferredVendorName?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !preferredVendor.isEmpty else {
            return false
        }
        order.vendorName = preferredVendor
        order.vendorQuickBooksID = item.preferredVendorQuickBooksID
        order.itemSKU = item.sku
        order.vendorPartNumber = item.vendorPartNumber
        order.unitCost = max(item.purchaseCost ?? order.unitCost, 0)
        order.status = .draft
        return true
    }

    private static func matches(_ order: PurchaseOrder, item: Item) -> Bool {
        let orderSKU = normalized(order.itemSKU)
        let itemSKU = normalized(item.sku)
        if !orderSKU.isEmpty, !itemSKU.isEmpty {
            return orderSKU == itemSKU
        }
        guard normalized(order.itemName) == normalized(item.name) else { return false }
        let orderPart = normalized(order.vendorPartNumber)
        let itemPart = normalized(item.vendorPartNumber)
        return orderPart.isEmpty || itemPart.isEmpty || orderPart == itemPart
    }

    private static func normalized(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }
}

enum PurchaseOrderReceiving {
    /// Backward-compatible full-receipt entry point. New UI uses
    /// `receiveShipment` so split and backordered shipments remain visible.
    static func receive(
        _ order: PurchaseOrder,
        catalogItems: [Item],
        actorEmail: String?
    ) -> InventoryMovement? {
        guard let openLine = order.purchaseOrderLines.first(where: {
            order.remainingQuantity(for: $0.id) > 0.0001
        }) else { return nil }
        return try? receiveShipment(
            order,
            lineID: openLine.id,
            quantity: order.remainingQuantity(for: openLine.id),
            destinationLocation: defaultDestination(for: order, lineID: openLine.id, catalogItems: catalogItems),
            note: nil,
            catalogItems: catalogItems,
            actorEmail: actorEmail
        ).inventoryMovement
    }

    static func receiveShipment(
        _ order: PurchaseOrder,
        lineID requestedLineID: UUID? = nil,
        quantity receivedQuantity: Double,
        destinationLocation: String,
        note: String?,
        serialNumbers: [String] = [],
        manufacturer: String? = nil,
        modelNumber: String? = nil,
        catalogItems: [Item],
        actorEmail: String?,
        at date: Date = Date(),
        receiptID: UUID = UUID(),
        serializedAssetIDs: [UUID]? = nil
    ) throws -> PurchaseOrderReceiptOutcome {
        guard order.status == .ordered || order.status == .partiallyReceived else {
            throw PurchaseOrderReceivingError.invalidState
        }
        guard order.hasSupplierOrderConfirmation else {
            throw PurchaseOrderReceivingError.missingSupplierConfirmation
        }
        let actor = normalized(actorEmail)
        guard !actor.isEmpty else {
            throw PurchaseOrderReceivingError.actorRequired
        }
        let location = normalized(destinationLocation)
        guard !location.isEmpty else {
            throw PurchaseOrderReceivingError.locationRequired
        }
        guard location.count <= 100 else {
            throw PurchaseOrderReceivingError.locationTooLong
        }
        guard receivedQuantity.isFinite, receivedQuantity > 0.0001 else {
            throw PurchaseOrderReceivingError.invalidQuantity
        }
        guard let line = requestedLineID.flatMap({ order.line(for: $0) }) ?? order.purchaseOrderLines.first else {
            throw PurchaseOrderReceivingError.missingLine
        }
        let remaining = order.remainingQuantity(for: line.id)
        guard remaining > 0.0001 else {
            throw PurchaseOrderReceivingError.invalidState
        }
        guard receivedQuantity <= remaining + 0.0001 else {
            throw PurchaseOrderReceivingError.exceedsRemainingQuantity
        }
        let normalizedNote = normalized(note)
        guard normalizedNote.count <= 240 else {
            throw PurchaseOrderReceivingError.noteTooLong
        }

        let normalizedManufacturer = normalized(manufacturer)
        guard normalizedManufacturer.count <= 100 else {
            throw PurchaseOrderReceivingError.manufacturerTooLong
        }
        let normalizedModel = normalized(modelNumber)
        guard normalizedModel.count <= 100 else {
            throw PurchaseOrderReceivingError.modelNumberTooLong
        }
        let normalizedSerials = serialNumbers
            .map { normalized($0) }
            .filter { !$0.isEmpty }
        let serialTrackingRequired = line.serialTrackingRequired == true
        if serialTrackingRequired || !normalizedSerials.isEmpty {
            let wholeQuantity = receivedQuantity.rounded()
            guard abs(receivedQuantity - wholeQuantity) <= 0.0001,
                  wholeQuantity >= 1,
                  wholeQuantity <= 100 else {
                throw PurchaseOrderReceivingError.serialTrackingRequiresWholeQuantity
            }
            guard normalizedSerials.count == Int(wholeQuantity) else {
                throw PurchaseOrderReceivingError.serialCountMismatch
            }
            guard normalizedSerials.allSatisfy({ $0.count <= 80 }) else {
                throw PurchaseOrderReceivingError.serialNumberTooLong
            }
            let normalizedKeys = normalizedSerials.map(EquipmentCodeLookup.normalizedSerial)
            let priorKeys = Set(order.receivedSerializedAssets.map {
                EquipmentCodeLookup.normalizedSerial($0.serialNumber)
            })
            guard normalizedKeys.allSatisfy({ $0.count >= 4 }),
                  Set(normalizedKeys).count == normalizedKeys.count,
                  priorKeys.isDisjoint(with: normalizedKeys) else {
                throw PurchaseOrderReceivingError.duplicateSerialNumber
            }
        }
        let assetIDs = serializedAssetIDs ?? normalizedSerials.map { _ in UUID() }
        guard assetIDs.count == normalizedSerials.count,
              Set(assetIDs).count == assetIDs.count else {
            throw PurchaseOrderReceivingError.unableToStoreEvidence
        }
        let serializedAssets = zip(assetIDs, normalizedSerials).map { assetID, serial in
            PurchaseOrderReceivedAsset(
                id: assetID,
                serialNumber: serial,
                manufacturer: normalizedManufacturer.isEmpty ? nil : normalizedManufacturer,
                modelNumber: normalizedModel.isEmpty ? nil : normalizedModel
            )
        }

        let acceptedQuantity = min(receivedQuantity, remaining)
        let trackedItem = matchedItem(for: order, lineID: line.id, catalogItems: catalogItems).flatMap { item in
            item.tracksInventory ? item : nil
        }
        let movementID = trackedItem.map { _ in UUID() }
        let receipt = PurchaseOrderReceipt(
            id: receiptID,
            lineID: line.id,
            itemName: order.lineCount > 1 ? line.itemName : nil,
            quantity: acceptedQuantity,
            destinationLocation: location,
            note: normalizedNote.isEmpty ? nil : normalizedNote,
            receivedByEmail: actor,
            receivedAt: date,
            inventoryMovementID: movementID,
            serializedAssets: serializedAssets.isEmpty ? nil : serializedAssets
        )
        guard order.appendReceipt(receipt) else {
            throw PurchaseOrderReceivingError.unableToStoreEvidence
        }

        order.receivedToLocation = location
        order.updatedAt = date
        if order.remainingQuantity <= 0.0001 {
            order.statusRaw = PurchaseOrderStatus.received.rawValue
            order.receivedAt = date
        } else {
            order.statusRaw = PurchaseOrderStatus.partiallyReceived.rawValue
            order.receivedAt = nil
        }

        let movement = trackedItem.flatMap { item in
            movementID.map { movementID in
                InventoryMovement(
                    id: movementID,
                    item: item,
                    type: .receive,
                    quantity: acceptedQuantity,
                    destinationLocation: location,
                    serviceCallID: order.serviceCallID,
                    notes: order.lineCount == 1
                        ? "Received from \(order.vendorName) on \(order.number)."
                        : "Received \(line.itemName) from \(order.vendorName) on \(order.number).",
                    createdByEmail: actor,
                    createdAt: date
                )
            }
        }
        return PurchaseOrderReceiptOutcome(receipt: receipt, inventoryMovement: movement)
    }

    static func defaultDestination(
        for order: PurchaseOrder,
        lineID: UUID? = nil,
        catalogItems: [Item]
    ) -> String {
        let configured = matchedItem(for: order, lineID: lineID, catalogItems: catalogItems)?
            .defaultInventoryLocation?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return configured.isEmpty ? "Warehouse" : configured
    }

    static func matchedItem(
        for order: PurchaseOrder,
        lineID: UUID? = nil,
        catalogItems: [Item]
    ) -> Item? {
        guard let line = lineID.flatMap({ order.line(for: $0) }) ?? order.purchaseOrderLines.first else {
            return nil
        }
        if let catalogItemID = line.catalogItemID,
           let item = catalogItems.first(where: { $0.id == catalogItemID }) {
            return item
        }
        let sku = line.itemSKU?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sku, !sku.isEmpty,
           let item = catalogItems.first(where: { $0.sku?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(sku) == .orderedSame }) {
            return item
        }
        return catalogItems.first { item in
            item.name.caseInsensitiveCompare(line.itemName) == .orderedSame &&
                item.vendorPartNumber?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(line.vendorPartNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") == .orderedSame
        }
    }

    nonisolated private static func normalized(_ value: String?) -> String {
        value?
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ") ?? ""
    }
}
