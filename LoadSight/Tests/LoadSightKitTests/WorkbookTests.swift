import XCTest
@testable import LoadSightKit

final class WorkbookTests: XCTestCase {
    func testWorkbookPreservesTypedZeroAndLiteralFormulaText() throws {
        var p = try LoadSightTests().readyProject()
        try p.updateItem(id: "D1", fields: ["quantity": .number(0), "description": .string("=1+1 <source> & details")])
        let data = try TakeoffWorkbook.xlsx(p)
        let xml = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(xml.contains("<v>0.0</v>"))
        XCTAssertTrue(xml.contains("=1+1 &lt;source&gt; &amp; details"))
        XCTAssertFalse(xml.contains("<f>"))
        try p.updateItem(id: "D1", fields: ["quantity": .null])
        let blank = String(decoding: try TakeoffWorkbook.xlsx(p), as: UTF8.self)
        XCTAssertTrue(blank.contains("<c r=\"C6\" s=\"0\"/>"))
    }
    func testInvalidXMLAndOversizedRecordsFailInsteadOfTruncating() throws {
        var p = try LoadSightTests().readyProject()
        try p.updateItem(id: "D1", fields: ["notes": .string("bad\u{0001}data")])
        XCTAssertThrowsError(try TakeoffWorkbook.xlsx(p))
        try p.updateItem(id: "D1", fields: ["notes": .string(String(repeating: "x", count: 40000))])
        XCTAssertThrowsError(try TakeoffWorkbook.xlsx(p))
    }
    func testReviewDatesAreExportedAsNumericDateCells() throws {
        let p = try LoadSightTests().readyProject()
        let xml = String(decoding: try TakeoffWorkbook.xlsx(p), as: UTF8.self)
        XCTAssertTrue(xml.contains("<c r=\"E6\" s=\"5\"><v>46275.0</v></c>"))
    }
}


final class CatalogWorkbookTests: XCTestCase {
    private func mapped(cost: Double? = 50) throws -> ProjectDocument {
        var p = try LoadSightTests().readyProject()
        let source = OpsMaterialCatalogSnapshot(id: UUID(), source: "Synthetic catalog source", name: "Synthetic duct", sku: "=1+1 <SKU>", supplier: "Supplier & Co", purchaseCost: cost, updatedAt: "2026-09-10T12:34:56Z")
        let mapping = CatalogMaterialMapping(catalog: source, currency: "USD", purchaseUnit: "five-foot length", catalogUnitsPerTakeoffUnit: 0.2, takeoffUnit: "LF", itemDescription: "Duct", lifecycle: "", basis: "Synthetic compatibility and conversion")
        try p.updateCatalogMaterialMapping(itemID: "D1", mapping: mapping, expectedFingerprint: p.catalogMaterialEditFingerprint(itemID: "D1"), author: "Recorder", reason: "Initial mapping")
        return p
    }
    func testCurrentAndStaleCostsRemainDistinctInWorkbook() throws {
        var p = try mapped()
        var row = try TakeoffWorkbook.catalogTables(p).materialRows[0]
        XCTAssertEqual(row[4], .number(10)); XCTAssertEqual(row[5], .string("Current")); XCTAssertEqual(row[6], .number(10))
        try p.updateItem(id: "D1", fields: ["materialUnit": .number(99)])
        row = try TakeoffWorkbook.catalogTables(p).materialRows[0]
        XCTAssertEqual(row[4], .number(99)); XCTAssertEqual(row[5], .string("Stale")); XCTAssertEqual(row[6], .number(10))
    }
    func testUnknownZeroAndRemovedLinkDoNotConflate() throws {
        let unknown = try TakeoffWorkbook.catalogTables(mapped(cost: nil)).materialRows[0]
        XCTAssertEqual(unknown[4], .null); XCTAssertEqual(unknown[6], .null)
        var zero = try mapped(cost: 0)
        XCTAssertEqual(try TakeoffWorkbook.catalogTables(zero).materialRows[0][4], .number(0))
        try zero.updateCatalogMaterialMapping(itemID: "D1", mapping: nil, expectedFingerprint: zero.catalogMaterialEditFingerprint(itemID: "D1"), author: "Remover", reason: "Keep manual cost")
        let row = try TakeoffWorkbook.catalogTables(zero).materialRows[0]
        XCTAssertEqual(row[4], .number(0)); XCTAssertEqual(row[5], .string("Removed link")); XCTAssertEqual(row[6], .null)
        XCTAssertNotEqual(row[8], .null)
    }
    func testHistoryRetainsFullBeforeAfterEvidenceAndNumericValues() throws {
        var p = try mapped()
        try p.updateCatalogMaterialMapping(itemID: "D1", mapping: nil, expectedFingerprint: p.catalogMaterialEditFingerprint(itemID: "D1"), author: "Remover", reason: "Documented removal")
        let rows = try TakeoffWorkbook.catalogTables(p).historyRows
        let source = try XCTUnwrap(rows.first { $0[5] == .string("Supplier") && $0[2] == .string("Remover") })
        XCTAssertEqual(source[6], .string("Supplier & Co")); XCTAssertEqual(source[7], .null)
        let cost = try XCTUnwrap(rows.first { $0[5] == .string("Purchase cost (USD/purchase unit)") && $0[2] == .string("Recorder") })
        XCTAssertEqual(cost[7], .number(50)); XCTAssertNotNil(cost[3].number)
        XCTAssertTrue(rows.contains { $0[5] == .string("Catalog updated at") && $0[7] == .string("2026-09-10T12:34:56Z") })
        let xml = String(decoding: try TakeoffWorkbook.xlsx(p), as: UTF8.self)
        XCTAssertTrue(xml.contains("=1+1 &lt;SKU&gt;")); XCTAssertFalse(xml.contains("<f>"))
        XCTAssertTrue(xml.contains("Catalog history")); XCTAssertTrue(xml.contains("Material costs"))
        XCTAssertTrue(xml.contains("numFmtId=\"165\""))
    }
    func testHistoryPreservesForwardCompatibleEmptyObjectsAndBooleanEvidence() throws {
        let original = try mapped()
        var root = original.root.object!, items = root["items"]!.array!, item = items[0].object!
        var mapping = item["catalogMaterialMapping"]!.object!
        mapping["extensionEmpty"] = .object([:]); mapping["extensionFlag"] = .bool(false)
        mapping["extensionList"] = .array([.bool(true), .number(2)])
        item["catalogMaterialMapping"] = .object(mapping); items[0] = .object(item); root["items"] = .array(items)
        var history = root["catalogMaterialHistory"]!.array!, event = history[0].object!
        event["after"] = .object(mapping); history[0] = .object(event); root["catalogMaterialHistory"] = .array(history)
        let p = try ProjectDocument(data: JSONEncoder().encode(JSONValue.object(root)))
        let rows = try TakeoffWorkbook.catalogTables(p).historyRows
        XCTAssertTrue(rows.contains { $0[5] == .string("extensionEmpty") && $0[7] == .string("{}") })
        XCTAssertTrue(rows.contains { $0[5] == .string("extensionFlag") && $0[7] == .string("false") })
        let list = try XCTUnwrap(rows.first { $0[5] == .string("extensionList") }?[7].string)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data(list.utf8)), mapping["extensionList"])
    }
    func testUnmappedRowsStillExposeTheirEnteredCostBasis() throws {
        let p = try LoadSightTests().readyProject(), tables = try TakeoffWorkbook.catalogTables(p)
        XCTAssertEqual(tables.materialRows[0][5], .string("Unmapped"))
        XCTAssertEqual(tables.materialRows[0][4], .number(20)); XCTAssertEqual(tables.materialRows[0][9], .string("Fixture quote"))
        XCTAssertTrue(tables.historyRows.isEmpty)
    }
}
