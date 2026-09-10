import Foundation
import CryptoKit

private func roomFingerprint(room: JSONValue, assemblies: [JSONValue], latestRevision: JSONValue) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return SHA256.hash(data: try encoder.encode(JSONValue.object([
        "room": room, "assemblies": .array(assemblies), "latestRevision": latestRevision
    ]))).map { String(format: "%02x", $0) }.joined()
}

public struct RoomTransmissionRevision: Codable, Identifiable, Sendable {
    public let id: String
    public let roomID: String
    public let author: String
    public let recordedAt: String
    public let reason: String
    public let before: JSONValue
    public let after: JSONValue
    public let assemblyBasis: [JSONValue]
    public func result(before useBefore: Bool) throws -> RoomTransmissionResult {
        let room = try JSONDecoder().decode(RoomTransmissionRecord.self,from:JSONEncoder().encode(useBefore ? before : after))
        let assemblies = try JSONDecoder().decode([EnvelopeAssemblyRecord].self,from:JSONEncoder().encode(assemblyBasis))
        return try room.calculate(assemblies:assemblies)
    }
}

public extension ProjectDocument {
    func roomTransmissionHistory() throws -> [RoomTransmissionRevision] {
        if root["roomTransmissionHistory"] == .null { return [] }
        let records = try JSONDecoder().decode([RoomTransmissionRevision].self,from:JSONEncoder().encode(root["roomTransmissionHistory"]))
        try require(Set(records.map(\.id)).count == records.count,"Duplicate room revision IDs.")
        var latest: [String:JSONValue] = [:]
        for revision in records {
            for text in [revision.id,revision.roomID,revision.author,revision.recordedAt,revision.reason] {
                try require(!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,"Room revisions require identity, author, date and reason.")
            }
            try require(revision.before["id"].string == revision.roomID && revision.after["id"].string == revision.roomID,"Room revision snapshots must preserve room identity.")
            _ = try JSONDecoder().decode(RoomTransmissionRecord.self,from:JSONEncoder().encode(revision.before))
            _ = try JSONDecoder().decode(RoomTransmissionRecord.self,from:JSONEncoder().encode(revision.after))
            try require(revision.after["author"].string == revision.author && revision.after["recordedAt"].string == revision.recordedAt,"Room revision author/date must match the saved inputs.")
            if let previous = latest[revision.roomID] { try require(previous == revision.before,"Room revision history has a broken input chain.") }
            _ = try revision.result(before:true); _ = try revision.result(before:false)
            latest[revision.roomID] = revision.after
        }
        var current: [String: JSONValue] = [:]
        for row in root["roomTransmissions"].array ?? [] {
            guard let id = row["id"].string else { throw LoadSightError.invalid("Room transmission ID is missing.") }
            try require(current[id] == nil, "Duplicate room transmission IDs.")
            current[id] = row
        }
        for (id, last) in latest {
            try require(current[id] == last,"Room inputs disagree with their latest recorded revision.")
        }
        return records
    }

    /// Optimistic edit token includes full room inputs and the current assembly catalog.
    func roomTransmissionEditFingerprint(id: String) throws -> String {
        _ = try roomTransmissions()
        guard let room = root["roomTransmissions"].array?.first(where:{$0["id"].string == id}) else { throw LoadSightError.invalid("Room transmission case not found.") }
        let assemblies = (root["envelopeAssemblies"].array ?? []).sorted { ($0["id"].string ?? "") < ($1["id"].string ?? "") }
        let latestRevision = root["roomTransmissionHistory"].array?.last(where:{$0["roomID"].string == id})?["id"] ?? .null
        return try roomFingerprint(room: room, assemblies: assemblies, latestRevision: latestRevision)
    }

    /// Internal bulk read: validates once and uses the same token contract as an individual edit.
    internal func roomTransmissionEditFingerprints() throws -> [String: String] {
        _ = try roomTransmissions()
        let assemblies = (root["envelopeAssemblies"].array ?? []).sorted { ($0["id"].string ?? "") < ($1["id"].string ?? "") }
        var latest: [String: JSONValue] = [:], tokens: [String: String] = [:]
        for row in root["roomTransmissionHistory"].array ?? [] { latest[row["roomID"].string!] = row["id"] }
        for room in root["roomTransmissions"].array ?? [] {
            let id = room["id"].string!
            tokens[id] = try roomFingerprint(room: room, assemblies: assemblies, latestRevision: latest[id] ?? .null)
        }
        return tokens
    }

    @discardableResult
    mutating func reviseRoomTransmission(id: String, expectedFingerprint: String, reason: String, name: String, author: String, source: String, indoorDesignF: SourcedEngineeringValue, surfaces: [RoomEnvelopeSurface]) throws -> String {
        try require(!reason.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,"Explain the room revision.")
        try require(expectedFingerprint == roomTransmissionEditFingerprint(id:id),"Room inputs or available assemblies changed. Reload the case before revising it.")
        let before = root["roomTransmissions"].array!.first(where:{$0["id"].string == id})!
        var candidate = self
        // Reuse complete input validation and method migration before replacing the existing identity.
        let temporaryID = try candidate.saveRoomTransmission(name:name,author:author,source:source,indoorDesignF:indoorDesignF,surfaces:surfaces)
        var rows = candidate.root["roomTransmissions"].array!
        var replacement = rows.removeLast().object!
        try require(replacement["id"]?.string == temporaryID,"Unexpected room append order.")
        replacement["id"] = .string(id)
        var merged = before.object!
        merged.merge(replacement) { _, new in new }
        let after = JSONValue.object(merged)
        guard let index = rows.firstIndex(where:{$0["id"].string == id}) else { throw LoadSightError.invalid("Room transmission case disappeared.") }
        rows[index] = after
        let referenced = Set(((before["surfaces"].array ?? []) + (after["surfaces"].array ?? [])).compactMap { $0["assemblyID"].string })
        let basis = (root["envelopeAssemblies"].array ?? []).filter { referenced.contains($0["id"].string ?? "") }
        let revision = RoomTransmissionRevision(id:UUID().uuidString,roomID:id,author:author,recordedAt:after["recordedAt"].string!,reason:reason,before:before,after:after,assemblyBasis:basis)
        var history = root["roomTransmissionHistory"].array ?? []
        history.append(try JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(revision)))
        try candidate.replace("roomTransmissions",with:.array(rows))
        try candidate.replace("roomTransmissionHistory",with:.array(history))
        try candidate.validatePortableProject()
        self = candidate
        return id
    }
}
