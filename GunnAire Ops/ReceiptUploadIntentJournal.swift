import Foundation

/// Only opaque scope/request digests and operation IDs are persisted. Receipt
/// bytes, customer metadata and credentials never enter this journal.
actor ReceiptUploadIntentJournal {
    static let device = ReceiptUploadIntentJournal(directory: FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("ReceiptUploadIntents-v1", isDirectory: true))
    enum Failure: LocalizedError {
        case storage, busy, pending
        var errorDescription: String? {
            switch self {
            case .storage: "The retained receipt upload could not be verified. No new upload was sent."
            case .busy: "This receipt upload is already being checked."
            case .pending: "An earlier receipt upload is unresolved. Select that original receipt and job again to recover it before starting another receipt."
            }
        }
    }
    struct Record: Codable, Equatable, Sendable {
        let scope: String
        let operation: UUID
        var fingerprint: String?
        var confirmed: Bool
    }
    private let directory: URL?
    private var active: Set<String> = []
    init(directory: URL?) { self.directory = directory }

    nonisolated static func scope(origin: String, email: String) -> String {
        CompanyWorkspaceSession.digest(origin + "\n" + email)
    }
    func begin(scope: String, fingerprint: String) throws -> UUID {
        guard !active.contains(scope) else { throw Failure.busy }
        guard valid(fingerprint) else { throw Failure.storage }
        let prior = try read(scope)
        if let prior, let original = prior.fingerprint {
            if original == fingerprint { active.insert(scope); return prior.operation }
            guard prior.confirmed else { throw Failure.pending }
        }
        let operation = prior?.fingerprint == nil ? (prior?.operation ?? UUID()) : UUID()
        try write(Record(scope: scope, operation: operation, fingerprint: fingerprint, confirmed: false))
        active.insert(scope)
        return operation
    }
    func confirm(scope: String, operation: UUID) throws {
        guard active.contains(scope), var value = try read(scope), value.operation == operation,
              value.fingerprint != nil else { throw Failure.storage }
        value.confirmed = true
        try write(value)
    }
    func release(scope: String) { active.remove(scope) }
    /// Explicit new intent permits two legitimate receipts with identical bytes.
    /// An unresolved write can never be discarded by this action.
    func startNew(scope: String) throws {
        guard !active.contains(scope) else { throw Failure.busy }
        if let prior = try read(scope), prior.fingerprint != nil, !prior.confirmed { throw Failure.pending }
        try write(Record(scope: scope, operation: UUID(), fingerprint: nil, confirmed: false))
    }
    private func valid(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private func file(_ scope: String) throws -> URL {
        guard valid(scope), let directory else { throw Failure.storage }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else { throw Failure.storage }
        return directory.appendingPathComponent(scope + ".json")
    }
    private func read(_ scope: String) throws -> Record? {
        let url = try file(scope)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) < 4096 else { throw Failure.storage }
        let value = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
        guard value.scope == scope, value.fingerprint.map(valid) ?? !value.confirmed else { throw Failure.storage }
        return value
    }
    private func write(_ value: Record) throws {
        let url = try file(value.scope)
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        guard try read(value.scope) == value else { throw Failure.storage }
    }
}
