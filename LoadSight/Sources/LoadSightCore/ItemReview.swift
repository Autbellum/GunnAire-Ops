import Foundation

public enum QuantityReviewStatus: String, CaseIterable, Sendable {
    case required = "Review required", verified = "Verified", fieldVerified = "Field-verified"
    case crossChecked = "Cross-checked", scopeDefined = "Scope-defined", allowance = "Approved allowance"
}
public extension ProjectDocument {
    static var itemReviewFields: [String] { ["quantity", "unit", "source", "basis", "description", "category", "lifecycle", "scope", "quantityStatus", "allowanceNote"] }
    func isItemReviewCurrent(_ item: [String: JSONValue]) -> Bool {
        guard let snapshot = item["quantityReviewBasis"]?.object else { return item["quantityReviewBasis"] == nil }
        return Self.itemReviewFields.allSatisfy { (snapshot[$0] ?? .null) == (item[$0] ?? .null) }
    }
    mutating func reviewItem(id: String, scope: String, status: QuantityReviewStatus, allowanceNote: String, reviewer: String, evidence: String) throws {
        try require(!reviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Record the quantity reviewer.")
        try require(!evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Record the scope decision and quantity-review evidence.")
        try require(["Base", "Allowance", "Hold", "Excluded"].contains(scope), "Unknown item scope.")
        var rows = root["items"].array!
        guard let index = rows.firstIndex(where: { $0["id"].string == id }), var item = rows[index].object else { throw LoadSightError.invalid("Takeoff item not found.") }
        if status != .required {
            try require(item["quantity"]?.number != nil, "Measure or enter a deliberate quantity before approving it.")
            for key in ["unit", "source"] {
                try require(!(item[key]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Quantity approval requires \(key).")
            }
        }
        if scope == "Allowance" && status != .required {
            try require(status == .allowance && !allowanceNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "An approved allowance requires its written basis and Approved allowance status.")
        }
        if status == .allowance { try require(scope == "Allowance", "Approved allowance status belongs to Allowance scope.") }
        let before = rows[index], now = Date().ISO8601Format()
        item["scope"] = .string(scope); item["quantityStatus"] = .string(status.rawValue); item["allowanceNote"] = .string(allowanceNote)
        item["quantityReviewer"] = .string(reviewer); item["quantityReviewedAt"] = .string(now); item["quantityReviewEvidence"] = .string(evidence)
        item["quantityReviewBasis"] = .object(Dictionary(uniqueKeysWithValues: Self.itemReviewFields.map { ($0, item[$0] ?? .null) }))
        rows[index] = .object(item)
        var object = root.object!, history = root["itemReviewHistory"].array ?? []
        history.append(.object(["id": .string(UUID().uuidString), "itemID": .string(id), "reviewer": .string(reviewer), "at": .string(now),
                                "evidence": .string(evidence), "before": before, "after": .object(item)]))
        object["items"] = .array(rows); object["itemReviewHistory"] = .array(history)
        object["qa"] = .array(root["qa"].array!.map { entry in
            var gate = entry.object!; gate["status"] = .string("Open"); gate["reviewer"] = .string(""); gate["date"] = .string("")
            return .object(gate)
        })
        self = try ProjectDocument(data: JSONEncoder().encode(JSONValue.object(object)))
    }
}
