import Foundation
import XCTest
@testable import GunnAire_Ops

@MainActor final class StaffOwnerFieldEditWireTests: XCTestCase {
    func responses() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "StaffOwnerFieldEditWireInterop", withExtension: "json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    func bytes(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }

    func testActualPythonHTTPResponsesDecodeWithoutDroppingFields() throws {
        let responses = try responses()
        for name in ["page", "emptyPage"] {
            let raw = try bytes(XCTUnwrap(responses[name]))
            XCTAssertThrowsError(try StaffWorkspacePublicationContract.decode(StaffOwnerFieldEditPage.self, from: raw), "Reproduces the old strict optional/null mismatch")
            let page = try StaffOwnerFieldEditWire.decode(StaffOwnerFieldEditPage.self, from: raw)
            XCTAssertNil(page.nextCursor)
            XCTAssertEqual(page.commandIDs.count, name == "page" ? 1 : 0)
        }
        for name in ["original", "claimed", "completed"] {
            let edit = try StaffOwnerFieldEditWire.decode(StaffOwnerFieldEdit.self, from: bytes(XCTUnwrap(responses[name])))
            try edit.request.validate(); try edit.receipt.validate(against: edit.request)
            XCTAssertNotNil(edit.current)
            XCTAssertEqual(edit.application?.state, name == "original" ? nil : (name == "claimed" ? "prepared" : "published"))
        }
        for name in ["prepared", "published"] {
            let receipt = try StaffOwnerFieldEditWire.decode(StaffOwnerFieldEditApplication.self, from: bytes(XCTUnwrap(responses[name])))
            try receipt.validate(commandID: receipt.commandID)
            XCTAssertEqual(receipt.publishedAt == nil, name == "prepared")
        }
    }

    func testUnknownNullFieldsAndDuplicateKeysRemainRejected() throws {
        let responses = try responses()
        var original = try XCTUnwrap(responses["original"] as? [String: Any])
        original["unexpected"] = NSNull()
        XCTAssertThrowsError(try StaffOwnerFieldEditWire.decode(StaffOwnerFieldEdit.self, from: bytes(original)))
        var claimed = try XCTUnwrap(responses["claimed"] as? [String: Any])
        var receipt = try XCTUnwrap(claimed["application"] as? [String: Any])
        receipt["unexpected"] = NSNull(); claimed["application"] = receipt
        XCTAssertThrowsError(try StaffOwnerFieldEditWire.decode(StaffOwnerFieldEdit.self, from: bytes(claimed)))
        let raw = try bytes(XCTUnwrap(responses["page"]))
        let duplicate = Data(("{\"nextCursor\":null," + String(decoding: raw.dropFirst(), as: UTF8.self)).utf8)
        XCTAssertThrowsError(try StaffOwnerFieldEditWire.decode(StaffOwnerFieldEditPage.self, from: duplicate))
    }

    func testActualBackendKeepOfficeReceiptAndRetainedOriginalInteroperate() throws {
        let responses = try responses()
        let edit = try StaffOwnerFieldEditWire.decode(StaffOwnerFieldEdit.self, from: bytes(XCTUnwrap(responses["retained"])))
        let receipt = try StaffOwnerFieldEditWire.decode(StaffOwnerFieldEditResolution.self, from: bytes(XCTUnwrap(responses["kept"])))
        let binding = CompanyCloudKitBinding(companyID: try XCTUnwrap(UUID(uuidString: edit.request.companyID)),
            containerID: GunnAireCloudKit.containerIdentifier, environment: edit.request.environment,
            replicaID: try XCTUnwrap(UUID(uuidString: edit.request.replicaID)), cloudAccountHash: String(repeating: "a", count: 64),
            approvedAt: "2026-09-09T00:00:00Z")
        let scope = StaffReplicaSourceScope(backendOrigin: "https://fixture.gunnaire.invalid", actorEmail: receipt.ownerEmail,
            binding: binding, storeUUID: receipt.request.ownerStoreID)
        try edit.validate(scope)
        XCTAssertEqual(edit.resolution, receipt)
        XCTAssertFalse(edit.eligible)
        XCTAssertEqual(edit.request.commandID, receipt.request.commandID)
    }

    func testNullIsNotAReplacementForRequiredFieldsOrPublishedProof() throws {
        let responses = try responses()
        for key in ["schema", "commandIDs", "companyID"] {
            var page = try XCTUnwrap(responses["page"] as? [String: Any]); page[key] = NSNull()
            XCTAssertThrowsError(try StaffOwnerFieldEditWire.decode(StaffOwnerFieldEditPage.self, from: bytes(page)))
        }
        for instant in [NSNull(), "1970-01-01T00:00:00Z"] as [Any] {
            var receipt = try XCTUnwrap(responses["published"] as? [String: Any]); receipt["publishedAt"] = instant
            let decoded = try StaffOwnerFieldEditWire.decode(StaffOwnerFieldEditApplication.self, from: bytes(receipt))
            XCTAssertThrowsError(try decoded.validate(commandID: decoded.commandID))
        }
    }

    func testLegacyJournalAndExplicitNullJournalRetainTheSameOriginals() async throws {
        let f = try StaffOwnerFieldEditTests.Fixture(); defer { f.cleanup() }
        try await f.coordinator().synchronize(f.source)
        let key = StaffOwnerFieldEditCoordinator.key(f.source.scope)
        let original = try XCTUnwrap(f.memory.saved[key])
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        root["after"] = NSNull()
        var pending = try XCTUnwrap(root["pending"] as? [String: Any])
        var item = try XCTUnwrap(pending[f.original.commandID] as? [String: Any])
        var edit = try XCTUnwrap(item["edit"] as? [String: Any]); edit["application"] = NSNull()
        item["edit"] = edit
        var application = try XCTUnwrap(item["application"] as? [String: Any]); application["publishedAt"] = NSNull()
        item["application"] = application; pending[f.original.commandID] = item; root["pending"] = pending
        f.memory.saved[key] = try bytes(root)
        try await f.coordinator().synchronize(f.source)
        XCTAssertEqual(try f.journal().pending[f.original.commandID]?.edit.receipt, f.receipt)
        XCTAssertEqual(f.applyCalls, 1)
    }
}
