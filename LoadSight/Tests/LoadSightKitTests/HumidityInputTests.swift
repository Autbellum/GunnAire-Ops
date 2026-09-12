import XCTest
import LoadSightKit
import LoadSightUI

final class HumidityInputTests: XCTestCase {
    struct Fixture: Decodable { let rows: [Row] }
    struct Row: Decodable { let t,p,value,w,rh: Double; let kind: HumidityInputKind }
    func testPrimaryReferenceWetBulbAndDewPointInputs() throws {
        let url = Bundle.module.url(forResource:"HumidityInputs",withExtension:"json",subdirectory:"Fixtures")!
        let rows = try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:url)).rows
        XCTAssertEqual(rows.count,56)
        for r in rows {
            let state = try Psychrometrics.state(dryBulbC:r.t,humidity:.init(kind:r.kind,value:r.value),pressurePa:r.p)
            XCTAssertEqual(state.humidityRatio,r.w,accuracy:1e-10)
            XCTAssertEqual(state.relativeHumidity,r.rh,accuracy:1e-9)
            if r.kind == .wetBulbC { XCTAssertEqual(state.wetBulbC,r.value) }
            else { XCTAssertEqual(try XCTUnwrap(state.dewPointC),r.value,accuracy:1e-7) }
        }
    }
    func testImpossibleInputsAndSaturation() throws {
        for kind in [HumidityInputKind.wetBulbC,.dewPointC] {
            XCTAssertThrowsError(try Psychrometrics.state(dryBulbC:25,humidity:.init(kind:kind,value:26),pressurePa:101325))
            XCTAssertThrowsError(try Psychrometrics.state(dryBulbC:25,humidity:.init(kind:kind,value:-101),pressurePa:101325))
            XCTAssertThrowsError(try Psychrometrics.state(dryBulbC:25,humidity:.init(kind:kind,value:.nan),pressurePa:101325))
            let sat = try Psychrometrics.state(dryBulbC:25,humidity:.init(kind:kind,value:25),pressurePa:101325)
            XCTAssertEqual(sat.relativeHumidity,1,accuracy:1e-12)
        }
        XCTAssertThrowsError(try Psychrometrics.state(dryBulbC:40,humidity:.init(kind:.wetBulbC,value:-20),pressurePa:101325))
    }
    func testStructuredHumidityChoiceIsExclusiveAndTyped() throws {
        let project = try LoadSightTests().readyProject()
        var request: [String:JSONValue] = ["operation":.string("aircondition.create"),"author":.string("Fixture"),"name":.string("Source wet bulb"),"source":.string("Fictional design condition"),
            "dryBulbC":.number(35),"pressurePa":.number(101325),"humidityInput":.object(["kind":.string("wetBulbC"),"value":.number(24)]),
            "dryBulbClassification":.string("USER-PROVIDED"),"humidityClassification":.string("EXTRACTED"),"pressureClassification":.string("ENGINEERING-ASSUMPTION")]
        let result = try ProjectEditing.apply(.object(request),to:project)
        XCTAssertEqual(try result.project.airConditions()[0].humidityInput,.init(kind:.wetBulbC,value:24))
        let report = try result.project.airProcessReview()
        XCTAssertNotNil(report["conditions"].array?[0]["inputTrace"]["equation"].string)
        request["relativeHumidity"] = .number(0.5)
        XCTAssertThrowsError(try ProjectEditing.apply(.object(request),to:project))
        request.removeValue(forKey:"relativeHumidity")
        request["humidityInput"] = .object(["kind":.string("wetBulbC"),"value":.string("24")])
        XCTAssertThrowsError(try ProjectEditing.apply(.object(request),to:project))
        request["humidityInput"] = .object(["kind":.string("wetBulbC"),"value":.number(24),"unit":.string("F")])
        XCTAssertThrowsError(try ProjectEditing.apply(.object(request),to:project))
    }
    func testOriginalInputPersistsAndLegacyRHStillLoads() throws {
        var p = try LoadSightTests().readyProject()
        try p.saveAirCondition(name:"Summer outdoor",author:"Fixture",source:"Fictional coincident WB",dryBulbC:35,humidity:.init(kind:.wetBulbC,value:24),pressurePa:101325)
        let doc = try LoadSightDocument(project:p)
        let restored = try LoadSightDocument(wrapper:doc.wrapper(asPackage:true)).project
        let first = try XCTUnwrap(restored.airConditions().first)
        XCTAssertEqual(first.humidityInput,.init(kind:.wetBulbC,value:24))
        XCTAssertEqual(try first.calculate().wetBulbC,24)
        var rows=p.root["airConditions"].array!, row=rows[0].object!
        let rh=row["relativeHumidity"]!
        row.removeValue(forKey:"humidityInput"); rows[0] = .object(row)
        try p.replace("airConditions",with:.array(rows))
        XCTAssertNil(try p.airConditions()[0].humidityInput)
        XCTAssertEqual(try p.airConditions()[0].calculate().relativeHumidity,rh.number)
        row["humidityInput"] = .object(["kind":.string("wetBulbC"),"value":.number(20)])
        rows[0] = .object(row); try p.replace("airConditions",with:.array(rows))
        XCTAssertThrowsError(try p.validatePortableProject())
    }
}
