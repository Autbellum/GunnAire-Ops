import Foundation
import SwiftData
import Testing
import Combine
import CloudKit
import StoreKit
@testable import GunnAire_Ops

@MainActor
struct CompanyWorkspaceAccessTests {
    private actor AccountResolutionProbe {
        private var pending: [Int: CheckedContinuation<CompanyCloudKitAccount, Error>] = [:]
        private(set) var reads = 0

        func resolve(started: AsyncStream<Int>.Continuation) async throws -> CompanyCloudKitAccount {
            let index = reads
            reads += 1
            return try await withCheckedThrowingContinuation { continuation in
                pending[index] = continuation
                started.yield(index)
            }
        }

        func finish(_ index: Int, result: Result<CompanyCloudKitAccount, Error>) {
            pending.removeValue(forKey: index)?.resume(with: result)
        }
    }

    private actor AccountStatusProbe {
        private var statuses: [CKAccountStatus]
        private(set) var reads = 0

        init(_ statuses: [CKAccountStatus]) { self.statuses = statuses }

        func next() throws -> CKAccountStatus {
            reads += 1
            guard !statuses.isEmpty else { throw CompanyWorkspaceFailure.configuration }
            return statuses.removeFirst()
        }
    }

    nonisolated private enum DistributionOutcome: Sendable {
        case verified, rejected, timeout, networkFailure, cancelled
    }

    private actor DistributionProbe {
        private var outcomes: [DistributionOutcome]
        private(set) var reads = 0

        init(_ outcomes: [DistributionOutcome]) { self.outcomes = outcomes }

        func next() throws -> Bool {
            reads += 1
            guard !outcomes.isEmpty else { throw CompanyWorkspaceFailure.configuration }
            switch outcomes.removeFirst() {
            case .verified: return true
            case .rejected: return false
            case .timeout: throw CompanyCloudKitTimeout(seconds: 6)
            case .networkFailure: throw StoreKitError.networkError(URLError(.notConnectedToInternet))
            case .cancelled: throw CancellationError()
            }
        }
    }

    nonisolated private final class SuspendedCloudKitCall: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Int, Never>?
        private var released = false

        func hold(signaling started: AsyncStream<Void>.Continuation) async -> Int {
            await withCheckedContinuation { continuation in
                lock.lock()
                let shouldResume = released
                if !shouldResume { self.continuation = continuation }
                lock.unlock()
                started.yield(())
                if shouldResume { continuation.resume(returning: 42) }
            }
        }

        func release() {
            lock.lock()
            released = true
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: 42)
        }

        var hasReleased: Bool {
            lock.lock()
            defer { lock.unlock() }
            return released
        }
    }

    private final class SaveCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func record() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var snapshot: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    @MainActor
    private final class Harness {
        var now = Date(timeIntervalSince1970: 1_788_800_000)
        var session: CompanyWorkspaceSession?
        var user = BackendAppUserRecord(email: "tech@example.test", role: "Field Technician", isActive: true, createdAt: nil)
        var binding: CompanyCloudKitBinding
        var remoteBindings: [CompanyCloudKitBinding]?
        var cloudAccountHash = String(repeating: "a", count: 64)
        var environment = "development"
        var registration: CompanyWorkspaceStoreRegistration?
        var lease: CompanyWorkspaceLease?
        // Read and written by the store-opening closures, which the controller
        // now runs on a background task; the test awaits the controller before
        // reading them, so no two accesses overlap.
        nonisolated(unsafe) var storeID: String? = "existing-store"
        nonisolated(unsafe) var openCount = 0
        nonisolated(unsafe) var storeIdentityWasOnMainThread = false
        nonisolated(unsafe) var onStoreIdentity: (@Sendable () -> Void)?
        var approvalCount = 0
        var fetchError: Error?
        var fetchCount = 0
        var approvalError: Error?
        var delayedFetch: (() async throws -> BackendCompanyWorkspaceResponse)?
        var delayedSleep: ((TimeInterval) async throws -> Void)?
        var delayedReadLease: (() async throws -> CompanyWorkspaceLease?)?
        var sessionStorageValid: (() async -> Bool)?
        var discardedProofCount = 0
        var clearedContinuations = 0
        var registrationError = false
        var sessionReads = 0
        var sessionSignal = "signal-a"
        var accountError: Error?
        let modelContainer: ModelContainer

        init() throws {
            binding = CompanyCloudKitBinding(companyID: UUID(), containerID: GunnAireCloudKit.containerIdentifier, environment: "development", replicaID: UUID(), cloudAccountHash: String(repeating: "a", count: 64), approvedAt: "2026-09-06T12:00:00+00:00")
            modelContainer = try ModelContainer(for: GunnAireModelSchema.schema, configurations: [ModelConfiguration(schema: GunnAireModelSchema.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
            session = CompanyWorkspaceSession(backendOrigin: "https://company.example.test", email: user.email, tokenFingerprint: "test-session-digest", expiresAt: now.addingTimeInterval(172_800))
        }

        func register() {
            registration = CompanyWorkspaceStoreRegistration(backendOrigin: session!.backendOrigin, binding: binding, storeUUID: storeID!)
        }

        func cache() {
            lease = CompanyWorkspaceLease(session: session!, binding: binding, user: user, verifiedAt: now)
        }

        var response: BackendCompanyWorkspaceResponse {
            BackendCompanyWorkspaceResponse(user: user, workspace: CompanyWorkspaceIdentity(companyID: binding.companyID, containerID: binding.containerID, bindings: remoteBindings ?? [binding]))
        }

        func controller() -> CompanyWorkspaceAccessController {
            CompanyWorkspaceAccessController(dependencies: CompanyWorkspaceDependencies(
                session: { self.sessionReads += 1; return self.session },
                account: {
                    if let error = self.accountError { throw error }
                    return CompanyCloudKitAccount(environment: self.environment, accountHash: self.cloudAccountHash)
                },
                fetchWorkspace: {
                    self.fetchCount += 1
                    if let delayed = self.delayedFetch { return try await delayed() }
                    if let error = self.fetchError { throw error }
                    return self.response
                },
                approve: { request in
                    if let error = self.approvalError { throw error }
                    #expect(request.confirmCompanyDataOwnership)
                    #expect(request.expectedCompanyID == self.binding.companyID.uuidString.lowercased())
                    self.approvalCount += 1
                    return self.binding
                },
                readRegistration: { self.registration },
                saveRegistration: {
                    if self.registrationError { throw CompanyWorkspaceFailure.storage }
                    self.registration = $0
                },
                readLease: { self.lease }, saveLease: { self.lease = $0 },
                readLeaseAsync: delayedReadLease,
                sessionStorageValidAsync: sessionStorageValid,
                clearSessionProofs: { self.discardedProofCount += 1 },
                storeIdentity: {
                    self.storeIdentityWasOnMainThread = self.storeIdentityWasOnMainThread || Thread.isMainThread
                    self.onStoreIdentity?()
                    return self.storeID
                },
                openStore: {
                    self.openCount += 1
                    if self.storeID == nil { self.storeID = "new-store" }
                    return self.modelContainer
                },
                now: { self.now },
                sleep: { interval in
                    if let delayed = self.delayedSleep { try await delayed(interval) }
                    else { try await Task.sleep(for: .seconds(interval)) }
                },
                clearContinuations: { self.clearedContinuations += 1 },
                sessionSignal: { self.sessionSignal }
            ))
        }
    }

    @Test func cleanupPermitIsRetiredByWorkspaceInvalidationBeforeCommit() async throws {
        let h = try Harness()
        h.user = BackendAppUserRecord(email: h.user.email, role: AppUserRole.admin.rawValue,
            isActive: true, createdAt: nil)
        h.register()
        let controller = h.controller()
        await controller.refresh()
        let permit = try controller.customerCleanupPermit(generation: controller.generation, container: h.modelContainer)
        controller.invalidate(accountChanged: true)
        #expect(throws: CustomerCalendarCleanupError.self) { try permit.beginCommit(now: h.now) }
    }

    @Test func fieldRoleCannotObtainCustomerCleanupPermit() async throws {
        let h = try Harness(); h.register()
        let controller = h.controller(); await controller.refresh()
        #expect(controller.phase == .ready)
        #expect(throws: CustomerCalendarCleanupError.self) {
            try controller.customerCleanupPermit(generation: controller.generation, container: h.modelContainer)
        }
    }

    /// Render-time authority reads (`verifiedRole`, `verifiedUser`,
    /// `operationStamp`, `verifiedCompanyID`) reuse one decoded session within
    /// the memo lifetime, re-read it once the lifetime passes or the in-memory
    /// token signal changes, and never let the memo outlive a removed session
    /// when the deadline is enforced.
    @Test func renderTimeAuthorityReadsMemoizeTheSessionWithoutExtendingIt() async throws {
        let h = try Harness(); h.register()
        let controller = h.controller(); await controller.refresh()
        #expect(controller.phase == .ready)

        let baseline = h.sessionReads
        for _ in 0..<100 {
            #expect(controller.verifiedRole == .fieldTechnician)
            #expect(controller.verifiedUser?.email == h.user.email)
            #expect(controller.operationStamp != nil)
            #expect(controller.verifiedCompanyID == h.binding.companyID)
        }
        #expect(h.sessionReads - baseline <= 1)

        let beforeLifetime = h.sessionReads
        h.now = h.now.addingTimeInterval(CompanyWorkspaceAccessController.sessionMemoLifetime)
        #expect(controller.verifiedRole == .fieldTechnician)
        #expect(h.sessionReads == beforeLifetime + 1)
        #expect(controller.verifiedRole == .fieldTechnician)
        #expect(h.sessionReads == beforeLifetime + 1)

        let beforeSignal = h.sessionReads
        h.sessionSignal = "signal-b"
        #expect(controller.verifiedRole == .fieldTechnician)
        #expect(h.sessionReads == beforeSignal + 1)

        // Within the lifetime the memo is reused, but the deadline check always
        // observes the live session and closes the workspace immediately.
        let beforeRemoval = h.sessionReads
        h.session = nil
        #expect(controller.verifiedRole == .fieldTechnician)
        #expect(h.sessionReads == beforeRemoval)
        controller.enforceAccessDeadline()
        #expect(controller.phase == .blocked(.signIn))
        #expect(controller.authorizedContainer == nil && controller.verifiedRole == nil)
    }

    /// A repeated verification with an unchanged server user must not save
    /// the store: every save is a CloudKit export candidate. Reconciliation
    /// saves through a private context, never on the UI thread.
    @Test func repeatedVerificationWithUnchangedUserDoesNotSaveTheStore() async throws {
        let h = try Harness(); h.register()
        let container = h.modelContainer
        let saves = SaveCounter()
        let observation = NotificationCenter.default.publisher(for: ModelContext.didSave)
            .filter { ($0.object as? ModelContext)?.container === container }
            .sink { _ in saves.record() }
        let controller = h.controller(); await controller.refresh()
        #expect(controller.phase == .ready)
        #expect(saves.snapshot >= 1)
        let firstPassSaves = saves.snapshot
        let initialContext = ModelContext(container)
        let templates = try initialContext.fetch(FetchDescriptor<FieldFormTemplate>()).count
        #expect(templates >= 5)
        let users = try initialContext.fetch(FetchDescriptor<AppUser>()).count

        await controller.refresh()
        #expect(controller.phase == .ready)
        #expect(saves.snapshot == firstPassSaves)
        let repeatedContext = ModelContext(container)
        #expect(try repeatedContext.fetch(FetchDescriptor<FieldFormTemplate>()).count == templates)
        #expect(try repeatedContext.fetch(FetchDescriptor<AppUser>()).count == users)

        // A changed server role is still written and saved.
        h.user = BackendAppUserRecord(email: h.user.email, role: "Standard", isActive: true, createdAt: nil)
        await controller.refresh()
        #expect(controller.phase == .ready)
        #expect(saves.snapshot == firstPassSaves + 1)
        #expect(try ModelContext(container).fetch(FetchDescriptor<AppUser>()).allSatisfy { $0.role == .standard })
        withExtendedLifetime(observation) {}
    }

    @Test func verifiedUserMaintenanceExecutesOffTheMainThread() async throws {
        let h = try Harness()
        let container = h.modelContainer
        let worker = await Task.detached(priority: .userInitiated) {
            CompanyWorkspaceUnlockMaintenance(modelContainer: container)
        }.value
        let projection = try await worker.prepareVerifiedUser(
            email: h.user.email, role: h.user.role, isActive: h.user.isActive,
            createdAt: h.user.createdAt, seedStarterTemplates: true
        )
        #expect(!projection.ranOnMainThread)
        #expect(projection.records.count == 1)
        #expect(try ModelContext(container).fetch(FetchDescriptor<AppUser>()).count == 1)
    }

    /// Starter templates are seeded once per workspace generation, not on every
    /// foreground verification; a new generation (here, a server role change)
    /// seeds again on the unlock that follows it.
    @Test func starterTemplatesAreSeededOncePerWorkspaceGeneration() async throws {
        let h = try Harness(); h.register()
        let controller = h.controller(); await controller.refresh()
        #expect(controller.phase == .ready)
        let initialContext = ModelContext(h.modelContainer)
        let seeded = try initialContext.fetch(FetchDescriptor<FieldFormTemplate>())
        #expect(seeded.count >= 5)
        initialContext.delete(try #require(seeded.first)); try initialContext.save()
        let afterDelete = try ModelContext(h.modelContainer).fetch(FetchDescriptor<FieldFormTemplate>()).count

        await controller.refresh()
        #expect(controller.phase == .ready)
        #expect(try ModelContext(h.modelContainer).fetch(FetchDescriptor<FieldFormTemplate>()).count == afterDelete)

        let generation = controller.generation
        h.user = BackendAppUserRecord(email: h.user.email, role: "Standard", isActive: true, createdAt: nil)
        await controller.refresh()
        #expect(controller.generation != generation)
        // The seed check ran before the role change bumped the generation.
        #expect(try ModelContext(h.modelContainer).fetch(FetchDescriptor<FieldFormTemplate>()).count == afterDelete)
        await controller.refresh()
        #expect(try ModelContext(h.modelContainer).fetch(FetchDescriptor<FieldFormTemplate>()).count == afterDelete + 1)
    }

    /// A foreground activation re-verifies with the server only once the lease
    /// is older than the interval; the local deadline check still runs every time.
    @Test func foregroundReverificationSkipsTheServerWhileTheLeaseIsFresh() async throws {
        let h = try Harness(); h.register()
        let controller = h.controller(); await controller.refresh()
        #expect(controller.phase == .ready)
        #expect(h.fetchCount == 1)

        h.now = h.now.addingTimeInterval(14 * 60)
        await controller.refreshIfStale(maxAge: 15 * 60)
        #expect(h.fetchCount == 1)
        #expect(controller.phase == .ready)

        h.now = h.now.addingTimeInterval(2 * 60)
        await controller.refreshIfStale(maxAge: 15 * 60)
        #expect(h.fetchCount == 2)
        #expect(controller.phase == .ready)

        // A removed session closes the workspace on the very next activation.
        h.session = nil
        await controller.refreshIfStale(maxAge: 15 * 60)
        #expect(controller.phase == .blocked(.signIn))
        #expect(controller.authorizedContainer == nil)
    }

    /// A CloudKit stall at the account step is transport failure: a lease
    /// verified within its bound keeps the workspace open offline, exactly as
    /// an unreachable server already did.
    @Test func iCloudTimeoutKeepsAVerifiedLeaseOpenOffline() async throws {
        let h = try Harness(); h.register(); h.cache()
        h.accountError = CompanyCloudKitTimeout(seconds: 20)
        let controller = h.controller(); await controller.refresh()
        #expect(controller.phase == .ready)
        #expect(controller.authorizedContainer != nil)
        #expect(h.fetchCount == 0)
        #expect(h.lease != nil)
        #expect(!h.storeIdentityWasOnMainThread)
    }

    @Test func iCloudTimeoutWithoutALeaseBlocksAsAServerFailure() async throws {
        let h = try Harness(); h.register()
        h.accountError = CompanyCloudKitTimeout(seconds: 20)
        let controller = h.controller(); await controller.refresh()
        #expect(controller.phase == .blocked(.server))
        #expect(controller.authorizedContainer == nil)
        #expect(h.openCount == 0)
    }

    @Test func storeDistributionRetriesTransportFailureAndAcceptsVerifiedEvidence() async throws {
        let probe = DistributionProbe([.networkFailure, .timeout, .verified])
        try await CompanyCloudKitRuntimeAccount.verifyStoreDistribution(
            attempt: { try await probe.next() }, pause: {}
        )
        #expect(await probe.reads == 3)
    }

    @Test func unverifiedDistributionRejectsAnExistingLeaseWithoutRetrying() async throws {
        let h = try Harness(); h.register(); h.cache()
        let probe = DistributionProbe([.rejected, .verified])
        do {
            try await CompanyCloudKitRuntimeAccount.verifyStoreDistribution(
                attempt: { try await probe.next() }, pause: {}
            )
            Issue.record("Unverified StoreKit evidence must not authorize the workspace")
        } catch { h.accountError = error }
        let controller = h.controller(); await controller.refresh()
        #expect(await probe.reads == 1)
        #expect(controller.phase == .blocked(.configuration))
        #expect(controller.authorizedContainer == nil)
        #expect(h.openCount == 0 && h.lease == nil)
    }

    @Test func storeDistributionOutageKeepsExistingLeaseWithoutExtendingIt() async throws {
        let h = try Harness(); h.register(); h.cache()
        let verifiedAt = h.lease?.verifiedAt
        h.now = h.now.addingTimeInterval(23 * 60 * 60)
        let probe = DistributionProbe([.networkFailure, .timeout, .networkFailure])
        do {
            try await CompanyCloudKitRuntimeAccount.verifyStoreDistribution(
                attempt: { try await probe.next() }, pause: {}
            )
            Issue.record("An outage cannot produce verified distribution evidence")
        } catch { h.accountError = error }
        let controller = h.controller(); await controller.refresh()
        #expect(await probe.reads == 3)
        #expect(controller.phase == .ready)
        #expect(controller.authorizedContainer != nil)
        #expect(h.fetchCount == 0)
        #expect(h.lease?.verifiedAt == verifiedAt)

        let fresh = try Harness(); fresh.register(); fresh.accountError = h.accountError
        let freshController = fresh.controller(); await freshController.refresh()
        #expect(freshController.authorizedContainer == nil)
        #expect(fresh.openCount == 0 && fresh.lease == nil)
    }

    @Test func cancelledDistributionVerificationDoesNotRetry() async throws {
        let probe = DistributionProbe([.cancelled, .verified])
        do {
            try await CompanyCloudKitRuntimeAccount.verifyStoreDistribution(
                attempt: { try await probe.next() }, pause: {}
            )
            Issue.record("Cancelled verification must not resume authorization")
        } catch { #expect(error is CancellationError) }
        #expect(await probe.reads == 1)
    }

    @Test func indeterminateAccountStatusRetriesWithinItsBound() async throws {
        let probe = AccountStatusProbe([.couldNotDetermine, .couldNotDetermine, .available])
        try await CompanyCloudKitRuntimeAccount.requireAvailableAccount(
            status: { try await probe.next() }, pause: {}
        )
        #expect(await probe.reads == 3)

        let exhausted = AccountStatusProbe([.couldNotDetermine, .couldNotDetermine, .couldNotDetermine, .available])
        do {
            try await CompanyCloudKitRuntimeAccount.requireAvailableAccount(
                status: { try await exhausted.next() }, pause: {}
            )
            Issue.record("Indeterminate status must not retry without a bound")
        } catch { #expect(CompanyWorkspaceAccessController.isConnectivityFailure(error)) }
        #expect(await exhausted.reads == 3)
    }

    @Test func temporarilyUnavailableAccountRetainsProofWithoutOpeningCloudKitStore() async throws {
        let h = try Harness(); h.register(); h.cache()
        let probe = AccountStatusProbe([.temporarilyUnavailable, .available])
        do {
            try await CompanyCloudKitRuntimeAccount.requireAvailableAccount(
                status: { try await probe.next() }, pause: {}
            )
            Issue.record("A temporarily unavailable account must not start new CloudKit operations")
        } catch { h.accountError = error }
        let controller = h.controller(); await controller.refresh()
        #expect(await probe.reads == 1)
        #expect(controller.phase == .blocked(.accountUnavailable))
        #expect(controller.authorizedContainer == nil)
        #expect(h.openCount == 0 && h.fetchCount == 0)
        #expect(h.lease != nil)

        // A foreground refresh must not bypass the observed unavailable
        // account through the otherwise valid saved-lease fast path.
        await controller.refreshIfStale(maxAge: CompanyWorkspaceAccessController.verificationInterval)
        #expect(controller.phase == .blocked(.accountUnavailable))
        #expect(h.openCount == 0 && h.lease != nil)

        h.accountError = nil
        await controller.refreshIfStale(maxAge: CompanyWorkspaceAccessController.verificationInterval)
        #expect(controller.phase == .ready)
        #expect(h.openCount == 1 && h.fetchCount == 1)
    }

    @Test func missingOrRestrictedAccountDoesNotRetryOrRetainAuthorization() async throws {
        for status in [CKAccountStatus.noAccount, .restricted] {
            let h = try Harness(); h.register(); h.cache()
            let probe = AccountStatusProbe([status, .available])
            do {
                try await CompanyCloudKitRuntimeAccount.requireAvailableAccount(
                    status: { try await probe.next() }, pause: {}
                )
                Issue.record("An unavailable account must not authorize the workspace")
            } catch { h.accountError = error }
            let controller = h.controller(); await controller.refresh()
            #expect(await probe.reads == 1)
            #expect(controller.phase == .blocked(.accountUnavailable))
            #expect(controller.authorizedContainer == nil)
            #expect(h.openCount == 0 && h.lease == nil)
        }
    }

    @Test func unavailableAccountRetiresCachedAndLateSiblingResolution() async throws {
        let cache = CompanyCloudKitAccountCache(lifetime: 900)
        let probe = AccountResolutionProbe()
        let account = CompanyCloudKitAccount(environment: "development", accountHash: "approved")
        let (started, signal) = AsyncStream<Int>.makeStream()
        var starts = started.makeAsyncIterator()
        let first = Task { try await cache.current { try await probe.resolve(started: signal) } }
        #expect(await starts.next() == 0)
        let second = Task { try await cache.current { try await probe.resolve(started: signal) } }
        #expect(await starts.next() == 1)
        let late = Task { try await cache.current { try await probe.resolve(started: signal) } }
        #expect(await starts.next() == 2)

        await probe.finish(0, result: .success(account))
        #expect(try await first.value.accountHash == "approved")
        await probe.finish(1, result: .failure(CompanyCloudKitAccountTemporarilyUnavailable()))
        do {
            _ = try await second.value
            Issue.record("Temporary account unavailability must be reported")
        } catch { #expect(error is CompanyCloudKitAccountTemporarilyUnavailable) }
        await probe.finish(2, result: .success(account))
        do {
            _ = try await late.value
            Issue.record("An older overlapping success must not restore unavailable account proof")
        } catch { #expect(error is CompanyCloudKitAccountVerificationSuperseded) }

        let reread = try await cache.current {
            CompanyCloudKitAccount(environment: "development", accountHash: "freshly-verified")
        }
        #expect(reread.accountHash == "freshly-verified")
    }

    @Test func accountChangeInvalidationRejectsPendingResolutionAndItsLateFailure() async throws {
        let cache = CompanyCloudKitAccountCache(lifetime: 900)
        let probe = AccountResolutionProbe()
        let (started, signal) = AsyncStream<Int>.makeStream()
        var starts = started.makeAsyncIterator()
        let lateSuccess = Task { try await cache.current { try await probe.resolve(started: signal) } }
        #expect(await starts.next() == 0)
        let lateFailure = Task { try await cache.current { try await probe.resolve(started: signal) } }
        #expect(await starts.next() == 1)
        cache.invalidate()
        let fresh = try await cache.current {
            CompanyCloudKitAccount(environment: "development", accountHash: "replacement")
        }
        #expect(fresh.accountHash == "replacement")

        await probe.finish(0, result: .success(.init(environment: "development", accountHash: "old")))
        do {
            _ = try await lateSuccess.value
            Issue.record("Account-change invalidation must reject old pending account evidence")
        } catch { #expect(error is CompanyCloudKitAccountVerificationSuperseded) }
        await probe.finish(1, result: .failure(CompanyCloudKitAccountTemporarilyUnavailable()))
        do { _ = try await lateFailure.value }
        catch { #expect(error is CompanyCloudKitAccountVerificationSuperseded) }

        // A failure from the old epoch must not erase the replacement's cache.
        let retained = try await cache.current { throw CompanyWorkspaceFailure.configuration }
        #expect(retained.accountHash == "replacement")
    }

    @Test func supersededAccountVerificationKeepsLeaseButRequiresFreshAccountProof() async throws {
        let h = try Harness(); h.register(); h.cache()
        h.accountError = CompanyCloudKitAccountVerificationSuperseded()
        let controller = h.controller(); await controller.refresh()
        #expect(controller.phase == .blocked(.accountUnavailable))
        #expect(h.lease != nil && h.openCount == 0)
        await controller.refreshIfStale(maxAge: CompanyWorkspaceAccessController.verificationInterval)
        #expect(controller.phase == .blocked(.accountUnavailable))
        #expect(h.lease != nil && h.openCount == 0)
        h.accountError = nil
        await controller.refreshIfStale(maxAge: CompanyWorkspaceAccessController.verificationInterval)
        #expect(controller.phase == .ready)
        #expect(h.openCount == 1 && h.fetchCount == 1)
    }

    @Test func cloudKitTimeoutDoesNotWaitForAnOperationThatIgnoresCancellation() async throws {
        let gate = SuspendedCloudKitCall()
        let (started, signal) = AsyncStream<Void>.makeStream()
        let failsafe = Task.detached {
            do { try await Task.sleep(for: .seconds(10)) }
            catch { return }
            gate.release()
        }
        let work = Task { () -> Error? in
            do {
                _ = try await withCloudKitTimeout(seconds: 0.05) {
                    await gate.hold(signaling: signal)
                }
                return nil
            } catch {
                return error
            }
        }
        for await _ in started { break }
        let error = await work.value
        let operationWasReleased = gate.hasReleased
        gate.release()
        failsafe.cancel()
        #expect(error is CompanyCloudKitTimeout)
        // Completion must precede releasing the operation; this checks the
        // cancellation-ignoring failure without a narrow wall-clock budget.
        #expect(!operationWasReleased)
    }

    @Test func cloudKitTimeoutReturnsAnOperationThatFinishesBeforeDeadline() async throws {
        let value = try await withCloudKitTimeout(seconds: 1) { 42 }
        #expect(value == 42)
    }

    /// The gate names the failing check: an approved iCloud account that
    /// differs from this device's, or a saved-store registration that belongs
    /// to another server or binding. Only 8-character fingerprints are shown.
    @Test func workspaceMismatchNamesTheFailingCheckWithFingerprints() async throws {
        let h = try Harness(); h.register()
        h.cloudAccountHash = String(repeating: "b", count: 64)
        let controller = h.controller(); await controller.refresh()
        #expect(controller.phase == .blocked(.differentWorkspace))
        #expect(controller.lastMismatchDetail
                == "iCloud account differs: approved aaaaaaaa on \(h.binding.approvedAt), this device bbbbbbbb")

        let other = try Harness(); other.register()
        other.registration = CompanyWorkspaceStoreRegistration(
            backendOrigin: "https://other.example.test", binding: other.binding, storeUUID: "existing-store"
        )
        let second = other.controller(); await second.refresh()
        #expect(second.phase == .blocked(.differentWorkspace))
        #expect(second.lastMismatchDetail
                == "saved store registration does not match: server origin differs")

        // A later successful refresh clears the detail.
        other.registration = CompanyWorkspaceStoreRegistration(
            backendOrigin: other.session!.backendOrigin, binding: other.binding, storeUUID: "existing-store"
        )
        await second.refresh()
        #expect(second.phase == .ready)
        #expect(second.lastMismatchDetail.isEmpty)
    }

    /// A server re-approval of the same iCloud account (new approval date and
    /// replica id) must not lock a device out: the saved store registration
    /// follows the current binding. Any other difference still blocks.
    @Test func registrationFollowsAReapprovedBindingForTheSameAccount() async throws {
        let h = try Harness(); h.register()
        let previous = CompanyCloudKitBinding(
            companyID: h.binding.companyID, containerID: h.binding.containerID, environment: h.binding.environment,
            replicaID: UUID(), cloudAccountHash: h.binding.cloudAccountHash, approvedAt: "2026-08-01T12:00:00+00:00"
        )
        h.registration = CompanyWorkspaceStoreRegistration(backendOrigin: h.session!.backendOrigin, binding: previous, storeUUID: "existing-store")
        let controller = h.controller(); await controller.refresh()
        #expect(controller.phase == .ready)
        #expect(h.registration?.binding == h.binding)
        #expect(h.registration?.storeUUID == "existing-store")
        #expect(controller.lastMismatchDetail.isEmpty)

        // A different company is never adopted.
        let other = try Harness(); other.register()
        let foreign = CompanyCloudKitBinding(
            companyID: UUID(), containerID: other.binding.containerID, environment: other.binding.environment,
            replicaID: other.binding.replicaID, cloudAccountHash: other.binding.cloudAccountHash, approvedAt: other.binding.approvedAt
        )
        other.registration = CompanyWorkspaceStoreRegistration(backendOrigin: other.session!.backendOrigin, binding: foreign, storeUUID: "existing-store")
        let second = other.controller(); await second.refresh()
        #expect(second.phase == .blocked(.differentWorkspace))
        #expect(second.lastMismatchDetail.hasPrefix("saved store registration does not match: binding differs"))
    }

    /// A Keychain registration that names a store no longer on the device
    /// (reinstall, rebuilt database) must not refuse every unlock. With no
    /// store present, a fresh one is created and registered.
    @Test func staleRegistrationWithNoStoreOnDeviceCreatesAndRegistersAFreshStore() async throws {
        let h = try Harness(); h.register()
        h.registration = CompanyWorkspaceStoreRegistration(backendOrigin: h.session!.backendOrigin, binding: h.binding, storeUUID: "4d8dcc46-old-store")
        h.storeID = nil
        let controller = h.controller(); await controller.refresh()
        #expect(controller.phase == .ready)
        #expect(controller.lastMismatchDetail.isEmpty)
        #expect(h.openCount == 1)
        #expect(h.registration?.storeUUID == "new-store")
        #expect(h.registration?.binding == h.binding)
    }

    /// A registered device whose store was swapped for a different populated
    /// one stays refused for every role (a registration is never relabelled to
    /// another store); the gate names the check.
    @Test func staleRegistrationWithADifferentStorePresentStaysRefused() async throws {
        let h = try Harness(); h.register()
        h.user = BackendAppUserRecord(email: h.user.email, role: "Admin", isActive: true, createdAt: nil)
        h.registration = CompanyWorkspaceStoreRegistration(backendOrigin: h.session!.backendOrigin, binding: h.binding, storeUUID: "4d8dcc46-old-store")
        let controller = h.controller(); await controller.refresh()
        #expect(controller.phase == .blocked(.differentWorkspace))
        #expect(h.openCount == 0)
        #expect(controller.lastMismatchDetail
                == "saved store registration does not match: store differs (registered 4d8dcc46, on device existing)")
    }

    /// A launch inside the verification interval opens the workspace from the
    /// saved lease with no server round-trip; once the lease is older than the
    /// interval the next launch or activation re-verifies, and a lease for
    /// another session is never used.
    @Test func launchInsideTheVerificationIntervalOpensFromTheSavedLease() async throws {
        let h = try Harness(); h.register(); h.cache()
        h.now = h.now.addingTimeInterval(6 * 60 * 60)
        let controller = h.controller()
        await controller.refreshIfStale(maxAge: CompanyWorkspaceAccessController.verificationInterval)
        #expect(controller.phase == .ready)
        #expect(h.fetchCount == 0)
        #expect(h.openCount == 1)
        #expect(controller.verifiedRole == .fieldTechnician)
        #expect(!h.storeIdentityWasOnMainThread)

        h.now = h.now.addingTimeInterval(CompanyWorkspaceAccessController.verificationInterval)
        await controller.refreshIfStale(maxAge: CompanyWorkspaceAccessController.verificationInterval)
        #expect(controller.phase == .ready)
        #expect(h.fetchCount == 1)

        let other = try Harness(); other.register(); other.cache()
        let s = other.session!
        other.session = CompanyWorkspaceSession(backendOrigin: s.backendOrigin, email: "someone-else@example.test",
                                                tokenFingerprint: "another-digest", expiresAt: s.expiresAt)
        let second = other.controller()
        await second.refreshIfStale(maxAge: CompanyWorkspaceAccessController.verificationInterval)
        #expect(other.fetchCount == 1)
    }

    /// The metadata lookup is allowed to take time, but a session removed
    /// while it runs must never unlock or publish the saved container.
    @Test func savedLeaseCannotOpenAfterSessionChangesDuringStoreIdentityRead() async throws {
        let h = try Harness(); h.register(); h.cache()
        let (entered, signal) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        h.onStoreIdentity = {
            signal.yield(())
            _ = release.wait(timeout: .now() + 3)
        }
        let controller = h.controller()
        let work = Task {
            await controller.refreshIfStale(maxAge: CompanyWorkspaceAccessController.verificationInterval)
        }
        for await _ in entered { break }
        h.session = nil
        controller.invalidate(accountChanged: true)
        release.signal()
        await work.value
        #expect(controller.phase == .blocked(.restartRequired))
        #expect(controller.authorizedContainer == nil)
        #expect(h.openCount == 0)
        #expect(!h.storeIdentityWasOnMainThread)
    }

    @Test func approvalGateCannotReappearAfterAccountChangeDuringStoreIdentityRead() async throws {
        let h = try Harness()
        h.user = BackendAppUserRecord(email: h.user.email, role: "Admin", isActive: true, createdAt: nil)
        h.remoteBindings = []
        let (entered, signal) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        h.onStoreIdentity = {
            signal.yield(())
            _ = release.wait(timeout: .now() + 3)
        }
        let controller = h.controller()
        let work = Task { await controller.refresh() }
        for await _ in entered { break }
        controller.invalidate(accountChanged: true)
        release.signal()
        await work.value
        #expect(controller.phase == .blocked(.restartRequired))
        #expect(controller.authorizedContainer == nil)
        #expect(h.openCount == 0 && h.approvalCount == 0)
        #expect(!h.storeIdentityWasOnMainThread)
    }

    @Test func noBusinessSessionNeverOpensAnExistingStore() async throws {
        let h = try Harness(); h.register(); h.session = nil
        let controller = h.controller()
        await controller.refresh()
        #expect(controller.phase == .blocked(.signIn))
        #expect(controller.authorizedContainer == nil)
        #expect(h.openCount == 0)
    }

    @Test func populatedForeignStoreIsDeniedToStaffAndAdministrators() async throws {
        for role in ["Field Technician", "Admin"] {
            let h = try Harness()
            h.user = BackendAppUserRecord(email: h.user.email, role: role, isActive: true, createdAt: nil)
            h.register()
            h.storeID = "another-company-store"
            let controller = h.controller()
            await controller.refresh()
            #expect(controller.phase == .blocked(.differentWorkspace))
            #expect(controller.authorizedContainer == nil)
            #expect(h.openCount == 0)
        }
    }

    @Test func backendCompanyOrOriginChangesCannotRelabelRegisteredData() async throws {
        for changeCompany in [false, true] {
            let h = try Harness(); h.register()
            if changeCompany {
                h.binding = CompanyCloudKitBinding(companyID: UUID(), containerID: h.binding.containerID, environment: h.binding.environment, replicaID: UUID(), cloudAccountHash: h.binding.cloudAccountHash, approvedAt: h.binding.approvedAt)
            } else {
                let s = h.session!
                h.session = CompanyWorkspaceSession(backendOrigin: "https://other.example.test", email: s.email, tokenFingerprint: s.tokenFingerprint, expiresAt: s.expiresAt)
            }
            let controller = h.controller(); await controller.refresh()
            #expect(controller.phase == .blocked(.differentWorkspace))
            #expect(h.openCount == 0)
        }
    }

    @Test func approvedStoreOpensOnlyAfterAccountAndCompanyMatch() async throws {
        let h = try Harness(); h.register()
        let controller = h.controller(); await controller.refresh()
        #expect(controller.phase == .ready)
        #expect(controller.authorizedContainer != nil)
        #expect(h.openCount == 1)
        #expect(h.lease?.user.email == h.user.email)
        #expect(try h.modelContainer.mainContext.fetch(FetchDescriptor<AppUser>()).contains { $0.email == h.user.email })
        await controller.prepareForIntent()
        #expect(h.openCount == 1)
    }

    @Test func existingUnregisteredDataRequiresExplicitRecentAdminApproval() async throws {
        let h = try Harness()
        h.modelContainer.mainContext.insert(Customer(name: "Retained fixture customer"))
        try h.modelContainer.mainContext.save()
        let staff = h.controller(); await staff.refresh()
        #expect(staff.phase == .blocked(.administratorRequired))
        #expect(h.openCount == 0)
        h.user = BackendAppUserRecord(email: h.user.email, role: "Admin", isActive: true, createdAt: nil)
        let admin = h.controller(); await admin.refresh()
        #expect(admin.phase == .needsApproval(hasSavedStore: true))
        #expect(!h.storeIdentityWasOnMainThread)
        await admin.approve(confirmed: false)
        #expect(h.openCount == 0 && h.approvalCount == 0)
        await admin.approve(confirmed: true)
        #expect(admin.phase == .ready)
        #expect(h.approvalCount == 1 && h.openCount == 1)
        #expect(h.registration?.storeUUID == "existing-store")
        #expect(try h.modelContainer.mainContext.fetch(FetchDescriptor<Customer>()).count == 1)
    }

    @Test func newDeviceCanReceiveApprovedCompanyReplicaWithoutInventingASecondCompany() async throws {
        let h = try Harness(); h.storeID = nil
        let controller = h.controller(); await controller.refresh()
        #expect(controller.phase == .ready)
        #expect(h.registration?.binding.replicaID == h.binding.replicaID)
        #expect(h.registration?.storeUUID == "new-store")
        #expect(h.approvalCount == 0)
    }

    @Test func missingCloudApprovalNeverBootstrapsFromRecordPresence() async throws {
        let h = try Harness(); h.remoteBindings = []
        let controller = h.controller(); await controller.refresh()
        #expect(controller.phase == .blocked(.administratorRequired))
        #expect(h.openCount == 0)
    }

    @Test func wrongCloudAccountAndEnvironmentFailBeforeStoreAttachment() async throws {
        for mismatch in ["account", "environment"] {
            let h = try Harness(); h.register()
            if mismatch == "account" { h.cloudAccountHash = String(repeating: "b", count: 64) }
            else { h.environment = "production" }
            let controller = h.controller(); await controller.refresh()
            #expect(controller.authorizedContainer == nil)
            #expect(h.openCount == 0)
        }
    }

    @Test func offlineAccessRequiresSameSessionAccountRegistrationAndUnexpiredLease() async throws {
        for age in [0.0, 86_401.0, -60.0] {
            let h = try Harness(); h.register(); h.cache()
            h.now = h.now.addingTimeInterval(age)
            h.fetchError = URLError(.notConnectedToInternet)
            let controller = h.controller(); await controller.refresh()
            #expect((controller.authorizedContainer != nil) == (age == 0))
            #expect(h.openCount == (age == 0 ? 1 : 0))
            #expect(!h.storeIdentityWasOnMainThread)
        }
        let h = try Harness(); h.register(); h.cache()
        let old = h.session!
        h.session = CompanyWorkspaceSession(backendOrigin: old.backendOrigin, email: old.email, tokenFingerprint: "different-session", expiresAt: old.expiresAt)
        h.fetchError = URLError(.notConnectedToInternet)
        let controller = h.controller(); await controller.refresh()
        #expect(controller.authorizedContainer == nil && h.openCount == 0)
    }

    @Test func authorizationFailureNeverFallsBackToCachedOfflineAccess() async throws {
        for status in [401, 403, 404, 409, 500] {
            let h = try Harness(); h.register(); h.cache()
            h.fetchError = GunnAireBackendError.server(statusCode: status, message: "Fixture rejection")
            let controller = h.controller(); await controller.refresh()
            #expect(controller.authorizedContainer == nil && h.openCount == 0)
            #expect(h.lease == nil)
        }
    }

    @Test func accountChangeInvalidatesInFlightProofAndCannotReopenInSameProcess() async throws {
        let h = try Harness(); h.register()
        let (started, signal) = AsyncStream<Void>.makeStream()
        var resume: CheckedContinuation<BackendCompanyWorkspaceResponse, Never>?
        h.delayedFetch = {
            await withCheckedContinuation { continuation in resume = continuation; signal.yield(()) }
        }
        let controller = h.controller()
        let work = Task { await controller.refresh() }
        for await _ in started { break }
        controller.invalidate(accountChanged: true)
        resume?.resume(returning: h.response)
        await work.value
        #expect(controller.phase == .blocked(.restartRequired))
        #expect(controller.authorizedContainer == nil && h.openCount == 0)
        h.delayedFetch = nil
        await controller.refresh()
        #expect(controller.phase == .blocked(.restartRequired))
    }

    @Test func registrationStorageFailureDoesNotExposeAnUnregisteredContainer() async throws {
        let h = try Harness(); h.storeID = nil; h.registrationError = true
        let controller = h.controller(); await controller.refresh()
        #expect(controller.phase == .blocked(.storage))
        #expect(controller.authorizedContainer == nil)
        #expect(h.registration == nil && h.lease == nil)
    }

    @Test func storeIdentityReadsActualSQLiteMetadataWithoutCloudKit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.store")
        #expect(try CompanyWorkspaceStore.identity(at: url) == nil)
        let schema = GunnAireModelSchema.schema
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
        container.mainContext.insert(Customer(name: "Identity fixture"))
        try container.mainContext.save()
        let readIdentity = try CompanyWorkspaceStore.identity(at: url)
        let first = try #require(readIdentity)
        #expect(!first.isEmpty)
        #expect(try CompanyWorkspaceStore.identity(at: url) == first)
    }

    @Test func signedCloudKitEnvironmentDoesNotFollowBuildModeOrQBO() throws {
        for environment in ["Development", "Production"] {
            let plist = ["Entitlements": ["com.apple.developer.icloud-container-identifiers": [GunnAireCloudKit.containerIdentifier], "com.apple.developer.icloud-container-environment": environment]]
            let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            #expect(CompanyCloudKitRuntimeAccount.environment(profileData: Data([0, 1, 2]) + xml + Data([3, 4]), hasVerifiedStoreDistribution: false) == environment.lowercased())
        }
        #expect(CompanyCloudKitRuntimeAccount.environment(profileData: nil, hasVerifiedStoreDistribution: false) == nil)
        #expect(CompanyCloudKitRuntimeAccount.environment(profileData: nil, hasVerifiedStoreDistribution: true) == "production")
        #expect(CompanyCloudKitRuntimeAccount.environment(profileData: Data("invalid profile".utf8), hasVerifiedStoreDistribution: true) == nil)
    }

    /// Real device provisioning profiles (confirmed on-device) encode this
    /// entitlement as a String array, not a single String, when the profile
    /// supports both environments. Missing this shape made environment()
    /// always return nil for real installs, surfacing as a false
    /// "Company workspace needs attention" / accountUnavailable block.
    @Test func signedCloudKitEnvironmentAcceptsArrayShapedEntitlement() throws {
        let developmentOnlyPlist = ["Entitlements": ["com.apple.developer.icloud-container-identifiers": [GunnAireCloudKit.containerIdentifier], "com.apple.developer.icloud-container-environment": ["Development"]]]
        let developmentOnlyXML = try PropertyListSerialization.data(fromPropertyList: developmentOnlyPlist, format: .xml, options: 0)
        #expect(CompanyCloudKitRuntimeAccount.environment(profileData: developmentOnlyXML, hasVerifiedStoreDistribution: false) == "development")

        let productionOnlyPlist = ["Entitlements": ["com.apple.developer.icloud-container-identifiers": [GunnAireCloudKit.containerIdentifier], "com.apple.developer.icloud-container-environment": ["Production"]]]
        let productionOnlyXML = try PropertyListSerialization.data(fromPropertyList: productionOnlyPlist, format: .xml, options: 0)
        #expect(CompanyCloudKitRuntimeAccount.environment(profileData: productionOnlyXML, hasVerifiedStoreDistribution: false) == "production")
    }

    /// Both the development and the store profile for this app carry
    /// ["Production", "Development"] - the entitlement is an allowlist, not a
    /// selection. Preferring Production unconditionally made a debug build
    /// call itself "production" while CloudKit served it the Development
    /// database, so its account hash could never match the production binding
    /// and every run failed as an opaque "workspace does not match".
    /// get-task-allow is the signed discriminator: true only for development
    /// profiles, false for App Store, Ad Hoc and Enterprise.
    @Test func bothEnvironmentsAllowedResolvesByDebuggableSigning() throws {
        func profile(debuggable: Bool?) throws -> Data {
            var entitlements: [String: Any] = [
                "com.apple.developer.icloud-container-identifiers": [GunnAireCloudKit.containerIdentifier],
                "com.apple.developer.icloud-container-environment": ["Production", "Development"]
            ]
            if let debuggable { entitlements["get-task-allow"] = debuggable }
            let xml = try PropertyListSerialization.data(fromPropertyList: ["Entitlements": entitlements], format: .xml, options: 0)
            return Data([0, 1, 2]) + xml + Data([3, 4])
        }
        #expect(CompanyCloudKitRuntimeAccount.environment(profileData: try profile(debuggable: true), hasVerifiedStoreDistribution: false) == "development")
        #expect(CompanyCloudKitRuntimeAccount.environment(profileData: try profile(debuggable: false), hasVerifiedStoreDistribution: false) == "production")
        // A missing key must fail closed to distribution, never to development.
        #expect(CompanyCloudKitRuntimeAccount.environment(profileData: try profile(debuggable: nil), hasVerifiedStoreDistribution: false) == "production")
    }

    /// A single-environment profile is unambiguous and must ignore
    /// get-task-allow entirely: a development-signed build of a
    /// Production-only profile still reaches Production.
    @Test func singleEnvironmentEntitlementIgnoresDebuggableSigning() throws {
        for (value, expected) in [("Production", "production"), ("Development", "development")] {
            for debuggable in [true, false] {
                let entitlements: [String: Any] = [
                    "com.apple.developer.icloud-container-identifiers": [GunnAireCloudKit.containerIdentifier],
                    "com.apple.developer.icloud-container-environment": [value],
                    "get-task-allow": debuggable
                ]
                let xml = try PropertyListSerialization.data(fromPropertyList: ["Entitlements": entitlements], format: .xml, options: 0)
                #expect(CompanyCloudKitRuntimeAccount.environment(profileData: xml, hasVerifiedStoreDistribution: false) == expected)
            }
        }
    }

    @Test func businessDataRequestsRequireWorkspaceProofButIdentityEstablishmentDoesNot() {
        for path in ["/api/users", "/api/documents", "/api/payments", "/api/qbo/tokens", "/api/communications", "/api/readiness"] {
            #expect(CompanyWorkspaceRequestPolicy.needsWorkspaceProof(path: path))
        }
        for path in ["/api/auth/apple", "/api/auth/google", "/api/auth/logout", "/api/workspace", "/api/workspace/bind", "/api/session"] {
            #expect(!CompanyWorkspaceRequestPolicy.needsWorkspaceProof(path: path))
        }
    }

    @Test func expiryClosesTheMountedWorkspaceAndClearsContinuationsWithoutNavigation() async throws {
        for lifetime in [60.0, 172_800.0] {
            let h = try Harness()
            let old = h.session!
            h.session = CompanyWorkspaceSession(backendOrigin: old.backendOrigin, email: old.email, tokenFingerprint: old.tokenFingerprint, expiresAt: h.now.addingTimeInterval(lifetime))
            h.register()
            let (started, start) = AsyncStream<Void>.makeStream()
            var wake: CheckedContinuation<Void, Never>?
            var scheduledInterval = 0.0
            h.delayedSleep = { interval in
                scheduledInterval = interval
                await withCheckedContinuation { continuation in wake = continuation; start.yield(()) }
            }
            let controller = h.controller()
            await controller.refresh()
            for await _ in started { break }
            #expect(controller.phase == .ready)
            #expect(scheduledInterval == min(lifetime, 86_400))
            let generation = controller.generation
            let (expired, event) = AsyncStream<Void>.makeStream()
            let observation = controller.$phase.sink { phase in
                if phase == .blocked(.signIn) { event.yield(()) }
            }
            h.now = h.now.addingTimeInterval(scheduledInterval)
            wake?.resume()
            for await _ in expired { break }
            #expect(controller.authorizedContainer == nil)
            #expect(controller.generation != generation)
            #expect(h.lease == nil && h.clearedContinuations == 1)
            #expect(h.registration != nil && h.storeID == "existing-store")
            withExtendedLifetime(observation) {}
        }
    }

    @Test func clockRollbackAndSessionReplacementCloseAnAlreadyMountedWorkspace() async throws {
        for clockChanged in [false, true] {
            let h = try Harness(); h.register()
            let controller = h.controller(); await controller.refresh()
            if clockChanged { h.now = h.now.addingTimeInterval(-60) }
            else { h.session = nil }
            controller.enforceAccessDeadline()
            #expect(controller.phase == .blocked(.signIn))
            #expect(controller.authorizedContainer == nil && h.clearedContinuations == 1)
            #expect(h.registration != nil)
        }
    }

    @Test func concurrentIntentWaitsForTheSameWorkspaceProof() async throws {
        let h = try Harness(); h.register()
        let (started, signal) = AsyncStream<Void>.makeStream()
        var resume: CheckedContinuation<BackendCompanyWorkspaceResponse, Never>?
        h.delayedFetch = {
            await withCheckedContinuation { continuation in resume = continuation; signal.yield(()) }
        }
        let controller = h.controller()
        let refresh = Task { await controller.refresh() }
        for await _ in started { break }
        let (joined, join) = AsyncStream<Void>.makeStream()
        var intentFinished = false
        let intent = Task {
            join.yield(())
            await controller.prepareForIntent()
            intentFinished = true
        }
        for await _ in joined { break }
        // Give the intent a chance to reach the suspended shared task.
        await Task.yield()
        #expect(!intentFinished && h.fetchCount == 1 && h.openCount == 0)
        resume?.resume(returning: h.response)
        await refresh.value
        await intent.value
        #expect(intentFinished && h.fetchCount == 1 && h.openCount == 1)
        #expect(controller.phase == .ready)
    }

    @Test func replacedSessionCannotApplyAnOldInFlightProof() async throws {
        let h = try Harness(); h.register()
        let (started, signal) = AsyncStream<Void>.makeStream()
        var resume: CheckedContinuation<BackendCompanyWorkspaceResponse, Never>?
        h.delayedFetch = {
            await withCheckedContinuation { continuation in resume = continuation; signal.yield(()) }
        }
        let controller = h.controller()
        let work = Task { await controller.refresh() }
        for await _ in started { break }
        let s = h.session!
        h.session = CompanyWorkspaceSession(backendOrigin: s.backendOrigin, email: s.email, tokenFingerprint: "replacement", expiresAt: s.expiresAt)
        resume?.resume(returning: h.response)
        await work.value
        #expect(controller.phase == .blocked(.signIn))
        #expect(controller.authorizedContainer == nil && h.openCount == 0)
        h.delayedFetch = nil
        await controller.refresh()
        #expect(controller.phase == .ready && h.openCount == 1)
    }

    @Test func replacedSessionCannotUseALeaseReturnedByDelayedSecureStorage() async throws {
        let h = try Harness(); h.register(); h.cache()
        let savedLease = h.lease
        let (started, signal) = AsyncStream<Void>.makeStream()
        var resume: CheckedContinuation<CompanyWorkspaceLease?, Never>?
        h.delayedReadLease = {
            await withCheckedContinuation { continuation in
                resume = continuation
                signal.yield(())
            }
        }
        let controller = h.controller()
        let work = Task { await controller.refreshIfStale(maxAge: 60) }
        for await _ in started { break }
        h.session = nil
        resume?.resume(returning: savedLease)
        await work.value
        #expect(controller.phase == .blocked(.signIn))
        #expect(controller.authorizedContainer == nil)
        #expect(h.lease == nil)
    }

    @Test func cachedSessionProofRejectsExpiredAndEmptyTokens() async {
        let origin = "https://company.example.test"
        let valid = await Task.detached {
            CompanyWorkspaceSession.validated(
                token: "opaque-session", email: " STAFF@example.test ",
                expiry: "2099-01-01T00:00:00Z", backendOrigin: origin
            )
        }.value
        #expect(valid?.email == "staff@example.test")
        #expect(valid?.tokenFingerprint == CompanyWorkspaceSession.digest("opaque-session"))
        let empty = await Task.detached {
            CompanyWorkspaceSession.validated(token: "", email: "staff@example.test",
                                              expiry: "2099-01-01T00:00:00Z", backendOrigin: origin)
        }.value
        let expired = await Task.detached {
            CompanyWorkspaceSession.validated(token: "opaque-session", email: "staff@example.test",
                                              expiry: "2020-01-01T00:00:00Z", backendOrigin: origin)
        }.value
        #expect(empty == nil && expired == nil)
    }

    @Test func foregroundStorageMismatchRevokesMountedWorkspace() async throws {
        let h = try Harness(); h.register()
        h.sessionStorageValid = { false }
        let controller = h.controller(); await controller.refresh()
        #expect(controller.phase == .ready)
        await controller.revalidateSessionStorageOnForeground()
        #expect(controller.phase == .blocked(.signIn))
        #expect(controller.authorizedContainer == nil)
        #expect(h.discardedProofCount == 1)
        #expect(h.lease == nil)
    }

    @Test func staleApprovalExplainsReauthenticationWithoutOpeningTheStore() async throws {
        let h = try Harness()
        h.user = BackendAppUserRecord(email: h.user.email, role: "Admin", isActive: true, createdAt: nil)
        h.approvalError = GunnAireBackendError.server(statusCode: 403, message: "Fixture stale authentication")
        let controller = h.controller(); await controller.refresh()
        await controller.approve(confirmed: true)
        #expect(controller.phase == .blocked(.signIn))
        #expect(h.openCount == 0 && h.registration == nil)
        #expect(CompanyWorkspaceAccessController.failure(for: GunnAireBackendError.server(statusCode: 409, message: "Fixture conflict"), verifiedAccount: true) == .differentWorkspace)
    }

    @Test func refreshedPermissionsInvalidateOldSheetsAndRequestGenerations() async throws {
        let h = try Harness(); h.register()
        let controller = h.controller(); await controller.refresh()
        let original = controller.generation
        await controller.refresh()
        #expect(controller.generation == original && h.openCount == 1)
        h.user = BackendAppUserRecord(email: h.user.email, role: "Standard", isActive: true, createdAt: nil)
        await controller.refresh()
        #expect(controller.phase == .ready && controller.generation != original)
        #expect(h.lease?.user.role == "Standard" && h.clearedContinuations == 1)
        #expect(h.openCount == 1)
    }

    @Test func serverRevocationClosesMountedAccessAndKeepsTheStoreRegistration() async throws {
        let h = try Harness(); h.register()
        let controller = h.controller(); await controller.refresh()
        let original = controller.generation
        h.fetchError = GunnAireBackendError.server(statusCode: 401, message: "Fixture revoked session")
        await controller.refresh()
        #expect(controller.phase == .blocked(.signIn))
        #expect(controller.generation != original && controller.authorizedContainer == nil)
        #expect(h.lease == nil && h.registration != nil && h.clearedContinuations == 1)
    }

    @Test func mirroredAdministratorCannotReplaceVerifiedFieldAuthority() async throws {
        let h = try Harness(); h.register()
        let controller = h.controller(); await controller.refresh()
        let users = try h.modelContainer.mainContext.fetch(FetchDescriptor<AppUser>())
        let user = try #require(users.first { $0.email == h.user.email })
        #expect(AppAccess.activeRole(email: user.email, users: users, verifiedUser: controller.verifiedUser) == .fieldTechnician)
        user.role = .admin
        try h.modelContainer.mainContext.save()
        #expect(controller.verifiedRole == .fieldTechnician)
        #expect(AppAccess.activeRole(email: user.email, users: users, verifiedUser: controller.verifiedUser) == .fieldTechnician)
        let editedCreationDate = user.createdAt.addingTimeInterval(1)
        user.createdAt = editedCreationDate
        await controller.refresh()
        #expect(controller.verifiedRole == .fieldTechnician)
        #expect(user.role == .fieldTechnician)
        #expect(user.createdAt == editedCreationDate)
        #expect(AppAccess.activeRole(email: user.email, users: users, verifiedUser: controller.verifiedUser) == .fieldTechnician)
        let persistedBeforeEdit = try ModelContext(h.modelContainer).fetch(FetchDescriptor<AppUser>())
        #expect(persistedBeforeEdit.first { $0.email == user.email }?.role == .fieldTechnician)
        // Saving a previously unsaved unrelated edit on the registered main
        // object must not restore its old administrator role to the store.
        try h.modelContainer.mainContext.save()
        let persistedAfterEdit = try ModelContext(h.modelContainer).fetch(FetchDescriptor<AppUser>())
        #expect(persistedAfterEdit.first { $0.email == user.email }?.role == .fieldTechnician)
        #expect(persistedAfterEdit.first { $0.email == user.email }?.createdAt == editedCreationDate)
    }

    @Test func expiredAndRevokedLeasesCannotAuthorizeMirroredUsers() async throws {
        for expire in [true, false] {
            let h = try Harness(); h.register()
            let controller = h.controller(); await controller.refresh()
            let users = try h.modelContainer.mainContext.fetch(FetchDescriptor<AppUser>())
            #expect(controller.verifiedUser != nil)
            if expire { h.now = h.now.addingTimeInterval(86_400) }
            else { controller.invalidate() }
            #expect(controller.verifiedUser == nil)
            #expect(AppAccess.activeRole(email: h.user.email, users: users, verifiedUser: controller.verifiedUser) == nil)
            #expect(try h.modelContainer.mainContext.fetch(FetchDescriptor<AppUser>()).count == users.count)
            #expect(h.registration != nil)
        }
    }

    @Test func providerStampTracksApprovedSessionRoleAndExpiration() async throws {
        let h = try Harness(); h.register()
        let controller = h.controller()
        #expect(controller.operationStamp == nil)
        await controller.refresh()
        let stamp = try #require(controller.operationStamp)
        let operation = WorkspaceProviderOperation { controller.operationStamp == stamp }
        #expect(operation.failure == nil)
        await controller.refresh()
        #expect(operation.failure == nil)
        h.user = BackendAppUserRecord(email: h.user.email, role: "Standard", isActive: true, createdAt: nil)
        await controller.refresh()
        #expect(operation.failure == .changed(mayHaveReachedProvider: false))
        let renewed = try #require(controller.operationStamp)
        let next = WorkspaceProviderOperation { controller.operationStamp == renewed }
        h.now = h.now.addingTimeInterval(86_400)
        #expect(next.failure == .changed(mayHaveReachedProvider: false))
        #expect(controller.operationStamp == nil)
    }
}
