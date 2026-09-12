import Foundation

enum CompanyDocumentContentError: Error, LocalizedError, Equatable {
    case access, invalid, changed, unverified
    var errorDescription: String? {
        switch self {
        case .access: "Document access changed. Reopen the original business account."
        case .invalid: "The original document proof could not be verified. The record was retained."
        case .changed: "The document does not match its original upload. Keep the original for review."
        case .unverified: "Original document content could not be verified. Keep this record and check or import the retained original."
        }
    }
    static func transportFailure(_ error: Error) -> Error {
        if case GmailServerHTTPError.status(let status) = error {
            if [401, 403].contains(status) { return Self.access }
            if status == 409 { return Self.unverified }
        }
        if error is GmailServerHTTPError { return Self.invalid }
        return error // Preserve readable system network/cancellation errors.
    }
}

/// Upload-time evidence from the authorized server, never a hash of today's
/// downloaded bytes masquerading as historical proof.
struct CompanyDocumentContentProof: Codable, Equatable {
    static let schema = "company-document-content-v1"
    static let maximum = 64 * 1024 * 1024
    let schema, id, filename, contentType: String
    let fileSizeBytes: Int
    let fileSHA256, createdAt: String
    func validate(id: String) throws {
        guard schema == Self.schema, self.id == id, CloudKitStaffSetupPolicy.canonicalID(id),
              StaffWorkspaceOperationalMediaGrant.validDisplayName(filename),
              StaffWorkspaceOperationalMediaGrant.validContentType(contentType),
              (1...Self.maximum).contains(fileSizeBytes), JobBillingAssignmentSnapshot.validConnectionRevision(fileSHA256),
              CompanyWorkspaceClock.parse(createdAt) != nil else { throw CompanyDocumentContentError.invalid }
    }
    static func verify(_ data: Data, size: Int, sha256: String) throws {
        guard (1...maximum).contains(size), JobBillingAssignmentSnapshot.validConnectionRevision(sha256),
              data.count == size, QBODocumentFileInfo.hash(data) == sha256 else { throw CompanyDocumentContentError.changed }
    }
    static func verifyFile(_ url: URL, size: Int, sha256: String) throws {
        guard (1...maximum).contains(size) else { throw CompanyDocumentContentError.invalid }
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true, properties.fileSize == size else { throw CompanyDocumentContentError.changed }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var bytes = Data()
        while bytes.count <= size {
            guard let part = try file.read(upToCount: min(64 * 1024, size + 1 - bytes.count)), !part.isEmpty else { break }
            bytes.append(part)
        }
        try verify(bytes, size: size, sha256: sha256)
    }
}

@MainActor struct CompanyDocumentContentClient {
    let request: (String, Int) async throws -> Data
    let check: () throws -> Void
    static func path(id: String, manifest: Bool) throws -> String {
        guard CloudKitStaffSetupPolicy.canonicalID(id) else { throw CompanyDocumentContentError.invalid }
        return "/api/documents/" + id + (manifest ? "/manifest" : "/download")
    }
    static func allows(_ path: String, maximum: Int) -> Bool {
        guard let url = URLComponents(string: path), url.scheme == nil, url.host == nil, url.query == nil,
              url.fragment == nil, url.percentEncodedPath == url.path else { return false }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0].isEmpty, parts[1] == "api", parts[2] == "documents",
              CloudKitStaffSetupPolicy.canonicalID(String(parts[3])) else { return false }
        return (parts[4] == "manifest" && maximum == 8192)
            || (parts[4] == "download" && (1...CompanyDocumentContentProof.maximum).contains(maximum))
    }
    func download(id: String) async throws -> Data {
        try check(); try Task.checkCancellation()
        let path = try Self.path(id: id, manifest: true)
        let raw = try await request(path, 8192)
        try check(); try Task.checkCancellation()
        let proof = try StaffWorkspacePublicationContract.decode(CompanyDocumentContentProof.self, from: raw, maximum: 8192)
        try proof.validate(id: id)
        let bytes = try await request(Self.path(id: id, manifest: false), proof.fileSizeBytes)
        try check(); try Task.checkCancellation()
        try CompanyDocumentContentProof.verify(bytes, size: proof.fileSizeBytes, sha256: proof.fileSHA256)
        // A changed binding/filename/permission between the two requests must
        // not cause verified bytes to be attached to a different record.
        let latest = try await request(path, 8192)
        try check(); try Task.checkCancellation()
        let current = try StaffWorkspacePublicationContract.decode(CompanyDocumentContentProof.self, from: latest, maximum: 8192)
        try current.validate(id: id)
        guard current == proof else { throw CompanyDocumentContentError.changed }
        return bytes
    }
}
