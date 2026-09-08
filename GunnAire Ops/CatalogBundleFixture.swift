#if DEBUG
import Foundation
import CryptoKit
import SwiftData

/// Isolated catalog evidence for the actual composer. No fixture supplies a
/// live transport, alters credentials, or invents a successful provider write.
@MainActor enum CatalogBundleFixture {
    static let scope = QuickBooksChangeHistoryScope(
        companyID: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
        realmID: "bundle-composer-fixture", environment: Config.QuickBooks.environment)
    static let rootID = UUID(uuidString: "90000000-0000-4000-8000-000000000044")!
    static func makeCatalog(scope requestedScope: QuickBooksChangeHistoryScope? = nil,
                            overrides: [String: [String: Any]] = [:],
                            additionalDefinitions: [[String: Any]] = []) throws -> [Item] {
        let scope = requestedScope ?? Self.scope
        let definitions: [[String: Any]] = [
            ["Id": "BC-C1", "Name": "Repairs", "Type": "Category", "Level": 0],
            ["Id": "BC-C2", "Name": "Electrical", "Type": "Category", "Level": 1, "ParentRef": ["value": "BC-C1"]],
            ["Id": "BC-L1", "Name": "Saved diagnostic labor", "Type": "Service", "UnitPrice": 94.5,
             "PurchaseCost": 40, "Level": 2, "ParentRef": ["value": "BC-C2"]],
            ["Id": "BC-G1", "Name": "Electrical Repair Bundle", "Type": "Group",
             "PrintGroupedItems": true, "ParentRef": ["value": "BC-C2"], "Level": 2,
             "ItemGroupDetail": ["ItemGroupLine": [
                ["Qty": 1, "ItemRef": ["value": "BC-L1", "type": "Service"]],
                ["Qty": 1, "ItemRef": ["value": "BC-L1", "type": "Service"]]]]]
        ] + additionalDefinitions
        return try definitions.enumerated().map { index, fields in
            var object: [String: Any] = ["Active": true, "Taxable": false, "UnitPrice": 0,
                "SyncToken": "1", "MetaData": ["LastUpdatedTime": "2026-09-08T00:00:00.000001Z"]]
            object.merge(fields) { _, new in new }
            object.merge(overrides[fields["Id"] as! String] ?? [:]) { _, new in new }
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let record = try JSONDecoder().decode(QuickBooksItem.self, from: data)
            let version = QuickBooksHistoryVersion(sequence: index + 1, entityID: record.Id,
                updatedAt: "2026-09-08T00:00:00.000001Z", status: "present",
                recordJSON: String(decoding: data, as: UTF8.self),
                payloadSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            let batch = try QuickBooksCatalogHistoryBatch(scope: scope,
                connectionRevision: String(repeating: "b", count: 64), versions: [version])
            let item = Item(id: index == 3 ? rootID : UUID(), name: record.Name, unitPrice: 0)
            try QuickBooksCatalogApplicationReceipt.apply(record, version: batch.version(for: record), to: item)
            return item
        }
    }
    static func seed(_ context: ModelContext) throws {
        guard GunnAireCloudKit.usesTestDatabase,
              ProcessInfo.processInfo.arguments.contains("-uiTestBundleComposer") else { return }
        for item in try context.fetch(FetchDescriptor<Item>()) where item.quickBooksID?.hasPrefix("BC-") == true {
            context.delete(item)
        }
        for item in try makeCatalog() { context.insert(item) }
    }
}
#endif
