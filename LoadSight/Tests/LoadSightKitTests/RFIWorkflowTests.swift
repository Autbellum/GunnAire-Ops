import XCTest
import LoadSightKit
import LoadSightUI

final class RFIWorkflowTests: XCTestCase {
    func project() throws -> ProjectDocument { try LoadSightTests().readyProject() }
    var draft: RFIDraft { .init(title: "Duct size conflict", question: "Which size applies?", source: "M101 plan / M601 detail", impact: "Duct procurement", itemIDs: ["D1"]) }
    func testQuestionResolutionAndReopeningPreserveEvidenceAndInvalidateQA() throws {
        var p = try project(); let originalItems = p.items
        let id = try p.saveRFI(draft: draft, author: "Estimator")
        XCTAssertTrue(p.root["qa"].array!.allSatisfy { $0["status"].string == "Open" })
        XCTAssertTrue(try EstimatePricing.review(p).blockers.contains { $0.contains("RFIs") })
        try p.resolveRFI(id: id, response: "Use revised 12 inch duct", responseSource: "Engineer response 4", respondent: "Engineer", author: "Estimator")
        XCTAssertFalse(try EstimatePricing.review(p).blockers.contains { $0.contains("RFIs") })
        XCTAssertFalse(try EstimatePricing.review(p).ready)
        XCTAssertEqual(p.items, originalItems)
        try p.reopenRFI(id: id, reason: "Addendum conflicts with answer", author: "Reviewer")
        XCTAssertEqual(p.root["rfis"].array![0]["response"], .string(""))
        let events = p.root["rfiHistory"].array!
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[2]["before"]["response"], .string("Use revised 12 inch duct"))
        XCTAssertEqual(events[2]["author"], .string("Reviewer"))
        XCTAssertEqual(try ProjectDocument(data: p.data()).root, p.root)
    }
    func testInvalidTransitionsAndMissingEvidenceAreAtomic() throws {
        var p = try project(); let id = try p.saveRFI(draft: draft, author: "Estimator"); let before = p.root
        XCTAssertThrowsError(try p.resolveRFI(id: id, response: "Yes", responseSource: "", respondent: "Engineer", author: "Estimator"))
        XCTAssertThrowsError(try p.reopenRFI(id: id, reason: "Wrong state", author: "Estimator"))
        XCTAssertThrowsError(try p.saveRFI(draft: draft, author: " "))
        var bad = draft; bad.itemIDs = ["missing"]
        XCTAssertThrowsError(try p.saveRFI(draft: bad, author: "Estimator"))
        XCTAssertEqual(p.root, before)
        try p.resolveRFI(id: id, response: "Yes", responseSource: "Signed response", respondent: "Engineer", author: "Estimator")
        let resolved = p.root
        XCTAssertThrowsError(try p.saveRFI(id: id, draft: draft, author: "Estimator"))
        XCTAssertThrowsError(try p.resolveRFI(id: id, response: "No", responseSource: "Other", respondent: "Engineer", author: "Estimator"))
        XCTAssertThrowsError(try p.reopenRFI(id: id, reason: "", author: "Estimator"))
        XCTAssertEqual(p.root, resolved)
    }
    func testLegacyRFIIsAdoptedWithoutLosingFields() throws {
        var p = try LoadSightTests().fixture()
        let original = p.root["rfis"].array![0]
        try p.resolveRFI(id: "RFI-01", response: "Documented fixture answer", responseSource: "Fixture response A", respondent: "Engineer", author: "Estimator")
        XCTAssertEqual(p.root["rfiHistory"].array![0]["before"], original)
        XCTAssertEqual(p.root["rfis"].array![0]["question"], original["question"])
        XCTAssertEqual(p.root["rfis"].array?.count, 12)
        XCTAssertEqual(try ProjectDocument(data: p.data()).root, p.root)
    }
    func testUnrecordedResolutionCannotBypassHistory() throws {
        var p = try project(); _ = try p.saveRFI(draft: draft, author: "Estimator")
        let before = p.root
        var rows = p.root["rfis"].array!, row = rows[0].object!
        row["question"] = .string("Silently changed")
        rows[0] = .object(row)
        XCTAssertThrowsError(try p.replace("rfis", with: .array(rows)))
        XCTAssertEqual(p.root, before)
    }
    @MainActor
    func testNativePackageRetainsResolutionHistory() throws {
        var p = try project(); let id = try p.saveRFI(draft: draft, author: "Estimator")
        try p.resolveRFI(id: id, response: "Yes", responseSource: "Response A", respondent: "Engineer", author: "Estimator")
        let doc = try LoadSightDocument(project: p)
        for package in [true, false] {
            let restored = try LoadSightDocument(wrapper: doc.wrapper(asPackage: package))
            XCTAssertEqual(restored.project.root["rfiHistory"], p.root["rfiHistory"])
            XCTAssertEqual(restored.project.root["rfis"], p.root["rfis"])
        }
    }
}
