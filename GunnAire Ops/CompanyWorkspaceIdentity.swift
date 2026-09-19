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
        CompanyApprovalDateParser.date(from: raw)
    }
}

/// Parses the approval stamp on a workspace binding without rebuilding a date
/// formatter every time.
///
/// This sits on the hottest path in the app. Every screen asks whether the
/// signed-in account still holds its role; each of those checks reaches
/// `CompanyCloudKitBinding.isValid`, and one redraw of the dashboard makes
/// thousands of them. Constructing an `ISO8601DateFormatter` loads ICU calendar
/// and locale tables from disk, which costs far more than the comparison the
/// caller actually wanted: an Instruments recording on the owner's iPad
/// attributed roughly three quarters of all CPU samples to this check, with the
/// main thread blocked for 40 of 45 seconds.
///
/// Two changes, neither of which alters what counts as a valid date. The two
/// formatters are built once instead of per call, and the last result is
/// remembered, because the same binding is re-validated over and over inside a
/// single redraw. Parsing is deterministic, so a repeat of the same string must
/// produce the same answer.
///
/// The lock is what makes shared formatters safe: a binding is `Sendable` and is
/// validated from the decoding and networking paths as well as the main actor.
/// Taking an uncontended lock costs a fraction of what it replaces.
enum CompanyApprovalDateParser {
    private static let lock = NSLock()

    private static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let withInternetDateTime = ISO8601DateFormatter()

    private static var memoizedRaw: String?
    private static var memoizedDate: Date?

    static func date(from raw: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        if let memoizedRaw, memoizedRaw == raw {
            return memoizedDate
        }
        // Fractional seconds first, then the plain internet date-time form, so a
        // stamp written either way is still accepted.
        let parsed = withFractionalSeconds.date(from: raw) ?? withInternetDateTime.date(from: raw)
        memoizedRaw = raw
        memoizedDate = parsed
        return parsed
    }

    /// Only for tests, which need each case measured from a cold parser rather
    /// than against the previous case's remembered answer.
    static func forgetMemoizedValue() {
        lock.lock()
        defer { lock.unlock() }
        memoizedRaw = nil
        memoizedDate = nil
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
