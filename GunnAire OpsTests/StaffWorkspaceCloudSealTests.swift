import Foundation
import CloudKit
import CryptoKit
import XCTest
@testable import GunnAire_Ops

final class StaffWorkspaceCloudSealTests: XCTestCase {
    private let fixtureCompany = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    private let fixtureReplica = "11111111-2222-4333-8444-555555555555"
    private let fixtureMembership = "66666666-7777-4888-8999-aaaaaaaaaaaa"
    private let fixtureSelection = "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
    private let fixtureKeyB64 = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
    private let fixtureNonceB64 = "AAECAwQFBgcICQoL"
    private let fixtureRaw = Data("gunnaire-full-workspace-fixture-v1".utf8)
    private let fixtureContentSHA = "e4439cc0e840c41f60e6b24593c2c05eabc7b3bdaa078d47c15fb6a770b531f1"
    private let fixtureSealedHex = "000102030405060708090a0b2077b875a48cb07ea027e2e7ddc40f02f1bdf44491183a515e0e9df1681b659f7721937dc474a0520de3a8c75dfced06a99c"
    private let fixtureSealedSHA256 = "46e4ab9572cdd81dbf44f0497bb3c15af55d62b870cd6b3f9e668bf536fb6f1c"
    private let fixtureAAD = Data("""
gunnaire-full-workspace-cloud-seal-v1
aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
development
11111111-2222-4333-8444-555555555555
66666666-7777-4888-8999-aaaaaaaaaaaa
rev-1
Field Technician
2
field-assigned-jobs-v1
bbbbbbbb-cccc-4ddd-8eee-ffffffffffff
9
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
e4439cc0e840c41f60e6b24593c2c05eabc7b3bdaa078d47c15fb6a770b531f1
""".utf8)

    private func receipt(companyID: String? = nil, replicaID: String? = nil, membershipID: String? = nil,
                         memberRevision: String = "rev-1", memberRole: String = "Field Technician",
                         shareRevision: Int = 2, projectionPolicy: String = "field-assigned-jobs-v1",
                         selectionID: String? = nil, sourceSequence: Int = 9,
                         selectionSHA256: String = String(repeating: "a", count: 64),
                         contentSHA256: String? = nil, payloadBytes: Int? = nil) throws -> StaffWorkspaceContentReceipt {
        let rawHash = contentSHA256 ?? fixtureContentSHA
        let object: [String: Any] = [
            "schema": "staff-workspace-delivery-v1",
            "contentSchema": "staff-workspace-content-v1",
            "selectionID": selectionID ?? fixtureSelection,
            "companyID": companyID ?? fixtureCompany,
            "environment": "development",
            "replicaID": replicaID ?? fixtureReplica,
            "membershipID": membershipID ?? fixtureMembership,
            "memberRevision": memberRevision,
            "memberRole": memberRole,
            "shareRevision": shareRevision,
            "projectionPolicy": projectionPolicy,
            "sourceSequence": sourceSequence,
            "selectionSHA256": selectionSHA256,
            "contentSHA256": rawHash,
            "sourceSchema": StaffWorkspacePublicationContract.schema,
            "sourceSchemaDigest": StaffWorkspacePublicationContract.schemaDigest,
            "fieldPolicy": "staff-operational-fields-v1",
            "discriminatorSchema": "staff-workspace-discriminators-v1",
            "structuredSchema": "staff-operational-evidence-v1",
            "billingSchema": "staff-billing-view-v1",
            "coverage": StaffWorkspacePublicationContract.kinds.sorted(),
            "recordCount": 0,
            "payloadBytes": payloadBytes ?? fixtureRaw.count,
            "chunkBytes": StaffWorkspaceContentReceipt.chunkSize,
            "currentSourceSequence": sourceSequence,
            "sourceCurrent": true,
            "operationalWorkspaceReady": false,
            "fieldProjectionRequired": false,
            "localCloudKitProofRequired": true,
        ]
        return try JSONDecoder().decode(StaffWorkspaceContentReceipt.self,
                                        from: JSONSerialization.data(withJSONObject: object))
    }

    func testAADBytesMatchPythonCloudFixture() throws {
        let content = try receipt()
        XCTAssertEqual(StaffWorkspaceCloudSealResponse.authenticatedScope(content), fixtureAAD)
        XCTAssertEqual(StaffReplicaManifest.hash(fixtureRaw), fixtureContentSHA)
    }

    func testSealRoundTripMatchesPythonSealedDigestAndRejectsTampering() throws {
        let content = try receipt()
        let sealed = Data(hexString: fixtureSealedHex)!
        XCTAssertEqual(StaffReplicaManifest.hash(sealed), fixtureSealedSHA256)
        let response = StaffWorkspaceCloudSealResponse(
            schema: StaffWorkspaceCloudSealResponse.schema, content: content,
            sealedSHA256: fixtureSealedSHA256, sealedBytes: sealed.count,
            keyBase64: fixtureKeyB64, nonceBase64: fixtureNonceB64)
        let package = try StaffWorkspaceCloudSealedPackage(content: content, raw: fixtureRaw, response: response)
        XCTAssertEqual(package.bytes, sealed)
        XCTAssertEqual(package.opened, fixtureRaw)
        XCTAssertEqual(try StaffWorkspaceCloudSealedPackage(manifest: package.manifest, bytes: package.bytes, key: package.key).opened, fixtureRaw)

        var badCipher = sealed; badCipher[badCipher.count - 1] ^= 1
        XCTAssertThrowsError(try StaffWorkspaceCloudSealedPackage(manifest: package.manifest, bytes: badCipher, key: package.key))
        XCTAssertThrowsError(try StaffWorkspaceCloudSealedPackage(manifest: package.manifest, bytes: sealed, key: Data(repeating: 0, count: 32)))
        let tampered = try receipt(selectionSHA256: String(repeating: "c", count: 64))
        let badManifest = try StaffWorkspaceCloudSealManifest(content: tampered, sealedSHA256: fixtureSealedSHA256, sealedBytes: sealed.count)
        XCTAssertThrowsError(try StaffWorkspaceCloudSealedPackage(manifest: badManifest, bytes: sealed, key: package.key))
    }

    @MainActor func testHTTPPolicyAllowsCloudSealAndRejectsSiblings() throws {
        let plan = try CloudKitStaffSharingTests().plan()
        let request = StaffWorkspaceSelectionRequest(plan: plan, sequence: 1, operation: UUID(uuidString: fixtureSelection)!)
        let body = try StaffWorkspacePublicationContract.encode(StaffWorkspaceContentRequest(request))
        let postPath = StaffWorkspaceContentHTTPPolicy.root(plan) + "/" + request.operationID + "/content/cloud-seal"
        let getPath = StaffWorkspaceContentHTTPPolicy.path(plan, request: request, suffix: "/content/cloud-seal")
        XCTAssertTrue(StaffWorkspaceContentHTTPPolicy.allows(path: postPath, method: "POST", body: body))
        XCTAssertTrue(StaffWorkspaceContentHTTPPolicy.allows(path: getPath, method: "GET", body: nil))
        XCTAssertFalse(StaffWorkspaceContentHTTPPolicy.allows(path: postPath + "?companyID=" + request.companyID, method: "POST", body: body))
        XCTAssertFalse(StaffWorkspaceContentHTTPPolicy.allows(path: getPath + "&offset=0", method: "GET", body: nil))
        XCTAssertFalse(StaffWorkspaceContentHTTPPolicy.allows(path: "https://evil.invalid" + getPath, method: "GET", body: nil))
        XCTAssertFalse(StaffWorkspaceContentHTTPPolicy.allows(path: postPath, method: "DELETE", body: nil))
        var bad = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        bad["contentSchema"] = "core-field-v1"
        XCTAssertFalse(StaffWorkspaceContentHTTPPolicy.allows(path: postPath, method: "POST",
                                                              body: try JSONSerialization.data(withJSONObject: bad)))
        // Existing content/chunks twin still works; cloud-seal is not confused with chunks.
        let chunks = StaffWorkspaceContentHTTPPolicy.path(plan, request: request, suffix: "/content/chunks", offset: 0)
        XCTAssertTrue(StaffWorkspaceContentHTTPPolicy.allows(path: chunks, method: "GET", body: nil))
        let keyPath = StaffWorkspaceCloudTransfer.cloudKeyPath(plan: plan, request: request)
        XCTAssertEqual(keyPath, StaffWorkspaceContentHTTPPolicy.path(plan, request: request, suffix: "/content/cloud-key"))
        XCTAssertTrue(StaffWorkspaceContentHTTPPolicy.allows(path: keyPath, method: "GET", body: nil))
        XCTAssertFalse(StaffWorkspaceContentHTTPPolicy.allows(path: keyPath, method: "POST", body: body))
        XCTAssertFalse(StaffWorkspaceContentHTTPPolicy.allows(path: keyPath + "&offset=0", method: "GET", body: nil))
        XCTAssertFalse(StaffWorkspaceContentHTTPPolicy.allows(path: keyPath, method: "DELETE", body: nil))
    }

    @MainActor func testCloudTransferMakeManifestPublishAndParticipantReceive() async throws {
        let base = CloudKitStaffSharingTests()
        let plan = try base.plan()
        let content = try receipt(
            companyID: plan.companyID.uuidString.lowercased(),
            replicaID: plan.replicaID.uuidString.lowercased(),
            membershipID: plan.id.uuidString.lowercased(),
            memberRevision: plan.memberRevision,
            memberRole: plan.memberRole,
            shareRevision: plan.revision,
            projectionPolicy: plan.projectionPolicy,
            selectionID: fixtureSelection,
            sourceSequence: 9,
            selectionSHA256: String(repeating: "a", count: 64),
            contentSHA256: StaffReplicaManifest.hash(fixtureRaw),
            payloadBytes: fixtureRaw.count)
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        let sealed = try AES.GCM.seal(fixtureRaw, using: key, authenticating: StaffWorkspaceCloudSealResponse.authenticatedScope(content)).combined!
        let response = StaffWorkspaceCloudSealResponse(
            schema: StaffWorkspaceCloudSealResponse.schema, content: content,
            sealedSHA256: StaffReplicaManifest.hash(sealed), sealedBytes: sealed.count,
            keyBase64: keyData.base64EncodedString(), nonceBase64: Data(sealed.prefix(12)).base64EncodedString())
        let package = try StaffWorkspaceCloudSealedPackage(content: content, raw: fixtureRaw, response: response)

        let zone = CKRecordZone.ID(zoneName: plan.zoneName, ownerName: CKCurrentUserDefaultName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GAWSCloudTest-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let head = try StaffWorkspaceCloudRecords.make(package.manifest, plan: plan, zone: zone)
        XCTAssertEqual(head.recordType, "GAStaffWorkspaceHead")
        XCTAssertEqual(head.recordID.recordName, StaffWorkspaceCloudRecords.headName)
        XCTAssertNotEqual(head.recordType, "GAStaffReplicaHead")
        XCTAssertNotEqual(StaffWorkspaceCloudRecords.headName, StaffReplicaCloudRecords.headName)

        let seedURL = directory.appendingPathComponent("seed.sealed")
        try package.bytes.write(to: seedURL)
        let payloadSeed = try StaffWorkspaceCloudRecords.make(package.manifest, plan: plan, zone: zone, asset: CKAsset(fileURL: seedURL))
        XCTAssertEqual(payloadSeed.recordType, "GAStaffWorkspaceSealedPayload")
        XCTAssertNotEqual(payloadSeed.recordType, "GAStaffReplicaSealedPayload")
        XCTAssertTrue(payloadSeed.recordID.recordName.hasPrefix("full-workspace-cloud-seal-v1-"))

        var remote: [String: (StaffWorkspaceCloudSealManifest, Data?)] = [:]
        var afterRead: (() -> Void)?
        var loseSaveReply = true
        let io = StaffReplicaCloudIO(zone: zone, authorize: {}, read: { ids in
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
            let callback = afterRead; afterRead = nil; callback?()
            return result
        }, save: { values in
            for value in values {
                let payload = value.recordType == "GAStaffWorkspaceSealedPayload"
                let manifest = try StaffWorkspaceCloudRecords.manifest(value, plan: plan, workspace: base.workspace,
                                                                       zone: zone, payload: payload, now: base.now)
                let bytes = payload ? try StaffWorkspaceCloudRecords.payload(value, manifest: manifest, key: keyData).bytes : nil
                let text = String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self)
                XCTAssertFalse(text.contains("keyBase64"))
                XCTAssertFalse(text.contains("nonceBase64"))
                XCTAssertFalse(text.contains(keyData.base64EncodedString()))
                remote[value.recordID.recordName] = (manifest, bytes)
            }
            if loseSaveReply { loseSaveReply = false; throw URLError(.networkConnectionLost) }
        })

        do {
            try await StaffWorkspaceCloudTransfer.publish(package, plan: plan, workspace: base.workspace, io: io, now: { base.now })
            XCTFail("The simulated lost save acknowledgement must be surfaced")
        } catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        try await StaffWorkspaceCloudTransfer.publish(package, plan: plan, workspace: base.workspace, io: io, now: { base.now })
        try await StaffWorkspaceCloudTransfer.verifyOwnerPublication(package, plan: plan, workspace: base.workspace, io: io, now: base.now)
        XCTAssertEqual(remote[StaffWorkspaceCloudRecords.headName]?.0, package.manifest)
        XCTAssertEqual(remote[StaffWorkspaceCloudRecords.payloadName(package.manifest.selectionID)]?.1, package.bytes)

        let sharedZone = CKRecordZone.ID(zoneName: plan.zoneName, ownerName: base.ownerName)
        let participantIO = StaffReplicaCloudIO(zone: sharedZone, authorize: {}, read: io.read, save: io.save)
        let downloaded = try await StaffWorkspaceCloudTransfer.download(plan: plan, workspace: base.workspace,
                                                                        io: participantIO, key: keyData, now: { base.now })
        XCTAssertEqual(downloaded.opened, fixtureRaw)

        var advanced = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(content)) as? [String: Any])
        advanced["sourceSequence"] = content.sourceSequence + 1
        advanced["currentSourceSequence"] = content.sourceSequence + 1
        advanced["selectionID"] = UUID().uuidString.lowercased()
        let laterContent = try JSONDecoder().decode(StaffWorkspaceContentReceipt.self, from: JSONSerialization.data(withJSONObject: advanced))
        let later = try StaffWorkspaceCloudSealManifest(content: laterContent,
            sealedSHA256: String(repeating: "b", count: 64), sealedBytes: package.bytes.count)
        afterRead = { remote[StaffWorkspaceCloudRecords.headName] = (later, nil) }
        do {
            try await StaffWorkspaceCloudTransfer.publish(package, plan: plan, workspace: base.workspace, io: io, now: { base.now })
            XCTFail("Full-workspace retry must not confirm a stale head")
        } catch { XCTAssertEqual(error as? StaffReplicaDeliveryError, .superseded) }
        XCTAssertEqual(remote[StaffWorkspaceCloudRecords.headName]?.0, later)
    }

    @MainActor func testParticipantReceiveAndLeaseHappyPathAndInvitationFailure() async throws {
        let base = CloudKitStaffSharingTests()
        let plan = try base.plan()
        let selection = UUID(uuidString: fixtureSelection)!
        let raw = fixtureRaw
        let content = try receipt(
            companyID: plan.companyID.uuidString.lowercased(),
            replicaID: plan.replicaID.uuidString.lowercased(),
            membershipID: plan.id.uuidString.lowercased(),
            memberRevision: plan.memberRevision,
            memberRole: plan.memberRole,
            shareRevision: plan.revision,
            projectionPolicy: plan.projectionPolicy,
            selectionID: fixtureSelection,
            sourceSequence: 9,
            selectionSHA256: String(repeating: "a", count: 64),
            contentSHA256: StaffReplicaManifest.hash(raw),
            payloadBytes: raw.count)
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        let sealed = try AES.GCM.seal(raw, using: key, authenticating: StaffWorkspaceCloudSealResponse.authenticatedScope(content)).combined!
        let sealResponse = StaffWorkspaceCloudSealResponse(
            schema: StaffWorkspaceCloudSealResponse.schema, content: content,
            sealedSHA256: StaffReplicaManifest.hash(sealed), sealedBytes: sealed.count,
            keyBase64: keyData.base64EncodedString(), nonceBase64: Data(sealed.prefix(12)).base64EncodedString())
        let package = try StaffWorkspaceCloudSealedPackage(content: content, raw: raw, response: sealResponse)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GAWSReceiveTest-" + UUID().uuidString, isDirectory: true)
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
        var keyCalls = 0
        var serverAllows = true
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
            staffRequest: { path in
                keyCalls += 1
                guard serverAllows else { throw StaffReplicaDeliveryError.access }
                XCTAssertEqual(URLComponents(string: path)?.path.hasSuffix("/content/cloud-key"), true)
                XCTAssertTrue(path.contains(selection.uuidString.lowercased()))
                return try StaffWorkspacePublicationContract.encode(sealResponse)
            },
            now: { base.now })

        let coordinator = StaffWorkspaceContentCoordinator(dependencies: dependencies)
        let first = try await coordinator.receiveAndLease(plan: plan, context: context, invitation: invitation)
        XCTAssertEqual(first.selectionID, fixtureSelection)
        XCTAssertFalse(first.alreadyLeased)
        XCTAssertTrue(first.operationalMounted)
        XCTAssertFalse(first.operationalAccepted) // opaque fixture is not content-v1
        XCTAssertEqual(keyCalls, 2) // key + confirm

        let receiveKey = StaffWorkspaceContentCoordinator.receiveKey(context.scope, plan.id)
        let journal = try StaffWorkspacePublicationContract.decode(
            StaffWorkspaceCloudReceiveJournal.self, from: XCTUnwrap(saved[receiveKey]), maximum: 8192)
        XCTAssertEqual(journal.cloudReceivedOperation, fixtureSelection)
        let journalText = String(decoding: saved[receiveKey]!, as: UTF8.self)
        XCTAssertFalse(journalText.contains(keyData.base64EncodedString()))
        XCTAssertFalse(journalText.contains("keyBase64"))
        XCTAssertFalse(journalText.contains("nonceBase64"))
        let mountKey = StaffWorkspaceOperationalMountStore.metaKey(context.scope, plan.id)
        let payloadKey = StaffWorkspaceOperationalMountStore.payloadKey(context.scope, plan.id)
        let mount = try StaffWorkspacePublicationContract.decode(
            StaffWorkspaceOperationalMount.self, from: XCTUnwrap(saved[mountKey]), maximum: 8192)
        XCTAssertEqual(mount.selectionID, fixtureSelection)
        XCTAssertEqual(saved[payloadKey], raw)
        let mountText = String(decoding: saved[mountKey]!, as: UTF8.self)
        XCTAssertFalse(mountText.contains(keyData.base64EncodedString()))
        XCTAssertFalse(mountText.contains("keyBase64"))

        let second = try await coordinator.receiveAndLease(plan: plan, context: context, invitation: invitation)
        XCTAssertTrue(second.alreadyLeased)
        XCTAssertTrue(second.operationalMounted)
        XCTAssertFalse(second.operationalAccepted)
        XCTAssertEqual(keyCalls, 3) // A cached mount is not lasting business authority.
        let retained = saved
        serverAllows = false
        do {
            _ = try await coordinator.receiveAndLease(plan: plan, context: context, invitation: invitation)
            XCTFail("Cached receive must recheck current business authorization")
        } catch { XCTAssertEqual(error as? StaffReplicaDeliveryError, .access) }
        XCTAssertEqual(saved, retained)
        serverAllows = true

        // Missing invitation fails closed without writing a lease marker overwrite.
        let denied = StaffWorkspaceContentCoordinator(dependencies: .init(
            setup: { (context, [plan]) },
            check: { _ in },
            request: { _, _, _ in Data() },
            store: .init(read: { saved[$0] }, write: { saved[$0] = $1 }),
            ownerCloudIO: nil,
            participantCloudIO: { _, _, _, _ in participantIO },
            invitationURL: { _, _ in nil },
            staffRequest: { _ in try StaffWorkspacePublicationContract.encode(sealResponse) },
            now: { base.now }))
        do {
            _ = try await denied.receiveAndLease(plan: plan, context: context, invitation: nil)
            XCTFail("Expected invitation failure")
        } catch {
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .access)
        }

        // Owner-context must not use the staff receive path.
        let ownerContext = CloudKitStaffSetupController.Context(
            stamp: stamp, workspace: base.workspace,
            member: .init(email: "owner@gunnaire.com", role: AppUserRole.admin.rawValue, isActive: true, createdAt: base.instant),
            account: .init(environment: plan.environment, accountHash: base.ownerHash, recordName: base.ownerName))
        do {
            _ = try await coordinator.receiveAndLease(plan: plan, context: ownerContext, invitation: invitation)
            XCTFail("Expected owner blocked from staff receive")
        } catch {
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .access)
        }

        // Authority mismatch on cloud-key sealed digest fails without leasing a forged package.
        var forgedSaved: [String: Data] = [:]
        let forgedSeal = StaffWorkspaceCloudSealResponse(
            schema: StaffWorkspaceCloudSealResponse.schema, content: content,
            sealedSHA256: String(repeating: "b", count: 64), sealedBytes: sealed.count,
            keyBase64: keyData.base64EncodedString(), nonceBase64: Data(sealed.prefix(12)).base64EncodedString())
        let forged = StaffWorkspaceContentCoordinator(dependencies: .init(
            setup: { (context, [plan]) },
            check: { _ in },
            request: { _, _, _ in Data() },
            store: .init(read: { forgedSaved[$0] }, write: { forgedSaved[$0] = $1 }),
            ownerCloudIO: nil,
            participantCloudIO: { _, _, _, _ in participantIO },
            invitationURL: { _, _ in invitation },
            staffRequest: { _ in try StaffWorkspacePublicationContract.encode(forgedSeal) },
            now: { base.now }))
        do {
            _ = try await forged.receiveAndLease(plan: plan, context: context, invitation: invitation)
            XCTFail("Expected authority failure")
        } catch {
            XCTAssertNil(forgedSaved[receiveKey])
        }
    }

    @MainActor func testReceiveControllerSurfacesLeaseAfterCoreReceive() async throws {
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
        let manifest = StaffReplicaManifest(
            protocolVersion: 1, schema: StaffReplicaCoreSource.schemaVersion, coverage: StaffReplicaCoreSource.recordKinds,
            operationID: UUID(), membershipID: plan.id, companyID: plan.companyID, environment: plan.environment,
            replicaID: plan.replicaID, memberRevision: plan.memberRevision, projectionPolicy: plan.projectionPolicy,
            sourceSequence: 1, authorizationSequence: 1, payloadSHA256: String(repeating: "a", count: 64),
            payloadBytes: 16, recordCount: 0, createdAt: base.instant)
        let invitation = URL(string: "https://www.icloud.com/share/fixture")!
        let controller = StaffReplicaReceiveController(dependencies: .init(check: { _ in }, download: { _, _, _ in manifest },
            receiveFullWorkspace: { _, _, _ in .init(selectionID: self.fixtureSelection, alreadyLeased: false, operationalMounted: true, operationalAccepted: false) },
            now: { base.now }))
        _ = await controller.refresh(context: context, plan: plan, invitation: invitation)
        XCTAssertEqual(controller.received, manifest)
        XCTAssertTrue(controller.message.contains("Full workspace verification is still required"))
        XCTAssertNil(controller.hostedStore)
    }


    @MainActor func testOperationalMountRecoversPartialWriteAndRejectsOlderOrMismatchedSnapshots() async throws {
        let base = CloudKitStaffSharingTests()
        let plan = try base.plan()
        let selection = UUID(uuidString: fixtureSelection)!
        let raw = fixtureRaw
        let content = try receipt(
            companyID: plan.companyID.uuidString.lowercased(),
            replicaID: plan.replicaID.uuidString.lowercased(),
            membershipID: plan.id.uuidString.lowercased(),
            memberRevision: plan.memberRevision,
            memberRole: plan.memberRole,
            shareRevision: plan.revision,
            projectionPolicy: plan.projectionPolicy,
            selectionID: fixtureSelection,
            sourceSequence: 9,
            selectionSHA256: String(repeating: "a", count: 64),
            contentSHA256: StaffReplicaManifest.hash(raw),
            payloadBytes: raw.count)
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        let sealed = try AES.GCM.seal(raw, using: key, authenticating: StaffWorkspaceCloudSealResponse.authenticatedScope(content)).combined!
        let sealResponse = StaffWorkspaceCloudSealResponse(
            schema: StaffWorkspaceCloudSealResponse.schema, content: content,
            sealedSHA256: StaffReplicaManifest.hash(sealed), sealedBytes: sealed.count,
            keyBase64: keyData.base64EncodedString(), nonceBase64: Data(sealed.prefix(12)).base64EncodedString())
        let package = try StaffWorkspaceCloudSealedPackage(content: content, raw: raw, response: sealResponse)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GAWSMountTest-" + UUID().uuidString, isDirectory: true)
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

        let stamp = CloudKitStaffSetupStamp(
            session: .init(backendOrigin: "https://fixture.gunnaire.invalid", email: base.member.email,
                           tokenFingerprint: String(repeating: "1", count: 64), expiresAt: base.now.addingTimeInterval(3600)),
            accountGeneration: UUID())
        let context = CloudKitStaffSetupController.Context(
            stamp: stamp, workspace: base.workspace,
            member: .init(email: base.member.email, role: plan.memberRole, isActive: true, createdAt: base.instant),
            account: .init(environment: plan.environment, accountHash: base.participantHash, recordName: base.participantName))
        let invitation = URL(string: "https://www.icloud.com/share/fixture-full-workspace")!

        // Partial payload write before meta/lease — remount completes without replacing newer data.
        var saved: [String: Data] = [:]
        let payloadKey = StaffWorkspaceOperationalMountStore.payloadKey(context.scope, plan.id)
        let metaKey = StaffWorkspaceOperationalMountStore.metaKey(context.scope, plan.id)
        let receiveKey = StaffWorkspaceContentCoordinator.receiveKey(context.scope, plan.id)
        saved[payloadKey] = raw
        XCTAssertNil(try StaffWorkspaceOperationalMountStore.load(store: .init(read: { saved[$0] }, write: { saved[$0] = $1 }),
                                                                  scope: context.scope, plan: plan.id))

        var keyCalls = 0
        let coordinator = StaffWorkspaceContentCoordinator(dependencies: .init(
            setup: { (context, [plan]) },
            check: { _ in throw StaffReplicaDeliveryError.access },
            request: { _, _, _ in throw StaffReplicaDeliveryError.access },
            store: .init(read: { saved[$0] }, write: { saved[$0] = $1 }),
            ownerCloudIO: nil,
            participantCloudIO: { _, _, _, _ in participantIO },
            invitationURL: { _, _ in invitation },
            staffRequest: { path in
                keyCalls += 1
                XCTAssertTrue(path.contains(selection.uuidString.lowercased()))
                return try StaffWorkspacePublicationContract.encode(sealResponse)
            },
            now: { base.now }))
        let recovered = try await coordinator.receiveAndLease(plan: plan, context: context, invitation: invitation)
        XCTAssertTrue(recovered.operationalMounted)
        XCTAssertFalse(recovered.operationalAccepted)
        XCTAssertFalse(recovered.alreadyLeased)
        XCTAssertEqual(saved[payloadKey], raw)
        XCTAssertNotNil(saved[metaKey])
        let recoveredJournal = try StaffWorkspacePublicationContract.decode(
            StaffWorkspaceCloudReceiveJournal.self, from: XCTUnwrap(saved[receiveKey]), maximum: 8192)
        XCTAssertEqual(recoveredJournal.cloudReceivedOperation, fixtureSelection)

        // Lease without mount recovers by reopening once.
        saved.removeValue(forKey: metaKey)
        saved.removeValue(forKey: payloadKey)
        let remounted = try await coordinator.receiveAndLease(plan: plan, context: context, invitation: invitation)
        XCTAssertTrue(remounted.operationalMounted)
        XCTAssertFalse(remounted.operationalAccepted)
        XCTAssertFalse(remounted.alreadyLeased)
        XCTAssertEqual(saved[payloadKey], raw)

        // Older head cannot replace a newer retained mount.
        let newerRaw = Data("gunnaire-full-workspace-fixture-v2-newer".utf8)
        // Build a strictly newer mount locally.
        let newerContent = try receipt(
            companyID: plan.companyID.uuidString.lowercased(),
            replicaID: plan.replicaID.uuidString.lowercased(),
            membershipID: plan.id.uuidString.lowercased(),
            memberRevision: plan.memberRevision,
            memberRole: plan.memberRole,
            shareRevision: plan.revision,
            projectionPolicy: plan.projectionPolicy,
            selectionID: "cccccccc-dddd-4eee-8fff-000000000000",
            sourceSequence: 10,
            selectionSHA256: String(repeating: "d", count: 64),
            contentSHA256: StaffReplicaManifest.hash(newerRaw),
            payloadBytes: newerRaw.count)
        let newerSealKey = SymmetricKey(size: .bits256)
        let newerKeyData = newerSealKey.withUnsafeBytes { Data($0) }
        let newerSealed = try AES.GCM.seal(newerRaw, using: newerSealKey,
                                           authenticating: StaffWorkspaceCloudSealResponse.authenticatedScope(newerContent)).combined!
        let newerResponse = StaffWorkspaceCloudSealResponse(
            schema: StaffWorkspaceCloudSealResponse.schema, content: newerContent,
            sealedSHA256: StaffReplicaManifest.hash(newerSealed), sealedBytes: newerSealed.count,
            keyBase64: newerKeyData.base64EncodedString(), nonceBase64: Data(newerSealed.prefix(12)).base64EncodedString())
        let newerPackage = try StaffWorkspaceCloudSealedPackage(content: newerContent, raw: newerRaw, response: newerResponse)
        _ = try StaffWorkspaceOperationalMountStore.install(
            opened: newerPackage.opened, manifest: newerPackage.manifest,
            store: .init(read: { saved[$0] }, write: { saved[$0] = $1 }),
            scope: context.scope, plan: plan.id, check: {})
        // Clear the older lease marker so the older CK head is evaluated against the newer mount.
        saved.removeValue(forKey: receiveKey)
        do {
            _ = try await coordinator.receiveAndLease(plan: plan, context: context, invitation: invitation)
            XCTFail("Expected superseded older head")
        } catch {
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .superseded)
            let retained = try XCTUnwrap(StaffWorkspaceOperationalMountStore.load(
                store: .init(read: { saved[$0] }, write: { saved[$0] = $1 }), scope: context.scope, plan: plan.id))
            XCTAssertEqual(retained.0.sourceSequence, 10)
            XCTAssertEqual(retained.1, newerRaw)
        }

        // Equal-sequence mismatched bytes fail closed without clobbering.
        saved.removeValue(forKey: metaKey)
        saved.removeValue(forKey: payloadKey)
        saved.removeValue(forKey: receiveKey)
        saved[payloadKey] = Data("tampered-equal-sequence".utf8)
        let equalMount = try StaffWorkspaceOperationalMount(scope: context.scope, planID: plan.id, manifest: package.manifest)
        // Force equal-sequence meta with wrong payload retained separately via direct writes after install rejection path.
        // Install should reject changed equal-sequence when a complete mismatched mount exists.
        saved[metaKey] = try StaffWorkspacePublicationContract.encode(equalMount)
        // Corrupt payload hash vs meta — load fails closed and install from receive still cannot silently wipe it.
        do {
            _ = try StaffWorkspaceOperationalMountStore.load(
                store: .init(read: { saved[$0] }, write: { saved[$0] = $1 }), scope: context.scope, plan: plan.id)
            XCTFail("Expected corrupt mount retention failure")
        } catch {
            XCTAssertEqual(error as? StaffReplicaDeliveryError, .storage)
        }
        XCTAssertEqual(saved[payloadKey], Data("tampered-equal-sequence".utf8))
        XCTAssertNotNil(saved[metaKey])
    }


    func testSealReceiptRequiresExactFreshnessCoverageAndSchema() throws {
        let original = try receipt()
        let response = StaffWorkspaceCloudSealResponse(schema: StaffWorkspaceCloudSealResponse.schema,
            content: original, sealedSHA256: fixtureSealedSHA256, sealedBytes: fixtureRaw.count + 28,
            keyBase64: fixtureKeyB64, nonceBase64: fixtureNonceB64)
        XCTAssertNoThrow(try response.validate(against: original))
        let mutations: [String: Any] = ["schema": "unsupported", "contentSchema": "unsupported",
            "sourceSchemaDigest": String(repeating: "b", count: 64), "coverage": [], "recordCount": 1,
            "fieldPolicy": "unsupported", "structuredSchema": "unsupported", "billingSchema": "unsupported",
            "currentSourceSequence": 10, "sourceCurrent": false, "operationalWorkspaceReady": true,
            "fieldProjectionRequired": true, "localCloudKitProofRequired": false]
        for (field, value) in mutations {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
            object[field] = value
            let changed = try JSONDecoder().decode(StaffWorkspaceContentReceipt.self, from: JSONSerialization.data(withJSONObject: object))
            let forged = StaffWorkspaceCloudSealResponse(schema: response.schema, content: changed,
                sealedSHA256: response.sealedSHA256, sealedBytes: response.sealedBytes,
                keyBase64: response.keyBase64, nonceBase64: response.nonceBase64)
            XCTAssertThrowsError(try forged.validate(against: original), "Changed \(field)")
        }
    }

    func testStrictMaterialRejectsWrongLengthOrNonCanonicalBase64() {
        XCTAssertThrowsError(try StaffWorkspaceCloudSealResponse.material("AAAA", size: 32))
        XCTAssertThrowsError(try StaffWorkspaceCloudSealResponse.material("AAECAwQFBgcICQoLDA==", size: 12))
        XCTAssertNoThrow(try StaffWorkspaceCloudSealResponse.material(fixtureKeyB64, size: 32))
        XCTAssertNoThrow(try StaffWorkspaceCloudSealResponse.material(fixtureNonceB64, size: 12))
    }
}

private extension Data {
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var data = Data(capacity: chars.count / 2)
        for index in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[index...index + 1]), radix: 16) else { return nil }
            data.append(byte)
        }
        self = data
    }
}
