import Foundation
import CloudKit
import SwiftData
import XCTest
@testable import GunnAire_Ops

final class StaffWorkspaceOperationalStoreTests: XCTestCase {
    /// Retains MainActor coordinator/handles so XCTest off-actor teardown cannot
    /// hit `swift_task_deinitOnExecutorImpl` aborts under default MainActor isolation.
    private enum StoreTestRetain {
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
    private func importReady(memory: MemoryStore, scope: CloudKitStaffSetupScope, plan: UUID,
                             selectionID: String) throws -> StaffWorkspaceOperationalImportPlan {
        try StaffWorkspaceOperationalImportStore.importAccepted(
            store: memory.store, scope: scope, plan: plan, selectionID: selectionID)
    }

    @MainActor
    func testDetachedCallerReadsActivatedStoreThroughItsActor() async throws {
        let vector = try vector(), raw = Data(vector.payloadUtf8.utf8)
        let (scope, plan, _) = try scopeAndPlan()
        let memory = MemoryStore()
        let view = try installAccepted(raw: raw, receipt: vector.receipt, scope: scope, plan: plan.id, memory: memory)
        let imported = try importReady(memory: memory, scope: scope, plan: plan.id, selectionID: view.selectionID)
        let activated = try StaffWorkspaceOperationalStoreActivator.activate(plan: imported, store: memory.store, scope: scope, planID: plan.id)
        let before = memory.saved
        let count = try await Task.detached { try await activated.fetch().count }.value
        XCTAssertEqual(count, imported.recordCount)
        XCTAssertEqual(memory.saved, before)
        XCTAssertFalse(activated.journal.operationalWorkspaceReady)
    }

    @MainActor
    func testActivatePreservesUnavailablePartitionsReadyFalseMountUnchanged() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (scope, plan, _) = try scopeAndPlan()
        let memory = MemoryStore()
        let view = try installAccepted(raw: raw, receipt: vector.receipt, scope: scope, plan: plan.id, memory: memory)
        let imported = try importReady(memory: memory, scope: scope, plan: plan.id, selectionID: view.selectionID)
        let payloadBefore = try XCTUnwrap(memory.saved[StaffWorkspaceOperationalMountStore.payloadKey(scope, plan.id)])

        let activated = try StaffWorkspaceOperationalStoreActivator.activate(
            plan: imported, store: memory.store, scope: scope, planID: plan.id)
        XCTAssertEqual(activated.journal.schema, StaffWorkspaceOperationalStoreJournal.schema)
        XCTAssertEqual(activated.journal.state, "activated")
        XCTAssertFalse(activated.journal.operationalWorkspaceReady)
        XCTAssertFalse(activated.plan.operationalWorkspaceReady)
        XCTAssertEqual(activated.journal.recordCount, imported.recordCount)
        XCTAssertEqual(activated.journal.contentSHA256, imported.contentSHA256)

        let attachment = try XCTUnwrap(activated.plan.record(kind: "attachment", id: try XCTUnwrap(
            view.records.first { $0.kind == "attachment" }?.id)))
        let unavailable = StaffWorkspaceOperationalImportReadAdapter.unavailableFields(for: attachment)
        XCTAssertFalse(unavailable.isEmpty)
        XCTAssertEqual(unavailable["quickBooksAttachableID"], .serviceOnly)
        let display = try StaffWorkspaceOperationalImportReadAdapter.displayFields(for: attachment)
        XCTAssertNil(display["quickBooksAttachableID"])
        XCTAssertTrue(Set(display.keys).isDisjoint(with: Set(unavailable.keys)))

        let fromStore = try activated.fetch(kind: "attachment", id: attachment.id)
        XCTAssertEqual(fromStore.count, 1)
        let storeUnavailable = StaffWorkspaceOperationalImportReadAdapter.unavailableFields(for: fromStore[0])
        XCTAssertEqual(storeUnavailable["quickBooksAttachableID"], .serviceOnly)
        let storeDisplay = try StaffWorkspaceOperationalImportReadAdapter.displayFields(for: fromStore[0])
        XCTAssertNil(storeDisplay["quickBooksAttachableID"])
        XCTAssertTrue(Set(storeDisplay.keys).isDisjoint(with: Set(storeUnavailable.keys)))

        XCTAssertEqual(memory.saved[StaffWorkspaceOperationalMountStore.payloadKey(scope, plan.id)], payloadBefore)
        XCTAssertFalse(vector.receipt.operationalWorkspaceReady)
    }

    @MainActor
    func testFetchViaReadAdapterWithActivatedContainerMatchesPlan() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (scope, plan, _) = try scopeAndPlan()
        let memory = MemoryStore()
        let view = try installAccepted(raw: raw, receipt: vector.receipt, scope: scope, plan: plan.id, memory: memory)
        let imported = try importReady(memory: memory, scope: scope, plan: plan.id, selectionID: view.selectionID)
        let activated = try StaffWorkspaceOperationalStoreActivator.activate(
            plan: imported, store: memory.store, scope: scope, planID: plan.id)

        let planContainer = StaffWorkspaceOperationalImportContainer(plan: imported)
        XCTAssertFalse(planContainer.modelContainerPresent)
        let fromPlan = try StaffWorkspaceOperationalImportReadAdapter.fetch(container: planContainer)

        let liveContainer = StaffWorkspaceOperationalImportContainer(plan: imported, activatedStore: activated)
        XCTAssertTrue(liveContainer.modelContainerPresent)
        let fromLive = try StaffWorkspaceOperationalImportReadAdapter.fetch(container: liveContainer)

        XCTAssertEqual(fromLive.count, fromPlan.count)
        XCTAssertEqual(Set(fromLive.map { $0.kind + ":" + $0.id }), Set(fromPlan.map { $0.kind + ":" + $0.id }))
        for record in fromPlan {
            let match = try XCTUnwrap(fromLive.first { $0.kind == record.kind && $0.id == record.id })
            XCTAssertEqual(match.revision, record.revision)
            XCTAssertEqual(match.unavailableLinks, record.unavailableLinks)
            XCTAssertEqual(match.body, record.body)
            let display = try StaffWorkspaceOperationalImportReadAdapter.displayFields(for: match)
            let unavailable = StaffWorkspaceOperationalImportReadAdapter.unavailableFields(for: match)
            XCTAssertTrue(Set(display.keys).isDisjoint(with: Set(unavailable.keys)))
        }
    }

    @MainActor
    func testFailWithoutImportAndRefuseSupersededHead() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (scope, plan, _) = try scopeAndPlan()
        let memory = MemoryStore()
        let view = try installAccepted(raw: raw, receipt: vector.receipt, scope: scope, plan: plan.id, memory: memory)

        // Acceptance alone is not enough — import journal required.
        XCTAssertThrowsError(try StaffWorkspaceOperationalStoreActivator.activate(
            store: memory.store, scope: scope, planID: plan.id)) { error in
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .pending)
        }
        XCTAssertNil(try StaffWorkspaceOperationalStoreActivator.loadJournal(
            store: memory.store, scope: scope, plan: plan.id))

        let imported = try importReady(memory: memory, scope: scope, plan: plan.id, selectionID: view.selectionID)
        _ = try StaffWorkspaceOperationalStoreActivator.activate(
            plan: imported, store: memory.store, scope: scope, planID: plan.id)

        // Advance mount past import/activation head.
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let newerSequence = view.sourceSequence + 1
        root["sourceSequence"] = newerSequence
        let newerRaw = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        var receiptObject = try XCTUnwrap(JSONSerialization.jsonObject(
            with: StaffWorkspacePublicationContract.encode(vector.receipt)) as? [String: Any])
        receiptObject["sourceSequence"] = newerSequence
        receiptObject["currentSourceSequence"] = newerSequence
        receiptObject["selectionID"] = UUID().uuidString.lowercased()
        receiptObject["contentSHA256"] = StaffReplicaManifest.hash(newerRaw)
        receiptObject["payloadBytes"] = newerRaw.count
        let newerReceipt = try JSONDecoder().decode(StaffWorkspaceContentReceipt.self,
                                                    from: JSONSerialization.data(withJSONObject: receiptObject))
        let newerManifest = try StaffWorkspaceCloudSealManifest(
            content: newerReceipt, sealedSHA256: String(repeating: "c", count: 64),
            sealedBytes: newerRaw.count + 28)
        _ = try StaffWorkspaceOperationalMountStore.install(
            opened: newerRaw, manifest: newerManifest, store: memory.store, scope: scope, plan: plan.id, check: {})

        XCTAssertThrowsError(try StaffWorkspaceOperationalStoreActivator.activate(
            store: memory.store, scope: scope, planID: plan.id)) { error in
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .superseded)
        }
        XCTAssertThrowsError(try StaffWorkspaceOperationalStoreActivator.loadActivated(
            store: memory.store, scope: scope, planID: plan.id)) { error in
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .superseded)
        }
        XCTAssertEqual(try StaffWorkspaceOperationalMountStore.load(store: memory.store, scope: scope, plan: plan.id)?.1, newerRaw)
        XCTAssertEqual(memory.saved[StaffWorkspaceOperationalMountStore.payloadKey(scope, plan.id)], raw)
    }

    @MainActor
    func testIdempotentReActivateSameHead() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (scope, plan, _) = try scopeAndPlan()
        let memory = MemoryStore()
        let view = try installAccepted(raw: raw, receipt: vector.receipt, scope: scope, plan: plan.id, memory: memory)
        let imported = try importReady(memory: memory, scope: scope, plan: plan.id, selectionID: view.selectionID)
        let first = try StaffWorkspaceOperationalStoreActivator.activate(
            plan: imported, store: memory.store, scope: scope, planID: plan.id)
        let journalBytes = try XCTUnwrap(memory.saved[StaffWorkspaceOperationalStoreActivator.key(scope, plan.id)])
        let second = try StaffWorkspaceOperationalStoreActivator.activate(
            plan: imported, store: memory.store, scope: scope, planID: plan.id)
        XCTAssertEqual(first.journal, second.journal)
        XCTAssertEqual(memory.saved[StaffWorkspaceOperationalStoreActivator.key(scope, plan.id)], journalBytes)
        XCTAssertFalse(second.journal.operationalWorkspaceReady)

        let loaded = try XCTUnwrap(StaffWorkspaceOperationalStoreActivator.loadActivated(
            store: memory.store, scope: scope, planID: plan.id))
        XCTAssertEqual(loaded.journal.contentSHA256, first.journal.contentSHA256)
        XCTAssertFalse(loaded.journal.operationalWorkspaceReady)
        let live = try StaffWorkspaceOperationalImportReadAdapter.fetch(
            container: .init(plan: imported, activatedStore: loaded), kind: "job")
        XCTAssertFalse(live.isEmpty)
    }

    @MainActor
    func testModelContainerPresentNoLongerThrowsUnavailable() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (scope, plan, _) = try scopeAndPlan()
        let memory = MemoryStore()
        let view = try installAccepted(raw: raw, receipt: vector.receipt, scope: scope, plan: plan.id, memory: memory)
        let imported = try importReady(memory: memory, scope: scope, plan: plan.id, selectionID: view.selectionID)
        let activated = try StaffWorkspaceOperationalStoreActivator.activate(
            plan: imported, store: memory.store, scope: scope, planID: plan.id)
        let container = StaffWorkspaceOperationalImportContainer(plan: imported, activatedStore: activated)
        XCTAssertTrue(container.modelContainerPresent)
        let fetched = try StaffWorkspaceOperationalImportReadAdapter.fetch(container: container)
        XCTAssertEqual(fetched.count, imported.recordCount)
        XCTAssertFalse(activated.journal.operationalWorkspaceReady)
    }

    @MainActor
    func testRefuseReconstructingRestrictedFieldsInDisplay() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (scope, plan, _) = try scopeAndPlan()
        let memory = MemoryStore()
        let view = try installAccepted(raw: raw, receipt: vector.receipt, scope: scope, plan: plan.id, memory: memory)
        let imported = try importReady(memory: memory, scope: scope, plan: plan.id, selectionID: view.selectionID)
        let activated = try StaffWorkspaceOperationalStoreActivator.activate(
            plan: imported, store: memory.store, scope: scope, planID: plan.id)
        let container = StaffWorkspaceOperationalImportContainer(plan: imported, activatedStore: activated)

        let invoice = try XCTUnwrap(try StaffWorkspaceOperationalImportReadAdapter.fetch(
            container: container, kind: "invoice").first)
        guard case let .billing(document) = invoice.body else {
            return XCTFail("invoice must keep typed billing body")
        }
        XCTAssertEqual(document.unavailableFields["quickBooksID"], .roleRestricted)
        XCTAssertNil(document.fields["quickBooksID"])
        let display = try StaffWorkspaceOperationalImportReadAdapter.displayFields(for: invoice)
        XCTAssertNil(display["quickBooksID"])
        XCTAssertTrue(Set(display.keys).isDisjoint(with: Set(document.unavailableFields.keys)))

        // Coordinator activate/load — retain on StoreTestRetain so XCTest
        // off-actor teardown cannot MainActor-deinit the coordinator.
        let base = CloudKitStaffSharingTests()
        let stamp = CloudKitStaffSetupStamp(
            session: .init(backendOrigin: "https://fixture.gunnaire.invalid", email: base.member.email,
                           tokenFingerprint: String(repeating: "1", count: 64), expiresAt: base.now.addingTimeInterval(3600)),
            accountGeneration: UUID())
        let context = CloudKitStaffSetupController.Context(
            stamp: stamp, workspace: base.workspace,
            member: .init(email: base.member.email, role: plan.memberRole, isActive: true, createdAt: base.instant),
            account: .init(environment: plan.environment, accountHash: base.participantHash, recordName: base.participantName))
        StoreTestRetain.coordinator = StaffWorkspaceContentCoordinator(dependencies: .init(
            setup: { (context, [plan]) },
            check: { _ in throw StaffReplicaDeliveryError.access },
            request: { _, _, _ in throw StaffReplicaDeliveryError.access },
            store: memory.store,
            now: { base.now }))
        let viaCoordinator = try StoreTestRetain.coordinator!.activateImportedOperationalStore(
            plan: plan, context: context)
        XCTAssertFalse(viaCoordinator.journal.operationalWorkspaceReady)
        let loaded = try XCTUnwrap(StoreTestRetain.coordinator!.loadActivatedOperationalStore(
            plan: plan, context: context))
        XCTAssertEqual(loaded.journal.contentSHA256, viaCoordinator.journal.contentSHA256)
        XCTAssertFalse(loaded.journal.operationalWorkspaceReady)
        StoreTestRetain.handles = [viaCoordinator, loaded]
    }
}
