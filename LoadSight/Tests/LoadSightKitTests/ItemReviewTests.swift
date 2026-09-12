import XCTest
import LoadSightKit

final class ItemReviewTests: XCTestCase {
    func testReviewRetainsQuantityAndReopensQA() throws {
        var p = try LoadSightTests().readyProject()
        let quantity = p.items[0]["quantity"]
        try p.reviewItem(id: "D1", scope: "Base", status: .crossChecked, allowanceNote: "", reviewer: "Estimator", evidence: "Plan and schedule reconciled")
        XCTAssertEqual(p.items[0]["quantity"], quantity)
        XCTAssertTrue(p.isItemReviewCurrent(p.items[0]))
        XCTAssertTrue(p.root["qa"].array!.allSatisfy { $0["status"].string == "Open" })
        XCTAssertEqual(try ProjectDocument(data: p.data()).root, p.root)
        try p.updateItem(id: "D1", fields: ["quantity": .number(11)])
        XCTAssertFalse(p.isItemReviewCurrent(p.items[0]))
        XCTAssertTrue(try EstimatePricing.review(p).blockers.contains { $0.contains("quantity review is stale") })
        XCTAssertEqual(p.root["itemReviewHistory"].array![0]["after"]["quantity"], quantity)
    }
    func testAllowanceRequiresWrittenBasisAndUnknownQuantityCannotBeApproved() throws {
        var p = try LoadSightTests().readyProject(); let before = p.root
        XCTAssertThrowsError(try p.reviewItem(id: "D1", scope: "Allowance", status: .allowance, allowanceNote: "", reviewer: "A", evidence: "Reviewed"))
        XCTAssertThrowsError(try p.reviewItem(id: "D1", scope: "Base", status: .allowance, allowanceNote: "Assumed route", reviewer: "A", evidence: "Reviewed"))
        XCTAssertEqual(p.root, before)
        try p.reviewItem(id: "D1", scope: "Allowance", status: .allowance, allowanceNote: "Written fixture allowance", reviewer: "A", evidence: "Approved fixture basis")
        XCTAssertEqual(p.items[0]["scope"], .string("Allowance"))
        try p.updateItem(id: "D1", fields: ["quantity": .null])
        XCTAssertThrowsError(try p.reviewItem(id: "D1", scope: "Base", status: .verified, allowanceNote: "", reviewer: "A", evidence: "Cannot verify unknown"))
        try p.reviewItem(id: "D1", scope: "Hold", status: .required, allowanceNote: "", reviewer: "A", evidence: "Await measurement")
        XCTAssertNil(p.items[0]["quantity"]?.number)
    }
    func testCostEditsDoNotInvalidateQuantityReviewButSourceEditsDo() throws {
        var p = try LoadSightTests().readyProject()
        try p.reviewItem(id: "D1", scope: "Base", status: .verified, allowanceNote: "", reviewer: "A", evidence: "Checked source")
        try p.updateItem(id: "D1", fields: ["materialUnit": .number(99)])
        XCTAssertTrue(p.isItemReviewCurrent(p.items[0]))
        try p.updateItem(id: "D1", fields: ["source": .string("Different drawing")])
        XCTAssertFalse(p.isItemReviewCurrent(p.items[0]))
    }
}
