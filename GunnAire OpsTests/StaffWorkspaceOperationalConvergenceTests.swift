import Foundation
import CloudKit
import XCTest
@testable import GunnAire_Ops

final class StaffWorkspaceOperationalConvergenceTests: XCTestCase {
    /// Retain MainActor coordinator/handles across XCTest off-actor teardown.
    private enum ConvergenceTestRetain {
        static var coordinator: StaffWorkspaceContentCoordinator?
        static var handles: [StaffWorkspaceOperationalActivatedStore] = []
    }

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
    private func scopeContextAndPlan() throws -> (CloudKitStaffSetupController.Context, CloudKitStaffSharePlan, CloudKitStaffSharingTests) {
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
        return (context, plan, base)
    }

    private final class MemoryStore {
        var saved: [String: Data] = [:]
        var store: SharedTimeLocalStore {
            .init(read: { [self] in self.saved[$0] }, write: { [self] key, value in self.saved[key] = value })
        }
    }

    @MainActor
    private func installAcceptedImportActivate(
        raw: Data, receipt: StaffWorkspaceContentReceipt,
        sealedSHA256: String, scope: CloudKitStaffSetupScope, plan: UUID,
        memory: MemoryStore
    ) throws -> (StaffWorkspaceOperationalView, StaffWorkspaceCloudSealManifest, StaffWorkspaceOperationalActivatedStore) {
        let manifest = try StaffWorkspaceCloudSealManifest(
            content: receipt, sealedSHA256: sealedSHA256, sealedBytes: raw.count + 28)
        _ = try StaffWorkspaceOperationalMountStore.install(
            opened: raw, manifest: manifest, store: memory.store, scope: scope, plan: plan, check: {})
        let view = try StaffWorkspaceOperationalAcceptanceStore.accept(
            store: memory.store, scope: scope, plan: plan, selectionID: receipt.selectionID)
        let imported = try StaffWorkspaceOperationalImportStore.importAccepted(
            store: memory.store, scope: scope, plan: plan, selectionID: view.selectionID)
        let activated = try StaffWorkspaceOperationalStoreActivator.activate(
            plan: imported, store: memory.store, scope: scope, planID: plan)
        return (view, manifest, activated)
    }

    @MainActor
    func testProveConvergenceHappyPathReadyStaysFalseMountUnchanged() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (context, plan, _) = try scopeContextAndPlan()
        let memory = MemoryStore()
        let sealed = String(repeating: "b", count: 64)
        let (view, head, activated) = try installAcceptedImportActivate(
            raw: raw, receipt: vector.receipt, sealedSHA256: sealed,
            scope: context.scope, plan: plan.id, memory: memory)
        ConvergenceTestRetain.handles = [activated]
        let payloadBefore = try XCTUnwrap(memory.saved[StaffWorkspaceOperationalMountStore.payloadKey(context.scope, plan.id)])

        let journal = try StaffWorkspaceOperationalConvergenceStore.prove(
            head: head, plan: plan, participantAccountHash: context.account.accountHash,
            zoneName: plan.zoneName, store: memory.store, scope: context.scope, planID: plan.id)

        XCTAssertEqual(journal.schema, StaffWorkspaceOperationalConvergenceJournal.schema)
        XCTAssertEqual(journal.state, "converged")
        XCTAssertFalse(journal.operationalWorkspaceReady)
        XCTAssertFalse(activated.journal.operationalWorkspaceReady)
        XCTAssertEqual(journal.selectionID, view.selectionID)
        XCTAssertEqual(journal.contentSHA256, view.contentSHA256)
        XCTAssertEqual(journal.sealedSHA256, sealed)
        XCTAssertEqual(journal.sourceSequence, view.sourceSequence)
        XCTAssertEqual(journal.ownerAccountHash, plan.ownerAccountHash)
        XCTAssertEqual(journal.participantAccountHash, plan.participantAccountHash)
        XCTAssertEqual(journal.zoneName, plan.zoneName)
        XCTAssertEqual(journal.shareRevision, plan.revision)
        XCTAssertEqual(memory.saved[StaffWorkspaceOperationalMountStore.payloadKey(context.scope, plan.id)], payloadBefore)
        XCTAssertFalse(vector.receipt.operationalWorkspaceReady)
    }

    @MainActor
    func testRejectPrivateZoneAndWrongOwnerAccountHash() async throws {
        let base = CloudKitStaffSharingTests()
        let plan = try base.plan()
        let privateZone = CKRecordZone.ID(zoneName: plan.zoneName, ownerName: CKCurrentUserDefaultName)
        let privateIO = StaffReplicaCloudIO(zone: privateZone, authorize: {}, read: { _ in [:] }, save: { _ in })
        XCTAssertThrowsError(try StaffWorkspaceOperationalConvergenceStore.requireParticipantZone(privateIO, plan: plan)) { error in
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .access)
        }

        let wrongOwnerZone = CKRecordZone.ID(zoneName: plan.zoneName, ownerName: "_wrong-owner-record")
        let wrongIO = StaffReplicaCloudIO(zone: wrongOwnerZone, authorize: {}, read: { _ in [:] }, save: { _ in })
        XCTAssertThrowsError(try StaffWorkspaceOperationalConvergenceStore.requireParticipantZone(wrongIO, plan: plan)) { error in
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .access)
        }

        do {
            _ = try await StaffWorkspaceCloudTransfer.participantHead(
                plan: plan, workspace: base.workspace, io: privateIO, now: base.now)
            XCTFail("private-zone participantHead must throw")
        } catch {
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .access)
        }
    }

    @MainActor
    func testRejectHeadDigestMismatch() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (context, plan, _) = try scopeContextAndPlan()
        let memory = MemoryStore()
        let sealed = String(repeating: "b", count: 64)
        let (_, _, activated) = try installAcceptedImportActivate(
            raw: raw, receipt: vector.receipt, sealedSHA256: sealed,
            scope: context.scope, plan: plan.id, memory: memory)
        ConvergenceTestRetain.handles = [activated]

        let mismatched = try StaffWorkspaceCloudSealManifest(
            content: vector.receipt, sealedSHA256: String(repeating: "c", count: 64), sealedBytes: raw.count + 28)
        XCTAssertThrowsError(try StaffWorkspaceOperationalConvergenceStore.prove(
            head: mismatched, plan: plan, participantAccountHash: context.account.accountHash,
            zoneName: plan.zoneName, store: memory.store, scope: context.scope, planID: plan.id)) { error in
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .changed)
        }
        XCTAssertNil(try StaffWorkspaceOperationalConvergenceStore.load(
            store: memory.store, scope: context.scope, plan: plan.id))
    }

    @MainActor
    func testRejectMissingActivatedStore() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (context, plan, _) = try scopeContextAndPlan()
        let memory = MemoryStore()
        let sealed = String(repeating: "b", count: 64)
        let manifest = try StaffWorkspaceCloudSealManifest(
            content: vector.receipt, sealedSHA256: sealed, sealedBytes: raw.count + 28)
        _ = try StaffWorkspaceOperationalMountStore.install(
            opened: raw, manifest: manifest, store: memory.store, scope: context.scope, plan: plan.id, check: {})
        _ = try StaffWorkspaceOperationalAcceptanceStore.accept(
            store: memory.store, scope: context.scope, plan: plan.id, selectionID: vector.receipt.selectionID)
        _ = try StaffWorkspaceOperationalImportStore.importAccepted(
            store: memory.store, scope: context.scope, plan: plan.id, selectionID: vector.receipt.selectionID)

        XCTAssertThrowsError(try StaffWorkspaceOperationalConvergenceStore.prove(
            head: manifest, plan: plan, participantAccountHash: context.account.accountHash,
            zoneName: plan.zoneName, store: memory.store, scope: context.scope, planID: plan.id)) { error in
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .pending)
        }
    }

    @MainActor
    func testIdempotentReProveSameHead() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (context, plan, _) = try scopeContextAndPlan()
        let memory = MemoryStore()
        let sealed = String(repeating: "b", count: 64)
        let (_, head, activated) = try installAcceptedImportActivate(
            raw: raw, receipt: vector.receipt, sealedSHA256: sealed,
            scope: context.scope, plan: plan.id, memory: memory)
        ConvergenceTestRetain.handles = [activated]

        let first = try StaffWorkspaceOperationalConvergenceStore.prove(
            head: head, plan: plan, participantAccountHash: context.account.accountHash,
            zoneName: plan.zoneName, store: memory.store, scope: context.scope, planID: plan.id)
        let journalBytes = try XCTUnwrap(memory.saved[StaffWorkspaceOperationalConvergenceStore.key(context.scope, plan.id)])
        let second = try StaffWorkspaceOperationalConvergenceStore.prove(
            head: head, plan: plan, participantAccountHash: context.account.accountHash,
            zoneName: plan.zoneName, store: memory.store, scope: context.scope, planID: plan.id)
        XCTAssertEqual(first, second)
        XCTAssertEqual(memory.saved[StaffWorkspaceOperationalConvergenceStore.key(context.scope, plan.id)], journalBytes)
        XCTAssertFalse(second.operationalWorkspaceReady)
        let loaded = try XCTUnwrap(StaffWorkspaceOperationalConvergenceStore.load(
            store: memory.store, scope: context.scope, plan: plan.id))
        XCTAssertEqual(loaded, first)
    }

    @MainActor
    func testCoordinatorProvePathWithParticipantCloudIO() async throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (context, plan, base) = try scopeContextAndPlan()
        let memory = MemoryStore()
        let sealed = String(repeating: "b", count: 64)
        let (_, head, activated) = try installAcceptedImportActivate(
            raw: raw, receipt: vector.receipt, sealedSHA256: sealed,
            scope: context.scope, plan: plan.id, memory: memory)
        let payloadBefore = try XCTUnwrap(memory.saved[StaffWorkspaceOperationalMountStore.payloadKey(context.scope, plan.id)])

        let sharedZone = CKRecordZone.ID(zoneName: plan.zoneName, ownerName: base.ownerName)
        let headRecord = try StaffWorkspaceCloudRecords.make(head, plan: plan, zone: sharedZone)
        let participantIO = StaffReplicaCloudIO(zone: sharedZone, authorize: {}, read: { ids in
            var result: [CKRecord.ID: CKRecord] = [:]
            for id in ids where id.recordName == StaffWorkspaceCloudRecords.headName {
                result[id] = headRecord
            }
            return result
        }, save: { _ in XCTFail("Convergence must not write CloudKit") })

        let invitation = URL(string: "https://www.icloud.com/share/fixture-convergence-v1")!
        var serverAllows = true
        ConvergenceTestRetain.coordinator = StaffWorkspaceContentCoordinator(dependencies: .init(
            setup: { (context, [plan]) },
            check: { _ in throw StaffReplicaDeliveryError.access },
            request: { _, _, _ in throw StaffReplicaDeliveryError.access },
            store: memory.store,
            ownerCloudIO: nil,
            participantCloudIO: { _, _, _, _ in participantIO },
            invitationURL: { _, _ in invitation },
            staffRequest: { _ in
                guard serverAllows else { throw StaffReplicaDeliveryError.access }
                return try StaffWorkspacePublicationContract.encode(StaffWorkspaceCloudSealResponse(
                    schema: StaffWorkspaceCloudSealResponse.schema, content: vector.receipt,
                    sealedSHA256: sealed, sealedBytes: raw.count + 28,
                    keyBase64: Data(repeating: 1, count: 32).base64EncodedString(),
                    nonceBase64: Data(repeating: 2, count: 12).base64EncodedString()))
            },
            now: { base.now }))
        ConvergenceTestRetain.handles = [activated]

        let journal = try await ConvergenceTestRetain.coordinator!.proveIndependentCloudKitConvergence(
            plan: plan, context: context, invitation: invitation)
        XCTAssertEqual(journal.schema, StaffWorkspaceOperationalConvergenceJournal.schema)
        XCTAssertEqual(journal.state, "converged")
        XCTAssertFalse(journal.operationalWorkspaceReady)
        XCTAssertEqual(journal.sealedSHA256, sealed)
        XCTAssertEqual(journal.ownerAccountHash, plan.ownerAccountHash)
        XCTAssertEqual(memory.saved[StaffWorkspaceOperationalMountStore.payloadKey(context.scope, plan.id)], payloadBefore)

        let loaded = try XCTUnwrap(ConvergenceTestRetain.coordinator!.loadIndependentCloudKitConvergence(
            plan: plan, context: context))
        XCTAssertEqual(loaded, journal)
        XCTAssertFalse(loaded.operationalWorkspaceReady)

        let retained = memory.saved
        serverAllows = false
        do {
            _ = try await ConvergenceTestRetain.coordinator!.proveIndependentCloudKitConvergence(plan: plan, context: context, invitation: invitation)
            XCTFail("A stored convergence journal must not bypass server authority")
        } catch { XCTAssertEqual(error as? StaffReplicaDeliveryError, .access) }
        XCTAssertEqual(memory.saved, retained)

        // Private-zone IO rejected through coordinator.
        let privateZone = CKRecordZone.ID(zoneName: plan.zoneName, ownerName: CKCurrentUserDefaultName)
        let privateIO = StaffReplicaCloudIO(zone: privateZone, authorize: {}, read: { _ in [:] },
                                            save: { _ in XCTFail("must not save") })
        let denied = StaffWorkspaceContentCoordinator(dependencies: .init(
            setup: { (context, [plan]) },
            check: { _ in throw StaffReplicaDeliveryError.access },
            request: { _, _, _ in throw StaffReplicaDeliveryError.access },
            store: memory.store,
            participantCloudIO: { _, _, _, _ in privateIO },
            invitationURL: { _, _ in invitation },
            now: { base.now }))
        do {
            _ = try await denied.proveIndependentCloudKitConvergence(
                plan: plan, context: context, invitation: invitation)
            XCTFail("private-zone coordinator prove must throw")
        } catch {
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .access)
        }
    }
}
