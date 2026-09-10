import Foundation
import CryptoKit

public struct QACheck: Identifiable, Sendable {
    public let id: String
    public let title: String
}

public enum QAWorkflow {
    public static let checks: [QACheck] = [
        "Supplied mechanical sheet inventory and source fingerprint",
        "Visual review of each supplied page and embedded schedules/details",
        "Unique new-device count / duplicate-view check",
        "New-plan zone airflow arithmetic",
        "All relevant RFIs and trade responsibilities resolved",
        "Calibrated per-view length / area measurements and fittings",
        "Demolition leader endpoints, existing/new/reuse reconciliation",
        "Site survey, baseline TAB and existing-condition evidence",
        "Supplier / subcontract pricing and labor basis checked",
        "Allowances, exclusions and proposal commercial terms approved",
        "Current addenda / complete mechanical bid basis confirmed",
        "Independent reviewer signoff and final purchasing check"
    ].enumerated().map { .init(id: String(format: "QA-%02d", $0.offset + 1), title: $0.element) }
    public static func title(for id: String) -> String { checks.first { $0.id == id }?.title ?? id }
}

public extension ProjectDocument {
    /// Semantic estimate state. Drawing bytes are validated separately against source hashes;
    /// excluding their portable storage representation keeps package/JSON reviews equivalent.
    func qaFingerprint() throws -> String {
        var state = root.object!
        for key in ["qaHistory", "nativeDrawings"] { state.removeValue(forKey: key) }
        state["qa"] = .array((root["qa"].array ?? []).map { gate in
            .object(["id": gate["id"], "check": .string(gate["check"].string ?? QAWorkflow.title(for: gate["id"].string ?? ""))])
        })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(JSONValue.object(state))).map { String(format: "%02x", $0) }.joined()
    }
    func isQACurrent(_ gate: JSONValue) throws -> Bool {
        guard gate["status"].string == "Complete" else { return false }
        // Preserve documented legacy reviews; managed reviews additionally bind to project state.
        guard gate["reviewFingerprint"] != .null else { return true }
        guard gate["reviewFingerprint"].string == (try qaFingerprint()) else { return false }
        if gate["id"].string == "QA-12" { return gate["checklistFingerprint"].string == (try qaChecklistFingerprint()) }
        return true
    }
    private func qaChecklistFingerprint() throws -> String {
        let prior = (root["qa"].array ?? []).filter { $0["id"].string != "QA-12" }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(prior)).map { String(format: "%02x", $0) }.joined()
    }
    mutating func recordQACheck(id: String, reviewer: String, evidence: String, complete: Bool) throws {
        let cleanReviewer = reviewer.trimmingCharacters(in: .whitespacesAndNewlines)
        try require(!cleanReviewer.isEmpty, "Record the reviewer name.")
        try require(!evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Record review evidence or the reason for reopening.")
        var rows = root["qa"].array!
        guard let index = rows.firstIndex(where: { $0["id"].string == id }), var gate = rows[index].object else { throw LoadSightError.invalid("QA check not found.") }
        if complete && id == "QA-12" {
            let estimator = (root["reviewer"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            try require(!estimator.isEmpty && estimator.caseInsensitiveCompare(cleanReviewer) != .orderedSame, "The final check needs an independent reviewer distinct from the responsible estimator.")
            for check in QAWorkflow.checks where check.id != id {
                guard let other = rows.first(where: { $0["id"].string == check.id }) else { throw LoadSightError.invalid("Required QA check is missing.") }
                try require(other["reviewFingerprint"].string != nil, "Review legacy checks against the current project before final signoff.")
                try require(try isQACurrent(other) && !(other["reviewer"].string ?? "").isEmpty && !(other["date"].string ?? "").isEmpty, "Complete the other current QA checks before final signoff.")
            }
        }
        let before = rows[index], now = Date().ISO8601Format()
        gate["check"] = .string(gate["check"]?.string ?? QAWorkflow.title(for: id))
        gate["status"] = .string(complete ? "Complete" : "Open")
        gate["reviewer"] = .string(complete ? cleanReviewer : "")
        gate["date"] = .string(complete ? now : "")
        gate["note"] = .string(evidence)
        gate["reviewFingerprint"] = complete ? .string(try qaFingerprint()) : .null
        if id == "QA-12" { gate["checklistFingerprint"] = complete ? .string(try qaChecklistFingerprint()) : .null }
        rows[index] = .object(gate)
        // Any changed underlying check requires a fresh independent final review.
        if id != "QA-12", let final = rows.firstIndex(where: { $0["id"].string == "QA-12" }), var value = rows[final].object {
            value["status"] = .string("Open"); value["reviewer"] = .string(""); value["date"] = .string(""); value["reviewFingerprint"] = .null
            rows[final] = .object(value)
        }
        var object = root.object!, history = root["qaHistory"].array ?? []
        history.append(.object(["id": .string(UUID().uuidString), "gateID": .string(id), "action": .string(complete ? "reviewed" : "reopened"),
                                "reviewer": .string(cleanReviewer), "at": .string(now), "evidence": .string(evidence), "before": before, "after": .object(gate)]))
        object["qa"] = .array(rows); object["qaHistory"] = .array(history)
        self = try ProjectDocument(data: JSONEncoder().encode(JSONValue.object(object)))
    }
}
