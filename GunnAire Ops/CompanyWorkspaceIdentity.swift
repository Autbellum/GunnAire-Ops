import Foundation

/// Server-owned identity for this business database. An email domain, QBO
/// connection, administrator role, or a nonempty local replica is not proof of
/// membership. This contract is only one input to the storage access boundary.
struct CompanyWorkspaceIdentity: Codable, Equatable, Sendable {
    let companyID: UUID
    let containerID: String
    let bindings: [CompanyCloudKitBinding]

    /// Reject conflicting or malformed server metadata rather than picking an
    /// arbitrary binding. Development and Production are distinct replicas.
    func binding(for environment: String) -> CompanyCloudKitBinding? {
        guard containerID == GunnAireCloudKit.containerIdentifier,
              environment == "development" || environment == "production",
              bindings.allSatisfy({
                  $0.companyID == companyID && $0.containerID == containerID && $0.isValid
              }) else { return nil }
        let candidates = bindings.filter { $0.environment == environment }
        guard candidates.count == 1 else { return nil }
        return candidates[0]
    }
}

struct CompanyCloudKitBinding: Codable, Equatable, Sendable {
    let companyID: UUID
    let containerID: String
    let environment: String
    let replicaID: UUID
    let cloudAccountHash: String
    let approvedAt: String

    var isValid: Bool {
        containerID == GunnAireCloudKit.containerIdentifier &&
        (environment == "development" || environment == "production") &&
        cloudAccountHash.count == 64 &&
        cloudAccountHash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } &&
        Self.parseApprovalDate(approvedAt) != nil
    }

    private static func parseApprovalDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}

struct BackendCompanyWorkspaceResponse: Decodable {
    let user: BackendAppUserRecord
    let workspace: CompanyWorkspaceIdentity
}

struct CompanyCloudKitApprovalRequest: Encodable {
    let expectedCompanyID: String
    let containerID: String
    let environment: String
    let cloudAccountHash: String
    let confirmCompanyDataOwnership: Bool

    init(
        companyID: UUID,
        containerID: String,
        environment: String,
        cloudAccountHash: String,
        confirmCompanyDataOwnership: Bool
    ) {
        self.expectedCompanyID = companyID.uuidString.lowercased()
        self.containerID = containerID
        self.environment = environment
        self.cloudAccountHash = cloudAccountHash
        self.confirmCompanyDataOwnership = confirmCompanyDataOwnership
    }
}

struct BackendCompanyCloudKitApprovalResponse: Decodable {
    let binding: CompanyCloudKitBinding
}
