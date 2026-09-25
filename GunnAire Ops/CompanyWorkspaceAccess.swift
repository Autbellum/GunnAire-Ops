import Foundation
import CryptoKit
import SwiftData
import CoreData
import CloudKit
import Combine

nonisolated struct CompanyWorkspaceSession: Codable, Equatable, Sendable {
    let backendOrigin: String
    let email: String
    let tokenFingerprint: String
    let expiresAt: Date

    nonisolated static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Build once on a background task immediately after a successful
    /// Keychain restore or save. Render-time authorization never parses a
    /// date, hashes a token, or reads secure storage.
    nonisolated static func validated(token: String, email: String, expiry: String,
                                      backendOrigin: String) -> Self? {
        let normalizedEmail = AppAccess.normalizedEmail(email)
        guard !token.isEmpty, let expiresAt = CompanyWorkspaceClock.parse(expiry),
              expiresAt > Date(), !normalizedEmail.isEmpty else { return nil }
        return Self(backendOrigin: backendOrigin,
                    email: normalizedEmail,
                    tokenFingerprint: digest(token), expiresAt: expiresAt)
    }

    @MainActor static var current: Self? {
        guard Config.Backend.isProductionReady,
              let url = URL(string: Config.Backend.normalizedBaseURL),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        let proof: Self?
        let apple = AppleAuthManager.shared
        let google = GoogleAuthManager.shared
        if apple.isAuthenticated,
           let stored = apple.businessApplicationSessionSnapshot,
           stored.token == apple.sessionToken {
            proof = apple.workspaceSessionProof
        } else if let stored = google.businessApplicationSessionSnapshot,
                  stored.token == google.applicationSessionToken {
            proof = google.workspaceSessionProof
        } else { return nil }
        guard let proof, proof.backendOrigin == Config.Backend.normalizedBaseURL,
              proof.expiresAt > Date(),
              proof.email == AppAccess.normalizedEmail(AppIdentity.currentEmail) else { return nil }
        return proof
    }
}

/// A Keychain-independent view of every in-memory input that can change the
/// result of `CompanyWorkspaceSession.current` between two reads: the Apple
/// session token, the Google application-session token, Apple's authenticated
/// flag, and the signed-in email. `AppleAuthManager` and `GoogleAuthManager`
/// update these in the same call that writes or removes the Keychain item, so
/// a changed token is observed here before any Keychain read happens.
enum CompanyWorkspaceSessionSignal {
    static var current: String {
        [
            AppleAuthManager.shared.isAuthenticated ? "apple" : "",
            AppleAuthManager.shared.sessionToken ?? "",
            GoogleAuthManager.shared.applicationSessionToken ?? "",
            AppIdentity.currentEmail ?? ""
        ].joined(separator: "\u{1F}")
    }
}

/// Shared formatters behind a lock: this parser runs on every session read
/// and inside the per-minute replica capture, where building two
/// `ISO8601DateFormatter`s per call loaded ICU tables each time (Rule A).
nonisolated enum CompanyWorkspaceClock {
    private static let lock = NSLock()
    private static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let withInternetDateTime = ISO8601DateFormatter()

    static func parse(_ text: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return withFractionalSeconds.date(from: text) ?? withInternetDateTime.date(from: text)
    }

    /// Internet date-time with fractional seconds, the form the replica
    /// contract stores; the inverse of `parse` for such strings.
    static func fractionalString(from date: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return withFractionalSeconds.string(from: date)
    }
}

enum CompanyWorkspaceRequestPolicy {
    static func needsWorkspaceProof(path: String) -> Bool {
        !["/api/auth/apple", "/api/auth/google", "/api/auth/logout", "/api/session", "/api/workspace", "/api/workspace/bind"].contains(path)
    }
}

/// Stored in device-only Keychain, not editable preferences. The SQLite store
/// UUID anchors approval to the actual file without attaching CloudKit first.
nonisolated struct CompanyWorkspaceStoreRegistration: Codable, Equatable, Sendable {
    let backendOrigin: String
    let binding: CompanyCloudKitBinding
    let storeUUID: String

    func matches(session: CompanyWorkspaceSession, binding: CompanyCloudKitBinding, storeUUID: String?) -> Bool {
        self.backendOrigin == session.backendOrigin && self.binding == binding &&
        !self.storeUUID.isEmpty && self.storeUUID == storeUUID
    }
}

nonisolated struct CompanyWorkspaceLease: Codable, Sendable {
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

nonisolated enum CompanyWorkspaceFailure: String, Error, LocalizedError, Equatable, Sendable {
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

nonisolated struct CompanyCloudKitAccount: Sendable {
    let environment: String
    let accountHash: String
    /// Available only from live CKContainer lookup; never used as a substitute
    /// for the immutable hash or for private-store ownership verification.
    let recordName: String?
    init(environment: String, accountHash: String, recordName: String? = nil) {
        self.environment = environment; self.accountHash = accountHash; self.recordName = recordName
    }
}

/// Only reads metadata. No ModelContainer, model fetch, or mirroring is needed
/// to distinguish an approved store from an unrelated restored/copied file.
nonisolated enum CompanyWorkspaceStore {
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

/// Swift's default actor isolation can place even a ModelActor executor on
/// the physical main thread. Create and use a private context on one dedicated
/// serial queue for this unlock; no context or model crosses the queue edge.
nonisolated private final class CompanyWorkspaceWorkCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

nonisolated struct CompanyWorkspaceUnlockMaintenance: Sendable {
    let modelContainer: ModelContainer

    nonisolated struct VerifiedUserProjection: Sendable {
        nonisolated struct Record: Sendable {
            let id: PersistentIdentifier
            let email: String
            let roleRawValue: String
            let isActive: Bool
        }

        let records: [Record]
        let ranOnMainThread: Bool
    }

    func prepareVerifiedUser(email: String, role: String, isActive: Bool, createdAt: String?,
                             seedStarterTemplates: Bool) async throws -> VerifiedUserProjection {
        let cancellation = CompanyWorkspaceWorkCancellation()
        let queue = DispatchQueue(label: "com.gunnaire.workspace.unlock.\(UUID().uuidString)", qos: .userInitiated)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try cancellation.check()
                        let context = ModelContext(modelContainer)
                        context.autosaveEnabled = false
                        let users = try context.fetch(FetchDescriptor<AppUser>())
                        let technicians = try context.fetch(FetchDescriptor<Technician>())
                        let user = BackendAppUserRecord(email: email, role: role,
                                                        isActive: isActive, createdAt: createdAt)
                        let reconciled = GunnAireBackendService.applyVerifiedUser(
                            user, into: context, currentUsers: users, technicians: technicians
                        )
                        try cancellation.check()
                        if seedStarterTemplates { FieldFormTemplate.ensureStarterTemplates(in: context) }
                        try cancellation.check()
                        if context.hasChanges { try context.save() }
                        let verifiedEmail = AppAccess.normalizedEmail(email)
                        let result = VerifiedUserProjection(
                            records: reconciled.filter { AppAccess.normalizedEmail($0.email) == verifiedEmail }
                                .map { .init(id: $0.persistentModelID, email: $0.email,
                                             roleRawValue: $0.roleRawValue, isActive: $0.isActive) },
                            ranOnMainThread: Thread.isMainThread
                        )
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
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
    /// Production Keychain access suspends the UI actor. Test fixtures retain
    /// the synchronous hooks so their state stays on their owning actor.
    var readRegistrationAsync: (() async throws -> CompanyWorkspaceStoreRegistration?)? = nil
    var saveRegistrationAsync: ((CompanyWorkspaceStoreRegistration) async throws -> Void)? = nil
    var readLeaseAsync: (() async throws -> CompanyWorkspaceLease?)? = nil
    var saveLeaseAsync: ((CompanyWorkspaceLease?) async throws -> Void)? = nil
    var sessionStorageValidAsync: (() async -> Bool)? = nil
    var clearSessionProofs: () -> Void = {}
    /// Both read the store file, and `openStore` loads it with CloudKit
    /// mirroring attached; `unlock` runs them on a background task so the
    /// "Verifying company access" screen keeps drawing while the store opens.
    var storeIdentity: @Sendable () throws -> String?
    var openStore: @Sendable () throws -> ModelContainer
    var now: () -> Date
    var sleep: (TimeInterval) async throws -> Void = { interval in
        try await Task.sleep(for: .seconds(interval))
    }
    var clearContinuations: () -> Void = {}
    /// Cheap identity inputs compared before a memoized `session()` result is
    /// reused; any change forces a fresh read. See `CompanyWorkspaceSessionSignal`.
    var sessionSignal: () -> String = { CompanyWorkspaceSessionSignal.current }

    static var live: Self {
        Self(
            session: { CompanyWorkspaceSession.current },
            account: { try await CompanyCloudKitRuntimeAccount.current() },
            fetchWorkspace: { try await GunnAireBackendService.fetchCompanyWorkspace() },
            approve: { try await GunnAireBackendService.approveCompanyCloudKitWorkspace($0) },
            readRegistration: { throw CompanyWorkspaceFailure.storage },
            saveRegistration: { _ in throw CompanyWorkspaceFailure.storage },
            readLease: { throw CompanyWorkspaceFailure.storage },
            saveLease: { _ in throw CompanyWorkspaceFailure.storage },
            readRegistrationAsync: {
                try await Task.detached(priority: .userInitiated) {
                    try KeychainStore.loadCodable(CompanyWorkspaceStoreRegistration.self, account: "GunnAireCompanyStoreRegistration")
                }.value
            },
            saveRegistrationAsync: { registration in
                try await Task.detached(priority: .userInitiated) {
                    try KeychainStore.saveCodable(registration, account: "GunnAireCompanyStoreRegistration")
                }.value
            },
            readLeaseAsync: {
                try await Task.detached(priority: .userInitiated) {
                    try KeychainStore.loadCodable(CompanyWorkspaceLease.self, account: "GunnAireCompanyWorkspaceLease")
                }.value
            },
            saveLeaseAsync: { lease in
                try await Task.detached(priority: .userInitiated) {
                    if let lease { try KeychainStore.saveCodable(lease, account: "GunnAireCompanyWorkspaceLease") }
                    else { try KeychainStore.remove(account: "GunnAireCompanyWorkspaceLease") }
                }.value
            },
            sessionStorageValidAsync: {
                let apple = AppleAuthManager.shared
                if apple.isAuthenticated,
                   let expected = apple.businessApplicationSessionSnapshot,
                   expected.token == apple.sessionToken {
                    do {
                        let stored = try await Task.detached(priority: .userInitiated) {
                            try KeychainStore.loadCodable(GunnAireApplicationSession.self,
                                                          account: "GunnAireAppleApplicationSession")
                        }.value
                        return stored == expected
                    } catch { return false }
                }
                let google = GoogleAuthManager.shared
                guard let expected = google.businessApplicationSessionSnapshot,
                      expected.token == google.applicationSessionToken else { return false }
                do {
                    let stored = try await Task.detached(priority: .userInitiated) {
                        try KeychainStore.loadCodable(GunnAireGoogleApplicationSession.self,
                                                      account: "GunnAireGoogleApplicationSession")
                    }.value
                    return stored == expected
                } catch { return false }
            },
            clearSessionProofs: {
                AppleAuthManager.shared.discardBusinessSessionProof()
                GoogleAuthManager.shared.discardBusinessSessionProof()
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
    /// Which check produced the most recent .differentWorkspace failure, with
    /// 8-character fingerprints of the accounts, bindings or store involved.
    /// That failure covers five distinct conditions and its one sentence made
    /// the owner's iPad undiagnosable from outside. No account or token content.
    @Published private(set) var lastMismatchDetail: String = ""
    @Published private(set) var phase: CompanyWorkspacePhase = .checking
    /// Surfaced directly in the "Verifying company access…" spinner so a
    /// stuck verification can be localized to a specific step without needing
    /// console access to the device — read the on-screen text and report it.
    @Published private(set) var diagnosticStep: String = "Starting…"
    private(set) var generation = UUID() {
        didSet {
            invalidateMutationPermits()
        }
    }
    private var mutationEpoch = CompanyWorkspaceMutationEpoch()

    /// Authentication owners call this before replacing or clearing in-memory
    /// business credentials; SwiftUI's later onChange is too late for a worker.
    func invalidateMutationPermits() {
        mutationEpoch.invalidate()
        mutationEpoch = CompanyWorkspaceMutationEpoch()
    }
    private var container: ModelContainer?
    private var activeLease: CompanyWorkspaceLease?
    private var pending: (CompanyWorkspaceSession, BackendCompanyWorkspaceResponse, CompanyCloudKitAccount)?
    private var mustRestart = false
    private var accountAvailabilityRequiresVerification = false
    private var refreshTask: (id: UUID, task: Task<Void, Never>)?
    private var expiryTask: Task<Void, Never>?
    private var leaseWriteTail: Task<Void, Never>?
    private let dependencies: CompanyWorkspaceDependencies
    private var accountObserver: NSObjectProtocol?
    /// The render-time getters (`verifiedUser`, `verifiedRole`, `operationStamp`,
    /// `verifiedCompanyID`) are evaluated hundreds of times per SwiftUI body
    /// pass. The session is derived from prevalidated in-memory authentication
    /// snapshots, then memoized for at most `sessionMemoLifetime`. It never extends
    /// authority: lease expiry, the email match and the clock are evaluated on
    /// every call; the entry is discarded when the in-memory session tokens or
    /// signed-in email change, when the clock moves backwards, and whenever
    /// `invalidate()` or `unlock` run; and every verification path
    /// (`enforceAccessDeadline`, `refresh`, `unlock`, `isCurrent`) reads the
    /// session fresh.
    static let sessionMemoLifetime: TimeInterval = 1
    private var sessionMemo: (signal: String, readAt: Date, session: CompanyWorkspaceSession?)?
    private var starterTemplatesGeneration: UUID?
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
                    CompanyCloudKitRuntimeAccount.invalidateCache()
                    // This notification can accompany recovery or a different
                    // account. SwiftData and staff tasks may retain the prior
                    // mirrored container, so only a fresh process can prove
                    // that every old account-bound reference is retired.
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
        // State checks first: while the workspace is not ready there is no
        // lease to compare a session against, so no Keychain read is warranted
        // (the gate re-renders several times per verification).
        guard phase == .ready, !mustRestart, activeLease != nil else { return nil }
        return authorizedContainer(for: memoizedSession())
    }

    private func authorizedContainer(for session: CompanyWorkspaceSession?) -> ModelContainer? {
        #if DEBUG
        if GunnAireCloudKit.usesTestDatabase, let testContainer { return testContainer }
        #endif
        guard phase == .ready, !mustRestart, let lease = activeLease, let session,
              lease.isValid(for: session, accountHash: lease.binding.cloudAccountHash,
                            environment: lease.binding.environment, now: dependencies.now()) else { return nil }
        return container
    }

    private func memoizedSession() -> CompanyWorkspaceSession? {
        let now = dependencies.now()
        let signal = dependencies.sessionSignal()
        if let memo = sessionMemo, memo.signal == signal, now >= memo.readAt,
           now.timeIntervalSince(memo.readAt) < Self.sessionMemoLifetime {
            return memo.session
        }
        let session = dependencies.session()
        sessionMemo = (signal, now, session)
        return session
    }

    private func forgetSessionMemo() {
        sessionMemo = nil
    }

    var operationStamp: CompanyWorkspaceOperationStamp? {
        guard authorizedContainer != nil, let lease = activeLease else { return nil }
        return CompanyWorkspaceOperationStamp(generation: generation, session: lease.session)
    }

    var verifiedCompanyID: UUID? {
        guard authorizedContainer != nil else { return nil }
        return activeLease?.binding.companyID
    }

    var verifiedRole: AppUserRole? {
        verifiedUser.flatMap { AppUserRole(rawValue: $0.role) }
    }

    /// Issued only after the caller's current administrator check. The worker
    /// must consume this permit immediately before its background save begins.
    func customerCleanupPermit(generation expected: UUID, container expectedContainer: ModelContainer) throws -> CustomerCleanupCommitPermit {
        let now = dependencies.now()
        guard generation == expected, !Task.isCancelled,
              let lease = activeLease, verifiedRole == .admin,
              authorizedContainer(for: dependencies.session()) === expectedContainer else {
            throw CustomerCalendarCleanupError.accessChanged
        }
        return CustomerCleanupCommitPermit(epoch: mutationEpoch, issuedAt: now,
            expiresAt: min(lease.expiresAt, now.addingTimeInterval(5)))
    }

    /// Obtained only from the current bounded server lease, never SwiftData.
    /// Expiry, logout, account changes and revocation remove this authority.
    var verifiedUser: BackendAppUserRecord? {
        guard authorizedContainer != nil, let user = activeLease?.user, user.isActive else { return nil }
        return user
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
        forgetSessionMemo()
        mustRestart = mustRestart || accountChanged
        dependencies.clearContinuations()
        if !preserveCachedLease { clearSavedLease() }
        phase = .blocked(mustRestart ? .restartRequired : reason)
    }

    private func readRegistration() async throws -> CompanyWorkspaceStoreRegistration? {
        if let read = dependencies.readRegistrationAsync { return try await read() }
        return try dependencies.readRegistration()
    }

    private func saveRegistration(_ registration: CompanyWorkspaceStoreRegistration) async throws {
        if let save = dependencies.saveRegistrationAsync { try await save(registration) }
        else { try dependencies.saveRegistration(registration) }
    }

    private func readLease() async throws -> CompanyWorkspaceLease? {
        await leaseWriteTail?.value
        if let read = dependencies.readLeaseAsync { return try await read() }
        return try dependencies.readLease()
    }

    private func saveLease(_ lease: CompanyWorkspaceLease?) async throws {
        if let save = dependencies.saveLeaseAsync {
            let previous = leaseWriteTail
            let write = Task<Void, Error> {
                await previous?.value
                try await save(lease)
            }
            leaseWriteTail = Task { _ = try? await write.value }
            try await write.value
        } else {
            try dependencies.saveLease(lease)
        }
    }

    private func clearSavedLease() {
        if let save = dependencies.saveLeaseAsync {
            let previous = leaseWriteTail
            leaseWriteTail = Task {
                await previous?.value
                try? await save(nil)
            }
        } else {
            try? dependencies.saveLease(nil)
        }
    }

    /// Also called when foregrounding or changing the system clock so a
    /// mounted workspace never relies only on a non-observable getter.
    func enforceAccessDeadline() {
        guard activeLease != nil else { return }
        // A deadline check must observe the live session, never the memo.
        forgetSessionMemo()
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

    /// A foreground check catches an externally removed or rotated Keychain
    /// session without bringing secure-storage I/O into SwiftUI body reads.
    /// A replacement sign-in during the suspended read owns the new state.
    func revalidateSessionStorageOnForeground() async {
        guard phase == .ready, let validate = dependencies.sessionStorageValidAsync,
              let session = dependencies.session() else { return }
        let operation = generation
        let signal = dependencies.sessionSignal()
        let valid = await validate()
        guard operation == generation, signal == dependencies.sessionSignal(),
              dependencies.session() == session else {
            enforceAccessDeadline()
            return
        }
        guard !valid else { return }
        dependencies.clearSessionProofs()
        invalidate(reason: .signIn)
    }

    /// How long a server-verified lease is trusted before the workspace is
    /// re-verified with the server: the lease itself is bounded to 24 hours,
    /// so re-verification at 23 hours renews it before it lapses. Launches and
    /// foreground activations inside the interval use the lease; sign-out,
    /// revocation and expiry are still enforced locally by
    /// `enforceAccessDeadline` on every activation and by the backend on every
    /// proof-bearing request.
    static let verificationInterval: TimeInterval = 23 * 60 * 60

    /// Launch and foreground path: after the local deadline check, a workspace
    /// whose lease was verified within `maxAge` stays open (or is opened from
    /// the saved lease without a network round-trip); anything older, or a
    /// lease that does not fit this session and store, runs a full `refresh()`.
    func refreshIfStale(maxAge: TimeInterval) async {
        enforceAccessDeadline()
        let now = dependencies.now()
        if authorizedContainer != nil, let lease = activeLease, now.timeIntervalSince(lease.verifiedAt) < maxAge {
            return
        }
        let operation = generation
        if activeLease == nil, !mustRestart, !accountAvailabilityRequiresVerification,
           let session = dependencies.session(),
           let lease = try? await readLease(),
           now.timeIntervalSince(lease.verifiedAt) < maxAge,
           lease.isValid(for: session, accountHash: lease.binding.cloudAccountHash,
                         environment: lease.binding.environment, now: now),
           let registration = try? await readRegistration() {
            guard isCurrent(operation, session: session) else { return }
            do {
                let storeUUID = try await Self.offMain(dependencies.storeIdentity)
                guard isCurrent(operation, session: session) else { return }
                if registration.matches(session: session, binding: lease.binding, storeUUID: storeUUID) {
                    lastMismatchDetail = ""
                    try await unlock(lease, allowLegacyAdoption: false, isOffline: true)
                    return
                }
            } catch {
                // A stale or unusable saved lease falls through to a full verification.
            }
            guard isCurrent(operation, session: session) else { return }
        }
        await refresh()
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
        lastMismatchDetail = ""
        let operation = generation
        if authorizedContainer(for: session) == nil { phase = .checking }
        diagnosticStep = "Checking iCloud account…"
        var verifiedAccount = false
        do {
            let account: CompanyCloudKitAccount
            do {
                account = try await dependencies.account()
            } catch {
                guard isCurrent(operation, session: session) else { return }
                // A CloudKit stall or a network outage at the account step is
                // transport failure, like an unreachable server: a lease that
                // is still within its bound keeps the workspace open offline.
                // Anything else (no iCloud account, configuration) still fails.
                if !accountAvailabilityRequiresVerification,
                   Self.isConnectivityFailure(error), let lease = try await readLease(),
                   lease.isValid(for: session, accountHash: lease.binding.cloudAccountHash,
                                 environment: lease.binding.environment, now: dependencies.now()),
                   let registration = try await readRegistration() {
                    guard isCurrent(operation, session: session) else { return }
                    let storeUUID = try await Self.offMain(dependencies.storeIdentity)
                    guard isCurrent(operation, session: session) else { return }
                    if registration.matches(session: session, binding: lease.binding, storeUUID: storeUUID) {
                        diagnosticStep = "iCloud unreachable. Using the verified workspace lease…"
                        try await unlock(lease, allowLegacyAdoption: false, isOffline: true)
                        diagnosticStep = "Store opened. Ready."
                        return
                    }
                }
                throw error
            }
            verifiedAccount = true
            diagnosticStep = "iCloud account confirmed. Contacting server…"
            guard isCurrent(operation, session: session) else { return }
            accountAvailabilityRequiresVerification = false
            do {
                let response = try await dependencies.fetchWorkspace()
                diagnosticStep = "Server responded. Verifying workspace binding…"
                guard isCurrent(operation, session: session) else { return }
                guard response.user.isActive, AppAccess.normalizedEmail(response.user.email) == session.email,
                      AppUserRole(rawValue: response.user.role) != nil,
                      response.workspace.containerID == GunnAireCloudKit.containerIdentifier else {
                    throw CompanyWorkspaceFailure.signIn
                }
                pending = (session, response, account)
                let matching = response.workspace.bindings.filter { $0.environment == account.environment }
                guard matching.count <= 1 else {
                    throw mismatch("server lists \(matching.count) \(account.environment) bindings; expected one")
                }
                guard let binding = response.workspace.binding(for: account.environment) else {
                    guard matching.isEmpty, response.workspace.bindings.allSatisfy({ $0.isValid && $0.companyID == response.workspace.companyID }) else {
                        throw mismatch("no \(account.environment) binding; \(response.workspace.bindings.count) other binding(s) invalid or for another company")
                    }
                    diagnosticStep = "No binding yet. Requesting admin approval…"
                    try await requireApproval(user: response.user, operation: operation, session: session)
                    return
                }
                guard binding.cloudAccountHash == account.accountHash else {
                    throw mismatch("iCloud account differs: approved \(Self.fingerprint(binding.cloudAccountHash)) on \(binding.approvedAt), this device \(Self.fingerprint(account.accountHash))")
                }
                let lease = CompanyWorkspaceLease(session: session, binding: binding, user: response.user, verifiedAt: dependencies.now())
                diagnosticStep = "Binding verified. Opening local data store…"
                try await unlock(lease, allowLegacyAdoption: false)
                diagnosticStep = "Store opened. Ready."
            } catch {
                guard isCurrent(operation, session: session) else { return }
                // Only transport failure can use an existing bounded lease.
                // A 401/403/404, changed company, or malformed response cannot.
                if Self.isConnectivityFailure(error), let lease = try await readLease(),
                   lease.isValid(for: session, accountHash: account.accountHash, environment: account.environment, now: dependencies.now()),
                   let registration = try await readRegistration() {
                    guard isCurrent(operation, session: session) else { return }
                    let storeUUID = try await Self.offMain(dependencies.storeIdentity)
                    guard isCurrent(operation, session: session) else { return }
                    if registration.matches(session: session, binding: lease.binding, storeUUID: storeUUID) {
                        try await unlock(lease, allowLegacyAdoption: false, isOffline: true)
                    } else { throw error }
                } else { throw error }
            }
        } catch {
            guard isCurrent(operation, session: session) else { return }
            if Self.requiresAccountReverification(error) {
                accountAvailabilityRequiresVerification = true
            }
            let failure = Self.failure(for: error, verifiedAccount: verifiedAccount)
            if failure == .server {
                CompanyWorkspaceDiagnostics.lastServerFailureDetail = Self.describeRawError(error)
            }
            invalidate(reason: failure, preserveCachedLease: Self.isConnectivityFailure(error) ||
                       Self.requiresAccountReverification(error))
        }
    }

    func prepareForIntent() async {
        if authorizedContainer == nil { await refresh() }
    }

    private func requireApproval(user: BackendAppUserRecord, ignoringStaleRegistration: Bool = false,
                                 operation: UUID, session: CompanyWorkspaceSession) async throws {
        guard user.role == AppUserRole.admin.rawValue else { throw CompanyWorkspaceFailure.administratorRequired }
        // Even an administrator cannot relabel a previously registered store.
        if !ignoringStaleRegistration, let registration = try await readRegistration() {
            guard isCurrent(operation, session: session) else { return }
            throw mismatch("saved store \(Self.fingerprint(registration.storeUUID)) is already registered to the \(registration.binding.environment) binding for account \(Self.fingerprint(registration.binding.cloudAccountHash))")
        }
        let hasSavedStore = try await Self.offMain(dependencies.storeIdentity) != nil
        guard isCurrent(operation, session: session) else { return }
        phase = .needsApproval(hasSavedStore: hasSavedStore)
    }

    /// Records which check failed before the generic `.differentWorkspace` is
    /// thrown, so the gate can show it. Cleared at the start of each refresh.
    private func mismatch(_ detail: String) -> CompanyWorkspaceFailure {
        lastMismatchDetail = detail
        return .differentWorkspace
    }

    static func fingerprint(_ value: String) -> String {
        String(value.prefix(8))
    }

    /// A registration may follow a re-approved binding only when every
    /// identity component matches: same server, same store, same company,
    /// container, environment and iCloud account. Only the approval date and
    /// replica id may differ.
    /// The registration names this same server and binding, but there is no
    /// store on the device at all: the registered database is gone. A different
    /// store in its place is not this case and remains refused, even to an
    /// administrator, because a registered device's data must not be swapped.
    static func registeredStoreIsGone(registration: CompanyWorkspaceStoreRegistration, session: CompanyWorkspaceSession,
                                      binding: CompanyCloudKitBinding, storeUUID: String?) -> Bool {
        registration.backendOrigin == session.backendOrigin
            && registration.binding == binding
            && !registration.storeUUID.isEmpty
            && storeUUID == nil
    }

    static func canAdopt(registration: CompanyWorkspaceStoreRegistration, session: CompanyWorkspaceSession,
                         binding: CompanyCloudKitBinding, storeUUID: String?) -> Bool {
        registration.backendOrigin == session.backendOrigin
            && !registration.storeUUID.isEmpty && registration.storeUUID == storeUUID
            && registration.binding.companyID == binding.companyID
            && registration.binding.containerID == binding.containerID
            && registration.binding.environment == binding.environment
            && registration.binding.cloudAccountHash == binding.cloudAccountHash
            && binding.isValid
    }

    func approve(confirmed: Bool) async {
        guard confirmed, case .needsApproval = phase, let (session, response, account) = pending,
              dependencies.session() == session, !mustRestart else { return }
        let operation = generation
        phase = .checking
        do {
            let currentAccount = try await dependencies.account()
            guard currentAccount.accountHash == account.accountHash, currentAccount.environment == account.environment else {
                throw mismatch("iCloud account changed during approval: was \(Self.fingerprint(account.accountHash)) (\(account.environment)), now \(Self.fingerprint(currentAccount.accountHash)) (\(currentAccount.environment))")
            }
            guard isCurrent(operation, session: session) else { return }
            let binding = try await dependencies.approve(CompanyCloudKitApprovalRequest(
                companyID: response.workspace.companyID, containerID: response.workspace.containerID,
                environment: account.environment, cloudAccountHash: account.accountHash, confirmCompanyDataOwnership: true
            ))
            guard isCurrent(operation, session: session) else { return }
            guard binding.isValid, binding.companyID == response.workspace.companyID,
                  binding.environment == account.environment, binding.cloudAccountHash == account.accountHash else {
                throw mismatch("server returned a binding that does not match this device (valid=\(binding.isValid), environment \(binding.environment), account \(Self.fingerprint(binding.cloudAccountHash)) vs \(Self.fingerprint(account.accountHash)))")
            }
            let lease = CompanyWorkspaceLease(session: session, binding: binding, user: response.user, verifiedAt: dependencies.now())
            try await unlock(lease, allowLegacyAdoption: true)
        } catch {
            guard isCurrent(operation, session: session) else { return }
            invalidate(reason: Self.failure(for: error, verifiedAccount: true))
        }
    }

    /// Opens the store and prepares it for the verified user. The store file
    /// reads and the store load (which attaches CloudKit mirroring) run off
    /// the main actor so the "Verifying company access" screen keeps drawing.
    /// Each resumption re-checks that this unlock is still the current one,
    /// because the session can be signed out or the generation replaced while
    /// the store is opening.
    private func unlock(_ lease: CompanyWorkspaceLease, allowLegacyAdoption: Bool, isOffline: Bool = false) async throws {
        let operation = generation
        guard dependencies.session() == lease.session, !mustRestart,
              lease.isValid(for: lease.session, accountHash: lease.binding.cloudAccountHash,
                            environment: lease.binding.environment, now: dependencies.now()) else {
            throw CompanyWorkspaceFailure.signIn
        }
        let identity = try await Self.offMain(dependencies.storeIdentity)
        try requireCurrent(operation, lease: lease)
        var registration = try await readRegistration()
        try requireCurrent(operation, lease: lease)
        if let existing = registration, !existing.matches(session: lease.session, binding: lease.binding, storeUUID: identity) {
            if Self.canAdopt(registration: existing, session: lease.session, binding: lease.binding, storeUUID: identity) {
                // The server re-approved the same iCloud account for the same
                // company, container and environment (a new approval date or
                // replica id). The store still belongs to this workspace; the
                // registration follows the current binding.
                let updated = CompanyWorkspaceStoreRegistration(
                    backendOrigin: lease.session.backendOrigin, binding: lease.binding, storeUUID: existing.storeUUID
                )
                try await saveRegistration(updated)
                try requireCurrent(operation, lease: lease)
                registration = updated
            } else if Self.registeredStoreIsGone(registration: existing, session: lease.session, binding: lease.binding, storeUUID: identity) {
                // The registered store is no longer on this device and no other
                // store is present: a reinstall leaves the Keychain registration
                // behind, and it refused every unlock. The workspace identity
                // still matches, so the device is treated as never registered
                // and a fresh store is created and registered below. A different
                // populated store in its place stays refused (see below).
                registration = nil
            } else {
                let registration = existing
                let parts = [
                    registration.backendOrigin == lease.session.backendOrigin ? nil : "server origin differs",
                    registration.binding == lease.binding ? nil
                        : "binding differs (registered account \(Self.fingerprint(registration.binding.cloudAccountHash)) \(registration.binding.environment), current \(Self.fingerprint(lease.binding.cloudAccountHash)) \(lease.binding.environment))",
                    registration.storeUUID.isEmpty || registration.storeUUID != identity
                        ? "store differs (registered \(Self.fingerprint(registration.storeUUID)), on device \(identity.map(Self.fingerprint) ?? "none"))" : nil
                ].compactMap { $0 }
                throw mismatch("saved store registration does not match: " + parts.joined(separator: "; "))
            }
        }
        if registration == nil {
            if identity != nil && !allowLegacyAdoption {
                try await requireApproval(user: lease.user, ignoringStaleRegistration: true,
                                          operation: operation, session: lease.session)
                return
            } else if isOffline { throw CompanyWorkspaceFailure.storage }
        }

        let opened: ModelContainer
        if let container {
            opened = container
        } else {
            opened = try await Self.offMain(dependencies.openStore)
            try requireCurrent(operation, lease: lease)
        }
        guard let storeUUID = try await Self.offMain(dependencies.storeIdentity) else { throw CompanyWorkspaceFailure.storage }
        try requireCurrent(operation, lease: lease)
        if registration == nil {
            try await saveRegistration(CompanyWorkspaceStoreRegistration(backendOrigin: lease.session.backendOrigin, binding: lease.binding, storeUUID: storeUUID))
            try requireCurrent(operation, lease: lease)
        }
        // Build the private context off main, then reconcile and save there.
        // The lease is checked after each suspension before the store is
        // published to the UI. An unchanged user does not produce a save.
        let maintenance = try await Self.offMain { CompanyWorkspaceUnlockMaintenance(modelContainer: opened) }
        try requireCurrent(operation, lease: lease)
        let seedStarterTemplates = starterTemplatesGeneration != generation
        let projection = try await maintenance.prepareVerifiedUser(
            email: lease.user.email, role: lease.user.role,
            isActive: lease.user.isActive, createdAt: lease.user.createdAt,
            seedStarterTemplates: seedStarterTemplates
        )
        try requireCurrent(operation, lease: lease)
        // SwiftData does not expose a public context merge. A user already
        // loaded by the UI can retain an old role and later save it over the
        // authoritative background write. Touch only that registered model;
        // no main-context fetch, store transaction, or rollback occurs here.
        for record in projection.records {
            guard let cached: AppUser = opened.mainContext.registeredModel(for: record.id),
                  AppAccess.normalizedEmail(cached.email) == AppAccess.normalizedEmail(record.email) else { continue }
            if cached.roleRawValue != record.roleRawValue { cached.roleRawValue = record.roleRawValue }
            if cached.isActive != record.isActive { cached.isActive = record.isActive }
        }
        if seedStarterTemplates { starterTemplatesGeneration = generation }
        if !isOffline {
            try await saveLease(lease)
            try requireCurrent(operation, lease: lease)
        }
        if let activeLease, activeLease.user.role != lease.user.role {
            // Invalidate privileged sheets and late responses when the server
            // changes permissions, even if the user's session token is stable.
            generation = UUID()
            dependencies.clearContinuations()
        }
        container = opened
        activeLease = lease
        pending = nil
        forgetSessionMemo()
        phase = .ready
        scheduleExpiry(for: lease)
    }

    /// `unlock` suspends while the store opens; anything that replaced this
    /// generation or removed the session in the meantime ends the unlock.
    private func requireCurrent(_ operation: UUID, lease: CompanyWorkspaceLease) throws {
        guard operation == generation, !mustRestart, dependencies.session() == lease.session else {
            throw CompanyWorkspaceFailure.signIn
        }
    }

    /// Runs synchronous file work on a background task and returns its value.
    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
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
        if Self.requiresAccountReverification(error) { return .accountUnavailable }
        if error is CompanyCloudKitTimeout { return .server }
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

    /// A confirmed-healthy backend (curl and Safari both reach it fine) but a
    /// generic .server failure on-device meant the real cause - the specific
    /// URLError/DecodingError this app's own request hit - was being thrown
    /// away. No token or header value is included, only the error's type/code.
    static func describeRawError(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return "URLError(\(urlError.code.rawValue) \(urlError.code)): \(urlError.localizedDescription)"
        }
        if error is DecodingError {
            return "DecodingError: \(error.localizedDescription)"
        }
        return "\(type(of: error)): \(error.localizedDescription)"
    }

    nonisolated private static func requiresAccountReverification(_ error: Error) -> Bool {
        error is CompanyCloudKitAccountTemporarilyUnavailable || error is CompanyCloudKitAccountVerificationSuperseded
    }

    nonisolated static func isConnectivityFailure(_ error: Error) -> Bool {
        if error is CompanyCloudKitTimeout { return true }
        if let error = error as? CKError {
            return [.networkFailure, .networkUnavailable].contains(error.code)
        }
        guard let error = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code)
    }
}
