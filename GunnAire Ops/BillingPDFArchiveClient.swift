import Foundation
import SwiftData

nonisolated enum BillingPDFArchiveClientError: Error, LocalizedError, Equatable {
    case access
    case connection
    case changed
    case invalid

    var errorDescription: String? {
        switch self {
        case .access: "Reopen the verified company workspace as the approved administrator."
        case .connection: "Connect the same approved Google account to the app and business server with Drive access."
        case .changed: "The billing PDF reservation or Google account changed. Review the original document."
        case .invalid: "The billing PDF reservation could not be verified. Review the document before archiving."
        }
    }
}

nonisolated struct BillingPDFArchiveKey: Codable, Equatable, Sendable {
    let companyID: UUID
    let driveAccount: String
    let documentKind: BillingPDFGenerationIntent.DocumentKind
    let documentID: UUID
    let sourceDigest: String
    let rendererVersion: String

    enum CodingKeys: String, CodingKey {
        case companyID = "company_id"
        case driveAccount = "drive_account"
        case documentKind = "document_kind"
        case documentID = "document_id"
        case sourceDigest = "source_digest"
        case rendererVersion = "renderer_version"
    }
}

nonisolated struct BillingPDFArchiveReservation: Decodable, Equatable, Sendable {
    let key: BillingPDFArchiveKey
    let attachmentID: UUID
    let renderedAt: String
    let leaseToken: UUID?
    let leaseUntil: String?
    let contentDigest: String?
    let driveFileID: String?
    let confirmedLink: String?

    enum CodingKeys: String, CodingKey {
        case key
        case attachmentID = "attachment_id"
        case renderedAt = "rendered_at"
        case leaseToken = "lease_token"
        case leaseUntil = "lease_until"
        case contentDigest = "content_digest"
        case driveFileID = "drive_file_id"
        case confirmedLink = "confirmed_link"
    }
}

nonisolated struct BillingPDFArchiveResponse: Decodable, Sendable {
    let reservation: BillingPDFArchiveReservation?
}

nonisolated struct BillingPDFArchiveIdentity: Decodable, Sendable {
    let companyID: UUID
    let grantID: UUID
    let driveAccount: String

    func validate(companyID: UUID, grantID: UUID, nativeGoogleSubject: String) throws {
        let expected = "google-subject:" + CompanyWorkspaceSession.digest(nativeGoogleSubject)
        guard self.companyID == companyID, self.grantID == grantID,
              driveAccount == expected else { throw BillingPDFArchiveClientError.connection }
    }
}

/// Serializes a single device's reservation requests. The backend CAS ledger
/// is the cross-device authority; this actor never treats an absent status or
/// lost reply as permission to generate a new Google file ID.
actor BillingPDFArchiveClient {
    typealias Request = @Sendable (String, String, Data?) async throws -> Data
    typealias Check = @Sendable () async throws -> Void

    private let binding: CompanyCloudKitBinding
    private let grantID: UUID
    private let driveAccount: String
    private let request: Request
    private let check: Check
    private static let endpoint = "/api/google/drive/billing-pdf-intents"

    init(binding: CompanyCloudKitBinding, grantID: UUID, driveAccount: String,
         check: @escaping Check, request: @escaping Request) throws {
        guard binding.isValid,
              driveAccount.range(of: "^google-subject:[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw BillingPDFArchiveClientError.invalid
        }
        self.binding = binding
        self.grantID = grantID
        self.driveAccount = driveAccount
        self.check = check
        self.request = request
    }

    @MainActor static func capture(context: ModelContext) async throws -> BillingPDFArchiveClient {
        let workspace = CompanyWorkspaceAccessController.shared
        guard workspace.verifiedRole == .admin, let binding = workspace.verifiedBinding,
              let container = workspace.authorizedContainer, container === context.container,
              let session = CompanyWorkspaceSession.current else { throw BillingPDFArchiveClientError.access }
        let generation = workspace.generation
        let containerID = ObjectIdentifier(container)
        let auth = GoogleAuthManager.shared
        guard auth.googleDriveAuthorizationState == .ready else { throw BillingPDFArchiveClientError.connection }
        let nativeGeneration = auth.driveArchiveConnectionGeneration
        let profile: GoogleUserProfile = try await withCheckedThrowingContinuation { continuation in
            auth.fetchUserProfile(rememberIdentity: false) { continuation.resume(with: $0) }
        }
        guard !profile.sub.isEmpty,
              AppAccess.normalizedEmail(profile.email) == session.email,
              auth.driveArchiveConnectionGeneration == nativeGeneration,
              workspace.generation == generation else { throw BillingPDFArchiveClientError.connection }
        let scope = GoogleServerScope(companyID: binding.companyID,
            backendOrigin: session.backendOrigin, actorEmail: session.email)
        try scope.validate()
        let status = try await GunnAireBackendService.googleConnectionRequest(
            path: "/api/google/connection?companyID=" + binding.companyID.uuidString.lowercased(),
            method: "GET", body: nil)
        let snapshot = try JSONDecoder().decode(GoogleServerSnapshot.self, from: status)
        try snapshot.validate(scope: scope)
        guard snapshot.state == .active, snapshot.features.contains(.drive),
              let grantID = snapshot.id,
              workspace.generation == generation,
              workspace.verifiedBinding == binding,
              workspace.authorizedContainer === container,
              auth.driveArchiveConnectionGeneration == nativeGeneration else {
            throw BillingPDFArchiveClientError.connection
        }
        var components = URLComponents()
        components.path = Self.endpoint + "/identity"
        let workspaceFields: [String: String] = [
            "companyID": binding.companyID.uuidString.lowercased(),
            "grantID": grantID.uuidString.lowercased(),
            "containerID": binding.containerID,
            "environment": binding.environment,
            "replicaID": binding.replicaID.uuidString.lowercased(),
            "cloudAccountHash": binding.cloudAccountHash,
        ]
        components.queryItems = workspaceFields.sorted { $0.key < $1.key }.map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        guard let identityPath = components.string else { throw BillingPDFArchiveClientError.invalid }
        let identityData = try await GunnAireBackendService.billingPDFArchiveRequest(
            path: identityPath, method: "GET", body: nil)
        guard let serverIdentity = try? JSONDecoder().decode(BillingPDFArchiveIdentity.self, from: identityData),
              workspace.generation == generation,
              workspace.verifiedBinding == binding,
              workspace.authorizedContainer === container,
              auth.driveArchiveConnectionGeneration == nativeGeneration else {
            throw BillingPDFArchiveClientError.connection
        }
        try serverIdentity.validate(companyID: binding.companyID, grantID: grantID,
            nativeGoogleSubject: profile.sub)
        let identity = serverIdentity.driveAccount
        let check: Check = {
            try await MainActor.run {
                let current = CompanyWorkspaceAccessController.shared
                let google = GoogleAuthManager.shared
                guard current.generation == generation,
                      current.verifiedBinding == binding,
                      current.authorizedContainer.map(ObjectIdentifier.init) == containerID,
                      CompanyWorkspaceSession.current == session,
                      google.driveArchiveConnectionGeneration == nativeGeneration,
                      google.googleDriveAuthorizationState == .ready,
                      AppAccess.normalizedEmail(google.signedInEmail) == session.email else {
                    throw BillingPDFArchiveClientError.access
                }
            }
        }
        return try BillingPDFArchiveClient(binding: binding, grantID: grantID,
            driveAccount: identity, check: check,
            request: { try await GunnAireBackendService.billingPDFArchiveRequest(path: $0, method: $1, body: $2) })
    }

    func status(kind: BillingPDFGenerationIntent.DocumentKind, documentID: UUID,
                sourceDigest: String, rendererVersion: String) async throws -> BillingPDFArchiveReservation? {
        try await perform("GET", operation: nil, kind: kind, documentID: documentID,
            sourceDigest: sourceDigest, rendererVersion: rendererVersion, extra: [:])
    }

    func reserve(kind: BillingPDFGenerationIntent.DocumentKind, documentID: UUID,
                 sourceDigest: String, rendererVersion: String) async throws -> BillingPDFArchiveReservation {
        guard let result = try await perform("POST", operation: "reserve", kind: kind,
            documentID: documentID, sourceDigest: sourceDigest, rendererVersion: rendererVersion,
            extra: [:]) else { throw BillingPDFArchiveClientError.invalid }
        return result
    }

    func bindContent(_ reservation: BillingPDFArchiveReservation, digest: String) async throws -> BillingPDFArchiveReservation {
        guard let token = reservation.leaseToken, Self.validDigest(digest) else { throw BillingPDFArchiveClientError.changed }
        guard let result = try await perform("POST", operation: "content", kind: reservation.key.documentKind,
            documentID: reservation.key.documentID, sourceDigest: reservation.key.sourceDigest,
            rendererVersion: reservation.key.rendererVersion,
            extra: ["leaseToken": token.uuidString.lowercased(), "contentDigest": digest]) else {
            throw BillingPDFArchiveClientError.invalid
        }
        return result
    }

    func bindFile(_ reservation: BillingPDFArchiveReservation, fileID: String) async throws -> BillingPDFArchiveReservation {
        guard let token = reservation.leaseToken, Self.validFileID(fileID) else { throw BillingPDFArchiveClientError.changed }
        guard let result = try await perform("POST", operation: "file", kind: reservation.key.documentKind,
            documentID: reservation.key.documentID, sourceDigest: reservation.key.sourceDigest,
            rendererVersion: reservation.key.rendererVersion,
            extra: ["leaseToken": token.uuidString.lowercased(), "fileID": fileID]) else {
            throw BillingPDFArchiveClientError.invalid
        }
        return result
    }

    func confirm(_ reservation: BillingPDFArchiveReservation) async throws -> BillingPDFArchiveReservation {
        guard let token = reservation.leaseToken,
              let fileID = reservation.driveFileID,
              let digest = reservation.contentDigest else { throw BillingPDFArchiveClientError.changed }
        guard let result = try await perform("POST", operation: "confirm", kind: reservation.key.documentKind,
            documentID: reservation.key.documentID, sourceDigest: reservation.key.sourceDigest,
            rendererVersion: reservation.key.rendererVersion,
            extra: ["leaseToken": token.uuidString.lowercased(), "fileID": fileID,
                    "contentDigest": digest]) else { throw BillingPDFArchiveClientError.invalid }
        return result
    }

    private func perform(_ method: String, operation: String?,
                         kind: BillingPDFGenerationIntent.DocumentKind, documentID: UUID,
                         sourceDigest: String, rendererVersion: String,
                         extra: [String: String]) async throws -> BillingPDFArchiveReservation? {
        guard Self.validDigest(sourceDigest),
              rendererVersion.range(of: "^[A-Za-z0-9_.-]{1,40}$", options: .regularExpression) != nil else {
            throw BillingPDFArchiveClientError.invalid
        }
        try await check()
        var fields: [String: String] = [
            "companyID": binding.companyID.uuidString.lowercased(),
            "grantID": grantID.uuidString.lowercased(),
            "containerID": binding.containerID,
            "environment": binding.environment,
            "replicaID": binding.replicaID.uuidString.lowercased(),
            "cloudAccountHash": binding.cloudAccountHash,
            "expectedDriveAccount": driveAccount,
            "documentKind": kind.rawValue,
            "documentID": documentID.uuidString.lowercased(),
            "sourceDigest": sourceDigest,
            "rendererVersion": rendererVersion,
        ]
        let path: String
        let body: Data?
        if method == "GET" {
            guard operation == nil, extra.isEmpty else { throw BillingPDFArchiveClientError.invalid }
            var components = URLComponents()
            components.path = Self.endpoint
            components.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let encoded = components.string else { throw BillingPDFArchiveClientError.invalid }
            path = encoded
            body = nil
        } else {
            guard let operation, ["reserve", "content", "file", "confirm"].contains(operation),
                  Set(fields.keys).isDisjoint(with: extra.keys) else { throw BillingPDFArchiveClientError.invalid }
            fields.merge(extra) { old, _ in old }
            path = Self.endpoint + "/" + operation
            body = try JSONEncoder().encode(fields)
        }
        let data = try await request(path, method, body)
        try await check()
        guard data.count <= 32_768,
              let decoded = try? JSONDecoder().decode(BillingPDFArchiveResponse.self, from: data) else {
            throw BillingPDFArchiveClientError.invalid
        }
        guard let reservation = decoded.reservation else { return nil }
        let expected = BillingPDFArchiveKey(companyID: binding.companyID,
            driveAccount: driveAccount, documentKind: kind, documentID: documentID,
            sourceDigest: sourceDigest, rendererVersion: rendererVersion)
        guard reservation.key == expected,
              !reservation.renderedAt.isEmpty,
              reservation.contentDigest.map(Self.validDigest) != false,
              reservation.driveFileID.map(Self.validFileID) != false,
              reservation.confirmedLink == nil || reservation.driveFileID != nil else {
            throw BillingPDFArchiveClientError.changed
        }
        return reservation
    }

    private nonisolated static func validDigest(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }

    private nonisolated static func validFileID(_ value: String) -> Bool {
        (1...200).contains(value.utf8.count) && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) ||
            (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
}
