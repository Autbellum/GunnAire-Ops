import Foundation

public enum AirInputClassification: String, Codable, CaseIterable, Sendable {
    case extracted = "EXTRACTED", userProvided = "USER-PROVIDED", codeDefault = "CODE-DEFAULT", engineeringAssumption = "ENGINEERING-ASSUMPTION", rfiRequired = "RFI-REQUIRED"
}

public struct AirConditionRecord: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let author: String
    public let source: String
    public let recordedAt: String
    public let method: String
    public let dryBulbC: Double
    public let relativeHumidity: Double
    public let humidityInput: HumidityInput?
    public let derivation: AirConditionDerivation?
    public let pressurePa: Double
    public let dryBulbClassification: AirInputClassification
    public let humidityClassification: AirInputClassification
    public let pressureClassification: AirInputClassification
    public let assumptionsLog: [String]
    public func inputTrace() throws -> CalculationTrace {
        if let derivation {
            return try .init(equation:"State = validated mixed-air process output",substitution:"Process " + derivation.processID + "; source fingerprint " + derivation.sourceFingerprint,
                value:relativeHumidity,unit:"derived RH fraction",assumptions:["Calculated model output; follow the source process for mixing balance traces."])
        }
        return try Psychrometrics.humidityInputTrace(dryBulbC:dryBulbC,humidity:humidityInput ?? .init(kind:.relativeHumidity,value:relativeHumidity),pressurePa:pressurePa)
    }
    public func calculate() throws -> MoistAirState {
        try require(![dryBulbClassification, humidityClassification, pressureClassification].contains(.rfiRequired), "Resolve missing-condition RFIs before saving a calculated design state.")
        try require(!assumptionsLog.isEmpty, "Saved air conditions require their assumptions log.")
        try require(method == Psychrometrics.method, "Unsupported saved air-state method; migrate before recalculating.")
        for text in [id, name, author, source, recordedAt] { try require(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Saved air conditions require identity, name, author, source and date.") }
        let state = try Psychrometrics.state(dryBulbC: dryBulbC, humidity: humidityInput ?? .init(kind: .relativeHumidity, value: relativeHumidity), pressurePa: pressurePa)
        try require(relativeHumidity.isFinite && abs(state.relativeHumidity-relativeHumidity) <= 1e-10, "Saved humidity input disagrees with its derived relative humidity.")
        return state
    }
}

public extension ProjectDocument {
    func airConditions() throws -> [AirConditionRecord] {
        try airNetwork().conditions
    }

    /// Append a source-backed condition. Calculated values are recomputed, never trusted from JSON.
    mutating func saveAirCondition(name: String, author: String, source: String, dryBulbC: Double, relativeHumidity: Double, pressurePa: Double,
                                   dryBulbClassification: AirInputClassification = .userProvided,
                                   humidityClassification: AirInputClassification = .userProvided,
                                   pressureClassification: AirInputClassification = .userProvided) throws {
        try saveAirCondition(name: name, author: author, source: source, dryBulbC: dryBulbC,
            humidity: .init(kind: .relativeHumidity, value: relativeHumidity), pressurePa: pressurePa,
            dryBulbClassification: dryBulbClassification, humidityClassification: humidityClassification, pressureClassification: pressureClassification)
    }
    mutating func saveAirCondition(name: String, author: String, source: String, dryBulbC: Double, humidity: HumidityInput, pressurePa: Double,
                                   dryBulbClassification: AirInputClassification = .userProvided,
                                   humidityClassification: AirInputClassification = .userProvided,
                                   pressureClassification: AirInputClassification = .userProvided) throws {
        let state = try Psychrometrics.state(dryBulbC: dryBulbC, humidity: humidity, pressurePa: pressurePa)
        _ = try airConditions()
        var records = root["airConditions"].array ?? []
        let record = AirConditionRecord(id: UUID().uuidString, name: name, author: author, source: source,
                                        recordedAt: Date().ISO8601Format(), method: Psychrometrics.method,
                                        dryBulbC: dryBulbC, relativeHumidity: state.relativeHumidity, humidityInput: humidity, derivation: nil, pressurePa: pressurePa,
                                        dryBulbClassification: dryBulbClassification, humidityClassification: humidityClassification,
                                        pressureClassification: pressureClassification, assumptionsLog: [
                                            "Pressure is absolute station pressure at the condition location.",
                                            "Ideal-gas moist air; properties use dry-air mass basis.",
                                            "Below freezing, saturation follows ice; wet bulb uses the applicable ice/water branch.",
                                            "No jurisdiction, climate, geometry, occupancy, safety factor or load method is inferred by this air-state worksheet."])
        _ = try record.calculate(); records.append(try JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(record)))
        var candidate = self
        try candidate.replace("airConditions", with: .array(records))
        try candidate.replace("qa", with: .array(root["qa"].array!.map { entry in
            var gate = entry.object!; gate["status"] = .string("Open"); gate["reviewer"] = .string(""); gate["date"] = .string("")
            return .object(gate)
        }))
        self = candidate
    }
}
