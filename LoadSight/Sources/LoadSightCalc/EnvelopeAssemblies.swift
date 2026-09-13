import Foundation
import LoadSightCore

public struct ThermalPath: Codable, Sendable {
    public let name: String
    public let fraction: Double
    public let resistances: [Double]
    public init(name: String, fraction: Double, resistances: [Double]) {
        self.name = name; self.fraction = fraction; self.resistances = resistances
    }
}

public struct EnvelopeAssemblyResult: Codable, Sendable {
    public let uFactor: Double
    public let effectiveR: Double
    public let traces: [CalculationTrace]
}

/// Independent, steady-state parallel paths. No lateral heat spreading or metal framing model.
public enum EnvelopeAssemblies {
    public static let method = "Independent parallel heat paths; IP resistance v1"
    public static let assumptions = [
        "Steady-state independent paths with common indoor/outdoor temperatures; no lateral heat spreading.",
        "Layer R-values are in h·ft²·°F/Btu. Each path must include its complete layer stack and stated surface-film basis.",
        "Fractions describe mutually exclusive areas covering the assembly and must sum to 1 within 1e-9; values are not normalized.",
        "No default films, material resistances, framing fractions, thermal-bridge corrections or safety factors are added.",
        "Not applicable to metal framing, ground-coupled surfaces or assemblies requiring multidimensional thermal-bridge analysis.",
        "This assembly worksheet is not a complete ACCA load calculation or code compliance determination."
    ]
    public static func calculate(paths: [ThermalPath]) throws -> EnvelopeAssemblyResult {
        try require(!paths.isEmpty && paths.count <= 100, "Provide 1–100 heat-flow paths.")
        let names = paths.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        try require(!names.contains("") && Set(names).count == names.count, "Heat-flow paths require distinct names.")
        try require(paths.allSatisfy { $0.fraction.isFinite && $0.fraction > 0 && $0.fraction <= 1 }, "Each path fraction must be greater than zero and at most one.")
        let total = paths.reduce(0) { $0 + $1.fraction }
        try require(abs(total - 1) <= 1e-9, "Path fractions must sum to 1; entered total is \(total).")
        var traces: [CalculationTrace] = []
        var contributions: [Double] = []
        for path in paths {
            try require(path.resistances.count <= 100, "A path may contain at most 100 layers.")
            let trace = try MechanicalMath.assemblyU(resistances: path.resistances)
            try require(trace.value > 0, "Path conductance underflow.")
            traces.append(try .init(equation: "\(path.name): Upath = 1 / ΣRlayer",
                substitution: "1 / (" + path.resistances.map { String($0) }.joined(separator: " + ") + ")",
                value: trace.value, unit: trace.unit))
            let contribution = path.fraction * trace.value
            try require(contribution.isFinite && contribution > 0, "Path contribution overflow or underflow.")
            contributions.append(contribution)
            traces.append(try .init(equation: "\(path.name): contribution = area fraction × Upath",
                substitution: "\(path.fraction) × \(trace.value)", value: contribution, unit: trace.unit))
        }
        let u = contributions.reduce(0, +)
        traces.append(try .init(equation: "Uassembly = Σ(fraction × Upath)", substitution: contributions.map { String($0) }.joined(separator: " + "), value: u, unit: "Btuh/(ft²·°F)", assumptions: assumptions))
        let r = 1 / u
        traces.append(try .init(equation: "Reffective = 1 / Uassembly", substitution: "1 / \(u)", value: r, unit: "h·ft²·°F/Btu"))
        return .init(uFactor: u, effectiveR: r, traces: traces)
    }
}
