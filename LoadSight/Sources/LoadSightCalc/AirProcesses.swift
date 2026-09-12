import Foundation
import LoadSightCore

public struct AirMixResult: Codable, Sendable {
    public let state: MoistAirState
    public let dryAirMassKgPerSecond: Double
    public let outletActualCFM: Double
    public let traces: [CalculationTrace]
}
public struct CoolingCoilResult: Codable, Sendable {
    public let apparatusDewPoint: CoilADPAnalysis?
    public let totalKW: Double
    public let sensibleKW: Double
    public let latentKW: Double
    public let condensateKgPerHour: Double
    public let sensibleHeatRatio: Double?
    public let dryAirMassKgPerSecond: Double
    public let traces: [CalculationTrace]
}

public enum AirProcesses {
    public static let method = "Dry-air mass/enthalpy conservation; air-side cooling v1"
    public static let cfmToM3PerSecond = 0.0004719474432
    public static let kwToBtuh = 3412.141633

    /// Volume flow is actual CFM at each stream's entered condition, never standard CFM.
    public static func mix(first: MoistAirState, firstActualCFM: Double, second: MoistAirState, secondActualCFM: Double) throws -> AirMixResult {
        let (a, b) = try checked(first, second)
        try nonnegative(firstActualCFM, secondActualCFM)
        let m1 = firstActualCFM * cfmToM3PerSecond / a.volumeM3PerKgDryAir
        let m2 = secondActualCFM * cfmToM3PerSecond / b.volumeM3PerKgDryAir
        let m = m1 + m2
        try require(m.isFinite && m > 0, "Mixing requires positive total dry-air flow without overflow.")
        let f = m1 / m
        let w = f * a.humidityRatio + (1 - f) * b.humidityRatio
        let h = f * a.enthalpyKJPerKgDryAir + (1 - f) * b.enthalpyKJPerKgDryAir
        let t = (h - 2501 * w) / (1.006 + 1.86 * w)
        let mixed = try state(dryBulbC: t, humidityRatio: w, pressurePa: a.pressurePa)
        let cfm = m * mixed.volumeM3PerKgDryAir / cfmToM3PerSecond
        let assumptions = ["Adiabatic mixing at common pressure, no fan heat or leakage.", "Actual CFM at each inlet; dry-air mass weighting, not volume weighting.", "No fog/liquid-water phase. Supersaturated mixtures require a separate condensation model."]
        let traces: [CalculationTrace] = try [
            .init(equation: "mda = V1/v1 + V2/v2", substitution: "\(firstActualCFM) × \(cfmToM3PerSecond) / \(a.volumeM3PerKgDryAir) + \(secondActualCFM) × \(cfmToM3PerSecond) / \(b.volumeM3PerKgDryAir)", value: m, unit: "kg dry air/s", assumptions: assumptions),
            .init(equation: "Wmix = f × W1 + (1−f) × W2", substitution: "\(f) × \(a.humidityRatio) + \(1-f) × \(b.humidityRatio)", value: w, unit: "kg water/kg dry air"),
            .init(equation: "hmix = f × h1 + (1−f) × h2", substitution: "\(f) × \(a.enthalpyKJPerKgDryAir) + \(1-f) × \(b.enthalpyKJPerKgDryAir)", value: h, unit: "kJ/kg dry air (SI datum)"),
            .init(equation: "Tmix = (hmix − 2501Wmix)/(1.006 + 1.86Wmix)", substitution: "(\(h) − 2501 × \(w)) / (1.006 + 1.86 × \(w))", value: t, unit: "°C"),
            .init(equation: "Vout = mda × vmix", substitution: "\(m) × \(mixed.volumeM3PerKgDryAir) / \(cfmToM3PerSecond)", value: cfm, unit: "actual CFM")]
        return AirMixResult(state: mixed, dryAirMassKgPerSecond: m, outletActualCFM: cfm, traces: traces)
    }

    /// Positive air-side heat removal. Does not model refrigerant capacity or condensate liquid enthalpy.
    public static func coolingCoil(inlet: MoistAirState, outlet: MoistAirState, inletActualCFM: Double) throws -> CoolingCoilResult {
        let (a, b) = try checked(inlet, outlet)
        try require(inletActualCFM.isFinite && inletActualCFM > 0, "Enter positive actual inlet CFM.")
        try require(b.dryBulbC <= a.dryBulbC && b.humidityRatio <= a.humidityRatio + 1e-12, "Cooling-coil output cannot be warmer or more humid in humidity ratio than its inlet.")
        let m = inletActualCFM * cfmToM3PerSecond / a.volumeM3PerKgDryAir
        let total = m * (a.enthalpyKJPerKgDryAir - b.enthalpyKJPerKgDryAir)
        let sensible = m * (1.006 + 1.86 * b.humidityRatio) * (a.dryBulbC - b.dryBulbC)
        let latent = total - sensible
        try require([m,total,sensible,latent].allSatisfy(\.isFinite) && total >= -1e-10 && latent >= -1e-10, "Cooling process is inconsistent or overflows.")
        let q = max(0, total), l = max(0, latent)
        let water = m * max(0, a.humidityRatio - b.humidityRatio) * 3600
        let shr: Double? = q > 1e-10 ? min(1, sensible / q) : nil
        let assumptions = ["Steady flow; actual inlet CFM converted to dry-air mass using inlet specific volume.", "Sensible/latent split: sensible cooling at leaving humidity ratio; latent remainder at entering dry bulb.", "Air-side enthalpy decrease only; excludes liquid condensate enthalpy, fan heat, leakage and refrigerant performance.", "No manufacturer capacity selection. Supplemental ADP/bypass analysis is a separate geometric model and may be ambiguous."]
        let traces: [CalculationTrace] = try [
            .init(equation: "mda = Vin/vin", substitution: "\(inletActualCFM) × \(cfmToM3PerSecond) / \(a.volumeM3PerKgDryAir)", value: m, unit: "kg dry air/s", assumptions: assumptions),
            .init(equation: "Qt = mda × (hin − hout)", substitution: "\(m) × (\(a.enthalpyKJPerKgDryAir) − \(b.enthalpyKJPerKgDryAir))", value: q, unit: "kW"),
            .init(equation: "Qs = mda × (1.006 + 1.86Wout) × (Tin − Tout)", substitution: "\(m) × (1.006 + 1.86 × \(b.humidityRatio)) × (\(a.dryBulbC) − \(b.dryBulbC))", value: sensible, unit: "kW"),
            .init(equation: "Ql = Qt − Qs", substitution: "\(q) − \(sensible)", value: l, unit: "kW"),
            .init(equation: "Condensate = mda × (Win − Wout) × 3600", substitution: "\(m) × (\(a.humidityRatio) − \(b.humidityRatio)) × 3600", value: water, unit: "kg/h")]
        return CoolingCoilResult(apparatusDewPoint: try CoilApparatusDewPoint.analyze(inlet: a, outlet: b), totalKW: q, sensibleKW: sensible, latentKW: l, condensateKgPerHour: water, sensibleHeatRatio: shr, dryAirMassKgPerSecond: m, traces: traces)
    }

    public static func state(dryBulbC: Double, humidityRatio: Double, pressurePa: Double) throws -> MoistAirState {
        try Psychrometrics.state(dryBulbC: dryBulbC, humidityRatio: humidityRatio, pressurePa: pressurePa)
    }

    private static func checked(_ first: MoistAirState, _ second: MoistAirState) throws -> (MoistAirState, MoistAirState) {
        // Recompute derived data so decoded/caller-supplied property values cannot drive calculations.
        let a = try Psychrometrics.state(dryBulbC: first.dryBulbC, relativeHumidity: first.relativeHumidity, pressurePa: first.pressurePa)
        let b = try Psychrometrics.state(dryBulbC: second.dryBulbC, relativeHumidity: second.relativeHumidity, pressurePa: second.pressurePa)
        try require(abs(a.pressurePa - b.pressurePa) <= 1, "Air-process states must share absolute pressure (within 1 Pa); pressure-drop modeling is separate.")
        return (a,b)
    }
}
