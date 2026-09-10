import XCTest
import LoadSightKit

final class RFIWordTests: XCTestCase {
    func testExportKeepsQuestionHistoryAndDoesNotMutateProject() throws {
        var project = try LoadSightTests().readyProject()
        let id = try project.saveRFI(draft: .init(title: "Duct <clearance> & access", question: "Confirm clearance\nKeep this second line.", source: "M1", impact: "Unknown price", itemIDs: ["D1"]), author: "Estimator")
        try project.resolveRFI(id: id, response: "Provide access", responseSource: "Architect answer 1", respondent: "Designer", author: "Recorder")
        try project.reopenRFI(id: id, reason: "New addendum", author: "Estimator")
        let original = project.root
        let data = try RFIWordDocument.docx(project, rfiID: id, generatedAt: Date(timeIntervalSince1970: 0))
        let xml = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(project.root, original)
        XCTAssertTrue(xml.contains("Duct &lt;clearance&gt; &amp; access"))
        XCTAssertTrue(xml.contains("<w:br/>"))
        XCTAssertTrue(xml.contains("Provide access"))
        XCTAssertTrue(xml.contains("Architect answer 1"))
        XCTAssertTrue(xml.contains("New addendum"))
        XCTAssertTrue(xml.contains("Status: Open"))
        XCTAssertFalse(xml.contains("TargetMode=\"External\""))
    }
    func testInvalidCharactersAndMissingIdentityFail() throws {
        var project = try LoadSightTests().readyProject()
        XCTAssertThrowsError(try RFIWordDocument.docx(project, rfiID: "missing"))
        let id = try project.saveRFI(draft: .init(title: "Question", question: "Invalid\u{0001}character", source: "M1", impact: "Unknown"), author: "Estimator")
        XCTAssertThrowsError(try RFIWordDocument.docx(project, rfiID: id))
    }
    func testAttachmentReferencesDoNotEmbedPayload() throws {
        var project = try LoadSightTests().readyProject()
        let id = try project.saveRFI(draft: .init(title: "Question", question: "Confirm", source: "M1", impact: "Unknown"), author: "Estimator")
        let hash = try project.addAttachment(data: Data("PAYLOAD_NOT_FOR_WORD".utf8), filename: "answer.txt", author: "Recorder", source: "Designer", rfiID: id)
        let xml = String(decoding: try RFIWordDocument.docx(project, rfiID: id), as: UTF8.self)
        XCTAssertTrue(xml.contains("answer.txt")); XCTAssertTrue(xml.contains(hash))
        XCTAssertFalse(xml.contains("PAYLOAD_NOT_FOR_WORD"))
    }
}
