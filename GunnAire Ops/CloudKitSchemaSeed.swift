import CloudKit
import Foundation

#if DEBUG
/// One-time DEBUG-only utility that registers CloudKit's built-in
/// `cloudkit.share` record type in this container's Development schema.
///
/// CloudKit creates record types implicitly on first write in Development but
/// never in Production, where a type must instead be deployed from
/// Development. This app has only ever created staff shares from distribution
/// builds, which run against Production, so `cloudkit.share` exists in neither
/// schema and every invitation fails with "Cannot create new type
/// cloudkit.share in production schema". Saving one share here creates the
/// type in Development so it can be deployed to Production.
///
/// Safety properties:
/// - Compiled out of release builds entirely.
/// - Refuses to run unless the signed profile resolves to Development, so it
///   can never write to the Production database even if reached.
/// - Writes to its own `ga-schemaseed-` zone, never a `ga-staff-` zone, so it
///   cannot collide with or be mistaken for a real staff share.
/// - Reuses the staff root record type and its exact field set, so the only
///   thing this adds to the schema is `cloudkit.share` itself. Nothing new
///   would be carried into Production by the subsequent deploy.
@MainActor
enum CloudKitSchemaSeed {
    static let zonePrefix = "ga-schemaseed-"

    static func seedShareRecordType() async -> String {
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

            // Same record type and field set as the real staff share root, so
            // no additional custom type or field enters the schema.
            let root = CKRecord(
                recordType: CloudKitStaffShareRecords.rootType,
                recordID: .init(recordName: "workspace", zoneID: zone.zoneID)
            )
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

            let saved = try await database.modifyRecords(
                saving: [root, share], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true
            )
            let failures = saved.saveResults.values.compactMap { result -> Error? in
                if case .failure(let error) = result { return error }
                return nil
            }
            // Prefer a real CKError over the .batchRequestFailed placeholder a
            // sibling record reports when an atomic save is rolled back.
            if let real = failures.first(where: { ($0 as? CKError)?.code != .batchRequestFailed }) ?? failures.first {
                return "Share save failed: \(type(of: real)): \(real.localizedDescription)"
            }
            return """
            Seeded cloudkit.share in Development.
            Zone: \(zone.zoneID.zoneName)
            Next: confirm cloudkit.share appears under Record Types (Development) in CloudKit Console, deploy the Development schema to Production, then delete this zone.
            """
        } catch {
            return "Failed: \(type(of: error)): \(error.localizedDescription)"
        }
    }
}
#endif
