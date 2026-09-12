import XCTest
import LoadSightKit

final class CatalogReadSnapshotTests: XCTestCase {
    func project(itemCount: Int) throws -> ProjectDocument {
        var base = try LoadSightTests().readyProject()
        let catalog = OpsMaterialCatalogSnapshot(id: UUID(), source: "Synthetic read fixture", name: "Duct", purchaseCost: 50, updatedAt: "2026-09-10T12:00:00Z")
        let mapping = CatalogMaterialMapping(catalog: catalog, currency: "USD", purchaseUnit: "5-foot length", catalogUnitsPerTakeoffUnit: 0.2, takeoffUnit: "LF", itemDescription: "Duct", lifecycle: "", basis: "Synthetic five-foot conversion")
        try base.updateCatalogMaterialMapping(itemID: "D1", mapping: mapping, expectedFingerprint: base.catalogMaterialEditFingerprint(itemID: "D1"), author: "Fixture", reason: "Read validation")
        var root = base.root.object!, items: [JSONValue] = [], history: [JSONValue] = []
        for index in 0..<itemCount {
            let id = "D\(index + 1)"
            var item = base.items[0], event = base.root["catalogMaterialHistory"].array![0].object!
            item["id"] = .string(id); event["itemID"] = .string(id); event["id"] = .string(UUID().uuidString)
            items.append(.object(item)); history.append(.object(event))
        }
        root["items"] = .array(items); root["catalogMaterialHistory"] = .array(history)
        return try ProjectDocument(data: JSONEncoder().encode(JSONValue.object(root)))
    }

    func testReviewRetainsHistoryAfterUnlinkAndItemRemoval() throws {
        var p = try project(itemCount: 2)
        try p.updateCatalogMaterialMapping(itemID: "D1", mapping: nil, expectedFingerprint: p.catalogMaterialEditFingerprint(itemID: "D1"), author: "Fixture", reason: "Retire takeoff item")
        try p.replace("items", with: .array(p.root["items"].array!.filter { $0["id"] != .string("D1") }))
        let review = try p.catalogMaterialReview()
        XCTAssertEqual(review["items"].array?.count, 1)
        let removed = try XCTUnwrap(review["removedItemHistory"].array)
        XCTAssertEqual(removed, p.root["catalogMaterialHistory"].array!.filter { $0["itemID"] == .string("D1") })
        XCTAssertEqual(removed.count, 2)
    }

    func testReviewFingerprintsMatchSingleItemEditsAndRetainForwardEvidence() throws {
        var p = try project(itemCount: 3)
        var events = p.root["catalogMaterialHistory"].array!, event = events[0].object!
        event["extensionEvidence"] = .object(["recorded": .bool(false), "note": .string("Retain without interpreting")])
        events[0] = .object(event); try p.replace("catalogMaterialHistory", with: .array(events))
        for row in try XCTUnwrap(p.catalogMaterialReview()["items"].array) {
            let id = try XCTUnwrap(row["itemID"].string)
            XCTAssertEqual(row["editFingerprint"].string, try p.catalogMaterialEditFingerprint(itemID: id))
            XCTAssertEqual(row["history"].array, events.filter { $0["itemID"] == .string(id) })
            XCTAssertEqual(row["mappingCurrent"], .bool(true))
        }
    }

    func testLargeCatalogReadBenchmark() throws {
        let p = try project(itemCount: 100)
        let start = Date()
        let review = try p.catalogMaterialReview()
        print("CATALOG_READ_100_SECONDS=\(Date().timeIntervalSince(start))")
        XCTAssertEqual(review["items"].array?.count, 100)
    }

    func testSnapshotDoesNotFollowLaterEditsAndOldFingerprintStillRejects() throws {
        var p = try project(itemCount: 2)
        let old = try p.catalogMaterialReadSnapshot()
        try p.updateItem(id: "D1", fields: ["materialUnit": .number(99)])
        let current = try p.catalogMaterialReadSnapshot()
        XCTAssertEqual(old.entries[0].item["materialUnit"], .number(10))
        XCTAssertEqual(current.entries[0].item["materialUnit"], .number(99))
        XCTAssertFalse(try XCTUnwrap(current.entries[0].mapping).matches(current.entries[0].item))
        XCTAssertNotEqual(old.entries[0].editFingerprint, current.entries[0].editFingerprint)
        XCTAssertEqual(old.entries[1].editFingerprint, current.entries[1].editFingerprint)
        let before = p.root
        XCTAssertThrowsError(try p.updateCatalogMaterialMapping(itemID: "D1", mapping: old.entries[0].mapping,
            expectedFingerprint: old.entries[0].editFingerprint, author: "Fixture", reason: "Stale view"))
        XCTAssertEqual(p.root, before)
    }

    func testRowDecoderPreservesUnknownZeroAndRejectsMalformedMapping() throws {
        let p = try project(itemCount: 1)
        var item = p.items[0]
        item["catalogMaterialMapping"] = .null
        XCTAssertNil(try CatalogMaterialMapping.recorded(in: item))
        for cost in [JSONValue.null, .number(0)] {
            var mapping = p.items[0]["catalogMaterialMapping"]!.object!, catalog = mapping["catalog"]!.object!
            catalog["purchaseCost"] = cost; mapping["catalog"] = .object(catalog)
            item["catalogMaterialMapping"] = .object(mapping); item["materialUnit"] = cost
            let decoded = try XCTUnwrap(CatalogMaterialMapping.recorded(in: item))
            XCTAssertEqual(decoded.materialUnit.map(JSONValue.number) ?? .null, cost)
            XCTAssertTrue(decoded.matches(item))
        }
        item["catalogMaterialMapping"] = .string("invalid")
        XCTAssertThrowsError(try CatalogMaterialMapping.recorded(in: item))
    }
}
