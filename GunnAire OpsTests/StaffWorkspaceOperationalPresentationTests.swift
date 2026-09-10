import Foundation
import CloudKit
import SwiftData
import XCTest
@testable import GunnAire_Ops

final class StaffWorkspaceOperationalPresentationTests: XCTestCase {
    /// Retain MainActor coordinator/handles across XCTest off-actor teardown.
    private enum PresentationTestRetain {
        static var coordinator: StaffWorkspaceContentCoordinator?
        static var handles: [StaffWorkspaceOperationalActivatedStore] = []
        static var hosted: [StaffWorkspaceOperationalHostedStore] = []
        static var receive: StaffReplicaReceiveController?
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
        PresentationTestRetain.handles = [activated]
        _ = try StaffWorkspaceOperationalConvergenceStore.prove(
            head: manifest, plan: plan, participantAccountHash: participantAccountHash,
            zoneName: plan.zoneName, store: memory.store, scope: scope, planID: plan.id)
        _ = try StaffWorkspaceOperationalReadyStore.markReady(
            plan: plan, store: memory.store, scope: scope, planID: plan.id)
        let hosted = try StaffWorkspaceOperationalHostStore.open(
            plan: plan, store: memory.store, scope: scope, planID: plan.id)
        PresentationTestRetain.hosted = [hosted]
        return hosted
    }

    @MainActor
    func testDestinationsFromHostedProjectionKinds() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (context, plan, _) = try scopeContextAndPlan()
        let memory = MemoryStore()
        let sealed = String(repeating: "b", count: 64)
        let hosted = try installThroughHost(
            raw: raw, receipt: vector.receipt, sealedSHA256: sealed,
            scope: context.scope, plan: plan, participantAccountHash: context.account.accountHash,
            memory: memory)

        try StaffWorkspaceOperationalPresentation.requireHosted(hosted)
        let kinds = try StaffWorkspaceOperationalPresentation.kindsPresent(in: hosted)
        XCTAssertTrue(kinds.contains("customer"))
        XCTAssertTrue(kinds.contains("job") || kinds.contains("invoice") || kinds.contains("technician"))

        let destinations = try StaffWorkspaceOperationalPresentation.destinations(for: hosted)
        XCTAssertEqual(destinations.first, .overview)
        XCTAssertTrue(destinations.contains(.customers))
        XCTAssertTrue(destinations.count >= 2)

        let customers = try StaffWorkspaceOperationalPresentation.records(in: hosted, for: .customers)
        XCTAssertFalse(customers.isEmpty)
        XCTAssertTrue(customers.allSatisfy { StaffWorkspaceOperationalNavDestination.customers.kinds.contains($0.kind) })

        let overview = try StaffWorkspaceOperationalPresentation.records(in: hosted, for: .overview)
        XCTAssertEqual(overview.count, hosted.journal.recordCount)
    }

    @MainActor
    func testNavPolicySelectionRecovery() {
        let visible: [StaffWorkspaceOperationalNavDestination] = [.overview, .customers, .invoices]
        XCTAssertEqual(
            StaffWorkspaceOperationalNavPolicy.resolvedSelection(.invoices, visible: visible),
            .invoices)
        XCTAssertEqual(
            StaffWorkspaceOperationalNavPolicy.resolvedSelection(.fleet, visible: visible),
            .overview)
        XCTAssertEqual(
            StaffWorkspaceOperationalNavPolicy.resolvedSelection(nil, visible: [.customers, .payments]),
            .customers)
        XCTAssertNil(StaffWorkspaceOperationalNavPolicy.resolvedSelection(.overview, visible: []))
        XCTAssertEqual(
            StaffWorkspaceOperationalNavPolicy.destinations(kindsPresent: ["vehicle"]),
            [.overview, .fleet])
        XCTAssertEqual(
            StaffWorkspaceOperationalNavPolicy.destinations(kindsPresent: []),
            [.overview])
    }

    @MainActor
    func testRejectUnhostedHandle() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (context, plan, _) = try scopeContextAndPlan()
        let memory = MemoryStore()
        let sealed = String(repeating: "b", count: 64)
        let hosted = try installThroughHost(
            raw: raw, receipt: vector.receipt, sealedSHA256: sealed,
            scope: context.scope, plan: plan, participantAccountHash: context.account.accountHash,
            memory: memory)

        // Forge a journal that no longer matches activated digests.
        let mismatched = try StaffWorkspaceOperationalHostJournal(
            scope: context.scope, planID: plan.id, selectionID: hosted.journal.selectionID,
            sourceSequence: hosted.journal.sourceSequence,
            contentSHA256: String(repeating: "d", count: 64),
            sealedSHA256: hosted.journal.sealedSHA256,
            recordCount: hosted.journal.recordCount)
        let broken = StaffWorkspaceOperationalHostedStore(journal: mismatched, activated: hosted.activated)
        PresentationTestRetain.hosted.append(broken)
        XCTAssertThrowsError(try StaffWorkspaceOperationalPresentation.requireHosted(broken)) { error in
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .storage)
        }
        XCTAssertThrowsError(try StaffWorkspaceOperationalPresentation.destinations(for: broken)) { error in
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .storage)
        }
    }

    @MainActor
    func testReceiveControllerPublishesHostedStoreForUI() async throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (context, plan, base) = try scopeContextAndPlan()
        let memory = MemoryStore()
        let sealed = String(repeating: "b", count: 64)
        let hosted = try installThroughHost(
            raw: raw, receipt: vector.receipt, sealedSHA256: sealed,
            scope: context.scope, plan: plan, participantAccountHash: context.account.accountHash,
            memory: memory)
        let invitation = URL(string: "https://www.icloud.com/share/fixture-presentation")!
        let manifest = StaffReplicaManifest(
            protocolVersion: 1, schema: StaffReplicaCoreSource.schemaVersion, coverage: StaffReplicaCoreSource.recordKinds,
            operationID: UUID(), membershipID: plan.id, companyID: plan.companyID, environment: plan.environment,
            replicaID: plan.replicaID, memberRevision: plan.memberRevision, projectionPolicy: plan.projectionPolicy,
            sourceSequence: 1, authorizationSequence: 1, payloadSHA256: String(repeating: "a", count: 64),
            payloadBytes: 16, recordCount: 0, createdAt: base.instant)

        let receive = StaffReplicaReceiveController(dependencies: .init(
            check: { _ in },
            download: { _, _, _ in manifest },
            receiveFullWorkspace: { _, _, _ in
                .init(selectionID: hosted.journal.selectionID, alreadyLeased: false,
                      operationalMounted: true, operationalAccepted: true)
            },
            markOperationalReady: { _, _, _ in
                try XCTUnwrap(StaffWorkspaceOperationalReadyStore.load(
                    store: memory.store, scope: context.scope, plan: plan.id))
            },
            loadOperationalReady: { _, _ in nil },
            openOperationalHost: { sharePlan, _ in
                let opened = try StaffWorkspaceOperationalHostStore.open(
                    plan: sharePlan, store: memory.store, scope: context.scope, planID: sharePlan.id)
                PresentationTestRetain.hosted.append(opened)
                return opened
            },
            now: { base.now }))
        PresentationTestRetain.receive = receive

        XCTAssertNil(receive.hostedStore)
        _ = await receive.refresh(context: context, plan: plan, invitation: invitation)
        let published = try XCTUnwrap(receive.hostedStore)
        PresentationTestRetain.hosted.append(published)
        XCTAssertEqual(published.journal.state, "hosted")
        XCTAssertTrue(published.journal.operationalWorkspaceReady)
        XCTAssertTrue(receive.message.contains("hosted for staff projection"))

        let destinations = try StaffWorkspaceOperationalPresentation.destinations(for: published)
        XCTAssertEqual(destinations.first, .overview)
        XCTAssertFalse(destinations.isEmpty)

        receive.clearDisplay()
        XCTAssertNil(receive.hostedStore)
    }

    @MainActor
    func testHostedContainerQueryableForNavPresentation() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (setupContext, plan, _) = try scopeContextAndPlan()
        let memory = MemoryStore()
        let sealed = String(repeating: "b", count: 64)
        let hosted = try installThroughHost(
            raw: raw, receipt: vector.receipt, sealedSHA256: sealed,
            scope: setupContext.scope, plan: plan, participantAccountHash: setupContext.account.accountHash,
            memory: memory)

        try StaffWorkspaceOperationalPresentation.requireHosted(hosted)
        let modelContext = ModelContext(hosted.container)
        modelContext.autosaveEnabled = false
        let rows = try modelContext.fetch(FetchDescriptor<StaffWorkspaceOperationalProjectionRecord>())
        XCTAssertEqual(rows.count, hosted.journal.recordCount)
        XCTAssertFalse(rows.isEmpty)

        let destinations = try StaffWorkspaceOperationalPresentation.destinations(for: hosted)
        for destination in destinations where destination != .overview {
            let matched = rows.filter { destination.kinds.contains($0.kind) }
            XCTAssertFalse(matched.isEmpty, "Expected rows for \(destination.rawValue)")
        }
    }
}
