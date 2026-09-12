import Foundation
import LoadSightCore

/// Moist-air properties on a dry-air mass basis. SI enthalpy uses a 0 °C datum.
public struct MoistAirState: Codable, Equatable, Sendable {
    public let dryBulbC: Double
    public let relativeHumidity: Double
    public let pressurePa: Double
    public let vaporPressurePa: Double
    public let humidityRatio: Double
    public let dewPointC: Double?
    public let wetBulbC: Double?
    public let enthalpyKJPerKgDryAir: Double
    public let volumeM3PerKgDryAir: Double
    public let warnings: [String]
    /// IP empirical enthalpy uses its own 0 °F datum, not a unit conversion of SI absolute enthalpy.
    public var enthalpyBtuPerLbDryAir: Double {
        let f = dryBulbC * 1.8 + 32
        return 0.240 * f + humidityRatio * (1061 + 0.444 * f)
    }
    public var dryAirDensityKgPerM3: Double { 1 / volumeM3PerKgDryAir }
    public var moistAirDensityKgPerM3: Double { (1 + humidityRatio) / volumeM3PerKgDryAir }
}

/// ASHRAE 2017 Fundamentals ch. 1 equations as documented by PsychroLib.
/// Coefficients adapted from PsychroLib (MIT); see Reference/engineering/PsychroLib-LICENSE.txt.
/// Solver and domain checks are local. No minimum-humidity clamp is applied.
public enum HumidityInputKind: String, Codable, CaseIterable, Sendable {
    case relativeHumidity, wetBulbC, dewPointC
}
public struct HumidityInput: Codable, Equatable, Sendable {
    public let kind: HumidityInputKind
    public let value: Double
    public init(kind: HumidityInputKind, value: Double) { self.kind = kind; self.value = value }
}

public enum Psychrometrics {
    public static let license = """
The MIT License (MIT)

Copyright (c) 2018-2020 The PsychroLib Contributors.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
"""
    public static let method = "ASHRAE 2017 Fundamentals ch. 1 via PsychroLib 2.5.0; SI moist-air state v1"
    public static let sourceURL = "https://psychrometrics.github.io/psychrolib/_modules/psychrolib.html"

    public static func saturationPressurePa(atC t: Double) throws -> Double {
        try require(t.isFinite && (-100...200).contains(t), "Saturation temperature must be between −100 and 200 °C.")
        let k = t + 273.15
        let ln: Double
        if t <= 0.01 {
            ln = -5674.5359/k + 6.3925247 - 0.009677843*k + 0.00000062215701*k*k
                + 0.0000000020747825*pow(k,3) - 0.0000000000009484024*pow(k,4) + 4.1635019*log(k)
        } else {
            ln = -5800.2206/k + 1.3914993 - 0.048640239*k + 0.000041764768*k*k
                - 0.000000014452093*pow(k,3) + 6.5459673*log(k)
        }
        return exp(ln)
    }

    public static func state(dryBulbC: Double, relativeHumidity: Double, pressurePa: Double) throws -> MoistAirState {
        let sat = try validateDomain(dryBulbC: dryBulbC, pressurePa: pressurePa)
        try require(relativeHumidity.isFinite && (0...1).contains(relativeHumidity), "Relative humidity must be between 0 and 100 percent.")
        let pv = relativeHumidity * sat
        let w = 0.621945 * pv / (pressurePa - pv)
        var warnings: [String] = []
        let dew: Double?
        if relativeHumidity == 0 {
            dew = nil; warnings.append("Zero water vapor has no finite dew point.")
        } else if pv < (try saturationPressurePa(atC: -100)) {
            dew = nil; warnings.append("Dew/frost point is below the −100 °C correlation limit.")
        } else if relativeHumidity == 1 { dew = dryBulbC }
        else {
            var low = -100.0, high = dryBulbC
            for _ in 0..<80 {
                let mid = (low + high) / 2
                if try saturationPressurePa(atC: mid) < pv { low = mid } else { high = mid }
            }
            dew = (low + high) / 2
        }
        let wet: Double?
        if relativeHumidity == 1 { wet = dryBulbC }
        else {
            var low = -100.0, high = dryBulbC
            for _ in 0..<80 {
                let mid = (low + high) / 2
                if try ratio(dry: dryBulbC, wet: mid, pressure: pressurePa) < w { low = mid } else { high = mid }
            }
            let candidate = (low + high) / 2
            if abs(try ratio(dry: dryBulbC, wet: candidate, pressure: pressurePa) - w) < 1e-8 { wet = candidate }
            else { wet = nil; warnings.append("Wet bulb has no resolved root within this domain/ice-water branch; verify the phase convention.") }
        }
        if let dew, dew < 0 { warnings.append("Below freezing, saturation and dew/frost point use the ice correlation.") }
        return MoistAirState(dryBulbC: dryBulbC, relativeHumidity: relativeHumidity, pressurePa: pressurePa,
                             vaporPressurePa: pv, humidityRatio: w, dewPointC: dew, wetBulbC: wet,
                             enthalpyKJPerKgDryAir: 1.006 * dryBulbC + w * (2501 + 1.86 * dryBulbC),
                             volumeM3PerKgDryAir: 287.042 * (dryBulbC + 273.15) * (1 + 1.607858 * w) / pressurePa,
                             warnings: warnings)
    }
    private static func validateDomain(dryBulbC: Double, pressurePa: Double) throws -> Double {
        try require(dryBulbC.isFinite && (-100...80).contains(dryBulbC), "This air-state calculator supports −100 to 80 °C dry bulb.")
        try require(pressurePa.isFinite && (20_000...120_000).contains(pressurePa), "Enter absolute station pressure between 20 and 120 kPa.")
        let sat = try saturationPressurePa(atC: dryBulbC)
        try require(sat < pressurePa, "Saturation pressure at the dry bulb must be below the entered total pressure.")
        return sat
    }
    public static func state(dryBulbC: Double, humidityRatio: Double, pressurePa: Double) throws -> MoistAirState {
        let sat = try validateDomain(dryBulbC: dryBulbC, pressurePa: pressurePa)
        try require(humidityRatio.isFinite && humidityRatio >= 0, "Humidity ratio must be finite and nonnegative.")
        let pv = pressurePa * (humidityRatio / (0.621945 + humidityRatio))
        let rh = pv / sat
        try require(rh.isFinite && rh <= 1 + 1e-12, "This state is supersaturated; a fog/condensation model is required.")
        return try state(dryBulbC: dryBulbC, relativeHumidity: min(1,rh), pressurePa: pressurePa)
    }
    public static func state(dryBulbC: Double, humidity: HumidityInput, pressurePa: Double) throws -> MoistAirState {
        let sat = try validateDomain(dryBulbC: dryBulbC, pressurePa: pressurePa)
        try require(humidity.value.isFinite, "Enter a finite humidity measurement.")
        switch humidity.kind {
        case .relativeHumidity:
            return try state(dryBulbC: dryBulbC, relativeHumidity: humidity.value, pressurePa: pressurePa)
        case .dewPointC:
            try require(humidity.value >= -100 && humidity.value <= dryBulbC, "Dew/frost point must be at least −100 °C and cannot exceed dry bulb.")
            let pv = try saturationPressurePa(atC: humidity.value)
            return try state(dryBulbC: dryBulbC, relativeHumidity: pv/sat, pressurePa: pressurePa)
        case .wetBulbC:
            try require(humidity.value >= -100 && humidity.value <= dryBulbC, "Wet bulb must be at least −100 °C and cannot exceed dry bulb.")
            let w = try ratio(dry: dryBulbC, wet: humidity.value, pressure: pressurePa)
            try require(w >= -1e-12, "The wet-bulb/dry-bulb/pressure combination implies negative moisture. Check units and input basis.")
            let s = try state(dryBulbC: dryBulbC, humidityRatio: max(0,w), pressurePa: pressurePa)
            // The supplied thermodynamic wet bulb fixes the branch. Retain it even if a reverse
            // solve near freezing has another solution or an unresolved ice/water boundary.
            var notes = s.warnings.filter { !$0.hasPrefix("Wet bulb has no resolved root") }
            if s.wetBulbC == nil || abs((s.wetBulbC ?? humidity.value)-humidity.value) > 0.002 {
                notes.append("The reverse RH wet-bulb solve differs at the ice/water boundary; the supplied input branch is retained.")
            }
            return MoistAirState(dryBulbC:s.dryBulbC, relativeHumidity:s.relativeHumidity, pressurePa:s.pressurePa,
                vaporPressurePa:s.vaporPressurePa, humidityRatio:s.humidityRatio, dewPointC:s.dewPointC,
                wetBulbC:humidity.value, enthalpyKJPerKgDryAir:s.enthalpyKJPerKgDryAir,
                volumeM3PerKgDryAir:s.volumeM3PerKgDryAir,
                warnings:notes + ["Supplied thermodynamic wet bulb uses the ice balance below 0 °C and liquid-water balance at/above 0 °C; instrument corrections are not modeled."])
        }
    }
    public static func humidityInputTrace(dryBulbC: Double, humidity: HumidityInput, pressurePa: Double) throws -> CalculationTrace {
        let s = try state(dryBulbC:dryBulbC,humidity:humidity,pressurePa:pressurePa)
        switch humidity.kind {
        case .relativeHumidity:
            return try .init(equation:"RH = supplied fraction",substitution:"RH = \(humidity.value)",value:s.relativeHumidity,unit:"fraction")
        case .dewPointC:
            return try .init(equation:"RH = Pws(Tdew)/Pws(Tdry)",substitution:"Pws(\(humidity.value) °C) / Pws(\(dryBulbC) °C)",value:s.relativeHumidity,unit:"fraction",assumptions:["Below the triple point, saturation uses ice (frost-point convention)."])
        case .wetBulbC:
            let pv = try saturationPressurePa(atC:humidity.value)
            let ws = 0.621945*pv/(pressurePa-pv)
            let equation = humidity.value >= 0 ? "W = ((2501−2.326Twb)Wsat−1.006(Tdb−Twb))/(2501+1.86Tdb−4.186Twb)" : "W = ((2830−0.24Twb)Wsat−1.006(Tdb−Twb))/(2830+1.86Tdb−2.1Twb)"
            return try .init(equation:equation,substitution:"Tdb=\(dryBulbC) °C; Twb=\(humidity.value) °C; P=\(pressurePa) Pa; Wsat=\(ws)",value:s.humidityRatio,unit:"kg water/kg dry air",assumptions:["Thermodynamic wet bulb; instrument corrections are not modeled."])
        }
    }
    private static func ratio(dry: Double, wet: Double, pressure: Double) throws -> Double {
        let pv = try saturationPressurePa(atC: wet)
        let ws = 0.621945 * pv / (pressure - pv)
        if wet >= 0 { return ((2501 - 2.326 * wet) * ws - 1.006 * (dry - wet)) / (2501 + 1.86 * dry - 4.186 * wet) }
        return ((2830 - 0.24 * wet) * ws - 1.006 * (dry - wet)) / (2830 + 1.86 * dry - 2.1 * wet)
    }
}
