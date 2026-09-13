import XCTest
import LoadSightKit
import LoadSightUI

final class OpsProjectContextTests: XCTestCase {
    private let customerID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private func context(job: Bool = true, name: String = "Synthetic customer") -> OpsProjectContext {
        OpsProjectContext(customer: .init(id: customerID, name: name, address: "Synthetic billing address"), job: job ? .init(id: UUID(uuidString: "20000000-0000-4000-8000-000000000001")!, customerID: customerID, title: "Synthetic site visit", siteAddress: "Synthetic job site", serviceLocationID: nil) : nil)
    }
    func testLinkCorrectionAndRemovalPreserveSnapshotsAndCommercialInputs() throws {
        var p = try LoadSightTests().readyProject()
        let originalInputs = p.root["inputs"], originalItems = p.root["items"], first = context()
        try p.updateOpsContext(first, expectedFingerprint: p.opsContextEditFingerprint(), author: "Recorder", reason: "Selected existing job")
        let second = context(job: false, name: "Corrected snapshot")
        try p.updateOpsContext(second, expectedFingerprint: p.opsContextEditFingerprint(), author: "Editor", reason: "Customer only")
        try p.updateOpsContext(nil, expectedFingerprint: p.opsContextEditFingerprint(), author: "Editor", reason: "Remove incorrect link")
        XCTAssertNil(try p.opsContext())
        let history = try p.opsContextHistory(); XCTAssertEqual(history.count, 3)
        XCTAssertNil(try history[0].context(before: true))
        XCTAssertEqual(try history[1].context(before: true), first)
        XCTAssertEqual(try history[2].context(before: true), second)
        XCTAssertNil(try history[2].context(before: false))
        XCTAssertEqual(history[0].author, "Recorder"); XCTAssertEqual(history[1].reason, "Customer only")
        XCTAssertEqual(p.root["inputs"], originalInputs); XCTAssertEqual(p.root["items"], originalItems)
        XCTAssertTrue(p.root["qa"].array!.allSatisfy { $0["status"].string == "Open" })
    }
    func testCrossCustomerJobAndMissingEvidenceFailAtomically() throws {
        var p = try LoadSightTests().readyProject(); let token = try p.opsContextEditFingerprint(), original = try p.data()
        let wrong = OpsProjectContext(customer: context().customer, job: .init(id: UUID(), customerID: UUID(), title: "Wrong customer", siteAddress: "", serviceLocationID: nil))
        XCTAssertThrowsError(try p.updateOpsContext(wrong, expectedFingerprint: token, author: "Recorder", reason: "Mismatch"))
        XCTAssertThrowsError(try p.updateOpsContext(context(name: " "), expectedFingerprint: token, author: "Recorder", reason: "Missing name"))
        XCTAssertThrowsError(try p.updateOpsContext(context(), expectedFingerprint: token, author: " ", reason: "Reason"))
        XCTAssertThrowsError(try p.updateOpsContext(context(), expectedFingerprint: token, author: "Recorder", reason: ""))
        XCTAssertThrowsError(try p.updateOpsContext(nil, expectedFingerprint: token, author: "Recorder", reason: "No link"))
        XCTAssertEqual(try p.data(), original)
    }
    func testStaleAndRepeatedSelectionsUseRevisionTokens() throws {
        var p = try LoadSightTests().readyProject(); let token = try p.opsContextEditFingerprint()
        try p.replace("unrelatedExtension", with: .string("Retain this"))
        XCTAssertEqual(try p.opsContextEditFingerprint(), token)
        try p.updateOpsContext(context(), expectedFingerprint: token, author: "Recorder", reason: "Selected")
        let afterFirst = try p.opsContextEditFingerprint()
        XCTAssertThrowsError(try p.updateOpsContext(context(job: false), expectedFingerprint: token, author: "Stale", reason: "Old selection"))
        try p.updateOpsContext(context(), expectedFingerprint: afterFirst, author: "Recorder", reason: "Reconfirmed snapshot")
        XCTAssertNotEqual(try p.opsContextEditFingerprint(), afterFirst)
        XCTAssertEqual(p.root["unrelatedExtension"].string, "Retain this")
    }
    func testBrokenChainCurrentMismatchAndInvalidDatesReject() throws {
        var p = try LoadSightTests().readyProject()
        try p.updateOpsContext(context(), expectedFingerprint: p.opsContextEditFingerprint(), author: "Recorder", reason: "Linked")
        try p.updateOpsContext(context(job: false), expectedFingerprint: p.opsContextEditFingerprint(), author: "Recorder", reason: "Revised")
        let saved = try p.data()
        XCTAssertThrowsError(try p.replace("opsContext", with: .null))
        XCTAssertThrowsError(try p.replace("opsContextHistory", with: .array([])))
        var history = p.root["opsContextHistory"].array!, last = history[1].object!
        last["before"] = .null; history[1] = .object(last)
        XCTAssertThrowsError(try p.replace("opsContextHistory", with: .array(history)))
        history = p.root["opsContextHistory"].array!; last = history[1].object!; last["recordedAt"] = .string("not a date"); history[1] = .object(last)
        XCTAssertThrowsError(try p.replace("opsContextHistory", with: .array(history)))
        XCTAssertEqual(try p.data(), saved)
    }
    func testPackageAndPortableJSONRetainLinkAndHistory() throws {
        var document = LoadSightDocument()
        try document.project.updateOpsContext(context(), expectedFingerprint: document.project.opsContextEditFingerprint(), author: "Recorder", reason: "Saved project")
        for package in [true, false] {
            let restored = try LoadSightDocument(wrapper: document.wrapper(asPackage: package))
            XCTAssertEqual(try restored.project.opsContext(), context())
            XCTAssertEqual(restored.project.root["opsContextHistory"], document.project.root["opsContextHistory"])
        }
    }
    func testStructuredAPIRequiresExplicitContextAndExactKeys() throws {
        let p = try LoadSightTests().readyProject()
        var raw = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(context()))
        var object = raw.object!, job = object["job"]!.object!; job["serviceLocationID"] = .null; object["job"] = .object(job); raw = .object(object)
        var request: [String: JSONValue] = ["operation": .string("ops.context.update"), "author": .string("Plugin recorder"), "reason": .string("Supplied Ops snapshot"), "expectedFingerprint": .string(try p.opsContextEditFingerprint()), "context": raw]
        let result = try ProjectEditing.apply(.object(request), to: p).project
        XCTAssertEqual(try result.opsContext(), context())
        object["custmer"] = .null; request["context"] = .object(object)
        XCTAssertThrowsError(try ProjectEditing.apply(.object(request), to: p))
        request.removeValue(forKey: "context")
        XCTAssertThrowsError(try ProjectEditing.apply(.object(request), to: result))
        request["context"] = .null; request["expectedFingerprint"] = .string(try result.opsContextEditFingerprint())
        XCTAssertNil(try ProjectEditing.apply(.object(request), to: result).project.opsContext())
    }
}
