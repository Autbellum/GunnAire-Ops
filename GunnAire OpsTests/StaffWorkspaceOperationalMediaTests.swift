import Foundation
import CloudKit
import XCTest
@testable import GunnAire_Ops

final class StaffWorkspaceOperationalMediaTests: XCTestCase {
    struct Vector: Decodable {
        let receipt: StaffWorkspaceContentReceipt
        let payloadUtf8: String
    }

    private func vector() throws -> Vector {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "StaffWorkspaceContentTransportInterop",
                                                           withExtension: "json"))
        return try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
    }

    @MainActor
    private func scopeAndPlan() throws -> (CloudKitStaffSetupScope, CloudKitStaffSharePlan, CompanyWorkspaceIdentity) {
        let base = CloudKitStaffSharingTests()
        let plan = try base.plan()
        let stamp = CloudKitStaffSetupStamp(
            session: .init(backendOrigin: "https://fixture.gunnaire.invalid", email: base.member.email,
                           tokenFingerprint: String(repeating: "1", count: 64), expiresAt: base.now.addingTimeInterval(3600)),
            accountGeneration: UUID())
        let context = CloudKitStaffSetupController.Context(
            stamp: stamp, workspace: base.workspace,
            member: .init(email: base.member.email, role: plan.memberRole, isActive: true, createdAt: base.instant),
            account: .init(environment: plan.environment, accountHash: base.participantHash, recordName: base.participantName))
        return (context.scope, plan, base.workspace)
    }

    private final class MemoryStore {
        var saved: [String: Data] = [:]
        var store: SharedTimeLocalStore {
            .init(read: { [self] in self.saved[$0] }, write: { [self] key, value in self.saved[key] = value })
        }
    }

    @MainActor
    private func installAccepted(raw: Data, receipt: StaffWorkspaceContentReceipt,
                                 scope: CloudKitStaffSetupScope, plan: UUID,
                                 memory: MemoryStore) throws -> StaffWorkspaceOperationalView {
        let manifest = try StaffWorkspaceCloudSealManifest(
            content: receipt, sealedSHA256: String(repeating: "b", count: 64), sealedBytes: raw.count + 28)
        _ = try StaffWorkspaceOperationalMountStore.install(
            opened: raw, manifest: manifest, store: memory.store, scope: scope, plan: plan, check: {})
        return try StaffWorkspaceOperationalAcceptanceStore.accept(
            store: memory.store, scope: scope, plan: plan, selectionID: receipt.selectionID)
    }

    private func withDocumentID(_ raw: Data, documentID: String, fileSize: Int) throws -> (Data, StaffWorkspaceContentReceipt) {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        var records = try XCTUnwrap(root["records"] as? [[String: Any]])
        guard let index = records.firstIndex(where: { ($0["kind"] as? String) == "attachment" }) else {
            throw NSError(domain: "test", code: 1)
        }
        var attachment = records[index]
        var body = try XCTUnwrap(attachment["body"] as? [String: Any])
        var operational = try XCTUnwrap((body["operational"] as? [String: Any])?["_0"] as? [String: Any])
        var fields = try XCTUnwrap(operational["fields"] as? [String: Any])
        fields["backendDocumentID"] = ["text": ["_0": documentID]]
        fields["fileSizeBytes"] = ["integer": ["_0": fileSize]]
        operational["fields"] = fields
        body["operational"] = ["_0": operational]
        attachment["body"] = body
        records[index] = attachment
        root["records"] = records
        let forged = try JSONSerialization.data(withJSONObject: root)
        var receiptObject = try XCTUnwrap(JSONSerialization.jsonObject(
            with: StaffWorkspacePublicationContract.encode(try vector().receipt)) as? [String: Any])
        receiptObject["contentSHA256"] = StaffReplicaManifest.hash(forged)
        receiptObject["payloadBytes"] = forged.count
        let receipt = try JSONDecoder().decode(StaffWorkspaceContentReceipt.self,
                                               from: JSONSerialization.data(withJSONObject: receiptObject))
        return (forged, receipt)
    }

    @MainActor
    func testNullBackendDocumentIDIsNotMediaCapability() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (scope, plan, _) = try scopeAndPlan()
        let memory = MemoryStore()
        let view = try installAccepted(raw: raw, receipt: vector.receipt, scope: scope, plan: plan.id, memory: memory)
        let candidates = try StaffWorkspaceOperationalMediaStore.candidates(from: view)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertNil(candidates[0].backendDocumentID)
        XCTAssertThrowsError(try StaffWorkspaceOperationalMediaStore.authorize(
            store: memory.store, scope: scope, plan: plan.id, attachmentID: candidates[0].attachmentID)) { error in
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .pending)
        }
        XCTAssertNil(memory.saved[StaffWorkspaceOperationalMediaStore.key(
            scope, plan.id, attachmentID: candidates[0].attachmentID)])
        XCTAssertFalse(vector.receipt.operationalWorkspaceReady)
    }

    @MainActor
    func testAuthorizePersistsGrantAndOpensSandboxOnlyForPreparedDocument() throws {
        let vector = try vector()
        // Use a valid-looking non-path document id (not necessarily UUID).
        let preparedID = "doc-media-prepared-001"
        let bytes = Data("gunnaire-staff-media-fixture-v1".utf8)
        let (raw, receipt) = try withDocumentID(Data(vector.payloadUtf8.utf8), documentID: preparedID,
                                                fileSize: bytes.count)
        let (scope, plan, _) = try scopeAndPlan()
        let memory = MemoryStore()
        let view = try installAccepted(raw: raw, receipt: receipt, scope: scope, plan: plan.id, memory: memory)
        let candidate = try XCTUnwrap(try StaffWorkspaceOperationalMediaStore.candidates(from: view).first)
        XCTAssertEqual(candidate.backendDocumentID, preparedID)
        XCTAssertEqual(candidate.fileSizeBytes, bytes.count)

        let httpGrant = StaffWorkspaceOperationalMediaHTTPGrant(
            schema: StaffWorkspaceOperationalMediaGrant.schema, selectionID: receipt.selectionID,
            sourceSequence: receipt.sourceSequence, contentSHA256: receipt.contentSHA256,
            attachmentID: candidate.attachmentID, backendDocumentID: preparedID,
            contentType: candidate.contentType, fileSizeBytes: candidate.fileSizeBytes,
            displayName: candidate.displayName, kindRaw: candidate.kindRaw,
            operationalWorkspaceReady: false)
        let grant = try StaffWorkspaceOperationalMediaStore.authorize(
            store: memory.store, scope: scope, plan: plan.id, attachmentID: candidate.attachmentID,
            httpGrant: httpGrant)
        XCTAssertEqual(grant.schema, StaffWorkspaceOperationalMediaGrant.schema)
        XCTAssertFalse(grant.operationalWorkspaceReady)
        XCTAssertEqual(grant.backendDocumentID, preparedID)
        let again = try StaffWorkspaceOperationalMediaStore.authorize(
            store: memory.store, scope: scope, plan: plan.id, attachmentID: candidate.attachmentID,
            httpGrant: httpGrant)
        XCTAssertEqual(again, grant)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StaffMediaTests-\(UUID().uuidString)", isDirectory: true)
        let url = try StaffWorkspaceOperationalMediaStore.openSandbox(grant: grant, bytes: bytes, directory: directory)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(url.lastPathComponent, grant.displayName)
        XCTAssertThrowsError(try StaffWorkspaceOperationalMediaStore.openSandbox(
            grant: grant, bytes: Data(bytes.dropLast()), directory: directory))
    }

    @MainActor
    func testForgedHTTPGrantAndUnknownAttachmentAreRejected() throws {
        let vector = try vector()
        let preparedID = "doc-media-prepared-002"
        let bytes = Data("gunnaire-staff-media-fixture-v2".utf8)
        let (raw, receipt) = try withDocumentID(Data(vector.payloadUtf8.utf8), documentID: preparedID,
                                                fileSize: bytes.count)
        let (scope, plan, _) = try scopeAndPlan()
        let memory = MemoryStore()
        let view = try installAccepted(raw: raw, receipt: receipt, scope: scope, plan: plan.id, memory: memory)
        let candidate = try XCTUnwrap(try StaffWorkspaceOperationalMediaStore.candidates(from: view).first)

        var forged = StaffWorkspaceOperationalMediaHTTPGrant(
            schema: StaffWorkspaceOperationalMediaGrant.schema, selectionID: receipt.selectionID,
            sourceSequence: receipt.sourceSequence, contentSHA256: receipt.contentSHA256,
            attachmentID: candidate.attachmentID, backendDocumentID: preparedID,
            contentType: candidate.contentType, fileSizeBytes: candidate.fileSizeBytes,
            displayName: candidate.displayName, kindRaw: candidate.kindRaw,
            operationalWorkspaceReady: true)
        XCTAssertThrowsError(try StaffWorkspaceOperationalMediaStore.authorize(
            store: memory.store, scope: scope, plan: plan.id, attachmentID: candidate.attachmentID,
            httpGrant: forged))

        forged = StaffWorkspaceOperationalMediaHTTPGrant(
            schema: StaffWorkspaceOperationalMediaGrant.schema, selectionID: receipt.selectionID,
            sourceSequence: receipt.sourceSequence, contentSHA256: String(repeating: "a", count: 64),
            attachmentID: candidate.attachmentID, backendDocumentID: preparedID,
            contentType: candidate.contentType, fileSizeBytes: candidate.fileSizeBytes,
            displayName: candidate.displayName, kindRaw: candidate.kindRaw,
            operationalWorkspaceReady: false)
        XCTAssertThrowsError(try StaffWorkspaceOperationalMediaStore.authorize(
            store: memory.store, scope: scope, plan: plan.id, attachmentID: candidate.attachmentID,
            httpGrant: forged))

        XCTAssertThrowsError(try StaffWorkspaceOperationalMediaStore.authorize(
            store: memory.store, scope: scope, plan: plan.id,
            attachmentID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))
    }

    @MainActor
    func testHTTPPolicyAdmitsMediaPathsAndRejectsMissingAttachment() throws {
        let base = CloudKitStaffSharingTests()
        let plan = try base.plan()
        let selection = StaffWorkspaceSelectionRequest(plan: plan, sequence: 1)
        let ok = StaffWorkspaceContentHTTPPolicy.path(plan, request: selection, suffix: "/content/media",
                                                      attachmentID: selection.operationID)
        XCTAssertTrue(StaffWorkspaceContentHTTPPolicy.allows(path: ok, method: "GET", body: nil))
        let bytes = StaffWorkspaceContentHTTPPolicy.path(plan, request: selection, suffix: "/content/media/bytes",
                                                         attachmentID: selection.operationID)
        XCTAssertTrue(StaffWorkspaceContentHTTPPolicy.allows(path: bytes, method: "GET", body: nil))
        let missing = StaffWorkspaceContentHTTPPolicy.path(plan, request: selection, suffix: "/content/media")
        XCTAssertFalse(StaffWorkspaceContentHTTPPolicy.allows(path: missing, method: "GET", body: nil))
        XCTAssertFalse(StaffWorkspaceContentHTTPPolicy.allows(path: ok, method: "POST", body: Data("{}".utf8)))
    }
}
