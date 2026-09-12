import XCTest
import LoadSightKit

final class CommercialInputTests: XCTestCase {
    func testCommercialChangesPreserveExtensionsReopenQAAndRetainPriorValues() throws {
        var p = try LoadSightTests().readyProject()
        var inputs = p.root["inputs"].object!; inputs["supplierExtension"] = .string("preserve")
        try p.replace("inputs", with: .object(inputs))
        let before = p.root["inputs"]
        try p.updateCommercialInputs(name: "Updated project", estimator: "New estimator", fields: ["laborRate": .number(123.456789123), "markupPct": .number(30)], basis: "Approved burden schedule A", author: "Estimator")
        XCTAssertEqual(p.root["inputs"]["supplierExtension"], .string("preserve"))
        XCTAssertEqual(p.root["commercialHistory"].array![0]["before"]["inputs"], before)
        XCTAssertEqual(p.root["inputs"]["laborRate"], .number(123.456789123))
        XCTAssertTrue(p.root["qa"].array!.allSatisfy { $0["status"].string == "Open" })
        XCTAssertNil(try EstimatePricing.review(p).releasableSellingPrice)
        XCTAssertEqual(try ProjectDocument(data: p.data()).root, p.root)
    }
    func testUnknownAndExplicitZeroRemainDifferent() throws {
        var p = try LoadSightTests().readyProject()
        try p.updateCommercialInputs(name: p.name, estimator: "Estimator", fields: ["laborRate": .null], basis: "Quote pending", author: "A")
        XCTAssertNil(try EstimatePricing.review(p).estimatedCost)
        try p.updateCommercialInputs(name: p.name, estimator: "Estimator", fields: ["laborRate": .number(0)], basis: "Labor included elsewhere", author: "A")
        XCTAssertNotNil(try EstimatePricing.review(p).estimatedCost)
        XCTAssertEqual(p.root["commercialHistory"].array?.count, 2)
    }
    func testInvalidInputIsAtomicAndNoOpDoesNotInvalidateReview() throws {
        var p = try LoadSightTests().readyProject(); let before = p.root
        for fields: [String: JSONValue] in [["laborRate": .number(-1)], ["laborRate": .string("100")], ["customer": .null], ["unsupported": .number(1)]] {
            XCTAssertThrowsError(try p.updateCommercialInputs(name: p.name, estimator: "Estimator", fields: fields, basis: "Test", author: "A"))
            XCTAssertEqual(p.root, before)
        }
        XCTAssertThrowsError(try p.updateCommercialInputs(name: p.name, estimator: "Estimator", fields: [:], basis: "", author: "A"))
        try p.updateCommercialInputs(name: p.name, estimator: "Estimator", fields: [:], basis: "No change", author: "A")
        XCTAssertEqual(p.root, before)
        XCTAssertTrue(try EstimatePricing.review(p).ready)
    }
}
