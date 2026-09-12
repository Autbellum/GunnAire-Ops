import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor struct CatalogSnapshotIntegrityTests {
    typealias P = CatalogSnapshotPayload
    func json(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
    func rows(_ text: String) throws -> [[String: Any]] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
    }
    func snapshot() throws -> String {
        let item = Item(quickBooksID: "42", name: "Original labor", unitPrice: 125)
        return try #require(CatalogLineItemSnapshot.encoded(from: [item]))
    }

    @Test func publicationRejectsUnknownEnvelopeVersionWithoutReinterpretingSoldLines() throws {
        let json = try "{\"version\":999,\"lines\":" + snapshot() + "}"
        #expect(throws: (any Error).self) {
            try QuickBooksDocumentLinePublication.validateSnapshotTotals(snapshotJSON: json, expectedSubtotal: 125)
        }
    }

    @Test func completeStaffGraphRejectsUnclassifiedNestedFinancialFields() throws {
        let records = try StaffWorkspaceFullModelTests().encodedFixtures()
        let json = try "{\"version\":1,\"lines\":" + snapshot() + ",\"futurePriceRule\":\"do-not-ignore\"}"
        let changed = records.map { record in
            StaffWorkspaceModelRecord(version: record.version, kind: record.kind, id: record.id,
                fields: record.kind == "invoice" ? record.fields.merging(["catalogSnapshotJSON": .text(json)]) { _, next in next } : record.fields)
        }
        #expect(throws: (any Error).self) { _ = try StaffWorkspaceRelationshipGraph.validate(changed) }
    }

    @Test func supportedLegacyArraysKeepOriginalDefaultsAndExplicitOptionalNulls() throws {
        var values = try rows(snapshot())
        values[0].removeValue(forKey: "quantity"); values[0].removeValue(forKey: "pricebookUnitPrice")
        values[0].removeValue(forKey: "itemTypeRawValue"); values[0].removeValue(forKey: "quickBooksItemID")
        values[0]["sku"] = NSNull()
        let text = try json(values), result = try #require(try P.read(text))
        #expect(result.lines.count == 1 && result.lines[0].quantity == 1 && result.lines[0].pricebookUnitPrice == 125)
        #expect(result.lines[0].sku == nil && result.lines[0].quickBooksItemID == nil && result.discount == nil)
        #expect(result.lines == CatalogLineItemSnapshot.decoded(from: text))
        try P.validateBusinessEvidence(result)
        #expect(try P.read(nil) == nil)
        #expect(try P.read("[]")?.lines.isEmpty == true)
        for field in ["quantity", "pricebookUnitPrice"] {
            var invalid = values; invalid[0][field] = NSNull()
            #expect(throws: P.Invalid.evidence) { _ = try P.read(json(invalid)) }
        }
    }

    @Test func duplicateKeysEscapedKeysWrongTypesUnknownFieldsAndTrailingDataReject() throws {
        let valid = try snapshot()
        for text in ["", "null", "{}", valid + "{}", "[true]", "[\"saved line\"]",
                     "{\"version\":1,\"version\":2,\"lines\":" + valid + "}",
                     "{\"version\":1,\"vers\\u0069on\":1,\"lines\":" + valid + "}"] {
            #expect(throws: P.Invalid.evidence) { _ = try P.read(text) }
        }
        let base = try rows(valid)
        for (field, value) in [("unitPrice", true as Any), ("isTaxable", 1 as Any), ("futureDiscount", 15 as Any),
                               ("name", "bad\0name" as Any), ("catalogUpdatedAt", "tomorrow" as Any)] {
            var changed = base; changed[0][field] = value
            #expect(throws: P.Invalid.evidence) { _ = try P.read(json(changed)) }
        }
        #expect(throws: P.Invalid.evidence) { _ = try P.read(json(base + base)) }
    }

    @Test func everyNestedObjectRejectsUnclassifiedKeysWithoutDiscardingEvidence() throws {
        let items = try CatalogBundleFixture.makeCatalog()
        let root = try CatalogBundlePolicy.resolve(root: #require(items.last), catalog: items, scope: CatalogBundleFixture.scope)
        var values = try rows(#require(CatalogLineItemSnapshot.encoded(snapshots: [root])))
        let original = try #require(values[0]["bundle"] as? [String: Any])
        for location in 0..<4 {
            var bundle = original
            switch location {
            case 0: bundle["futureGrouping"] = true
            case 1:
                var scope = try #require(bundle["scope"] as? [String: Any]); scope["futureTenant"] = "another"; bundle["scope"] = scope
            default:
                var members = try #require(bundle["members"] as? [[String: Any]])
                if location == 2 { members[0]["futureTax"] = true }
                else {
                    var line = try #require(members[0]["line"] as? [String: Any]); line["futurePrice"] = 1; members[0]["line"] = line
                }
                bundle["members"] = members
            }
            values[0]["bundle"] = bundle
            #expect(throws: P.Invalid.evidence) { _ = try P.read(json(values)) }
        }
        var basic = try rows(snapshot())
        basic[0]["servicedEquipment"] = ["equipmentID": UUID().uuidString, "name": "Original unit", "futureOwner": "other"]
        #expect(throws: P.Invalid.evidence) { _ = try P.read(json(basic)) }
        basic[0].removeValue(forKey: "servicedEquipment")
        let component: [String: Any] = ["itemID": UUID().uuidString, "name": "Valve", "quantity": 1, "tracksInventory": false]
        for location in 0..<2 {
            var assembly: [String: Any] = ["assemblyItemID": UUID().uuidString, "name": "Package", "revision": 1, "presentation": "itemized", "components": [component]]
            if location == 0 { assembly["futureCost"] = 5 }
            else { var changed = component; changed["futureCost"] = 5; assembly["components"] = [changed] }
            basic[0]["assembly"] = assembly
            #expect(throws: P.Invalid.evidence) { _ = try P.read(json(basic)) }
        }
    }

    @Test func orderedRepeatedBundleProductsAndOriginalPricesSurviveCatalogChanges() throws {
        let items = try CatalogBundleFixture.makeCatalog()
        let original = try CatalogBundlePolicy.resolve(root: #require(items.last), catalog: items, scope: CatalogBundleFixture.scope)
        let text = try #require(CatalogLineItemSnapshot.encoded(snapshots: [original]))
        items[2].unitPrice = 999; items[2].purchaseCost = 888
        let result = try #require(try P.read(text)); try P.validateBusinessEvidence(result)
        #expect(result.lines == [original] && result.lines[0].bundle?.members.count == 2)
        #expect(result.lines[0].soldLeaves.map(\.unitPrice) == [94.5, 94.5])
        #expect(result.lines[0].bundle?.members.map(\.id) == original.bundle?.members.map(\.id))
        let bundle = try #require(original.bundle)
        let repeated = original.replacingBundle(bundle.replacingMembers([bundle.members[0], bundle.members[0]]))
        #expect(throws: P.Invalid.evidence) { _ = try P.read(CatalogLineItemSnapshot.encoded(snapshots: [repeated])) }
    }

    @Test func authorizedDiscountAndAdjustmentPreserveOriginalHistoryNotCurrentRole() throws {
        let date = Date(timeIntervalSinceReferenceDate: 810_000_000)
        let item = Item(name: "Original labor", unitPrice: 150, purchaseCost: 37.125)
        let adjustment = AuthorizedLinePriceAdjustment(pricebookUnitPrice: 150, unitPrice: 125, reason: "Original approval",
            authorizedByEmail: "former-office@example.invalid", authorizedAt: date)
        let original = CatalogLineItemSnapshot(item: item, quantity: 2, priceAdjustment: adjustment)
        let discount = AuthorizedDocumentDiscount(kind: .percentage, value: 10, grossSubtotalAtAuthorization: 250,
            reason: "Original discount", authorizedByEmail: "former-office@example.invalid", authorizedAt: date)
        let text = try #require(CatalogLineItemSnapshot.encoded(snapshots: [original], documentDiscount: discount))
        let result = try #require(try P.read(text)); try P.validateBusinessEvidence(result)
        #expect(result.lines == [original] && result.discount == discount && result.discount?.amount(for: 250) == 25)
        var value = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        var rawDiscount = try #require(value["documentDiscount"] as? [String: Any])
        rawDiscount["futureApproval"] = "ignored before"; value["documentDiscount"] = rawDiscount
        #expect(throws: P.Invalid.evidence) { _ = try P.read(json(value)) }
        rawDiscount.removeValue(forKey: "futureApproval")
        for (field, change) in [("grossSubtotalAtAuthorization", 300 as Any), ("value", 101 as Any), ("authorizedByEmail", "" as Any), ("reason", "" as Any)] {
            var changed = rawDiscount; changed[field] = change; value["documentDiscount"] = changed
            #expect(throws: P.Invalid.evidence) { try P.validateBusinessEvidence(#require(try P.read(json(value)))) }
        }
    }

    @Test func invalidAmountsAndPartialAuthorizationCannotBecomeValidStaffEvidence() throws {
        let base = try rows(snapshot())
        for (field, value) in [("unitPrice", -1 as Any), ("quantity", 0 as Any), ("quantity", 0.000001 as Any),
                               ("purchaseCost", -1 as Any), ("itemTypeRawValue", "Category" as Any),
                               ("quickBooksItemID", "../another" as Any), ("pricebookUnitPrice", 200 as Any),
                               ("priceAdjustmentReason", "Partial only" as Any)] {
            var changed = base; changed[0][field] = value
            #expect(throws: P.Invalid.evidence) { try P.validateBusinessEvidence(#require(try P.read(json(changed)))) }
        }
    }

    @Test func corruptSnapshotsStopInvoiceApprovalExportAndEditingWithoutChangingSavedText() throws {
        let customer = Customer(name: "Original customer"), item = Item(name: "Original item", unitPrice: 125)
        let text = try "{\"version\":999,\"lines\":" + snapshot() + "}"
        let invoice = Invoice(customer: customer, catalogSnapshotJSON: text, amount: 125)
        let estimate = Estimate(customer: customer, catalogSnapshotJSON: text, amount: 125)
        #expect(invoice.paymentCollectionBlockedMessage == P.Invalid.evidence.localizedDescription)
        #expect(estimate.customerApprovalBlockedMessage == P.Invalid.evidence.localizedDescription)
        #expect(throws: (any Error).self) { _ = try CustomerDocumentExporter.exportInvoice(invoice, serviceCall: nil, payments: []) }
        #expect(throws: (any Error).self) { _ = try CustomerDocumentExporter.exportEstimate(estimate, serviceCall: nil) }
        #expect(throws: CatalogBundleError.invalidMembers) { try CatalogBundlePolicy.validateRestoration(text, catalog: [item]) }
        #expect(throws: CatalogBundleError.invalidMembers) { _ = try ProjectProgressAllocation.documents(from: text, targetAmounts: [125]) }
        #expect(invoice.catalogSnapshotJSON == text && estimate.catalogSnapshotJSON == text && invoice.amount == 125)
        invoice.catalogSnapshotJSON = nil; estimate.catalogSnapshotJSON = nil
        #expect(invoice.paymentCollectionBlockedMessage == nil && estimate.customerApprovalBlockedMessage == nil)
    }

    @Test func unmappedCustomerAndCatalogCannotBeWrittenBeforeOriginalSnapshotValidation() throws {
        for isEstimate in [false, true] {
            let fixture = try QuickBooksBillingWorkflowTests.Fixture(mapped: false)
            let original = try #require(fixture.invoice.catalogSnapshotJSON)
            let invalid = "{\"version\":999,\"lines\":" + original + "}"
            fixture.invoice.catalogSnapshotJSON = invalid; fixture.estimate.catalogSnapshotJSON = invalid
            try fixture.context.save()
            #expect(throws: P.Invalid.evidence) { _ = try fixture.flow(estimate: isEstimate) }
            #expect(fixture.requests.isEmpty && fixture.customer.quickBooksID == nil && fixture.item.quickBooksID == nil)
            #expect(fixture.invoice.catalogSnapshotJSON == invalid && fixture.estimate.catalogSnapshotJSON == invalid)
        }
    }

    @Test func fullGraphKeepsSoldEquipmentHistoryButRejectsAnotherCustomersSystem() throws {
        let customer = Customer(name: "Original customer"), other = Customer(name: "Other customer")
        let item = Item(name: "Original labor", unitPrice: 125), equipment = CustomerEquipment(customer: customer, name: "Original system", serialNumber: "OLD")
        let line = CatalogLineItemSnapshot(item: item, servicedEquipment: .init(equipment: equipment))
        let text = try #require(CatalogLineItemSnapshot.encoded(snapshots: [line]))
        let invoice = Invoice(customer: customer, catalogSnapshotJSON: text, amount: 125)
        equipment.serialNumber = "CURRENT"; item.unitPrice = 999
        let C = StaffWorkspaceModelCodecs.self
        let source = try [C.customer.encode(customer), C.customer.encode(other), C.item.encode(item), C.equipment.encode(equipment), C.invoice.encode(invoice)]
        let graph = try StaffWorkspaceRelationshipGraph.validate(source)
        let copy = try #require(graph.decodeDetached().compactMap { $0 as? Invoice }.first)
        #expect(copy.catalogSnapshotJSON == text && copy.catalogLineSnapshots[0].servicedEquipment?.serialNumber == "OLD")
        equipment.customer = other
        let changed = try source.filter { $0.kind != "equipment" } + [C.equipment.encode(equipment)]
        #expect(throws: StaffWorkspaceLinkError.self) { _ = try StaffWorkspaceRelationshipGraph.validate(changed) }
        #expect(throws: StaffWorkspaceLinkError.self) { _ = try StaffWorkspaceRelationshipGraph.validate(source.filter { $0.kind != "item" }) }
        #expect(invoice.catalogSnapshotJSON == text && equipment.customer?.id == other.id)
    }

    @Test func boundedPayloadAllows750FullRowsButNeverTruncatesExtraRowsOrBytes() throws {
        let rows = (0..<750).map { index in CatalogLineItemSnapshot(item: Item(name: "Line \(index)", unitPrice: 1, purchaseCost: 0.5, itemDescription: "Original")) }
        let text = try #require(CatalogLineItemSnapshot.encoded(snapshots: rows))
        #expect(try P.read(text)?.lines.count == 750)
        let over = rows + [CatalogLineItemSnapshot(item: Item(name: "Extra", unitPrice: 1))]
        #expect(throws: P.Invalid.evidence) { _ = try P.read(CatalogLineItemSnapshot.encoded(snapshots: over)) }
        #expect(throws: P.Invalid.evidence) { _ = try P.read(String(repeating: " ", count: 1_048_577)) }
        #expect(throws: FieldFormJSON.Invalid.self) { _ = try FieldFormJSON.parse("[]", maximumNodes: 100_001) }
    }

    @Test func taxAddressMetadataIsExplicitlySupportedAndPreservedNotDiscarded() throws {
        let scope = BillingTaxAddressScope(customerID: UUID(), serviceLocationID: UUID(), siteAddress: "Original property")
        let address = BillingPublicationAddress(Line1: "10 Test Street", City: "Richmond", CountrySubDivisionCode: "VA", PostalCode: "23220")
        let original = try BillingTaxAddressContext(scope: scope, service: address, origin: address)
        let text = try BillingTaxAddressContext.attaching(original, to: snapshot())
        let result = try #require(try P.read(text)); try P.validateBusinessEvidence(result)
        #expect(result.taxAddresses == original && result.lines.count == 1)
        var object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let addresses = try #require(object["taxAddresses"] as? [String: Any])
        for location in 0..<4 {
            var changed = addresses
            if location == 0 { changed["futureRate"] = 0.2 }
            else if location == 1 { changed["version"] = 2 }
            else {
                let key = location == 2 ? "scope" : "service"
                var nested = try #require(changed[key] as? [String: Any]); nested["futureRegion"] = "unknown"; changed[key] = nested
            }
            object["taxAddresses"] = changed
            #expect(throws: P.Invalid.evidence) { _ = try P.read(json(object)) }
        }
        #expect(BillingTaxAddressContext.read(text) == original)
    }

    @Test func fullStaffGraphRequiresOriginalTaxScopeAndExactDocumentNetSubtotal() throws {
        let customer = Customer(name: "Original customer"), item = Item(name: "Original sale", unitPrice: 125)
        let address = BillingPublicationAddress(Line1: "10 Test Street", City: "Richmond", CountrySubDivisionCode: "VA", PostalCode: "23220")
        let scope = BillingTaxAddressScope(customerID: customer.id, serviceLocationID: nil, siteAddress: "Original property")
        let evidence = try BillingTaxAddressContext(scope: scope, service: address, origin: address)
        let snapshot = try BillingTaxAddressContext.attaching(evidence, to: #require(CatalogLineItemSnapshot.encoded(from: [item])))
        let invoice = Invoice(siteAddress: "Original property", customer: customer, catalogSnapshotJSON: snapshot, amount: 133.25, salesTaxAmount: 8.25)
        func records() throws -> [StaffWorkspaceModelRecord] {
            try [StaffWorkspaceModelCodecs.customer.encode(customer), StaffWorkspaceModelCodecs.item.encode(item), StaffWorkspaceModelCodecs.invoice.encode(invoice)]
        }
        #expect(try StaffWorkspaceRelationshipGraph.validate(records()).recordCount == 3)
        invoice.amount = 134.25
        #expect(throws: (any Error).self) { _ = try StaffWorkspaceRelationshipGraph.validate(records()) }
        invoice.amount = 133.25; invoice.siteAddress = "Changed property"
        #expect(throws: BillingTaxAddressError.changed) { _ = try StaffWorkspaceRelationshipGraph.validate(records()) }
        invoice.siteAddress = "Original property"
        let prior = try StaffWorkspaceRelationshipGraph.validate(records())
        invoice.salesTaxAmount = -1
        #expect(throws: P.Invalid.evidence) { _ = try StaffWorkspaceRelationshipGraph.validate(records()) }
        let copy = try #require(prior.decodeDetached().compactMap { $0 as? Invoice }.first)
        #expect(copy.amount == 133.25 && copy.salesTaxAmount == 8.25 && invoice.salesTaxAmount == -1)
        #expect(invoice.catalogSnapshotJSON == snapshot && copy.catalogSnapshotJSON == snapshot)
    }
}
