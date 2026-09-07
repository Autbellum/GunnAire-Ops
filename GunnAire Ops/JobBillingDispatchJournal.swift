import Foundation
import CryptoKit
import SwiftData

enum JobBillingDispatchError: LocalizedError, Equatable {
    case storage, save, changed, connection, access

    var errorDescription: String? {
        switch self {
        case .storage: "The saved billing-access queue could not be verified. Your existing work was not cleared. Keep this job open and ask an administrator to review this device."
        case .save: "This job could not be saved. Keep the form open and try Save again. No billing-access or calendar update was sent."
        case .changed: "This job or its crew changed while you were editing. Reopen the job and review the current assignment."
        case .connection: "Connect this business to QuickBooks, then review field billing access from the job."
        case .access: "Current dispatcher or administrator access to this business is required."
        }
    }
}

/// Queues belong to the original business AND office account. Signing out does
/// not erase work, and another dispatcher cannot silently replay it.
struct JobBillingQueueScope: Codable, Equatable {
    let companyID: UUID
    let realmID: String
    let environment: String
    let actorEmail: String

    func job(_ id: UUID) -> JobBillingScope {
        .init(companyID: companyID, realmID: realmID, environment: environment, serviceCallID: id)
    }

    var storageKey: String {
        let data = Data([companyID.uuidString.lowercased(), realmID, environment, actorEmail].joined(separator: "\n").utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func validate() throws {
        guard !realmID.isEmpty, realmID.count <= 128, !realmID.contains("\n"),
              ["sandbox", "production"].contains(environment),
              actorEmail == AppAccess.normalizedEmail(actorEmail), actorEmail.contains("@"), !actorEmail.contains("\n") else {
            throw JobBillingDispatchError.access
        }
    }
}

/// Only billing-relevant edits invalidate this handoff. Notes, start/end times,
/// and customer contact edits do not turn an ordinary invoice into a conflict.
struct JobBillingLocalRevision: Codable, Equatable {
    let customerID: UUID
    let leadID: UUID?
    let crewIDs: [UUID]
    let type: ServiceCallType
    let billingAllowed: Bool

    init(_ call: ServiceCall) {
        customerID = call.customer.id
        leadID = call.assignedTechnician?.id
        crewIDs = call.additionalTechnicianIDs.sorted { $0.uuidString < $1.uuidString }
        type = call.type
        billingAllowed = call.status != .cancelled && !call.visitDisposition.preventsBilling &&
            ![ServiceCallType.meeting, .reminder, .other].contains(call.type)
    }
}

struct JobBillingTarget: Codable, Equatable {
    let localCustomerID: UUID
    let technicianEmails: [String]
    let enabled: Bool
    let needsCrewAccounts: Bool

    func matches(_ assignment: JobBillingAssignment?) -> Bool {
        guard let assignment else { return false }
        return assignment.localCustomerID == localCustomerID && assignment.enabled == enabled &&
            assignment.technicianEmails.sorted() == technicianEmails && (!enabled || assignment.usable)
    }

    static func capture(_ call: ServiceCall, context: ModelContext) throws -> (JobBillingLocalRevision, Self) {
        // Verify membership before touching retained SwiftData relationships.
        let calls = try context.fetch(FetchDescriptor<ServiceCall>())
        guard calls.contains(where: { $0 === call }), !call.isDeleted else {
            throw JobBillingDispatchError.changed
        }
        guard calls.filter({ $0.id == call.id }).count == 1 else {
            throw JobBillingDispatchError.changed
        }
        let customers = try context.fetch(FetchDescriptor<Customer>())
        guard customers.contains(where: { $0 === call.customer }), customers.filter({ $0.id == call.customer.id }).count == 1 else {
            throw JobBillingDispatchError.changed
        }
        let revision = JobBillingLocalRevision(call)
        let technicians = try context.fetch(FetchDescriptor<Technician>())
        let users = try context.fetch(FetchDescriptor<AppUser>())
        let ids = Set(revision.crewIDs + [revision.leadID].compactMap { $0 })
        var emails: Set<String> = []
        var missing = false
        for id in ids {
            let matches = technicians.filter { $0.id == id }
            guard matches.count == 1 else { missing = true; continue }
            let email = AppAccess.normalizedEmail(matches[0].contactInfo)
            let accounts = users.filter { AppAccess.normalizedEmail($0.email) == email }
            guard !email.isEmpty, email.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil,
                  accounts.count == 1, accounts[0].isActive else { missing = true; continue }
            switch accounts[0].role {
            case .fieldTechnician: emails.insert(email)
            case .admin, .dispatcher, .accounting: break // Their office authority is separate.
            default: missing = true
            }
        }
        // Never retain an old crew grant or grant a guessed/partially mapped
        // crew. A missing account produces a revocation plus a clear review cue.
        let enabled = revision.billingAllowed && !missing && !emails.isEmpty && emails.count <= 32
        return (revision, .init(localCustomerID: revision.customerID,
            technicianEmails: enabled ? emails.sorted() : [], enabled: enabled,
            needsCrewAccounts: revision.billingAllowed && (missing || emails.count > 32)))
    }
}

enum JobBillingEditState: String, Codable { case prepared, queued, review }

struct JobBillingPendingEdit: Codable, Equatable {
    let id: UUID
    let original: JobBillingTarget?
    let desired: JobBillingTarget
    let localRevision: JobBillingLocalRevision
    let baseline: JobBillingAssignmentSnapshot?
    var state: JobBillingEditState
    var request: JobBillingAssignmentRequest?
    /// Retain uncertain older operations after a newer local edit. They are
    /// never resent; an explicit CAS decision can supersede them safely.
    var supersededRequests: [JobBillingAssignmentRequest]
}

struct JobBillingQueueRecord: Codable, Equatable, Identifiable {
    let id: UUID // job, not an invoice or provider identity
    var confirmed: JobBillingAssignmentSnapshot?
    var pending: JobBillingPendingEdit?
}

struct JobBillingQueue: Codable, Equatable {
    var version = 1
    let scope: JobBillingQueueScope
    var connectionRevision: String?
    var records: [JobBillingQueueRecord] = []

    func validate(_ expected: JobBillingQueueScope) throws {
        try expected.validate()
        guard version == 1, scope == expected, records.count <= 4096,
              connectionRevision.map(JobBillingAssignmentSnapshot.validConnectionRevision) ?? true,
              Set(records.map(\.id)).count == records.count else { throw JobBillingDispatchError.storage }
        for record in records {
            if let confirmed = record.confirmed {
                guard JobBillingAssignmentSnapshot.validConnectionRevision(confirmed.connectionRevision) else { throw JobBillingDispatchError.storage }
                if let row = confirmed.assignment { try row.validate(scope.job(record.id), customerID: row.localCustomerID) }
            }
            if let edit = record.pending {
                guard edit.desired.localCustomerID == edit.localRevision.customerID,
                      edit.desired.technicianEmails.count <= 32,
                      edit.desired.technicianEmails == Array(Set(edit.desired.technicianEmails)).sorted(),
                      !edit.desired.enabled || (!edit.desired.technicianEmails.isEmpty && !edit.desired.needsCrewAccounts),
                      edit.supersededRequests.count <= 32 else { throw JobBillingDispatchError.storage }
                try edit.baseline?.validate(scope.job(record.id), customerID: edit.desired.localCustomerID)
                for request in edit.supersededRequests + [edit.request].compactMap({ $0 }) {
                    guard request.scope == scope.job(record.id), request.localCustomerID == edit.desired.localCustomerID,
                          JobBillingAssignmentSnapshot.validConnectionRevision(request.connectionRevision),
                          (0..<2_147_483_647).contains(request.expectedRevision) else { throw JobBillingDispatchError.storage }
                }
                if let request = edit.request {
                    guard request.operationID == edit.id, request.enabled == edit.desired.enabled,
                          request.technicianEmails == edit.desired.technicianEmails else { throw JobBillingDispatchError.storage }
                }
            }
        }
    }
}

/// Atomic, authenticated local journal; no new CloudKit schema and no plaintext
/// business data in UserDefaults. Missing/corrupt keys or files fail closed and
/// are never replaced with an empty queue. Device-only keys mean these files
/// are excluded from backup; other devices recover current authority from the
/// server and require office review for a new offline intent.
struct JobBillingJournalStore {
    let read: (JobBillingQueueScope) throws -> JobBillingQueue
    let write: (JobBillingQueue) throws -> Void

    static func encrypted(directory: URL, key: @escaping (_ create: Bool) throws -> Data) -> Self {
        func url(_ scope: JobBillingQueueScope) -> URL { directory.appendingPathComponent(scope.storageKey + ".sealed") }
        return .init(read: { scope in
            do {
                try scope.validate()
                let file = url(scope)
                guard FileManager.default.fileExists(atPath: file.path) else { return JobBillingQueue(scope: scope) }
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard size <= 8 * 1024 * 1024 else { throw JobBillingDispatchError.storage }
                let sealed = try AES.GCM.SealedBox(combined: Data(contentsOf: file))
                let plaintext = try AES.GCM.open(sealed, using: SymmetricKey(data: key(false)), authenticating: Data(scope.storageKey.utf8))
                let queue = try JSONDecoder().decode(JobBillingQueue.self, from: plaintext)
                try queue.validate(scope)
                return queue
            } catch { throw JobBillingDispatchError.storage }
        }, write: { queue in
            do {
                try queue.validate(queue.scope)
                let plaintext = try JSONEncoder().encode(queue)
                guard plaintext.count <= 8 * 1024 * 1024 - 64 else { throw JobBillingDispatchError.storage }
                let exists = FileManager.default.fileExists(atPath: url(queue.scope).path)
                let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key(!exists)), authenticating: Data(queue.scope.storageKey.utf8))
                guard let data = sealed.combined else { throw JobBillingDispatchError.storage }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var folder = directory
                var resources = URLResourceValues()
                resources.isExcludedFromBackup = true
                try folder.setResourceValues(resources)
                try data.write(to: url(queue.scope), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch { throw JobBillingDispatchError.storage }
        })
    }

    static var device: Self {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return .init(read: { _ in throw JobBillingDispatchError.storage }, write: { _ in throw JobBillingDispatchError.storage })
        }
        return encrypted(directory: root.appendingPathComponent("JobBillingDispatch-v1", isDirectory: true)) { create in
            let account = "JobBillingDispatchEncryption-v1"
            if let existing = try KeychainStore.loadCodable(Data.self, account: account) {
                guard existing.count == 32 else { throw JobBillingDispatchError.storage }
                return existing
            }
            guard create else { throw JobBillingDispatchError.storage }
            let data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try KeychainStore.saveCodable(data, account: account)
            return data
        }
    }
}
