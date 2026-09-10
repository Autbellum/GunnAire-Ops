import XCTest
import LoadSightKit
import LoadSightUI

final class ProjectAttachmentTests: XCTestCase {
    func testDeduplicatesBytesPreservesReferencesAndDoesNotResolveRFI() throws {
        var p = try LoadSightTests().fixture()
        let rfis = p.root["rfis"], data = Data("Fixture signed answer contents".utf8)
        let id = try p.addAttachment(data: data, filename: "answer.txt", author: "A", source: "Fixture correspondence", rfiID: "RFI-01")
        let before = p.root
        XCTAssertEqual(try p.addAttachment(data: data, filename: "answer.txt", author: "A", source: "Fixture correspondence", rfiID: "RFI-01"), id)
        XCTAssertEqual(p.root, before)
        try p.addAttachment(data: data, filename: "answer-copy.txt", author: "B", source: "Second review", rfiID: "RFI-02")
        let records = try p.attachments()
        XCTAssertEqual(records.count, 1); XCTAssertEqual(records[0].references.count, 2)
        XCTAssertEqual(records[0].data, data); XCTAssertEqual(p.root["rfis"], rfis)
        XCTAssertTrue(p.root["qa"].array!.allSatisfy { $0["status"].string == "Open" })
    }
    func testInvalidLinksNamesAndCorruptBytesAreRejectedAtomically() throws {
        var p = try LoadSightTests().readyProject(); let before = p.root
        XCTAssertThrowsError(try p.addAttachment(data: Data(), filename: "../bad", author: "A", source: "B"))
        XCTAssertThrowsError(try p.addAttachment(data: Data(), filename: "good.txt", author: "", source: "B"))
        XCTAssertThrowsError(try p.addAttachment(data: Data(), filename: "good.txt", author: "A", source: "B", rfiID: "missing"))
        XCTAssertEqual(p.root, before)
        try p.addAttachment(data: Data("original".utf8), filename: "evidence.txt", author: "A", source: "Fixture")
        let original = p.root
        var archive = p.root["projectAttachments"].object!, rows = archive["records"]!.array!, row = rows[0].object!
        row["data"] = .string(Data("changed".utf8).base64EncodedString()); rows[0] = .object(row); archive["records"] = .array(rows)
        XCTAssertThrowsError(try p.replace("projectAttachments", with: .object(archive)))
        XCTAssertEqual(p.root, original)
    }
    @MainActor
    func testPackageAndJSONRetainOriginalBinaryData() throws {
        var doc = try LoadSightDocument(project: LoadSightTests().readyProject())
        let bytes = Data((0...255).map { UInt8($0) })
        try doc.project.addAttachment(data: bytes, filename: "quote.bin", author: "A", source: "Binary fixture")
        for package in [true, false] {
            let restored = try LoadSightDocument(wrapper: doc.wrapper(asPackage: package))
            XCTAssertEqual(try restored.project.attachments()[0].data, bytes)
            XCTAssertEqual(try restored.project.attachments()[0].references[0].source, "Binary fixture")
        }
    }
}
