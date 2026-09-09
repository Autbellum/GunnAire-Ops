import Foundation
import CloudKit
import CryptoKit
import Testing
@testable import GunnAire_Ops

@MainActor struct StaffReplicaDeliveryTests {
    @MainActor final class Fixture {
        let base = CloudKitStaffSharingTests()
        let operation = UUID(uuidString: "a2000000-0000-4000-8000-000000000001")!
        var stamp: CloudKitStaffSetupStamp?
        var owner = true
        var sequence = 1
        var authorizationSequence = 1
        var authorized = true
        var saved: [String: Data] = [:]
        var remote: [String: (StaffReplicaManifest, Data?)] = [:]
        var requests: [String] = []
        var saves = 0
        var reads = 0
        var checks = 0
        var writes = 0
        var failWrite: Int?
        var loseSaveReply = false
        var conflictSave = false
        var afterRead: (() -> Void)?
        var afterRequest: (() -> Void)?
        var mutateRecord: ((CKRecord) -> Void)?
        let directory: URL
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("GAStaffDeliveryTest-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            signIn(owner: true)
        }
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
        func signIn(owner: Bool) {
            self.owner = owner
            stamp = .init(session: .init(backendOrigin: "https://fixture.gunnaire.invalid", email: owner ? "owner@gunnaire.com" : base.member.email,
                tokenFingerprint: String(repeating: "1", count: 64), expiresAt: base.now.addingTimeInterval(3600)), accountGeneration: UUID())
        }
        func context() throws -> CloudKitStaffSetupController.Context {
            .init(stamp: stamp!, workspace: base.workspace,
                  member: .init(email: stamp!.session.email, role: owner ? "Admin" : base.member.role, isActive: true, createdAt: base.instant),
                  account: .init(environment: "development", accountHash: owner ? base.ownerHash : base.participantHash,
                    recordName: owner ? base.ownerName : base.participantName))
        }
        func payload(operation: UUID? = nil, sequence: Int = 1, authorization: Int = 1, notes: String = "Original work") throws -> StaffReplicaVerifiedPayload {
            let plan = try base.plan(), operation = operation ?? self.operation
            let fields: [String: Any] = ["protocolVersion": 1, "schema": "core-field-v1", "coverage": StaffReplicaCoreSource.recordKinds,
                "completeForSchema": true, "companyID": plan.companyID.uuidString.lowercased(), "environment": plan.environment,
                "replicaID": plan.replicaID.uuidString.lowercased(), "membershipID": plan.id.uuidString.lowercased(),
                "memberRevision": plan.memberRevision, "projectionPolicy": plan.projectionPolicy, "sourceSequence": sequence,
                "authorizationSequence": authorization, "operationID": operation.uuidString.lowercased(),
                "records": [["kind": "customer", "id": "a3000000-0000-4000-8000-000000000001", "revision": 1, "fields": ["name": notes]]]]
            let bytes = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
            let manifest = StaffReplicaManifest(protocolVersion: 1, schema: "core-field-v1", coverage: StaffReplicaCoreSource.recordKinds,
                operationID: operation, membershipID: plan.id, companyID: plan.companyID, environment: plan.environment, replicaID: plan.replicaID,
                memberRevision: plan.memberRevision, projectionPolicy: plan.projectionPolicy, sourceSequence: sequence, authorizationSequence: authorization,
                payloadSHA256: StaffReplicaManifest.hash(bytes), payloadBytes: bytes.count, recordCount: 1, createdAt: base.instant)
            return try .init(manifest: manifest, bytes: bytes)
        }
        var originals: [UUID: StaffReplicaVerifiedPayload] = [:]
        var seals: [UUID: StaffReplicaSealedPayload] = [:]
        func seal(_ original: StaffReplicaVerifiedPayload) throws -> StaffReplicaSealedPayload {
            if let existing = seals[original.manifest.operationID] { return existing }
            let key = SymmetricKey(size: .bits256)
            let data = try AES.GCM.seal(original.bytes, using: key, authenticating: original.manifest.authenticatedScope).combined!
            let value = try StaffReplicaSealedPayload(manifest: original.manifest, bytes: data, key: key.withUnsafeBytes { Data($0) })
            seals[original.manifest.operationID] = value; return value
        }
        func receipt(_ payload: StaffReplicaVerifiedPayload, content: Bool = false, cloudKey: Bool = false, cloudContent: Bool = false,
                     changes: [String: Any] = [:]) throws -> Data {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload.manifest)) as! [String: Any]
            object["currentSequence"] = sequence; object["isCurrent"] = sequence == payload.manifest.sourceSequence
            object["currentAuthorizationSequence"] = authorizationSequence
            object["authorizationCurrent"] = authorizationSequence == payload.manifest.authorizationSequence
            object["localCloudKitProofRequired"] = true; object["operationalWorkspaceReady"] = false
            if content { object["payloadBase64"] = payload.bytes.base64EncodedString() }
            if cloudKey || cloudContent {
                let value = try seal(payload)
                object["sealVersion"] = 1; object["keyBase64"] = value.key.base64EncodedString()
                if cloudContent { object["sealedBase64"] = value.bytes.base64EncodedString() }
            }
            return try JSONSerialization.data(withJSONObject: object.merging(changes) { _, new in new })
        }
        func io(plan: CloudKitStaffSharePlan, context: CloudKitStaffSetupController.Context,
                authorize: @escaping CloudKitStaffRemote.Authorize) -> StaffReplicaCloudIO {
            let zone = CKRecordZone.ID(zoneName: plan.zoneName, ownerName: owner ? CKCurrentUserDefaultName : base.ownerName)
            return .init(zone: zone, authorize: {
                self.checks += 1
                guard self.authorized else { throw StaffReplicaDeliveryError.access }
                try await authorize()
            }, read: { ids in
                self.reads += 1
                var result: [CKRecord.ID: CKRecord] = [:]
                for id in ids {
                    guard let value = self.remote[id.recordName] else { continue }
                    var asset: CKAsset?
                    if let data = value.1 {
                        let url = self.directory.appendingPathComponent(UUID().uuidString)
                        try data.write(to: url); asset = CKAsset(fileURL: url)
                    }
                    let record = try StaffReplicaCloudRecords.make(value.0, plan: plan, zone: zone, asset: asset)
                    self.mutateRecord?(record); result[id] = record
                }
                let callback = self.afterRead; self.afterRead = nil; callback?()
                return result
            }, save: { values in
                if self.conflictSave { throw CKError(.serverRecordChanged) }
                self.saves += 1
                var next = self.remote
                for value in values {
                    let payload = value.recordType == "GAStaffReplicaSealedPayload"
                    let manifest = try StaffReplicaCloudRecords.manifest(value, plan: plan, workspace: context.workspace, zone: zone, payload: payload, now: self.base.now)
                    let bytes = payload ? try StaffReplicaCloudRecords.payload(value, manifest: manifest, key: self.seals[manifest.operationID]!.key).bytes : nil
                    next[value.recordID.recordName] = (manifest, bytes)
                }
                self.remote = next
                if self.loseSaveReply { self.loseSaveReply = false; throw URLError(.networkConnectionLost) }
            })
        }
        var dependencies: StaffReplicaDeliveryDependencies {
            .init(stamp: { self.stamp }, authorize: { _, _ in if !self.authorized { throw StaffReplicaDeliveryError.access } },
                request: { path in
                    self.requests.append(path)
                    let parts = URLComponents(string: path)!.path.split(separator: "/")
                    let id = UUID(uuidString: String(parts[5]))!
                    guard let payload = self.originals[id] else { throw StaffReplicaDeliveryError.pending }
                    let bytes = try self.receipt(payload, cloudKey: parts.last == "cloud-key", cloudContent: parts.last == "cloud-payload")
                    let callback = self.afterRequest; self.afterRequest = nil; callback?()
                    return bytes
                }, ownerIO: { self.io(plan: $0, context: $1, authorize: $2) }, participantIO: { plan, context, _, authorize in
                    self.io(plan: plan, context: context, authorize: authorize)
                }, store: .init(read: { self.saved[$0] }, write: {
                    self.writes += 1
                    if self.writes == self.failWrite { throw StaffReplicaDeliveryError.storage }
                    self.saved[$0] = $1
                }), now: { self.base.now })
        }
        func coordinator() -> StaffReplicaDeliveryCoordinator { .init(dependencies: dependencies) }
        func publish(_ payload: StaffReplicaVerifiedPayload? = nil) async throws -> StaffReplicaManifest {
            let payload = try payload ?? self.payload()
            originals[payload.manifest.operationID] = payload
            return try await coordinator().publish(operation: payload.manifest.operationID, plan: base.plan(), context: context())
        }
        func download() async throws -> StaffReplicaManifest {
            try await coordinator().download(plan: base.plan(), context: context(), invitation: URL(string: "https://www.icloud.com/share/fixture")!)
        }
    }

    @Test func projectionRoutesAreExactReadOnlyMetadataOrOwnerPayloadNotSourceBypasses() throws {
        let base = CloudKitStaffSharingTests(), plan = try base.plan()
        for payload in [true, false] {
            let path = StaffReplicaDeliveryPolicy.path(plan: plan, operation: UUID(), payload: payload)
            #expect(StaffReplicaDeliveryPolicy.allows(path: path))
            #expect(!CloudKitStaffSetupPolicy.allows(path: path, method: "GET", bytes: nil))
            #expect(CompanyWorkspaceRequestPolicy.needsWorkspaceProof(path: path))
            for suffix in ["/", "&environment=production", "#fragment", "&after=anything"] {
                #expect(!StaffReplicaDeliveryPolicy.allows(path: path + suffix))
            }
            #expect(!StaffReplicaDeliveryPolicy.allows(path: "https://attacker.invalid" + path))
            #expect(!StaffReplicaDeliveryPolicy.allows(path: path.replacingOccurrences(of: "/projections/", with: "/%70rojections/")))
        }
        for path in ["/api/workspace/replica-records", "/api/workspace", "/api/invoices", "/api/workspace/staff-shares"] {
            #expect(!StaffReplicaDeliveryPolicy.allows(path: path))
        }
    }

    @Test func originalBytesAndDataFreshnessAreSeparateFromCurrentAssignmentAuthority() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let payload = try f.payload(); f.sequence = 4
        let value = try JSONDecoder().decode(StaffReplicaProjectionReceipt.self, from: f.receipt(payload, content: true))
        try value.validate(plan: f.base.plan(), workspace: f.base.workspace, now: f.base.now)
        #expect(!value.isCurrent); #expect(value.authorizationCurrent)
        #expect(try value.ownerPayload().bytes == payload.bytes)
        #expect(value.manifest.sourceSequence == 1); #expect(value.currentSequence == 4)
        f.authorizationSequence = 2
        let changed = try JSONDecoder().decode(StaffReplicaProjectionReceipt.self, from: f.receipt(payload))
        #expect(throws: StaffReplicaDeliveryError.changed) { try changed.validate(plan: f.base.plan(), workspace: f.base.workspace, now: f.base.now) }
    }

    @Test func invalidReceiptAuthorityScopeVersionsFlagsCountsAndHashAreRejected() throws {
        let f = try Fixture(); defer { f.cleanup() }; let payload = try f.payload()
        let invalid: [[String: Any]] = [["protocolVersion": 2], ["schema": "all-business"], ["coverage": []], ["companyID": UUID().uuidString],
            ["membershipID": UUID().uuidString], ["replicaID": UUID().uuidString], ["environment": "production"], ["memberRevision": String(repeating: "b", count: 64)],
            ["projectionPolicy": "admin-operations-v1"], ["sourceSequence": 0], ["currentSequence": 0], ["currentSequence": 2],
            ["authorizationSequence": 0], ["authorizationSequence": 2], ["authorizationCurrent": false], ["currentAuthorizationSequence": 2],
            ["payloadBytes": 0], ["payloadBytes": 16 * 1024 * 1024 + 1], ["recordCount": 20_001], ["payloadSHA256": "bad"],
            ["createdAt": "2026-09-10T00:00:00Z"], ["localCloudKitProofRequired": false], ["operationalWorkspaceReady": true]]
        for changes in invalid {
            let value = try JSONDecoder().decode(StaffReplicaProjectionReceipt.self, from: f.receipt(payload, changes: changes))
            #expect(throws: (any Error).self) { try value.validate(plan: f.base.plan(), workspace: f.base.workspace, now: f.base.now) }
        }
        #expect(throws: (any Error).self) { try StaffReplicaVerifiedPayload(manifest: payload.manifest, bytes: payload.bytes + Data([32])) }
    }

    @Test func publicationAndRelaunchRecoverTheExactOriginalWithoutAnotherCloudWrite() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let first = try await f.publish(); #expect(f.saves == 1); #expect(f.remote.count == 2)
        let again = try await f.publish(); #expect(first == again); #expect(f.saves == 1)
        #expect(f.saved.count == 1)
        let saved = try JSONDecoder().decode(StaffReplicaDeliveryJournal.self, from: f.saved.values.first!)
        #expect(saved.state == "confirmed"); #expect(saved.payload == nil)
        #expect(f.checks >= 6)
    }

    @Test func lostCloudReplyKeepsPreparedOperationAndRelaunchConfirmsItWithoutResending() async throws {
        let f = try Fixture(); defer { f.cleanup() }; f.loseSaveReply = true
        await #expect(throws: URLError.self) { try await f.publish() }
        #expect(f.saves == 1); #expect(f.remote.count == 2)
        #expect(try JSONDecoder().decode(StaffReplicaDeliveryJournal.self, from: f.saved.values.first!).state == "prepared")
        _ = try await f.publish()
        #expect(f.saves == 1)
        #expect(try JSONDecoder().decode(StaffReplicaDeliveryJournal.self, from: f.saved.values.first!).state == "confirmed")
    }

    @Test func failureBeforeDurableIntentHasNoCloudActivityAndAfterConfirmationRetainsRecovery() async throws {
        for write in [1, 2] {
            let f = try Fixture(); defer { f.cleanup() }; f.failWrite = write
            await #expect(throws: StaffReplicaDeliveryError.storage) { try await f.publish() }
            #expect(f.saves == (write == 1 ? 0 : 1))
            if write == 1 { #expect(f.reads == 0); #expect(f.saved.isEmpty) }
            else { #expect(try JSONDecoder().decode(StaffReplicaDeliveryJournal.self, from: f.saved.values.first!).state == "prepared") }
            f.failWrite = nil; _ = try await f.publish(); #expect(f.saves == 1)
        }
    }

    @Test func olderAndEqualSequenceDifferentOperationsNeverOverwriteTheCurrentHead() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let newer = try f.payload(operation: UUID(), sequence: 2); f.sequence = 2
        _ = try await f.publish(newer)
        for older in [try f.payload(), try f.payload(operation: UUID(), sequence: 2)] {
            await #expect(throws: StaffReplicaDeliveryError.superseded) { try await f.publish(older) }
        }
        #expect(f.saves == 1); #expect(f.remote[StaffReplicaCloudRecords.headName]?.0 == newer.manifest)
    }

    @Test func serverRecordConflictRetainsIntentWithoutRetryLoopOrHeadOverwrite() async throws {
        let f = try Fixture(); defer { f.cleanup() }; f.conflictSave = true
        await #expect(throws: CKError.self) { try await f.publish() }
        #expect(f.saves == 0); #expect(f.remote.isEmpty)
        #expect(try JSONDecoder().decode(StaffReplicaDeliveryJournal.self, from: f.saved.values.first!).state == "prepared")
    }

    @Test func memberStagesCloudAssetUsingMetadataOnlyAndRetainsItsActualSourceSequence() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let original = try await f.publish(); f.signIn(owner: false); f.sequence = 4; f.requests = []
        let staged = try await f.download()
        #expect(staged == original); #expect(staged.sourceSequence == 1)
        #expect(f.requests.allSatisfy { !URLComponents(string: $0)!.path.hasSuffix("/cloud-payload") })
        #expect(f.requests.contains { URLComponents(string: $0)!.path.hasSuffix("/cloud-key") })
        let key = try f.coordinator().key(context: f.context(), plan: f.base.plan())
        let saved = try JSONDecoder().decode(StaffReplicaDeliveryJournal.self, from: f.saved[key]!)
        #expect(saved.state == "staged"); #expect(saved.payload == (try f.payload().bytes))
        #expect(saved.manifest.sourceSequence == 1); #expect(f.saves == 1)
    }

    @Test func olderCloudHeadCannotReplaceNewerEncryptedStage() async throws {
        let f = try Fixture(); defer { f.cleanup() }; _ = try await f.publish()
        let oldCloud = f.remote
        let newer = try f.payload(operation: UUID(), sequence: 2); f.sequence = 2; _ = try await f.publish(newer)
        f.signIn(owner: false); _ = try await f.download(); let before = f.saved
        f.remote = oldCloud
        await #expect(throws: StaffReplicaDeliveryError.superseded) { try await f.download() }
        #expect(f.saved == before)
    }

    @Test func assignmentRevokedDuringCloudReadPreventsNewStageAndRetainsExistingWork() async throws {
        let f = try Fixture(); defer { f.cleanup() }; _ = try await f.publish(); f.signIn(owner: false)
        _ = try await f.download(); let before = f.saved
        f.sequence = 2; f.afterRead = { f.authorizationSequence = 2 }
        await #expect(throws: StaffReplicaDeliveryError.changed) { try await f.download() }
        #expect(f.saved == before)
    }

    @Test func accountChangedDuringBackendReadStopsBeforeCloudAndLeavesOriginalScopeAlone() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.afterRequest = { f.signIn(owner: false) }
        await #expect(throws: StaffReplicaDeliveryError.access) { try await f.publish() }
        #expect(f.remote.isEmpty); #expect(f.saved.isEmpty); #expect(f.reads == 0)
    }

    @Test func revokedApplePermissionDuringReadPreventsCloudWriteAndRetainsIntent() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.afterRead = { f.authorized = false }
        await #expect(throws: StaffReplicaDeliveryError.access) { try await f.publish() }
        #expect(f.saves == 0); #expect(f.saved.count == 1)
    }

    @Test func wrongSharedParentUnexpectedFieldsAndCorruptAssetDoNotCreateStage() async throws {
        for variant in 0..<3 {
            let f = try Fixture(); defer { f.cleanup() }; _ = try await f.publish(); f.signIn(owner: false)
            let before = f.saved
            if variant == 2 {
                let key = StaffReplicaCloudRecords.payloadName(f.operation), original = f.remote[key]!
                f.remote[key] = (original.0, Data("modified".utf8))
            } else {
                f.mutateRecord = { record in
                    if variant == 0 { record.parent = nil } else { record["otherCompany"] = "unexpected" as CKRecordValue }
                }
            }
            await #expect(throws: StaffReplicaDeliveryError.invalid) { try await f.download() }
            #expect(f.saved == before)
        }
    }

    @Test func missingSnapshotOrHeadIsPendingNotEmptyWorkspace() async throws {
        for name in [StaffReplicaCloudRecords.headName, StaffReplicaCloudRecords.payloadName(UUID(uuidString: "a2000000-0000-4000-8000-000000000001")!)] {
            let f = try Fixture(); defer { f.cleanup() }; _ = try await f.publish(); f.signIn(owner: false)
            f.remote[name] = nil
            await #expect(throws: StaffReplicaDeliveryError.pending) { try await f.download() }
            #expect(f.saved.count == 1)
        }
    }

    @Test func staffCannotUseOwnerPublicationEvenWithPreparedServerMetadata() async throws {
        let f = try Fixture(); defer { f.cleanup() }; f.signIn(owner: false)
        await #expect(throws: StaffReplicaDeliveryError.access) { try await f.publish() }
        #expect(f.requests.isEmpty); #expect(f.saved.isEmpty); #expect(f.remote.isEmpty)
    }

    @Test func corruptJournalCannotBeReplacedAsAnEmptyRecoveryState() async throws {
        let f = try Fixture(); defer { f.cleanup() }; let plan = try f.base.plan(), context = try f.context()
        let key = f.coordinator().key(context: context, plan: plan, operation: f.operation)
        f.saved[key] = Data("corrupt".utf8); let before = f.saved
        await #expect(throws: StaffReplicaDeliveryError.storage) { try await f.publish() }
        #expect(f.saved == before); #expect(f.requests.isEmpty); #expect(f.reads == 0)
    }

    @Test func encryptedStageSupportsLargeAssetsAndRejectsWrongScopeKeyAndBounds() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let key = Data(repeating: 4, count: 32)
        let store = SharedTimeLocalStore.encrypted(directory: f.directory, maximumBytes: 3 * 1024 * 1024) { _ in key }
        let bytes = Data(repeating: 65, count: 2 * 1024 * 1024)
        try store.write("original-scope", bytes); #expect(try store.read("original-scope") == bytes)
        let files = try FileManager.default.contentsOfDirectory(at: f.directory, includingPropertiesForKeys: nil)
        #expect(files.count == 1); #expect(try Data(contentsOf: files[0]).range(of: Data(repeating: 65, count: 128)) == nil)
        let wrong = SharedTimeLocalStore.encrypted(directory: f.directory, maximumBytes: 3 * 1024 * 1024) { _ in Data(repeating: 5, count: 32) }
        #expect(throws: SharedTimeError.self) { try wrong.read("original-scope") }
        let legacy = SharedTimeLocalStore.encrypted(directory: f.directory) { _ in key }
        #expect(throws: SharedTimeError.self) { try legacy.read("original-scope") }
        #expect(throws: SharedTimeError.self) { try legacy.write("legacy", bytes) }
        #expect(try store.read("another-scope") == nil)
        #expect(try store.read("original-scope") == bytes)
    }

    @Test func cloudRecordsAndPublisherJournalNeverContainPlaintextOrPerSnapshotKey() async throws {
        let f = try Fixture(); defer { f.cleanup() }; _ = try await f.publish()
        let original = try f.payload(), key = f.seals[f.operation]!.key
        let cloud = f.remote[StaffReplicaCloudRecords.payloadName(f.operation)]!.1!
        #expect(cloud != original.bytes); #expect(cloud.range(of: Data("Original work".utf8)) == nil)
        #expect(cloud.count == original.bytes.count + 28)
        for journal in f.saved.values {
            #expect(journal.range(of: Data(key.base64EncodedString().utf8)) == nil)
            #expect(journal.range(of: Data("Original work".utf8)) == nil)
        }
        #expect(try StaffReplicaSealedPayload(manifest: original.manifest, bytes: cloud, key: key).opened.bytes == original.bytes)
        #expect(throws: StaffReplicaDeliveryError.invalid) { try StaffReplicaSealedPayload(manifest: original.manifest, bytes: cloud, key: Data(repeating: 0, count: 32)) }
        #expect(throws: StaffReplicaDeliveryError.invalid) { try StaffReplicaSealedPayload(manifest: original.manifest, bytes: original.bytes, key: key) }
    }

    @Test func substitutedSnapshotScopeTagKeyAndUnknownSealVersionAreRejected() throws {
        let f = try Fixture(); defer { f.cleanup() }; let original = try f.payload(), sealed = try f.seal(original)
        var changed = sealed.bytes; changed[changed.count - 1] ^= 1
        #expect(throws: StaffReplicaDeliveryError.invalid) { try StaffReplicaSealedPayload(manifest: original.manifest, bytes: changed, key: sealed.key) }
        let foreign = try f.payload(operation: UUID())
        #expect(throws: StaffReplicaDeliveryError.invalid) { try StaffReplicaSealedPayload(manifest: foreign.manifest, bytes: sealed.bytes, key: sealed.key) }
        for change: [String: Any] in [["sealVersion": 2], ["keyBase64": "bad"], ["payloadBase64": original.bytes.base64EncodedString()], ["sealedBase64": "bad"]] {
            let receipt = try JSONDecoder().decode(StaffReplicaProjectionReceipt.self, from: f.receipt(original, cloudContent: true, changes: change))
            #expect(throws: StaffReplicaDeliveryError.invalid) { try receipt.ownerSealedPayload() }
        }
    }
}
