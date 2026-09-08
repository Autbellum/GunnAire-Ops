import Foundation

enum QuickBooksInventoryError: LocalizedError, Equatable {
    case setupRequired, originalBusinessRequired, invalidStock, lifecycleReview, unsupportedType

    var errorDescription: String? {
        switch self {
        case .setupRequired: "Open the item's Inventory Setup. Review the opening quantity, date and three accounting accounts before publishing. Your draft is saved."
        case .originalBusinessRequired: "Inventory accounts belong to a different business or QuickBooks connection. Review and select the accounts for the original business before publishing."
        case .invalidStock: "QuickBooks returned incomplete inventory information. Keep the saved item and refresh or review its inventory details."
        case .lifecycleReview: "Inventory activation and stock changes require a separate accounting review in QuickBooks. A price edit cannot change stock or activation."
        case .unsupportedType: "This catalog record is a category, bundle or unrecognized type. It cannot be published as an ordinary product or service."
        }
    }
}

/// A draft may be incomplete offline. Publication requires all explicit fields
/// and the same business/realm/environment; no default service account is used.
struct QuickBooksInventorySetup: Codable, Equatable {
    var scope: QuickBooksChangeHistoryScope?
    var openingQuantity: Double?
    var openingDate: String?
    var assetAccount: QuickBooksReference?
    var incomeAccount: QuickBooksReference?
    var expenseAccount: QuickBooksReference?

    func validate(scope expected: QuickBooksChangeHistoryScope) throws {
        try expected.validate()
        guard scope == expected else { throw QuickBooksInventoryError.originalBusinessRequired }
        guard let openingQuantity, openingQuantity.isFinite, openingQuantity >= 0,
              openingQuantity <= 99_999_999_999, Self.validDate(openingDate),
              [assetAccount, incomeAccount, expenseAccount].allSatisfy({
                  $0.map { QuickBooksChangeHistoryScope.validReference($0.value) } == true
              }) else { throw QuickBooksInventoryError.setupRequired }
    }

    static func validDate(_ value: String?) -> Bool {
        guard let value, value.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z"#,
            options: .regularExpression) != nil else { return false }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, parts[0] >= 1 else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: components) else { return false }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        return actual.year == parts[0] && actual.month == parts[1] && actual.day == parts[2]
    }

    enum AccountRole: String, CaseIterable, Identifiable {
        case asset = "Inventory asset", income = "Sales income", expense = "Cost of goods sold"
        var id: String { rawValue }
        func accepts(_ account: QuickBooksAccount) -> Bool {
            guard account.Active == true, QuickBooksChangeHistoryScope.validReference(account.Id) else { return false }
            switch self {
            case .asset: return account.AccountType == "Other Current Asset" && account.AccountSubType == "Inventory"
            case .income: return account.AccountType == "Income" && account.AccountSubType == "SalesOfProductIncome"
            case .expense: return account.AccountType == "Cost of Goods Sold"
            }
        }
    }
}

struct QuickBooksItemGroupDetail: Codable, Equatable {
    struct Line: Codable, Equatable {
        struct Reference: Codable, Equatable {
            let value: String
            let name: String?
            let type: String?
        }
        let Qty: Double
        let ItemRef: Reference
    }
    let ItemGroupLine: [Line]
}

/// Provider evidence, not an editable stock count and not an invoice price.
struct QuickBooksCatalogDetails: Codable, Equatable {
    let quantityOnHand: Double?
    let inventoryStartDate: String?
    let tracksQuantity: Bool?
    let assetAccount: QuickBooksReference?
    let incomeAccount: QuickBooksReference?
    let expenseAccount: QuickBooksReference?
    let parent: QuickBooksReference?
    let fullyQualifiedName: String?
    let level: Int?
    let group: QuickBooksItemGroupDetail?
    let printGroupedItems: Bool?

    init(_ record: QuickBooksItem) {
        quantityOnHand = record.QtyOnHand; inventoryStartDate = record.InvStartDate
        tracksQuantity = record.TrackQtyOnHand; assetAccount = record.AssetAccountRef
        incomeAccount = record.IncomeAccountRef; expenseAccount = record.ExpenseAccountRef
        parent = record.ParentRef; fullyQualifiedName = record.FullyQualifiedName; level = record.Level
        group = record.ItemGroupDetail; printGroupedItems = record.PrintGroupedItems
    }

    func validateInventory() throws {
        guard let quantityOnHand, quantityOnHand.isFinite, abs(quantityOnHand) <= 99_999_999_999,
              tracksQuantity == true, QuickBooksInventorySetup.validDate(inventoryStartDate),
              [assetAccount, incomeAccount, expenseAccount].allSatisfy({
                  $0.map { QuickBooksChangeHistoryScope.validReference($0.value) } == true
              }) else { throw QuickBooksInventoryError.invalidStock }
    }
}

enum QuickBooksCatalogJSON {
    static func encode<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }
    static func decode<T: Decodable>(_ type: T.Type, _ json: String?) -> T? {
        guard let json, json.utf8.count <= 262_144 else { return nil }
        return try? JSONDecoder().decode(type, from: Data(json.utf8))
    }
}

@MainActor extension Item {
    var inventorySetup: QuickBooksInventorySetup? {
        get { QuickBooksCatalogJSON.decode(QuickBooksInventorySetup.self, quickBooksInventorySetupJSON) }
        set { quickBooksInventorySetupJSON = newValue.flatMap(QuickBooksCatalogJSON.encode) }
    }
    var catalogDetails: QuickBooksCatalogDetails? {
        QuickBooksCatalogJSON.decode(QuickBooksCatalogDetails.self, quickBooksCatalogDetailsJSON)
    }
}
