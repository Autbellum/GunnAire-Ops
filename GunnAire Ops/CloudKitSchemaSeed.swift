import CloudKit
import Foundation

#if DEBUG
/// One-time DEBUG-only utility that brings this container's Development schema
/// up to date with what the app actually writes.
///
/// CloudKit creates record types and fields implicitly on first write in
/// Development but never in Production, where they must instead be deployed
/// from Development. Two separate gaps exist, both verified against the live
/// container on 2026-09-15:
///
/// 1. **Staff sharing types.** The app has only ever created staff shares from
///    distribution builds, which run against Production, so none of the six
///    types a staff invitation writes exist in either schema and every
///    invitation fails with "Cannot create new type … in production schema".
///
/// 2. **SwiftData model fields.** Nine stored properties added between
///    2026-09-07 and 2026-09-14 are absent from the Development schema, because
///    no development-environment sync has happened since. Seven of them are
///    QuickBooks sync-state fields.
///
/// Apple's `NSPersistentCloudKitContainer.initializeCloudKitSchema(options:)`
/// exists for exactly the second problem — it "creates a set of representative
/// CKRecord instances … a representative value for every field Core Data might
/// serialize", uploads them, and then "deletes the representative records".
/// SwiftData exposes no equivalent and no access to the underlying container,
/// so this reproduces the same mechanism directly.
///
/// Safety properties:
/// - Compiled out of release builds entirely.
/// - Refuses to run unless the signed profile resolves to Development, so it
///   can never write to the Production database even if reached.
/// - Every record goes into a dedicated `ga-schemaseed-` zone, never a
///   `ga-staff-` zone and never Core Data's own mirroring zone, so the app's
///   local store cannot import these as real Payments, Invoices or Items.
/// - That zone is deleted once the writes land. Record types and fields are
///   container-level schema and survive the zone's deletion; the representative
///   data does not. Nothing is left behind to sync anywhere.
/// - Field value kinds are taken from how this same container already stores
///   the equivalent Swift types (`UUID` → STRING via `CD_refundedPaymentID`,
///   `Double` → DOUBLE via `CD_amount`, `Bool` → INT(64) via `CD_isRefund`),
///   not from assumption.
@MainActor
enum CloudKitSchemaSeed {
    static let zonePrefix = "ga-schemaseed-"

    /// Record types a staff invitation writes, in write order. Pinned against
    /// the real writers by `CloudKitSchemaSeedTests`.
    static let seededTypes = [
        CloudKitStaffShareRecords.rootType,
        "GAStaffWorkspaceHead",
        "GAStaffWorkspaceSealedPayload",
        "GAStaffReplicaHead",
        "GAStaffReplicaSealedPayload",
    ]

    /// How CloudKit stores a given Swift property, as observed in this
    /// container's existing schema rather than assumed.
    enum FieldKind: Equatable {
        case string   // String? and UUID? both serialize as STRING
        case double   // Double
        case int64    // Bool
    }

    /// SwiftData stored properties missing from the Development schema, keyed
    /// by the mirrored record type. Field names carry Core Data's `CD_` prefix.
    /// Only the missing fields are written: everything else on these types is
    /// already registered, and a sparser record is less likely to resemble a
    /// real financial record if it is ever seen.
    static let missingModelFields: [String: [String: FieldKind]] = [
        "CD_Payment": [
            "CD_collectionAttemptID": .string,
            "CD_providerPaymentStatus": .string,
        ],
        "CD_Invoice": [
            "CD_quickBooksPaymentReviewJSON": .string,
            "CD_milestoneDraftReceiptJSON": .string,
        ],
        "CD_Item": [
            "CD_quickBooksCatalogReceiptJSON": .string,
            "CD_quickBooksInventorySetupJSON": .string,
            "CD_quickBooksCatalogDetailsJSON": .string,
        ],
        "CD_TimeEntry": [
            "CD_deviceClockDriftSeconds": .double,
            "CD_clockDriftFlaggedForReview": .int64,
        ],
    ]

    static func value(for kind: FieldKind) -> CKRecordValue {
        switch kind {
        case .string: return "ga-schema-seed" as CKRecordValue
        case .double: return NSNumber(value: Double(0)) as CKRecordValue
        case .int64: return NSNumber(value: Int64(0)) as CKRecordValue
        }
    }

    static func seedDevelopmentSchema() async -> String {
        var log: [String] = []
        var assetURLs: [URL] = []
        defer { for url in assetURLs { try? FileManager.default.removeItem(at: url) } }
        var zone: CKRecordZone?
        var database: CKDatabase?
        do {
            let account = try await CompanyCloudKitRuntimeAccount.current()
            guard account.environment == "development" else {
                return "Refused: resolved environment is \"\(account.environment)\", not development. Run a debug build signed with a development profile on a physical device — the Simulator has no embedded profile and resolves \"production\"."
            }
            let db = CKContainer(identifier: GunnAireCloudKit.containerIdentifier).privateCloudDatabase
            database = db
            let newZone = CKRecordZone(zoneName: zonePrefix + UUID().uuidString.lowercased())
            let zones = try await db.modifyRecordZones(saving: [newZone], deleting: [])
            guard let savedZone = zones.saveResults[newZone.zoneID] else {
                return "Zone save returned no result for \(newZone.zoneID.zoneName)."
            }
            _ = try savedZone.get()
            zone = newZone
            log.append("Zone \(newZone.zoneID.zoneName) created.")

            // Stage 1: the staff share root and its share. These must land
            // together so the share has a root to attach to.
            let rootID = CKRecord.ID(recordName: "workspace", zoneID: newZone.zoneID)
            let root = CKRecord(recordType: CloudKitStaffShareRecords.rootType, recordID: rootID)
            // Same field set CloudKitStaffShareRecords.verifyRoot requires.
            root["protocolVersion"] = NSNumber(value: 1)
            root["companyID"] = UUID().uuidString.lowercased() as CKRecordValue
            root["replicaID"] = UUID().uuidString.lowercased() as CKRecordValue
            root["membershipID"] = UUID().uuidString.lowercased() as CKRecordValue
            root["memberRevision"] = "schema-seed" as CKRecordValue
            root["projectionPolicy"] = "schema-seed" as CKRecordValue

            let share = CKShare(rootRecord: root, shareID: .init(recordName: "share-seed", zoneID: newZone.zoneID))
            share.publicPermission = .none
            share[CKShare.SystemFieldKey.title] = "GunnAire Ops schema seed" as CKRecordValue

            if let failure = try await save([root, share], to: db) {
                log.append("FAILED at staff root + cloudkit.share: \(failure)")
                return report(log, zone: newZone, cleanedUp: false)
            }
            log.append("Registered \(CloudKitStaffShareRecords.rootType) and cloudkit.share.")

            // Stage 2: the four transfer records. `manifest` is Data on every
            // one; `payload` is a CKAsset on the two sealed-payload types.
            var children: [CKRecord] = []
            for type in seededTypes.dropFirst() {
                let record = CKRecord(recordType: type, recordID: .init(recordName: "seed-" + type, zoneID: newZone.zoneID))
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
            if let failure = try await save(children, to: db) {
                log.append("FAILED at staff transfer records: \(failure)")
                return report(log, zone: newZone, cleanedUp: false)
            }
            log.append("Registered " + seededTypes.dropFirst().joined(separator: ", ") + ".")

            // Stage 3: representative records carrying the SwiftData stored
            // properties that the Development schema is missing.
            var modelRecords: [CKRecord] = []
            for (type, fields) in missingModelFields.sorted(by: { $0.key < $1.key }) {
                let record = CKRecord(recordType: type, recordID: .init(recordName: "seed-" + type, zoneID: newZone.zoneID))
                for (field, kind) in fields.sorted(by: { $0.key < $1.key }) {
                    record[field] = value(for: kind)
                }
                modelRecords.append(record)
            }
            if let failure = try await save(modelRecords, to: db) {
                log.append("FAILED at model field records: \(failure)")
                return report(log, zone: newZone, cleanedUp: false)
            }
            let fieldCount = missingModelFields.values.reduce(0) { $0 + $1.count }
            log.append("Registered \(fieldCount) missing model fields across " + missingModelFields.keys.sorted().joined(separator: ", ") + ".")

            // Cleanup: drop the zone so no representative record survives. The
            // record types and fields just registered are container-level
            // schema and are unaffected.
            _ = try await db.modifyRecordZones(saving: [], deleting: [newZone.zoneID])
            log.append("Deleted zone \(newZone.zoneID.zoneName); schema retained, no records left behind.")
            return report(log, zone: newZone, cleanedUp: true)
        } catch {
            log.append("Failed: \(type(of: error)): \(error.localizedDescription)")
            if let zone, let database {
                _ = try? await database.modifyRecordZones(saving: [], deleting: [zone.zoneID])
                log.append("Attempted cleanup of zone \(zone.zoneID.zoneName).")
            }
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

    private static func report(_ log: [String], zone: CKRecordZone, cleanedUp: Bool) -> String {
        var lines = log
        lines.append("")
        if cleanedUp {
            lines.append("Next: confirm the six GAStaff*/cloudkit.share types and the nine model fields appear in CloudKit Console → Development, then deploy Development to Production.")
        } else {
            lines.append("Zone \(zone.zoneID.zoneName) was left in place for inspection. Delete it once you have read the failure above.")
        }
        return lines.joined(separator: "\n")
    }
}
#endif
