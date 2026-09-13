import XCTest
import LoadSightKit

final class CatalogComparisonReviewTests: XCTestCase {
    private func record(_ cost: Double?) -> OpsMaterialCatalogSnapshot {
        .init(id: UUID(uuidString: "30000000-0000-4000-8000-000000000001")!, source: "Synthetic A", name: "Duct", sku: "SKU", supplier: "Supplier", supplierPartNumber: "Part", purchaseCost: cost, updatedAt: "2026-09-10T12:00:00Z")
    }
    func testStrictInputRejectsUnknownOmittedAndMalformedEvidence() throws {
        let data = try JSONEncoder().encode([record(nil)])
        XCTAssertNil(try CatalogComparisonInput.decode(data).first!.purchaseCost)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        var object = value.array![0].object!
        object.removeValue(forKey: "purchaseCost")
        XCTAssertThrowsError(try CatalogComparisonInput.decode(JSONEncoder().encode([object])))
        object["purchaseCost"] = .null; object["purchasePrice"] = .number(50)
        XCTAssertThrowsError(try CatalogComparisonInput.decode(JSONEncoder().encode([object])))
        object.removeValue(forKey: "purchasePrice"); object["purchaseCost"] = .number(-1)
        XCTAssertThrowsError(try CatalogComparisonInput.decode(JSONEncoder().encode([object])))
        XCTAssertThrowsError(try CatalogComparisonInput.decode(Data("{}".utf8)))
    }
    func testReviewIsReadOnlyAndRetainsUnknownAndAmbiguity() throws {
        var p = try LoadSightTests().readyProject()
        let mapping = CatalogMaterialMapping(catalog: record(50), currency: "USD", purchaseUnit: "5-foot length", catalogUnitsPerTakeoffUnit: 0.2, takeoffUnit: "LF", itemDescription: "Duct", lifecycle: "", basis: "Synthetic compatible duct")
        try p.updateCatalogMaterialMapping(itemID: "D1", mapping: mapping, expectedFingerprint: p.catalogMaterialEditFingerprint(itemID: "D1"), author: "Test", reason: "Fixture")
        let original = try p.data()
        for (records, status) in [([record(75)], "changed"), ([record(nil)], "changed"), ([], "missing"), ([record(75), record(75)], "ambiguous")] {
            let report = try p.catalogComparisonReview(available: records)
            let item = report["items"].array!.first { $0["itemID"].string == "D1" }!
            XCTAssertEqual(item["comparison"]["status"], .string(status))
            XCTAssertEqual(item["mappingCurrent"], .bool(true))
            if records.first?.purchaseCost == nil || status == "ambiguous" {
                XCTAssertEqual(item["comparison"]["purchaseCostDelta"], .null)
                XCTAssertNotNil(item["comparison"].object?["purchaseCostDelta"])
            }
            XCTAssertEqual(try p.data(), original)
        }
    }
    func testUnmappedRowsAreNotReportedMissing() throws {
        let p = try LoadSightTests().readyProject()
        let report = try p.catalogComparisonReview(available: [])
        XCTAssertTrue(report["items"].array!.allSatisfy { $0["comparison"] == .null && $0["mappingCurrent"] == .null })
    }
}
