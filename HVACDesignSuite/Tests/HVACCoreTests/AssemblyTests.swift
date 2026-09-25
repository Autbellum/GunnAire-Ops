import XCTest
@testable import HVACCore

final class AssemblyTests: XCTestCase {

    /// Hand-check of the parallel-path method on the most common wall there is, using the
    /// ASHRAE Chapter 26 design values the library now carries.
    ///
    /// Cavity path: 0.17 film + 0.61 vinyl + 0.705 OSB (0.5 in. at R-1.41/in.)
    ///            + 11.655 batt (3.5 in. at R-3.33/in.) + 0.45 gypsum + 0.68 film = 14.27
    /// Framing path: the stud replaces the batt — 3.5 × 1.25 = 4.375 — giving 6.99
    /// U = 0.25·(1/6.99) + 0.75·(1/14.27) = 0.0883
    func test2x4WallMatchesHandCalculation() {
        let wall = AssemblyLibrary.framedWall(
            name: "test", cladding: .vinylSiding, sheathing: .osb, sheathingThickness: 0.5,
            framing: .woodStud2x4at16, cavityInsulation: .fiberglassBatt)
        XCTAssertEqual(wall.cavityPathResistance, 14.27, accuracy: 0.02)
        XCTAssertEqual(wall.framingPathResistance, 6.99, accuracy: 0.02)
        XCTAssertEqual(wall.uValue, 0.0883, accuracy: 0.001)
    }

    /// Conductances add in parallel, resistances do not. Averaging R overstates the wall,
    /// because heat takes the easy path through the stud.
    func testParallelPathBeatsNaiveResistanceAveraging() {
        let wall = AssemblyLibrary.framedWall(
            name: "test", cladding: .vinylSiding, sheathing: .osb, sheathingThickness: 0.5,
            framing: .woodStud2x6at16, cavityInsulation: .fiberglassBatt)
        let naive = 0.25 * wall.framingPathResistance + 0.75 * wall.cavityPathResistance
        XCTAssertLessThan(wall.effectiveR, naive)
    }

    /// The number that surprises people: a "R-21 wall" does not perform at R-21.
    func testFramingPenaltyIsSubstantial() {
        let wall = AssemblyLibrary.framedWall(
            name: "test", cladding: .vinylSiding, sheathing: .osb, sheathingThickness: 0.5,
            framing: .woodStud2x6at16, cavityInsulation: .fiberglassBatt)
        XCTAssertGreaterThan(wall.framingPenalty, 0.15)
        XCTAssertLessThan(wall.framingPenalty, 0.35)
    }

    func testContinuousInsulationReducesTheFramingPenalty() {
        let plain = AssemblyLibrary.framedWall(
            name: "a", cladding: .fiberCementSiding, sheathing: .osb, sheathingThickness: 0.5,
            framing: .woodStud2x6at16, cavityInsulation: .fiberglassBatt)
        let sheathed = AssemblyLibrary.framedWall(
            name: "b", cladding: .fiberCementSiding, sheathing: .extrudedPolystyrene,
            sheathingThickness: 1.0, framing: .woodStud2x6at16, cavityInsulation: .fiberglassBatt)
        XCTAssertLessThan(sheathed.uValue, plain.uValue)
        XCTAssertLessThan(sheathed.framingPenalty, plain.framingPenalty)
    }

    func testUnframedAssemblyHasNoPenalty() {
        let ceiling = AssemblyLibrary.atticCeiling(name: "c", insulation: .blownCellulose,
                                                   thicknessInches: 10.9)
        XCTAssertEqual(ceiling.framingPathResistance, ceiling.cavityPathResistance, accuracy: 1e-9)
        XCTAssertEqual(ceiling.framingPenalty, 0, accuracy: 1e-9)
        XCTAssertEqual(ceiling.effectiveR, 40.4, accuracy: 1.0)
    }

    func testBetterInsulationAlwaysLowersU() {
        let batt = AssemblyLibrary.framedWall(name: "a", cladding: .vinylSiding, sheathing: .osb,
                                              sheathingThickness: 0.5, framing: .woodStud2x4at16,
                                              cavityInsulation: .fiberglassBatt)
        let foam = AssemblyLibrary.framedWall(name: "b", cladding: .vinylSiding, sheathing: .osb,
                                              sheathingThickness: 0.5, framing: .woodStud2x4at16,
                                              cavityInsulation: .closedCellSprayFoam)
        XCTAssertLessThan(foam.uValue, batt.uValue)
    }

    /// A dark roof under peak sun runs far above outdoor air — the reason plain ΔT
    /// understates a sunlit assembly.
    func testSolAirEquivalentDifferenceExceedsPlainDeltaT() {
        let ceiling = AssemblyLibrary.atticCeiling(name: "c", insulation: .blownCellulose,
                                                   thicknessInches: 10.9)
        let irradiance = Solar.peakIrradiance(surfaceAzimuth: 180, tilt: 0, latitude: 36.1,
                                              month: 7, altitudeFeet: 902).irradiance
        let etd = ceiling.equivalentTemperatureDifference(designDeltaT: 17, irradiance: irradiance)
        XCTAssertGreaterThan(etd, 17)
        XCTAssertEqual(etd, 17 + 0.85 * irradiance / 4.0, accuracy: 0.01)
    }

    func testEveryLibraryAssemblyProducesAPlausibleU() {
        for assembly in AssemblyLibrary.standard {
            XCTAssertGreaterThan(assembly.uValue, 0.005, "\(assembly.name)")
            XCTAssertLessThan(assembly.uValue, 0.5, "\(assembly.name)")
            XCTAssertGreaterThan(assembly.effectiveR, 2, "\(assembly.name)")
        }
    }

    func testMaterialLibraryIsWellFormed() {
        XCTAssertGreaterThan(Material.library.count, 25)
        for material in Material.library {
            let r = material.resistance(thicknessInches: 1)
            XCTAssertGreaterThan(r, 0, material.name)
            XCTAssertLessThan(r, 10, material.name)
        }
    }
}

/// The library has to be reachable and complete enough that no category leaves the user
/// with nothing to pick — which is what forced hand-entered R-values in the first place.
final class ConstructionSelectionTests: XCTestCase {

    func testEverySurfaceCategoryHasLibraryOptions() {
        for category in SurfaceCategory.allCases where category != .window {
            XCTAssertFalse(AssemblyLibrary.assemblies(for: category).isEmpty,
                           "no assemblies offered for \(category.rawValue)")
        }
        XCTAssertFalse(GlazingType.library.isEmpty)
    }

    func testAssembliesAreFilteredToTheirCategory() {
        for category in SurfaceCategory.allCases {
            for assembly in AssemblyLibrary.assemblies(for: category) {
                XCTAssertEqual(assembly.category, category, assembly.name)
            }
        }
    }

    func testConstructionDerivesUAndSHGC() {
        let wall = Construction.assembly(AssemblyLibrary.standard[0])
        XCTAssertGreaterThan(wall.uValue, 0)
        XCTAssertEqual(wall.solarHeatGainCoefficient, 0, "opaque construction admits no solar")

        let window = Construction.glazing(.doublePaneLowEArgon, .interiorBlindsLight)
        XCTAssertEqual(window.uValue, GlazingType.doublePaneLowEArgon.uFactor, accuracy: 1e-9)
        XCTAssertEqual(window.solarHeatGainCoefficient,
                       GlazingType.doublePaneLowEArgon.solarHeatGainCoefficient * 0.75, accuracy: 1e-9)

        let manual = Construction.manual(rValue: 20, shgc: 0.4)
        XCTAssertEqual(manual.uValue, 0.05, accuracy: 1e-9)
    }

    func testBasisExplainsWhereTheNumbersCameFrom() {
        XCTAssertTrue(Construction.assembly(AssemblyLibrary.standard[0]).basis.contains("framing"))
        XCTAssertTrue(Construction.glazing(.doublePaneLowEArgon, .none).basis.contains("Typical"))
        XCTAssertTrue(Construction.glazing(.certified(name: "X", uFactor: 0.28, shgc: 0.2), .none)
                        .basis.contains("NFRC"))
    }

    /// Changing a surface's category must not leave a wall assembly on a window.
    func testDefaultConstructionMatchesCategory() {
        for category in SurfaceCategory.allCases {
            let construction = SurfaceRowDefaults.defaultConstruction(for: category)
            XCTAssertGreaterThan(construction.uValue, 0, category.rawValue)
            if category == .window {
                XCTAssertGreaterThan(construction.solarHeatGainCoefficient, 0)
            } else {
                XCTAssertEqual(construction.solarHeatGainCoefficient, 0, category.rawValue)
            }
        }
    }
}

/// Mirrors the picker's default so the rule is testable without importing the UI layer.
enum SurfaceRowDefaults {
    static func defaultConstruction(for category: SurfaceCategory) -> Construction {
        if category == .window { return .glazing(.doublePaneLowEArgon, .none) }
        if let first = AssemblyLibrary.assemblies(for: category).first { return .assembly(first) }
        return .manual(rValue: 13, shgc: 0)
    }
}

extension AssemblyTests {
    /// An empty cavity is worse than the wood beside it, so the framing helps rather than
    /// hurts. Reporting that as "lost to framing" states the opposite of what happened.
    func testFramingWordingFollowsTheSign() throws {
        let insulated = try XCTUnwrap(AssemblyLibrary.named("2×6 wall, R-21 batt, vinyl siding"))
        XCTAssertGreaterThan(insulated.framingPenalty, 0)
        XCTAssertTrue(try XCTUnwrap(insulated.framingDescription).contains("lost to framing"))

        let empty = try XCTUnwrap(AssemblyLibrary.named("2×4 wall, no insulation (pre-1960)"))
        XCTAssertLessThan(empty.framingPenalty, 0)
        XCTAssertTrue(try XCTUnwrap(empty.framingDescription).contains("gained from framing"))
        XCTAssertFalse(try XCTUnwrap(empty.framingDescription).contains("lost"))
    }

    /// Batts are bought by rated R. An assembly named for one must deliver it.
    func testRatedBattAssembliesDeliverTheirNamedRValue() throws {
        let wall = try XCTUnwrap(AssemblyLibrary.named("2×4 wall, R-13 batt, vinyl siding"))
        // Cavity path is the batt plus the films, sheathing, cladding and board around it.
        XCTAssertGreaterThan(wall.nominalR, 13)
        XCTAssertLessThan(wall.nominalR, 17)
        // Whole-wall effective R for a 2×4 R-13 wall lands near R-12 in practice.
        XCTAssertEqual(wall.effectiveR, 11.9, accuracy: 1.0)

        let deep = try XCTUnwrap(AssemblyLibrary.named("2×6 wall, R-21 batt, vinyl siding"))
        XCTAssertEqual(deep.effectiveR, 17.2, accuracy: 1.2)

        let attic = try XCTUnwrap(AssemblyLibrary.named("Vented attic, R-38 blown cellulose"))
        XCTAssertEqual(attic.nominalR, 39.9, accuracy: 1.0)
    }

    /// Cross-check against the values in Eric's own MJ8 workbook, which were taken from
    /// the printed Manual J tables.
    func testAgreesWithTheWorkbookValues() throws {
        let attic = try XCTUnwrap(AssemblyLibrary.named("Vented attic, R-30 blown cellulose"))
        XCTAssertEqual(attic.uValue, 0.032, accuracy: 0.002, "workbook 16B-30 gives U 0.032")
    }
}
