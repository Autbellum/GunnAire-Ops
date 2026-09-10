import Foundation

struct StaffOwnerFieldEditKeepRequest: Codable, Equatable {
    static let schema = "staff-owner-field-resolution-v1"
    let schema, companyID, environment, replicaID, commandID, operationID, ownerStoreID, claimOperationID: String
    let expectedRevision: Int
    let expectedValue: StaffWorkspaceValue
    init(edit: StaffOwnerFieldEdit, scope: StaffReplicaSourceScope, operation: UUID) throws {
        guard let current = edit.current, !current.deleted, edit.resolution == nil,
              edit.application?.state != "published" else { throw StaffOwnerFieldEditError.conflict }
        if let claim = edit.application {
            guard claim.ownerEmail == scope.actorEmail, claim.ownerStoreID == scope.storeUUID.lowercased() else { throw StaffOwnerFieldEditError.otherDevice }
        }
        schema = Self.schema; companyID = edit.request.companyID; environment = edit.request.environment
        replicaID = edit.request.replicaID; commandID = edit.id; operationID = operation.uuidString.lowercased()
        ownerStoreID = scope.storeUUID.lowercased(); claimOperationID = edit.application?.operationID ?? ""
        expectedRevision = current.revision; expectedValue = current.value
    }
    func validate(_ scope: StaffReplicaSourceScope, edit: StaffOwnerFieldEdit) throws {
        try edit.validate(scope)
        guard schema == Self.schema, commandID == edit.id, companyID == edit.request.companyID,
              environment == edit.request.environment, replicaID == edit.request.replicaID,
              ownerStoreID == scope.storeUUID.lowercased(), CloudKitStaffSetupPolicy.canonicalID(operationID),
              claimOperationID == (edit.application?.operationID ?? ""), edit.application?.state != "published",
              (1..<2_147_483_647).contains(expectedRevision),
              let field = StaffWorkspaceModelCatalog.all.first(where: { $0.kind == edit.request.recordKind })?.fieldSchema[edit.request.fieldName]
        else { throw StaffReplicaSourceSyncError.invalid }
        try field.validateScalar(expectedValue)
        if let resolution = edit.resolution {
            guard resolution.request == self, resolution.ownerEmail == scope.actorEmail else { throw StaffReplicaSourceSyncError.invalid }
        }
        if let claim = edit.application {
            guard claim.ownerEmail == scope.actorEmail, claim.ownerStoreID == ownerStoreID else { throw StaffOwnerFieldEditError.otherDevice }
        }
    }
}

struct StaffOwnerFieldEditResolution: Codable, Equatable {
    let schema: String
    let request: StaffOwnerFieldEditKeepRequest
    let ownerEmail, resolvedAt, outcome: String
    func validate(edit: StaffOwnerFieldEdit, scope: StaffReplicaSourceScope) throws {
        guard schema == StaffOwnerFieldEditKeepRequest.schema, request.schema == schema, outcome == "keptOffice",
              request.commandID == edit.id, request.companyID == edit.request.companyID,
              request.environment == edit.request.environment, request.replicaID == edit.request.replicaID,
              request.companyID == scope.binding.companyID.uuidString.lowercased(), request.environment == scope.binding.environment,
              request.replicaID == scope.binding.replicaID.uuidString.lowercased(),
              CloudKitStaffSetupPolicy.canonicalID(request.operationID), CloudKitStaffSetupPolicy.canonicalID(request.ownerStoreID),
              request.claimOperationID == (edit.application?.operationID ?? ""), edit.application?.state != "published",
              (1..<2_147_483_647).contains(request.expectedRevision), SharedTimeError.validEmail(ownerEmail),
              let resolved = StaffOwnerFieldEditApplication.instant(resolvedAt),
              let recorded = StaffOwnerFieldEditApplication.instant(edit.receipt.createdAt), resolved >= recorded,
              let field = StaffWorkspaceModelCatalog.all.first(where: { $0.kind == edit.request.recordKind })?.fieldSchema[edit.request.fieldName]
        else { throw StaffReplicaSourceSyncError.invalid }
        try field.validateScalar(request.expectedValue)
        if let claim = edit.application {
            guard claim.ownerEmail == ownerEmail, claim.ownerStoreID == request.ownerStoreID,
                  let prepared = StaffOwnerFieldEditApplication.instant(claim.preparedAt), resolved >= prepared else { throw StaffReplicaSourceSyncError.invalid }
        }
    }
    func validate(_ original: StaffOwnerFieldEditKeepRequest, edit: StaffOwnerFieldEdit, scope: StaffReplicaSourceScope) throws {
        try validate(edit: edit, scope: scope)
        guard request == original, ownerEmail == scope.actorEmail else { throw StaffReplicaSourceSyncError.invalid }
    }
}

struct StaffOwnerFieldEditKeepPending: Codable {
    let edit: StaffOwnerFieldEdit
    let request: StaffOwnerFieldEditKeepRequest
}

/// Each completed/superseded decision has its own encrypted immutable file.
/// Clearing an active queue entry never deletes the original decision evidence.
struct StaffOwnerFieldEditKeepArchive: Codable {
    let version: Int
    let scope: StaffReplicaSourceScope
    let pending: StaffOwnerFieldEditKeepPending
    let applicationIntent: StaffOwnerFieldEditPending?
    let resolution: StaffOwnerFieldEditResolution?
    let supersededAtRevision: Int?
    var supersededByClaim: String? = nil
    func validate(_ scope: StaffReplicaSourceScope) throws {
        guard version == 1, self.scope == scope,
              [resolution != nil, supersededAtRevision != nil, supersededByClaim != nil].filter({ $0 }).count == 1 else { throw StaffReplicaSourceSyncError.storage }
        try pending.request.validate(scope, edit: pending.edit)
        if let resolution { try resolution.validate(pending.request, edit: pending.edit, scope: scope) }
        if let supersededAtRevision {
            guard supersededAtRevision > pending.request.expectedRevision, supersededAtRevision < 2_147_483_647 else { throw StaffReplicaSourceSyncError.storage }
        }
        if let supersededByClaim {
            guard pending.request.claimOperationID.isEmpty, CloudKitStaffSetupPolicy.canonicalID(supersededByClaim) else { throw StaffReplicaSourceSyncError.storage }
        }
        if let applicationIntent {
            try applicationIntent.request.validate(edit: applicationIntent.edit, scope: scope)
            guard applicationIntent.edit.request == pending.edit.request, ["prepared", "saved"].contains(applicationIntent.phase),
                  applicationIntent.phase != "saved" || applicationIntent.application != nil else { throw StaffReplicaSourceSyncError.storage }
            try applicationIntent.application?.validate(applicationIntent.request, scope: scope)
            if let resolution, !resolution.request.claimOperationID.isEmpty {
                guard applicationIntent.request.operationID == resolution.request.claimOperationID else { throw StaffReplicaSourceSyncError.storage }
            }
        }
    }
}
