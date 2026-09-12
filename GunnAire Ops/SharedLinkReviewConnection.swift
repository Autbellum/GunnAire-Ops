import Foundation
import SwiftData

enum LinkReviewTransportPolicy {
    static func allows(path: String, method: String, bodyBytes: Int?) -> Bool {
        guard path.utf8.count <= 8192, let url = URLComponents(string: path), url.scheme == nil,
              url.host == nil, url.fragment == nil, url.percentEncodedPath == url.path else { return false }
        let root = "/api/qbo-link-reviews"
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
        if method == "POST" {
            guard url.query == nil, let size = bodyBytes, (1...131072).contains(size) else { return false }
            if url.path == root { return true }
            return parts.count == 5 && parts[0].isEmpty && parts[1] == "api" && parts[2] == "qbo-link-reviews" &&
                UUID(uuidString: String(parts[3]))?.uuidString.lowercased() == String(parts[3]) &&
                ["confirm", "cancel"].contains(parts[4])
        }
        guard method == "GET", bodyBytes == nil else { return false }
        if parts.count == 4, parts[0].isEmpty, parts[1] == "api", parts[2] == "qbo-link-reviews",
           UUID(uuidString: String(parts[3])) != nil { return url.query == nil }
        guard url.path == root || url.path == root + "/context", let fields = url.queryItems,
              Set(fields.map(\.name)).count == fields.count else { return false }
        let names = Set(fields.map(\.name))
        func value(_ key: String) -> String { fields.first(where: { $0.name == key })?.value ?? "" }
        guard UUID(uuidString: value("companyID")) != nil else { return false }
        if url.path.hasSuffix("/context") { return names == ["companyID"] }
        return (names == ["companyID", "realmID", "environment"] || names == ["companyID", "realmID", "environment", "operationID"]) &&
            PaymentAttemptRecord.isReference(value("realmID")) && ["sandbox", "production"].contains(value("environment")) &&
            (!names.contains("operationID") || UUID(uuidString: value("operationID")) != nil)
    }
}

struct SharedLinkReviewConnection: Codable {
    let companyID: UUID
    let realmID: String
    let environment: String
    let connectionRevision: String
    let protocolVersion: Int

    func validate(companyID: UUID) throws {
        guard self.companyID == companyID, PaymentAttemptRecord.isReference(realmID),
              ["sandbox", "production"].contains(environment), protocolVersion == 1,
              JobBillingAssignmentSnapshot.validConnectionRevision(connectionRevision) else { throw QuickBooksLinkReviewError.invalid }
    }
}

/// Connection discovery is bound to the original visible business before await.
/// The existing realm/actor journal is retained, including old-grant recovery.
@MainActor final class SharedLinkReviewPreparation {
    let companyID: UUID
    private let operation: WorkspaceProviderOperation
    private let context: ModelContext
    private let client: QuickBooksLinkReviewClient
    private let access: () throws -> Void
    private let actorEmail: String?

    init(context: ModelContext, client: QuickBooksLinkReviewClient, isCurrent: @escaping () -> Bool,
         fixtureCompanyID: UUID? = nil, actorEmail: String? = nil, validateAccess: (() throws -> Void)? = nil) throws {
        if fixtureCompanyID != nil { precondition(GunnAireCloudKit.usesTestDatabase) }
        let validate = validateAccess ?? { try QuickBooksSyncAccessPolicy.validate(context: context) }
        let originalActor = AppAccess.normalizedEmail(actorEmail ?? AppIdentity.currentEmail)
        let access = {
            try validate()
            guard AppAccess.normalizedEmail(actorEmail ?? AppIdentity.currentEmail) == originalActor else { throw QuickBooksLinkReviewError.access }
        }
        try access()
        guard let companyID = fixtureCompanyID ?? CompanyWorkspaceAccessController.shared.verifiedCompanyID else { throw QuickBooksLinkReviewError.access }
        self.companyID = companyID; self.context = context; self.client = client; self.access = access; self.actorEmail = actorEmail
        operation = try WorkspaceProviderOperation.capture {
            guard isCurrent() else { return false }
            do { try access(); return true } catch { return false }
        }
    }

    func owner(store: QuickBooksLinkReviewStore? = nil) async throws -> QuickBooksLinkReviewOwner {
        try operation.check(); try access()
        do {
            let data = try await client.transport("/api/qbo-link-reviews/context?companyID=\(companyID.uuidString.lowercased())", "GET", nil)
            try operation.check(); try access()
            guard data.count <= 8192 else { throw QuickBooksLinkReviewError.invalid }
            let connection = try JSONDecoder().decode(SharedLinkReviewConnection.self, from: data)
            try connection.validate(companyID: companyID)
            let api = QuickBooksDataAPI(sharedCompanyID: companyID, realmID: connection.realmID, environment: connection.environment,
                connectionRevision: connection.connectionRevision, operation: operation,
                billingPublisher: .init { _, _, _ in throw BillingPublicationError.accessRequired },
                catalogPublisher: { _ in throw CatalogPublicationError.accessRequired })
            return try QuickBooksLinkReviewOwner(context: context, api: api, client: client, store: store,
                actorEmail: actorEmail, validateAccess: access)
        } catch {
            try operation.check(); try access()
            throw QuickBooksLinkReviewClient.safe(error)
        }
    }
}
