import Foundation
import LoadSightCore

public struct CalculationTrace: Codable, Equatable, Sendable {
    public let equation: String
    public let substitution: String
    public let value: Double
    public let unit: String
    public let assumptions: [String]
    public let evidence: [Evidence]
    public init(equation: String, substitution: String, value: Double, unit: String,
                assumptions: [String] = [], evidence: [Evidence] = []) throws {
        try require(value.isFinite, "Calculation overflow or invalid result.")
        self.equation = equation; self.substitution = substitution; self.value = value
        self.unit = unit; self.assumptions = assumptions; self.evidence = evidence
    }
}

/// Elementary engineering arithmetic. Does not claim a complete ACCA or code method.
public enum MechanicalMath {
    public static func envelope(u: Double, areaSF: Double, deltaF: Double, evidence: [Evidence] = []) throws -> CalculationTrace {
        try nonnegative(u, areaSF); try require(deltaF.isFinite, "Temperature difference must be finite.")
        return try .init(equation: "Q = U × A × ΔT", substitution: "\(u) × \(areaSF) × \(deltaF)", value: u * areaSF * deltaF, unit: "Btuh", evidence: evidence)
    }
    public static func assemblyU(resistances: [Double]) throws -> CalculationTrace {
        try require(!resistances.isEmpty && resistances.allSatisfy { $0.isFinite && $0 > 0 }, "Each assembly resistance must be positive.")
        let sum = resistances.reduce(0, +)
        try require(sum.isFinite, "Assembly resistance overflow.")
        return try .init(equation: "U = 1 / ΣR", substitution: "1 / \(sum)", value: 1 / sum, unit: "Btuh/(ft²·°F)")
    }
    public static func sensibleAir(cfm: Double, deltaF: Double, density: Double = 0.075, specificHeat: Double = 0.24) throws -> CalculationTrace {
        try nonnegative(cfm); try require(deltaF.isFinite && density.isFinite && density > 0 && specificHeat.isFinite && specificHeat > 0, "Invalid air properties or temperature difference.")
        return try .init(equation: "Qs = 60 × ρ × cp × CFM × ΔT", substitution: "60 × \(density) × \(specificHeat) × \(cfm) × \(deltaF)", value: 60 * density * specificHeat * cfm * deltaF, unit: "Btuh", assumptions: ["Density \(density) lb/ft³; specific heat \(specificHeat) Btu/(lb·°F). Confirm air conditions."])
    }
    public static func latentAir(cfm: Double, deltaGrains: Double) throws -> CalculationTrace {
        try nonnegative(cfm); try require(deltaGrains.isFinite, "Humidity difference must be finite.")
        return try .init(equation: "Ql ≈ 0.68 × CFM × Δgrains", substitution: "0.68 × \(cfm) × \(deltaGrains)", value: 0.68 * cfm * deltaGrains, unit: "Btuh", assumptions: ["Standard-air approximation; humidity difference in grains/lb dry air, not lb/lb."])
    }
    public static func totalAir(cfm: Double, deltaEnthalpy: Double, dryAirDensity: Double = 0.075) throws -> CalculationTrace {
        try nonnegative(cfm); try require(deltaEnthalpy.isFinite && dryAirDensity.isFinite && dryAirDensity > 0, "Invalid enthalpy or density.")
        return try .init(equation: "Qt = 60 × ρda × CFM × Δh", substitution: "60 × \(dryAirDensity) × \(cfm) × \(deltaEnthalpy)", value: 60 * dryAirDensity * cfm * deltaEnthalpy, unit: "Btuh", assumptions: ["Enthalpy in Btu/lb dry air; density \(dryAirDensity) lb dry air/ft³."])
    }
    public static func sensibleHeatRatio(sensible: Double, total: Double) throws -> CalculationTrace {
        try nonnegative(sensible); try require(total.isFinite && total > 0 && sensible <= total, "SHR requires 0 ≤ sensible ≤ total and total > 0.")
        return try .init(equation: "SHR = Qs / Qt", substitution: "\(sensible) / \(total)", value: sensible / total, unit: "ratio")
    }
    public static func infiltration(ach: Double, volumeCF: Double) throws -> CalculationTrace {
        try nonnegative(ach, volumeCF)
        return try .init(equation: "CFM = ACH × V / 60", substitution: "\(ach) × \(volumeCF) / 60", value: ach * volumeCF / 60, unit: "CFM", assumptions: ["ACH must describe the design condition; blower-door ACH50 is not natural ACH."])
    }
    public static func zoneOutdoorAir(people: Double, areaSF: Double, cfmPerPerson: Double, cfmPerSF: Double, effectiveness: Double, source: Evidence) throws -> CalculationTrace {
        try nonnegative(people, areaSF, cfmPerPerson, cfmPerSF)
        try require(effectiveness.isFinite && effectiveness > 0, "Zone effectiveness must be positive.")
        return try .init(equation: "Vbz = Rp × Pz + Ra × Az; Voz = Vbz / Ez", substitution: "(\(cfmPerPerson) × \(people) + \(cfmPerSF) × \(areaSF)) / \(effectiveness)", value: (cfmPerPerson * people + cfmPerSF * areaSF) / effectiveness, unit: "CFM", assumptions: ["Caller supplies applicable occupancy rates and Ez; multizone system efficiency is separate."], evidence: [source])
    }
    public static func waterFlow(btuh: Double, deltaF: Double, density: Double = 8.33, specificHeat: Double = 1) throws -> CalculationTrace {
        try nonnegative(btuh)
        try require([deltaF, density, specificHeat].allSatisfy { $0.isFinite && $0 > 0 }, "Water ΔT and fluid properties must be positive.")
        return try .init(equation: "GPM = Q / (60 × ρ × cp × ΔT)", substitution: "\(btuh) / (60 × \(density) × \(specificHeat) × \(deltaF))", value: btuh / (60 * density * specificHeat * deltaF), unit: "GPM", assumptions: ["Density in lb/gal; use actual glycol properties where applicable."])
    }
    public static func gasDemand(inputBtuh: Double, heatingValueBtuPerCF: Double) throws -> CalculationTrace {
        try nonnegative(inputBtuh); try require(heatingValueBtuPerCF.isFinite && heatingValueBtuPerCF > 0, "Fuel heating value must be positive.")
        return try .init(equation: "CFH = fuel input / heating value", substitution: "\(inputBtuh) / \(heatingValueBtuPerCF)", value: inputBtuh / heatingValueBtuPerCF, unit: "CFH", assumptions: ["Use nameplate fuel INPUT, not delivered heat or AFUE. This is demand arithmetic, not gas pipe sizing."])
    }
    /// Coincident block load, preserving each timestamp; never sum room peaks as block load.
    public static func blockLoad(spaceProfiles: [[Double]]) throws -> CalculationTrace {
        guard let count = spaceProfiles.first?.count, count > 0 else { throw LoadSightError.invalid("Hourly profiles are required.") }
        try require(spaceProfiles.allSatisfy { $0.count == count && $0.allSatisfy { $0.isFinite && $0 >= 0 } }, "Space profiles must have aligned nonnegative samples.")
        let totals = (0..<count).map { hour in spaceProfiles.reduce(0) { $0 + $1[hour] } }
        let peak = totals.max()!
        return try .init(equation: "Qblock = max_t Σspace Q(space,t)", substitution: "max(\(totals.map(String.init(describing:)).joined(separator: ", ")))", value: peak, unit: "Btuh", assumptions: ["Samples share design day, time zone, and interval; supplied profiles define the calculation method."])
    }
}
