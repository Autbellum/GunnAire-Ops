import Foundation
import XCTest
@testable import GunnAire_Ops

@MainActor final class StaffWorkspaceFieldUpdatesWireTests: XCTestCase {
    func responses() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "StaffFieldUpdatesWireInterop", withExtension: "json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    func testActualBackendWaitingKeptAppliedAndEmptyPagesUseClosedNativeContract() throws {
        let f = try StaffWorkspaceCommandRecoveryTests.Fixture(); defer { f.cleanup() }
        let responses = try responses()
        for (name, object) in responses {
            let raw = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let page = try StaffWorkspacePublicationContract.decode(StaffWorkspaceFieldUpdatesPage.self, from: raw,
                maximum: StaffWorkspaceFieldUpdatesPage.maximumBytes)
            let plan = try JSONDecoder().decode(CloudKitStaffSharePlan.self, from: f.base.modified(f.plan,
                ["id": page.shareID, "companyID": page.companyID, "replicaID": page.replicaID]))
            let waitingKey = name.hasPrefix("kept") ? "keptWaiting" : "appliedWaiting"
            let waiting = try StaffWorkspacePublicationContract.decode(StaffWorkspaceFieldUpdatesPage.self,
                from: JSONSerialization.data(withJSONObject: XCTUnwrap(responses[waitingKey])))
            let original = try XCTUnwrap(waiting.entries.first)
            let scope = CloudKitStaffSetupScope(origin: f.context.scope.origin,
                company: try XCTUnwrap(UUID(uuidString: page.companyID)), email: original.receipt.actorEmail,
                environment: page.environment, accountHash: f.context.scope.accountHash)
            try page.validate(scope: scope, plan: plan)
            XCTAssertTrue(page.nextCursor.isEmpty)
            if name.hasSuffix("Empty") {
                XCTAssertTrue(page.entries.isEmpty)
            } else {
                let entry = try XCTUnwrap(page.entries.first)
                XCTAssertEqual(entry.request, original.request)
                XCTAssertEqual(entry.receipt, original.receipt)
                XCTAssertEqual(entry.state, name.hasSuffix("Waiting") ? "awaitingOffice" : (name == "kept" ? "keptOffice" : "appliedToOffice"))
            }
        }
    }
    func testPythonWireCannotAddOwnerFieldsOrReplaceEmptyCursorWithNull() throws {
        let responses = try responses()
        var root = try XCTUnwrap(responses["kept"] as? [String: Any])
        root["nextCursor"] = NSNull()
        XCTAssertThrowsError(try StaffWorkspacePublicationContract.decode(StaffWorkspaceFieldUpdatesPage.self,
            from: JSONSerialization.data(withJSONObject: root)))
        root = try XCTUnwrap(responses["kept"] as? [String: Any])
        var entries = try XCTUnwrap(root["entries"] as? [[String: Any]])
        entries[0]["expectedValue"] = NSNull(); root["entries"] = entries
        XCTAssertThrowsError(try StaffWorkspacePublicationContract.decode(StaffWorkspaceFieldUpdatesPage.self,
            from: JSONSerialization.data(withJSONObject: root)))
    }
}
