import XCTest
import LoadSightKit

final class ChangeOrderWordTests: XCTestCase {
    func testUnknownAmountsStayUnknownAndExportDoesNotMutate() throws {
        var p = try LoadSightTests().readyProject()
        let id = try p.createChangeOrder(.init(number: "CO <1> & draft", originalScope: "Original\nSecond line", proposedScope: "Revised"), author: "Recorder")
        let before = try p.data(), word = try ChangeOrderWordDocument.docx(p, changeOrderID: id, generatedAt: Date(timeIntervalSince1970: 0))
        let xml = String(decoding: word, as: UTF8.self)
        XCTAssertEqual(try p.data(), before)
        for text in ["Change order draft", "Unknown — withheld", "CO &lt;1&gt; &amp; draft", "<w:br/>", "<w:tbl>", "<w:tblHeader/>", "Not recorded", "1970-01-01", "Recorded by: Recorder"] { XCTAssertTrue(xml.contains(text), text) }
        XCTAssertFalse(xml.contains("TargetMode=\"External\""))
    }
    func testCreditQuantitiesSourcesAndLinkedRFIStatusAppear() throws {
        var p = try LoadSightTests().readyProject()
        let rfi = try p.saveRFI(draft: .init(title: "Clearance revision", question: "Confirm", source: "M101", impact: "Route change"), author: "Recorder")
        var d = ChangeOrderDraft(number: "CO-1", originalScope: "Original route", proposedScope: "Proposed route")
        d.rfiIDs = [rfi]
        d.costs = zip(ChangeCostCategory.allCases, [100.0,-40,0,0]).map { .init(category: $0, delta: .init(amount: $1, source: "Synthetic cost source")) }
        d.markupPercent = .init(amount: 10, source: "Markup source"); d.markupBasis = .positiveAdditionsOnly
        d.tax = .init(amount: 2, source: "Tax source"); d.bond = .init(amount: 1, source: "Bond source")
        d.quantities = [.init(name: "Duct", unit: "LF", original: .init(amount: 100, source: "Original M1"), proposed: .init(amount: 70, source: "Revised M2"))]
        let id = try p.createChangeOrder(d, author: "Recorder")
        let xml = String(decoding: try ChangeOrderWordDocument.docx(p, changeOrderID: id), as: UTF8.self)
        for text in ["-40.00", "73.00", "-30.0", "Original M1", "Revised M2", "Synthetic cost source", "Positive category deltas only", "Current RFI status: Open", "Clearance revision"] { XCTAssertTrue(xml.contains(text),text) }
    }
    func testMissingRecordAndIllegalXMLFail() throws {
        var p = try LoadSightTests().readyProject()
        XCTAssertThrowsError(try ChangeOrderWordDocument.docx(p, changeOrderID: "missing"))
        let id = try p.createChangeOrder(.init(number: "CO-1", originalScope: "Illegal\u{0001}text", proposedScope: "Proposed"), author: "Recorder")
        XCTAssertThrowsError(try ChangeOrderWordDocument.docx(p, changeOrderID: id))
    }
}
