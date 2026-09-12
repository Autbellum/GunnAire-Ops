import Foundation

/// Durable staff operational mount after verified cloud-seal open.
///
/// Stores the original opened full-workspace bytes under a separate encrypted
/// key from the small lease marker. This is the staff operational durable
/// store for the receive path — not a ModelContext import and not authority to
/// invent SwiftData defaults for restricted or unavailable fields.
struct StaffWorkspaceOperationalMount: Codable, Equatable {
    static let schema = "staff-workspace-operational-mount-v1"
    let schema: String
    let scope: CloudKitStaffSetupScope
    let planID: UUID
    let selectionID: String
    let sourceSequence: Int
    let contentSHA256: String
    let sealedSHA256: String
    let contentBytes: Int
    let state: String
    // Nil reads the original v1 payload location. Successor snapshots use an
    // immutable per-selection key, so writing bytes cannot corrupt the old head.
    var storageSelectionID: String? = nil

    init(scope: CloudKitStaffSetupScope, planID: UUID, manifest: StaffWorkspaceCloudSealManifest) throws {
        guard CloudKitStaffSetupPolicy.canonicalID(manifest.selectionID),
              (1...2_147_483_647).contains(manifest.sourceSequence),
              JobBillingAssignmentSnapshot.validConnectionRevision(manifest.contentSHA256),
              JobBillingAssignmentSnapshot.validConnectionRevision(manifest.sealedSHA256),
              (1...StaffWorkspaceContentReceipt.maximumBytes).contains(manifest.contentBytes) else {
            throw StaffReplicaDeliveryError.invalid
        }
        schema = Self.schema
        self.scope = scope
        self.planID = planID
        selectionID = manifest.selectionID
        sourceSequence = manifest.sourceSequence
        contentSHA256 = manifest.contentSHA256
        sealedSHA256 = manifest.sealedSHA256
        contentBytes = manifest.contentBytes
        state = "mounted"
    }

    func validate(scope: CloudKitStaffSetupScope, plan: UUID, manifest: StaffWorkspaceCloudSealManifest) throws {
        guard schema == Self.schema, state == "mounted", self.scope == scope, planID == plan,
              selectionID == manifest.selectionID, sourceSequence == manifest.sourceSequence,
              contentSHA256 == manifest.contentSHA256, sealedSHA256 == manifest.sealedSHA256,
              contentBytes == manifest.contentBytes else {
            throw StaffReplicaDeliveryError.storage
        }
    }
}

/// Install/load helpers for the operational mount envelope.
/// Payload bytes are written under their own store key (raw, not JSON/base64)
/// before metadata, and the lease marker is written last.
enum StaffWorkspaceOperationalMountStore {
    static func metaKey(_ scope: CloudKitStaffSetupScope, _ plan: UUID) -> String {
        "full-staff-content-mount-v1\n" + scope.key + "\n" + plan.uuidString.lowercased()
    }

    static func payloadKey(_ scope: CloudKitStaffSetupScope, _ plan: UUID, selection: String? = nil) -> String {
        metaKey(scope, plan) + "\npayload" + (selection.map { "-" + $0 } ?? "")
    }

    static func verifyOpened(_ opened: Data, manifest: StaffWorkspaceCloudSealManifest) throws {
        guard opened.count == manifest.contentBytes,
              opened.count <= StaffWorkspaceContentReceipt.maximumBytes,
              opened.count <= 64 * 1024 * 1024 - 64,
              StaffReplicaManifest.hash(opened) == manifest.contentSHA256 else {
            throw StaffReplicaDeliveryError.changed
        }
        // Hash/size only here. Semantic content acceptance remains a separate gate
        // and must not invent SwiftData defaults from this transport envelope.
    }

    /// A bounded freshness hint, never proof that payload bytes still exist or
    /// are valid. All content consumers must continue through full `load`.
    static func peekMetadata(store: SharedTimeLocalStore, scope: CloudKitStaffSetupScope,
                             plan: UUID) throws -> StaffWorkspaceOperationalMount? {
        guard let bytes = try store.read(metaKey(scope, plan)) else { return nil }
        let metadata = try StaffWorkspacePublicationContract.decode(StaffWorkspaceOperationalMount.self, from: bytes, maximum: 8192)
        guard metadata.schema == StaffWorkspaceOperationalMount.schema, metadata.state == "mounted",
              metadata.scope == scope, metadata.planID == plan,
              CloudKitStaffSetupPolicy.canonicalID(metadata.selectionID),
              (1...2_147_483_647).contains(metadata.sourceSequence),
              JobBillingAssignmentSnapshot.validConnectionRevision(metadata.contentSHA256),
              JobBillingAssignmentSnapshot.validConnectionRevision(metadata.sealedSHA256),
              (1...StaffWorkspaceContentReceipt.maximumBytes).contains(metadata.contentBytes),
              metadata.storageSelectionID == nil || metadata.storageSelectionID == metadata.selectionID else {
            throw StaffReplicaDeliveryError.storage
        }
        return metadata
    }

    static func load(store: SharedTimeLocalStore, scope: CloudKitStaffSetupScope, plan: UUID) throws -> (StaffWorkspaceOperationalMount, Data)? {
        do {
            let metadata = try peekMetadata(store: store, scope: scope, plan: plan)
            let payload = try store.read(payloadKey(scope, plan, selection: metadata?.storageSelectionID))
            switch (metadata, payload) {
            case (nil, nil):
                return nil
            case (nil, .some):
                // Interrupted after payload write — retain bytes, do not treat as mounted.
                return nil
            case (.some, nil):
                throw StaffReplicaDeliveryError.storage
            case let (.some(mount), .some(payload)):
                guard payload.count == mount.contentBytes,
                      StaffReplicaManifest.hash(payload) == mount.contentSHA256 else {
                    throw StaffReplicaDeliveryError.storage
                }
                return (mount, payload)
            }
        } catch let error as StaffReplicaDeliveryError {
            throw error
        } catch {
            throw StaffReplicaDeliveryError.storage
        }
    }

    /// Install verified opened bytes. Never replaces a newer retained snapshot,
    /// never deletes a corrupt prior mount, and never regenerates encryption keys
    /// (SharedTimeLocalStore refuses create when sealed journals already exist).
    @discardableResult
    static func install(opened: Data, manifest: StaffWorkspaceCloudSealManifest,
                        store: SharedTimeLocalStore, scope: CloudKitStaffSetupScope, plan: UUID,
                        check: () throws -> Void) throws -> StaffWorkspaceOperationalMount {
        try check()
        try verifyOpened(opened, manifest: manifest)
        var next = try StaffWorkspaceOperationalMount(scope: scope, planID: plan, manifest: manifest)
        if let (existing, existingPayload) = try load(store: store, scope: scope, plan: plan) {
            if existing.sourceSequence > next.sourceSequence {
                throw StaffReplicaDeliveryError.superseded
            }
            if existing.sourceSequence == next.sourceSequence {
                guard existing.selectionID == next.selectionID,
                      existing.contentSHA256 == next.contentSHA256,
                      existing.sealedSHA256 == next.sealedSHA256,
                      existingPayload == opened else {
                    throw StaffReplicaDeliveryError.changed
                }
                return existing // Exact remount / lost lease-marker recovery.
            }
            // Strictly newer sourceSequence may replace the retained mount.
            next.storageSelectionID = next.selectionID
        }
        try check()
        // Payload durable before metadata pointer.
        let destination = payloadKey(scope, plan, selection: next.storageSelectionID)
        if let original = try store.read(destination) {
            guard original == opened else { throw StaffReplicaDeliveryError.storage }
        } else { try store.write(destination, opened) }
        try check()
        let encoded = try StaffWorkspacePublicationContract.encode(next)
        guard encoded.count <= 8192 else { throw StaffReplicaDeliveryError.storage }
        try store.write(metaKey(scope, plan), encoded)
        try check()
        guard let confirmed = try load(store: store, scope: scope, plan: plan),
              confirmed.0 == next, confirmed.1 == opened else {
            throw StaffReplicaDeliveryError.storage
        }
        return next
    }
}
