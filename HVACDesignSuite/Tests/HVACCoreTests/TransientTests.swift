import XCTest
@testable import HVACCore

final class TransientConductionTests: XCTestCase {

    private var conditions: DesignConditions { .piedmontTriad }

    // MARK: Design day

    func testOutdoorProfilePeaksAtThreeAndSpansTheDailyRange() {
        let peak = 92.0, range = 18.0
        let day = (0..<24).map {
            TransientConduction.outdoorTemperature(hour: Double($0), peakF: peak, dailyRangeF: range)
        }
        XCTAssertEqual(day.max() ?? 0, peak, accuracy: 0.01)
        XCTAssertEqual(day.min() ?? 0, peak - range, accuracy: 0.01)
        XCTAssertEqual(day.firstIndex(of: day.max()!), 15, "design day should peak at 15:00")
        XCTAssertEqual(day.firstIndex(of: day.min()!), 3, "and bottom out before dawn")
    }

    func testSolAirExceedsAirTemperatureUnderSun() {
        let lit = TransientConduction.solAirTemperature(outdoorF: 92, irradiance: 240,
                                                        absorptance: 0.85, tilt: 90)
        XCTAssertGreaterThan(lit, 92)
        // 0.85 × 240 / 4.0 = 51 °F above air.
        XCTAssertEqual(lit, 92 + 51, accuracy: 0.5)
        // A horizontal surface loses to the sky.
        let flat = TransientConduction.solAirTemperature(outdoorF: 92, irradiance: 0,
                                                         absorptance: 0.85, tilt: 0)
        XCTAssertEqual(flat, 85, accuracy: 0.01)
    }

    // MARK: The solver

    /// A massless assembly has nothing to store, so it must reproduce the steady-state
    /// answer exactly, hour for hour. This is the anchor: if it drifts here, every
    /// massive result built on the same code is suspect.
    func testMasslessAssemblyReproducesSteadyStateExactly() throws {
        let massless = Assembly(name: "massless", category: .wall, layers: [
            Layer(material: .outsideAirFilmWinter, thicknessInches: 0),
            Layer(material: Material(name: "pure resistance", fixedResistance: 12, category: .insulation),
                  thicknessInches: 0),
            Layer(material: .insideAirFilmVertical, thicknessInches: 0)
        ])
        let solAir = (0..<24).map { 75.0 + 20 * sin(Double($0) / 24 * 2 * .pi) }
        let response = try TransientConduction.solve(assembly: massless, solAir: solAir, roomF: 75)
        for hour in 0..<24 {
            XCTAssertEqual(response.hourlyFlux[hour],
                           massless.uValue * (solAir[hour] - 75), accuracy: 1e-9,
                           "hour \(hour)")
        }
        XCTAssertEqual(response.decrementFactor, 1.0, accuracy: 1e-9)
    }

    /// Energy conservation. Mass moves a load in time; it does not destroy it. Over a
    /// closed 24-hour cycle the average flux must equal the steady-state average.
    func testDailyAverageFluxIsConservedRegardlessOfMass() throws {
        let solAir = (0..<24).map { 75.0 + 25 * sin(Double($0 - 6) / 24 * 2 * .pi) }
        let names = ["2×4 wall, R-13 batt, vinyl siding",
                     "2×6 wall, R-21 batt, vinyl siding",
                     "8\" block wall, furred and insulated"]
        for assembly in names.compactMap(AssemblyLibrary.named) {
            let response = try TransientConduction.solve(assembly: assembly, solAir: solAir,
                                                         roomF: 75, stepsPerHour: 8)
            let simulated = response.hourlyFlux.reduce(0, +) / 24
            let steady = solAir.map { assembly.uValue * ($0 - 75) }.reduce(0, +) / 24
            XCTAssertEqual(simulated, steady, accuracy: max(0.02, abs(steady) * 0.02),
                           "energy not conserved for \(assembly.name)")
        }
    }

    /// Mass damps the swing. A heavy assembly must show a smaller peak than the
    /// steady-state figure that ignores it.
    func testMassDampsThePeak() throws {
        let solAir = TransientConduction.solAirDay(conditions: conditions,
                                                   orientation: .west, absorptance: 0.7)
        let light = try XCTUnwrap(AssemblyLibrary.named("2×4 wall, R-13 batt, vinyl siding"))
        let heavy = try XCTUnwrap(AssemblyLibrary.named("8\" block wall, furred and insulated"))
        let lightResponse = try TransientConduction.solve(assembly: light, solAir: solAir, roomF: 75)
        let heavyResponse = try TransientConduction.solve(assembly: heavy, solAir: solAir, roomF: 75)

        XCTAssertLessThan(lightResponse.decrementFactor, 1.0)
        XCTAssertLessThan(heavyResponse.decrementFactor, lightResponse.decrementFactor,
                          "the heavier assembly should damp more")
        XCTAssertGreaterThan(heavyResponse.decrementFactor, 0.0)
    }

    /// And delays it. This is the behaviour the steady-state method could not express.
    func testMassDelaysThePeak() throws {
        let solAir = TransientConduction.solAirDay(conditions: conditions,
                                                   orientation: .west, absorptance: 0.7)
        let block = try XCTUnwrap(AssemblyLibrary.named("8\" block wall, furred and insulated"))
        let heavy = try TransientConduction.solve(assembly: block, solAir: solAir, roomF: 75)
        XCTAssertGreaterThan(heavy.lagHours, 0, "a block wall must lag the sol-air peak")
        XCTAssertLessThan(heavy.lagHours, 12)
    }

    func testEveryLibraryAssemblySolvesToFinitePeriodicValues() throws {
        let solAir = TransientConduction.solAirDay(conditions: conditions,
                                                   orientation: .south, absorptance: 0.7)
        for assembly in AssemblyLibrary.standard {
            let response = try TransientConduction.solve(assembly: assembly, solAir: solAir, roomF: 75)
            XCTAssertEqual(response.hourlyFlux.count, 24, assembly.name)
            XCTAssertTrue(response.hourlyFlux.allSatisfy(\.isFinite), assembly.name)
            XCTAssertGreaterThan(response.decrementFactor, 0, assembly.name)
            XCTAssertLessThanOrEqual(response.decrementFactor, 1.001, assembly.name)
        }
    }

    /// The solve must not depend on how finely the day is stepped, or the answer is an
    /// artefact of the discretisation rather than of the wall.
    func testResultIsStableAcrossTimeSteps() throws {
        let solAir = TransientConduction.solAirDay(conditions: conditions,
                                                   orientation: .west, absorptance: 0.7)
        let assembly = try XCTUnwrap(AssemblyLibrary.named("8\" block wall, furred and insulated"))
        let coarse = try TransientConduction.solve(assembly: assembly, solAir: solAir,
                                                   roomF: 75, stepsPerHour: 2)
        let fine = try TransientConduction.solve(assembly: assembly, solAir: solAir,
                                                 roomF: 75, stepsPerHour: 16)
        XCTAssertEqual(coarse.peakFlux, fine.peakFlux, accuracy: abs(fine.peakFlux) * 0.05)
        XCTAssertEqual(coarse.peakHour, fine.peakHour)
    }

    func testMalformedDesignDayIsRefused() {
        XCTAssertThrowsError(try TransientConduction.solve(
            assembly: AssemblyLibrary.standard[0], solAir: [75, 76], roomF: 75))
    }
}
