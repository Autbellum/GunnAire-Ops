import XCTest
import LoadSightKit
import LoadSightUI

final class AirNetworkTests: XCTestCase {
    func seed() throws -> (ProjectDocument,String,String,String) {
        var p = try LoadSightTests().readyProject()
        try p.saveAirCondition(name:"Outdoor",author:"Fixture",source:"Fictional design",dryBulbC:35,relativeHumidity:0.5,pressurePa:101325)
        try p.saveAirCondition(name:"Return",author:"Fixture",source:"Fictional room",dryBulbC:25,relativeHumidity:0.5,pressurePa:101325)
        let cs = try p.airConditions()
        try p.saveAirProcess(name:"Mix",author:"Fixture",source:"Fixture actual flows",kind:.mixing,firstConditionID:cs[0].id,secondConditionID:cs[1].id,firstActualCFM:300,secondActualCFM:900,flowClassification:.engineeringAssumption)
        return (p,cs[0].id,cs[1].id,try p.airProcesses()[0].id)
    }
    func testStructuredDerivationReturnsIdentityAndRejectsOverrides() throws {
        let (p,_,_,mix) = try seed()
        var request: [String:JSONValue] = ["operation":.string("aircondition.derive"),"processID":.string(mix),"name":.string("Derived"),"author":.string("Fixture"),"source":.string("Downstream coil basis")]
        let result = try ProjectEditing.apply(.object(request),to:p)
        let id = try XCTUnwrap(result.recordID)
        XCTAssertEqual(try result.project.airConditions().first(where:{$0.id==id})?.derivation?.processID,mix)
        request["relativeHumidity"] = .number(0.5)
        XCTAssertThrowsError(try ProjectEditing.apply(.object(request),to:p))
        XCTAssertEqual(try p.airConditions().count,2)
    }
    func testDerivedMixFeedsCoilAndRoundTrips() throws {
        var (p,_,_,mix) = try seed()
        let output = try p.saveMixedAirOutput(processID:mix,name:"Coil entering",author:"Fixture",source:"Mixing result used at coil inlet")
        try p.saveAirCondition(name:"Coil leaving",author:"Fixture",source:"Fictional leaving state",dryBulbC:13,relativeHumidity:0.9,pressurePa:101325)
        let cs = try p.airConditions(), leaving = try XCTUnwrap(cs.last)
        let derived = try XCTUnwrap(cs.first(where:{$0.id==output}))
        let d = try XCTUnwrap(derived.derivation)
        XCTAssertEqual(d.processID,mix); XCTAssertEqual(d.sourceFingerprint.count,64)
        try p.saveAirProcess(name:"Coil",author:"Fixture",source:"Full modeled mixed-stream airflow",kind:.coolingCoil,firstConditionID:output,secondConditionID:leaving.id,firstActualCFM:d.actualCFM,secondActualCFM:nil,flowClassification:.engineeringAssumption)
        let doc = try LoadSightDocument(project:p)
        let restored = try LoadSightDocument(wrapper:doc.wrapper(asPackage:true)).project
        let result = try restored.airProcessReview()
        let processes = try XCTUnwrap(result["processes"].array)
        XCTAssertEqual(processes.count,2)
        XCTAssertGreaterThan(try XCTUnwrap(processes[1]["result"]["totalKW"].number),0)
        XCTAssertEqual(try XCTUnwrap(processes[0]["result"]["dryAirMassKgPerSecond"].number),try XCTUnwrap(processes[1]["result"]["dryAirMassKgPerSecond"].number),accuracy:1e-10)
        XCTAssertEqual(try restored.airConditions().first(where:{$0.id==output})?.derivation?.sourceFingerprint,d.sourceFingerprint)
    }
    func testUpstreamEvidenceChangeInvalidatesDerivedCondition() throws {
        var (p,_,_,mix) = try seed()
        _ = try p.saveMixedAirOutput(processID:mix,name:"Derived",author:"Fixture",source:"Model")
        var rows = p.root["airConditions"].array!, source = rows[0].object!
        source["source"] = .string("Changed upstream evidence, same numeric state")
        rows[0] = .object(source); try p.replace("airConditions",with:.array(rows))
        XCTAssertThrowsError(try p.validatePortableProject())
        XCTAssertThrowsError(try LoadSightDocument(project:p))
    }
    func testCyclesAndChangedDerivedValuesAreRejected() throws {
        var (p,_,_,mix) = try seed()
        let id = try p.saveMixedAirOutput(processID:mix,name:"Derived",author:"Fixture",source:"Model")
        var cyclic=p, processes=p.root["airProcesses"].array!, process=processes[0].object!
        process["firstConditionID"] = .string(id); processes[0] = .object(process)
        try cyclic.replace("airProcesses",with:.array(processes))
        XCTAssertThrowsError(try cyclic.airProcesses()) { XCTAssertTrue($0.localizedDescription.contains("cycle")) }
        var rows=p.root["airConditions"].array!, derived=rows.last!.object!
        derived["dryBulbC"] = .number(derived["dryBulbC"]!.number!+1)
        rows[rows.count-1] = .object(derived); try p.replace("airConditions",with:.array(rows))
        XCTAssertThrowsError(try p.airConditions())
    }
    func testMissingSourceAndInvalidSaveAreAtomic() throws {
        var (p,_,_,mix) = try seed()
        let before=p.root
        XCTAssertThrowsError(try p.saveMixedAirOutput(processID:"missing",name:"Derived",author:"Fixture",source:"Model"))
        XCTAssertThrowsError(try p.saveMixedAirOutput(processID:mix,name:"Derived",author:"",source:"Model"))
        XCTAssertEqual(p.root,before)
        _ = try p.saveMixedAirOutput(processID:mix,name:"Derived",author:"Fixture",source:"Model")
        try p.replace("airProcesses",with:.array([]))
        XCTAssertThrowsError(try p.validatePortableProject())
    }
    func testChainedMixesAndUnknownProvenanceSurviveAppend() throws {
        var (p,_,returnID,mix) = try seed()
        var raw=p.root["airConditions"].array!, original=raw[0].object!
        original["externalEvidence"] = .object(["reference":.string("Retain this metadata")]); raw[0] = .object(original)
        try p.replace("airConditions",with:.array(raw))
        var parent=mix
        for i in 0..<8 {
            let id = try p.saveMixedAirOutput(processID:parent,name:"Stage \(i)",author:"Fixture",source:"Chained fixture")
            try p.saveAirProcess(name:"Mix stage \(i)",author:"Fixture",source:"Fixture flows",kind:.mixing,firstConditionID:id,secondConditionID:returnID,firstActualCFM:300,secondActualCFM:900,flowClassification:.engineeringAssumption)
            parent = try XCTUnwrap(p.airProcesses().last?.id)
        }
        try p.saveAirCondition(name:"Additional",author:"Fixture",source:"Fixture",dryBulbC:20,relativeHumidity:0.5,pressurePa:101325)
        XCTAssertEqual(p.root["airConditions"].array![0]["externalEvidence"],original["externalEvidence"])
        XCTAssertEqual(try p.airProcesses().count,9)
        try p.validatePortableProject()
    }
}
