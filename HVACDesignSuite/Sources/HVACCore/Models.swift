import Foundation

// MARK: - Design conditions

/// Which ACCA load procedure governs a project.
public enum LoadProcedure: String, Codable, Sendable, CaseIterable, Identifiable {
    case residentialManualJ = "Manual J"
    case commercialManualN = "Manual N"
    public var id: String { rawValue }

    public var summary: String {
        switch self {
        case .residentialManualJ: "Residential — low-density occupancy, default appliance gains"
        case .commercialManualN: "Commercial — explicit lighting, occupancy and appliance gains"
        }
    }
}

/// Outdoor design weather and the indoor targets held against it.
///
/// The outdoor defaults are the values LoadSight derived from ten years of NOAA
/// Integrated Surface Database observations at Piedmont Triad International (station
/// 72317013723), 2014–2023. They are derived values, not ASHRAE published design
/// conditions, and are stated as such wherever they are printed.
public struct DesignConditions: Codable, Sendable, Equatable {
    public var siteName: String
    public var altitudeFeet: Double

    /// Dry bulb exceeded 99.6% of annual hours, °F.
    public var winterOutdoorDryBulbF: Double
    /// Dry bulb exceeded 0.4% of annual hours, °F.
    public var summerOutdoorDryBulbF: Double
    /// Mean wet bulb coincident with the summer design dry bulb, °F.
    public var summerOutdoorWetBulbF: Double
    /// Mean daily dry-bulb range of the warmest month, °F. Manual J uses this to
    /// classify a climate as low, medium or high daily range.
    public var summerDailyRangeF: Double

    public var indoorWinterDryBulbF: Double
    public var indoorSummerDryBulbF: Double
    public var indoorSummerRelativeHumidityPercent: Double

    /// Attribution for the outdoor values, carried onto any printed output.
    public var weatherSource: String

    public static let piedmontTriad = DesignConditions(
        siteName: "Piedmont Triad, NC",
        altitudeFeet: 902,
        winterOutdoorDryBulbF: 18.0,
        summerOutdoorDryBulbF: 91.9,
        summerOutdoorWetBulbF: 74.1,
        summerDailyRangeF: 17.5,
        indoorWinterDryBulbF: 70,
        indoorSummerDryBulbF: 75,
        indoorSummerRelativeHumidityPercent: 50,
        weatherSource: "Derived from NOAA ISD observations at Piedmont Triad International "
                     + "(72317013723), 2014–2023. Not ASHRAE published design conditions.")

    /// Heating design temperature difference, °F. ΔT = indoor target − outdoor winter design.
    public var heatingDeltaT: Double { indoorWinterDryBulbF - winterOutdoorDryBulbF }

    /// Cooling design temperature difference, °F. ΔT = outdoor summer design − indoor target.
    public var coolingDeltaT: Double { summerOutdoorDryBulbF - indoorSummerDryBulbF }

    /// Manual J daily-range classification, which drives its temperature-swing corrections.
    public var dailyRangeClass: String {
        switch summerDailyRangeF {
        case ..<16: "Low"
        case 16..<26: "Medium"
        default: "High"
        }
    }
}

// MARK: - Envelope

/// What kind of envelope element a surface is. The category selects which design
/// temperature difference applies and whether solar gain is computed.
public enum SurfaceCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case wall = "Exterior Wall"
    case roof = "Roof / Ceiling"
    case window = "Window / Glazing"
    case door = "Door"
    case floor = "Floor"
    public var id: String { rawValue }

    /// Only glazing carries a solar gain term in this engine.
    public var admitsSolarGain: Bool { self == .window }
}

/// Compass orientation, used for the fenestration solar term.
public enum Orientation: String, Codable, Sendable, CaseIterable, Identifiable {
    case north = "N", northEast = "NE", east = "E", southEast = "SE"
    case south = "S", southWest = "SW", west = "W", northWest = "NW"
    case horizontal = "Horizontal"
    public var id: String { rawValue }

    /// Provisional peak clear-sky irradiance on a vertical surface, Btu/h·ft².
    ///
    /// These stand in until the radiant-time-series engine supplies clear-sky irradiance
    /// derived from NREL NSRDB for the actual site, date and hour. They are the single
    /// largest approximation in this build, they are not latitude-specific, and a cooling
    /// load that leans on them should be treated as provisional.
    public var provisionalPeakIrradiance: Double {
        switch self {
        case .north: 35
        case .northEast, .northWest: 90
        case .east, .west: 165
        case .southEast, .southWest: 140
        case .south: 105
        case .horizontal: 235
        }
    }
}

/// One envelope element.
///
/// Stored as a value type: copying a `Zone` copies its surfaces, so nothing in the
/// calculation chain can mutate a caller's model behind its back. Stored properties are
/// `var` because SwiftUI forms bind to them directly; value semantics, not immutable
/// members, is what supplies the decoupling the brief asked for.
public struct Surface: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var category: SurfaceCategory
    public var areaSquareFeet: Double
    /// Thermal resistance, h·ft²·°F/Btu. U is its reciprocal.
    public var rValue: Double
    public var orientation: Orientation
    /// Fraction of solar gain admitted, combining glazing SHGC with interior shading.
    public var solarHeatGainCoefficient: Double
    /// Optional cooling equivalent temperature difference, °F.
    ///
    /// Plain ΔT understates a sunlit roof badly, because it ignores the sol-air rise of a
    /// dark surface under peak irradiance. Manual J handles this with tabulated
    /// equivalent differences. Setting this overrides the plain ΔT for cooling only.
    public var coolingEquivalentDeltaTF: Double?

    public init(id: UUID = UUID(), name: String, category: SurfaceCategory,
                areaSquareFeet: Double, rValue: Double,
                orientation: Orientation = .north,
                solarHeatGainCoefficient: Double = 0.30,
                coolingEquivalentDeltaTF: Double? = nil) {
        self.id = id; self.name = name; self.category = category
        self.areaSquareFeet = areaSquareFeet; self.rValue = rValue
        self.orientation = orientation
        self.solarHeatGainCoefficient = solarHeatGainCoefficient
        self.coolingEquivalentDeltaTF = coolingEquivalentDeltaTF
    }

    /// U = 1 / R, Btu/(h·ft²·°F).
    public var uValue: Double { rValue > 0 ? 1 / rValue : 0 }

    public var isValid: Bool { areaSquareFeet > 0 && rValue > 0 }
}

// MARK: - Internal gains

/// Occupancy and equipment gains for a space. Cooling only — Manual J and Manual N both
/// disregard internal gains for heating, since design heating occurs at night with the
/// building unoccupied and lights off.
public struct InternalGains: Codable, Sendable, Equatable {
    public var occupantCount: Double
    /// Sensible gain per person, Btu/h. Manual J's low-density residential default.
    public var sensiblePerOccupant: Double
    /// Latent gain per person, Btu/h.
    public var latentPerOccupant: Double

    /// Manual N lighting density, W/ft². Converted at 3.412 Btu/h per watt.
    public var lightingWattsPerSquareFoot: Double
    /// Manual N explicit appliance gains, Btu/h.
    public var applianceSensibleBtuh: Double
    public var applianceLatentBtuh: Double

    public static let residentialDefault = InternalGains(
        occupantCount: 0, sensiblePerOccupant: 230, latentPerOccupant: 200,
        lightingWattsPerSquareFoot: 0, applianceSensibleBtuh: 0, applianceLatentBtuh: 0)

    public static let commercialDefault = InternalGains(
        occupantCount: 0, sensiblePerOccupant: 250, latentPerOccupant: 200,
        lightingWattsPerSquareFoot: 1.0, applianceSensibleBtuh: 0, applianceLatentBtuh: 0)

    public static let wattsToBtuh = 3.412142
}

/// How outdoor air enters a space.
public struct AirExchange: Codable, Sendable, Equatable {
    /// Infiltration expressed as air changes per hour at design conditions.
    public var airChangesPerHour: Double
    /// Mechanical ventilation delivered to the space, CFM.
    public var ventilationCFM: Double

    public static let tight = AirExchange(airChangesPerHour: 0.25, ventilationCFM: 0)
    public static let average = AirExchange(airChangesPerHour: 0.50, ventilationCFM: 0)

    /// Infiltration airflow, CFM, from ACH and room volume: CFM = ACH · volume / 60.
    public func infiltrationCFM(volumeCubicFeet: Double) -> Double {
        airChangesPerHour * volumeCubicFeet / 60
    }
}

// MARK: - Zone

/// A conditioned space. Manual J calls it a room; Manual N calls it a zone.
public struct Zone: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var floorAreaSquareFeet: Double
    public var ceilingHeightFeet: Double
    public var surfaces: [Surface]
    public var internalGains: InternalGains
    public var airExchange: AirExchange

    public init(id: UUID = UUID(), name: String,
                floorAreaSquareFeet: Double, ceilingHeightFeet: Double = 8,
                surfaces: [Surface] = [],
                internalGains: InternalGains = .residentialDefault,
                airExchange: AirExchange = .average) {
        self.id = id; self.name = name
        self.floorAreaSquareFeet = floorAreaSquareFeet
        self.ceilingHeightFeet = ceilingHeightFeet
        self.surfaces = surfaces
        self.internalGains = internalGains
        self.airExchange = airExchange
    }

    public var volumeCubicFeet: Double { floorAreaSquareFeet * ceilingHeightFeet }
}

// MARK: - Equipment

public enum EquipmentType: String, Codable, Sendable, CaseIterable, Identifiable {
    case airConditioner = "Air Conditioner"
    case heatPump = "Heat Pump"
    case furnace = "Furnace"
    public var id: String { rawValue }
}

/// Values transcribed from a manufacturer's expanded performance data sheet.
///
/// Manual S is explicit that selection is made against expanded performance data at the
/// design condition, not against nameplate tonnage, which is why every capacity here is
/// entered by hand rather than inferred from a model number.
public struct EquipmentSpec: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var manufacturer: String
    public var modelNumber: String
    public var type: EquipmentType

    /// Total cooling capacity at the design condition, Btu/h.
    public var totalCoolingCapacityBtuh: Double
    /// Sensible cooling capacity at the design condition, Btu/h.
    public var sensibleCoolingCapacityBtuh: Double
    /// Heating capacity at the design condition, Btu/h.
    public var heatingCapacityBtuh: Double
    /// Maximum rated blower airflow, CFM.
    public var maximumAirflowCFM: Double
    /// Blower external static pressure available at the design airflow, inches w.g.
    public var blowerExternalStaticPressure: Double

    public init(id: UUID = UUID(), manufacturer: String = "", modelNumber: String = "",
                type: EquipmentType = .heatPump,
                totalCoolingCapacityBtuh: Double = 0,
                sensibleCoolingCapacityBtuh: Double = 0,
                heatingCapacityBtuh: Double = 0,
                maximumAirflowCFM: Double = 0,
                blowerExternalStaticPressure: Double = 0.5) {
        self.id = id; self.manufacturer = manufacturer; self.modelNumber = modelNumber
        self.type = type
        self.totalCoolingCapacityBtuh = totalCoolingCapacityBtuh
        self.sensibleCoolingCapacityBtuh = sensibleCoolingCapacityBtuh
        self.heatingCapacityBtuh = heatingCapacityBtuh
        self.maximumAirflowCFM = maximumAirflowCFM
        self.blowerExternalStaticPressure = blowerExternalStaticPressure
    }

    /// Latent capacity is whatever total capacity is left after sensible, Btu/h.
    public var latentCoolingCapacityBtuh: Double {
        max(0, totalCoolingCapacityBtuh - sensibleCoolingCapacityBtuh)
    }

    /// Sensible heat ratio of the equipment at the design condition.
    public var sensibleHeatRatio: Double? {
        totalCoolingCapacityBtuh > 0 ? sensibleCoolingCapacityBtuh / totalCoolingCapacityBtuh : nil
    }
}

/// The Manual S acceptance window, held as data rather than hard-coded.
///
/// The bounds below are the ones specified for this build. Manual S states its limits by
/// equipment type and climate, and the exact percentages should be confirmed against the
/// current edition before any output is submitted for permit. They are exposed here so
/// that confirmation is a data change rather than a code change.
public struct SizingLimits: Codable, Sendable, Equatable {
    public var coolingMinimumFraction: Double
    public var coolingMaximumFraction: Double
    public var heatPumpHeatingMaximumFraction: Double
    public var furnaceHeatingMaximumFraction: Double

    public static let standard = SizingLimits(
        coolingMinimumFraction: 0.95,
        coolingMaximumFraction: 1.15,
        heatPumpHeatingMaximumFraction: 1.25,
        furnaceHeatingMaximumFraction: 1.40)
}

// MARK: - Duct

public enum DuctRole: String, Codable, Sendable, CaseIterable, Identifiable {
    case supplyTrunk = "Supply Trunk"
    case supplyBranch = "Supply Branch"
    case returnTrunk = "Return Trunk"
    case returnBranch = "Return Branch"
    public var id: String { rawValue }

    /// Maximum design velocity, FPM, above which a residential run is audible.
    /// Trunks tolerate more than branches because branches terminate at a register in
    /// an occupied room.
    public var maximumVelocityFPM: Double {
        switch self {
        case .supplyTrunk, .returnTrunk: 900
        case .supplyBranch: 600
        case .returnBranch: 600
        }
    }
}

/// A fitting and the equivalent length it contributes, ft.
///
/// Manual D assigns each fitting an equivalent length from its own tables. Those tables
/// are ACCA's; the values a user enters here come from their copy of the manual.
public struct Fitting: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var equivalentLengthFeet: Double
    public var count: Int

    public init(id: UUID = UUID(), name: String, equivalentLengthFeet: Double, count: Int = 1) {
        self.id = id; self.name = name
        self.equivalentLengthFeet = equivalentLengthFeet; self.count = count
    }

    public var totalEquivalentLength: Double { equivalentLengthFeet * Double(count) }
}

/// One duct run, from the air handler to a register or between trunk sections.
public struct DuctRun: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var role: DuctRole
    /// Straight, measured length of the run, ft.
    public var physicalLengthFeet: Double
    public var fittings: [Fitting]
    /// The zone this branch serves. Trunks carry no single zone.
    public var servingZoneID: UUID?
    /// Absolute roughness of the duct material, ft.
    public var roughnessFeet: Double

    public init(id: UUID = UUID(), name: String, role: DuctRole,
                physicalLengthFeet: Double, fittings: [Fitting] = [],
                servingZoneID: UUID? = nil,
                roughnessFeet: Double = DuctMaterial.galvanizedSteel.roughnessFeet) {
        self.id = id; self.name = name; self.role = role
        self.physicalLengthFeet = physicalLengthFeet
        self.fittings = fittings
        self.servingZoneID = servingZoneID
        self.roughnessFeet = roughnessFeet
    }

    /// Total equivalent length of this run, ft: measured length plus every fitting.
    public var totalEquivalentLengthFeet: Double {
        physicalLengthFeet + fittings.reduce(0) { $0 + $1.totalEquivalentLength }
    }
}

/// Absolute roughness by duct material, ft.
///
/// Standard published values for duct friction work. Flexible duct is an order of
/// magnitude rougher than sheet metal and is the most common reason a built system
/// misses its design airflow.
public enum DuctMaterial: String, Codable, Sendable, CaseIterable, Identifiable {
    case galvanizedSteel = "Galvanised Steel"
    case fibrousGlassDuctBoard = "Fibrous Glass Duct Board"
    case flexibleDuctFullyExtended = "Flexible Duct (fully extended)"
    public var id: String { rawValue }

    public var roughnessFeet: Double {
        switch self {
        case .galvanizedSteel: 0.0003
        case .fibrousGlassDuctBoard: 0.003
        case .flexibleDuctFullyExtended: 0.01
        }
    }
}

/// Pressure losses between the blower and the duct system, inches w.g.
///
/// Manual D subtracts these from blower external static pressure before any duct is
/// sized. Leaving them out is the classic way to arrive at ducts that are too small.
public struct StaticPressureBudget: Codable, Sendable, Equatable {
    public var coolingCoil: Double
    public var filter: Double
    public var supplyRegisters: Double
    public var returnGrilles: Double
    public var balancingDampers: Double
    public var other: Double

    public static let typical = StaticPressureBudget(
        coolingCoil: 0.25, filter: 0.10, supplyRegisters: 0.03,
        returnGrilles: 0.03, balancingDampers: 0.03, other: 0)

    public var total: Double {
        coolingCoil + filter + supplyRegisters + returnGrilles + balancingDampers + other
    }
}

// MARK: - Project

/// The whole design. One value; copying it copies the entire state of the job.
public struct Project: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var procedure: LoadProcedure
    public var designConditions: DesignConditions
    public var zones: [Zone]
    public var equipment: EquipmentSpec
    public var sizingLimits: SizingLimits
    public var staticPressureBudget: StaticPressureBudget
    public var ductRuns: [DuctRun]
    /// Supply-air temperature difference used to convert sensible load to airflow, °F.
    public var supplyAirDeltaTF: Double

    public init(id: UUID = UUID(), name: String = "Untitled Project",
                procedure: LoadProcedure = .residentialManualJ,
                designConditions: DesignConditions = .piedmontTriad,
                zones: [Zone] = [], equipment: EquipmentSpec = EquipmentSpec(),
                sizingLimits: SizingLimits = .standard,
                staticPressureBudget: StaticPressureBudget = .typical,
                ductRuns: [DuctRun] = [], supplyAirDeltaTF: Double = 20) {
        self.id = id; self.name = name; self.procedure = procedure
        self.designConditions = designConditions; self.zones = zones
        self.equipment = equipment; self.sizingLimits = sizingLimits
        self.staticPressureBudget = staticPressureBudget
        self.ductRuns = ductRuns; self.supplyAirDeltaTF = supplyAirDeltaTF
    }
}
