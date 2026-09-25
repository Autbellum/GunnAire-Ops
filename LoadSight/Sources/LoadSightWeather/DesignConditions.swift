import Foundation
import LoadSightCore

/// A dry-bulb design condition and the mean wet bulb occurring with it.
public struct DesignDryBulb: Codable, Sendable, Equatable {
    /// Annual percentage of hours this dry bulb is exceeded (0.4, 1, 2, 99, 99.6).
    public let exceedancePercent: Double
    public let dryBulbC: Double
    public let meanCoincidentWetBulbC: Double?
    /// Observations inside the coincident bin. A small count makes the coincident
    /// value unreliable even though the dry bulb itself is sound.
    public let coincidentSampleCount: Int
    public let coincidentBinWidthC: Double?

    public var dryBulbF: Double { dryBulbC * 9 / 5 + 32 }
    public var meanCoincidentWetBulbF: Double? { meanCoincidentWetBulbC.map { $0 * 9 / 5 + 32 } }
}

/// A dew-point design condition and the mean dry bulb occurring with it.
public struct DesignDewPoint: Codable, Sendable, Equatable {
    public let exceedancePercent: Double
    public let dewPointC: Double
    public let meanCoincidentDryBulbC: Double?
    public let humidityRatio: Double?
    public let coincidentSampleCount: Int

    public var dewPointF: Double { dewPointC * 9 / 5 + 32 }
    public var meanCoincidentDryBulbF: Double? { meanCoincidentDryBulbC.map { $0 * 9 / 5 + 32 } }
    /// Grains of moisture per pound of dry air, the unit residential load work uses.
    public var grainsPerPound: Double? { humidityRatio.map { $0 * 7_000 } }
}

/// Where a set of design conditions came from and how much of the record survived.
///
/// This travels with the numbers and is meant to be printed on a report. LoadSight
/// derives design conditions from public observations rather than reproducing ASHRAE's
/// published tables, so anyone reviewing a calculation is entitled to see the station,
/// the years, the method and the attrition behind them.
public struct DesignConditionProvenance: Codable, Sendable, Equatable {
    public let stationID: String
    public let stationName: String
    public let latitude: Double
    public let longitude: Double
    public let elevationM: Double?
    public let elevationAssumed: Bool
    public let stationPressurePa: Double
    public let distanceFromSiteKM: Double?
    public let firstYear: Int
    public let lastYear: Int
    public let yearsUsed: [Int]
    public let hoursUsed: Int
    public let hoursRejectedQuality: Int
    public let hoursRejectedMissing: Int
    public let hoursRejectedMalformed: Int
    public let method: String
    public let sourceURL: String
    public let warnings: [String]

    /// One line suitable for a report footer.
    public var citation: String {
        let elevation = elevationM.map { String(format: "%.0f m", $0) } ?? "elevation unpublished"
        return "\(stationName) (\(stationID)), \(elevation), \(firstYear)–\(lastYear), "
             + "\(hoursUsed) hourly observations. Derived by LoadSight from NOAA Integrated "
             + "Surface Database observations; not ASHRAE published design conditions."
    }
}

/// The derived annual design conditions for one station.
public struct DesignConditions: Codable, Sendable, Equatable {
    /// Heating dry bulb, exceeded 99.6% and 99% of annual hours.
    public let heating: [DesignDryBulb]
    /// Cooling dry bulb with mean coincident wet bulb, exceeded 0.4%, 1% and 2% of hours.
    public let cooling: [DesignDryBulb]
    /// Dehumidification dew point with mean coincident dry bulb.
    public let dehumidification: [DesignDewPoint]
    /// Mean daily dry-bulb range of the warmest month, the figure Manual J calls
    /// the design temperature swing.
    public let coolingDailyRangeC: Double?
    public let warmestMonth: Int?
    /// Mean of each year's lowest and highest observed dry bulb.
    public let extremeAnnualMinimumC: Double?
    public let extremeAnnualMaximumC: Double?
    public let provenance: DesignConditionProvenance

    public func heating(at percent: Double) -> DesignDryBulb? {
        heating.first { abs($0.exceedancePercent - percent) < 0.001 }
    }
    public func cooling(at percent: Double) -> DesignDryBulb? {
        cooling.first { abs($0.exceedancePercent - percent) < 0.001 }
    }
    public func dehumidification(at percent: Double) -> DesignDewPoint? {
        dehumidification.first { abs($0.exceedancePercent - percent) < 0.001 }
    }

    public var coolingDailyRangeF: Double? { coolingDailyRangeC.map { $0 * 9 / 5 } }
}
