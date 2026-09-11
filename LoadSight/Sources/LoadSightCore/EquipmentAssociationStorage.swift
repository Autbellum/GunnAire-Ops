import Foundation
import CryptoKit

public enum EquipmentAssociationRelationship: String, Codable, CaseIterable, Sendable {
    case sameEquipment, coordinationReference
}
public enum EquipmentAssociationViewRole: String, Codable, CaseIterable, Sendable {
    case plan, detail, controls, electrical, structural, other
}
public struct StoredEquipmentAssociation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let mapID: UUID
    public let mapFingerprint: String
    public let label: String
    public let relationship: EquipmentAssociationRelationship
    public let viewRole: EquipmentAssociationViewRole
    public let basis: String
    public let evidence: JSONValue
    public init(id: UUID, mapID: UUID, mapFingerprint: String, label: String,
                relationship: EquipmentAssociationRelationship, viewRole: EquipmentAssociationViewRole, basis: String, evidence: JSONValue) {
        self.id = id; self.mapID = mapID; self.mapFingerprint = mapFingerprint; self.label = label
        self.relationship = relationship; self.viewRole = viewRole; self.basis = basis; self.evidence = evidence
    }
}
public struct EquipmentAssociationRevision: Codable, Identifiable, Sendable {
    public let id: UUID
    public let recordedAt: String
    public let author: String
    public let reason: String
    public let before: JSONValue
    public let after: JSONValue
    public init(author: String, reason: String, before: JSONValue, after: JSONValue) {
        id = UUID(); recordedAt = Date().ISO8601Format(); self.author = author; self.reason = reason; self.before = before; self.after = after
    }
}
public extension ProjectDocument {
    func equipmentAssociations() throws -> [StoredEquipmentAssociation] {
        try Self.decodeEquipmentAssociations(root["equipmentAssociations"] == .null ? .array([]) : root["equipmentAssociations"])
    }
    static func decodeEquipmentAssociations(_ raw: JSONValue) throws -> [StoredEquipmentAssociation] {
        let records = try JSONDecoder().decode([StoredEquipmentAssociation].self, from: JSONEncoder().encode(raw))
        try require(records.count <= 1000 && Set(records.map(\.id)).count == records.count, "Duplicate or excessive equipment association records.")
        var assignments = Set<String>()
        for record in records {
            try require(!record.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && record.label.count <= 512,
                        "Equipment link label is required (up to 512 characters).")
            try require(!record.basis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && record.basis.count <= 4096,
                        "Record the source review basis for this equipment link (up to 4,096 characters).")
            try require(record.mapFingerprint.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil, "Invalid equipment-link map fingerprint.")
            let evidence = record.evidence
            try require(evidence["schemaVersion"].number == 1 && evidence["row"]["id"].string?.isEmpty == false && evidence["occurrence"]["id"].string?.isEmpty == false,
                        "Equipment association requires a complete source evidence snapshot.")
            let key = evidence["row"]["id"].string! + ":" + evidence["occurrence"]["id"].string! + ":" + record.relationship.rawValue
            try require(assignments.insert(key).inserted, "This row/occurrence relationship is already recorded. Revise its existing link.")
        }
        return records
    }
    func equipmentAssociationHistory() throws -> [EquipmentAssociationRevision] {
        let current = root["equipmentAssociations"] == .null ? JSONValue.array([]) : root["equipmentAssociations"]
        _ = try Self.decodeEquipmentAssociations(current)
        if root["equipmentAssociationHistory"] == .null {
            try require(current == .array([]), "Equipment links require authored history."); return []
        }
        let history = try JSONDecoder().decode([EquipmentAssociationRevision].self, from: JSONEncoder().encode(root["equipmentAssociationHistory"]))
        try require(history.count <= 10000 && Set(history.map(\.id)).count == history.count, "Duplicate or excessive equipment-link history.")
        var previous = JSONValue.array([])
        for revision in history {
            try require(!revision.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !revision.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        "Equipment-link changes require an author and reason.")
            try require(ISO8601DateFormatter().date(from: revision.recordedAt) != nil, "Invalid equipment-link history date.")
            _ = try Self.decodeEquipmentAssociations(revision.before); _ = try Self.decodeEquipmentAssociations(revision.after)
            try require(revision.before == previous && revision.before != revision.after, "Equipment-link history has a broken or empty revision.")
            previous = revision.after
        }
        try require(current == previous, "Equipment links differ from their history.")
        return history
    }
    func equipmentAssociationEditFingerprint() throws -> String {
        _ = try equipmentAssociationHistory()
        return try Self.equipmentAssociationFingerprint(.object(["links": root["equipmentAssociations"], "history": root["equipmentAssociationHistory"]]))
    }
    static func equipmentAssociationFingerprint(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
}
