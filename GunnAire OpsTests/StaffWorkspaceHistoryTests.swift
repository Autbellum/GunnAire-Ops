import Foundation
import SwiftData
import CoreData
import Testing
@testable import GunnAire_Ops

@MainActor struct StaffWorkspaceHistoryTests {
    typealias H = StaffWorkspaceHistory
    func directory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("GAFullHistory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false)
        return value
    }
    func container(_ url: URL) throws -> ModelContainer {
        let schema = GunnAireModelSchema.schema
        return try ModelContainer(for: schema, configurations: [.init(schema: schema, url: url, cloudKitDatabase: .none)])
    }
    func identity(_ url: URL) throws -> String {
        let value = try CompanyWorkspaceStore.identity(at: url)
        return try #require(value)
    }

    @Test func everyBusinessModelRetainsItsOriginalIDOnDeletion() throws {
        let schema = GunnAireModelSchema.schema
        let missing = schema.entities.filter {
            $0.attributesByName["id"]?.options.contains(.preserveValueOnDeletion) != true
        }.map(\.name).sorted()
        #expect(schema.entities.count == 32)
        #expect(missing.isEmpty, "Deletion history must cover every business model: \(missing)")
    }

    @Test func originalDeletedInvoiceAndPaymentIDsSurviveStoreReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GAFullHistoryReproduction-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Original.store"), schema = GunnAireModelSchema.schema
        var invoiceID: UUID?, paymentID: UUID?
        do {
            let container = try ModelContainer(for: schema, configurations: [.init(schema: schema, url: url, cloudKitDatabase: .none)])
            let context = container.mainContext; context.autosaveEnabled = false
            let customer = Customer(name: "History fixture")
            let invoice = Invoice(customer: customer, amount: 189)
            let payment = Payment(invoice: invoice, amount: 50)
            context.insert(customer); context.insert(invoice); context.insert(payment)
            try context.save()
            invoiceID = invoice.id; paymentID = payment.id
            context.delete(payment); context.delete(invoice)
            try context.save()
        }
        let reopened = try ModelContainer(for: schema, configurations: [.init(schema: schema, url: url, cloudKitDatabase: .none)])
        let history = try reopened.mainContext.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>())
        var invoices: [UUID?] = [], payments: [UUID?] = []
        for transaction in history {
            for change in transaction.changes {
                guard case .delete(let deletion) = change else { continue }
                if let invoice = deletion as? DefaultHistoryDelete<Invoice> { invoices.append(invoice.tombstone[\Invoice.id] as? UUID) }
                if let payment = deletion as? DefaultHistoryDelete<Payment> { payments.append(payment.tombstone[\Payment.id] as? UUID) }
            }
        }
        #expect(invoices.count == 1 && invoices.first! == invoiceID)
        #expect(payments.count == 1 && payments.first! == paymentID)
    }

    @Test func all32OriginalDeletionsSurviveReopenAndCursorResume() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Original.store")
        var original: StaffWorkspaceHistoryCapture?, storeID: String?
        try autoreleasepool {
            let store = try container(url), context = store.mainContext
            context.autosaveEnabled = false
            let models = StaffWorkspaceFullModelTests().fixtures()
            for model in models { context.insert(model) }; try context.save()
            storeID = try identity(url)
            let snapshot = try H.capture(container: store, after: nil, storeUUID: storeID!)
            #expect(snapshot.records.count == 32 && snapshot.deletions.isEmpty && snapshot.cursor != nil)
            #expect(Set(snapshot.records.map(\.kind)) == Set(StaffWorkspaceModelCatalog.all.map(\.kind)))
            original = snapshot
            // One deletion transaction includes owning relationships/cascades,
            // not just detached per-type mocks.
            for model in models.reversed() { context.delete(model) }; try context.save()
        }
        let reopened = try container(url), first = try #require(original)
        let deleted = try H.capture(container: reopened, after: first.cursor, storeUUID: storeID!)
        #expect(deleted.records.isEmpty && deleted.deletions == Set(first.records.map(H.key)))
        #expect(deleted.deletions.count == 32 && deleted.cursor != first.cursor)
        let resume = try H.capture(container: reopened, after: deleted.cursor, storeUUID: storeID!)
        #expect(resume.records.isEmpty && resume.deletions.isEmpty && resume.cursor == deleted.cursor)
        #expect(try CompanyWorkspaceStore.identity(at: url) == storeID)
    }

    @Test func emptyHistoryStillChecksTheActualStoreAndFullSchema() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Empty.store"), store = try container(url), id = try identity(url)
        let empty = try H.capture(container: store, after: nil, storeUUID: id)
        #expect(empty.records.isEmpty && empty.cursor == nil && empty.deletions.isEmpty)
        #expect(throws: StaffReplicaSourceSyncError.history) { try H.capture(container: store, after: nil, storeUUID: UUID().uuidString) }
        let memory = try ModelContainer(for: GunnAireModelSchema.schema, configurations: [.init(isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        #expect(throws: StaffReplicaSourceSyncError.history) { try H.capture(container: memory, after: nil, storeUUID: id) }
        let partial = Schema([Vendor.self]), partialURL = root.appendingPathComponent("Partial.store")
        let partialStore = try ModelContainer(for: partial, configurations: [.init(schema: partial, url: partialURL, cloudKitDatabase: .none)])
        #expect(throws: StaffReplicaSourceSyncError.history) {
            try H.capture(container: partialStore, after: nil, storeUUID: identity(partialURL))
        }
    }

    @Test func foreignMalformedExpiredAndReducedCoverageCursorsCannotAdvance() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Original.store"), store = try container(url), context = store.mainContext
        context.autosaveEnabled = false; context.insert(Vendor(name: "Original")); try context.save()
        let id = try identity(url), first = try H.capture(container: store, after: nil, storeUUID: id)
        let cursor = try #require(first.cursor)
        let otherURL = root.appendingPathComponent("Other.store"), other = try container(otherURL)
        other.mainContext.insert(Vendor(name: "Other")); try other.mainContext.save()
        let foreign = try #require(H.capture(container: other, after: nil, storeUUID: identity(otherURL)).cursor)
        let bad: [StaffWorkspaceHistoryCursor] = [
            foreign,
            .init(version: 2, storeUUID: cursor.storeUUID, coverage: cursor.coverage, transactionID: cursor.transactionID, token: cursor.token),
            .init(version: 1, storeUUID: cursor.storeUUID, coverage: Array(cursor.coverage.dropLast()), transactionID: cursor.transactionID, token: cursor.token),
            .init(version: 1, storeUUID: cursor.storeUUID, coverage: cursor.coverage, transactionID: cursor.transactionID, token: Data("invalid".utf8)),
            .init(version: 1, storeUUID: cursor.storeUUID, coverage: cursor.coverage, transactionID: cursor.transactionID, token: foreign.token),
            .init(version: 1, storeUUID: cursor.storeUUID, coverage: cursor.coverage, transactionID: cursor.transactionID + 100, token: cursor.token),
        ]
        for badCursor in bad {
            #expect(throws: StaffReplicaSourceSyncError.history) { try H.capture(container: store, after: badCursor, storeUUID: id) }
        }
        #expect(try H.capture(container: store, after: cursor, storeUUID: id).records == first.records)
        // Only this disposable test store has history removed to model expiry.
        try context.deleteHistory(HistoryDescriptor<DefaultHistoryTransaction>())
        #expect(throws: StaffReplicaSourceSyncError.history) { try H.capture(container: store, after: cursor, storeUUID: id) }
        #expect(try context.fetch(FetchDescriptor<Vendor>()).first?.name == "Original")
    }

    @Test func mixedReadsAndUnsavedEditsRejectWithoutDiscardingOriginalWork() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Original.store"), store = try container(url), writer = ModelContext(store)
        writer.autosaveEnabled = false
        let vendor = Vendor(name: "Original"); writer.insert(vendor); try writer.save()
        let id = try identity(url), first = try H.capture(container: store, after: nil, storeUUID: id)
        #expect(throws: StaffReplicaSourceError.unsaved) {
            try H.capture(container: store, after: first.cursor, storeUUID: id, read: { reader in
                let records = try H.readSavedRecords(reader)
                vendor.name = "Concurrent save"; try writer.save()
                return records
            })
        }
        let caughtUp = try H.capture(container: store, after: first.cursor, storeUUID: id)
        #expect(caughtUp.cursor != first.cursor && caughtUp.records.first?.fields["name"] == .text("Concurrent save"))
        let editing = try #require(store.mainContext.fetch(FetchDescriptor<Vendor>()).first)
        store.mainContext.autosaveEnabled = false; editing.name = "Unsaved edit"
        #expect(throws: StaffReplicaSourceError.unsaved) { try H.capture(container: store, after: caughtUp.cursor, storeUUID: id) }
        #expect(editing.name == "Unsaved edit" && store.mainContext.hasChanges)
    }

    @Test func firstEmptySnapshotCannotMissAConcurrentFirstSave() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Original.store"), store = try container(url), writer = ModelContext(store)
        writer.autosaveEnabled = false
        let id = try identity(url), vendor = Vendor(name: "First saved work")
        #expect(throws: StaffReplicaSourceError.unsaved) {
            try H.capture(container: store, after: nil, storeUUID: id, read: { reader in
                let empty = try H.readSavedRecords(reader)
                writer.insert(vendor); try writer.save()
                return empty
            })
        }
        let captured = try H.capture(container: store, after: nil, storeUUID: id)
        #expect(captured.records.count == 1 && captured.records.first?.id == vendor.id && captured.cursor != nil)
    }

    @Test func recreatedOriginalIDIsLiveAndAbsenceNeverFabricatesDeletion() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Original.store"), store = try container(url), context = store.mainContext
        context.autosaveEnabled = false
        let original = Vendor(name: "Original"), originalID = original.id
        context.insert(original); try context.save()
        let id = try identity(url), first = try H.capture(container: store, after: nil, storeUUID: id)
        context.delete(original); try context.save()
        let restored = Vendor(name: "Restored"); restored.id = originalID
        context.insert(restored); try context.save()
        let captured = try H.capture(container: store, after: first.cursor, storeUUID: id)
        #expect(captured.deletions.isEmpty && captured.records.count == 1 && captured.records.first?.id == originalID)
        #expect(captured.records.first?.fields["name"] == .text("Restored"))
    }

    @Test func all32ModelsMigrateFromPriorHistorySchemaWithoutChangingValuesOrRelationships() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("Fixture.store"), legacyURL = root.appendingPathComponent("Legacy.store")
        var expected: [StaffWorkspaceModelRecord] = []
        try autoreleasepool {
            let source = try container(sourceURL), writer = source.mainContext
            writer.autosaveEnabled = false
            for model in StaffWorkspaceFullModelTests().fixtures() { writer.insert(model) }; try writer.save()
            expected = try H.readSavedRecords(ModelContext(source))
        }
        var originalStore: String?
        try autoreleasepool {
            let generated = try #require(NSManagedObjectModel.makeManagedObjectModel(for: StaffWorkspaceModelCatalog.all.map(\.modelType)))
            let legacy = try #require(generated.copy() as? NSManagedObjectModel)
            let priorSix = Set(["Customer", "CustomerServiceLocation", "CustomerEquipment", "Technician", "ServiceCall", "Item"])
            for entity in legacy.entities {
                let attribute = try #require(entity.attributesByName["id"])
                #expect(attribute.preservesValueInHistoryOnDeletion)
                attribute.preservesValueInHistoryOnDeletion = priorSix.contains(entity.name!)
            }
            #expect(legacy.entities.filter { $0.attributesByName["id"]!.preservesValueInHistoryOnDeletion }.count == 6)
            let sourceCoordinator = NSPersistentStoreCoordinator(managedObjectModel: generated)
            let sourceStore = try sourceCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: sourceURL,
                options: [NSReadOnlyPersistentStoreOption: true])
            let legacyCoordinator = NSPersistentStoreCoordinator(managedObjectModel: legacy)
            let legacyStore = try legacyCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: legacyURL,
                options: [NSPersistentHistoryTrackingKey: true])
            let reader = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType); reader.persistentStoreCoordinator = sourceCoordinator
            let writer = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType); writer.persistentStoreCoordinator = legacyCoordinator
            var originals: [NSManagedObject] = [], copies: [NSManagedObjectID: NSManagedObject] = [:]
            for entity in generated.entities {
                let name = try #require(entity.name)
                for original in try reader.fetch(NSFetchRequest<NSManagedObject>(entityName: name)) {
                    originals.append(original)
                    let copy = NSEntityDescription.insertNewObject(forEntityName: name, into: writer)
                    for attribute in entity.attributesByName.keys { copy.setValue(original.value(forKey: attribute), forKey: attribute) }
                    copies[original.objectID] = copy
                }
            }
            // Test-only KVC copies the generated persisted representation,
            // including SwiftData's registered custom values and all inverses.
            // Production transfer remains the explicit typed 32-model catalog.
            for original in originals {
                let copy = try #require(copies[original.objectID])
                for (name, relation) in original.entity.relationshipsByName {
                    if relation.isToMany {
                        let linked = (original.value(forKey: name) as? NSSet)?.allObjects as? [NSManagedObject] ?? []
                        copy.setValue(NSSet(array: try linked.map { try #require(copies[$0.objectID]) }), forKey: name)
                    } else if let linked = original.value(forKey: name) as? NSManagedObject {
                        let linkedCopy = try #require(copies[linked.objectID])
                        copy.setValue(linkedCopy, forKey: name)
                    }
                }
            }
            try writer.save()
            #expect(originals.count == 32 && copies.count == 32)
            originalStore = try identity(legacyURL)
            let metadata = legacyCoordinator.metadata(for: legacyStore)
            #expect(legacy.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata))
            reader.reset(); writer.reset()
            try sourceCoordinator.remove(sourceStore); try legacyCoordinator.remove(legacyStore)
        }
        let reopened = try container(legacyURL), reader = ModelContext(reopened)
        #expect(try H.readSavedRecords(reader) == expected)
        #expect(try identity(legacyURL) == originalStore)
        let payment = try #require(reader.fetch(FetchDescriptor<Payment>()).first)
        let invoice = try #require(reader.fetch(FetchDescriptor<Invoice>()).first)
        #expect(payment.invoice === invoice && invoice.customer?.id == expected.first { $0.kind == "customer" }?.id)
        #expect(try reader.fetch(FetchDescriptor<ServiceDocumentAttachment>()).first?.localFilePath == "/DO-NOT-TRANSFER/owner-file.pdf")
        let captured = try H.capture(container: reopened, after: nil, storeUUID: identity(legacyURL))
        #expect(captured.records == expected && captured.deletions.isEmpty)
        let paymentID = payment.id
        reader.delete(payment); try reader.save()
        let after = try H.capture(container: reopened, after: captured.cursor, storeUUID: identity(legacyURL))
        #expect(after.deletions == ["payment:" + paymentID.uuidString.lowercased()])
    }

    @Test func legacyDeletionWithoutOriginalIDRequiresReviewInsteadOfAdvancing() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("LegacyDeletion.store")
        try autoreleasepool {
            let generated = try #require(NSManagedObjectModel.makeManagedObjectModel(for: StaffWorkspaceModelCatalog.all.map(\.modelType)))
            let legacy = try #require(generated.copy() as? NSManagedObjectModel)
            let attribute = try #require(legacy.entitiesByName["Invoice"]?.attributesByName["id"])
            attribute.preservesValueInHistoryOnDeletion = false
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: legacy)
            let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url,
                                                          options: [NSPersistentHistoryTrackingKey: true])
            let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType); context.persistentStoreCoordinator = coordinator
            let invoice = NSEntityDescription.insertNewObject(forEntityName: "Invoice", into: context)
            invoice.setValue(UUID(), forKey: "id"); invoice.setValue(189.0, forKey: "amount")
            try context.save(); context.delete(invoice); try context.save()
            context.reset(); try coordinator.remove(store)
        }
        let reopened = try container(url)
        #expect(try reopened.mainContext.fetch(FetchDescriptor<Invoice>()).isEmpty)
        #expect(throws: StaffReplicaSourceSyncError.history) {
            try H.capture(container: reopened, after: nil, storeUUID: identity(url))
        }
    }
}
