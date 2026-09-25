import Foundation

/// The hourly cooling load across the design day.
///
/// **This is an analysis, not yet the sizing basis.** Equipment selection still runs from
/// the steady-state sensible load, which is the larger and therefore more conservative of
/// the two. Promoting the coincident peak to the primary figure changes every number
/// downstream — airflow, room CFM, duct sizes — and is a deliberate step to take on its
/// own rather than as a side effect of adding the transient solver.
///
/// The reason this exists rather than a single design-condition calculation: surfaces do
/// not peak together. An east window peaks at 08:00, a west wall at 16:00, a block wall at
/// 21:00. Adding each surface's own maximum produces a building peak that never occurs,
/// and sizes equipment for it. The correct figure is the *coincident* peak — the largest
/// the sum ever reaches — which is what this finds.
public struct CoolingProfile: Sendable, Equatable {
    /// Sensible cooling load for each hour of the design day, Btu/h.
    public let hourlySensible: [Double]
    /// Hour at which the building total peaks.
    public let peakHour: Int
    /// Sensible load at that hour.
    public let peakSensible: Double
    /// Sum of each surface's individual maximum, regardless of when it occurs.
    /// Always greater than or equal to the coincident peak.
    public let sumOfIndividualPeaks: Double
    /// Per-zone sensible load at the building's peak hour.
    public let zoneSensibleAtPeak: [UUID: Double]

    /// How much the coincident peak saves over summing individual maxima.
    public var diversityFactor: Double {
        sumOfIndividualPeaks > 0 ? peakSensible / sumOfIndividualPeaks : 1
    }
}

public extension LoadCalculator {

    /// Builds the design-day sensible profile for a project.
    ///
    /// Each opaque surface backed by a library assembly is solved transiently, so its
    /// contribution carries the lag and damping its mass actually produces. Glazing is
    /// treated as instantaneous, which is very nearly true: a window has almost no mass
    /// and its conduction and solar gain both follow the sun directly.
    static func coolingProfile(project: Project) throws -> CoolingProfile {
        let conditions = project.designConditions
        let day = Solar.representativeDay(month: conditions.coolingDesignMonth)
        let room = conditions.indoorSummerDryBulbF
        let sensibleCoefficient = try Psychrometrics.sensibleCoefficient(altitudeFeet: conditions.altitudeFeet)

        // Hourly outdoor air and solar, shared by every surface.
        var outdoor = [Double](repeating: 0, count: 24)
        var irradiance: [Orientation: [Double]] = [:]
        for orientation in Orientation.allCases {
            irradiance[orientation] = [Double](repeating: 0, count: 24)
        }
        for hour in 0..<24 {
            outdoor[hour] = TransientConduction.outdoorTemperature(
                hour: Double(hour), peakF: conditions.summerOutdoorDryBulbF,
                dailyRangeF: conditions.summerDailyRangeF)
            let sun = Solar.position(latitude: conditions.latitude, dayOfYear: day,
                                     solarHour: Double(hour))
            let sky = Solar.clearSky(position: sun, dayOfYear: day,
                                     altitudeFeet: conditions.altitudeFeet,
                                     atmosphere: .humidSummer)
            for orientation in Orientation.allCases {
                irradiance[orientation]?[hour] = Solar.irradiance(
                    on: orientation.azimuth, tilt: orientation.tilt,
                    position: sun, clearSky: sky)
            }
        }

        var buildingHourly = [Double](repeating: 0, count: 24)
        var zoneHourly: [UUID: [Double]] = [:]
        var individualPeaks = 0.0

        for zone in project.zones {
            var hourly = [Double](repeating: 0, count: 24)

            for surface in zone.surfaces where surface.isValid {
                var contribution = [Double](repeating: 0, count: 24)

                if case .assembly(let assembly) = surface.construction {
                    // Opaque and massive: solve the heat equation across the design day.
                    let solAir = (0..<24).map { hour in
                        TransientConduction.solAirTemperature(
                            outdoorF: outdoor[hour],
                            irradiance: irradiance[surface.orientation]?[hour] ?? 0,
                            absorptance: assembly.solarAbsorptance,
                            tilt: surface.orientation.tilt)
                    }
                    let response = try TransientConduction.solve(assembly: assembly,
                                                                 solAir: solAir, roomF: room)
                    for hour in 0..<24 {
                        contribution[hour] = response.hourlyFlux[hour] * surface.areaSquareFeet
                    }
                } else {
                    // Glazing and hand-entered construction: conduction on air temperature,
                    // plus transmitted solar. Both follow the sun without delay.
                    for hour in 0..<24 {
                        let conduction = surface.uValue * surface.areaSquareFeet * (outdoor[hour] - room)
                        let solar = surface.category.admitsSolarGain
                            ? surface.areaSquareFeet * surface.solarHeatGainCoefficient
                              * (irradiance[surface.orientation]?[hour] ?? 0)
                            : 0
                        contribution[hour] = conduction + solar
                    }
                }

                individualPeaks += contribution.max() ?? 0
                for hour in 0..<24 { hourly[hour] += contribution[hour] }
            }

            // Infiltration and ventilation follow outdoor air through the day.
            let outdoorAirCFM = zone.airExchange.infiltrationCFM(volumeCubicFeet: zone.volumeCubicFeet)
                              + zone.airExchange.ventilationCFM
            if outdoorAirCFM > 0 {
                var air = [Double](repeating: 0, count: 24)
                for hour in 0..<24 {
                    air[hour] = sensibleCoefficient * outdoorAirCFM * (outdoor[hour] - room)
                }
                individualPeaks += air.max() ?? 0
                for hour in 0..<24 { hourly[hour] += air[hour] }
            }

            // Internal gains are held constant. Manual J's residential assumption is a
            // steady occupancy rather than a schedule, and a schedule the engineer has
            // not supplied would be invented.
            let internalSensible = internalGainComponents(zone: zone, procedure: project.procedure)
                .filter { !$0.name.hasSuffix("latent") }
                .reduce(0) { $0 + $1.btuh }
            if internalSensible > 0 {
                individualPeaks += internalSensible
                for hour in 0..<24 { hourly[hour] += internalSensible }
            }

            zoneHourly[zone.id] = hourly
            for hour in 0..<24 { buildingHourly[hour] += hourly[hour] }
        }

        let peak = buildingHourly.enumerated().max { $0.element < $1.element }
        let peakHour = peak?.offset ?? 15
        var atPeak: [UUID: Double] = [:]
        for (id, hourly) in zoneHourly { atPeak[id] = hourly[peakHour] }

        return CoolingProfile(hourlySensible: buildingHourly,
                              peakHour: peakHour,
                              peakSensible: peak?.element ?? 0,
                              sumOfIndividualPeaks: individualPeaks,
                              zoneSensibleAtPeak: atPeak)
    }
}
