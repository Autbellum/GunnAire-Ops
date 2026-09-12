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
}
