import XCTest
import LoadSightKit

final class LoadSightTests: XCTestCase {
    func fixture(_ name: String = "Dental_Office_Seed") throws -> ProjectDocument {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try ProjectDocument(data: Data(contentsOf: url))
    }
    func readyProject() throws -> ProjectDocument {
        var p = try fixture("Blank_Project")
        try p.replace("sheets", with: .array([.object(["sheet": .string("M101")])]))
        try p.replace("reviewer", with: .string("Estimator"))
        try p.replace("inputs", with: .object([
            "laborRate": .number(100), "markupPct": .number(20), "taxAllowance": .number(0),
            "jobCosts": .number(0), "contingency": .number(0), "customer": .string("Fixture customer"), "proposalTerms": .string("Fixture terms")]))
        try p.replace("items", with: .array([.object([
            "id": .string("D1"), "scope": .string("Base"), "description": .string("Duct"),
            "quantity": .number(10), "unit": .string("LF"), "quantityStatus": .string("Verified"),
            "source": .string("M101 reviewed route"), "priceSource": .string("Fixture quote"),
            "materialUnit": .number(20), "laborHoursUnit": .number(0.5), "subcontractUnit": .number(0),
            "otherUnit": .number(0), "wastePct": .number(10)])]))
        let gates = (p.root["qa"].array ?? []).map { gate -> JSONValue in
            var q = gate.object!; q["status"] = .string("Complete"); q["reviewer"] = .string("Reviewer"); q["date"] = .string("2026-09-10")
            return .object(q)
        }
        try p.replace("qa", with: .array(gates))
        return p
    }
    func testPilotRoundTripPreservesEveryField() throws {
        let p = try fixture()
        let restored = try ProjectDocument(data: p.data())
        XCTAssertEqual(p.root, restored.root)
        XCTAssertEqual(p.items.count, 46)
        XCTAssertEqual(p.root["devices"].array?.count, 60)
        XCTAssertEqual(p.root["requirements"].array?.count, 34)
        XCTAssertEqual(p.root["rfis"].array?.count, 12)
        let devices = p.root["devices"].array!
        XCTAssertEqual(devices.filter { $0["tag"].string == "R1" }.count, 21)
        XCTAssertEqual(devices.filter { $0["tag"].string == "S1" }.count, 6)
        XCTAssertEqual(devices.filter { $0["tag"].string == "S2" }.count, 17)
    }
    func testPilotCannotReleaseWithoutPricesAndResolution() throws {
        let review = try EstimatePricing.review(fixture())
        XCTAssertFalse(review.ready); XCTAssertNil(review.estimatedCost); XCTAssertNil(review.releasableSellingPrice)
        XCTAssertEqual(review.pricedCount, 0)
        XCTAssertTrue(review.blockers.contains { $0.contains("12 unanswered") })
    }
    func testBlankDoesNotRetainPilotCounts() throws {
        let p = try fixture("Blank_Project")
        XCTAssertTrue(p.items.isEmpty)
        XCTAssertEqual(p.root["devices"].array?.count, 0)
        XCTAssertNil(try EstimatePricing.review(p).releasableSellingPrice)
    }
    func testWasteOnlyOnMaterialAndMarkupOnCost() throws {
        let review = try EstimatePricing.review(readyProject())
        XCTAssertEqual(review.lines[0].material, 220, accuracy: 0.000001)
        XCTAssertEqual(review.lines[0].labor, 500, accuracy: 0.000001)
        XCTAssertEqual(review.estimatedCost!, 720, accuracy: 0.000001)
        XCTAssertEqual(review.releasableSellingPrice!, 864, accuracy: 0.000001)
        XCTAssertTrue(review.ready)
    }
    func testIntentionalZeroIsDifferentFromUnknown() throws {
        var p = try readyProject()
        var rows = p.root["items"].array!
        var item = rows[0].object!; item["materialUnit"] = .number(0); rows[0] = .object(item)
        try p.replace("items", with: .array(rows))
        XCTAssertTrue(try EstimatePricing.review(p).ready)
        item["materialUnit"] = .null; rows[0] = .object(item)
        try p.replace("items", with: .array(rows))
        XCTAssertNil(try EstimatePricing.review(p).releasableSellingPrice)
    }
    func testEditInvalidatesReviewAndPreservesUnrelatedEvidence() throws {
        var p = try readyProject()
        let sheets = p.root["sheets"]
        try p.updateItem(id: "D1", fields: ["quantity": .number(12)])
        XCTAssertEqual(p.root["sheets"], sheets)
        XCTAssertTrue(p.root["qa"].array!.allSatisfy { $0["status"].string == "Open" })
        XCTAssertNil(try EstimatePricing.review(p).releasableSellingPrice)
    }
    func testInvalidEditIsAtomic() throws {
        var p = try readyProject(); let before = p.root
        XCTAssertThrowsError(try p.updateItem(id: "D1", fields: ["quantity": .number(-1)]))
        XCTAssertEqual(p.root, before)
    }
    func testRejectDuplicateRecordsAndUnsupportedSchema() throws {
        var p = try readyProject()
        XCTAssertThrowsError(try p.replace("items", with: .array(p.root["items"].array! + p.root["items"].array!)))
        XCTAssertThrowsError(try p.replace("schemaVersion", with: .number(99)))
        XCTAssertThrowsError(try p.replace("items", with: .array([.string("bad")])) )
    }
    func testIncompleteQAAndUndocumentedRFIBlockEvenFullyPricedProject() throws {
        var p = try readyProject()
        try p.replace("rfis", with: .array([.object(["id": .string("R1"), "status": .string("Resolved")])]))
        XCTAssertNil(try EstimatePricing.review(p).releasableSellingPrice)
        try p.replace("rfis", with: .array([]))
        var qa = p.root["qa"].array!; var first = qa[0].object!; first["reviewer"] = .string(""); qa[0] = .object(first)
        try p.replace("qa", with: .array(qa))
        XCTAssertNil(try EstimatePricing.review(p).releasableSellingPrice)
    }
    func testHoldAndMissingRequiredGateBlockRelease() throws {
        var p = try readyProject()
        var hold = p.items[0]; hold["id"] = .string("H1"); hold["scope"] = .string("Hold")
        try p.replace("items", with: .array(p.root["items"].array! + [.object(hold)]))
        XCTAssertNil(try EstimatePricing.review(p).releasableSellingPrice)
        try p.replace("items", with: .array([p.root["items"].array![0]]))
        try p.replace("qa", with: .array(Array(p.root["qa"].array!.dropLast())))
        XCTAssertNil(try EstimatePricing.review(p).releasableSellingPrice)
    }
    func testCSVQuotesAndNeutralizesSpreadsheetFormulas() throws {
        var p = try readyProject()
        try p.updateItem(id: "D1", fields: ["description": .string("=HYPERLINK(\"bad\")"), "source": .string("M101,\nNote 1")])
        let csv = TakeoffExport.csv(p)
        XCTAssertTrue(csv.contains("\"'=HYPERLINK(\"\"bad\"\")\""))
        XCTAssertTrue(csv.contains("\"M101,\nNote 1\""))
    }
    func testEnvelopeAndStandardAirGoldenCalculations() throws {
        XCTAssertEqual(try MechanicalMath.envelope(u: 0.05, areaSF: 1000, deltaF: 60).value, 3000)
        XCTAssertEqual(try MechanicalMath.assemblyU(resistances: [5, 15]).value, 0.05)
        XCTAssertEqual(try MechanicalMath.sensibleAir(cfm: 1200, deltaF: 20).value, 25920, accuracy: 0.000001)
        XCTAssertEqual(try MechanicalMath.latentAir(cfm: 100, deltaGrains: 30).value, 2040, accuracy: 0.000001)
        XCTAssertEqual(try MechanicalMath.totalAir(cfm: 1000, deltaEnthalpy: 10).value, 45000, accuracy: 0.000001)
        XCTAssertEqual(try MechanicalMath.infiltration(ach: 0.5, volumeCF: 12000).value, 100)
    }
    func testVentilationUsesBreathingZoneThenEffectiveness() throws {
        let evidence = try Evidence(origin: .userProvided, source: "Fixture rates; not a code lookup", confidence: 1)
        let result = try MechanicalMath.zoneOutdoorAir(people: 10, areaSF: 1000, cfmPerPerson: 5, cfmPerSF: 0.06, effectiveness: 0.8, source: evidence)
        XCTAssertEqual(result.value, 137.5); XCTAssertEqual(result.evidence, [evidence])
    }
    func testBlockPeakDoesNotSumNoncoincidentRoomPeaks() throws {
        XCTAssertEqual(try MechanicalMath.blockLoad(spaceProfiles: [[100, 20], [20, 100]]).value, 120)
        XCTAssertThrowsError(try MechanicalMath.blockLoad(spaceProfiles: [[100], [20, 100]]))
    }
    func testInvalidMathAndOverflowRejected() throws {
        XCTAssertThrowsError(try MechanicalMath.sensibleHeatRatio(sensible: 2, total: 1))
        XCTAssertThrowsError(try MechanicalMath.sensibleHeatRatio(sensible: 0, total: 0))
        XCTAssertThrowsError(try MechanicalMath.envelope(u: .infinity, areaSF: 10, deltaF: 5))
        XCTAssertThrowsError(try MechanicalMath.envelope(u: 1e300, areaSF: 1e300, deltaF: 5))
        XCTAssertThrowsError(try MechanicalMath.waterFlow(btuh: 1000, deltaF: 0))
        XCTAssertThrowsError(try MechanicalMath.gasDemand(inputBtuh: 1000, heatingValueBtuPerCF: -1))
        XCTAssertEqual(try MechanicalMath.gasDemand(inputBtuh: 100000, heatingValueBtuPerCF: 1000).value, 100)
    }
    func testCalibratedRouteAndIndependentValidation() throws {
        let evidence = try Evidence(origin: .userProvided, source: "M101 detail dimension", confidence: 1)
        var scale = try ScaleRegion(id: "main", sheet: "M101", revision: "A", min: .init(x: 0, y: 0), max: .init(x: 1000, y: 1000), reference: [.init(x: 0, y: 0), .init(x: 100, y: 0)], knownFeet: 10, evidence: evidence)
        XCTAssertNil(scale.validationErrorFraction)
        XCTAssertEqual(try scale.length([.init(x: 0, y: 0), .init(x: 30, y: 40), .init(x: 60, y: 40)]), 8)
        try scale.validate(reference: [.init(x: 0, y: 0), .init(x: 0, y: 200)], knownFeet: 20)
        XCTAssertEqual(scale.validationErrorFraction, 0)
        XCTAssertThrowsError(try scale.length([.init(x: 0, y: 0), .init(x: 1001, y: 0)]))
    }
    func testDuctAreaAndVelocityUnits() throws {
        XCTAssertEqual(try DuctGeometry.rectangularSurface(widthIn: 24, heightIn: 12, lengthFt: 10), 60)
        XCTAssertEqual(try DuctGeometry.roundSurface(diameterIn: 12, lengthFt: 10), 10 * .pi, accuracy: 0.000001)
        XCTAssertEqual(try DuctGeometry.rectangularVelocity(cfm: 1200, widthIn: 24, heightIn: 12), 600)
        XCTAssertThrowsError(try DuctGeometry.roundSurface(diameterIn: 0, lengthFt: 10))
    }
}
