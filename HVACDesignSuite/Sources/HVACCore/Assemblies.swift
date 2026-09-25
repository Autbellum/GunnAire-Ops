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
/// **Verified against ASHRAE Handbook—Fundamentals Chapter 26, Table 4** ("Typical Thermal
/// Properties of Common Building and Insulating Materials: Design Values"), as published
/// by ASHRAE. Where the table gives a range, the design value used here sits inside it and
/// the choice is noted. Where the table gives a conductivity rather than a resistance, the
/// resistance per inch is its reciprocal.
public struct Material: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: String { name }
    public let name: String
    /// Resistance per inch, h·ft²·°F/Btu·in. Zero when the material has a fixed resistance.
    public let resistancePerInch: Double
    /// Fixed resistance for materials made in a single form, h·ft²·°F/Btu.
    public let fixedResistance: Double?
    public let category: Category
    /// Density, lb/ft³. Zero for an air film, which stores no heat.
    public let density: Double
    /// Specific heat, Btu/(lb·°F).
    public let specificHeat: Double
    /// Actual thickness for a material sold in one form, in.
    ///
    /// A fixed-resistance material still occupies space and still stores heat. Brick
    /// veneer is quoted as R-0.44 and is four inches of masonry; without its real
    /// thickness it would be modelled as a massless film, which is precisely backwards
    /// for the heaviest layer in the wall.
    public let nominalThicknessInches: Double?

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
                fixedResistance: Double? = nil, category: Category,
                density: Double = 0, specificHeat: Double = 0.2,
                nominalThicknessInches: Double? = nil) {
        self.name = name; self.resistancePerInch = resistancePerInch
        self.fixedResistance = fixedResistance; self.category = category
        self.density = density; self.specificHeat = specificHeat
        self.nominalThicknessInches = nominalThicknessInches
    }

    /// Volumetric heat capacity, Btu/(ft³·°F). This is what gives an assembly its lag.
    public var volumetricHeatCapacity: Double { density * specificHeat }

    /// Thermal conductivity, Btu/(h·ft·°F).
    ///
    /// Derived from resistance per inch where the material is sold by thickness, and from
    /// the fixed resistance over its actual thickness where it is not.
    public var conductivity: Double? {
        if resistancePerInch > 0 { return 1 / (12 * resistancePerInch) }
        if let fixed = fixedResistance, fixed > 0, let thickness = nominalThicknessInches, thickness > 0 {
            return (thickness / 12) / fixed
        }
        return nil
    }

    /// True when the material stores enough heat to delay a load.
    public var isMassive: Bool { volumetricHeatCapacity > 1 && conductivity != nil }

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

    /// The thickness that carries this layer's mass, ft. A fixed-resistance material
    /// uses its own nominal thickness rather than whatever the builder passed in.
    public var massThicknessFeet: Double {
        (material.nominalThicknessInches ?? thicknessInches) / 12
    }

    /// Conductivity implied by this layer's own resistance over its own thickness.
    public var conductivity: Double? {
        guard resistance > 0, massThicknessFeet > 0 else { return nil }
        return massThicknessFeet / resistance
    }

    /// True when this layer stores enough heat to shift a load in time.
    public var isMassive: Bool {
        material.volumetricHeatCapacity > 1 && conductivity != nil && massThicknessFeet > 0
    }
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
    ///
    /// Negative where the framing *outperforms* the cavity, which is the case whenever
    /// the cavity is empty — a wood stud beats an air gap. That is a real result, not an
    /// error, so it is reported rather than clamped, and the wording below changes with
    /// the sign.
    public var framingPenalty: Double {
        nominalR > 0 ? 1 - (effectiveR / nominalR) : 0
    }

    /// One phrase describing what the framing does to this assembly.
    public var framingDescription: String? {
        let magnitude = abs(framingPenalty)
        guard magnitude >= 0.01 else { return nil }
        return framingPenalty > 0
            ? String(format: "%.0f%% lost to framing", magnitude * 100)
            : String(format: "%.0f%% gained from framing (the studs beat the empty cavity)", magnitude * 100)
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
    static let softwoodFraming = Material(name: "Softwood framing", resistancePerInch: 1.25, category: .framing, density: 28, specificHeat: 0.39)

    // Cladding.
    static let vinylSiding = Material(name: "Vinyl siding", fixedResistance: 0.61, category: .cladding, density: 0, specificHeat: 0.2, nominalThicknessInches: 0.05)
    static let woodBevelSiding = Material(name: "Wood bevel siding", fixedResistance: 0.80, category: .cladding, density: 32, specificHeat: 0.33, nominalThicknessInches: 0.75)
    static let fiberCementSiding = Material(name: "Fibre cement siding", fixedResistance: 0.18, category: .cladding, density: 88, specificHeat: 0.2, nominalThicknessInches: 0.31)
    static let brickVeneer = Material(name: "Brick veneer (4\")", fixedResistance: 0.43, category: .masonry, density: 150, specificHeat: 0.19, nominalThicknessInches: 4.0)
    static let stucco = Material(name: "Stucco", resistancePerInch: 0.103, category: .cladding, density: 120, specificHeat: 0.2)

    // Sheathing.
    static let osb = Material(name: "OSB / plywood", resistancePerInch: 1.41, category: .sheathing, density: 41, specificHeat: 0.45)
    static let expandedPolystyrene = Material(name: "EPS rigid foam", resistancePerInch: 3.85, category: .sheathing, density: 1.25, specificHeat: 0.35)
    static let extrudedPolystyrene = Material(name: "XPS rigid foam", resistancePerInch: 5.0, category: .sheathing, density: 2.0, specificHeat: 0.35)
    static let polyisocyanurate = Material(name: "Polyisocyanurate", resistancePerInch: 6.0, category: .sheathing, density: 2.0, specificHeat: 0.22)
    static let fiberboardSheathing = Material(name: "Fibreboard sheathing", resistancePerInch: 2.64, category: .sheathing, density: 18, specificHeat: 0.31)

    // Insulation.
    static let fiberglassBatt = Material(name: "Fibreglass batt", resistancePerInch: 3.33, category: .insulation, density: 0.75, specificHeat: 0.2)
    static let mineralWoolBatt = Material(name: "Mineral wool batt", resistancePerInch: 3.70, category: .insulation, density: 2.5, specificHeat: 0.2)
    static let blownCellulose = Material(name: "Blown cellulose", resistancePerInch: 3.5, category: .insulation, density: 2.5, specificHeat: 0.45)
    static let blownFiberglass = Material(name: "Blown fibreglass", resistancePerInch: 2.5, category: .insulation, density: 0.6, specificHeat: 0.2)
    static let openCellSprayFoam = Material(name: "Open-cell spray foam", resistancePerInch: 3.45, category: .insulation, density: 0.45, specificHeat: 0.35)
    static let closedCellSprayFoam = Material(name: "Closed-cell spray foam", resistancePerInch: 6.50, category: .insulation, density: 2.0, specificHeat: 0.35)

    // Interior finish.
    static let gypsumBoardHalf = Material(name: "Gypsum board ½\"", fixedResistance: 0.45, category: .interiorFinish, density: 40, specificHeat: 0.27, nominalThicknessInches: 0.5)
    static let gypsumBoardFiveEighths = Material(name: "Gypsum board ⅝\"", fixedResistance: 0.57, category: .interiorFinish, density: 40, specificHeat: 0.27, nominalThicknessInches: 0.625)

    // Masonry and floors.
    static let concreteBlock8 = Material(name: "Concrete block 8\"", fixedResistance: 1.11, category: .masonry, density: 138, specificHeat: 0.22, nominalThicknessInches: 7.625)
    static let pouredConcrete = Material(name: "Poured concrete", resistancePerInch: 0.08, category: .masonry, density: 140, specificHeat: 0.2)
    static let plywoodSubfloor = Material(name: "Plywood subfloor ¾\"", fixedResistance: 1.08, category: .flooring, density: 28, specificHeat: 0.45, nominalThicknessInches: 0.75)
    static let carpetAndPad = Material(name: "Carpet and pad", fixedResistance: 2.38, category: .flooring, density: 7, specificHeat: 0.34, nominalThicknessInches: 0.5)
    static let hardwoodFlooring = Material(name: "Hardwood ¾\"", fixedResistance: 0.64, category: .flooring, density: 44, specificHeat: 0.39, nominalThicknessInches: 0.75)

    // Roofing.
    static let asphaltShingles = Material(name: "Asphalt shingles", fixedResistance: 0.44, category: .roofing, density: 70, specificHeat: 0.3, nominalThicknessInches: 0.25)

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

    /// A cavity insulation sold by its rated R rather than by thickness.
    ///
    /// Batts are specified and bought as "R-13", not as so many inches of a material with
    /// a conductivity. An R-13 batt and an R-11 batt both fill a 3.5 in. cavity; they
    /// differ in density, not in depth. Deriving cavity R from a single conductivity
    /// times the stud depth therefore gets the product wrong — it turned an assembly
    /// named "R-13 batt" into R-11.7 — so the rated value is the input.
    public static func ratedBatt(_ ratedR: Double, density: Double = 0.9) -> Material {
        Material(name: String(format: "R-%.0f batt", ratedR), fixedResistance: ratedR,
                 category: .insulation, density: density, specificHeat: 0.20)
    }

    /// Builds a standard framed wall from its parts, so a new assembly is a choice of
    /// components rather than a table lookup.
    ///
    /// `cavityRatedR` fills the stud cavity with insulation of that rated value. Pass
    /// `cavityInsulation` instead where the cavity is filled with a material specified by
    /// thickness, such as spray foam.
    public static func framedWall(name: String, cladding: Material, sheathing: Material,
                                  sheathingThickness: Double, framing: Framing,
                                  cavityInsulation: Material? = nil,
                                  cavityRatedR: Double? = nil,
                                  interior: Material = .gypsumBoardHalf,
                                  solarAbsorptance: Double = 0.70) -> Assembly {
        let cavity = cavityRatedR.map { ratedBatt($0) } ?? cavityInsulation ?? .fiberglassBatt
        return Assembly(name: name, category: .wall, layers: [
            Layer(material: .outsideAirFilmWinter, thicknessInches: 0),
            Layer(material: cladding, thicknessInches: 1),
            Layer(material: sheathing, thicknessInches: sheathingThickness),
            Layer(material: cavity, thicknessInches: framing.depthInches, isCavity: true),
            Layer(material: interior, thicknessInches: 0.5),
            Layer(material: .insideAirFilmVertical, thicknessInches: 0)
        ], framing: framing, solarAbsorptance: solarAbsorptance)
    }

    /// A vented attic ceiling: blown insulation on the flat, no framing penalty worth
    /// modelling because the insulation is continuous over the joists.
    public static func atticCeiling(name: String, insulation: Material? = nil,
                                    thicknessInches: Double = 0,
                                    ratedR: Double? = nil) -> Assembly {
        let blanket = ratedR.map { ratedBatt($0, density: 1.6) } ?? insulation ?? .blownCellulose
        return Assembly(name: name, category: .roof, layers: [
            Layer(material: .atticAirSpace, thicknessInches: 0),
            Layer(material: blanket, thicknessInches: thicknessInches),
            Layer(material: .gypsumBoardHalf, thicknessInches: 0.5),
            Layer(material: .insideAirFilmHorizontal, thicknessInches: 0)
        ], framing: .none, solarAbsorptance: 0.85)
    }

    /// A floor over an unconditioned crawl space or basement — the Piedmont default.
    public static func framedFloor(name: String, insulation: Material? = nil,
                                   thicknessInches: Double = 0,
                                   ratedR: Double? = nil,
                                   finish: Material = .carpetAndPad) -> Assembly {
        let cavity = ratedR.map { ratedBatt($0) } ?? insulation ?? .fiberglassBatt
        return Assembly(name: name, category: .floor, layers: [
            Layer(material: .atticAirSpace, thicknessInches: 0),
            Layer(material: cavity, thicknessInches: thicknessInches, isCavity: true),
            Layer(material: .plywoodSubfloor, thicknessInches: 0.75),
            Layer(material: finish, thicknessInches: 0),
            Layer(material: .insideAirFilmHorizontal, thicknessInches: 0)
        ], framing: Framing(name: "2×10 joists @ 16\" o.c.", depthInches: 9.25,
                            framingFactor: 0.13, material: .softwoodFraming))
    }

    /// An opaque exterior door. Doors are sold by rated R-value rather than assembled on
    /// site, so the rating is the input and the air films are added to it.
    public static func door(name: String, ratedR: Double) -> Assembly {
        Assembly(name: name, category: .door, layers: [
            Layer(material: .outsideAirFilmWinter, thicknessInches: 0),
            Layer(material: Material(name: name, fixedResistance: ratedR, category: .cladding),
                  thicknessInches: 0),
            Layer(material: .insideAirFilmVertical, thicknessInches: 0)
        ], framing: .none, solarAbsorptance: 0.70)
    }

    /// Looks an assembly up by name.
    ///
    /// Callers select by name rather than by position: the library grows, and an index
    /// that silently points at a different wall is the kind of mistake that produces a
    /// plausible number for the wrong assembly.
    public static func named(_ name: String) -> Assembly? {
        standard.first { $0.name == name }
    }

    /// Everything, filtered to what can legally go on a surface of this kind.
    public static func assemblies(for category: SurfaceCategory) -> [Assembly] {
        standard.filter { $0.category == category }
    }

    /// The assemblies that actually turn up on Piedmont Triad jobs, so the common case is
    /// a single pick with nothing typed.
    public static let standard: [Assembly] = [
        framedWall(name: "2×4 wall, R-13 batt, vinyl siding",
                   cladding: .vinylSiding, sheathing: .osb, sheathingThickness: 0.5,
                   framing: .woodStud2x4at16, cavityRatedR: 13),
        framedWall(name: "2×4 wall, R-13 batt, brick veneer",
                   cladding: .brickVeneer, sheathing: .osb, sheathingThickness: 0.5,
                   framing: .woodStud2x4at16, cavityRatedR: 13,
                   solarAbsorptance: 0.60),
        framedWall(name: "2×6 wall, R-21 batt, vinyl siding",
                   cladding: .vinylSiding, sheathing: .osb, sheathingThickness: 0.5,
                   framing: .woodStud2x6at16, cavityRatedR: 21),
        framedWall(name: "2×6 wall, R-21 batt, 1\" XPS, fibre cement",
                   cladding: .fiberCementSiding, sheathing: .extrudedPolystyrene, sheathingThickness: 1.0,
                   framing: .woodStud2x6at16, cavityRatedR: 21),
        framedWall(name: "2×4 wall, closed-cell foam, vinyl siding",
                   cladding: .vinylSiding, sheathing: .osb, sheathingThickness: 0.5,
                   framing: .woodStud2x4at16, cavityInsulation: .closedCellSprayFoam),
        atticCeiling(name: "Vented attic, R-30 blown cellulose", ratedR: 30),
        atticCeiling(name: "Vented attic, R-38 blown cellulose", ratedR: 38),
        atticCeiling(name: "Vented attic, R-49 blown cellulose", ratedR: 49),
        atticCeiling(name: "Vented attic, R-19 blown fibreglass (older home)", ratedR: 19),
        framedWall(name: "2×4 wall, no insulation (pre-1960)",
                   cladding: .woodBevelSiding, sheathing: .fiberboardSheathing,
                   sheathingThickness: 0.5, framing: .woodStud2x4at16,
                   cavityInsulation: Material(name: "Empty cavity", resistancePerInch: 0.28,
                                              category: .insulation)),
        framedWall(name: "8\" block wall, furred and insulated",
                   cladding: .brickVeneer, sheathing: .concreteBlock8, sheathingThickness: 8,
                   framing: Framing(name: "1×2 furring @ 16\" o.c.", depthInches: 1.5,
                                    framingFactor: 0.10, material: .softwoodFraming),
                   cavityInsulation: .extrudedPolystyrene),
        framedFloor(name: "Floor over crawl space, R-19 batt", thicknessInches: 9.25, ratedR: 19),
        framedFloor(name: "Floor over crawl space, R-30 batt", thicknessInches: 9.25, ratedR: 30),
        framedFloor(name: "Floor over crawl space, uninsulated",
                    insulation: Material(name: "Empty joist bay", resistancePerInch: 0.28,
                                         category: .insulation),
                    thicknessInches: 9.25),
        door(name: "Steel door, polyurethane core", ratedR: 5.0),
        door(name: "Steel door, polystyrene core", ratedR: 3.0),
        door(name: "Solid wood door, 1¾\"", ratedR: 2.2),
        door(name: "Fibreglass door, insulated core", ratedR: 5.6)
    ]
}
