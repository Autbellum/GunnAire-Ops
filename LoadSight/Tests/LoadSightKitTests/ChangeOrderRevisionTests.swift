import XCTest
import LoadSightKit
import LoadSightUI

final class ChangeOrderRevisionTests: XCTestCase {
    private func draft() -> ChangeOrderDraft { .init(number: "CO-1", originalScope: "Original", proposedScope: "Proposed") }
    func testRevisionRetainsIdentityCreationBasisAndBothScopes() throws {
        var p = try LoadSightTests().readyProject()
        let id = try p.createChangeOrder(draft(), author: "Creator"), token = try p.changeOrderEditFingerprint(id: id)
        let original = p.root["changeOrders"].array![0]
        var d = draft(); d.proposedScope = "Revised route"; d.tax = .init(amount: -12, source: "Credit source")
        XCTAssertEqual(try p.reviseChangeOrder(id: id, expectedFingerprint: token, draft: d, author: "Editor", reason: "Drawing revision B"), id)
        let history = try p.changeOrderHistory(); XCTAssertEqual(history.count, 1); XCTAssertEqual(history[0].before, original)
        XCTAssertEqual(history[0].author, "Editor"); XCTAssertEqual(try history[0].record(before: false).author, "Creator")
        XCTAssertEqual(try history[0].record(before: true).draft.proposedScope, "Proposed")
        XCTAssertEqual(try history[0].record(before: false).draft.tax.amount, -12)
        XCTAssertEqual(try p.changeOrders().count, 1); XCTAssertTrue(p.root["qa"].array!.allSatisfy { $0["status"].string == "Open" })
        let word = String(decoding: try ChangeOrderWordDocument.docx(p, changeOrderID: id), as: UTF8.self)
        for text in ["Recorded revisions", "Latest revision author: Editor", "Drawing revision B", "Before: Proposed", "After: Revised route", "Credit source"] { XCTAssertTrue(word.contains(text), text) }
        let restored = try ProjectDocument(data: p.data()); XCTAssertEqual(try restored.changeOrderHistory().first?.after, p.root["changeOrders"].array!.first)
    }
    func testStaleNoOpAndUnrelatedChangesRespectEditToken() throws {
        var p = try LoadSightTests().readyProject(); let id = try p.createChangeOrder(draft(), author: "Creator")
        let token = try p.changeOrderEditFingerprint(id: id)
        var other = draft(); other.number = "CO-2"; try p.createChangeOrder(other, author: "Other")
        XCTAssertEqual(try p.changeOrderEditFingerprint(id: id), token)
        try p.reviseChangeOrder(id: id, expectedFingerprint: token, draft: draft(), author: "Editor", reason: "Reaffirm supplied values")
        XCTAssertNotEqual(try p.changeOrderEditFingerprint(id: id), token)
        let saved = try p.data()
        XCTAssertThrowsError(try p.reviseChangeOrder(id: id, expectedFingerprint: token, draft: draft(), author: "Stale editor", reason: "Old form"))
        XCTAssertEqual(try p.data(), saved)
    }
    func testInvalidEditsFailAtomicallyAndOptionalFieldsCanClear() throws {
        var p = try LoadSightTests().readyProject(), d = draft(); d.entitlement = .designRevision; d.markupBasis = .signedNetCosts
        let id = try p.createChangeOrder(d, author: "Creator"), token = try p.changeOrderEditFingerprint(id: id), original = try p.data()
        XCTAssertThrowsError(try p.reviseChangeOrder(id: id, expectedFingerprint: token, draft: d, author: "", reason: "Reason"))
        XCTAssertThrowsError(try p.reviseChangeOrder(id: id, expectedFingerprint: token, draft: d, author: "Editor", reason: ""))
        d.rfiIDs = ["missing"]
        XCTAssertThrowsError(try p.reviseChangeOrder(id: id, expectedFingerprint: token, draft: d, author: "Editor", reason: "Reason")); XCTAssertEqual(try p.data(), original)
        d.rfiIDs = []; d.entitlement = nil; d.markupBasis = nil
        try p.reviseChangeOrder(id: id, expectedFingerprint: token, draft: d, author: "Editor", reason: "Basis pending")
        XCTAssertNil(try p.changeOrders()[0].draft.entitlement); XCTAssertNil(try p.changeOrders()[0].draft.markupBasis)
    }
    func testBrokenHistoryAndSnapshotDisagreementAreRejected() throws {
        var p = try LoadSightTests().readyProject(); let id = try p.createChangeOrder(draft(), author: "Creator")
        var d = draft()
        for scope in ["Second", "Third"] {
            d.proposedScope = scope
            try p.reviseChangeOrder(id: id, expectedFingerprint: p.changeOrderEditFingerprint(id: id), draft: d, author: "Editor", reason: scope)
        }
        let saved = try p.data()
        var rows = p.root["changeOrderHistory"].array!, entry = rows[1].object!
        entry["before"] = rows[0]["before"]; rows[1] = .object(entry)
        XCTAssertThrowsError(try p.replace("changeOrderHistory", with: .array(rows)))
        rows = p.root["changeOrders"].array!; rows[0] = p.root["changeOrderHistory"].array![0]["before"]
        XCTAssertThrowsError(try p.replace("changeOrders", with: .array(rows)))
        XCTAssertEqual(try p.data(), saved)
    }
    func testLoadedNativeFormKeepsNumbersSourcesAndRequiresNewAuthor() throws {
        var d = draft(); d.costs[0].delta = .init(amount: -12.125, source: "Quote")
        d.quantities = [.init(name: "Duct", unit: "LF", original: .init(amount: 12.25, source: "M1"), proposed: .init(source: "Pending M2"))]
        let state = ChangeOrderFormState(draft: d)
        XCTAssertEqual(try state.resolvedDraft(), d); XCTAssertEqual(state.author, "")
    }
}
