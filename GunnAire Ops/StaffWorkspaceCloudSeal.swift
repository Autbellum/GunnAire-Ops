import Foundation
import CryptoKit

/// HTTP seal material for full-workspace CloudKit delivery. Keys never enter
/// CK records or audit metadata. Owner prepares/reads via `/content/cloud-seal`;
/// staff (and Admin) release an already-prepared key via GET `/content/cloud-key`.
struct StaffWorkspaceCloudSealResponse: Codable, Equatable {
    static let schema = "staff-workspace-cloud-seal-v1"
    let schema: String
    let content: StaffWorkspaceContentReceipt
    let sealedSHA256: String
    let sealedBytes: Int
    let keyBase64: String
    let nonceBase64: String

    func validate(against content: StaffWorkspaceContentReceipt) throws {
        guard (1...StaffWorkspaceContentReceipt.maximumBytes).contains(content.payloadBytes),
              schema == Self.schema, self.content == content,
              self.content.selectionID == content.selectionID,
              self.content.companyID == content.companyID,
              self.content.environment == content.environment,
              self.content.replicaID == content.replicaID,
              self.content.membershipID == content.membershipID,
              self.content.memberRevision == content.memberRevision,
              self.content.memberRole == content.memberRole,
              self.content.shareRevision == content.shareRevision,
              self.content.projectionPolicy == content.projectionPolicy,
              self.content.sourceSequence == content.sourceSequence,
              self.content.selectionSHA256 == content.selectionSHA256,
              self.content.contentSHA256 == content.contentSHA256,
              self.content.payloadBytes == content.payloadBytes,
              sealedBytes == content.payloadBytes + 28,
              JobBillingAssignmentSnapshot.validConnectionRevision(sealedSHA256) else {
            throw StaffReplicaDeliveryError.invalid
        }
        _ = try Self.material(keyBase64, size: 32)
        _ = try Self.material(nonceBase64, size: 12)
    }

    /// Exact Python `cloud.aad` wire: literal prefix then receipt fields as `str(...)`.
    static func authenticatedScope(
        companyID: String, environment: String, replicaID: String, membershipID: String,
        memberRevision: String, memberRole: String, shareRevision: Int, projectionPolicy: String,
        selectionID: String, sourceSequence: Int, selectionSHA256: String, contentSHA256: String
    ) -> Data {
        let lines = [
            "gunnaire-full-workspace-cloud-seal-v1",
            companyID, environment, replicaID, membershipID, memberRevision, memberRole,
            String(shareRevision), projectionPolicy, selectionID,
            String(sourceSequence), selectionSHA256, contentSHA256,
        ]
        return Data(lines.joined(separator: "\n").utf8)
    }

    static func authenticatedScope(_ content: StaffWorkspaceContentReceipt) -> Data {
        authenticatedScope(companyID: content.companyID, environment: content.environment, replicaID: content.replicaID,
                           membershipID: content.membershipID, memberRevision: content.memberRevision,
                           memberRole: content.memberRole, shareRevision: content.shareRevision,
                           projectionPolicy: content.projectionPolicy, selectionID: content.selectionID,
                           sourceSequence: content.sourceSequence, selectionSHA256: content.selectionSHA256,
                           contentSHA256: content.contentSHA256)
    }

    static func material(_ encoded: String, size: Int) throws -> Data {
        guard encoded.utf8.count == 4 * ((size + 2) / 3),
              let value = Data(base64Encoded: encoded), value.count == size,
              value.base64EncodedString() == encoded else { throw StaffReplicaDeliveryError.invalid }
        return value
    }
}

/// Local AES-GCM package matching Python `nonce || AESGCM.encrypt(...)`.
/// Combined length is always raw + 28 (12-byte nonce + 16-byte tag).
struct StaffWorkspaceCloudSealedPackage {
    let manifest: StaffWorkspaceCloudSealManifest
    let bytes: Data
    let key: Data
    let opened: Data

    init(content: StaffWorkspaceContentReceipt, raw: Data, response: StaffWorkspaceCloudSealResponse) throws {
        try response.validate(against: content)
        guard raw.count == content.payloadBytes,
              StaffReplicaManifest.hash(raw) == content.contentSHA256 else { throw StaffReplicaDeliveryError.invalid }
        let key = try StaffWorkspaceCloudSealResponse.material(response.keyBase64, size: 32)
        let nonce = try StaffWorkspaceCloudSealResponse.material(response.nonceBase64, size: 12)
        let aad = StaffWorkspaceCloudSealResponse.authenticatedScope(content)
        let sealed: Data
        do {
            let box = try AES.GCM.seal(raw, using: SymmetricKey(data: key),
                                       nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
            guard let combined = box.combined, combined.count == raw.count + 28,
                  combined.prefix(12) == nonce else { throw StaffReplicaDeliveryError.invalid }
            sealed = combined
        } catch { throw StaffReplicaDeliveryError.invalid }
        guard StaffReplicaManifest.hash(sealed) == response.sealedSHA256,
              sealed.count == response.sealedBytes else { throw StaffReplicaDeliveryError.invalid }
        self.manifest = try .init(content: content, sealedSHA256: response.sealedSHA256, sealedBytes: response.sealedBytes)
        self.bytes = sealed; self.key = key; self.opened = raw
    }

    /// Open an already-authorized sealed package. Key arrives only via owner
    /// `/content/cloud-seal`, staff `/content/cloud-key`, or an explicit
    /// caller-supplied authorized buffer — never from CloudKit.
    init(manifest: StaffWorkspaceCloudSealManifest, bytes: Data, key: Data) throws {
        guard key.count == 32, bytes.count == manifest.sealedBytes,
              bytes.count == manifest.contentBytes + 28,
              StaffReplicaManifest.hash(bytes) == manifest.sealedSHA256 else { throw StaffReplicaDeliveryError.invalid }
        let raw: Data
        do {
            raw = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes),
                                   using: SymmetricKey(data: key), authenticating: manifest.authenticatedScope)
        } catch { throw StaffReplicaDeliveryError.invalid }
        guard raw.count == manifest.contentBytes,
              StaffReplicaManifest.hash(raw) == manifest.contentSHA256 else { throw StaffReplicaDeliveryError.invalid }
        self.manifest = manifest; self.bytes = bytes; self.key = key; self.opened = raw
    }
}

/// Non-secret CK/publish identity. Never includes key or nonce.
struct StaffWorkspaceCloudSealManifest: Codable, Equatable {
    static let schema = StaffWorkspaceCloudSealResponse.schema
    let schema: String
    let selectionID: String
    let companyID: String
    let environment: String
    let replicaID: String
    let membershipID: String
    let memberRevision: String
    let memberRole: String
    let shareRevision: Int
    let projectionPolicy: String
    let sourceSequence: Int
    let selectionSHA256: String
    let contentSHA256: String
    let sealedSHA256: String
    let sealedBytes: Int

    var contentBytes: Int { sealedBytes - 28 }
    var authenticatedScope: Data {
        StaffWorkspaceCloudSealResponse.authenticatedScope(
            companyID: companyID, environment: environment, replicaID: replicaID, membershipID: membershipID,
            memberRevision: memberRevision, memberRole: memberRole, shareRevision: shareRevision,
            projectionPolicy: projectionPolicy, selectionID: selectionID, sourceSequence: sourceSequence,
            selectionSHA256: selectionSHA256, contentSHA256: contentSHA256)
    }

    init(content: StaffWorkspaceContentReceipt, sealedSHA256: String, sealedBytes: Int) throws {
        guard (1...StaffWorkspaceContentReceipt.maximumBytes).contains(content.payloadBytes),
              sealedBytes == content.payloadBytes + 28,
              JobBillingAssignmentSnapshot.validConnectionRevision(sealedSHA256),
              JobBillingAssignmentSnapshot.validConnectionRevision(content.contentSHA256),
              JobBillingAssignmentSnapshot.validConnectionRevision(content.selectionSHA256) else {
            throw StaffReplicaDeliveryError.invalid
        }
        schema = Self.schema
        selectionID = content.selectionID; companyID = content.companyID; environment = content.environment
        replicaID = content.replicaID; membershipID = content.membershipID; memberRevision = content.memberRevision
        memberRole = content.memberRole; shareRevision = content.shareRevision; projectionPolicy = content.projectionPolicy
        sourceSequence = content.sourceSequence; selectionSHA256 = content.selectionSHA256
        contentSHA256 = content.contentSHA256; self.sealedSHA256 = sealedSHA256; self.sealedBytes = sealedBytes
    }

    func validate(plan: CloudKitStaffSharePlan, workspace: CompanyWorkspaceIdentity, now: Date) throws {
        try plan.validate(workspace: workspace, now: now)
        guard plan.state == "accepted", plan.businessAccessEligible, !plan.reviewRequired, !plan.cloudKitRevocationRequired,
              schema == Self.schema, CloudKitStaffSetupPolicy.canonicalID(selectionID),
              companyID == plan.companyID.uuidString.lowercased(), environment == plan.environment,
              replicaID == plan.replicaID.uuidString.lowercased(), membershipID == plan.id.uuidString.lowercased(),
              memberRevision == plan.memberRevision, memberRole == plan.memberRole,
              shareRevision == plan.revision, projectionPolicy == plan.projectionPolicy,
              (1...2_147_483_647).contains(sourceSequence),
              JobBillingAssignmentSnapshot.validConnectionRevision(selectionSHA256),
              JobBillingAssignmentSnapshot.validConnectionRevision(contentSHA256),
              JobBillingAssignmentSnapshot.validConnectionRevision(sealedSHA256),
              (29...StaffWorkspaceContentReceipt.maximumBytes + 28).contains(sealedBytes) else {
            throw StaffReplicaDeliveryError.invalid
        }
    }
}
