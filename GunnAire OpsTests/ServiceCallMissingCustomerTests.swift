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

    @Test func warrantyMatchingNeverJoinsUnresolvedCustomers() throws {
        let (call, context) = try job(customerSynced: false)
        defer { withExtendedLifetime(context) {} }
        #expect(EquipmentWarrantyClaimPolicy.relatedServiceCallIDs(customerID: nil, serviceCalls: [call]).isEmpty)
        #expect(EquipmentWarrantyClaimPolicy.relatedServiceCallIDs(customerID: UUID(), serviceCalls: [call]).isEmpty)
        let customer = Customer(name: "Warranty customer")
        context.insert(customer)
        call.customer = customer
        #expect(EquipmentWarrantyClaimPolicy.relatedServiceCallIDs(customerID: customer.id, serviceCalls: [call]) == [call.id])
        #expect(EquipmentWarrantyClaimPolicy.relatedServiceCallIDs(customerID: UUID(), serviceCalls: [call]).isEmpty)
    }

    private func expense(for call: ServiceCall?) throws -> FieldExpenseClaim {
        try FieldExpenseClaimPolicy.makeClaim(serviceCall: call, claimantEmail: "worker@example.com",
            claimantName: "Fixture worker", claimType: .expense, category: .other,
            expenseDate: Date(), merchant: "Fixture supplier", businessPurpose: "Job supplies",
            amount: 12, mileageMiles: nil, mileageRatePerMile: nil,
            mileageOrigin: nil, mileageDestination: nil, reimbursable: true)
    }

    @Test func expenseWaitsForCustomerAndThenKeepsTheOriginalJob() throws {
        let (call, context) = try job(customerSynced: false)
        defer { withExtendedLifetime(context) {} }
        #expect(throws: FieldExpenseClaimError.jobCustomerSyncing) { try expense(for: call) }
        let customer = Customer(name: "Expense customer")
        context.insert(customer)
        call.customer = customer
        let claim = try expense(for: call)
        #expect(claim.serviceCallID == call.id)
        #expect(claim.customerID == customer.id)
        #expect(claim.customerName == customer.name)
    }

    @Test func generalBusinessExpenseDoesNotRequireAJobCustomer() throws {
        let claim = try expense(for: nil)
        #expect(claim.serviceCallID == nil)
        #expect(claim.customerID == nil)
        #expect(claim.customerName == nil)
    }
}
