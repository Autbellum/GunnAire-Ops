import Foundation

struct StaffOwnerFieldHandoffRequest: Codable, Equatable {
    static let schema = "staff-owner-field-handoff-v1"
    let schema, companyID, environment, replicaID, commandID, operationID, ownerStoreID, claimOperationID: String
    let expectedRevision: Int
    let expectedValue: StaffWorkspaceValue
    let writeFence: String
    init(edit: StaffOwnerFieldEdit, scope: StaffReplicaSourceScope, operation: UUID) throws {
        guard let current = edit.current, let claim = edit.application else { throw StaffOwnerFieldEditError.conflict }
        schema = Self.schema; companyID = edit.request.companyID; environment = edit.request.environment
        replicaID = edit.request.replicaID; commandID = edit.id; operationID = operation.uuidString.lowercased()
        ownerStoreID = scope.storeUUID.lowercased(); claimOperationID = claim.operationID
        expectedRevision = current.revision; expectedValue = current.value; writeFence = "before-save-v1"
    }
    func validate(edit: StaffOwnerFieldEdit, scope: StaffReplicaSourceScope) throws {
        try edit.validate(scope)
        guard schema == Self.schema, companyID == edit.request.companyID, environment == edit.request.environment,
              replicaID == edit.request.replicaID, commandID == edit.id,
              CloudKitStaffSetupPolicy.canonicalID(operationID), operationID != claimOperationID,
              ownerStoreID == scope.storeUUID.lowercased(), writeFence == "before-save-v1",
              let claim = edit.application, claim.state == "prepared", edit.resolution == nil,
              claim.ownerEmail == scope.actorEmail, claim.ownerStoreID == ownerStoreID, claim.operationID == claimOperationID,
              let current = edit.current, !current.deleted, expectedRevision == current.revision,
              expectedRevision >= claim.expectedRevision, expectedValue == current.value,
              expectedValue == claim.expectedValue, expectedValue != edit.request.value else { throw StaffOwnerFieldEditError.conflict }
    }
}

/// Immutable local barrier written BEFORE the release request. Legacy journals
/// lack before-save evidence and cannot be upgraded by guessing that no save ran.
struct StaffOwnerFieldHandoffFence: Codable, Equatable {
    let version: Int
    let scope: StaffReplicaSourceScope
    let edit: StaffOwnerFieldEdit
    let pending: StaffOwnerFieldEditPending
    let request: StaffOwnerFieldHandoffRequest
    static func key(_ scope: StaffReplicaSourceScope, id: String) -> String { "owner-field-handoff-fence-v1\n" + scope.key + "\n" + id }
    func validate(_ scope: StaffReplicaSourceScope) throws {
        guard version == 1, self.scope == scope, pending.writeBoundaryVersion == 1, pending.phase == "prepared",
              pending.edit.request == edit.request, pending.edit.receipt == edit.receipt, pending.edit.baseValue == edit.baseValue,
              pending.edit.shareID == edit.shareID, let claim = edit.application else { throw StaffReplicaSourceSyncError.storage }
        try request.validate(edit: edit, scope: scope)
        try pending.request.validate(edit: pending.edit, scope: scope)
        try claim.validate(pending.request, scope: scope)
        if let originalClaim = pending.application { guard originalClaim == claim else { throw StaffReplicaSourceSyncError.storage } }
    }
    static func load(_ scope: StaffReplicaSourceScope, id: String, store: SharedTimeLocalStore) throws -> Self? {
        guard let bytes = try store.read(key(scope, id: id)) else { return nil }
        let value = try StaffOwnerFieldEditWire.decode(Self.self, from: bytes, maximum: 64 * 1024 * 1024)
        try value.validate(scope)
        guard value.edit.id == id else { throw StaffReplicaSourceSyncError.storage }
        return value
    }
    static func checkWrite(_ scope: StaffReplicaSourceScope, id: String, store: SharedTimeLocalStore) throws {
        guard try load(scope, id: id, store: store) == nil else { throw StaffOwnerFieldEditError.released }
    }
}

struct StaffOwnerFieldHandoffReceipt: Codable, Equatable {
    let schema: String
    let request: StaffOwnerFieldHandoffRequest
    let ownerEmail, releasedAt, outcome: String
    func validate(_ fence: StaffOwnerFieldHandoffFence) throws {
        try fence.validate(fence.scope)
        guard schema == StaffOwnerFieldHandoffRequest.schema, request == fence.request,
              ownerEmail == fence.scope.actorEmail, outcome == "released",
              let released = StaffOwnerFieldEditApplication.instant(releasedAt),
              let prepared = fence.edit.application.flatMap({ StaffOwnerFieldEditApplication.instant($0.preparedAt) }),
              released >= prepared else { throw StaffReplicaSourceSyncError.invalid }
    }
}
