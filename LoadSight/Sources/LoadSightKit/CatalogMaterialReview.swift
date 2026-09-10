import Foundation

public extension ProjectDocument {
    func catalogMaterialReview() throws -> JSONValue {
        try validatePortableProject()
        let snapshot = try catalogMaterialReadSnapshot()
        return .object([
            "authority": .string("Recorded local catalog snapshots and estimator assertions; no live catalog fetch, authenticated approval or accounting publication"),
            "removedItemHistory": .array(snapshot.removedItemHistory),
            "items": .array(snapshot.entries.map { entry in
                let item = entry.item
                return .object([
                    "itemID": .string(entry.itemID), "item": .object(item), "mapping": item["catalogMaterialMapping"] ?? .null,
                    "mappingCurrent": entry.mapping.map { .bool($0.matches(item)) } ?? .null,
                    "editFingerprint": .string(entry.editFingerprint),
                    "history": .array(entry.history)
                ])
            })
        ])
    }
}
