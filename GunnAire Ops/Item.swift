//
//  Item.swift
//  GunnAire Ops
//
//  Created by Eric Gunn on 2/23/26.
//

import Foundation
import SwiftData

enum CatalogItemType: String, Codable, CaseIterable, Identifiable {
    case service = "Service"
    case nonInventory = "NonInventory"

    var id: String { rawValue }
}

enum PricebookReviewStatus: String, Codable, CaseIterable {
    case approved
    case needsReview = "needs_review"
}

/// A reusable service package can either remain one customer-facing flat-rate
/// line or expand into its individual approved pricebook lines. The definition
/// lives on the service item; every estimate/invoice captures an immutable
/// snapshot so later pricebook edits cannot rewrite sold work.
enum CatalogAssemblyPresentation: String, Codable, CaseIterable, Identifiable, Sendable {
    case flatRate = "flat_rate"
    case itemized

    var id: String { rawValue }

    var label: String {
        switch self {
        case .flatRate: "Flat Rate"
        case .itemized: "Itemized"
        }
    }

    var explanation: String {
        switch self {
        case .flatRate:
            "Adds one customer-facing service line while retaining the included labor and materials for costing and stock planning."
        case .itemized:
            "Adds every included pricebook item as its own customer and QuickBooks line."
        }
    }
}

struct CatalogAssemblyComponentDefinition: Codable, Equatable, Identifiable, Sendable {
    let itemID: UUID
    let quantity: Double

    var id: UUID { itemID }
}

struct CatalogAssemblyDefinition: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let revision: Int
    let presentation: CatalogAssemblyPresentation
    let components: [CatalogAssemblyComponentDefinition]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        revision: Int = 1,
        presentation: CatalogAssemblyPresentation,
        components: [CatalogAssemblyComponentDefinition]
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.presentation = presentation
        self.components = components
    }

    var encodedJSON: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decoded(from json: String?) -> Self? {
        guard let json,
              let data = json.data(using: .utf8),
              let definition = try? JSONDecoder().decode(Self.self, from: data),
              definition.schemaVersion == currentSchemaVersion else { return nil }
        return definition
    }
}

struct CatalogAssemblyComponentSnapshot: Codable, Equatable, Identifiable, Sendable {
    let itemID: UUID
    let name: String
    let sku: String?
    let quantity: Double
    let purchaseCost: Double?
    let tracksInventory: Bool

    var id: UUID { itemID }
}

struct CatalogLineAssemblySnapshot: Codable, Equatable, Identifiable, Sendable {
    let assemblyItemID: UUID
    let name: String
    let revision: Int
    let presentation: CatalogAssemblyPresentation
    let components: [CatalogAssemblyComponentSnapshot]

    var id: UUID { assemblyItemID }

    var unitPurchaseCost: Double? {
        guard !components.isEmpty,
              components.allSatisfy({ $0.purchaseCost != nil }) else { return nil }
        return components.reduce(0) { partial, component in
            partial + (component.purchaseCost ?? 0) * component.quantity
        }
    }

    var lineContext: String {
        switch presentation {
        case .flatRate: "Flat-rate package: \(name)"
        case .itemized: "Package: \(name)"
        }
    }
}

/// A job-specific price is never written back to the company pricebook. The
/// authorization travels with the estimate/invoice line so later edits,
/// exports, and QuickBooks retries can reproduce the exact approved amount.
struct AuthorizedLinePriceAdjustment: Codable, Equatable {
    let pricebookUnitPrice: Double
    let unitPrice: Double
    let reason: String
    let authorizedByEmail: String
    let authorizedAt: Date
}

enum BillingDocumentDiscountKind: String, Codable, CaseIterable, Identifiable {
    case percentage
    case fixedAmount = "fixed_amount"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .percentage: "Percent"
        case .fixedAmount: "Fixed Amount"
        }
    }
}

/// A revenue-reducing adjustment authorized against one exact document scope.
/// Keeping the gross subtotal in the immutable evidence prevents later line
/// edits from silently expanding a previously approved percentage discount.
struct AuthorizedDocumentDiscount: Codable, Equatable {
    let kind: BillingDocumentDiscountKind
    let value: Double
    let grossSubtotalAtAuthorization: Double
    let reason: String
    let authorizedByEmail: String
    let authorizedAt: Date

    func amount(for grossSubtotal: Double) -> Double? {
        guard grossSubtotal.isFinite,
              grossSubtotal >= 0,
              BillingDocumentDiscountPolicy.currencyCents(grossSubtotal) ==
                BillingDocumentDiscountPolicy.currencyCents(grossSubtotalAtAuthorization) else {
            return nil
        }
        let rawAmount: Double
        switch kind {
        case .percentage:
            rawAmount = grossSubtotal * value / 100
        case .fixedAmount:
            rawAmount = value
        }
        guard rawAmount.isFinite, rawAmount >= 0 else { return nil }
        return min(BillingDocumentDiscountPolicy.roundCurrency(rawAmount), grossSubtotal)
    }

    var valueDisplayName: String {
        switch kind {
        case .percentage:
            "\(value.formatted(.number.precision(.fractionLength(0...2))))%"
        case .fixedAmount:
            value.formatted(.currency(code: "USD"))
        }
    }
}

enum BillingDocumentDiscountError: LocalizedError, Equatable {
    case unauthorized
    case invalidSubtotal
    case invalidValue
    case exceedsSubtotal
    case missingReason
    case reasonTooLong
    case scopeChanged

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Only an administrator can authorize a document discount."
        case .invalidSubtotal:
            "Add at least one priced line before authorizing a discount."
        case .invalidValue:
            "Enter a percentage greater than 0 and no more than 100, or a fixed amount greater than 0."
        case .exceedsSubtotal:
            "A fixed discount cannot exceed the current line-item subtotal."
        case .missingReason:
            "Enter the customer-visible business reason for this discount."
        case .reasonTooLong:
            "Keep the discount reason to 240 characters or fewer."
        case .scopeChanged:
            "The line-item subtotal changed after this discount was authorized. Reauthorize or remove the discount before saving."
        }
    }
}

enum BillingDocumentDiscountPolicy {
    static func authorize(
        kind: BillingDocumentDiscountKind,
        value: Double,
        grossSubtotal: Double,
        reason: String,
        actorEmail: String?,
        users: [AppUser],
        at date: Date = Date()
    ) throws -> AuthorizedDocumentDiscount {
        guard AppAccess.canAuthorizePriceAdjustments(email: actorEmail, users: users) else {
            throw BillingDocumentDiscountError.unauthorized
        }
        guard grossSubtotal.isFinite, grossSubtotal > 0 else {
            throw BillingDocumentDiscountError.invalidSubtotal
        }
        guard value.isFinite, value > 0 else {
            throw BillingDocumentDiscountError.invalidValue
        }
        switch kind {
        case .percentage:
            guard value <= 100 else { throw BillingDocumentDiscountError.invalidValue }
        case .fixedAmount:
            guard currencyCents(value).map({ $0 <= (currencyCents(grossSubtotal) ?? -1) }) == true else {
                throw BillingDocumentDiscountError.exceedsSubtotal
            }
        }
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedReason.isEmpty else { throw BillingDocumentDiscountError.missingReason }
        guard normalizedReason.count <= 240 else { throw BillingDocumentDiscountError.reasonTooLong }

        return AuthorizedDocumentDiscount(
            kind: kind,
            value: kind == .fixedAmount ? roundCurrency(value) : value,
            grossSubtotalAtAuthorization: roundCurrency(grossSubtotal),
            reason: normalizedReason,
            authorizedByEmail: AppAccess.normalizedEmail(actorEmail),
            authorizedAt: date
        )
    }

    static func validationMessage(
        for discount: AuthorizedDocumentDiscount?,
        grossSubtotal: Double
    ) -> String? {
        guard let discount else { return nil }
        return discount.amount(for: grossSubtotal) == nil
            ? BillingDocumentDiscountError.scopeChanged.localizedDescription
            : nil
    }

    static func netSubtotal(snapshotJSON: String?) -> Double? {
        let lines = CatalogLineItemSnapshot.decoded(from: snapshotJSON)
        guard !lines.isEmpty else { return nil }
        let grossSubtotal = lines.reduce(0) { $0 + ($1.unitPrice * $1.quantity) }
        guard grossSubtotal.isFinite, grossSubtotal >= 0 else { return nil }
        if let discount = CatalogLineItemSnapshot.documentDiscount(from: snapshotJSON) {
            guard let discountAmount = discount.amount(for: grossSubtotal) else { return nil }
            return max(roundCurrency(grossSubtotal - discountAmount), 0)
        }
        return roundCurrency(grossSubtotal)
    }

    static func grossSubtotal(snapshotJSON: String?) -> Double? {
        let lines = CatalogLineItemSnapshot.decoded(from: snapshotJSON)
        guard !lines.isEmpty else { return nil }
        let total = lines.reduce(0) { $0 + ($1.unitPrice * $1.quantity) }
        return total.isFinite && total >= 0 ? roundCurrency(total) : nil
    }

    static func roundCurrency(_ value: Double) -> Double {
        Double((value * 100).rounded()) / 100
    }

    static func currencyCents(_ value: Double) -> Int64? {
        guard value.isFinite,
              value >= 0,
              value <= Double(Int64.max) / 100 else { return nil }
        return Int64((value * 100).rounded())
    }
}

enum BillingDocumentDiscountAudit {
    static func quickBooksPrivateNote(existing: String?, snapshotJSON: String?) -> String? {
        var entries = [existing]
            .compactMap(normalized)
        if let discount = CatalogLineItemSnapshot.documentDiscount(from: snapshotJSON),
           let grossSubtotal = BillingDocumentDiscountPolicy.grossSubtotal(snapshotJSON: snapshotJSON),
           let amount = discount.amount(for: grossSubtotal) {
            entries.append(
                "Authorized document discount: \(discount.valueDisplayName) / \(amount.formatted(.currency(code: "USD"))); \(discount.reason); authorized by \(discount.authorizedByEmail) at \(ISO8601DateFormatter().string(from: discount.authorizedAt))"
            )
        }
        guard !entries.isEmpty else { return nil }
        return String(entries.joined(separator: "\n").prefix(4_000))
    }

    static func customerDocumentSummary(snapshotJSON: String?) -> String? {
        guard let discount = CatalogLineItemSnapshot.documentDiscount(from: snapshotJSON),
              let grossSubtotal = BillingDocumentDiscountPolicy.grossSubtotal(snapshotJSON: snapshotJSON),
              let amount = discount.amount(for: grossSubtotal) else { return nil }
        return "\(discount.valueDisplayName) — \(discount.reason) • −\(amount.formatted(.currency(code: "USD")))"
    }

    nonisolated private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

enum BillingPriceAdjustmentError: LocalizedError, Equatable {
    case unauthorized
    case invalidPrice
    case unchangedPrice
    case missingReason
    case reasonTooLong

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Only an administrator can authorize a line-price adjustment."
        case .invalidPrice:
            "Enter a valid unit price of zero or more."
        case .unchangedPrice:
            "The adjusted price must be different from the pricebook price."
        case .missingReason:
            "Enter the business reason for this price adjustment."
        case .reasonTooLong:
            "Keep the adjustment reason to 240 characters or fewer."
        }
    }
}

enum BillingPriceAdjustmentPolicy {
    static func authorize(
        item: Item,
        unitPrice: Double,
        reason: String,
        actorEmail: String?,
        users: [AppUser],
        at date: Date = Date()
    ) throws -> AuthorizedLinePriceAdjustment {
        guard AppAccess.canAuthorizePriceAdjustments(email: actorEmail, users: users) else {
            throw BillingPriceAdjustmentError.unauthorized
        }
        guard unitPrice.isFinite, unitPrice >= 0 else {
            throw BillingPriceAdjustmentError.invalidPrice
        }
        guard abs(unitPrice - item.unitPrice) >= 0.005 else {
            throw BillingPriceAdjustmentError.unchangedPrice
        }
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedReason.isEmpty else {
            throw BillingPriceAdjustmentError.missingReason
        }
        guard normalizedReason.count <= 240 else {
            throw BillingPriceAdjustmentError.reasonTooLong
        }
        return AuthorizedLinePriceAdjustment(
            pricebookUnitPrice: item.unitPrice,
            unitPrice: unitPrice,
            reason: normalizedReason,
            authorizedByEmail: AppAccess.normalizedEmail(actorEmail),
            authorizedAt: date
        )
    }
}

enum BillingPriceAdjustmentAudit {
    /// QuickBooks PrivateNote is internal accounting context. Keep the existing
    /// job note first, append traceable adjustment evidence, and stay within the
    /// provider's practical text limit.
    static func quickBooksPrivateNote(existing: String?, snapshotJSON: String?) -> String? {
        var entries: [String] = []
        if let existing = normalized(existing) {
            entries.append(existing)
        }
        let adjustmentEntries = CatalogLineItemSnapshot.decoded(from: snapshotJSON)
            .filter(\.hasAuthorizedPriceAdjustment)
            .compactMap { snapshot -> String? in
                guard let reason = normalized(snapshot.priceAdjustmentReason),
                      let actor = normalized(snapshot.priceAdjustmentAuthorizedByEmail),
                      let date = snapshot.priceAdjustmentAuthorizedAt else { return nil }
                return "\(snapshot.name): \(currency(snapshot.pricebookUnitPrice)) to \(currency(snapshot.unitPrice)); \(reason); authorized by \(actor) at \(ISO8601DateFormatter().string(from: date))"
            }
        if !adjustmentEntries.isEmpty {
            entries.append("Authorized line-price adjustments:\n" + adjustmentEntries.joined(separator: "\n"))
        }
        guard !entries.isEmpty else { return nil }
        return String(entries.joined(separator: "\n").prefix(4_000))
    }

    static func customerDocumentSummary(snapshotJSON: String?) -> String? {
        let summaries = CatalogLineItemSnapshot.decoded(from: snapshotJSON)
            .filter(\.hasAuthorizedPriceAdjustment)
            .compactMap { snapshot -> String? in
                guard let reason = normalized(snapshot.priceAdjustmentReason) else { return nil }
                let kind = snapshot.unitPrice < snapshot.pricebookUnitPrice ? "Discount" : "Price adjustment"
                return "\(kind) — \(snapshot.name): \(currency(snapshot.pricebookUnitPrice)) to \(currency(snapshot.unitPrice)) • \(reason)"
            }
        guard !summaries.isEmpty else { return nil }
        return summaries.joined(separator: "\n")
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "USD"))
    }
}

/// Immutable customer-system identity captured with a document line. This keeps
/// service history and QuickBooks descriptions understandable after the live
/// equipment profile is edited or deactivated.
struct CatalogLineEquipmentSnapshot: Codable, Equatable, Identifiable, Sendable {
    let equipmentID: UUID
    let name: String
    let equipmentType: String?
    let manufacturer: String?
    let modelNumber: String?
    let serialNumber: String?
    let location: String?

    var id: UUID { equipmentID }

    init(
        equipmentID: UUID,
        name: String,
        equipmentType: String? = nil,
        manufacturer: String? = nil,
        modelNumber: String? = nil,
        serialNumber: String? = nil,
        location: String? = nil
    ) {
        self.equipmentID = equipmentID
        self.name = name
        self.equipmentType = Self.normalized(equipmentType)
        self.manufacturer = Self.normalized(manufacturer)
        self.modelNumber = Self.normalized(modelNumber)
        self.serialNumber = Self.normalized(serialNumber)
        self.location = Self.normalized(location)
    }

    @MainActor
    init(equipment: CustomerEquipment) {
        self.init(
            equipmentID: equipment.id,
            name: equipment.name,
            equipmentType: equipment.equipmentType?.displayName,
            manufacturer: equipment.manufacturer,
            modelNumber: equipment.modelNumber,
            serialNumber: equipment.serialNumber,
            location: equipment.location
        )
    }

    var customerLabel: String {
        let identity = [manufacturer, modelNumber]
            .compactMap(Self.normalized)
            .joined(separator: " ")
        return identity.isEmpty ? name : "\(name) • \(identity)"
    }

    var quickBooksLabel: String {
        let details = [
            equipmentType,
            manufacturer,
            modelNumber,
            serialNumber.map { "Serial \($0)" },
            location.map { "Location \($0)" }
        ]
        .compactMap(Self.normalized)
        .joined(separator: " • ")
        return details.isEmpty ? name : "\(name) • \(details)"
    }

    nonisolated private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

/// Restricts line-to-system assignments to the selected catalog lines and the
/// active systems available for the current customer. Snapshot-only inputs make
/// this policy deterministic and independently testable.
enum CatalogLineEquipmentAssignmentPolicy {
    static func resolvedSnapshots(
        assignments: [UUID: UUID],
        selectedItemIDs: Set<UUID>,
        available: [CatalogLineEquipmentSnapshot]
    ) -> [UUID: CatalogLineEquipmentSnapshot] {
        let availableByID = Dictionary(
            available.map { ($0.equipmentID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return Dictionary(
            uniqueKeysWithValues: assignments.compactMap { itemID, equipmentID in
                guard selectedItemIDs.contains(itemID),
                      let equipment = availableByID[equipmentID] else { return nil }
                return (itemID, equipment)
            }
        )
    }

    static func restoredAssignments(
        from snapshots: [CatalogLineItemSnapshot],
        available: [CatalogLineEquipmentSnapshot]
    ) -> [UUID: UUID] {
        let availableIDs = Set(available.map(\.equipmentID))
        return Dictionary(
            uniqueKeysWithValues: snapshots.compactMap { snapshot in
                guard let equipmentID = snapshot.servicedEquipment?.equipmentID,
                      availableIDs.contains(equipmentID) else { return nil }
                return (snapshot.catalogItemID, equipmentID)
            }
        )
    }
}

/// Immutable pricebook context captured when a customer-facing document is created.
/// The live catalog remains editable; completed estimates and invoices retain the
/// price, cost, tax treatment, part identity, and serviced system that were approved.
struct CatalogLineItemSnapshot: Codable, Equatable, Identifiable {
    let catalogItemID: UUID
    let name: String
    let description: String?
    let sku: String?
    /// Pricebook price at document creation. Legacy snapshots decode this from
    /// `unitPrice`, which keeps old estimates and invoices valid.
    let pricebookUnitPrice: Double
    /// Actual customer document price after any authorized adjustment.
    let unitPrice: Double
    let purchaseCost: Double?
    let isTaxable: Bool
    let quantity: Double
    let catalogUpdatedAt: Date
    let priceAdjustmentReason: String?
    let priceAdjustmentAuthorizedByEmail: String?
    let priceAdjustmentAuthorizedAt: Date?
    let servicedEquipment: CatalogLineEquipmentSnapshot?
    let assembly: CatalogLineAssemblySnapshot?

    var id: UUID { catalogItemID }

    init(
        item: Item,
        quantity: Double = 1,
        priceAdjustment: AuthorizedLinePriceAdjustment? = nil,
        servicedEquipment: CatalogLineEquipmentSnapshot? = nil,
        assembly: CatalogLineAssemblySnapshot? = nil
    ) {
        catalogItemID = item.id
        name = item.name
        description = item.itemDescription
        sku = item.sku
        pricebookUnitPrice = priceAdjustment?.pricebookUnitPrice ?? item.unitPrice
        unitPrice = priceAdjustment?.unitPrice ?? item.unitPrice
        purchaseCost = assembly?.presentation == .flatRate
            ? (assembly?.unitPurchaseCost ?? item.purchaseCost)
            : item.purchaseCost
        isTaxable = item.isTaxable
        self.quantity = max(quantity, 0.0001)
        catalogUpdatedAt = item.timestamp
        priceAdjustmentReason = priceAdjustment?.reason
        priceAdjustmentAuthorizedByEmail = priceAdjustment?.authorizedByEmail
        priceAdjustmentAuthorizedAt = priceAdjustment?.authorizedAt
        self.servicedEquipment = servicedEquipment
        self.assembly = assembly
    }

    private init(
        catalogItemID: UUID,
        name: String,
        description: String?,
        sku: String?,
        pricebookUnitPrice: Double,
        unitPrice: Double,
        purchaseCost: Double?,
        isTaxable: Bool,
        quantity: Double,
        catalogUpdatedAt: Date,
        priceAdjustmentReason: String?,
        priceAdjustmentAuthorizedByEmail: String?,
        priceAdjustmentAuthorizedAt: Date?,
        servicedEquipment: CatalogLineEquipmentSnapshot?,
        assembly: CatalogLineAssemblySnapshot?
    ) {
        self.catalogItemID = catalogItemID
        self.name = name
        self.description = description
        self.sku = sku
        self.pricebookUnitPrice = pricebookUnitPrice
        self.unitPrice = unitPrice
        self.purchaseCost = purchaseCost
        self.isTaxable = isTaxable
        self.quantity = max(quantity, 0.0001)
        self.catalogUpdatedAt = catalogUpdatedAt
        self.priceAdjustmentReason = priceAdjustmentReason
        self.priceAdjustmentAuthorizedByEmail = priceAdjustmentAuthorizedByEmail
        self.priceAdjustmentAuthorizedAt = priceAdjustmentAuthorizedAt
        self.servicedEquipment = servicedEquipment
        self.assembly = assembly
    }

    var hasAuthorizedPriceAdjustment: Bool {
        abs(unitPrice - pricebookUnitPrice) >= 0.005 &&
        priceAdjustmentReason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
        priceAdjustmentAuthorizedByEmail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
        priceAdjustmentAuthorizedAt != nil
    }

    var authorizedPriceAdjustment: AuthorizedLinePriceAdjustment? {
        guard hasAuthorizedPriceAdjustment,
              let reason = priceAdjustmentReason,
              let authorizedByEmail = priceAdjustmentAuthorizedByEmail,
              let authorizedAt = priceAdjustmentAuthorizedAt else { return nil }
        return AuthorizedLinePriceAdjustment(
            pricebookUnitPrice: pricebookUnitPrice,
            unitPrice: unitPrice,
            reason: reason,
            authorizedByEmail: authorizedByEmail,
            authorizedAt: authorizedAt
        )
    }

    var quickBooksDescription: String {
        let base = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBase = base.flatMap { $0.isEmpty ? nil : $0 } ?? name
        var lines = [normalizedBase]
        if let assembly {
            lines.append(assembly.lineContext)
        }
        if let servicedEquipment {
            lines.append("Serviced system: \(servicedEquipment.quickBooksLabel)")
        }
        return lines.joined(separator: "\n")
    }

    @MainActor static func encoded(
        from items: [Item],
        quantities: [UUID: Double] = [:],
        priceAdjustments: [UUID: AuthorizedLinePriceAdjustment] = [:],
        servicedEquipment: [UUID: CatalogLineEquipmentSnapshot] = [:],
        assemblies: [UUID: CatalogLineAssemblySnapshot] = [:],
        documentDiscount: AuthorizedDocumentDiscount? = nil
    ) -> String? {
        let snapshots = items
            .map {
                CatalogLineItemSnapshot(
                    item: $0,
                    quantity: quantities[$0.id] ?? 1,
                    priceAdjustment: priceAdjustments[$0.id],
                    servicedEquipment: servicedEquipment[$0.id],
                    assembly: assemblies[$0.id]
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return encoded(snapshots: snapshots, documentDiscount: documentDiscount)
    }

    static func encoded(
        snapshots: [CatalogLineItemSnapshot],
        documentDiscount: AuthorizedDocumentDiscount? = nil
    ) -> String? {
        guard !snapshots.isEmpty else { return nil }
        let data: Data?
        if let documentDiscount {
            data = try? JSONEncoder().encode(
                CatalogDocumentSnapshotEnvelope(
                    version: 1,
                    lines: snapshots,
                    documentDiscount: documentDiscount
                )
            )
        } else {
            data = try? JSONEncoder().encode(snapshots)
        }
        guard let data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func replacingQuantity(with quantity: Double) -> CatalogLineItemSnapshot {
        CatalogLineItemSnapshot(
            catalogItemID: catalogItemID,
            name: name,
            description: description,
            sku: sku,
            pricebookUnitPrice: pricebookUnitPrice,
            unitPrice: unitPrice,
            purchaseCost: purchaseCost,
            isTaxable: isTaxable,
            quantity: quantity,
            catalogUpdatedAt: catalogUpdatedAt,
            priceAdjustmentReason: priceAdjustmentReason,
            priceAdjustmentAuthorizedByEmail: priceAdjustmentAuthorizedByEmail,
            priceAdjustmentAuthorizedAt: priceAdjustmentAuthorizedAt,
            servicedEquipment: servicedEquipment,
            assembly: assembly
        )
    }

    static func decoded(from json: String?) -> [CatalogLineItemSnapshot] {
        guard let json,
              let data = json.data(using: .utf8) else {
            return []
        }
        if let snapshots = try? JSONDecoder().decode([CatalogLineItemSnapshot].self, from: data) {
            return snapshots
        }
        return (try? JSONDecoder().decode(CatalogDocumentSnapshotEnvelope.self, from: data).lines) ?? []
    }

    static func documentDiscount(from json: String?) -> AuthorizedDocumentDiscount? {
        guard let json,
              let data = json.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(CatalogDocumentSnapshotEnvelope.self, from: data) else {
            return nil
        }
        return envelope.documentDiscount
    }

    private enum CodingKeys: String, CodingKey {
        case catalogItemID, name, description, sku, pricebookUnitPrice, unitPrice, purchaseCost, isTaxable, quantity, catalogUpdatedAt
        case priceAdjustmentReason, priceAdjustmentAuthorizedByEmail, priceAdjustmentAuthorizedAt
        case servicedEquipment, assembly
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        catalogItemID = try values.decode(UUID.self, forKey: .catalogItemID)
        name = try values.decode(String.self, forKey: .name)
        description = try values.decodeIfPresent(String.self, forKey: .description)
        sku = try values.decodeIfPresent(String.self, forKey: .sku)
        unitPrice = try values.decode(Double.self, forKey: .unitPrice)
        pricebookUnitPrice = try values.decodeIfPresent(Double.self, forKey: .pricebookUnitPrice) ?? unitPrice
        purchaseCost = try values.decodeIfPresent(Double.self, forKey: .purchaseCost)
        isTaxable = try values.decode(Bool.self, forKey: .isTaxable)
        quantity = max(try values.decodeIfPresent(Double.self, forKey: .quantity) ?? 1, 0.0001)
        catalogUpdatedAt = try values.decode(Date.self, forKey: .catalogUpdatedAt)
        priceAdjustmentReason = try values.decodeIfPresent(String.self, forKey: .priceAdjustmentReason)
        priceAdjustmentAuthorizedByEmail = try values.decodeIfPresent(String.self, forKey: .priceAdjustmentAuthorizedByEmail)
        priceAdjustmentAuthorizedAt = try values.decodeIfPresent(Date.self, forKey: .priceAdjustmentAuthorizedAt)
        servicedEquipment = try values.decodeIfPresent(CatalogLineEquipmentSnapshot.self, forKey: .servicedEquipment)
        assembly = try values.decodeIfPresent(CatalogLineAssemblySnapshot.self, forKey: .assembly)
    }
}

private struct CatalogDocumentSnapshotEnvelope: Codable {
    let version: Int
    let lines: [CatalogLineItemSnapshot]
    let documentDiscount: AuthorizedDocumentDiscount?
}

@Model
final class Item {
    var id: UUID = UUID()
    var quickBooksID: String?
    /// `pending`, `synced`, or `needs_attention`. This is intentionally stored
    /// with the pricebook item so an offline-created line can be retried after
    /// the originating invoice screen has been dismissed.
    var quickBooksSyncStatus: String = "pending"
    var quickBooksSyncDetail: String?
    var quickBooksLastSyncedAt: Date?
    /// Field-created items remain usable on their originating job, but cannot
    /// become global QBO products/services until an administrator reviews the
    /// price, tax treatment, purchasing identity, and description.
    var pricebookReviewStatusRawValue: String?
    var pricebookCreatedByEmail: String?
    var pricebookReviewedByEmail: String?
    var pricebookReviewedAt: Date?
    var name: String = ""
    var itemTypeRawValue: String = CatalogItemType.service.rawValue
    var unitPrice: Double = 0
    var purchaseCost: Double?
    var isTaxable: Bool = false
    var itemDescription: String?
    var sku: String?
    var preferredVendorName: String?
    var preferredVendorQuickBooksID: String?
    var vendorPartNumber: String?
    var purchaseURL: String?
    var purchaseDescription: String?
    var tracksInventory: Bool = false
    var reorderPoint: Double?
    var defaultInventoryLocation: String?
    /// Versioned component identities and quantities for a reusable service
    /// package. Optional JSON keeps legacy CloudKit records readable while the
    /// immutable document snapshot preserves every sold revision.
    var flatRateAssemblyJSON: String?
    var createdAt: Date = Date()
    var timestamp: Date = Date()

    init(
        id: UUID = UUID(),
        quickBooksID: String? = nil,
        quickBooksSyncStatus: String? = nil,
        quickBooksSyncDetail: String? = nil,
        quickBooksLastSyncedAt: Date? = nil,
        pricebookReviewStatus: PricebookReviewStatus = .approved,
        pricebookCreatedByEmail: String? = nil,
        pricebookReviewedByEmail: String? = nil,
        pricebookReviewedAt: Date? = nil,
        name: String,
        itemType: CatalogItemType = .service,
        unitPrice: Double,
        purchaseCost: Double? = nil,
        isTaxable: Bool = false,
        itemDescription: String? = nil,
        sku: String? = nil,
        preferredVendorName: String? = nil,
        preferredVendorQuickBooksID: String? = nil,
        vendorPartNumber: String? = nil,
        purchaseURL: String? = nil,
        purchaseDescription: String? = nil,
        tracksInventory: Bool = false,
        reorderPoint: Double? = nil,
        defaultInventoryLocation: String? = nil,
        flatRateAssemblyJSON: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.quickBooksID = quickBooksID
        self.quickBooksSyncStatus = quickBooksSyncStatus ?? (quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? "synced" : "pending")
        self.quickBooksSyncDetail = quickBooksSyncDetail
        self.quickBooksLastSyncedAt = quickBooksLastSyncedAt
        self.pricebookReviewStatusRawValue = pricebookReviewStatus.rawValue
        self.pricebookCreatedByEmail = Self.normalizedOptionalValue(pricebookCreatedByEmail)
        self.pricebookReviewedByEmail = Self.normalizedOptionalValue(pricebookReviewedByEmail)
        self.pricebookReviewedAt = pricebookReviewedAt
        self.name = name
        self.itemTypeRawValue = itemType.rawValue
        self.unitPrice = unitPrice
        self.purchaseCost = purchaseCost
        self.isTaxable = isTaxable
        self.itemDescription = itemDescription
        self.sku = sku
        self.preferredVendorName = preferredVendorName
        self.preferredVendorQuickBooksID = preferredVendorQuickBooksID
        self.vendorPartNumber = vendorPartNumber
        self.purchaseURL = purchaseURL
        self.purchaseDescription = purchaseDescription
        self.tracksInventory = tracksInventory
        self.reorderPoint = reorderPoint
        self.defaultInventoryLocation = defaultInventoryLocation
        self.flatRateAssemblyJSON = flatRateAssemblyJSON
        self.createdAt = createdAt
        self.timestamp = createdAt
    }

    var itemType: CatalogItemType {
        get { CatalogItemType(rawValue: itemTypeRawValue) ?? .service }
        set { itemTypeRawValue = newValue.rawValue }
    }

    var pricebookReviewStatus: PricebookReviewStatus {
        get {
            guard let pricebookReviewStatusRawValue else { return .approved }
            return PricebookReviewStatus(rawValue: pricebookReviewStatusRawValue) ?? .needsReview
        }
        set { pricebookReviewStatusRawValue = newValue.rawValue }
    }

    var requiresPricebookReview: Bool {
        pricebookReviewStatus == .needsReview
    }

    var assemblyDefinition: CatalogAssemblyDefinition? {
        get { CatalogAssemblyDefinition.decoded(from: flatRateAssemblyJSON) }
        set { flatRateAssemblyJSON = newValue?.encodedJSON }
    }

    var isServiceAssembly: Bool {
        assemblyDefinition != nil
    }

    func markForPricebookReview(createdByEmail: String?) {
        pricebookReviewStatus = .needsReview
        pricebookCreatedByEmail = Self.normalizedOptionalValue(createdByEmail)
        pricebookReviewedByEmail = nil
        pricebookReviewedAt = nil
        quickBooksSyncStatus = "needs_review"
        quickBooksSyncDetail = "Administrator pricebook review is required before QuickBooks publication."
    }

    func approveForPricebook(by reviewerEmail: String?, at date: Date = Date()) {
        pricebookReviewStatus = .approved
        pricebookReviewedByEmail = Self.normalizedOptionalValue(reviewerEmail)
        pricebookReviewedAt = date
        if quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            quickBooksSyncStatus = "pending"
            quickBooksSyncDetail = "Pricebook review approved; QuickBooks publication is pending."
        }
    }

    var hasPendingQuickBooksCatalogUpdate: Bool {
        quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
        (quickBooksSyncStatus == "pending_update" || quickBooksSyncStatus == "needs_attention")
    }

    func stageQuickBooksCatalogUpdate(at date: Date = Date()) {
        guard quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            quickBooksSyncStatus = "pending"
            quickBooksSyncDetail = "QuickBooks catalog publication is pending."
            timestamp = date
            return
        }
        quickBooksSyncStatus = "pending_update"
        quickBooksSyncDetail = "Administrator-approved catalog changes are waiting for explicit QuickBooks publication."
        timestamp = date
    }

    var needsQuickBooksAttention: Bool {
        quickBooksSyncStatus == "needs_attention"
    }

    var quickBooksCatalogSyncState: String {
        if quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return "synced"
        }
        return quickBooksSyncStatus
    }

    /// Finds the one local catalog record that can safely be reconciled with a
    /// QuickBooks import. A QuickBooks ID is authoritative. Before an item has
    /// one, a unique normalized name is acceptable only when two populated SKUs
    /// agree; this keeps similarly named vendor parts from being merged silently.
    static func matchingLocalCatalogItem(
        in items: [Item],
        quickBooksID: String,
        name: String,
        sku: String?
    ) -> Item? {
        let normalizedQuickBooksID = normalizedCatalogValue(quickBooksID)
        guard !normalizedQuickBooksID.isEmpty else { return nil }

        let identifiedItems = items.filter {
            normalizedCatalogValue($0.quickBooksID ?? "") == normalizedQuickBooksID
        }
        if !identifiedItems.isEmpty {
            return identifiedItems.count == 1 ? identifiedItems[0] : nil
        }

        let normalizedName = normalizedCatalogValue(name)
        guard !normalizedName.isEmpty else { return nil }
        let candidates = items.filter {
            normalizedCatalogValue($0.quickBooksID ?? "").isEmpty &&
            normalizedCatalogValue($0.name) == normalizedName &&
            normalizedCatalogValuesAreCompatible($0.sku, sku)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func normalizedCatalogValuesAreCompatible(_ lhs: String?, _ rhs: String?) -> Bool {
        let left = normalizedCatalogValue(lhs ?? "")
        let right = normalizedCatalogValue(rhs ?? "")
        return left.isEmpty || right.isEmpty || left == right
    }

    private static func normalizedCatalogValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedOptionalValue(_ value: String?) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else { return nil }
        return normalized
    }
}

enum CatalogAssemblyValidationError: LocalizedError, Equatable {
    case serviceItemRequired
    case missingDefinition
    case invalidRevision
    case emptyComponents
    case tooManyComponents(maximum: Int)
    case invalidQuantity(itemID: UUID)
    case duplicateComponent(itemID: UUID)
    case selfReference
    case missingComponent(itemID: UUID)
    case nestedAssembly(name: String)

    var errorDescription: String? {
        switch self {
        case .serviceItemRequired:
            "Only service items can be configured as reusable packages."
        case .missingDefinition:
            "This service does not contain a valid package definition."
        case .invalidRevision:
            "The package revision must be one or greater."
        case .emptyComponents:
            "Add at least one labor, material, or equipment item to this package."
        case .tooManyComponents(let maximum):
            "Keep a service package to \(maximum) included items or fewer."
        case .invalidQuantity:
            "Every package item must have a quantity greater than zero and no more than 1,000."
        case .duplicateComponent:
            "Each pricebook item can appear only once in a service package."
        case .selfReference:
            "A service package cannot include itself."
        case .missingComponent:
            "An included pricebook item is no longer available. Remove it before saving this package."
        case .nestedAssembly(let name):
            "\(name) is already a service package. Packages cannot contain other packages."
        }
    }
}

@MainActor
struct ResolvedCatalogAssemblyComponent {
    let item: Item
    let quantity: Double
}

@MainActor
struct ResolvedCatalogAssembly {
    let definition: CatalogAssemblyDefinition
    let components: [ResolvedCatalogAssemblyComponent]
    let snapshot: CatalogLineAssemblySnapshot
}

@MainActor
struct CatalogAssemblySelection {
    let lineItems: [Item]
    let quantities: [UUID: Double]
    let assemblySnapshots: [UUID: CatalogLineAssemblySnapshot]
    let itemizedAssemblyMemberships: [UUID: Set<UUID>]
}

/// Resolves an administrator-authored package into a safe field selection and
/// an immutable document snapshot. Flat-rate packages remain one public line;
/// itemized packages expand only into their approved component lines.
@MainActor
enum CatalogAssemblyPolicy {
    static let maximumComponentCount = 50
    static let maximumComponentQuantity = 1_000.0

    static func resolve(root: Item, catalogItems: [Item]) throws -> ResolvedCatalogAssembly {
        guard let definition = root.assemblyDefinition else {
            throw CatalogAssemblyValidationError.missingDefinition
        }
        return try resolve(root: root, definition: definition, catalogItems: catalogItems)
    }

    static func resolve(
        root: Item,
        definition: CatalogAssemblyDefinition,
        catalogItems: [Item],
        rootItemType: CatalogItemType? = nil
    ) throws -> ResolvedCatalogAssembly {
        guard (rootItemType ?? root.itemType) == .service else {
            throw CatalogAssemblyValidationError.serviceItemRequired
        }
        guard definition.revision >= 1 else {
            throw CatalogAssemblyValidationError.invalidRevision
        }
        guard !definition.components.isEmpty else {
            throw CatalogAssemblyValidationError.emptyComponents
        }
        guard definition.components.count <= maximumComponentCount else {
            throw CatalogAssemblyValidationError.tooManyComponents(maximum: maximumComponentCount)
        }

        let catalogByID = Dictionary(
            catalogItems.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seenItemIDs = Set<UUID>()
        var resolvedComponents: [ResolvedCatalogAssemblyComponent] = []
        var componentSnapshots: [CatalogAssemblyComponentSnapshot] = []

        for component in definition.components {
            guard component.quantity.isFinite,
                  component.quantity > 0,
                  component.quantity <= maximumComponentQuantity else {
                throw CatalogAssemblyValidationError.invalidQuantity(itemID: component.itemID)
            }
            guard seenItemIDs.insert(component.itemID).inserted else {
                throw CatalogAssemblyValidationError.duplicateComponent(itemID: component.itemID)
            }
            guard component.itemID != root.id else {
                throw CatalogAssemblyValidationError.selfReference
            }
            guard let item = catalogByID[component.itemID] else {
                throw CatalogAssemblyValidationError.missingComponent(itemID: component.itemID)
            }
            guard item.assemblyDefinition == nil else {
                throw CatalogAssemblyValidationError.nestedAssembly(name: item.name)
            }

            resolvedComponents.append(
                ResolvedCatalogAssemblyComponent(item: item, quantity: component.quantity)
            )
            componentSnapshots.append(
                CatalogAssemblyComponentSnapshot(
                    itemID: item.id,
                    name: item.name,
                    sku: normalized(item.sku),
                    quantity: component.quantity,
                    purchaseCost: item.purchaseCost,
                    tracksInventory: item.tracksInventory
                )
            )
        }

        return ResolvedCatalogAssembly(
            definition: definition,
            components: resolvedComponents,
            snapshot: CatalogLineAssemblySnapshot(
                assemblyItemID: root.id,
                name: root.name,
                revision: definition.revision,
                presentation: definition.presentation,
                components: componentSnapshots
            )
        )
    }

    static func selection(root: Item, catalogItems: [Item]) throws -> CatalogAssemblySelection {
        guard root.assemblyDefinition != nil else {
            return CatalogAssemblySelection(
                lineItems: [root],
                quantities: [root.id: 1],
                assemblySnapshots: [:],
                itemizedAssemblyMemberships: [:]
            )
        }

        let resolved = try resolve(root: root, catalogItems: catalogItems)
        switch resolved.definition.presentation {
        case .flatRate:
            return CatalogAssemblySelection(
                lineItems: [root],
                quantities: [root.id: 1],
                assemblySnapshots: [root.id: resolved.snapshot],
                itemizedAssemblyMemberships: [:]
            )
        case .itemized:
            let componentIDs = Set(resolved.components.map { $0.item.id })
            return CatalogAssemblySelection(
                lineItems: resolved.components.map(\.item),
                quantities: Dictionary(
                    uniqueKeysWithValues: resolved.components.map { ($0.item.id, $0.quantity) }
                ),
                assemblySnapshots: Dictionary(
                    uniqueKeysWithValues: resolved.components.map { ($0.item.id, resolved.snapshot) }
                ),
                itemizedAssemblyMemberships: [root.id: componentIDs]
            )
        }
    }

    static func restoredItemizedMemberships(
        from snapshots: [CatalogLineItemSnapshot]
    ) -> [UUID: Set<UUID>] {
        var memberships: [UUID: Set<UUID>] = [:]
        for snapshot in snapshots {
            guard let assembly = snapshot.assembly,
                  assembly.presentation == .itemized else { continue }
            memberships[assembly.assemblyItemID, default: []].insert(snapshot.catalogItemID)
        }
        return memberships
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

struct QuickBooksCatalogMappingConflict: Identifiable {
    let quickBooksID: String
    let localItems: [Item]

    var id: String { QuickBooksCatalogMappingIntegrity.normalizedIdentifier(quickBooksID) }
}

enum QuickBooksCatalogMappingIntegrityError: LocalizedError, Equatable {
    case ambiguousIdentifier(quickBooksID: String, localItemNames: [String])
    case identifierAlreadyAssigned(quickBooksID: String, localItemName: String)
    case invalidResolution

    var errorDescription: String? {
        switch self {
        case .ambiguousIdentifier(let quickBooksID, let localItemNames):
            let names = localItemNames.joined(separator: ", ")
            return "QuickBooks item \(quickBooksID) is linked to more than one GunnAire catalog record (\(names)). Choose the one authoritative mapping before syncing invoices or catalog changes."
        case .identifierAlreadyAssigned(let quickBooksID, let localItemName):
            return "QuickBooks item \(quickBooksID) is already linked to \(localItemName). Resolve that mapping before linking another GunnAire item."
        case .invalidResolution:
            return "The selected catalog item is no longer part of this duplicate QuickBooks mapping. Refresh and choose again."
        }
    }
}

/// Enforces a one-to-one boundary between reusable GunnAire pricebook records
/// and QuickBooks Item identities. Completed estimates and invoices retain
/// their own line snapshots; resolving a conflict changes only future catalog
/// selection and publication behavior.
@MainActor
enum QuickBooksCatalogMappingIntegrity {
    nonisolated static func normalizedIdentifier(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func linkedItems(to quickBooksID: String, in items: [Item]) -> [Item] {
        let normalizedID = normalizedIdentifier(quickBooksID)
        guard !normalizedID.isEmpty else { return [] }
        return items
            .filter { normalizedIdentifier($0.quickBooksID ?? "") == normalizedID }
            .sorted(by: stableItemOrder)
    }

    static func conflicts(in items: [Item]) -> [QuickBooksCatalogMappingConflict] {
        let linkedItems = items.filter {
            !normalizedIdentifier($0.quickBooksID ?? "").isEmpty
        }
        return Dictionary(grouping: linkedItems) {
            normalizedIdentifier($0.quickBooksID ?? "")
        }
        .compactMap { normalizedID, groupedItems in
            guard groupedItems.count > 1 else { return nil }
            return QuickBooksCatalogMappingConflict(
                quickBooksID: groupedItems[0].quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? normalizedID,
                localItems: groupedItems.sorted(by: stableItemOrder)
            )
        }
        .sorted { $0.quickBooksID.localizedCaseInsensitiveCompare($1.quickBooksID) == .orderedAscending }
    }

    static func conflict(containing item: Item, in items: [Item]) -> QuickBooksCatalogMappingConflict? {
        guard let quickBooksID = item.quickBooksID else { return nil }
        let matches = linkedItems(to: quickBooksID, in: items)
        guard matches.count > 1 else { return nil }
        return QuickBooksCatalogMappingConflict(
            quickBooksID: quickBooksID.trimmingCharacters(in: .whitespacesAndNewlines),
            localItems: matches
        )
    }

    static func validateDocumentItems(_ documentItems: [Item], against catalogItems: [Item]) throws {
        for item in documentItems {
            guard let conflict = conflict(containing: item, in: catalogItems) else { continue }
            throw QuickBooksCatalogMappingIntegrityError.ambiguousIdentifier(
                quickBooksID: conflict.quickBooksID,
                localItemNames: conflict.localItems.map(\.name)
            )
        }
    }

    static func validateAssignment(
        of quickBooksID: String,
        to item: Item,
        in catalogItems: [Item]
    ) throws {
        if let owner = linkedItems(to: quickBooksID, in: catalogItems).first(where: { $0.id != item.id }) {
            throw QuickBooksCatalogMappingIntegrityError.identifierAlreadyAssigned(
                quickBooksID: quickBooksID.trimmingCharacters(in: .whitespacesAndNewlines),
                localItemName: owner.name
            )
        }
    }

    static func markConflictsForReview(in items: [Item], at date: Date = Date()) {
        for conflict in conflicts(in: items) {
            let names = conflict.localItems.map(\.name).joined(separator: ", ")
            for item in conflict.localItems {
                item.quickBooksSyncStatus = "needs_attention"
                item.quickBooksSyncDetail = "Duplicate QuickBooks mapping \(conflict.quickBooksID) is shared by \(names). Choose one authoritative GunnAire item before syncing."
                item.timestamp = date
            }
        }
    }

    @discardableResult
    static func resolve(
        _ conflict: QuickBooksCatalogMappingConflict,
        keeping canonicalItem: Item,
        at date: Date = Date()
    ) throws -> [Item] {
        guard conflict.localItems.contains(where: { $0.id == canonicalItem.id }),
              normalizedIdentifier(canonicalItem.quickBooksID ?? "") == normalizedIdentifier(conflict.quickBooksID),
              conflict.localItems.count > 1 else {
            throw QuickBooksCatalogMappingIntegrityError.invalidResolution
        }

        let unlinkedItems = conflict.localItems.filter { $0.id != canonicalItem.id }
        canonicalItem.quickBooksSyncStatus = "pending_update"
        canonicalItem.quickBooksSyncDetail = "Kept as the sole GunnAire mapping for QuickBooks item \(conflict.quickBooksID). Review the live comparison before publishing catalog changes."
        canonicalItem.timestamp = date

        for item in unlinkedItems {
            item.quickBooksID = nil
            item.quickBooksSyncStatus = "pending"
            item.quickBooksSyncDetail = "Removed duplicate link to QuickBooks item \(conflict.quickBooksID). This local item remains available and requires review before publication as a separate QuickBooks item."
            item.quickBooksLastSyncedAt = nil
            item.timestamp = date
        }
        return unlinkedItems
    }

    private static func stableItemOrder(_ lhs: Item, _ rhs: Item) -> Bool {
        let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
