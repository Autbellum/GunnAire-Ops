import Foundation
import CloudKit

enum StaffWorkspaceCloudRecords {
    static let headName = "full-workspace-cloud-seal-v1-current"
    static func payloadName(_ selectionID: String) -> String { "full-workspace-cloud-seal-v1-" + selectionID }
    static func make(_ manifest: StaffWorkspaceCloudSealManifest, plan: CloudKitStaffSharePlan, zone: CKRecordZone.ID,
                     asset: CKAsset? = nil, updating head: CKRecord? = nil) throws -> CKRecord {
        let payload = asset != nil
        let record = head ?? CKRecord(recordType: payload ? "GAStaffWorkspaceSealedPayload" : "GAStaffWorkspaceHead",
            recordID: .init(recordName: payload ? payloadName(manifest.selectionID) : headName, zoneID: zone))
        record.parent = .init(recordID: .init(recordName: plan.rootRecordName, zoneID: zone), action: .none)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        record["manifest"] = try encoder.encode(manifest) as CKRecordValue
        if let asset { record["payload"] = asset }
        return record
    }
    static func manifest(_ record: CKRecord, plan: CloudKitStaffSharePlan, workspace: CompanyWorkspaceIdentity,
                         zone: CKRecordZone.ID, payload: Bool, now: Date) throws -> StaffWorkspaceCloudSealManifest {
        guard record.recordType == (payload ? "GAStaffWorkspaceSealedPayload" : "GAStaffWorkspaceHead"),
              record.recordID.zoneID == zone,
              Set(record.allKeys()) == (payload ? ["manifest", "payload"] : ["manifest"]),
              record.parent?.recordID == CKRecord.ID(recordName: plan.rootRecordName, zoneID: zone),
              record.parent?.action == CKRecord.ReferenceAction.none,
              record.share == nil || record.share?.recordID == CKRecord.ID(recordName: plan.shareRecordName, zoneID: zone),
              let bytes = record["manifest"] as? Data, bytes.count <= 8192 else { throw StaffReplicaDeliveryError.invalid }
        let manifest = try StaffWorkspacePublicationContract.decode(StaffWorkspaceCloudSealManifest.self, from: bytes, maximum: 8192)
        try manifest.validate(plan: plan, workspace: workspace, now: now)
        guard record.recordID.recordName == (payload ? payloadName(manifest.selectionID) : headName) else {
            throw StaffReplicaDeliveryError.changed
        }
        return manifest
    }
    static func payload(_ record: CKRecord, manifest: StaffWorkspaceCloudSealManifest, key: Data) throws -> StaffWorkspaceCloudSealedPackage {
        guard let asset = record["payload"] as? CKAsset, let url = asset.fileURL, url.isFileURL else {
            throw StaffReplicaDeliveryError.invalid
        }
        // CloudKit owns this staging URL. Read bounded bytes immediately; never
        // retain its URL as durable recovery state or delete Apple's staged file.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: manifest.sealedBytes + 1) ?? Data()
        return try .init(manifest: manifest, bytes: data, key: key)
    }
}

/// Full-workspace cloud-seal transfer. Uses the same StaffReplicaCloudIO doubles as
/// core-field delivery, but distinct CK record types/names so the two never collide.
@MainActor enum StaffWorkspaceCloudTransfer {
    private static func read(_ ids: [CKRecord.ID], io: StaffReplicaCloudIO) async throws -> [CKRecord.ID: CKRecord] {
        try Task.checkCancellation(); try await io.authorize()
        let values = try await io.read(ids)
        try Task.checkCancellation(); try await io.authorize()
        guard Set(values.keys).isSubset(of: Set(ids)), values.allSatisfy({ $0.key == $0.value.recordID }) else {
            throw StaffReplicaDeliveryError.invalid
        }
        return values
    }

    static func publish(_ original: StaffWorkspaceCloudSealedPackage, plan: CloudKitStaffSharePlan,
                        workspace: CompanyWorkspaceIdentity, io: StaffReplicaCloudIO,
                        now: () -> Date = Date.init) async throws {
        try original.manifest.validate(plan: plan, workspace: workspace, now: now())
        guard io.zone.zoneName == plan.zoneName, io.zone.ownerName == CKCurrentUserDefaultName else {
            throw StaffReplicaDeliveryError.access
        }
        let payloadID = CKRecord.ID(recordName: StaffWorkspaceCloudRecords.payloadName(original.manifest.selectionID), zoneID: io.zone)
        let headID = CKRecord.ID(recordName: StaffWorkspaceCloudRecords.headName, zoneID: io.zone)
        let values = try await read([payloadID, headID], io: io)
        let existing = values[payloadID], head = values[headID]
        if let existing {
            let manifest = try StaffWorkspaceCloudRecords.manifest(existing, plan: plan, workspace: workspace,
                                                                   zone: io.zone, payload: true, now: now())
            guard manifest == original.manifest else { throw StaffReplicaDeliveryError.changed }
            guard try StaffWorkspaceCloudRecords.payload(existing, manifest: manifest, key: original.key).bytes == original.bytes else {
                throw StaffReplicaDeliveryError.changed
            }
        }
        if let head {
            let manifest = try StaffWorkspaceCloudRecords.manifest(head, plan: plan, workspace: workspace,
                                                                   zone: io.zone, payload: false, now: now())
            if manifest == original.manifest {
                guard existing != nil else { throw StaffReplicaDeliveryError.invalid }
                try await verifyOwnerPublication(original, plan: plan, workspace: workspace, io: io, now: now())
                return // Original asset and current head are independently rechecked.
            }
            guard manifest.sourceSequence < original.manifest.sourceSequence else { throw StaffReplicaDeliveryError.superseded }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GAStaffWorkspaceUpload-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("payload.sealed")
        try original.bytes.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        var saving: [CKRecord] = []
        if existing == nil {
            saving.append(try StaffWorkspaceCloudRecords.make(original.manifest, plan: plan, zone: io.zone, asset: CKAsset(fileURL: url)))
        }
        saving.append(try StaffWorkspaceCloudRecords.make(original.manifest, plan: plan, zone: io.zone, updating: head))
        try Task.checkCancellation(); try await io.authorize()
        try await io.save(saving)
        try Task.checkCancellation(); try await io.authorize()
        let confirmed = try await read([payloadID, headID], io: io)
        guard let confirmedPayload = confirmed[payloadID], let confirmedHead = confirmed[headID] else {
            throw StaffReplicaDeliveryError.pending
        }
        let saved = try StaffWorkspaceCloudRecords.manifest(confirmedPayload, plan: plan, workspace: workspace,
                                                            zone: io.zone, payload: true, now: now())
        let current = try StaffWorkspaceCloudRecords.manifest(confirmedHead, plan: plan, workspace: workspace,
                                                              zone: io.zone, payload: false, now: now())
        guard saved == original.manifest else { throw StaffReplicaDeliveryError.changed }
        guard try StaffWorkspaceCloudRecords.payload(confirmedPayload, manifest: saved, key: original.key).bytes == original.bytes else {
            throw StaffReplicaDeliveryError.changed
        }
        guard current == saved else { throw StaffReplicaDeliveryError.superseded }
    }

    static func ownerHead(plan: CloudKitStaffSharePlan, workspace: CompanyWorkspaceIdentity,
                          io: StaffReplicaCloudIO, now: Date) async throws -> StaffWorkspaceCloudSealManifest? {
        guard io.zone.zoneName == plan.zoneName, io.zone.ownerName == CKCurrentUserDefaultName else {
            throw StaffReplicaDeliveryError.access
        }
        let id = CKRecord.ID(recordName: StaffWorkspaceCloudRecords.headName, zoneID: io.zone)
        guard let record = try await read([id], io: io)[id] else { return nil }
        return try StaffWorkspaceCloudRecords.manifest(record, plan: plan, workspace: workspace, zone: io.zone, payload: false, now: now)
    }

    static func verifyOwnerPublication(_ original: StaffWorkspaceCloudSealedPackage, plan: CloudKitStaffSharePlan,
                                       workspace: CompanyWorkspaceIdentity, io: StaffReplicaCloudIO, now: Date) async throws {
        guard try await ownerHead(plan: plan, workspace: workspace, io: io, now: now) == original.manifest else {
            throw StaffReplicaDeliveryError.superseded
        }
        let id = CKRecord.ID(recordName: StaffWorkspaceCloudRecords.payloadName(original.manifest.selectionID), zoneID: io.zone)
        guard let record = try await read([id], io: io)[id] else { throw StaffReplicaDeliveryError.pending }
        guard try StaffWorkspaceCloudRecords.manifest(record, plan: plan, workspace: workspace, zone: io.zone, payload: true, now: now) == original.manifest,
              try StaffWorkspaceCloudRecords.payload(record, manifest: original.manifest, key: original.key).bytes == original.bytes else {
            throw StaffReplicaDeliveryError.changed
        }
        guard try await ownerHead(plan: plan, workspace: workspace, io: io, now: now) == original.manifest else {
            throw StaffReplicaDeliveryError.superseded
        }
    }

    /// Participant head read for shared-zone authority. Zone owner must be the
    /// share owner (not the current user). Does not open sealed bytes.
    static func participantHead(plan: CloudKitStaffSharePlan, workspace: CompanyWorkspaceIdentity,
                                io: StaffReplicaCloudIO, now: Date) async throws -> StaffWorkspaceCloudSealManifest? {
        guard io.zone.zoneName == plan.zoneName, io.zone.ownerName != CKCurrentUserDefaultName,
              CloudKitStaffSharePlan.accountHash(recordName: io.zone.ownerName, environment: plan.environment) == plan.ownerAccountHash else {
            throw StaffReplicaDeliveryError.access
        }
        let id = CKRecord.ID(recordName: StaffWorkspaceCloudRecords.headName, zoneID: io.zone)
        guard let record = try await read([id], io: io)[id] else { return nil }
        return try StaffWorkspaceCloudRecords.manifest(record, plan: plan, workspace: workspace, zone: io.zone, payload: false, now: now)
    }

    /// Participant receive: download sealed bytes from shared CK. Decrypt only with
    /// an already-authorized key from HTTP GET `.../content/cloud-key` (or owner
    /// cloud-seal) — never from CloudKit itself. StaffWorkspaceContentCoordinator
    /// receiveAndLease wires key release, verified open, and the durable lease marker.
    static func download(plan: CloudKitStaffSharePlan, workspace: CompanyWorkspaceIdentity,
                         io: StaffReplicaCloudIO, key: Data, now: () -> Date = Date.init) async throws -> StaffWorkspaceCloudSealedPackage {
        guard io.zone.zoneName == plan.zoneName, io.zone.ownerName != CKCurrentUserDefaultName,
              CloudKitStaffSharePlan.accountHash(recordName: io.zone.ownerName, environment: plan.environment) == plan.ownerAccountHash else {
            throw StaffReplicaDeliveryError.access
        }
        let headID = CKRecord.ID(recordName: StaffWorkspaceCloudRecords.headName, zoneID: io.zone)
        guard let head = try await read([headID], io: io)[headID] else { throw StaffReplicaDeliveryError.pending }
        let manifest = try StaffWorkspaceCloudRecords.manifest(head, plan: plan, workspace: workspace,
                                                               zone: io.zone, payload: false, now: now())
        let id = CKRecord.ID(recordName: StaffWorkspaceCloudRecords.payloadName(manifest.selectionID), zoneID: io.zone)
        guard let record = try await read([id], io: io)[id] else { throw StaffReplicaDeliveryError.pending }
        guard try StaffWorkspaceCloudRecords.manifest(record, plan: plan, workspace: workspace,
                                                      zone: io.zone, payload: true, now: now()) == manifest else {
            throw StaffReplicaDeliveryError.changed
        }
        let package = try StaffWorkspaceCloudRecords.payload(record, manifest: manifest, key: key)
        guard let current = try await read([headID], io: io)[headID],
              try StaffWorkspaceCloudRecords.manifest(current, plan: plan, workspace: workspace,
                  zone: io.zone, payload: false, now: now()) == manifest else { throw StaffReplicaDeliveryError.superseded }
        try Task.checkCancellation(); try await io.authorize()
        return package
    }

    /// Staff/owner HTTP path for already-prepared seal key release (never sealed bytes).
    static func cloudKeyPath(plan: CloudKitStaffSharePlan, request: StaffWorkspaceSelectionRequest) -> String {
        StaffWorkspaceContentHTTPPolicy.path(plan, request: request, suffix: "/content/cloud-key")
    }

    /// Decode a staff/owner cloud-key release response. Same schema as cloud-seal;
    /// this is key release only — never sealed content bytes.
    static func decodeKeyRelease(_ bytes: Data, against content: StaffWorkspaceContentReceipt) throws -> StaffWorkspaceCloudSealResponse {
        let response = try StaffWorkspacePublicationContract.decode(StaffWorkspaceCloudSealResponse.self, from: bytes, maximum: 8192)
        try response.validate(against: content)
        return response
    }
}
