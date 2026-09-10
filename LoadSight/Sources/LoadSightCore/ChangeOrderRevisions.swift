import Foundation
import CryptoKit

public struct ChangeOrderRevision: Codable, Identifiable, Sendable {
    public let id: String
    public let changeOrderID: String
    public let author: String
    public let recordedAt: String
    public let reason: String
    public let before: JSONValue
    public let after: JSONValue
    public func record(before useBefore: Bool) throws -> ChangeOrderRecord {
        let record = try JSONDecoder().decode(ChangeOrderRecord.self, from: JSONEncoder().encode(useBefore ? before : after))
        try record.validate()
        return record
    }
}
public extension ChangeOrderRecord {
    func validate() throws {
        try require(version == 1 && status == "Draft", "Unsupported change-order version or status.")
        for value in [id, author, createdAt, project] { try require(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Change record identity and authorship are required.") }
        _ = try draft.review()
    }
}
public extension ProjectDocument {
    func changeOrderHistory() throws -> [ChangeOrderRevision] {
        guard root.object?["changeOrderHistory"] != nil else { return [] }
        let history = try JSONDecoder().decode([ChangeOrderRevision].self, from: JSONEncoder().encode(root["changeOrderHistory"]))
        try require(Set(history.map(\.id)).count == history.count, "Duplicate change-order revision IDs.")
        var latest: [String: JSONValue] = [:]
        for revision in history {
            for value in [revision.id, revision.changeOrderID, revision.author, revision.reason] { try require(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Change revision identity, author and reason are required.") }
            try require(ISO8601DateFormatter().date(from: revision.recordedAt) != nil, "Invalid change revision date.")
            let before = try revision.record(before: true), after = try revision.record(before: false)
            try require(before.id == revision.changeOrderID && after.id == revision.changeOrderID, "Change revision must preserve its record identity.")
            for key in ["version", "id", "project", "author", "createdAt", "status"] { try require(revision.before[key] == revision.after[key], "Change revisions preserve creation metadata and draft status.") }
            if let preceding = latest[revision.changeOrderID] { try require(preceding == revision.before, "Change revision snapshots have a broken chain.") }
            latest[revision.changeOrderID] = revision.after
        }
        for (id, snapshot) in latest {
            try require(root["changeOrders"].array?.first { $0["id"].string == id } == snapshot, "Current change order disagrees with its latest revision.")
        }
        return history
    }
    func changeOrderEditFingerprint(id: String) throws -> String {
        _ = try changeOrders(); _ = try changeOrderHistory()
        guard let record = root["changeOrders"].array?.first(where: { $0["id"].string == id }) else { throw LoadSightError.invalid("Change order not found.") }
        let latest = root["changeOrderHistory"].array?.last(where: { $0["changeOrderID"].string == id })?["id"] ?? .null
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(JSONValue.object(["record": record, "latestRevision": latest]))).map { String(format: "%02x", $0) }.joined()
    }
    @discardableResult
    mutating func reviseChangeOrder(id: String, expectedFingerprint: String, draft: ChangeOrderDraft, author: String, reason: String) throws -> String {
        try require(expectedFingerprint == changeOrderEditFingerprint(id: id), "This change order was revised. Reopen the current record before saving; your draft has not been applied.")
        _ = try draft.review()
        let before = root["changeOrders"].array!.first { $0["id"].string == id }!
        let existing = try JSONDecoder().decode(ChangeOrderRecord.self, from: JSONEncoder().encode(before))
        let allowedLinks = Set(root["rfis"].array!.compactMap { $0["id"].string }).union(existing.draft.rfiIDs)
        try require(draft.rfiIDs.allSatisfy { allowedLinks.contains($0) }, "New change-order RFI links must identify existing RFIs.")
        var replacement = before.object!
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(draft))
        var mergedDraft = before["draft"].object!
        // Optional fields omitted by Codable must explicitly clear their previous values.
        for key in ["entitlement", "markupBasis"] { mergedDraft.removeValue(forKey: key) }
        mergedDraft.merge(encoded.object!) { _, new in new }
        replacement["draft"] = .object(mergedDraft)
        let after = JSONValue.object(replacement)
        let revision = ChangeOrderRevision(id: UUID().uuidString, changeOrderID: id, author: author, recordedAt: Date().ISO8601Format(), reason: reason, before: before, after: after)
        var object = root.object!, rows = root["changeOrders"].array!, history = root["changeOrderHistory"].array ?? []
        rows[rows.firstIndex { $0["id"].string == id }!] = after
        history.append(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(revision)))
        object["changeOrders"] = .array(rows); object["changeOrderHistory"] = .array(history)
        object["qa"] = .array(root["qa"].array!.map { entry in
            var gate = entry.object!; gate["status"] = .string("Open"); gate["reviewer"] = .string(""); gate["date"] = .string(""); return .object(gate)
        })
        self = try ProjectDocument(data: JSONEncoder().encode(JSONValue.object(object)))
        return id
    }
}
