import Foundation

/// A historical office outcome, separate from the immutable recorded receipt.
/// No office comparison values, claim identifiers, or device information cross this wire.
struct StaffWorkspaceFieldUpdate: Codable, Equatable, Identifiable {
    let request: StaffWorkspaceOperationalCommandRequest
    let receipt: StaffWorkspaceOperationalCommandReceipt
    let state: String
    /// Closed wire contract uses an empty string while awaiting office review.
    let decidedAt: String
    var id: String { request.commandID }
    var status: String {
        switch state {
        case "appliedToOffice": return "Applied to office records"
        case "keptOffice": return "Office value kept · your update is retained"
        default: return "Awaiting office review"
        }
    }
    func validate(scope: CloudKitStaffSetupScope, plan: CloudKitStaffSharePlan) throws {
        try request.validate()
        try receipt.validate(against: request)
        guard request.companyID == scope.company.uuidString.lowercased(), request.environment == scope.environment,
              request.replicaID == plan.replicaID.uuidString.lowercased(), receipt.actorEmail == scope.email,
              ["awaitingOffice", "appliedToOffice", "keptOffice"].contains(state) else { throw StaffReplicaDeliveryError.invalid }
        if state == "awaitingOffice" {
            guard decidedAt.isEmpty else { throw StaffReplicaDeliveryError.invalid }
        } else {
            guard let decided = StaffOwnerFieldEditApplication.instant(decidedAt),
                  let recorded = StaffOwnerFieldEditApplication.instant(receipt.createdAt), decided >= recorded else {
                throw StaffReplicaDeliveryError.invalid
            }
        }
    }
}

struct StaffWorkspaceFieldUpdatesPage: Codable, Equatable {
    static let schema = "staff-field-updates-v1"
    static let maximumBytes = 512 * 1024
    let schema: String
    let companyID: String
    let environment: String
    let replicaID: String
    let shareID: String
    let entries: [StaffWorkspaceFieldUpdate]
    let nextCursor: String

    func validate(scope: CloudKitStaffSetupScope, plan: CloudKitStaffSharePlan,
                  after: String? = nil, commandID: String? = nil) throws {
        guard schema == Self.schema, companyID == scope.company.uuidString.lowercased(), environment == scope.environment,
              replicaID == plan.replicaID.uuidString.lowercased(), shareID == plan.id.uuidString.lowercased(),
              entries.count <= 8, Set(entries.map(\.id)).count == entries.count,
              entries.map(\.id) == entries.map(\.id).sorted() else { throw StaffReplicaDeliveryError.invalid }
        for entry in entries { try entry.validate(scope: scope, plan: plan) }
        if let commandID {
            guard after == nil, entries.count == 1, entries.first?.id == commandID, nextCursor.isEmpty else {
                throw StaffReplicaDeliveryError.invalid
            }
        } else {
            guard after == nil || CloudKitStaffSetupPolicy.canonicalID(after!),
                  entries.allSatisfy({ $0.id > (after ?? "") }),
                  nextCursor.isEmpty || entries.count == 8 && nextCursor == entries.last?.id else {
                throw StaffReplicaDeliveryError.invalid
            }
        }
    }
}

enum StaffWorkspaceFieldUpdatesHTTPPolicy {
    static func path(plan: CloudKitStaffSharePlan, scope: CloudKitStaffSetupScope,
                     after: String? = nil, commandID: String? = nil) -> String {
        var url = URLComponents()
        url.path = CloudKitStaffSetupPolicy.base + "/" + plan.id.uuidString.lowercased() + "/field-updates"
        if let commandID { url.path += "/" + commandID }
        url.queryItems = [.init(name: "companyID", value: scope.company.uuidString.lowercased()),
                          .init(name: "environment", value: scope.environment),
                          .init(name: "replicaID", value: plan.replicaID.uuidString.lowercased())]
        if let after { url.queryItems?.append(.init(name: "after", value: after)) }
        return url.string ?? ""
    }
    static func allows(path: String, method: String, body: Data?) -> Bool {
        guard method == "GET", body == nil, let url = URLComponents(string: path), url.scheme == nil,
              url.host == nil, url.fragment == nil, url.path == url.percentEncodedPath else { return false }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (6...7).contains(parts.count), Array(parts.prefix(4)) == ["", "api", "workspace", "staff-shares"],
              CloudKitStaffSetupPolicy.canonicalID(parts[4]), parts[5] == "field-updates",
              parts.count == 6 || CloudKitStaffSetupPolicy.canonicalID(parts[6]),
              let items = url.queryItems, items.allSatisfy({ $0.value != nil }),
              Set(items.map(\.name)).count == items.count else { return false }
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
        let names: Set<String> = ["companyID", "environment", "replicaID"]
        guard CloudKitStaffSetupPolicy.canonicalID(query["companyID"] ?? ""),
              CloudKitStaffSetupPolicy.canonicalID(query["replicaID"] ?? ""),
              ["development", "production"].contains(query["environment"] ?? "") else { return false }
        return Set(query.keys) == names || parts.count == 6 && Set(query.keys) == names.union(["after"])
            && CloudKitStaffSetupPolicy.canonicalID(query["after"] ?? "")
    }
}
