import CloudKit
import Foundation

#if DEBUG
/// One-time DEBUG-only utility that registers every record type the staff
/// sharing feature writes into this container's Development schema.
///
/// CloudKit creates record types implicitly on first write in Development but
/// never in Production, where a type must instead be deployed from
/// Development. This app has only ever created staff shares from distribution
/// builds, which run against Production, so none of the staff sharing types
/// exist in either schema and every invitation fails with "Cannot create new
/// type … in production schema".
///
/// Verified against the live container on 2026-09-15: the Development schema
/// held only the 32 SwiftData-mirrored `CD_*` types plus `Users`, and
/// Production held 24 of those. Neither contained `cloudkit.share` nor any
/// `GAStaff*` type.
///
/// Registering only the root type and the share is not enough. A staff
/// invitation writes six types in total, and the delivery step fails on the
/// first unregistered one:
///
/// | Type | Fields | Written by |
/// | --- | --- | --- |
/// | `GAStaffWorkspace` | six strings/int | `CloudKitStaffShareRecords.ownerDraft` |
/// | `cloudkit.share` | system | same |
/// | `GAStaffWorkspaceHead` | `manifest` | `StaffWorkspaceCloudRecords.make` |
/// | `GAStaffWorkspaceSealedPayload` | `manifest`, `payload` | same |
/// | `GAStaffReplicaHead` | `manifest` | `StaffReplicaCloudRecords.make` |
/// | `GAStaffReplicaSealedPayload` | `manifest`, `payload` | same |
///
/// Safety properties:
/// - Compiled out of release builds entirely.
/// - Refuses to run unless the signed profile resolves to Development, so it
///   can never write to the Production database even if reached.
/// - Writes to its own `ga-schemaseed-` zone, never a `ga-staff-` zone, so it
///   cannot collide with or be mistaken for a real staff share.
/// - Uses each type's exact production field names and value kinds, so the
///   schema this registers is the schema the real feature needs — no extra
///   fields, and no type the feature does not already write.
@MainActor
enum CloudKitSchemaSeed {
    static let zonePrefix = "ga-schemaseed-"

    /// Field names and value kinds mirrored from the real writers. Changing a
    /// writer without changing this list will seed a schema the feature cannot
    /// use, so `CloudKitSchemaSeedTests` pins both against each other.
    static let seededTypes = [
        CloudKitStaffShareRecords.rootType,
        "GAStaffWorkspaceHead",
        "GAStaffWorkspaceSealedPayload",
        "GAStaffReplicaHead",
        "GAStaffReplicaSealedPayload",
    ]

    static func seedShareRecordType() async -> String {
        var log: [String] = []
        var assetURLs: [URL] = []
        defer { for url in assetURLs { try? FileManager.default.removeItem(at: url) } }
        do {
            let account = try await CompanyCloudKitRuntimeAccount.current()
            guard account.environment == "development" else {
                return "Refused: resolved environment is \"\(account.environment)\", not development. Run a debug build signed with a development profile."
            }
            let database = CKContainer(identifier: GunnAireCloudKit.containerIdentifier).privateCloudDatabase
            let zone = CKRecordZone(zoneName: zonePrefix + UUID().uuidString.lowercased())
            let zones = try await database.modifyRecordZones(saving: [zone], deleting: [])
            guard let savedZone = zones.saveResults[zone.zoneID] else {
                return "Zone save returned no result for \(zone.zoneID.zoneName)."
            }
            _ = try savedZone.get()
            log.append("Zone \(zone.zoneID.zoneName) created.")

            // Stage 1: the root record and its share. These must land together
            // so the share has a root to attach to. Saving them first also
            // means a later child failure still leaves cloudkit.share
            // registered, and the report says exactly how far we got.
            let rootID = CKRecord.ID(recordName: "workspace", zoneID: zone.zoneID)
            let root = CKRecord(recordType: CloudKitStaffShareRecords.rootType, recordID: rootID)
            // Same field set CloudKitStaffShareRecords.verifyRoot requires.
            root["protocolVersion"] = NSNumber(value: 1)
            root["companyID"] = UUID().uuidString.lowercased() as CKRecordValue
            root["replicaID"] = UUID().uuidString.lowercased() as CKRecordValue
            root["membershipID"] = UUID().uuidString.lowercased() as CKRecordValue
            root["memberRevision"] = "schema-seed" as CKRecordValue
            root["projectionPolicy"] = "schema-seed" as CKRecordValue

            // A share with no participants is still a saved cloudkit.share
            // record, which is all the schema needs.
            let share = CKShare(rootRecord: root, shareID: .init(recordName: "share-seed", zoneID: zone.zoneID))
            share.publicPermission = .none
            share[CKShare.SystemFieldKey.title] = "GunnAire Ops schema seed" as CKRecordValue

            if let failure = try await save([root, share], to: database) {
                log.append("FAILED at root + cloudkit.share: \(failure)")
                return report(log, zone: zone)
            }
            log.append("Registered \(CloudKitStaffShareRecords.rootType) and cloudkit.share.")

            // Stage 2: the four transfer records. `manifest` is Data on every
            // one and `payload` is a CKAsset on the two sealed-payload types,
            // matching StaffWorkspaceCloudRecords.make / StaffReplicaCloudRecords.make.
            var children: [CKRecord] = []
            for type in seededTypes.dropFirst() {
                let record = CKRecord(recordType: type, recordID: .init(recordName: "seed-" + type, zoneID: zone.zoneID))
                record.parent = .init(recordID: rootID, action: .none)
                record["manifest"] = Data("schema-seed".utf8) as CKRecordValue
                if type.hasSuffix("SealedPayload") {
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("ga-schemaseed-\(type)-\(UUID().uuidString).bin")
                    try Data("schema-seed".utf8).write(to: url, options: .atomic)
                    assetURLs.append(url)
                    record["payload"] = CKAsset(fileURL: url)
                }
                children.append(record)
            }

            if let failure = try await save(children, to: database) {
                log.append("FAILED at transfer records: \(failure)")
                return report(log, zone: zone)
            }
            log.append("Registered " + seededTypes.dropFirst().joined(separator: ", ") + ".")
            log.append("All 6 staff sharing types are now in the Development schema.")
            return report(log, zone: zone)
        } catch {
            log.append("Failed: \(type(of: error)): \(error.localizedDescription)")
            return log.joined(separator: "\n")
        }
    }

    /// Saves atomically and returns a description of the real failure, or nil
    /// on success. Prefers a genuine CKError over the `.batchRequestFailed`
    /// placeholder a sibling record reports when an atomic save is rolled back.
    private static func save(_ records: [CKRecord], to database: CKDatabase) async throws -> String? {
        let saved = try await database.modifyRecords(
            saving: records, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true
        )
        let failures = saved.saveResults.values.compactMap { result -> Error? in
            if case .failure(let error) = result { return error }
            return nil
        }
        guard let real = failures.first(where: { ($0 as? CKError)?.code != .batchRequestFailed }) ?? failures.first else {
            return nil
        }
        return "\(type(of: real)): \(real.localizedDescription)"
    }

    private static func report(_ log: [String], zone: CKRecordZone) -> String {
        (log + [
            "",
            "Zone: \(zone.zoneID.zoneName)",
            "Next: confirm the types appear under Record Types (Development) in CloudKit Console, deploy Development to Production, then delete this zone.",
        ]).joined(separator: "\n")
    }
}
#endif
