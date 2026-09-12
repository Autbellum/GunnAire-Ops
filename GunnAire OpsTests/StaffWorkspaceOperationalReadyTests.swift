import Foundation
import CloudKit
import XCTest
@testable import GunnAire_Ops

final class StaffWorkspaceOperationalReadyTests: XCTestCase {
    /// Retain MainActor coordinator/handles across XCTest off-actor teardown.
    private enum ReadyTestRetain {
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
    private func installAcceptedImportActivateConverge(
        raw: Data, receipt: StaffWorkspaceContentReceipt,
        sealedSHA256: String, scope: CloudKitStaffSetupScope, plan: CloudKitStaffSharePlan,
        participantAccountHash: String, memory: MemoryStore
    ) throws -> (StaffWorkspaceOperationalView, StaffWorkspaceCloudSealManifest, StaffWorkspaceOperationalActivatedStore,
                 StaffWorkspaceOperationalConvergenceJournal) {
        let manifest = try StaffWorkspaceCloudSealManifest(
            content: receipt, sealedSHA256: sealedSHA256, sealedBytes: raw.count + 28)
        _ = try StaffWorkspaceOperationalMountStore.install(
            opened: raw, manifest: manifest, store: memory.store, scope: scope, plan: plan.id, check: {})
        let view = try StaffWorkspaceOperationalAcceptanceStore.accept(
            store: memory.store, scope: scope, plan: plan.id, selectionID: receipt.selectionID)
        let imported = try StaffWorkspaceOperationalImportStore.importAccepted(
            store: memory.store, scope: scope, plan: plan.id, selectionID: view.selectionID)
        let activated = try StaffWorkspaceOperationalStoreActivator.activate(
            plan: imported, store: memory.store, scope: scope, planID: plan.id)
        let convergence = try StaffWorkspaceOperationalConvergenceStore.prove(
            head: manifest, plan: plan, participantAccountHash: participantAccountHash,
            zoneName: plan.zoneName, store: memory.store, scope: scope, planID: plan.id)
        return (view, manifest, activated, convergence)
    }

    @MainActor
    func testMarkReadyHappyPathPriorJournalsStayFalseMountUnchanged() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (context, plan, _) = try scopeContextAndPlan()
        let memory = MemoryStore()
        let sealed = String(repeating: "b", count: 64)
        let (view, _, activated, convergence) = try installAcceptedImportActivateConverge(
            raw: raw, receipt: vector.receipt, sealedSHA256: sealed,
            scope: context.scope, plan: plan, participantAccountHash: context.account.accountHash,
            memory: memory)
        ReadyTestRetain.handles = [activated]
        let payloadBefore = try XCTUnwrap(memory.saved[StaffWorkspaceOperationalMountStore.payloadKey(context.scope, plan.id)])

        let ready = try StaffWorkspaceOperationalReadyStore.markReady(
            plan: plan, store: memory.store, scope: context.scope, planID: plan.id)

        XCTAssertEqual(ready.schema, StaffWorkspaceOperationalReadyJournal.schema)
        XCTAssertEqual(ready.state, "ready")
        XCTAssertTrue(ready.operationalWorkspaceReady)
        XCTAssertEqual(ready.selectionID, view.selectionID)
        XCTAssertEqual(ready.contentSHA256, view.contentSHA256)
        XCTAssertEqual(ready.sealedSHA256, sealed)
        XCTAssertEqual(ready.sourceSequence, view.sourceSequence)
        XCTAssertEqual(ready.ownerAccountHash, plan.ownerAccountHash)
        XCTAssertEqual(ready.participantAccountHash, plan.participantAccountHash)
        XCTAssertEqual(ready.zoneName, plan.zoneName)
        XCTAssertEqual(ready.shareRevision, plan.revision)
        XCTAssertEqual(memory.saved[StaffWorkspaceOperationalMountStore.payloadKey(context.scope, plan.id)], payloadBefore)

        XCTAssertFalse(convergence.operationalWorkspaceReady)
        XCTAssertFalse(activated.journal.operationalWorkspaceReady)
        XCTAssertFalse(vector.receipt.operationalWorkspaceReady)
        let loadedConvergence = try XCTUnwrap(StaffWorkspaceOperationalConvergenceStore.load(
            store: memory.store, scope: context.scope, plan: plan.id))
        XCTAssertFalse(loadedConvergence.operationalWorkspaceReady)
        let loadedStore = try XCTUnwrap(StaffWorkspaceOperationalStoreActivator.loadJournal(
            store: memory.store, scope: context.scope, plan: plan.id))
        XCTAssertFalse(loadedStore.operationalWorkspaceReady)
        let loadedImport = try XCTUnwrap(StaffWorkspaceOperationalImportStore.load(
            store: memory.store, scope: context.scope, plan: plan.id))
        XCTAssertFalse(loadedImport.operationalWorkspaceReady)
        XCTAssertNotNil(try StaffWorkspaceOperationalAcceptanceStore.load(
            store: memory.store, scope: context.scope, plan: plan.id))

        let container = StaffWorkspaceOperationalImportContainer(
            plan: activated.plan, activatedStore: activated, readyJournal: ready)
        let fetched = try StaffWorkspaceOperationalImportReadAdapter.fetch(container: container)
        XCTAssertEqual(fetched.count, activated.plan.recordCount)
        XCTAssertTrue(container.operationalWorkspaceReady)
    }

    @MainActor
    func testIdempotentMarkReadySameHead() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (context, plan, _) = try scopeContextAndPlan()
        let memory = MemoryStore()
        let sealed = String(repeating: "b", count: 64)
        let (_, _, activated, _) = try installAcceptedImportActivateConverge(
            raw: raw, receipt: vector.receipt, sealedSHA256: sealed,
            scope: context.scope, plan: plan, participantAccountHash: context.account.accountHash,
            memory: memory)
        ReadyTestRetain.handles = [activated]

        let first = try StaffWorkspaceOperationalReadyStore.markReady(
            plan: plan, store: memory.store, scope: context.scope, planID: plan.id)
        let journalBytes = try XCTUnwrap(memory.saved[StaffWorkspaceOperationalReadyStore.key(context.scope, plan.id)])
        let second = try StaffWorkspaceOperationalReadyStore.markReady(
            plan: plan, store: memory.store, scope: context.scope, planID: plan.id)
        XCTAssertEqual(first, second)
        XCTAssertEqual(memory.saved[StaffWorkspaceOperationalReadyStore.key(context.scope, plan.id)], journalBytes)
        XCTAssertTrue(second.operationalWorkspaceReady)
        let loaded = try XCTUnwrap(StaffWorkspaceOperationalReadyStore.load(
            store: memory.store, scope: context.scope, plan: plan.id))
        XCTAssertEqual(loaded, first)
    }

    @MainActor
    func testRejectWithoutConvergence() throws {
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
        let imported = try StaffWorkspaceOperationalImportStore.importAccepted(
            store: memory.store, scope: context.scope, plan: plan.id, selectionID: vector.receipt.selectionID)
        let activated = try StaffWorkspaceOperationalStoreActivator.activate(
            plan: imported, store: memory.store, scope: context.scope, planID: plan.id)
        ReadyTestRetain.handles = [activated]

        XCTAssertThrowsError(try StaffWorkspaceOperationalReadyStore.markReady(
            plan: plan, store: memory.store, scope: context.scope, planID: plan.id)) { error in
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .pending)
        }
        XCTAssertNil(try StaffWorkspaceOperationalReadyStore.load(
            store: memory.store, scope: context.scope, plan: plan.id))
    }

    @MainActor
    func testRejectWithoutActivatedStore() throws {
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
        // Convergence requires activated store — write a synthetic convergence journal
        // so markReady reaches the missing-store check.
        let fake = try StaffWorkspaceOperationalConvergenceJournal(
            scope: context.scope, planID: plan.id, selectionID: vector.receipt.selectionID,
            sourceSequence: vector.receipt.sourceSequence, contentSHA256: vector.receipt.contentSHA256,
            sealedSHA256: sealed, ownerAccountHash: plan.ownerAccountHash,
            participantAccountHash: plan.participantAccountHash, zoneName: plan.zoneName,
            shareRevision: plan.revision)
        memory.saved[StaffWorkspaceOperationalConvergenceStore.key(context.scope, plan.id)] =
            try StaffWorkspacePublicationContract.encode(fake)

        XCTAssertThrowsError(try StaffWorkspaceOperationalReadyStore.markReady(
            plan: plan, store: memory.store, scope: context.scope, planID: plan.id)) { error in
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .pending)
        }
    }

    @MainActor
    func testRejectDigestMismatch() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (context, plan, _) = try scopeContextAndPlan()
        let memory = MemoryStore()
        let sealed = String(repeating: "b", count: 64)
        let (_, _, activated, _) = try installAcceptedImportActivateConverge(
            raw: raw, receipt: vector.receipt, sealedSHA256: sealed,
            scope: context.scope, plan: plan, participantAccountHash: context.account.accountHash,
            memory: memory)
        ReadyTestRetain.handles = [activated]

        let mismatched = try StaffWorkspaceOperationalConvergenceJournal(
            scope: context.scope, planID: plan.id, selectionID: vector.receipt.selectionID,
            sourceSequence: vector.receipt.sourceSequence, contentSHA256: vector.receipt.contentSHA256,
            sealedSHA256: String(repeating: "c", count: 64), ownerAccountHash: plan.ownerAccountHash,
            participantAccountHash: plan.participantAccountHash, zoneName: plan.zoneName,
            shareRevision: plan.revision)
        memory.saved[StaffWorkspaceOperationalConvergenceStore.key(context.scope, plan.id)] =
            try StaffWorkspacePublicationContract.encode(mismatched)

        XCTAssertThrowsError(try StaffWorkspaceOperationalReadyStore.markReady(
            plan: plan, store: memory.store, scope: context.scope, planID: plan.id)) { error in
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .changed)
        }
        XCTAssertNil(try StaffWorkspaceOperationalReadyStore.load(
            store: memory.store, scope: context.scope, plan: plan.id))
    }

    @MainActor
    func testRejectSupersededReadyHead() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (context, plan, _) = try scopeContextAndPlan()
        let memory = MemoryStore()
        let sealed = String(repeating: "b", count: 64)
        let (_, _, activated, convergence) = try installAcceptedImportActivateConverge(
            raw: raw, receipt: vector.receipt, sealedSHA256: sealed,
            scope: context.scope, plan: plan, participantAccountHash: context.account.accountHash,
            memory: memory)
        ReadyTestRetain.handles = [activated]

        let newer = try StaffWorkspaceOperationalReadyJournal(
            scope: context.scope, planID: plan.id, selectionID: convergence.selectionID,
            sourceSequence: convergence.sourceSequence + 1, contentSHA256: convergence.contentSHA256,
            sealedSHA256: convergence.sealedSHA256, ownerAccountHash: plan.ownerAccountHash,
            participantAccountHash: plan.participantAccountHash, zoneName: plan.zoneName,
            shareRevision: plan.revision)
        memory.saved[StaffWorkspaceOperationalReadyStore.key(context.scope, plan.id)] =
            try StaffWorkspacePublicationContract.encode(newer)

        XCTAssertThrowsError(try StaffWorkspaceOperationalReadyStore.markReady(
            plan: plan, store: memory.store, scope: context.scope, planID: plan.id)) { error in
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .superseded)
        }
    }

    @MainActor
    func testCoordinatorMarkAndLoadPathWithParticipantCloudIO() async throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (context, plan, base) = try scopeContextAndPlan()
        let memory = MemoryStore()
        let sealed = String(repeating: "b", count: 64)
        let (_, head, activated, _) = try installAcceptedImportActivateConverge(
            raw: raw, receipt: vector.receipt, sealedSHA256: sealed,
            scope: context.scope, plan: plan, participantAccountHash: context.account.accountHash,
            memory: memory)
        let payloadBefore = try XCTUnwrap(memory.saved[StaffWorkspaceOperationalMountStore.payloadKey(context.scope, plan.id)])

        // Drop convergence journal so coordinator mark must re-prove via participantCloudIO.
        memory.saved.removeValue(forKey: StaffWorkspaceOperationalConvergenceStore.key(context.scope, plan.id))

        let sharedZone = CKRecordZone.ID(zoneName: plan.zoneName, ownerName: base.ownerName)
        let headRecord = try StaffWorkspaceCloudRecords.make(head, plan: plan, zone: sharedZone)
        let participantIO = StaffReplicaCloudIO(zone: sharedZone, authorize: {}, read: { ids in
            var result: [CKRecord.ID: CKRecord] = [:]
            for id in ids where id.recordName == StaffWorkspaceCloudRecords.headName {
                result[id] = headRecord
            }
            return result
        }, save: { _ in XCTFail("Ready must not write CloudKit") })

        let invitation = URL(string: "https://www.icloud.com/share/fixture-ready-v1")!
        var serverAllows = true
        ReadyTestRetain.coordinator = StaffWorkspaceContentCoordinator(dependencies: .init(
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
        ReadyTestRetain.handles = [activated]

        let journal = try await ReadyTestRetain.coordinator!.markOperationalWorkspaceReady(
            plan: plan, context: context, invitation: invitation)
        XCTAssertEqual(journal.schema, StaffWorkspaceOperationalReadyJournal.schema)
        XCTAssertEqual(journal.state, "ready")
        XCTAssertTrue(journal.operationalWorkspaceReady)
        XCTAssertEqual(journal.sealedSHA256, sealed)
        XCTAssertEqual(memory.saved[StaffWorkspaceOperationalMountStore.payloadKey(context.scope, plan.id)], payloadBefore)

        let loaded = try XCTUnwrap(ReadyTestRetain.coordinator!.loadOperationalWorkspaceReady(
            plan: plan, context: context))
        XCTAssertEqual(loaded, journal)
        XCTAssertTrue(loaded.operationalWorkspaceReady)

        let readyStore = try XCTUnwrap(ReadyTestRetain.coordinator!.loadReadyOperationalStore(
            plan: plan, context: context))
        ReadyTestRetain.handles.append(readyStore)
        XCTAssertEqual(readyStore.journal.selectionID, journal.selectionID)
        XCTAssertEqual(readyStore.journal.contentSHA256, journal.contentSHA256)
        XCTAssertFalse(readyStore.journal.operationalWorkspaceReady)

        let convergence = try XCTUnwrap(ReadyTestRetain.coordinator!.loadIndependentCloudKitConvergence(
            plan: plan, context: context))
        XCTAssertFalse(convergence.operationalWorkspaceReady)
        let retained = memory.saved
        serverAllows = false
        do {
            _ = try await ReadyTestRetain.coordinator!.markOperationalWorkspaceReady(plan: plan, context: context, invitation: invitation)
            XCTFail("Readiness must recheck authorization even when convergence is already saved")
        } catch { XCTAssertEqual(error as? StaffReplicaDeliveryError, .access) }
        XCTAssertEqual(memory.saved, retained)
    }
}
