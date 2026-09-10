import Foundation

public enum EnvelopeConstruction: String, Codable, CaseIterable, Sendable {
    case woodFramed = "Wood framed"
    case homogeneous = "Homogeneous layers"
}

public struct EnvelopeLayer: Codable, Sendable {
    public let name: String
    public let resistance: Double
    public let source: String
    public let classification: AirInputClassification
    public init(name: String, resistance: Double, source: String, classification: AirInputClassification) {
        self.name = name; self.resistance = resistance; self.source = source; self.classification = classification
    }
}

public struct EnvelopePath: Codable, Sendable {
    public let name: String
    public let fraction: Double
    public let fractionSource: String
    public let fractionClassification: AirInputClassification
    public let layers: [EnvelopeLayer]
    public init(name: String, fraction: Double, fractionSource: String, fractionClassification: AirInputClassification, layers: [EnvelopeLayer]) {
        self.name = name; self.fraction = fraction; self.fractionSource = fractionSource
        self.fractionClassification = fractionClassification; self.layers = layers
    }
}

public struct EnvelopeAssemblyRecord: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let author: String
    public let source: String
    public let recordedAt: String
    public let method: String
    public let construction: EnvelopeConstruction
    public let filmBasis: String
    public let paths: [EnvelopePath]
    public let assumptionsLog: [String]

    public func calculate() throws -> EnvelopeAssemblyResult {
        try require(method == EnvelopeAssemblies.method, "Unsupported envelope method; migrate before recalculating.")
        for value in [id, name, author, source, recordedAt, filmBasis] {
            try require(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Assembly identity, author, source, date and surface-film basis are required.")
        }
        try require(!assumptionsLog.isEmpty, "Assembly assumptions log is required.")
        try require(construction != .homogeneous || paths.count == 1, "Homogeneous construction requires one complete path.")
        for path in paths {
            try require(!path.fractionSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && path.fractionClassification != .rfiRequired, "Each area fraction needs a resolved source and classification.")
            let names = path.layers.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            try require(!names.contains("") && Set(names).count == names.count, "Layers in a path require distinct, nonblank names.")
            for layer in path.layers {
                try require(!layer.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && layer.classification != .rfiRequired, "Each resistance needs a resolved source and classification.")
            }
        }
        return try EnvelopeAssemblies.calculate(paths: paths.map { .init(name: $0.name, fraction: $0.fraction, resistances: $0.layers.map(\.resistance)) })
    }
}

public extension ProjectDocument {
    func envelopeAssemblies() throws -> [EnvelopeAssemblyRecord] {
        let value = root["envelopeAssemblies"]
        if value == .null { return [] }
        let records = try JSONDecoder().decode([EnvelopeAssemblyRecord].self, from: JSONEncoder().encode(value))
        try require(Set(records.map(\.id)).count == records.count, "Duplicate envelope assembly IDs.")
        for record in records { _ = try record.calculate() }
        return records
    }

    @discardableResult
    mutating func saveEnvelopeAssembly(name: String, author: String, source: String, construction: EnvelopeConstruction, filmBasis: String, paths: [EnvelopePath]) throws -> String {
        _ = try envelopeAssemblies()
        let record = EnvelopeAssemblyRecord(id: UUID().uuidString, name: name, author: author, source: source,
            recordedAt: Date().ISO8601Format(), method: EnvelopeAssemblies.method, construction: construction,
            filmBasis: filmBasis, paths: paths, assumptionsLog: EnvelopeAssemblies.assumptions)
        _ = try record.calculate()
        var records = root["envelopeAssemblies"].array ?? []
        records.append(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(record)))
        var candidate = self
        try candidate.replace("envelopeAssemblies", with: .array(records))
        try candidate.replace("qa", with: .array(root["qa"].array!.map { entry in
            var gate = entry.object!; gate["status"] = .string("Open"); gate["reviewer"] = .string(""); gate["date"] = .string("")
            return .object(gate)
        }))
        self = candidate
        return record.id
    }

    func envelopeReview() throws -> JSONValue {
        try validatePortableProject()
        return .object(["status": .string("Assembly worksheet; complete room loads and compliance remain separate"), "assemblies": .array(try envelopeAssemblies().map { record in
            .object(["record": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(record)),
                     "result": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(record.calculate()))])
        })])
    }
}
