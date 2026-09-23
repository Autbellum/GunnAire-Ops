import Foundation
import SwiftUI
import SwiftData
import CloudKit
import UIKit
import StoreKit

/// CloudKit's async calls carry no built-in timeout, so a stalled network
/// path (rather than a clean error) can leave a caller awaiting forever with
/// no feedback. Races the operation against a deadline and throws
/// `CompanyCloudKitTimeout` if the deadline wins. The access controller
/// treats that like a network outage (a bounded lease may keep the workspace
/// open) and reports it as a server-side failure otherwise.
nonisolated struct CompanyCloudKitTimeout: Error, CustomStringConvertible, Sendable {
    let seconds: TimeInterval
    var description: String { "CloudKit call exceeded \(Int(seconds)) s" }
}

/// The account still exists, but CloudKit explicitly forbids new operations
/// until it becomes available. Retain durable proof without opening a store.
nonisolated struct CompanyCloudKitAccountTemporarilyUnavailable: Error, Sendable {}

/// A concurrent account result retired this lookup. It is neither proof of
/// revocation nor permission to reuse an earlier account without rechecking.
nonisolated struct CompanyCloudKitAccountVerificationSuperseded: Error, Sendable {}

nonisolated private final class CompanyCloudKitTimeoutRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var operationTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?

    /// Returns false when cancellation already settled the race before the
    /// continuation was installed. In that case no CloudKit work is started.
    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        let settled = result
        if settled == nil { self.continuation = continuation }
        lock.unlock()
        if let settled { continuation.resume(with: settled) }
        return settled == nil
    }

    func retain(operation: Task<Void, Never>, timer: Task<Void, Never>) {
        lock.lock()
        let settled = result != nil
        if !settled {
            operationTask = operation
            timerTask = timer
        }
        lock.unlock()
        if settled {
            operation.cancel()
            timer.cancel()
        }
    }

    func finish(_ next: Result<Value, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = next
        let continuation = self.continuation
        self.continuation = nil
        let operation = operationTask
        let timer = timerTask
        operationTask = nil
        timerTask = nil
        lock.unlock()
        operation?.cancel()
        timer?.cancel()
        continuation?.resume(with: next)
    }
}

nonisolated func withCloudKitTimeout<T: Sendable>(
    seconds: TimeInterval,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let race = CompanyCloudKitTimeoutRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            guard race.install(continuation) else { return }
            let operationTask = Task.detached(priority: .userInitiated) {
                guard !Task.isCancelled else { return }
                do { race.finish(.success(try await operation())) }
                catch { race.finish(.failure(error)) }
            }
            let timerTask = Task.detached(priority: .utility) {
                guard !Task.isCancelled else { return }
                do {
                    try await Task.sleep(for: .seconds(max(0, seconds)))
                    race.finish(.failure(CompanyCloudKitTimeout(seconds: seconds)))
                } catch {
                    // The operation won or the caller was cancelled.
                }
            }
            race.retain(operation: operationTask, timer: timerTask)
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// A repeated "could not verify its secure server or signed CloudKit
/// environment" failure on a real device with no console access is otherwise
/// undiagnosable. Captures exactly why the AppTransaction check didn't
/// succeed so it can be shown directly in the on-screen error text.
@MainActor
enum CompanyWorkspaceDiagnostics {
    static var lastConfigurationDetail: String = ""
    /// The raw CKAccountStatus (or empty-record-ID condition) behind the most
    /// recent accountUnavailable failure. That failure collapses several
    /// distinct device-side conditions (.noAccount, .restricted,
    /// .couldNotDetermine, .temporarilyUnavailable) into one generic message,
    /// which made remote diagnosis on real staff hardware pure guesswork.
    static var lastAccountStatusDetail: String = ""
    /// The raw error behind the most recent .server failure. That failure is
    /// a catch-all for any workspace-fetch error that isn't a recognized
    /// GunnAireBackendError, so the on-screen message alone can't distinguish
    /// a real backend problem from a URLError/DecodingError on this device.
    static var lastServerFailureDetail: String = ""
    /// The CloudKit environment this build resolved to. It namespaces the
    /// account hash, the workspace binding and every staff share plan, so a
    /// mismatch surfaces only as an opaque "workspace does not match".
    static var lastResolvedEnvironment: String = ""
}

/// Account lookups can overlap between workspace and staff operations. An
/// explicit unavailable result retires successes from the same epoch, even
/// when a sibling lookup finishes after that failure.
@MainActor
final class CompanyCloudKitAccountCache {
    private var cached: (account: CompanyCloudKitAccount, resolvedAt: Date)?
    private var generation = UUID()
    private let lifetime: TimeInterval

    init(lifetime: TimeInterval) { self.lifetime = lifetime }

    func invalidate() {
        cached = nil
        generation = UUID()
    }

    func current(
        resolve: @escaping @Sendable () async throws -> CompanyCloudKitAccount
    ) async throws -> CompanyCloudKitAccount {
        try Task.checkCancellation()
        let now = Date()
        if let cached, now >= cached.resolvedAt,
           now.timeIntervalSince(cached.resolvedAt) < lifetime {
            return cached.account
        }
        let operation = generation
        // Approachable concurrency makes nonisolated async work inherit its
        // caller's executor. Profile I/O and parsing need an explicit hop.
        let work = Task.detached(priority: .userInitiated) { try await resolve() }
        let account: CompanyCloudKitAccount
        do {
            account = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: { work.cancel() }
        } catch {
            guard generation == operation else { throw CompanyCloudKitAccountVerificationSuperseded() }
            if error is CompanyCloudKitAccountTemporarilyUnavailable ||
                (error as? CompanyWorkspaceFailure) == .accountUnavailable ||
                (error as? CompanyWorkspaceFailure) == .configuration {
                invalidate()
            }
            throw error
        }
        try Task.checkCancellation()
        guard generation == operation else { throw CompanyCloudKitAccountVerificationSuperseded() }
        cached = (account, Date())
        return account
    }
}

nonisolated enum CompanyCloudKitRuntimeAccount {
    /// The installed, signed profile determines CloudKit's environment when
    /// present. A missing profile alone is not signing evidence: simulator
    /// and custom builds can also omit it. Such builds require a verified
    /// AppTransaction before selecting the production CloudKit environment.
    static func environment(
        profileData: Data?,
        hasVerifiedStoreDistribution: Bool,
        hasStoreReceipt: Bool = false
    ) -> String? {
        if let data = profileData {
            guard let start = data.range(of: Data("<?xml".utf8)),
                  let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
                  let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
                  let entitlements = plist["Entitlements"] as? [String: Any],
                  let containers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String],
                  containers.contains(GunnAireCloudKit.containerIdentifier) else { return nil }
            // Provisioning profiles encode this entitlement as a single String
            // for a single-environment profile, but as a String array (e.g.
            // ["Production", "Development"]) for profiles that permit both.
            // The array is an ALLOWLIST, not a selection: both the development
            // and the store profile for this app carry both values (verified
            // by decoding the installed profiles), so it cannot by itself say
            // which environment a build actually reaches.
            let rawEnvironmentValues: [String]
            if let single = entitlements["com.apple.developer.icloud-container-environment"] as? String {
                rawEnvironmentValues = [single]
            } else if let list = entitlements["com.apple.developer.icloud-container-environment"] as? [String] {
                rawEnvironmentValues = list
            } else {
                return nil
            }
            let allowsProduction = rawEnvironmentValues.contains("Production")
            let allowsDevelopment = rawEnvironmentValues.contains("Development")
            guard allowsProduction || allowsDevelopment else { return nil }
            guard allowsProduction && allowsDevelopment else {
                return allowsProduction ? "production" : "development"
            }
            // Both permitted: disambiguate with get-task-allow, the signed,
            // tamper-evident marker of a development-signed build. Apple's
            // development profiles carry true and distribution profiles
            // (App Store, Ad Hoc, Enterprise) carry false - verified by
            // decoding this app's own installed profiles. A missing key is
            // treated as distribution, the conservative choice. Never infer
            // this from DEBUG, a receipt file, or QBO.
            let debuggable = (entitlements["get-task-allow"] as? Bool) ?? false
            return debuggable ? "development" : "production"
        }
        return hasVerifiedStoreDistribution || hasStoreReceipt ? "production" : nil
    }

    /// Resolving the account costs a StoreKit transaction lookup (with
    /// retries) and two CloudKit calls, and every foreground verification,
    /// publication pass and staff delivery repeats it. A successful result is
    /// reused briefly; CloudKit's account-change notification drops it.
    static let cacheLifetime: TimeInterval = 15 * 60
    @MainActor private static let accountCache = CompanyCloudKitAccountCache(lifetime: cacheLifetime)

    @MainActor static func invalidateCache() {
        accountCache.invalidate()
    }

    static func current() async throws -> CompanyCloudKitAccount {
        guard !GunnAireCloudKit.usesTestDatabase else { throw CompanyWorkspaceFailure.configuration }
        return try await accountCache.current { try await resolve() }
    }

    /// Only transport failures retry. An unverified or mismatched transaction
    /// is a configuration failure and cannot inherit an older authorization.
    static func verifyStoreDistribution(
        attempt: @escaping @Sendable () async throws -> Bool,
        pause: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .seconds(1))
        }
    ) async throws {
        for index in 0..<3 {
            try Task.checkCancellation()
            do {
                guard try await withCloudKitTimeout(seconds: 6, attempt) else {
                    throw CompanyWorkspaceFailure.configuration
                }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let transportError: Error
                if let storeError = error as? StoreKitError,
                   case .networkError(let networkError) = storeError {
                    transportError = networkError
                } else { transportError = error }
                guard CompanyWorkspaceAccessController.isConnectivityFailure(transportError) else {
                    throw CompanyWorkspaceFailure.configuration
                }
                if index == 2 { throw transportError }
                try await pause()
            }
        }
    }

    /// TestFlight can omit the embedded profile and, on some iOS releases,
    /// StoreKit can surface its configuration failure as a private error
    /// string rather than a public StoreKitError case. A nonempty App Store
    /// receipt is the signed distribution marker available in that state. It
    /// is accepted only for that exact diagnostic; unverified transactions,
    /// bundle mismatches and transport failures still fail closed.
    static func permitsStoreReceiptFallback(error: Error, receiptData: Data?) -> Bool {
        guard receiptData?.isEmpty == false else { return false }
        if let storeError = error as? StoreKitError {
            if case .networkError = storeError { return false }
            if case .userCancelled = storeError { return false }
            if case .notAvailableInStorefront = storeError { return false }
            if case .notEntitled = storeError { return false }
        }
        let description = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
        return description == "configuration" || description.localizedCaseInsensitiveContains("configuration")
    }

    static func requireAvailableAccount(
        status: @escaping @Sendable () async throws -> CKAccountStatus,
        pause: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .seconds(1))
        }
    ) async throws {
        for index in 0..<3 {
            try Task.checkCancellation()
            let value = try await withCloudKitTimeout(seconds: 20, status)
            await MainActor.run {
                CompanyWorkspaceDiagnostics.lastAccountStatusDetail = "accountStatus=\(Self.describe(value))"
            }
            switch value {
            case .available:
                return
            case .temporarilyUnavailable:
                throw CompanyCloudKitAccountTemporarilyUnavailable()
            case .couldNotDetermine:
                if index == 2 { throw URLError(.timedOut) }
                try await pause()
            case .noAccount, .restricted:
                throw CompanyWorkspaceFailure.accountUnavailable
            @unknown default:
                throw CompanyWorkspaceFailure.accountUnavailable
            }
        }
    }

    private static func resolve() async throws -> CompanyCloudKitAccount {
        let profileURLs = [
            Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile")
        ]
        let profileURL = profileURLs.first { FileManager.default.fileExists(atPath: $0.path) }
        let profileData = try profileURL.map { try Data(contentsOf: $0) }
        var hasVerifiedDistribution = false
        var hasStoreReceipt = false
        if profileData == nil {
            // App Store and TestFlight may strip the embedded profile. In
            // that case require StoreKit's verified transaction before using
            // the production CloudKit container. Retry transient failures,
            // then fail closed with a configuration diagnostic.
            let receiptURL = Bundle.main.bundleURL.appendingPathComponent("StoreKit/receipt", isDirectory: false)
            let receiptData = try? Data(contentsOf: receiptURL)
            do {
                try await verifyStoreDistribution {
                    let result = try await AppTransaction.shared
                    switch result {
                    case .verified(let transaction):
                        return transaction.bundleID == Bundle.main.bundleIdentifier &&
                            (transaction.environment == .production || transaction.environment == .sandbox)
                    case .unverified:
                        return false
                    }
                }
                hasVerifiedDistribution = true
                let detail = "profileData=nil, AppTransaction verified"
                await MainActor.run { CompanyWorkspaceDiagnostics.lastConfigurationDetail = detail }
            } catch {
                if Self.permitsStoreReceiptFallback(error: error, receiptData: receiptData) {
                    hasStoreReceipt = true
                    let detail = "profileData=nil, AppTransaction configuration; nonempty store receipt present"
                    await MainActor.run { CompanyWorkspaceDiagnostics.lastConfigurationDetail = detail }
                } else {
                let detail = "profileData=nil, AppTransaction: \(String(describing: error))"
                await MainActor.run { CompanyWorkspaceDiagnostics.lastConfigurationDetail = detail }
                throw error
                }
            }
        } else {
            await MainActor.run { CompanyWorkspaceDiagnostics.lastConfigurationDetail = "profileData present, \(profileData?.count ?? -1) bytes" }
        }
        guard let environment = environment(
            profileData: profileData,
            hasVerifiedStoreDistribution: hasVerifiedDistribution,
            hasStoreReceipt: hasStoreReceipt
        ) else {
            throw CompanyWorkspaceFailure.configuration
        }
        // The resolved environment namespaces accountHash, the workspace
        // binding lookup and every staff share plan, so a wrong value fails as
        // an opaque "workspace does not match". Record it where it can be read
        // off the device instead of inferred.
        await MainActor.run {
            CompanyWorkspaceDiagnostics.lastResolvedEnvironment = environment
        }
        let container = CKContainer(identifier: GunnAireCloudKit.containerIdentifier)
        // CKContainer's async calls have no built-in timeout. A stalled
        // network path (rather than a clean error) previously left staff
        // staring at an unbounded "Verifying company access…" spinner with
        // no feedback at all. Bound each call so a stall surfaces as a clear,
        // actionable failure instead of hanging indefinitely.
        try await requireAvailableAccount { try await container.accountStatus() }
        let identifier = try await withCloudKitTimeout(seconds: 20) { try await container.userRecordID() }
        guard !identifier.recordName.isEmpty else {
            await MainActor.run { CompanyWorkspaceDiagnostics.lastAccountStatusDetail = "accountStatus=available, userRecordID.recordName=empty" }
            throw CompanyWorkspaceFailure.accountUnavailable
        }
        let hash = CompanyWorkspaceSession.digest(
            "gunnaire-cloudkit-account-v1\n\(GunnAireCloudKit.containerIdentifier)\n\(environment)\n\(identifier.recordName)"
        )
        return CompanyCloudKitAccount(environment: environment, accountHash: hash, recordName: identifier.recordName)
    }

    private static func describe(_ status: CKAccountStatus) -> String {
        switch status {
        case .available: "available"
        case .restricted: "restricted"
        case .noAccount: "noAccount"
        case .couldNotDetermine: "couldNotDetermine"
        case .temporarilyUnavailable: "temporarilyUnavailable"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }
}

struct CompanyWorkspaceHost: View {
    @ObservedObject private var access = CompanyWorkspaceAccessController.shared
    @ObservedObject private var receive = StaffReplicaReceiveController.shared
    @Binding var hasAuthenticatedUser: Bool
    @State private var confirmsOwnership = false
    @State private var showingStaffSetup = false
    #if DEBUG
    @State private var schemaSeedResult = ""
    @State private var isSeedingSchema = false
    #endif
    @StateObject private var staffNavigation = StaffWorkspaceNavigationController()
    @ObservedObject private var staffInvitations = CloudKitStaffInvitationInbox.shared

    var body: some View {
        Group {
            if let container = access.authorizedContainer {
                ContentView().modifier(JobBillingRecoveryModifier()).modifier(StaffReplicaSourceRecoveryModifier()).modelContainer(container)
                    .id(access.generation)
            } else if let presentation = receive.authorizedPresentation {
                // One verified session, never independently published host/identity
                // fields. Navigation survives content refresh within this scope.
                StaffWorkspaceOperationalHostedWorkspaceView(
                    hosted: presentation.workspace.hosted,
                    identity: presentation.workspace.identity,
                    account: presentation.context.account,
                    deviceFingerprint: presentation.deviceFingerprint,
                    navigation: staffNavigation
                )
                    .id(presentation.navigationScope)
                    .accessibilityIdentifier("StaffOperationalHostedWorkspace")
                    .safeAreaInset(edge: .top, spacing: 0) {
                        StaffReplicaOfflineStatusView(receive: receive)
                    }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Label("Company workspace", systemImage: "person.icloud")
                            .font(.title2.bold())
                        switch access.phase {
                        case .checking, .ready:
                            ProgressView("Verifying company access…")
                                .accessibilityIdentifier("CompanyWorkspaceProofCheck")
                            Text(access.diagnosticStep)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("CompanyWorkspaceDiagnosticStep")
                        case .needsApproval(let hasSavedStore):
                            Text(hasSavedStore ? "Review this device's saved work" : "Approve this company iCloud account")
                                .font(.headline)
                            Text("Only approve the business iCloud account used for GunnAire's operational records. This links the account and this device's saved workspace to your verified business. It does not move or delete existing records.")
                            if hasSavedStore {
                                Text("Existing saved records have not been assigned to a verified company. If you cannot confirm their ownership, stop and ask for a data review.")
                                    .foregroundStyle(.secondary)
                            }
                            Toggle("I confirm that this iCloud account and any saved work belong to this business.", isOn: $confirmsOwnership)
                                .accessibilityIdentifier("CompanyWorkspaceOwnershipConfirmation")
                            Button("Approve Workspace") {
                                Task { await access.approve(confirmed: confirmsOwnership) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!confirmsOwnership)
                            .accessibilityIdentifier("CompanyWorkspaceApproveButton")
                            Text("Approval requires an administrator sign-in within the last 10 minutes.")
                                .font(.footnote).foregroundStyle(.secondary)
                        case .blocked(let failure):
                            Text(failure == .differentWorkspace ? "Workspace does not match" : "Workspace needs attention")
                                .font(.headline)
                            Text(failure.localizedDescription)
                            if failure == .configuration, !CompanyWorkspaceDiagnostics.lastConfigurationDetail.isEmpty {
                                Text(CompanyWorkspaceDiagnostics.lastConfigurationDetail)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("CompanyWorkspaceConfigurationDetail")
                            }
                            if failure == .accountUnavailable, !CompanyWorkspaceDiagnostics.lastAccountStatusDetail.isEmpty {
                                Text(CompanyWorkspaceDiagnostics.lastAccountStatusDetail)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("CompanyWorkspaceAccountStatusDetail")
                            }
                            if failure == .server, !CompanyWorkspaceDiagnostics.lastServerFailureDetail.isEmpty {
                                Text(CompanyWorkspaceDiagnostics.lastServerFailureDetail)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("CompanyWorkspaceServerFailureDetail")
                            }
                            if failure == .differentWorkspace, !CompanyWorkspaceDiagnostics.lastResolvedEnvironment.isEmpty {
                                Text("environment=\(CompanyWorkspaceDiagnostics.lastResolvedEnvironment)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("CompanyWorkspaceResolvedEnvironment")
                            }
                            if failure == .differentWorkspace, !access.lastMismatchDetail.isEmpty {
                                Text(access.lastMismatchDetail)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .accessibilityIdentifier("CompanyWorkspaceMismatchDetail")
                            }
                            if failure != .restartRequired {
                                Button("Check Again") { Task { await access.refresh() } }
                                    .buttonStyle(.borderedProminent)
                                Button("Staff iCloud Setup") { showingStaffSetup = true }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("OpenStaffCloudKitSetup")
                            }
                        }
                        #if DEBUG
                        // Reachable in every blocked state on purpose: seeding
                        // the Development schema needs CloudKit only, not an
                        // approved workspace, so this must not sit behind the
                        // approval it exists to make unnecessary.
                        VStack(alignment: .leading, spacing: 8) {
                            Divider()
                            Text("Developer")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Button(isSeedingSchema ? "Seeding…" : "Seed Development schema") {
                                isSeedingSchema = true
                                Task {
                                    schemaSeedResult = await CloudKitSchemaSeed.seedDevelopmentSchema()
                                    isSeedingSchema = false
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isSeedingSchema)
                            .accessibilityIdentifier("SeedCloudKitShareType")
                            if !schemaSeedResult.isEmpty {
                                Text(schemaSeedResult)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .accessibilityIdentifier("SeedCloudKitShareTypeResult")
                            }
                        }
                        #endif
                        Button("Sign Out") {
                            access.invalidate()
                            FieldPaymentHandoff.shared.end()
                            GunnAireAppIntentRouter.discardAllPendingPayloads()
                            QuickBooksAuthAPI.shared.signOut()
                            GoogleAuthManager.shared.signOut()
                            AppleAuthManager.shared.signOut()
                            hasAuthenticatedUser = false
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(24)
                    .frame(maxWidth: 600, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemBackground))
                .accessibilityIdentifier("CompanyWorkspaceProofGate")
            }
        }
        .modifier(StaffReplicaReceiveRecoveryModifier())
        .onChange(of: receive.authorizedPresentation?.navigationIdentity, initial: true) { _, _ in
            staffNavigation.update(receive.authorizedPresentation)
        }
        .sheet(item: $staffNavigation.editor) { session in
            StaffWorkspaceFieldEditorView(title: session.title, field: session.field, editor: session.controller)
        }
        .sheet(item: $staffNavigation.invoiceEditor) { session in
            StaffInvoiceEditorView(editor: session.controller)
        }
        .sheet(isPresented: $showingStaffSetup) { CloudKitStaffSetupView() }
        .onReceive(staffInvitations.$pending) { invitation in
            if invitation != nil { showingStaffSetup = true }
        }
        .task { await access.refreshIfStale(maxAge: CompanyWorkspaceAccessController.verificationInterval) }
        .task(id: receive.presentation?.context.stamp.session.expiresAt) {
            guard let expires = receive.presentation?.context.stamp.session.expiresAt else { return }
            do { try await Task.sleep(for: .seconds(max(0, expires.timeIntervalSinceNow))) }
            catch { return }
            receive.enforceAccessDeadline()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            access.enforceAccessDeadline()
            receive.enforceAccessDeadline()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            access.enforceAccessDeadline()
            receive.enforceAccessDeadline()
            Task { await access.refreshIfStale(maxAge: CompanyWorkspaceAccessController.verificationInterval) }
        }
    }
}
