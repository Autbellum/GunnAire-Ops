import Foundation
import CryptoKit

struct JobBillingBusinessScope: Codable, Equatable {
    let companyID: UUID
    let actorEmail: String
    var storageKey: String {
        SHA256.hash(data: Data([companyID.uuidString.lowercased(), actorEmail].joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    func validate() throws {
        guard actorEmail == AppAccess.normalizedEmail(actorEmail), actorEmail.utf8.count <= 254,
              actorEmail.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil else {
            throw JobBillingDispatchError.access
        }
    }
}

/// An opaque server descriptor, not a credential or permission grant. Cached
/// descriptors only select the original encrypted queue while offline.
struct SharedJobBillingConnection: Codable, Equatable {
    let companyID: UUID
    let realmID: String
    let environment: String
    let connectionRevision: String
    var protocolVersion = 1

    func validate(_ company: UUID) throws {
        guard companyID == company, protocolVersion == 1, PaymentAttemptRecord.isReference(realmID),
              ["sandbox", "production"].contains(environment),
              JobBillingAssignmentSnapshot.validConnectionRevision(connectionRevision) else {
            throw JobBillingDispatchError.connection
        }
    }
    func scope(_ business: JobBillingBusinessScope) -> JobBillingQueueScope {
        .init(companyID: business.companyID, realmID: realmID, environment: environment, actorEmail: business.actorEmail)
    }
}

/// First-use offline intent has no invented realm, provider epoch or approval.
/// It is moved to the existing realm-bound journal only after discovery, and
/// removed here only AFTER that original record is durably written there.
struct JobBillingBootstrap: Codable, Equatable {
    var version = 1
    let business: JobBillingBusinessScope
    var connection: SharedJobBillingConnection?
    var records: [JobBillingQueueRecord] = []

    func validate(_ expected: JobBillingBusinessScope) throws {
        try business.validate()
        guard version == 1, business == expected, records.count <= 4096,
              Set(records.map(\.id)).count == records.count else { throw JobBillingDispatchError.storage }
        try connection?.validate(business.companyID)
        for record in records {
            guard record.confirmed == nil, let edit = record.pending,
                  edit.baseline == nil, edit.request == nil, edit.supersededRequests.isEmpty,
                  edit.desired.localCustomerID == edit.localRevision.customerID,
                  edit.desired.technicianEmails == Array(Set(edit.desired.technicianEmails)).sorted(),
                  edit.desired.technicianEmails.count <= 32,
                  !edit.desired.enabled || (!edit.desired.needsCrewAccounts && !edit.desired.technicianEmails.isEmpty),
                  edit.desired.technicianEmails.allSatisfy({ email in
                      email == AppAccess.normalizedEmail(email) && email.utf8.count <= 254 &&
                      email.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
                  }) else { throw JobBillingDispatchError.storage }
        }
    }
}

struct JobBillingBootstrapStore {
    let read: (JobBillingBusinessScope) throws -> JobBillingBootstrap
    let write: (JobBillingBootstrap) throws -> Void

    static func encrypted(directory: URL, key: @escaping (Bool) throws -> Data) -> Self {
        func file(_ scope: JobBillingBusinessScope) -> URL { directory.appendingPathComponent(scope.storageKey + ".sealed") }
        return .init(read: { scope in
            do {
                try scope.validate()
                let url = file(scope)
                guard FileManager.default.fileExists(atPath: url.path) else { return .init(business: scope) }
                guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max <= 8 * 1024 * 1024 else {
                    throw JobBillingDispatchError.storage
                }
                let sealed = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
                let data = try AES.GCM.open(sealed, using: SymmetricKey(data: key(false)), authenticating: Data(scope.storageKey.utf8))
                let value = try JSONDecoder().decode(JobBillingBootstrap.self, from: data)
                try value.validate(scope)
                return value
            } catch { throw JobBillingDispatchError.storage }
        }, write: { value in
            do {
                try value.validate(value.business)
                let data = try JSONEncoder().encode(value)
                guard data.count <= 8 * 1024 * 1024 - 64 else { throw JobBillingDispatchError.storage }
                let exists = FileManager.default.fileExists(atPath: file(value.business).path)
                let sealed = try AES.GCM.seal(data, using: SymmetricKey(data: key(!exists)), authenticating: Data(value.business.storageKey.utf8))
                guard let bytes = sealed.combined else { throw JobBillingDispatchError.storage }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var folder = directory, resources = URLResourceValues()
                resources.isExcludedFromBackup = true
                try folder.setResourceValues(resources)
                try bytes.write(to: file(value.business), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch { throw JobBillingDispatchError.storage }
        })
    }

    static var device: Self {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return .init(read: { _ in throw JobBillingDispatchError.storage }, write: { _ in throw JobBillingDispatchError.storage })
        }
        return encrypted(directory: root.appendingPathComponent("JobBillingBootstrap-v1", isDirectory: true)) { create in
            let account = "JobBillingBootstrapEncryption-v1"
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
