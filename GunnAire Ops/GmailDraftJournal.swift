import Foundation
import CryptoKit
import SwiftData

enum GmailDraftError: LocalizedError, Equatable {
    case storage, changed, access, locked, limit, businessChanged
    var errorDescription: String? {
        switch self {
        case .storage: "Your draft could not be saved or verified. Keep this message open and try again. Existing drafts have not been cleared."
        case .changed: "This draft changed in another window. Close and reopen the original draft before editing."
        case .access: "Verify access to the original business and Google account before opening this draft."
        case .locked: "This message may already have been sent. Review Sent; another copy will not be sent from this draft."
        case .limit: "This device's draft storage is full. Keep this message open and review your saved drafts."
        case .businessChanged: "The linked customer or work changed after this draft was saved. Review the original customer, job or billing document and prepare an updated message. This draft was not sent."
        }
    }
}

struct GmailDraftScope: Codable, Equatable {
    let companyID: UUID
    let backendOrigin: String
    let actorEmail: String
    let googleEmail: String

    var storageKey: String {
        CompanyWorkspaceSession.digest([companyID.uuidString.lowercased(), backendOrigin, actorEmail, googleEmail].joined(separator: "\n"))
    }

    func validate() throws {
        guard let url = URL(string: backendOrigin), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              actorEmail == AppAccess.normalizedEmail(actorEmail), actorEmail == googleEmail,
              (try? GmailAddressList.parse(actorEmail)) == [actorEmail] else { throw GmailDraftError.access }
    }

    @MainActor static func capture(auth: GoogleAuthManager, context: ModelContext) throws -> Self {
        let controller = CompanyWorkspaceAccessController.shared
        guard controller.authorizedContainer === context.container,
              let company = controller.verifiedCompanyID,
              auth.canUseCurrentBusinessIdentity else { throw GmailDraftError.access }
        let scope = Self(companyID: company, backendOrigin: Config.Backend.normalizedBaseURL,
            actorEmail: AppAccess.normalizedEmail(AppIdentity.currentEmail), googleEmail: AppAccess.normalizedEmail(auth.signedInEmail))
        try scope.validate()
        return scope
    }
    @MainActor static func captureCompany(context: ModelContext) throws -> Self {
        let controller = CompanyWorkspaceAccessController.shared
        guard controller.authorizedContainer === context.container, let company = controller.verifiedCompanyID,
              let session = CompanyWorkspaceSession.current else { throw GmailDraftError.access }
        let scope = Self(companyID: company, backendOrigin: session.backendOrigin,
                         actorEmail: session.email, googleEmail: session.email)
        try scope.validate(); return scope
    }
}

struct GmailDraftFile: Codable, Equatable {
    let name: String
    let mimeType: String
    let data: Data
    init(_ file: GmailAttachment) { name = file.fileName; mimeType = file.mimeType; data = file.data }
    var attachment: GmailAttachment { .init(fileName: name, mimeType: mimeType, data: data) }
}

/// Incomplete addresses and subjects remain editable drafts. Sending still
/// uses GmailOutgoingMessage validation and the current business/consent gate.
struct GmailDraftContent: Codable, Equatable {
    var to: String
    var subject: String
    var body: String
    var files: [GmailDraftFile] = []
    var reply: GmailReplyContext?
    var business: GmailBusinessContext?
    var requiresBusinessContext = false
    var attachmentError: String?
    var businessSnapshot: [String]?

    var hasContent: Bool { !to.isEmpty || !subject.isEmpty || !body.isEmpty || !files.isEmpty || attachmentError != nil }
    func validate() throws {
        guard to.utf8.count <= 16_384, subject.utf8.count <= 16_384, body.utf8.count <= 2 * 1024 * 1024,
              (attachmentError?.utf8.count ?? 0) <= 4096 else { throw GmailDraftError.limit }
        try GmailOutgoingMessage.validateAttachments(files.map(\.attachment))
        guard (businessSnapshot?.count ?? 0) <= 100,
              (businessSnapshot?.reduce(0) { $0 + $1.utf8.count } ?? 0) <= 2 * 1024 * 1024 else { throw GmailDraftError.limit }
        if let reply {
            guard GoogleAuthManager.calendarPathComponent(reply.threadID) != nil,
                  GmailReplyContext.isValidMessageID(reply.messageID), reply.references.count <= 50,
                  reply.references.allSatisfy(GmailReplyContext.isValidMessageID), reply.subject.utf8.count <= 16_384 else {
                throw GmailDraftError.storage
            }
        }
    }
}

/// Stable domain values, never process-specific object identifiers. A reopened
/// draft cannot adopt changed sold prices, contact consent or linked work just
/// because the new send coordinator captured a fresh in-memory baseline.
enum GmailDraftBusinessSnapshot {
    static func capture(_ business: GmailBusinessContext?, context: ModelContext) throws -> [String]? {
        guard let business else { return nil }
        let customers = try context.fetch(FetchDescriptor<Customer>()).filter { $0.id == business.customerID }
        guard customers.count == 1 else { throw GmailDraftError.businessChanged }
        let customer = customers[0]
        var values = [customer.id.uuidString, customer.name, customer.email ?? "", customer.address ?? "",
            String(customer.allowsTransactionalEmail), String(customer.allowsMarketing), customer.communicationConsentUpdatedAt?.description ?? ""]
        if let id = business.serviceCallID {
            let rows = try context.fetch(FetchDescriptor<ServiceCall>()).filter { $0.id == id }
            guard rows.count == 1, rows[0].customer === customer else { throw GmailDraftError.businessChanged }
            let row = rows[0]
            values += [id.uuidString, row.status.rawValue, row.eventTitle ?? "", row.scheduledDate.description,
                String(row.duration), row.notes ?? "", row.assignedTechnician?.id.uuidString ?? "", row.additionalTechnicianIDsJSON ?? ""]
        }
        if let id = business.invoiceID {
            let rows = try context.fetch(FetchDescriptor<Invoice>()).filter { $0.id == id }
            guard rows.count == 1, rows[0].customer === customer else { throw GmailDraftError.businessChanged }
            let row = rows[0]
            values += [id.uuidString, row.status, String(row.amount), String(describing: row.quickBooksBalanceDue),
                row.catalogSnapshotJSON ?? "", row.quickBooksID ?? "", row.serviceCallID?.uuidString ?? ""]
        }
        if let id = business.estimateID {
            let rows = try context.fetch(FetchDescriptor<Estimate>()).filter { $0.id == id }
            guard rows.count == 1, rows[0].customer === customer else { throw GmailDraftError.businessChanged }
            let row = rows[0]
            values += [id.uuidString, row.status, String(row.amount), row.catalogSnapshotJSON ?? "", row.quickBooksID ?? "", row.serviceCallID?.uuidString ?? ""]
        }
        if let id = business.maintenanceContractID {
            let rows = try context.fetch(FetchDescriptor<RecurringMaintenanceContract>()).filter { $0.id == id }
            guard rows.count == 1, rows[0].customer === customer else { throw GmailDraftError.businessChanged }
            values += [id.uuidString, String(rows[0].active)]
        }
        return values
    }
}

enum GmailDraftState: String, Codable { case editing, sending, review, sent, discarded }

struct GmailServerDraftAttempt: Codable, Equatable {
    let id: UUID
    let scope: GmailServerScope
}

/// Constructed only after the original server content, identity and result have
/// been checked below. Generic draft writes cannot manufacture this transition.
fileprivate struct GmailServerDraftResolution: Codable, Equatable {
    let attempt: GmailServerDraftAttempt
    let state: GmailServerOperationState
}

struct GmailDraftRecord: Codable, Equatable, Identifiable {
    var version = 1
    let id: UUID
    let scope: GmailDraftScope
    var revision = 0
    var content: GmailDraftContent
    var state: GmailDraftState = .editing
    var updatedAt = Date()
    var status: String?
    var serverAttempt: GmailServerDraftAttempt?
    var retiredServerAttempts: [GmailServerDraftAttempt]?
    fileprivate var serverResolution: GmailServerDraftResolution?
    init(id: UUID, scope: GmailDraftScope, content: GmailDraftContent) {
        self.id = id; self.scope = scope; self.content = content
    }
    var messageID: String { "<gunnaire-\((serverAttempt?.id ?? id).uuidString.lowercased())@gunnaire.com>" }
    var editable: Bool { state == .editing }
    func validate() throws {
        try scope.validate(); try content.validate()
        guard version == 1, revision >= 0, revision < Int.max, updatedAt.timeIntervalSince1970.isFinite,
              (status?.utf8.count ?? 0) <= 4096 else { throw GmailDraftError.storage }
        let attempts = (retiredServerAttempts ?? []) + (serverAttempt.map { [$0] } ?? [])
        guard attempts.count <= 100, Set(attempts.map(\.id)).count == attempts.count,
              attempts.allSatisfy({ $0.scope.draftScope == scope }) else { throw GmailDraftError.storage }
        if let serverResolution, !attempts.contains(serverResolution.attempt) { throw GmailDraftError.storage }
    }
}

struct GmailDraftSummary: Identifiable, Codable, Equatable {
    let id: UUID
    let subject: String
    let recipient: String
    let state: GmailDraftState
    let updatedAt: Date
    let business: GmailBusinessContext?
}

private struct GmailDraftIndex: Codable, Equatable {
    let revision: Int
    let summary: GmailDraftSummary
    init(_ record: GmailDraftRecord) {
        revision = record.revision
        summary = .init(id: record.id, subject: record.content.subject, recipient: record.content.to,
            state: record.state, updatedAt: record.updatedAt, business: record.content.business)
    }
}

/// All in-process readers/writers serialize on MainActor. CAS revisions prevent
/// stale windows from replacing content or unlocking an already-started send.
/// Individual encrypted files avoid rewriting every attachment on each edit.
@MainActor struct GmailDraftStore {
    let read: (GmailDraftScope, UUID) throws -> GmailDraftRecord?
    let write: (GmailDraftRecord, Int?) throws -> Void
    let list: (GmailDraftScope) throws -> [GmailDraftSummary]

    static func encrypted(directory: URL, activeDraftLimit: Int = 512, key: @escaping (Bool) throws -> Data) -> Self {
        func folder(_ scope: GmailDraftScope) -> URL { directory.appendingPathComponent(scope.storageKey, isDirectory: true) }
        func file(_ scope: GmailDraftScope, _ id: UUID) -> URL { folder(scope).appendingPathComponent(id.uuidString.lowercased() + ".sealed") }
        func aad(_ scope: GmailDraftScope, _ id: UUID) -> Data { Data((scope.storageKey + "/" + id.uuidString.lowercased()).utf8) }
        let magic = Data("GAMAIL1\n".utf8)
        func index(_ scope: GmailDraftScope, _ id: UUID, using secret: SymmetricKey) throws -> (GmailDraftIndex, Int) {
            let url = file(scope, id)
            let resource = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard resource.isRegularFile == true, resource.isSymbolicLink != true,
                  (resource.fileSize ?? Int.max) <= 40 * 1024 * 1024 + 65536 else { throw GmailDraftError.storage }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard let header = try handle.read(upToCount: 12), header.count == 12,
                  header.prefix(8) == magic else { throw GmailDraftError.storage }
            let size = header.suffix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard (28...65536).contains(size), let data = try handle.read(upToCount: size), data.count == size else { throw GmailDraftError.storage }
            let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: secret,
                authenticating: aad(scope, id) + Data("/index".utf8))
            let value = try JSONDecoder().decode(GmailDraftIndex.self, from: plaintext)
            guard value.summary.id == id, value.revision >= 0 else { throw GmailDraftError.storage }
            return (value, 12 + size)
        }
        func read(_ scope: GmailDraftScope, _ id: UUID) throws -> GmailDraftRecord? {
            try scope.validate()
            let url = file(scope, id)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            do {
                let secret = SymmetricKey(data: try key(false))
                let (metadata, offset) = try index(scope, id, using: secret)
                let data = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: url).dropFirst(offset)),
                    using: secret, authenticating: aad(scope, id))
                let record = try JSONDecoder().decode(GmailDraftRecord.self, from: data)
                try record.validate()
                guard record.scope == scope, record.id == id, GmailDraftIndex(record) == metadata else { throw GmailDraftError.storage }
                return record
            } catch { throw GmailDraftError.storage }
        }
        func ids(_ scope: GmailDraftScope) throws -> [UUID] {
            try scope.validate()
            guard FileManager.default.fileExists(atPath: folder(scope).path) else { return [] }
            do {
                let entries = try FileManager.default.contentsOfDirectory(at: folder(scope), includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "sealed" }
                guard entries.count <= 65536 else { throw GmailDraftError.limit }
                return try entries.map {
                    guard let id = UUID(uuidString: $0.deletingPathExtension().lastPathComponent),
                          $0.lastPathComponent == id.uuidString.lowercased() + ".sealed" else { throw GmailDraftError.storage }
                    return id
                }
            } catch let error as GmailDraftError { throw error }
            catch { throw GmailDraftError.storage }
        }
        func summaries(_ scope: GmailDraftScope) throws -> [GmailDraftSummary] {
            do {
                let identifiers = try ids(scope)
                guard !identifiers.isEmpty else { return [] }
                let secret = SymmetricKey(data: try key(false))
                var result: [GmailDraftSummary] = []
                for id in identifiers {
                    let (metadata, _) = try index(scope, id, using: secret)
                    if metadata.summary.state != .sent && metadata.summary.state != .discarded { result.append(metadata.summary) }
                }
                return result.sorted { $0.updatedAt > $1.updatedAt }
            } catch let error as GmailDraftError { throw error }
            catch { throw GmailDraftError.storage }
        }
        return Self(read: read, write: { record, expected in
            try record.validate()
            let previous = try read(record.scope, record.id)
            guard previous?.revision == expected, record.revision == (expected.map { $0 + 1 } ?? 0) else { throw GmailDraftError.changed }
            if let previous {
                let legal: Bool
                switch previous.state {
                case .editing: legal = [.editing, .sending, .discarded].contains(record.state)
                case .sending: legal = [.editing, .review, .sent].contains(record.state)
                case .review:
                    if let original = previous.serverAttempt, let resolution = record.serverResolution,
                       resolution.attempt == original {
                        switch resolution.state {
                        case .confirmed:
                            legal = record.state == .sent && record.serverAttempt == original
                        case .rejected, .cancelled:
                            legal = record.state == .editing && record.serverAttempt == nil &&
                                record.retiredServerAttempts == (previous.retiredServerAttempts ?? []) + [original]
                        default:
                            legal = record.state == .review && record.serverAttempt == original
                        }
                    } else { legal = false }
                case .sent, .discarded: legal = false
                }
                guard legal, previous.state == .editing || previous.content == record.content else { throw GmailDraftError.locked }
            } else {
                guard record.state == .editing else { throw GmailDraftError.locked }
                guard (1...512).contains(activeDraftLimit), try summaries(record.scope).count < activeDraftLimit,
                      try ids(record.scope).count < 65536 else { throw GmailDraftError.limit }
            }
            do {
                let plaintext = try JSONEncoder().encode(record)
                guard plaintext.count < 40 * 1024 * 1024 - 64 else { throw GmailDraftError.limit }
                // A lost key must never be regenerated while any encrypted
                // draft exists, including another account's retained drafts.
                let existingRoot = FileManager.default.fileExists(atPath: directory.path)
                let secret = SymmetricKey(data: try key(!existingRoot))
                let sealed = try AES.GCM.seal(plaintext, using: secret, authenticating: aad(record.scope, record.id))
                let metadata = try AES.GCM.seal(JSONEncoder().encode(GmailDraftIndex(record)), using: secret,
                    authenticating: aad(record.scope, record.id) + Data("/index".utf8))
                guard let payload = sealed.combined, let indexData = metadata.combined, indexData.count <= 65536 else { throw GmailDraftError.storage }
                var size = UInt32(indexData.count).bigEndian
                var data = magic
                withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
                data.append(indexData); data.append(payload)
                try FileManager.default.createDirectory(at: folder(record.scope), withIntermediateDirectories: true)
                var root = directory
                var resources = URLResourceValues(); resources.isExcludedFromBackup = true
                try root.setResourceValues(resources)
                try data.write(to: file(record.scope, record.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch let error as GmailDraftError { throw error }
            catch { throw GmailDraftError.storage }
        }, list: summaries)
    }

    static var device: Self {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return .init(read: { _, _ in throw GmailDraftError.storage }, write: { _, _ in throw GmailDraftError.storage }, list: { _ in throw GmailDraftError.storage })
        }
        let directory = root.appendingPathComponent("MailDrafts-v1", isDirectory: true)
        return encrypted(directory: directory) { create in
            let account = "MailDraftEncryption-v1"
            if let key = try KeychainStore.loadCodable(Data.self, account: account) {
                guard key.count == 32 else { throw GmailDraftError.storage }
                return key
            }
            guard create else { throw GmailDraftError.storage }
            let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try KeychainStore.saveCodable(key, account: account)
            return key
        }
    }
}

@MainActor final class GmailDraftSession {
    private(set) var record: GmailDraftRecord
    private let store: GmailDraftStore
    private let access: () throws -> Void
    private var ownsDispatch = false
    private(set) var serverCanCancel = false

    init(record: GmailDraftRecord, store: GmailDraftStore, access: @escaping () throws -> Void) throws {
        self.record = record; self.store = store; self.access = access
        try access(); try record.validate()
        if let saved = try store.read(record.scope, record.id) {
            guard saved == record else { throw GmailDraftError.changed }
        } else { try store.write(record, nil) }
    }

    func save(_ content: GmailDraftContent) throws {
        guard record.editable else { throw GmailDraftError.locked }
        var next = record; next.content = content; next.status = nil
        if content != record.content { retireAttempt(&next) }
        try update(next)
    }

    func prepareServerAttempt(scope: GmailServerScope) throws {
        try verify()
        guard record.editable, scope.draftScope == record.scope, record.content.business == nil,
              !record.content.requiresBusinessContext else { throw GmailDraftError.access }
        if let original = record.serverAttempt {
            guard original.scope == scope else { throw GmailDraftError.access }
            return
        }
        var next = record
        next.serverAttempt = .init(id: UUID(), scope: scope)
        next.serverResolution = nil
        try update(next)
    }

    private func retireAttempt(_ record: inout GmailDraftRecord) {
        if let original = record.serverAttempt {
            record.retiredServerAttempts = (record.retiredServerAttempts ?? []) + [original]
            record.serverAttempt = nil
        }
    }

    func verify() throws {
        try access()
        guard try store.read(record.scope, record.id) == record else { throw GmailDraftError.changed }
    }

    func begin() throws {
        guard record.editable else { throw GmailDraftError.locked }
        var next = record; next.state = .sending; next.status = GmailDraftError.locked.localizedDescription
        try update(next)
        ownsDispatch = true
    }

    func finish(_ outcome: GmailSendOutcome) throws {
        guard record.state == .sending, ownsDispatch else { throw GmailDraftError.locked }
        var next = record
        next.state = outcome.state == .sent ? .sent : outcome.canRetry ? .editing : .review
        next.status = outcome.message
        if outcome.canRetry { retireAttempt(&next) }
        try update(next)
        ownsDispatch = false
    }

    /// Only a read of the exact retained server content and original outcome
    /// can resolve an interrupted send. Never rebind it to a replacement grant.
    func recoverServer(provider: WorkspaceProviderOperation, cancelUnsent: Bool = false) async throws -> GmailSendOutcome {
        try verify(); try provider.check()
        guard !record.editable, record.state != .discarded, let attempt = record.serverAttempt,
              let server = provider.serverMail, server.scope == attempt.scope,
              record.content.business == nil, !record.content.requiresBusinessContext else { throw GmailDraftError.access }
        let original = record
        if original.state == .sent { return .init(state: .sent, message: "The original message is saved in Gmail Sent.") }
        let content = original.content
        let expected = try GmailServerMessage(GmailOutgoingMessage(to: content.to, subject: content.subject,
            body: content.body, attachments: content.files.map(\.attachment), reply: content.reply))
        guard try await server.savedMessage(id: attempt.id, operation: provider) == expected else { throw GmailDraftError.changed }
        try verify(); guard record == original else { throw GmailDraftError.changed }
        let response = try await (cancelUnsent ? server.cancel(id: attempt.id, operation: provider)
            : server.operation(id: attempt.id, recovery: true, operation: provider))
        try provider.check(); try verify(); guard record == original else { throw GmailDraftError.changed }
        var next = record
        next.serverResolution = .init(attempt: attempt, state: response.state)
        let result: GmailSendOutcome
        switch response.state {
        case .confirmed:
            next.state = .sent
            result = .init(state: .sent, message: "The original message is saved in Gmail Sent.")
        case .rejected, .cancelled:
            next.state = .editing; retireAttempt(&next)
            result = .init(state: .notSent, message: "The original message was not sent. You can edit this draft.")
        case .prepared:
            next.state = .review
            result = .init(state: .reviewRequired, message: "The original message is saved but has not been sent. Cancel the unsent request to edit this draft.")
        default:
            next.state = .review; result = .uncertain
        }
        serverCanCancel = response.state == .prepared
        next.status = result.message
        try update(next); ownsDispatch = false
        return result
    }

    func discard() throws {
        guard record.editable else { throw GmailDraftError.locked }
        var next = record; next.state = .discarded
        // Keep only a tombstone: stale windows cannot resurrect discarded work.
        next.content = .init(to: "", subject: "", body: ""); next.status = nil
        try update(next)
    }

    private func update(_ next: GmailDraftRecord) throws {
        try access()
        var next = next; next.revision += 1; next.updatedAt = Date()
        try store.write(next, record.revision)
        record = next
    }
}
