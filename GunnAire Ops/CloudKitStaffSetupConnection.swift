import Foundation
import CloudKit
import Combine
import CryptoKit

struct CloudKitStaffSetupStamp: Equatable {
    let session: CompanyWorkspaceSession
    let accountGeneration: UUID
    static var current: Self? {
        guard let session = CompanyWorkspaceSession.current, !CloudKitStaffAccountFence.shared.mustRestart else { return nil }
        return .init(session: session, accountGeneration: CloudKitStaffAccountFence.shared.generation)
    }
}

@MainActor final class CloudKitStaffAccountFence {
    static let shared = CloudKitStaffAccountFence()
    private(set) var generation = UUID()
    private(set) var mustRestart = false
    private var observer: NSObjectProtocol?
    private init() {
        observer = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.generation = UUID(); self?.mustRestart = true }
        }
    }
}

enum CloudKitStaffSetupPolicy {
    static let base = "/api/workspace/staff-shares"
    static let actions: Set<String> = ["approve", "invite", "accept", "revoke", "confirm-cleanup"]
    nonisolated static func canonicalID(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString.lowercased() == value }
    static func allows(path: String, method: String, bytes: Int?) -> Bool {
        guard path.utf8.count <= 4096, let url = URLComponents(string: path), url.scheme == nil, url.host == nil,
              url.fragment == nil, url.percentEncodedPath == url.path else { return false }
        if method == "GET", bytes == nil, url.path == "/api/workspace" { return url.query == nil }
        let suffix = String(url.path.dropFirst(base.count))
        guard url.path == base || url.path.hasPrefix(base + "/") else { return false }
        let parts = suffix.isEmpty ? [] : suffix.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.isEmpty || canonicalID(parts[0]) else { return false }
        if method == "GET", bytes == nil {
            guard parts.count <= 1 || (parts.count == 2 && ["participant", "owner-authority"].contains(parts[1])),
                  let items = url.queryItems, Set(items.map(\.name)).count == items.count else { return false }
            let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            let required: Set<String> = ["companyID", "environment"]
            guard Set(values.keys) == required || (parts.isEmpty && Set(values.keys) == required.union(["after"])),
                  canonicalID(values["companyID"] ?? ""), ["development", "production"].contains(values["environment"] ?? "") else { return false }
            return values["after"].map(canonicalID) ?? true
        }
        return method == "POST" && url.query == nil && bytes.map { (1...8192).contains($0) } == true &&
            (parts.isEmpty || (parts.count == 2 && actions.contains(parts[1])))
    }

    static func invitationURL(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return url.absoluteString.utf8.count <= 4096 && parts.scheme == "https" &&
            ["icloud.com", "www.icloud.com"].contains(parts.host ?? "") && parts.user == nil && parts.password == nil &&
            (parts.port == nil || parts.port == 443) && parts.path.hasPrefix("/share/") && parts.path.count > 7
    }

    static func safe(_ error: Error) -> CloudKitStaffSharingError {
        if let error = error as? CloudKitStaffSharingError { return error }
        if error is DecodingError { return .invalid }
        if case GunnAireBackendError.server(let status, _) = error {
            if status == 401 || status == 403 { return .access }
            if status == 400 { return .invalid }
            if status == 409 { return .review }
        }
        if case SharedTimeError.storage = error { return .storage }
        if StaffSyncNetworkFailure.isTransient(error) { return .offline }
        return .unavailable
    }

    static func query(company: UUID, environment: String, id: UUID? = nil, participant: Bool = false,
                      ownerAuthority: Bool = false, after: UUID? = nil) -> String {
        var url = URLComponents()
        url.path = base + (id.map { "/" + $0.uuidString.lowercased() } ?? "") + (participant ? "/participant" : (ownerAuthority ? "/owner-authority" : ""))
        url.queryItems = [.init(name: "companyID", value: company.uuidString.lowercased()), .init(name: "environment", value: environment)]
        if let after { url.queryItems?.append(.init(name: "after", value: after.uuidString.lowercased())) }
        return url.string ?? ""
    }
}

struct CloudKitStaffShareList: Decodable { let shares: [CloudKitStaffSharePlan]; let nextCursor: UUID? }
struct CloudKitStaffParticipantIdentity: Decodable {
    let id: UUID
    let companyID: UUID
    let environment: String
    let revision: Int
    let participantAccountHash: String
    let recordName: String
    func validate(_ plan: CloudKitStaffSharePlan) throws {
        guard id == plan.id, companyID == plan.companyID, environment == plan.environment, revision == plan.revision,
              participantAccountHash == plan.participantAccountHash, (1...255).contains(recordName.utf8.count),
              recordName != CKCurrentUserDefaultName,
              !recordName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              CloudKitStaffSharePlan.accountHash(recordName: recordName, environment: environment) == participantAccountHash
        else { throw CloudKitStaffSharingError.changed }
    }
}

struct CloudKitStaffSetupScope: Codable, Equatable {
    let origin: String
    let company: UUID
    let email: String
    let environment: String
    let accountHash: String
    var key: String { ["cloudkit-staff-setup-v1", origin, company.uuidString.lowercased(), email, environment, accountHash].joined(separator: "\n") }
}

struct CloudKitStaffSetupMutation: Codable, Equatable {
    let operationID: UUID
    let shareID: UUID?
    let action: String
    let body: Data
}

struct CloudKitStaffSetupJournal: Codable {
    let scope: CloudKitStaffSetupScope
    var pending: CloudKitStaffSetupMutation?
    var originalPlans: [CloudKitStaffSharePlan] = []
    /// Share URLs are sensitive invitation material; only this encrypted,
    /// account/company/actor-scoped journal retains them across relaunch.
    var invitationURLs: [String: URL] = [:]
    var lastCloudOperation: String?
    var lastCloudShareID: UUID?
}

enum CloudKitStaffSetupStorage {
    static var device: SharedTimeLocalStore {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return .init(read: { _ in throw CloudKitStaffSharingError.storage }, write: { _, _ in throw CloudKitStaffSharingError.storage })
        }
        return .encrypted(directory: root.appendingPathComponent("CloudKitStaffSetup-v1", isDirectory: true)) { create in
            let name = "CloudKitStaffSetupEncryption-v1"
            if let bytes = try KeychainStore.loadCodable(Data.self, account: name) {
                guard bytes.count == 32 else { throw CloudKitStaffSharingError.storage }; return bytes
            }
            guard create else { throw CloudKitStaffSharingError.storage }
            let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try KeychainStore.saveCodable(bytes, account: name); return bytes
        }
    }
}

@MainActor enum CloudKitStaffSetupLocks {
    private static var active: Set<String> = []
    static func acquire(_ key: String) throws {
        guard active.insert(key).inserted else { throw CloudKitStaffSharingError.review }
    }
    static func release(_ key: String) { active.remove(key) }
}
