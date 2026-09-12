import Foundation
import CloudKit
import CryptoKit
import XCTest
@testable import GunnAire_Ops

final class StaffWorkspaceOperationalAcceptanceTests: XCTestCase {
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
    private func installMount(raw: Data, receipt: StaffWorkspaceContentReceipt,
                              scope: CloudKitStaffSetupScope, plan: UUID,
                              memory: MemoryStore) throws -> StaffWorkspaceOperationalMount {
        let manifest = try StaffWorkspaceCloudSealManifest(
            content: receipt, sealedSHA256: String(repeating: "b", count: 64), sealedBytes: raw.count + 28)
        return try StaffWorkspaceOperationalMountStore.install(
            opened: raw, manifest: manifest, store: memory.store, scope: scope, plan: plan, check: {})
    }

    @MainActor
    func testMountedContentAcceptsJournalAndPreservesUnavailablePartition() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        XCTAssertEqual(StaffReplicaManifest.hash(raw), vector.receipt.contentSHA256)
        let (scope, plan, _) = try scopeAndPlan()
        let memory = MemoryStore()
        let mount = try installMount(raw: raw, receipt: vector.receipt, scope: scope, plan: plan.id, memory: memory)
        let store = memory.store

        let view = try StaffWorkspaceOperationalAcceptanceStore.accept(
            store: store, scope: scope, plan: plan.id, selectionID: mount.selectionID)
        let journal = try XCTUnwrap(StaffWorkspaceOperationalAcceptanceStore.load(store: store, scope: scope, plan: plan.id))
        XCTAssertEqual(journal.schema, StaffWorkspaceOperationalAcceptance.schema)
        XCTAssertEqual(journal.selectionID, mount.selectionID)
        XCTAssertEqual(journal.contentSHA256, mount.contentSHA256)
        XCTAssertEqual(journal.sourceSequence, mount.sourceSequence)
        XCTAssertEqual(journal.recordCount, view.records.count)
        XCTAssertEqual(view.schema, "staff-workspace-content-v1")
        XCTAssertFalse(view.records.isEmpty)

        let attachment = try XCTUnwrap(view.records.first { $0.kind == "attachment" })
        guard case let .operational(partition) = attachment.body else {
            return XCTFail("attachment must be operational")
        }
        XCTAssertFalse(partition.unavailableFields.isEmpty)
        XCTAssertEqual(partition.unavailableFields["quickBooksAttachableID"], .serviceOnly)
        XCTAssertNil(partition.fields["quickBooksAttachableID"])
        XCTAssertTrue(Set(partition.fields.keys).isDisjoint(with: Set(partition.unavailableFields.keys)))

        let invoice = try XCTUnwrap(view.records.first { $0.kind == "invoice" })
        guard case let .billing(document) = invoice.body else {
            return XCTFail("invoice must be billing")
        }
        XCTAssertEqual(document.unavailableFields["quickBooksID"], .roleRestricted)
        XCTAssertEqual(document.unavailableFields["quickBooksSyncDetail"], .serviceOnly)
        XCTAssertNil(document.fields["quickBooksSyncDetail"])
    }

    @MainActor
    func testInventingDefaultsByStrippingUnavailableIsRejected() throws {
        let vector = try vector()
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(vector.payloadUtf8.utf8)) as? [String: Any])
        var records = try XCTUnwrap(root["records"] as? [[String: Any]])
        guard let index = records.firstIndex(where: { ($0["kind"] as? String) == "invoice" }) else {
            return XCTFail("missing invoice")
        }
        var invoice = records[index]
        var body = try XCTUnwrap(invoice["body"] as? [String: Any])
        var billing = try XCTUnwrap((body["billing"] as? [String: Any])?["_0"] as? [String: Any])
        var fields = try XCTUnwrap(billing["fields"] as? [String: Any])
        // Strip unavailable markers and invent empty/null scalars for restricted service fields.
        billing["unavailableFields"] = [String: Any]()
        fields["quickBooksSyncDetail"] = ["null": [String: Any]()]
        fields["quickBooksPaymentReviewJSON"] = ["text": ["_0": ""]]
        fields["milestoneDraftReceiptJSON"] = ["null": [String: Any]()]
        fields["quickBooksID"] = ["text": ["_0": ""]]
        billing["fields"] = fields
        body["billing"] = ["_0": billing]
        invoice["body"] = body
        records[index] = invoice
        root["records"] = records
        let forged = try JSONSerialization.data(withJSONObject: root)
        var receiptObject = try XCTUnwrap(JSONSerialization.jsonObject(
            with: StaffWorkspacePublicationContract.encode(vector.receipt)) as? [String: Any])
        receiptObject["contentSHA256"] = StaffReplicaManifest.hash(forged)
        receiptObject["payloadBytes"] = forged.count
        let receipt = try JSONDecoder().decode(StaffWorkspaceContentReceipt.self,
                                               from: JSONSerialization.data(withJSONObject: receiptObject))

        let (scope, plan, _) = try scopeAndPlan()
        let memory = MemoryStore()
        _ = try installMount(raw: forged, receipt: receipt, scope: scope, plan: plan.id, memory: memory)
        let store = memory.store
        XCTAssertThrowsError(try StaffWorkspaceOperationalAcceptanceStore.accept(store: store, scope: scope, plan: plan.id))
        XCTAssertNil(try StaffWorkspaceOperationalAcceptanceStore.load(store: store, scope: scope, plan: plan.id))
        // Mount retained.
        XCTAssertNotNil(try StaffWorkspaceOperationalMountStore.load(store: store, scope: scope, plan: plan.id))
        XCTAssertEqual(memory.saved[StaffWorkspaceOperationalMountStore.payloadKey(scope, plan.id)], forged)
    }

    @MainActor
    func testCorruptOrMismatchedContentSHA256FailsClosed() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (scope, plan, _) = try scopeAndPlan()
        let memory = MemoryStore()
        _ = try installMount(raw: raw, receipt: vector.receipt, scope: scope, plan: plan.id, memory: memory)
        // Tamper payload after mount meta written — load fails; accept must not write journal or delete meta.
        memory.saved[StaffWorkspaceOperationalMountStore.payloadKey(scope, plan.id)] = Data("tampered-operational-bytes".utf8)
        let store = memory.store
        XCTAssertThrowsError(try StaffWorkspaceOperationalAcceptanceStore.accept(store: store, scope: scope, plan: plan.id))
        XCTAssertNil(try StaffWorkspaceOperationalAcceptanceStore.load(store: store, scope: scope, plan: plan.id))
        XCTAssertNotNil(memory.saved[StaffWorkspaceOperationalMountStore.metaKey(scope, plan.id)])
        XCTAssertEqual(memory.saved[StaffWorkspaceOperationalMountStore.payloadKey(scope, plan.id)],
                       Data("tampered-operational-bytes".utf8))
    }

    @MainActor
    func testRemountIdempotentReAcceptSameHead() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (scope, plan, _) = try scopeAndPlan()
        let memory = MemoryStore()
        _ = try installMount(raw: raw, receipt: vector.receipt, scope: scope, plan: plan.id, memory: memory)
        let store = memory.store
        let first = try StaffWorkspaceOperationalAcceptanceStore.accept(store: store, scope: scope, plan: plan.id)
        let journalBytes = try XCTUnwrap(memory.saved[StaffWorkspaceOperationalAcceptanceStore.key(scope, plan.id)])
        let second = try StaffWorkspaceOperationalAcceptanceStore.accept(store: store, scope: scope, plan: plan.id)
        XCTAssertEqual(first.records.count, second.records.count)
        XCTAssertEqual(memory.saved[StaffWorkspaceOperationalAcceptanceStore.key(scope, plan.id)], journalBytes)
        // Exact remount of same bytes keeps acceptance.
        _ = try installMount(raw: raw, receipt: vector.receipt, scope: scope, plan: plan.id, memory: memory)
        let third = try StaffWorkspaceOperationalAcceptanceStore.accept(store: store, scope: scope, plan: plan.id)
        XCTAssertEqual(third.contentSHA256, first.contentSHA256)
        XCTAssertEqual(memory.saved[StaffWorkspaceOperationalAcceptanceStore.key(scope, plan.id)], journalBytes)
    }

    @MainActor
    func testFailedAcceptanceDoesNotDeleteMount() throws {
        let vector = try vector()
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(vector.payloadUtf8.utf8)) as? [String: Any])
        root["schema"] = "not-a-staff-content-schema"
        let forged = try JSONSerialization.data(withJSONObject: root)
        var receiptObject = try XCTUnwrap(JSONSerialization.jsonObject(
            with: StaffWorkspacePublicationContract.encode(vector.receipt)) as? [String: Any])
        receiptObject["contentSHA256"] = StaffReplicaManifest.hash(forged)
        receiptObject["payloadBytes"] = forged.count
        let receipt = try JSONDecoder().decode(StaffWorkspaceContentReceipt.self,
                                               from: JSONSerialization.data(withJSONObject: receiptObject))
        let (scope, plan, _) = try scopeAndPlan()
        let memory = MemoryStore()
        _ = try installMount(raw: forged, receipt: receipt, scope: scope, plan: plan.id, memory: memory)
        let metaBefore = try XCTUnwrap(memory.saved[StaffWorkspaceOperationalMountStore.metaKey(scope, plan.id)])
        let payloadBefore = try XCTUnwrap(memory.saved[StaffWorkspaceOperationalMountStore.payloadKey(scope, plan.id)])
        let store = memory.store
        XCTAssertThrowsError(try StaffWorkspaceOperationalAcceptanceStore.accept(store: store, scope: scope, plan: plan.id))
        XCTAssertEqual(memory.saved[StaffWorkspaceOperationalMountStore.metaKey(scope, plan.id)], metaBefore)
        XCTAssertEqual(memory.saved[StaffWorkspaceOperationalMountStore.payloadKey(scope, plan.id)], payloadBefore)
        XCTAssertNil(memory.saved[StaffWorkspaceOperationalAcceptanceStore.key(scope, plan.id)])
    }

    @MainActor
    func testCoordinatorAcceptMountedOperationalViewEntry() async throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
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
        let memory = MemoryStore()
        _ = try installMount(raw: raw, receipt: vector.receipt, scope: context.scope, plan: plan.id, memory: memory)
        let coordinator = StaffWorkspaceContentCoordinator(dependencies: .init(
            setup: { (context, [plan]) },
            check: { _ in throw StaffReplicaDeliveryError.access },
            request: { _, _, _ in throw StaffReplicaDeliveryError.access },
            store: memory.store,
            now: { base.now }))
        let view = try coordinator.acceptMountedOperationalView(plan: plan, context: context,
                                                                selectionID: vector.receipt.selectionID)
        XCTAssertEqual(view.contentSHA256, vector.receipt.contentSHA256)
        XCTAssertEqual(view.selectionID, vector.receipt.selectionID)
        let journal = try XCTUnwrap(StaffWorkspaceOperationalAcceptanceStore.load(
            store: memory.store, scope: context.scope, plan: plan.id))
        XCTAssertEqual(journal.contentSHA256, vector.receipt.contentSHA256)
        // Idempotent coordinator re-entry.
        let again = try coordinator.acceptMountedOperationalView(plan: plan, context: context,
                                                                 selectionID: vector.receipt.selectionID)
        XCTAssertEqual(again.records.count, view.records.count)
    }
    @MainActor
    func testReceiveAndLeaseAutoAcceptsContentV1() async throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let base = CloudKitStaffSharingTests()
        let plan = try base.plan()
        // Align receipt identity to the share plan used by CloudKit fixtures.
        var receiptObject = try XCTUnwrap(JSONSerialization.jsonObject(
            with: StaffWorkspacePublicationContract.encode(vector.receipt)) as? [String: Any])
        receiptObject["companyID"] = plan.companyID.uuidString.lowercased()
        receiptObject["replicaID"] = plan.replicaID.uuidString.lowercased()
        receiptObject["membershipID"] = plan.id.uuidString.lowercased()
        receiptObject["memberRevision"] = plan.memberRevision
        receiptObject["memberRole"] = plan.memberRole
        receiptObject["shareRevision"] = plan.revision
        receiptObject["projectionPolicy"] = plan.projectionPolicy
        receiptObject["environment"] = plan.environment
        receiptObject["selectionID"] = vector.receipt.selectionID
        receiptObject["sourceSequence"] = vector.receipt.sourceSequence
        receiptObject["contentSHA256"] = StaffReplicaManifest.hash(raw)
        receiptObject["payloadBytes"] = raw.count
        // Payload company/replica fields must match the receipt/plan for accept parse.
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        root["companyID"] = plan.companyID.uuidString.lowercased()
        root["replicaID"] = plan.replicaID.uuidString.lowercased()
        root["membershipID"] = plan.id.uuidString.lowercased()
        root["memberRevision"] = plan.memberRevision
        root["memberRole"] = plan.memberRole
        root["shareRevision"] = plan.revision
        root["projectionPolicy"] = plan.projectionPolicy
        root["environment"] = plan.environment
        root["sourceSequence"] = vector.receipt.sourceSequence
        let aligned = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        receiptObject["contentSHA256"] = StaffReplicaManifest.hash(aligned)
        receiptObject["payloadBytes"] = aligned.count
        let content = try JSONDecoder().decode(StaffWorkspaceContentReceipt.self,
                                               from: JSONSerialization.data(withJSONObject: receiptObject))
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        let sealed = try AES.GCM.seal(aligned, using: key, authenticating: StaffWorkspaceCloudSealResponse.authenticatedScope(content)).combined!
        let sealResponse = StaffWorkspaceCloudSealResponse(
            schema: StaffWorkspaceCloudSealResponse.schema, content: content,
            sealedSHA256: StaffReplicaManifest.hash(sealed), sealedBytes: sealed.count,
            keyBase64: keyData.base64EncodedString(), nonceBase64: Data(sealed.prefix(12)).base64EncodedString())
        let package = try StaffWorkspaceCloudSealedPackage(content: content, raw: aligned, response: sealResponse)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GAWSAcceptReceive-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        var remote: [String: (StaffWorkspaceCloudSealManifest, Data?)] = [:]
        remote[StaffWorkspaceCloudRecords.headName] = (package.manifest, nil)
        remote[StaffWorkspaceCloudRecords.payloadName(package.manifest.selectionID)] = (package.manifest, package.bytes)

        let sharedZone = CKRecordZone.ID(zoneName: plan.zoneName, ownerName: base.ownerName)
        let participantIO = StaffReplicaCloudIO(zone: sharedZone, authorize: {}, read: { ids in
            var result: [CKRecord.ID: CKRecord] = [:]
            for id in ids {
                guard let value = remote[id.recordName] else { continue }
                var asset: CKAsset?
                if let data = value.1 {
                    let url = directory.appendingPathComponent(UUID().uuidString)
                    try data.write(to: url); asset = CKAsset(fileURL: url)
                }
                result[id] = try StaffWorkspaceCloudRecords.make(value.0, plan: plan, zone: id.zoneID, asset: asset)
            }
            return result
        }, save: { _ in XCTFail("Staff receive must not write CloudKit") })

        var saved: [String: Data] = [:]
        let invitation = URL(string: "https://www.icloud.com/share/fixture-full-workspace")!
        let stamp = CloudKitStaffSetupStamp(
            session: .init(backendOrigin: "https://fixture.gunnaire.invalid", email: base.member.email,
                           tokenFingerprint: String(repeating: "1", count: 64), expiresAt: base.now.addingTimeInterval(3600)),
            accountGeneration: UUID())
        let context = CloudKitStaffSetupController.Context(
            stamp: stamp, workspace: base.workspace,
            member: .init(email: base.member.email, role: plan.memberRole, isActive: true, createdAt: base.instant),
            account: .init(environment: plan.environment, accountHash: base.participantHash, recordName: base.participantName))
        let dependencies = StaffWorkspaceContentDependencies(
            setup: { (context, [plan]) },
            check: { _ in throw StaffReplicaDeliveryError.access },
            request: { _, _, _ in throw StaffReplicaDeliveryError.access },
            store: .init(read: { saved[$0] }, write: { saved[$0] = $1 }),
            ownerCloudIO: nil,
            participantCloudIO: { _, _, _, _ in participantIO },
            invitationURL: { _, _ in invitation },
            staffRequest: { _ in try StaffWorkspacePublicationContract.encode(sealResponse) },
            now: { base.now })
        let coordinator = StaffWorkspaceContentCoordinator(dependencies: dependencies)
        let first = try await coordinator.receiveAndLease(plan: plan, context: context, invitation: invitation)
        XCTAssertTrue(first.operationalMounted)
        XCTAssertTrue(first.operationalAccepted)
        XCTAssertFalse(first.alreadyLeased)
        let journal = try XCTUnwrap(StaffWorkspaceOperationalAcceptanceStore.load(
            store: .init(read: { saved[$0] }, write: { saved[$0] = $1 }),
            scope: context.scope, plan: plan.id))
        XCTAssertEqual(journal.contentSHA256, content.contentSHA256)
        XCTAssertEqual(journal.selectionID, content.selectionID)
        // Idempotent re-receive keeps acceptance.
        let second = try await coordinator.receiveAndLease(plan: plan, context: context, invitation: invitation)
        XCTAssertTrue(second.alreadyLeased)
        XCTAssertTrue(second.operationalAccepted)
    }


}
