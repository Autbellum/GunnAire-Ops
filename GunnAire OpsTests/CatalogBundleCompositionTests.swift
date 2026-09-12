import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor struct CatalogBundleCompositionTests {
    private func catalog() throws -> [Item] { try CatalogBundleFixture.makeCatalog() }
    private func select(_ items: [Item]) throws -> CatalogLineItemSnapshot {
        try CatalogBundlePolicy.resolve(root: #require(items.last), catalog: items, scope: CatalogBundleFixture.scope)
    }
    private func json(_ snapshot: CatalogLineItemSnapshot) throws -> String {
        try #require(CatalogLineItemSnapshot.encoded(snapshots: [snapshot]))
    }
    @Test func selectionUsesOrderedRowsNotProductDictionaryAndNoHeaderCharge() throws {
        let items = try catalog(), saved = try select(items)
        let members = try #require(saved.bundle?.members)
        #expect(members.count == 2 && members[0].id != members[1].id)
        #expect(members[0].line.catalogItemID == members[1].line.catalogItemID)
        #expect(saved.unitPrice == 0 && saved.extendedAmount == 189)
        #expect(saved.soldLeaves.map(\.purchaseCost) == [40, 40])
        #expect(try CatalogLineItemSnapshot.decoded(from: json(saved)) == [saved])
    }

    @Test func changingBundleQuantityScalesEverySavedMemberWithoutReadingNewPrices() throws {
        let items = try catalog(), saved = try select(items)
        items[2].unitPrice = 999; items[2].purchaseCost = 888
        let scaled = try CatalogBundlePolicy.resized(saved, quantity: 2.5)
        #expect(scaled.quantity == 2.5 && scaled.extendedAmount == 472.5)
        #expect(scaled.soldLeaves.map(\.quantity) == [2.5, 2.5])
        #expect(scaled.soldLeaves.map(\.unitPrice) == [94.5, 94.5])
        #expect(scaled.soldLeaves.map(\.purchaseCost) == [40, 40])
        #expect(scaled.bundle?.members.map(\.id) == saved.bundle?.members.map(\.id))
    }

    @Test func customizationAndRemovalKeepGroupAndOtherRepeatedMember() throws {
        let saved = try select(catalog()), members = try #require(saved.bundle?.members)
        let edited = try CatalogBundlePolicy.editMember(saved, memberID: members[1].id, quantity: 3)
        #expect(edited.soldLeaves.map(\.quantity) == [1, 3])
        let removed = try CatalogBundlePolicy.editMember(edited, memberID: members[0].id, quantity: nil)
        #expect(removed.quickBooksItemID == saved.quickBooksItemID && removed.bundle?.members.first?.id == members[1].id)
        #expect(try CatalogBundlePolicy.resized(removed, quantity: 2).soldLeaves.first?.quantity == 6)
        #expect(throws: CatalogBundleError.lastMember) {
            try CatalogBundlePolicy.editMember(removed, memberID: members[1].id, quantity: nil)
        }
    }

    @Test(arguments: [0.0, -1, 0.000001, 1_000_000, .infinity, .nan])
    func invalidQuantityDoesNotBecomeAZeroOrMinimumCharge(_ quantity: Double) throws {
        let saved = try select(catalog())
        #expect(throws: CatalogBundleError.invalidQuantity) { try CatalogBundlePolicy.resized(saved, quantity: quantity) }
        #expect(throws: CatalogBundleError.invalidQuantity) {
            try CatalogBundlePolicy.editMember(saved, memberID: saved.bundle!.members[0].id, quantity: quantity)
        }
    }

    @Test func scalingCannotSilentlyRoundFractionalMemberQuantities() throws {
        let saved = try CatalogBundlePolicy.resized(select(catalog()), quantity: 3)
        let edited = try CatalogBundlePolicy.editMember(saved, memberID: saved.bundle!.members[0].id, quantity: 1)
        #expect(throws: CatalogBundleError.invalidQuantity) { try CatalogBundlePolicy.resized(edited, quantity: 1) }
    }

    @Test func priceAndTaxChangesRequireOfficeAuthorityAndRetainSavedCostAndReason() throws {
        let saved = try select(catalog()), id = saved.bundle!.members[1].id
        let tech = AppUser(email: "tech@example.invalid", role: .fieldTechnician)
        #expect(throws: BillingPriceAdjustmentError.unauthorized) {
            try CatalogBundlePolicy.editSale(saved, memberID: id, quantity: 1, price: 80, taxable: true,
                reason: "Reviewed repair", actorEmail: tech.email, users: [tech])
        }
        let admin = AppUser(email: "office@example.invalid", role: .admin)
        let edited = try CatalogBundlePolicy.editSale(saved, memberID: id, quantity: 1.25, price: 12.375,
            taxable: true, reason: "Approved diagnostic adjustment", actorEmail: admin.email, users: [admin])
        #expect(edited.soldLeaves[0] == saved.soldLeaves[0])
        #expect(edited.soldLeaves[1].extendedAmount == 15.47)
        #expect(edited.soldLeaves[1].purchaseCost == 40)
        #expect(edited.soldLeaves[1].priceAdjustmentReason == "Approved diagnostic adjustment")
        let snapshotJSON = try json(edited)
        #expect(BillingTaxPolicy.hasTaxableLines(snapshotJSON))
        #expect(BillingTaxPolicy.snapshotSubtotal(snapshotJSON) == 109.97)
        #expect(edited.isTaxable == false)
    }

    @Test func resolverRejectsUnreviewedMissingArchivedDuplicateAndOtherCompanyComponents() throws {
        for mutation in 0..<6 {
            var items = try catalog()
            switch mutation {
            case 0: items[2].quickBooksCatalogReceiptJSON = nil
            case 1: items[2].pricebookReviewStatusRawValue = PricebookReviewStatus.archived.rawValue
            case 2: items.remove(at: 2)
            case 3: items.append(Item(quickBooksID: "BC-L1", name: "Duplicate", unitPrice: 0))
            case 4: items[2].unitPrice = 999
            default:
                let other = try CatalogBundleFixture.makeCatalog(scope: .init(companyID: UUID(),
                    realmID: CatalogBundleFixture.scope.realmID, environment: CatalogBundleFixture.scope.environment))
                items[2] = other[2]
            }
            let root = try #require(items.first { $0.itemType == .group })
            #expect(throws: (any Error).self) {
                try CatalogBundlePolicy.resolve(root: root, catalog: items, scope: CatalogBundleFixture.scope)
            }
        }
    }

    @Test func publicationBuildsActualGroupWithAllCurrentMappingsAndExactSavedAmounts() throws {
        let items = try catalog(), saved = try CatalogBundlePolicy.resized(select(items), quantity: 2)
        items[2].unitPrice = 700 // Saving/publishing an old sale must not reprice it.
        let lines = try QuickBooksDocumentLinePublication.lines(snapshotJSON: json(saved), expectedSubtotal: 378, catalogItems: items)
        #expect(lines.count == 1 && lines[0].DetailType == "GroupLineDetail" && lines[0].Amount == 0)
        #expect(lines[0].GroupLineDetail?.Quantity == 2)
        #expect(lines[0].GroupLineDetail?.Line.map { $0.SalesItemLineDetail.Qty } == [2, 2])
        #expect(lines[0].GroupLineDetail?.Line.map(\.Amount) == [189, 189])
        #expect(try QuickBooksSalesLineContract.totals(lines).net == 378)
        items[2].quickBooksID = "different"
        #expect(throws: QuickBooksDocumentLinePublicationError.catalogIdentityChanged(saved.soldLeaves[0].name)) {
            try QuickBooksDocumentLinePublication.lines(snapshotJSON: json(saved), expectedSubtotal: 378, catalogItems: items)
        }
    }

    @Test func malformedMemberEvidenceAndDuplicatePositionsCannotPublish() throws {
        let items = try catalog(), saved = try select(items), bundle = try #require(saved.bundle)
        let repeatedPosition = saved.replacingBundle(bundle.replacingMembers([bundle.members[0], bundle.members[0]]))
        #expect(throws: CatalogBundleError.invalidMembers) { try CatalogBundlePolicy.validate(repeatedPosition) }
        let malformed = bundle.members[0].line.replacingQuantity(with: -1)
        let invalid = saved.replacingBundle(bundle.replacingMembers([.init(id: UUID(), line: malformed, tracksInventory: false)]))
        let restored = try #require(CatalogLineItemSnapshot.decoded(from: json(invalid)).first)
        #expect(restored.soldLeaves[0].quantity == -1)
        #expect(throws: (any Error).self) { try CatalogBundlePolicy.validate(restored) }
    }

    @Test func categoryFilteringUsesExactAncestorsNotNamesAndDoesNotSellCategories() throws {
        let items = try catalog(), index = CatalogCategoryIndex(items: items, scope: CatalogBundleFixture.scope)
        #expect(index.categories.map(\.title) == ["Repairs", "Repairs › Electrical"])
        #expect(index.matches(items[3], category: items[0].id))
        #expect(index.matches(items[3], category: items[1].id))
        #expect(!index.matches(items[0], category: items[1].id))
        #expect(!CatalogItemSelectionPolicy.canAdd(items[0], documentScopedReviewItemIDs: []))
        let missing = CatalogCategoryIndex(items: Array(items.dropFirst()), scope: CatalogBundleFixture.scope)
        #expect(missing.reviewItemIDs.contains(items[3].id))
        #expect(!missing.matches(items[3], category: items[1].id))
        let duplicate = CatalogCategoryIndex(items: items + [Item(quickBooksID: "BC-C1", name: "Repairs", unitPrice: 0)],
            scope: CatalogBundleFixture.scope)
        #expect(duplicate.reviewItemIDs.contains(items[3].id))
        let foreign = CatalogCategoryIndex(items: items, scope: .init(companyID: UUID(), realmID: "different", environment: "sandbox"))
        #expect(foreign.categories.isEmpty)
    }

    @Test func customerDisplayChoiceDoesNotEraseInternalMembers() throws {
        let saved = try select(catalog()), bundle = try #require(saved.bundle)
        #expect(saved.customerSummary.components(separatedBy: "Saved diagnostic labor").count == 3)
        let hidden = saved.replacingBundle(.init(scope: bundle.scope, printGroupedItems: false, members: bundle.members))
        #expect(!hidden.customerSummary.contains("Saved diagnostic labor"))
        #expect(hidden.soldLeaves.count == 2 && hidden.extendedAmount == 189)
    }

    @Test func cyclesWrongParentTypesAndDepthMismatchRemainExplicitlyUncategorized() throws {
        let cases: [[String: [String: Any]]] = [
            ["BC-C1": ["ParentRef": ["value": "BC-C2"], "Level": 2]],
            ["BC-C2": ["ParentRef": ["value": "BC-L1"]]],
            ["BC-C2": ["Level": 4]],
            ["BC-G1": ["Level": 0]],
        ]
        for overrides in cases {
            let items = try CatalogBundleFixture.makeCatalog(overrides: overrides)
            let index = CatalogCategoryIndex(items: items, scope: CatalogBundleFixture.scope)
            #expect(index.reviewItemIDs.contains(items[3].id))
            #expect(index.label(for: items[3]) == "Category needs review")
            #expect(!index.matches(items[3], category: items[1].id))
        }
    }

    @Test func recursiveCategoriesAndEmptyRecipesAreNotSaleComponents() throws {
        for component in ["BC-C1", "BC-G1", "MISSING"] {
            let items = try CatalogBundleFixture.makeCatalog(overrides: [
                "BC-G1": ["ItemGroupDetail": ["ItemGroupLine": [["Qty": 1, "ItemRef": ["value": component]]]]]])
            #expect(throws: (any Error).self) { try select(items) }
        }
        let items = try CatalogBundleFixture.makeCatalog(overrides: ["BC-G1": ["ItemGroupDetail": ["ItemGroupLine": []]]])
        #expect(throws: CatalogBundleError.refreshRequired) { try select(items) }
    }

    @Test func fourCategoryLevelsAllowASoldFifthLevelButNotAnotherCategory() throws {
        let extra: [[String: Any]] = (3...5).map { level in
            ["Id": "BC-C\(level)", "Name": "Category \(level)", "Type": "Category", "Level": level - 1,
             "ParentRef": ["value": "BC-C\(level - 1)"]]
        }
        let allowed = try CatalogBundleFixture.makeCatalog(overrides: [
            "BC-G1": ["ParentRef": ["value": "BC-C4"], "Level": 4]], additionalDefinitions: extra)
        let index = CatalogCategoryIndex(items: allowed, scope: CatalogBundleFixture.scope)
        #expect(index.ancestorsByItem[allowed[3].id]?.count == 4)
        #expect(!index.reviewItemIDs.contains(allowed[3].id))
        #expect(index.reviewItemIDs.contains(allowed[6].id))
        let tooDeep = try CatalogBundleFixture.makeCatalog(overrides: [
            "BC-G1": ["ParentRef": ["value": "BC-C5"], "Level": 5]], additionalDefinitions: extra)
        #expect(CatalogCategoryIndex(items: tooDeep, scope: CatalogBundleFixture.scope).reviewItemIDs.contains(tooDeep[3].id))
    }

    @Test func equipmentEvidenceSurvivesQuantityAndIndependentMemberEdits() throws {
        let equipment = CatalogLineEquipmentSnapshot(equipmentID: UUID(), name: "Upstairs heat pump",
            manufacturer: "Lennox", modelNumber: "Fixture", serialNumber: "SAVED-SERIAL", location: "Roof")
        let saved = CatalogBundlePolicy.equipment(try select(catalog()), equipment)
        let resized = try CatalogBundlePolicy.resized(saved, quantity: 2)
        let edited = try CatalogBundlePolicy.editMember(resized, memberID: resized.bundle!.members[1].id, quantity: 3)
        #expect(edited.servicedEquipment == equipment && edited.soldLeaves.allSatisfy { $0.servicedEquipment == equipment })
        #expect(edited.quickBooksDescription.contains("SAVED-SERIAL"))
        #expect(edited.customerSummary.contains(equipment.customerLabel))
        #expect(edited.soldLeaves.allSatisfy { $0.quickBooksDescription.contains("SAVED-SERIAL") })
        let restored = try #require(CatalogLineItemSnapshot.decoded(from: json(edited)).first)
        #expect(restored == edited)
    }

    @Test func restorationRejectsDuplicateTopRowsAndMissingCatalogWithoutRebuildingFromNames() throws {
        let items = try catalog(), saved = try select(items)
        let duplicate = try #require(CatalogLineItemSnapshot.encoded(snapshots: [saved, saved]))
        #expect(throws: CatalogBundleError.invalidMembers) { try CatalogBundlePolicy.validateRestoration(duplicate, catalog: items) }
        #expect(throws: CatalogBundleError.invalidMembers) { try CatalogBundlePolicy.validateRestoration(json(saved), catalog: Array(items.dropLast())) }
        try CatalogBundlePolicy.validateRestoration(json(saved), catalog: items)
    }

    @Test func changingCustomerRetargetsEveryBundleMemberWithoutExposingPriorSystem() throws {
        let originalCustomer = UUID(), nextCustomer = UUID()
        let original = CatalogLineEquipmentSnapshot(equipmentID: UUID(), name: "Original customer's system",
            manufacturer: "Lennox", modelNumber: "Original", serialNumber: "PRIVATE-OLD", location: "Roof")
        let next = CatalogLineEquipmentSnapshot(equipmentID: UUID(), name: "New customer's system",
            manufacturer: "Lennox", modelNumber: "New", serialNumber: "NEW", location: "Garage")
        let saved = CatalogBundlePolicy.equipment(try select(catalog()), original)
        let snapshots = [saved.catalogItemID: saved]
        let reopened = CatalogBundlePolicy.equipmentForCustomerChange(in: snapshots,
            from: originalCustomer, to: originalCustomer, defaultEquipment: nil)
        #expect(reopened == snapshots)
        for target in [nextCustomer, nil] {
            let changed = try #require(CatalogBundlePolicy.equipmentForCustomerChange(in: snapshots,
                from: originalCustomer, to: target, defaultEquipment: next)[saved.catalogItemID])
            #expect(changed.servicedEquipment == (target == nil ? nil : next))
            #expect(changed.soldLeaves.allSatisfy { $0.servicedEquipment == changed.servicedEquipment })
            #expect(!changed.customerSummary.contains("PRIVATE-OLD"))
            #expect(!changed.customerSummary.contains(original.name))
            #expect(changed.soldLeaves.allSatisfy { !$0.quickBooksDescription.contains("PRIVATE-OLD") })
            #expect(changed.extendedAmount == saved.extendedAmount)
            #expect(changed.bundle?.members.map(\.id) == saved.bundle?.members.map(\.id))
        }
        let noDefault = try #require(CatalogBundlePolicy.equipmentForCustomerChange(in: snapshots,
            from: originalCustomer, to: nextCustomer, defaultEquipment: nil)[saved.catalogItemID])
        #expect(noDefault.soldLeaves.allSatisfy { $0.servicedEquipment == nil })
    }

    @Test func savedSnapshotSurvivesSQLiteReopenAndEstimateToInvoiceCopy() throws {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent("BundleComposer-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        let schema = GunnAireModelSchema.schema
        let config = ModelConfiguration(schema: schema, url: location.appendingPathComponent("fixture.store"), cloudKitDatabase: .none)
        let saved = try autoreleasepool {
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(container), items = try catalog()
            for item in items { context.insert(item) }
            let saved = try CatalogBundlePolicy.resized(select(items), quantity: 2)
            let customer = Customer(name: "Fixture")
            context.insert(customer)
            let estimate = Estimate(customer: customer, lineItemSummary: saved.customerSummary,
                catalogSnapshotJSON: try json(saved), amount: 378)
            context.insert(estimate); try context.save()
            return saved
        }
        try autoreleasepool {
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(container)
            let reopened = try #require(context.fetch(FetchDescriptor<Estimate>()).first)
            #expect(reopened.catalogLineSnapshots == [saved])
            let invoice = Invoice.draft(from: reopened)
            context.insert(invoice); try context.save()
            #expect(invoice.catalogLineSnapshots == [saved] && invoice.amount == 378)
        }
        try autoreleasepool {
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(container)
            #expect(try context.fetch(FetchDescriptor<Invoice>()).first?.catalogLineSnapshots == [saved])
        }
    }

    @Test func jobMaterialRequirementsSumRepeatedSoldMembersOnceAndKeepStockCost() throws {
        let items = try catalog()
        items[2].tracksInventory = true
        let saved = try CatalogBundlePolicy.resized(select(items), quantity: 2)
        let customer = Customer(name: "Fixture")
        let call = ServiceCall(type: .repair, scheduledDate: Date(), customer: customer)
        let invoice = Invoice(serviceCallID: call.id, customer: customer,
            lineItemSummary: saved.customerSummary, catalogSnapshotJSON: try json(saved), amount: 378)
        let requirements = JobMaterialCloseoutPolicy.requirements(for: call, invoice: invoice,
            estimates: [], projectMilestones: [], items: items, movements: [])
        #expect(requirements.count == 1)
        #expect(requirements.first?.quantity == 4)
        #expect(saved.soldLeaves.reduce(0) { $0 + ($1.purchaseCost ?? 0) * $1.quantity } == 160)
    }

    @Test func actualSharedWorkflowPublishesInvoiceAndEstimateAndRecoversLostReplyWithoutDuplicate() async throws {
        for estimate in [false, true] {
            let f = try BillingNativeWorkflowTests.Fixture()
            let scope = QuickBooksChangeHistoryScope(companyID: f.company, realmID: "billing-realm", environment: Config.QuickBooks.environment)
            let items = try CatalogBundleFixture.makeCatalog(scope: scope)
            for item in items { f.app.context.insert(item) }
            let saved = try CatalogBundlePolicy.resolve(root: items[3], catalog: items, scope: scope)
            f.app.invoice.catalogSnapshotJSON = try json(saved); f.app.invoice.amount = 189
            f.app.estimate.catalogSnapshotJSON = try json(saved); f.app.estimate.amount = 189
            try f.app.context.save()
            f.failReply = true
            let first = try f.flow(estimate: estimate)
            await #expect(throws: (any Error).self) { try await first.execute() }
            f.finish(first)
            #expect(f.writes == 1 && f.request?.document.Line.first?.GroupLineDetail?.Line.count == 2)
            items[2].unitPrice = 700; try f.app.context.save()
            f.failReply = false
            let second = try f.flow(estimate: estimate)
            let outcome = try await second.execute()
            #expect(outcome.recovered && f.writes == 1 && f.app.requests.isEmpty)
            #expect(f.request?.document.Line.first?.GroupLineDetail?.Line.map { $0.SalesItemLineDetail.UnitPrice } == [94.5, 94.5])
            f.finish(second)
        }
    }

    @Test(arguments: [false, true])
    func actualProfitabilityReportsUseSavedMemberCostsAndDiscloseMissingCoverage(_ missingCost: Bool) throws {
        let items = try CatalogBundleFixture.makeCatalog(overrides: missingCost
            ? ["BC-L1": ["PurchaseCost": NSNull()]] : [:])
        let saved = try CatalogBundlePolicy.resized(select(items), quantity: 2)
        let now = Date(), customer = Customer(name: "Report fixture")
        let call = ServiceCall(type: .repair, scheduledDate: now, customer: customer)
        let invoice = Invoice(serviceCallID: call.id, customer: customer,
            lineItemSummary: saved.customerSummary, catalogSnapshotJSON: try json(saved), amount: 378, createdAt: now)
        items[2].purchaseCost = 900
        let report = BusinessReporting.snapshot(period: .currentMonth, now: now,
            serviceCalls: [call], estimates: [], invoices: [invoice], payments: [], timeEntries: [], technicians: [])
        let job = try #require(report.jobProfitabilityRows.first)
        #expect(report.invoicedRevenue == 378 && report.collectedRevenue == 0)
        #expect(report.materialCost == (missingCost ? 0 : 160))
        #expect(job.materialCost == report.materialCost)
        #expect(report.missingMaterialCostLineCount == (missingCost ? 2 : 0))
        #expect(job.missingMaterialCostLineCount == report.missingMaterialCostLineCount)
        #expect(job.needsCostReview && job.knownGrossProfit == nil)
        #expect(report.knownGrossProfit == nil) // No labor evidence; do not advertise a complete margin.
    }

    @Test func differentOriginalCompanyStopsBeforeAnyProviderOrCatalogRequest() throws {
        let f = try BillingNativeWorkflowTests.Fixture(), items = try catalog()
        for item in items { f.app.context.insert(item) }
        f.app.invoice.catalogSnapshotJSON = try json(select(items)); f.app.invoice.amount = 189
        try f.app.context.save()
        #expect(throws: CatalogBundleError.originalBusiness) { try f.flow() }
        #expect(f.calls.isEmpty && f.app.requests.isEmpty && f.writes == 0)
    }
}
