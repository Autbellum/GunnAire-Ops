import Foundation
import CloudKit
import XCTest
@testable import GunnAire_Ops

final class StaffWorkspaceOperationalCommandTests: XCTestCase {
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

    @MainActor
    func testRejectUnavailableAndFinancialFields() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (scope, plan, _) = try scopeAndPlan()
        let memory = MemoryStore()
        let view = try installAccepted(raw: raw, receipt: vector.receipt, scope: scope, plan: plan.id, memory: memory)
        let candidates = try StaffWorkspaceOperationalCommandStore.candidates(from: view)
        XCTAssertFalse(candidates.contains(where: { $0.fieldName == "status" }))
        XCTAssertFalse(candidates.contains(where: { $0.recordKind == "payment" }))
        XCTAssertTrue(candidates.contains(where: { $0.recordKind == "job" && $0.fieldName == "notes" }))
        XCTAssertTrue(candidates.contains(where: { $0.recordKind == "job" && $0.fieldName == "findingsSummary" }))
        XCTAssertFalse(StaffWorkspaceOperationalCommandPolicy.isOperationsField(kind: "job", field: "status"))
        XCTAssertFalse(StaffWorkspaceOperationalCommandPolicy.isOperationsField(kind: "payment", field: "amount"))
        XCTAssertFalse(vector.receipt.operationalWorkspaceReady)
    }

    @MainActor
    func testHappyJournalAndReceiptShape() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (scope, plan, _) = try scopeAndPlan()
        let memory = MemoryStore()
        let view = try installAccepted(raw: raw, receipt: vector.receipt, scope: scope, plan: plan.id, memory: memory)
        let candidate = try XCTUnwrap(try StaffWorkspaceOperationalCommandStore.candidates(from: view)
            .first { $0.recordKind == "job" && $0.fieldName == "notes" })
        let commandID = UUID()
        let request = try StaffWorkspaceOperationalCommandRequest(
            companyID: view.companyID, environment: view.environment, replicaID: view.replicaID,
            commandID: commandID, selectionID: view.selectionID, sourceSequence: view.sourceSequence,
            contentSHA256: view.contentSHA256, candidate: candidate, value: .text("Field findings note"))
        let pending = try StaffWorkspaceOperationalCommandStore.enqueue(
            store: memory.store, scope: scope, plan: plan.id, request: request)
        XCTAssertEqual(pending.state, "pending")
        XCTAssertNil(pending.receipt)
        XCTAssertFalse(pending.operationalWorkspaceReady)

        let receipt = StaffWorkspaceOperationalCommandReceipt(
            schema: StaffWorkspaceOperationalCommandRequest.schema,
            commandID: request.commandID, selectionID: request.selectionID,
            sourceSequence: request.sourceSequence, contentSHA256: request.contentSHA256,
            recordKind: request.recordKind, recordID: request.recordID,
            expectedRevision: request.expectedRevision, fieldName: request.fieldName,
            value: request.value, actorEmail: "field.technician@gunnaire.com",
            createdAt: "2026-09-10T08:00:00Z", state: "recorded", operationalWorkspaceReady: false)
        let recorded = try StaffWorkspaceOperationalCommandStore.attachReceipt(
            store: memory.store, scope: scope, plan: plan.id, request: request, receipt: receipt)
        XCTAssertEqual(recorded.state, "recorded")
        XCTAssertEqual(recorded.receipt, receipt)
        XCTAssertFalse(recorded.operationalWorkspaceReady)
        XCTAssertTrue(try StaffWorkspaceOperationalCommandStore.listPending(
            store: memory.store, scope: scope, plan: plan.id).isEmpty)
    }

    @MainActor
    func testRevisionMismatchAndReadyAlwaysFalse() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (scope, plan, _) = try scopeAndPlan()
        let memory = MemoryStore()
        let view = try installAccepted(raw: raw, receipt: vector.receipt, scope: scope, plan: plan.id, memory: memory)
        let candidate = try XCTUnwrap(try StaffWorkspaceOperationalCommandStore.candidates(from: view)
            .first { $0.recordKind == "job" && $0.fieldName == "notes" })
        var forged = candidate
        // Build with mismatched revision via a reconstructed candidate.
        forged = .init(recordKind: candidate.recordKind, recordID: candidate.recordID,
                       revision: candidate.revision + 1, fieldName: candidate.fieldName,
                       currentValue: candidate.currentValue)
        let request = try StaffWorkspaceOperationalCommandRequest(
            companyID: view.companyID, environment: view.environment, replicaID: view.replicaID,
            commandID: UUID(), selectionID: view.selectionID, sourceSequence: view.sourceSequence,
            contentSHA256: view.contentSHA256, candidate: forged, value: .text("stale revision"))
        XCTAssertNotEqual(request.expectedRevision, candidate.revision)

        let okRequest = try StaffWorkspaceOperationalCommandRequest(
            companyID: view.companyID, environment: view.environment, replicaID: view.replicaID,
            commandID: UUID(), selectionID: view.selectionID, sourceSequence: view.sourceSequence,
            contentSHA256: view.contentSHA256, candidate: candidate, value: .text("ok"))
        var receipt = StaffWorkspaceOperationalCommandReceipt(
            schema: StaffWorkspaceOperationalCommandRequest.schema,
            commandID: okRequest.commandID, selectionID: okRequest.selectionID,
            sourceSequence: okRequest.sourceSequence, contentSHA256: okRequest.contentSHA256,
            recordKind: okRequest.recordKind, recordID: okRequest.recordID,
            expectedRevision: okRequest.expectedRevision, fieldName: okRequest.fieldName,
            value: okRequest.value, actorEmail: "field.technician@gunnaire.com",
            createdAt: "2026-09-10T08:00:00Z", state: "recorded", operationalWorkspaceReady: true)
        XCTAssertThrowsError(try receipt.validate(against: okRequest))
        receipt = StaffWorkspaceOperationalCommandReceipt(
            schema: StaffWorkspaceOperationalCommandRequest.schema,
            commandID: okRequest.commandID, selectionID: okRequest.selectionID,
            sourceSequence: okRequest.sourceSequence, contentSHA256: okRequest.contentSHA256,
            recordKind: okRequest.recordKind, recordID: okRequest.recordID,
            expectedRevision: okRequest.expectedRevision, fieldName: okRequest.fieldName,
            value: okRequest.value, actorEmail: "field.technician@gunnaire.com",
            createdAt: "2026-09-10T08:00:00Z", state: "recorded", operationalWorkspaceReady: false)
        try receipt.validate(against: okRequest)
        XCTAssertFalse(receipt.operationalWorkspaceReady)
        XCTAssertFalse(vector.receipt.operationalWorkspaceReady)
    }

    @MainActor
    func testIdempotentLocalJournal() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (scope, plan, _) = try scopeAndPlan()
        let memory = MemoryStore()
        let view = try installAccepted(raw: raw, receipt: vector.receipt, scope: scope, plan: plan.id, memory: memory)
        let candidate = try XCTUnwrap(try StaffWorkspaceOperationalCommandStore.candidates(from: view)
            .first { $0.recordKind == "location" && $0.fieldName == "accessNotes" })
        let commandID = UUID()
        let request = try StaffWorkspaceOperationalCommandRequest(
            companyID: view.companyID, environment: view.environment, replicaID: view.replicaID,
            commandID: commandID, selectionID: view.selectionID, sourceSequence: view.sourceSequence,
            contentSHA256: view.contentSHA256, candidate: candidate, value: .text("Gate code 1234"))
        let first = try StaffWorkspaceOperationalCommandStore.enqueue(
            store: memory.store, scope: scope, plan: plan.id, request: request)
        let again = try StaffWorkspaceOperationalCommandStore.enqueue(
            store: memory.store, scope: scope, plan: plan.id, request: request)
        XCTAssertEqual(first, again)
        // Different body same commandID must fail closed at enqueue when journal exists.
        let other = try StaffWorkspaceOperationalCommandRequest(
            companyID: view.companyID, environment: view.environment, replicaID: view.replicaID,
            commandID: commandID, selectionID: view.selectionID, sourceSequence: view.sourceSequence,
            contentSHA256: view.contentSHA256, candidate: candidate, value: .text("Different note"))
        XCTAssertThrowsError(try StaffWorkspaceOperationalCommandStore.enqueue(
            store: memory.store, scope: scope, plan: plan.id, request: other))
    }

    @MainActor
    func testHTTPPolicyAdmitsCommandsPost() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (scope, plan, _) = try scopeAndPlan()
        let memory = MemoryStore()
        let view = try installAccepted(raw: raw, receipt: vector.receipt, scope: scope, plan: plan.id, memory: memory)
        let candidate = try XCTUnwrap(try StaffWorkspaceOperationalCommandStore.candidates(from: view)
            .first { $0.recordKind == "job" && $0.fieldName == "findingsSummary" })
        let request = try StaffWorkspaceOperationalCommandRequest(
            companyID: view.companyID, environment: view.environment, replicaID: view.replicaID,
            commandID: UUID(), selectionID: view.selectionID, sourceSequence: view.sourceSequence,
            contentSHA256: view.contentSHA256, candidate: candidate, value: .text("Compressor amps high"))
        let body = try StaffWorkspacePublicationContract.encode(request)
        let path = StaffWorkspaceContentHTTPPolicy.root(plan) + "/" + view.selectionID + "/content/commands"
        XCTAssertTrue(StaffWorkspaceContentHTTPPolicy.allows(path: path, method: "POST", body: body))
        XCTAssertFalse(StaffWorkspaceContentHTTPPolicy.allows(path: path, method: "GET", body: nil))
        XCTAssertFalse(StaffWorkspaceContentHTTPPolicy.allows(path: path + "?companyID=" + view.companyID,
                                                              method: "POST", body: body))
    }
}
