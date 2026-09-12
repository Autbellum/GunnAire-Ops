import XCTest
import PDFKit
import LoadSightKit

final class ProposalDetailsTests: XCTestCase {
    func testTermsPreserveHistoryAndInvalidateReviewWithoutChangingCosts() throws {
        var p = try LoadSightTests().readyProject()
        let items = p.items, inputs = p.root["inputs"]
        let fingerprint = try p.qaFingerprint()
        try p.updateProposalDetails(["address": "Fixture address", "exclusions": "Plumbing trade excluded", "bonds": "Fixture bond terms pending"], author: "Fixture estimator", source: "Fixture meeting record")
        XCTAssertEqual(p.items, items); XCTAssertEqual(p.root["inputs"], inputs)
        XCTAssertNotEqual(try p.qaFingerprint(), fingerprint)
        XCTAssertTrue(p.root["qa"].array!.allSatisfy { $0["status"].string == "Open" })
        try p.updateProposalDetails(["exclusions": "Plumbing and electrical trades excluded"], author: "Fixture estimator", source: "Fixture correction")
        XCTAssertEqual(p.root["proposalHistory"].array!.last!["before"]["exclusions"], .string("Plumbing trade excluded"))
        XCTAssertEqual(p.root["proposalDetails"]["address"], .string("Fixture address"))
        XCTAssertEqual(try ProjectDocument(data: p.data()).root, p.root)
    }
    func testMissingAuthorAndUnknownKeysFailAtomically() throws {
        var p = try LoadSightTests().readyProject(); let before = p.root
        XCTAssertThrowsError(try p.updateProposalDetails(["address": "A"], author: "", source: "B"))
        XCTAssertThrowsError(try p.updateProposalDetails(["sellingPrice": "12"], author: "A", source: "B"))
        XCTAssertEqual(p.root, before)
        XCTAssertEqual(ProposalDetails.missingFields(in: p).count, 12)
    }
    func testAllSuppliedDetailsReachDraftPDFAsLiteralText() throws {
        var p = try LoadSightTests().readyProject()
        let fields = Dictionary(uniqueKeysWithValues: ProposalDetails.fields.map { ($0.id, "FIXTURE_" + $0.id + " <literal> & evidence") })
        try p.updateProposalDetails(fields, author: "Fixture author", source: "Fixture source")
        let pdf = try XCTUnwrap(PDFDocument(data: DraftProposal.pdf(p)))
        let text = try XCTUnwrap(pdf.string)
        for field in ProposalDetails.fields { XCTAssertTrue(text.contains("FIXTURE_" + field.id)) }
        XCTAssertTrue(text.contains("<literal> & evidence"))
        XCTAssertTrue(ProposalDetails.missingFields(in: p).isEmpty)
    }
}
