import Foundation

public extension ProjectDocument {
    func catalogMaterialReview(asOf: Date = Date()) throws -> JSONValue {
        try require(asOf.timeIntervalSince1970.isFinite, "Catalog review time must be finite.")
        try validatePortableProject()
        let snapshot = try catalogMaterialReadSnapshot()
        return .object([
            "authority": .string("Recorded local catalog snapshots and estimator assertions; no live catalog fetch, authenticated approval or accounting publication"),
            "reviewedAt": .string(ISO8601DateFormatter().string(from: asOf)),
            "removedItemHistory": .array(snapshot.removedItemHistory),
            "items": .array(try snapshot.entries.map { entry in
                let item = entry.item
                let quoteReview = try entry.mapping?.quote?.review(asOf: asOf)
                return .object([
                    "itemID": .string(entry.itemID), "item": .object(item), "mapping": item["catalogMaterialMapping"] ?? .null,
                    "quoteReview": try quoteReview.map { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode($0)) } ?? .null,
                    "mappingCurrent": entry.mapping.map { .bool($0.matches(item)) } ?? .null,
                    "editFingerprint": .string(entry.editFingerprint),
                    "history": .array(entry.history)
                ])
            })
        ])
    }
}
