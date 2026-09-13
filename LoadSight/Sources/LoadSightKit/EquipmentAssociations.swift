import Foundation

public struct EquipmentAssociationEvidence: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let row: EquipmentScheduleRow
    public let occurrence: MechanicalTextCandidate
}
public struct EquipmentAssociationAssessment: Codable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable { case current, needsReview }
    public let association: StoredEquipmentAssociation
    public let evidence: EquipmentAssociationEvidence
    public let status: Status
    public let issues: [String]
    public var id: UUID { association.id }
}
public extension StoredEquipmentAssociation {
    func sourceEvidence() throws -> EquipmentAssociationEvidence {
        let result = try JSONDecoder().decode(EquipmentAssociationEvidence.self, from: JSONEncoder().encode(evidence))
        try require(result.schemaVersion == 1 && result.occurrence.kind == .equipmentTag, "Unsupported equipment association evidence.")
        try require(result.row.tag.uppercased() == result.occurrence.matchedText.uppercased(), "Equipment association tag evidence does not match.")
        return result
    }
}
public extension ProjectDocument {
    func validateEquipmentAssociationSnapshots() throws {
        for record in try equipmentAssociations() { _ = try record.sourceEvidence() }
        for revision in try equipmentAssociationHistory() {
            for record in try Self.decodeEquipmentAssociations(revision.before) + Self.decodeEquipmentAssociations(revision.after) { _ = try record.sourceEvidence() }
        }
    }
    /// Current means the recorded evidence still matches. It does not authenticate the reviewer or prove physical quantity.
    func equipmentAssociationReview(in drawings: DrawingArchive) throws -> [EquipmentAssociationAssessment] {
        try validateDrawingEvidence(in: drawings)
        let maps = try scheduleMaps()
        var extractions: [UUID: EquipmentScheduleExtraction] = [:]
        var results: [EquipmentAssociationAssessment] = []
        for record in try equipmentAssociations() {
            try Task.checkCancellation()
            let evidence = try record.sourceEvidence()
            var issues: [String] = []
            if let map = maps.first(where: { $0.id == record.mapID }) {
                if try Self.equipmentAssociationFingerprint(map.request) != record.mapFingerprint {
                    issues.append("The saved column map changed. Review the current schedule and revise this link.")
                } else {
                    do {
                        if extractions[map.id] == nil { extractions[map.id] = try EquipmentScheduleExtractor.extract(drawings, request: map.columnMap()) }
                        if extractions[map.id]?.rows.contains(evidence.row) != true { issues.append("The schedule row or its cross-reference evidence changed.") }
                        try evidence.occurrence.validate(in: drawings)
                        try validateAssociationOccurrence(evidence.occurrence, maps: maps)
                    } catch is CancellationError { throw CancellationError() }
                    catch { issues.append(error.localizedDescription) }
                }
            } else { issues.append("The source column map was removed. The historical link is retained but needs review.") }
            results.append(.init(association: record, evidence: evidence, status: issues.isEmpty ? .current : .needsReview, issues: issues))
        }
        try Task.checkCancellation()
        return results
    }
    @discardableResult
    mutating func saveEquipmentAssociation(id: UUID? = nil, mapID: UUID, rowID: String, occurrenceID: String,
                                           label: String, relationship: EquipmentAssociationRelationship,
                                           viewRole: EquipmentAssociationViewRole, basis: String, drawings: DrawingArchive,
                                           expectedFingerprint: String, author: String, reason: String) throws -> UUID {
        try validateDrawingEvidence(in: drawings)
        let maps = try scheduleMaps()
        guard let map = maps.first(where: { $0.id == mapID }) else { throw LoadSightError.invalid("Save and review the schedule map before linking equipment.") }
        let extraction = try EquipmentScheduleExtractor.extract(drawings, request: map.columnMap())
        guard let row = extraction.rows.first(where: { $0.id == rowID }),
              let occurrence = row.matchingTagOccurrences.first(where: { $0.id == occurrenceID }) else {
            throw LoadSightError.invalid("Schedule row or matching occurrence changed. Read the current map and review the link again.")
        }
        try occurrence.validate(in: drawings)
        try validateAssociationOccurrence(occurrence, maps: maps)
        let records = try equipmentAssociations()
        if relationship == .sameEquipment {
            for other in records where other.id != id && other.relationship == .sameEquipment {
                let old = try other.sourceEvidence()
                try require(old.occurrence.id != occurrenceID,
                            "This occurrence already has a same-equipment link. Revise or remove that link before assigning another schedule row.")
            }
        }
        let encoder = JSONEncoder()
        let snapshot = EquipmentAssociationEvidence(schemaVersion: 1, row: row, occurrence: occurrence)
        let data = try encoder.encode(snapshot)
        try require(data.count <= 16_000_000, "Equipment-link evidence exceeds the 16 MB limit. Review a smaller source set.")
        let identity = id ?? UUID()
        let record = StoredEquipmentAssociation(id: identity, mapID: mapID,
            mapFingerprint: try Self.equipmentAssociationFingerprint(map.request), label: label,
            relationship: relationship, viewRole: viewRole, basis: basis,
            evidence: try JSONDecoder().decode(JSONValue.self, from: data))
        let value = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(record))
        var raw = root["equipmentAssociations"].array ?? []
        if let id {
            guard let index = records.firstIndex(where: { $0.id == id }) else { throw LoadSightError.invalid("The equipment link was removed. Reload the current records.") }
            var object = raw[index].object!
            for (key, field) in value.object! { object[key] = field }
            raw[index] = .object(object)
        } else { raw.append(value) }
        try commitEquipmentAssociations(raw, drawings: drawings, expectedFingerprint: expectedFingerprint, author: author, reason: reason)
        return identity
    }
    mutating func removeEquipmentAssociation(id: UUID, drawings: DrawingArchive, expectedFingerprint: String, author: String, reason: String) throws {
        try validateDrawingEvidence(in: drawings)
        guard let index = try equipmentAssociations().firstIndex(where: { $0.id == id }) else { throw LoadSightError.invalid("Equipment link is missing.") }
        var raw = root["equipmentAssociations"].array!; raw.remove(at: index)
        try commitEquipmentAssociations(raw, drawings: drawings, expectedFingerprint: expectedFingerprint, author: author, reason: reason)
    }
    private func validateAssociationOccurrence(_ occurrence: MechanicalTextCandidate, maps: [StoredScheduleMap]) throws {
        for map in maps {
            for region in try map.columnMap().regions where region.sourceID == occurrence.sourceID && region.pageID == occurrence.pageID {
                try require(!region.bodyBounds.rect.intersects(occurrence.anchor.bounds.rect),
                            "The selected tag anchor intersects a saved schedule body. Choose a plan/detail occurrence and review its full anchor.")
            }
        }
    }
    private mutating func commitEquipmentAssociations(_ raw: [JSONValue], drawings: DrawingArchive, expectedFingerprint: String, author: String, reason: String) throws {
        try require(expectedFingerprint == equipmentAssociationEditFingerprint(), "Equipment links changed. Reopen the current record before saving.")
        let before = root["equipmentAssociations"] == .null ? JSONValue.array([]) : root["equipmentAssociations"]
        let after = JSONValue.array(raw)
        let revision = EquipmentAssociationRevision(author: author, reason: reason, before: before, after: after)
        var object = root.object!, history = root["equipmentAssociationHistory"].array ?? []
        history.append(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(revision)))
        object["equipmentAssociations"] = after; object["equipmentAssociationHistory"] = .array(history)
        object["qa"] = .array(root["qa"].array!.map { value in
            var gate = value.object!; gate["status"] = .string("Open"); gate["reviewer"] = .string(""); gate["date"] = .string(""); gate["reviewFingerprint"] = .null; gate["checklistFingerprint"] = .null
            return .object(gate)
        })
        let candidate = try ProjectDocument(data: JSONEncoder().encode(JSONValue.object(object)))
        try candidate.validateDrawingEvidence(in: drawings)
        self = candidate
    }
}
public extension LocalLoadSightService {
    func reviewEquipmentAssociations(_ project: ProjectDocument, drawings: DrawingArchive) async throws -> [EquipmentAssociationAssessment] {
        try project.equipmentAssociationReview(in: drawings)
    }
}
