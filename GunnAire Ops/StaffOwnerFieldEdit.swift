import Foundation

struct StaffOwnerFieldEdit: Codable, Equatable, Identifiable {
    static let schema = "staff-owner-field-edit-v1"
    struct Current: Codable, Equatable {
        let revision: Int
        let deleted: Bool
        let value: StaffWorkspaceValue
    }
    let schema: String
    let shareID: String
    let request: StaffWorkspaceOperationalCommandRequest
    let receipt: StaffWorkspaceOperationalCommandReceipt
    let baseValue: StaffWorkspaceValue
    let current: Current?
    let eligible: Bool
    let sourceSequence: Int
    let application: StaffOwnerFieldEditApplication?
    var resolution: StaffOwnerFieldEditResolution? = nil
    var id: String { request.commandID }

    func validate(_ scope: StaffReplicaSourceScope) throws {
        try request.validate(); try receipt.validate(against: request)
        guard schema == Self.schema, CloudKitStaffSetupPolicy.canonicalID(shareID),
              request.companyID == scope.binding.companyID.uuidString.lowercased(),
              request.environment == scope.binding.environment,
              request.replicaID == scope.binding.replicaID.uuidString.lowercased(),
              sourceSequence >= request.sourceSequence,
              sourceSequence < 2_147_483_647,
              let field = StaffWorkspaceModelCatalog.all.first(where: { $0.kind == request.recordKind })?.fieldSchema[request.fieldName]
        else { throw StaffReplicaSourceSyncError.invalid }
        try field.validateScalar(baseValue)
        if let current {
            guard (1..<2_147_483_647).contains(current.revision) else { throw StaffReplicaSourceSyncError.invalid }
            try field.validateScalar(current.value)
        }
        try application?.validate(commandID: id)
        if let application {
            try field.validateScalar(application.expectedValue)
            guard let prepared = StaffOwnerFieldEditApplication.instant(application.preparedAt),
                  let recorded = StaffOwnerFieldEditApplication.instant(receipt.createdAt), prepared >= recorded else { throw StaffReplicaSourceSyncError.invalid }
        }
        if let resolution {
            guard !eligible else { throw StaffReplicaSourceSyncError.invalid }
            try resolution.validate(edit: self, scope: scope)
        }
    }
}

struct StaffOwnerFieldEditPrepare: Codable, Equatable {
    let schema: String
    let companyID: String
    let environment: String
    let replicaID: String
    let commandID: String
    let operationID: String
    let ownerStoreID: String
    let expectedRevision: Int
    let expectedValue: StaffWorkspaceValue
    let reviewedConflict: Bool

    init(edit: StaffOwnerFieldEdit, scope: StaffReplicaSourceScope, reviewed: Bool, operation: UUID) throws {
        guard let current = edit.current, !current.deleted else { throw StaffOwnerFieldEditError.conflict }
        schema = StaffOwnerFieldEdit.schema; companyID = edit.request.companyID
        environment = edit.request.environment; replicaID = edit.request.replicaID; commandID = edit.id
        operationID = operation.uuidString.lowercased(); ownerStoreID = scope.storeUUID.lowercased()
        expectedRevision = current.revision; expectedValue = current.value; reviewedConflict = reviewed
    }
    init(edit: StaffOwnerFieldEdit, scope: StaffReplicaSourceScope, application: StaffOwnerFieldEditApplication) throws {
        try application.validate(commandID: edit.id)
        guard application.ownerStoreID == scope.storeUUID.lowercased(), application.ownerEmail == scope.actorEmail else { throw StaffOwnerFieldEditError.otherDevice }
        schema = StaffOwnerFieldEdit.schema; companyID = edit.request.companyID
        environment = edit.request.environment; replicaID = edit.request.replicaID; commandID = edit.id
        operationID = application.operationID; ownerStoreID = application.ownerStoreID
        expectedRevision = application.expectedRevision; expectedValue = application.expectedValue
        reviewedConflict = application.reviewedConflict
    }
    func validate(edit: StaffOwnerFieldEdit, scope: StaffReplicaSourceScope) throws {
        try edit.validate(scope)
        guard schema == StaffOwnerFieldEdit.schema, companyID == edit.request.companyID,
              environment == edit.request.environment, replicaID == edit.request.replicaID,
              commandID == edit.id, ownerStoreID == scope.storeUUID.lowercased(),
              CloudKitStaffSetupPolicy.canonicalID(operationID), CloudKitStaffSetupPolicy.canonicalID(ownerStoreID),
              (1..<2_147_483_647).contains(expectedRevision) else { throw StaffReplicaSourceSyncError.storage }
        guard let field = StaffWorkspaceModelCatalog.all.first(where: { $0.kind == edit.request.recordKind })?.fieldSchema[edit.request.fieldName]
        else { throw StaffReplicaSourceSyncError.invalid }
        try field.validateScalar(expectedValue)
    }
    var confirmation: StaffOwnerFieldEditConfirmation {
        .init(schema: schema, companyID: companyID, environment: environment, replicaID: replicaID,
              commandID: commandID, operationID: operationID, ownerStoreID: ownerStoreID)
    }
}

struct StaffOwnerFieldEditConfirmation: Codable, Equatable {
    let schema, companyID, environment, replicaID, commandID, operationID, ownerStoreID: String
}

struct StaffOwnerFieldEditApplication: Codable, Equatable {
    let schema, commandID, operationID, ownerStoreID, ownerEmail, preparedAt: String
    let expectedRevision: Int
    let expectedValue: StaffWorkspaceValue
    let reviewedConflict: Bool
    let state: String
    let publishedAt: String?
    nonisolated static func instant(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatter.date(from: text) { return value }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
    func validate(commandID: String) throws {
        guard schema == StaffOwnerFieldEdit.schema, self.commandID == commandID,
              CloudKitStaffSetupPolicy.canonicalID(commandID), CloudKitStaffSetupPolicy.canonicalID(operationID),
              CloudKitStaffSetupPolicy.canonicalID(ownerStoreID), SharedTimeError.validEmail(ownerEmail),
              let prepared = Self.instant(preparedAt), (1..<2_147_483_647).contains(expectedRevision),
              ["prepared", "published"].contains(state),
              (state == "prepared" && publishedAt == nil) || (state == "published" && publishedAt.flatMap(Self.instant).map { $0 >= prepared } == true)
        else { throw StaffReplicaSourceSyncError.invalid }
    }
    func validate(_ original: StaffOwnerFieldEditPrepare, scope: StaffReplicaSourceScope) throws {
        try validate(commandID: original.commandID)
        guard ownerEmail == scope.actorEmail, operationID == original.operationID, ownerStoreID == original.ownerStoreID,
              expectedRevision == original.expectedRevision, expectedValue == original.expectedValue,
              reviewedConflict == original.reviewedConflict else { throw StaffReplicaSourceSyncError.invalid }
    }
}

struct StaffOwnerFieldEditPage: Codable {
    let schema, companyID, environment, replicaID: String
    let commandIDs: [String]
    let nextCursor: String?
    func validate(_ scope: StaffReplicaSourceScope, after: String?) throws {
        guard schema == StaffOwnerFieldEdit.schema, companyID == scope.binding.companyID.uuidString.lowercased(),
              environment == scope.binding.environment, replicaID == scope.binding.replicaID.uuidString.lowercased(),
              commandIDs.count <= 50, commandIDs == Set(commandIDs).sorted(),
              commandIDs.allSatisfy({ CloudKitStaffSetupPolicy.canonicalID($0) && $0 > (after ?? "") }),
              nextCursor.map({ CloudKitStaffSetupPolicy.canonicalID($0) && $0 > (after ?? "") && $0 >= (commandIDs.last ?? "") }) ?? true
        else { throw StaffReplicaSourceSyncError.invalid }
    }
}

enum StaffOwnerFieldEditError: Error, LocalizedError {
    case conflict, unsaved, missing, otherDevice, released
    var errorDescription: String? {
        switch self {
        case .conflict: "Office data changed. Review both values before applying this field edit."
        case .unsaved: "Save or finish your current office changes before applying field edits."
        case .missing: "The original office record is missing. The field edit was retained."
        case .otherDevice: "This edit was prepared on another office device. If the update is already in company records, confirm it here using the same owner account. Otherwise recover it on the original device."
        case .released: "This device handed off the field update. Continue on another approved owner device. The original work was retained."
        }
    }
}

enum StaffOwnerFieldEditTransport {
    // The same scalar appears in the base, current value, and prepared claim.
    // JSON escaping can expand each permitted 1 MiB value up to sixfold.
    static let maximumRequestBytes = 7 * 1024 * 1024
    static let maximumResponseBytes = 32 * 1024 * 1024
    static let root = "/api/workspace/field-edits"
    static func path(_ scope: StaffReplicaSourceScope, id: String? = nil, after: String? = nil) -> String {
        var url = URLComponents(); url.path = root + (id.map { "/" + $0 } ?? "")
        url.queryItems = [.init(name: "companyID", value: scope.binding.companyID.uuidString.lowercased()),
                          .init(name: "environment", value: scope.binding.environment),
                          .init(name: "replicaID", value: scope.binding.replicaID.uuidString.lowercased())]
        if let after { url.queryItems?.append(.init(name: "after", value: after)) }
        return url.string!
    }
    static func allows(path: String, method: String, body: Data?) -> Bool {
        guard let url = URLComponents(string: path), url.scheme == nil, url.host == nil, url.fragment == nil,
              url.percentEncodedPath == url.path, url.path == root || url.path.hasPrefix(root + "/") else { return false }
        let suffix = String(url.path.dropFirst(root.count))
        let parts = suffix.isEmpty ? [] : suffix.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if method == "POST" {
            return parts.count == 2 && CloudKitStaffSetupPolicy.canonicalID(parts[0]) && ["prepare", "confirm", "keep-office", "confirm-observed", "release"].contains(parts[1])
                && url.query == nil && body.map { !$0.isEmpty && $0.count <= maximumRequestBytes } == true
        }
        guard method == "GET", body == nil, parts.count <= 1, parts.first.map(CloudKitStaffSetupPolicy.canonicalID) ?? true,
              let query = url.queryItems else { return false }
        var values: [String: String] = [:]
        for item in query { guard let value = item.value, values.updateValue(value, forKey: item.name) == nil else { return false } }
        guard let company = values["companyID"], let replica = values["replicaID"],
              CloudKitStaffSetupPolicy.canonicalID(company), CloudKitStaffSetupPolicy.canonicalID(replica),
              ["development", "production"].contains(values["environment"] ?? ""),
              Set(values.keys).isSubset(of: parts.isEmpty ? ["companyID", "environment", "replicaID", "after"] : ["companyID", "environment", "replicaID"])
        else { return false }
        return values["after"].map(CloudKitStaffSetupPolicy.canonicalID) ?? true
    }
}
