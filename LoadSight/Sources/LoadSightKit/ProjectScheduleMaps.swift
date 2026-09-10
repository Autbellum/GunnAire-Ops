import Foundation

public extension StoredScheduleMap {
    func columnMap() throws -> EquipmentScheduleRequest { try EquipmentScheduleRequest.decode(JSONEncoder().encode(request)) }
}
public extension ProjectDocument {
    func validateScheduleMaps(in drawings: DrawingArchive) throws {
        _ = try scheduleMapHistory()
        for map in try scheduleMaps() { try EquipmentScheduleExtractor.validate(map.columnMap(), in: drawings) }
        for revision in try scheduleMapHistory() {
            for map in try Self.decodeScheduleMaps(revision.before) + Self.decodeScheduleMaps(revision.after) {
                _ = try map.columnMap() // Historical source files can be absent, but malformed request schemas cannot pass.
            }
        }
    }
    @discardableResult
    mutating func saveScheduleMap(id: UUID? = nil, name: String, request: EquipmentScheduleRequest, drawings: DrawingArchive,
                                  expectedFingerprint: String, author: String, reason: String) throws -> UUID {
        try validateDrawingEvidence(in: drawings)
        try EquipmentScheduleExtractor.validate(request, in: drawings)
        let raw = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(request))
        let identity = id ?? UUID(), map = StoredScheduleMap(id: identity, name: name, request: raw)
        var maps = root["scheduleMaps"].array ?? []
        if let id {
            guard let index = try scheduleMaps().firstIndex(where: { $0.id == id }) else { throw LoadSightError.invalid("Saved schedule map is missing. Reload the current project.") }
            var object = maps[index].object! // Preserve future record metadata outside the replaced map/name.
            object["name"] = .string(name); object["request"] = raw; maps[index] = .object(object)
        } else { maps.append(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(map))) }
        try commitScheduleMaps(maps, drawings: drawings, expectedFingerprint: expectedFingerprint, author: author, reason: reason)
        return identity
    }
    mutating func removeScheduleMap(id: UUID, drawings: DrawingArchive, expectedFingerprint: String, author: String, reason: String) throws {
        try validateDrawingEvidence(in: drawings)
        let maps = try scheduleMaps()
        guard let index = maps.firstIndex(where: { $0.id == id }) else { throw LoadSightError.invalid("Saved schedule map is missing.") }
        var raw = root["scheduleMaps"].array!; raw.remove(at: index)
        try commitScheduleMaps(raw, drawings: drawings, expectedFingerprint: expectedFingerprint, author: author, reason: reason)
    }
    private mutating func commitScheduleMaps(_ maps: [JSONValue], drawings: DrawingArchive, expectedFingerprint: String, author: String, reason: String) throws {
        try require(expectedFingerprint == scheduleMapEditFingerprint(), "Schedule maps changed. Reopen the current map before saving; your edits were not applied.")
        let before = root["scheduleMaps"] == .null ? JSONValue.array([]) : root["scheduleMaps"], after = JSONValue.array(maps)
        let revision = ScheduleMapRevision(author: author, reason: reason, before: before, after: after)
        var object = root.object!, history = root["scheduleMapHistory"].array ?? []
        history.append(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(revision)))
        object["scheduleMaps"] = after; object["scheduleMapHistory"] = .array(history)
        object["qa"] = .array(root["qa"].array!.map { value in
            var gate = value.object!; gate["status"] = .string("Open"); gate["reviewer"] = .string(""); gate["date"] = .string(""); gate["reviewFingerprint"] = .null; gate["checklistFingerprint"] = .null
            return .object(gate)
        })
        let candidate = try ProjectDocument(data: JSONEncoder().encode(JSONValue.object(object)))
        try candidate.validateDrawingEvidence(in: drawings)
        self = candidate
    }
}
