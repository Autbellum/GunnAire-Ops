import XCTest
@testable import HVACCore

final class DesignDayIntegrationTests: XCTestCase {

    /// The invariant the whole detail view depends on: the components shown to an
    /// engineer must add up to the headline figure. If they drift, the breakdown is
    /// explaining a number that is not there.
    func testComponentsSumToTheZoneSensibleLoad() throws {
        let load = try LoadCalculator.calculate(project: .sample)
        for zone in load.zoneLoads {
            let sensible = zone.coolingComponents
                .filter { !$0.name.hasSuffix("latent") }
                .reduce(0) { $0 + $1.btuh }
            XCTAssertEqual(sensible, zone.coolingSensibleBtuh, accuracy: 1.0,
                           "components do not explain the sensible load for \(zone.zoneName)")
            let latent = zone.coolingComponents
                .filter { $0.name.hasSuffix("latent") }
                .reduce(0) { $0 + $1.btuh }
            XCTAssertEqual(latent, zone.coolingLatentBtuh, accuracy: 1.0, zone.zoneName)
        }
    }

    /// The project sensible load is the coincident peak, not a sum of separate maxima.
    func testProjectSensibleEqualsTheCoincidentPeak() throws {
        let designDay = try DesignDay.solve(project: .sample)
        let load = try LoadCalculator.calculate(project: .sample)
        XCTAssertEqual(load.coolingSensibleBtuh, designDay.profile.peakSensible, accuracy: 1.0)
        XCTAssertLessThan(load.coolingSensibleBtuh, designDay.profile.sumOfIndividualPeaks)
    }

    /// Solar on a transient surface enters through the sol-air boundary. Adding a separate
    /// solar term would count it twice, which is the easiest mistake to make here and the
    /// hardest to see in a total.
    func testTransientSurfacesDoNotDoubleCountSolar() throws {
        var project = Project.sample
        let wall = try XCTUnwrap(AssemblyLibrary.named("2×6 wall, R-21 batt, vinyl siding"))
        project.zones = [Zone(name: "Z", floorAreaSquareFeet: 200, ceilingHeightFeet: 8,
                              surfaces: [Surface(name: "West Wall", category: .wall,
                                                 areaSquareFeet: 200,
                                                 construction: .assembly(wall),
                                                 orientation: .west)],
                              internalGains: .residentialDefault,
                              airExchange: AirExchange(airChangesPerHour: 0, ventilationCFM: 0))]
        let load = try LoadCalculator.calculate(project: project)
        let zone = try XCTUnwrap(load.zoneLoads.first)
        XCTAssertEqual(zone.coolingComponents.filter { $0.name.contains("solar") }.count, 0,
                       "a transient surface must not carry a separate solar component")
        // Sanity bound: 200 ft² of R-15.5 wall cannot deliver a ridiculous load.
        XCTAssertGreaterThan(zone.coolingSensibleBtuh, 0)
        XCTAssertLessThan(zone.coolingSensibleBtuh, 3_000)
    }

    /// An engineer-supplied equivalent difference must still be honoured, since someone
    /// with a book value should not be forced onto the solver.
    func testEquivalentTemperatureDifferenceIsStillHonoured() throws {
        var project = Project.sample
        let wall = try XCTUnwrap(AssemblyLibrary.named("2×6 wall, R-21 batt, vinyl siding"))
        project.zones = [Zone(name: "Z", floorAreaSquareFeet: 200, ceilingHeightFeet: 8,
                              surfaces: [Surface(name: "Roof", category: .roof,
                                                 areaSquareFeet: 200,
                                                 construction: .assembly(wall),
                                                 orientation: .horizontal,
                                                 coolingEquivalentDeltaTF: 40)],
                              internalGains: .residentialDefault,
                              airExchange: AirExchange(airChangesPerHour: 0, ventilationCFM: 0))]
        let load = try LoadCalculator.calculate(project: project)
        let expected = wall.uValue * 200 * 40
        XCTAssertEqual(load.coolingSensibleBtuh, expected, accuracy: 1.0)
    }

    /// Heating is untouched by the design day: it is a night condition with no sun and no
    /// gains, so the hourly sweep has nothing to find.
    func testHeatingIsUnchangedByTheHourlyMethod() throws {
        let project = Project.sample
        let viaProject = try LoadCalculator.calculate(project: project)
        let solar = LoadCalculator.solarTable(for: project.designConditions)
        var summed = 0.0
        for zone in project.zones {
            summed += try LoadCalculator.calculate(zone: zone, conditions: project.designConditions,
                                                   procedure: project.procedure, solar: solar).heatingBtuh
        }
        XCTAssertEqual(viaProject.heatingBtuh, summed, accuracy: 0.01)
    }

    /// The hourly method should come in at or below the single-condition method, since it
    /// no longer assumes every surface peaks at once.
    func testHourlyMethodIsNotMoreConservativeThanSteadyState() throws {
        let project = Project.sample
        let hourly = try LoadCalculator.calculate(project: project)
        let solar = LoadCalculator.solarTable(for: project.designConditions)
        var steady = 0.0
        for zone in project.zones {
            steady += try LoadCalculator.calculate(zone: zone, conditions: project.designConditions,
                                                   procedure: project.procedure, solar: solar).coolingSensibleBtuh
        }
        XCTAssertLessThanOrEqual(hourly.coolingSensibleBtuh, steady * 1.02)
    }

    /// Everything downstream must move with it, or the cascade is only partly switched.
    @MainActor
    func testCascadeRunsFromTheCoincidentPeak() throws {
        let engine = DesignEngine()
        let profile = try XCTUnwrap(engine.coolingProfile)
        let load = try XCTUnwrap(engine.load)
        XCTAssertEqual(load.coolingSensibleBtuh, profile.peakSensible, accuracy: 1.0)

        let selection = try XCTUnwrap(engine.selection)
        let coefficient = try Psychrometrics.sensibleCoefficient(
            altitudeFeet: engine.project.designConditions.altitudeFeet)
        XCTAssertEqual(selection.requiredAirflowCFM,
                       profile.peakSensible / (coefficient * engine.project.supplyAirDeltaTF),
                       accuracy: 1.0, "airflow must follow the coincident peak")
        XCTAssertFalse(engine.ductSizing.isEmpty)
    }
}
