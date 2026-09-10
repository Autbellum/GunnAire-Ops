import Foundation

struct CatalogWorkbookTables {
    let materialHeaders = ["Item ID", "Description", "Scope", "Takeoff unit", "Current material cost (USD/unit)", "Catalog basis", "Saved mapped cost (USD/unit)", "Saved catalog material", "Latest mapping revision", "Existing price / labor basis"]
    let materialRows: [[JSONValue]]
    let historyRows: [[JSONValue]]
}
extension TakeoffWorkbook {
    static func catalogTables(_ project: ProjectDocument) throws -> CatalogWorkbookTables {
        let history = try project.catalogMaterialHistory()
        let grouped = Dictionary(grouping: history, by: \.itemID)
        let materials: [[JSONValue]] = try project.items.map { item in
            let id = item["id"]!.string!, mapping = try CatalogMaterialMapping.recorded(in: item)
            let last = grouped[id]?.last
            let status = mapping.map { $0.matches(item) ? "Current" : "Stale" } ?? (last == nil ? "Unmapped" : "Removed link")
            return [item["id"]!, item["description"] ?? .null, item["scope"] ?? .null, item["unit"] ?? .null,
                    item["materialUnit"] ?? .null, .string(status), mapping?.materialUnit.map(JSONValue.number) ?? .null,
                    mapping.map { .string($0.catalog.name) } ?? .null, last.map { .string($0.id.uuidString) } ?? .null,
                    item["priceSource"] ?? .null]
        }
        var historyRows: [[JSONValue]] = []
        let labels = ["version": "Mapping version", "catalog.id": "Catalog item ID", "catalog.source": "Catalog source",
                      "catalog.name": "Catalog material", "catalog.sku": "SKU", "catalog.supplier": "Supplier",
                      "catalog.supplierPartNumber": "Supplier part number", "catalog.purchaseCost": "Purchase cost (USD/purchase unit)",
                      "catalog.updatedAt": "Catalog updated at", "currency": "Confirmed currency", "purchaseUnit": "Purchase unit",
                      "catalogUnitsPerTakeoffUnit": "Purchase units per takeoff unit", "takeoffUnit": "Takeoff unit",
                      "itemDescription": "Mapped description", "lifecycle": "Mapped lifecycle", "basis": "Compatibility / conversion evidence"]
        for event in history {
            let before = try flattened(event.before), after = try flattened(event.after)
            let prefix: [JSONValue] = [.string(event.itemID), .string(event.id.uuidString), .string(event.author),
                                      .number(ISO8601DateFormatter().date(from: event.recordedAt)!.timeIntervalSince1970 / 86400 + 25569), .string(event.reason)]
            historyRows.append(prefix + [.string("Catalog link"), .string(event.before == .null ? "No link" : "Recorded"), .string(event.after == .null ? "No link" : "Recorded")])
            historyRows.append(prefix + [.string("Recorded material cost (USD/unit)"), event.beforeMaterialUnit, event.afterMaterialUnit])
            for key in Set(before.keys).union(after.keys).sorted() {
                historyRows.append(prefix + [.string(labels[key] ?? key), before[key] ?? .null, after[key] ?? .null])
            }
        }
        return .init(materialRows: materials, historyRows: historyRows)
    }
    private static func flattened(_ value: JSONValue, prefix: String = "") throws -> [String: JSONValue] {
        if let object = value.object {
            if object.isEmpty && !prefix.isEmpty { return [prefix: .string("{}")] }
            var fields: [String: JSONValue] = [:]
            for (key, child) in object {
                let path = prefix.isEmpty ? key : prefix + "." + key
                for (name, leaf) in try flattened(child, prefix: path) {
                    try require(fields[name] == nil, "Catalog evidence contains ambiguous nested field names.")
                    fields[name] = leaf
                }
            }
            return fields
        }
        guard !prefix.isEmpty else { return [:] }
        switch value {
        case .bool(let flag): return [prefix: .string(flag ? "true" : "false")]
        case .array:
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return [prefix: .string(String(decoding: try encoder.encode(value), as: UTF8.self))]
        default: return [prefix: value]
        }
    }
}
