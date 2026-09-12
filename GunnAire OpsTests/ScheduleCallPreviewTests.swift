import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor struct ScheduleCallPreviewTests {
    private func fixture() throws -> (ModelContext, ServiceCall) {
        let schema = GunnAireModelSchema.schema
        let context = ModelContext(try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ]))
        context.autosaveEnabled = false
        let call = ServiceCall(eventTitle: "Original repair", type: .repair,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: Customer(name: "Original customer"))
        context.insert(call); try context.save()
        return (context, call)
    }

    @Test func previewAndConfirmationRemainReadableAfterOriginalDeletionAndSave() throws {
        let (context, call) = try fixture()
        let id = call.id, date = call.scheduledDate
        let preview = try #require(ScheduleCallPreview(call: call, context: context, isNextStop: true,
            title: { $0.eventTitle! }, subtitle: { $0.customer.name + " • " + $0.type.displayName }))
        let confirmation = try #require(ScheduleDeletionConfirmation(call: call, context: context))
        let retainedQuery = [call]
        try GoogleCalendarScheduleSync.removeLocalEntry(call, context: context)
        #expect(preview.id == id && preview.title == "Original repair")
        #expect(preview.subtitle == "Original customer • Repair" && preview.scheduledDate == date && preview.isNextStop)
        #expect(confirmation.title == "Original repair" && confirmation.identity == preview.identity)
        #expect(preview.identity.resolve(in: retainedQuery, context: context) == nil)
        #expect(ScheduleCallIdentity(call, context: context) == nil)
        #expect(try context.fetchCount(FetchDescriptor<ServiceCall>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Customer>()) == 1)
    }

    @Test func pendingDeletionCannotBeRenderedOrInvokedAndRollbackRestoresOriginal() throws {
        let (context, call) = try fixture()
        let identity = try #require(ScheduleCallIdentity(call, context: context))
        context.delete(call)
        #expect(identity.resolve(in: [call], context: context) == nil)
        var reads = 0
        let preview = ScheduleCallPreview(call: call, context: context, isNextStop: false,
            title: { _ in reads += 1; return "must not read" }, subtitle: { _ in reads += 1; return "must not read" })
        #expect(preview == nil && reads == 0)
        #expect(ScheduleDeletionConfirmation(call: call, context: context) == nil)
        context.rollback()
        #expect(identity.resolve(in: [call], context: context) === call)
    }

    @Test func actionsRequireCurrentVisibilityOriginalStoreAndUnambiguousIdentity() throws {
        let (context, call) = try fixture()
        let (other, unrelated) = try fixture()
        let identity = try #require(ScheduleCallIdentity(call, context: context))
        #expect(identity.resolve(in: [call], context: context) === call)
        #expect(identity.resolve(in: [], context: context) == nil)
        #expect(identity.resolve(in: [call], context: other) == nil)
        #expect(identity.resolve(in: [unrelated], context: context) == nil)
        let duplicate = ServiceCall(id: call.id, type: .service, scheduledDate: .now, customer: call.customer)
        context.insert(duplicate)
        #expect(identity.resolve(in: [call, duplicate], context: context) == nil)
        #expect(identity.resolve(in: [duplicate], context: context) == nil)
        #expect(ScheduleCallIdentity(ServiceCall(type: .service, scheduledDate: .now,
            customer: Customer(name: "Detached")), context: context) == nil)
    }

    @Test func isolatedFixtureStoreNamesAreExplicitStableAndCannotChooseAnArbitraryPath() {
        let first = UUID().uuidString, second = UUID().uuidString
        let prefix = ["-disableCloudKitForTesting", "-uiTestIsolatedStore"]
        #expect(GunnAireCloudKit.isolatedUITestStoreName(arguments: prefix + [first]) == "GunnAireUITest-" + first)
        #expect(GunnAireCloudKit.isolatedUITestStoreName(arguments: prefix + [first]) != GunnAireCloudKit.isolatedUITestStoreName(arguments: prefix + [second]))
        for args in [["-uiTestIsolatedStore", first], prefix, prefix + ["../default"], prefix + [first.lowercased()],
                     prefix + [first, "-uiTestIsolatedStore", second]] {
            #expect(GunnAireCloudKit.isolatedUITestStoreName(arguments: args) == nil)
        }
    }
}
