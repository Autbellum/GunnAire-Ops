import XCTest
import LoadSightKit
import CryptoKit

final class ReviewBoundaryTests: XCTestCase {
    func testPricingRejectsNonfiniteReviewTimeEvenWithoutAQuote() throws {
        let p = try LoadSightTests().readyProject()
        for value in [Double.infinity, -.infinity, .nan] {
            XCTAssertThrowsError(try EstimatePricing.review(p, asOf: Date(timeIntervalSince1970: value)))
        }
    }

    func testChangeReviewRetainsRawRecordAndRevisionExtensions() throws {
        var p = try LoadSightTests().readyProject()
        var draft = ChangeOrderDraft(number: "CO-1", originalScope: "Before", proposedScope: "After")
        let id = try p.createChangeOrder(draft, author: "Fixture")
        var rows = p.root["changeOrders"].array!, row = rows[0].object!
        row["futureEvidence"] = .object(["verified": .bool(false)]); rows[0] = .object(row)
        try p.replace("changeOrders", with: .array(rows))
        draft.proposedScope = "Revised"
        try p.reviseChangeOrder(id: id, expectedFingerprint: p.changeOrderEditFingerprint(id: id), draft: draft, author: "Reviewer", reason: "Synthetic revision")
        var history = p.root["changeOrderHistory"].array!, event = history[0].object!
        event["futureEvidence"] = .array([.string("Uninterpreted"), .number(0)])
        history[0] = .object(event); try p.replace("changeOrderHistory", with: .array(history))
        let review = try XCTUnwrap(p.changeOrderReview().array?.first)
        XCTAssertEqual(review["record"], p.root["changeOrders"].array![0])
        XCTAssertEqual(review["history"], p.root["changeOrderHistory"])
        XCTAssertEqual(review["editFingerprint"].string, try p.changeOrderEditFingerprint(id: id))
    }

    func testRoomReviewRetainsRawRoomAndAssemblyEvidence() throws {
        var (p, id) = try RoomRevisionTests().seed()
        var rooms = p.root["roomTransmissions"].array!, room = rooms[0].object!
        room["futureSurvey"] = .string("Synthetic extra evidence"); rooms[0] = .object(room)
        try p.replace("roomTransmissions", with: .array(rooms))
        var assemblies = p.root["envelopeAssemblies"].array!, assembly = assemblies[0].object!
        assembly["futureCertificate"] = .object(["verified": .bool(false)]); assemblies[0] = .object(assembly)
        try p.replace("envelopeAssemblies", with: .array(assemblies))
        let review = try p.roomTransmissionReview()
        XCTAssertEqual(review["rooms"].array?.first?["record"], rooms[0])
        XCTAssertEqual(review["assemblies"].array?.first?["record"], assemblies[0])
        XCTAssertEqual(try p.envelopeReview()["assemblies"].array?.first?["record"], assemblies[0])
        XCTAssertEqual(review["rooms"].array?.first?["editFingerprint"].string, try p.roomTransmissionEditFingerprint(id: id))
    }

    func testCatalogComparisonBenchmark() throws {
        let p = try CatalogReadSnapshotTests().project(itemCount: 100)
        let saved = try XCTUnwrap(p.catalogMaterialMapping(itemID: "D1")?.catalog)
        let available = [saved] + (0..<99).map { _ in
            OpsMaterialCatalogSnapshot(id: UUID(), source: saved.source, name: "Other synthetic item", purchaseCost: nil, updatedAt: saved.updatedAt)
        }
        let start = Date()
        let review = try p.catalogComparisonReview(available: available)
        print("CATALOG_COMPARE_100_SECONDS=\(Date().timeIntervalSince(start))")
        XCTAssertEqual(review["items"].array?.count, 100)
        XCTAssertTrue(review["items"].array!.allSatisfy { $0["comparison"]["status"] == .string("unchanged") })
    }

    func testAirReviewRetainsRawConditionAndProcessEvidence() throws {
        var p = try LoadSightTests().readyProject()
        try p.saveAirCondition(name: "In", author: "Fixture", source: "Synthetic", dryBulbC: 25, relativeHumidity: 0.5, pressurePa: 101325)
        let id = try XCTUnwrap(p.airConditions().first?.id)
        try p.saveAirProcess(name: "Mix", author: "Fixture", source: "Synthetic", kind: .mixing,
            firstConditionID: id, secondConditionID: id, firstActualCFM: 100, secondActualCFM: 200, flowClassification: .userProvided)
        for key in ["airConditions", "airProcesses"] {
            var rows = p.root[key].array!, row = rows[0].object!
            row["futureEvidence"] = .object(["verified": .bool(false)]); rows[0] = .object(row)
            try p.replace(key, with: .array(rows))
        }
        let review = try p.airProcessReview()
        XCTAssertEqual(review["conditions"].array?.first?["record"], p.root["airConditions"].array?.first)
        XCTAssertEqual(review["processes"].array?.first?["record"], p.root["airProcesses"].array?.first)
        XCTAssertEqual(review["conditions"].array?.first?["state"]["dryBulbC"], .number(25))
    }

    private func legacyFingerprint(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    func testBulkChangeTokensKeepLegacyContractAndIsolateOtherRecords() throws {
        var p = try LoadSightTests().readyProject()
        for number in ["CO-1", "CO-2", "CO-3"] {
            try p.createChangeOrder(.init(number: number, originalScope: "Before", proposedScope: "After"), author: "Fixture")
        }
        let old = try p.changeOrderReadSnapshot(), first = old[0]
        try p.reviseChangeOrder(id: first.record.id, expectedFingerprint: first.editFingerprint,
            draft: first.record.draft, author: "Fixture", reason: "Reaffirm reviewed values")
        let current = try p.changeOrderReadSnapshot()
        XCTAssertNotEqual(old[0].editFingerprint, current[0].editFingerprint)
        XCTAssertEqual(old[1].editFingerprint, current[1].editFingerprint)
        XCTAssertTrue(old[0].history.isEmpty); XCTAssertEqual(current[0].history.count, 1)
        for entry in current {
            let last = p.root["changeOrderHistory"].array?.last { $0["changeOrderID"].string == entry.record.id }?["id"] ?? .null
            XCTAssertEqual(entry.editFingerprint, try legacyFingerprint(.object(["record": entry.rawRecord, "latestRevision": last])))
        }
        let before = p.root
        XCTAssertThrowsError(try p.reviseChangeOrder(id: first.record.id, expectedFingerprint: first.editFingerprint,
            draft: first.record.draft, author: "Fixture", reason: "Stale review"))
        XCTAssertEqual(p.root, before)
    }

    func testBulkRoomTokensKeepFullAssemblyAndRevisionContract() throws {
        var (p, id) = try RoomRevisionTests().seed()
        try RoomRevisionTests().revise(&p, id)
        let before = p.root
        let review = try p.roomTransmissionReview()
        let raw = p.root["roomTransmissions"].array![0]
        let assemblies = p.root["envelopeAssemblies"].array!.sorted { $0["id"].string! < $1["id"].string! }
        let last = p.root["roomTransmissionHistory"].array!.last!["id"]
        let expected = try legacyFingerprint(.object(["room": raw, "assemblies": .array(assemblies), "latestRevision": last]))
        XCTAssertEqual(review["rooms"].array?.first?["editFingerprint"].string, expected)
        XCTAssertEqual(review["history"].array?.first?["before"], p.root["roomTransmissionHistory"].array?.first?["before"])
        XCTAssertEqual(p.root, before)
    }

    func testCatalogReviewRejectsNonfiniteTimeBeforeFormatting() throws {
        let p = try LoadSightTests().readyProject()
        for value in [Double.infinity, -.infinity, .nan] {
            XCTAssertThrowsError(try p.catalogMaterialReview(asOf: Date(timeIntervalSince1970: value)))
        }
    }

    func testComparisonIndexRetainsAmbiguityIsolationAndCapturedRecords() throws {
        let p = try CatalogReadSnapshotTests().project(itemCount: 1)
        let saved = try XCTUnwrap(p.catalogMaterialMapping(itemID: "D1")?.catalog)
        let foreign = OpsMaterialCatalogSnapshot(id: saved.id, source: "Different account", name: saved.name, purchaseCost: 0, updatedAt: saved.updatedAt)
        var records = [saved, foreign]
        let index = try CatalogComparisonIndex(available: records)
        records.append(saved)
        XCTAssertEqual(try index.compare(saved: saved).status, .unchanged)
        XCTAssertEqual(try CatalogComparisonIndex(available: records).compare(saved: saved).status, .ambiguous)
        XCTAssertEqual(try CatalogComparisonIndex(available: [foreign]).compare(saved: saved).status, .differentSource)
        let invalid = OpsMaterialCatalogSnapshot(id: UUID(), source: "Other", name: "Invalid", purchaseCost: -1, updatedAt: saved.updatedAt)
        XCTAssertThrowsError(try CatalogComparisonIndex(available: [saved, invalid]))
        XCTAssertThrowsError(try p.catalogComparisonReview(available: [invalid]))
    }
}
