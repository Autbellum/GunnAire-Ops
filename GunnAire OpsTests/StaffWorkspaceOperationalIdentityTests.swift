import Foundation
import CloudKit
import SwiftData
import XCTest
@testable import GunnAire_Ops

final class StaffWorkspaceOperationalIdentityTests: XCTestCase {
    /// Retain MainActor coordinator/handles across XCTest off-actor teardown.
    private enum IdentityTestRetain {
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

    private func fingerprint(_ label: String = "device-a") -> String {
        CompanyWorkspaceSession.digest("gunnaire-staff-installation-v1-test\n\(label)")
    }

    @MainActor
    private func installThroughHost(
        raw: Data, receipt: StaffWorkspaceContentReceipt,
        sealedSHA256: String, scope: CloudKitStaffSetupScope, plan: CloudKitStaffSharePlan,
        participantAccountHash: String, memory: MemoryStore
    ) throws -> StaffWorkspaceOperationalHostedStore {
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
        IdentityTestRetain.handles = [activated]
        _ = try StaffWorkspaceOperationalConvergenceStore.prove(
            head: manifest, plan: plan, participantAccountHash: participantAccountHash,
            zoneName: plan.zoneName, store: memory.store, scope: scope, planID: plan.id)
        _ = try StaffWorkspaceOperationalReadyStore.markReady(
            plan: plan, store: memory.store, scope: scope, planID: plan.id)
        let hosted = try StaffWorkspaceOperationalHostStore.open(
            plan: plan, store: memory.store, scope: scope, planID: plan.id)
        IdentityTestRetain.hosted = [hosted]
        return hosted
    }

    @MainActor
    func testBindSucceedsAndLoadRoundTrips() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (context, plan, _) = try scopeContextAndPlan()
        let memory = MemoryStore()
        let sealed = String(repeating: "b", count: 64)
        let hosted = try installThroughHost(
            raw: raw, receipt: vector.receipt, sealedSHA256: sealed,
            scope: context.scope, plan: plan, participantAccountHash: context.account.accountHash,
            memory: memory)
        let fp = fingerprint()
        let payloadBefore = try XCTUnwrap(memory.saved[StaffWorkspaceOperationalMountStore.payloadKey(context.scope, plan.id)])

        let bound = try StaffWorkspaceOperationalIdentityStore.bind(
            plan: plan, store: memory.store, scope: context.scope, planID: plan.id,
            account: context.account, deviceFingerprint: fp, hosted: hosted)
        XCTAssertEqual(bound.schema, StaffWorkspaceOperationalIdentityJournal.schema)
        XCTAssertEqual(bound.state, "bound")
        XCTAssertFalse(bound.operationalWorkspaceReady)
        XCTAssertEqual(bound.participantAccountHash, context.account.accountHash)
        XCTAssertEqual(bound.environment, context.account.environment)
        XCTAssertEqual(bound.deviceFingerprint, fp)
        XCTAssertEqual(bound.selectionID, hosted.journal.selectionID)
        XCTAssertEqual(bound.contentSHA256, hosted.journal.contentSHA256)
        XCTAssertEqual(bound.sealedSHA256, hosted.journal.sealedSHA256)
        XCTAssertEqual(bound.sourceSequence, hosted.journal.sourceSequence)
        XCTAssertEqual(bound.recordCount, hosted.journal.recordCount)

        let loaded = try XCTUnwrap(StaffWorkspaceOperationalIdentityStore.load(
            store: memory.store, scope: context.scope, plan: plan.id))
        XCTAssertEqual(loaded, bound)
        XCTAssertEqual(memory.saved[StaffWorkspaceOperationalMountStore.payloadKey(context.scope, plan.id)], payloadBefore)
        let hostJournal = try XCTUnwrap(StaffWorkspaceOperationalHostStore.loadJournal(
            store: memory.store, scope: context.scope, plan: plan.id))
        XCTAssertTrue(hostJournal.operationalWorkspaceReady)
    }

    @MainActor
    func testIdempotentRebindSameFingerprintAndAccount() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (context, plan, _) = try scopeContextAndPlan()
        let memory = MemoryStore()
        let sealed = String(repeating: "b", count: 64)
        let hosted = try installThroughHost(
            raw: raw, receipt: vector.receipt, sealedSHA256: sealed,
            scope: context.scope, plan: plan, participantAccountHash: context.account.accountHash,
            memory: memory)
        let fp = fingerprint()
        let first = try StaffWorkspaceOperationalIdentityStore.bind(
            plan: plan, store: memory.store, scope: context.scope, planID: plan.id,
            account: context.account, deviceFingerprint: fp, hosted: hosted)
        let identityBytes = try XCTUnwrap(memory.saved[StaffWorkspaceOperationalIdentityStore.key(context.scope, plan.id)])
        let second = try StaffWorkspaceOperationalIdentityStore.bind(
            plan: plan, store: memory.store, scope: context.scope, planID: plan.id,
            account: context.account, deviceFingerprint: fp, hosted: hosted)
        XCTAssertEqual(first, second)
        XCTAssertEqual(memory.saved[StaffWorkspaceOperationalIdentityStore.key(context.scope, plan.id)], identityBytes)
    }

    @MainActor
    func testRejectWrongParticipantAccountHash() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (context, plan, _) = try scopeContextAndPlan()
        let memory = MemoryStore()
        let sealed = String(repeating: "b", count: 64)
        let hosted = try installThroughHost(
            raw: raw, receipt: vector.receipt, sealedSHA256: sealed,
            scope: context.scope, plan: plan, participantAccountHash: context.account.accountHash,
            memory: memory)
        let wrong = CompanyCloudKitAccount(
            environment: context.account.environment,
            accountHash: String(repeating: "a", count: 64),
            recordName: "wrong")
        XCTAssertThrowsError(try StaffWorkspaceOperationalIdentityStore.bind(
            plan: plan, store: memory.store, scope: context.scope, planID: plan.id,
            account: wrong, deviceFingerprint: fingerprint(), hosted: hosted)) { error in
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .access)
        }
    }

    @MainActor
    func testRejectWrongDeviceFingerprintOnRequireBound() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (context, plan, _) = try scopeContextAndPlan()
        let memory = MemoryStore()
        let sealed = String(repeating: "b", count: 64)
        let hosted = try installThroughHost(
            raw: raw, receipt: vector.receipt, sealedSHA256: sealed,
            scope: context.scope, plan: plan, participantAccountHash: context.account.accountHash,
            memory: memory)
        let fp = fingerprint("device-a")
        let bound = try StaffWorkspaceOperationalIdentityStore.bind(
            plan: plan, store: memory.store, scope: context.scope, planID: plan.id,
            account: context.account, deviceFingerprint: fp, hosted: hosted)
        try StaffWorkspaceOperationalPresentation.requireBound(
            hosted: hosted, identity: bound, account: context.account, deviceFingerprint: fp)
        XCTAssertThrowsError(try StaffWorkspaceOperationalPresentation.requireBound(
            hosted: hosted, identity: bound, account: context.account,
            deviceFingerprint: fingerprint("other-device"))) { error in
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .storage)
        }
    }

    @MainActor
    func testRejectMismatchedSelectionDigests() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (context, plan, _) = try scopeContextAndPlan()
        let memory = MemoryStore()
        let sealed = String(repeating: "b", count: 64)
        let hosted = try installThroughHost(
            raw: raw, receipt: vector.receipt, sealedSHA256: sealed,
            scope: context.scope, plan: plan, participantAccountHash: context.account.accountHash,
            memory: memory)
        let fp = fingerprint()
        let bound = try StaffWorkspaceOperationalIdentityStore.bind(
            plan: plan, store: memory.store, scope: context.scope, planID: plan.id,
            account: context.account, deviceFingerprint: fp, hosted: hosted)
        let mismatched = try StaffWorkspaceOperationalHostJournal(
            scope: context.scope, planID: plan.id, selectionID: hosted.journal.selectionID,
            sourceSequence: hosted.journal.sourceSequence,
            contentSHA256: String(repeating: "d", count: 64),
            sealedSHA256: hosted.journal.sealedSHA256,
            recordCount: hosted.journal.recordCount)
        let broken = StaffWorkspaceOperationalHostedStore(journal: mismatched, activated: hosted.activated)
        IdentityTestRetain.hosted.append(broken)
        XCTAssertThrowsError(try StaffWorkspaceOperationalPresentation.requireBound(
            hosted: broken, identity: bound, account: context.account, deviceFingerprint: fp)) { error in
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .storage)
        }
    }

    @MainActor
    func testPresentationRequireBoundAcceptsMatchingIdentity() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (context, plan, _) = try scopeContextAndPlan()
        let memory = MemoryStore()
        let sealed = String(repeating: "b", count: 64)
        let hosted = try installThroughHost(
            raw: raw, receipt: vector.receipt, sealedSHA256: sealed,
            scope: context.scope, plan: plan, participantAccountHash: context.account.accountHash,
            memory: memory)
        let fp = fingerprint()
        let bound = try StaffWorkspaceOperationalIdentityStore.bind(
            plan: plan, store: memory.store, scope: context.scope, planID: plan.id,
            account: context.account, deviceFingerprint: fp, hosted: hosted)
        try StaffWorkspaceOperationalPresentation.requireBound(
            hosted: hosted, identity: bound, account: context.account, deviceFingerprint: fp)
        // Existing requireHosted remains intact for unbound presentation paths.
        try StaffWorkspaceOperationalPresentation.requireHosted(hosted)
        let destinations = try StaffWorkspaceOperationalPresentation.destinations(for: hosted)
        XCTAssertEqual(destinations.first, .overview)
    }

    @MainActor
    func testRejectChangedIdentityFingerprintAfterBind() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (context, plan, _) = try scopeContextAndPlan()
        let memory = MemoryStore()
        let sealed = String(repeating: "b", count: 64)
        let hosted = try installThroughHost(
            raw: raw, receipt: vector.receipt, sealedSHA256: sealed,
            scope: context.scope, plan: plan, participantAccountHash: context.account.accountHash,
            memory: memory)
        _ = try StaffWorkspaceOperationalIdentityStore.bind(
            plan: plan, store: memory.store, scope: context.scope, planID: plan.id,
            account: context.account, deviceFingerprint: fingerprint("device-a"), hosted: hosted)
        XCTAssertThrowsError(try StaffWorkspaceOperationalIdentityStore.bind(
            plan: plan, store: memory.store, scope: context.scope, planID: plan.id,
            account: context.account, deviceFingerprint: fingerprint("device-b"), hosted: hosted)) { error in
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .changed)
        }
    }
}
