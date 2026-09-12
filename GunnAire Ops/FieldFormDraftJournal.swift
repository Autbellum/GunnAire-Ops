import Foundation
import CryptoKit

enum FieldFormDraftError: LocalizedError, Equatable {
    case access, storage, changed, contextChanged, locked, limit, completionReview, fileLinkReview

    var errorDescription: String? {
        switch self {
        case .access: "Verify access to the original business and assigned job before opening this draft. Your saved answers have been kept."
        case .storage: "The draft could not be saved or verified. Keep the form open and try again. Existing drafts have not been cleared."
        case .changed: "This form changed in another window. Your entries are still visible here. Reopen the saved draft before continuing."
        case .contextChanged: "The job, equipment, or form changed. Your original answers are kept below for review. They will not be applied to different work."
        case .locked: "This form is already being completed. Review the original saved result before starting another form."
        case .limit: "This device cannot save more form data right now. Keep your entries open and review your saved drafts."
        case .completionReview: "The original form or its file needs review in Saved forms and Files. Another completion has not been created."
        case .fileLinkReview: "This job’s equipment or billing link needs review before the form can be filed. Your draft is kept. Ask the office to verify the link."
        }
    }
}

/// A device draft is not a CloudKit record or evidence of company membership.
/// The verified workspace, actual SQLite identity and signed-in author all
/// participate in its encryption context. Refreshing a login retains the slot;
/// changing the account, company, server or local workspace does not adopt it.
struct FieldFormDraftScope: Codable, Equatable {
    let companyID: UUID
    let backendOrigin: String
    let actorEmail: String
    let storeID: String

    var storageKey: String {
        CompanyWorkspaceSession.digest([companyID.uuidString.lowercased(), backendOrigin,
                                       actorEmail, storeID].joined(separator: "\n"))
    }

    func validate() throws {
        guard let url = URL(string: backendOrigin), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              actorEmail == AppAccess.normalizedEmail(actorEmail),
              (try? GmailAddressList.parse(actorEmail)) == [actorEmail],
              !storeID.isEmpty, storeID.utf8.count <= 256,
              !storeID.contains("\n"), !storeID.contains("\0") else { throw FieldFormDraftError.access }
    }
}

struct FieldFormDraftSlot: Codable, Equatable {
    let scope: FieldFormDraftScope
    let jobID: UUID
    let templateID: UUID
    var key: String { CompanyWorkspaceSession.digest(jobID.uuidString + "/" + templateID.uuidString) }
}

struct FieldFormDraftJob: Codable, Equatable {
    let customerID: UUID
    let customerName: String
    let siteAddress: String
    let workType: String
    let serviceLocationID: UUID?
    let equipmentID: UUID?
    let equipment: [String?]
    let invoiceID: UUID?
    let estimateID: UUID?
}

struct FieldFormDraftContent: Codable, Equatable {
    let title: String
    let questions: [FieldFormQuestion]
    let job: FieldFormDraftJob
    var answers: [UUID: String] = [:]

    func validate() throws {
        guard title.utf8.count <= 4096, !title.contains("\0"), questions.count <= 500,
              answers.count <= 500, answers.values.allSatisfy({ $0.utf8.count <= 262_144 && !$0.contains("\0") }),
              job.equipment.count == 5,
              ([job.customerName, job.siteAddress, job.workType] + job.equipment.compactMap { $0 })
                .allSatisfy({ $0.utf8.count <= 16_384 && !$0.contains("\0") }) else { throw FieldFormDraftError.limit }
        guard FieldFormTemplatePolicy.validationIssue(title: title, questions: questions) == nil,
              ServiceCallType(rawValue: job.workType) != nil else { throw FieldFormDraftError.storage }
        _ = try FieldFormPayload.questions(String(decoding: JSONEncoder().encode(questions), as: UTF8.self))
        // Required fields are deliberately allowed to be unfinished in a draft.
        let partial = questions.map { question in var question = question; question.required = false; return question }
        guard FieldFormCompletionPolicy.validationIssue(questions: partial, answers: answers) == nil else {
            throw FieldFormDraftError.storage
        }
    }
}

enum FieldFormDraftState: String, Codable { case editing, completing, completed, discarded }

struct FieldFormDraftRecord: Codable, Equatable, Identifiable {
    var version = 1
    let slot: FieldFormDraftSlot
    let id: UUID
    let attachmentID: UUID
    let activityID: UUID
    var revision: Int
    var content: FieldFormDraftContent?
    var state: FieldFormDraftState = .editing
    var updatedAt = Date()
    var completedAt: Date?

    init(slot: FieldFormDraftSlot, content: FieldFormDraftContent, revision: Int = 0) {
        self.slot = slot; self.content = content; self.revision = revision
        id = UUID(); attachmentID = UUID(); activityID = UUID()
    }

    func validate() throws {
        try slot.scope.validate()
        guard version == 1, revision >= 0, revision < Int.max - 1, Set([id, attachmentID, activityID]).count == 3,
              updatedAt.timeIntervalSince1970.isFinite,
              completedAt?.timeIntervalSince1970.isFinite != false,
              (state == .discarded) == (content == nil),
              ([.completing, .completed].contains(state)) == (completedAt != nil) else {
            throw FieldFormDraftError.storage
        }
        try content?.validate()
        if [.completing, .completed].contains(state), let content,
           FieldFormCompletionPolicy.validationIssue(questions: content.questions, answers: content.answers) != nil {
            throw FieldFormDraftError.storage
        }
    }
}

/// MainActor serialization plus compare-and-swap protects multiple app windows.
/// One durable slot per author/job/template keeps ordinary navigation resumable.
/// Terminal tombstones prevent an old editor from resurrecting discarded work.
@MainActor struct FieldFormDraftStore {
    let read: (FieldFormDraftSlot) throws -> FieldFormDraftRecord?
    let write: (FieldFormDraftRecord, Int?) throws -> Void
    let list: (FieldFormDraftScope, UUID) throws -> [FieldFormDraftRecord]

    static func encrypted(directory: URL, key: @escaping (Bool) throws -> Data) -> Self {
        let manager = FileManager.default
        let maxBytes = 1_048_576
        func folder(_ scope: FieldFormDraftScope) -> URL { directory.appendingPathComponent(scope.storageKey) }
        func file(_ slot: FieldFormDraftSlot) -> URL { folder(slot.scope).appendingPathComponent(slot.key + ".sealed") }
        func aad(_ scope: FieldFormDraftScope, _ name: String) -> Data {
            Data(("GAFORM1/" + scope.storageKey + "/" + name).utf8)
        }
        func verifyDirectory(_ url: URL) throws {
            if manager.fileExists(atPath: url.path) {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { throw FieldFormDraftError.storage }
            }
        }
        func decode(_ scope: FieldFormDraftScope, _ url: URL) throws -> FieldFormDraftRecord {
            do {
                try verifyDirectory(directory); try verifyDirectory(folder(scope))
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      (28...maxBytes).contains(values.fileSize ?? 0) else { throw FieldFormDraftError.storage }
                let secret = try key(false)
                guard secret.count == 32 else { throw FieldFormDraftError.storage }
                let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: url)),
                    using: SymmetricKey(data: secret), authenticating: aad(scope, url.lastPathComponent))
                _ = try FieldFormJSON.parse(String(decoding: bytes, as: UTF8.self))
                let record = try JSONDecoder().decode(FieldFormDraftRecord.self, from: bytes)
                try record.validate()
                // Directory enumeration may return a relative-base URL while
                // direct reads use an absolute URL. Compare resolved paths,
                // retaining the exact scope and hashed slot filename checks.
                guard record.slot.scope == scope,
                      file(record.slot).standardizedFileURL.path == url.standardizedFileURL.path else {
                    throw FieldFormDraftError.storage
                }
                return record
            } catch { throw FieldFormDraftError.storage }
        }
        func read(_ slot: FieldFormDraftSlot) throws -> FieldFormDraftRecord? {
            try slot.scope.validate()
            try verifyDirectory(directory); try verifyDirectory(folder(slot.scope))
            guard manager.fileExists(atPath: file(slot).path) else { return nil }
            let record = try decode(slot.scope, file(slot))
            guard record.slot == slot else { throw FieldFormDraftError.storage }
            return record
        }
        func records(_ scope: FieldFormDraftScope) throws -> [FieldFormDraftRecord] {
            try scope.validate(); try verifyDirectory(directory); try verifyDirectory(folder(scope))
            guard manager.fileExists(atPath: folder(scope).path) else { return [] }
            let urls = try manager.contentsOfDirectory(at: folder(scope), includingPropertiesForKeys: nil)
            guard urls.count <= 65_536 else { throw FieldFormDraftError.limit }
            return try urls.map { url in
                guard url.pathExtension == "sealed" else { throw FieldFormDraftError.storage }
                return try decode(scope, url)
            }
        }
        return Self(read: read, write: { record, expected in
            try record.validate()
            let previous = try read(record.slot)
            guard previous?.revision == expected, record.revision == (expected.map { $0 + 1 } ?? 0) else {
                throw FieldFormDraftError.changed
            }
            if let previous {
                let legal: Bool
                if previous.id != record.id {
                    legal = [.completed, .discarded].contains(previous.state) && record.state == .editing &&
                        record.attachmentID != previous.attachmentID && record.activityID != previous.activityID
                    guard try records(record.slot.scope).filter({ [.editing, .completing].contains($0.state) }).count < 512 else {
                        throw FieldFormDraftError.limit
                    }
                } else {
                    guard previous.attachmentID == record.attachmentID, previous.activityID == record.activityID else {
                        throw FieldFormDraftError.locked
                    }
                    switch previous.state {
                    case .editing:
                        var unchanged = record.content; unchanged?.answers = previous.content?.answers ?? [:]
                        legal = record.state == .discarded ||
                            ([.editing, .completing].contains(record.state) && unchanged == previous.content)
                    case .completing:
                        legal = record.state == .completed && record.content == previous.content &&
                            record.completedAt == previous.completedAt
                    case .completed, .discarded: legal = false
                    }
                }
                guard legal else { throw FieldFormDraftError.locked }
            } else {
                guard record.state == .editing else { throw FieldFormDraftError.locked }
                let all = try records(record.slot.scope)
                guard all.count < 65_536,
                      all.filter({ [.editing, .completing].contains($0.state) }).count < 512 else { throw FieldFormDraftError.limit }
            }
            do {
                let bytes = try JSONEncoder().encode(record)
                guard bytes.count + 28 <= maxBytes else { throw FieldFormDraftError.limit }
                // Do not generate a replacement key if any account has retained
                // encrypted drafts, even when this particular slot is new.
                let secret = try key(!manager.fileExists(atPath: directory.path))
                guard secret.count == 32 else { throw FieldFormDraftError.storage }
                let sealed = try AES.GCM.seal(bytes, using: SymmetricKey(data: secret),
                    authenticating: aad(record.slot.scope, file(record.slot).lastPathComponent))
                guard let data = sealed.combined else { throw FieldFormDraftError.storage }
                try manager.createDirectory(at: folder(record.slot.scope), withIntermediateDirectories: true)
                var root = directory
                var resources = URLResourceValues(); resources.isExcludedFromBackup = true
                try root.setResourceValues(resources)
                try data.write(to: file(record.slot), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch let error as FieldFormDraftError { throw error }
            catch { throw FieldFormDraftError.storage }
        }, list: { scope, jobID in
            try records(scope).filter { $0.slot.jobID == jobID && [.editing, .completing].contains($0.state) }
                .sorted { $0.updatedAt > $1.updatedAt }
        })
    }

    static var device: Self {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return .init(read: { _ in throw FieldFormDraftError.storage },
                         write: { _, _ in throw FieldFormDraftError.storage }, list: { _, _ in throw FieldFormDraftError.storage })
        }
        return encrypted(directory: root.appendingPathComponent("FieldFormDrafts-v1")) { create in
            let account = "FieldFormDraftEncryption-v1"
            if let key = try KeychainStore.loadCodable(Data.self, account: account) {
                guard key.count == 32 else { throw FieldFormDraftError.storage }; return key
            }
            guard create else { throw FieldFormDraftError.storage }
            let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try KeychainStore.saveCodable(key, account: account)
            return key
        }
    }
}

@MainActor final class FieldFormDraftSession {
    private(set) var record: FieldFormDraftRecord
    private let store: FieldFormDraftStore
    private let access: () throws -> Void

    init(record: FieldFormDraftRecord, store: FieldFormDraftStore, access: @escaping () throws -> Void) throws {
        self.record = record; self.store = store; self.access = access
        try access(); try record.validate()
        guard try store.read(record.slot) == record else { throw FieldFormDraftError.changed }
    }

    func verify() throws {
        try access()
        guard try store.read(record.slot) == record else { throw FieldFormDraftError.changed }
    }

    func save(_ answers: [UUID: String]) throws {
        guard record.state == .editing else { throw FieldFormDraftError.locked }
        var next = record; next.content?.answers = answers
        try update(next)
    }

    func begin(at date: Date = Date()) throws {
        guard record.state == .editing, let content = record.content,
              FieldFormCompletionPolicy.validationIssue(questions: content.questions, answers: content.answers) == nil else {
            throw FieldFormDraftError.locked
        }
        var next = record; next.state = .completing; next.completedAt = date
        try update(next)
    }

    func finish() throws {
        guard record.state == .completing else { throw FieldFormDraftError.locked }
        var next = record; next.state = .completed
        try update(next)
    }

    func discard() throws {
        guard record.state == .editing else { throw FieldFormDraftError.locked }
        var next = record; next.state = .discarded; next.content = nil
        try update(next)
    }

    private func update(_ value: FieldFormDraftRecord) throws {
        try verify()
        var next = value; next.revision += 1; next.updatedAt = Date()
        try store.write(next, record.revision)
        record = next
    }
}
