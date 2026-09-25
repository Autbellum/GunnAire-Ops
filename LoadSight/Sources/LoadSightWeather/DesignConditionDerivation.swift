import Foundation
import LoadSightCore
import LoadSightCalc

/// Derives annual design conditions from hourly observations.
///
/// The percentile definitions implemented here are the published ASHRAE annual design
/// condition definitions — a dry bulb quoted at "0.4%" is the value exceeded 0.4% of the
/// annual hours. The definitions are method, and ASHRAE TC 4.2 computes its own published
/// tables from this same Integrated Surface Database. LoadSight recomputes them from the
/// observations rather than reproducing the licensed tables, so the values will sit close
/// to the published ones without being them, and must never be labelled as ASHRAE data.
///
/// Every function here is pure and has no actor isolation, so a caller may run a
/// multi-decade derivation from a background task without touching the main actor.
public enum DesignConditionDerivation {
    public static let method =
        "Empirical annual exceedance percentiles over pooled hourly observations "
      + "(one observation per clock hour, nearest the hour); mean coincident values "
      + "averaged over a dry-bulb bin centred on the design value; "
      + "wet bulb from dry bulb and dew point at station pressure via ASHRAE 2017 "
      + "Fundamentals ch. 1 psychrometrics."

    /// Annual exceedance percentages carried for heating and cooling.
    public static let heatingPercents: [Double] = [99.6, 99]
    public static let coolingPercents: [Double] = [0.4, 1, 2]
    public static let dehumidificationPercents: [Double] = [0.4, 1, 2]

    /// Minimum observations inside a coincident bin before the mean is reported.
    static let minimumCoincidentSamples = 30
    /// Bin half-widths tried in order until the sample minimum is met.
    static let coincidentBinHalfWidthsC: [Double] = [0.5, 1, 2, 3]

    public static func derive(observations: [ISDObservation], station: ISDStation,
                              read: ISDReadTotals, distanceFromSiteKM: Double? = nil) throws -> DesignConditions {
        try require(!observations.isEmpty, "No usable observations remain after quality filtering; design conditions cannot be derived.")

        let dryBulbs = observations.map(\.dryBulbC).sorted()
        let years = Set(observations.map(\.year)).sorted()
        let pressure = station.stationPressurePa

        var warnings: [String] = []
        if !station.hasPublishedElevation {
            warnings.append("The station has no published elevation; sea-level pressure was assumed, which biases wet bulb and humidity ratio.")
        }
        let expectedHours = years.count * 8_760
        let coverage = Double(observations.count) / Double(max(expectedHours, 1))
        if coverage < 0.85 {
            warnings.append(String(format: "The record is %.0f%% complete against 8,760 hours per year; percentiles near the tails are less certain.", coverage * 100))
        }
        if years.count < 10 {
            warnings.append("Only \(years.count) year(s) of record were used. ASHRAE derives published conditions from a multi-decade record; short records move the extreme percentiles.")
        }

        let heating = try heatingPercents.map {
            try dryBulbCondition(percent: $0, sortedDryBulbs: dryBulbs, observations: observations,
                                 pressurePa: pressure)
        }
        let cooling = try coolingPercents.map {
            try dryBulbCondition(percent: $0, sortedDryBulbs: dryBulbs, observations: observations,
                                 pressurePa: pressure)
        }

        let withDewPoint = observations.filter { $0.dewPointC != nil }
        var dehumidification: [DesignDewPoint] = []
        if withDewPoint.count >= minimumCoincidentSamples {
            let dewPoints = withDewPoint.compactMap(\.dewPointC).sorted()
            dehumidification = try dehumidificationPercents.map {
                try dewPointCondition(percent: $0, sortedDewPoints: dewPoints,
                                      observations: withDewPoint, pressurePa: pressure)
            }
        } else {
            warnings.append("Too few dew-point observations to derive dehumidification conditions.")
        }

        let (dailyRange, warmestMonth) = warmestMonthDailyRange(observations)
        if dailyRange == nil {
            warnings.append("No month had enough complete days to derive a mean daily range.")
        }

        let provenance = DesignConditionProvenance(
            stationID: station.id, stationName: station.name,
            latitude: station.latitude, longitude: station.longitude,
            elevationM: station.elevationM, elevationAssumed: !station.hasPublishedElevation,
            stationPressurePa: pressure, distanceFromSiteKM: distanceFromSiteKM,
            firstYear: years.first ?? 0, lastYear: years.last ?? 0, yearsUsed: years,
            hoursUsed: observations.count,
            hoursRejectedQuality: read.rejectedQuality,
            hoursRejectedMissing: read.rejectedMissing,
            hoursRejectedMalformed: read.rejectedMalformed,
            method: method, sourceURL: "https://www.ncei.noaa.gov/products/land-based-station/integrated-surface-database",
            warnings: warnings)

        let extremes = annualExtremes(observations)
        return DesignConditions(heating: heating, cooling: cooling, dehumidification: dehumidification,
                                coolingDailyRangeC: dailyRange, warmestMonth: warmestMonth,
                                extremeAnnualMinimumC: extremes.minimum,
                                extremeAnnualMaximumC: extremes.maximum,
                                provenance: provenance)
    }

    // MARK: - Percentiles

    /// Empirical quantile with linear interpolation between order statistics.
    static func quantile(_ sorted: [Double], fraction: Double) throws -> Double {
        try require(!sorted.isEmpty, "Cannot take a percentile of an empty sample.")
        try require(fraction.isFinite && (0...1).contains(fraction), "Percentile position must lie between zero and one.")
        if sorted.count == 1 { return sorted[0] }
        let position = fraction * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let weight = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * weight
    }

    /// The value exceeded `percent` of the hours.
    ///
    /// A 0.4% cooling condition is exceeded by only the warmest 0.4% of hours, which is
    /// the 99.6th percentile; a 99.6% heating condition is exceeded by almost every hour,
    /// which is the 0.4th percentile. Both are `1 − percent/100`, so heating and cooling
    /// share one expression rather than two that can drift apart.
    static func exceedanceValue(_ sorted: [Double], percent: Double) throws -> Double {
        try require(percent > 0 && percent < 100, "An exceedance percentage must lie between zero and one hundred.")
        return try quantile(sorted, fraction: 1 - percent / 100)
    }

    // MARK: - Conditions

    static func dryBulbCondition(percent: Double, sortedDryBulbs: [Double],
                                 observations: [ISDObservation], pressurePa: Double) throws -> DesignDryBulb {
        let designDryBulb = try exceedanceValue(sortedDryBulbs, percent: percent)
        for halfWidth in coincidentBinHalfWidthsC {
            let inBin = observations.filter { abs($0.dryBulbC - designDryBulb) <= halfWidth && $0.dewPointC != nil }
            guard inBin.count >= minimumCoincidentSamples else { continue }
            let wetBulbs = inBin.compactMap { observation -> Double? in
                guard let dewPoint = observation.dewPointC else { return nil }
                return try? Psychrometrics.state(dryBulbC: observation.dryBulbC,
                                                 humidity: HumidityInput(kind: .dewPointC, value: dewPoint),
                                                 pressurePa: pressurePa).wetBulbC
            }.compactMap { $0 }
            guard !wetBulbs.isEmpty else { continue }
            let mean = wetBulbs.reduce(0, +) / Double(wetBulbs.count)
            return DesignDryBulb(exceedancePercent: percent, dryBulbC: designDryBulb,
                                 meanCoincidentWetBulbC: mean, coincidentSampleCount: wetBulbs.count,
                                 coincidentBinWidthC: halfWidth * 2)
        }
        return DesignDryBulb(exceedancePercent: percent, dryBulbC: designDryBulb,
                             meanCoincidentWetBulbC: nil, coincidentSampleCount: 0, coincidentBinWidthC: nil)
    }

    static func dewPointCondition(percent: Double, sortedDewPoints: [Double],
                                  observations: [ISDObservation], pressurePa: Double) throws -> DesignDewPoint {
        let designDewPoint = try exceedanceValue(sortedDewPoints, percent: percent)
        var meanDryBulb: Double?
        var sampleCount = 0
        for halfWidth in coincidentBinHalfWidthsC {
            let inBin = observations.filter { observation in
                guard let dewPoint = observation.dewPointC else { return false }
                return abs(dewPoint - designDewPoint) <= halfWidth
            }
            guard inBin.count >= minimumCoincidentSamples else { continue }
            meanDryBulb = inBin.map(\.dryBulbC).reduce(0, +) / Double(inBin.count)
            sampleCount = inBin.count
            break
        }
        // Humidity ratio at the design dew point is fixed by the dew point and pressure;
        // the coincident dry bulb only sets which state it is quoted at.
        let humidityRatio = try? Psychrometrics.state(
            dryBulbC: max(meanDryBulb ?? designDewPoint, designDewPoint),
            humidity: HumidityInput(kind: .dewPointC, value: designDewPoint),
            pressurePa: pressurePa).humidityRatio
        return DesignDewPoint(exceedancePercent: percent, dewPointC: designDewPoint,
                              meanCoincidentDryBulbC: meanDryBulb, humidityRatio: humidityRatio,
                              coincidentSampleCount: sampleCount)
    }

    // MARK: - Daily range and extremes

    /// Mean daily dry-bulb range of the warmest month.
    ///
    /// Days with thin coverage are excluded: a day holding three observations reports a
    /// range that is an artefact of when the station happened to report.
    static func warmestMonthDailyRange(_ observations: [ISDObservation],
                                       minimumObservationsPerDay: Int = 18) -> (Double?, Int?) {
        var monthlyTotals: [Int: (sum: Double, count: Int)] = [:]
        for observation in observations {
            let existing = monthlyTotals[observation.month] ?? (0, 0)
            monthlyTotals[observation.month] = (existing.sum + observation.dryBulbC, existing.count + 1)
        }
        let warmest = monthlyTotals
            .filter { $0.value.count > 0 }
            .max { ($0.value.sum / Double($0.value.count)) < ($1.value.sum / Double($1.value.count)) }?.key
        guard let warmest else { return (nil, nil) }

        var byDay: [Int: [Double]] = [:]
        for observation in observations where observation.month == warmest {
            byDay[observation.dayKey, default: []].append(observation.dryBulbC)
        }
        let ranges = byDay.values
            .filter { $0.count >= minimumObservationsPerDay }
            .compactMap { values -> Double? in
                guard let low = values.min(), let high = values.max() else { return nil }
                return high - low
            }
        guard !ranges.isEmpty else { return (nil, warmest) }
        return (ranges.reduce(0, +) / Double(ranges.count), warmest)
    }

    /// Mean across years of each year's lowest and highest observed dry bulb.
    static func annualExtremes(_ observations: [ISDObservation]) -> (minimum: Double?, maximum: Double?) {
        var byYear: [Int: (low: Double, high: Double)] = [:]
        for observation in observations {
            if let existing = byYear[observation.year] {
                byYear[observation.year] = (min(existing.low, observation.dryBulbC),
                                            max(existing.high, observation.dryBulbC))
            } else {
                byYear[observation.year] = (observation.dryBulbC, observation.dryBulbC)
            }
        }
        guard !byYear.isEmpty else { return (nil, nil) }
        let lows = byYear.values.map(\.low), highs = byYear.values.map(\.high)
        return (lows.reduce(0, +) / Double(lows.count), highs.reduce(0, +) / Double(highs.count))
    }
}

/// Attrition totals accumulated across every yearly file read for a station.
public struct ISDReadTotals: Sendable, Equatable {
    public var rowsRead = 0
    public var rejectedQuality = 0
    public var rejectedMissing = 0
    public var rejectedMalformed = 0
    public var duplicateHoursDropped = 0
    public init() {}
    public mutating func add(_ result: ISDReadResult) {
        rowsRead += result.rowsRead
        rejectedQuality += result.rejectedQuality
        rejectedMissing += result.rejectedMissing
        rejectedMalformed += result.rejectedMalformed
        duplicateHoursDropped += result.duplicateHoursDropped
    }
}
