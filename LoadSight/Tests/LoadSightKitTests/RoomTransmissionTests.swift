import XCTest
import LoadSightKit
import LoadSightUI

final class RoomTransmissionTests: XCTestCase {
    func scalar(_ x: Double) -> SourcedEngineeringValue { .init(value:x,source:"Synthetic test input",classification:.engineeringAssumption) }
    func seed() throws -> (ProjectDocument,String) {
        let p = try ProjectEditing.apply(EnvelopeAssemblyTests().request(),to:LoadSightTests().readyProject()).project
        return (p,try XCTUnwrap(p.envelopeAssemblies().first?.id))
    }
    func surfaces(_ id: String) -> [RoomEnvelopeSurface] {
        [.init(name:"Outside wall",assemblyID:id,grossAreaSF:scalar(200),openings:[.init(name:"Window",areaSF:scalar(30)),.init(name:"Door",areaSF:scalar(20))],adjacentDesignF:scalar(10)),
         .init(name:"Warmer partition",assemblyID:id,grossAreaSF:scalar(100),openings:[],adjacentDesignF:scalar(80))]
    }
    func save(_ p: inout ProjectDocument, _ id: String) throws {
        try p.saveRoomTransmission(name:"Test room",author:"Fixture",source:"Synthetic design case",indoorDesignF:scalar(70),surfaces:surfaces(id))
    }
    func testAreaDeductionAndSignedLossGainBalance() throws {
        var (p,id) = try seed(); try save(&p,id)
        let result = try XCTUnwrap(p.roomTransmissions().first).calculate(assemblies:p.envelopeAssemblies())
        XCTAssertEqual(result.surfaces[0].netOpaqueAreaSF,150)
        XCTAssertEqual(result.outwardLossBtuh,787.5,accuracy:1e-10)
        XCTAssertEqual(result.inwardGainBtuh,87.5,accuracy:1e-10)
        XCTAssertEqual(result.netOutwardBtuh,700,accuracy:1e-10)
        XCTAssertEqual(result.surfaces[1].outwardBtuh,-87.5,accuracy:1e-10)
        XCTAssertEqual(result.traces.count,3)
        XCTAssertEqual(result.excludedComponents.count,6)
        XCTAssertTrue(result.surfaces[1].traces[0].substitution.contains("(0)"))
    }
    func testRoundTripAndAssemblySourcesInReview() throws {
        var (p,id) = try seed(); try save(&p,id)
        var rows = p.root["roomTransmissions"].array!, record = rows[0].object!
        record["futureRoomSource"] = .string("Original source extension"); rows[0] = .object(record)
        try p.replace("roomTransmissions",with:.array(rows))
        try save(&p,id)
        XCTAssertEqual(p.root["roomTransmissions"].array![0],rows[0])
        let doc = try LoadSightDocument(project:p), restored = try LoadSightDocument(wrapper:doc.wrapper(asPackage:true)).project
        XCTAssertEqual(restored.root["roomTransmissions"],p.root["roomTransmissions"])
        let review = try restored.roomTransmissionReview()
        XCTAssertEqual(review["rooms"].array?.count,2)
        XCTAssertEqual(review["assemblies"].array?.count,1)
        XCTAssertEqual(review["assemblies"].array?.first?["record"]["source"].string,"Synthetic example, not material data")
    }
    func testAssemblyChangesRecomputeAndInvalidateQA() throws {
        var (p,id) = try seed(); try save(&p,id)
        try p.recordQACheck(id:"QA-01",reviewer:"Fixture",evidence:"Synthetic check",complete:true)
        XCTAssertTrue(try p.isQACurrent(p.root["qa"].array![0]))
        var assemblies = p.root["envelopeAssemblies"].array!, a = assemblies[0].object!, paths = a["paths"]!.array!
        for i in paths.indices {
            var path = paths[i].object!, layers = path["layers"]!.array!
            for j in layers.indices { var layer = layers[j].object!; layer["resistance"] = .number(layer["resistance"]!.number! * 2); layers[j] = .object(layer) }
            path["layers"] = .array(layers); paths[i] = .object(path)
        }
        a["paths"] = .array(paths); assemblies[0] = .object(a); try p.replace("envelopeAssemblies",with:.array(assemblies))
        XCTAssertFalse(try p.isQACurrent(p.root["qa"].array![0]))
        XCTAssertEqual(try XCTUnwrap(p.roomTransmissions().first).calculate(assemblies:p.envelopeAssemblies()).netOutwardBtuh,350,accuracy:1e-10)
    }
    func testInvalidGeometryMissingReferencesAndSourcesAreAtomic() throws {
        var (p,id) = try seed()
        let before = p.root
        let unresolved = SourcedEngineeringValue(value:100,source:"Missing survey",classification:.rfiRequired)
        let blank = SourcedEngineeringValue(value:100,source:" ",classification:.userProvided)
        for gross in [scalar(0),scalar(-1),scalar(.infinity),unresolved,blank] {
            XCTAssertThrowsError(try p.saveRoomTransmission(name:"Room",author:"Fixture",source:"Fixture",indoorDesignF:scalar(70),surfaces:[.init(name:"Wall",assemblyID:id,grossAreaSF:gross,openings:[],adjacentDesignF:scalar(10))]))
            XCTAssertEqual(p.root,before)
        }
        for opening in [0.0,-1,200,250,Double.infinity] {
            XCTAssertThrowsError(try p.saveRoomTransmission(name:"Room",author:"Fixture",source:"Fixture",indoorDesignF:scalar(70),surfaces:[.init(name:"Wall",assemblyID:id,grossAreaSF:scalar(200),openings:[.init(name:"Opening",areaSF:scalar(opening))],adjacentDesignF:scalar(10))]))
        }
        for temperature in [-459.67,Double.infinity,Double.nan] {
            XCTAssertThrowsError(try p.saveRoomTransmission(name:"Room",author:"Fixture",source:"Fixture",indoorDesignF:scalar(temperature),surfaces:surfaces(id)))
        }
        XCTAssertThrowsError(try p.saveRoomTransmission(name:"Room",author:"Fixture",source:"Fixture",indoorDesignF:scalar(70),surfaces:surfaces("missing")))
        XCTAssertThrowsError(try p.saveRoomTransmission(name:"Room",author:"Fixture",source:"Fixture",indoorDesignF:scalar(70),surfaces:surfaces(id)+surfaces(id)))
        XCTAssertEqual(p.root,before)
    }
    func testImportedDanglingReferenceAndDuplicateRoomFailValidation() throws {
        var (p,id) = try seed(); try save(&p,id)
        let saved = p
        try p.replace("envelopeAssemblies",with:.array([]))
        XCTAssertThrowsError(try p.validatePortableProject())
        XCTAssertThrowsError(try LoadSightDocument(project:p))
        p = saved
        let first = p.root["roomTransmissions"].array![0]
        try p.replace("roomTransmissions",with:.array([first,first]))
        XCTAssertThrowsError(try p.validatePortableProject())
    }
    func testStrictCommandAndQAReopening() throws {
        let (p,id) = try seed()
        func json<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(value)) }
        var request: [String:JSONValue] = ["operation":.string("room.transmission.create"),"author":.string("Fixture"),"name":.string("Room"),"source":.string("Synthetic case"),"indoorDesignF":try json(scalar(70)),"surfaces":try json(surfaces(id))]
        let result = try ProjectEditing.apply(.object(request),to:p)
        XCTAssertNotNil(result.recordID)
        XCTAssertTrue(result.project.root["qa"].array!.allSatisfy { $0["status"].string == "Open" })
        var scalar = request["indoorDesignF"]!.object!; scalar["units"] = .string("C"); request["indoorDesignF"] = .object(scalar)
        XCTAssertThrowsError(try ProjectEditing.apply(.object(request),to:p))
    }
}
