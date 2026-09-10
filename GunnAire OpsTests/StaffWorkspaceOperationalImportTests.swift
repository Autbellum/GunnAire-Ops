import Foundation
import CloudKit
import XCTest
@testable import GunnAire_Ops

final class StaffWorkspaceOperationalImportTests: XCTestCase {
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
    func testImportPreservesUnavailablePartitionWithoutDefaults() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (scope, plan, _) = try scopeAndPlan()
        let memory = MemoryStore()
        let view = try installAccepted(raw: raw, receipt: vector.receipt, scope: scope, plan: plan.id, memory: memory)
        let payloadBefore = try XCTUnwrap(memory.saved[StaffWorkspaceOperationalMountStore.payloadKey(scope, plan.id)])

        let imported = try StaffWorkspaceOperationalImportStore.importAccepted(
            store: memory.store, scope: scope, plan: plan.id, selectionID: view.selectionID)
        XCTAssertEqual(imported.schema, StaffWorkspaceOperationalImportJournal.schema)
        XCTAssertFalse(imported.operationalWorkspaceReady)
        XCTAssertEqual(imported.recordCount, view.records.count)
        XCTAssertEqual(imported.contentSHA256, view.contentSHA256)

        let journal = try XCTUnwrap(StaffWorkspaceOperationalImportStore.load(
            store: memory.store, scope: scope, plan: plan.id))
        XCTAssertEqual(journal.state, "imported")
        XCTAssertFalse(journal.operationalWorkspaceReady)
        XCTAssertEqual(journal.recordCount, imported.recordCount)

        let attachment = try XCTUnwrap(imported.record(kind: "attachment", id: try XCTUnwrap(
            view.records.first { $0.kind == "attachment" }?.id)))
        let unavailable = StaffWorkspaceOperationalImportReadAdapter.unavailableFields(for: attachment)
        XCTAssertFalse(unavailable.isEmpty)
        XCTAssertEqual(unavailable["quickBooksAttachableID"], .serviceOnly)
        let display = try StaffWorkspaceOperationalImportReadAdapter.displayFields(for: attachment)
        XCTAssertNil(display["quickBooksAttachableID"])
        XCTAssertTrue(Set(display.keys).isDisjoint(with: Set(unavailable.keys)))

        let invoice = try XCTUnwrap(imported.records.first { $0.kind == "invoice" })
        guard case let .billing(document) = invoice.body else {
            return XCTFail("invoice must keep typed billing body")
        }
        XCTAssertEqual(document.unavailableFields["quickBooksID"], .roleRestricted)
        XCTAssertNil(document.fields["quickBooksID"])
        // Mount bytes untouched.
        XCTAssertEqual(memory.saved[StaffWorkspaceOperationalMountStore.payloadKey(scope, plan.id)], payloadBefore)
        XCTAssertFalse(vector.receipt.operationalWorkspaceReady)
    }

    @MainActor
    func testFailWithoutAcceptanceOrMismatchedSelection() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (scope, plan, _) = try scopeAndPlan()
        let memory = MemoryStore()
        // Mount only — no acceptance journal.
        let manifest = try StaffWorkspaceCloudSealManifest(
            content: vector.receipt, sealedSHA256: String(repeating: "b", count: 64), sealedBytes: raw.count + 28)
        _ = try StaffWorkspaceOperationalMountStore.install(
            opened: raw, manifest: manifest, store: memory.store, scope: scope, plan: plan.id, check: {})
        XCTAssertThrowsError(try StaffWorkspaceOperationalImportStore.importAccepted(
            store: memory.store, scope: scope, plan: plan.id)) { error in
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .pending)
        }
        XCTAssertNil(try StaffWorkspaceOperationalImportStore.load(store: memory.store, scope: scope, plan: plan.id))

        // Accept, then mismatched selection digest must fail closed.
        _ = try StaffWorkspaceOperationalAcceptanceStore.accept(
            store: memory.store, scope: scope, plan: plan.id, selectionID: vector.receipt.selectionID)
        let foreign = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try StaffWorkspaceOperationalImportStore.importAccepted(
            store: memory.store, scope: scope, plan: plan.id, selectionID: foreign)) { error in
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .changed)
        }
        XCTAssertNil(try StaffWorkspaceOperationalImportStore.load(store: memory.store, scope: scope, plan: plan.id))
    }

    @MainActor
    func testIdempotentReImportSameHead() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (scope, plan, _) = try scopeAndPlan()
        let memory = MemoryStore()
        let view = try installAccepted(raw: raw, receipt: vector.receipt, scope: scope, plan: plan.id, memory: memory)
        let first = try StaffWorkspaceOperationalImportStore.importAccepted(
            store: memory.store, scope: scope, plan: plan.id, selectionID: view.selectionID)
        let journalBytes = try XCTUnwrap(memory.saved[StaffWorkspaceOperationalImportStore.key(scope, plan.id)])
        let second = try StaffWorkspaceOperationalImportStore.importAccepted(
            store: memory.store, scope: scope, plan: plan.id, selectionID: view.selectionID)
        XCTAssertEqual(first.recordCount, second.recordCount)
        XCTAssertEqual(first.contentSHA256, second.contentSHA256)
        XCTAssertEqual(memory.saved[StaffWorkspaceOperationalImportStore.key(scope, plan.id)], journalBytes)
        let loaded = try XCTUnwrap(StaffWorkspaceOperationalImportStore.loadPlan(
            store: memory.store, scope: scope, plan: plan.id))
        XCTAssertEqual(loaded.contentSHA256, first.contentSHA256)
        XCTAssertFalse(loaded.operationalWorkspaceReady)
    }

    @MainActor
    func testRefuseWhenMountHeadSuperseded() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (scope, plan, _) = try scopeAndPlan()
        let memory = MemoryStore()
        let view = try installAccepted(raw: raw, receipt: vector.receipt, scope: scope, plan: plan.id, memory: memory)
        _ = try StaffWorkspaceOperationalImportStore.importAccepted(
            store: memory.store, scope: scope, plan: plan.id, selectionID: view.selectionID)

        // Advance mount to a newer sourceSequence with new content digest.
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
        // The server creates a new immutable selection when its source advances.
        let newerReceipt = try JSONDecoder().decode(StaffWorkspaceContentReceipt.self,
                                                    from: JSONSerialization.data(withJSONObject: receiptObject))
        let newerManifest = try StaffWorkspaceCloudSealManifest(
            content: newerReceipt, sealedSHA256: String(repeating: "c", count: 64),
            sealedBytes: newerRaw.count + 28)
        _ = try StaffWorkspaceOperationalMountStore.install(
            opened: newerRaw, manifest: newerManifest, store: memory.store, scope: scope, plan: plan.id, check: {})

        // Acceptance still points at old head → import must refuse superseded.
        XCTAssertThrowsError(try StaffWorkspaceOperationalImportStore.importAccepted(
            store: memory.store, scope: scope, plan: plan.id)) { error in
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .superseded)
        }
        // loadPlan against superseded journal also refuses.
        XCTAssertThrowsError(try StaffWorkspaceOperationalImportStore.loadPlan(
            store: memory.store, scope: scope, plan: plan.id)) { error in
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .superseded)
        }
        // Mount payload is the newer head — import did not rewrite it back.
        XCTAssertEqual(try StaffWorkspaceOperationalMountStore.load(store: memory.store, scope: scope, plan: plan.id)?.1, newerRaw)
        XCTAssertEqual(memory.saved[StaffWorkspaceOperationalMountStore.payloadKey(scope, plan.id)], raw)
    }

    @MainActor
    func testWritePathRecordsCommandIntentOnlyWithoutMutatingMount() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (scope, plan, _) = try scopeAndPlan()
        let memory = MemoryStore()
        let view = try installAccepted(raw: raw, receipt: vector.receipt, scope: scope, plan: plan.id, memory: memory)
        let imported = try StaffWorkspaceOperationalImportStore.importAccepted(
            store: memory.store, scope: scope, plan: plan.id, selectionID: view.selectionID)
        let payloadBefore = try XCTUnwrap(memory.saved[StaffWorkspaceOperationalMountStore.payloadKey(scope, plan.id)])

        let job = try XCTUnwrap(imported.records.first { $0.kind == "job" })
        let intent = try StaffWorkspaceOperationalImportWriteAdapter.commandIntent(
            plan: imported, recordKind: "job", recordID: job.id, fieldName: "notes",
            value: .text("Import-adapter field intent"), commandID: UUID())
        XCTAssertEqual(intent.schema, StaffWorkspaceOperationalCommandRequest.schema)
        XCTAssertEqual(intent.selectionID, imported.selectionID)
        XCTAssertEqual(intent.contentSHA256, imported.contentSHA256)
        XCTAssertEqual(intent.fieldName, "notes")

        // Enqueue through existing command store — deferred HTTP submit stays on
        // submitOperationalCommand / submitImportedOperationalWrite.
        let pending = try StaffWorkspaceOperationalCommandStore.enqueue(
            store: memory.store, scope: scope, plan: plan.id, request: intent)
        XCTAssertEqual(pending.state, "pending")
        XCTAssertFalse(pending.operationalWorkspaceReady)
        XCTAssertEqual(memory.saved[StaffWorkspaceOperationalMountStore.payloadKey(scope, plan.id)], payloadBefore)

        // Unavailable / financial fields refuse.
        XCTAssertThrowsError(try StaffWorkspaceOperationalImportWriteAdapter.commandIntent(
            plan: imported, recordKind: "job", recordID: job.id, fieldName: "status",
            value: .text("forged"), commandID: UUID()))
        XCTAssertThrowsError(try StaffWorkspaceOperationalImportWriteAdapter.commandIntent(
            plan: imported, recordKind: "payment", recordID: UUID().uuidString.lowercased(),
            fieldName: "amount", value: .number(1), commandID: UUID()))
        XCTAssertEqual(memory.saved[StaffWorkspaceOperationalMountStore.payloadKey(scope, plan.id)], payloadBefore)
    }

    @MainActor
    func testImportJournalKeepsOperationalWorkspaceReadyFalse() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (scope, plan, _) = try scopeAndPlan()
        let memory = MemoryStore()
        let view = try installAccepted(raw: raw, receipt: vector.receipt, scope: scope, plan: plan.id, memory: memory)
        let imported = try StaffWorkspaceOperationalImportStore.importAccepted(
            store: memory.store, scope: scope, plan: plan.id)
        XCTAssertFalse(imported.operationalWorkspaceReady)
        let journal = try XCTUnwrap(StaffWorkspaceOperationalImportStore.load(
            store: memory.store, scope: scope, plan: plan.id))
        XCTAssertFalse(journal.operationalWorkspaceReady)
        XCTAssertEqual(journal.schema, "staff-workspace-operational-import-v1")
        XCTAssertFalse(vector.receipt.operationalWorkspaceReady)

        // Read adapter from plan-backed container (no live ModelContainer yet).
        // Store-v1 activation attaches a dedicated projection container separately.
        // Coordinator import/load is covered by Acceptance + Store tests (MainActor
        // coordinator locals can abort under XCTest off-actor teardown).
        let container = StaffWorkspaceOperationalImportContainer(plan: imported)
        XCTAssertFalse(container.modelContainerPresent)
        let fetched = try StaffWorkspaceOperationalImportReadAdapter.fetch(container: container, kind: "job")
        XCTAssertFalse(fetched.isEmpty)
        XCTAssertEqual(imported.schema, "staff-workspace-operational-import-v1")
    }
}
