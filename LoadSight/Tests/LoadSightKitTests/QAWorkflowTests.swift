import XCTest
import LoadSightKit
import LoadSightUI

final class QAWorkflowTests: XCTestCase {
    func testIndependentChecksStayCurrentAndFinalReviewerMustDiffer() throws {
        var p = try LoadSightTests().readyProject()
        try p.recordQACheck(id: "QA-01", reviewer: "Estimator", evidence: "Source hash reviewed", complete: true)
        try p.recordQACheck(id: "QA-02", reviewer: "Estimator", evidence: "All pages reviewed", complete: true)
        XCTAssertTrue(try p.isQACurrent(p.root["qa"].array![0]))
        XCTAssertThrowsError(try p.recordQACheck(id: "QA-12", reviewer: " estimator ", evidence: "Final check", complete: true))
        XCTAssertThrowsError(try p.recordQACheck(id: "QA-12", reviewer: "Independent", evidence: "Legacy checks are unbound", complete: true))
        for check in QAWorkflow.checks.dropFirst(2).dropLast() {
            try p.recordQACheck(id: check.id, reviewer: "Estimator", evidence: "Fixture review for \(check.id)", complete: true)
        }
        try p.recordQACheck(id: "QA-12", reviewer: "Independent reviewer", evidence: "Fixture final comparison", complete: true)
        XCTAssertTrue(try EstimatePricing.review(p).ready)
        var raw = p
        var rows = raw.root["qa"].array!, changed = rows[0].object!
        changed["note"] = .string("Changed after final signoff"); rows[0] = .object(changed)
        try raw.replace("qa", with: .array(rows))
        XCTAssertFalse(try raw.isQACurrent(raw.root["qa"].array!.last!))
        try p.recordQACheck(id: "QA-01", reviewer: "Estimator", evidence: "Additional evidence", complete: true)
        XCTAssertEqual(p.root["qa"].array!.last!["status"], .string("Open"))
        XCTAssertNil(try EstimatePricing.review(p).releasableSellingPrice)
    }
    func testRawEstimateChangeMakesBoundReviewStale() throws {
        var p = try LoadSightTests().readyProject()
        try p.recordQACheck(id: "QA-01", reviewer: "Estimator", evidence: "Reviewed", complete: true)
        var inputs = p.root["inputs"].object!; inputs["laborRate"] = .number(321)
        try p.replace("inputs", with: .object(inputs))
        XCTAssertFalse(try p.isQACurrent(p.root["qa"].array![0]))
        XCTAssertTrue(try EstimatePricing.review(p).blockers.contains { $0.contains("earlier project state") })
    }
    func testReopeningPreservesPriorEvidenceAndMissingEvidenceFailsAtomically() throws {
        var p = try LoadSightTests().readyProject()
        let before = p.root
        XCTAssertThrowsError(try p.recordQACheck(id: "QA-01", reviewer: "A", evidence: " ", complete: true))
        XCTAssertEqual(p.root, before)
        try p.recordQACheck(id: "QA-01", reviewer: "A", evidence: "Reviewed drawing", complete: true)
        try p.recordQACheck(id: "QA-01", reviewer: "B", evidence: "Addendum received", complete: false)
        XCTAssertEqual(p.root["qaHistory"].array!.last!["before"]["note"], .string("Reviewed drawing"))
        XCTAssertEqual(p.root["qa"].array![0]["status"], .string("Open"))
        XCTAssertThrowsError(try p.recordQACheck(id: "QA-12", reviewer: "Independent", evidence: "Final", complete: true))
    }
    @MainActor
    func testPackageAndJSONPersistenceKeepReviewFingerprint() async throws {
        var doc = try LoadSightDocument(project: LoadSightTests().readyProject())
        let url = Bundle.module.url(forResource: "DrawingIntake", withExtension: "pdf", subdirectory: "Fixtures")!
        try doc.addDrawings(await DrawingIngestor().ingest(url: url, ocr: .disabled))
        try doc.project.recordQACheck(id: "QA-01", reviewer: "Estimator", evidence: "Reviewed fixture source", complete: true)
        for package in [true, false] {
            let restored = try LoadSightDocument(wrapper: doc.wrapper(asPackage: package))
            XCTAssertTrue(try restored.project.isQACurrent(restored.project.root["qa"].array![0]))
            XCTAssertEqual(restored.project.root["qaHistory"], doc.project.root["qaHistory"])
        }
    }
}
