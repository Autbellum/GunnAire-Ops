import XCTest
@testable import HVACCore

// MARK: - Psychrometrics

/// These pin the ASHRAE Chapter 1 coefficients against published reference values.
/// If a coefficient is mistyped the saturation curve still looks smooth and plausible,
/// and every enthalpy and humidity ratio downstream is quietly wrong, so the anchors
/// matter more than any other test here.
final class PsychrometricsTests: XCTestCase {

    func testSaturationPressureAgainstPublishedAnchors() throws {
        // Triple point of water: 0.08865 psia at 32 °F.
        XCTAssertEqual(try Psychrometrics.saturationPressure(dryBulbF: 32), 0.08865, accuracy: 0.0002)
        // Room temperature reference: 0.36334 psia at 70 °F.
        XCTAssertEqual(try Psychrometrics.saturationPressure(dryBulbF: 70), 0.36334, accuracy: 0.0005)
        // Normal boiling point: saturation equals one standard atmosphere at 212 °F.
        XCTAssertEqual(try Psychrometrics.saturationPressure(dryBulbF: 212), 14.696, accuracy: 0.02)
    }

    func testSaturationCurveIsContinuousAcrossTheIceBoundary() throws {
        let justBelow = try Psychrometrics.saturationPressure(dryBulbF: 31.999)
        let justAbove = try Psychrometrics.saturationPressure(dryBulbF: 32.001)
        XCTAssertEqual(justBelow, justAbove, accuracy: 1e-4)
    }

    func testStandardAtmosphere() {
        XCTAssertEqual(Psychrometrics.pressure(altitudeFeet: 0), 14.696, accuracy: 1e-6)
        // Piedmont Triad, roughly 900 ft.
        XCTAssertEqual(Psychrometrics.pressure(altitudeFeet: 902), 14.22, accuracy: 0.03)
        XCTAssertLessThan(Psychrometrics.pressure(altitudeFeet: 5_000),
                          Psychrometrics.pressure(altitudeFeet: 902))
    }

    func testStandardAirDensity() throws {
        // The 0.075 lb/ft³ behind the 1.08 and 4840 coefficients.
        let air = try Psychrometrics.state(dryBulbF: 70, relativeHumidityPercent: 0, altitudeFeet: 0)
        XCTAssertEqual(air.density, 0.0749, accuracy: 0.0008)
    }

    /// The familiar coefficients must fall out of the general relations at sea level.
    func testAirflowCoefficientsReduceToTheFamiliarValues() throws {
        XCTAssertEqual(try Psychrometrics.sensibleCoefficient(altitudeFeet: 0), 1.08, accuracy: 0.01)
        XCTAssertEqual(try Psychrometrics.latentCoefficient(altitudeFeet: 0), 4840, accuracy: 40)
        XCTAssertEqual(try Psychrometrics.totalCoefficient(altitudeFeet: 0), 4.5, accuracy: 0.04)
    }

    /// The reason altitude correction is in the engine at all.
    func testAltitudeReducesTheSensibleCoefficient() throws {
        let seaLevel = try Psychrometrics.sensibleCoefficient(altitudeFeet: 0)
        let triad = try Psychrometrics.sensibleCoefficient(altitudeFeet: 902)
        XCTAssertLessThan(triad, seaLevel)
        // About 3% thinner air at 900 ft.
        XCTAssertEqual(triad / seaLevel, 0.968, accuracy: 0.01)
    }

    func testHumidityRatioAndEnthalpyAtAKnownState() throws {
        // 80 °F dry bulb, 50% RH at sea level: W ≈ 0.0110 lb/lb, h ≈ 31.2 Btu/lb.
        let air = try Psychrometrics.state(dryBulbF: 80, relativeHumidityPercent: 50, altitudeFeet: 0)
        XCTAssertEqual(air.humidityRatio, 0.0110, accuracy: 0.0004)
        XCTAssertEqual(air.enthalpyBtuPerPound, 31.2, accuracy: 0.5)
        XCTAssertEqual(air.grains, 77, accuracy: 3)
    }

    func testDewPointRoundTrip() throws {
        let air = try Psychrometrics.state(dryBulbF: 78, relativeHumidityPercent: 60, altitudeFeet: 0)
        let rebuilt = try Psychrometrics.state(dryBulbF: 78, dewPointF: air.dewPointF, altitudeFeet: 0)
        XCTAssertEqual(rebuilt.humidityRatio, air.humidityRatio, accuracy: 1e-5)
        XCTAssertEqual(rebuilt.relativeHumidity, 0.60, accuracy: 0.005)
    }

    /// Design conditions arrive as a dry bulb with a mean coincident wet bulb, so this
    /// path carries the entire latent load.
    func testWetBulbStateMatchesDewPointState() throws {
        let fromWetBulb = try Psychrometrics.state(dryBulbF: 91.9, wetBulbF: 74.1, altitudeFeet: 902)
        XCTAssertGreaterThan(fromWetBulb.humidityRatio, 0)
        XCTAssertLessThan(fromWetBulb.relativeHumidity, 1.0)
        let rebuilt = try Psychrometrics.state(dryBulbF: 91.9,
                                               dewPointF: fromWetBulb.dewPointF, altitudeFeet: 902)
        XCTAssertEqual(rebuilt.humidityRatio, fromWetBulb.humidityRatio, accuracy: 1e-5)
    }

    func testSaturatedAirHasWetBulbEqualToDryBulb() throws {
        let air = try Psychrometrics.state(dryBulbF: 70, wetBulbF: 70, altitudeFeet: 0)
        XCTAssertEqual(air.relativeHumidity, 1.0, accuracy: 0.01)
    }

    func testImpossibleStatesAreRefused() {
        XCTAssertThrowsError(try Psychrometrics.state(dryBulbF: 70, relativeHumidityPercent: 140))
        XCTAssertThrowsError(try Psychrometrics.state(dryBulbF: 70, dewPointF: 80))
        XCTAssertThrowsError(try Psychrometrics.state(dryBulbF: 70, wetBulbF: 80))
        XCTAssertThrowsError(try Psychrometrics.saturationPressure(dryBulbF: 500))
    }
}

// MARK: - Module 1

final class LoadCalculationTests: XCTestCase {

    private var conditions: DesignConditions {
        var conditions = DesignConditions.piedmontTriad
        conditions.altitudeFeet = 0          // isolate the arithmetic from altitude correction
        conditions.indoorSummerDryBulbF = 75
        conditions.indoorWinterDryBulbF = 70
        conditions.summerOutdoorDryBulbF = 95
        conditions.winterOutdoorDryBulbF = 20
        return conditions
    }

    func testDesignTemperatureDifferences() {
        XCTAssertEqual(conditions.coolingDeltaT, 20, accuracy: 1e-9)   // 95 − 75
        XCTAssertEqual(conditions.heatingDeltaT, 50, accuracy: 1e-9)   // 70 − 20
    }

    /// q = U · A · ΔT with U = 1/R, checked by hand:
    /// (1/20) · 100 ft² · 50 °F = 250 Btu/h heating.
    func testEnvelopeConductionIsHandCheckable() throws {
        let zone = Zone(name: "Test", floorAreaSquareFeet: 100, ceilingHeightFeet: 8,
                        surfaces: [Surface(name: "Wall", category: .wall,
                                           areaSquareFeet: 100, rValue: 20)],
                        internalGains: InternalGains(occupantCount: 0, sensiblePerOccupant: 230,
                                                     latentPerOccupant: 200,
                                                     lightingWattsPerSquareFoot: 0,
                                                     applianceSensibleBtuh: 0, applianceLatentBtuh: 0),
                        airExchange: AirExchange(airChangesPerHour: 0, ventilationCFM: 0))
        let load = try LoadCalculator.calculate(zone: zone, conditions: conditions,
                                                procedure: .residentialManualJ)
        XCTAssertEqual(load.heatingBtuh, 250, accuracy: 0.01)
        XCTAssertEqual(load.coolingSensibleBtuh, 100, accuracy: 0.01)   // (1/20)·100·20
        XCTAssertEqual(load.coolingLatentBtuh, 0, accuracy: 0.01)
    }

    /// Infiltration: 0.5 ACH over 800 ft³ is 6.67 CFM; sensible = 1.08 · 6.67 · 50 ≈ 360 Btu/h.
    func testInfiltrationSensibleMatchesTheStandardCoefficient() throws {
        let zone = Zone(name: "Test", floorAreaSquareFeet: 100, ceilingHeightFeet: 8,
                        surfaces: [],
                        internalGains: .residentialDefault,
                        airExchange: AirExchange(airChangesPerHour: 0.5, ventilationCFM: 0))
        let load = try LoadCalculator.calculate(zone: zone, conditions: conditions,
                                                procedure: .residentialManualJ)
        let expectedCFM = 0.5 * 800 / 60
        XCTAssertEqual(expectedCFM, 6.667, accuracy: 0.001)
        XCTAssertEqual(load.heatingBtuh, 1.08 * expectedCFM * 50, accuracy: 4)
    }

    /// Latent load must be positive and driven by the moisture difference alone.
    func testLatentLoadTracksMoistureDifference() throws {
        var humid = conditions
        humid.summerOutdoorWetBulbF = 78
        var dry = conditions
        dry.summerOutdoorWetBulbF = 66

        let zone = Zone(name: "Test", floorAreaSquareFeet: 100, ceilingHeightFeet: 8,
                        surfaces: [], internalGains: .residentialDefault,
                        airExchange: AirExchange(airChangesPerHour: 0.5, ventilationCFM: 0))

        let humidLoad = try LoadCalculator.calculate(zone: zone, conditions: humid, procedure: .residentialManualJ)
        let dryLoad = try LoadCalculator.calculate(zone: zone, conditions: dry, procedure: .residentialManualJ)

        XCTAssertGreaterThan(humidLoad.coolingLatentBtuh, dryLoad.coolingLatentBtuh)
        // Sensible is untouched by the wet bulb.
        XCTAssertEqual(humidLoad.coolingSensibleBtuh, dryLoad.coolingSensibleBtuh, accuracy: 0.01)
    }

    /// Occupant gains: 3 people at 230/200 Btu/h.
    func testManualJOccupantGains() throws {
        let zone = Zone(name: "Test", floorAreaSquareFeet: 100, ceilingHeightFeet: 8,
                        surfaces: [],
                        internalGains: InternalGains(occupantCount: 3, sensiblePerOccupant: 230,
                                                     latentPerOccupant: 200,
                                                     lightingWattsPerSquareFoot: 5,
                                                     applianceSensibleBtuh: 0, applianceLatentBtuh: 0),
                        airExchange: AirExchange(airChangesPerHour: 0, ventilationCFM: 0))
        let load = try LoadCalculator.calculate(zone: zone, conditions: conditions,
                                                procedure: .residentialManualJ)
        XCTAssertEqual(load.coolingSensibleBtuh, 690, accuracy: 0.01)   // lighting ignored under Manual J
        XCTAssertEqual(load.coolingLatentBtuh, 600, accuracy: 0.01)
    }

    /// Manual N adds the lighting term Manual J ignores: 5 W/ft² · 100 ft² · 3.412 = 1706 Btu/h.
    func testManualNAddsLightingDensity() throws {
        let zone = Zone(name: "Test", floorAreaSquareFeet: 100, ceilingHeightFeet: 8,
                        surfaces: [],
                        internalGains: InternalGains(occupantCount: 3, sensiblePerOccupant: 230,
                                                     latentPerOccupant: 200,
                                                     lightingWattsPerSquareFoot: 5,
                                                     applianceSensibleBtuh: 0, applianceLatentBtuh: 0),
                        airExchange: AirExchange(airChangesPerHour: 0, ventilationCFM: 0))
        let load = try LoadCalculator.calculate(zone: zone, conditions: conditions,
                                                procedure: .commercialManualN)
        XCTAssertEqual(load.coolingSensibleBtuh, 690 + 1706.07, accuracy: 1)
    }

    /// Heating takes no credit for solar or internal gains: design heating is a
    /// night-time, unoccupied condition.
    func testHeatingIgnoresSolarAndInternalGains() throws {
        let zone = Zone(name: "Test", floorAreaSquareFeet: 100, ceilingHeightFeet: 8,
                        surfaces: [Surface(name: "Glass", category: .window,
                                           areaSquareFeet: 40, rValue: 3,
                                           orientation: .south, solarHeatGainCoefficient: 0.5)],
                        internalGains: InternalGains(occupantCount: 10, sensiblePerOccupant: 230,
                                                     latentPerOccupant: 200,
                                                     lightingWattsPerSquareFoot: 0,
                                                     applianceSensibleBtuh: 0, applianceLatentBtuh: 0),
                        airExchange: AirExchange(airChangesPerHour: 0, ventilationCFM: 0))
        let load = try LoadCalculator.calculate(zone: zone, conditions: conditions,
                                                procedure: .residentialManualJ)
        // Conduction only: (1/3) · 40 · 50 = 666.7 Btu/h.
        XCTAssertEqual(load.heatingBtuh, 666.67, accuracy: 0.5)
    }

    func testSolarGainAppliesOnlyToGlazing() throws {
        let glazed = Surface(name: "Glass", category: .window, areaSquareFeet: 40, rValue: 3,
                             orientation: .west, solarHeatGainCoefficient: 0.5)
        let opaque = Surface(name: "Wall", category: .wall, areaSquareFeet: 40, rValue: 3,
                             orientation: .west)
        let makeZone = { (surface: Surface) in
            Zone(name: "Z", floorAreaSquareFeet: 100, ceilingHeightFeet: 8, surfaces: [surface],
                 internalGains: .residentialDefault,
                 airExchange: AirExchange(airChangesPerHour: 0, ventilationCFM: 0))
        }
        let solar = LoadCalculator.solarTable(for: conditions)
        let glazedLoad = try LoadCalculator.calculate(zone: makeZone(glazed), conditions: conditions,
                                                      procedure: .residentialManualJ, solar: solar)
        let opaqueLoad = try LoadCalculator.calculate(zone: makeZone(opaque), conditions: conditions,
                                                      procedure: .residentialManualJ, solar: solar)
        // 40 ft² · 0.5 · E, where E is the computed west-wall peak for this site.
        let expected = 40 * 0.5 * (solar[.west] ?? 0)
        XCTAssertGreaterThan(expected, 100)
        XCTAssertEqual(glazedLoad.coolingSensibleBtuh - opaqueLoad.coolingSensibleBtuh, expected, accuracy: 1)
    }

    func testEquivalentTemperatureDifferenceOverridesPlainDeltaTForCoolingOnly() throws {
        let surface = Surface(name: "Roof", category: .roof, areaSquareFeet: 100, rValue: 25,
                              orientation: .horizontal, coolingEquivalentDeltaTF: 40)
        let zone = Zone(name: "Z", floorAreaSquareFeet: 100, ceilingHeightFeet: 8,
                        surfaces: [surface], internalGains: .residentialDefault,
                        airExchange: AirExchange(airChangesPerHour: 0, ventilationCFM: 0))
        let load = try LoadCalculator.calculate(zone: zone, conditions: conditions,
                                                procedure: .residentialManualJ)
        XCTAssertEqual(load.coolingSensibleBtuh, (1.0 / 25) * 100 * 40, accuracy: 0.01)
        // Heating still uses the plain design difference.
        XCTAssertEqual(load.heatingBtuh, (1.0 / 25) * 100 * 50, accuracy: 0.01)
    }

    func testInvalidSurfaceIsSkippedWithAWarning() throws {
        let zone = Zone(name: "Z", floorAreaSquareFeet: 100, ceilingHeightFeet: 8,
                        surfaces: [Surface(name: "Bad", category: .wall, areaSquareFeet: 0, rValue: 0)],
                        internalGains: .residentialDefault,
                        airExchange: AirExchange(airChangesPerHour: 0, ventilationCFM: 0))
        let load = try LoadCalculator.calculate(zone: zone, conditions: conditions,
                                                procedure: .residentialManualJ)
        XCTAssertTrue(load.warnings.contains { $0.contains("non-positive") })
    }
}

// MARK: - Module 2

final class EquipmentSelectionTests: XCTestCase {

    private func load(sensible: Double, latent: Double, heating: Double) -> ProjectLoad {
        let zone = ZoneLoad(id: UUID(), zoneID: UUID(), zoneName: "Z",
                            coolingSensibleBtuh: sensible, coolingLatentBtuh: latent,
                            heatingBtuh: heating, coolingComponents: [], heatingComponents: [],
                            warnings: [])
        return ProjectLoad(zoneLoads: [zone], designConditions: .piedmontTriad,
                           procedure: .residentialManualJ)
    }

    private func evaluate(_ equipment: EquipmentSpec, against load: ProjectLoad) throws -> SelectionResult {
        try EquipmentSelector.evaluate(load: load, equipment: equipment, limits: .standard,
                                       supplyAirDeltaTF: 20, altitudeFeet: 0)
    }

    func testCapacityInsideTheWindowPasses() throws {
        let load = load(sensible: 18_000, latent: 6_000, heating: 30_000)
        let equipment = EquipmentSpec(type: .heatPump, totalCoolingCapacityBtuh: 25_000,
                                      sensibleCoolingCapacityBtuh: 18_500,
                                      heatingCapacityBtuh: 30_000, maximumAirflowCFM: 1_000,
                                      blowerExternalStaticPressure: 0.5)
        let result = try evaluate(equipment, against: load)
        XCTAssertTrue(result.isAcceptable)
        XCTAssertEqual(result.totalCapacityRatio ?? 0, 25_000.0 / 24_000.0, accuracy: 1e-6)
    }

    func testOversizedCoolingFails() throws {
        let load = load(sensible: 18_000, latent: 6_000, heating: 30_000)
        let equipment = EquipmentSpec(type: .airConditioner, totalCoolingCapacityBtuh: 36_000,
                                      sensibleCoolingCapacityBtuh: 27_000,
                                      heatingCapacityBtuh: 0, maximumAirflowCFM: 1_400,
                                      blowerExternalStaticPressure: 0.5)
        let result = try evaluate(equipment, against: load)
        XCTAssertFalse(result.isAcceptable)
        let check = try XCTUnwrap(result.checks.first { $0.name == "Total cooling capacity" })
        XCTAssertEqual(check.status, .fail)
        XCTAssertTrue(check.detail.contains("Oversized"))
        XCTAssertTrue(check.detail.contains("short-cycle"))
    }

    func testUndersizedCoolingFails() throws {
        let load = load(sensible: 18_000, latent: 6_000, heating: 30_000)
        let equipment = EquipmentSpec(type: .airConditioner, totalCoolingCapacityBtuh: 18_000,
                                      sensibleCoolingCapacityBtuh: 14_000,
                                      heatingCapacityBtuh: 0, maximumAirflowCFM: 1_000,
                                      blowerExternalStaticPressure: 0.5)
        let result = try evaluate(equipment, against: load)
        XCTAssertFalse(result.isAcceptable)
        XCTAssertEqual(result.checks.first { $0.name == "Total cooling capacity" }?.status, .fail)
    }

    /// The case Manual S exists to catch: total capacity is inside the window, but the
    /// coil is the wrong shape and cannot remove the moisture.
    func testLatentShortfallFailsEvenWhenTotalCapacityPasses() throws {
        let load = load(sensible: 16_000, latent: 8_000, heating: 30_000)
        let equipment = EquipmentSpec(type: .heatPump, totalCoolingCapacityBtuh: 25_000,
                                      sensibleCoolingCapacityBtuh: 21_000,   // leaves only 4,000 latent
                                      heatingCapacityBtuh: 30_000, maximumAirflowCFM: 1_000,
                                      blowerExternalStaticPressure: 0.5)
        let result = try evaluate(equipment, against: load)
        XCTAssertEqual(result.checks.first { $0.name == "Total cooling capacity" }?.status, .pass)
        let latent = try XCTUnwrap(result.checks.first { $0.name == "Latent capacity" })
        XCTAssertEqual(latent.status, .fail)
        XCTAssertTrue(latent.detail.contains("humid"))
        XCTAssertFalse(result.isAcceptable)
    }

    func testSensibleShortfallIsReportedIndependently() throws {
        let load = load(sensible: 20_000, latent: 4_000, heating: 30_000)
        let equipment = EquipmentSpec(type: .heatPump, totalCoolingCapacityBtuh: 25_000,
                                      sensibleCoolingCapacityBtuh: 17_000,
                                      heatingCapacityBtuh: 30_000, maximumAirflowCFM: 1_200,
                                      blowerExternalStaticPressure: 0.5)
        let result = try evaluate(equipment, against: load)
        XCTAssertEqual(result.checks.first { $0.name == "Sensible capacity" }?.status, .fail)
    }

    /// A heat pump short of the heating load is normal practice — supplemental heat covers
    /// the balance point — so it cautions rather than fails. A furnace must meet it.
    func testHeatPumpHeatingShortfallCautionsAndSizesStripHeat() throws {
        let load = load(sensible: 18_000, latent: 6_000, heating: 40_000)
        let heatPump = EquipmentSpec(type: .heatPump, totalCoolingCapacityBtuh: 25_000,
                                     sensibleCoolingCapacityBtuh: 18_500,
                                     heatingCapacityBtuh: 28_000, maximumAirflowCFM: 1_000,
                                     blowerExternalStaticPressure: 0.5)
        let heatPumpCheck = try XCTUnwrap(try evaluate(heatPump, against: load)
                                            .checks.first { $0.name == "Heating capacity" })
        XCTAssertEqual(heatPumpCheck.status, .caution)
        // 40,000 − 28,000 = 12,000 Btu/h short, which is 3.5 kW of strip heat.
        XCTAssertTrue(heatPumpCheck.detail.contains("3.5 kW"), heatPumpCheck.detail)

        var furnace = heatPump
        furnace.type = .furnace
        XCTAssertEqual(try evaluate(furnace, against: load)
                        .checks.first { $0.name == "Heating capacity" }?.status, .fail)
    }

    /// Climate dominance is a property of the climate, not of one building's load ratio.
    /// The Triad has 52 °F of heating ΔT against 17 °F of cooling ΔT, so a heat pump gets
    /// the 125% cooling allowance even in a house whose cooling load exceeds its heating
    /// load — which a well-insulated, glassy house in the Piedmont routinely does.
    func testHeatPumpAllowanceFollowsClimateNotBuildingLoads() throws {
        XCTAssertTrue(DesignConditions.piedmontTriad.isHeatingDominantClimate)

        // A cooling-heavy building in that heating-dominant climate.
        let zone = ZoneLoad(id: UUID(), zoneID: UUID(), zoneName: "Z",
                            coolingSensibleBtuh: 18_000, coolingLatentBtuh: 6_000,
                            heatingBtuh: 9_000, coolingComponents: [], heatingComponents: [],
                            warnings: [])
        let coolingHeavy = ProjectLoad(zoneLoads: [zone],
                                       designConditions: .piedmontTriad,
                                       procedure: .residentialManualJ)
        // 120% of the 24,000 load: over the 115% ceiling, inside the 125% one.
        let equipment = EquipmentSpec(type: .heatPump, totalCoolingCapacityBtuh: 28_800,
                                      sensibleCoolingCapacityBtuh: 19_000,
                                      heatingCapacityBtuh: 9_000, maximumAirflowCFM: 1_200,
                                      blowerExternalStaticPressure: 0.8)
        let result = try EquipmentSelector.evaluate(load: coolingHeavy, equipment: equipment,
                                                    limits: .standard, supplyAirDeltaTF: 20,
                                                    altitudeFeet: 902)
        let check = try XCTUnwrap(result.checks.first { $0.name == "Total cooling capacity" })
        XCTAssertEqual(check.status, .pass, check.detail)
        XCTAssertTrue(check.detail.contains("heating-dominant"), check.detail)

        // The same machine as a plain air conditioner gets only 115% and fails.
        var airConditioner = equipment
        airConditioner.type = .airConditioner
        let acResult = try EquipmentSelector.evaluate(load: coolingHeavy, equipment: airConditioner,
                                                      limits: .standard, supplyAirDeltaTF: 20,
                                                      altitudeFeet: 902)
        XCTAssertEqual(acResult.checks.first { $0.name == "Total cooling capacity" }?.status, .fail)
    }

    func testRequiredAirflowFollowsTheSensibleLoad() throws {
        let load = load(sensible: 21_600, latent: 6_000, heating: 30_000)
        let equipment = EquipmentSpec(type: .heatPump, totalCoolingCapacityBtuh: 29_000,
                                      sensibleCoolingCapacityBtuh: 22_000,
                                      heatingCapacityBtuh: 30_000, maximumAirflowCFM: 1_200,
                                      blowerExternalStaticPressure: 0.5)
        let result = try evaluate(equipment, against: load)
        // 21,600 / (1.08 · 20) = 1,000 CFM.
        XCTAssertEqual(result.requiredAirflowCFM, 1_000, accuracy: 5)
    }

    func testAirflowBeyondTheBlowerFails() throws {
        let load = load(sensible: 43_200, latent: 6_000, heating: 30_000)
        let equipment = EquipmentSpec(type: .heatPump, totalCoolingCapacityBtuh: 52_000,
                                      sensibleCoolingCapacityBtuh: 44_000,
                                      heatingCapacityBtuh: 30_000, maximumAirflowCFM: 1_200,
                                      blowerExternalStaticPressure: 0.5)
        XCTAssertEqual(try evaluate(equipment, against: load)
                        .checks.first { $0.name == "Blower airflow" }?.status, .fail)
    }
}

// MARK: - Module 3a

final class AirDistributionTests: XCTestCase {

    private func load(_ zones: [(String, Double, Double)]) -> ProjectLoad {
        ProjectLoad(zoneLoads: zones.map { name, sensible, heating in
            ZoneLoad(id: UUID(), zoneID: UUID(), zoneName: name,
                     coolingSensibleBtuh: sensible, coolingLatentBtuh: 0,
                     heatingBtuh: heating, coolingComponents: [], heatingComponents: [], warnings: [])
        }, designConditions: .piedmontTriad, procedure: .residentialManualJ)
    }

    /// Room CFM = System CFM · (Room Sensible / Total Sensible).
    func testAllocationIsProportionalToSensibleLoad() {
        let projectLoad = load([("A", 12_000, 12_000), ("B", 6_000, 6_000), ("C", 2_000, 2_000)])
        let airflows = AirDistributionCalculator.allocate(load: projectLoad,
                                                          systemCoolingCFM: 1_000,
                                                          systemHeatingCFM: 1_000)
        XCTAssertEqual(airflows[0].coolingCFM, 600, accuracy: 0.01)   // 12/20
        XCTAssertEqual(airflows[1].coolingCFM, 300, accuracy: 0.01)   // 6/20
        XCTAssertEqual(airflows[2].coolingCFM, 100, accuracy: 0.01)   // 2/20
        XCTAssertEqual(airflows.reduce(0) { $0 + $1.coolingCFM }, 1_000, accuracy: 0.01)
    }

    /// One duct serves both seasons, so it is sized on whichever demands more air.
    /// A north room with little solar gain but high conduction loss is the usual case.
    func testDesignAirflowTakesTheGoverningSeason() {
        let projectLoad = load([("South", 12_000, 6_000), ("North", 4_000, 10_000)])
        let airflows = AirDistributionCalculator.allocate(load: projectLoad,
                                                          systemCoolingCFM: 800,
                                                          systemHeatingCFM: 800)
        let north = try! XCTUnwrap(airflows.first { $0.zoneName == "North" })
        XCTAssertEqual(north.coolingCFM, 200, accuracy: 0.01)   // 4/16
        XCTAssertEqual(north.heatingCFM, 500, accuracy: 0.01)   // 10/16
        XCTAssertEqual(north.designCFM, 500, accuracy: 0.01)
    }

    func testZeroLoadAllocatesNothingRatherThanDividingByZero() {
        let projectLoad = load([("A", 0, 0)])
        let airflows = AirDistributionCalculator.allocate(load: projectLoad,
                                                          systemCoolingCFM: 800, systemHeatingCFM: 800)
        XCTAssertEqual(airflows[0].designCFM, 0)
    }
}

// MARK: - Module 3b

final class DuctDesignTests: XCTestCase {

    func testAvailableStaticPressureAndFrictionRate() {
        var equipment = EquipmentSpec()
        equipment.blowerExternalStaticPressure = 0.50
        let budget = StaticPressureBudget(coolingCoil: 0.20, filter: 0.08, supplyRegisters: 0.03,
                                          returnGrilles: 0.03, balancingDampers: 0.06, other: 0)
        // ASP = 0.50 − 0.40 = 0.10 in. w.g.
        XCTAssertEqual(budget.total, 0.40, accuracy: 1e-9)

        let runs = [DuctRun(name: "Supply", role: .supplyTrunk, physicalLengthFeet: 60),
                    DuctRun(name: "Return", role: .returnTrunk, physicalLengthFeet: 40)]
        let result = DuctDesigner.frictionRate(equipment: equipment, budget: budget, runs: runs)
        XCTAssertEqual(result.availableStaticPressure, 0.10, accuracy: 1e-9)
        XCTAssertEqual(result.governingTotalEquivalentLength, 100, accuracy: 1e-9)
        // FR = 0.10 · 100 / 100 = 0.10 in. w.g. per 100 ft.
        XCTAssertEqual(result.frictionRatePer100Feet, 0.10, accuracy: 1e-9)
    }

    func testComponentLossesExceedingBlowerAreCalledOut() {
        var equipment = EquipmentSpec()
        equipment.blowerExternalStaticPressure = 0.30
        let result = DuctDesigner.frictionRate(equipment: equipment, budget: .typical,
                                               runs: [DuctRun(name: "S", role: .supplyTrunk, physicalLengthFeet: 50)])
        XCTAssertLessThanOrEqual(result.availableStaticPressure, 0)
        XCTAssertTrue(result.warnings.contains { $0.contains("No pressure is left") })
    }

    /// Sizing and friction must be exact inverses of one another.
    func testDiameterAndFrictionRateRoundTrip() throws {
        let roughness = DuctMaterial.galvanizedSteel.roughnessFeet
        for cfm in [100.0, 400.0, 1_200.0] {
            for target in [0.06, 0.10, 0.15] {
                let diameter = try DuctDesigner.diameter(cfm: cfm, targetFrictionRate: target,
                                                         roughnessFeet: roughness)
                let recovered = try DuctDesigner.frictionRate(cfm: cfm, diameterInches: diameter,
                                                              roughnessFeet: roughness)
                XCTAssertEqual(recovered, target, accuracy: target * 0.01,
                               "round trip failed at \(cfm) CFM, \(target) in/100 ft")
            }
        }
    }

    /// Anchored against a hand calculation rather than a rule of thumb.
    ///
    /// 400 CFM at 0.10 in. w.g. per 100 ft in galvanised duct needs about 9.7 in. The
    /// familiar "8 in. carries 400 CFM" belongs to a much higher friction rate: an 8 in.
    /// round at 400 CFM runs 1,146 FPM and 0.25 in. w.g. per 100 ft, which is both far
    /// over the 600 FPM branch limit and two and a half times the friction budget.
    func testTypicalBranchSizeMatchesPractice() throws {
        let roughness = DuctMaterial.galvanizedSteel.roughnessFeet
        let diameter = try DuctDesigner.diameter(cfm: 400, targetFrictionRate: 0.10,
                                                 roughnessFeet: roughness)
        XCTAssertEqual(diameter, 9.7, accuracy: 0.2)
        // The rule-of-thumb size, shown to be a different friction rate entirely.
        XCTAssertEqual(try DuctDesigner.frictionRate(cfm: 400, diameterInches: 8,
                                                     roughnessFeet: roughness),
                       0.254, accuracy: 0.01)
    }

    func testLargerDuctAlwaysMeansLessFriction() throws {
        let roughness = DuctMaterial.galvanizedSteel.roughnessFeet
        var previous = Double.greatestFiniteMagnitude
        for diameter in stride(from: 4.0, through: 24.0, by: 2.0) {
            let rate = try DuctDesigner.frictionRate(cfm: 600, diameterInches: diameter,
                                                     roughnessFeet: roughness)
            XCTAssertLessThan(rate, previous)
            previous = rate
        }
    }

    /// The reason material is an input rather than a constant.
    func testFlexibleDuctNeedsMoreDiameterThanSheetMetal() throws {
        let metal = try DuctDesigner.diameter(cfm: 400, targetFrictionRate: 0.10,
                                              roughnessFeet: DuctMaterial.galvanizedSteel.roughnessFeet)
        let flex = try DuctDesigner.diameter(cfm: 400, targetFrictionRate: 0.10,
                                             roughnessFeet: DuctMaterial.flexibleDuctFullyExtended.roughnessFeet)
        XCTAssertGreaterThan(flex, metal)
    }

    /// Huebscher's equivalence. A square duct's equivalent diameter exceeds its side.
    func testEquivalentDiameterOfRectangularDuct() throws {
        let square = try DuctDesigner.equivalentDiameter(height: 10, width: 10)
        XCTAssertEqual(square, 10.9, accuracy: 0.15)
        // 1.30 · (8·20)^0.625 / (28)^0.25 = 13.481 in.
        let wide = try DuctDesigner.equivalentDiameter(height: 8, width: 20)
        XCTAssertEqual(wide, 13.481, accuracy: 0.02)
        XCTAssertThrowsError(try DuctDesigner.equivalentDiameter(height: 0, width: 10))
    }

    func testRectangularOptionsRespectAspectRatio() {
        let options = DuctDesigner.rectangularOptions(equivalentTo: 14, maximumAspectRatio: 4)
        XCTAssertFalse(options.isEmpty)
        for option in options {
            XCTAssertLessThanOrEqual(option.width / option.height, 4.0)
            let equivalent = try? DuctDesigner.equivalentDiameter(height: option.height, width: option.width)
            XCTAssertEqual(equivalent ?? 0, 14, accuracy: 1.2)
        }
    }

    func testImpossibleAirflowIsRefusedRatherThanGuessed() {
        XCTAssertThrowsError(try DuctDesigner.diameter(cfm: 500_000, targetFrictionRate: 0.08,
                                                       roughnessFeet: 0.0003))
        XCTAssertThrowsError(try DuctDesigner.diameter(cfm: 400, targetFrictionRate: 0,
                                                       roughnessFeet: 0.0003))
    }

    /// A high friction rate would force a small, fast duct. The sizer must upsize to the
    /// velocity limit and say so, rather than hand over an undersized run with a warning
    /// attached — a warning is not a duct size.
    func testHighFrictionRateUpsizesRatherThanLeavingItFast() {
        let zoneID = UUID()
        let run = DuctRun(name: "Branch", role: .supplyBranch, physicalLengthFeet: 20,
                          servingZoneID: zoneID)
        let airflow = ZoneAirflow(id: UUID(), zoneID: zoneID, zoneName: "Z",
                                  coolingCFM: 900, heatingCFM: 0, designCFM: 900,
                                  sensibleLoadFraction: 1)
        let sized = DuctDesigner.size(runs: [run], airflows: [airflow], systemCFM: 900, frictionRate: 0.6)
        XCTAssertLessThanOrEqual(sized[0].velocityFPM, run.role.maximumVelocityFPM)
        XCTAssertTrue(sized[0].warnings.contains { $0.contains("Upsized") }, "\(sized[0].warnings)")
    }
}

// MARK: - The cascade

@MainActor
final class DesignEngineTests: XCTestCase {

    func testSampleProjectCalculatesEndToEnd() throws {
        let engine = DesignEngine()
        XCTAssertNil(engine.calculationError)
        let load = try XCTUnwrap(engine.load)
        XCTAssertGreaterThan(load.coolingSensibleBtuh, 0)
        XCTAssertGreaterThan(load.coolingLatentBtuh, 0)
        XCTAssertGreaterThan(load.heatingBtuh, 0)
        XCTAssertNotNil(engine.selection)
        XCTAssertEqual(engine.zoneAirflows.count, 2)
        XCTAssertFalse(engine.ductSizing.isEmpty)
    }

    /// The property the whole architecture exists for: one envelope change must move
    /// every downstream stage, not just the load.
    func testEnvelopeChangeRipplesThroughToDuctSizing() {
        let engine = DesignEngine()
        let originalLoad = engine.load?.coolingSensibleBtuh ?? 0
        let originalCFM = engine.systemCoolingCFM
        let originalTrunk = engine.ductSizing.first { $0.role == .supplyTrunk }?.nominalDiameterInches ?? 0

        // Triple the west glazing of the first zone.
        if let index = engine.project.zones.firstIndex(where: { $0.name == "Living Room" }),
           let glass = engine.project.zones[index].surfaces.firstIndex(where: { $0.name == "West Windows" }) {
            engine.project.zones[index].surfaces[glass].areaSquareFeet *= 3
        }

        XCTAssertGreaterThan(engine.load?.coolingSensibleBtuh ?? 0, originalLoad)
        XCTAssertGreaterThan(engine.systemCoolingCFM, originalCFM)
        let updatedTrunk = engine.ductSizing.first { $0.role == .supplyTrunk }?.nominalDiameterInches ?? 0
        XCTAssertGreaterThanOrEqual(updatedTrunk, originalTrunk)
    }

    func testSwitchingProcedureChangesTheLoad() {
        let engine = DesignEngine()
        for index in engine.project.zones.indices {
            engine.project.zones[index].internalGains.lightingWattsPerSquareFoot = 2
        }
        let residential = engine.load?.coolingSensibleBtuh ?? 0
        engine.project.procedure = .commercialManualN
        XCTAssertGreaterThan(engine.load?.coolingSensibleBtuh ?? 0, residential)
    }

    func testRemovingAZoneDetachesItsDuctRun() {
        let engine = DesignEngine()
        let zoneID = engine.project.zones[0].id
        XCTAssertTrue(engine.project.systems.flatMap(\.ductRuns).contains { $0.servingZoneID == zoneID })
        engine.removeZones(at: IndexSet(integer: 0))
        XCTAssertFalse(engine.project.systems.flatMap(\.ductRuns).contains { $0.servingZoneID == zoneID })
        XCTAssertFalse(engine.project.systems.contains { $0.zoneIDs.contains(zoneID) },
                       "a removed zone must also leave its system")
    }

    func testAltitudeChangesTheCalculatedLoad() {
        let engine = DesignEngine()
        engine.project.designConditions.altitudeFeet = 0
        let seaLevel = engine.load?.coolingSensibleBtuh ?? 0
        engine.project.designConditions.altitudeFeet = 5_000
        let altitude = engine.load?.coolingSensibleBtuh ?? 0
        // Thinner air carries less heat per CFM, so the infiltration term falls.
        XCTAssertLessThan(altitude, seaLevel)
    }
}

extension DuctDesignTests {
    /// Friction rate sets the size, the velocity limit caps it. A branch sized purely on
    /// friction can land over the noise threshold at the airflow it carries, so the
    /// sizer must step up rather than merely complain.
    func testRunIsUpsizedToRespectTheVelocityLimit() {
        let zoneID = UUID()
        let run = DuctRun(name: "Branch", role: .supplyBranch, physicalLengthFeet: 20,
                          servingZoneID: zoneID)
        let airflow = ZoneAirflow(id: UUID(), zoneID: zoneID, zoneName: "Z",
                                  coolingCFM: 215, heatingCFM: 0, designCFM: 215,
                                  sensibleLoadFraction: 1)
        let sized = DuctDesigner.size(runs: [run], airflows: [airflow],
                                      systemCFM: 215, frictionRate: 0.113)
        XCTAssertLessThanOrEqual(sized[0].velocityFPM, run.role.maximumVelocityFPM,
                                 "sizer left a branch over its velocity limit")
        XCTAssertTrue(sized[0].warnings.contains { $0.contains("Upsized") },
                      "the upsize should be reported, not silent")
    }
}
