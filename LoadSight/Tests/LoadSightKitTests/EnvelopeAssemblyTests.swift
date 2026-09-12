import XCTest
import LoadSightKit
import LoadSightUI

final class EnvelopeAssemblyTests: XCTestCase {
    func paths() -> [EnvelopePath] {
        [("Cavity", 0.75, 19.0), ("Framing", 0.25, 4.0)].map { name, fraction, r in
            .init(name: name, fraction: fraction, fractionSource: "Synthetic analytical fixture", fractionClassification: .engineeringAssumption,
                layers: [.init(name: "Common", resistance: 1, source: "Fixture only", classification: .engineeringAssumption),
                         .init(name: "Core", resistance: r, source: "Fixture only", classification: .engineeringAssumption)])
        }
    }
    func request() throws -> JSONValue {
        .object(["operation": .string("assembly.create"), "name": .string("Analytical wall"), "author": .string("Fixture"),
            "source": .string("Synthetic example, not material data"), "construction": .string("Wood framed"),
            "filmBasis": .string("Common layer includes fictional boundary resistance"),
            "paths": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(paths()))])
    }
    func testParallelConductanceNotAverageResistance() throws {
        let result = try EnvelopeAssemblies.calculate(paths: [.init(name:"Cavity",fraction:0.75,resistances:[1,19]), .init(name:"Framing",fraction:0.25,resistances:[1,4])])
        XCTAssertEqual(result.uFactor, 0.0875, accuracy:1e-12)
        XCTAssertEqual(result.effectiveR, 80.0/7, accuracy:1e-12)
        XCTAssertNotEqual(result.effectiveR, 0.75*20+0.25*5)
        XCTAssertEqual(result.traces.count,6)
        let single = try EnvelopeAssemblies.calculate(paths:[.init(name:"Uniform",fraction:1,resistances:[1,4])])
        XCTAssertEqual(single.uFactor,0.2,accuracy:1e-12)
        let reversed = try EnvelopeAssemblies.calculate(paths:[.init(name:"Framing",fraction:0.25,resistances:[4,1]),.init(name:"Cavity",fraction:0.75,resistances:[19,1])])
        XCTAssertEqual(result.uFactor,reversed.uFactor)
    }
    func testRejectsBadCoverageAndNonPhysicalResistance() throws {
        for fraction in [0.0, -1, 0.75, 1.1, Double.nan, Double.infinity] {
            XCTAssertThrowsError(try EnvelopeAssemblies.calculate(paths:[.init(name:"Only",fraction:fraction,resistances:[5])]))
        }
        for rs in [[], [0], [-1], [Double.nan], [Double.infinity], [Double.greatestFiniteMagnitude,Double.greatestFiniteMagnitude], [Double.leastNonzeroMagnitude]] {
            XCTAssertThrowsError(try EnvelopeAssemblies.calculate(paths:[.init(name:"Only",fraction:1,resistances:rs)]))
        }
        XCTAssertThrowsError(try EnvelopeAssemblies.calculate(paths:[.init(name:" same ",fraction:0.5,resistances:[1]),.init(name:"Same",fraction:0.5,resistances:[2])]))
    }
    func testPersistenceReopensQAAndPreservesUnknownProvenance() throws {
        let seed = try LoadSightTests().readyProject()
        var p = try ProjectEditing.apply(request(),to:seed).project
        XCTAssertTrue(p.root["qa"].array!.allSatisfy { $0["status"].string == "Open" })
        var raw = p.root["envelopeAssemblies"].array!, row = raw[0].object!
        row["futureSource"] = .object(["pageID":.string("Evidence retained")]); raw[0] = .object(row)
        try p.replace("envelopeAssemblies",with:.array(raw))
        p = try ProjectEditing.apply(request(),to:p).project
        XCTAssertEqual(p.root["envelopeAssemblies"].array![0],raw[0])
        let doc = try LoadSightDocument(project:p)
        let restored = try LoadSightDocument(wrapper:doc.wrapper(asPackage:true)).project
        XCTAssertEqual(restored.root["envelopeAssemblies"],p.root["envelopeAssemblies"])
        XCTAssertEqual(try restored.envelopeAssemblies().count,2)
        XCTAssertEqual(try XCTUnwrap(restored.envelopeReview()["assemblies"].array?.first?["result"]["uFactor"].number),0.0875,accuracy:1e-12)
    }
    func testStrictStructuredRequestAndMissingSources() throws {
        let p = try LoadSightTests().readyProject()
        var r = try request().object!
        r["construction"] = .string("Steel framed")
        XCTAssertThrowsError(try ProjectEditing.apply(.object(r),to:p))
        r = try request().object!; r["construction"] = .string("Homogeneous layers")
        XCTAssertThrowsError(try ProjectEditing.apply(.object(r),to:p))
        for field in ["source","author","filmBasis"] {
            r = try request().object!; r[field] = .string(" ")
            XCTAssertThrowsError(try ProjectEditing.apply(.object(r),to:p))
        }
        for mutation in ["unknown", "classification", "source"] {
            r = try request().object!
            var paths = r["paths"]!.array!, path = paths[0].object!, layers = path["layers"]!.array!, layer = layers[0].object!
            layer[mutation] = .string(mutation == "classification" ? "RFI-REQUIRED" : "")
            layers[0] = .object(layer); path["layers"] = .array(layers); paths[0] = .object(path); r["paths"] = .array(paths)
            XCTAssertThrowsError(try ProjectEditing.apply(.object(r),to:p))
        }
        XCTAssertEqual(try p.envelopeAssemblies().count,0)
    }
    func testImportedInvalidAssemblyFailsPortableValidation() throws {
        let seed = try LoadSightTests().readyProject()
        var p = try ProjectEditing.apply(request(),to:seed).project
        var raw = p.root["envelopeAssemblies"].array!, record = raw[0].object!
        record["method"] = .string("Unknown method"); raw[0] = .object(record)
        try p.replace("envelopeAssemblies",with:.array(raw))
        XCTAssertThrowsError(try p.validatePortableProject())
        XCTAssertThrowsError(try LoadSightDocument(project:p))
        p = try ProjectEditing.apply(request(),to:seed).project
        let first = p.root["envelopeAssemblies"].array![0]
        try p.replace("envelopeAssemblies",with:.array([first,first]))
        XCTAssertThrowsError(try p.validatePortableProject())
    }
    func testSaveFailureIsAtomic() throws {
        var p = try LoadSightTests().readyProject()
        let before = p.root
        XCTAssertThrowsError(try p.saveEnvelopeAssembly(name:"Wall",author:"Fixture",source:"Fixture",construction:.woodFramed,filmBasis:"Unknown",paths:[]))
        XCTAssertEqual(before,p.root)
    }
}
