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
        let (call, _) = try job(customerSynced: false)
        #expect(call.customer == nil)
        #expect(call.customerDisplayName == "Customer syncing")
    }

    @Test func displayNameIsTheCustomerNameOnceSynced() throws {
        let (call, _) = try job(customerSynced: true)
        #expect(call.customerDisplayName == "Taylor Customer")
    }

    @Test func missingCustomerIsNotTheSystemCalendarPlaceholder() throws {
        let (call, _) = try job(customerSynced: false)
        #expect(CustomerDataMaintenance.isSystemCalendarCustomer(call.customer) == false)
    }

    @Test func placeholderCustomerIsStillRecognizedThroughTheOptionalOverload() throws {
        let (call, _) = try job(customerSynced: true)
        call.customer.name = CustomerDataMaintenance.unassignedCalendarCustomerName
        let optional: Customer? = call.customer
        #expect(CustomerDataMaintenance.isSystemCalendarCustomer(optional))
        #expect(CustomerDataMaintenance.isSystemCalendarCustomer(call.customer))
    }
}
