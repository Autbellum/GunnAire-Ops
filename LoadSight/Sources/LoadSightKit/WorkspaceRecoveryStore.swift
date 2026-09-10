import Foundation
import CryptoKit
import Darwin

public struct WorkspaceRecoveryDraft: Codable, Sendable {
    public let version: Int
    public let revision: UUID
    public let scopeDigest: String
    public let savedAt: String
    public let project: JSONValue
    public let drawings: DrawingArchive
    public func restoredProject() throws -> ProjectDocument {
        try require(version == 1, "Unsupported recovery draft version.")
        try require(ISO8601DateFormatter().date(from: savedAt) != nil, "Invalid recovery save date.")
        let value = try ProjectDocument(data: JSONEncoder().encode(project))
        try value.validateDrawingEvidence(in: drawings)
        return value
    }
}

/// Atomic local recovery with a per-scope interprocess lock and revision comparison.
/// The caller supplies an authorized account scope; this store is not an authentication service.
public actor WorkspaceRecoveryStore {
    public static let shared = WorkspaceRecoveryStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LoadSightRecovery", isDirectory: true))
    private let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func load(scope: String) throws -> WorkspaceRecoveryDraft? {
        try locked(scope: scope) { url, digest in try read(url, digest: digest) }
    }
    public func save(project: ProjectDocument, drawings: DrawingArchive, scope: String, expectedRevision: UUID?) throws -> WorkspaceRecoveryDraft {
        try project.validateDrawingEvidence(in: drawings)
        return try locked(scope: scope) { url, digest in
            let existing = try read(url, digest: digest)
            try require(existing?.revision == expectedRevision, "Another window changed this recovery draft. Export your current project, then reopen the workspace to review the saved draft.")
            var normalized = project.root.object!
            normalized["nativeDrawings"] = .null
            let draft = WorkspaceRecoveryDraft(version: 1, revision: UUID(), scopeDigest: digest, savedAt: Date().ISO8601Format(), project: .object(normalized), drawings: drawings)
            let data = try JSONEncoder().encode(draft)
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            #else
            try data.write(to: url, options: .atomic)
            #endif
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return draft
        }
    }
    public func remove(scope: String, expectedRevision: UUID?) throws {
        try locked(scope: scope) { url, digest in
            let existing = try read(url, digest: digest)
            try require(existing?.revision == expectedRevision, "The recovery draft changed in another window and was not removed.")
            if existing != nil { try FileManager.default.removeItem(at: url) }
        }
    }
    private func read(_ url: URL, digest: String) throws -> WorkspaceRecoveryDraft? {
        guard FileManager.default.fileExists(atPath: url.path) || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        try require(values.isRegularFile == true && values.isSymbolicLink != true, "Recovery storage is not a regular local file.")
        let draft = try JSONDecoder().decode(WorkspaceRecoveryDraft.self, from: Data(contentsOf: url))
        try require(draft.scopeDigest == digest, "The recovery draft belongs to another account scope.")
        _ = try draft.restoredProject()
        return draft
    }
    private func locked<T>(scope: String, operation: (URL, String) throws -> T) throws -> T {
        try require(!scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Recovery requires an explicit account scope.")
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        try require(values.isDirectory == true && values.isSymbolicLink != true, "Recovery storage must be a local directory.")
        let digest = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        let lockURL = directory.appendingPathComponent(digest + ".lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw LoadSightError.invalid("Unable to open the local recovery lock.") }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw LoadSightError.invalid("Unable to lock local recovery storage.") }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation(directory.appendingPathComponent(digest + ".json"), digest)
    }
}
