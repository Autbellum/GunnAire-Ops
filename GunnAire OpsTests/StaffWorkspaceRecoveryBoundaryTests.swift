import Foundation
import CloudKit
import XCTest
@testable import GunnAire_Ops

@MainActor final class StaffWorkspaceRecoveryBoundaryTests: XCTestCase {
    final class Memory {
        var saved: [String: Data] = [:]
        var writes = 0
        var failBefore: Int?, failAfter: Int?
        var store: SharedTimeLocalStore {
            .init(read: { self.saved[$0] }, write: { key, value in
                self.writes += 1
                if self.failBefore == self.writes { throw StaffReplicaDeliveryError.storage }
                self.saved[key] = value
                if self.failAfter == self.writes { throw StaffReplicaDeliveryError.storage }
            })
        }
    }
    func testUpgradingMountPreservesPriorSnapshotAcrossEveryWriteBoundary() throws {
        let f = try StaffWorkspaceContentCoordinatorTests.Fixture(); defer { f.cleanup() }
        let scope = try f.authority.cloud.context().scope, plan = f.plan.id
        let raw = Data(f.row.payloadUtf8.utf8), nextRaw = raw + Data("\n".utf8)
        let first = try StaffWorkspaceCloudSealManifest(content: f.row.contentReceipt,
            sealedSHA256: String(repeating: "a", count: 64), sealedBytes: raw.count + 28)
        let nextReceipt = try JSONDecoder().decode(StaffWorkspaceContentReceipt.self, from: f.modified(f.row.contentReceipt,
            ["selectionID": UUID().uuidString.lowercased(), "sourceSequence": 2, "currentSourceSequence": 2,
             "payloadBytes": nextRaw.count, "contentSHA256": StaffReplicaManifest.hash(nextRaw)]))
        let next = try StaffWorkspaceCloudSealManifest(content: nextReceipt,
            sealedSHA256: String(repeating: "b", count: 64), sealedBytes: nextRaw.count + 28)
        let baseline = Memory()
        try StaffWorkspaceOperationalMountStore.install(opened: raw, manifest: first, store: baseline.store, scope: scope, plan: plan, check: {})
        let success = Memory(); success.saved = baseline.saved
        try StaffWorkspaceOperationalMountStore.install(opened: nextRaw, manifest: next, store: success.store, scope: scope, plan: plan, check: {})
        for boundary in 1...success.writes {
            for after in [false, true] {
                let m = Memory(); m.saved = baseline.saved
                if after { m.failAfter = boundary } else { m.failBefore = boundary }
                XCTAssertThrowsError(try StaffWorkspaceOperationalMountStore.install(opened: nextRaw, manifest: next,
                    store: m.store, scope: scope, plan: plan, check: {}))
                let recovered = try XCTUnwrap(StaffWorkspaceOperationalMountStore.load(store: m.store, scope: scope, plan: plan))
                XCTAssertTrue(recovered.1 == raw || recovered.1 == nextRaw, "Boundary \(boundary), after=\(after)")
                m.failBefore = nil; m.failAfter = nil
                try StaffWorkspaceOperationalMountStore.install(opened: nextRaw, manifest: next, store: m.store, scope: scope, plan: plan, check: {})
                XCTAssertEqual(try StaffWorkspaceOperationalMountStore.load(store: m.store, scope: scope, plan: plan)?.1, nextRaw)
                XCTAssertEqual(m.saved[StaffWorkspaceOperationalMountStore.payloadKey(scope, plan)], raw, "Original bytes must not be overwritten")
            }
        }
    }
    func testInterruptedCommandEnqueueRetainsDiscoverableOriginalRequest() throws {
        let f = try StaffWorkspaceContentCoordinatorTests.Fixture(); defer { f.cleanup() }
        let scope = try f.authority.cloud.context().scope, plan = f.plan.id, c = f.row.contentReceipt
        let request = try StaffWorkspaceOperationalCommandRequest(companyID: c.companyID, environment: c.environment,
            replicaID: c.replicaID, commandID: UUID(), selectionID: c.selectionID, sourceSequence: c.sourceSequence,
            contentSHA256: c.contentSHA256, candidate: .init(recordKind: "job", recordID: UUID().uuidString.lowercased(),
                revision: 1, fieldName: "notes", currentValue: .text("Original")), value: .text("Retain this offline finding"))
        let success = Memory()
        try StaffWorkspaceOperationalCommandStore.enqueue(store: success.store, scope: scope, plan: plan, request: request)
        for boundary in 1...success.writes {
            for after in [false, true] {
                let m = Memory()
                if after { m.failAfter = boundary } else { m.failBefore = boundary }
                XCTAssertThrowsError(try StaffWorkspaceOperationalCommandStore.enqueue(store: m.store, scope: scope, plan: plan, request: request))
                if !m.saved.isEmpty {
                    XCTAssertEqual(try StaffWorkspaceOperationalCommandStore.listPending(store: m.store, scope: scope, plan: plan).map(\.request), [request])
                }
                m.failBefore = nil; m.failAfter = nil
                try StaffWorkspaceOperationalCommandStore.enqueue(store: m.store, scope: scope, plan: plan, request: request)
                XCTAssertEqual(try StaffWorkspaceOperationalCommandStore.listPending(store: m.store, scope: scope, plan: plan).map(\.request), [request])
            }
        }
    }

    func testDuplicateCloudManifestKeysAreRejectedInBothReplicaSchemas() throws {
        let f = try StaffWorkspaceContentCoordinatorTests.Fixture(); defer { f.cleanup() }
        let full = try StaffWorkspaceCloudSealManifest(content: f.row.contentReceipt,
            sealedSHA256: String(repeating: "a", count: 64), sealedBytes: f.row.contentReceipt.payloadBytes + 28)
        let zone = CKRecordZone.ID(zoneName: f.plan.zoneName, ownerName: CKCurrentUserDefaultName)
        let record = try StaffWorkspaceCloudRecords.make(full, plan: f.plan, zone: zone)
        let context = try f.authority.cloud.context()
        XCTAssertNoThrow(try StaffWorkspaceCloudRecords.manifest(record, plan: f.plan, workspace: context.workspace, zone: zone, payload: false, now: f.now))
        let original = try XCTUnwrap(record["manifest"] as? Data)
        record["manifest"] = (Data("{\"schema\":\"\(full.schema)\",".utf8) + original.dropFirst()) as CKRecordValue
        XCTAssertThrowsError(try StaffWorkspaceCloudRecords.manifest(record, plan: f.plan, workspace: context.workspace, zone: zone, payload: false, now: f.now))

        let core = try StaffReplicaDeliveryTests.Fixture(); defer { core.cleanup() }
        let corePlan = try core.base.plan(), payload = try core.payload()
        let coreZone = CKRecordZone.ID(zoneName: corePlan.zoneName, ownerName: CKCurrentUserDefaultName)
        let coreRecord = try StaffReplicaCloudRecords.make(payload.manifest, plan: corePlan, zone: coreZone)
        XCTAssertNoThrow(try StaffReplicaCloudRecords.manifest(coreRecord, plan: corePlan, workspace: core.base.workspace, zone: coreZone, payload: false, now: core.base.now))
        let coreRaw = try XCTUnwrap(coreRecord["manifest"] as? Data)
        coreRecord["manifest"] = (Data("{\"schema\":\"\(payload.manifest.schema)\",".utf8) + coreRaw.dropFirst()) as CKRecordValue
        XCTAssertThrowsError(try StaffReplicaCloudRecords.manifest(coreRecord, plan: corePlan, workspace: core.base.workspace, zone: coreZone, payload: false, now: core.base.now))
    }

    func testCoreRetryCannotConfirmAHeadThatAdvancedDuringRead() async throws {
        let f = try StaffReplicaDeliveryTests.Fixture(); defer { f.cleanup() }
        let plan = try f.base.plan(), context = try f.context()
        let original = try f.seal(f.payload()), newer = try f.payload(sequence: 2)
        let io = f.io(plan: plan, context: context, authorize: {})
        try await StaffReplicaCloudTransfer.publish(original, plan: plan, workspace: f.base.workspace, io: io, now: { f.base.now })
        f.afterRead = { f.remote[StaffReplicaCloudRecords.headName] = (newer.manifest, nil) }
        do {
            try await StaffReplicaCloudTransfer.publish(original, plan: plan, workspace: f.base.workspace, io: io, now: { f.base.now })
            XCTFail("The exact-upload retry must recheck its current head")
        } catch { XCTAssertEqual(error as? StaffReplicaDeliveryError, .superseded) }
        XCTAssertEqual(f.remote[StaffReplicaCloudRecords.headName]?.0, newer.manifest)
    }
}
