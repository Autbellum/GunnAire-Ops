import Foundation
import CloudKit
import Combine
import XCTest
@testable import GunnAire_Ops

@MainActor
final class StaffWorkspaceOpenSessionTests: XCTestCase {
    @MainActor
    final class Fixture {
        struct Vector: Decodable { let receipt: StaffWorkspaceContentReceipt; let payloadUtf8: String }
        let base = CloudKitStaffSharingTests()
        let plan: CloudKitStaffSharePlan
        let context: CloudKitStaffSetupController.Context
        let invitation = URL(string: "https://www.icloud.com/share/fixture-verified-open")!
        var receipt: StaffWorkspaceContentReceipt
        var raw: Data
        var head: StaffWorkspaceCloudSealManifest
        var saved: [String: Data] = [:]
        var device = String(repeating: "f", count: 64)
        var allowed = true
        var serverAllows = true
        var currentTime: Date
        var serverChecks = 0
        var afterServer: (() throws -> Void)?
        var serverWait: (() async -> Void)?
        var afterOpen: ((StaffWorkspaceOperationalSession) throws -> Void)?
        var replacement: StaffWorkspaceOperationalSession?

        init() throws {
            plan = try base.plan(); currentTime = base.now
            let stamp = CloudKitStaffSetupStamp(session: .init(backendOrigin: "https://fixture.gunnaire.invalid",
                email: base.member.email, tokenFingerprint: String(repeating: "1", count: 64),
                expiresAt: base.now.addingTimeInterval(3600)), accountGeneration: UUID())
            context = .init(stamp: stamp, workspace: base.workspace,
                member: .init(email: base.member.email, role: plan.memberRole, isActive: true, createdAt: base.instant),
                account: .init(environment: plan.environment, accountHash: base.participantHash, recordName: base.participantName))
            let url = try XCTUnwrap(Bundle(for: StaffWorkspaceOpenSessionTests.self)
                .url(forResource: "StaffWorkspaceContentTransportInterop", withExtension: "json"))
            let vector = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
            receipt = vector.receipt; raw = Data(vector.payloadUtf8.utf8)
            head = try .init(content: receipt, sealedSHA256: String(repeating: "b", count: 64), sealedBytes: raw.count + 28)
            try install()
        }
        nonisolated deinit {}
        func cleanup() { afterOpen = nil; afterServer = nil; serverWait = nil; replacement = nil }
        var store: SharedTimeLocalStore { .init(read: { self.saved[$0] }, write: { self.saved[$0] = $1 }) }
        func authorize(_ context: CloudKitStaffSetupController.Context) throws {
            guard allowed, context.stamp == self.context.stamp else { throw StaffReplicaDeliveryError.access }
        }
        func install() throws {
            try StaffWorkspaceOperationalMountStore.install(opened: raw, manifest: head, store: store,
                scope: context.scope, plan: plan.id, check: {})
            try StaffWorkspaceOperationalAcceptanceStore.accept(store: store, scope: context.scope, plan: plan.id)
        }
        func advance(jobNotes: String? = nil) throws {
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
            root["sourceSequence"] = receipt.sourceSequence + 1
            if let jobNotes {
                var records = try XCTUnwrap(root["records"] as? [[String: Any]])
                let index = try XCTUnwrap(records.firstIndex { $0["kind"] as? String == "job" })
                var record = records[index]
                var body = try XCTUnwrap(record["body"] as? [String: Any])
                var operational = try XCTUnwrap(body["operational"] as? [String: Any])
                var partition = try XCTUnwrap(operational["_0"] as? [String: Any])
                var fields = try XCTUnwrap(partition["fields"] as? [String: Any])
                fields["notes"] = ["text": ["_0": jobNotes]]
                partition["fields"] = fields; operational["_0"] = partition; body["operational"] = operational
                record["body"] = body; record["revision"] = (record["revision"] as? Int ?? 0) + 1
                records[index] = record; root["records"] = records
            }
            raw = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
            wire["selectionID"] = UUID().uuidString.lowercased()
            wire["sourceSequence"] = receipt.sourceSequence + 1; wire["currentSourceSequence"] = receipt.sourceSequence + 1
            wire["contentSHA256"] = StaffReplicaManifest.hash(raw); wire["payloadBytes"] = raw.count
            receipt = try JSONDecoder().decode(StaffWorkspaceContentReceipt.self, from: JSONSerialization.data(withJSONObject: wire))
            head = try .init(content: receipt, sealedSHA256: String(repeating: "c", count: 64), sealedBytes: raw.count + 28)
            try install()
        }
        var engine: StaffWorkspaceContentCoordinator {
            let zone = CKRecordZone.ID(zoneName: plan.zoneName, ownerName: base.ownerName)
            let io = StaffReplicaCloudIO(zone: zone, authorize: {}, read: { ids in
                var records: [CKRecord.ID: CKRecord] = [:]
                for id in ids where id.recordName == StaffWorkspaceCloudRecords.headName {
                    records[id] = try StaffWorkspaceCloudRecords.make(self.head, plan: self.plan, zone: zone)
                }
                return records
            }, save: { _ in XCTFail("Opening staff data must not write CloudKit") })
            return .init(dependencies: .init(setup: { (self.context, [self.plan]) },
                check: { _ in throw StaffReplicaDeliveryError.access }, request: { _, _, _ in throw StaffReplicaDeliveryError.access },
                store: store, participantCloudIO: { _, _, _, _ in io }, invitationURL: { _, _ in self.invitation },
                staffRequest: { _ in
                    guard self.serverAllows else { throw StaffReplicaDeliveryError.access }
                    self.serverChecks += 1
                    let bytes = try StaffWorkspacePublicationContract.encode(StaffWorkspaceCloudSealResponse(
                        schema: StaffWorkspaceCloudSealResponse.schema, content: self.receipt,
                        sealedSHA256: self.head.sealedSHA256, sealedBytes: self.raw.count + 28,
                        keyBase64: Data(repeating: 1, count: 32).base64EncodedString(),
                        nonceBase64: Data(repeating: 2, count: 12).base64EncodedString()))
                    let callback = self.afterServer; self.afterServer = nil; try callback?()
                    await self.serverWait?()
                    return bytes
                }, checkStaffSession: { try self.authorize($0) }, now: { self.currentTime }))
        }
        func open(previous: StaffWorkspaceOperationalSession? = nil) async throws -> StaffWorkspaceOperationalSession {
            try await engine.openReceivedOperationalWorkspace(plan: plan, context: context, invitation: invitation,
                selectionID: receipt.selectionID, deviceFingerprint: device, previous: previous)
        }
        var core: StaffReplicaManifest {
            .init(protocolVersion: 1, schema: StaffReplicaCoreSource.schemaVersion, coverage: StaffReplicaCoreSource.recordKinds,
                operationID: UUID(), membershipID: plan.id, companyID: plan.companyID, environment: plan.environment,
                replicaID: plan.replicaID, memberRevision: plan.memberRevision, projectionPolicy: plan.projectionPolicy,
                sourceSequence: 1, authorizationSequence: 1, payloadSHA256: String(repeating: "a", count: 64),
                payloadBytes: 16, recordCount: 0, createdAt: base.instant)
        }
        func controller() -> StaffReplicaReceiveController {
            .init(dependencies: .init(check: { try self.authorize($0) }, download: { _, _, _ in self.core },
                receiveFullWorkspace: { _, _, _ in .init(selectionID: self.receipt.selectionID, alreadyLeased: false,
                    operationalMounted: true, operationalAccepted: true) },
                openWorkspace: { plan, context, url, selection, device, previous in
                    let value: StaffWorkspaceOperationalSession
                    if let replacement = self.replacement { value = replacement }
                    else { value = try await self.engine.openReceivedOperationalWorkspace(plan: plan, context: context,
                        invitation: url, selectionID: selection, deviceFingerprint: device, previous: previous) }
                    try self.afterOpen?(value)
                    return value
                }, currentDeviceFingerprint: { self.device }, now: { self.currentTime }))
        }
        func refresh(_ controller: StaffReplicaReceiveController) async {
            await controller.refresh(context: context, plan: plan, invitation: invitation)
        }
    }

    func testFirstReceiveCompletesMissingImportActivationAndIdentityStages() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        XCTAssertNil(try StaffWorkspaceOperationalImportStore.load(store: f.store, scope: f.context.scope, plan: f.plan.id))
        XCTAssertNil(try StaffWorkspaceOperationalStoreActivator.loadJournal(store: f.store, scope: f.context.scope, plan: f.plan.id))
        let session = try await f.open()
        try session.validate(plan: f.plan, context: f.context, selectionID: f.receipt.selectionID, deviceFingerprint: f.device)
        XCTAssertEqual(try session.hosted.fetch().count, f.receipt.recordCount)
        XCTAssertEqual(session.identity.deviceFingerprint, f.device)
        XCTAssertGreaterThan(f.serverChecks, 0)
    }

    func testUnchangedRefreshReusesContainerButStillChecksServerAuthority() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let first = try await f.open(), saved = f.saved, checks = f.serverChecks
        let second = try await f.open(previous: first)
        XCTAssertTrue(first.hosted === second.hosted)
        XCTAssertEqual(f.saved, saved)
        XCTAssertGreaterThan(f.serverChecks, checks)
        f.serverAllows = false
        do { _ = try await f.open(previous: second); XCTFail("Cached data is not fresh server authority") } catch {}
        XCTAssertEqual(f.saved, saved)
    }

    func testControllerPublishesOnlyCompleteMatchingSessionsAcrossSuccessors() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let controller = f.controller()
        var published: [StaffReplicaPresentation] = []
        let observer = controller.$presentation.compactMap { $0 }.sink { published.append($0) }
        defer { observer.cancel() }
        await f.refresh(controller)
        let first = try XCTUnwrap(controller.authorizedPresentation), saved = f.saved
        await f.refresh(controller)
        XCTAssertTrue(controller.hostedStore === first.workspace.hosted)
        XCTAssertEqual(published.count, 1); XCTAssertEqual(f.saved, saved)
        f.saved["pending-draft-fixture"] = Data("Unsent work".utf8)
        try f.advance(); await f.refresh(controller)
        let second = try XCTUnwrap(controller.authorizedPresentation)
        XCTAssertEqual(second.workspace.hosted.journal.selectionID, f.receipt.selectionID)
        XCTAssertNotEqual(second.workspace.identity.selectionID, first.workspace.identity.selectionID)
        XCTAssertEqual(second.navigationScope, first.navigationScope)
        XCTAssertNotEqual(second.viewIdentity, first.viewIdentity)
        XCTAssertEqual(published.count, 2)
        for value in published {
            try value.workspace.validate(plan: f.plan, context: f.context,
                selectionID: value.workspace.hosted.journal.selectionID, deviceFingerprint: f.device)
        }
        XCTAssertEqual(f.saved["pending-draft-fixture"], Data("Unsent work".utf8))
        XCTAssertThrowsError(try controller.fieldEditingAuthority(for: first.workspace.hosted))
        XCTAssertEqual(try controller.fieldEditingAuthority(for: second.workspace.hosted).1, f.plan)
    }

    func testFailedRefreshCannotLeavePriorSessionOrEditingAuthorityVisible() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let controller = f.controller(); await f.refresh(controller)
        let hosted = try XCTUnwrap(controller.hostedStore), saved = f.saved
        f.serverAllows = false; await f.refresh(controller)
        XCTAssertNil(controller.presentation); XCTAssertNil(controller.hostedStore); XCTAssertNil(controller.received)
        XCTAssertThrowsError(try controller.fieldEditingAuthority(for: hosted))
        XCTAssertEqual(f.saved, saved)
        f.serverAllows = true; await f.refresh(controller)
        XCTAssertNotNil(controller.authorizedPresentation)
    }

    func testIndependentDeviceEvidenceChangingAfterOpenBlocksPublication() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let controller = f.controller()
        f.afterOpen = { _ in f.device = String(repeating: "d", count: 64) }
        await f.refresh(controller)
        XCTAssertNil(controller.presentation); XCTAssertNil(controller.hostedStore)
        let savedIdentity = try XCTUnwrap(StaffWorkspaceOperationalIdentityStore.load(store: f.store,
            scope: f.context.scope, plan: f.plan.id))
        XCTAssertEqual(savedIdentity.deviceFingerprint, String(repeating: "f", count: 64))
    }

    func testStaleFactoryResultCannotSatisfyANewerReceivedSelection() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let controller = f.controller(); await f.refresh(controller)
        f.replacement = try XCTUnwrap(controller.authorizedPresentation).workspace
        try f.advance(); let saved = f.saved
        await f.refresh(controller)
        XCTAssertNil(controller.authorizedPresentation); XCTAssertNil(controller.presentation)
        XCTAssertEqual(f.saved, saved)
    }

    func testAccountAndViewInvalidationDuringOpenCannotRepublish() async throws {
        for accountChanged in [false, true] {
            let f = try Fixture(); defer { f.cleanup() }
            let controller = f.controller()
            f.afterOpen = { _ in
                if accountChanged { f.allowed = false } else { controller.clearDisplay() }
            }
            await f.refresh(controller)
            XCTAssertNil(controller.presentation); XCTAssertNil(controller.received)
        }
    }

    func testScopeDeviceAndExpiryAreRecheckedWhenReadingPresentation() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let controller = f.controller(); await f.refresh(controller)
        let hosted = try XCTUnwrap(controller.hostedStore), saved = f.saved
        f.allowed = false
        XCTAssertNil(controller.authorizedPresentation)
        XCTAssertThrowsError(try controller.fieldEditingAuthority(for: hosted))
        f.allowed = true; f.device = String(repeating: "d", count: 64)
        XCTAssertNil(controller.authorizedPresentation)
        f.device = String(repeating: "f", count: 64)
        f.currentTime = f.context.stamp.session.expiresAt
        XCTAssertNil(controller.authorizedPresentation)
        XCTAssertThrowsError(try controller.fieldEditingAuthority(for: hosted))
        XCTAssertEqual(f.saved, saved)
    }

    func testHeadChangingDuringCloudProofFailsAndNextSnapshotRecovers() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.afterServer = { try f.advance() }
        do { _ = try await f.open(); XCTFail("Changed remote head") } catch {}
        XCTAssertNil(try StaffWorkspaceOperationalHostStore.loadJournal(store: f.store, scope: f.context.scope, plan: f.plan.id))
        let recovered = try await f.open()
        XCTAssertEqual(recovered.identity.selectionID, f.receipt.selectionID)
        XCTAssertEqual(recovered.identity.sourceSequence, f.receipt.sourceSequence)
    }

    func testInvalidDeviceOrSelectionIsRejectedBeforePreparationWrites() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let saved = f.saved
        for (selection, device) in [("../other", f.device), (f.receipt.selectionID, "not-a-fingerprint")] {
            do {
                _ = try await f.engine.openReceivedOperationalWorkspace(plan: f.plan, context: f.context,
                    invitation: f.invitation, selectionID: selection, deviceFingerprint: device)
                XCTFail("Invalid identity")
            } catch {}
            XCTAssertEqual(f.saved, saved)
        }
    }

    func testRealIdentityBindingFailureCannotPublishAnUnboundHost() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let original = try await f.open()
        let identityKey = StaffWorkspaceOperationalIdentityStore.key(f.context.scope, f.plan.id)
        let originalBytes = try XCTUnwrap(f.saved[identityKey])
        f.device = String(repeating: "d", count: 64)
        let controller = f.controller(); await f.refresh(controller)
        XCTAssertNil(controller.presentation); XCTAssertNil(controller.hostedStore)
        XCTAssertNil(controller.operationalIdentity)
        XCTAssertThrowsError(try controller.fieldEditingAuthority(for: original.hosted))
        XCTAssertEqual(f.saved[identityKey], originalBytes)
        f.device = original.identity.deviceFingerprint
        await f.refresh(controller)
        XCTAssertNotNil(controller.authorizedPresentation)
    }

    func testMismatchedIdentityFieldsNeverReachPublishedSession() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let valid = try await f.open()
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid.identity)) as? [String: Any])
        let mismatches: [[String: Any]] = [
            ["schema": "unrecognized"], ["state": "pending"], ["operationalWorkspaceReady": true],
            ["planID": UUID().uuidString], ["selectionID": UUID().uuidString.lowercased()],
            ["sourceSequence": valid.identity.sourceSequence + 1], ["recordCount": valid.identity.recordCount + 1],
            ["contentSHA256": String(repeating: "0", count: 64)],
            ["sealedSHA256": String(repeating: "0", count: 64)],
            ["participantAccountHash": String(repeating: "0", count: 64)],
            ["deviceFingerprint": String(repeating: "0", count: 64)], ["environment": "production"]
        ]
        let saved = f.saved
        for mismatch in mismatches {
            let altered = try JSONDecoder().decode(StaffWorkspaceOperationalIdentityJournal.self,
                from: JSONSerialization.data(withJSONObject: original.merging(mismatch) { _, new in new }))
            f.replacement = .init(hosted: valid.hosted, identity: altered)
            let controller = f.controller(); await f.refresh(controller)
            XCTAssertNil(controller.presentation, "Rejected field: \(mismatch.keys)")
            XCTAssertThrowsError(try controller.fieldEditingAuthority(for: valid.hosted))
            XCTAssertEqual(f.saved, saved)
        }
    }

    func testCancelledRefreshCoalescesAndCannotRepublishAfterAwait() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let controller = f.controller(); await f.refresh(controller)
        let previous = try XCTUnwrap(controller.hostedStore)
        f.saved["pending-draft-fixture"] = Data("Unsent work".utf8)
        let saved = f.saved
        let entered = expectation(description: "Server proof suspended")
        var release: CheckedContinuation<Void, Never>?
        f.serverWait = {
            await withCheckedContinuation { continuation in
                release = continuation
                entered.fulfill()
            }
        }
        let refresh = Task { await f.refresh(controller) }
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertTrue(controller.isRunning)
        XCTAssertTrue(controller.hostedStore === previous)
        XCTAssertThrowsError(try controller.fieldEditingAuthority(for: previous))
        let duplicate = await controller.refresh(context: f.context, plan: f.plan, invitation: f.invitation)
        XCTAssertFalse(duplicate)
        refresh.cancel(); release?.resume(); release = nil
        await refresh.value
        XCTAssertFalse(controller.isRunning)
        XCTAssertNil(controller.presentation); XCTAssertNil(controller.received)
        XCTAssertEqual(f.saved, saved)
        f.serverWait = nil; await f.refresh(controller)
        XCTAssertNotNil(controller.authorizedPresentation)
    }
}
