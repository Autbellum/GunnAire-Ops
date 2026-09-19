import CloudKit
import Foundation
import XCTest
@testable import GunnAire_Ops

/// Pins the schema seeder against what the app actually writes to CloudKit.
///
/// The seeder exists because the Development schema is missing both the six
/// record types a staff invitation writes and nine SwiftData stored properties
/// added between 2026-09-07 and 2026-09-14. An earlier version seeded only the
/// staff root and the share, which would have left an invitation failing on the
/// very next write. These tests fail if the seeded set drifts from the writers
/// or if a field's value kind stops matching how this container stores it.
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

    // MARK: - Staff sharing types

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

    func testSeedZonePrefixIsDistinctFromStaffZones() {
        XCTAssertEqual(CloudKitSchemaSeed.zonePrefix, "ga-schemaseed-")
        XCTAssertFalse(CloudKitSchemaSeed.zonePrefix.hasPrefix("ga-staff-"))
        XCTAssertFalse("ga-staff-".hasPrefix(CloudKitSchemaSeed.zonePrefix))
    }

    func testSeededRootFieldSetMatchesVerifyRootExpectations() {
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

    // MARK: - Missing SwiftData model fields

    /// The exact nine stored properties found absent from the Development
    /// schema, with the record type each is mirrored under.
    private let expectedMissing: [String: Set<String>] = [
        "CD_Payment": ["CD_collectionAttemptID", "CD_providerPaymentStatus"],
        "CD_Invoice": ["CD_quickBooksPaymentReviewJSON", "CD_milestoneDraftReceiptJSON"],
        "CD_Item": [
            "CD_quickBooksCatalogReceiptJSON",
            "CD_quickBooksInventorySetupJSON",
            "CD_quickBooksCatalogDetailsJSON",
        ],
        "CD_TimeEntry": ["CD_deviceClockDriftSeconds", "CD_clockDriftFlaggedForReview"],
    ]

    func testSeedsExactlyTheMissingModelFields() {
        let actual = CloudKitSchemaSeed.missingModelFields.mapValues { Set($0.keys) }
        XCTAssertEqual(actual, expectedMissing)
        let total = CloudKitSchemaSeed.missingModelFields.values.reduce(0) { $0 + $1.count }
        XCTAssertEqual(total, 9, "Nine stored properties were absent from the Development schema.")
    }

    func testEveryMirroredNameCarriesCoreDataPrefix() {
        for (type, fields) in CloudKitSchemaSeed.missingModelFields {
            XCTAssertTrue(type.hasPrefix("CD_"), "\(type) must be a Core Data mirrored record type")
            for field in fields.keys {
                XCTAssertTrue(field.hasPrefix("CD_"), "\(field) must carry Core Data's CD_ prefix")
            }
        }
    }

    /// The value kinds are taken from how this container already stores the
    /// equivalent Swift types: UUID?/String? as STRING (`CD_refundedPaymentID`),
    /// Double as DOUBLE (`CD_amount`), Bool as INT(64) (`CD_isRefund`).
    /// CloudKit infers a field's type from the value, so an NSNumber built from
    /// the wrong Swift type silently registers the wrong column.
    func testValueKindsProduceTheCloudKitTypesTheSchemaUses() throws {
        XCTAssertTrue(CloudKitSchemaSeed.value(for: .string) is String)

        let double = try XCTUnwrap(CloudKitSchemaSeed.value(for: .double) as? NSNumber)
        XCTAssertEqual(String(cString: double.objCType), "d", "Double fields must serialize as DOUBLE, not INT(64)")

        let int64 = try XCTUnwrap(CloudKitSchemaSeed.value(for: .int64) as? NSNumber)
        XCTAssertEqual(String(cString: int64.objCType), "q", "Bool fields must serialize as INT(64), not DOUBLE")
    }

    func testClockDriftFieldsUseTheKindsMatchingTheirSwiftTypes() {
        let timeEntry = CloudKitSchemaSeed.missingModelFields["CD_TimeEntry"]
        // deviceClockDriftSeconds is Double?, clockDriftFlaggedForReview is Bool.
        XCTAssertEqual(timeEntry?["CD_deviceClockDriftSeconds"], .double)
        XCTAssertEqual(timeEntry?["CD_clockDriftFlaggedForReview"], .int64)
    }

    func testPaymentIdentifierFieldUsesStringLikeItsSiblingUUIDColumn() {
        // collectionAttemptID is UUID?, stored as STRING exactly like the
        // already-registered refundedPaymentID: UUID? column.
        XCTAssertEqual(CloudKitSchemaSeed.missingModelFields["CD_Payment"]?["CD_collectionAttemptID"], .string)
    }

    /// The seeded record types must not collide with the staff sharing types:
    /// the two stages write into the same zone in one run.
    func testModelTypesAndStaffTypesAreDisjoint() {
        let model = Set(CloudKitSchemaSeed.missingModelFields.keys)
        XCTAssertTrue(model.isDisjoint(with: Set(CloudKitSchemaSeed.seededTypes)))
    }
}
