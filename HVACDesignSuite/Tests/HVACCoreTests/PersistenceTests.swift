import XCTest
@testable import HVACCore

/// A saved job that loses a field is worse than no save at all: the loss is silent, and
/// it surfaces as a load that quietly disagrees with the one that was signed off.
final class PersistenceTests: XCTestCase {

    private func roundTrip(_ project: Project) throws -> Project {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(project)
        return try JSONDecoder().decode(Project.self, from: data)
    }

    func testSampleProjectSurvivesRoundTrip() throws {
        let original = Project.sample
        let restored = try roundTrip(original)
        XCTAssertEqual(original, restored)
    }

    /// Equality is structural, so this also proves nothing was silently defaulted.
    func testEveryFieldSurvivesRoundTrip() throws {
        var project = Project.sample
        project.name = "Gunn Residence — Pfafftown"
        project.procedure = .commercialManualN
        project.designConditions.latitude = 36.1234
        project.designConditions.coolingDesignMonth = 8
        project.designConditions.altitudeFeet = 958
        project.customer.customerName = "Eric Gunn"
        project.customer.streetAddress = "100 Reynolda Road"
        project.customer.city = "Winston-Salem"
        project.customer.postalCode = "27106"
        project.customLibrary.materials.append(
            Material(name: "Straw bale", resistancePerInch: 1.45, category: .insulation,
                     density: 7.5, specificHeat: 0.35))
        project.systems[0].supplyAirDeltaTF = 22
        project.sizingLimits.coolingMinimumFraction = 1.02
        project.systems[0].staticPressureBudget.filter = 0.14
        project.systems[0].equipment.modelNumber = "XR16-036"
        project.zones[0].surfaces[0].coolingEquivalentDeltaTF = 41
        project.systems[0].ductRuns[1].fittings.append(Fitting(name: "Extra elbow", equivalentLengthFeet: 12, count: 3))

        let restored = try roundTrip(project)
        XCTAssertEqual(project, restored)
        XCTAssertEqual(restored.designConditions.latitude, 36.1234, accuracy: 1e-9)
        XCTAssertEqual(restored.zones[0].surfaces[0].coolingEquivalentDeltaTF ?? 0, 41, accuracy: 1e-9)
        XCTAssertEqual(restored.systems[0].ductRuns[1].fittings.last?.count, 3)
        XCTAssertEqual(restored.systems[0].equipment.modelNumber, "XR16-036")
        XCTAssertEqual(restored.customer.city, "Winston-Salem")
        XCTAssertEqual(restored.customLibrary.materials.first?.name, "Straw bale")
    }

    /// Identity has to survive too, or a duct run loses the zone it serves on reopen.
    func testZoneIdentityAndDuctLinksSurvive() throws {
        let project = Project.sample
        let restored = try roundTrip(project)
        let servedOriginal = project.systems.flatMap(\.ductRuns).compactMap(\.servingZoneID)
        let servedRestored = restored.systems.flatMap(\.ductRuns).compactMap(\.servingZoneID)
        XCTAssertFalse(servedOriginal.isEmpty)
        XCTAssertEqual(servedOriginal, servedRestored)
        for id in servedRestored {
            XCTAssertTrue(restored.zones.contains { $0.id == id },
                          "duct run lost its zone on reopen")
        }
    }

    /// A reopened file must recompute to the same answers, not merely decode.
    @MainActor
    func testReopenedProjectReproducesTheSameDesign() throws {
        let engine = DesignEngine()
        let originalLoad = engine.load?.coolingSensibleBtuh ?? 0
        let originalTrunk = engine.ductSizing.first { $0.role == .supplyTrunk }?.nominalDiameterInches ?? 0
        XCTAssertFalse(engine.systems.isEmpty)
        XCTAssertGreaterThan(originalLoad, 0)

        let reopened = DesignEngine(project: try roundTrip(engine.project))
        XCTAssertEqual(reopened.load?.coolingSensibleBtuh ?? 0, originalLoad, accuracy: 0.001)
        XCTAssertEqual(reopened.load?.heatingBtuh ?? 0, engine.load?.heatingBtuh ?? 0, accuracy: 0.001)
        XCTAssertEqual(reopened.ductSizing.first { $0.role == .supplyTrunk }?.nominalDiameterInches ?? 0,
                       originalTrunk, accuracy: 0.001)
        XCTAssertEqual(reopened.systems.first?.selection?.checks.count,
                       engine.systems.first?.selection?.checks.count)
    }

    func testCorruptFileIsRefusedNotGuessed() {
        XCTAssertThrowsError(try JSONDecoder().decode(Project.self, from: Data("{}".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(Project.self, from: Data("not json".utf8)))
    }
}
