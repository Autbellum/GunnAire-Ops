import Foundation

/// A building material with a published thermal resistance.
///
/// Values are thermal resistance per inch of thickness, except where a material is only
/// made in one form (a sheet of gypsum, an air film), which carries a fixed resistance.
///
/// These are physical properties of materials, the kind published in ASHRAE
/// Handbook—Fundamentals and reproduced in every building science reference. They are not
/// ACCA's Table 4A: this engine computes an assembly's U-value from its layers rather than
/// reproducing a copyrighted table of pre-computed construction numbers. That is also why
/// it is not limited to the constructions that happen to appear in the table.
///
/// **Verify before relying on a submittal.** These are standard published figures, but
/// they have not been checked against a current edition in this codebase.
public struct Material: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: String { name }
    public let name: String
    /// Resistance per inch, h·ft²·°F/Btu·in. Zero when the material has a fixed resistance.
    public let resistancePerInch: Double
    /// Fixed resistance for materials made in a single form, h·ft²·°F/Btu.
    public let fixedResistance: Double?
    public let category: Category

    public enum Category: String, Codable, Sendable, CaseIterable {
        case airFilm = "Air Film"
        case cladding = "Cladding"
        case sheathing = "Sheathing"
        case insulation = "Insulation"
        case framing = "Framing"
        case interiorFinish = "Interior Finish"
        case masonry = "Masonry"
        case flooring = "Flooring"
        case roofing = "Roofing"
    }

    public init(name: String, resistancePerInch: Double = 0,
                fixedResistance: Double? = nil, category: Category) {
        self.name = name; self.resistancePerInch = resistancePerInch
        self.fixedResistance = fixedResistance; self.category = category
    }

    /// Resistance of this material at a thickness, h·ft²·°F/Btu.
    public func resistance(thicknessInches: Double) -> Double {
        if let fixed = fixedResistance { return fixed }
        return resistancePerInch * max(0, thicknessInches)
    }
}

/// One layer of an assembly.
public struct Layer: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var material: Material
    public var thicknessInches: Double
    /// True when this layer is interrupted by framing — a cavity, essentially. The
    /// framing member replaces it along the framing path.
    public var isCavity: Bool

    public init(id: UUID = UUID(), material: Material, thicknessInches: Double, isCavity: Bool = false) {
        self.id = id; self.material = material
        self.thicknessInches = thicknessInches; self.isCavity = isCavity
    }

    public var resistance: Double { material.resistance(thicknessInches: thicknessInches) }
}

/// Framing that interrupts the insulated cavity.
public struct Framing: Codable, Sendable, Equatable {
    public let name: String
    /// Actual depth of the member, in. A nominal 2×4 is 3.5 in.
    public let depthInches: Double
    /// Fraction of the wall area occupied by framing, including plates, headers and studs.
    public let framingFactor: Double
    public let material: Material

    /// Framing fractions for common construction.
    ///
    /// These are the whole-wall fractions that account for plates, corners and headers
    /// rather than the bare stud spacing, which is why 16 in. on centre comes out near
    /// 0.25 rather than the 0.09 a naive 1.5/16 would give.
    public static let woodStud2x4at16 = Framing(name: "2×4 @ 16\" o.c.", depthInches: 3.5,
                                                framingFactor: 0.25, material: .softwoodFraming)
    public static let woodStud2x4at24 = Framing(name: "2×4 @ 24\" o.c.", depthInches: 3.5,
                                                framingFactor: 0.22, material: .softwoodFraming)
    public static let woodStud2x6at16 = Framing(name: "2×6 @ 16\" o.c.", depthInches: 5.5,
                                                framingFactor: 0.25, material: .softwoodFraming)
    public static let woodStud2x6at24 = Framing(name: "2×6 @ 24\" o.c.", depthInches: 5.5,
                                                framingFactor: 0.22, material: .softwoodFraming)
    public static let none = Framing(name: "None", depthInches: 0, framingFactor: 0,
                                     material: .softwoodFraming)
}

/// A complete envelope assembly, from outside air to inside air.
public struct Assembly: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var category: SurfaceCategory
    public var layers: [Layer]
    public var framing: Framing
    /// Absorptance of the exterior surface, used for the sol-air equivalent difference.
    /// Dark surfaces run far hotter than light ones under the same sun.
    public var solarAbsorptance: Double

    public init(id: UUID = UUID(), name: String, category: SurfaceCategory,
                layers: [Layer], framing: Framing = .none, solarAbsorptance: Double = 0.70) {
        self.id = id; self.name = name; self.category = category
        self.layers = layers; self.framing = framing
        self.solarAbsorptance = solarAbsorptance
    }

    /// Resistance along the path through the insulated cavity, h·ft²·°F/Btu.
    public var cavityPathResistance: Double {
        layers.reduce(0) { $0 + $1.resistance }
    }

    /// Resistance along the path through the framing member.
    ///
    /// The framing member replaces the cavity layer over its own depth. A 2×6 stud beside
    /// R-21 batt is the reason a nominally R-21 wall performs nearer R-16.
    public var framingPathResistance: Double {
        guard framing.framingFactor > 0 else { return cavityPathResistance }
        return layers.reduce(0) { total, layer in
            if layer.isCavity {
                return total + framing.material.resistance(thicknessInches: framing.depthInches)
            }
            return total + layer.resistance
        }
    }

    /// Area-weighted U-value, Btu/(h·ft²·°F).
    ///
    /// Parallel paths are combined on conductance, not on resistance — averaging R-values
    /// overstates the assembly, because heat takes the easy path. This is the same
    /// parallel-path method ACCA uses to build Table 4A in the first place.
    ///
    ///   U = FF · (1/R_framing) + (1 − FF) · (1/R_cavity)
    public var uValue: Double {
        let cavity = cavityPathResistance
        let framed = framingPathResistance
        guard cavity > 0, framed > 0 else { return 0 }
        let fraction = framing.framingFactor
        return fraction * (1 / framed) + (1 - fraction) * (1 / cavity)
    }

    /// Effective whole-assembly resistance, h·ft²·°F/Btu.
    public var effectiveR: Double { uValue > 0 ? 1 / uValue : 0 }

    /// Nominal resistance — what the insulation label claims, before framing.
    public var nominalR: Double { cavityPathResistance }

    /// How much of the labelled R-value the framing takes away, as a fraction.
    /// Worth showing: on a 2×4 wall it is routinely a fifth of the insulation.
    public var framingPenalty: Double {
        nominalR > 0 ? 1 - (effectiveR / nominalR) : 0
    }

    /// Cooling equivalent temperature difference for an opaque assembly, °F.
    ///
    /// The sol-air approximation: a sunlit surface sits above outdoor air by roughly
    /// α·E/h₀, where α is absorptance, E the incident irradiance and h₀ the outside film
    /// coefficient (about 4.0 Btu/h·ft²·°F at summer wind speed). Mass and lag are not
    /// modelled — that is the radiant time series — so this is an upper bound for a light
    /// assembly and overstates a masonry one.
    public func equivalentTemperatureDifference(designDeltaT: Double,
                                                irradiance: Double) -> Double {
        let outsideFilmCoefficient = 4.0
        return designDeltaT + solarAbsorptance * irradiance / outsideFilmCoefficient
    }
}

// MARK: - Material library

public extension Material {
    // Air films. ASHRAE Fundamentals surface conductances.
    static let insideAirFilmVertical = Material(name: "Inside air film (wall)", fixedResistance: 0.68, category: .airFilm)
    static let insideAirFilmHorizontal = Material(name: "Inside air film (ceiling)", fixedResistance: 0.61, category: .airFilm)
    static let outsideAirFilmWinter = Material(name: "Outside air film (15 mph)", fixedResistance: 0.17, category: .airFilm)
    static let outsideAirFilmSummer = Material(name: "Outside air film (7.5 mph)", fixedResistance: 0.25, category: .airFilm)
    static let atticAirSpace = Material(name: "Vented attic air space", fixedResistance: 0.80, category: .airFilm)

    // Framing.
    static let softwoodFraming = Material(name: "Softwood framing", resistancePerInch: 1.25, category: .framing)

    // Cladding.
    static let vinylSiding = Material(name: "Vinyl siding", fixedResistance: 0.61, category: .cladding)
    static let woodBevelSiding = Material(name: "Wood bevel siding", fixedResistance: 0.80, category: .cladding)
    static let fiberCementSiding = Material(name: "Fibre cement siding", fixedResistance: 0.21, category: .cladding)
    static let brickVeneer = Material(name: "Brick veneer (4\")", fixedResistance: 0.44, category: .masonry)
    static let stucco = Material(name: "Stucco", resistancePerInch: 0.20, category: .cladding)

    // Sheathing.
    static let osb = Material(name: "OSB / plywood", resistancePerInch: 1.25, category: .sheathing)
    static let expandedPolystyrene = Material(name: "EPS rigid foam", resistancePerInch: 3.85, category: .sheathing)
    static let extrudedPolystyrene = Material(name: "XPS rigid foam", resistancePerInch: 5.0, category: .sheathing)
    static let polyisocyanurate = Material(name: "Polyisocyanurate", resistancePerInch: 6.0, category: .sheathing)
    static let fiberboardSheathing = Material(name: "Fibreboard sheathing", resistancePerInch: 2.64, category: .sheathing)

    // Insulation.
    static let fiberglassBatt = Material(name: "Fibreglass batt", resistancePerInch: 3.14, category: .insulation)
    static let mineralWoolBatt = Material(name: "Mineral wool batt", resistancePerInch: 3.70, category: .insulation)
    static let blownCellulose = Material(name: "Blown cellulose", resistancePerInch: 3.50, category: .insulation)
    static let blownFiberglass = Material(name: "Blown fibreglass", resistancePerInch: 2.80, category: .insulation)
    static let openCellSprayFoam = Material(name: "Open-cell spray foam", resistancePerInch: 3.70, category: .insulation)
    static let closedCellSprayFoam = Material(name: "Closed-cell spray foam", resistancePerInch: 6.50, category: .insulation)

    // Interior finish.
    static let gypsumBoardHalf = Material(name: "Gypsum board ½\"", fixedResistance: 0.45, category: .interiorFinish)
    static let gypsumBoardFiveEighths = Material(name: "Gypsum board ⅝\"", fixedResistance: 0.56, category: .interiorFinish)

    // Masonry and floors.
    static let concreteBlock8 = Material(name: "Concrete block 8\"", fixedResistance: 1.11, category: .masonry)
    static let pouredConcrete = Material(name: "Poured concrete", resistancePerInch: 0.08, category: .masonry)
    static let plywoodSubfloor = Material(name: "Plywood subfloor ¾\"", fixedResistance: 0.94, category: .flooring)
    static let carpetAndPad = Material(name: "Carpet and pad", fixedResistance: 2.08, category: .flooring)
    static let hardwoodFlooring = Material(name: "Hardwood ¾\"", fixedResistance: 0.68, category: .flooring)

    // Roofing.
    static let asphaltShingles = Material(name: "Asphalt shingles", fixedResistance: 0.44, category: .roofing)

    /// Everything, for a material picker.
    static let library: [Material] = [
        insideAirFilmVertical, insideAirFilmHorizontal, outsideAirFilmWinter, outsideAirFilmSummer,
        atticAirSpace, softwoodFraming,
        vinylSiding, woodBevelSiding, fiberCementSiding, brickVeneer, stucco,
        osb, expandedPolystyrene, extrudedPolystyrene, polyisocyanurate, fiberboardSheathing,
        fiberglassBatt, mineralWoolBatt, blownCellulose, blownFiberglass,
        openCellSprayFoam, closedCellSprayFoam,
        gypsumBoardHalf, gypsumBoardFiveEighths,
        concreteBlock8, pouredConcrete, plywoodSubfloor, carpetAndPad, hardwoodFlooring,
        asphaltShingles
    ]
}

// MARK: - Assembly library

public enum AssemblyLibrary {

    /// Builds a standard framed wall from its parts, so a new assembly is a choice of
    /// components rather than a table lookup.
    public static func framedWall(name: String, cladding: Material, sheathing: Material,
                                  sheathingThickness: Double, framing: Framing,
                                  cavityInsulation: Material,
                                  interior: Material = .gypsumBoardHalf,
                                  solarAbsorptance: Double = 0.70) -> Assembly {
        Assembly(name: name, category: .wall, layers: [
            Layer(material: .outsideAirFilmWinter, thicknessInches: 0),
            Layer(material: cladding, thicknessInches: 1),
            Layer(material: sheathing, thicknessInches: sheathingThickness),
            Layer(material: cavityInsulation, thicknessInches: framing.depthInches, isCavity: true),
            Layer(material: interior, thicknessInches: 0.5),
            Layer(material: .insideAirFilmVertical, thicknessInches: 0)
        ], framing: framing, solarAbsorptance: solarAbsorptance)
    }

    /// A vented attic ceiling: blown insulation on the flat, no framing penalty worth
    /// modelling because the insulation is continuous over the joists.
    public static func atticCeiling(name: String, insulation: Material,
                                    thicknessInches: Double) -> Assembly {
        Assembly(name: name, category: .roof, layers: [
            Layer(material: .atticAirSpace, thicknessInches: 0),
            Layer(material: insulation, thicknessInches: thicknessInches),
            Layer(material: .gypsumBoardHalf, thicknessInches: 0.5),
            Layer(material: .insideAirFilmHorizontal, thicknessInches: 0)
        ], framing: .none, solarAbsorptance: 0.85)
    }

    /// The assemblies that actually turn up on Piedmont Triad jobs, so the common case is
    /// a single pick with nothing typed.
    public static let standard: [Assembly] = [
        framedWall(name: "2×4 wall, R-13 batt, vinyl siding",
                   cladding: .vinylSiding, sheathing: .osb, sheathingThickness: 0.5,
                   framing: .woodStud2x4at16, cavityInsulation: .fiberglassBatt),
        framedWall(name: "2×4 wall, R-13 batt, brick veneer",
                   cladding: .brickVeneer, sheathing: .osb, sheathingThickness: 0.5,
                   framing: .woodStud2x4at16, cavityInsulation: .fiberglassBatt,
                   solarAbsorptance: 0.60),
        framedWall(name: "2×6 wall, R-21 batt, vinyl siding",
                   cladding: .vinylSiding, sheathing: .osb, sheathingThickness: 0.5,
                   framing: .woodStud2x6at16, cavityInsulation: .fiberglassBatt),
        framedWall(name: "2×6 wall, R-21 batt, 1\" XPS, fibre cement",
                   cladding: .fiberCementSiding, sheathing: .extrudedPolystyrene, sheathingThickness: 1.0,
                   framing: .woodStud2x6at16, cavityInsulation: .fiberglassBatt),
        framedWall(name: "2×4 wall, closed-cell foam, vinyl siding",
                   cladding: .vinylSiding, sheathing: .osb, sheathingThickness: 0.5,
                   framing: .woodStud2x4at16, cavityInsulation: .closedCellSprayFoam),
        atticCeiling(name: "Vented attic, R-30 blown cellulose",
                     insulation: .blownCellulose, thicknessInches: 8.6),
        atticCeiling(name: "Vented attic, R-38 blown cellulose",
                     insulation: .blownCellulose, thicknessInches: 10.9),
        atticCeiling(name: "Vented attic, R-49 blown cellulose",
                     insulation: .blownCellulose, thicknessInches: 14.0)
    ]
}
