import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor struct SharedJobBillingDispatchTests {
    typealias Fixture = JobBillingDispatchTests.Fixture
    func business(_ f: Fixture) -> JobBillingBusinessScope { .init(companyID: f.company, actorEmail: f.email) }

    @Test func firstSavedCrewUsesBusinessSessionAndOneOriginalOperationWithoutOAuth() async throws {
        let f = try Fixture(), d = f.coordinator(shared: true)
        try f.save(d)
        let original = try #require(try f.pending(d))
        #expect(f.files.isEmpty && !f.bootstrapFiles.isEmpty && !f.context.hasChanges)
        #expect(original.baseline == nil && original.request == nil)
        let result = try await f.liveSync(d)
        #expect(result.snapshot.assignment?.usable == true)
        #expect(f.writes.count == 1 && f.writes[0].operationID == original.id)
        #expect(try f.pending(d) == nil)
        #expect(try f.bootstrapStore.read(business(f)).records.isEmpty)
        let handle = try d.capture(context: f.context)
        #expect(handle.workflow.sharedBillingConnectionRevision == f.epoch)
    }

    @Test func firstUseOfflineRestartRetainsSavedJobAndRequiresVisibleCrewReview() async throws {
        let f = try Fixture(), d = f.coordinator(shared: true)
        try f.save(d)
        let original = try #require(try f.pending(d))
        let retained = f.bootstrapFiles
        f.discoveryError = URLError(.notConnectedToInternet)
        await d.resume(context: f.context)
        #expect(f.bootstrapFiles == retained && f.files.isEmpty && f.writes.isEmpty)
        f.discoveryError = nil
        let restarted = f.coordinator(shared: true)
        await restarted.resume(context: f.context)
        #expect(try f.pending(restarted)?.id == original.id)
        #expect(try f.pending(restarted)?.state == .review && f.writes.isEmpty)
        let review = try await restarted.refresh(f.call, context: f.context)
        _ = try await restarted.applySavedCrew(f.call, context: f.context, reviewed: review)
        #expect(f.writes.count == 1 && f.remote?.technicianEmails == ["alex@example.invalid"])
    }

    @Test func knownBusinessOfflineReassignmentAndLostReplyRecoverWithoutSecondPost() async throws {
        let f = try Fixture(), d = f.coordinator(shared: true)
        f.setRemote(); _ = try await d.refresh(f.call, context: f.context)
        let original = try JobBillingTarget.capture(f.call, context: f.context).1
        f.call.assignedTechnician = f.second; try f.save(d, original: original)
        f.loseWriteResponse = true
        await #expect(throws: BillingPublicationError.unavailable) { try await f.liveSync(d) }
        #expect(try f.pending(d)?.request != nil && f.writes.count == 1)
        let restarted = f.coordinator(shared: true)
        await restarted.resume(context: f.context)
        #expect(try f.pending(restarted) == nil && f.writes.count == 1)
        #expect(f.remote?.technicianEmails == ["sam@example.invalid"])
    }

    @Test func legacyRealmJournalResumesUsingSharedBusinessDiscovery() async throws {
        let f = try Fixture(), legacy = f.coordinator()
        f.setRemote(); _ = try await legacy.refresh(f.call, context: f.context)
        let original = try JobBillingTarget.capture(f.call, context: f.context).1
        f.call.assignedTechnician = f.second; try f.save(legacy, original: original)
        let savedID = try #require(try f.pending(legacy)?.id)
        let shared = f.coordinator(shared: true)
        await shared.resume(context: f.context)
        #expect(f.writes.count == 1 && f.writes[0].operationID == savedID)
        #expect(try f.pending(shared) == nil)
    }

    @Test func malformedOrOldServerCannotBindOrEraseFirstUseIntent() async throws {
        for changes: [String: Any] in [["companyID": UUID().uuidString], ["realmID": ""], ["environment": "unknown"],
                                     ["protocolVersion": 2], ["connectionRevision": String(repeating: "A", count: 64)]] {
            let f = try Fixture(), d = f.coordinator(shared: true)
            try f.save(d); let saved = f.bootstrapFiles
            f.discoveryChanges = changes
            await #expect(throws: JobBillingDispatchError.connection) { try await d.refresh(f.call, context: f.context) }
            #expect(f.bootstrapFiles == saved && f.files.isEmpty && f.writes.isEmpty)
        }
        let f = try Fixture(), d = f.coordinator(shared: true)
        try f.save(d); let saved = f.bootstrapFiles
        f.discoveryError = GunnAireBackendError.server(statusCode: 404, message: "Untrusted internal details")
        await #expect(throws: JobBillingDispatchError.serverUpdate) { try await d.refresh(f.call, context: f.context) }
        #expect(f.bootstrapFiles == saved && f.writes.isEmpty)
    }

    @Test func changedUserRoleAndNavigationCannotFinishConnectionDiscovery() async throws {
        for change in 0..<3 {
            let f = try Fixture(), d = f.coordinator(shared: true)
            try f.save(d); let saved = f.bootstrapFiles
            var current = true
            f.beforeDiscovery = {
                if change == 0 { f.email = "other@example.invalid" }
                if change == 1 { f.authorized = false }
                if change == 2 { current = false }
            }
            await #expect(throws: WorkspaceProviderAccessError.self) {
                try await d.refresh(f.call, context: f.context, isCurrent: { current })
            }
            #expect(f.bootstrapFiles == saved && f.files.isEmpty && f.writes.isEmpty)
        }
    }

    @Test func changedCrewOrDeletedJobDuringDiscoveryCannotApproveReplacementWork() async throws {
        for deleted in [false, true] {
            let f = try Fixture(), d = f.coordinator(shared: true)
            f.beforeDiscovery = {
                if deleted { f.context.delete(f.call) }
                else { f.call.assignedTechnician = f.second }
                try f.context.save()
            }
            await #expect(throws: JobBillingDispatchError.changed) { try await d.refresh(f.call, context: f.context) }
            #expect(f.writes.isEmpty)
        }
    }

    @Test func replacementGrantAfterDiscoveryCannotReadOrWriteUnderOldPin() async throws {
        let f = try Fixture(), d = f.coordinator(shared: true)
        try f.save(d)
        f.beforeReply = { f.epoch = String(repeating: "b", count: 64) }
        await #expect(throws: BillingPublicationError.reviewRequired) { try await f.liveSync(d) }
        let pending = try f.pending(d)
        #expect(f.writes.isEmpty && pending != nil)
    }

    @Test func replacementAccountingRealmNeverMovesOriginalPendingQueue() async throws {
        let f = try Fixture(), d = f.coordinator(shared: true)
        f.setRemote(); _ = try await d.refresh(f.call, context: f.context)
        f.call.assignedTechnician = f.second; try f.save(d)
        let pending = try f.pending(d), files = f.files, bootstrap = f.bootstrapFiles
        f.discoveryChanges = ["realmID": "another-realm"]
        await #expect(throws: JobBillingDispatchError.connection) { try await d.refresh(f.call, context: f.context) }
        #expect(f.files == files && f.bootstrapFiles == bootstrap && f.writes.isEmpty)
        #expect(try f.pending(d) == pending)
    }

    @Test func interruptedTransferCannotResurrectAlreadyConfirmedImportedEdit() async throws {
        let f = try Fixture(), d = f.coordinator(shared: true)
        try f.save(d)
        let editID = try #require(try f.pending(d)?.id)
        f.afterStoreWrite = { f.failBootstrapWrite = true }
        await #expect(throws: JobBillingDispatchError.storage) { try await d.discover(context: f.context) }
        #expect(try f.bootstrapStore.read(business(f)).records.count == 1)
        var bound = try f.store.read(f.scope)
        #expect(bound.records[0].importedBootstrapEditID == editID)
        // Model confirmation by another live run before cleanup could persist.
        f.afterStoreWrite = nil; f.failBootstrapWrite = false; f.setRemote()
        bound.records[0].pending = nil
        bound.records[0].confirmed = .init(assignment: f.remote, connectionRevision: f.epoch)
        try f.store.write(bound)
        await f.coordinator(shared: true).resume(context: f.context)
        #expect(try f.bootstrapStore.read(business(f)).records.isEmpty)
        #expect(try f.store.read(f.scope).records[0].pending == nil)
        #expect(f.writes.isEmpty)
    }

    @Test func failedFirstSaveAndPostSaveJournalFailureRetainCorrectLocalOutcome() async throws {
        let f = try Fixture(), d = f.coordinator(shared: true)
        f.call.assignedTechnician = f.second
        #expect(throws: JobBillingDispatchError.save) {
            try d.save(f.call, original: nil, context: f.context, saveLocal: { _ in throw JobBillingDispatchError.save }, startSync: false)
        }
        #expect(try f.pending(d)?.state == .prepared && f.writes.isEmpty)
        await d.resume(context: f.context)
        #expect(f.writes.isEmpty)
        let g = try Fixture(), shared = g.coordinator(shared: true)
        _ = try shared.save(g.call, original: nil, context: g.context, saveLocal: { context in
            try context.save(); g.failBootstrapWrite = true
        }, startSync: false)
        let retained = try g.pending(shared)
        #expect(!g.context.hasChanges && retained?.state == .prepared)
    }

    @Test func firstUseEncryptedJournalIsAccountBoundAndNeverResetsMissingKeys() throws {
        let f = try Fixture(), d = f.coordinator(shared: true)
        try f.save(d)
        let value = try f.bootstrapStore.read(business(f))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shared-job-fixture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JobBillingBootstrapStore.encrypted(directory: directory) { _ in Data(repeating: 9, count: 32) }
        try store.write(value)
        #expect(try store.read(business(f)) == value)
        let other = JobBillingBusinessScope(companyID: f.company, actorEmail: "other@example.invalid")
        try FileManager.default.copyItem(at: directory.appendingPathComponent(value.business.storageKey + ".sealed"),
            to: directory.appendingPathComponent(other.storageKey + ".sealed"))
        #expect(throws: JobBillingDispatchError.storage) { try store.read(other) }
        let locked = JobBillingBootstrapStore.encrypted(directory: directory) { _ in throw JobBillingDispatchError.storage }
        #expect(throws: JobBillingDispatchError.storage) { try locked.read(business(f)) }
        #expect(throws: JobBillingDispatchError.storage) { try locked.write(value) }
        #expect(try store.read(business(f)) == value)
    }
}
