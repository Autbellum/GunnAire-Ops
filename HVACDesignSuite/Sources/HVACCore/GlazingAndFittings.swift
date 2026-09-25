import Foundation

// MARK: - Glazing

/// A window or glass door, described by the two numbers that actually govern its load.
///
/// U-factor drives conduction and SHGC drives solar gain, and they are independent: a
/// low-E double pane and a clear double pane can share a U-factor while passing very
/// different amounts of sun. Both appear on the NFRC label of every window sold in the
/// United States, so the honest path is to carry typical values for each construction and
/// let the actual label override them when it is to hand.
///
/// **These are typical published values for a construction, not certified product data.**
/// A specific window's NFRC numbers should be entered when the model is known.
public struct GlazingType: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: String { name }
    public let name: String
    /// Whole-window U-factor, Btu/(h·ft²·°F).
    public let uFactor: Double
    /// Solar heat gain coefficient, fraction of incident solar admitted.
    public let solarHeatGainCoefficient: Double
    /// True when these came from an NFRC label rather than the typical-value library.
    public let isCertified: Bool

    public init(name: String, uFactor: Double, solarHeatGainCoefficient: Double,
                isCertified: Bool = false) {
        self.name = name; self.uFactor = uFactor
        self.solarHeatGainCoefficient = solarHeatGainCoefficient
        self.isCertified = isCertified
    }

    /// Effective R-value, for the conduction term.
    public var rValue: Double { uFactor > 0 ? 1 / uFactor : 0 }

    // Typical values by construction, aluminium or vinyl frame as noted.
    public static let singlePaneAluminum = GlazingType(name: "Single pane, aluminium frame", uFactor: 1.04, solarHeatGainCoefficient: 0.75)
    public static let singlePaneWood = GlazingType(name: "Single pane, wood or vinyl frame", uFactor: 0.89, solarHeatGainCoefficient: 0.64)
    public static let singlePaneWithStorm = GlazingType(name: "Single pane + storm", uFactor: 0.55, solarHeatGainCoefficient: 0.60)
    public static let doublePaneAluminum = GlazingType(name: "Double pane, aluminium frame", uFactor: 0.64, solarHeatGainCoefficient: 0.62)
    public static let doublePaneVinyl = GlazingType(name: "Double pane, vinyl frame", uFactor: 0.49, solarHeatGainCoefficient: 0.56)
    public static let doublePaneLowE = GlazingType(name: "Double pane, low-E, vinyl", uFactor: 0.33, solarHeatGainCoefficient: 0.38)
    public static let doublePaneLowEArgon = GlazingType(name: "Double pane, low-E, argon, vinyl", uFactor: 0.30, solarHeatGainCoefficient: 0.30)
    public static let doublePaneLowEArgonSouthern = GlazingType(name: "Double pane, low-E (southern), argon", uFactor: 0.30, solarHeatGainCoefficient: 0.25)
    public static let triplePaneLowEArgon = GlazingType(name: "Triple pane, low-E, argon", uFactor: 0.20, solarHeatGainCoefficient: 0.26)

    public static let library: [GlazingType] = [
        singlePaneAluminum, singlePaneWood, singlePaneWithStorm,
        doublePaneAluminum, doublePaneVinyl,
        doublePaneLowE, doublePaneLowEArgon, doublePaneLowEArgonSouthern,
        triplePaneLowEArgon
    ]

    /// A window whose NFRC label is known. Always preferred over a library entry.
    public static func certified(name: String, uFactor: Double, shgc: Double) -> GlazingType {
        GlazingType(name: name, uFactor: uFactor, solarHeatGainCoefficient: shgc, isCertified: true)
    }
}

/// Shading applied to a window, as a multiplier on admitted solar.
///
/// Manual J treats interior and exterior shading separately because they act differently:
/// an exterior shade rejects heat before it enters, an interior blind re-radiates much of
/// what it stops back into the room.
public struct Shading: Codable, Sendable, Equatable {
    public var name: String
    public var factor: Double

    public static let none = Shading(name: "None", factor: 1.00)
    public static let interiorBlindsLight = Shading(name: "Light interior blinds", factor: 0.75)
    public static let interiorDrapesMedium = Shading(name: "Medium interior drapes", factor: 0.65)
    public static let exteriorAwning = Shading(name: "Exterior awning", factor: 0.25)
    public static let exteriorScreen = Shading(name: "Exterior insect screen", factor: 0.70)

    public static let library: [Shading] = [
        none, interiorBlindsLight, interiorDrapesMedium, exteriorScreen, exteriorAwning
    ]
}

public extension GlazingType {
    /// Effective solar gain coefficient with shading applied.
    func effectiveSHGC(shading: Shading) -> Double {
        solarHeatGainCoefficient * shading.factor
    }
}

// MARK: - Duct fittings

/// A fitting described by its loss coefficient rather than a tabulated length.
///
/// Manual D assigns each fitting an equivalent length from its own tables. Those tables
/// are ACCA's, and a table entry is also fixed: it assumes a duct size. The physics is
/// better behaved. A fitting's loss is `C · Pv`, and a foot of duct loses `(f/D) · Pv`, so
/// the equivalent length that produces the same loss is
///
///   Lₑ = C · D / f
///
/// with D in feet. That scales with the duct it is actually installed in — a 90° elbow in
/// a 16 in. trunk is worth far more equivalent length than the same elbow in a 6 in.
/// branch — and it needs no table at all.
///
/// **Loss coefficients are standard published values for the fitting geometry**, not
/// ACCA's equivalent-length tables.
public struct FittingType: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: String { name }
    public let name: String
    /// Dimensionless local loss coefficient.
    public let lossCoefficient: Double

    public init(name: String, lossCoefficient: Double) {
        self.name = name; self.lossCoefficient = lossCoefficient
    }

    public static let elbow90Smooth = FittingType(name: "90° elbow, smooth radius", lossCoefficient: 0.22)
    public static let elbow90Mitered = FittingType(name: "90° elbow, mitred", lossCoefficient: 1.20)
    public static let elbow45 = FittingType(name: "45° elbow", lossCoefficient: 0.15)
    public static let elbowFlex90 = FittingType(name: "90° bend in flexible duct", lossCoefficient: 0.60)
    public static let takeoffStraight = FittingType(name: "Straight take-off from trunk", lossCoefficient: 0.35)
    public static let takeoffConical = FittingType(name: "Conical take-off from trunk", lossCoefficient: 0.12)
    public static let boot90 = FittingType(name: "Register boot, 90°", lossCoefficient: 1.00)
    public static let boot45 = FittingType(name: "Register boot, 45°", lossCoefficient: 0.60)
    public static let returnGrille = FittingType(name: "Return grille entry", lossCoefficient: 0.50)
    public static let plenumTakeoff = FittingType(name: "Supply plenum take-off", lossCoefficient: 0.60)
    public static let reducer = FittingType(name: "Gradual reducer", lossCoefficient: 0.10)
    public static let wye45 = FittingType(name: "45° wye branch", lossCoefficient: 0.30)

    public static let library: [FittingType] = [
        elbow90Smooth, elbow90Mitered, elbow45, elbowFlex90,
        takeoffStraight, takeoffConical, boot90, boot45,
        returnGrille, plenumTakeoff, reducer, wye45
    ]

    /// Equivalent length of this fitting in a duct of a given diameter, ft.
    ///
    ///   Lₑ = C · D / f
    ///
    /// The friction factor is taken at the duct's own size, airflow and roughness, so a
    /// fitting in rough flexible duct is worth less equivalent length than the same
    /// fitting in smooth metal — correctly, since the duct it replaces is already lossier.
    public func equivalentLength(diameterInches: Double, cfm: Double,
                                 roughnessFeet: Double) -> Double {
        guard diameterInches > 0, cfm > 0 else { return 0 }
        let diameterFeet = diameterInches / 12
        let area = Double.pi * diameterFeet * diameterFeet / 4
        let velocityFPM = cfm / area
        let reynolds = (velocityFPM / 60) * diameterFeet / DuctDesigner.kinematicViscosity
        let f = DuctDesigner.frictionFactor(reynolds: reynolds,
                                            relativeRoughness: roughnessFeet / diameterFeet)
        guard f > 0 else { return 0 }
        return lossCoefficient * diameterFeet / f
    }
}

public extension Fitting {
    /// Builds a fitting whose equivalent length is computed for the duct it sits in,
    /// rather than typed in from a table.
    static func computed(_ type: FittingType, count: Int = 1,
                         diameterInches: Double, cfm: Double,
                         roughnessFeet: Double = DuctMaterial.galvanizedSteel.roughnessFeet) -> Fitting {
        Fitting(name: type.name,
                equivalentLengthFeet: type.equivalentLength(diameterInches: diameterInches,
                                                            cfm: cfm, roughnessFeet: roughnessFeet),
                count: count)
    }
}
