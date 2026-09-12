import XCTest
import LoadSightKit
import LoadSightUI

final class RFICommunicationTests: XCTestCase {
    private var details: RFICommunication { .init(to: "Design team", from: "Mechanical estimator", date: "2026-09-10", requiredResponseDate: "2026-09-17", suggestedResolution: "Confirm the revised route before procurement.") }
    private func draft(_ communication: RFICommunication? = nil) -> RFIDraft {
        .init(title: "Route clarification", question: "Which route applies?", source: "M101 detail 2", impact: "Cost pending answer", communication: communication)
    }
    func testCalendarDatesRejectNormalizationAndRetainUnknowns() throws {
        for value in ["", "2024-02-29", "2000-02-29", "2026-09-10"] { XCTAssertNoThrow(try RFICommunication(date: value, requiredResponseDate: value).validate()) }
        for value in ["2023-02-29", "1900-02-29", "2026-04-31", "2026-13-01", "2026-00-01", "2026-01-00", "0000-01-01", "2026-9-01", "09/10/2026", " "] {
            XCTAssertThrowsError(try RFICommunication(date: value).validate(), value)
            XCTAssertThrowsError(try RFICommunication(requiredResponseDate: value).validate(), value)
        }
        // A historical or overdue deadline remains recorded evidence, not an inferred new deadline.
        XCTAssertNoThrow(try RFICommunication(date: "2026-09-10", requiredResponseDate: "2026-09-01").validate())
    }
    func testLegacyEditPreservesRoutingAndExplicitClearRetainsHistory() throws {
        var p = try LoadSightTests().readyProject()
        let id = try p.saveRFI(draft: draft(details), author: "Recorder")
        let fingerprint = try p.qaFingerprint()
        try p.saveRFI(id: id, draft: draft(), author: "Older client")
        XCTAssertEqual(p.root["rfis"].array![0]["to"].string, "Design team")
        try p.saveRFI(id: id, draft: draft(.init()), author: "Editor")
        XCTAssertEqual(p.root["rfis"].array![0]["to"].string, "")
        XCTAssertEqual(p.root["rfiHistory"].array!.last!["before"]["to"].string, "Design team")
        XCTAssertEqual(p.root["rfiHistory"].array!.last!["after"]["to"].string, "")
        XCTAssertNotEqual(try p.qaFingerprint(), fingerprint)
        XCTAssertTrue(p.root["qa"].array!.allSatisfy { $0["status"].string == "Open" })
        let xml = String(decoding: try RFIWordDocument.docx(p, rfiID: id), as: UTF8.self)
        XCTAssertTrue(xml.contains("To: Not recorded")); XCTAssertTrue(xml.contains("To: Design team"))
        XCTAssertTrue(xml.contains("Required response date: 2026-09-17"))
    }
    func testInvalidEditDoesNotPartiallyChangeRecord() throws {
        var p = try LoadSightTests().readyProject()
        let id = try p.saveRFI(draft: draft(details), author: "Recorder")
        let before = p.root
        var invalid = details; invalid.date = "2026-02-30"
        XCTAssertThrowsError(try p.saveRFI(id: id, draft: draft(invalid), author: "Editor"))
        XCTAssertEqual(p.root, before)
        var rows = p.root["rfis"].array!, row = rows[0].object!
        row["communicationVersion"] = .number(2); rows[0] = .object(row)
        XCTAssertThrowsError(try p.replace("rfis", with: .array(rows)))
        XCTAssertEqual(p.root, before)
    }
    func testStructuredRoutingSchemaRejectsTyposNullAndPartialReplacement() throws {
        let p = try LoadSightTests().readyProject()
        var request: [String: JSONValue] = ["operation": .string("rfi.create"), "author": .string("Recorder"), "title": .string("Clarification"), "question": .string("Which route?"), "source": .string("M101"), "impact": .string("Unknown"), "priority": .string("Normal"), "itemIDs": .array([])]
        let values = details.values.mapValues(JSONValue.string)
        request["communication"] = .object(values)
        let result = try ProjectEditing.apply(.object(request), to: p)
        XCTAssertEqual(result.project.root["rfis"].array![0]["from"].string, "Mechanical estimator")
        for supplied: JSONValue in [.null, .object([:]), .object(values.merging(["recipient": .string("Typo")]) { _, new in new }), .object(values.merging(["date": .number(1)]) { _, new in new })] {
            request["communication"] = supplied
            XCTAssertThrowsError(try ProjectEditing.apply(.object(request), to: p))
        }
    }
    @MainActor
    func testNativePackageAndResolutionKeepCommunication() throws {
        var p = try LoadSightTests().readyProject()
        let id = try p.saveRFI(draft: draft(details), author: "Recorder")
        try p.resolveRFI(id: id, response: "Use revised route", responseSource: "Answer 1", respondent: "Engineer", author: "Recorder")
        try p.reopenRFI(id: id, reason: "New addendum", author: "Recorder")
        let document = try LoadSightDocument(project: p)
        for package in [true, false] {
            let restored = try LoadSightDocument(wrapper: document.wrapper(asPackage: package))
            XCTAssertEqual(restored.project.root["rfis"], p.root["rfis"])
            XCTAssertEqual(restored.project.root["rfiHistory"], p.root["rfiHistory"])
            XCTAssertEqual(restored.project.root["rfis"].array![0]["requiredResponseDate"].string, "2026-09-17")
        }
    }
}
