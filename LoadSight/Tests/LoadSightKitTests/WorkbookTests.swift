import XCTest
import LoadSightKit

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
