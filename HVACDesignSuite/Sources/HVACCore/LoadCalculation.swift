import Foundation

// MARK: - Results

/// One line of a load calculation, carrying the arithmetic that produced it.
///
/// A load figure without its derivation is unreviewable. Every component records the
/// formula and the substituted values so a reviewer can follow the number back to the
/// manual it came from.
public struct LoadComponent: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let btuh: Double
    public let formula: String
    public let substitution: String
    public let reference: String

    public init(name: String, btuh: Double, formula: String,
                substitution: String, reference: String) {
        self.id = UUID(); self.name = name; self.btuh = btuh
        self.formula = formula; self.substitution = substitution; self.reference = reference
    }
}

/// The load of a single zone, broken into the targets Module 1 must produce
/// independently: sensible and latent, heating and cooling.
public struct ZoneLoad: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let zoneID: UUID
    public let zoneName: String
    public let coolingSensibleBtuh: Double
    public let coolingLatentBtuh: Double
    public let heatingBtuh: Double
    public let coolingComponents: [LoadComponent]
    public let heatingComponents: [LoadComponent]
    public let warnings: [String]

    public var coolingTotalBtuh: Double { coolingSensibleBtuh + coolingLatentBtuh }

    /// Sensible heat ratio of the space. The equipment must be able to match this, and a
    /// low value is what makes a humid-climate job hard to size.
    public var sensibleHeatRatio: Double? {
        coolingTotalBtuh > 0 ? coolingSensibleBtuh / coolingTotalBtuh : nil
    }
}

/// The whole-building load. Manual N calls this the block load.
public struct ProjectLoad: Sendable, Equatable {
    public let zoneLoads: [ZoneLoad]
    public let designConditions: DesignConditions
    public let procedure: LoadProcedure

    public var coolingSensibleBtuh: Double { zoneLoads.reduce(0) { $0 + $1.coolingSensibleBtuh } }
    public var coolingLatentBtuh: Double { zoneLoads.reduce(0) { $0 + $1.coolingLatentBtuh } }
    public var coolingTotalBtuh: Double { coolingSensibleBtuh + coolingLatentBtuh }
    public var heatingBtuh: Double { zoneLoads.reduce(0) { $0 + $1.heatingBtuh } }

    public var sensibleHeatRatio: Double? {
        coolingTotalBtuh > 0 ? coolingSensibleBtuh / coolingTotalBtuh : nil
    }

    public var coolingTons: Double { coolingTotalBtuh / 12_000 }
    public var warnings: [String] { zoneLoads.flatMap(\.warnings) }
}

// MARK: - Engine

/// Module 1 — the Manual J and Manual N load calculation.
///
/// The two procedures share every envelope and airflow term and differ only in how
/// internal gains are described: Manual J takes a low-density occupant count against
/// default per-person gains, Manual N takes explicit lighting density, occupancy and
/// appliance figures. That difference is isolated to `internalGainComponents`.
///
/// Pure functions throughout, so a recalculation can run anywhere without isolation.
public enum LoadCalculator {

    /// Peak clear-sky irradiance for every orientation at this site, Btu/h·ft².
    ///
    /// Computed once per calculation and shared across zones: the sun does not change
    /// between rooms, and scanning the design day for nine orientations is the only part
    /// of this engine with any real cost.
    public static func solarTable(for conditions: DesignConditions) -> [Orientation: Double] {
        var table: [Orientation: Double] = [:]
        for orientation in Orientation.allCases {
            table[orientation] = Solar.peakIrradiance(
                surfaceAzimuth: orientation.azimuth, tilt: orientation.tilt,
                latitude: conditions.latitude, month: conditions.coolingDesignMonth,
                altitudeFeet: conditions.altitudeFeet).irradiance
        }
        return table
    }

    public static func calculate(project: Project) throws -> ProjectLoad {
        let solar = solarTable(for: project.designConditions)
        let loads = try project.zones.map {
            try calculate(zone: $0, conditions: project.designConditions,
                          procedure: project.procedure, solar: solar)
        }
        return ProjectLoad(zoneLoads: loads,
                           designConditions: project.designConditions,
                           procedure: project.procedure)
    }

    public static func calculate(zone: Zone,
                                 conditions: DesignConditions,
                                 procedure: LoadProcedure,
                                 solar: [Orientation: Double]? = nil) throws -> ZoneLoad {
        var warnings: [String] = []
        let solarTable = solar ?? Self.solarTable(for: conditions)
        let altitude = conditions.altitudeFeet

        // Altitude-corrected airflow coefficients. At sea level these reduce to the
        // familiar 1.08 and 4840.
        let sensibleCoefficient = try Psychrometrics.sensibleCoefficient(altitudeFeet: altitude)
        let latentCoefficient = try Psychrometrics.latentCoefficient(altitudeFeet: altitude)

        // Moisture difference driving the latent load. Outdoor state comes from the
        // summer design dry bulb and its mean coincident wet bulb; indoor from the
        // target dry bulb and relative humidity.
        let outdoorSummer = try Psychrometrics.state(dryBulbF: conditions.summerOutdoorDryBulbF,
                                                     wetBulbF: conditions.summerOutdoorWetBulbF,
                                                     altitudeFeet: altitude)
        let indoorSummer = try Psychrometrics.state(dryBulbF: conditions.indoorSummerDryBulbF,
                                                    relativeHumidityPercent: conditions.indoorSummerRelativeHumidityPercent,
                                                    altitudeFeet: altitude)
        let deltaW = outdoorSummer.humidityRatio - indoorSummer.humidityRatio
        if deltaW <= 0 {
            warnings.append("The outdoor design air is drier than the indoor target, so there is no latent load to remove. Check the summer wet bulb.")
        }

        let coolingDeltaT = conditions.coolingDeltaT
        let heatingDeltaT = conditions.heatingDeltaT

        var coolingComponents: [LoadComponent] = []
        var heatingComponents: [LoadComponent] = []

        // MARK: Envelope conduction — q = U · A · ΔT, with U = 1/R.
        for surface in zone.surfaces {
            guard surface.isValid else {
                warnings.append("Surface “\(surface.name)” has a non-positive area or R-value and was skipped.")
                continue
            }
            let u = surface.uValue

            // Cooling. A sol-air equivalent difference overrides plain ΔT when supplied,
            // because a dark roof under peak sun runs far hotter than outdoor air.
            let coolingDifference = surface.coolingEquivalentDeltaTF ?? coolingDeltaT
            let coolingConduction = u * surface.areaSquareFeet * coolingDifference
            coolingComponents.append(LoadComponent(
                name: "\(surface.name) — conduction",
                btuh: coolingConduction,
                formula: "q = U · A · ΔT,  U = 1/R",
                substitution: String(format: "q = (1/%.2f) · %.1f ft² · %.1f °F = %.0f Btu/h",
                                     surface.rValue, surface.areaSquareFeet, coolingDifference, coolingConduction),
                reference: surface.coolingEquivalentDeltaTF == nil
                    ? "Manual J — envelope conduction"
                    : "Manual J — equivalent temperature difference"))

            // Solar gain through glazing.
            if surface.category.admitsSolarGain {
                let irradiance = solarTable[surface.orientation] ?? 0
                let solar = surface.areaSquareFeet * surface.solarHeatGainCoefficient * irradiance
                coolingComponents.append(LoadComponent(
                    name: "\(surface.name) — solar gain",
                    btuh: solar,
                    formula: "q = A · SHGC · E",
                    substitution: String(format: "q = %.1f ft² · %.2f · %.0f Btu/h·ft² = %.0f Btu/h",
                                         surface.areaSquareFeet, surface.solarHeatGainCoefficient,
                                         irradiance, solar),
                    reference: String(format: "Bird clear-sky peak on %@ at %.1f°N, month %d",
                                      surface.orientation.rawValue, conditions.latitude,
                                      conditions.coolingDesignMonth)))
            }

            // Heating. No solar credit is taken: design heating is a night-time condition.
            let heatingConduction = u * surface.areaSquareFeet * heatingDeltaT
            heatingComponents.append(LoadComponent(
                name: "\(surface.name) — conduction",
                btuh: heatingConduction,
                formula: "q = U · A · ΔT,  U = 1/R",
                substitution: String(format: "q = (1/%.2f) · %.1f ft² · %.1f °F = %.0f Btu/h",
                                     surface.rValue, surface.areaSquareFeet, heatingDeltaT, heatingConduction),
                reference: "Manual J — envelope conduction"))
        }

        // MARK: Infiltration and ventilation.
        let infiltrationCFM = zone.airExchange.infiltrationCFM(volumeCubicFeet: zone.volumeCubicFeet)
        let outdoorAirCFM = infiltrationCFM + zone.airExchange.ventilationCFM

        if outdoorAirCFM > 0 {
            let sensible = sensibleCoefficient * outdoorAirCFM * coolingDeltaT
            coolingComponents.append(LoadComponent(
                name: "Infiltration and ventilation — sensible",
                btuh: sensible,
                formula: "q_s = 1.08 · CFM · ΔT  (1.08 corrected for altitude)",
                substitution: String(format: "q_s = %.3f · %.0f CFM · %.1f °F = %.0f Btu/h",
                                     sensibleCoefficient, outdoorAirCFM, coolingDeltaT, sensible),
                reference: "Manual J — infiltration, at \(Int(altitude)) ft"))

            let latent = max(0, latentCoefficient * outdoorAirCFM * deltaW)
            coolingComponents.append(LoadComponent(
                name: "Infiltration and ventilation — latent",
                btuh: latent,
                formula: "q_l = 4840 · CFM · ΔW  (4840 corrected for altitude)",
                substitution: String(format: "q_l = %.0f · %.0f CFM · %.5f lb/lb = %.0f Btu/h  (ΔW = %.1f grains)",
                                     latentCoefficient, outdoorAirCFM, deltaW, latent,
                                     deltaW * Psychrometrics.grainsPerPound),
                reference: "Manual J — latent infiltration"))

            let heatingAir = sensibleCoefficient * outdoorAirCFM * heatingDeltaT
            heatingComponents.append(LoadComponent(
                name: "Infiltration and ventilation",
                btuh: heatingAir,
                formula: "q_s = 1.08 · CFM · ΔT  (1.08 corrected for altitude)",
                substitution: String(format: "q_s = %.3f · %.0f CFM · %.1f °F = %.0f Btu/h",
                                     sensibleCoefficient, outdoorAirCFM, heatingDeltaT, heatingAir),
                reference: "Manual J — infiltration"))
        }

        // MARK: Internal gains — cooling only.
        coolingComponents.append(contentsOf: internalGainComponents(zone: zone, procedure: procedure))

        let coolingSensible = coolingComponents
            .filter { !$0.name.hasSuffix("latent") }
            .reduce(0) { $0 + $1.btuh }
        let coolingLatent = coolingComponents
            .filter { $0.name.hasSuffix("latent") }
            .reduce(0) { $0 + $1.btuh }
        let heating = heatingComponents.reduce(0) { $0 + $1.btuh }

        if zone.surfaces.isEmpty {
            warnings.append("Zone “\(zone.name)” has no envelope surfaces, so its conduction load is zero.")
        }

        return ZoneLoad(id: UUID(), zoneID: zone.id, zoneName: zone.name,
                        coolingSensibleBtuh: coolingSensible,
                        coolingLatentBtuh: coolingLatent,
                        heatingBtuh: heating,
                        coolingComponents: coolingComponents,
                        heatingComponents: heatingComponents,
                        warnings: warnings)
    }

    /// The one place the two procedures diverge.
    ///
    /// Manual J: a low-density occupant count against default per-person gains.
    /// Manual N: explicit lighting density, occupancy and appliance gains, because a
    /// commercial space is dominated by them rather than by its envelope.
    static func internalGainComponents(zone: Zone, procedure: LoadProcedure) -> [LoadComponent] {
        let gains = zone.internalGains
        var components: [LoadComponent] = []

        if gains.occupantCount > 0 {
            let sensible = gains.occupantCount * gains.sensiblePerOccupant
            components.append(LoadComponent(
                name: "Occupants — sensible",
                btuh: sensible,
                formula: "q_s = people · sensible per person",
                substitution: String(format: "q_s = %.0f · %.0f Btu/h = %.0f Btu/h",
                                     gains.occupantCount, gains.sensiblePerOccupant, sensible),
                reference: "\(procedure.rawValue) — occupant gain"))

            let latent = gains.occupantCount * gains.latentPerOccupant
            components.append(LoadComponent(
                name: "Occupants — latent",
                btuh: latent,
                formula: "q_l = people · latent per person",
                substitution: String(format: "q_l = %.0f · %.0f Btu/h = %.0f Btu/h",
                                     gains.occupantCount, gains.latentPerOccupant, latent),
                reference: "\(procedure.rawValue) — occupant gain"))
        }

        if procedure == .commercialManualN, gains.lightingWattsPerSquareFoot > 0 {
            let watts = gains.lightingWattsPerSquareFoot * zone.floorAreaSquareFeet
            let sensible = watts * InternalGains.wattsToBtuh
            components.append(LoadComponent(
                name: "Lighting",
                btuh: sensible,
                formula: "q_s = W/ft² · area · 3.412",
                substitution: String(format: "q_s = %.2f W/ft² · %.0f ft² · 3.412 = %.0f Btu/h",
                                     gains.lightingWattsPerSquareFoot, zone.floorAreaSquareFeet, sensible),
                reference: "Manual N — lighting gain"))
        }

        if gains.applianceSensibleBtuh > 0 {
            components.append(LoadComponent(
                name: "Appliances",
                btuh: gains.applianceSensibleBtuh,
                formula: "Entered directly",
                substitution: String(format: "%.0f Btu/h", gains.applianceSensibleBtuh),
                reference: "\(procedure.rawValue) — appliance gain"))
        }
        if gains.applianceLatentBtuh > 0 {
            components.append(LoadComponent(
                name: "Appliances — latent",
                btuh: gains.applianceLatentBtuh,
                formula: "Entered directly",
                substitution: String(format: "%.0f Btu/h", gains.applianceLatentBtuh),
                reference: "\(procedure.rawValue) — appliance gain"))
        }

        return components
    }
}
