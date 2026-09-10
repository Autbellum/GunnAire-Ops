import Foundation
import CryptoKit

/// Portable map storage. The ingestion layer validates the typed geometry/source contract.
public struct StoredScheduleMap: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let request: JSONValue
    public init(id: UUID, name: String, request: JSONValue) { self.id = id; self.name = name; self.request = request }
}
public struct ScheduleMapRevision: Codable, Identifiable, Sendable {
    public let id: UUID
    public let recordedAt: String
    public let author: String
    public let reason: String
    public let before: JSONValue
    public let after: JSONValue
    public init(id: UUID = UUID(), recordedAt: String = Date().ISO8601Format(), author: String, reason: String, before: JSONValue, after: JSONValue) {
        self.id = id; self.recordedAt = recordedAt; self.author = author; self.reason = reason; self.before = before; self.after = after
    }
}
public extension ProjectDocument {
    func scheduleMaps() throws -> [StoredScheduleMap] { try Self.decodeScheduleMaps(root["scheduleMaps"] == .null ? .array([]) : root["scheduleMaps"]) }
    static func decodeScheduleMaps(_ raw: JSONValue) throws -> [StoredScheduleMap] {
        let maps = try JSONDecoder().decode([StoredScheduleMap].self, from: JSONEncoder().encode(raw))
        try require(maps.count <= 100 && Set(maps.map(\.id)).count == maps.count, "Duplicate or excessive saved schedule maps.")
        for map in maps {
            try require(!map.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Saved schedule map name is required.")
            try require(map.request.object != nil && map.request["schemaVersion"].number == 1 && map.request["regions"].array?.isEmpty == false, "Saved schedule map request is missing or unsupported.")
        }
        return maps
    }
    func scheduleMapHistory() throws -> [ScheduleMapRevision] {
        let current = root["scheduleMaps"] == .null ? JSONValue.array([]) : root["scheduleMaps"]
        _ = try Self.decodeScheduleMaps(current)
        if root["scheduleMapHistory"] == .null {
            try require(current == .array([]), "Saved schedule maps require their authored history.")
            return []
        }
        let history = try JSONDecoder().decode([ScheduleMapRevision].self, from: JSONEncoder().encode(root["scheduleMapHistory"]))
        try require(Set(history.map(\.id)).count == history.count, "Duplicate schedule map revision IDs.")
        var previous = JSONValue.array([])
        for revision in history {
            try require(!revision.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !revision.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Schedule map changes require an author and reason.")
            try require(ISO8601DateFormatter().date(from: revision.recordedAt) != nil, "Invalid schedule map history date.")
            _ = try Self.decodeScheduleMaps(revision.before); _ = try Self.decodeScheduleMaps(revision.after)
            try require(revision.before == previous && revision.before != revision.after, "Schedule map history has a broken or empty revision.")
            previous = revision.after
        }
        try require(current == previous, "Saved schedule maps differ from their history.")
        return history
    }
    func scheduleMapEditFingerprint() throws -> String {
        _ = try scheduleMapHistory()
        let state = JSONValue.object(["maps": root["scheduleMaps"], "history": root["scheduleMapHistory"]])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(state)).map { String(format: "%02x", $0) }.joined()
    }
}
