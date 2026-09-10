import XCTest
import LoadSightKit
import LoadSightUI

final class OpeningTransmissionTests: XCTestCase {
    func scalar(_ value: Double) -> SourcedEngineeringValue { .init(value:value,source:"Synthetic whole-product fixture; not a rating recommendation",classification:.engineeringAssumption) }
    func save(window: SourcedEngineeringValue?, door: SourcedEngineeringValue?, adjacent: Double = 10) throws -> ProjectDocument {
        var (p,id) = try RoomTransmissionTests().seed()
        try p.saveRoomTransmission(name:"Rated room",author:"Fixture",source:"Synthetic design case",indoorDesignF:scalar(70),surfaces:[
            .init(name:"Outside",assemblyID:id,grossAreaSF:scalar(200),openings:[.init(name:"Window",areaSF:scalar(30),wholeProductU:window),.init(name:"Door",areaSF:scalar(20),wholeProductU:door)],adjacentDesignF:scalar(adjacent)),
            .init(name:"Partition",assemblyID:id,grossAreaSF:scalar(100),openings:[],adjacentDesignF:scalar(80))])
        return p
    }
    func result(_ p: ProjectDocument) throws -> RoomTransmissionResult { try XCTUnwrap(p.roomTransmissions().first).calculate(assemblies:p.envelopeAssemblies()) }
    func testRatedOpeningsCloseEnvelopeWithoutDoubleCounting() throws {
        let p = try save(window:scalar(0.3),door:scalar(0.5)), r = try result(p), o = try XCTUnwrap(r.openingTransmission)
        XCTAssertEqual(r.outwardLossBtuh,787.5,accuracy:1e-10)
        XCTAssertEqual(r.surfaces[0].netOpaqueAreaSF,150)
        XCTAssertEqual(o.knownOpeningLossBtuh,1140,accuracy:1e-10)
        XCTAssertEqual(try XCTUnwrap(o.combinedEnvelopeLossBtuh),1927.5,accuracy:1e-10)
        XCTAssertEqual(try XCTUnwrap(o.combinedEnvelopeGainBtuh),87.5,accuracy:1e-10)
        XCTAssertEqual(try XCTUnwrap(o.combinedEnvelopeNetOutwardBtuh),1840,accuracy:1e-10)
        XCTAssertTrue(o.allListedOpeningsRated)
        XCTAssertEqual(o.traces.count,5)
        XCTAssertEqual(r.excludedComponents.count,5)
        XCTAssertTrue(try XCTUnwrap(o.openings[0].trace).assumptions[0].contains("Synthetic whole-product"))
    }
    func testMissingRatingWithholdsCombinedSubtotalNotKnownTerms() throws {
        let r = try result(save(window:scalar(0.3),door:nil)), o = try XCTUnwrap(r.openingTransmission)
        XCTAssertFalse(o.allListedOpeningsRated)
        XCTAssertEqual(o.knownOpeningLossBtuh,540,accuracy:1e-10)
        XCTAssertNil(o.openings[1].wholeProductU); XCTAssertNil(o.openings[1].outwardBtuh)
        XCTAssertNil(o.combinedEnvelopeLossBtuh); XCTAssertNil(o.combinedEnvelopeGainBtuh); XCTAssertNil(o.combinedEnvelopeNetOutwardBtuh)
        XCTAssertEqual(o.traces.count,2)
        XCTAssertEqual(r.excludedComponents.count,6)
        let zeroDelta = try XCTUnwrap(result(save(window:scalar(0.3),door:nil,adjacent:70)).openingTransmission)
        XCTAssertFalse(zeroDelta.allListedOpeningsRated)
        XCTAssertNil(zeroDelta.combinedEnvelopeLossBtuh)
    }
    func testInwardOpeningHeatFlowAndNoOpeningCase() throws {
        let o = try XCTUnwrap(result(save(window:scalar(0.3),door:scalar(0.5),adjacent:80)).openingTransmission)
        XCTAssertEqual(o.knownOpeningLossBtuh,0)
        XCTAssertEqual(o.knownOpeningGainBtuh,190,accuracy:1e-10)
        XCTAssertEqual(try XCTUnwrap(o.combinedEnvelopeNetOutwardBtuh),-408.75,accuracy:1e-10)
        var (p,id) = try RoomTransmissionTests().seed()
        try p.saveRoomTransmission(name:"No openings",author:"Fixture",source:"Synthetic case",indoorDesignF:scalar(70),surfaces:[.init(name:"Wall",assemblyID:id,grossAreaSF:scalar(100),openings:[],adjacentDesignF:scalar(10))])
        let r = try result(p), empty = try XCTUnwrap(r.openingTransmission)
        XCTAssertTrue(empty.allListedOpeningsRated); XCTAssertTrue(empty.openings.isEmpty)
        XCTAssertEqual(empty.combinedEnvelopeLossBtuh,r.outwardLossBtuh)
    }
    func testInvalidOrUnresolvedRatingsFail() throws {
        for u in [0.0,-1,Double.nan,Double.infinity,Double.greatestFiniteMagnitude] { XCTAssertThrowsError(try save(window:scalar(u),door:scalar(0.5))) }
        XCTAssertThrowsError(try save(window:.init(value:0.3,source:"Missing rating",classification:.rfiRequired),door:nil))
        XCTAssertThrowsError(try save(window:.init(value:0.3,source:" ",classification:.userProvided),door:nil))
    }
    func testNativePersistenceLegacyMethodAndResultCompatibility() throws {
        let p = try save(window:scalar(0.3),door:scalar(0.5)), doc = try LoadSightDocument(project:p)
        let restored = try LoadSightDocument(wrapper:doc.wrapper(asPackage:true)).project
        XCTAssertEqual(restored.root["roomTransmissions"],p.root["roomTransmissions"])
        XCTAssertEqual(try XCTUnwrap(result(restored).openingTransmission?.combinedEnvelopeNetOutwardBtuh),1840,accuracy:1e-10)
        var legacy = p, rows = p.root["roomTransmissions"].array!, room = rows[0].object!
        room["method"] = .string(RoomTransmissionRecord.legacyMethod); rows[0] = .object(room)
        try legacy.replace("roomTransmissions",with:.array(rows))
        XCTAssertThrowsError(try legacy.validatePortableProject())
        var surfaces = room["surfaces"]!.array!
        for i in surfaces.indices {
            var surface = surfaces[i].object!, openings = surface["openings"]!.array!
            for j in openings.indices { var opening = openings[j].object!; opening.removeValue(forKey:"wholeProductU"); openings[j] = .object(opening) }
            surface["openings"] = .array(openings); surfaces[i] = .object(surface)
        }
        room["surfaces"] = .array(surfaces); rows[0] = .object(room); try legacy.replace("roomTransmissions",with:.array(rows))
        try legacy.validatePortableProject()
        XCTAssertNil(try result(legacy).openingTransmission?.combinedEnvelopeLossBtuh)
        var json = try JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(result(p))).object!
        json.removeValue(forKey:"openingTransmission")
        let oldResult = try JSONDecoder().decode(RoomTransmissionResult.self,from:JSONEncoder().encode(JSONValue.object(json)))
        XCTAssertNil(oldResult.openingTransmission)
    }
    func testStrictOpeningRatingRequest() throws {
        let rated = try save(window:scalar(0.3),door:scalar(0.5)), record = try XCTUnwrap(rated.roomTransmissions().first)
        var request: [String:JSONValue] = ["operation":.string("room.transmission.create"),"name":.string("Another case"),"author":.string("Fixture"),"source":.string("Synthetic"),"indoorDesignF":try JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(record.indoorDesignF)),"surfaces":try JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(record.surfaces))]
        XCTAssertNotNil(try ProjectEditing.apply(.object(request),to:rated).recordID)
        var surfaces = request["surfaces"]!.array!, surface = surfaces[0].object!, openings = surface["openings"]!.array!, opening = openings[0].object!
        opening["centerGlassU"] = .number(0.2); openings[0] = .object(opening); surface["openings"] = .array(openings); surfaces[0] = .object(surface); request["surfaces"] = .array(surfaces)
        XCTAssertThrowsError(try ProjectEditing.apply(.object(request),to:rated))
    }
}
