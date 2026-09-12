import Foundation
import SwiftData
import CoreData
import Testing
@testable import GunnAire_Ops

@MainActor struct StaffReplicaSourceHistoryTests {
    @Test func additiveHistoryAttributeReopensLegacyDiskWithoutReplacingBusinessIDs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GAOwnerMigration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Original.store"), id = UUID()
        // Copy the actual generated Core Data model. SwiftData's Schema
        // attributes can be shared across instances; mutating those would alter
        // the supposed current schema too and invalidate this migration test.
        let names = ["Customer", "CustomerServiceLocation", "CustomerEquipment", "Technician", "ServiceCall", "Item"]
        var originalStore: String?
        try autoreleasepool {
            let generated = try #require(NSManagedObjectModel.makeManagedObjectModel(for: [Customer.self, CustomerServiceLocation.self,
                CustomerEquipment.self, Technician.self, ServiceCall.self, Item.self]))
            let legacy = try #require(generated.copy() as? NSManagedObjectModel)
            for name in names {
                let attribute = try #require(legacy.entitiesByName[name]?.attributesByName["id"])
                #expect(attribute.preservesValueInHistoryOnDeletion)
                attribute.preservesValueInHistoryOnDeletion = false
            }
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: legacy)
            let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url,
                                                          options: [NSPersistentHistoryTrackingKey: true])
            let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            let customer = NSEntityDescription.insertNewObject(forEntityName: "Customer", into: context)
            customer.setValue(id, forKey: "id"); customer.setValue("Legacy customer", forKey: "name")
            customer.setValue(false, forKey: "allowsServiceText")
            let location = NSEntityDescription.insertNewObject(forEntityName: "CustomerServiceLocation", into: context)
            location.setValue(UUID(), forKey: "id"); location.setValue(customer, forKey: "customer")
            location.setValue("Original property", forKey: "name"); location.setValue("10 Main", forKey: "address")
            try context.save()
            originalStore = try CompanyWorkspaceStore.identity(at: url)
            context.reset(); try coordinator.remove(store)
        }
        let current = GunnAireModelSchema.schema
        let reopened = try ModelContainer(for: current, configurations: [.init(schema: current, url: url, cloudKitDatabase: .none)])
        let customer = try #require(reopened.mainContext.fetch(FetchDescriptor<Customer>()).first)
        #expect(customer.id == id && customer.name == "Legacy customer" && !customer.allowsServiceText)
        #expect(try reopened.mainContext.fetch(FetchDescriptor<CustomerServiceLocation>()).first?.customer?.id == id)
        #expect(try CompanyWorkspaceStore.identity(at: url) == originalStore)
        for name in names { #expect(current.entitiesByName[name]?.attributesByName["id"]?.options.contains(.preserveValueOnDeletion) == true) }
    }

    @Test func realDiskHistoryKeepsAllSixDeletedBusinessIdentitiesAndResumesAfterReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GAOwnerHistory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Original.store"), schema = GunnAireModelSchema.schema
        var token: Data?, storeID: String?, expected = Set<String>()
        do {
            let container = try ModelContainer(for: schema, configurations: [.init(schema: schema, url: url, cloudKitDatabase: .none)])
            let context = container.mainContext; context.autosaveEnabled = false
            let customer = Customer(name: "Original"), technician = Technician(name: "Original tech", contactInfo: "tech@example.invalid")
            let location = CustomerServiceLocation(customer: customer, name: "Property", address: "10 Main")
            let equipment = CustomerEquipment(customer: customer, serviceLocationID: location.id, name: "System")
            let job = ServiceCall(type: .service, scheduledDate: Date(), assignedTechnician: technician, customer: customer)
            let item = Item(name: "Service", unitPrice: 95)
            for model: any PersistentModel in [customer, location, equipment, technician, job, item] { context.insert(model) }
            try context.save()
            let identity = try CompanyWorkspaceStore.identity(at: url)
            storeID = try #require(identity)
            let first = try StaffReplicaSourceHistory.capture(container: container, after: nil, storeUUID: storeID!)
            #expect(first.source.records.count == 6 && first.deletions.isEmpty && first.token != nil)
            expected = Set(first.source.records.map(\.key)); token = first.token
            context.delete(job); context.delete(equipment); context.delete(location); context.delete(customer); context.delete(technician); context.delete(item)
            try context.save()
        }
        let reopened = try ModelContainer(for: schema, configurations: [.init(schema: schema, url: url, cloudKitDatabase: .none)])
        let captured = try StaffReplicaSourceHistory.capture(container: reopened, after: token, storeUUID: storeID!)
        #expect(captured.deletions == expected && captured.deletions.count == 6)
        #expect(captured.source.records.isEmpty && captured.token != token)
        let resumed = try StaffReplicaSourceHistory.capture(container: reopened, after: captured.token, storeUUID: storeID!)
        #expect(resumed.deletions.isEmpty && resumed.token == captured.token)
    }

    @Test func wrongStoreIdentityAndUnsavedChangesCannotAdvanceCheckpoint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GAOwnerFence-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Original.store"), schema = GunnAireModelSchema.schema
        let container = try ModelContainer(for: schema, configurations: [.init(schema: schema, url: url, cloudKitDatabase: .none)])
        container.mainContext.autosaveEnabled = false
        let customer = Customer(name: "Saved"); container.mainContext.insert(customer); try container.mainContext.save()
        #expect(throws: StaffReplicaSourceSyncError.self) {
            try StaffReplicaSourceHistory.capture(container: container, after: nil, storeUUID: "different-store")
        }
        customer.name = "Unsaved original edit"
        #expect(throws: StaffReplicaSourceError.self) {
            try StaffReplicaSourceHistory.capture(container: container, after: nil, storeUUID: CompanyWorkspaceStore.identity(at: url)!)
        }
        #expect(customer.name == "Unsaved original edit" && container.mainContext.hasChanges)
    }
}
