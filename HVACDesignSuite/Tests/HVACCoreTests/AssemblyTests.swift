import XCTest
@testable import HVACCore

final class AssemblyTests: XCTestCase {

    /// Hand-check of the parallel-path method on the most common wall there is.
    ///
    /// Cavity path: 0.17 + 0.61 + 0.625 + 10.99 + 0.45 + 0.68 = 13.525
    /// Framing path: stud replaces the batt — 3.5 × 1.25 = 4.375 — giving 6.91
    /// U = 0.25·(1/6.91) + 0.75·(1/13.525) = 0.0916
    func test2x4R13WallMatchesHandCalculation() {
        let wall = AssemblyLibrary.framedWall(
            name: "test", cladding: .vinylSiding, sheathing: .osb, sheathingThickness: 0.5,
            framing: .woodStud2x4at16, cavityInsulation: .fiberglassBatt)
        XCTAssertEqual(wall.cavityPathResistance, 13.525, accuracy: 0.02)
        XCTAssertEqual(wall.framingPathResistance, 6.91, accuracy: 0.02)
        XCTAssertEqual(wall.uValue, 0.0916, accuracy: 0.001)
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
        let etd = ceiling.equivalentTemperatureDifference(designDeltaT: 17, orientation: .horizontal)
        XCTAssertGreaterThan(etd, 17)
        XCTAssertEqual(etd, 17 + 0.85 * 235 / 4.0, accuracy: 0.01)
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
