import Foundation

public enum AirProcessKind: String, Codable, CaseIterable, Sendable { case mixing = "Mixed air", coolingCoil = "Cooling coil" }
public enum AirProcessResult: Sendable { case mixing(AirMixResult), coolingCoil(CoolingCoilResult) }
public struct AirProcessRecord: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let author: String
    public let source: String
    public let recordedAt: String
    public let method: String
    public let kind: AirProcessKind
    public let firstConditionID: String
    public let secondConditionID: String
    public let firstActualCFM: Double
    public let secondActualCFM: Double?
    public let flowClassification: AirInputClassification

    public func calculate(conditions: [AirConditionRecord]) throws -> AirProcessResult {
        for text in [id,name,author,source,recordedAt] { try require(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Air processes require name, author, source and date.") }
        try require(method == AirProcesses.method, "Unsupported saved air-process method.")
        try require(flowClassification != .rfiRequired, "Resolve airflow information before saving a process calculation.")
        guard let first = conditions.first(where: { $0.id == firstConditionID }), let second = conditions.first(where: { $0.id == secondConditionID }) else { throw LoadSightError.invalid("A saved air process references a missing condition.") }
        let a = try first.calculate(), b = try second.calculate()
        switch kind {
        case .mixing:
            guard let secondActualCFM else { throw LoadSightError.invalid("Mixing requires an actual airflow for each stream.") }
            return .mixing(try AirProcesses.mix(first: a, firstActualCFM: firstActualCFM, second: b, secondActualCFM: secondActualCFM))
        case .coolingCoil:
            try require(secondActualCFM == nil, "Cooling airflow must be specified at the inlet only.")
            return .coolingCoil(try AirProcesses.coolingCoil(inlet: a, outlet: b, inletActualCFM: firstActualCFM))
        }
    }
}
public extension ProjectDocument {
    func airProcessReview() throws -> JSONValue {
        try validatePortableProject()
        func json<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) }
        let network = try airNetwork()
        let conditionResults = try zip(network.conditions, root["airConditions"].array ?? []).map { row, raw in
            JSONValue.object(["record": raw, "state": try json(row.calculate()), "inputTrace": try json(row.inputTrace())])
        }
        let processes = try zip(network.processes, root["airProcesses"].array ?? []).map { row, raw -> JSONValue in
            let value: JSONValue
            switch network.results[row.id]! {
            case .mixing(let output): value = try json(output)
            case .coolingCoil(let output): value = try json(output)
            }
            return .object(["record": raw, "result": value])
        }
        return .object(["status": .string("Engineering worksheet; not equipment selection or a complete building load"), "conditions": .array(conditionResults), "processes": .array(processes)])
    }
    func airProcesses() throws -> [AirProcessRecord] {
        try airNetwork().processes
    }
    mutating func saveAirProcess(name: String, author: String, source: String, kind: AirProcessKind,
                                firstConditionID: String, secondConditionID: String, firstActualCFM: Double,
                                secondActualCFM: Double?, flowClassification: AirInputClassification) throws {
        _ = try airProcesses()
        var rows = root["airProcesses"].array ?? []
        let row = AirProcessRecord(id: UUID().uuidString, name: name, author: author, source: source, recordedAt: Date().ISO8601Format(), method: AirProcesses.method,
                                   kind: kind, firstConditionID: firstConditionID, secondConditionID: secondConditionID,
                                   firstActualCFM: firstActualCFM, secondActualCFM: secondActualCFM, flowClassification: flowClassification)
        _ = try row.calculate(conditions: airConditions()); rows.append(try JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(row)))
        var candidate = self
        try candidate.replace("airProcesses", with: .array(rows))
        try candidate.replace("qa", with: .array(root["qa"].array!.map { entry in
            var gate = entry.object!; gate["status"] = .string("Open"); gate["reviewer"] = .string(""); gate["date"] = .string(""); return .object(gate)
        }))
        self = candidate
    }
}
