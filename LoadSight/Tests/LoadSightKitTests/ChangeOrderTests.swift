import XCTest
import LoadSightKit

final class ChangeOrderTests: XCTestCase {
    private func priced() -> ChangeOrderDraft {
        var d = ChangeOrderDraft(number: "CO-001", originalScope: "Original mechanical route", proposedScope: "Revised mechanical route")
        d.costs = zip(ChangeCostCategory.allCases, [100.0, -40, 0, 0]).map { .init(category: $0.0, delta: .init(amount: $0.1, source: "Synthetic quoted delta")) }
        d.markupPercent = .init(amount: 10, source: "Synthetic terms"); d.markupBasis = .signedNetCosts
        d.tax = .init(amount: 2, source: "Synthetic tax delta"); d.bond = .init(amount: 1, source: "Synthetic bond delta")
        return d
    }
    func testUnknownIsNotZeroAndDoesNotCompleteScope() throws {
        let d = ChangeOrderDraft(number: "1", originalScope: "Original", proposedScope: "Proposed")
        let r = try d.review(); XCTAssertEqual(r.knownCostDelta, 0); XCTAssertNil(r.costDelta); XCTAssertNil(r.totalDelta)
        let p = try priced().review(); XCTAssertEqual(p.totalDelta, 69); XCTAssertTrue(p.unknownFields.contains("Quantity ledger")); XCTAssertEqual(p.status, "Draft")
        var incomplete = priced(); incomplete.costs[3].delta.amount = nil
        XCTAssertEqual(try incomplete.review().knownCostDelta, 60); XCTAssertNil(try incomplete.review().totalDelta)
    }
    func testCreditAndMarkupPoliciesHaveExplicitDifferentResults() throws {
        var d = priced(); XCTAssertEqual(try d.review().totalDelta, 69)
        d.markupBasis = .positiveAdditionsOnly; XCTAssertEqual(try d.review().totalDelta, 73)
        d.costs[0].delta.amount = -100; d.markupBasis = .signedNetCosts
        XCTAssertEqual(try d.review().totalDelta, -151)
        d.markupBasis = .positiveAdditionsOnly; XCTAssertEqual(try d.review().totalDelta, -137)
        d.markupBasis = nil; XCTAssertNil(try d.review().totalDelta)
    }
    func testQuantitiesRemainIndependentFromQuotedCosts() throws {
        var d = priced()
        d.quantities = [.init(name: "Duct", unit: "LF", original: .init(amount: 100, source: "Original M1"), proposed: .init(amount: 70, source: "Revision M2"))]
        XCTAssertEqual(try d.review().quantityDeltas, [-30]); XCTAssertEqual(try d.review().totalDelta, 69)
        d.quantities[0].proposed.amount = nil
        XCTAssertNil(try d.review().quantityDeltas[0]); XCTAssertEqual(try d.review().totalDelta, 69)
        d.quantities[0].original.amount = -1; XCTAssertThrowsError(try d.review())
    }
    func testInvalidEvidenceCategoriesDatesAndOverflowFail() throws {
        var d = priced(); d.costs[2].delta.source = ""; XCTAssertThrowsError(try d.review())
        d = priced(); d.costs[3].category = .labor; XCTAssertThrowsError(try d.review())
        d = priced(); d.date = "2026-02-30"; XCTAssertThrowsError(try d.review())
        d = priced(); d.markupPercent.amount = -1; XCTAssertThrowsError(try d.review())
        d = priced(); d.costs[0].delta.amount = .greatestFiniteMagnitude; d.costs[1].delta.amount = .greatestFiniteMagnitude; XCTAssertThrowsError(try d.review())
        d = priced(); d.costs[0].delta.amount = .infinity; XCTAssertThrowsError(try d.review())
    }
    func testSaveIsAtomicDraftOnlyAndPreservesProjectExtensions() throws {
        var p = try LoadSightTests().readyProject(); try p.replace("custom", with: .string("Retained"))
        let before = try p.data(), fingerprint = try p.qaFingerprint()
        var d = priced(); d.rfiIDs = ["missing"]
        XCTAssertThrowsError(try p.createChangeOrder(d, author: "Recorder")); XCTAssertEqual(try p.data(), before)
        d.rfiIDs = []; let id = try p.createChangeOrder(d, author: "Recorder")
        XCTAssertEqual(try p.changeOrders().first?.id, id); XCTAssertNotEqual(try p.qaFingerprint(), fingerprint)
        XCTAssertEqual(p.root["custom"].string, "Retained"); XCTAssertTrue(p.root["qa"].array!.allSatisfy { $0["status"].string == "Open" })
        let saved = try p.data(); XCTAssertThrowsError(try p.createChangeOrder(d, author: "Recorder")); XCTAssertEqual(try p.data(), saved)
        let restored = try ProjectDocument(data: saved); XCTAssertEqual(try restored.changeOrders().first?.draft.review().totalDelta, 69)
        var rows = p.root["changeOrders"].array!, row = rows[0].object!; row["status"] = .string("Approved"); rows[0] = .object(row)
        XCTAssertThrowsError(try p.replace("changeOrders", with: .array(rows))); XCTAssertEqual(try p.data(), saved)
    }
    func testStructuredDraftRejectsTyposAndPreservesUnknowns() throws {
        let project = try LoadSightTests().readyProject()
        var draft = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(priced())).object!
        draft["entitlement"] = .null
        var request: [String: JSONValue] = ["operation": .string("changeorder.create"), "author": .string("Recorder"), "draft": .object(draft)]
        let result = try ProjectEditing.apply(.object(request), to: project)
        XCTAssertEqual(try result.project.changeOrders().first?.draft.review().totalDelta, 69)
        draft["typo"] = .number(42); request["draft"] = .object(draft)
        XCTAssertThrowsError(try ProjectEditing.apply(.object(request), to: project))
        draft.removeValue(forKey: "typo"); draft["tax"] = .object(["amount": .null]); request["draft"] = .object(draft)
        XCTAssertThrowsError(try ProjectEditing.apply(.object(request), to: project))
        XCTAssertTrue(try project.changeOrders().isEmpty)
    }

}
