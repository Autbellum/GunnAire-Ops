import Foundation
import Testing
@testable import GunnAire_Ops

@MainActor struct QuickBooksBundleTransactionTests {
    private let company = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private let customer = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
    private let documentID = UUID(uuidString: "10000000-0000-4000-8000-000000000003")!
    private let attempt = UUID(uuidString: "10000000-0000-4000-8000-000000000004")!

    private func sale(_ id: String = "I1", quantity: Double = 2, price: Double = 189,
                      amount: Double = 378, tax: String = "NON", description: String = "Repair labor") -> QuickBooksLineItem {
        .init(Amount: amount, DetailType: "SalesItemLineDetail", Description: description,
              SalesItemLineDetail: .init(ItemRef: .init(value: id, name: nil), Qty: quantity, UnitPrice: price,
                                        TaxCodeRef: .init(value: tax, name: nil)))
    }

    private func bundle(quantity: Double = 2, components: [QuickBooksLineItem]? = nil) -> QuickBooksLineItem {
        .bundle(description: "Capacitor repair bundle", reference: .init(value: "G1", name: "Capacitor repair bundle"),
                quantity: quantity, components: components ?? [sale(),
                    sale("M1", quantity: 4, price: 12.375, amount: 49.5, tax: "TAX", description: "Replacement capacitor"),
                    sale("M1", quantity: 2, price: 12.375, amount: 24.75, tax: "TAX", description: "Additional capacitor")])
    }

    private func object(_ line: QuickBooksLineItem) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(line)) as? [String: Any])
    }
    private func decode(_ value: [String: Any]) throws -> QuickBooksLineItem {
        try JSONDecoder().decode(QuickBooksLineItem.self, from: JSONSerialization.data(withJSONObject: value))
    }
    private func request(lines: [QuickBooksLineItem]? = nil, origin: Bool = true, taxAfterDiscount: Bool? = nil) -> BillingPublicationRequest {
        let address = BillingPublicationAddress(Line1: "42 Fixture Street", City: "Raleigh", CountrySubDivisionCode: "NC", PostalCode: "27601")
        return .init(companyID: company, realmID: "bundle-realm", environment: Config.QuickBooks.environment,
                     documentType: .invoice, localDocumentID: documentID, localCustomerID: customer, operation: .create,
                     document: .init(CustomerRef: .init(value: "C1", name: nil), Line: lines ?? [bundle()], TxnDate: "2026-09-08",
                                     ShipAddr: address, ShipFromAddr: origin ? address : nil, ApplyTaxAfterDiscount: taxAfterDiscount),
                     connectionRevision: String(repeating: "a", count: 64))
    }
    private func response(lines: [QuickBooksLineItem]? = nil, total: Double = 459.68) throws -> Data {
        let value = request(lines: lines)
        var remote = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value.document)) as? [String: Any])
        remote.merge(["Id": "D1", "SyncToken": "1", "TotalAmt": total, "Balance": total, "TxnTaxDetail": ["TotalTax": 7.43],
                      "PrivateNote": "GunnAire Invoice ID: \(documentID.uuidString.uppercased())"]) { _, new in new }
        return try JSONSerialization.data(withJSONObject: ["publication": [
            "id": attempt.uuidString, "companyID": company.uuidString, "realmID": value.realmID, "environment": value.environment,
            "documentType": "Invoice", "localDocumentID": documentID.uuidString, "localCustomerID": customer.uuidString,
            "operation": "create", "state": "confirmed", "providerID": "D1", "updatedAt": "2026-09-08T12:00:00Z"], "document": remote])
    }

    @Test func groupWireUsesQuantityAndNestedLinesWithoutOrdinarySalesFallback() throws {
        let value = try object(bundle())
        #expect(value["Amount"] as? Double == 0)
        #expect(value["SalesItemLineDetail"] == nil)
        let group = try #require(value["GroupLineDetail"] as? [String: Any])
        #expect(group["Quantity"] as? Double == 2); #expect(group["Qty"] == nil)
        let restored = try decode(value)
        let components = try #require(restored.GroupLineDetail?.Line)
        #expect(components.map { $0.SalesItemLineDetail.ItemRef.value } == ["I1", "M1", "M1"])
        #expect(components.map { $0.SalesItemLineDetail.Qty } == [2, 4, 2])
        #expect(components.map { $0.SalesItemLineDetail.UnitPrice } == [189, 12.375, 12.375])
        #expect(QuickBooksBillingLineEvidence.matches(expected: [bundle()], reported: [restored]))
    }

    @Test func groupTotalUsesExtendedComponentsOnceAndRetainsMixedTax() throws {
        let total = try QuickBooksSalesLineContract.totals([bundle()])
        #expect(total.gross == Decimal(string: "452.25")); #expect(total.net == total.gross); #expect(total.taxable)
        #expect(QuickBooksSalesLineContract.displayedAmount(bundle()) == 452.25)
        #expect(try QuickBooksSalesLineContract.totals([bundle(quantity: 7)]).net == total.net)
    }

    @Test func reviewRetainsUnitPricePrecisionWithoutAddingNoiseToWholeCentPrices() {
        #expect(QuickBooksSalesLineContract.unitPriceLabel(12.375) == "$12.375")
        #expect(QuickBooksSalesLineContract.unitPriceLabel(12.37501) == "$12.37501")
        #expect(QuickBooksSalesLineContract.unitPriceLabel(94.5) == "$94.50")
    }

    @Test func memberChangesRetainTheGroupAndEachRoundedCharge() throws {
        let edited = bundle(components: [sale("M1", quantity: 1.25, price: 11.375, amount: 14.22, tax: "TAX")])
        let restored = try decode(object(edited))
        #expect(restored.GroupLineDetail?.GroupItemRef.value == "G1")
        #expect(try QuickBooksSalesLineContract.totals([restored]).net == Decimal(string: "14.22"))
        #expect(!QuickBooksBillingLineEvidence.matches(expected: [bundle()], reported: [restored]))
    }

    @Test func discountIsCalculatedFromBundleComponentsNotZeroHeader() throws {
        let discount = QuickBooksLineItem(Amount: 45.23, DetailType: "DiscountLineDetail", Description: "Reviewed discount",
            SalesItemLineDetail: .init(ItemRef: .init(value: "", name: nil)),
            DiscountLineDetail: .init(PercentBased: true, DiscountPercent: 10))
        #expect(try QuickBooksSalesLineContract.totals([bundle(), discount]).net == Decimal(string: "407.02"))
        var value = request(lines: [bundle(), discount])
        #expect(throws: BillingPublicationError.invalidProposal) { try value.validate() }
        value = request(lines: [bundle(), discount], taxAfterDiscount: true)
        try value.validate()
    }

    @Test func omittedGroupHeaderAmountIsValidButMissingLeafAmountAndNullHeaderAreNot() throws {
        var value = try object(bundle()); value.removeValue(forKey: "Amount")
        let omitted = try decode(value)
        #expect(!omitted.hasExplicitAmount); #expect(omitted.hasValidGroupHeaderAmount)
        #expect(QuickBooksBillingLineEvidence.matches(expected: [bundle()], reported: [omitted]))
        let invalidAmounts: [Any] = [NSNull(), true, "not-a-number", 1]
        for amount in invalidAmounts {
            value["Amount"] = amount
            let invalid = try decode(value)
            #expect(throws: BillingPublicationError.invalidResponse) { try QuickBooksSalesLineContract.totals([invalid]) }
        }
        var leaf = try object(sale()); leaf.removeValue(forKey: "Amount")
        #expect(throws: BillingPublicationError.invalidResponse) { try QuickBooksSalesLineContract.totals([bundle(components: [decode(leaf)])]) }
    }

    @Test func allHeadersAndMembersCountToward750LineLimit() throws {
        let components = Array(repeating: sale(), count: 749)
        _ = try QuickBooksSalesLineContract.totals([bundle(components: components)])
        #expect(throws: BillingPublicationError.invalidResponse) { try QuickBooksSalesLineContract.totals([bundle(components: components), sale()]) }
        #expect(throws: BillingPublicationError.invalidResponse) { try QuickBooksSalesLineContract.totals([bundle(components: [])]) }
    }

    @Test func nestedBundleAndConflictingDetailsFailDuringDecode() throws {
        var value = try object(bundle())
        value["SalesItemLineDetail"] = ["ItemRef": ["value": "I1"]]
        #expect(throws: (any Error).self) { try decode(value) }
        #expect(throws: (any Error).self) { try decode(object(bundle(components: [bundle()]))) }
    }

    @Test(arguments: [0.0, -1, 0.000001, 1_000_000, .infinity, .nan])
    func invalidGroupQuantityCannotBecomeADraft(_ quantity: Double) throws {
        #expect(throws: BillingPublicationError.invalidProposal) { try request(lines: [bundle(quantity: quantity)]).validate() }
    }

    @Test func groupCannotBeItsOwnMemberOrAnOrdinarySoldLineElsewhere() throws {
        for lines in [[bundle(components: [sale("G1")])], [bundle(), sale("G1")]] {
            #expect(throws: BillingPublicationError.invalidResponse) { try QuickBooksSalesLineContract.totals(lines) }
        }
    }

    @Test func duplicateProviderLineIDsAcrossGroupAndLeavesAreNotCollapsed() throws {
        var value = try object(bundle())
        value["Id"] = "same"
        var group = try #require(value["GroupLineDetail"] as? [String: Any])
        var lines = try #require(group["Line"] as? [[String: Any]])
        lines[1]["Id"] = "same"; group["Line"] = lines; value["GroupLineDetail"] = group
        let invalid = try decode(value)
        #expect(!QuickBooksBillingLineEvidence.matches(expected: [bundle()], reported: [invalid]))
    }

    @Test func changedProviderOrderQuantityIdentityPriceAndTaxCannotConfirmSoldBundle() throws {
        let original = try #require(bundle().GroupLineDetail?.Line)
        let changed: [QuickBooksLineItem] = [bundle(quantity: 3), bundle(components: Array(original.reversed())),
            bundle(components: Array(original.dropLast())), bundle(components: [sale(price: 190, amount: 380)]),
            bundle(components: [sale("OTHER")]), bundle(components: [sale(tax: "TAX")])]
        for line in changed { #expect(!QuickBooksBillingLineEvidence.matches(expected: [bundle()], reported: [line])) }
    }

    @Test func providerSubtotalMustEqualAllBundleComponents() throws {
        for amount in [0.0, 452.25, 904.5] {
            let subtotal = try decode(["Amount": amount, "DetailType": "SubTotalLineDetail"])
            #expect(QuickBooksBillingLineEvidence.matches(expected: [bundle()], reported: [bundle(), subtotal]) == (amount == 452.25))
        }
    }

    @Test func taxableLeafRequiresAddressesEvenWhenGroupHasNoTaxFlag() throws {
        try request().validate()
        #expect(throws: BillingPublicationError.invalidProposal) { try request(origin: false).validate() }
    }

    @Test func sharedClientPublishesAndValidatesRealBundleWithoutDirectQuickBooksWrite() async throws {
        let api = QuickBooksDataAPI(testTokens: .init(accessToken: "fixture", expiration: .distantFuture), realmID: "bundle-realm",
            environment: Config.QuickBooks.environment, catalogCompanyID: company, transport: { _ in
                Issue.record("Bundle publication reached direct QuickBooks transport")
                throw BillingPublicationError.unavailable
            })
        var calls = 0
        let client = BillingPublicationClient { path, method, body in
            calls += 1
            #expect(path == "/api/billing-publications"); #expect(method == "POST")
            let sent = try JSONDecoder().decode(BillingPublicationRequest.self, from: #require(body))
            #expect(sent.document.Line.first?.GroupLineDetail?.Line.count == 3)
            #expect(sent.document.Line.first?.Amount == 0)
            return try response()
        }
        let result = try await client.publish(request(), workflow: api.captureWorkspaceWorkflow())
        #expect(result.invoice?.TotalAmt == 459.68); #expect(calls == 1)
        #expect(result.invoice?.Line?.first?.GroupLineDetail?.Line.count == 3)
    }

    @Test func inconsistentBundleResponseTotalCannotBecomeConfirmation() throws {
        let result = try JSONDecoder().decode(BillingPublicationResponse.self, from: response(total: 7.43))
        #expect(throws: BillingPublicationError.invalidResponse) {
            try result.validate(request().scope, customerID: customer, providerCustomerID: "C1")
        }
    }

    @Test func encryptedOriginalProposalReopensExactGroupPricesMembersAndScope() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BundleJournal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let value = request()
        let scope = BillingNativeJournalScope(document: value.scope, actorEmail: "field@example.invalid")
        let original = BillingNativeJournal(scope: scope, pending: .init(request: value,
            draftRevision: String(repeating: "b", count: 64), submitted: true, publicationID: attempt))
        let key = Data(repeating: 42, count: 32)
        let writer = BillingNativeJournalStore.encrypted(directory: directory, key: { _ in key })
        try writer.write(original)
        let reader = BillingNativeJournalStore.encrypted(directory: directory, key: { _ in key })
        let reopened = try reader.read(scope)
        let restored = try #require(reopened.pending?.request)
        #expect(try restored.matches(value)); #expect(reopened.pending?.publicationID == attempt)
        #expect(restored.document.Line.first?.GroupLineDetail?.Line.map { $0.SalesItemLineDetail.Qty } == [2, 4, 2])
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let sealed = try Data(contentsOf: #require(files.first))
        #expect(sealed.range(of: Data("Capacitor repair bundle".utf8)) == nil)
    }
}
