import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

/// CloudKit can deliver a job before its customer, leaving the implicitly
/// unwrapped `ServiceCall.customer` nil. Schedule renders every job through
/// these helpers, so they must answer without dereferencing that relationship.
@MainActor
struct ServiceCallMissingCustomerTests {
    private func job(customerSynced: Bool) throws -> (ServiceCall, ModelContext) {
        let schema = GunnAireModelSchema.schema
        let context = ModelContext(try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ]))
        let customer = Customer(name: "Taylor Customer", address: "42 Fixture Street")
        let call = ServiceCall(type: .install, scheduledDate: Date(timeIntervalSinceReferenceDate: 810_123_456),
                               customer: customer)
        context.insert(customer); context.insert(call)
        if !customerSynced { call.customer = nil }
        try context.save()
        return (call, context)
    }

    @Test func displayNameReportsSyncingInsteadOfTrapping() throws {
        let (call, context) = try job(customerSynced: false)
        defer { withExtendedLifetime(context) {} }
        #expect(call.customer == nil)
        #expect(call.customerDisplayName == "Customer syncing")
    }

    @Test func displayNameIsTheCustomerNameOnceSynced() throws {
        let (call, context) = try job(customerSynced: true)
        defer { withExtendedLifetime(context) {} }
        #expect(call.customerDisplayName == "Taylor Customer")
    }

    @Test func missingCustomerIsNotTheSystemCalendarPlaceholder() throws {
        let (call, context) = try job(customerSynced: false)
        defer { withExtendedLifetime(context) {} }
        #expect(CustomerDataMaintenance.isSystemCalendarCustomer(call.customer) == false)
    }

    @Test func placeholderCustomerIsStillRecognizedThroughTheOptionalOverload() throws {
        let (call, context) = try job(customerSynced: true)
        defer { withExtendedLifetime(context) {} }
        call.customer?.name = CustomerDataMaintenance.unassignedCalendarCustomerName
        let optional: Customer? = call.customer
        #expect(CustomerDataMaintenance.isSystemCalendarCustomer(optional))
        #expect(CustomerDataMaintenance.isSystemCalendarCustomer(call.customer))
    }

    @Test func displayNameRecoversWhenTheCustomerArrives() throws {
        let (call, context) = try job(customerSynced: false)
        defer { withExtendedLifetime(context) {} }
        let customer = Customer(name: "Arrived customer")
        context.insert(customer)
        call.customer = customer
        try context.save()
        #expect(call.customerDisplayName == "Arrived customer")
    }

    @Test func calendarPayloadUsesTheJobTypeWhileCustomerIsMissing() throws {
        let (call, context) = try job(customerSynced: false)
        defer { withExtendedLifetime(context) {} }
        call.eventTitle = nil
        call.notes = nil
        call.siteAddress = nil
        let event = GoogleCalendarScheduleSync.makeCalendarCreateEvent(for: call)
        #expect(event.summary == call.type.displayName)
        #expect(event.location == nil)

        call.siteAddress = "42 Fixture Street"
        let addressedEvent = GoogleCalendarScheduleSync.makeCalendarCreateEvent(for: call)
        #expect(addressedEvent.location == "42 Fixture Street")
    }

}
