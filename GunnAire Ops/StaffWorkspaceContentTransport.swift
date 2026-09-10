import Foundation

/// Transport integrity only. These bytes are not owner models, an accepted
/// staff store, a lease, a financial command, or proof of CloudKit receipt.
struct StaffWorkspaceContentReceipt: Codable, Equatable {
    static let maximumBytes = 64 * 1024 * 1024
    static let chunkSize = 1024 * 1024
    let schema: String
    let contentSchema: String
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
    let sourceSchema: String
    let sourceSchemaDigest: String
    let fieldPolicy: String
    let discriminatorSchema: String
    let structuredSchema: String
    let billingSchema: String
    let coverage: [String]
    let recordCount: Int
    let payloadBytes: Int
    let chunkBytes: Int
    let currentSourceSequence: Int
    let sourceCurrent: Bool
    let operationalWorkspaceReady: Bool
    let fieldProjectionRequired: Bool
    let localCloudKitProofRequired: Bool

    func validate(plan: CloudKitStaffSharePlan, workspace: CompanyWorkspaceIdentity,
                  selection: String, selectionDigest: String, sequence: Int, now: Date) throws {
        try plan.validate(workspace: workspace, now: now)
        guard plan.state == "accepted", plan.businessAccessEligible, !plan.reviewRequired, !plan.cloudKitRevocationRequired,
              schema == "staff-workspace-delivery-v1", contentSchema == "staff-workspace-content-v1",
              sourceSchema == StaffWorkspacePublicationContract.schema,
              sourceSchemaDigest == StaffWorkspacePublicationContract.schemaDigest,
              fieldPolicy == "staff-operational-fields-v1", discriminatorSchema == "staff-workspace-discriminators-v1",
              structuredSchema == "staff-operational-evidence-v1", billingSchema == "staff-billing-view-v1",
              CloudKitStaffSetupPolicy.canonicalID(selectionID), selectionID == selection,
              selectionSHA256 == selectionDigest, JobBillingAssignmentSnapshot.validConnectionRevision(selectionSHA256),
              JobBillingAssignmentSnapshot.validConnectionRevision(contentSHA256),
              companyID == plan.companyID.uuidString.lowercased(), environment == plan.environment,
              replicaID == plan.replicaID.uuidString.lowercased(), membershipID == plan.id.uuidString.lowercased(),
              memberRevision == plan.memberRevision, memberRole == plan.memberRole,
              shareRevision == plan.revision, projectionPolicy == plan.projectionPolicy,
              coverage == StaffWorkspacePublicationContract.kinds.sorted(),
              (1...2_147_483_647).contains(sourceSequence), sourceSequence == sequence,
              currentSourceSequence == sourceSequence, sourceCurrent,
              (0...20_000).contains(recordCount), (1...Self.maximumBytes).contains(payloadBytes),
              chunkBytes == Self.chunkSize, !operationalWorkspaceReady, !fieldProjectionRequired,
              localCloudKitProofRequired else { throw StaffReplicaDeliveryError.invalid }
    }
}

struct StaffWorkspaceContentChunk: Codable, Equatable {
    let receipt: StaffWorkspaceContentReceipt
    let offset: Int
    let nextOffset: Int?
    let chunkSHA256: String
    let payloadBase64: String
    enum CodingKeys: String, CodingKey { case offset, nextOffset, chunkSHA256, payloadBase64 }
    init(receipt: StaffWorkspaceContentReceipt, offset: Int, nextOffset: Int?, chunkSHA256: String, payloadBase64: String) {
        self.receipt = receipt; self.offset = offset; self.nextOffset = nextOffset
        self.chunkSHA256 = chunkSHA256; self.payloadBase64 = payloadBase64
    }
    init(from decoder: Decoder) throws {
        receipt = try StaffWorkspaceContentReceipt(from: decoder)
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        offset = try fields.decode(Int.self, forKey: .offset)
        // Missing is not the same as the explicitly terminal null cursor.
        guard fields.contains(.nextOffset) else { throw StaffReplicaDeliveryError.invalid }
        nextOffset = try fields.decodeIfPresent(Int.self, forKey: .nextOffset)
        chunkSHA256 = try fields.decode(String.self, forKey: .chunkSHA256)
        payloadBase64 = try fields.decode(String.self, forKey: .payloadBase64)
    }
    func encode(to encoder: Encoder) throws {
        try receipt.encode(to: encoder)
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(offset, forKey: .offset); try fields.encode(nextOffset, forKey: .nextOffset)
        try fields.encode(chunkSHA256, forKey: .chunkSHA256); try fields.encode(payloadBase64, forKey: .payloadBase64)
    }
    static func decode(_ bytes: Data) throws -> Self {
        try StaffWorkspacePublicationContract.decode(Self.self, from: bytes, maximum: 2 * 1024 * 1024)
    }
}

/// All-or-nothing assembly. Failed/mixed/reordered chunks leave accumulated
/// bytes unchanged. A caller must recheck live authority around network awaits;
/// this immutable receipt intentionally cannot grant or extend authorization.
struct StaffWorkspaceContentAssembly {
    let receipt: StaffWorkspaceContentReceipt
    private(set) var bytes = Data()
    var nextOffset: Int? { bytes.count < receipt.payloadBytes ? bytes.count : nil }
    init(receipt: StaffWorkspaceContentReceipt, plan: CloudKitStaffSharePlan, workspace: CompanyWorkspaceIdentity,
         selection: String, selectionDigest: String, sequence: Int, now: Date) throws {
        try receipt.validate(plan: plan, workspace: workspace, selection: selection,
                             selectionDigest: selectionDigest, sequence: sequence, now: now)
        self.receipt = receipt
    }
    mutating func append(_ chunk: StaffWorkspaceContentChunk) throws {
        guard chunk.receipt == receipt, chunk.offset == bytes.count, let offset = nextOffset,
              chunk.payloadBase64.count <= 4 * ((receipt.chunkBytes + 2) / 3),
              let part = Data(base64Encoded: chunk.payloadBase64), !part.isEmpty,
              part.base64EncodedString() == chunk.payloadBase64,
              part.count == min(receipt.chunkBytes, receipt.payloadBytes - offset),
              chunk.chunkSHA256 == StaffReplicaManifest.hash(part) else { throw StaffReplicaDeliveryError.invalid }
        let end = offset + part.count
        guard chunk.nextOffset == (end < receipt.payloadBytes ? end : nil) else { throw StaffReplicaDeliveryError.invalid }
        // Verify the completed digest before appending the last chunk. A bad
        // final reply cannot poison earlier verified progress.
        if end == receipt.payloadBytes {
            guard StaffReplicaManifest.hash(bytes + part) == receipt.contentSHA256 else { throw StaffReplicaDeliveryError.invalid }
        }
        bytes.append(part)
    }
    func completedBytes() throws -> Data {
        guard bytes.count == receipt.payloadBytes, StaffReplicaManifest.hash(bytes) == receipt.contentSHA256 else {
            throw StaffReplicaDeliveryError.pending
        }
        return bytes
    }
}
