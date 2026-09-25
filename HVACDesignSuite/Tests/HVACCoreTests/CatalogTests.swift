import XCTest
@testable import HVACCore

final class EquipmentCatalogTests: XCTestCase {

    private func load(total: Double, sensible: Double, heating: Double) -> ProjectLoad {
        let zone = ZoneLoad(id: UUID(), zoneID: UUID(), zoneName: "Z",
                            coolingSensibleBtuh: sensible,
                            coolingLatentBtuh: total - sensible,
                            heatingBtuh: heating, coolingComponents: [],
                            heatingComponents: [], warnings: [])
        return ProjectLoad(zoneLoads: [zone], designConditions: .piedmontTriad,
                           procedure: .residentialManualJ)
    }

    /// Model strings must decode back to the tonnage they were generated for.
    func testGeneratedModelsCarryTheirNominalCapacity() {
        for (code, tons) in EquipmentCatalog.nominalCodes {
            for brand in EquipmentCatalog.Brand.allCases {
                for heatPump in [true, false] {
                    for model in brand.outdoorUnit(code: code, heatPump: heatPump) {
                        XCTAssertTrue(model.contains(code),
                                      "\(model) does not carry \(code) for \(tons) tons")
                    }
                }
            }
        }
    }

    /// Verified naming: Lennox carries capacity in its dash group, American Standard at
    /// positions 6–8, with 4A6H for heat pumps and 4A7A for air conditioners.
    func testVerifiedNamingConventions() {
        XCTAssertEqual(EquipmentCatalog.Brand.lennox.outdoorUnit(code: "036", heatPump: true).last,
                       "ML14XP1-036-230")
        XCTAssertEqual(EquipmentCatalog.Brand.lennox.outdoorUnit(code: "036", heatPump: false).last,
                       "ML14XC1-036-230")
        XCTAssertEqual(EquipmentCatalog.Brand.americanStandard.outdoorUnit(code: "036", heatPump: true).last,
                       "4A6H4036G1000A")
        XCTAssertEqual(EquipmentCatalog.Brand.americanStandard.outdoorUnit(code: "036", heatPump: false).last,
                       "4A7A4036G1000A")
    }

    /// The Triad is heating dominant, so a heat pump gets the 125% ceiling. A 24,000 Btu/h
    /// load therefore admits 2.0 and 2.5 ton, and excludes 3.0 ton at 150%.
    func testHeatPumpWindowInAHeatingDominantClimate() {
        let result = EquipmentCatalog.recommend(load: load(total: 24_000, sensible: 18_000, heating: 40_000))
        XCTAssertEqual(result.status, .passed)
        XCTAssertEqual(result.targetTonnage, 2.0, accuracy: 0.01)
        let tons = Set(result.candidates.map(\.nominalTons))
        XCTAssertTrue(tons.contains(2.0))
        XCTAssertTrue(tons.contains(2.5))
        XCTAssertFalse(tons.contains(3.0), "3 ton is 150% of load and must be excluded")
        XCTAssertFalse(tons.contains(1.5), "1.5 ton is below the load and must be excluded")
    }

    /// An air conditioner gets only 115%, so 2.5 ton drops out of the same load.
    func testAirConditionerWindowIsTighter() {
        let result = EquipmentCatalog.recommend(
            load: load(total: 24_000, sensible: 18_000, heating: 40_000), heatPump: false)
        XCTAssertFalse(result.candidates.map(\.nominalTons).contains(2.5),
                       "2.5 ton is 125% of load, over the 115% ceiling for an air conditioner")
    }

    /// A latent-heavy load must not be matched by a nominal split that cannot remove it.
    func testLatentHeavyLoadIsRejectedWithAReason() {
        let result = EquipmentCatalog.recommend(
            load: load(total: 24_000, sensible: 14_000, heating: 40_000))
        XCTAssertTrue(result.notes.contains { $0.contains("latent") },
                      "a latent shortfall should be explained, not silently dropped")
    }

    func testBrandPreferenceIsHonoured() {
        let result = EquipmentCatalog.recommend(
            load: load(total: 24_000, sensible: 18_000, heating: 40_000), brands: [.lennox])
        XCTAssertFalse(result.candidates.isEmpty)
        XCTAssertTrue(result.candidates.allSatisfy { $0.brand == .lennox })
    }

    func testLoadTooLargeForStockIsReportedUndersized() {
        let result = EquipmentCatalog.recommend(
            load: load(total: 90_000, sensible: 68_000, heating: 120_000))
        XCTAssertEqual(result.status, .undersized)
        XCTAssertTrue(result.candidates.isEmpty)
    }

    // MARK: Schema

    func testJSONMatchesTheAgreedSchema() throws {
        let result = EquipmentCatalog.recommend(
            load: load(total: 24_000, sensible: 18_000, heating: 40_000), brands: [.lennox])
        let text = try EquipmentCatalog.json(result)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])

        XCTAssertEqual(object["load_match_status"] as? String, "PASSED")
        XCTAssertNotNil(object["target_tonnage"] as? Double)
        let recommendations = try XCTUnwrap(object["recommendations"] as? [[String: Any]])
        XCTAssertFalse(recommendations.isEmpty)

        let first = recommendations[0]
        XCTAssertEqual(first["brand"] as? String, "Lennox")
        XCTAssertNotNil(first["system_type"] as? String)
        XCTAssertEqual(first["data_basis"] as? String, "nominal_derived")

        let components = try XCTUnwrap(first["components"] as? [String: Any])
        XCTAssertNotNil(components["outdoor_unit"] as? String)
        // A heat pump takes an air handler and carries no separate coil.
        XCTAssertTrue(components["indoor_coil"] is NSNull)
        XCTAssertNotNil(components["furnace_or_air_handler"] as? String)

        let performance = try XCTUnwrap(first["estimated_performance"] as? [String: Any])
        XCTAssertNotNil(performance["total_cooling_btu"] as? Int)
        XCTAssertNotNil(performance["sensible_cooling_btu"] as? Int)
        XCTAssertNotNil(performance["latent_cooling_btu"] as? Int)
        XCTAssertTrue(performance["estimated_seer2"] is NSNull,
                      "SEER2 belongs to an AHRI matched combination and must not be invented")
    }

    func testSensibleAndLatentSumToTotal() {
        let result = EquipmentCatalog.recommend(
            load: load(total: 24_000, sensible: 18_000, heating: 40_000))
        for candidate in result.candidates {
            XCTAssertEqual(candidate.sensibleCoolingBtu + candidate.latentCoolingBtu,
                           candidate.totalCoolingBtu, accuracy: 1)
        }
    }
}

extension EquipmentCatalogTests {
    /// Binary floats leak through JSON as 0.72999999999999998, which is noise to whatever
    /// reads the file next. Numbers are emitted at the precision intended.
    func testJSONNumbersCarryCleanPrecision() throws {
        let result = EquipmentCatalog.recommend(
            load: load(total: 8_787, sensible: 6_825, heating: 6_299))
        let text = try EquipmentCatalog.json(result)
        XCTAssertTrue(text.contains("0.73"), text)
        XCTAssertFalse(text.contains("0.7299"), "float tail leaked into the payload")

        let matched = EquipmentCatalog.recommend(
            load: load(total: 24_000, sensible: 17_000, heating: 40_000), brands: [.lennox])
        let json = try EquipmentCatalog.json(matched)
        XCTAssertFalse(json.contains("9999999"), "float tail leaked into the payload")
        XCTAssertFalse(json.contains("0000000"), "float tail leaked into the payload")
    }
}

extension EquipmentCatalogTests {

    /// Indoor components are tabulated from manufacturer literature, so the capacity each
    /// one carries must match the system it is matched into.
    func testHeatPumpGetsAnAirHandlerCarryingTheRightCapacity() {
        let result = EquipmentCatalog.recommend(
            load: load(total: 34_000, sensible: 25_000, heating: 50_000))
        XCTAssertFalse(result.candidates.isEmpty)
        for candidate in result.candidates {
            XCTAssertNil(candidate.indoorCoil, "a heat pump air handler carries its own coil")
            let handler = try? XCTUnwrap(candidate.furnaceOrAirHandler)
            XCTAssertNotNil(handler)
            let code = String(format: "%03d", Int(candidate.nominalTons * 12))
            switch candidate.brand {
            case .lennox:
                XCTAssertEqual(handler, "CBA38MV-\(code)-230")
            case .americanStandard:
                // GAM5 carries its capacity in thousands of Btu/h.
                XCTAssertTrue(handler?.contains(String(code.dropFirst())) ?? false,
                              "\(handler ?? "nil") should carry \(code)")
            }
        }
    }

    /// A cooling-only split pairs with a cased coil for the furnace already on site.
    ///
    /// The load is chosen to sit comfortably inside the window: at a nominal SHR of 0.75
    /// a 2-ton unit offers 18,000 Btu/h sensible and 6,000 latent, and both must cover
    /// the load independently.
    func testAirConditionerGetsACoilNotAnAirHandler() {
        let result = EquipmentCatalog.recommend(
            load: load(total: 22_000, sensible: 16_500, heating: 30_000), heatPump: false)
        XCTAssertFalse(result.candidates.isEmpty)
        for candidate in result.candidates {
            XCTAssertNotNil(candidate.indoorCoil, "a split AC needs a cased coil")
            XCTAssertNil(candidate.furnaceOrAirHandler,
                         "no furnace is selected here; a furnace is sized on the heating load")
        }
    }

    /// Lennox coils carry two capacity digits while its outdoor units and air handlers
    /// carry three. Getting that backwards produces a part number that does not exist.
    func testLennoxCoilUsesTwoDigitsAndAirHandlerThree() {
        XCTAssertEqual(EquipmentCatalog.Indoor.lennoxCoil(code: "036"), "CX35-36B-6F")
        XCTAssertEqual(EquipmentCatalog.Indoor.lennoxAirHandler(code: "036"), "CBA38MV-036-230")
        XCTAssertEqual(EquipmentCatalog.Indoor.lennoxCoil(code: "060"), "CX35-60D-6F")
        XCTAssertNil(EquipmentCatalog.Indoor.lennoxCoil(code: "099"))
    }

    /// American Standard coil numbers are sequence numbers, not capacities, so they are
    /// matched against the tonnage ranges the product guide publishes.
    func testAmericanStandardCoilMatchesByPublishedRange() {
        XCTAssertEqual(EquipmentCatalog.Indoor.americanStandardCoil(tons: 2.0), "4MXCB004AC6HCA1")
        XCTAssertEqual(EquipmentCatalog.Indoor.americanStandardCoil(tons: 3.0), "4MXCC005AC6HCA1")
        XCTAssertEqual(EquipmentCatalog.Indoor.americanStandardCoil(tons: 4.0), "4MXCC007AC6HCA1")
        XCTAssertEqual(EquipmentCatalog.Indoor.americanStandardCoil(tons: 5.0), "4MXCC009AC6HCA1")
    }

    func testEveryNominalSizeHasIndoorComponentsForBothBrands() {
        for (code, tons) in EquipmentCatalog.nominalCodes {
            XCTAssertNotNil(EquipmentCatalog.Indoor.lennoxCoil(code: code), code)
            XCTAssertNotNil(EquipmentCatalog.Indoor.lennoxAirHandler(code: code), code)
            XCTAssertNotNil(EquipmentCatalog.Indoor.americanStandardAirHandler(code: code), code)
            XCTAssertNotNil(EquipmentCatalog.Indoor.americanStandardCoil(tons: tons), code)
        }
    }
}
