import Foundation
import LoadSightCore

public struct CoilADPCandidate: Codable, Sendable {
    public let temperatureC: Double
    public let humidityRatio: Double
    public let bypassFactorTemperature: Double
    public let bypassFactorHumidity: Double
    public let bypassFactorEnthalpy: Double
    public let humidityResidual: Double
    public let nearTangent: Bool
    public let traces: [CalculationTrace]
}
public struct CoilADPAnalysis: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case inferred = "One model intersection"
        case ambiguous = "Multiple model intersections"
        case notApplicable = "Not applicable"
        case unresolved = "No resolved model intersection"
    }
    public let method: String
    public let status: Status
    /// Sorted warmest first; multiple candidates require engineering interpretation, not silent selection.
    public let candidates: [CoilADPCandidate]
    public let notes: [String]
}

public enum CoilApparatusDewPoint {
    public static let method = "Saturation/process-line intersection at site pressure; ADP v1"
    public static func analyze(inlet: MoistAirState, outlet: MoistAirState) throws -> CoilADPAnalysis {
        let a = try Psychrometrics.state(dryBulbC: inlet.dryBulbC, relativeHumidity: inlet.relativeHumidity, pressurePa: inlet.pressurePa)
        let b = try Psychrometrics.state(dryBulbC: outlet.dryBulbC, relativeHumidity: outlet.relativeHumidity, pressurePa: outlet.pressurePa)
        try require(abs(a.pressurePa - b.pressurePa) <= 1, "ADP states must share absolute pressure within 1 Pa.")
        try require(b.dryBulbC <= a.dryBulbC && b.humidityRatio <= a.humidityRatio + 1e-12, "ADP analysis requires cooling without humidification.")
        let deltaT = a.dryBulbC - b.dryBulbC, deltaW = a.humidityRatio - b.humidityRatio
        let general = ["Straight process line in dry-bulb/humidity-ratio coordinates, at the supplied site pressure.",
                       "ADP is an equivalent saturation-state model, not a measured coil surface temperature or manufacturer selection.",
                       "Temperature/humidity and enthalpy bypass factors use different approximations; all are reported without an invented agreement tolerance."]
        guard deltaT > 1e-8 && deltaW > 1e-12 else {
            return .init(method: method, status: .notApplicable, candidates: [], notes: general + ["Dry/sensible-only or zero-temperature-change processes do not identify a wet-coil apparatus dew point."])
        }
        let slope = deltaW / deltaT
        func ws(_ t: Double) throws -> Double {
            let pv = try Psychrometrics.saturationPressurePa(atC: t)
            return 0.621945 * pv / (a.pressurePa - pv)
        }
        func residual(_ t: Double) throws -> Double { try ws(t) - (a.humidityRatio - slope * (a.dryBulbC - t)) }
        var roots: [(Double,Bool)] = []
        func add(_ t: Double, tangent: Bool) {
            if !roots.contains(where: { abs($0.0 - t) < 1e-5 }) { roots.append((t,tangent)) }
        }
        func bracket(_ lo: Double, _ hi: Double) throws {
            let fl = try residual(lo), fh = try residual(hi)
            if abs(fl) < 1e-12 { add(lo,tangent:false) }
            if abs(fh) < 1e-12 { add(hi,tangent:false) }
            guard fl * fh < 0 else { return }
            var l = lo, h = hi, lowValue = fl
            for _ in 0..<80 {
                let mid = (l+h)/2, value = try residual(mid)
                if value == 0 { l = mid; h = mid; break }
                if lowValue * value > 0 { l = mid; lowValue = value } else { h = mid }
            }
            add((l+h)/2,tangent:false)
        }
        // Ws(T) is convex on each ice/water correlation branch. Locate its residual minimum,
        // then solve the monotone halves. This also finds closely spaced and tangent intersections.
        func branch(_ lo: Double, _ hi: Double) throws {
            guard hi >= lo else { return }
            if hi-lo < 1e-10 { if abs(try residual(lo)) < 1e-12 { add(lo,tangent:false) }; return }
            var l = lo, h = hi
            let factor = (sqrt(5.0)-1)/2
            var x1 = h-factor*(h-l), x2 = l+factor*(h-l)
            var f1 = try residual(x1), f2 = try residual(x2)
            for _ in 0..<100 {
                if f1 < f2 {
                    h = x2; x2 = x1; f2 = f1; x1 = h-factor*(h-l); f1 = try residual(x1)
                } else {
                    l = x1; x1 = x2; f1 = f2; x2 = l+factor*(h-l); f2 = try residual(x2)
                }
            }
            let minimum = (l+h)/2, value = try residual(minimum)
            if abs(value) < 1e-12 { add(minimum,tangent:true) }
            // If the minimum is a resolved tangent, do not invent two roots from floating-point noise.
            if abs(value) >= 1e-12 { try bracket(lo,minimum); try bracket(minimum,hi) }
            else {
                if abs(try residual(lo)) < 1e-12 { add(lo,tangent:false) }
                if abs(try residual(hi)) < 1e-12 { add(hi,tangent:false) }
            }
        }
        try branch(-100, min(0.01,b.dryBulbC))
        if b.dryBulbC > 0.01 { try branch(0.010000001,b.dryBulbC) }
        var candidates: [CoilADPCandidate] = []
        for (t,tangent) in roots.sorted(by: { $0.0 > $1.0 }) {
            let w = try ws(t), r = try residual(t)
            let h = 1.006*t + w*(2501+1.86*t)
            guard a.humidityRatio > w, a.enthalpyKJPerKgDryAir > h else { continue }
            let bt = (b.dryBulbC-t)/(a.dryBulbC-t)
            let bw = (b.humidityRatio-w)/(a.humidityRatio-w)
            let bh = (b.enthalpyKJPerKgDryAir-h)/(a.enthalpyKJPerKgDryAir-h)
            guard [bt,bw,bh].allSatisfy({ $0.isFinite && $0 >= -1e-9 && $0 <= 1+1e-9 }), abs(r) <= 1e-10, abs(bt-bw) <= 1e-6 else { continue }
            let traces: [CalculationTrace] = try [
                .init(equation: "Wsat(Tadp) = Win − ((Win−Wout)/(Tin−Tout)) × (Tin−Tadp)", substitution: "\(w) = \(a.humidityRatio) − \(slope) × (\(a.dryBulbC) − \(t)); residual \(r)", value:t,unit:"°C"),
                .init(equation: "BFt = (Tout−Tadp)/(Tin−Tadp)", substitution:"(\(b.dryBulbC) − \(t))/(\(a.dryBulbC) − \(t))",value:max(0,min(1,bt)),unit:"ratio"),
                .init(equation: "BFw = (Wout−Wadp)/(Win−Wadp)", substitution:"(\(b.humidityRatio) − \(w))/(\(a.humidityRatio) − \(w))",value:max(0,min(1,bw)),unit:"ratio"),
                .init(equation: "BFh = (hout−hadp)/(hin−hadp)", substitution:"(\(b.enthalpyKJPerKgDryAir) − \(h))/(\(a.enthalpyKJPerKgDryAir) − \(h))",value:max(0,min(1,bh)),unit:"ratio")]
            candidates.append(.init(temperatureC:t,humidityRatio:w,bypassFactorTemperature:max(0,min(1,bt)),bypassFactorHumidity:max(0,min(1,bw)),bypassFactorEnthalpy:max(0,min(1,bh)),humidityResidual:r,nearTangent:tangent,traces:traces))
        }
        var notes = general
        if candidates.isEmpty { notes.append("No physical bypass factors resolved over −100 °C to leaving dry bulb. Check conditions and model applicability; input states were not adjusted.") }
        if candidates.count > 1 { notes.append("Multiple saturation intersections satisfy the supplied line. Candidates are shown warmest first; no automatic physical-coil selection is made.") }
        if candidates.contains(where: { $0.nearTangent }) { notes.append("A near-tangent intersection is sensitive to small input changes; review precision and measurement uncertainty.") }
        if candidates.contains(where: { $0.temperatureC < 0 }) { notes.append("Subfreezing candidates use the ice saturation correlation; frost/defrost and surface physics are not modeled.") }
        return .init(method:method,status:candidates.isEmpty ? .unresolved : (candidates.count > 1 ? .ambiguous : .inferred),candidates:candidates,notes:notes)
    }
}
