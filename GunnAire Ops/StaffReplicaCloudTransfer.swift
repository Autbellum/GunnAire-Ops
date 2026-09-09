import Foundation
import CloudKit

enum StaffReplicaCloudRecords {
    static let headName = "current-core-field-v1"
    static func payloadName(_ operation: UUID) -> String { "core-field-v1-" + operation.uuidString.lowercased() }
    static func make(_ manifest: StaffReplicaManifest, plan: CloudKitStaffSharePlan, zone: CKRecordZone.ID,
                     asset: CKAsset? = nil, updating head: CKRecord? = nil) throws -> CKRecord {
        let payload = asset != nil
        let record = head ?? CKRecord(recordType: payload ? "GAStaffReplicaSealedPayload" : "GAStaffReplicaHead",
            recordID: .init(recordName: payload ? payloadName(manifest.operationID) : headName, zoneID: zone))
        record.parent = .init(recordID: .init(recordName: plan.rootRecordName, zoneID: zone), action: .none)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        record["manifest"] = try encoder.encode(manifest) as CKRecordValue
        if let asset { record["payload"] = asset }
        return record
    }
    static func manifest(_ record: CKRecord, plan: CloudKitStaffSharePlan, workspace: CompanyWorkspaceIdentity,
                         zone: CKRecordZone.ID, payload: Bool, now: Date) throws -> StaffReplicaManifest {
        guard record.recordType == (payload ? "GAStaffReplicaSealedPayload" : "GAStaffReplicaHead"), record.recordID.zoneID == zone,
              Set(record.allKeys()) == (payload ? ["manifest", "payload"] : ["manifest"]),
              record.parent?.recordID == CKRecord.ID(recordName: plan.rootRecordName, zoneID: zone), record.parent?.action == CKRecord.ReferenceAction.none,
              record.share == nil || record.share?.recordID == CKRecord.ID(recordName: plan.shareRecordName, zoneID: zone),
              let bytes = record["manifest"] as? Data, bytes.count <= 8192 else { throw StaffReplicaDeliveryError.invalid }
        let manifest = try JSONDecoder().decode(StaffReplicaManifest.self, from: bytes)
        try manifest.validate(plan: plan, workspace: workspace, now: now)
        guard record.recordID.recordName == (payload ? payloadName(manifest.operationID) : headName) else { throw StaffReplicaDeliveryError.changed }
        return manifest
    }
    static func payload(_ record: CKRecord, manifest: StaffReplicaManifest, key: Data) throws -> StaffReplicaSealedPayload {
        guard let asset = record["payload"] as? CKAsset, let url = asset.fileURL, url.isFileURL else { throw StaffReplicaDeliveryError.invalid }
        // CloudKit owns this staging URL. Read bounded bytes immediately; never
        // retain its URL as durable recovery state or delete Apple's staged file.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: manifest.payloadBytes + 29) ?? Data()
        return try .init(manifest: manifest, bytes: data, key: key)
    }
}

/// The common state machine is tested against exact CKRecord/CKAsset values;
/// live I/O uses only the verified owner's private or participant's shared DB.
struct StaffReplicaCloudIO {
    let zone: CKRecordZone.ID
    let authorize: () async throws -> Void
    let read: ([CKRecord.ID]) async throws -> [CKRecord.ID: CKRecord]
    let save: ([CKRecord]) async throws -> Void
    static func live(zone: CKRecordZone.ID, database: CKDatabase, authorize: @escaping () async throws -> Void) -> Self {
        .init(zone: zone, authorize: authorize, read: { ids in
            let results = try await database.records(for: ids)
            guard Set(results.keys) == Set(ids) else { throw StaffReplicaDeliveryError.invalid }
            var values: [CKRecord.ID: CKRecord] = [:]
            for (id, result) in results {
                do {
                    let record = try result.get()
                    guard record.recordID == id else { throw StaffReplicaDeliveryError.changed }
                    values[id] = record
                } catch let error as CKError where error.code == .unknownItem { continue }
            }
            return values
        }, save: { records in
            let results = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
            guard Set(results.saveResults.keys) == Set(records.map(\.recordID)), results.deleteResults.isEmpty else { throw StaffReplicaDeliveryError.invalid }
            for (id, result) in results.saveResults {
                guard try result.get().recordID == id else { throw StaffReplicaDeliveryError.changed }
            }
        })
    }
}

@MainActor enum StaffReplicaCloudTransfer {
    typealias Context = CloudKitStaffSetupController.Context
    typealias Authority = (UUID) async throws -> StaffReplicaProjectionReceipt

    static func ownerIO(plan: CloudKitStaffSharePlan, context: Context,
                        authorize: @escaping CloudKitStaffRemote.Authorize) throws -> StaffReplicaCloudIO {
        guard context.ownerAdministrator else { throw StaffReplicaDeliveryError.access }
        let database = try CloudKitStaffRemote.container().privateCloudDatabase
        let zone = CKRecordZone.ID(zoneName: plan.zoneName, ownerName: CKCurrentUserDefaultName)
        return .live(zone: zone, database: database, authorize: {
            try await authorize()
            let (root, share) = try await CloudKitStaffRemote.readOwner(database: database, plan: plan, account: context.account, authorize: authorize)
            guard let root, let share else { throw StaffReplicaDeliveryError.pending }
            _ = try CloudKitStaffRemote.verifyOwnerShare(share, root: root, plan: plan, account: context.account, enforceParticipant: true)
            guard share.participants.filter({ $0.role != .owner }).first?.acceptanceStatus == .accepted else { throw StaffReplicaDeliveryError.pending }
            try await authorize()
        })
    }

    static func participantIO(plan: CloudKitStaffSharePlan, context: Context, url: URL,
                              authorize: @escaping CloudKitStaffRemote.Authorize) async throws -> StaffReplicaCloudIO {
        guard context.owns(plan), context.member.role == plan.memberRole else { throw StaffReplicaDeliveryError.access }
        let container = try CloudKitStaffRemote.container()
        func zone() async throws -> CKRecordZone.ID {
            let metadata = try await CloudKitStaffRemote.metadata(container: container, url: url, authorize: authorize)
            return try CloudKitStaffShareEvidence(metadata: metadata).verify(plan: plan, workspace: context.workspace,
                account: context.account, member: context.member, requiresAccepted: true)
        }
        let expected = try await zone()
        return .live(zone: expected, database: container.sharedCloudDatabase, authorize: {
            guard try await zone() == expected else { throw StaffReplicaDeliveryError.changed }
            let id = CKRecord.ID(recordName: plan.rootRecordName, zoneID: expected)
            try await authorize()
            let result = try await container.sharedCloudDatabase.records(for: [id])
            try await authorize()
            guard result.count == 1, let value = result[id] else { throw StaffReplicaDeliveryError.invalid }
            try CloudKitStaffShareRecords.verifyRoot(try value.get(), plan: plan, zone: expected)
        })
    }

    private static func read(_ ids: [CKRecord.ID], io: StaffReplicaCloudIO) async throws -> [CKRecord.ID: CKRecord] {
        try Task.checkCancellation(); try await io.authorize()
        let values = try await io.read(ids)
        try Task.checkCancellation(); try await io.authorize()
        guard Set(values.keys).isSubset(of: Set(ids)), values.allSatisfy({ $0.key == $0.value.recordID }) else { throw StaffReplicaDeliveryError.invalid }
        return values
    }

    static func publish(_ original: StaffReplicaSealedPayload, plan: CloudKitStaffSharePlan, workspace: CompanyWorkspaceIdentity,
                        io: StaffReplicaCloudIO, now: () -> Date = Date.init) async throws {
        try original.manifest.validate(plan: plan, workspace: workspace, now: now())
        guard io.zone.zoneName == plan.zoneName, io.zone.ownerName == CKCurrentUserDefaultName else { throw StaffReplicaDeliveryError.access }
        let payloadID = CKRecord.ID(recordName: StaffReplicaCloudRecords.payloadName(original.manifest.operationID), zoneID: io.zone)
        let headID = CKRecord.ID(recordName: StaffReplicaCloudRecords.headName, zoneID: io.zone)
        let values = try await read([payloadID, headID], io: io)
        let existing = values[payloadID], head = values[headID]
        if let existing {
            let manifest = try StaffReplicaCloudRecords.manifest(existing, plan: plan, workspace: workspace, zone: io.zone, payload: true, now: now())
            guard manifest == original.manifest else { throw StaffReplicaDeliveryError.changed }
            guard try StaffReplicaCloudRecords.payload(existing, manifest: manifest, key: original.key).bytes == original.bytes else { throw StaffReplicaDeliveryError.changed }
        }
        if let head {
            let manifest = try StaffReplicaCloudRecords.manifest(head, plan: plan, workspace: workspace, zone: io.zone, payload: false, now: now())
            if manifest == original.manifest {
                guard existing != nil else { throw StaffReplicaDeliveryError.invalid }
                return // Exact original upload is confirmed, including a lost reply.
            }
            guard manifest.sourceSequence < original.manifest.sourceSequence,
                  manifest.authorizationSequence <= original.manifest.authorizationSequence else { throw StaffReplicaDeliveryError.superseded }
        }
        // A unique owned temporary file survives through Apple's awaited save.
        // The durable journal contains the original identity, never this URL.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GAStaffUpload-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("payload.sealed")
        try original.bytes.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        var saving: [CKRecord] = []
        if existing == nil { saving.append(try StaffReplicaCloudRecords.make(original.manifest, plan: plan, zone: io.zone, asset: CKAsset(fileURL: url))) }
        saving.append(try StaffReplicaCloudRecords.make(original.manifest, plan: plan, zone: io.zone, updating: head))
        try Task.checkCancellation(); try await io.authorize()
        try await io.save(saving)
        try Task.checkCancellation(); try await io.authorize()
        let confirmed = try await read([payloadID, headID], io: io)
        guard let confirmedPayload = confirmed[payloadID], let confirmedHead = confirmed[headID] else { throw StaffReplicaDeliveryError.pending }
        let saved = try StaffReplicaCloudRecords.manifest(confirmedPayload, plan: plan, workspace: workspace, zone: io.zone, payload: true, now: now())
        let current = try StaffReplicaCloudRecords.manifest(confirmedHead, plan: plan, workspace: workspace, zone: io.zone, payload: false, now: now())
        guard saved == original.manifest else { throw StaffReplicaDeliveryError.changed }
        guard try StaffReplicaCloudRecords.payload(confirmedPayload, manifest: saved, key: original.key).bytes == original.bytes else { throw StaffReplicaDeliveryError.changed }
        guard current == saved else { throw StaffReplicaDeliveryError.superseded }
    }

    static func download(plan: CloudKitStaffSharePlan, workspace: CompanyWorkspaceIdentity, io: StaffReplicaCloudIO,
                         authority: Authority, now: () -> Date = Date.init) async throws -> StaffReplicaVerifiedPayload {
        guard io.zone.zoneName == plan.zoneName, io.zone.ownerName != CKCurrentUserDefaultName,
              CloudKitStaffSharePlan.accountHash(recordName: io.zone.ownerName, environment: plan.environment) == plan.ownerAccountHash else {
            throw StaffReplicaDeliveryError.access
        }
        let headID = CKRecord.ID(recordName: StaffReplicaCloudRecords.headName, zoneID: io.zone)
        guard let head = try await read([headID], io: io)[headID] else { throw StaffReplicaDeliveryError.pending }
        let manifest = try StaffReplicaCloudRecords.manifest(head, plan: plan, workspace: workspace, zone: io.zone, payload: false, now: now())
        func checkAuthority() async throws -> Data {
            let receipt = try await authority(manifest.operationID)
            try receipt.validate(plan: plan, workspace: workspace, now: now())
            guard receipt.manifest == manifest, receipt.payloadBase64 == nil, receipt.sealedBase64 == nil else { throw StaffReplicaDeliveryError.changed }
            return try receipt.decryptionKey()
        }
        let key = try await checkAuthority()
        let id = CKRecord.ID(recordName: StaffReplicaCloudRecords.payloadName(manifest.operationID), zoneID: io.zone)
        guard let record = try await read([id], io: io)[id] else { throw StaffReplicaDeliveryError.pending }
        guard try StaffReplicaCloudRecords.manifest(record, plan: plan, workspace: workspace, zone: io.zone, payload: true, now: now()) == manifest else {
            throw StaffReplicaDeliveryError.changed
        }
        let payload = try StaffReplicaCloudRecords.payload(record, manifest: manifest, key: key)
        guard try await checkAuthority() == key else { throw StaffReplicaDeliveryError.changed }
        try Task.checkCancellation(); try await io.authorize()
        return payload.opened
    }
}
