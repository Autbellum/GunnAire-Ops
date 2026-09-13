import Foundation
import LoadSightCore

public extension ProjectDocument {
    func markupLedger() throws -> MarkupLedger { try MarkupLedger(json: root["nativeMarkup"]) }
    func validateMarkupQuantities() throws {
        let ledger = try markupLedger()
        let expected = try ledger.takeoffRows()
        let actual = items.filter { $0["nativeMarkupID"] != nil }
        try require(Set(expected.compactMap { $0["id"]?.string }) == Set(actual.compactMap { $0["id"]?.string }), "Drawing markup and takeoff rows disagree.")
        for row in expected {
            guard let stored = actual.first(where: { $0["id"] == row["id"] }) else { throw LoadSightError.invalid("Drawing quantity is missing.") }
            for key in ["quantity", "unit", "nativeMarkupID", "source", "lifecycle", "description", "category"] {
                try require(stored[key] == row[key], "Drawing-derived \(key) was changed without updating its evidence.")
            }
        }
    }
    mutating func applyMarkup(_ ledger: MarkupLedger) throws {
        let derived = try ledger.takeoffRows()
        var rows = (root["items"].array ?? []).filter { $0["nativeMarkupID"] == .null }
        for newRow in derived {
            var row = items.first { $0["id"] == newRow["id"] } ?? newRow
            for key in ["id", "nativeMarkupID", "category", "description", "lifecycle", "quantity", "unit", "quantityStatus", "source", "basis"] { row[key] = newRow[key] }
            rows.append(.object(row))
        }
        var copy = self
        try copy.replace("items", with: .array(rows))
        try copy.replace("nativeMarkup", with: ledger.json())
        let gates = (root["qa"].array ?? []).map { entry -> JSONValue in
            var row = entry.object!; row["status"] = .string("Open"); row["reviewer"] = .string(""); row["date"] = .string("")
            return .object(row)
        }
        try copy.replace("qa", with: .array(gates))
        try copy.validateMarkupQuantities(); self = copy
    }
}
