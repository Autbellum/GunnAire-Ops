import Foundation
import CryptoKit
import SwiftData
import CoreData
import CloudKit
import Combine

struct CompanyWorkspaceSession: Codable, Equatable {
    let backendOrigin: String
    let email: String
    let tokenFingerprint: String
    let expiresAt: Date

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static var current: Self? {
        guard Config.Backend.isProductionReady,
              let url = URL(string: Config.Backend.normalizedBaseURL),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        let token: String
        let email: String
        let expiry: String
        if AppleAuthManager.shared.isAuthenticated,
           let stored = try? KeychainStore.loadCodable(GunnAireApplicationSession.self, account: "GunnAireAppleApplicationSession"),
           stored.token == AppleAuthManager.shared.sessionToken {
            (token, email, expiry) = (stored.token, stored.email, stored.expiresAt)
        } else if let stored = try? KeychainStore.loadCodable(GunnAireGoogleApplicationSession.self, account: "GunnAireGoogleApplicationSession"),
                  stored.token == GoogleAuthManager.shared.applicationSessionToken {
            (token, email, expiry) = (stored.token, stored.email, stored.expiresAt)
        } else { return nil }
        guard !token.isEmpty, let expiresAt = CompanyWorkspaceClock.parse(expiry), expiresAt > Date(),
              AppAccess.normalizedEmail(email) == AppAccess.normalizedEmail(AppIdentity.currentEmail) else { return nil }
        return Self(backendOrigin: Config.Backend.normalizedBaseURL, email: AppAccess.normalizedEmail(email), tokenFingerprint: digest(token), expiresAt: expiresAt)
    }
}

enum CompanyWorkspaceClock {
    static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

enum CompanyWorkspaceRequestPolicy {
    static func needsWorkspaceProof(path: String) -> Bool {
        !["/api/auth/apple", "/api/auth/google", "/api/auth/logout", "/api/session", "/api/workspace", "/api/workspace/bind"].contains(path)
    }
}

/// Stored in device-only Keychain, not editable preferences. The SQLite store
/// UUID anchors approval to the actual file without attaching CloudKit first.
struct CompanyWorkspaceStoreRegistration: Codable, Equatable {
    let backendOrigin: String
    let binding: CompanyCloudKitBinding
    let storeUUID: String

    func matches(session: CompanyWorkspaceSession, binding: CompanyCloudKitBinding, storeUUID: String?) -> Bool {
        self.backendOrigin == session.backendOrigin && self.binding == binding &&
        !self.storeUUID.isEmpty && self.storeUUID == storeUUID
    }
}

struct CompanyWorkspaceLease: Codable {
    let session: CompanyWorkspaceSession
    let binding: CompanyCloudKitBinding
    let user: BackendAppUserRecord
    let verifiedAt: Date

    var expiresAt: Date { min(session.expiresAt, verifiedAt.addingTimeInterval(86_400)) }

    func isValid(for session: CompanyWorkspaceSession, accountHash: String, environment: String, now: Date) -> Bool {
        self.session == session && now < expiresAt && now >= verifiedAt &&
        binding.isValid && binding.environment == environment && binding.cloudAccountHash == accountHash &&
        user.isActive && AppAccess.normalizedEmail(user.email) == session.email && AppUserRole(rawValue: user.role) != nil
    }
}

enum CompanyWorkspaceFailure: String, Error, LocalizedError, Equatable {
    case configuration, signIn, accountUnavailable, differentWorkspace, administratorRequired
    case storage, server, restartRequired

    var errorDescription: String? {
        switch self {
        case .configuration: "This app could not verify its secure server or signed CloudKit environment. Contact your administrator for the current app build."
        case .signIn: "Sign in again with your approved business account to verify access."
        case .accountUnavailable: "Connect briefly to verify the approved business iCloud account. Your saved work has not been removed."
        case .differentWorkspace: "This device's saved work or iCloud account belongs to a different workspace. Do not enter new work here. An administrator must review the data before moving it."
        case .administratorRequired: "An administrator must approve this company device and its existing saved work before staff can use it."
        case .storage: "The saved workspace could not be verified. Your existing data was not removed. Contact support before reinstalling the app."
        case .server: "The business server could not verify this workspace. Check the connection and confirm that the current backend version is deployed, then try again."
        case .restartRequired: "The iCloud account changed while the app was open. Close and reopen GunnAire Ops to verify the workspace before continuing. Your saved work is retained."
        }
    }
}

enum CompanyWorkspacePhase: Equatable {
    case checking
    case needsApproval(hasSavedStore: Bool)
    case ready
    case blocked(CompanyWorkspaceFailure)
}

struct CompanyCloudKitAccount {
    let environment: String
    let accountHash: String
}

/// Only reads metadata. No ModelContainer, model fetch, or mirroring is needed
/// to distinguish an approved store from an unrelated restored/copied file.
enum CompanyWorkspaceStore {
    static var url: URL { ModelConfiguration(schema: GunnAireModelSchema.schema, cloudKitDatabase: .none).url }

    static func identity(at url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType, at: url, options: [NSReadOnlyPersistentStoreOption: true]
        )
        guard let identifier = metadata[NSStoreUUIDKey] as? String, !identifier.isEmpty else {
            throw CompanyWorkspaceFailure.storage
        }
        return identifier
    }

    static func open() throws -> ModelContainer {
        try ModelContainer(for: GunnAireModelSchema.schema, configurations: [
            GunnAireCloudKit.productionModelConfiguration(for: GunnAireModelSchema.schema)
        ])
    }
}

struct CompanyWorkspaceDependencies {
    var session: () -> CompanyWorkspaceSession?
    var account: () async throws -> CompanyCloudKitAccount
    var fetchWorkspace: () async throws -> BackendCompanyWorkspaceResponse
    var approve: (CompanyCloudKitApprovalRequest) async throws -> CompanyCloudKitBinding
    var readRegistration: () throws -> CompanyWorkspaceStoreRegistration?
    var saveRegistration: (CompanyWorkspaceStoreRegistration) throws -> Void
    var readLease: () throws -> CompanyWorkspaceLease?
    var saveLease: (CompanyWorkspaceLease?) throws -> Void
    var storeIdentity: () throws -> String?
    var openStore: () throws -> ModelContainer
    var now: () -> Date
    var sleep: (TimeInterval) async throws -> Void = { interval in
        try await Task.sleep(for: .seconds(interval))
    }
    var clearContinuations: () -> Void = {}

    static var live: Self {
        Self(
            session: { CompanyWorkspaceSession.current },
            account: { try await CompanyCloudKitRuntimeAccount.current() },
            fetchWorkspace: { try await GunnAireBackendService.fetchCompanyWorkspace() },
            approve: { try await GunnAireBackendService.approveCompanyCloudKitWorkspace($0) },
            readRegistration: { try KeychainStore.loadCodable(CompanyWorkspaceStoreRegistration.self, account: "GunnAireCompanyStoreRegistration") },
            saveRegistration: { try KeychainStore.saveCodable($0, account: "GunnAireCompanyStoreRegistration") },
            readLease: { try KeychainStore.loadCodable(CompanyWorkspaceLease.self, account: "GunnAireCompanyWorkspaceLease") },
            saveLease: { lease in
                if let lease { try KeychainStore.saveCodable(lease, account: "GunnAireCompanyWorkspaceLease") }
                else { try KeychainStore.remove(account: "GunnAireCompanyWorkspaceLease") }
            },
            storeIdentity: { try CompanyWorkspaceStore.identity(at: CompanyWorkspaceStore.url) },
            openStore: { try CompanyWorkspaceStore.open() },
            now: { Date() },
            clearContinuations: {
                FieldPaymentHandoff.shared.end()
                GunnAireAppIntentRouter.discardAllPendingPayloads()
            }
        )
    }
}

@MainActor
final class CompanyWorkspaceAccessController: ObservableObject {
    static let shared = CompanyWorkspaceAccessController(dependencies: .live, observesAccountChanges: true)
    @Published private(set) var phase: CompanyWorkspacePhase = .checking
    private(set) var generation = UUID()
    private var container: ModelContainer?
    private var activeLease: CompanyWorkspaceLease?
    private var pending: (CompanyWorkspaceSession, BackendCompanyWorkspaceResponse, CompanyCloudKitAccount)?
    private var mustRestart = false
    private var refreshTask: (id: UUID, task: Task<Void, Never>)?
    private var expiryTask: Task<Void, Never>?
    private let dependencies: CompanyWorkspaceDependencies
    private var accountObserver: NSObjectProtocol?
    #if DEBUG
    private var testContainer: ModelContainer?
    func installTestContainer(_ container: ModelContainer) {
        guard GunnAireCloudKit.usesTestDatabase else { return }
        testContainer = container
    }
    #endif

    init(dependencies: CompanyWorkspaceDependencies, observesAccountChanges: Bool = false) {
        self.dependencies = dependencies
        if observesAccountChanges {
            accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.invalidate(accountChanged: true)
                }
            }
        }
    }

    deinit {
        expiryTask?.cancel()
        refreshTask?.task.cancel()
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
    }

    var authorizedContainer: ModelContainer? {
        #if DEBUG
        if GunnAireCloudKit.usesTestDatabase, let testContainer { return testContainer }
        #endif
        guard phase == .ready, !mustRestart, let lease = activeLease,
              let session = dependencies.session(),
              lease.isValid(for: session, accountHash: lease.binding.cloudAccountHash,
                            environment: lease.binding.environment, now: dependencies.now()) else { return nil }
        return container
    }

    var operationStamp: CompanyWorkspaceOperationStamp? {
        guard authorizedContainer != nil, let lease = activeLease else { return nil }
        return CompanyWorkspaceOperationStamp(generation: generation, session: lease.session)
    }

    func invalidate(accountChanged: Bool = false, reason: CompanyWorkspaceFailure = .signIn, preserveCachedLease: Bool = false) {
        generation = UUID()
        refreshTask?.task.cancel()
        refreshTask = nil
        expiryTask?.cancel()
        expiryTask = nil
        activeLease = nil
        pending = nil
        container = nil
        mustRestart = mustRestart || accountChanged
        dependencies.clearContinuations()
        if !preserveCachedLease { try? dependencies.saveLease(nil) }
        phase = .blocked(mustRestart ? .restartRequired : reason)
    }

    /// Also called when foregrounding or changing the system clock so a
    /// mounted workspace never relies only on a non-observable getter.
    func enforceAccessDeadline() {
        guard activeLease != nil else { return }
        if authorizedContainer == nil { invalidate() }
    }

    func refresh() async {
        enforceAccessDeadline()
        if let work = refreshTask {
            await work.task.value
            return
        }
        let id = UUID()
        let task = Task { await refreshWorkspace() }
        refreshTask = (id, task)
        await task.value
        if refreshTask?.id == id { refreshTask = nil }
    }

    private func refreshWorkspace() async {
        guard !Task.isCancelled else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTestWorkspaceProofMismatch") {
            phase = .blocked(.differentWorkspace)
            return
        }
        #endif
        guard !mustRestart else { phase = .blocked(.restartRequired); return }
        guard let session = dependencies.session() else { invalidate(); return }
        let operation = generation
        if authorizedContainer == nil { phase = .checking }
        var verifiedAccount = false
        do {
            let account = try await dependencies.account()
            verifiedAccount = true
            guard isCurrent(operation, session: session) else { return }
            do {
                let response = try await dependencies.fetchWorkspace()
                guard isCurrent(operation, session: session) else { return }
                guard response.user.isActive, AppAccess.normalizedEmail(response.user.email) == session.email,
                      AppUserRole(rawValue: response.user.role) != nil,
                      response.workspace.containerID == GunnAireCloudKit.containerIdentifier else {
                    throw CompanyWorkspaceFailure.signIn
                }
                pending = (session, response, account)
                let matching = response.workspace.bindings.filter { $0.environment == account.environment }
                guard matching.count <= 1 else { throw CompanyWorkspaceFailure.differentWorkspace }
                guard let binding = response.workspace.binding(for: account.environment) else {
                    guard matching.isEmpty, response.workspace.bindings.allSatisfy({ $0.isValid && $0.companyID == response.workspace.companyID }) else {
                        throw CompanyWorkspaceFailure.differentWorkspace
                    }
                    try requireApproval(user: response.user)
                    return
                }
                guard binding.cloudAccountHash == account.accountHash else { throw CompanyWorkspaceFailure.differentWorkspace }
                let lease = CompanyWorkspaceLease(session: session, binding: binding, user: response.user, verifiedAt: dependencies.now())
                try unlock(lease, allowLegacyAdoption: false)
            } catch {
                guard isCurrent(operation, session: session) else { return }
                // Only transport failure can use an existing bounded lease.
                // A 401/403/404, changed company, or malformed response cannot.
                if Self.isConnectivityFailure(error), let lease = try dependencies.readLease(),
                   lease.isValid(for: session, accountHash: account.accountHash, environment: account.environment, now: dependencies.now()),
                   let registration = try dependencies.readRegistration(),
                   registration.matches(session: session, binding: lease.binding, storeUUID: try dependencies.storeIdentity()) {
                    try unlock(lease, allowLegacyAdoption: false, isOffline: true)
                } else { throw error }
            }
        } catch {
            guard isCurrent(operation, session: session) else { return }
            invalidate(reason: Self.failure(for: error, verifiedAccount: verifiedAccount),
                       preserveCachedLease: Self.isConnectivityFailure(error))
        }
    }

    func prepareForIntent() async {
        if authorizedContainer == nil { await refresh() }
    }

    private func requireApproval(user: BackendAppUserRecord) throws {
        guard user.role == AppUserRole.admin.rawValue else { throw CompanyWorkspaceFailure.administratorRequired }
        // Even an administrator cannot relabel a previously registered store.
        guard try dependencies.readRegistration() == nil else { throw CompanyWorkspaceFailure.differentWorkspace }
        phase = .needsApproval(hasSavedStore: try dependencies.storeIdentity() != nil)
    }

    func approve(confirmed: Bool) async {
        guard confirmed, case .needsApproval = phase, let (session, response, account) = pending,
              dependencies.session() == session, !mustRestart else { return }
        let operation = generation
        phase = .checking
        do {
            let currentAccount = try await dependencies.account()
            guard currentAccount.accountHash == account.accountHash, currentAccount.environment == account.environment else {
                throw CompanyWorkspaceFailure.differentWorkspace
            }
            guard isCurrent(operation, session: session) else { return }
            let binding = try await dependencies.approve(CompanyCloudKitApprovalRequest(
                companyID: response.workspace.companyID, containerID: response.workspace.containerID,
                environment: account.environment, cloudAccountHash: account.accountHash, confirmCompanyDataOwnership: true
            ))
            guard isCurrent(operation, session: session) else { return }
            guard binding.isValid, binding.companyID == response.workspace.companyID,
                  binding.environment == account.environment, binding.cloudAccountHash == account.accountHash else {
                throw CompanyWorkspaceFailure.differentWorkspace
            }
            let lease = CompanyWorkspaceLease(session: session, binding: binding, user: response.user, verifiedAt: dependencies.now())
            try unlock(lease, allowLegacyAdoption: true)
        } catch {
            guard isCurrent(operation, session: session) else { return }
            invalidate(reason: Self.failure(for: error, verifiedAccount: true))
        }
    }

    private func unlock(_ lease: CompanyWorkspaceLease, allowLegacyAdoption: Bool, isOffline: Bool = false) throws {
        guard dependencies.session() == lease.session, !mustRestart,
              lease.isValid(for: lease.session, accountHash: lease.binding.cloudAccountHash,
                            environment: lease.binding.environment, now: dependencies.now()) else {
            throw CompanyWorkspaceFailure.signIn
        }
        let identity = try dependencies.storeIdentity()
        if let registration = try dependencies.readRegistration() {
            guard registration.matches(session: lease.session, binding: lease.binding, storeUUID: identity) else {
                throw CompanyWorkspaceFailure.differentWorkspace
            }
        } else if identity != nil && !allowLegacyAdoption {
            try requireApproval(user: lease.user)
            return
        } else if isOffline { throw CompanyWorkspaceFailure.storage }

        let opened = try container ?? dependencies.openStore()
        guard let storeUUID = try dependencies.storeIdentity() else { throw CompanyWorkspaceFailure.storage }
        if try dependencies.readRegistration() == nil {
            try dependencies.saveRegistration(CompanyWorkspaceStoreRegistration(backendOrigin: lease.session.backendOrigin, binding: lease.binding, storeUUID: storeUUID))
        }
        let context = opened.mainContext
        let users = try context.fetch(FetchDescriptor<AppUser>())
        let technicians = try context.fetch(FetchDescriptor<Technician>())
        _ = GunnAireBackendService.applyVerifiedUser(lease.user, into: context, currentUsers: users, technicians: technicians)
        FieldFormTemplate.ensureStarterTemplates(in: context)
        try context.save()
        if !isOffline { try dependencies.saveLease(lease) }
        if let activeLease, activeLease.user.role != lease.user.role {
            // Invalidate privileged sheets and late responses when the server
            // changes permissions, even if the user's session token is stable.
            generation = UUID()
            dependencies.clearContinuations()
        }
        container = opened
        activeLease = lease
        pending = nil
        phase = .ready
        scheduleExpiry(for: lease)
    }

    private func isCurrent(_ operation: UUID, session: CompanyWorkspaceSession) -> Bool {
        guard operation == generation, !Task.isCancelled else { return false }
        guard dependencies.session() == session else { invalidate(); return false }
        return true
    }

    private func scheduleExpiry(for lease: CompanyWorkspaceLease) {
        expiryTask?.cancel()
        let operation = generation
        let interval = max(0, lease.expiresAt.timeIntervalSince(dependencies.now()))
        let sleep = dependencies.sleep
        expiryTask = Task { [weak self] in
            do { try await sleep(interval) } catch { return }
            guard !Task.isCancelled, let self, self.generation == operation else { return }
            self.enforceAccessDeadline()
        }
    }

    static func failure(for error: Error, verifiedAccount: Bool) -> CompanyWorkspaceFailure {
        if let failure = error as? CompanyWorkspaceFailure { return failure }
        if let backend = error as? GunnAireBackendError {
            switch backend {
            case .missingBusinessIdentity: return .signIn
            case .notConfigured, .invalidURL: return .configuration
            case .server(let status, _):
                if status == 401 || status == 403 { return .signIn }
                if status == 409 { return .differentWorkspace }
            default: break
            }
        }
        return verifiedAccount ? .server : .accountUnavailable
    }

    static func isConnectivityFailure(_ error: Error) -> Bool {
        if let error = error as? CKError {
            return [.networkFailure, .networkUnavailable].contains(error.code)
        }
        guard let error = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code)
    }
}
