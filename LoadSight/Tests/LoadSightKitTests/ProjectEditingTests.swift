import XCTest
import LoadSightKit

final class ProjectEditingTests: XCTestCase {
    func request(_ op: String, _ fields: [String: JSONValue]) -> JSONValue {
        var result = fields; result["operation"] = .string(op); result["author"] = .string("Fixture estimator")
        return .object(result)
    }
    var draft: [String: JSONValue] { ["title": .string("Size conflict"), "question": .string("Confirm size?"), "source": .string("M101 vs M601"), "impact": .string("Procurement"), "priority": .string("High"), "itemIDs": .array([])] }
    func testStructuredWorkflowUsesSameHistoryAndPreservesInput() throws {
        let original = try LoadSightTests().readyProject()
        let created = try ProjectEditing.apply(request("rfi.create", draft), to: original)
        let id = created.recordID!
        var editedFields = draft; editedFields["id"] = .string(id); editedFields["question"] = .string("Confirm size after addendum?")
        let edited = try ProjectEditing.apply(request("rfi.edit", editedFields), to: created.project)
        let resolved = try ProjectEditing.apply(request("rfi.resolve", ["id": .string(id), "response": .string("12 inch"), "responseSource": .string("Fixture answer A"), "respondent": .string("Engineer")]), to: edited.project)
        let reopened = try ProjectEditing.apply(request("rfi.reopen", ["id": .string(id), "reason": .string("New addendum")]), to: resolved.project)
        let commercial = try ProjectEditing.apply(request("commercial.update", ["name": .string(original.name), "estimator": .string("Estimator"), "basis": .string("Fixture quote"), "fields": .object(["laborRate": .number(125)])]), to: reopened.project)
        XCTAssertEqual(original.root["rfis"].array?.count, 0)
        XCTAssertEqual(commercial.project.root["rfiHistory"].array?.count, 4)
        XCTAssertEqual(commercial.project.root["commercialHistory"].array?.count, 1)
        XCTAssertEqual(commercial.project.root["rfis"].array![0]["status"], .string("Open"))
        XCTAssertNil(try EstimatePricing.review(commercial.project).releasableSellingPrice)
    }
    func testRejectsTyposMissingFieldsAndUnsupportedActions() throws {
        let p = try LoadSightTests().readyProject()
        var typo = draft; typo["souce"] = .string("Wrong")
        XCTAssertThrowsError(try ProjectEditing.apply(request("rfi.create", typo), to: p))
        XCTAssertThrowsError(try ProjectEditing.apply(request("rfi.create", [:]), to: p))
        XCTAssertThrowsError(try ProjectEditing.apply(request("estimate.approve", [:]), to: p))
    }
    func testOutputPublicationNeverReplacesFileOrSymlink() throws {
        let p = try LoadSightTests().readyProject(), fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let output = directory.appendingPathComponent("new.json")
        try ProjectEditing.writeNew(p, to: output)
        XCTAssertEqual(try ProjectDocument(data: Data(contentsOf: output)).root, p.root)
        let data = try Data(contentsOf: output)
        XCTAssertThrowsError(try ProjectEditing.writeNew(p, to: output))
        XCTAssertEqual(try Data(contentsOf: output), data)
        let link = directory.appendingPathComponent("link.json")
        try fm.createSymbolicLink(at: link, withDestinationURL: output)
        XCTAssertThrowsError(try ProjectEditing.writeNew(p, to: link))
        XCTAssertEqual(try Data(contentsOf: output), data)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: directory.path).sorted(), ["link.json", "new.json"])
    }
    func testNewCommandsRejectInvalidTypesWithoutChangingSource() throws {
        let p = try LoadSightTests().readyProject(), before = p.root
        XCTAssertThrowsError(try ProjectEditing.apply(request("qa.review", ["id": .string("QA-01"), "complete": .string("true"), "evidence": .string("Checked")]), to: p))
        XCTAssertThrowsError(try ProjectEditing.apply(request("proposal.update", ["source": .string("Fixture"), "fields": .object(["address": .number(123)])]), to: p))
        XCTAssertThrowsError(try ProjectEditing.apply(request("attachment.add", ["filename": .string("a.txt"), "dataBase64": .string("invalid!"), "source": .string("Fixture"), "rfiID": .null]), to: p))
        XCTAssertThrowsError(try ProjectEditing.apply(request("item.review", ["id": .string("D1"), "scope": .string("Base"), "status": .string("Definitely done"), "allowanceNote": .string(""), "evidence": .string("Fixture")]), to: p))
        XCTAssertEqual(p.root, before)
    }
}
