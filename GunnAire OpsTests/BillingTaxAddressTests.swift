import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor struct BillingTaxAddressTests {
    private let address = BillingPublicationAddress(Line1: "12 Main Street", City: "Raleigh",
        CountrySubDivisionCode: "NC", PostalCode: "27601")
    private func snapshot(taxable: Bool = true) -> String {
        CatalogLineItemSnapshot.encoded(from: [Item(name: "Capacitor", unitPrice: 190, isTaxable: taxable)])!
    }
    private func scope() -> BillingTaxAddressScope {
        .init(customerID: UUID(), serviceLocationID: UUID(), siteAddress: "Original service site")
    }

    @Test func completeUSAddressesNormalizeWithoutGuessingJurisdiction() throws {
        var value = address
        value.City = " Raleigh "; value.CountrySubDivisionCode = " nc "; value.PostalCode = "27601-1234"
        let context = try BillingTaxAddressContext(scope: scope(), service: value, origin: address)
        #expect(context.service.City == "Raleigh")
        #expect(context.service.CountrySubDivisionCode == "NC")
        #expect(context.service.PostalCode == "27601-1234")
        #expect(BillingPublicationAddress.empty.isValidUS == false)
    }

    @Test func partialControlCharacterWrongCountryAndInvalidZIPAreRejected() throws {
        for field in ["street", "city", "state", "zip", "country", "control", "length"] {
            var value = address
            switch field {
            case "street": value.Line1 = " "
            case "city": value.City = ""
            case "state": value.CountrySubDivisionCode = "XX"
            case "zip": value.PostalCode = "2760A"
            case "country": value.Country = "CA"
            case "control": value.Line1 = "Street\u{0000}detail"
            default: value.Line1 = String(repeating: "a", count: 501)
            }
            #expect(throws: BillingTaxAddressError.invalid) {
                _ = try BillingTaxAddressContext(scope: scope(), service: value, origin: address)
            }
            #expect(throws: BillingTaxAddressError.invalid) {
                _ = try BillingTaxAddressContext(scope: scope(), service: address, origin: value)
            }
        }
    }

    @Test func legacyArrayRoundTripPreservesSoldLinesAndScope() throws {
        let json = snapshot(), original = CatalogLineItemSnapshot.decoded(from: json)
        let context = try BillingTaxAddressContext(scope: scope(), service: address, origin: address)
        let saved = try BillingTaxAddressContext.attaching(context, to: json)
        #expect(CatalogLineItemSnapshot.decoded(from: saved) == original)
        #expect(BillingTaxAddressContext.read(saved) == context)
        #expect(BillingTaxPolicy.snapshotSubtotal(saved) == 190)
    }

    @Test func existingEnvelopeKeepsUnknownMetadataAndLines() throws {
        let lines = try JSONSerialization.jsonObject(with: Data(snapshot().utf8))
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "lines": lines, "futureEvidence": ["value": 27]])
        let context = try BillingTaxAddressContext(scope: scope(), service: address, origin: address)
        let saved = try BillingTaxAddressContext.attaching(context, to: String(decoding: data, as: UTF8.self))
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: Any])
        #expect((envelope["futureEvidence"] as? [String: Int])?["value"] == 27)
        #expect(CatalogLineItemSnapshot.decoded(from: saved).count == 1)
    }

    @Test func changedCustomerLocationOrSiteRequiresFreshReview() throws {
        let old = scope(), context = try BillingTaxAddressContext(scope: old, service: address, origin: address)
        for changed in [BillingTaxAddressScope(customerID: UUID(), serviceLocationID: old.serviceLocationID, siteAddress: old.siteAddress),
            .init(customerID: old.customerID, serviceLocationID: UUID(), siteAddress: old.siteAddress),
            .init(customerID: old.customerID, serviceLocationID: old.serviceLocationID, siteAddress: "Other site")] {
            #expect(throws: BillingTaxAddressError.changed) { try context.validate(for: changed) }
        }
    }

    @Test func taxableDraftNeedsReviewButNontaxableWorkStillPublishesWithoutAddresses() throws {
        let customer = Customer(name: "Tax fixture")
        let invoice = Invoice(customer: customer, catalogSnapshotJSON: snapshot(), amount: 190)
        #expect(throws: BillingTaxAddressError.required) { _ = try BillingTaxAddressContext.forPublication(.invoice(invoice)) }
        invoice.catalogSnapshotJSON = snapshot(taxable: false)
        #expect(try BillingTaxAddressContext.forPublication(.invoice(invoice)) == nil)
    }

    @Test func invalidAddressMetadataDoesNotEraseSoldLineDecoding() throws {
        let lines = try JSONSerialization.jsonObject(with: Data(snapshot().utf8))
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "lines": lines, "taxAddresses": "corrupt"])
        let json = String(decoding: data, as: UTF8.self)
        #expect(BillingTaxAddressContext.read(json) == nil)
        #expect(CatalogLineItemSnapshot.decoded(from: json).count == 1)
        let invoice = Invoice(customer: Customer(name: "Fixture"), catalogSnapshotJSON: json, amount: 190)
        #expect(throws: BillingTaxAddressError.required) { _ = try BillingTaxAddressContext.forPublication(.invoice(invoice)) }
    }

    @Test func savedSnapshotSurvivesFreshModelContextAndEstimateConversion() throws {
        let schema = GunnAireModelSchema.schema
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema,
            isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(container), customer = Customer(name: "Snapshot fixture")
        let estimate = Estimate(siteAddress: "Original service site", customer: customer, catalogSnapshotJSON: snapshot(), amount: 190)
        let addresses = try BillingTaxAddressContext(scope: .init(customerID: customer.id, serviceLocationID: nil,
            siteAddress: estimate.siteAddress), service: address, origin: address)
        estimate.catalogSnapshotJSON = try BillingTaxAddressContext.attaching(addresses, to: estimate.catalogSnapshotJSON!)
        context.insert(customer); context.insert(estimate); try context.save()
        let fresh = ModelContext(container)
        let read = try #require(fresh.fetch(FetchDescriptor<Estimate>()).first)
        let invoice = Invoice.draft(from: read, dueDate: Date(), createdAt: Date())
        #expect(try BillingTaxAddressContext.forPublication(.estimate(read)) == addresses)
        #expect(try BillingTaxAddressContext.forPublication(.invoice(invoice)) == addresses)
        #expect(invoice.catalogLineSnapshots == read.catalogLineSnapshots)
    }

    @Test func addressChangesInvalidateCustomerApprovalRevision() throws {
        let customer = Customer(name: "Revision fixture")
        let estimate = Estimate(customer: customer, catalogSnapshotJSON: snapshot(), amount: 190)
        let before = estimate.customerPortalRevision
        let addresses = try BillingTaxAddressContext(scope: .init(customerID: customer.id, serviceLocationID: nil,
            siteAddress: nil), service: address, origin: address)
        estimate.catalogSnapshotJSON = try BillingTaxAddressContext.attaching(addresses, to: estimate.catalogSnapshotJSON!)
        #expect(estimate.customerPortalRevision != before)
    }

    @Test func oldProviderAddressRemainsDecodableAndFullAddressEncodesAllFields() throws {
        let old = try JSONDecoder().decode(QuickBooksAddress.self, from: Data(#"{"Line1":"Old site"}"#.utf8))
        #expect(old.City == nil); #expect(old.Line1 == "Old site")
        let encoded = try JSONEncoder().encode(address.quickBooksAddress)
        let decoded = try JSONDecoder().decode(BillingPublicationAddress.self, from: encoded)
        #expect(decoded == address)
    }
}
