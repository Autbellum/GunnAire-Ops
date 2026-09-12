import Foundation
import CryptoKit

public struct AirConditionDerivation: Codable, Sendable {
    public let method: String
    public let processID: String
    public let sourceFingerprint: String
    public let actualCFM: Double
}

struct EvaluatedAirNetwork {
    let conditions: [AirConditionRecord]
    let processes: [AirProcessRecord]
    let results: [String: AirProcessResult]
    let fingerprints: [String: String]
}

extension ProjectDocument {
    /// Iterative topological evaluation rejects cycles without recursive stack growth.
    func airNetwork() throws -> EvaluatedAirNetwork {
        func decode<T: Decodable>(_ type: T.Type, _ key: String) throws -> T {
            try JSONDecoder().decode(type, from: JSONEncoder().encode(root[key] == .null ? .array([]) : root[key]))
        }
        let conditions = try decode([AirConditionRecord].self,"airConditions")
        let processes = try decode([AirProcessRecord].self,"airProcesses")
        try require(Set(conditions.map(\.id)).count == conditions.count, "Duplicate air-condition IDs.")
        try require(Set(processes.map(\.id)).count == processes.count, "Duplicate air-process IDs.")
        let cs = Dictionary(uniqueKeysWithValues: conditions.map { ($0.id,$0) })
        let ps = Dictionary(uniqueKeysWithValues: processes.map { ($0.id,$0) })
        var raw: [String:JSONValue] = [:], dependencies: [String:Set<String>] = [:]
        for (index,c) in conditions.enumerated() {
            let key = "condition:"+c.id
            raw[key] = root["airConditions"].array![index]
            dependencies[key] = c.derivation.map { Set(["process:"+$0.processID]) } ?? []
        }
        for (index,p) in processes.enumerated() {
            let key = "process:"+p.id
            raw[key] = root["airProcesses"].array![index]
            dependencies[key] = Set(["condition:"+p.firstConditionID,"condition:"+p.secondConditionID])
        }
        var dependents: [String:[String]] = [:]
        var remaining: [String:Int] = [:]
        for (key,parents) in dependencies {
            remaining[key] = parents.count
            for parent in parents {
                try require(raw[parent] != nil, "Air network references a missing source: \(parent).")
                dependents[parent, default:[]].append(key)
            }
        }
        var ready = remaining.filter { $0.value == 0 }.map(\.key).sorted(), cursor = 0
        var fingerprints: [String:String] = [:], results: [String:AirProcessResult] = [:]
        while cursor < ready.count {
            let key = ready[cursor]; cursor += 1
            if key.hasPrefix("condition:") {
                let c = cs[String(key.dropFirst(10))]!
                let state = try c.calculate()
                if let d = c.derivation {
                    try require(d.method == "Mixed-air output snapshot v1", "Unsupported air-condition derivation method.")
                    guard case .mixing(let output) = results[d.processID] else { throw LoadSightError.invalid("A derived air condition must reference a mixed-air process.") }
                    try require(d.sourceFingerprint == fingerprints["process:"+d.processID], "Derived condition \(c.name) is stale: its source process or upstream evidence changed.")
                    try require(d.actualCFM.isFinite && abs(d.actualCFM-output.outletActualCFM) <= max(1e-8,abs(output.outletActualCFM)*1e-10), "Derived outlet airflow disagrees with its source process.")
                    try require(abs(state.dryBulbC-output.state.dryBulbC) <= 1e-8 && abs(state.relativeHumidity-output.state.relativeHumidity) <= 1e-10 && abs(state.pressurePa-output.state.pressurePa) <= 1e-8,
                                "Derived condition values disagree with their source process.")
                    try require(c.dryBulbClassification == .engineeringAssumption && c.humidityClassification == .engineeringAssumption && c.pressureClassification == .engineeringAssumption,
                                "Derived conditions must retain their modeled-condition classification.")
                }
            } else {
                let p = ps[String(key.dropFirst(8))]!
                results[p.id] = try p.calculate(conditions: [cs[p.firstConditionID]!,cs[p.secondConditionID]!])
            }
            let fingerprintValue: JSONValue = .object(["record":raw[key]!,"dependencies":.array(dependencies[key]!.sorted().map { .object(["id":.string($0),"fingerprint":.string(fingerprints[$0]!)]) })])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            fingerprints[key] = SHA256.hash(data:try encoder.encode(fingerprintValue)).map { String(format:"%02x",$0) }.joined()
            for child in dependents[key] ?? [] {
                remaining[child]! -= 1
                if remaining[child] == 0 { ready.append(child) }
            }
        }
        try require(cursor == raw.count, "Air network contains a dependency cycle; conditions cannot depend on their own downstream process.")
        return .init(conditions:conditions,processes:processes,results:results,fingerprints:fingerprints)
    }
}

public extension ProjectDocument {
    /// Freeze a verified mixing output as a reusable, source-linked condition. No manual rounding.
    @discardableResult
    mutating func saveMixedAirOutput(processID: String, name: String, author: String, source: String) throws -> String {
        let network = try airNetwork()
        guard case .mixing(let output) = network.results[processID], let fingerprint = network.fingerprints["process:"+processID] else {
            throw LoadSightError.invalid("Select an existing mixed-air process to derive its output condition.")
        }
        for text in [name,author,source] { try require(!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,"Derived conditions require name, author and source/use basis.") }
        let state = output.state
        let record = AirConditionRecord(id:UUID().uuidString,name:name,author:author,source:source,recordedAt:Date().ISO8601Format(),method:Psychrometrics.method,
            dryBulbC:state.dryBulbC,relativeHumidity:state.relativeHumidity,humidityInput:.init(kind:.relativeHumidity,value:state.relativeHumidity),
            derivation:.init(method:"Mixed-air output snapshot v1",processID:processID,sourceFingerprint:fingerprint,actualCFM:output.outletActualCFM),
            pressurePa:state.pressurePa,dryBulbClassification:.engineeringAssumption,humidityClassification:.engineeringAssumption,pressureClassification:.engineeringAssumption,
            assumptionsLog:["Calculated output of saved mixed-air process \(processID); not an independently measured condition.","Source fingerprint binds process inputs and all upstream evidence.","Actual outlet CFM applies to the full mixed stream. A downstream branch may require its own flow basis."])
        var rows = root["airConditions"].array ?? []
        rows.append(try JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(record)))
        var candidate = self
        try candidate.replace("airConditions",with:.array(rows))
        try candidate.replace("qa",with:.array(root["qa"].array!.map { entry in
            var gate=entry.object!; gate["status"] = .string("Open"); gate["reviewer"] = .string(""); gate["date"] = .string(""); return .object(gate)
        }))
        _ = try candidate.airNetwork()
        self = candidate
        return record.id
    }
}
