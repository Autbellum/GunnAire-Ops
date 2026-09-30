import Foundation
import Testing
@testable import GunnAire_Ops

/// Pins the customer search behind the schedule's New and Edit Service Call
/// sheets. Before this, the edit sheet showed no results while a calendar
/// job's placeholder was bound and capped results at eight rows.
@MainActor
struct CustomerSearchTests {
    private func fixtures() -> [Customer] {
        [
            Customer(name: "Álvarez Plumbing", phone: "512-555-0199", email: "office@alvarez.example"),
            Customer(name: "John Smith", phone: "(512) 555-0100", email: "jsmith@example.com", address: "12 Oak St, Austin TX 78701"),
            Customer(name: "Smithfield Dental", address: "900 Main St, Round Rock TX 78664"),
        ]
    }

    @Test func emptyQueryReturnsEveryCustomerWithoutACap() {
        let many = (0..<40).map { Customer(name: String(format: "Customer %02d", $0)) }
        #expect(CustomerSearch.matches(in: many, query: "").count == 40)
        #expect(CustomerSearch.matches(in: many, query: "   ").count == 40)
    }

    @Test func everyTermMustMatchInAnyOrder() {
        let customers = fixtures()
        #expect(CustomerSearch.matches(in: customers, query: "smith").map(\.name) == ["John Smith", "Smithfield Dental"])
        #expect(CustomerSearch.matches(in: customers, query: "smith john").map(\.name) == ["John Smith"])
        #expect(CustomerSearch.matches(in: customers, query: "SMITH 78664").map(\.name) == ["Smithfield Dental"])
        #expect(CustomerSearch.matches(in: customers, query: "smith zzz").isEmpty)
    }

    @Test func caseAndDiacriticsAreIgnored() {
        #expect(CustomerSearch.matches(in: fixtures(), query: "alvarez").map(\.name) == ["Álvarez Plumbing"])
    }

    @Test func phoneMatchesByDigitsRegardlessOfFormatting() {
        let customers = fixtures()
        #expect(CustomerSearch.matches(in: customers, query: "5125550100").map(\.name) == ["John Smith"])
        #expect(CustomerSearch.matches(in: customers, query: "(512) 555-0199").map(\.name) == ["Álvarez Plumbing"])
        #expect(CustomerSearch.matches(in: customers, query: "555").count == 2)
    }

    @Test func mixedLetterAndDigitTermIsNotTreatedAsAPhone() {
        #expect(!CustomerSearch.fieldsMatch(terms: ["ab5125"], name: "X", email: nil, phone: "512-5", address: nil))
    }

    @Test func emailAndAddressAreSearched() {
        let customers = fixtures()
        #expect(CustomerSearch.matches(in: customers, query: "jsmith@").map(\.name) == ["John Smith"])
        #expect(CustomerSearch.matches(in: customers, query: "main st").map(\.name) == ["Smithfield Dental"])
    }
}
