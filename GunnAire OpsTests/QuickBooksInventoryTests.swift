import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor
struct QuickBooksInventoryTests {
    private let company = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private var scope: QuickBooksChangeHistoryScope {
        .init(companyID: company, realmID: "inventory-fixture", environment: Config.QuickBooks.environment)
    }
    private var setup: QuickBooksInventorySetup {
        .init(scope: scope, openingQuantity: 4.25, openingDate: "2026-09-08",
            assetAccount: .init(value: "ASSET", name: "Inventory Asset"),
            incomeAccount: .init(value: "SALES", name: "Product Income"),
            expenseAccount: .init(value: "COGS", name: "Cost of Goods Sold"))
    }
    private func item(linked: Bool = false) -> Item {
        let item = Item(quickBooksID: linked ? "I-42" : nil, name: "Capacitor", itemType: .inventory,
                        unitPrice: 125.375, purchaseCost: 19.125, isTaxable: true)
        item.inventorySetup = setup
        return item
    }
    private func remote(quantity: Double = 4.25) throws -> QuickBooksItem {
        let object: [String: Any] = ["Id": "I-42", "SyncToken": "2", "Name": "Capacitor",
            "Type": "Inventory", "UnitPrice": 125.375, "PurchaseCost": 19.125, "Taxable": true,
            "Active": true, "QtyOnHand": quantity, "InvStartDate": "2026-09-08", "TrackQtyOnHand": true,
            "AssetAccountRef": ["value": "ASSET"], "IncomeAccountRef": ["value": "SALES"],
            "ExpenseAccountRef": ["value": "COGS"], "ParentRef": ["value": "P-1", "name": "Electrical"],
            "FullyQualifiedName": "Parts:Electrical:Capacitor", "Level": 2]
        return try JSONDecoder().decode(QuickBooksItem.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func context(_ item: Item) throws -> ModelContext {
        let schema = GunnAireModelSchema.schema
        let context = ModelContext(try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]))
        context.autosaveEnabled = false; context.insert(item); try context.save()
        return context
    }
    private func response(_ itemID: UUID, quantity: Double = 4.25, created: Bool = true) throws -> CatalogPublicationResponse {
        .init(publication: .init(id: UUID(), companyID: company, realmID: scope.realmID,
            environment: scope.environment, localItemID: itemID, operation: "create",
            state: "confirmed", providerID: "I-42", updatedAt: "2026-09-08T00:00:00Z"),
            item: try remote(quantity: quantity), created: created)
    }
    private func api(_ publisher: @escaping CatalogPublicationBoundary.Transport) -> QuickBooksDataAPI {
        .init(testTokens: .init(accessToken: "inventory-fixture", expiration: .distantFuture),
            realmID: scope.realmID, environment: scope.environment, catalogCompanyID: company,
            catalogPublisher: publisher, transport: { _ in
                Issue.record("Inventory used a direct provider write"); throw CatalogPublicationError.unavailable
            })
    }
    private func flow(_ item: Item, _ context: ModelContext, _ api: QuickBooksDataAPI,
                      save: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws -> QuickBooksCatalogWorkflow {
        try .init(item: item, context: context, api: api, lifecycle: QuickBooksSyncLifecycle(),
                  mode: .publish, validateAccess: {}, save: save)
    }

    @Test func inventoryUsesPerItemAccountsWithoutGlobalServiceDefaults() async throws {
        let item = item(), context = try context(item)
        var calls = 0
        let api = api { request in
            calls += 1
            #expect(request.companyID == company && request.localItemID == item.id)
            guard case .create(let payload) = request.item else { throw CatalogPublicationError.invalidProposal }
            #expect(payload.ItemType == "Inventory" && payload.QtyOnHand == 4.25)
            #expect(payload.InvStartDate == "2026-09-08" && payload.TrackQtyOnHand == true)
            #expect(payload.IncomeAccountRef?.value == "SALES" && payload.AssetAccountRef?.value == "ASSET")
            #expect(payload.ExpenseAccountRef?.value == "COGS" && payload.UnitPrice == 125.375)
            return try response(item.id)
        }
        let workflow = try flow(item, context, api)
        let result = try await workflow.execute()
        #expect(result.created && calls == 1 && item.quickBooksID == "I-42")
        #expect(item.catalogDetails?.quantityOnHand == 4.25 && item.inventorySetup == setup)
        #expect(item.quickBooksSyncStatus == "synced")
    }

    @Test func incompleteAndWrongBusinessSetupsNeverDispatch() async throws {
        for mode in 0..<6 {
            let item = item()
            var changed = setup
            if mode == 0 { item.inventorySetup = nil }
            else {
                if mode == 1 { changed.openingDate = "2026-02-30" }
                if mode == 2 { changed.assetAccount = nil }
                if mode == 3 { changed.scope = .init(companyID: UUID(), realmID: scope.realmID, environment: scope.environment) }
                if mode == 4 { changed.scope = .init(companyID: company, realmID: "other", environment: scope.environment) }
                if mode == 5 { changed.scope = .init(companyID: company, realmID: scope.realmID, environment: scope.environment == "sandbox" ? "production" : "sandbox") }
                item.inventorySetup = changed
            }
            let context = try context(item)
            let api = api { _ in Issue.record("Invalid setup dispatched"); throw CatalogPublicationError.invalidProposal }
            do { _ = try await flow(item, context, api).execute(); Issue.record("Invalid setup accepted") }
            catch { #expect(error is QuickBooksInventoryError) }
            #expect(item.quickBooksID == nil)
        }
    }

    @Test func datesAndOpeningQuantitiesAreStrictWithoutRounding() throws {
        for date in ["2024-02-29", "2026-09-08", "2000-02-29"] { #expect(QuickBooksInventorySetup.validDate(date)) }
        for date in ["2026-02-29", "2026-02-30", "1900-02-29", "2026-13-01", "0000-01-01", "2026-1-01", "2026-01-01T00:00:00Z"] {
            #expect(!QuickBooksInventorySetup.validDate(date))
        }
        for value in [Double.nan, .infinity, -1, 100_000_000_000] {
            var draft = setup; draft.openingQuantity = value
            #expect(throws: QuickBooksInventoryError.self) { try draft.validate(scope: scope) }
        }
        for value in [0, 0.001, 99_999_999_999] {
            var draft = setup; draft.openingQuantity = value
            try draft.validate(scope: scope)
        }
    }

    @Test func quantityDraftKeepsIntermediateTextAndDoesNotMutateSavedSetup() throws {
        let original = setup
        var draft = QuickBooksInventoryQuantityDraft(original.openingQuantity, locale: Locale(identifier: "en_US"))
        #expect(draft.text == "4.25")
        for text in ["6", "6.", "6.5", "6.500"] {
            draft.text = text
            let proposed = try #require(draft.applying(to: original))
            #expect(draft.text == text)
            #expect(proposed.openingQuantity == Double(text))
            #expect(proposed.scope == original.scope && proposed.openingDate == original.openingDate)
            #expect(proposed.assetAccount == original.assetAccount && proposed.incomeAccount == original.incomeAccount)
            #expect(proposed.expenseAccount == original.expenseAccount && original.openingQuantity == 4.25)
        }
    }

    @Test func invalidQuantityDraftNeverFallsBackToPriorValue() {
        for text in [".", "-", "-1", "nan", "inf", "1e999", "100000000000", "6..5", "6,5", "1,234", "$6.5", "6 5", "0x1p2"] {
            var draft = QuickBooksInventoryQuantityDraft(4.25, locale: Locale(identifier: "en_US"))
            draft.text = text
            #expect(!draft.isValid && draft.applying(to: setup) == nil)
            #expect(draft.text == text && setup.openingQuantity == 4.25)
        }
    }

    @Test func blankQuantityRemainsAnIncompleteOfflineDraftNotZero() throws {
        for text in ["", " \n "] {
            var draft = QuickBooksInventoryQuantityDraft(4.25)
            draft.text = text
            let proposed = try #require(draft.applying(to: setup))
            #expect(draft.isValid && proposed.openingQuantity == nil)
            #expect(proposed.openingDate == setup.openingDate && proposed.scope == setup.scope)
            #expect(throws: QuickBooksInventoryError.self) { try proposed.validate(scope: scope) }
        }
    }

    @Test func quantityDraftUsesLocaleDecimalSeparatorWithoutStrippingGrouping() throws {
        var draft = QuickBooksInventoryQuantityDraft(4.25, locale: Locale(identifier: "fr_FR"))
        #expect(draft.text == "4,25")
        draft.text = "6,500"
        #expect(try #require(draft.applying(to: setup)).openingQuantity == 6.5)
        #expect(draft.text == "6,500")
        for invalid in ["1.234,5", "1 234,5", "6,5,0"] {
            draft.text = invalid
            #expect(!draft.isValid)
        }
    }

    @Test func quantityDraftReopensWithoutPrecisionLossAndSavesTheProposedSetup() throws {
        let item = item(), context = try context(item)
        for quantity in [0.0, 0.0000001, 4.25123456789, 6.5, 99_999_999_999.0] {
            let draft = QuickBooksInventoryQuantityDraft(quantity, locale: Locale(identifier: "en_US"))
            let proposed = try #require(draft.applying(to: setup))
            #expect(proposed.openingQuantity == quantity)
            item.inventorySetup = proposed
            try context.save()
            #expect(item.inventorySetup == proposed)
            #expect(item.unitPrice == 125.375 && item.purchaseCost == 19.125)
            #expect(item.quickBooksID == nil)
        }
    }

    @Test func accountChoicesUseProviderTypesAndActiveIdentity() {
        func account(_ type: String, _ subtype: String?, active: Bool = true) -> QuickBooksAccount {
            .init(Id: "A-1", Name: "Fixture", FullyQualifiedName: nil, AccountType: type,
                  AccountSubType: subtype, Classification: nil, Active: active)
        }
        #expect(QuickBooksInventorySetup.AccountRole.asset.accepts(account("Other Current Asset", "Inventory")))
        #expect(!QuickBooksInventorySetup.AccountRole.asset.accepts(account("OtherCurrentAsset", "Inventory")))
        #expect(!QuickBooksInventorySetup.AccountRole.asset.accepts(account("Other Current Asset", "Inventory", active: false)))
        #expect(QuickBooksInventorySetup.AccountRole.income.accepts(account("Income", "SalesOfProductIncome")))
        #expect(!QuickBooksInventorySetup.AccountRole.income.accepts(account("Income", "ServiceFeeIncome")))
        #expect(QuickBooksInventorySetup.AccountRole.expense.accepts(account("Cost of Goods Sold", "SuppliesMaterialsCogs")))
        #expect(!QuickBooksInventorySetup.AccountRole.expense.accepts(account("Expense", nil)))
    }

    @Test func existingLinkKeepsCurrentNegativeStockInsteadOfOpeningProposal() async throws {
        let item = item(), context = try context(item)
        let result = try await flow(item, context, api { _ in try response(item.id, quantity: -2.5, created: false) }).execute()
        #expect(!result.created && item.catalogDetails?.quantityOnHand == -2.5)
        #expect(item.inventorySetup?.openingQuantity == 4.25 && !item.tracksInventory)
        #expect(item.catalogDetails?.parent?.value == "P-1")
    }

    @Test func setupEditsDuringPublicationCannotBeOverwritten() async throws {
        let item = item(), context = try context(item)
        let api = api { _ in
            var edited = setup; edited.openingQuantity = 8.5; item.inventorySetup = edited
            return try response(item.id)
        }
        do { _ = try await flow(item, context, api).execute(); Issue.record("Edited setup overwritten") }
        catch { #expect(error as? QuickBooksCatalogWorkflowError == .itemChanged) }
        #expect(item.inventorySetup?.openingQuantity == 8.5 && item.quickBooksID == nil)
    }

    @Test func failedSaveRestoresProviderDetailsAndOriginalDraft() async throws {
        let item = item(), context = try context(item)
        item.quickBooksCatalogDetailsJSON = "prior-details"; item.quickBooksCatalogReceiptJSON = "prior-receipt"
        try context.save()
        let api = api { _ in try response(item.id) }
        do {
            _ = try await flow(item, context, api, save: { _ in throw CatalogPublicationError.unavailable }).execute()
            Issue.record("Save failure ignored")
        } catch { #expect(error as? QuickBooksCatalogWorkflowError == .saveFailed) }
        #expect(item.quickBooksID == nil && item.quickBooksCatalogDetailsJSON == "prior-details")
        #expect(item.quickBooksCatalogReceiptJSON == "prior-receipt" && item.inventorySetup == setup)
    }

    @Test func inventoryPriceUpdateHasImmutableTypeButNoStockDateOrAccounts() throws {
        let item = item(linked: true), remote = try remote(quantity: -1)
        item.unitPrice = 140.875
        let payload = try QuickBooksCatalogReconciliation.updatePayload(localItem: item, currentRemoteItem: remote)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        #expect(json["Type"] as? String == "Inventory" && json["UnitPrice"] as? Double == 140.875)
        #expect(json["SyncToken"] as? String == "2" && json["sparse"] as? Bool == true)
        for key in ["QtyOnHand", "InvStartDate", "TrackQtyOnHand", "AssetAccountRef", "IncomeAccountRef", "ExpenseAccountRef"] {
            #expect(json[key] == nil)
        }
        item.archiveFromPricebook(by: "fixture@example.invalid")
        #expect(throws: QuickBooksInventoryError.lifecycleReview) {
            try QuickBooksCatalogReconciliation.updatePayload(localItem: item, currentRemoteItem: remote)
        }
    }

    @Test func savedInvoiceKeepsTypeIdentityAndPriceAcrossRefreshAndQuantityEdits() throws {
        let item = item(linked: true), snapshot = CatalogLineItemSnapshot(item: item, quantity: 2)
        QuickBooksCatalogSnapshotApplication.apply(try remote(), to: item)
        item.unitPrice = 999
        let revised = snapshot.replacingQuantity(with: 3)
        #expect(revised.itemTypeRawValue == "Inventory" && revised.quickBooksItemID == "I-42")
        #expect(revised.unitPrice == 125.375)
        let json = try #require(CatalogLineItemSnapshot.encoded(snapshots: [revised]))
        let lines = try QuickBooksDocumentLinePublication.lines(snapshotJSON: json, expectedSubtotal: 376.125, catalogItems: [item])
        #expect(lines.first?.SalesItemLineDetail.ItemRef.value == "I-42")
        item.quickBooksID = "another"
        #expect(throws: QuickBooksDocumentLinePublicationError.catalogIdentityChanged(item.name)) {
            try QuickBooksDocumentLinePublication.lines(snapshotJSON: json, expectedSubtotal: 376.125, catalogItems: [item])
        }
        item.quickBooksID = "I-42"; item.itemType = .nonInventory
        #expect(throws: QuickBooksDocumentLinePublicationError.catalogIdentityChanged(item.name)) {
            try QuickBooksDocumentLinePublication.lines(snapshotJSON: json, expectedSubtotal: 376.125, catalogItems: [item])
        }
    }

    @Test func offlineFirstLinkAndLegacySnapshotsRemainPublishableAfterApproval() throws {
        let item = item(), snapshot = CatalogLineItemSnapshot(item: item)
        item.quickBooksID = "I-42"
        let json = try #require(CatalogLineItemSnapshot.encoded(snapshots: [snapshot]))
        #expect(try QuickBooksDocumentLinePublication.lines(snapshotJSON: json, expectedSubtotal: 125.375, catalogItems: [item]).count == 1)
        var rows = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        rows[0].removeValue(forKey: "itemTypeRawValue"); rows[0].removeValue(forKey: "quickBooksItemID")
        let legacy = String(decoding: try JSONSerialization.data(withJSONObject: rows), as: UTF8.self)
        #expect(try QuickBooksDocumentLinePublication.lines(snapshotJSON: legacy, expectedSubtotal: 125.375, catalogItems: [item]).count == 1)
    }

    @Test func unknownCategoriesAndBundlesAreNeverInventedAsZeroPriceServices() throws {
        for type in ["Category", "Group", "FutureType", ""] {
            let item = item(linked: true); item.itemTypeRawValue = type
            #expect(item.itemType != .service && !item.itemType.isDirectSalesItem)
            #expect(!CatalogItemSelectionPolicy.canAdd(item, documentScopedReviewItemIDs: [item.id]))
            let json = try #require(CatalogLineItemSnapshot.encoded(from: [item]))
            #expect(throws: QuickBooksDocumentLinePublicationError.unsupportedItemType(item.name)) {
                try QuickBooksDocumentLinePublication.lines(snapshotJSON: json, expectedSubtotal: 125.375, catalogItems: [item])
            }
        }
        #expect(CatalogItemType.creatableCases == [.service, .nonInventory, .inventory])
        let fieldItem = item(); fieldItem.pricebookReviewStatus = .needsReview
        #expect(CatalogItemSelectionPolicy.canAdd(fieldItem, documentScopedReviewItemIDs: [fieldItem.id]))
        #expect(!CatalogItemSelectionPolicy.canAdd(fieldItem, documentScopedReviewItemIDs: []))
    }

    @Test func inventoryDraftAndProviderDetailsSurviveARealSQLiteReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("InventoryDraft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema([Item.self]), url = directory.appendingPathComponent("Inventory.store")
        let saved = item(), identity = saved.id, draft = setup
        let details = QuickBooksCatalogJSON.encode(QuickBooksCatalogDetails(try remote(quantity: -3.25)))
        try autoreleasepool {
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration("Inventory", schema: schema, url: url, cloudKitDatabase: .none)])
            saved.quickBooksCatalogDetailsJSON = details
            container.mainContext.insert(saved); try container.mainContext.save()
        }
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration("Inventory", schema: schema, url: url, cloudKitDatabase: .none)])
        let reopened = try #require(container.mainContext.fetch(FetchDescriptor<Item>()).first)
        #expect(reopened.id == identity && reopened.inventorySetup == draft)
        #expect(reopened.quickBooksCatalogDetailsJSON == details && reopened.catalogDetails?.quantityOnHand == -3.25)
    }

    @Test func v24SQLiteMigrationPreservesExistingReceiptAndPendingWork() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("InventoryMigration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Inventory.store"), identity = UUID()
        let savedReceipt = #"{"projectionVersion":1,"retained":"existing receipt bytes"}"#
        try autoreleasepool {
            let schema = Schema([PreInventoryCatalogSchema.Item.self])
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration("Inventory", schema: schema, url: url, cloudKitDatabase: .none)])
            let old = PreInventoryCatalogSchema.Item()
            old.id = identity; old.name = "Saved capacitor"; old.itemTypeRawValue = "Inventory"
            old.quickBooksID = "I-42"; old.unitPrice = 125.375; old.quickBooksSyncStatus = "pending_update"
            old.quickBooksCatalogReceiptJSON = savedReceipt; old.defaultInventoryLocation = "Truck 1"
            container.mainContext.insert(old); try container.mainContext.save()
        }
        let schema = Schema([Item.self])
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration("Inventory", schema: schema, url: url, cloudKitDatabase: .none)])
        let migrated = try #require(container.mainContext.fetch(FetchDescriptor<Item>()).first)
        #expect(migrated.id == identity && migrated.unitPrice == 125.375 && migrated.itemType == .inventory)
        #expect(migrated.quickBooksCatalogReceiptJSON == savedReceipt && migrated.hasPendingQuickBooksCatalogUpdate)
        #expect(migrated.quickBooksID == "I-42" && migrated.defaultInventoryLocation == "Truck 1")
        #expect(migrated.quickBooksInventorySetupJSON == nil && migrated.quickBooksCatalogDetailsJSON == nil)
    }

    @Test func providerBundleDetailsKeepRepeatedComponentsAndTheirActualTypes() throws {
        let json = #"{"Id":"B1","Name":"Repair kit","Type":"Group","ItemGroupDetail":{"ItemGroupLine":[{"Qty":2,"ItemRef":{"value":"I1","type":"Inventory"}},{"Qty":3,"ItemRef":{"value":"I1","type":"Inventory"}}]},"PrintGroupedItems":true}"#
        let remote = try JSONDecoder().decode(QuickBooksItem.self, from: Data(json.utf8))
        let local = Item(name: "old", unitPrice: 99)
        QuickBooksCatalogSnapshotApplication.apply(remote, to: local)
        #expect(local.itemType == .group && local.catalogDetails?.group?.ItemGroupLine.count == 2)
        #expect(local.catalogDetails?.group?.ItemGroupLine.last?.Qty == 3)
        #expect(local.catalogDetails?.group?.ItemGroupLine.first?.ItemRef.type == "Inventory")
        #expect(local.catalogDetails?.printGroupedItems == true)
    }
}

/// Exact Item attributes at 89c6ee7 / CloudKit v24. Keep the original entity
/// name so this tests real additive migration, not a new-schema empty row.
private enum PreInventoryCatalogSchema {
    @Model final class Item {
        var id: UUID = UUID()
        var quickBooksID: String?
        var quickBooksSyncStatus: String = "pending"
        var quickBooksSyncDetail: String?
        var quickBooksLastSyncedAt: Date?
        var quickBooksCatalogReceiptJSON: String?
        var pricebookReviewStatusRawValue: String?
        var pricebookCreatedByEmail: String?
        var pricebookReviewedByEmail: String?
        var pricebookReviewedAt: Date?
        var name: String = ""
        var itemTypeRawValue: String = "Service"
        var unitPrice: Double = 0
        var purchaseCost: Double?
        var isTaxable: Bool = false
        var itemDescription: String?
        var sku: String?
        var preferredVendorName: String?
        var preferredVendorQuickBooksID: String?
        var vendorPartNumber: String?
        var purchaseURL: String?
        var purchaseDescription: String?
        var tracksInventory: Bool = false
        var reorderPoint: Double?
        var defaultInventoryLocation: String?
        var flatRateAssemblyJSON: String?
        var createdAt: Date = Date()
        var timestamp: Date = Date()
        init() {}
    }
}
