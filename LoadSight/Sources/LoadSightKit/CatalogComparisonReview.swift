import Foundation

public extension ProjectDocument {
    /// Read-only comparison against caller-supplied records, never a provider freshness assertion.
    func catalogComparisonReview(available: [OpsMaterialCatalogSnapshot]) throws -> JSONValue {
        try validatePortableProject()
        let catalog = try CatalogComparisonIndex(available: available)
        let snapshot = try catalogMaterialReadSnapshot()
        let entries: [JSONValue] = try snapshot.entries.map { entry in
            let comparison = try entry.mapping.map {
                try catalog.compare(saved: $0.catalog)
            }
            return .object([
                "itemID": .string(entry.itemID),
                "editFingerprint": .string(entry.editFingerprint),
                "mappingCurrent": entry.mapping.map { .bool($0.matches(entry.item)) } ?? .null,
                "comparison": try comparison.map {
                    let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode($0))
                    var value = encoded.object!
                    value["message"] = .string($0.message)
                    value["candidate"] = encoded["candidate"]
                    value["purchaseCostDelta"] = encoded["purchaseCostDelta"]
                    return .object(value)
                } ?? .null
            ])
        }
        return .object([
            "schemaVersion": .number(1),
            "authority": .string("Caller-supplied local records only; no live supplier fetch, quote-validity assertion, repricing, approval or publication"),
            "suppliedRecordCount": .number(Double(available.count)),
            "items": .array(entries)
        ])
    }
}

public enum CatalogComparisonInput {
    /// Require every field, including explicit null purchaseCost, to catch misspelled or omitted evidence.
    public static func decode(_ data: Data) throws -> [OpsMaterialCatalogSnapshot] {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .array(let records) = value else { throw LoadSightError.invalid("Catalog input must be an array of material snapshots") }
        let fields: Set<String> = ["id", "source", "name", "sku", "supplier", "supplierPartNumber", "purchaseCost", "updatedAt"]
        for record in records {
            guard case .object(let object) = record, Set(object.keys) == fields else {
                throw LoadSightError.invalid("Each catalog record requires exactly id, source, name, sku, supplier, supplierPartNumber, purchaseCost (number or null), updatedAt")
            }
        }
        let decoded = try JSONDecoder().decode([OpsMaterialCatalogSnapshot].self, from: data)
        for record in decoded { try record.validate() }
        return decoded
    }
}
