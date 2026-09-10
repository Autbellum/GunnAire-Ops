import Foundation

public struct SourcedEngineeringValue: Codable, Sendable {
    public let value: Double
    public let source: String
    public let classification: AirInputClassification
    public init(value: Double, source: String, classification: AirInputClassification) {
        self.value = value; self.source = source; self.classification = classification
    }
    public func validate(_ label: String) throws {
        try require(value.isFinite, "\(label) must be finite.")
        try require(!source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && classification != .rfiRequired, "\(label) needs a resolved source and classification.")
    }
}

public struct SurfaceOpening: Codable, Sendable {
    public let name: String
    public let areaSF: SourcedEngineeringValue
    public let wholeProductU: SourcedEngineeringValue?
    public init(name: String, areaSF: SourcedEngineeringValue, wholeProductU: SourcedEngineeringValue? = nil) {
        self.name = name; self.areaSF = areaSF; self.wholeProductU = wholeProductU
    }
}

public struct RoomEnvelopeSurface: Codable, Sendable {
    public let name: String
    public let assemblyID: String
    public let grossAreaSF: SourcedEngineeringValue
    public let openings: [SurfaceOpening]
    public let adjacentDesignF: SourcedEngineeringValue
    public init(name: String, assemblyID: String, grossAreaSF: SourcedEngineeringValue, openings: [SurfaceOpening], adjacentDesignF: SourcedEngineeringValue) {
        self.name = name; self.assemblyID = assemblyID; self.grossAreaSF = grossAreaSF
        self.openings = openings; self.adjacentDesignF = adjacentDesignF
    }
}

public struct SurfaceTransmissionResult: Codable, Sendable {
    public let name: String
    public let assemblyID: String
    public let netOpaqueAreaSF: Double
    public let uFactor: Double
    public let deltaF: Double
    public let outwardBtuh: Double
    public let traces: [CalculationTrace]
}

public struct RoomTransmissionResult: Codable, Sendable {
    public let surfaces: [SurfaceTransmissionResult]
    public let outwardLossBtuh: Double
    public let inwardGainBtuh: Double
    public let netOutwardBtuh: Double
    public let traces: [CalculationTrace]
    public let excludedComponents: [String]
    public let openingTransmission: OpeningTransmissionSummary?
}

public struct RoomTransmissionRecord: Codable, Identifiable, Sendable {
    public static let legacyMethod = "Room opaque steady-state transmission; IP v1"
    public static let method = "Room opaque and opening steady-state transmission; IP v2"
    public static let exclusions = ["Window and door heat transfer", "Slab / ground-coupled transfer", "Infiltration and ventilation", "Duct and distribution losses", "Internal and solar gains", "Transient effects and complete heating/cooling design load"]
    public let id: String
    public let name: String
    public let author: String
    public let source: String
    public let recordedAt: String
    public let method: String
    public let indoorDesignF: SourcedEngineeringValue
    public let surfaces: [RoomEnvelopeSurface]
    public let assumptionsLog: [String]

    public func calculate(assemblies: [EnvelopeAssemblyRecord]) throws -> RoomTransmissionResult {
        try require([Self.method,Self.legacyMethod].contains(method), "Unsupported room transmission method.")
        try require(method != Self.legacyMethod || surfaces.allSatisfy { $0.openings.allSatisfy { $0.wholeProductU == nil } }, "Opening U-factors require the v2 room transmission method.")
        for text in [id,name,author,source,recordedAt] { try require(!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,"Room identity, name, author, source and date are required.") }
        try require(!assumptionsLog.isEmpty, "Room transmission assumptions are required.")
        try indoorDesignF.validate("Indoor design temperature")
        try require(indoorDesignF.value > -459.67, "Indoor temperature must exceed absolute zero.")
        try require(!surfaces.isEmpty && surfaces.count <= 1000, "Provide 1–1000 opaque surfaces.")
        func uniqueNames(_ names: [String], _ label: String) throws {
            let normalized = names.map { $0.trimmingCharacters(in:.whitespacesAndNewlines).lowercased() }
            try require(!normalized.contains("") && Set(normalized).count == normalized.count, "\(label) names must be nonblank and distinct.")
        }
        try uniqueNames(surfaces.map(\.name), "Surface")
        try require(Set(assemblies.map(\.id)).count == assemblies.count, "Duplicate assembly IDs.")
        let lookup = Dictionary(uniqueKeysWithValues: assemblies.map { ($0.id,$0) })
        let results: [SurfaceTransmissionResult] = try surfaces.map { surface in
            guard let assembly = lookup[surface.assemblyID] else { throw LoadSightError.invalid("\(surface.name) references a missing assembly.") }
            try surface.grossAreaSF.validate("\(surface.name) gross area")
            try require(surface.grossAreaSF.value > 0, "Gross surface area must be positive.")
            try surface.adjacentDesignF.validate("\(surface.name) adjacent design temperature")
            try require(surface.adjacentDesignF.value > -459.67, "Adjacent temperature must exceed absolute zero.")
            try require(surface.openings.count <= 1000, "A surface may contain at most 1000 openings.")
            try uniqueNames(surface.openings.map(\.name), "Opening")
            for opening in surface.openings {
                try opening.areaSF.validate("\(opening.name) opening area")
                try require(opening.areaSF.value > 0, "Opening area must be positive.")
            }
            let excluded = surface.openings.reduce(0) { $0 + $1.areaSF.value }
            let net = surface.grossAreaSF.value - excluded
            try require(excluded.isFinite && net.isFinite && net > 0, "Openings must leave positive opaque area; check gross area and duplicate openings.")
            let u = try assembly.calculate().uFactor
            let delta = indoorDesignF.value - surface.adjacentDesignF.value
            let q = try MechanicalMath.envelope(u:u,areaSF:net,deltaF:delta)
            let traces: [CalculationTrace] = [
                try .init(equation:"Anet = Agross − ΣAopening",substitution:"\(surface.grossAreaSF.value) − (\((surface.openings.isEmpty ? "0" : surface.openings.map { String($0.areaSF.value) }.joined(separator:" + "))))",value:net,unit:"ft²",assumptions:["An empty opening list explicitly declares no openings for this surface."]),
                try .init(equation:"ΔT = Troom − Tadjacent",substitution:"\(indoorDesignF.value) − \(surface.adjacentDesignF.value)",value:delta,unit:"°F"),
                try .init(equation:q.equation,substitution:q.substitution,value:q.value,unit:q.unit,assumptions:["U recomputed from assembly \(assembly.id) (\(assembly.name)). Positive is outward loss; negative is inward gain."])
            ]
            return .init(name:surface.name,assemblyID:assembly.id,netOpaqueAreaSF:net,uFactor:u,deltaF:delta,outwardBtuh:q.value,traces:traces)
        }
        let loss = results.reduce(0) { $0 + max(0,$1.outwardBtuh) }, gain = results.reduce(0) { $0 + max(0,-$1.outwardBtuh) }
        let net = loss - gain
        let traces: [CalculationTrace] = [
            try .init(equation:"Qoutward = Σmax(Qsurface, 0)",substitution:results.map { String(max(0,$0.outwardBtuh)) }.joined(separator:" + "),value:loss,unit:"Btuh"),
            try .init(equation:"Qinward = Σmax(−Qsurface, 0)",substitution:results.map { String(max(0,-$0.outwardBtuh)) }.joined(separator:" + "),value:gain,unit:"Btuh"),
            try .init(equation:"Qnet outward = Qoutward − Qinward",substitution:"\(loss) − \(gain)",value:net,unit:"Btuh",assumptions:["Signed steady-state balance only. No automatic gain credit or equipment sizing is authorized by this subtotal."])
        ]
        let openings = try OpeningTransmissionSummary.calculate(surfaces:surfaces,indoorDesignF:indoorDesignF.value,opaqueLoss:loss,opaqueGain:gain)
        let exclusions = openings.allListedOpeningsRated ? Array(Self.exclusions.dropFirst()) : Self.exclusions
        return .init(surfaces:results,outwardLossBtuh:loss,inwardGainBtuh:gain,netOutwardBtuh:net,traces:traces,excludedComponents:exclusions,openingTransmission:openings)
    }
}

public extension ProjectDocument {
    func roomTransmissions() throws -> [RoomTransmissionRecord] {
        _ = try roomTransmissionHistory()
        if root["roomTransmissions"] == .null { return [] }
        let records = try JSONDecoder().decode([RoomTransmissionRecord].self,from:JSONEncoder().encode(root["roomTransmissions"]))
        try require(Set(records.map(\.id)).count == records.count,"Duplicate room transmission IDs.")
        let assemblies = try envelopeAssemblies()
        for record in records { _ = try record.calculate(assemblies:assemblies) }
        return records
    }
    @discardableResult
    mutating func saveRoomTransmission(name: String, author: String, source: String, indoorDesignF: SourcedEngineeringValue, surfaces: [RoomEnvelopeSurface]) throws -> String {
        _ = try roomTransmissions()
        let record = RoomTransmissionRecord(id:UUID().uuidString,name:name,author:author,source:source,recordedAt:Date().ISO8601Format(),method:RoomTransmissionRecord.method,indoorDesignF:indoorDesignF,surfaces:surfaces,assumptionsLog:[
            "Above-grade steady-state transmission through opaque surfaces and rated openings; all source geometry and boundary temperatures require review.",
            "Gross area includes the listed openings. Openings are deducted from opaque area and their transmission is calculated separately only when whole-product U is supplied.",
            "Whole-product U in Btuh/(ft²·°F) includes frame/glazing or complete door assembly. Record the rating reference/configuration; do not substitute center-of-glass or slab-only values.",
            "Every listed opening needs a sourced rating before a combined envelope subtotal is available. No U-factor, film correction or solar gain is inferred.",
            "Assembly IDs refer to current source-backed inputs and are recomputed on review; no cached U or load is authoritative.",
            "Adjacent design temperatures must be coincident with the stated room design case; no climate/default setpoint is inferred.",
            "Other load components are unmodeled, not zero; this is not a complete Manual J/N result or equipment selection."])
        _ = try record.calculate(assemblies:envelopeAssemblies())
        var rows = root["roomTransmissions"].array ?? []
        rows.append(try JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(record)))
        var candidate = self
        try candidate.replace("roomTransmissions",with:.array(rows))
        try candidate.replace("qa",with:.array(root["qa"].array!.map { entry in
            var gate = entry.object!; gate["status"] = .string("Open"); gate["reviewer"] = .string(""); gate["date"] = .string("")
            return .object(gate)
        }))
        self = candidate
        return record.id
    }
    func roomTransmissionReview() throws -> JSONValue {
        try validatePortableProject()
        let assemblies = try envelopeAssemblies()
        let rooms = try roomTransmissions()
        let used = Set(rooms.flatMap { $0.surfaces.map(\.assemblyID) })
        let supporting: [JSONValue] = try assemblies.filter { used.contains($0.id) }.map { assembly in
            .object(["record":try JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(assembly)),"result":try JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(assembly.calculate()))])
        }
        let historyRows: [JSONValue] = try roomTransmissionHistory().map { revision in
            var row = root["roomTransmissionHistory"].array!.first(where:{$0["id"].string == revision.id})!.object!
            row["beforeResult"] = try JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(revision.result(before:true)))
            row["afterResult"] = try JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(revision.result(before:false)))
            return .object(row)
        }
        return .object(["status":.string("Partial room transmission; combined envelope subtotals require all listed opening ratings; other loads remain unmodeled"),"assemblies":.array(supporting),"history":.array(historyRows),"rooms":.array(try rooms.map { room in
            .object(["editFingerprint":.string(try roomTransmissionEditFingerprint(id:room.id)),"record":try JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(room)),"result":try JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(room.calculate(assemblies:assemblies)))])
        })])
    }
}
