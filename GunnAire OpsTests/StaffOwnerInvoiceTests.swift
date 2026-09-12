import Foundation
import SwiftData
import XCTest
@testable import GunnAire_Ops

@MainActor final class StaffOwnerInvoiceTests: XCTestCase {
    @MainActor final class Fixture {
        let now = ISO8601DateFormatter().date(from: "2026-09-11T08:00:00Z")!
        let scope: StaffReplicaSourceScope
        let container: ModelContainer
        let customer: Customer
        let job: ServiceCall
        let equipment: CustomerEquipment
        let invoice: Invoice
        let newID = UUID(), command = UUID(), selection = UUID(), share = UUID()
        var catalogItem: Item?
        var quantity = 2.0
        var allowed = true
        init(company: UUID = UUID()) throws {
            scope = .init(backendOrigin: "https://example.invalid", actorEmail: "office@example.invalid",
                binding: .init(companyID: company, containerID: GunnAireCloudKit.containerIdentifier,
                    environment: "development", replicaID: UUID(), cloudAccountHash: String(repeating: "a", count: 64),
                    approvedAt: "2026-09-10T08:00:00Z"), storeUUID: UUID().uuidString.lowercased())
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OwnerInvoice-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let schema = GunnAireModelSchema.schema
            container = try ModelContainer(for: schema, configurations: [.init(schema: schema,
                url: directory.appendingPathComponent("Owner.store"), cloudKitDatabase: .none)])
            container.mainContext.autosaveEnabled = false
            customer = Customer(name: "Synthetic customer")
            let tech = Technician(name: "Synthetic technician", contactInfo: "tech@example.invalid")
            job = ServiceCall(type: .repair, scheduledDate: now, assignedTechnician: tech, customer: customer)
            equipment = CustomerEquipment(customer: customer, equipmentType: .splitSystemAC, name: "Synthetic upstairs system",
                manufacturer: "Synthetic", modelNumber: "SYNTH-1", serialNumber: "TEST-ONLY", location: "Upstairs", createdAt: now)
            invoice = Invoice(serviceCallID: job.id, customer: customer, createdAt: now)
            for object: any PersistentModel in [customer, tech, job, equipment, invoice] { container.mainContext.insert(object) }
            try container.mainContext.save()
        }
        // Do not unlink a store while SwiftData still retains its registered models.
        func check() throws { if !allowed { throw StaffReplicaSourceSyncError.access } }
        func record(_ model: StaffWorkspaceModelRecord, revision: Int = 1) -> StaffWorkspacePublishedRecord {
            .init(companyID: scope.binding.companyID.uuidString.lowercased(), environment: scope.binding.environment,
                replicaID: scope.binding.replicaID.uuidString.lowercased(), schema: StaffWorkspacePublicationContract.schema,
                schemaDigest: StaffWorkspacePublicationContract.schemaDigest, kind: model.kind,
                id: model.id.uuidString.lowercased(), revision: revision, deleted: false, fields: model.fields)
        }
        func records() throws -> [StaffWorkspacePublishedRecord] {
            let context = ModelContext(container); context.autosaveEnabled = false
            return try StaffWorkspaceModelCatalog.all.filter { ["invoice", "customer", "job", "equipment", "item", "location"].contains($0.kind) }
                .flatMap { try $0.readSavedRecords(context).map { record($0) } }
        }
        func review() throws -> StaffOwnerInvoiceReview {
            let origin = StaffInvoiceOrigin(companyID: scope.binding.companyID.uuidString.lowercased(), environment: scope.binding.environment,
                replicaID: scope.binding.replicaID.uuidString.lowercased(), selectionID: selection.uuidString.lowercased(), sourceSequence: 1,
                contentSHA256: String(repeating: "a", count: 64), invoiceID: invoice.id.uuidString.lowercased(), invoiceRevision: 1,
                customerID: customer.id.uuidString.lowercased(), jobID: job.id.uuidString.lowercased())
            let line = StaffInvoiceLine(kind: catalogItem == nil ? "new" : "catalog",
                itemID: (catalogItem?.id ?? newID).uuidString.lowercased(), itemRevision: catalogItem == nil ? 0 : 1,
                itemType: catalogItem?.itemTypeRawValue ?? "Service", name: catalogItem?.name ?? "Synthetic service",
                description: catalogItem?.itemDescription, sku: catalogItem?.sku, unitPrice: catalogItem?.unitPrice ?? 123.375,
                quantity: quantity, isTaxable: catalogItem?.isTaxable ?? true, equipmentID: equipment.id.uuidString.lowercased())
            let request = StaffInvoiceRequest(origin: origin, commandID: command.uuidString.lowercased(), line: line, reason: "Field work for office review")
            let receipt = StaffInvoiceReceipt(schema: StaffInvoiceRequest.schema, request: request, actorEmail: "tech@example.invalid",
                shareID: share.uuidString.lowercased(), createdAt: "2026-09-11T07:59:00Z", state: "recorded", officeReviewRequired: true,
                qboPublished: false, lineSubtotal: line.unitPriceSubtotal.map { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), NSDecimalNumber(decimal: $0).doubleValue) })
            let base = record(try StaffWorkspaceModelCodecs.invoice.encode(invoice))
            let item = try catalogItem.map { record(try StaffWorkspaceModelCodecs.item.encode($0)) }
            return .init(schema: request.schema, request: request, receipt: receipt, baseInvoice: base,
                baseInvoiceSHA256: String(repeating: "b", count: 64), baseItem: item,
                baseItemSHA256: item == nil ? nil : String(repeating: "c", count: 64), currentInvoice: base,
                currentItem: item, invoiceUnchanged: true, itemUnchanged: true, currentSourceSequence: 1, sourceUnchanged: true)
        }
        func proposal() throws -> StaffOwnerInvoiceProposal {
            try StaffOwnerInvoicePlanner.make(review: review(), records: records(), scope: scope,
                reason: "Office reviewed original field work", now: now)
        }
        func receipt(_ proposal: StaffOwnerInvoiceProposal) -> StaffOwnerInvoiceApplication {
            .init(schema: proposal.schema, companyID: proposal.companyID, environment: proposal.environment, replicaID: proposal.replicaID,
                commandID: proposal.commandID, operationID: proposal.operationID, ownerStoreID: proposal.ownerStoreID, ownerEmail: scope.actorEmail,
                invoiceID: proposal.expectedInvoice.id, preparedAt: "2026-09-11T08:00:01Z", state: "prepared", publishedAt: nil,
                qboPublished: false, proposalSHA256: String(repeating: "d", count: 64))
        }
        func apply(_ proposal: StaffOwnerInvoiceProposal, save: ((ModelContext) throws -> Void)? = nil) throws {
            try StaffOwnerInvoiceModels.apply(proposal, application: receipt(proposal), scope: scope, container: container, check: check, save: save)
        }
        func addItem(_ price: Double = 25) throws -> Item {
            let item = Item(name: "Synthetic existing item", unitPrice: price, createdAt: now)
            container.mainContext.insert(item); try container.mainContext.save(); return item
        }
        func setLines(_ lines: [CatalogLineItemSnapshot], discount: AuthorizedDocumentDiscount? = nil) throws {
            struct Envelope: Encodable { let version = 1; let lines: [CatalogLineItemSnapshot]; let documentDiscount: AuthorizedDocumentDiscount? }
            invoice.catalogSnapshotJSON = String(data: try StaffWorkspacePublicationContract.encode(Envelope(lines: lines, documentDiscount: discount)), encoding: .utf8)
            invoice.amount = try XCTUnwrap(BillingTaxPolicy.snapshotSubtotal(invoice.catalogSnapshotJSON))
            try container.mainContext.save()
        }
        func snapshot(_ proposal: StaffOwnerInvoiceProposal) throws -> CatalogSnapshotPayload.Snapshot {
            try XCTUnwrap(CatalogSnapshotPayload.read(StaffOwnerInvoicePlanner.text(proposal.invoiceFields, "catalogSnapshotJSON")))
        }
    }
    func mutate<T: Codable>(_ value: T, _ changes: (inout [String: Any]) -> Void) throws -> T {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: StaffWorkspacePublicationContract.encode(value)) as? [String: Any])
        changes(&object)
        return try StaffWorkspacePublicationContract.decode(T.self, from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
    func changed(_ proposal: StaffOwnerInvoiceProposal, invoice: [String: StaffWorkspaceValue]? = nil,
                 item: [String: StaffWorkspaceValue]? = nil, dependencies: [StaffWorkspacePublishedRecord]? = nil) -> StaffOwnerInvoiceProposal {
        .init(schema: proposal.schema, companyID: proposal.companyID, environment: proposal.environment, replicaID: proposal.replicaID,
            commandID: proposal.commandID, operationID: proposal.operationID, ownerStoreID: proposal.ownerStoreID, request: proposal.request,
            expectedInvoice: proposal.expectedInvoice, invoiceFields: invoice ?? proposal.invoiceFields, newItemFields: item ?? proposal.newItemFields,
            dependencies: dependencies ?? proposal.dependencies, reviewed: proposal.reviewed, reason: proposal.reason)
    }

    func testNewItemProposalIsPureRetainsAuthorshipAndSystemAndClearsStaleApproval() throws {
        let f = try Fixture(); f.invoice.customerSignatureName = "Earlier approval"; f.invoice.customerSignedAt = f.now
        f.invoice.salesTaxAmount = 0; try f.container.mainContext.save()
        let proposal = try f.proposal(), snapshot = try f.snapshot(proposal)
        XCTAssertEqual(proposal.invoiceFields["amount"], .number(246.75)); XCTAssertEqual(snapshot.lines.count, 1)
        XCTAssertEqual(snapshot.lines[0].servicedEquipment?.serialNumber, "TEST-ONLY")
        XCTAssertEqual(snapshot.lines[0].servicedEquipment?.equipmentType, "Split System AC")
        XCTAssertEqual(proposal.newItemFields?["pricebookCreatedByEmail"], .text("tech@example.invalid"))
        XCTAssertEqual(proposal.invoiceFields["customerSignatureName"], .null)
        XCTAssertEqual(proposal.invoiceFields["taxCalculationStatusRawValue"], .text("pending_quickbooks"))
        XCTAssertEqual(f.invoice.amount, 0); XCTAssertEqual(f.invoice.customerSignatureName, "Earlier approval")
        XCTAssertEqual(try f.container.mainContext.fetchCount(FetchDescriptor<Item>()), 0)
        XCTAssertFalse(f.container.mainContext.hasChanges)
    }
    func testOrdinaryCatalogUsesSameItemWithoutCreatingAnother() throws {
        let f = try Fixture(); f.catalogItem = try f.addItem()
        let proposal = try f.proposal(); XCTAssertNil(proposal.newItemFields)
        XCTAssertEqual(try f.snapshot(proposal).lines[0].quantity, 2)
        try f.apply(proposal)
        XCTAssertEqual(f.invoice.amount, 50); XCTAssertEqual(try f.container.mainContext.fetchCount(FetchDescriptor<Item>()), 1)
    }
    func testCompatibleRepeatRetainsOriginalSoldEvidenceAndAddsExactQuantity() throws {
        let f = try Fixture(); f.catalogItem = try f.addItem()
        let initial = try f.snapshot(f.proposal()).lines[0]
        try f.setLines([initial])
        let proposal = try f.proposal(), line = try f.snapshot(proposal).lines[0]
        XCTAssertEqual(line, initial.replacingQuantity(with: 4)); XCTAssertEqual(proposal.invoiceFields["amount"], .number(100))
    }
    func testIncompatibleExistingPriceOrSystemDoesNotRepriceOriginalSale() throws {
        for differentSystem in [false, true] {
            let f = try Fixture(); let item = try f.addItem(); f.catalogItem = item
            let initial = try f.snapshot(f.proposal()).lines[0]
            try f.setLines([differentSystem ? initial.replacingEquipment(nil) : initial])
            if !differentSystem { item.unitPrice = 30; try f.container.mainContext.save() }
            let before = f.invoice.catalogSnapshotJSON
            XCTAssertThrowsError(try f.proposal()); XCTAssertEqual(f.invoice.catalogSnapshotJSON, before); XCTAssertEqual(f.invoice.amount, 50)
        }
    }
    func testItemizedAssemblyKeepsEveryComponentQuantityAndOldFlatRateSale() throws {
        let f = try Fixture(); let root = try f.addItem(100), first = try f.addItem(10), second = try f.addItem(20)
        f.catalogItem = root
        try f.setLines([CatalogLineItemSnapshot(item: root, quantity: 1)])
        root.flatRateAssemblyJSON = CatalogAssemblyDefinition(presentation: .itemized,
            components: [.init(itemID: first.id, quantity: 2), .init(itemID: second.id, quantity: 3)]).encodedJSON
        try f.container.mainContext.save()
        let proposal = try f.proposal(), rows = try f.snapshot(proposal).lines
        XCTAssertEqual(rows.count, 3); XCTAssertEqual(rows[0].quantity, 1); XCTAssertEqual(rows[0].unitPrice, 100)
        XCTAssertEqual(rows.first { $0.catalogItemID == first.id }?.quantity, 4)
        XCTAssertEqual(rows.first { $0.catalogItemID == second.id }?.quantity, 6)
        XCTAssertEqual(proposal.invoiceFields["amount"], .number(260))
    }
    func testGroupUsesOrderedProviderVerifiedMembersAndNoHeaderCharge() throws {
        let f = try Fixture(company: CatalogBundleFixture.scope.companyID), catalog = try CatalogBundleFixture.makeCatalog()
        for item in catalog { f.container.mainContext.insert(item) }
        f.catalogItem = try XCTUnwrap(catalog.last); try f.container.mainContext.save()
        let proposal = try f.proposal(), line = try f.snapshot(proposal).lines[0]
        XCTAssertEqual(line.unitPrice, 0); XCTAssertEqual(line.soldLeaves.count, 2)
        XCTAssertEqual(line.soldLeaves.map(\.quantity), [2, 2]); XCTAssertEqual(proposal.invoiceFields["amount"], .number(378))
    }
    func testDiscountReauthorizationKeepsOldLinesAndAppliesToNewGross() throws {
        let f = try Fixture(), old = try f.addItem(100)
        let line = CatalogLineItemSnapshot(item: old, quantity: 1)
        try f.setLines([line], discount: .init(kind: .percentage, value: 10, grossSubtotalAtAuthorization: 100,
            reason: "Service agreement", authorizedByEmail: "prior@example.invalid", authorizedAt: f.now))
        let proposal = try f.proposal(), snapshot = try f.snapshot(proposal)
        XCTAssertEqual(snapshot.lines[0], line); XCTAssertEqual(snapshot.discount?.grossSubtotalAtAuthorization, 346.75)
        XCTAssertEqual(snapshot.discount?.authorizedByEmail, f.scope.actorEmail); XCTAssertEqual(proposal.invoiceFields["amount"], .number(312.07))
    }
    func testSharedDiscountCurrencyHelpersUseDecimalHalfUpWithoutIntegerOverflow() throws {
        XCTAssertEqual(BillingDocumentDiscountPolicy.roundCurrency(1.005), 1.01)
        XCTAssertEqual(BillingDocumentDiscountPolicy.roundCurrency(34.675), 34.68)
        XCTAssertEqual(BillingDocumentDiscountPolicy.currencyCents(1.005), 101)
        XCTAssertNil(BillingDocumentDiscountPolicy.currencyCents(Double(Int64.max) / 100))
        XCTAssertNil(BillingDocumentDiscountPolicy.currencyCents(.infinity))
        XCTAssertNil(BillingDocumentDiscountPolicy.currencyCents(-1))
        let discount = AuthorizedDocumentDiscount(kind: .percentage, value: 10, grossSubtotalAtAuthorization: 346.75,
            reason: "Agreement", authorizedByEmail: "office@example.invalid", authorizedAt: Date())
        XCTAssertEqual(discount.amount(for: 346.75), 34.68)
        XCTAssertEqual(discount.amount(for: 346.74999999999994), 34.68, "Accumulating cent-priced lines cannot lose a half-cent")
        XCTAssertNil(discount.amount(for: 347))
    }
    func testManualOrLockedInvoiceIsRetained() throws {
        for field in 0..<4 {
            let f = try Fixture()
            switch field { case 0: f.invoice.amount = 50; case 1: f.invoice.status = "paid"
            case 2: f.invoice.finalizedAt = f.now; default: f.invoice.projectMilestoneID = UUID() }
            try f.container.mainContext.save(); let before = try StaffWorkspaceModelCodecs.invoice.encode(f.invoice)
            XCTAssertThrowsError(try f.proposal()); XCTAssertEqual(try StaffWorkspaceModelCodecs.invoice.encode(f.invoice), before)
        }
    }
    func testProposalRejectsTamperedTotalTaxAndMissingDependencies() throws {
        let f = try Fixture(), proposal = try f.proposal()
        for (key, value): (String, StaffWorkspaceValue) in [("amount", .number(1)), ("salesTaxAmount", .number(10)),
            ("taxCalculationStatusRawValue", .text("not_applicable")), ("quickBooksSyncStatus", .text("synced"))] {
            var fields = proposal.invoiceFields; fields[key] = value
            XCTAssertThrowsError(try changed(proposal, invoice: fields).validate(f.scope), key)
        }
        for record in proposal.dependencies {
            XCTAssertThrowsError(try changed(proposal, dependencies: proposal.dependencies.filter { $0.key != record.key }).validate(f.scope), record.kind)
        }
    }
    func testNewItemCannotBorrowProviderEvidenceOrAnotherStaffAuthor() throws {
        let f = try Fixture(), proposal = try f.proposal()
        for (key, value): (String, StaffWorkspaceValue) in [("pricebookCreatedByEmail", .text("other@example.invalid")),
            ("itemDescription", .text("Changed work")), ("quickBooksSyncToken", .text("2"))] {
            var fields = try XCTUnwrap(proposal.newItemFields); fields[key] = value
            XCTAssertThrowsError(try changed(proposal, item: fields).validate(f.scope, original: f.review()), key)
        }
    }
    func testOneAtomicSaveAndRetryDoesNotInsertOrApplyTwice() throws {
        let f = try Fixture(), proposal = try f.proposal(); var saves = 0
        try f.apply(proposal) { saves += 1; try $0.save() }
        try f.apply(proposal) { saves += 1; try $0.save() }
        XCTAssertEqual(saves, 1); XCTAssertEqual(f.invoice.amount, 246.75)
        XCTAssertEqual(try f.container.mainContext.fetchCount(FetchDescriptor<Item>()), 1)
        XCTAssertTrue(try StaffOwnerInvoiceModels.verify(proposal, scope: f.scope, container: f.container, allowApplied: true))
        XCTAssertNil(f.container.mainContext.author)
    }
    func testLostSaveAcknowledgmentRecoversWithoutSecondTransaction() throws {
        let f = try Fixture(), proposal = try f.proposal(); var saves = 0
        XCTAssertThrowsError(try f.apply(proposal) { saves += 1; try $0.save(); throw StaffOwnerInvoiceError.storage })
        try f.apply(proposal) { saves += 1; try $0.save() }
        XCTAssertEqual(saves, 1); XCTAssertEqual(f.invoice.amount, 246.75)
        XCTAssertEqual(try f.container.mainContext.fetchCount(FetchDescriptor<Item>()), 1)
    }
    func testSaveFailureRollsBackOnlyThisWriteThenRetriesOriginalItemID() throws {
        let f = try Fixture(), proposal = try f.proposal()
        XCTAssertThrowsError(try f.apply(proposal) { _ in throw StaffOwnerInvoiceError.storage })
        XCTAssertEqual(f.invoice.amount, 0); XCTAssertFalse(f.container.mainContext.hasChanges)
        XCTAssertEqual(try f.container.mainContext.fetchCount(FetchDescriptor<Item>()), 0)
        try f.apply(proposal)
        XCTAssertEqual(try f.container.mainContext.fetch(FetchDescriptor<Item>()).first?.id, f.newID)
    }
    func testFailurePreservesUnrelatedObserverDraft() throws {
        let f = try Fixture(), proposal = try f.proposal()
        XCTAssertThrowsError(try f.apply(proposal) { _ in f.job.notes = "User draft"; throw StaffOwnerInvoiceError.storage })
        XCTAssertEqual(f.job.notes, "User draft"); XCTAssertEqual(f.invoice.amount, 0)
        XCTAssertTrue(f.container.mainContext.hasChanges)
        XCTAssertThrowsError(try f.apply(proposal))
    }
    func testAccessLossAfterCommitRetainsSavedWorkForSameClaimRecovery() throws {
        let f = try Fixture(), proposal = try f.proposal()
        XCTAssertThrowsError(try f.apply(proposal) { try $0.save(); f.allowed = false })
        XCTAssertEqual(f.invoice.amount, 246.75)
        f.allowed = true; try f.apply(proposal)
        XCTAssertEqual(try f.container.mainContext.fetchCount(FetchDescriptor<Item>()), 1)
    }
    func testUnsavedUserDraftChangedDependencyOrInvoiceNeverGetsOverwritten() throws {
        for change in 0..<3 {
            let f = try Fixture(), proposal = try f.proposal()
            if change == 0 { f.job.notes = "Unsaved user draft" }
            if change == 1 { f.equipment.serialNumber = "New serial"; try f.container.mainContext.save() }
            if change == 2 { f.invoice.notes = "Office edit"; try f.container.mainContext.save() }
            XCTAssertThrowsError(try f.apply(proposal)); XCTAssertEqual(f.invoice.amount, 0)
            XCTAssertEqual(try f.container.mainContext.fetchCount(FetchDescriptor<Item>()), 0)
        }
    }
    func testWrongCustomerJobAndEquipmentCannotCrossInvoiceBoundary() throws {
        for equipment in [true, false] {
            let f = try Fixture(), other = Customer(name: "Other synthetic customer")
            f.container.mainContext.insert(other)
            if equipment { f.equipment.customer = other } else { f.job.customer = other }
            try f.container.mainContext.save(); XCTAssertThrowsError(try f.proposal())
        }
    }
    func testStrictWireAndExactScopedTransportRoundTrip() throws {
        let f = try Fixture(), proposal = try f.proposal(), review = try f.review()
        let bytes = try StaffWorkspacePublicationContract.encode(proposal)
        XCTAssertEqual(try StaffWorkspacePublicationContract.decode(StaffOwnerInvoiceProposal.self, from: bytes), proposal)
        XCTAssertEqual(try StaffWorkspacePublicationContract.decode(StaffOwnerInvoiceReview.self,
            from: StaffWorkspacePublicationContract.encode(review)), review)
        let path = StaffOwnerInvoiceTransport.root + "/" + proposal.commandID + "/prepare"
        XCTAssertTrue(StaffOwnerInvoiceTransport.allows(path: path, method: "POST", body: bytes))
        for invalid in [path + "/", path + "?x=1", path + "#x", "https://example.invalid" + path,
            path.replacingOccurrences(of: proposal.commandID, with: UUID().uuidString.lowercased()), path.replacingOccurrences(of: "prepare", with: "%70repare")] {
            XCTAssertFalse(StaffOwnerInvoiceTransport.allows(path: invalid, method: "POST", body: bytes))
        }
        XCTAssertThrowsError(try mutate(proposal) { $0["extra"] = true })
        XCTAssertThrowsError(try mutate(review) { $0.removeValue(forKey: "baseItem") })
        XCTAssertThrowsError(try mutate(proposal) { $0["reviewed"] = 1 })
    }
    func testReceiptCannotClaimQBOCompletionOrDifferentOperationOrOwner() throws {
        let f = try Fixture(), proposal = try f.proposal(), receipt = f.receipt(proposal)
        try receipt.validate(proposal, scope: f.scope)
        for (key, value): (String, Any) in [("qboPublished", true), ("operationID", UUID().uuidString.lowercased()),
            ("ownerEmail", "other@example.invalid"), ("state", "published"), ("preparedAt", "invalid")] {
            XCTAssertThrowsError(try mutate(receipt) { $0[key] = value }.validate(proposal, scope: f.scope), key)
        }
    }
    func testOriginalTaxIsRemovedFromChangedTotalUntilQBORecalculates() throws {
        let f = try Fixture(), old = try f.addItem(100)
        try f.setLines([CatalogLineItemSnapshot(item: old, quantity: 1)])
        f.invoice.amount = 108; f.invoice.salesTaxAmount = 8; f.invoice.quickBooksID = "SYNTHETIC-INVOICE"
        f.invoice.quickBooksBalanceDue = 108; try f.container.mainContext.save()
        let proposal = try f.proposal()
        XCTAssertEqual(proposal.invoiceFields["amount"], .number(346.75))
        XCTAssertEqual(proposal.invoiceFields["salesTaxAmount"], .number(0))
        XCTAssertEqual(proposal.invoiceFields["quickBooksSyncStatus"], .text("balance_needs_refresh"))
        XCTAssertEqual(proposal.invoiceFields["quickBooksBalanceDue"], .number(108))
    }
    func testInconsistentOriginalAmountDoesNotSilentlyCorrectTheInvoice() throws {
        let f = try Fixture(), old = try f.addItem(100)
        try f.setLines([CatalogLineItemSnapshot(item: old, quantity: 1)])
        f.invoice.amount = 130; try f.container.mainContext.save()
        XCTAssertThrowsError(try f.proposal()); XCTAssertEqual(f.invoice.amount, 130)
    }
    func testCommittedChangeDuringFinalAuthorityCheckStopsBeforeApplication() throws {
        let f = try Fixture(), proposal = try f.proposal(); var checks = 0, saves = 0
        XCTAssertThrowsError(try StaffOwnerInvoiceModels.apply(proposal, application: f.receipt(proposal), scope: f.scope,
            container: f.container, check: {
                checks += 1
                if checks == 2 { f.invoice.notes = "Newer office work"; try f.container.mainContext.save() }
            }, save: { saves += 1; try $0.save() }))
        XCTAssertEqual(saves, 0); XCTAssertEqual(f.invoice.amount, 0); XCTAssertEqual(f.invoice.notes, "Newer office work")
    }
    func testReviewFlagsOriginalCustomerAndOriginalItemMustMatch() throws {
        let f = try Fixture(); f.catalogItem = try f.addItem()
        let review = try f.review()
        for (key, value): (String, Any) in [("invoiceUnchanged", false), ("sourceUnchanged", false),
            ("currentSourceSequence", 0), ("baseInvoiceSHA256", "bad")] {
            XCTAssertThrowsError(try mutate(review) { $0[key] = value }.validate(f.scope), key)
        }
        let changedItem = try mutate(review) { object in
            var item = object["baseItem"] as! [String: Any], fields = item["fields"] as! [String: Any]
            fields["name"] = ["text": ["_0": "Wrong source item"]]; item["fields"] = fields
            object["baseItem"] = item; object["currentItem"] = item
        }
        XCTAssertThrowsError(try changedItem.validate(f.scope))
    }
    func testPaginationAndGetRoutesRequireExactScopeAndCanonicalCursor() throws {
        let f = try Fixture(), origin = try f.review().request.origin
        let ids = (0..<50).map { _ in UUID().uuidString.lowercased() }.sorted()
        let page = StaffOwnerInvoicePage(schema: StaffInvoiceRequest.schema, companyID: origin.companyID,
            environment: origin.environment, replicaID: origin.replicaID, commandIDs: ids, nextCursor: ids.last)
        try page.validate(f.scope, after: nil)
        XCTAssertThrowsError(try page.validate(f.scope, after: ids[0]))
        XCTAssertThrowsError(try mutate(page) { $0["nextCursor"] = ids[0] }.validate(f.scope, after: nil))
        let path = StaffOwnerInvoiceTransport.path(f.scope, after: ids[0])
        XCTAssertTrue(StaffOwnerInvoiceTransport.allows(path: path, method: "GET", body: nil))
        for invalid in [path + "&companyID=" + origin.companyID, path + "&extra=x",
            StaffOwnerInvoiceTransport.path(f.scope, id: ids[0], after: ids[1]), StaffOwnerInvoiceTransport.path(f.scope, application: true)] {
            XCTAssertFalse(StaffOwnerInvoiceTransport.allows(path: invalid, method: "GET", body: nil))
        }
    }
    func testExportActualNativeProposalsForBackendContractQualification() throws {
        struct Vector: Encodable {
            let kind: String
            let scope: StaffReplicaSourceScope
            let review: StaffOwnerInvoiceReview
            let proposal: StaffOwnerInvoiceProposal
        }
        var vectors: [Vector] = []
        for kind in ["new", "discount", "catalog", "assembly", "group"] {
            let f = try Fixture(company: CatalogBundleFixture.scope.companyID)
            if kind == "catalog" { f.catalogItem = try f.addItem() }
            if kind == "discount" {
                let old = try f.addItem(100)
                try f.setLines([CatalogLineItemSnapshot(item: old, quantity: 1)], discount: .init(kind: .percentage, value: 10,
                    grossSubtotalAtAuthorization: 100, reason: "Agreement", authorizedByEmail: f.scope.actorEmail, authorizedAt: f.now))
            }
            if kind == "assembly" {
                let root = try f.addItem(100), part = try f.addItem(10), labor = try f.addItem(20)
                f.catalogItem = root
                root.flatRateAssemblyJSON = CatalogAssemblyDefinition(presentation: .itemized,
                    components: [.init(itemID: part.id, quantity: 2), .init(itemID: labor.id, quantity: 3)]).encodedJSON
                try f.container.mainContext.save()
            }
            if kind == "group" {
                let items = try CatalogBundleFixture.makeCatalog()
                for item in items { f.container.mainContext.insert(item) }
                f.catalogItem = items.last; try f.container.mainContext.save()
            }
            let proposal = try f.proposal()
            try proposal.validate(f.scope, original: f.review())
            vectors.append(.init(kind: kind, scope: f.scope, review: try f.review(), proposal: proposal))
        }
        let attachment = XCTAttachment(data: try StaffWorkspacePublicationContract.encode(vectors), uniformTypeIdentifier: "public.json")
        attachment.name = "NativeOwnerInvoiceProposals.json"; attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testActualNativeProposalsAndPythonReceiptsStrictlyRoundTrip() throws {
        struct Vector: Codable {
            let kind: String
            let scope: StaffReplicaSourceScope
            let review: StaffOwnerInvoiceReview
            let proposal: StaffOwnerInvoiceProposal
            let receipt: StaffOwnerInvoiceApplication
        }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "NativeOwnerInvoiceInterop", withExtension: "json"))
        let vectors = try StaffWorkspacePublicationContract.decode([Vector].self, from: Data(contentsOf: url))
        XCTAssertEqual(Set(vectors.map(\.kind)), Set(["new", "discount", "catalog", "assembly", "group"]))
        for vector in vectors {
            try vector.review.validate(vector.scope)
            try vector.proposal.validate(vector.scope, original: vector.review)
            try vector.receipt.validate(vector.proposal, scope: vector.scope)
            XCTAssertFalse(vector.receipt.qboPublished)
            let envelope = StaffOwnerInvoiceApplicationEnvelope(schema: StaffOwnerInvoiceProposal.schema,
                application: .init(proposal: vector.proposal, receipt: vector.receipt))
            let bytes = try StaffWorkspacePublicationContract.encode(envelope)
            let decoded = try StaffWorkspacePublicationContract.decode(StaffOwnerInvoiceApplicationEnvelope.self, from: bytes)
            XCTAssertEqual(decoded.application?.proposal, vector.proposal)
        }
    }
}
