import Foundation
import SwiftData

/// A durable stock ledger record. Quantity is always positive except for an
/// adjustment, where a signed quantity documents the reconciled difference.
enum InventoryMovementType: String, Codable, CaseIterable, Identifiable {
    case receive
    case transfer
    case reserve
    case release
    case consume
    case returnToStock
    case returnToVendor
    case adjust

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .receive: "Receive"
        case .transfer: "Transfer"
        case .reserve: "Reserve for job"
        case .release: "Release reservation"
        case .consume: "Consume on job"
        case .returnToStock: "Return to stock"
        case .returnToVendor: "Return to vendor"
        case .adjust: "Reconcile adjustment"
        }
    }

    /// Vendor returns must be created from a purchase order so the RMA,
    /// serialized assets, actor, inventory reversal, and eventual credit remain
    /// one auditable transaction. They are intentionally absent from the
    /// free-form stock-movement picker.
    static var manualEntryCases: [InventoryMovementType] {
        allCases.filter { $0 != .returnToVendor }
    }

    var requiresSourceLocation: Bool {
        switch self {
        case .transfer, .reserve, .release, .consume, .returnToVendor: true
        case .receive, .returnToStock, .adjust: false
        }
    }

    var requiresDestinationLocation: Bool {
        switch self {
        case .receive, .transfer, .returnToStock, .adjust: true
        case .reserve, .release, .consume, .returnToVendor: false
        }
    }

    var requiresJobLink: Bool {
        switch self {
        case .reserve, .release, .consume: true
        case .receive, .transfer, .returnToStock, .returnToVendor, .adjust: false
        }
    }
}

@Model
final class InventoryMovement {
    var id: UUID = UUID()
    var itemID: UUID = UUID()
    var itemName: String = ""
    var itemSKU: String?
    var movementTypeRaw: String = InventoryMovementType.adjust.rawValue
    var quantity: Double = 0
    var sourceLocation: String?
    var destinationLocation: String?
    var serviceCallID: UUID?
    var notes: String?
    var createdByEmail: String?
    var createdAt: Date = Date()

    init(
        id: UUID = UUID(),
        item: Item,
        type: InventoryMovementType,
        quantity: Double,
        sourceLocation: String? = nil,
        destinationLocation: String? = nil,
        serviceCallID: UUID? = nil,
        notes: String? = nil,
        createdByEmail: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.itemID = item.id
        self.itemName = item.name
        self.itemSKU = item.sku
        self.movementTypeRaw = type.rawValue
        self.quantity = quantity
        self.sourceLocation = sourceLocation
        self.destinationLocation = destinationLocation
        self.serviceCallID = serviceCallID
        self.notes = notes
        self.createdByEmail = createdByEmail
        self.createdAt = createdAt
    }

    var type: InventoryMovementType {
        InventoryMovementType(rawValue: movementTypeRaw) ?? .adjust
    }
}

struct InventoryCycleCountSnapshot: Codable, Equatable {
    static let notesPrefix = "[GunnAireInventoryCount:v1]"

    let location: String
    let expectedQuantity: Double
    let countedQuantity: Double
    let reason: String

    var varianceQuantity: Double {
        countedQuantity - expectedQuantity
    }

    var summary: String {
        "Ledger \(expectedQuantity.formatted(.number.precision(.fractionLength(0...3)))) • Counted \(countedQuantity.formatted(.number.precision(.fractionLength(0...3)))) • Variance \(varianceQuantity.formatted(.number.precision(.fractionLength(0...3)).sign(strategy: .always())))"
    }

    var encodedNotes: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else {
            return Self.notesPrefix
        }
        return Self.notesPrefix + data.base64EncodedString()
    }

    static func decode(from notes: String?) -> InventoryCycleCountSnapshot? {
        guard let notes, notes.hasPrefix(notesPrefix) else { return nil }
        let encoded = String(notes.dropFirst(notesPrefix.count))
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONDecoder().decode(InventoryCycleCountSnapshot.self, from: data)
    }
}

enum InventoryCycleCountError: Error, Equatable, LocalizedError {
    case administratorRequired
    case actorRequired
    case locationRequired
    case locationTooLong
    case invalidCount
    case varianceReasonRequired
    case reasonTooLong

    var errorDescription: String? {
        switch self {
        case .administratorRequired:
            "Only an administrator can reconcile an inventory count."
        case .actorRequired:
            "Sign in with an approved business account before reconciling inventory."
        case .locationRequired:
            "Enter the truck, warehouse, or other stock location that was counted."
        case .locationTooLong:
            "Keep the inventory location to 100 characters or fewer."
        case .invalidCount:
            "Enter a counted quantity from 0 through 1,000,000."
        case .varianceReasonRequired:
            "Explain a non-zero inventory variance before changing the ledger."
        case .reasonTooLong:
            "Keep the count note or variance reason to 240 characters or fewer."
        }
    }
}

enum InventoryCycleCountPolicy {
    static func adjustment(
        for item: Item,
        location: String,
        countedQuantity: Double,
        reason: String,
        movements: [InventoryMovement],
        actorEmail: String?,
        isAdministrator: Bool,
        createdAt: Date = Date()
    ) throws -> InventoryMovement {
        guard isAdministrator else {
            throw InventoryCycleCountError.administratorRequired
        }
        guard let actorEmail = normalized(actorEmail), !actorEmail.isEmpty else {
            throw InventoryCycleCountError.actorRequired
        }
        guard let location = normalized(location), !location.isEmpty else {
            throw InventoryCycleCountError.locationRequired
        }
        guard location.count <= 100 else {
            throw InventoryCycleCountError.locationTooLong
        }
        guard countedQuantity.isFinite,
              countedQuantity >= 0,
              countedQuantity <= 1_000_000 else {
            throw InventoryCycleCountError.invalidCount
        }

        let expectedQuantity = InventoryLedger.onHandQuantity(
            for: item.id,
            at: location,
            movements: movements
        )
        let variance = countedQuantity - expectedQuantity
        let normalizedReason = normalized(reason) ?? ""
        guard normalizedReason.count <= 240 else {
            throw InventoryCycleCountError.reasonTooLong
        }
        guard abs(variance) <= 0.0001 || !normalizedReason.isEmpty else {
            throw InventoryCycleCountError.varianceReasonRequired
        }

        let snapshot = InventoryCycleCountSnapshot(
            location: location,
            expectedQuantity: expectedQuantity,
            countedQuantity: countedQuantity,
            reason: normalizedReason.isEmpty ? "Count verified with no variance." : normalizedReason
        )
        return InventoryMovement(
            item: item,
            type: .adjust,
            quantity: variance,
            destinationLocation: location,
            notes: snapshot.encodedNotes,
            createdByEmail: actorEmail,
            createdAt: createdAt
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }
}

/// Job-facing material progress derived from the immutable invoice requirement
/// and the durable stock ledger. Customer billing and physical stock remain
/// separate records, but this summary makes any gap between them visible.
struct InventoryJobMaterialStatus: Equatable {
    let requiredQuantity: Double
    let openReservedQuantity: Double
    let consumedQuantity: Double
    let returnedQuantity: Double

    var netUsedQuantity: Double {
        max(consumedQuantity - returnedQuantity, 0)
    }

    var remainingToRecord: Double {
        max(requiredQuantity - netUsedQuantity, 0)
    }

    var overRecordedQuantity: Double {
        max(netUsedQuantity - requiredQuantity, 0)
    }

    var isComplete: Bool {
        remainingToRecord <= 0.0001 &&
            overRecordedQuantity <= 0.0001 &&
            openReservedQuantity <= 0.0001
    }
}

struct JobMaterialRequirement: Identifiable {
    let item: Item
    let quantity: Double

    var id: UUID { item.id }
}

nonisolated struct JobMaterialCloseoutSummary: Equatable, Sendable {
    let totalRequirementCount: Int
    let unresolvedRequirementCount: Int

    static let notApplicable = JobMaterialCloseoutSummary(
        totalRequirementCount: 0,
        unresolvedRequirementCount: 0
    )

    var completedRequirementCount: Int {
        max(totalRequirementCount - unresolvedRequirementCount, 0)
    }

    var isApplicable: Bool { totalRequirementCount > 0 }
    var isReady: Bool { unresolvedRequirementCount == 0 }

    var statusLabel: String {
        guard isApplicable else { return "No tracked job materials" }
        return isReady
            ? "Material ledger complete"
            : "\(unresolvedRequirementCount) material record\(unresolvedRequirementCount == 1 ? "" : "s") need review"
    }
}

/// Creates one shared closeout view of immutable sold material requirements and
/// the durable job stock ledger. Office, Schedule, field, and report surfaces
/// must not independently guess whether a reserved/consumed part is complete.
enum JobMaterialCloseoutPolicy {
    static func requirements(
        for serviceCall: ServiceCall,
        invoice: Invoice?,
        estimates: [Estimate],
        projectMilestones: [ProjectMilestone],
        items: [Item],
        movements: [InventoryMovement]
    ) -> [JobMaterialRequirement] {
        guard serviceCall.type != .estimate else { return [] }
        let source = documentSource(
            for: serviceCall,
            invoice: invoice,
            estimates: estimates,
            projectMilestones: projectMilestones
        )
        var snapshots = source.snapshots
        let snapshotIDs = Set(snapshots.map(\.catalogItemID))
        let normalizedSummary = source.legacySummary.lowercased()
        let legacyTrackedItems = items.filter {
            itemHasInventoryLedger($0, movements: movements) &&
                !snapshotIDs.contains($0.id) &&
                normalizedSummary.contains($0.name.lowercased())
        }
        snapshots.append(contentsOf: legacyTrackedItems.map {
            CatalogLineItemSnapshot(item: $0)
        })

        var quantitiesByItemID: [UUID: Double] = [:]
        for snapshot in snapshots {
            if let assembly = snapshot.assembly,
               assembly.presentation == .flatRate,
               snapshot.catalogItemID == assembly.assemblyItemID {
                for component in assembly.components {
                    let localItemTracksStock = items
                        .first(where: { $0.id == component.itemID })
                        .map { itemHasInventoryLedger($0, movements: movements) } == true
                    guard component.tracksInventory || localItemTracksStock else { continue }
                    quantitiesByItemID[component.itemID, default: 0] += component.quantity * snapshot.quantity
                }
            } else if let item = items.first(where: { $0.id == snapshot.catalogItemID }),
                      itemHasInventoryLedger(item, movements: movements) {
                quantitiesByItemID[item.id, default: 0] += snapshot.quantity
            }
        }

        // A reservation or consumption without a matching sold line is still
        // operational evidence that must be released, returned, or billed.
        for movement in movements where movement.serviceCallID == serviceCall.id {
            quantitiesByItemID[movement.itemID, default: 0] += 0
        }

        return quantitiesByItemID.compactMap { itemID, quantity in
            guard let item = items.first(where: { $0.id == itemID }) else { return nil }
            return JobMaterialRequirement(item: item, quantity: quantity)
        }
        .sorted { $0.item.name.localizedCaseInsensitiveCompare($1.item.name) == .orderedAscending }
    }

    static func summary(
        for serviceCall: ServiceCall,
        invoice: Invoice?,
        estimates: [Estimate],
        projectMilestones: [ProjectMilestone],
        items: [Item],
        movements: [InventoryMovement]
    ) -> JobMaterialCloseoutSummary {
        let requirements = requirements(
            for: serviceCall,
            invoice: invoice,
            estimates: estimates,
            projectMilestones: projectMilestones,
            items: items,
            movements: movements
        )
        let unresolvedCount = requirements.filter { requirement in
            !InventoryLedger.jobMaterialStatus(
                for: requirement.item.id,
                serviceCallID: serviceCall.id,
                requiredQuantity: requirement.quantity,
                movements: movements
            ).isComplete
        }.count
        return JobMaterialCloseoutSummary(
            totalRequirementCount: requirements.count,
            unresolvedRequirementCount: unresolvedCount
        )
    }

    private static func documentSource(
        for serviceCall: ServiceCall,
        invoice: Invoice?,
        estimates: [Estimate],
        projectMilestones: [ProjectMilestone]
    ) -> (snapshots: [CatalogLineItemSnapshot], legacySummary: String) {
        let matchingMilestones = projectMilestones
            .filter { $0.projectServiceCallID == serviceCall.id }
            .sorted { $0.sequence < $1.sequence }
        if let estimateID = matchingMilestones.first?.estimateID ?? serviceCall.linkedEstimateID,
           !matchingMilestones.isEmpty,
           let projectEstimate = estimates.first(where: { $0.id == estimateID }) {
            return (projectEstimate.catalogLineSnapshots, projectEstimate.lineItemSummary)
        }
        if let invoice {
            return (invoice.catalogLineSnapshots, invoice.lineItemSummary)
        }
        if let estimateID = serviceCall.linkedEstimateID,
           let estimate = estimates.first(where: { $0.id == estimateID }) {
            return (estimate.catalogLineSnapshots, estimate.lineItemSummary)
        }
        return ([], "")
    }

    private static func itemHasInventoryLedger(
        _ item: Item,
        movements: [InventoryMovement]
    ) -> Bool {
        item.itemType == .nonInventory ||
            item.tracksInventory ||
            movements.contains { $0.itemID == item.id }
    }
}

enum InventoryLedger {
    static func onHandQuantity(
        for itemID: UUID,
        at location: String? = nil,
        movements: [InventoryMovement]
    ) -> Double {
        movements
            .filter { $0.itemID == itemID }
            .reduce(0) { partial, movement in
                partial + onHandDelta(for: movement, at: location)
            }
    }

    static func reservedQuantity(
        for itemID: UUID,
        at location: String? = nil,
        movements: [InventoryMovement]
    ) -> Double {
        var openByJobAndLocation: [InventoryReservationKey: Double] = [:]
        for movement in movements where movement.itemID == itemID && matches(movement.sourceLocation, location) {
            let key = InventoryReservationKey(
                serviceCallID: movement.serviceCallID,
                location: normalizedLocation(movement.sourceLocation)
            )
            switch movement.type {
            case .reserve:
                openByJobAndLocation[key, default: 0] += movement.quantity
            case .release, .consume:
                openByJobAndLocation[key, default: 0] -= movement.quantity
            case .receive, .transfer, .returnToStock, .returnToVendor, .adjust:
                break
            }
        }
        return openByJobAndLocation.values.reduce(0) { $0 + max($1, 0) }
    }

    static func availableQuantity(for itemID: UUID, at location: String? = nil, movements: [InventoryMovement]) -> Double {
        onHandQuantity(for: itemID, at: location, movements: movements) -
            reservedQuantity(for: itemID, at: location, movements: movements)
    }

    static func locations(for itemID: UUID, movements: [InventoryMovement]) -> [String] {
        Set(movements
            .filter { $0.itemID == itemID }
            .flatMap { [$0.sourceLocation, $0.destinationLocation] }
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func jobMaterialStatus(
        for itemID: UUID,
        serviceCallID: UUID,
        requiredQuantity: Double,
        at location: String? = nil,
        movements: [InventoryMovement]
    ) -> InventoryJobMaterialStatus {
        let matchingMovements = movements.filter {
            $0.itemID == itemID && $0.serviceCallID == serviceCallID
        }
        let reserved = reservedQuantity(
            for: itemID,
            serviceCallID: serviceCallID,
            at: location,
            movements: matchingMovements
        )
        let consumed = matchingMovements.reduce(0) { partial, movement in
            guard movement.type == .consume, matches(movement.sourceLocation, location) else { return partial }
            return partial + movement.quantity
        }
        let returned = matchingMovements.reduce(0) { partial, movement in
            guard movement.type == .returnToStock, matches(movement.destinationLocation, location) else { return partial }
            return partial + movement.quantity
        }
        return InventoryJobMaterialStatus(
            requiredQuantity: max(requiredQuantity, 0),
            openReservedQuantity: reserved,
            consumedQuantity: consumed,
            returnedQuantity: returned
        )
    }

    private static func onHandDelta(for movement: InventoryMovement, at location: String?) -> Double {
        switch movement.type {
        case .receive, .returnToStock:
            return matches(movement.destinationLocation, location) ? movement.quantity : 0
        case .transfer:
            var delta = 0.0
            if matches(movement.sourceLocation, location) { delta -= movement.quantity }
            if matches(movement.destinationLocation, location) { delta += movement.quantity }
            return delta
        case .consume, .returnToVendor:
            return matches(movement.sourceLocation, location) ? -movement.quantity : 0
        case .adjust:
            return matches(movement.destinationLocation, location) ? movement.quantity : 0
        case .reserve, .release:
            return 0
        }
    }

    private static func matches(_ movementLocation: String?, _ requestedLocation: String?) -> Bool {
        guard let requestedLocation else { return true }
        guard let movementLocation else { return false }
        return movementLocation.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(requestedLocation.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    private static func reservedQuantity(
        for itemID: UUID,
        serviceCallID: UUID,
        at location: String?,
        movements: [InventoryMovement]
    ) -> Double {
        movements.reduce(0) { partial, movement in
            guard movement.itemID == itemID,
                  movement.serviceCallID == serviceCallID,
                  matches(movement.sourceLocation, location) else { return partial }
            switch movement.type {
            case .reserve:
                return partial + movement.quantity
            case .release, .consume:
                return partial - movement.quantity
            case .receive, .transfer, .returnToStock, .returnToVendor, .adjust:
                return partial
            }
        }
        .clampedToNonnegative
    }

    private static func normalizedLocation(_ location: String?) -> String {
        location?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }
}

private struct InventoryReservationKey: Hashable {
    let serviceCallID: UUID?
    let location: String
}

private extension Double {
    var clampedToNonnegative: Double { max(self, 0) }
}
