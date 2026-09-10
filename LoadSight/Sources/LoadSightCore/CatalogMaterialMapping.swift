import Foundation
import CryptoKit

/// A read-only source record. Currency and purchasing units require explicit estimator confirmation.
public struct OpsMaterialCatalogSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let source: String
    public let name: String
    public let sku: String
    public let supplier: String
    public let supplierPartNumber: String
    public let purchaseCost: Double?
    public let updatedAt: String
    public init(id: UUID, source: String, name: String, sku: String = "", supplier: String = "", supplierPartNumber: String = "", purchaseCost: Double?, updatedAt: String) {
        self.id = id; self.source = source; self.name = name; self.sku = sku; self.supplier = supplier
        self.supplierPartNumber = supplierPartNumber; self.purchaseCost = purchaseCost; self.updatedAt = updatedAt
    }
    public func validate() throws {
        try require(!source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Catalog source and name are required.")
        try require(ISO8601DateFormatter().date(from: updatedAt) != nil, "Invalid catalog snapshot date.")
        if let purchaseCost { try nonnegative(purchaseCost) }
    }
}
public struct CatalogMaterialMapping: Codable, Equatable, Sendable {
    public let version: Int
    public let catalog: OpsMaterialCatalogSnapshot
    public let currency: String
    public let purchaseUnit: String
    public let catalogUnitsPerTakeoffUnit: Double
    public let takeoffUnit: String
    public let itemDescription: String
    public let lifecycle: String
    public let basis: String
    public init(catalog: OpsMaterialCatalogSnapshot, currency: String, purchaseUnit: String, catalogUnitsPerTakeoffUnit: Double, takeoffUnit: String, itemDescription: String, lifecycle: String, basis: String) {
        version = 1; self.catalog = catalog; self.currency = currency; self.purchaseUnit = purchaseUnit
        self.catalogUnitsPerTakeoffUnit = catalogUnitsPerTakeoffUnit; self.takeoffUnit = takeoffUnit
        self.itemDescription = itemDescription; self.lifecycle = lifecycle; self.basis = basis
    }
    public var materialUnit: Double? { catalog.purchaseCost.map { $0 * catalogUnitsPerTakeoffUnit } }
    public func validate() throws {
        try require(version == 1, "Unsupported catalog mapping version.")
        try catalog.validate()
        try require(currency == "USD", "Confirm USD purchase cost before mapping into this USD estimate.")
        for text in [purchaseUnit, takeoffUnit, itemDescription, basis] {
            try require(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Catalog mapping requires purchase/takeoff units, description and conversion evidence.")
        }
        try require(catalogUnitsPerTakeoffUnit.isFinite && catalogUnitsPerTakeoffUnit > 0, "Catalog units per takeoff unit must be finite and greater than zero.")
        if let materialUnit { try nonnegative(materialUnit) }
    }
    public func matches(_ item: [String: JSONValue]) -> Bool {
        (item["materialUnit"] ?? .null) == (materialUnit.map(JSONValue.number) ?? .null) &&
        (item["unit"]?.string ?? "") == takeoffUnit && (item["description"]?.string ?? "") == itemDescription &&
        (item["lifecycle"]?.string ?? "") == lifecycle
    }
}
public struct CatalogMaterialRevision: Codable, Identifiable, Sendable {
    public let id: UUID
    public let itemID: String
    public let author: String
    public let recordedAt: String
    public let reason: String
    public let before: JSONValue
    public let after: JSONValue
    public let beforeMaterialUnit: JSONValue
    public let afterMaterialUnit: JSONValue
}
private func mappingDecode(_ raw: JSONValue) throws -> CatalogMaterialMapping? {
    guard raw != .null else { return nil }
    let value = try JSONDecoder().decode(CatalogMaterialMapping.self, from: JSONEncoder().encode(raw))
    try value.validate(); return value
}
private func mappingJSON<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) }
public extension ProjectDocument {
    func catalogMaterialMapping(itemID: String) throws -> CatalogMaterialMapping? {
        guard let item = items.first(where: { $0["id"]?.string == itemID }) else { throw LoadSightError.invalid("Takeoff item not found.") }
        return try mappingDecode(item["catalogMaterialMapping"] ?? .null)
    }
    func catalogMaterialHistory() throws -> [CatalogMaterialRevision] {
        let raw = root["catalogMaterialHistory"]
        let history = raw == .null ? [] : try JSONDecoder().decode([CatalogMaterialRevision].self, from: JSONEncoder().encode(raw))
        try require(Set(history.map(\.id)).count == history.count, "Duplicate catalog mapping revision IDs.")
        var states: [String: JSONValue] = [:]
        for event in history {
            try require(!event.itemID.isEmpty && !event.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !event.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Catalog mapping requires item identity, author and reason.")
            try require(ISO8601DateFormatter().date(from: event.recordedAt) != nil, "Invalid catalog mapping history date.")
            _ = try mappingDecode(event.before)
            let after = try mappingDecode(event.after)
            try require(event.before == (states[event.itemID] ?? .null), "Catalog mapping history has a broken chain.")
            for cost in [event.beforeMaterialUnit, event.afterMaterialUnit] where cost != .null {
                guard let n = cost.number else { throw LoadSightError.invalid("Invalid recorded material cost.") }; try nonnegative(n)
            }
            if let after { try require(event.afterMaterialUnit == (after.materialUnit.map(JSONValue.number) ?? .null), "Recorded cost differs from the catalog conversion.") }
            else { try require(event.afterMaterialUnit == event.beforeMaterialUnit, "Removing a catalog link must preserve its material cost.") }
            states[event.itemID] = event.after
        }
        for item in items {
            let id = item["id"]!.string!, mapping = item["catalogMaterialMapping"] ?? .null
            _ = try mappingDecode(mapping)
            try require(mapping == (states[id] ?? .null), "Catalog mapping differs from its recorded history.")
            states.removeValue(forKey: id)
        }
        try require(states.values.allSatisfy { $0 == .null }, "Remove a catalog mapping before deleting its takeoff item.")
        return history
    }
    func catalogMaterialEditFingerprint(itemID: String) throws -> String {
        guard let item = items.first(where: { $0["id"]?.string == itemID }) else { throw LoadSightError.invalid("Takeoff item not found.") }
        let last = try catalogMaterialHistory().last { $0.itemID == itemID }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(JSONValue.object(["item": .object(item), "lastRevision": last.map { .string($0.id.uuidString) } ?? .null]))).map { String(format: "%02x", $0) }.joined()
    }
    /// Records an estimator-selected cost basis; never edits a catalog, selling price, quantity, or labor assumption.
    mutating func updateCatalogMaterialMapping(itemID: String, mapping: CatalogMaterialMapping?, expectedFingerprint: String, author: String, reason: String) throws {
        try require(expectedFingerprint == catalogMaterialEditFingerprint(itemID: itemID), "The takeoff item changed. Reopen its catalog mapping before saving.")
        try mapping?.validate()
        var rows = root["items"].array!, object = root.object!
        let index = rows.firstIndex { $0["id"].string == itemID }!
        var item = rows[index].object!
        let before = item["catalogMaterialMapping"] ?? .null, beforeCost = item["materialUnit"] ?? .null
        try require(mapping != nil || before != .null, "This item has no catalog mapping to remove.")
        if let mapping {
            try require(mapping.takeoffUnit == (item["unit"]?.string ?? "") && mapping.itemDescription == (item["description"]?.string ?? "") && mapping.lifecycle == (item["lifecycle"]?.string ?? ""), "Mapping must describe the current takeoff item and unit.")
            item["materialUnit"] = mapping.materialUnit.map(JSONValue.number) ?? .null
        }
        let after = try mapping.map(mappingJSON) ?? .null
        item["catalogMaterialMapping"] = after; rows[index] = .object(item)
        let event = CatalogMaterialRevision(id: UUID(), itemID: itemID, author: author, recordedAt: Date().ISO8601Format(), reason: reason, before: before, after: after, beforeMaterialUnit: beforeCost, afterMaterialUnit: item["materialUnit"] ?? .null)
        var history = root["catalogMaterialHistory"].array ?? []; history.append(try mappingJSON(event))
        object["items"] = .array(rows); object["catalogMaterialHistory"] = .array(history)
        object["qa"] = .array(root["qa"].array!.map { row in
            var gate = row.object!; gate["status"] = .string("Open"); gate["reviewer"] = .string(""); gate["date"] = .string(""); return .object(gate)
        })
        self = try ProjectDocument(data: JSONEncoder().encode(JSONValue.object(object)))
    }
}
