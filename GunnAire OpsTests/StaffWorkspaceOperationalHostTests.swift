import Foundation
import CloudKit
import XCTest
@testable import GunnAire_Ops

final class StaffWorkspaceOperationalHostTests: XCTestCase {
    /// Retain MainActor coordinator/handles across XCTest off-actor teardown.
    private enum HostTestRetain {
        static var coordinator: StaffWorkspaceContentCoordinator?
        static var handles: [StaffWorkspaceOperationalActivatedStore] = []
        static var hosted: [StaffWorkspaceOperationalHostedStore] = []
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
    private func installAcceptedImportActivateConvergeMarkReady(
        raw: Data, receipt: StaffWorkspaceContentReceipt,
        sealedSHA256: String, scope: CloudKitStaffSetupScope, plan: CloudKitStaffSharePlan,
        participantAccountHash: String, memory: MemoryStore
    ) throws -> (StaffWorkspaceOperationalView, StaffWorkspaceOperationalActivatedStore,
                 StaffWorkspaceOperationalReadyJournal) {
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
        _ = try StaffWorkspaceOperationalConvergenceStore.prove(
            head: manifest, plan: plan, participantAccountHash: participantAccountHash,
            zoneName: plan.zoneName, store: memory.store, scope: scope, planID: plan.id)
        let ready = try StaffWorkspaceOperationalReadyStore.markReady(
            plan: plan, store: memory.store, scope: scope, planID: plan.id)
        return (view, activated, ready)
    }

    @MainActor
    func testSuccessorSnapshotReopensStaffWorkspaceWithoutClearingOriginalWork() throws {
        let vector = try vector(), raw = Data(vector.payloadUtf8.utf8)
        let (context, plan, _) = try scopeContextAndPlan()
        let memory = MemoryStore()
        let (_, firstStore, _) = try installAcceptedImportActivateConvergeMarkReady(
            raw: raw, receipt: vector.receipt, sealedSHA256: String(repeating: "b", count: 64),
            scope: context.scope, plan: plan, participantAccountHash: context.account.accountHash, memory: memory)
        let first = try StaffWorkspaceOperationalHostStore.open(plan: plan, store: memory.store, scope: context.scope, planID: plan.id)
        let device = String(repeating: "d", count: 64)
        _ = try StaffWorkspaceOperationalIdentityStore.bind(plan: plan, store: memory.store, scope: context.scope,
            planID: plan.id, account: context.account, deviceFingerprint: device, hosted: first)
        HostTestRetain.handles = [firstStore]; HostTestRetain.hosted = [first]
        let originalPayload = try XCTUnwrap(memory.saved[StaffWorkspaceOperationalMountStore.payloadKey(context.scope, plan.id)])
        let stageKeys = [
            StaffWorkspaceOperationalAcceptanceStore.key(context.scope, plan.id),
            StaffWorkspaceOperationalImportStore.key(context.scope, plan.id),
            StaffWorkspaceOperationalStoreActivator.key(context.scope, plan.id),
            StaffWorkspaceOperationalConvergenceStore.key(context.scope, plan.id),
            StaffWorkspaceOperationalReadyStore.key(context.scope, plan.id),
            StaffWorkspaceOperationalHostStore.key(context.scope, plan.id),
            StaffWorkspaceOperationalIdentityStore.key(context.scope, plan.id),
        ]
        let predecessors = try stageKeys.map { try XCTUnwrap(memory.saved[$0]) }
        memory.saved["pending-field-draft-fixture"] = Data("Keep this unsent finding".utf8)
        let selection = UUID().uuidString.lowercased(), sequence = vector.receipt.sourceSequence + 1
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        object["sourceSequence"] = sequence
        var records = try XCTUnwrap(object["records"] as? [[String: Any]])
        let jobIndex = try XCTUnwrap(records.firstIndex { $0["kind"] as? String == "job" })
        let jobID = try XCTUnwrap(records[jobIndex]["id"] as? String)
        let jobRevision = try XCTUnwrap(records[jobIndex]["revision"] as? Int) + 1
        var body = try XCTUnwrap(records[jobIndex]["body"] as? [String: Any])
        var branch = try XCTUnwrap(body["operational"] as? [String: Any])
        var partition = try XCTUnwrap(branch["_0"] as? [String: Any])
        var fields = try XCTUnwrap(partition["fields"] as? [String: Any])
        fields["notes"] = ["text": ["_0": "Updated office finding"]]
        partition["fields"] = fields; branch["_0"] = partition; body["operational"] = branch
        records[jobIndex]["body"] = body; records[jobIndex]["revision"] = jobRevision
        object["records"] = records
        let nextRaw = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(vector.receipt)) as? [String: Any])
        wire["selectionID"] = selection; wire["sourceSequence"] = sequence; wire["currentSourceSequence"] = sequence
        wire["contentSHA256"] = StaffReplicaManifest.hash(nextRaw); wire["payloadBytes"] = nextRaw.count
        let receipt = try JSONDecoder().decode(StaffWorkspaceContentReceipt.self, from: JSONSerialization.data(withJSONObject: wire))
        let (_, secondStore, _) = try installAcceptedImportActivateConvergeMarkReady(
            raw: nextRaw, receipt: receipt, sealedSHA256: String(repeating: "c", count: 64),
            scope: context.scope, plan: plan, participantAccountHash: context.account.accountHash, memory: memory)
        let second = try StaffWorkspaceOperationalHostStore.open(plan: plan, store: memory.store, scope: context.scope, planID: plan.id)
        let identity = try StaffWorkspaceOperationalIdentityStore.bind(plan: plan, store: memory.store, scope: context.scope,
            planID: plan.id, account: context.account, deviceFingerprint: device, hosted: second)
        HostTestRetain.handles.append(secondStore); HostTestRetain.hosted.append(second)
        XCTAssertEqual(second.journal.sourceSequence, sequence)
        XCTAssertEqual(identity.selectionID, selection)
        XCTAssertEqual(try second.fetch().count, try first.fetch().count)
        let updatedJob = try XCTUnwrap(second.fetch(kind: "job", id: jobID).first)
        XCTAssertEqual(updatedJob.revision, jobRevision)
        guard case let .operational(updatedPartition) = updatedJob.body else {
            return XCTFail("Expected the refreshed operational job")
        }
        XCTAssertEqual(updatedPartition.fields["notes"], .text("Updated office finding"))
        XCTAssertEqual(memory.saved["pending-field-draft-fixture"], Data("Keep this unsent finding".utf8))
        XCTAssertEqual(memory.saved[StaffWorkspaceOperationalMountStore.payloadKey(context.scope, plan.id)], originalPayload)
        for (key, original) in zip(stageKeys, predecessors) {
            let archive = key + "\nprevious-generation-v1\n" + String(vector.receipt.sourceSequence) + "\n" + vector.receipt.selectionID
            XCTAssertEqual(memory.saved[archive], original, "Missing exact predecessor: \(key)")
            let current = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(memory.saved[key])) as? [String: Any])
            XCTAssertEqual(current["selectionID"] as? String, selection)
            XCTAssertEqual(current["sourceSequence"] as? Int, sequence)
        }
        let reloaded = try XCTUnwrap(StaffWorkspaceOperationalHostStore.load(plan: plan, store: memory.store, scope: context.scope, planID: plan.id))
        HostTestRetain.hosted.append(reloaded)
        XCTAssertEqual(reloaded.journal, second.journal)
    }

    @MainActor
    func testDetachedCallerReadsHostedStoreWithoutRewritingJournals() async throws {
        let vector = try vector(), raw = Data(vector.payloadUtf8.utf8)
        let (context, plan, _) = try scopeContextAndPlan()
        let memory = MemoryStore()
        let (_, activated, _) = try installAcceptedImportActivateConvergeMarkReady(
            raw: raw, receipt: vector.receipt, sealedSHA256: String(repeating: "b", count: 64),
            scope: context.scope, plan: plan, participantAccountHash: context.account.accountHash, memory: memory)
        let hosted = try StaffWorkspaceOperationalHostStore.open(plan: plan, store: memory.store, scope: context.scope, planID: plan.id)
        let before = memory.saved
        let count = try await Task.detached { try await hosted.fetch().count }.value
        XCTAssertEqual(count, activated.plan.recordCount)
        XCTAssertEqual(memory.saved, before)
        XCTAssertTrue(hosted.journal.operationalWorkspaceReady)
        XCTAssertFalse(activated.journal.operationalWorkspaceReady)
    }

    @MainActor
    func testOpenHostHappyPathPriorReadyFalseJournalsStayMountUnchanged() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (context, plan, _) = try scopeContextAndPlan()
        let memory = MemoryStore()
        let sealed = String(repeating: "b", count: 64)
        let (view, activated, ready) = try installAcceptedImportActivateConvergeMarkReady(
            raw: raw, receipt: vector.receipt, sealedSHA256: sealed,
            scope: context.scope, plan: plan, participantAccountHash: context.account.accountHash,
            memory: memory)
        HostTestRetain.handles = [activated]
        let payloadBefore = try XCTUnwrap(memory.saved[StaffWorkspaceOperationalMountStore.payloadKey(context.scope, plan.id)])
        let readyBytes = try XCTUnwrap(memory.saved[StaffWorkspaceOperationalReadyStore.key(context.scope, plan.id)])
        let storeBytes = try XCTUnwrap(memory.saved[StaffWorkspaceOperationalStoreActivator.key(context.scope, plan.id)])
        let importBytes = try XCTUnwrap(memory.saved[StaffWorkspaceOperationalImportStore.key(context.scope, plan.id)])
        let convergenceBytes = try XCTUnwrap(memory.saved[StaffWorkspaceOperationalConvergenceStore.key(context.scope, plan.id)])

        let hosted = try StaffWorkspaceOperationalHostStore.open(
            plan: plan, store: memory.store, scope: context.scope, planID: plan.id)
        HostTestRetain.hosted = [hosted]

        XCTAssertEqual(hosted.journal.schema, StaffWorkspaceOperationalHostJournal.schema)
        XCTAssertEqual(hosted.journal.state, "hosted")
        XCTAssertTrue(hosted.journal.operationalWorkspaceReady)
        XCTAssertEqual(hosted.journal.selectionID, view.selectionID)
        XCTAssertEqual(hosted.journal.contentSHA256, view.contentSHA256)
        XCTAssertEqual(hosted.journal.sealedSHA256, sealed)
        XCTAssertEqual(hosted.journal.sourceSequence, view.sourceSequence)
        XCTAssertEqual(hosted.journal.recordCount, activated.journal.recordCount)
        XCTAssertEqual(hosted.journal.selectionID, ready.selectionID)
        XCTAssertEqual(memory.saved[StaffWorkspaceOperationalMountStore.payloadKey(context.scope, plan.id)], payloadBefore)
        XCTAssertEqual(memory.saved[StaffWorkspaceOperationalReadyStore.key(context.scope, plan.id)], readyBytes)
        XCTAssertEqual(memory.saved[StaffWorkspaceOperationalStoreActivator.key(context.scope, plan.id)], storeBytes)
        XCTAssertEqual(memory.saved[StaffWorkspaceOperationalImportStore.key(context.scope, plan.id)], importBytes)
        XCTAssertEqual(memory.saved[StaffWorkspaceOperationalConvergenceStore.key(context.scope, plan.id)], convergenceBytes)

        let loadedStore = try XCTUnwrap(StaffWorkspaceOperationalStoreActivator.loadJournal(
            store: memory.store, scope: context.scope, plan: plan.id))
        XCTAssertFalse(loadedStore.operationalWorkspaceReady)
        let loadedImport = try XCTUnwrap(StaffWorkspaceOperationalImportStore.load(
            store: memory.store, scope: context.scope, plan: plan.id))
        XCTAssertFalse(loadedImport.operationalWorkspaceReady)
        let loadedConvergence = try XCTUnwrap(StaffWorkspaceOperationalConvergenceStore.load(
            store: memory.store, scope: context.scope, plan: plan.id))
        XCTAssertFalse(loadedConvergence.operationalWorkspaceReady)
        let loadedReady = try XCTUnwrap(StaffWorkspaceOperationalReadyStore.load(
            store: memory.store, scope: context.scope, plan: plan.id))
        XCTAssertTrue(loadedReady.operationalWorkspaceReady)
        XCTAssertEqual(loadedReady, ready)

        let fetched = try hosted.fetch()
        XCTAssertEqual(fetched.count, activated.plan.recordCount)
    }

    @MainActor
    func testIdempotentOpenSameHead() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (context, plan, _) = try scopeContextAndPlan()
        let memory = MemoryStore()
        let sealed = String(repeating: "b", count: 64)
        let (_, activated, _) = try installAcceptedImportActivateConvergeMarkReady(
            raw: raw, receipt: vector.receipt, sealedSHA256: sealed,
            scope: context.scope, plan: plan, participantAccountHash: context.account.accountHash,
            memory: memory)
        HostTestRetain.handles = [activated]

        let first = try StaffWorkspaceOperationalHostStore.open(
            plan: plan, store: memory.store, scope: context.scope, planID: plan.id)
        let journalBytes = try XCTUnwrap(memory.saved[StaffWorkspaceOperationalHostStore.key(context.scope, plan.id)])
        let second = try StaffWorkspaceOperationalHostStore.open(
            plan: plan, store: memory.store, scope: context.scope, planID: plan.id)
        HostTestRetain.hosted = [first, second]
        XCTAssertEqual(first.journal, second.journal)
        XCTAssertEqual(memory.saved[StaffWorkspaceOperationalHostStore.key(context.scope, plan.id)], journalBytes)
        XCTAssertTrue(second.journal.operationalWorkspaceReady)
        let loaded = try XCTUnwrap(StaffWorkspaceOperationalHostStore.load(
            plan: plan, store: memory.store, scope: context.scope, planID: plan.id))
        HostTestRetain.hosted.append(loaded)
        XCTAssertEqual(loaded.journal, first.journal)
    }

    @MainActor
    func testRejectMissingReady() throws {
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
        _ = try StaffWorkspaceOperationalConvergenceStore.prove(
            head: manifest, plan: plan, participantAccountHash: context.account.accountHash,
            zoneName: plan.zoneName, store: memory.store, scope: context.scope, planID: plan.id)
        HostTestRetain.handles = [activated]

        XCTAssertThrowsError(try StaffWorkspaceOperationalHostStore.open(
            plan: plan, store: memory.store, scope: context.scope, planID: plan.id)) { error in
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .pending)
        }
        XCTAssertNil(try StaffWorkspaceOperationalHostStore.loadJournal(
            store: memory.store, scope: context.scope, plan: plan.id))
    }

    @MainActor
    func testRejectDigestMismatchVsReady() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (context, plan, _) = try scopeContextAndPlan()
        let memory = MemoryStore()
        let sealed = String(repeating: "b", count: 64)
        let (_, activated, _) = try installAcceptedImportActivateConvergeMarkReady(
            raw: raw, receipt: vector.receipt, sealedSHA256: sealed,
            scope: context.scope, plan: plan, participantAccountHash: context.account.accountHash,
            memory: memory)
        HostTestRetain.handles = [activated]

        let mismatched = try StaffWorkspaceOperationalReadyJournal(
            scope: context.scope, planID: plan.id, selectionID: vector.receipt.selectionID,
            sourceSequence: vector.receipt.sourceSequence, contentSHA256: vector.receipt.contentSHA256,
            sealedSHA256: String(repeating: "c", count: 64), ownerAccountHash: plan.ownerAccountHash,
            participantAccountHash: plan.participantAccountHash, zoneName: plan.zoneName,
            shareRevision: plan.revision)
        memory.saved[StaffWorkspaceOperationalReadyStore.key(context.scope, plan.id)] =
            try StaffWorkspacePublicationContract.encode(mismatched)

        XCTAssertThrowsError(try StaffWorkspaceOperationalHostStore.open(
            plan: plan, store: memory.store, scope: context.scope, planID: plan.id)) { error in
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .changed)
        }
        XCTAssertNil(try StaffWorkspaceOperationalHostStore.loadJournal(
            store: memory.store, scope: context.scope, plan: plan.id))
    }

    @MainActor
    func testRejectRevokedOrIneligiblePlan() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (context, plan, base) = try scopeContextAndPlan()
        let memory = MemoryStore()
        let sealed = String(repeating: "b", count: 64)
        let (_, activated, _) = try installAcceptedImportActivateConvergeMarkReady(
            raw: raw, receipt: vector.receipt, sealedSHA256: sealed,
            scope: context.scope, plan: plan, participantAccountHash: context.account.accountHash,
            memory: memory)
        HostTestRetain.handles = [activated]

        let revoked = try base.plan([
            "state": "revoked", "revision": 5,
            "businessAccessEligible": false, "cloudKitRevocationRequired": true
        ])
        XCTAssertThrowsError(try StaffWorkspaceOperationalHostStore.open(
            plan: revoked, store: memory.store, scope: context.scope, planID: plan.id)) { error in
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .changed)
        }

        let ineligible = try base.plan([
            "businessAccessEligible": false, "reviewRequired": true, "cloudKitRevocationRequired": true
        ])
        XCTAssertThrowsError(try StaffWorkspaceOperationalHostStore.open(
            plan: ineligible, store: memory.store, scope: context.scope, planID: plan.id)) { error in
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .changed)
        }
        XCTAssertNil(try StaffWorkspaceOperationalHostStore.loadJournal(
            store: memory.store, scope: context.scope, plan: plan.id))
    }

    @MainActor
    func testRejectSupersededOlderHostHead() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (context, plan, _) = try scopeContextAndPlan()
        let memory = MemoryStore()
        let sealed = String(repeating: "b", count: 64)
        let (_, activated, ready) = try installAcceptedImportActivateConvergeMarkReady(
            raw: raw, receipt: vector.receipt, sealedSHA256: sealed,
            scope: context.scope, plan: plan, participantAccountHash: context.account.accountHash,
            memory: memory)
        HostTestRetain.handles = [activated]

        let newer = try StaffWorkspaceOperationalHostJournal(
            scope: context.scope, planID: plan.id, selectionID: ready.selectionID,
            sourceSequence: ready.sourceSequence + 1, contentSHA256: ready.contentSHA256,
            sealedSHA256: ready.sealedSHA256, recordCount: activated.journal.recordCount)
        memory.saved[StaffWorkspaceOperationalHostStore.key(context.scope, plan.id)] =
            try StaffWorkspacePublicationContract.encode(newer)

        XCTAssertThrowsError(try StaffWorkspaceOperationalHostStore.open(
            plan: plan, store: memory.store, scope: context.scope, planID: plan.id)) { error in
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .superseded)
        }
    }

    @MainActor
    func testCorruptHostJournalFailsClosed() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (context, plan, _) = try scopeContextAndPlan()
        let memory = MemoryStore()
        let sealed = String(repeating: "b", count: 64)
        let (_, activated, _) = try installAcceptedImportActivateConvergeMarkReady(
            raw: raw, receipt: vector.receipt, sealedSHA256: sealed,
            scope: context.scope, plan: plan, participantAccountHash: context.account.accountHash,
            memory: memory)
        HostTestRetain.handles = [activated]
        memory.saved[StaffWorkspaceOperationalHostStore.key(context.scope, plan.id)] = Data("not-json".utf8)

        XCTAssertThrowsError(try StaffWorkspaceOperationalHostStore.loadJournal(
            store: memory.store, scope: context.scope, plan: plan.id)) { error in
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .storage)
        }
        XCTAssertThrowsError(try StaffWorkspaceOperationalHostStore.open(
            plan: plan, store: memory.store, scope: context.scope, planID: plan.id)) { error in
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .storage)
        }
    }

    @MainActor
    func testCoordinatorOpenAndLoadPath() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (context, plan, base) = try scopeContextAndPlan()
        let memory = MemoryStore()
        let sealed = String(repeating: "b", count: 64)
        let (_, activated, ready) = try installAcceptedImportActivateConvergeMarkReady(
            raw: raw, receipt: vector.receipt, sealedSHA256: sealed,
            scope: context.scope, plan: plan, participantAccountHash: context.account.accountHash,
            memory: memory)
        let payloadBefore = try XCTUnwrap(memory.saved[StaffWorkspaceOperationalMountStore.payloadKey(context.scope, plan.id)])

        HostTestRetain.coordinator = StaffWorkspaceContentCoordinator(dependencies: .init(
            setup: { (context, [plan]) },
            check: { _ in throw StaffReplicaDeliveryError.access },
            request: { _, _, _ in throw StaffReplicaDeliveryError.access },
            store: memory.store,
            ownerCloudIO: nil,
            participantCloudIO: nil,
            invitationURL: { _, _ in URL(string: "https://www.icloud.com/share/fixture-host-v1")! },
            now: { base.now }))
        HostTestRetain.handles = [activated]

        let hosted = try HostTestRetain.coordinator!.openOperationalHost(plan: plan, context: context)
        HostTestRetain.hosted = [hosted]
        XCTAssertEqual(hosted.journal.schema, StaffWorkspaceOperationalHostJournal.schema)
        XCTAssertEqual(hosted.journal.state, "hosted")
        XCTAssertTrue(hosted.journal.operationalWorkspaceReady)
        XCTAssertEqual(hosted.journal.sealedSHA256, ready.sealedSHA256)
        XCTAssertEqual(memory.saved[StaffWorkspaceOperationalMountStore.payloadKey(context.scope, plan.id)], payloadBefore)

        let loaded = try XCTUnwrap(HostTestRetain.coordinator!.loadOperationalHost(plan: plan, context: context))
        HostTestRetain.hosted.append(loaded)
        XCTAssertEqual(loaded.journal, hosted.journal)
        XCTAssertTrue(loaded.journal.operationalWorkspaceReady)

        let readyStore = try XCTUnwrap(HostTestRetain.coordinator!.loadReadyOperationalStore(
            plan: plan, context: context))
        HostTestRetain.handles.append(readyStore)
        XCTAssertEqual(readyStore.journal.selectionID, hosted.journal.selectionID)
        XCTAssertFalse(readyStore.journal.operationalWorkspaceReady)
    }

    @MainActor
    func testReceiveControllerFailSoftHostMessage() async throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (context, plan, base) = try scopeContextAndPlan()
        let memory = MemoryStore()
        let sealed = String(repeating: "b", count: 64)
        let (_, activated, ready) = try installAcceptedImportActivateConvergeMarkReady(
            raw: raw, receipt: vector.receipt, sealedSHA256: sealed,
            scope: context.scope, plan: plan, participantAccountHash: context.account.accountHash,
            memory: memory)
        HostTestRetain.handles = [activated]
        let invitation = URL(string: "https://www.icloud.com/share/fixture-host-receive")!
        let manifest = StaffReplicaManifest(
            protocolVersion: 1, schema: StaffReplicaCoreSource.schemaVersion, coverage: StaffReplicaCoreSource.recordKinds,
            operationID: UUID(), membershipID: plan.id, companyID: plan.companyID, environment: plan.environment,
            replicaID: plan.replicaID, memberRevision: plan.memberRevision, projectionPolicy: plan.projectionPolicy,
            sourceSequence: 1, authorizationSequence: 1, payloadSHA256: String(repeating: "a", count: 64),
            payloadBytes: 16, recordCount: 0, createdAt: base.instant)

        var opened = false
        let failSoft = StaffReplicaReceiveController(dependencies: .init(
            check: { _ in },
            download: { _, _, _ in manifest },
            receiveFullWorkspace: { _, _, _ in
                .init(selectionID: ready.selectionID, alreadyLeased: false,
                      operationalMounted: true, operationalAccepted: true)
            },
            markOperationalReady: { _, _, _ in ready },
            loadOperationalReady: { _, _ in nil },
            openOperationalHost: { _, _ in
                opened = true
                throw StaffReplicaDeliveryError.pending
            },
            now: { base.now }))
        _ = await failSoft.refresh(context: context, plan: plan, invitation: invitation)
        XCTAssertTrue(opened)
        XCTAssertTrue(failSoft.message.contains("Operational workspace ready for staff projection"))
        XCTAssertFalse(failSoft.message.contains("hosted for staff projection"))

        var editingAllowed = true
        let success = StaffReplicaReceiveController(dependencies: .init(
            check: { _ in if !editingAllowed { throw StaffReplicaDeliveryError.access } },
            download: { _, _, _ in manifest },
            receiveFullWorkspace: { _, _, _ in
                .init(selectionID: ready.selectionID, alreadyLeased: false,
                      operationalMounted: true, operationalAccepted: true)
            },
            markOperationalReady: { _, _, _ in ready },
            loadOperationalReady: { _, _ in nil },
            openOperationalHost: { sharePlan, _ in
                let hosted = try StaffWorkspaceOperationalHostStore.open(
                    plan: sharePlan, store: memory.store, scope: context.scope, planID: sharePlan.id)
                HostTestRetain.hosted.append(hosted)
                return hosted
            },
            now: { base.now }))
        _ = await success.refresh(context: context, plan: plan, invitation: invitation)
        XCTAssertTrue(success.message.contains("Operational workspace hosted for staff projection"))
        let hosted = try XCTUnwrap(success.hostedStore)
        XCTAssertEqual(try success.fieldEditingAuthority(for: hosted).0.stamp, context.stamp)
        XCTAssertEqual(try success.fieldEditingAuthority(for: hosted).1, plan)
        XCTAssertThrowsError(try failSoft.fieldEditingAuthority(for: hosted))
        let otherHandle = StaffWorkspaceOperationalHostedStore(journal: hosted.journal, activated: hosted.activated)
        HostTestRetain.hosted.append(otherHandle)
        XCTAssertThrowsError(try success.fieldEditingAuthority(for: otherHandle))
        editingAllowed = false
        XCTAssertThrowsError(try success.fieldEditingAuthority(for: hosted))
        editingAllowed = true
        success.clearDisplay()
        XCTAssertThrowsError(try success.fieldEditingAuthority(for: hosted))
    }
}
