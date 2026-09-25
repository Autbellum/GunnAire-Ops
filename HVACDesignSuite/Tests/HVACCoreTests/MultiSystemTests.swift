import XCTest
@testable import HVACCore

@MainActor
final class MultiSystemTests: XCTestCase {

    private func twoSystemProject() -> Project {
        var project = Project.sample
        let upstairs = Zone(name: "Upstairs", floorAreaSquareFeet: 500, ceilingHeightFeet: 8,
                            surfaces: [Surface(name: "Wall", category: .wall, areaSquareFeet: 400,
                                               construction: .assembly(AssemblyLibrary.standard[0]),
                                               orientation: .west)],
                            internalGains: .residentialDefault, airExchange: .average)
        project.zones.append(upstairs)
        var second = HVACSystem(name: "System 2 — upstairs")
        second.equipment = EquipmentSpec(type: .heatPump, totalCoolingCapacityBtuh: 18_000,
                                         sensibleCoolingCapacityBtuh: 13_500,
                                         heatingCapacityBtuh: 15_000, maximumAirflowCFM: 700,
                                         blowerExternalStaticPressure: 0.6)
        second.zoneIDs = [upstairs.id]
        project.systems.append(second)
        return project
    }

    func testEachSystemIsSizedOnTheZonesItServes() {
        let engine = DesignEngine(project: twoSystemProject())
        XCTAssertEqual(engine.systems.count, 2)
        let downstairs = engine.systems[0]
        let upstairs = engine.systems[1]
        XCTAssertEqual(upstairs.zoneNames, ["Upstairs"])
        XCTAssertEqual(downstairs.zoneNames.count, 2)
        XCTAssertGreaterThan(upstairs.load.coolingTotalBtuh, 0)
        XCTAssertGreaterThan(downstairs.load.coolingTotalBtuh, 0)
        // Each system carries only its own zones.
        XCTAssertNotEqual(upstairs.load.coolingTotalBtuh, downstairs.load.coolingTotalBtuh)
    }

    /// The building total must account for every zone exactly once. A zone counted by two
    /// systems, or by none, breaks the rollup silently.
    func testSystemLoadsAccountForEveryZoneExactlyOnce() {
        let engine = DesignEngine(project: twoSystemProject())
        let whole = engine.load?.zoneLoads.count ?? 0
        let acrossSystems = engine.systems.flatMap(\.load.zoneLoads).count
        XCTAssertEqual(whole, 3)
        XCTAssertEqual(acrossSystems, 3)
        XCTAssertTrue(engine.project.unassignedZones.isEmpty)
    }

    func testAssignmentIsExclusive() {
        let engine = DesignEngine(project: twoSystemProject())
        let zoneID = engine.project.zones[0].id
        engine.assign(zoneID: zoneID, toSystem: engine.project.systems[1].id)
        let owners = engine.project.systems.filter { $0.zoneIDs.contains(zoneID) }
        XCTAssertEqual(owners.count, 1, "a zone served by two systems is counted twice")
        XCTAssertEqual(owners.first?.name, "System 2 — upstairs")
    }

    func testUnassignedZoneIsReportedNotIgnored() {
        let engine = DesignEngine(project: twoSystemProject())
        engine.assign(zoneID: engine.project.zones[0].id, toSystem: nil)
        XCTAssertEqual(engine.project.unassignedZones.count, 1)
        XCTAssertTrue(engine.allWarnings.contains { $0.contains("not assigned to any system") })
        // It still appears in the whole-building load — it has a load either way.
        XCTAssertEqual(engine.load?.zoneLoads.count, 3)
    }

    func testEachSystemGetsItsOwnManualSVerdict() {
        let engine = DesignEngine(project: twoSystemProject())
        for system in engine.systems {
            XCTAssertNotNil(system.selection, system.name)
            XCTAssertFalse(system.selection?.checks.isEmpty ?? true, system.name)
        }
        // With more than one system there is no single "the" equipment match.
        XCTAssertNil(engine.selection)
    }

    func testRemovingASystemNeverLeavesTheProjectWithNone() {
        let engine = DesignEngine(project: twoSystemProject())
        engine.removeSystems(at: IndexSet([0, 1]))
        XCTAssertEqual(engine.project.systems.count, 1)
    }
}

final class LegacyFileTests: XCTestCase {

    /// Files written before systems existed must still open. A saved job is a record of
    /// work; breaking it to tidy a model is not a trade worth making.
    func testSingleSystemFileMigratesForward() throws {
        let zoneID = UUID()
        let legacy = """
        {
          "id": "\(UUID().uuidString)",
          "name": "Pfafftown Job 1042",
          "procedure": "Manual J",
          "designConditions": {
            "siteName": "Winston-Salem, NC", "altitudeFeet": 958,
            "latitude": 36.1, "longitude": -79.94, "coolingDesignMonth": 7,
            "winterOutdoorDryBulbF": 23, "summerOutdoorDryBulbF": 91.9,
            "summerOutdoorWetBulbF": 74.1, "summerDailyRangeF": 17.5,
            "indoorWinterDryBulbF": 70, "indoorSummerDryBulbF": 75,
            "indoorSummerRelativeHumidityPercent": 50, "weatherSource": "NOAA ISD"
          },
          "zones": [{
            "id": "\(zoneID.uuidString)", "name": "Living Room",
            "floorAreaSquareFeet": 320, "ceilingHeightFeet": 9, "surfaces": [],
            "internalGains": {"occupantCount": 2, "sensiblePerOccupant": 230,
              "latentPerOccupant": 200, "lightingWattsPerSquareFoot": 0,
              "applianceSensibleBtuh": 0, "applianceLatentBtuh": 0},
            "airExchange": {"airChangesPerHour": 0.5, "ventilationCFM": 0}
          }],
          "equipment": {
            "id": "\(UUID().uuidString)", "manufacturer": "Lennox", "modelNumber": "ML14XP1-030-230",
            "type": "Heat Pump", "totalCoolingCapacityBtuh": 30000,
            "sensibleCoolingCapacityBtuh": 22500, "heatingCapacityBtuh": 28000,
            "maximumAirflowCFM": 1000, "blowerExternalStaticPressure": 0.6
          },
          "staticPressureBudget": {"coolingCoil": 0.25, "filter": 0.1, "supplyRegisters": 0.03,
            "returnGrilles": 0.03, "balancingDampers": 0.03, "other": 0},
          "ductRuns": [],
          "supplyAirDeltaTF": 20,
          "sizingLimits": {"coolingMinimumFraction": 1.0, "airConditionerCoolingMaximum": 1.15,
            "heatPumpCoolingMaximumCoolingDominant": 1.15,
            "heatPumpCoolingMaximumHeatingDominant": 1.25,
            "heatingMinimumFraction": 1.0, "furnaceHeatingMaximumFraction": 1.4}
        }
        """
        let project = try JSONDecoder().decode(Project.self, from: Data(legacy.utf8))
        XCTAssertEqual(project.name, "Pfafftown Job 1042")
        XCTAssertEqual(project.systems.count, 1, "the old single system should be folded into one")
        XCTAssertEqual(project.systems[0].equipment.modelNumber, "ML14XP1-030-230")
        XCTAssertEqual(project.systems[0].supplyAirDeltaTF, 20)
        XCTAssertEqual(project.systems[0].zoneIDs, [zoneID], "the system should serve the file's zones")
        XCTAssertEqual(project.customer, CustomerInformation(), "absent customer decodes empty")
        XCTAssertTrue(project.customLibrary.isEmpty)

        // And re-saving writes the new shape, not both.
        let data = try JSONEncoder().encode(project)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("systems"))
        XCTAssertFalse(text.contains("\"supplyAirDeltaTF\"") && !text.contains("systems"))
    }
}

final class CustomLibraryTests: XCTestCase {

    func testCustomMaterialsAppearAheadOfShippedOnes() {
        let straw = Material(name: "Straw bale", resistancePerInch: 1.45, category: .insulation,
                             density: 7.5, specificHeat: 0.35)
        let library = CustomLibrary(materials: [straw])
        XCTAssertEqual(library.allMaterials().first?.name, "Straw bale")
        XCTAssertGreaterThan(library.allMaterials().count, Material.library.count)
    }

    /// A project material with a shipped name overrides it rather than appearing twice.
    func testProjectOverrideWinsOverShippedName() {
        let override = Material(name: "OSB / plywood", resistancePerInch: 9.9,
                                category: .sheathing, density: 41, specificHeat: 0.45)
        let library = CustomLibrary(materials: [override])
        let matches = library.allMaterials().filter { $0.name == "OSB / plywood" }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.resistancePerInch, 9.9)
    }

    func testCustomAssemblyIsOfferedForItsCategory() {
        let wall = Assembly(name: "Straw bale wall", category: .wall, layers: [
            Layer(material: .outsideAirFilmWinter, thicknessInches: 0),
            Layer(material: Material(name: "Straw bale", resistancePerInch: 1.45,
                                     category: .insulation, density: 7.5, specificHeat: 0.35),
                  thicknessInches: 18),
            Layer(material: .insideAirFilmVertical, thicknessInches: 0)
        ])
        let library = CustomLibrary(assemblies: [wall])
        XCTAssertEqual(library.assemblies(for: .wall).first?.name, "Straw bale wall")
        XCTAssertFalse(library.assemblies(for: .roof).contains { $0.name == "Straw bale wall" })
        XCTAssertGreaterThan(wall.effectiveR, 25)
    }

    /// A custom material with mass must drive the transient solver like any other.
    func testCustomMassiveAssemblySolvesTransiently() throws {
        let rammedEarth = Material(name: "Rammed earth", resistancePerInch: 0.15,
                                   category: .masonry, density: 120, specificHeat: 0.2)
        let wall = Assembly(name: "Rammed earth", category: .wall, layers: [
            Layer(material: .outsideAirFilmWinter, thicknessInches: 0),
            Layer(material: rammedEarth, thicknessInches: 18),
            Layer(material: .insideAirFilmVertical, thicknessInches: 0)
        ], solarAbsorptance: 0.6)
        let solAir = TransientConduction.solAirDay(conditions: .piedmontTriad,
                                                    orientation: .west, absorptance: 0.6)
        let response = try TransientConduction.solve(assembly: wall, solAir: solAir, roomF: 75)
        XCTAssertGreaterThan(response.lagHours, 2, "18 inches of earth must lag")
        XCTAssertLessThan(response.decrementFactor, 0.8)
    }
}
