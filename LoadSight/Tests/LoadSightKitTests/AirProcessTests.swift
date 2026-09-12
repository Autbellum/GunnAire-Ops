import XCTest
import LoadSightKit
import LoadSightUI

final class AirProcessTests: XCTestCase {
    func air(_ t: Double, _ w: Double) throws -> MoistAirState { try AirProcesses.state(dryBulbC: t, humidityRatio: w, pressurePa: 101325) }
    func testMixConservesDryAirWaterAndEnthalpy() throws {
        let a = try air(20, 0.008), b = try air(35, 0.014)
        let m1 = 1.0, m2 = 3.0
        let r = try AirProcesses.mix(first:a, firstActualCFM:m1*a.volumeM3PerKgDryAir/AirProcesses.cfmToM3PerSecond,
                                     second:b, secondActualCFM:m2*b.volumeM3PerKgDryAir/AirProcesses.cfmToM3PerSecond)
        XCTAssertEqual(r.dryAirMassKgPerSecond,4,accuracy:1e-10)
        XCTAssertEqual(r.state.humidityRatio,0.0125,accuracy:1e-10)
        XCTAssertEqual(r.state.enthalpyKJPerKgDryAir,63.45795,accuracy:1e-8)
        XCTAssertEqual(r.state.dryBulbC,32.19545/1.02925,accuracy:1e-8)
        XCTAssertEqual(r.outletActualCFM*AirProcesses.cfmToM3PerSecond/r.state.volumeM3PerKgDryAir,4,accuracy:1e-10)
    }
    func testCoolingBalancesAndDryCoil() throws {
        let a = try air(30,0.014), b = try air(15,0.009)
        let flow = a.volumeM3PerKgDryAir/AirProcesses.cfmToM3PerSecond
        let r = try AirProcesses.coolingCoil(inlet:a,outlet:b,inletActualCFM:flow)
        XCTAssertEqual(r.totalKW,28.1251,accuracy:1e-8)
        XCTAssertEqual(r.sensibleKW,15.3411,accuracy:1e-8)
        XCTAssertEqual(r.latentKW,12.784,accuracy:1e-8)
        XCTAssertEqual(r.condensateKgPerHour,18,accuracy:1e-8)
        XCTAssertEqual(r.totalKW,r.sensibleKW+r.latentKW,accuracy:1e-10)
        let dry = try AirProcesses.coolingCoil(inlet:air(30,0.008),outlet:air(20,0.008),inletActualCFM:1200)
        XCTAssertEqual(dry.latentKW,0,accuracy:1e-10)
        XCTAssertEqual(try XCTUnwrap(dry.sensibleHeatRatio),1,accuracy:1e-10)
        let noChange = try AirProcesses.coolingCoil(inlet:a,outlet:a,inletActualCFM:1200)
        XCTAssertEqual(noChange.totalKW,0); XCTAssertNil(noChange.sensibleHeatRatio)
    }
    func testRejectsInconsistentPressureFlowAndFog() throws {
        let a = try air(30,0.014), b = try air(15,0.009)
        let high = try Psychrometrics.state(dryBulbC:20,relativeHumidity:0.5,pressurePa:85000)
        XCTAssertThrowsError(try AirProcesses.mix(first:a,firstActualCFM:100,second:high,secondActualCFM:100))
        XCTAssertThrowsError(try AirProcesses.mix(first:a,firstActualCFM:0,second:b,secondActualCFM:0))
        XCTAssertThrowsError(try AirProcesses.coolingCoil(inlet:b,outlet:a,inletActualCFM:1200))
        XCTAssertThrowsError(try AirProcesses.coolingCoil(inlet:a,outlet:b,inletActualCFM:Double.infinity))
        let cold = try Psychrometrics.state(dryBulbC:0,relativeHumidity:1,pressurePa:101325)
        let warm = try Psychrometrics.state(dryBulbC:40,relativeHumidity:1,pressurePa:101325)
        XCTAssertThrowsError(try AirProcesses.mix(first:cold,firstActualCFM:500,second:warm,secondActualCFM:500))
        let one = try AirProcesses.mix(first:a,firstActualCFM:500,second:b,secondActualCFM:0)
        XCTAssertEqual(one.state.dryBulbC,a.dryBulbC,accuracy:1e-8)
    }
    func testDecodedDerivedValuesAreNotTrusted() throws {
        let a = try air(30,0.014), b = try air(15,0.009)
        var fields = try XCTUnwrap(JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(a)).object)
        fields["enthalpyKJPerKgDryAir"] = .number(-9000)
        fields["volumeM3PerKgDryAir"] = .number(0)
        let altered = try JSONDecoder().decode(MoistAirState.self,from:JSONEncoder().encode(JSONValue.object(fields)))
        let expected = try AirProcesses.coolingCoil(inlet:a,outlet:b,inletActualCFM:1000)
        let actual = try AirProcesses.coolingCoil(inlet:altered,outlet:b,inletActualCFM:1000)
        XCTAssertEqual(actual.totalKW,expected.totalKW)
    }
    func testStructuredConditionsAndProcessesUseStrictTypes() throws {
        let p = try LoadSightTests().readyProject()
        let base: JSONValue = .object(["operation": .string("aircondition.create"), "author": .string("Test"), "name": .string("Fixture"), "source": .string("Fictional condition"),
            "dryBulbC": .number(25), "relativeHumidity": .number(0.5), "pressurePa": .number(101325), "dryBulbClassification": .string("USER-PROVIDED"),
            "humidityClassification": .string("USER-PROVIDED"), "pressureClassification": .string("ENGINEERING-ASSUMPTION")])
        let saved = try ProjectEditing.apply(base,to:p)
        let id = try XCTUnwrap(saved.recordID)
        var bad = base.object!; bad["pressurePa"] = .string("101325")
        XCTAssertThrowsError(try ProjectEditing.apply(.object(bad),to:p))
        var request: [String:JSONValue] = ["operation": .string("airprocess.create"), "author": .string("Test"), "name": .string("Fixture process"), "source": .string("Fictional airflow"),
            "kind": .string("Mixed air"), "firstConditionID": .string(id), "secondConditionID": .string(id), "firstActualCFM": .number(100), "secondActualCFM": .number(200), "flowClassification": .string("USER-PROVIDED")]
        let process = try ProjectEditing.apply(.object(request),to:saved.project)
        XCTAssertNotNil(process.recordID)
        XCTAssertEqual(try process.project.airProcesses().count,1)
        request["secondActualCFM"] = .bool(true)
        XCTAssertThrowsError(try ProjectEditing.apply(.object(request),to:saved.project))
    }
    func testProcessPersistenceAndMissingReferenceRejection() throws {
        var p = try LoadSightTests().readyProject()
        try p.saveAirCondition(name:"In",author:"Test",source:"Fictional fixture",dryBulbC:30,relativeHumidity:0.5,pressurePa:101325)
        try p.saveAirCondition(name:"Out",author:"Test",source:"Fictional fixture",dryBulbC:15,relativeHumidity:0.8,pressurePa:101325)
        let conditions = try p.airConditions(), before = p.root
        XCTAssertThrowsError(try p.saveAirProcess(name:"Coil",author:"Test",source:"Fixture",kind:.coolingCoil,firstConditionID:"missing",secondConditionID:conditions[1].id,firstActualCFM:1200,secondActualCFM:nil,flowClassification:.userProvided))
        XCTAssertEqual(p.root,before)
        try p.saveAirProcess(name:"Coil",author:"Test",source:"Actual inlet CFM fixture",kind:.coolingCoil,firstConditionID:conditions[0].id,secondConditionID:conditions[1].id,firstActualCFM:1200,secondActualCFM:nil,flowClassification:.engineeringAssumption)
        let native = try LoadSightDocument(project:p)
        let reloaded = try LoadSightDocument(wrapper:native.wrapper(asPackage:true)).project
        XCTAssertEqual(try reloaded.airProcesses().count,1)
        XCTAssertEqual(try reloaded.airProcesses()[0].source,"Actual inlet CFM fixture")
        XCTAssertEqual(reloaded.root["items"],before["items"])
        XCTAssertTrue(reloaded.root["qa"].array!.allSatisfy { $0["status"].string == "Open" })
        try p.replace("airConditions",with:.array([]))
        XCTAssertThrowsError(try p.validatePortableProject())
    }
}
