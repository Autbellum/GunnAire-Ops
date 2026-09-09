import Foundation
import CryptoKit

enum StaffReplicaDeliveryError: Error, LocalizedError, Equatable {
    case invalid, changed, access, storage, pending, superseded, unavailable
    var errorDescription: String? {
        switch self {
        case .invalid: "The original staff snapshot could not be verified. No workspace data was replaced."
        case .changed: "Staff access or the original snapshot changed. Keep saved work and refresh its authorization."
        case .access: "Verify the approved business and iCloud accounts before synchronizing staff data."
        case .storage: "Staff sync recovery could not be saved. Existing work was retained; do not reinstall the app."
        case .pending: "The owner has not delivered this staff snapshot through iCloud yet."
        case .superseded: "A newer staff snapshot is already in iCloud. The older operation was not published over it."
        case .unavailable: "Staff synchronization could not be confirmed. Recover the original operation when connected."
        }
    }
}

/// Immutable identity only. Fresh authorization always comes from a new server
/// read; these persisted fields cannot grant access or mount an operational store.
struct StaffReplicaManifest: Codable, Equatable {
    let protocolVersion: Int
    let schema: String
    let coverage: [String]
    let operationID: UUID
    let membershipID: UUID
    let companyID: UUID
    let environment: String
    let replicaID: UUID
    let memberRevision: String
    let projectionPolicy: String
    let sourceSequence: Int
    let authorizationSequence: Int
    let payloadSHA256: String
    let payloadBytes: Int
    let recordCount: Int
    let createdAt: String

    static let maximumPayloadBytes = 16 * 1024 * 1024
    var authenticatedScope: Data {
        Data(["gunnaire-staff-cloud-seal-v1", companyID.uuidString.lowercased(), environment, replicaID.uuidString.lowercased(),
              membershipID.uuidString.lowercased(), memberRevision, projectionPolicy, operationID.uuidString.lowercased(),
              String(sourceSequence), String(authorizationSequence), payloadSHA256].joined(separator: "\n").utf8)
    }
    func validate(plan: CloudKitStaffSharePlan, workspace: CompanyWorkspaceIdentity, now: Date = Date()) throws {
        try plan.validate(workspace: workspace, now: now)
        guard plan.state == "accepted", plan.businessAccessEligible, !plan.reviewRequired, !plan.cloudKitRevocationRequired,
              protocolVersion == 1, schema == StaffReplicaCoreSource.schemaVersion, coverage == StaffReplicaCoreSource.recordKinds,
              membershipID == plan.id, companyID == plan.companyID, environment == plan.environment,
              replicaID == plan.replicaID, memberRevision == plan.memberRevision, projectionPolicy == plan.projectionPolicy,
              (1...2_147_483_647).contains(sourceSequence), (1...sourceSequence).contains(authorizationSequence),
              JobBillingAssignmentSnapshot.validConnectionRevision(payloadSHA256),
              (1...Self.maximumPayloadBytes).contains(payloadBytes), (0...20_000).contains(recordCount),
              let date = SharedTimeError.date(createdAt), let approved = SharedTimeError.date(plan.createdAt),
              date >= approved, date <= now.addingTimeInterval(300) else { throw StaffReplicaDeliveryError.invalid }
    }
    static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
}

struct StaffReplicaProjectionReceipt: Decodable {
    let manifest: StaffReplicaManifest
    let currentSequence: Int
    let isCurrent: Bool
    let currentAuthorizationSequence: Int
    let authorizationCurrent: Bool
    let localCloudKitProofRequired: Bool
    let operationalWorkspaceReady: Bool
    let payloadBase64: String?
    let sealVersion: Int?
    let keyBase64: String?
    let sealedBase64: String?
    enum CodingKeys: String, CodingKey {
        case currentSequence, isCurrent, currentAuthorizationSequence, authorizationCurrent
        case localCloudKitProofRequired, operationalWorkspaceReady, payloadBase64, sealVersion, keyBase64, sealedBase64
    }
    init(from decoder: Decoder) throws {
        manifest = try StaffReplicaManifest(from: decoder)
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        currentSequence = try fields.decode(Int.self, forKey: .currentSequence)
        isCurrent = try fields.decode(Bool.self, forKey: .isCurrent)
        currentAuthorizationSequence = try fields.decode(Int.self, forKey: .currentAuthorizationSequence)
        authorizationCurrent = try fields.decode(Bool.self, forKey: .authorizationCurrent)
        localCloudKitProofRequired = try fields.decode(Bool.self, forKey: .localCloudKitProofRequired)
        operationalWorkspaceReady = try fields.decode(Bool.self, forKey: .operationalWorkspaceReady)
        payloadBase64 = try fields.decodeIfPresent(String.self, forKey: .payloadBase64)
        sealVersion = try fields.decodeIfPresent(Int.self, forKey: .sealVersion)
        keyBase64 = try fields.decodeIfPresent(String.self, forKey: .keyBase64)
        sealedBase64 = try fields.decodeIfPresent(String.self, forKey: .sealedBase64)
    }
    func validate(plan: CloudKitStaffSharePlan, workspace: CompanyWorkspaceIdentity, now: Date = Date()) throws {
        try validateMetadata(plan: plan, workspace: workspace, now: now)
        guard authorizationCurrent else { throw StaffReplicaDeliveryError.changed }
    }
    /// Allows inspecting an immutable superseded preparation receipt, never
    /// downloading its key, publishing it, or authorizing an operational store.
    func validateMetadata(plan: CloudKitStaffSharePlan, workspace: CompanyWorkspaceIdentity, now: Date = Date()) throws {
        try manifest.validate(plan: plan, workspace: workspace, now: now)
        guard (manifest.sourceSequence...2_147_483_647).contains(currentSequence),
              isCurrent == (manifest.sourceSequence == currentSequence),
              (manifest.authorizationSequence...currentSequence).contains(currentAuthorizationSequence),
              authorizationCurrent == (manifest.authorizationSequence == currentAuthorizationSequence),
              localCloudKitProofRequired, !operationalWorkspaceReady else { throw StaffReplicaDeliveryError.invalid }
    }
    func ownerPayload() throws -> StaffReplicaVerifiedPayload {
        guard let payloadBase64, payloadBase64.utf8.count <= ((StaffReplicaManifest.maximumPayloadBytes + 2) / 3) * 4,
              let bytes = Data(base64Encoded: payloadBase64), bytes.base64EncodedString() == payloadBase64 else {
            throw StaffReplicaDeliveryError.invalid
        }
        return try .init(manifest: manifest, bytes: bytes)
    }
    func decryptionKey() throws -> Data {
        guard sealVersion == 1, payloadBase64 == nil, let keyBase64, keyBase64.utf8.count == 44,
              let key = Data(base64Encoded: keyBase64), key.count == 32, key.base64EncodedString() == keyBase64 else { throw StaffReplicaDeliveryError.invalid }
        return key
    }
    func ownerSealedPayload() throws -> StaffReplicaSealedPayload {
        guard let sealedBase64, sealedBase64.utf8.count <= ((StaffReplicaManifest.maximumPayloadBytes + 30) / 3) * 4,
              let bytes = Data(base64Encoded: sealedBase64), bytes.base64EncodedString() == sealedBase64 else { throw StaffReplicaDeliveryError.invalid }
        return try .init(manifest: manifest, bytes: bytes, key: decryptionKey())
    }
}

/// The per-snapshot key is ephemeral: never a CKRecord field, URL, log, or
/// persisted publisher receipt. It is released again only by current authority.
struct StaffReplicaSealedPayload {
    let manifest: StaffReplicaManifest
    let bytes: Data
    let key: Data
    let opened: StaffReplicaVerifiedPayload
    init(manifest: StaffReplicaManifest, bytes: Data, key: Data) throws {
        guard (1...StaffReplicaManifest.maximumPayloadBytes).contains(manifest.payloadBytes),
              bytes.count == manifest.payloadBytes + 28, key.count == 32 else { throw StaffReplicaDeliveryError.invalid }
        do {
            let raw = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: SymmetricKey(data: key), authenticating: manifest.authenticatedScope)
            opened = try .init(manifest: manifest, bytes: raw)
        } catch { throw StaffReplicaDeliveryError.invalid }
        self.manifest = manifest; self.bytes = bytes; self.key = key
    }
}

/// Verified transport envelope, not validated SwiftData import authority.
/// Keep the exact server bytes; re-encoding may change their content hash.
struct StaffReplicaVerifiedPayload {
    let manifest: StaffReplicaManifest
    let bytes: Data
    init(manifest: StaffReplicaManifest, bytes: Data) throws {
        guard bytes.count == manifest.payloadBytes, bytes.count <= StaffReplicaManifest.maximumPayloadBytes,
              StaffReplicaManifest.hash(bytes) == manifest.payloadSHA256,
              let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(root.keys) == Set("protocolVersion schema coverage completeForSchema companyID environment replicaID membershipID memberRevision projectionPolicy sourceSequence authorizationSequence operationID records".split(separator: " ").map(String.init)),
              let records = root["records"] as? [[String: Any]], records.count == manifest.recordCount else { throw StaffReplicaDeliveryError.invalid }
        let headers: [String: Any] = ["protocolVersion": manifest.protocolVersion, "schema": manifest.schema, "coverage": manifest.coverage,
            "completeForSchema": true, "companyID": manifest.companyID.uuidString.lowercased(), "environment": manifest.environment,
            "replicaID": manifest.replicaID.uuidString.lowercased(), "membershipID": manifest.membershipID.uuidString.lowercased(),
            "memberRevision": manifest.memberRevision, "projectionPolicy": manifest.projectionPolicy,
            "sourceSequence": manifest.sourceSequence, "authorizationSequence": manifest.authorizationSequence,
            "operationID": manifest.operationID.uuidString.lowercased()]
        // JSON canonical data preserves the distinction between 1 and true.
        let actual = root.filter { $0.key != "records" }
        guard try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys]) == JSONSerialization.data(withJSONObject: headers, options: [.sortedKeys]) else {
            throw StaffReplicaDeliveryError.invalid
        }
        var prior = ""
        for record in records {
            guard Set(record.keys) == ["kind", "id", "revision", "fields"], let kind = record["kind"] as? String,
                  manifest.coverage.contains(kind), let id = record["id"] as? String, CloudKitStaffSetupPolicy.canonicalID(id),
                  let revision = record["revision"] as? NSNumber, String(cString: revision.objCType) != "c",
                  revision.doubleValue >= 1, revision.doubleValue <= 2_147_483_647, revision.doubleValue.rounded() == revision.doubleValue,
                  record["fields"] is [String: Any], kind + ":" + id > prior else { throw StaffReplicaDeliveryError.invalid }
            prior = kind + ":" + id
        }
        self.manifest = manifest; self.bytes = bytes
    }
}

enum StaffReplicaDeliveryPolicy {
    static func path(plan: CloudKitStaffSharePlan, operation: UUID, payload: Bool = false, key: Bool = false) -> String {
        var parts = URLComponents()
        parts.path = CloudKitStaffSetupPolicy.base + "/\(plan.id.uuidString.lowercased())/projections/\(operation.uuidString.lowercased())" + (payload ? "/cloud-payload" : (key ? "/cloud-key" : ""))
        parts.queryItems = [.init(name: "companyID", value: plan.companyID.uuidString.lowercased()), .init(name: "environment", value: plan.environment)]
        return parts.string ?? ""
    }
    /// Only receipt metadata is readable before the private owner store gate.
    /// No source, projection preparation or payload download exception for staff.
    static func allows(path: String) -> Bool {
        guard path.utf8.count <= 4096, let parts = URLComponents(string: path), parts.scheme == nil, parts.host == nil,
              parts.fragment == nil, parts.percentEncodedPath == parts.path,
              let query = parts.queryItems, query.count == 2, Set(query.map(\.name)) == ["companyID", "environment"] else { return false }
        let segments = parts.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.count == 7 || segments.count == 8, Array(segments.prefix(4)) == ["", "api", "workspace", "staff-shares"],
              CloudKitStaffSetupPolicy.canonicalID(segments[4]), segments[5] == "projections",
              CloudKitStaffSetupPolicy.canonicalID(segments[6]), segments.count == 7 || ["cloud-payload", "cloud-key"].contains(segments[7]) else { return false }
        return query.first { $0.name == "companyID" }?.value.map(CloudKitStaffSetupPolicy.canonicalID) == true &&
            ["development", "production"].contains(query.first { $0.name == "environment" }?.value ?? "")
    }
    static func safe(_ error: Error) -> StaffReplicaDeliveryError {
        if let error = error as? StaffReplicaDeliveryError { return error }
        if error is DecodingError { return .invalid }
        if case GunnAireBackendError.server(let status, _) = error {
            if status == 401 || status == 403 { return .access }
            if status == 409 { return .changed }
            if status == 404 { return .pending }
        }
        return .unavailable
    }
}
