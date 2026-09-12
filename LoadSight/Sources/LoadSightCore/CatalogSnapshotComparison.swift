import Foundation

public enum CatalogComparisonStatus: String, Codable, Sendable {
    case unchanged, changed, missing, ambiguous, differentSource, olderSource
}
public struct CatalogSnapshotDifference: Codable, Equatable, Sendable, Identifiable {
    public let field: String
    public let saved: JSONValue
    public let available: JSONValue
    public var id: String { field }
}

/// One validated caller-supplied catalog. Duplicate identities are retained as ambiguity,
/// and source contexts remain distinct. This does not fetch or authorize provider data.
public struct CatalogComparisonIndex: Sendable {
    private let records: [UUID: [String: [OpsMaterialCatalogSnapshot]]]
    public init(available: [OpsMaterialCatalogSnapshot]) throws {
        var grouped: [UUID: [String: [OpsMaterialCatalogSnapshot]]] = [:]
        for record in available {
            try record.validate()
            grouped[record.id, default: [:]][record.source, default: []].append(record)
        }
        records = grouped
    }
    public func compare(saved: OpsMaterialCatalogSnapshot) throws -> CatalogSnapshotComparison {
        try saved.validate()
        return CatalogSnapshotComparison.comparison(saved: saved,
            matches: records[saved.id]?[saved.source] ?? [], hasIdentity: records[saved.id] != nil)
    }
}
/// Compares supplied local records only; absence does not prove deletion or provider availability.
public struct CatalogSnapshotComparison: Codable, Sendable {
    public let status: CatalogComparisonStatus
    public let candidate: OpsMaterialCatalogSnapshot?
    public let differences: [CatalogSnapshotDifference]
    public let purchaseCostDelta: Double?
    public var message: String {
        switch status {
        case .unchanged: "The supplied Ops record matches the saved source."
        case .changed: "The supplied Ops record differs from the saved source. Review the changes before applying it."
        case .missing: "No matching material record was supplied. It may be unavailable, filtered, or outside this host's catalog."
        case .ambiguous: "Multiple records have this identity and source. Resolve the catalog ambiguity before selecting a replacement."
        case .differentSource: "This material ID appears under a different source context. It cannot automatically replace the saved source."
        case .olderSource: "The supplied record has an older timestamp than the saved source. Check its currency before using it."
        }
    }
    public static func compare(saved: OpsMaterialCatalogSnapshot, available: [OpsMaterialCatalogSnapshot]) throws -> Self {
        try CatalogComparisonIndex(available: available).compare(saved: saved)
    }
    fileprivate static func comparison(saved: OpsMaterialCatalogSnapshot, matches: [OpsMaterialCatalogSnapshot], hasIdentity: Bool) -> Self {
        guard matches.count <= 1 else { return .init(status: .ambiguous, candidate: nil, differences: [], purchaseCostDelta: nil) }
        guard let candidate = matches.first else {
            return .init(status: hasIdentity ? .differentSource : .missing, candidate: nil, differences: [], purchaseCostDelta: nil)
        }
        let pairs: [(String, JSONValue, JSONValue)] = [
            ("Name", .string(saved.name), .string(candidate.name)),
            ("SKU", .string(saved.sku), .string(candidate.sku)),
            ("Supplier", .string(saved.supplier), .string(candidate.supplier)),
            ("Supplier part", .string(saved.supplierPartNumber), .string(candidate.supplierPartNumber)),
            ("Purchase cost amount", saved.purchaseCost.map(JSONValue.number) ?? .null, candidate.purchaseCost.map(JSONValue.number) ?? .null)
        ]
        var differences = pairs.filter { $0.1 != $0.2 }.map { CatalogSnapshotDifference(field: $0.0, saved: $0.1, available: $0.2) }
        let oldDate = ISO8601DateFormatter().date(from: saved.updatedAt)!, newDate = ISO8601DateFormatter().date(from: candidate.updatedAt)!
        if oldDate != newDate { differences.append(.init(field: "Catalog timestamp", saved: .string(saved.updatedAt), available: .string(candidate.updatedAt))) }
        let delta: Double? = if let old = saved.purchaseCost, let new = candidate.purchaseCost { new - old } else { nil }
        return .init(status: newDate < oldDate ? .olderSource : (differences.isEmpty ? .unchanged : .changed), candidate: candidate, differences: differences, purchaseCostDelta: delta)
    }
}
