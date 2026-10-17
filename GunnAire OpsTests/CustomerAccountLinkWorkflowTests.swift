import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor
struct CustomerAccountLinkWorkflowTests {
    private func container() throws -> ModelContainer {
        let schema = GunnAireModelSchema.schema
        return try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
    }

    @Test func signupUUIDIsTheStableLocalCustomerID() throws {
        let accountID = UUID()
        #expect(try CustomerAccountLinkIdentity.customerID(for: accountID.uuidString) == accountID)
        #expect(try CustomerAccountLinkIdentity.customerID(for: accountID.uuidString) == accountID)
        #expect(throws: CustomerAccountLinkWorkflowError.self) {
            try CustomerAccountLinkIdentity.customerID(for: "not-an-account-id")
        }
    }

    @Test func onlyTheExactLinkedCustomerWithoutQBOIsConfirmed() {
        let customerID = UUID()
        #expect(CustomerAccountLinkIdentity.confirmsLink(
            status: "linked", linkedCustomerID: customerID.uuidString,
            linkedQuickBooksID: nil, customerID: customerID
        ))
        #expect(!CustomerAccountLinkIdentity.confirmsLink(
            status: "pending", linkedCustomerID: customerID.uuidString,
            linkedQuickBooksID: nil, customerID: customerID
        ))
        #expect(!CustomerAccountLinkIdentity.confirmsLink(
            status: "linked", linkedCustomerID: UUID().uuidString,
            linkedQuickBooksID: nil, customerID: customerID
        ))
        #expect(!CustomerAccountLinkIdentity.confirmsLink(
            status: "linked", linkedCustomerID: customerID.uuidString,
            linkedQuickBooksID: "other-provider-customer", customerID: customerID
        ))
    }

    @Test func uncertainResultKeepsTheStableCustomerUntilStatusCanBeProven() {
        let customerID = UUID()
        #expect(CustomerAccountLinkResolution.decide(
            status: nil, linkedCustomerID: nil, linkedQuickBooksID: nil,
            customerID: customerID, definitiveRejection: true
        ) == .keepForRetry)
        #expect(CustomerAccountLinkResolution.decide(
            status: "pending", linkedCustomerID: nil, linkedQuickBooksID: nil,
            customerID: customerID, definitiveRejection: false
        ) == .keepForRetry)
        #expect(CustomerAccountLinkResolution.decide(
            status: "pending", linkedCustomerID: nil, linkedQuickBooksID: nil,
            customerID: customerID, definitiveRejection: true
        ) == .discardUnlinked)
        #expect(CustomerAccountLinkResolution.decide(
            status: "linked", linkedCustomerID: customerID.uuidString, linkedQuickBooksID: nil,
            customerID: customerID, definitiveRejection: false
        ) == .confirmed)
        #expect(CustomerAccountLinkResolution.decide(
            status: "linked", linkedCustomerID: customerID.uuidString, linkedQuickBooksID: "42",
            customerID: customerID, definitiveRejection: false
        ) == .reviewExistingLink)
        #expect(CustomerAccountLinkResolution.decide(
            status: "linked", linkedCustomerID: UUID().uuidString, linkedQuickBooksID: nil,
            customerID: customerID, definitiveRejection: false
        ) == .discardUnlinked)
    }

    @Test func retryReusesOneCustomerAndDefinitiveRejectionCanDiscardIt() async throws {
        let storeContainer = try container()
        let store = CustomerAccountLocalCustomerStore(container: storeContainer)
        let id = UUID()
        try await store.prepare(id: id, name: "Fixture Customer", email: "fixture@example.com", phone: nil)
        try await store.prepare(id: id, name: "Fixture Customer", email: "fixture@example.com", phone: nil)
        let before = ModelContext(storeContainer)
        #expect(try before.fetch(FetchDescriptor<Customer>()).map(\.id) == [id])

        #expect(try await store.discardUnlinked(
            id: id, name: "Fixture Customer", email: "fixture@example.com", phone: nil
        ))
        let after = ModelContext(storeContainer)
        #expect(try after.fetch(FetchDescriptor<Customer>()).isEmpty)
    }

    @Test func twoOpenReviewViewsStillPrepareOnlyOneCustomer() async throws {
        let storeContainer = try container()
        let firstView = CustomerAccountLocalCustomerStore(container: storeContainer)
        let secondView = CustomerAccountLocalCustomerStore(container: storeContainer)
        let id = UUID()
        async let first: Void = firstView.prepare(
            id: id, name: "Fixture Customer", email: "fixture@example.com", phone: nil
        )
        async let second: Void = secondView.prepare(
            id: id, name: "Fixture Customer", email: "fixture@example.com", phone: nil
        )
        try await first
        try await second
        #expect(try ModelContext(storeContainer).fetch(FetchDescriptor<Customer>()).map(\.id) == [id])
    }

    @Test func changedCustomerIsPreservedDuringCompensation() async throws {
        let storeContainer = try container()
        let store = CustomerAccountLocalCustomerStore(container: storeContainer)
        let id = UUID()
        try await store.prepare(id: id, name: "Fixture Customer", email: "fixture@example.com", phone: nil)
        let editContext = ModelContext(storeContainer)
        let customer = try #require(editContext.fetch(FetchDescriptor<Customer>()).first)
        customer.name = "Reviewed Customer"
        try editContext.save()

        #expect(try await !store.discardUnlinked(
            id: id, name: "Fixture Customer", email: "fixture@example.com", phone: nil
        ))
        let verify = ModelContext(storeContainer)
        #expect(try verify.fetch(FetchDescriptor<Customer>()).first?.name == "Reviewed Customer")
    }

    @Test func sameIDWithDifferentEmailCannotBeReused() async throws {
        let store = CustomerAccountLocalCustomerStore(container: try container())
        let id = UUID()
        try await store.prepare(id: id, name: "Fixture Customer", email: "fixture@example.com", phone: nil)
        await #expect(throws: CustomerAccountLinkWorkflowError.self) {
            try await store.prepare(id: id, name: "Other Customer", email: "other@example.com", phone: nil)
        }
    }
}
