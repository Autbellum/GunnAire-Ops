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
        case .adjust: "Reconcile adjustment"
        }
    }

    var requiresSourceLocation: Bool {
        switch self {
        case .transfer, .reserve, .release, .consume: true
        case .receive, .returnToStock, .adjust: false
        }
    }

    var requiresDestinationLocation: Bool {
        switch self {
        case .receive, .transfer, .returnToStock, .adjust: true
        case .reserve, .release, .consume: false
        }
    }

    var requiresJobLink: Bool {
        switch self {
        case .reserve, .release, .consume: true
        case .receive, .transfer, .returnToStock, .adjust: false
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
        remainingToRecord <= 0.0001 && overRecordedQuantity <= 0.0001
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
            case .receive, .transfer, .returnToStock, .adjust:
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
        case .consume:
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
            case .receive, .transfer, .returnToStock, .adjust:
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
