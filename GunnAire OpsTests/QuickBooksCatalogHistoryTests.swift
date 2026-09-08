import Foundation
import CryptoKit
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor
struct QuickBooksCatalogHistoryTests {
    private let scope = QuickBooksChangeHistoryScope(companyID: UUID(), realmID: "fixture", environment: "sandbox")

    private func batch(_ fields: [[String: Any]] = [[:]],
                       time: String = "2026-09-08T00:00:00.000002Z",
                       scope override: QuickBooksChangeHistoryScope? = nil,
                       grant: String = String(repeating: "a", count: 64)) throws -> ([QuickBooksItem], QuickBooksCatalogHistoryBatch) {
        var records: [QuickBooksItem] = [], versions: [QuickBooksHistoryVersion] = []
        for (index, fields) in fields.enumerated() {
            var object: [String: Any] = ["Id": "42", "Name": "Service", "Type": "Service",
                "SyncToken": "2", "MetaData": ["LastUpdatedTime": time], "UnitPrice": 150,
                "Active": true, "Taxable": true]
            object.merge(fields) { _, new in new }
            let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            records.append(try JSONDecoder().decode(QuickBooksItem.self, from: bytes))
            versions.append(.init(sequence: index + 1, entityID: object["Id"] as! String, updatedAt: time,
                status: "present", recordJSON: String(decoding: bytes, as: UTF8.self),
                payloadSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()))
        }
        return (records, try .init(scope: override ?? scope, connectionRevision: grant, versions: versions))
    }

    private func context() throws -> ModelContext {
        let schema = GunnAireModelSchema.schema
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private func apply(_ batch: ([QuickBooksItem], QuickBooksCatalogHistoryBatch), into context: ModelContext,
                       save: (ModelContext) throws -> Void = { try $0.save() }) throws {
        try QuickBooksLocalSync.importSnapshot(customers: [], items: batch.0, estimates: [],
            invoices: [], payments: [], vendors: [], into: context, catalogHistory: batch.1, saveSnapshot: save)
    }

    @Test func savesDatedProjectionAndReceiptTogetherWithoutChangingSoldPricesOrStock() throws {
        let context = try context()
        let item = Item(quickBooksID: "42", name: "Old label", unitPrice: 80, purchaseCost: 20,
            itemDescription: "old", sku: "old", preferredVendorName: "old", preferredVendorQuickBooksID: "old",
            vendorPartNumber: "P-42", tracksInventory: true, reorderPoint: 4, defaultInventoryLocation: "Truck 1")
        context.insert(item)
        let customer = Customer(name: "Fixture")
        context.insert(customer)
        let sold = try #require(CatalogLineItemSnapshot.encoded(from: [item]))
        let invoice = Invoice(customer: customer, catalogSnapshotJSON: sold, amount: 80)
        context.insert(invoice); try context.save()
        let incoming = try batch()
        try apply(incoming, into: context)
        let receipt = try QuickBooksCatalogApplicationReceipt.decode(#require(item.quickBooksCatalogReceiptJSON))
        #expect(try receipt.source == incoming.1.version(for: incoming.0[0]))
        #expect(receipt.source.updatedAt == "2026-09-08T00:00:00.000002Z")
        #expect(receipt.isCurrent(on: item, scope: scope))
        #expect(item.unitPrice == 150 && item.purchaseCost == nil && item.itemDescription == nil && item.sku == nil)
        #expect(item.preferredVendorName == nil && item.preferredVendorQuickBooksID == nil)
        #expect(item.vendorPartNumber == "P-42" && item.tracksInventory && item.reorderPoint == 4)
        #expect(item.defaultInventoryLocation == "Truck 1" && invoice.catalogSnapshotJSON == sold && invoice.amount == 80)
        let reloaded = try #require(ModelContext(context.container).fetch(FetchDescriptor<Item>()).first)
        #expect(reloaded.quickBooksCatalogReceiptJSON == item.quickBooksCatalogReceiptJSON)
        #expect(receipt.isCurrent(on: reloaded, scope: scope))
    }

    @Test func replayIsIdempotentAndNewerVersionsAdvanceWithoutArrivalOrdering() throws {
        let context = try context()
        let first = try batch()
        try apply(first, into: context)
        try apply(first, into: context)
        let newer = try batch([["UnitPrice": 175, "SyncToken": "3"]], time: "2026-09-08T00:00:00.000003Z")
        try apply(newer, into: context)
        let item = try #require(context.fetch(FetchDescriptor<Item>()).first)
        let receipt = item.quickBooksCatalogReceiptJSON
        #expect(throws: QuickBooksBillingImportReview.self) { try apply(first, into: context) }
        #expect(item.unitPrice == 175 && item.quickBooksCatalogReceiptJSON == receipt)
        #expect(item.quickBooksSyncStatus == "needs_review")
        #expect(try context.fetchCount(FetchDescriptor<Item>()) == 1)
    }

    @Test func sameTimeConflictsAndDifferentBusinessesNeverReplaceAppliedVersions() throws {
        for nextScope in [scope,
            .init(companyID: UUID(), realmID: scope.realmID, environment: scope.environment),
            .init(companyID: scope.companyID, realmID: "other", environment: scope.environment),
            .init(companyID: scope.companyID, realmID: scope.realmID, environment: "production")] {
            let context = try context()
            try apply(batch(), into: context)
            let item = try #require(context.fetch(FetchDescriptor<Item>()).first)
            let original = item.quickBooksCatalogReceiptJSON
            #expect(throws: QuickBooksBillingImportReview.self) {
                try apply(batch([["UnitPrice": 999]], scope: nextScope), into: context)
            }
            #expect(item.unitPrice == 150 && item.quickBooksCatalogReceiptJSON == original)
        }
    }

    @Test func newGrantInSameRealmRestampsButCannotRemoveTimeBarrier() throws {
        let context = try context()
        try apply(batch(), into: context)
        try apply(batch(grant: String(repeating: "b", count: 64)), into: context)
        let item = try #require(context.fetch(FetchDescriptor<Item>()).first)
        let receipt = try QuickBooksCatalogApplicationReceipt.decode(#require(item.quickBooksCatalogReceiptJSON))
        #expect(receipt.source.connectionRevision == String(repeating: "b", count: 64))
        #expect(throws: QuickBooksBillingImportReview.self) {
            try apply(batch(time: "2026-09-08T00:00:00.000001Z", grant: String(repeating: "c", count: 64)), into: context)
        }
        #expect(item.quickBooksCatalogReceiptJSON != nil && item.unitPrice == 150)
    }

    @Test func pendingAdminAndTechnicianDecisionsArePreservedEvenIfAmountsMatch() throws {
        for review in [true, false] {
            let context = try context()
            let item = Item(quickBooksID: "42", quickBooksSyncStatus: review ? "needs_review" : "pending_update",
                pricebookReviewStatus: review ? .needsReview : .approved,
                pricebookCreatedByEmail: "tech@example.invalid", name: "Service", unitPrice: 150, isTaxable: true)
            context.insert(item); try context.save()
            #expect(throws: QuickBooksBillingImportReview.self) { try apply(batch(), into: context) }
            #expect(item.quickBooksCatalogReceiptJSON == nil && item.name == "Service" && item.unitPrice == 150)
            #expect(item.pricebookCreatedByEmail == "tech@example.invalid")
            #expect(review ? item.requiresPricebookReview : item.hasPendingQuickBooksCatalogUpdate)
        }
    }

    @Test func nameOrSKUIsNotIdentityAndDoesNotApproveOrDuplicateLocalProposals() throws {
        for candidates in [1, 2] {
            let context = try context()
            for _ in 0..<candidates {
                context.insert(Item(pricebookReviewStatus: .needsReview, name: "Service", unitPrice: 321))
            }
            try context.save()
            #expect(throws: QuickBooksBillingImportReview.self) { try apply(batch(), into: context) }
            let items = try context.fetch(FetchDescriptor<Item>())
            #expect(items.count == candidates)
            #expect(items.allSatisfy { $0.quickBooksID == nil && $0.unitPrice == 321 && $0.requiresPricebookReview })
        }
    }

    @Test func malformedOrFutureReceiptsAndProjectionDriftRequireReview() throws {
        for mode in ["malformed", "future", "drift", "wrong-local-id"] {
            let context = try context()
            try apply(batch(), into: context)
            let item = try #require(context.fetch(FetchDescriptor<Item>()).first)
            if mode == "malformed" { item.quickBooksCatalogReceiptJSON = "not-json" }
            if mode == "drift" { item.unitPrice = 321 }
            if mode == "future" || mode == "wrong-local-id" {
                let json = try #require(item.quickBooksCatalogReceiptJSON)
                var object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
                if mode == "future" { object["projectionVersion"] = 3 }
                else { object["localItemID"] = UUID().uuidString }
                item.quickBooksCatalogReceiptJSON = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            }
            try context.save()
            let original = item.quickBooksCatalogReceiptJSON
            #expect(throws: QuickBooksBillingImportReview.self) {
                try apply(batch([["UnitPrice": 175]], time: "2026-09-08T00:00:00.000004Z"), into: context)
            }
            #expect(item.unitPrice == (mode == "drift" ? 321 : 150))
            #expect(item.quickBooksCatalogReceiptJSON == original)
        }
    }

    @Test func operationalOnlyEditsDoNotInvalidatePriceEvidenceButProviderFieldsDo() throws {
        let context = try context()
        try apply(batch(), into: context)
        let item = try #require(context.fetch(FetchDescriptor<Item>()).first)
        let receipt = try QuickBooksCatalogApplicationReceipt.decode(#require(item.quickBooksCatalogReceiptJSON))
        item.vendorPartNumber = "new-part"; item.defaultInventoryLocation = "Truck 2"; item.reorderPoint = 8
        #expect(receipt.isCurrent(on: item, scope: scope))
        item.itemDescription = "Local proposal"
        #expect(!receipt.isCurrent(on: item, scope: scope))
    }

    @Test func explicitCatalogReviewCanConvergeWithoutDiscardingTheOldVersionBarrier() throws {
        let context = try context()
        try apply(batch(), into: context)
        let item = try #require(context.fetch(FetchDescriptor<Item>()).first)
        let next = try batch([["UnitPrice": 175, "SyncToken": "3"]], time: "2026-09-08T00:00:00.000003Z")
        QuickBooksCatalogSnapshotApplication.apply(next.0[0], to: item)
        try context.save()
        try apply(next, into: context)
        let receipt = try QuickBooksCatalogApplicationReceipt.decode(#require(item.quickBooksCatalogReceiptJSON))
        #expect(receipt.isCurrent(on: item, scope: scope))
        #expect(receipt.source.updatedAt == "2026-09-08T00:00:00.000003Z")
    }

    @Test func inactiveItemsRetainIdentityAndHistoricalReceipt() throws {
        let context = try context()
        try apply(batch([["Active": false]]), into: context)
        let item = try #require(context.fetch(FetchDescriptor<Item>()).first)
        #expect(item.isCatalogArchived && item.quickBooksID == "42")
        let receipt = try QuickBooksCatalogApplicationReceipt.decode(#require(item.quickBooksCatalogReceiptJSON))
        #expect(receipt.isCurrent(on: item, scope: scope))
    }

    @Test func failedSaveRollsBackProjectionAndReceiptWithoutLeavingAutosaveWork() throws {
        struct SaveFailure: Error {}
        let context = try context()
        try apply(batch(), into: context)
        let item = try #require(context.fetch(FetchDescriptor<Item>()).first)
        let original = item.quickBooksCatalogReceiptJSON
        context.autosaveEnabled = true
        #expect(throws: SaveFailure.self) {
            try apply(batch([["UnitPrice": 175], ["Id": "new", "Name": "New item"]],
                            time: "2026-09-08T00:00:00.000004Z"), into: context) { _ in throw SaveFailure() }
        }
        #expect(item.unitPrice == 150)
        #expect(item.quickBooksCatalogReceiptJSON == original)
        #expect(!context.hasChanges && context.autosaveEnabled)
        let fresh = ModelContext(context.container)
        #expect(try fresh.fetchCount(FetchDescriptor<Item>()) == 1)
        #expect(try fresh.fetch(FetchDescriptor<Item>()).first?.quickBooksCatalogReceiptJSON == original)
    }

    @Test func unsavedUserWorkAndMismatchedDownloadedRowsAreRejectedBeforeImport() throws {
        let context = try context()
        let item = Item(name: "Unsaved", unitPrice: 1)
        context.insert(item)
        #expect(throws: QuickBooksCatalogImportError.self) { try apply(batch(), into: context) }
        #expect(QuickBooksCatalogImportError.unsavedEdits.localizedDescription.contains("No records were imported"))
        #expect(context.hasChanges && item.modelContext != nil)
        try context.save()
        let incoming = try batch()
        let changed = try batch([["UnitPrice": 999]])
        #expect(throws: QuickBooksChangeHistoryError.self) { try apply((changed.0, incoming.1), into: context) }
        #expect(throws: QuickBooksChangeHistoryError.self) { try apply(([], incoming.1), into: context) }
        #expect(throws: QuickBooksChangeHistoryError.self) { try apply((incoming.0 + incoming.0, incoming.1), into: context) }
        #expect(try context.fetchCount(FetchDescriptor<Item>()) == 1)
        #expect(item.unitPrice == 1 && item.quickBooksCatalogReceiptJSON == nil)
    }

    @Test func duplicateLocalIdentityCannotReceiveAnApplicationReceipt() throws {
        for duplicateUUID in [true, false] {
            let context = try context()
            let first = Item(quickBooksID: "42", name: "First", unitPrice: 1)
            let second = Item(id: duplicateUUID ? first.id : UUID(), quickBooksID: duplicateUUID ? "other" : "42", name: "Second", unitPrice: 2)
            context.insert(first); context.insert(second); try context.save()
            #expect(throws: QuickBooksBillingImportReview.self) { try apply(batch(), into: context) }
            #expect(first.unitPrice == 1 && second.unitPrice == 2)
            #expect(first.quickBooksCatalogReceiptJSON == nil && second.quickBooksCatalogReceiptJSON == nil)
        }
    }

    @Test func cloudKitSeedIncludesOptionalReceiptWithoutClaimingItWasApplied() throws {
        let context = try context()
        #expect(Item(name: "Legacy", unitPrice: 0).quickBooksCatalogReceiptJSON == nil)
        try GunnAireCloudKitSchemaBootstrap.seedDevelopmentSchemaForTesting(in: context)
        let seeded = try #require(context.fetch(FetchDescriptor<Item>()).first { $0.quickBooksCatalogReceiptJSON != nil })
        #expect(throws: Error.self) { try QuickBooksCatalogApplicationReceipt.decode(#require(seeded.quickBooksCatalogReceiptJSON)) }
        #expect(GunnAireCloudKitSchemaBootstrap.schemaVersion == 27)
        #expect(seeded.quickBooksInventorySetupJSON != nil && seeded.quickBooksCatalogDetailsJSON != nil)
        let invoice = try #require(context.fetch(FetchDescriptor<Invoice>()).first { $0.quickBooksPaymentReviewJSON != nil })
        #expect(FieldPaymentReceiptReconciliation.decode(invoice.quickBooksPaymentReviewJSON) == nil)
    }

    @Test func versionOneReceiptsUpgradeWithoutLosingTimeOrLocalDetailBarriers() throws {
        for diverged in [false, true] {
            let context = try context()
            let incoming = try batch()
            try apply(incoming, into: context)
            let item = try #require(context.fetch(FetchDescriptor<Item>()).first)
            // Exact v1 wire projection: absent values are omitted, and the
            // new detail property did not exist in this encoding.
            let projection: [String: String] = ["quickBooksID": "42", "name": "Service",
                "itemType": "Service", "reviewStatus": "approved"]
            var object: [String: Any] = projection
            object["unitPrice"] = 150; object["taxable"] = true
            let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let v1 = QuickBooksCatalogApplicationReceipt(projectionVersion: 1, localItemID: item.id,
                source: try incoming.1.version(for: incoming.0[0]), projectionSHA256: digest, appliedAt: Date())
            item.quickBooksCatalogReceiptJSON = String(decoding: try JSONEncoder().encode(v1), as: UTF8.self)
            item.quickBooksCatalogDetailsJSON = diverged ? "unreviewed-details" : nil
            try context.save()
            #expect(v1.matchesProjection(of: item, scope: scope))
            if diverged {
                #expect(throws: QuickBooksBillingImportReview.self) { try apply(incoming, into: context) }
                #expect(item.quickBooksCatalogDetailsJSON == "unreviewed-details")
            } else {
                try apply(incoming, into: context)
                let v2 = try QuickBooksCatalogApplicationReceipt.decode(#require(item.quickBooksCatalogReceiptJSON))
                #expect(v2.projectionVersion == 2 && v2.isCurrent(on: item, scope: scope))
                #expect(throws: QuickBooksBillingImportReview.self) {
                    try apply(batch(time: "2026-09-08T00:00:00.000001Z"), into: context)
                }
            }
        }
    }

    @Test func versionTwoRetainsCurrentStockAndRollsBackFailedDetailApplication() throws {
        let context = try context()
        var fields: [String: Any] = ["Type": "Inventory", "QtyOnHand": -2.5, "TrackQtyOnHand": true,
            "InvStartDate": "2026-09-08", "AssetAccountRef": ["value": "A"],
            "IncomeAccountRef": ["value": "I"], "ExpenseAccountRef": ["value": "E"]]
        try apply(batch([fields]), into: context)
        let item = try #require(context.fetch(FetchDescriptor<Item>()).first)
        #expect(item.itemType == .inventory && item.catalogDetails?.quantityOnHand == -2.5)
        let originalDetails = item.quickBooksCatalogDetailsJSON
        let originalReceipt = item.quickBooksCatalogReceiptJSON
        fields["QtyOnHand"] = 30
        struct SaveFailure: Error {}
        #expect(throws: SaveFailure.self) {
            try apply(batch([fields], time: "2026-09-08T00:00:00.000003Z"), into: context) { _ in throw SaveFailure() }
        }
        #expect(item.quickBooksCatalogDetailsJSON == originalDetails && item.quickBooksCatalogReceiptJSON == originalReceipt)
        let reloaded = try #require(ModelContext(context.container).fetch(FetchDescriptor<Item>()).first)
        #expect(reloaded.catalogDetails?.quantityOnHand == -2.5)
        fields.removeValue(forKey: "AssetAccountRef")
        #expect(throws: QuickBooksInventoryError.self) { try apply(batch([fields]), into: context) }
        #expect(item.quickBooksCatalogDetailsJSON == originalDetails)
    }

    @Test func opensPreReceiptSQLiteItemStoreAndPreservesLegacyValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CatalogMigration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Catalog.store")
        let id = UUID()
        try autoreleasepool {
            let schema = Schema([PreReceiptCatalogSchema.Item.self])
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration("CatalogMigration", schema: schema, url: url, cloudKitDatabase: .none)])
            let legacy = PreReceiptCatalogSchema.Item()
            legacy.id = id; legacy.name = "Legacy furnace part"; legacy.unitPrice = 321
            legacy.quickBooksID = "42"; legacy.quickBooksSyncStatus = "pending_update"
            legacy.vendorPartNumber = "Vendor-42"; legacy.flatRateAssemblyJSON = "legacy-package"
            container.mainContext.insert(legacy)
            try container.mainContext.save()
        }
        let schema = Schema([Item.self])
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration("CatalogMigration", schema: schema, url: url, cloudKitDatabase: .none)])
        let migrated = try #require(container.mainContext.fetch(FetchDescriptor<Item>()).first)
        #expect(migrated.id == id && migrated.name == "Legacy furnace part" && migrated.unitPrice == 321)
        #expect(migrated.quickBooksID == "42" && migrated.hasPendingQuickBooksCatalogUpdate)
        #expect(migrated.vendorPartNumber == "Vendor-42" && migrated.flatRateAssemblyJSON == "legacy-package")
        #expect(migrated.quickBooksCatalogReceiptJSON == nil)
        #expect(migrated.quickBooksInventorySetupJSON == nil && migrated.quickBooksCatalogDetailsJSON == nil)
    }
}

/// Exact persisted Item attributes at 8aadb75, before the optional receipt.
/// Keep the entity's Item name so the test exercises a real SQLite lightweight
/// migration instead of seeding a new-schema row with a nil property.
private enum PreReceiptCatalogSchema {
    @Model final class Item {
        var id: UUID = UUID()
        var quickBooksID: String?
        var quickBooksSyncStatus: String = "pending"
        var quickBooksSyncDetail: String?
        var quickBooksLastSyncedAt: Date?
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
