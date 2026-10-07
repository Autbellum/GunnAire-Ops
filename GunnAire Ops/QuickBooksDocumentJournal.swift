import Foundation
import CryptoKit
import SwiftData

nonisolated struct QBODocumentOwner: Codable, Equatable, Sendable {
    let companyID: UUID
    let backendOrigin: String
    let actorEmail: String
    var storageKey: String { CompanyWorkspaceSession.digest([companyID.uuidString.lowercased(), backendOrigin, actorEmail].joined(separator: "\n")) }
    func validate() throws {
        guard let url = URL(string: backendOrigin), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              backendOrigin.utf8.count <= 2048, actorEmail == AppAccess.normalizedEmail(actorEmail),
              actorEmail.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil,
              actorEmail.utf8.count <= 254 else { throw QBODocumentError.access }
    }
    @MainActor static func capture(context: ModelContext) throws -> Self {
        let controller = CompanyWorkspaceAccessController.shared
        guard controller.authorizedContainer === context.container, let company = controller.verifiedCompanyID,
              let session = CompanyWorkspaceSession.current,
              QuickBooksSyncAccessPolicy.allows(email: session.email,
                users: try context.fetch(FetchDescriptor<AppUser>()), verifiedRole: controller.verifiedRole) else { throw QBODocumentError.access }
        let owner = Self(companyID: company, backendOrigin: session.backendOrigin, actorEmail: session.email)
        try owner.validate(); return owner
    }

    /// Captures only the server-verified workspace identity. Callers that use
    /// this for an asynchronous read must validate the local AppUser replica
    /// in a private context and recapture this identity after suspension.
    @MainActor static func captureForBackgroundRead(context: ModelContext) throws -> Self {
        let controller = CompanyWorkspaceAccessController.shared
        guard controller.authorizedContainer === context.container,
              let company = controller.verifiedCompanyID,
              let user = controller.verifiedUser, user.isActive,
              controller.verifiedRole == .admin,
              let session = CompanyWorkspaceSession.current,
              AppAccess.normalizedEmail(user.email) == AppAccess.normalizedEmail(session.email),
              !context.insertedModelsArray.contains(where: { $0 is AppUser }),
              !context.changedModelsArray.contains(where: { $0 is AppUser }),
              !context.deletedModelsArray.contains(where: { $0 is AppUser }) else {
            throw QBODocumentError.access
        }
        let owner = Self(companyID: company, backendOrigin: session.backendOrigin, actorEmail: session.email)
        try owner.validate()
        return owner
    }
}

/// Portable local identity, including invoices that have no operational job.
/// No path is persisted, so a reloaded file must still match its saved bytes.
nonisolated struct QBODocumentLocalAttachment: Codable, Equatable, Sendable {
    let attachmentID: UUID
    let customerID: UUID
    let customerQuickBooksID: String
    let serviceCallID: UUID?
    let invoiceID: UUID?
    let estimateID: UUID?
    let kind: String

    func validate(targets: [QBODocumentTarget], job: QBODocumentJob?) throws {
        guard QBODocumentScope.reference(customerQuickBooksID), !targets.isEmpty,
              ServiceDocumentAttachmentKind(rawValue: kind) != nil,
              targets.allSatisfy({ ($0.type == "Invoice" && invoiceID != nil) || ($0.type == "Estimate" && estimateID != nil) })
        else { throw QBODocumentError.invalid }
        if let job {
            guard attachmentID == job.attachmentID, customerID == job.localCustomerID,
                  customerQuickBooksID == job.customerQuickBooksID, serviceCallID == job.serviceCallID, kind == job.kind,
                  job.documents.allSatisfy({ $0.localID == ($0.type == "Invoice" ? invoiceID : estimateID) })
            else { throw QBODocumentError.invalid }
        } else if serviceCallID != nil { throw QBODocumentError.invalid }
    }
}

/// File, destination and local handoff never change after capture. This record
/// contains no tokens or device paths and remains scoped after logout.
nonisolated struct QBODocumentCapture: Codable, Equatable, Identifiable, Sendable {
    var version = 1
    let id: UUID // Stable client operation, not the server's deduplicated ID.
    let owner: QBODocumentOwner
    let scope: QBODocumentScope
    let file: QBODocumentFileInfo
    let targets: [QBODocumentTarget]
    let jobDocument: QBODocumentJob?
    let createdAt: Date
    var revision = 0
    var connectionRevision: String?
    var server: QBODocumentUploadRecord?
    var dispatchStarted = false
    var cancelledLocally = false
    var localAttachment: QBODocumentLocalAttachment? = nil
    var localAppliedAt: Date? = nil
    // A downloaded copy preserves the server's original operation and intent.
    // It never invents the original device's connection revision or authorship.
    var sharedSource: QBODocumentUploadRecord? = nil

    var needsLocalApplication: Bool {
        server?.state == .confirmed && (localAttachment != nil || jobDocument != nil) && localAppliedAt == nil
    }

    var status: String {
        if cancelledLocally { return "Cancelled — original retained" }
        if needsLocalApplication { return "Saved in QuickBooks — finish local link" }
        if dispatchStarted, server?.state == .reserved { return "Check original upload" }
        return server?.status ?? (connectionRevision == nil ? "Saved on this device" : "Check saved reservation")
    }
    var needsAttention: Bool { needsLocalApplication || (!cancelledLocally && (server.map { ![QBODocumentState.confirmed, .cancelled].contains($0.state) } ?? true)) }
    func sameOriginal(as other: Self) -> Bool {
        version == other.version && id == other.id && owner == other.owner && scope == other.scope &&
        file == other.file && targets == other.targets && jobDocument == other.jobDocument && createdAt == other.createdAt &&
        localAttachment == other.localAttachment && sharedSource == other.sharedSource
    }
    func validate() throws {
        try owner.validate(); try scope.validate(); try file.validate(); try jobDocument?.validate(targets: targets)
        try localAttachment?.validate(targets: targets, job: jobDocument)
        if let applied = localAppliedAt {
            guard server?.state == .confirmed, localAttachment != nil || jobDocument != nil,
                  applied.timeIntervalSince1970.isFinite, applied >= createdAt else { throw QBODocumentError.storage }
        }
        guard version == 1, owner.companyID == scope.companyID, revision >= 0, revision < Int.max,
              createdAt.timeIntervalSince1970.isFinite, try QBODocumentTarget.normalized(targets) == targets,
              connectionRevision.map(JobBillingAssignmentSnapshot.validConnectionRevision) ?? true,
              !dispatchStarted || server != nil, server == nil || connectionRevision != nil || sharedSource != nil else { throw QBODocumentError.storage }
        if let source = sharedSource {
            guard id == source.operationID, let server else { throw QBODocumentError.storage }
            try server.validateUpdate(from: source)
        }
        if let server {
            try server.validate(scope)
            guard server.file == file, server.targets == targets, server.jobDocument == jobDocument else { throw QBODocumentError.storage }
        }
    }
}

/// MainActor serialization + compare-and-set revisions protect multiple app
/// windows. An authenticated header supports listing without decrypting files.
/// Updating state retains the exact original ciphertext; one atomic replace
/// publishes the header and original together, with no half-written journal.
@MainActor struct QBODocumentCaptureStore {
    /// Header reads, listings and original decryption run on background tasks;
    /// no journal decryption, Keychain read or file I/O blocks the main actor.
    let read: (QBODocumentOwner, UUID) async throws -> QBODocumentCapture?
    let list: (QBODocumentOwner) async throws -> [QBODocumentCapture]
    let bytes: (QBODocumentOwner, UUID) async throws -> Data
    /// Compare-and-set writes, serialized with every other write to the same
    /// journal directory on one `QBOJournalWriter` actor (off the main actor).
    let write: (QBODocumentCapture, Int?, Data?) async throws -> Void
    /// Creates a new row against a listing. On the same serial writer it first
    /// checks only the journal's file names (no decryption, no Keychain read)
    /// and fails `.changed` if any row was added or removed since that listing.
    /// Because every write in this process goes through that one writer, the
    /// check and the write are atomic with respect to all other journal writes
    /// in this process, so a stale listing can never create a duplicate
    /// capture. There is no cross-process lock; none is needed while the app
    /// has no extension or second process writing this journal (the background
    /// retained-media reader only reads).
    let insert: (QBODocumentCapture, Data, [QBODocumentCapture]) async throws -> Void

    static func encrypted(directory: URL, key: @escaping @Sendable (Bool) throws -> Data) -> Self {
        let journal = QBOEncryptedCaptureJournal(directory: directory, key: key)
        let writer = QBOJournalWriters.writer(for: directory)
        return Self(read: { owner, id in
                        try await Task.detached(priority: .userInitiated) { try journal.header(owner, id)?.0 }.value
                    },
                    list: { owner in
                        try await Task.detached(priority: .userInitiated) { try journal.list(owner) }.value
                    },
                    bytes: { owner, id in
                        try await Task.detached(priority: .userInitiated) { try journal.bytes(owner, id) }.value
                    },
                    write: { row, expected, original in
                        try await writer.write(journal, row, expected: expected, original: original, knownRows: nil)
                    },
                    insert: { row, original, known in
                        try await writer.write(journal, row, expected: nil, original: original, knownRows: known)
                    })
    }

    static var device: Self {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return .init(read: { _, _ in throw QBODocumentError.storage }, list: { _ in throw QBODocumentError.storage },
                         bytes: { _, _ in throw QBODocumentError.storage }, write: { _, _, _ in throw QBODocumentError.storage },
                         insert: { _, _, _ in throw QBODocumentError.storage })
        }
        return encrypted(directory: root.appendingPathComponent("QBOOriginalFiles-v1", isDirectory: true)) { create in
            let account = "QBOOriginalFileEncryption-v1"
            if let data = try KeychainStore.loadCodable(Data.self, account: account) { return data }
            guard create else { throw QBODocumentError.storage }
            let data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try KeychainStore.saveCodable(data, account: account); return data
        }
    }
}

/// The encrypted journal's file format and cryptography with no actor
/// isolation, so a bounded listing can run off the main actor. Main-actor
/// callers reach the same functions synchronously through the store above.
nonisolated struct QBOEncryptedCaptureJournal: Sendable {
    static let magic = Data("GAFILE1\n".utf8)
    let directory: URL
    let key: @Sendable (Bool) throws -> Data

    func folder(_ owner: QBODocumentOwner) -> URL { directory.appendingPathComponent(owner.storageKey, isDirectory: true) }
    func file(_ owner: QBODocumentOwner, _ id: UUID) -> URL { folder(owner).appendingPathComponent(id.uuidString.lowercased() + ".sealed") }
    func aad(_ owner: QBODocumentOwner, _ id: UUID, _ part: String) -> Data { Data((owner.storageKey + "/" + id.uuidString.lowercased() + "/" + part).utf8) }
    func secret(_ create: Bool) throws -> SymmetricKey {
        let data = try key(create)
        guard data.count == 32 else { throw QBODocumentError.storage }
        return SymmetricKey(data: data)
    }

    /// `cached` lets a listing read the key once instead of once per row.
    func header(_ owner: QBODocumentOwner, _ id: UUID, key cached: SymmetricKey? = nil) throws -> (QBODocumentCapture, Int)? {
        try owner.validate()
        let url = file(owner, id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let properties = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isRegularFile == true, properties.isSymbolicLink != true,
                  (properties.fileSize ?? Int.max) <= QBODocumentFileInfo.maximum + 65_536 else { throw QBODocumentError.storage }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard let prefix = try handle.read(upToCount: 12), prefix.count == 12, prefix.prefix(8) == Self.magic else { throw QBODocumentError.storage }
            let size = prefix.suffix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard (28...32_768).contains(size), let encrypted = try handle.read(upToCount: size), encrypted.count == size else { throw QBODocumentError.storage }
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: cached ?? secret(false), authenticating: aad(owner, id, "metadata"))
            let row = try JSONDecoder().decode(QBODocumentCapture.self, from: plain)
            try row.validate()
            guard row.owner == owner, row.id == id, properties.fileSize == 12 + size + row.file.size + 28 else { throw QBODocumentError.storage }
            return (row, 12 + size)
        } catch { throw QBODocumentError.storage }
    }

    func payload(_ owner: QBODocumentOwner, _ id: UUID, offset: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file(owner, id))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: QBODocumentFileInfo.maximum + 29), data.count <= QBODocumentFileInfo.maximum + 28 else { throw QBODocumentError.storage }
        return data
    }

    /// Row IDs from file names only: no decryption and no Keychain read.
    func sealedIDs(_ owner: QBODocumentOwner) throws -> Set<UUID> {
        try owner.validate()
        guard FileManager.default.fileExists(atPath: folder(owner).path) else { return [] }
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: folder(owner), includingPropertiesForKeys: nil).filter { $0.pathExtension == "sealed" }
            guard urls.count <= 512 else { throw QBODocumentError.limit }
            return Set(try urls.map { url in
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      url.lastPathComponent == id.uuidString.lowercased() + ".sealed" else { throw QBODocumentError.storage }
                return id
            })
        } catch let error as QBODocumentError { throw error }
        catch { throw QBODocumentError.storage }
    }

    func list(_ owner: QBODocumentOwner) throws -> [QBODocumentCapture] {
        let ids = try sealedIDs(owner)
        guard !ids.isEmpty else { return [] }
        let key: SymmetricKey
        do { key = try secret(false) } catch { throw QBODocumentError.storage }
        return try ids.map { id in
            guard let (row, _) = try header(owner, id, key: key) else { throw QBODocumentError.storage }
            return row
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func bytes(_ owner: QBODocumentOwner, _ id: UUID) throws -> Data {
        do {
            guard let (row, offset) = try header(owner, id) else { throw QBODocumentError.storage }
            let data = try AES.GCM.open(AES.GCM.SealedBox(combined: payload(owner, id, offset: offset)),
                                        using: secret(false), authenticating: aad(owner, id, "file"))
            try row.file.verify(data); return data
        } catch { throw QBODocumentError.storage }
    }

    /// `knownRows` (new rows only) replaces the decrypting re-list with a
    /// name-only check that the journal still holds exactly those rows.
    func write(_ row: QBODocumentCapture, expected: Int?, original: Data?, knownRows: [QBODocumentCapture]?) throws {
        try row.validate()
        let previous = try header(row.owner, row.id)
        guard previous?.0.revision == expected, row.revision == (expected.map { $0 + 1 } ?? 0) else { throw QBODocumentError.changed }
        if let old = previous?.0 {
            guard original == nil, row.sameOriginal(as: old), !old.cancelledLocally,
                  old.connectionRevision == nil || row.connectionRevision == old.connectionRevision,
                  old.localAppliedAt == nil || row.localAppliedAt == old.localAppliedAt,
                  !old.dispatchStarted || row.dispatchStarted else { throw QBODocumentError.changed }
            if let saved = old.server {
                guard let next = row.server, next.matchesOriginal(saved),
                      saved.state != .confirmed || (next.state == .confirmed && next.providerID == saved.providerID),
                      saved.state != .cancelled || next.state == .cancelled,
                      ![.sending, .uncertain].contains(saved.state) || [.sending, .uncertain, .confirmed].contains(next.state)
                else { throw QBODocumentError.changed }
                try next.validateUpdate(from: saved)
            }
        } else {
            guard row.revision == 0, row.connectionRevision == nil, !row.cancelledLocally, row.localAppliedAt == nil,
                  let original else { throw QBODocumentError.changed }
            if let source = row.sharedSource {
                guard row.server == source,
                      row.dispatchStarted == [.sending, .uncertain, .confirmed].contains(source.state)
                else { throw QBODocumentError.changed }
            } else {
                guard row.server == nil, !row.dispatchStarted else { throw QBODocumentError.changed }
            }
            try row.file.verify(original)
            let rows: [QBODocumentCapture]
            if let knownRows {
                guard try sealedIDs(row.owner) == Set(knownRows.map(\.id)) else { throw QBODocumentError.changed }
                rows = knownRows
            } else {
                rows = try list(row.owner)
            }
            guard rows.count < 512, rows.reduce(row.file.size, { $0 + $1.file.size }) <= 512 * 1024 * 1024 else { throw QBODocumentError.limit }
        }
        do {
            let key = try secret(!FileManager.default.fileExists(atPath: directory.path))
            let sealedBytes: Data
            if let original {
                guard let data = try AES.GCM.seal(original, using: key, authenticating: aad(row.owner, row.id, "file")).combined else { throw QBODocumentError.storage }
                sealedBytes = data
            } else if let previous { sealedBytes = try payload(row.owner, row.id, offset: previous.1) }
            else { throw QBODocumentError.storage }
            guard let sealedHeader = try AES.GCM.seal(JSONEncoder().encode(row), using: key,
                    authenticating: aad(row.owner, row.id, "metadata")).combined, sealedHeader.count <= 32_768 else { throw QBODocumentError.storage }
            var count = UInt32(sealedHeader.count).bigEndian
            var output = Self.magic
            withUnsafeBytes(of: &count) { output.append(contentsOf: $0) }
            output.append(sealedHeader); output.append(sealedBytes)
            try FileManager.default.createDirectory(at: folder(row.owner), withIntermediateDirectories: true)
            var root = directory; var resource = URLResourceValues(); resource.isExcludedFromBackup = true
            try root.setResourceValues(resource)
            try output.write(to: file(row.owner, row.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch let error as QBODocumentError { throw error }
        catch { throw QBODocumentError.storage }
    }
}

/// One serial writer per journal directory for this process. Every
/// compare-and-set update and every new-row insert for that journal runs here,
/// off the main actor, so check-then-write sequences never interleave.
actor QBOJournalWriter {
    func write(_ journal: QBOEncryptedCaptureJournal, _ row: QBODocumentCapture, expected: Int?,
               original: Data?, knownRows: [QBODocumentCapture]?) throws {
        try journal.write(row, expected: expected, original: original, knownRows: knownRows)
    }
}

nonisolated enum QBOJournalWriters {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var writers: [String: QBOJournalWriter] = [:]

    static func writer(for directory: URL) -> QBOJournalWriter {
        let key = directory.standardizedFileURL.resolvingSymlinksInPath().path
        lock.lock(); defer { lock.unlock() }
        if let existing = writers[key] { return existing }
        let created = QBOJournalWriter()
        writers[key] = created
        return created
    }
}

/// A new instance can resume the same local capture after relaunch. A failed
/// reservation can only repeat its original immutable operation, while a
/// dispatched upload must be checked, never automatically sent again.
///
/// `check` is the caller's workspace + exact local identity fence. It runs
/// before every journal update and around every network request, and is
/// re-run after each suspension, so a change made while awaiting stops the
/// operation before any further provider write.
@MainActor final class QBODocumentCaptureSession {
    private(set) var record: QBODocumentCapture
    let store: QBODocumentCaptureStore
    let check: () async throws -> Void
    init(record: QBODocumentCapture, store: QBODocumentCaptureStore, check: @escaping () async throws -> Void) async throws {
        self.record = record; self.store = store; self.check = check
        try await verify()
    }
    /// The saved row must be unchanged; the caller's fence runs last so its
    /// own post-await rechecks are the final word before the next step.
    func verify() async throws {
        guard try await store.read(record.owner, record.id) == record else { throw QBODocumentError.changed }
        try await check()
    }
    private func save(_ next: QBODocumentCapture) async throws {
        try await verify(); var next = next; next.revision += 1
        try await store.write(next, record.revision, nil); record = next
    }
    private func accept(_ value: QBODocumentUploadRecord) async throws {
        try value.validate(record.scope)
        guard value.file == record.file, value.targets == record.targets, value.jobDocument == record.jobDocument else { throw QBODocumentError.invalid }
        var next = record; next.server = value
        try await save(next)
    }
    /// Incorporate a fresh read of the same server original, not a new proposal.
    func observe(_ value: QBODocumentUploadRecord) async throws {
        try await verify()
        guard let original = record.server else { throw QBODocumentError.changed }
        try value.validateUpdate(from: original)
        try await accept(value)
    }
    func send(client: QBODocumentUploadClient) async throws {
        try await verify()
        guard !record.cancelledLocally, !record.dispatchStarted else { throw QBODocumentError.review }
        if record.server == nil {
            let page = try await client.page(record.scope, operationID: record.id)
            try await verify()
            if let saved = page.uploads.first {
                guard record.connectionRevision != nil else { throw QBODocumentError.invalid }
                try await accept(saved)
            } else {
                if record.connectionRevision == nil {
                    guard let revision = page.connectionRevision else { throw QBODocumentError.access }
                    var next = record; next.connectionRevision = revision; try await save(next)
                }
                guard let revision = record.connectionRevision else { throw QBODocumentError.invalid }
                let original = try await store.bytes(record.owner, record.id)
                try await verify()
                let request = QBODocumentUploadRequest(companyID: record.scope.companyID, realmID: record.scope.realmID, environment: record.scope.environment,
                    operationID: record.id, connectionRevision: revision, file: .init(filename: record.file.filename, contentType: record.file.contentType, data: original),
                    targets: record.targets, jobDocument: record.jobDocument)
                let reserved = try await client.reserve(request)
                try await verify(); try await accept(reserved)
            }
        }
        guard let server = record.server else { throw QBODocumentError.invalid }
        if server.state == .confirmed { return }
        guard server.state == .reserved, !server.connectionChanged else { throw QBODocumentError.review }
        // Commit local uncertainty before the request can leave the device.
        var next = record; next.dispatchStarted = true; try await save(next)
        let result = try await client.action(.send, original: server)
        try await verify(); try await accept(result)
    }
    func recover(client: QBODocumentUploadClient) async throws {
        try await verify(); guard !record.cancelledLocally else { throw QBODocumentError.review }
        if let original = record.server {
            let value = try await client.action(.recover, original: original)
            try await verify(); try await accept(value)
        } else if record.connectionRevision != nil {
            let page = try await client.page(record.scope, operationID: record.id)
            try await verify()
            if let value = page.uploads.first { try await accept(value) }
        }
    }
    /// Call only after the original model's receipt was saved. A failed journal
    /// acknowledgement keeps the file visible for safe, idempotent application.
    func markLocalApplied() async throws {
        try await verify()
        guard record.needsLocalApplication else { return }
        var next = record; next.localAppliedAt = Date(); try await save(next)
    }
    func cancel(client: QBODocumentUploadClient) async throws {
        try await verify()
        guard !record.cancelledLocally else { return }
        guard !record.dispatchStarted else { throw QBODocumentError.review }
        if record.server == nil, record.connectionRevision != nil {
            try await recover(client: client)
            guard record.server != nil else { throw QBODocumentError.review }
        }
        if let original = record.server {
            let value = try await client.action(.cancel, original: original)
            try await verify(); try await accept(value)
        } else {
            var next = record; next.cancelledLocally = true; try await save(next)
        }
    }
}
