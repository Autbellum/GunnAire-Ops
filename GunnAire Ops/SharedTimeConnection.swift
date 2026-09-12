import Foundation
import SwiftData
import CryptoKit

enum SharedTimeError: LocalizedError, Equatable {
    case access, changed, invalid, unavailable, storage, mapping, review, setup, approval, save
    var errorDescription: String? {
        switch self {
        case .access: "Current office access to this business is required. Refresh your business sign-in and reopen this review."
        case .changed: "The original entry, account or review changed. Saved work is retained; reopen the original review."
        case .invalid: "The business service did not confirm the original time review. No replacement request was sent."
        case .unavailable: "The business service is unavailable. Saved work is retained. Refresh or recover the original review when online."
        case .storage: "The saved time review could not be verified on this device. It was not cleared. Ask the administrator to review this device."
        case .mapping: "Ask the administrator to review this worker's Employee or Vendor mapping in this QuickBooks company."
        case .review: "This review needs attention. Refresh the original result; cancel an unsent proposal before reviewing changed values."
        case .setup: "The configured payroll or project reference needs shared-account setup. It was not silently removed from this time entry."
        case .approval: "Approve a completed paid-time entry before preparing its QuickBooks review."
        case .save: "The QuickBooks result is retained, but the local time link could not be saved. Recover the original result again."
        }
    }

    static func safe(_ error: Error) -> Error {
        if error is Self || error is CancellationError || error is WorkspaceProviderAccessError { return error }
        if error is DecodingError { return Self.invalid }
        if case GunnAireBackendError.server(let status, _) = error {
            if status == 401 || status == 403 { return Self.access }
            if status == 400 { return Self.invalid }
            if status == 409 { return Self.review }
        }
        return Self.unavailable
    }

    static func validEmail(_ value: String) -> Bool {
        value == AppAccess.normalizedEmail(value) && value.utf8.count <= 254 &&
            value.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil &&
            value.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func date(_ value: String) -> Date? {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
    static func instant(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

enum SharedTimeTransportPolicy {
    static func allows(path: String, method: String, bodyBytes: Int?) -> Bool {
        guard path.utf8.count <= 4096, let url = URLComponents(string: path), url.scheme == nil, url.host == nil,
              url.fragment == nil, url.percentEncodedPath == url.path else { return false }
        let workers = "/api/time-worker-mappings", times = "/api/time-publications"
        if method == "GET", bodyBytes == nil {
            guard let fields = url.queryItems, Set(fields.map(\.name)).count == fields.count else { return false }
            let names = Set(fields.map(\.name))
            func value(_ key: String) -> String { fields.first { $0.name == key }?.value ?? "" }
            guard UUID(uuidString: value("companyID")) != nil else { return false }
            if url.path == times {
                return names == ["companyID", "localEntryID"] && UUID(uuidString: value("localEntryID")) != nil
            }
            guard SharedTimeError.validEmail(value("workerEmail")) else { return false }
            if url.path == workers { return names == ["companyID", "workerEmail"] }
            return url.path == workers + "/candidate" && names == ["companyID", "workerEmail", "kind", "providerID"] &&
                ["Employee", "Vendor"].contains(value("kind")) && PaymentAttemptRecord.isReference(value("providerID"))
        }
        guard method == "POST", url.query == nil, let size = bodyBytes, (1...32768).contains(size) else { return false }
        if url.path == workers { return size <= 8192 }
        if url.path == times { return true }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 5 && parts[0].isEmpty && parts[1] == "api" && parts[2] == "time-publications" &&
            UUID(uuidString: String(parts[3]))?.uuidString.lowercased() == String(parts[3]) &&
            ["confirm", "recover", "cancel", "adopt"].contains(parts[4])
    }
}

struct SharedTimeWorkerIdentity: Codable, Equatable {
    let companyID: UUID
    let workerEmail: String
    func path(candidate: SharedTimeWorkerReference? = nil) -> String {
        var url = URLComponents()
        url.path = "/api/time-worker-mappings" + (candidate == nil ? "" : "/candidate")
        url.queryItems = [.init(name: "companyID", value: companyID.uuidString.lowercased()), .init(name: "workerEmail", value: workerEmail)]
        if let candidate { url.queryItems! += [.init(name: "kind", value: candidate.kind), .init(name: "providerID", value: candidate.providerID)] }
        // The server uses form-style query decoding; an email's literal plus
        // must not become a space and select a different worker identity.
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return url.string ?? ""
    }
}

struct SharedTimeWorkerReference: Codable, Equatable {
    let kind: String
    let providerID: String
    let displayName: String
    let referenceRevision: String
    func validate() throws {
        guard ["Employee", "Vendor"].contains(kind), PaymentAttemptRecord.isReference(providerID),
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, displayName.count <= 500,
              displayName.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }),
              JobBillingAssignmentSnapshot.validConnectionRevision(referenceRevision) else { throw SharedTimeError.invalid }
    }
}

struct SharedTimeWorkerMapping: Codable, Equatable {
    let companyID: UUID
    let realmID: String
    let environment: String
    let workerEmail: String
    let revision: Int
    let kind: String
    let providerID: String
    let displayName: String
    let referenceRevision: String
    let enabled: Bool
    let usable: Bool
    let updatedAt: String
    var reference: SharedTimeWorkerReference { .init(kind: kind, providerID: providerID, displayName: displayName, referenceRevision: referenceRevision) }
    func validate(_ identity: SharedTimeWorkerIdentity, realmID: String, environment: String) throws {
        try reference.validate()
        guard companyID == identity.companyID, workerEmail == identity.workerEmail,
              self.realmID == realmID, self.environment == environment, (1...2_147_483_647).contains(revision),
              !usable || enabled, SharedTimeError.date(updatedAt) != nil else { throw SharedTimeError.invalid }
    }
}

struct SharedTimeWorkerContext: Codable, Equatable {
    let companyID: UUID
    let workerEmail: String
    let realmID: String
    let environment: String
    let protocolVersion: Int
    let connectionRevision: String
    let mapping: SharedTimeWorkerMapping?
    let candidate: SharedTimeWorkerReference?
    var identity: SharedTimeWorkerIdentity { .init(companyID: companyID, workerEmail: workerEmail) }
    func validate(_ identity: SharedTimeWorkerIdentity) throws {
        guard companyID == identity.companyID, workerEmail == identity.workerEmail,
              SharedTimeError.validEmail(workerEmail), protocolVersion == 1, PaymentAttemptRecord.isReference(realmID),
              ["sandbox", "production"].contains(environment), JobBillingAssignmentSnapshot.validConnectionRevision(connectionRevision) else { throw SharedTimeError.invalid }
        try mapping?.validate(identity, realmID: realmID, environment: environment)
        try candidate?.validate()
    }
}

struct SharedTimeWorkerRequest: Codable, Equatable {
    let companyID: UUID
    let realmID: String
    let environment: String
    let workerEmail: String
    let connectionRevision: String
    let operationID: UUID
    let expectedRevision: Int
    let kind: String
    let providerID: String
    let referenceRevision: String
    let enabled: Bool
    init(_ context: SharedTimeWorkerContext, reference: SharedTimeWorkerReference, enabled: Bool, operationID: UUID = UUID()) {
        companyID = context.companyID; realmID = context.realmID; environment = context.environment; workerEmail = context.workerEmail
        connectionRevision = context.connectionRevision; self.operationID = operationID; expectedRevision = context.mapping?.revision ?? 0
        kind = reference.kind; providerID = reference.providerID; referenceRevision = reference.referenceRevision; self.enabled = enabled
    }
    func validate(_ identity: SharedTimeWorkerIdentity) throws {
        guard companyID == identity.companyID, workerEmail == identity.workerEmail,
              SharedTimeError.validEmail(workerEmail), PaymentAttemptRecord.isReference(realmID),
              ["sandbox", "production"].contains(environment), JobBillingAssignmentSnapshot.validConnectionRevision(connectionRevision),
              (0..<2_147_483_647).contains(expectedRevision), ["Employee", "Vendor"].contains(kind),
              PaymentAttemptRecord.isReference(providerID), JobBillingAssignmentSnapshot.validConnectionRevision(referenceRevision) else { throw SharedTimeError.invalid }
    }
}

struct SharedTimeWorkerSave: Codable {
    let mapping: SharedTimeWorkerMapping?
    let operationID: UUID
    let replayed: Bool
}

@MainActor struct SharedTimeClient {
    let transport: (String, String, Data?) async throws -> Data
    static var live: Self { .init(transport: GunnAireBackendService.sharedTimeRequest) }
    func request<T: Decodable>(_ type: T.Type, path: String, method: String, body: Data? = nil) async throws -> T {
        do {
            guard SharedTimeTransportPolicy.allows(path: path, method: method, bodyBytes: body?.count) else { throw SharedTimeError.invalid }
            let data = try await transport(path, method, body)
            guard data.count <= 512 * 1024 else { throw SharedTimeError.invalid }
            return try JSONDecoder().decode(type, from: data)
        } catch { throw SharedTimeError.safe(error) }
    }
    func worker(_ identity: SharedTimeWorkerIdentity, kind: String? = nil, providerID: String? = nil) async throws -> SharedTimeWorkerContext {
        let candidate: SharedTimeWorkerReference? = kind.map { .init(kind: $0, providerID: providerID ?? "", displayName: "", referenceRevision: "") }
        let result = try await request(SharedTimeWorkerContext.self, path: identity.path(candidate: candidate), method: "GET")
        try result.validate(identity)
        if let kind, let providerID {
            guard result.candidate?.kind == kind, result.candidate?.providerID == providerID else { throw SharedTimeError.invalid }
        } else if result.candidate != nil { throw SharedTimeError.invalid }
        return result
    }
    func saveWorker(_ value: SharedTimeWorkerRequest) async throws -> SharedTimeWorkerSave {
        let identity = SharedTimeWorkerIdentity(companyID: value.companyID, workerEmail: value.workerEmail)
        try value.validate(identity)
        let result = try await request(SharedTimeWorkerSave.self, path: "/api/time-worker-mappings", method: "POST", body: JSONEncoder().encode(value))
        guard result.operationID == value.operationID, let mapping = result.mapping, mapping.revision > value.expectedRevision else { throw SharedTimeError.invalid }
        try mapping.validate(identity, realmID: value.realmID, environment: value.environment)
        if !result.replayed {
            guard mapping.kind == value.kind, mapping.providerID == value.providerID,
                  mapping.referenceRevision == value.referenceRevision, mapping.enabled == value.enabled,
                  mapping.revision == value.expectedRevision + 1 else { throw SharedTimeError.invalid }
        }
        return result
    }
}

/// Device-only, authenticated journals. A missing/corrupt existing key never
/// becomes a new empty queue. Names are hashed, data is excluded from backup,
/// and no bearer token or plaintext worker record is stored in preferences.
struct SharedTimeLocalStore {
    let read: (String) throws -> Data?
    let write: (String, Data) throws -> Void
    static func encrypted(directory: URL, maximumBytes: Int = 1024 * 1024, key: @escaping (Bool) throws -> Data) -> Self {
        func file(_ scope: String) -> URL { directory.appendingPathComponent(SharedTimeError.digest(Data(scope.utf8)) + ".sealed") }
        return .init(read: { scope in
            do {
                let path = file(scope)
                guard FileManager.default.fileExists(atPath: path.path) else { return nil }
                guard (1024...64 * 1024 * 1024).contains(maximumBytes),
                      (try path.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= maximumBytes else { throw SharedTimeError.storage }
                return try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: path)), using: SymmetricKey(data: key(false)), authenticating: Data(scope.utf8))
            } catch { throw SharedTimeError.storage }
        }, write: { scope, value in
            do {
                guard (1024...64 * 1024 * 1024).contains(maximumBytes), value.count <= maximumBytes - 64 else { throw SharedTimeError.storage }
                let path = file(scope)
                let hasJournals: Bool
                if FileManager.default.fileExists(atPath: directory.path) {
                    hasJournals = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                        .contains { $0.pathExtension == "sealed" }
                } else { hasJournals = false }
                let sealed = try AES.GCM.seal(value, using: SymmetricKey(data: key(!hasJournals)), authenticating: Data(scope.utf8))
                guard let data = sealed.combined else { throw SharedTimeError.storage }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var folder = directory, resources = URLResourceValues(); resources.isExcludedFromBackup = true
                try folder.setResourceValues(resources)
                try data.write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch { throw SharedTimeError.storage }
        })
    }
    static var device: Self {
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return .init(read: { _ in throw SharedTimeError.storage }, write: { _, _ in throw SharedTimeError.storage })
        }
        return .encrypted(directory: directory.appendingPathComponent("SharedTime-v1", isDirectory: true)) { create in
            let account = "SharedTimeEncryption-v1"
            if let value = try KeychainStore.loadCodable(Data.self, account: account) {
                guard value.count == 32 else { throw SharedTimeError.storage }; return value
            }
            guard create else { throw SharedTimeError.storage }
            let value = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try KeychainStore.saveCodable(value, account: account); return value
        }
    }
}

@MainActor enum SharedTimeMutationGate {
    private static var active: [String: UUID] = [:]
    static func begin(_ key: String) throws -> UUID {
        guard active[key] == nil else { throw SharedTimeError.review }
        let id = UUID(); active[key] = id; return id
    }
    static func finish(_ key: String, id: UUID) { if active[key] == id { active[key] = nil } }
}

@MainActor final class SharedTimeAccess {
    let companyID: UUID
    let actorEmail: String
    let operation: WorkspaceProviderOperation
    private let validate: () throws -> Void
    init(context: ModelContext, administrator: Bool = false, isCurrent: @escaping () -> Bool,
         fixtureCompanyID: UUID? = nil, fixtureActor: String? = nil, validateAccess: (() throws -> Void)? = nil) throws {
        if fixtureCompanyID != nil || fixtureActor != nil || validateAccess != nil { precondition(GunnAireCloudKit.usesTestDatabase) }
        let actor = AppAccess.normalizedEmail(fixtureActor ?? AppIdentity.currentEmail)
        let check = {
            if let validateAccess { try validateAccess() }
            else {
                guard GunnAireCloudKit.usesTestDatabase || CompanyWorkspaceAccessController.shared.authorizedContainer === context.container else { throw SharedTimeError.access }
                let users = try context.fetch(FetchDescriptor<AppUser>())
                let role = AppAccess.activeRole(email: actor, users: users)
                guard administrator ? role == .admin : (role == .admin || role == .accounting) else { throw SharedTimeError.access }
            }
            guard actor == AppAccess.normalizedEmail(fixtureActor ?? AppIdentity.currentEmail), SharedTimeError.validEmail(actor) else { throw SharedTimeError.access }
        }
        try check()
        guard let company = fixtureCompanyID ?? CompanyWorkspaceAccessController.shared.verifiedCompanyID else { throw SharedTimeError.access }
        companyID = company; actorEmail = actor; validate = check
        operation = try .capture {
            guard isCurrent() else { return false }; do { try check(); return true } catch { return false }
        }
    }
    func check() throws { try operation.check(); try validate() }
    func scope(_ kind: String, _ identifier: String) -> String { ["shared-time-v1", kind, companyID.uuidString.lowercased(), actorEmail, identifier].joined(separator: "\n") }
}
