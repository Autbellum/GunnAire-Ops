import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor struct StaffWorkspaceSourceStagingTests {
    typealias S = StaffWorkspaceSourceStaging
    @Test func encryptedJournalRetainsAll32ModelsAndOriginalDeletionsAcrossRelaunch() throws {
        let helpers = StaffWorkspaceHistoryTests(), root = try helpers.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Owner.store"), files = root.appendingPathComponent("Encrypted", isDirectory: true)
        let f = StaffReplicaSourceSyncTests.Fixture()
        func storage() -> SharedTimeLocalStore { .encrypted(directory: files, maximumBytes: 64 * 1024 * 1024, key: { _ in Data(repeating: 27, count: 32) }) }
        var originals = Set<String>()
        try autoreleasepool {
            let container = try helpers.container(url), context = container.mainContext
            context.autosaveEnabled = false
            let models = StaffWorkspaceFullModelTests().fixtures()
            for model in models { context.insert(model) }; try context.save()
            f.storeID = try helpers.identity(url)
            let first = try S.prepare(container: container, scope: f.scope, store: storage(), check: {})
            originals = Set(first.records.map(StaffWorkspaceHistory.key))
            #expect(first.records.count == 32 && first.deletionKeys.isEmpty && first.cursor != nil)
            #expect(try storage().read(f.scope.key) == nil) // Six-kind journal never reused.
            let sealedFiles = try FileManager.default.contentsOfDirectory(at: files, includingPropertiesForKeys: nil)
            #expect(sealedFiles.count == 1)
            let sealed = try Data(contentsOf: #require(sealedFiles.first))
            #expect(sealed.range(of: Data("Original customer".utf8)) == nil)
            for model in models.reversed() { context.delete(model) }; try context.save()
        }
        let reopened = try helpers.container(url)
        let deleted = try S.prepare(container: reopened, scope: f.scope, store: storage(), check: {})
        #expect(deleted.records.isEmpty && Set(deleted.deletionKeys) == originals && originals.count == 32)
        let again = try S.prepare(container: reopened, scope: f.scope, store: storage(), check: {})
        #expect(again == deleted) // No new history must not discard unacknowledged tombstones.
        let storedBytes = try storage().read(S.key(f.scope))
        let bytes = try #require(storedBytes)
        #expect(try StaffWorkspaceSourceJournal.decode(bytes, scope: f.scope) == deleted)
        let other = StaffReplicaSourceScope(backendOrigin: f.scope.backendOrigin, actorEmail: "other@example.invalid",
                                            binding: f.binding, storeUUID: f.storeID)
        #expect(S.key(other) != S.key(f.scope))
        #expect(try storage().read(S.key(other)) == nil)
        #expect(throws: StaffReplicaSourceSyncError.storage) { try StaffWorkspaceSourceJournal.decode(bytes, scope: other) }
        let customerKey = try #require(deleted.deletionKeys.first { $0.hasPrefix("customer:") })
        let customerID = try #require(UUID(uuidString: String(customerKey.dropFirst("customer:".count))))
        let restored = Customer(name: "Restored original"); restored.id = customerID
        reopened.mainContext.insert(restored); try reopened.mainContext.save()
        let restoredJournal = try S.prepare(container: reopened, scope: f.scope, store: storage(), check: {})
        #expect(restoredJournal.records.count == 1 && restoredJournal.records.first?.id == customerID)
        #expect(Set(restoredJournal.deletionKeys) == originals.subtracting([customerKey]))
    }

    @Test func failedWriteOrRevokedScopePreservesOriginalCursorAndSnapshot() throws {
        let helpers = StaffWorkspaceHistoryTests(), root = try helpers.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Owner.store"), container = try helpers.container(url), context = container.mainContext
        context.autosaveEnabled = false
        let f = StaffReplicaSourceSyncTests.Fixture(); f.storeID = try helpers.identity(url)
        var saved: [String: Data] = [:], fail = false
        let storage = SharedTimeLocalStore(read: { saved[$0] }, write: { key, bytes in
            if fail { throw StaffReplicaSourceSyncError.storage }; saved[key] = bytes
        })
        let vendor = Vendor(name: "Original"); context.insert(vendor); try context.save()
        let first = try S.prepare(container: container, scope: f.scope, store: storage, check: {})
        let originalBytes = saved
        vendor.name = "Later saved work"; try context.save(); fail = true
        #expect(throws: StaffReplicaSourceSyncError.storage) { try S.prepare(container: container, scope: f.scope, store: storage, check: {}) }
        #expect(saved == originalBytes && vendor.name == "Later saved work")
        fail = false
        var checks = 0
        #expect(throws: StaffReplicaSourceSyncError.access) {
            try S.prepare(container: container, scope: f.scope, store: storage, check: {
                checks += 1; if checks == 2 { throw StaffReplicaSourceSyncError.access }
            })
        }
        #expect(checks == 2 && saved == originalBytes)
        let recovered = try S.prepare(container: container, scope: f.scope, store: storage, check: {})
        #expect(recovered.cursor != first.cursor && recovered.records.first?.id == vendor.id)
        #expect(recovered.records.first?.fields["name"] == .text("Later saved work"))
    }

    @Test func malformedOrFutureJournalCannotBeReplacedWithAnEmptySuccess() throws {
        let helpers = StaffWorkspaceHistoryTests(), root = try helpers.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Owner.store"), container = try helpers.container(url)
        let f = StaffReplicaSourceSyncTests.Fixture(); f.storeID = try helpers.identity(url)
        var saved: Data?, writes = 0
        let storage = SharedTimeLocalStore(read: { _ in saved }, write: { _, bytes in saved = bytes; writes += 1 })
        let initial = try S.prepare(container: container, scope: f.scope, store: storage, check: {})
        let bytes = try JSONEncoder().encode(initial)
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object["futureAuthority"] = true
        let unknown = try JSONSerialization.data(withJSONObject: object)
        for invalid in [Data("broken".utf8), unknown] {
            saved = invalid
            #expect(throws: StaffReplicaSourceSyncError.storage) { try S.prepare(container: container, scope: f.scope, store: storage, check: {}) }
            #expect(saved == invalid && writes == 1)
        }
    }

    /// The publication coordinator now stages on a background task. The
    /// journal it produces must be the one the synchronous staging produces,
    /// the unsaved-work fence must still hold on the main context before and
    /// after the capture, and a failed second session check must leave the
    /// sealed journal untouched.
    @Test func offMainStagingMatchesTheSynchronousJournalAndKeepsBothFences() async throws {
        let helpers = StaffWorkspaceHistoryTests(), root = try helpers.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Owner.store"), container = try helpers.container(url), context = container.mainContext
        context.autosaveEnabled = false
        let f = StaffReplicaSourceSyncTests.Fixture(); f.storeID = try helpers.identity(url)
        func storage(_ name: String) -> SharedTimeLocalStore {
            .encrypted(directory: root.appendingPathComponent(name, isDirectory: true), maximumBytes: 64 * 1024 * 1024,
                       key: { _ in Data(repeating: 27, count: 32) })
        }
        func sealed(_ name: String) throws -> [Data] {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }.map { try Data(contentsOf: $0) }
        }
        for name in ["Sync", "OffMain"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: false)
        }
        let models = StaffWorkspaceFullModelTests().fixtures()
        for model in models { context.insert(model) }; try context.save()

        let synchronous = try S.prepare(container: container, scope: f.scope, store: storage("Sync"), check: {})
        var checks = 0
        let background = try await S.prepareOffMain(container: container, scope: f.scope, store: storage("OffMain"), check: { checks += 1 })
        #expect(background == synchronous && background.records.count == 32 && checks == 2)
        let firstBytes = try sealed("OffMain")
        #expect(firstBytes.count == 1)
        let stored = try #require(try storage("OffMain").read(S.key(f.scope)))
        #expect(try StaffWorkspaceSourceJournal.decode(stored, scope: f.scope) == synchronous)

        // Unsaved main-context work is refused before any background read.
        let vendor = try #require(models.compactMap { $0 as? Vendor }.first)
        vendor.name = "Unsaved owner edit"
        checks = 0
        await #expect(throws: StaffReplicaSourceError.self) {
            try await S.prepareOffMain(container: container, scope: f.scope, store: storage("OffMain"), check: { checks += 1 })
        }
        #expect(checks == 1 && vendor.name == "Unsaved owner edit" && context.hasChanges)
        #expect(try sealed("OffMain") == firstBytes)
        try context.save()

        // A session check that fails after the capture leaves the journal as it was.
        checks = 0
        await #expect(throws: StaffReplicaSourceSyncError.access) {
            try await S.prepareOffMain(container: container, scope: f.scope, store: storage("OffMain"), check: {
                checks += 1; if checks == 2 { throw StaffReplicaSourceSyncError.access }
            })
        }
        #expect(checks == 2)
        #expect(try sealed("OffMain") == firstBytes)

        // The saved edit is then staged, and an unchanged tree stages without a write.
        let edited = try await S.prepareOffMain(container: container, scope: f.scope, store: storage("OffMain"), check: {})
        // The journal is a full snapshot: all 32 records stay, the vendor updated in place.
        #expect(edited.cursor != synchronous.cursor && edited.records.count == 32 && edited.deletionKeys.isEmpty)
        let vendorRecord = try #require(edited.records.first { $0.id == vendor.id })
        #expect(vendorRecord.fields["name"] == .text("Unsaved owner edit"))
        let editedBytes = try sealed("OffMain")
        #expect(editedBytes != firstBytes && editedBytes.count == 1)
        let unchanged = try await S.prepareOffMain(container: container, scope: f.scope, store: storage("OffMain"), check: {})
        #expect(unchanged == edited)
        #expect(try sealed("OffMain") == editedBytes)
        let resynced = try S.prepare(container: container, scope: f.scope, store: storage("Sync"), check: {})
        #expect(resynced == edited)
    }
}
