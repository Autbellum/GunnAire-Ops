import XCTest
import PDFKit
import LoadSightKit

final class DraftProposalTests: XCTestCase {
    func testDentalDraftContainsAllItemsAndRFIsAndNeverInventsPrice() throws {
        let p = try LoadSightTests().fixture()
        let data = try DraftProposal.pdf(p)
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let text = try XCTUnwrap(pdf.string)
        XCTAssertGreaterThan(pdf.pageCount, 1)
        for item in p.items { XCTAssertTrue(text.contains(item["id"]!.string!)) }
        for rfi in p.root["rfis"].array! { XCTAssertTrue(text.contains(rfi["id"].string!)) }
        XCTAssertTrue(text.contains("No included rows have complete costs"))
        XCTAssertTrue(text.contains("Project review fingerprint"))
        for index in 0..<pdf.pageCount {
            let page = try XCTUnwrap(pdf.page(at: index)?.string)
            XCTAssertTrue(page.contains("NOT FOR BID RELEASE"))
            XCTAssertTrue(page.contains("Page \(index + 1)"))
        }
    }
    func testVeryLongRecordPaginatesWithoutTruncatingEnd() throws {
        var p = try LoadSightTests().readyProject()
        try p.updateItem(id: "D1", fields: ["notes": .string(String(repeating: "Long source evidence paragraph. ", count: 1500) + "FINAL_EVIDENCE_SENTINEL")])
        let pdf = try XCTUnwrap(PDFDocument(data: DraftProposal.pdf(p)))
        XCTAssertTrue(pdf.string!.contains("FINAL_EVIDENCE_SENTINEL"))
        XCTAssertTrue(pdf.string!.contains("6. Outstanding proposal inputs"))
        XCTAssertGreaterThan(pdf.pageCount, 5)
    }
}
