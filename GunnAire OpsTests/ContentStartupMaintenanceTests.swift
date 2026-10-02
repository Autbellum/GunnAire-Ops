import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

/// The startup maintenance moved from `ContentView.onAppear` on the main
/// context to a private context on a background queue. These pin that it still does the same
/// work: collapses duplicate users, reports whether a calendar-customer
/// cleanup is needed, and selects the same pending uploads the former root
/// queries did, newest first and capped.
@MainActor
struct ContentStartupMaintenanceTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = GunnAireModelSchema.schema
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
    }

    @Test func startupModelFetchRunsOutsideThePhysicalMainThread() async throws {
        let container = try makeContainer()
        let maintenance = ContentStartupColdMaintenance(modelContainer: container)
        #expect(await maintenance.modelWorkRunsOffMainThread())
    }

    @Test func duplicateUsersAreCollapsedOnTheBackgroundContextAndVisibleToTheMainOne() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        let older = AppUser(email: "tech@gunnaire.com", role: .fieldTechnician, isActive: true, createdAt: Date(timeIntervalSince1970: 1_789_757_000))
        let newer = AppUser(email: "Tech@GunnAire.com", role: .fieldTechnician, isActive: true, createdAt: Date(timeIntervalSince1970: 1_789_757_748))
        seed.insert(older)
        seed.insert(newer)
        try seed.save()

        let maintenance = ContentStartupColdMaintenance(modelContainer: container)
        let removed = await maintenance.collapseCloudKitUserDuplicates()
        #expect(removed == 1)

        let remaining = try ModelContext(container).fetch(FetchDescriptor<AppUser>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.email == "tech@gunnaire.com")
        #expect(remaining.first?.role == .fieldTechnician)
    }

    @Test func calendarCleanupIsReportedOnlyWhenAGenericCalendarCustomerExists() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        seed.insert(Customer(name: "Real Customer"))
        seed.insert(Customer(name: CustomerDataMaintenance.unassignedCalendarCustomerName))
        try seed.save()

        let maintenance = ContentStartupColdMaintenance(modelContainer: container)
        #expect(await maintenance.hasCalendarCreatedCustomersToClean() == false)

        seed.insert(Customer(name: "Service Call"))
        try seed.save()
        #expect(await maintenance.hasCalendarCreatedCustomersToClean() == true)
    }

    @Test func calendarCleanupDeletesRelatedRecordsOnTheBackgroundContext() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        let real = Customer(name: "Real Customer")
        let generic = Customer(name: "Service Call")
        seed.insert(real)
        seed.insert(generic)
        seed.insert(CustomerServiceLocation(customer: generic, name: "Imported", address: "Fixture", isPrimary: true))
        try seed.save()

        let maintenance = ContentStartupColdMaintenance(modelContainer: container)
        let summary = try await maintenance.cleanupCalendarNamedCustomers {
            let now = Date()
            return CustomerCleanupCommitPermit(epoch: .init(), issuedAt: now, expiresAt: now.addingTimeInterval(60))
        }
        #expect(summary.customers == 1)
        #expect(summary.serviceLocations == 1)

        let verify = ModelContext(container)
        let customers = try verify.fetch(FetchDescriptor<Customer>())
        let locations = try verify.fetch(FetchDescriptor<CustomerServiceLocation>())
        #expect(customers.map(\.name) == ["Real Customer"])
        #expect(locations.isEmpty)
    }

    @Test func pendingDocumentUploadsAreTheNewestTenThatStillNeedStorage() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        let customer = Customer(name: "Upload fixture")
        seed.insert(customer)
        let base = Date(timeIntervalSince1970: 1_789_757_748)
        for index in 0..<14 {
            let attachment = ServiceDocumentAttachment(
                customer: customer,
                serviceCallID: nil,
                kind: .beforePhoto,
                displayName: "photo-\(index).jpg",
                localFilePath: "photo-\(index).jpg",
                contentType: "image/jpeg",
                fileSizeBytes: 1_024,
                backendDocumentID: index == 3 ? "already-stored" : nil,
                sharedCompanySyncStatus: index == 3 ? "stored" : "needs_attention",
                createdAt: base.addingTimeInterval(Double(index))
            )
            seed.insert(attachment)
        }
        try seed.save()

        let maintenance = ContentStartupUploadMaintenance(modelContainer: container)
        let pending = await maintenance.pendingSharedCompanyDocumentUploads().map(\.displayName)
        #expect(pending.count == ContentStartupUploadMaintenance.uploadRetryBatchSize)
        #expect(pending.first == "photo-13.jpg")
        #expect(!pending.contains("photo-3.jpg"))
        #expect(pending.last == "photo-4.jpg")
    }

    @Test func pendingCommunicationSyncsAreTheNewestTenWithoutABackendID() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        let customer = Customer(name: "Sync fixture")
        seed.insert(customer)
        let base = Date(timeIntervalSince1970: 1_789_757_748)
        for index in 0..<12 {
            let communication = CustomerCommunication(
                customer: customer,
                channel: "email",
                direction: "outbound",
                recipient: "customer@example.com",
                subject: "Message \(index)",
                deliveryStatus: index == 5 ? "draft" : "sent"
            )
            communication.createdAt = base.addingTimeInterval(Double(index))
            if index == 7 { communication.backendCommunicationID = "synced" }
            seed.insert(communication)
        }
        try seed.save()

        let maintenance = ContentStartupUploadMaintenance(modelContainer: container)
        let pending = await maintenance.pendingCustomerCommunicationUploads().map(\.subject)
        #expect(pending.count == ContentStartupUploadMaintenance.uploadRetryBatchSize)
        #expect(pending.first == "Message 11")
        #expect(!pending.contains("Message 7"))
        #expect(!pending.contains("Message 5"))
    }

    @Test func documentRetryResultsPersistThroughPrivateContext() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        let customer = Customer(name: "Upload fixture")
        seed.insert(customer)
        seed.insert(ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .beforePhoto,
            displayName: "photo.jpg",
            localFilePath: "photo.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 100,
            sharedCompanySyncStatus: "needs_attention"
        ))
        try seed.save()

        let maintenance = ContentStartupUploadMaintenance(modelContainer: container)
        let candidate = try #require(await maintenance.pendingSharedCompanyDocumentUploads().first)
        await maintenance.completeDocument(candidate, storedID: nil, failure: "Retry failed")
        let failed = try #require(ModelContext(container).fetch(FetchDescriptor<ServiceDocumentAttachment>()).first)
        #expect(failed.sharedCompanySyncStatus == "needs_attention")
        #expect(failed.sharedCompanySyncDetail?.contains("Retry failed") == true)

        await maintenance.completeDocument(candidate, storedID: "stored-id", failure: nil)
        let stored = try #require(ModelContext(container).fetch(FetchDescriptor<ServiceDocumentAttachment>()).first)
        #expect(stored.backendDocumentID == "stored-id")
        #expect(stored.sharedCompanySyncStatus == "stored")
    }

    @Test func communicationRetryResultsPersistThroughPrivateContext() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        let customer = Customer(name: "Sync fixture")
        seed.insert(customer)
        seed.insert(CustomerCommunication(
            customer: customer,
            channel: "email",
            direction: "outbound",
            recipient: "customer@example.com",
            subject: "Delivered",
            deliveryStatus: "sent"
        ))
        try seed.save()

        let maintenance = ContentStartupUploadMaintenance(modelContainer: container)
        let candidate = try #require(await maintenance.pendingCustomerCommunicationUploads().first)
        await maintenance.completeCommunication(candidate, syncedID: nil, failure: "Retry failed")
        let failed = try #require(ModelContext(container).fetch(FetchDescriptor<CustomerCommunication>()).first)
        #expect(failed.backendCommunicationID == nil)
        #expect(failed.backendSyncError?.contains("Retry failed") == true)

        await maintenance.completeCommunication(candidate, syncedID: "sync-id", failure: nil)
        let synced = try #require(ModelContext(container).fetch(FetchDescriptor<CustomerCommunication>()).first)
        #expect(synced.backendCommunicationID == "sync-id")
        #expect(synced.backendSyncError == nil)
    }
}
