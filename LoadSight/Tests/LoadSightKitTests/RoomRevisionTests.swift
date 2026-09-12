import XCTest
import LoadSightKit
import LoadSightUI

final class RoomRevisionTests: XCTestCase {
    func seed() throws -> (ProjectDocument,String) {
        let f = OpeningTransmissionTests()
        let p = try f.save(window:f.scalar(0.3),door:f.scalar(0.5))
        return (p,try XCTUnwrap(p.roomTransmissions().first?.id))
    }
    @discardableResult
    func revise(_ p: inout ProjectDocument, _ id: String, temperature: Double = 75, fingerprint: String? = nil, reason: String = "Corrected design setpoint") throws -> String {
        let room = try XCTUnwrap(p.roomTransmissions().first(where:{$0.id == id}))
        return try p.reviseRoomTransmission(id:id,expectedFingerprint:fingerprint ?? p.roomTransmissionEditFingerprint(id:id),reason:reason,name:room.name,author:"Revision author",source:room.source,indoorDesignF:.init(value:temperature,source:"Synthetic correction",classification:.userProvided),surfaces:room.surfaces)
    }
    func testStableIdentityHistoryAndQAReopening() throws {
        var (p,id) = try seed()
        let original = p.root["roomTransmissions"].array![0]
        try p.recordQACheck(id:"QA-01",reviewer:"Fixture",evidence:"Synthetic check",complete:true)
        XCTAssertEqual(try revise(&p,id),id)
        XCTAssertEqual(try p.roomTransmissions().count,1)
        let history = try p.roomTransmissionHistory()
        XCTAssertEqual(history.count,1); XCTAssertEqual(history[0].before,original)
        XCTAssertEqual(history[0].after,p.root["roomTransmissions"].array![0])
        XCTAssertEqual(history[0].assemblyBasis.count,1)
        XCTAssertTrue(p.root["qa"].array!.allSatisfy { $0["status"].string == "Open" })
        XCTAssertEqual(try XCTUnwrap(history[0].result(before:true).openingTransmission?.combinedEnvelopeNetOutwardBtuh),1840,accuracy:1e-10)
        XCTAssertEqual(try XCTUnwrap(history[0].result(before:false).openingTransmission?.combinedEnvelopeNetOutwardBtuh),2044.375,accuracy:1e-10)
    }
    func testStaleTokenAndInvalidRevisionAreAtomic() throws {
        var (p,id) = try seed()
        let token = try p.roomTransmissionEditFingerprint(id:id)
        try revise(&p,id)
        let before = p.root
        XCTAssertThrowsError(try revise(&p,id,fingerprint:token))
        XCTAssertThrowsError(try revise(&p,id,reason:" "))
        XCTAssertThrowsError(try revise(&p,id,temperature:.nan))
        XCTAssertEqual(p.root,before)
        let current = try p.roomTransmissionEditFingerprint(id:id)
        try revise(&p,id,temperature:75,fingerprint:current,reason:"Reviewed same setpoint")
        XCTAssertNotEqual(try p.roomTransmissionEditFingerprint(id:id),current)
    }
    func testAssemblyCatalogChangesInvalidateEditTokenButQAChangesDoNot() throws {
        var (p,id) = try seed()
        let token = try p.roomTransmissionEditFingerprint(id:id)
        try p.recordQACheck(id:"QA-01",reviewer:"Fixture",evidence:"Synthetic check",complete:true)
        XCTAssertEqual(try p.roomTransmissionEditFingerprint(id:id),token)
        var rows = p.root["envelopeAssemblies"].array!, assembly = rows[0].object!
        assembly["source"] = .string("Corrected assembly source"); rows[0] = .object(assembly)
        try p.replace("envelopeAssemblies",with:.array(rows))
        let before = p.root
        XCTAssertThrowsError(try revise(&p,id,fingerprint:token))
        XCTAssertEqual(p.root,before)
    }
    func testHistoricalAssemblyBasisSurvivesLiveAssemblyChanges() throws {
        var (p,id) = try seed(); try revise(&p,id)
        let historical = try p.roomTransmissionHistory()[0].result(before:false)
        var rows = p.root["envelopeAssemblies"].array!, assembly = rows[0].object!, paths = assembly["paths"]!.array!
        for i in paths.indices {
            var path = paths[i].object!, layers = path["layers"]!.array!
            for j in layers.indices { var layer = layers[j].object!; layer["resistance"] = .number(layer["resistance"]!.number! * 2); layers[j] = .object(layer) }
            path["layers"] = .array(layers); paths[i] = .object(path)
        }
        assembly["paths"] = .array(paths); rows[0] = .object(assembly); try p.replace("envelopeAssemblies",with:.array(rows))
        XCTAssertEqual(try p.roomTransmissionHistory()[0].result(before:false).netOutwardBtuh,historical.netOutwardBtuh)
        XCTAssertNotEqual(try p.roomTransmissions()[0].calculate(assemblies:p.envelopeAssemblies()).netOutwardBtuh,historical.netOutwardBtuh)
    }
    func testHistoryChainRejectsChangedCurrentInputsAndBrokenLinks() throws {
        var (p,id) = try seed(); try revise(&p,id); try revise(&p,id,temperature:76)
        let valid = p
        var rooms = p.root["roomTransmissions"].array!, room = rooms[0].object!
        room["name"] = .string("Unrecorded edit"); rooms[0] = .object(room); try p.replace("roomTransmissions",with:.array(rooms))
        XCTAssertThrowsError(try p.validatePortableProject())
        p = valid
        var history = p.root["roomTransmissionHistory"].array!, revision = history[1].object!, before = revision["before"]!.object!
        before["name"] = .string("Broken predecessor"); revision["before"] = .object(before); history[1] = .object(revision)
        try p.replace("roomTransmissionHistory",with:.array(history))
        XCTAssertThrowsError(try LoadSightDocument(project:p))
    }
    func testUnknownInputRetentionAndNativeRoundTrip() throws {
        var (p,id) = try seed()
        var rows = p.root["roomTransmissions"].array!, room = rows[0].object!
        room["futureSurvey"] = .string("Retain original extension"); rows[0] = .object(room); try p.replace("roomTransmissions",with:.array(rows))
        let before = rows[0]
        try revise(&p,id)
        XCTAssertEqual(p.root["roomTransmissions"].array![0]["futureSurvey"],before["futureSurvey"])
        XCTAssertEqual(try p.roomTransmissionHistory()[0].before,before)
        let doc = try LoadSightDocument(project:p), restored = try LoadSightDocument(wrapper:doc.wrapper(asPackage:true)).project
        XCTAssertEqual(restored.root["roomTransmissionHistory"],p.root["roomTransmissionHistory"])
        let history = try XCTUnwrap(restored.roomTransmissionReview()["history"].array)
        XCTAssertEqual(history.count,1)
        XCTAssertEqual(try XCTUnwrap(history[0]["beforeResult"]["openingTransmission"]["combinedEnvelopeNetOutwardBtuh"].number),1840,accuracy:1e-10)
        XCTAssertEqual(try XCTUnwrap(history[0]["afterResult"]["openingTransmission"]["combinedEnvelopeNetOutwardBtuh"].number),2044.375,accuracy:1e-10)
    }
    func testStructuredRevisionReturnsSameIdentityAndRequiresToken() throws {
        let (p,id) = try seed(), room = try p.roomTransmissions()[0]
        var request: [String:JSONValue] = ["operation":.string("room.transmission.revise"),"id":.string(id),"expectedFingerprint":.string(try p.roomTransmissionEditFingerprint(id:id)),"reason":.string("Synthetic correction"),"author":.string("Fixture"),"name":.string(room.name),"source":.string(room.source),"indoorDesignF":try JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(room.indoorDesignF)),"surfaces":try JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(room.surfaces))]
        let revised = try ProjectEditing.apply(.object(request),to:p)
        XCTAssertEqual(revised.recordID,id); XCTAssertEqual(try revised.project.roomTransmissions().count,1)
        request.removeValue(forKey:"expectedFingerprint")
        XCTAssertThrowsError(try ProjectEditing.apply(.object(request),to:p))
    }
}
