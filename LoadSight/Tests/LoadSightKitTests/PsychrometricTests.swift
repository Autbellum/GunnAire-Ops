import XCTest
import LoadSightKit
import LoadSightUI

final class PsychrometricTests: XCTestCase {
    struct Fixture: Decodable { let rows: [Row] }
    struct Row: Decodable { let t, rh, p, w, wet, dew, pv, h, v, hip: Double }
    func testReferenceGridAcrossTemperatureHumidityAndAltitude() throws {
        let url = Bundle.module.url(forResource: "PsychrometricStates", withExtension: "json", subdirectory: "Fixtures")!
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.rows.count, 160)
        for r in fixture.rows {
            let s = try Psychrometrics.state(dryBulbC: r.t, relativeHumidity: r.rh, pressurePa: r.p)
            XCTAssertEqual(s.humidityRatio, r.w, accuracy: 1e-10)
            XCTAssertEqual(try XCTUnwrap(s.wetBulbC), r.wet, accuracy: 0.002)
            XCTAssertEqual(try XCTUnwrap(s.dewPointC), r.dew, accuracy: 0.002)
            XCTAssertEqual(s.enthalpyKJPerKgDryAir, r.h, accuracy: 1e-7)
            XCTAssertEqual(s.volumeM3PerKgDryAir, r.v, accuracy: 1e-9)
            XCTAssertEqual(s.vaporPressurePa, r.pv, accuracy: 1e-7)
            XCTAssertEqual(s.enthalpyBtuPerLbDryAir, r.hip, accuracy: 1e-8)
        }
    }
    func testDryAirAndSaturationAndInvalidInputs() throws {
        let dry = try Psychrometrics.state(dryBulbC: 25, relativeHumidity: 0, pressurePa: 101325)
        XCTAssertEqual(dry.humidityRatio, 0); XCTAssertNil(dry.dewPointC)
        XCTAssertNotNil(dry.wetBulbC)
        let saturated = try Psychrometrics.state(dryBulbC: 25, relativeHumidity: 1, pressurePa: 101325)
        XCTAssertEqual(saturated.wetBulbC, 25); XCTAssertEqual(saturated.dewPointC, 25)
        for (t,rh,p) in [(25.0,50.0,101325.0), (25,-0.1,101325), (25,0.5,0), (25,0.5,14.7), (81,0.5,101325), (80,0.5,20000), (Double.nan,0.5,101325)] {
            XCTAssertThrowsError(try Psychrometrics.state(dryBulbC:t, relativeHumidity:rh, pressurePa:p))
        }
    }
    func testPressureChangesHumidityRatioButNotDewPoint() throws {
        let sea = try Psychrometrics.state(dryBulbC: 25, relativeHumidity: 0.5, pressurePa: 101325)
        let high = try Psychrometrics.state(dryBulbC: 25, relativeHumidity: 0.5, pressurePa: 85000)
        XCTAssertGreaterThan(high.humidityRatio, sea.humidityRatio)
        XCTAssertEqual(high.dewPointC, sea.dewPointC)
        XCTAssertLessThan(high.dryAirDensityKgPerM3, sea.dryAirDensityKgPerM3)
    }
    func testInvalidSavedConditionsFailValidationAndDoNotOverwrite() throws {
        var p = try LoadSightTests().readyProject()
        let original = p.root
        XCTAssertThrowsError(try p.saveAirCondition(name: "Room", author: "Test", source: "Missing condition", dryBulbC: 25, relativeHumidity: 0.5, pressurePa: 101325, pressureClassification: .rfiRequired))
        XCTAssertEqual(p.root, original)
        try p.saveAirCondition(name: "Room", author: "Test", source: "Fixture", dryBulbC: 25, relativeHumidity: 0.5, pressurePa: 101325)
        var rows = p.root["airConditions"].array!
        var row = rows[0].object!; row["method"] = .string("unsupported future method"); rows[0] = .object(row)
        try p.replace("airConditions", with: .array(rows))
        XCTAssertThrowsError(try p.validatePortableProject())
        XCTAssertThrowsError(try LoadSightDocument(project: p))
    }
    func testSavedConditionsPersistRecomputeAndReopenQA() throws {
        var p = try LoadSightTests().readyProject()
        let original = p.root
        XCTAssertThrowsError(try p.saveAirCondition(name: "Room", author: "", source: "Test fixture", dryBulbC: 25, relativeHumidity: 0.5, pressurePa: 101325))
        XCTAssertEqual(p.root, original)
        try p.saveAirCondition(name: "Room", author: "Test reviewer", source: "Fictional design condition", dryBulbC: 25, relativeHumidity: 0.5, pressurePa: 101325)
        let native = try LoadSightDocument(project: p)
        let reloaded = try LoadSightDocument(wrapper: native.wrapper(asPackage: true)).project
        let record = try XCTUnwrap(reloaded.airConditions().first)
        XCTAssertEqual(record.source, "Fictional design condition")
        XCTAssertEqual(record.pressureClassification, .userProvided)
        XCTAssertFalse(record.assumptionsLog.isEmpty)
        XCTAssertEqual(try record.calculate().relativeHumidity, 0.5)
        XCTAssertTrue(reloaded.root["qa"].array!.allSatisfy { $0["status"].string == "Open" })
        XCTAssertEqual(p.root["items"], original["items"])
    }
}
