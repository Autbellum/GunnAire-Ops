import XCTest
import LoadSightKit
import LoadSightUI

final class CatalogMaterialMappingTests: XCTestCase {
    private func snapshot(cost: Double? = 50, name: String = "Synthetic duct length") -> OpsMaterialCatalogSnapshot {
        .init(id: UUID(uuidString: "30000000-0000-4000-8000-000000000001")!, source: "Synthetic Ops catalog / account A", name: name, sku: "SYN-5FT", supplier: "Synthetic supplier", supplierPartNumber: "TEST-PART", purchaseCost: cost, updatedAt: "2026-09-10T12:00:00Z")
    }
    private func mapping(cost: Double? = 50, factor: Double = 0.2, unit: String = "LF", currency: String = "USD", name: String = "Synthetic duct length") -> CatalogMaterialMapping {
        .init(catalog: snapshot(cost: cost, name: name), currency: currency, purchaseUnit: "5-foot length", catalogUnitsPerTakeoffUnit: factor, takeoffUnit: unit, itemDescription: "Duct", lifecycle: "", basis: "Synthetic 5-foot length: 0.2 purchased lengths per LF; part compatibility reviewed")
    }
    private func apply(_ mapping: CatalogMaterialMapping?, to p: inout ProjectDocument) throws {
        try p.updateCatalogMaterialMapping(itemID: "D1", mapping: mapping, expectedFingerprint: p.catalogMaterialEditFingerprint(itemID: "D1"), author: "Estimator", reason: "Synthetic cost mapping review")
    }
    func testMappingUsesPurchaseCostAndConversionWithoutChangingQuantityLaborOrSource() throws {
        var p = try LoadSightTests().readyProject(); let old = p.items[0]
        try apply(mapping(), to: &p)
        let item = p.items[0]
        XCTAssertEqual(item["materialUnit"], .number(10))
        for key in ["quantity", "source", "priceSource", "laborHoursUnit", "subcontractUnit", "otherUnit", "wastePct", "scope", "unit"] { XCTAssertEqual(item[key], old[key], key) }
        XCTAssertEqual(try EstimatePricing.line(item, laborRate: 100)!.material, 110, accuracy: 1e-9)
        XCTAssertTrue(try p.catalogMaterialMapping(itemID: "D1")!.matches(item))
        XCTAssertTrue(p.root["qa"].array!.allSatisfy { $0["status"].string == "Open" })
        let event = try XCTUnwrap(p.catalogMaterialHistory().first)
        XCTAssertEqual(event.before, .null); XCTAssertEqual(event.beforeMaterialUnit, .number(20)); XCTAssertEqual(event.afterMaterialUnit, .number(10))
    }
    func testUnknownCatalogCostReplacesOldNumberWithoutBecomingZero() throws {
        var p = try LoadSightTests().readyProject()
        try apply(mapping(cost: nil), to: &p)
        XCTAssertEqual(p.items[0]["materialUnit"], .null)
        XCTAssertNil(try EstimatePricing.line(p.items[0], laborRate: 100))
        let restored = try ProjectDocument(data: p.data())
        XCTAssertNil(try restored.catalogMaterialMapping(itemID: "D1")!.catalog.purchaseCost)
        try apply(mapping(cost: 0), to: &p)
        XCTAssertEqual(p.items[0]["materialUnit"], .number(0))
        XCTAssertEqual(try EstimatePricing.line(p.items[0], laborRate: 100)?.material, 0)
    }
    func testBadUnitsCurrencyOverflowAndMissingEvidenceAreAtomic() throws {
        var p = try LoadSightTests().readyProject(); let original = try p.data()
        for bad in [mapping(factor: 0), mapping(factor: -1), mapping(factor: .infinity), mapping(cost: .greatestFiniteMagnitude, factor: 2), mapping(unit: "EA"), mapping(currency: "CAD"), mapping(cost: -10)] {
            XCTAssertThrowsError(try apply(bad, to: &p)); XCTAssertEqual(try p.data(), original)
        }
        XCTAssertThrowsError(try p.updateCatalogMaterialMapping(itemID: "D1", mapping: mapping(), expectedFingerprint: p.catalogMaterialEditFingerprint(itemID: "D1"), author: "", reason: "Reason"))
        XCTAssertThrowsError(try p.updateCatalogMaterialMapping(itemID: "D1", mapping: mapping(), expectedFingerprint: p.catalogMaterialEditFingerprint(itemID: "D1"), author: "Recorder", reason: " "))
        XCTAssertEqual(try p.data(), original)
    }
    func testManualPriceOrUnitChangeFlagsStaleBasisAndRejectsOldEditor() throws {
        var p = try LoadSightTests().readyProject(); try apply(mapping(), to: &p)
        let token = try p.catalogMaterialEditFingerprint(itemID: "D1")
        try p.updateItem(id: "D1", fields: ["materialUnit": .number(11)])
        XCTAssertFalse(try p.catalogMaterialMapping(itemID: "D1")!.matches(p.items[0]))
        XCTAssertTrue(try EstimatePricing.review(p).blockers.contains { $0.contains("Catalog material mapping for D1 is stale") })
        XCTAssertThrowsError(try p.updateCatalogMaterialMapping(itemID: "D1", mapping: mapping(), expectedFingerprint: token, author: "Stale", reason: "Old form"))
        try apply(mapping(), to: &p)
        try p.updateItem(id: "D1", fields: ["unit": .string("EA")])
        XCTAssertFalse(try p.catalogMaterialMapping(itemID: "D1")!.matches(p.items[0]))
    }
    func testRevisionsAndRemovalRetainHistoryAndCurrentCost() throws {
        var p = try LoadSightTests().readyProject(); try apply(mapping(), to: &p)
        let old = try p.catalogMaterialMapping(itemID: "D1")!
        try apply(mapping(cost: 75, name: "Revised synthetic item"), to: &p)
        XCTAssertEqual(old.materialUnit, 10); XCTAssertEqual(p.items[0]["materialUnit"], .number(15))
        try p.updateItem(id: "D1", fields: ["materialUnit": .number(16)])
        try apply(nil, to: &p)
        XCTAssertNil(try p.catalogMaterialMapping(itemID: "D1")); XCTAssertEqual(p.items[0]["materialUnit"], .number(16))
        let history = try p.catalogMaterialHistory(); XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history[1].before, history[0].after); XCTAssertEqual(history[2].before, history[1].after)
        XCTAssertEqual(history[2].after, .null); XCTAssertEqual(history[2].beforeMaterialUnit, .number(16))
        XCTAssertThrowsError(try apply(nil, to: &p))
    }
    func testHistoryTamperingOrUnrecordedMappingRejectsWithoutChangingProject() throws {
        var p = try LoadSightTests().readyProject(); try apply(mapping(), to: &p); let original = try p.data()
        XCTAssertThrowsError(try p.replace("catalogMaterialHistory", with: .array([])))
        XCTAssertThrowsError(try p.updateItem(id: "D1", fields: ["catalogMaterialMapping": .null]))
        XCTAssertThrowsError(try p.replace("items", with: .array([])))
        for (field, value) in [("before", JSONValue.string("broken")), ("afterMaterialUnit", .number(99)), ("recordedAt", .string("yesterday")), ("author", .string(""))] {
            var event = p.root["catalogMaterialHistory"].array![0].object!; event[field] = value
            XCTAssertThrowsError(try p.replace("catalogMaterialHistory", with: .array([.object(event)])))
        }
        XCTAssertEqual(try p.data(), original)
    }
    func testPackageAndJSONRetainCatalogSnapshotAndRevisionHistory() throws {
        var p = try LoadSightTests().readyProject(); try apply(mapping(), to: &p)
        let document = try LoadSightDocument(project: p)
        for package in [true, false] {
            let restored = try LoadSightDocument(wrapper: document.wrapper(asPackage: package))
            XCTAssertEqual(try restored.project.catalogMaterialMapping(itemID: "D1"), mapping())
            XCTAssertEqual(restored.project.root["catalogMaterialHistory"], p.root["catalogMaterialHistory"])
        }
    }
    func testUnrelatedProjectChangeDoesNotInvalidateMappingEditor() throws {
        var p = try LoadSightTests().readyProject(); let token = try p.catalogMaterialEditFingerprint(itemID: "D1")
        try p.replace("extension", with: .string("retained"))
        XCTAssertEqual(try p.catalogMaterialEditFingerprint(itemID: "D1"), token)
        try apply(mapping(), to: &p)
        XCTAssertEqual(p.root["extension"], .string("retained"))
    }
}
