import Foundation

/// A witness of existing company data, not permission to apply or transfer a claim.
struct StaffOwnerFieldObservationRequest: Codable, Equatable {
    static let schema = "staff-owner-field-observation-v1"
    let schema, companyID, environment, replicaID, commandID, operationID, observerStoreID, claimOperationID: String
    let expectedRevision: Int
    let expectedValue: StaffWorkspaceValue
    init(edit: StaffOwnerFieldEdit, scope: StaffReplicaSourceScope, operation: UUID) throws {
        guard let current = edit.current, let claim = edit.application else { throw StaffOwnerFieldEditError.conflict }
        schema = Self.schema; companyID = edit.request.companyID; environment = edit.request.environment
        replicaID = edit.request.replicaID; commandID = edit.id; operationID = operation.uuidString.lowercased()
        observerStoreID = scope.storeUUID.lowercased(); claimOperationID = claim.operationID
        expectedRevision = current.revision; expectedValue = current.value
        try validate(scope, edit: edit)
    }
    func validate(_ scope: StaffReplicaSourceScope, edit: StaffOwnerFieldEdit) throws {
        try edit.validate(scope)
        guard schema == Self.schema, companyID == edit.request.companyID, environment == edit.request.environment,
              replicaID == edit.request.replicaID, commandID == edit.id,
              observerStoreID == scope.storeUUID.lowercased(), CloudKitStaffSetupPolicy.canonicalID(observerStoreID),
              CloudKitStaffSetupPolicy.canonicalID(operationID), let claim = edit.application,
              claim.ownerEmail == scope.actorEmail, claim.ownerStoreID != observerStoreID,
              claimOperationID == claim.operationID, edit.resolution == nil,
              let current = edit.current, !current.deleted, current.revision == expectedRevision,
              (1..<2_147_483_647).contains(expectedRevision), expectedRevision >= claim.expectedRevision,
              current.value == expectedValue, expectedValue == edit.request.value else { throw StaffOwnerFieldEditError.conflict }
    }
}

struct StaffOwnerFieldObservationReceipt: Codable, Equatable {
    let schema: String
    let request: StaffOwnerFieldObservationRequest
    let ownerEmail, observedAt: String
    let application: StaffOwnerFieldEditApplication
    func validate(_ pending: StaffOwnerFieldObservationPending, scope: StaffReplicaSourceScope) throws {
        try pending.request.validate(scope, edit: pending.edit)
        try application.validatePublication(of: pending.edit)
        guard schema == StaffOwnerFieldObservationRequest.schema, request == pending.request, ownerEmail == scope.actorEmail,
              let observed = StaffOwnerFieldEditApplication.instant(observedAt),
              let published = application.publishedAt.flatMap(StaffOwnerFieldEditApplication.instant), observed >= published
        else { throw StaffReplicaSourceSyncError.invalid }
    }
}

extension StaffOwnerFieldEditApplication {
    func validatePublication(of original: StaffOwnerFieldEdit) throws {
        try validate(commandID: original.id)
        guard let claim = original.application, state == "published", schema == claim.schema,
              operationID == claim.operationID, ownerStoreID == claim.ownerStoreID, ownerEmail == claim.ownerEmail,
              preparedAt == claim.preparedAt, expectedRevision == claim.expectedRevision,
              expectedValue == claim.expectedValue, reviewedConflict == claim.reviewedConflict,
              claim.state != "published" || self == claim else { throw StaffReplicaSourceSyncError.invalid }
    }
}

struct StaffOwnerFieldObservationPending: Codable, Equatable {
    let edit: StaffOwnerFieldEdit
    let request: StaffOwnerFieldObservationRequest
}

/// Immutable evidence of the response, publication elsewhere, or a supersession fence.
struct StaffOwnerFieldObservationArchive: Codable {
    let version: Int
    let scope: StaffReplicaSourceScope
    let pending: StaffOwnerFieldObservationPending
    var receipt: StaffOwnerFieldObservationReceipt? = nil
    var publishedElsewhere: StaffOwnerFieldEditApplication? = nil
    var supersededAtRevision: Int? = nil
    func validate(_ scope: StaffReplicaSourceScope) throws {
        guard version == 1, self.scope == scope,
              [receipt != nil, publishedElsewhere != nil, supersededAtRevision != nil].filter({ $0 }).count == 1
        else { throw StaffReplicaSourceSyncError.storage }
        try pending.request.validate(scope, edit: pending.edit)
        try receipt?.validate(pending, scope: scope)
        try publishedElsewhere?.validatePublication(of: pending.edit)
        if let revision = supersededAtRevision {
            guard revision > pending.request.expectedRevision, revision < 2_147_483_647 else { throw StaffReplicaSourceSyncError.storage }
        }
    }
}
