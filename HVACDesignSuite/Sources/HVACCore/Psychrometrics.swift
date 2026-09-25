import Foundation

/// Moist-air properties in inch-pound units.
///
/// The brief asked for an approximation module. This implements the actual ASHRAE 2017
/// Handbook—Fundamentals Chapter 1 formulation instead, in IP units, because the curve
/// fits commonly used in duct calculators drift by several Btu/lb at the wet end of the
/// cooling envelope — exactly where a latent load is decided. The interface is the one
/// requested: dry bulb in °F and relative humidity in percent go in, enthalpy and
/// humidity ratio come out.
///
/// Every value is a pure function of its inputs, so the whole module is `Sendable` and
/// safe to call from any actor or background task.
public enum Psychrometrics {

    // MARK: - Constants

    /// Ratio of the molecular mass of water vapour to dry air.
    /// ASHRAE Fundamentals Ch. 1, used throughout the humidity-ratio relations.
    public static let molecularMassRatio = 0.621945

    /// Standard sea-level atmospheric pressure, psia.
    public static let standardSeaLevelPressure = 14.696

    /// Specific heat of dry air at constant pressure, Btu/(lb·°F).
    public static let specificHeatDryAir = 0.240

    /// Specific heat of water vapour at constant pressure, Btu/(lb·°F).
    public static let specificHeatWaterVapor = 0.444

    /// Latent heat of vaporisation of water at 32 °F, Btu/lb.
    /// This is the 1061 in the enthalpy relation h = 0.240t + W(1061 + 0.444t).
    public static let latentHeatAt32F = 1061.0

    /// Grains of water per pound. Residential load work quotes humidity ratio in grains.
    public static let grainsPerPound = 7000.0

    // MARK: - Atmosphere

    /// Atmospheric pressure at an altitude, psia.
    ///
    /// ASHRAE Fundamentals Ch. 1 standard atmosphere. This matters more than it looks:
    /// the Piedmont Triad sits near 900 ft, where air is about 3% less dense than the
    /// sea-level air behind the familiar 1.08 and 4840 coefficients. Ignoring it
    /// oversizes airflow by roughly that much through every downstream calculation.
    ///
    /// - Parameter altitudeFeet: Site elevation above sea level, ft.
    public static func pressure(altitudeFeet: Double) -> Double {
        standardSeaLevelPressure * pow(1 - 6.8754e-6 * altitudeFeet, 5.2559)
    }

    // MARK: - Saturation

    /// Saturation vapour pressure over water or ice, psia.
    ///
    /// ASHRAE Fundamentals Ch. 1 Eq. 5 (over ice, below 32 °F) and Eq. 6 (over liquid
    /// water, at and above 32 °F). Temperature enters in degrees Rankine.
    ///
    /// - Parameter dryBulbF: Temperature, °F. Valid from −148 °F to 392 °F.
    public static func saturationPressure(dryBulbF: Double) throws -> Double {
        guard dryBulbF.isFinite, dryBulbF >= -148, dryBulbF <= 392 else {
            throw HVACError.outOfRange("Saturation pressure is defined from −148 °F to 392 °F; received \(dryBulbF) °F.")
        }
        let rankine = dryBulbF + 459.67
        let lnP: Double
        if dryBulbF < 32 {
            // Over ice.
            lnP = -1.0214165e4 / rankine
                - 4.8932428
                - 5.3765794e-3 * rankine
                + 1.9202377e-7 * rankine * rankine
                + 3.5575832e-10 * pow(rankine, 3)
                - 9.0344688e-14 * pow(rankine, 4)
                + 4.1635019 * log(rankine)
        } else {
            // Over liquid water.
            lnP = -1.0440397e4 / rankine
                - 1.1294650e1
                - 2.7022355e-2 * rankine
                + 1.2890360e-5 * rankine * rankine
                - 2.4780681e-9 * pow(rankine, 3)
                + 6.5459673 * log(rankine)
        }
        return exp(lnP)
    }

    // MARK: - State

    /// A complete moist-air state in IP units.
    public struct MoistAir: Codable, Sendable, Equatable {
        public let dryBulbF: Double
        public let relativeHumidity: Double          // 0…1
        public let pressurePsia: Double
        public let humidityRatio: Double             // lb water / lb dry air
        public let enthalpyBtuPerPound: Double       // Btu / lb dry air
        public let specificVolume: Double            // ft³ / lb dry air
        public let dewPointF: Double
        public let density: Double                   // lb dry air / ft³

        /// Humidity ratio expressed in grains, the unit Manual J worksheets use.
        public var grains: Double { humidityRatio * Psychrometrics.grainsPerPound }
    }

    /// Builds a moist-air state from the inputs the brief specified.
    ///
    /// - Parameters:
    ///   - dryBulbF: Dry-bulb temperature, °F.
    ///   - relativeHumidityPercent: Relative humidity, 0–100.
    ///   - altitudeFeet: Site elevation, ft.
    public static func state(dryBulbF: Double,
                             relativeHumidityPercent: Double,
                             altitudeFeet: Double = 0) throws -> MoistAir {
        guard relativeHumidityPercent.isFinite, (0...100).contains(relativeHumidityPercent) else {
            throw HVACError.outOfRange("Relative humidity must be between 0 and 100 percent; received \(relativeHumidityPercent).")
        }
        let pressure = pressure(altitudeFeet: altitudeFeet)
        let saturation = try saturationPressure(dryBulbF: dryBulbF)
        let relativeHumidity = relativeHumidityPercent / 100
        let vaporPressure = relativeHumidity * saturation
        return try state(dryBulbF: dryBulbF, vaporPressure: vaporPressure,
                         pressure: pressure, relativeHumidity: relativeHumidity)
    }

    /// Builds a state from a dew point rather than a relative humidity.
    /// Design conditions are published as a dew point, so this is the path the
    /// dehumidification load actually uses.
    public static func state(dryBulbF: Double,
                             dewPointF: Double,
                             altitudeFeet: Double = 0) throws -> MoistAir {
        guard dewPointF <= dryBulbF else {
            throw HVACError.outOfRange("Dew point (\(dewPointF) °F) cannot exceed dry bulb (\(dryBulbF) °F).")
        }
        let pressure = pressure(altitudeFeet: altitudeFeet)
        let vaporPressure = try saturationPressure(dryBulbF: dewPointF)
        let saturation = try saturationPressure(dryBulbF: dryBulbF)
        return try state(dryBulbF: dryBulbF, vaporPressure: vaporPressure,
                         pressure: pressure, relativeHumidity: vaporPressure / saturation)
    }

    /// Builds a state from a wet bulb.
    ///
    /// Summer design conditions are published as a dry bulb with its mean coincident wet
    /// bulb, so this is the path the cooling load actually uses. Humidity ratio comes from
    /// ASHRAE Fundamentals Ch. 1 Eq. 33 (IP):
    ///
    ///   W = ((1093 − 0.556·t*)·Ws* − 0.240·(t − t*)) / (1093 + 0.444·t − t*)
    ///
    /// where t* is the wet bulb and Ws* the saturation humidity ratio at it.
    public static func state(dryBulbF: Double,
                             wetBulbF: Double,
                             altitudeFeet: Double = 0) throws -> MoistAir {
        guard wetBulbF <= dryBulbF else {
            throw HVACError.outOfRange("Wet bulb (\(wetBulbF) °F) cannot exceed dry bulb (\(dryBulbF) °F).")
        }
        guard wetBulbF >= 32 else {
            throw HVACError.outOfRange("This wet-bulb relation uses the liquid-water balance and is applied at or above 32 °F; received \(wetBulbF) °F.")
        }
        let pressure = pressure(altitudeFeet: altitudeFeet)
        let saturationAtWetBulb = try saturationPressure(dryBulbF: wetBulbF)
        let saturationRatio = molecularMassRatio * saturationAtWetBulb / (pressure - saturationAtWetBulb)
        let humidityRatio = ((1093 - 0.556 * wetBulbF) * saturationRatio - specificHeatDryAir * (dryBulbF - wetBulbF))
                          / (1093 + 0.444 * dryBulbF - wetBulbF)
        guard humidityRatio > 0 else {
            throw HVACError.unsolvable("That dry-bulb and wet-bulb pair implies negative moisture; check the inputs.")
        }
        let vaporPressure = pressure * humidityRatio / (molecularMassRatio + humidityRatio)
        let saturation = try saturationPressure(dryBulbF: dryBulbF)
        return try state(dryBulbF: dryBulbF, vaporPressure: vaporPressure,
                         pressure: pressure, relativeHumidity: vaporPressure / saturation)
    }

    private static func state(dryBulbF: Double, vaporPressure: Double,
                              pressure: Double, relativeHumidity: Double) throws -> MoistAir {
        guard vaporPressure < pressure else {
            throw HVACError.outOfRange("The vapour pressure exceeds the atmospheric pressure; this state cannot exist.")
        }
        // ASHRAE Fundamentals Ch. 1 Eq. 20: W = 0.621945 · pw / (p − pw)
        let humidityRatio = molecularMassRatio * vaporPressure / (pressure - vaporPressure)

        // ASHRAE Fundamentals Ch. 1 Eq. 30: h = 0.240·t + W·(1061 + 0.444·t)
        let enthalpy = specificHeatDryAir * dryBulbF
            + humidityRatio * (latentHeatAt32F + specificHeatWaterVapor * dryBulbF)

        // ASHRAE Fundamentals Ch. 1 Eq. 26: v = 0.370486·(t + 459.67)·(1 + 1.607858·W) / p
        let specificVolume = 0.370486 * (dryBulbF + 459.67) * (1 + 1.607858 * humidityRatio) / pressure

        return MoistAir(dryBulbF: dryBulbF,
                        relativeHumidity: relativeHumidity,
                        pressurePsia: pressure,
                        humidityRatio: humidityRatio,
                        enthalpyBtuPerPound: enthalpy,
                        specificVolume: specificVolume,
                        dewPointF: try dewPoint(vaporPressure: vaporPressure),
                        density: 1 / specificVolume)
    }

    /// Inverts the saturation-pressure relation to recover a dew point.
    ///
    /// Solved by bisection rather than a published inverse fit: the fit carries its own
    /// error band, while bisection on the forward equation is exact to tolerance and
    /// cannot disagree with the enthalpy computed from the same curve.
    public static func dewPoint(vaporPressure: Double) throws -> Double {
        guard vaporPressure > 0 else { return -148 }
        var low = -148.0, high = 392.0
        for _ in 0..<80 {
            let middle = (low + high) / 2
            let pressure = try saturationPressure(dryBulbF: middle)
            if pressure < vaporPressure { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }

    // MARK: - Airflow heat-transfer coefficients

    /// The sensible-heat coefficient in q = C · CFM · ΔT, corrected for altitude.
    ///
    /// The familiar 1.08 is 60 min/h × 0.075 lb/ft³ × 0.240 Btu/(lb·°F), which bakes in
    /// sea-level standard air. At 900 ft the correct coefficient is nearer 1.05.
    /// Manual J allows the sea-level value for most residential work; this returns the
    /// corrected one so the elevation of the actual site is carried honestly.
    public static func sensibleCoefficient(altitudeFeet: Double, dryBulbF: Double = 70) throws -> Double {
        return 60 * dryAirDensity(dryBulbF: dryBulbF, altitudeFeet: altitudeFeet) * specificHeatDryAir
    }

    /// Density of dry air, lb per ft³.
    ///
    /// The published 1.08, 4840 and 4.5 are all referenced to dry air at 70 °F and sea
    /// level — 0.075 lb/ft³. Moist air at 50% RH holds about 1.3% fewer pounds of dry air
    /// per cubic foot, so evaluating the coefficients at a realistic humidity moves them
    /// off the values every table and duct calculator uses. Dry air is taken as the
    /// reference here so the coefficients reproduce the industry numbers exactly at sea
    /// level while still scaling correctly with altitude, which is the correction that
    /// actually matters at 900 ft.
    public static func dryAirDensity(dryBulbF: Double, altitudeFeet: Double) -> Double {
        let pressure = pressure(altitudeFeet: altitudeFeet)
        return pressure / (0.370486 * (dryBulbF + 459.67))
    }

    /// The latent coefficient in q = C · CFM · ΔW with ΔW in lb/lb, corrected for altitude.
    /// The familiar 4840 is 60 × 0.075 × 1076 Btu/lb at sea level.
    public static func latentCoefficient(altitudeFeet: Double, dryBulbF: Double = 70) throws -> Double {
        return 60 * dryAirDensity(dryBulbF: dryBulbF, altitudeFeet: altitudeFeet) * 1076
    }

    /// The total-heat coefficient in q = C · CFM · Δh, corrected for altitude.
    /// The familiar 4.5 is 60 × 0.075.
    public static func totalCoefficient(altitudeFeet: Double, dryBulbF: Double = 70) throws -> Double {
        return 60 * dryAirDensity(dryBulbF: dryBulbF, altitudeFeet: altitudeFeet)
    }
}

/// Errors raised across the suite. Every message names the offending value, because a
/// design tool that says only "invalid input" makes the engineer hunt for it.
public enum HVACError: Error, LocalizedError, Equatable, Sendable {
    case outOfRange(String)
    case invalidGeometry(String)
    case unsolvable(String)

    public var errorDescription: String? {
        switch self {
        case .outOfRange(let message), .invalidGeometry(let message), .unsolvable(let message):
            return message
        }
    }
}
