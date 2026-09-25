import Foundation

/// The hourly cooling load across the design day, and the coincident peak it finds.
///
/// This is the sizing basis. `LoadCalculator.calculate(project:)` reports each zone at the
/// hour the building total peaks, and equipment, airflow, room CFM and duct sizes all
/// follow from it.
///
/// Surfaces do not peak together. An east window peaks at 08:00, a west wall at 16:00, a
/// block wall at 21:00. Adding each surface's own maximum produces a building peak that
/// never occurs and sizes equipment for it. The coincident peak — the largest the sum ever
/// reaches — is the figure the whole cascade is built on.
public struct CoolingProfile: Sendable, Equatable {
    /// Sensible cooling load for each hour of the design day, Btu/h.
    public let hourlySensible: [Double]
    /// Hour at which the building total peaks.
    public let peakHour: Int
    /// Sensible load at that hour. This is the design sensible load.
    public let peakSensible: Double
    /// Sum of each surface's individual maximum, regardless of when it occurs.
    public let sumOfIndividualPeaks: Double
    /// Per-zone sensible load at the building's peak hour.
    public let zoneSensibleAtPeak: [UUID: Double]

    /// How much the coincident peak saves over summing individual maxima.
    public var diversityFactor: Double {
        sumOfIndividualPeaks > 0 ? peakSensible / sumOfIndividualPeaks : 1
    }
}

/// One surface's contribution across the design day, with the detail needed to explain
/// the hour the building peaks at.
struct SurfaceProfile {
    let surface: Surface
    let hourly: [Double]
    let isTransient: Bool
    let conductionHourly: [Double]
    let solarHourly: [Double]
    /// Sol-air temperature driving a transient surface, for the trace.
    let solAirHourly: [Double]?
}

/// Builds the design day: hourly profiles per surface, the building peak, and the
/// component breakdown evaluated at that hour.
///
/// One pass produces both the profile and the components, so the breakdown shown to an
/// engineer necessarily sums to the headline figure. Computing them separately is how a
/// detail view drifts out of agreement with the total it is supposed to explain.
public enum DesignDay {

    public struct ZoneResult: Sendable {
        public let zoneID: UUID
        public let zoneName: String
        public let hourly: [Double]
        public let sensibleAtPeak: Double
        public let componentsAtPeak: [LoadComponent]
    }

    public struct Result: Sendable {
        public let profile: CoolingProfile
        public let zones: [ZoneResult]
        public let outdoorHourly: [Double]
    }

    public static func solve(project: Project) throws -> Result {
        let conditions = project.designConditions
        let day = Solar.representativeDay(month: conditions.coolingDesignMonth)
        let room = conditions.indoorSummerDryBulbF
        let sensibleCoefficient = try Psychrometrics.sensibleCoefficient(altitudeFeet: conditions.altitudeFeet)

        // Hourly weather and solar, shared by every surface in the building.
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

        // Per-zone hourly totals and the pieces that made them.
        var zoneSurfaces: [UUID: [SurfaceProfile]] = [:]
        var zoneAirHourly: [UUID: [Double]] = [:]
        var zoneAirCFM: [UUID: Double] = [:]
        var zoneInternal: [UUID: [LoadComponent]] = [:]
        var zoneHourly: [UUID: [Double]] = [:]
        var buildingHourly = [Double](repeating: 0, count: 24)
        var individualPeaks = 0.0

        for zone in project.zones {
            var hourly = [Double](repeating: 0, count: 24)
            var profiles: [SurfaceProfile] = []

            for surface in zone.surfaces where surface.isValid {
                var conduction = [Double](repeating: 0, count: 24)
                var solar = [Double](repeating: 0, count: 24)
                var solAir: [Double]?
                var transient = false

                if case .assembly(let assembly) = surface.construction,
                   surface.coolingEquivalentDeltaTF == nil {
                    // Opaque and massive: solve the heat equation across the design day.
                    // Solar is already inside the sol-air boundary, so there is no
                    // separate solar term to add — adding one would double-count it.
                    let boundary = (0..<24).map { hour in
                        TransientConduction.solAirTemperature(
                            outdoorF: outdoor[hour],
                            irradiance: irradiance[surface.orientation]?[hour] ?? 0,
                            absorptance: assembly.solarAbsorptance,
                            tilt: surface.orientation.tilt)
                    }
                    let response = try TransientConduction.solve(assembly: assembly,
                                                                 solAir: boundary, roomF: room)
                    for hour in 0..<24 {
                        conduction[hour] = response.hourlyFlux[hour] * surface.areaSquareFeet
                    }
                    solAir = boundary
                    transient = true
                } else if let equivalent = surface.coolingEquivalentDeltaTF {
                    // An engineer-supplied equivalent difference is held all day. It is a
                    // book value for a peak condition and carries no shape of its own.
                    for hour in 0..<24 {
                        conduction[hour] = surface.uValue * surface.areaSquareFeet * equivalent
                    }
                } else {
                    // Glazing and hand-entered construction: conduction on air
                    // temperature, plus transmitted solar. Both follow the sun directly.
                    for hour in 0..<24 {
                        conduction[hour] = surface.uValue * surface.areaSquareFeet * (outdoor[hour] - room)
                        if surface.category.admitsSolarGain {
                            solar[hour] = surface.areaSquareFeet * surface.solarHeatGainCoefficient
                                        * (irradiance[surface.orientation]?[hour] ?? 0)
                        }
                    }
                }

                let total = (0..<24).map { conduction[$0] + solar[$0] }
                individualPeaks += total.max() ?? 0
                for hour in 0..<24 { hourly[hour] += total[hour] }
                profiles.append(SurfaceProfile(surface: surface, hourly: total,
                                               isTransient: transient,
                                               conductionHourly: conduction,
                                               solarHourly: solar,
                                               solAirHourly: solAir))
            }

            // Infiltration and ventilation follow outdoor air through the day.
            let outdoorAirCFM = zone.airExchange.infiltrationCFM(volumeCubicFeet: zone.volumeCubicFeet)
                              + zone.airExchange.ventilationCFM
            var air = [Double](repeating: 0, count: 24)
            if outdoorAirCFM > 0 {
                for hour in 0..<24 {
                    air[hour] = sensibleCoefficient * outdoorAirCFM * (outdoor[hour] - room)
                }
                individualPeaks += air.max() ?? 0
                for hour in 0..<24 { hourly[hour] += air[hour] }
            }

            // Internal gains are held constant. Manual J's residential assumption is a
            // steady occupancy; a schedule the engineer has not supplied would be invented.
            let internals = LoadCalculator.internalGainComponents(zone: zone, procedure: project.procedure)
                .filter { !$0.name.hasSuffix("latent") }
            let internalSensible = internals.reduce(0) { $0 + $1.btuh }
            if internalSensible > 0 {
                individualPeaks += internalSensible
                for hour in 0..<24 { hourly[hour] += internalSensible }
            }

            zoneSurfaces[zone.id] = profiles
            zoneAirHourly[zone.id] = air
            zoneAirCFM[zone.id] = outdoorAirCFM
            zoneInternal[zone.id] = internals
            zoneHourly[zone.id] = hourly
            for hour in 0..<24 { buildingHourly[hour] += hourly[hour] }
        }

        // The building peak. Every component below is reported at this hour, so the
        // breakdown sums to the headline by construction.
        let peak = buildingHourly.enumerated().max { $0.element < $1.element }
        let peakHour = peak?.offset ?? 15

        var zones: [ZoneResult] = []
        var atPeak: [UUID: Double] = [:]
        for zone in project.zones {
            var components: [LoadComponent] = []
            for profile in zoneSurfaces[zone.id] ?? [] {
                let surface = profile.surface
                if profile.isTransient {
                    let solAirAtPeak = profile.solAirHourly?[peakHour] ?? 0
                    components.append(LoadComponent(
                        name: "\(surface.name) — conduction",
                        btuh: profile.conductionHourly[peakHour],
                        formula: "ρc ∂T/∂t = ∂/∂x(k ∂T/∂x), solved across the design day",
                        substitution: String(format: "At %02d:00 the sol-air boundary is %.1f °F and the assembly delivers %.0f Btu/h through %.0f ft²",
                                             peakHour, solAirAtPeak,
                                             profile.conductionHourly[peakHour], surface.areaSquareFeet),
                        reference: "Transient conduction — thermal mass carries lag and damping"))
                } else {
                    let equivalent = surface.coolingEquivalentDeltaTF
                    let deltaT = equivalent ?? (outdoor[peakHour] - room)
                    components.append(LoadComponent(
                        name: "\(surface.name) — conduction",
                        btuh: profile.conductionHourly[peakHour],
                        formula: "q = U · A · ΔT,  U = 1/R",
                        substitution: String(format: "q = %.3f · %.1f ft² · %.1f °F = %.0f Btu/h at %02d:00",
                                             surface.uValue, surface.areaSquareFeet, deltaT,
                                             profile.conductionHourly[peakHour], peakHour),
                        reference: equivalent == nil ? "Conduction on outdoor air"
                                                     : "Engineer-supplied equivalent temperature difference"))
                    if surface.category.admitsSolarGain {
                        components.append(LoadComponent(
                            name: "\(surface.name) — solar gain",
                            btuh: profile.solarHourly[peakHour],
                            formula: "q = A · SHGC · E",
                            substitution: String(format: "q = %.1f ft² · %.2f · %.0f Btu/h·ft² = %.0f Btu/h at %02d:00",
                                                 surface.areaSquareFeet, surface.solarHeatGainCoefficient,
                                                 irradiance[surface.orientation]?[peakHour] ?? 0,
                                                 profile.solarHourly[peakHour], peakHour),
                            reference: String(format: "Bird clear-sky irradiance on %@ at %.1f°N",
                                              surface.orientation.rawValue, conditions.latitude)))
                    }
                }
            }

            if let cfm = zoneAirCFM[zone.id], cfm > 0, let air = zoneAirHourly[zone.id] {
                components.append(LoadComponent(
                    name: "Infiltration and ventilation — sensible",
                    btuh: air[peakHour],
                    formula: "q_s = 1.08 · CFM · ΔT  (1.08 corrected for altitude)",
                    substitution: String(format: "q_s = %.3f · %.0f CFM · %.1f °F = %.0f Btu/h at %02d:00",
                                         sensibleCoefficient, cfm, outdoor[peakHour] - room,
                                         air[peakHour], peakHour),
                    reference: "Manual J — infiltration, at \(Int(conditions.altitudeFeet)) ft"))
            }
            components.append(contentsOf: zoneInternal[zone.id] ?? [])

            let hourly = zoneHourly[zone.id] ?? [Double](repeating: 0, count: 24)
            atPeak[zone.id] = hourly[peakHour]
            zones.append(ZoneResult(zoneID: zone.id, zoneName: zone.name, hourly: hourly,
                                    sensibleAtPeak: hourly[peakHour],
                                    componentsAtPeak: components))
        }

        let profile = CoolingProfile(hourlySensible: buildingHourly,
                                     peakHour: peakHour,
                                     peakSensible: peak?.element ?? 0,
                                     sumOfIndividualPeaks: individualPeaks,
                                     zoneSensibleAtPeak: atPeak)
        return Result(profile: profile, zones: zones, outdoorHourly: outdoor)
    }
}

public extension LoadCalculator {
    /// Convenience for callers that only want the profile.
    static func coolingProfile(project: Project) throws -> CoolingProfile {
        try DesignDay.solve(project: project).profile
    }
}
