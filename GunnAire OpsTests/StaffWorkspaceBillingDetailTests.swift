import XCTest
import SwiftData
@testable import GunnAire_Ops

@MainActor final class StaffWorkspaceBillingDetailTests: XCTestCase {
    typealias Detail = StaffWorkspaceBillingDetail
    typealias Record = StaffWorkspaceOperationalImportRecord
    typealias Projection = StaffWorkspaceBillingProjection
    let fixture = StaffWorkspaceBillingProjectionTests()

    func imports(_ document: Projection.Document, context: [Record] = []) -> [Record] {
        [.init(kind: document.kind, id: document.id.uuidString.lowercased(), revision: 1, unavailableLinks: [], body: .billing(document))] + context
    }
    func render(_ document: Projection.Document, context: [Record] = []) throws -> Detail.Document {
        try Detail.make(route: .init(kind: document.kind, id: document.id.uuidString.lowercased()), records: imports(document, context: context))
    }
    func changed(_ document: Projection.Document, fields: [String: StaffWorkspaceValue]) -> Projection.Document {
        .init(kind: document.kind, id: document.id, fields: document.fields.merging(fields) { _, new in new },
              unavailableFields: document.unavailableFields, catalog: document.catalog)
    }
    func related(_ kind: String, id: UUID = UUID(), fields: [String: StaffWorkspaceValue], unavailable: [String] = []) -> Record {
        .init(kind: kind, id: id.uuidString.lowercased(), revision: 1, unavailableLinks: unavailable,
              body: .operational(.init(fields: fields, unavailableFields: [:], structuredFields: [:])))
    }
    func sale(role: AppUserRole = .fieldTechnician, kind: String = "invoice") throws -> Projection.Document {
        let base = try fixture.base()
        return try XCTUnwrap(fixture.prepare(fixture.sale(base, lines: [.init(item: fixture.item(base), quantity: 2)], kind: kind), role: role)
            .documents.first { $0.kind == kind })
    }

    func testSavedSalePricesDiscountTaxAndSystemSurviveChangedCatalog() throws {
        let base = try fixture.base(), item = try fixture.item(base), equipmentID = try fixture.row("equipment", base).id
        let adjustment = AuthorizedLinePriceAdjustment(pricebookUnitPrice: 25, unitPrice: 20, reason: "Service adjustment",
            authorizedByEmail: "office@example.invalid", authorizedAt: fixture.fixture.now)
        let equipment = CatalogLineEquipmentSnapshot(equipmentID: equipmentID, name: "Original system", serialNumber: "ORIGINAL-123")
        let discount = AuthorizedDocumentDiscount(kind: .percentage, value: 10, grossSubtotalAtAuthorization: 50,
            reason: "Service agreement", authorizedByEmail: "office@example.invalid", authorizedAt: fixture.fixture.now)
        var source = try fixture.sale(base, lines: [.init(item: item, quantity: 2.5, priceAdjustment: adjustment, servicedEquipment: equipment)], discount: discount, tax: 3.15)
        source = fixture.replace(source, "item", ["name": .text("New pricebook name"), "unitPrice": .number(999)])
        let document = try XCTUnwrap(fixture.prepare(source).documents.first)
        let output = try render(document, context: [related("item", id: item.id, fields: ["name": .text("New pricebook name")]),
            related("equipment", id: equipmentID, fields: ["name": .text("Updated system")])])
        XCTAssertEqual(output.lines[0].name, "Sold valve")
        XCTAssertEqual(output.lines[0].quantity, 2.5)
        XCTAssertEqual(output.lines[0].unitPrice, 20)
        XCTAssertEqual(output.lines[0].amount, 50)
        XCTAssertEqual(output.lines[0].equipment, "Original system · ORIGINAL-123")
        XCTAssertEqual(output.lines[0].catalogLink?.title, "New pricebook name")
        XCTAssertEqual(output.lines[0].equipmentLink?.route.id, equipmentID.uuidString.lowercased())
        XCTAssertEqual(output.totals.first { $0.id == "total" }?.value, Decimal(string: "48.15")!.formatted(.currency(code: "USD")))
        XCTAssertEqual(output.totals.map(\.id), ["gross", "discount", "tax", "total"])
    }

    func testBundleMembersKeepOriginalOrderAndAlreadyExtendedQuantities() throws {
        var base = try fixture.base()
        let root = Item(id: try fixture.row("item", base).id, quickBooksID: "BUNDLE", name: "Service package", itemType: .group, unitPrice: 0)
        let child = Item(quickBooksID: "MEMBER", name: "Valve", unitPrice: 25, purchaseCost: 9.375)
        base.append(try StaffWorkspaceModelCodecs.item.encode(child))
        let bundle = CatalogBundleSnapshot(scope: .init(companyID: fixture.fixture.companyID, realmID: "PRIVATE-REALM", environment: "sandbox"),
            printGroupedItems: false, members: [.init(id: UUID(), line: .init(item: child, quantity: 6), tracksInventory: true),
                .init(id: UUID(), line: .init(item: child, quantity: 3), tracksInventory: true)])
        let document = try XCTUnwrap(fixture.prepare(fixture.sale(base, lines: [.init(item: root, quantity: 3, bundle: bundle)]), role: .accounting).documents.first)
        let output = try render(document)
        XCTAssertEqual(output.lines[0].amount, 225)
        XCTAssertEqual(output.lines[0].members.map(\.quantity), [6, 3])
        XCTAssertEqual(output.lines[0].members.map(\.amount), [150, 75])
        XCTAssertEqual(Set(output.lines[0].members.map(\.id)).count, 2)
        XCTAssertFalse(String(reflecting: output).contains("PRIVATE-REALM"))
        XCTAssertFalse(String(reflecting: output).contains("9.375"))
    }

    func testFinancialRolesStillGetCleanDocumentWithoutRawIDsCostsOrSignatureBytes() throws {
        let document = changed(try sale(role: .accounting), fields: ["quickBooksID": .text("PRIVATE-QBO-ID"),
            "customerSignatureImageBase64": .text("PRIVATE-SIGNATURE-BYTES"), "notes": .text("Clean job note")])
        let output = try render(document), text = String(reflecting: output)
        XCTAssertFalse(text.contains("PRIVATE-QBO-ID")); XCTAssertFalse(text.contains("PRIVATE-SIGNATURE-BYTES"))
        XCTAssertFalse(text.contains("19.375")); XCTAssertFalse(text.contains("QB-HISTORICAL-ITEM"))
        XCTAssertEqual(output.notes.first { $0.id == "notes" }?.value, "Clean job note")
    }

    func testAssemblyShowsOriginalPhysicalPartsWithoutFinancialCost() throws {
        var base = try fixture.base()
        let root = try fixture.item(base), part = Item(name: "Original capacitor", unitPrice: 7, purchaseCost: 3.125)
        base.append(try StaffWorkspaceModelCodecs.item.encode(part))
        let assembly = CatalogLineAssemblySnapshot(assemblyItemID: root.id, name: "Repair package", revision: 3,
            presentation: .flatRate, components: [.init(itemID: part.id, name: part.name, sku: "P-1", quantity: 2, purchaseCost: part.purchaseCost, tracksInventory: true)])
        let document = try XCTUnwrap(fixture.prepare(fixture.sale(base, lines: [.init(item: root, quantity: 1, assembly: assembly)]), role: .accounting).documents.first)
        let output = try render(document, context: [related("item", id: part.id, fields: ["name": .text("Current capacitor")])])
        XCTAssertEqual(output.lines[0].parts.first?.name, "Original capacitor")
        XCTAssertEqual(output.lines[0].parts.first?.quantity, 2)
        XCTAssertEqual(output.lines[0].parts.first?.link?.title, "Current capacitor")
        XCTAssertFalse(String(reflecting: output).contains("3.125"))
    }

    func testQueueIdentifiesCustomerWorkDateAmountAndSearchWithoutRawIdentifiers() throws {
        let document = try sale(), customerID = UUID()
        let source = changed(document, fields: ["customer": .identifier(customerID), "workTypeRaw": .text("repair")])
        let summaries = StaffWorkspaceBillingQueue.summaries(imports(source, context: [related("customer", id: customerID, fields: ["name": .text("Fixture customer")])]))
        let summary = try XCTUnwrap(summaries[.init(kind: "invoice", id: document.id.uuidString.lowercased())])
        XCTAssertEqual(summary.title, "Repair Invoice")
        XCTAssertEqual(summary.customer, "Fixture customer")
        XCTAssertEqual(summary.amount, 50.formatted(.currency(code: "USD")))
        XCTAssertNotNil(summary.created)
        XCTAssertTrue(summary.searchText.localizedStandardContains("fixture"))
        XCTAssertFalse(summary.searchText.contains(document.id.uuidString.lowercased()))
        XCTAssertFalse(summary.searchText.contains(customerID.uuidString.lowercased()))
    }

    func testQueueAmbiguousOrMissingCustomerCannotPickArbitraryIdentity() throws {
        let document = try sale(), customerID = UUID()
        let source = changed(document, fields: ["customer": .identifier(customerID)])
        let one = related("customer", id: customerID, fields: ["name": .text("One")])
        let two = related("customer", id: customerID, fields: ["name": .text("Two")])
        for context in [[], [one, two]] {
            XCTAssertEqual(StaffWorkspaceBillingQueue.summaries(imports(source, context: context)).values.first?.customer, "Customer unavailable")
        }
        XCTAssertTrue(StaffWorkspaceBillingQueue.summaries(imports(source) + imports(source)).isEmpty)
    }

    // Ollama-proposed boundaries, corrected to use one original document ID
    // and a real matching visible customer. The raw advisory was not executed.
    func testQueueHiddenAmountDoesNotDiscloseSuppliedValue() throws {
        let document = Projection.Document(kind: "invoice", id: UUID(), fields: ["amount": .number(100)],
            unavailableFields: ["amount": .roleRestricted], catalog: .notRecorded)
        let result = StaffWorkspaceBillingQueue.summaries(imports(document))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.values.first?.amount, "Amount unavailable")
    }
    func testQueueNegativeAmountIsNotPresentedAsCurrency() throws {
        let document = changed(try sale(), fields: ["amount": .number(-50)])
        let result = StaffWorkspaceBillingQueue.summaries(imports(document))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.values.first?.amount, "Amount unavailable")
    }
    func testQueueUnavailableLinkHidesEvenMatchingVisibleCustomerName() throws {
        let customerID = UUID(), document = changed(try sale(), fields: ["customer": .identifier(customerID)])
        let record = Record(kind: "invoice", id: document.id.uuidString.lowercased(), revision: 1,
            unavailableLinks: ["customer"], body: .billing(document))
        let result = StaffWorkspaceBillingQueue.summaries([record,
            related("customer", id: customerID, fields: ["name": .text("Do not disclose this link")])])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.values.first?.customer, "Customer unavailable")
        XCTAssertFalse(result.values.first?.searchText.contains("Do not disclose") ?? true)
    }

    func testContextAndReverseLinksUseExactVisibleDocumentNotSameCustomerOrJob() throws {
        let document = try sale(), customerID = UUID(), jobID = UUID(), otherID = UUID()
        let scoped = changed(document, fields: ["customer": .identifier(customerID), "serviceCallID": .identifier(jobID)])
        let ownFile = related("attachment", fields: ["invoiceID": .identifier(document.id), "fileName": .text("Service report.pdf")])
        let otherFile = related("attachment", fields: ["invoiceID": .identifier(otherID), "customer": .identifier(customerID), "serviceCallID": .identifier(jobID)])
        let hiddenFile = related("attachment", fields: ["invoiceID": .identifier(document.id)], unavailable: ["invoiceID"])
        let message = related("communication", fields: ["invoiceID": .identifier(document.id), "subject": .text("Invoice follow-up")])
        let payment = related("payment", fields: ["invoice": .identifier(document.id), "amount": .number(10), "status": .text("completed")])
        let output = try render(scoped, context: [ownFile, otherFile, hiddenFile, message, payment,
            related("customer", id: customerID, fields: ["name": .text("Fixture customer")]),
            related("job", id: jobID, fields: ["title": .text("Service visit")])])
        XCTAssertEqual(output.context.map(\.title), ["Fixture customer", "Service visit"])
        XCTAssertEqual(output.files.map(\.route.id), [ownFile.id])
        XCTAssertEqual(output.messages.map(\.route.id), [message.id])
        XCTAssertEqual(output.payments.map(\.route.id), [payment.id])
        XCTAssertFalse(output.totals.contains { $0.id == "balance" }, "Visible payments cannot invent a balance")
    }

    func testUnavailableContextAndCatalogNeverBecomeFallbackOwnerRoutes() throws {
        let output = try render(sale())
        XCTAssertTrue(output.context.isEmpty)
        XCTAssertNil(output.lines[0].catalogLink)
        XCTAssertTrue(output.files.isEmpty)
    }

    func testMissingLegacyLinesRemainExplicitAndDoNotBecomeZeroLineTotals() throws {
        let base = try fixture.base()
        let document = changed(try XCTUnwrap(fixture.prepare(base).documents.first), fields: ["lineItemSummary": .text("Legacy service visit")])
        let output = try render(document)
        XCTAssertTrue(output.linesNotRecorded); XCTAssertTrue(output.lines.isEmpty)
        XCTAssertEqual(output.legacySummary, "Legacy service visit")
        XCTAssertFalse(output.totals.contains { $0.id == "gross" })
        XCTAssertEqual(output.totals.first { $0.id == "total" }?.value,
            Decimal(string: "123.375")!.formatted(.currency(code: "USD").precision(.fractionLength(2...16))))
        XCTAssertTrue(output.taxNotice.contains("fractional cents"))
        XCTAssertEqual(StaffWorkspaceBillingQueue.summaries(imports(document)).values.first?.amount,
            output.totals.first { $0.id == "total" }?.value)
    }

    func testPendingAndUnknownTaxNeverClaimCollectionReadiness() throws {
        let original = try sale()
        for (raw, phrase) in [("pending_quickbooks", "not ready"), ("needs_attention", "office review")] {
            let output = try render(changed(original, fields: ["taxCalculationStatusRawValue": .text(raw)]))
            XCTAssertTrue(output.taxNotice.contains(phrase))
        }
        XCTAssertTrue(try render(changed(original, fields: ["taxCalculationStatusRawValue": .null])).taxNotice.contains("not been verified"))
        XCTAssertTrue(try render(changed(original, fields: ["taxCalculationStatusRawValue": .text("calculated_by_quickbooks")])).taxNotice.contains("not a live payment balance"))
    }

    func testWorkTypeAndDispatchEstimateUseSameSavedDocumentPresentation() throws {
        for kind in InvoiceWorkType.allCases {
            XCTAssertEqual(try render(changed(sale(), fields: ["workTypeRaw": .text(kind.rawValue)])).title, kind.documentTitle)
        }
        let estimate = try render(sale(role: .dispatcher, kind: "estimate"))
        XCTAssertEqual(estimate.title, "Estimate"); XCTAssertEqual(estimate.lines.count, 1)
        XCTAssertTrue(estimate.payments.isEmpty)
    }

    func testInvalidTotalsIdentityDuplicatesAndPartitionCollisionFailClosed() throws {
        let document = try sale(), records = imports(document)
        for fields: [String: StaffWorkspaceValue] in [["amount": .number(999)], ["amount": .null], ["salesTaxAmount": .number(-1)]] {
            XCTAssertThrowsError(try render(changed(document, fields: fields)))
        }
        XCTAssertThrowsError(try Detail.make(route: .init(kind: "invoice", id: UUID().uuidString.lowercased()), records: records))
        XCTAssertThrowsError(try Detail.make(route: .init(kind: "invoice", id: document.id.uuidString.lowercased()), records: records + records))
        let collided = Projection.Document(kind: document.kind, id: document.id, fields: document.fields,
            unavailableFields: document.unavailableFields.merging(["amount": .roleRestricted]) { _, new in new }, catalog: document.catalog)
        XCTAssertThrowsError(try render(collided))
    }

    func testHostedDocumentUsesActualActivatedStoreAndRejectsLocalTampering() async throws {
        let f = try StaffWorkspaceOpenSessionTests.Fixture(); defer { f.cleanup() }
        let session = try await f.open(), before = f.saved
        let invoice = try XCTUnwrap(session.hosted.plan.records.first { $0.kind == "invoice" })
        let route = StaffWorkspaceRecordRoute(kind: invoice.kind, id: invoice.id)
        let output = try Detail.load(hosted: session.hosted, route: route)
        XCTAssertFalse(output.title.isEmpty); XCTAssertEqual(f.saved, before)
        let context = ModelContext(session.hosted.container)
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<StaffWorkspaceOperationalProjectionRecord>()).first { $0.recordID == invoice.id && $0.kind == "invoice" })
        row.availableFieldsJSON = row.availableFieldsJSON.replacingOccurrences(of: "unpaid", with: "paid")
        try context.save()
        XCTAssertThrowsError(try Detail.load(hosted: session.hosted, route: route))
    }

    func testSearchSurvivesVerifiedRefreshButClearsOnNavigationOrAccessLoss() async throws {
        let f = try StaffWorkspaceOpenSessionTests.Fixture(); defer { f.cleanup() }
        let receive = f.controller(), navigation = StaffWorkspaceNavigationController()
        await f.refresh(receive); navigation.update(receive.authorizedPresentation)
        navigation.selected = .invoices; navigation.searchText = "Original customer"
        try f.advance(); await f.refresh(receive); navigation.update(receive.authorizedPresentation)
        XCTAssertEqual(navigation.searchText, "Original customer")
        navigation.selected = .customers; XCTAssertEqual(navigation.searchText, "")
        navigation.searchText = "Private customer"
        f.allowed = false; navigation.update(receive.authorizedPresentation)
        XCTAssertEqual(navigation.searchText, "")
    }
}
