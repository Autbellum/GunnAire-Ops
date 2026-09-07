import Foundation
import SwiftData
import Testing
import Combine
@testable import GunnAire_Ops

@MainActor
struct CompanyWorkspaceAccessTests {
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
        var storeID: String? = "existing-store"
        var openCount = 0
        var approvalCount = 0
        var fetchError: Error?
        var fetchCount = 0
        var approvalError: Error?
        var delayedFetch: (() async throws -> BackendCompanyWorkspaceResponse)?
        var delayedSleep: ((TimeInterval) async throws -> Void)?
        var clearedContinuations = 0
        var registrationError = false
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
                session: { self.session },
                account: { CompanyCloudKitAccount(environment: self.environment, accountHash: self.cloudAccountHash) },
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
                storeIdentity: { self.storeID },
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
                clearContinuations: { self.clearedContinuations += 1 }
            ))
        }
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
