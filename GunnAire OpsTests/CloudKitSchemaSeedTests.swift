import CloudKit
import Foundation
import XCTest
@testable import GunnAire_Ops

/// Pins the schema seeder against the record types the staff sharing feature
/// actually writes.
///
/// The seeder exists because none of these types are present in the container's
/// Development schema, so CloudKit cannot create them in Production. An earlier
/// version seeded only the root type and the share, which would have left a
/// staff invitation failing on the very next write. These tests fail if the
/// seeded list and the real writers ever drift apart again.
final class CloudKitSchemaSeedTests: XCTestCase {
    /// Record types written by `StaffWorkspaceCloudRecords.make` and
    /// `StaffReplicaCloudRecords.make`, asserted literally in
    /// `StaffWorkspaceCloudSealTests` and `StaffReplicaDeliveryTests`.
    private let transferTypes: Set<String> = [
        "GAStaffWorkspaceHead",
        "GAStaffWorkspaceSealedPayload",
        "GAStaffReplicaHead",
        "GAStaffReplicaSealedPayload",
    ]

    func testSeedsRootTypeFirst() {
        XCTAssertEqual(CloudKitSchemaSeed.seededTypes.first, CloudKitStaffShareRecords.rootType)
        XCTAssertEqual(CloudKitStaffShareRecords.rootType, "GAStaffWorkspace")
    }

    func testSeedsEveryTypeTheFeatureWrites() {
        let seeded = Set(CloudKitSchemaSeed.seededTypes)
        XCTAssertEqual(seeded.count, CloudKitSchemaSeed.seededTypes.count, "seededTypes must not contain duplicates")
        XCTAssertEqual(
            seeded,
            transferTypes.union([CloudKitStaffShareRecords.rootType]),
            "Every record type the staff sharing feature writes must be seeded, or the first unseeded write fails in Production."
        )
    }

    /// The seeder decides whether to attach a CKAsset by suffix. If a type is
    /// ever renamed, that heuristic must keep selecting exactly the two types
    /// whose validators require a `payload` key.
    func testPayloadSuffixSelectsExactlyTheAssetBearingTypes() {
        let withAsset = CloudKitSchemaSeed.seededTypes.filter { $0.hasSuffix("SealedPayload") }
        XCTAssertEqual(
            Set(withAsset),
            ["GAStaffWorkspaceSealedPayload", "GAStaffReplicaSealedPayload"],
            "Only the sealed-payload types carry a CKAsset; the seeder's suffix check must match their validators."
        )

        let withoutAsset = CloudKitSchemaSeed.seededTypes.filter { !$0.hasSuffix("SealedPayload") }
        XCTAssertEqual(Set(withoutAsset), ["GAStaffWorkspace", "GAStaffWorkspaceHead", "GAStaffReplicaHead"])
    }

    /// The seeder never writes into a real staff zone.
    func testSeedZonePrefixIsDistinctFromStaffZones() {
        XCTAssertEqual(CloudKitSchemaSeed.zonePrefix, "ga-schemaseed-")
        XCTAssertFalse(CloudKitSchemaSeed.zonePrefix.hasPrefix("ga-staff-"))
        XCTAssertFalse("ga-staff-".hasPrefix(CloudKitSchemaSeed.zonePrefix))
    }

    /// The root record the seeder writes must carry the exact field set
    /// `CloudKitStaffShareRecords.verifyRoot` requires, or the seeded schema
    /// would not match the one the feature needs.
    func testSeededRootFieldSetMatchesVerifyRootExpectations() throws {
        let zone = CKRecordZone.ID(zoneName: CloudKitSchemaSeed.zonePrefix + "test", ownerName: CKCurrentUserDefaultName)
        let root = CKRecord(recordType: CloudKitStaffShareRecords.rootType, recordID: .init(recordName: "workspace", zoneID: zone))
        root["protocolVersion"] = NSNumber(value: 1)
        root["companyID"] = UUID().uuidString.lowercased() as CKRecordValue
        root["replicaID"] = UUID().uuidString.lowercased() as CKRecordValue
        root["membershipID"] = UUID().uuidString.lowercased() as CKRecordValue
        root["memberRevision"] = "schema-seed" as CKRecordValue
        root["projectionPolicy"] = "schema-seed" as CKRecordValue

        XCTAssertEqual(
            Set(root.allKeys()),
            ["protocolVersion", "companyID", "replicaID", "membershipID", "memberRevision", "projectionPolicy"]
        )
    }
}
