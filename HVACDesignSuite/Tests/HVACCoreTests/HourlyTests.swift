import XCTest
@testable import HVACCore

final class CoolingProfileTests: XCTestCase {

    /// The whole point of an hourly method: surfaces peak at different times, so the sum
    /// of their individual maxima describes a building that never exists.
    func testCoincidentPeakIsBelowTheSumOfIndividualPeaks() throws {
        let profile = try LoadCalculator.coolingProfile(project: .sample)
        XCTAssertGreaterThan(profile.peakSensible, 0)
        XCTAssertLessThan(profile.peakSensible, profile.sumOfIndividualPeaks)
        XCTAssertLessThan(profile.diversityFactor, 1.0)
        XCTAssertGreaterThan(profile.diversityFactor, 0.5, "a diversity below 0.5 would be suspicious")
    }

    func testProfileCoversTheWholeDayAndPeaksInTheAfternoon() throws {
        let profile = try LoadCalculator.coolingProfile(project: .sample)
        XCTAssertEqual(profile.hourlySensible.count, 24)
        XCTAssertTrue(profile.hourlySensible.allSatisfy(\.isFinite))
        XCTAssertTrue((12...21).contains(profile.peakHour),
                      "a cooling peak at hour \(profile.peakHour) is not physical")
        XCTAssertEqual(profile.hourlySensible[profile.peakHour], profile.peakSensible, accuracy: 0.01)
    }

    func testZoneContributionsSumToTheBuildingPeak() throws {
        let profile = try LoadCalculator.coolingProfile(project: .sample)
        let summed = profile.zoneSensibleAtPeak.values.reduce(0, +)
        XCTAssertEqual(summed, profile.peakSensible, accuracy: 0.5)
    }

    /// Orientation must move the peak hour, or the solar model is not reaching the load.
    func testOrientationShiftsThePeakHour() throws {
        func project(facing: Orientation) -> Project {
            var project = Project.sample
            project.zones = [Zone(name: "Z", floorAreaSquareFeet: 200, ceilingHeightFeet: 8,
                                  surfaces: [Surface(name: "Glass", category: .window,
                                                     areaSquareFeet: 120,
                                                     construction: .glazing(.singlePaneAluminum, .none),
                                                     orientation: facing)],
                                  internalGains: .residentialDefault,
                                  airExchange: AirExchange(airChangesPerHour: 0, ventilationCFM: 0))]
            return project
        }
        let east = try LoadCalculator.coolingProfile(project: project(facing: .east))
        let west = try LoadCalculator.coolingProfile(project: project(facing: .west))
        XCTAssertLessThan(east.peakHour, 12, "an east-glazed room peaks in the morning")
        XCTAssertGreaterThan(west.peakHour, 12, "a west-glazed room peaks in the afternoon")
    }

    /// Mass must delay the building peak, which is the behaviour the steady-state method
    /// could not represent at all.
    func testMasonryDelaysTheBuildingPeak() throws {
        func project(assembly: String) throws -> Project {
            var project = Project.sample
            let wall = try XCTUnwrap(AssemblyLibrary.named(assembly))
            project.zones = [Zone(name: "Z", floorAreaSquareFeet: 200, ceilingHeightFeet: 8,
                                  surfaces: [Surface(name: "West Wall", category: .wall,
                                                     areaSquareFeet: 400,
                                                     construction: .assembly(wall),
                                                     orientation: .west)],
                                  internalGains: .residentialDefault,
                                  airExchange: AirExchange(airChangesPerHour: 0, ventilationCFM: 0))]
            return project
        }
        let frame = try LoadCalculator.coolingProfile(project: try project(assembly: "2×4 wall, R-13 batt, vinyl siding"))
        let block = try LoadCalculator.coolingProfile(project: try project(assembly: "8\" block wall, furred and insulated"))
        XCTAssertGreaterThan(block.peakHour, frame.peakHour,
                             "masonry must push the peak later than frame")
    }

    func testEmptyProjectProducesAZeroProfileRatherThanFailing() throws {
        var empty = Project.sample
        empty.zones = []
        let profile = try LoadCalculator.coolingProfile(project: empty)
        XCTAssertEqual(profile.peakSensible, 0, accuracy: 1e-9)
        XCTAssertEqual(profile.hourlySensible.count, 24)
    }
}
