import Foundation

/// Strict saved-document input, separate from the lossless historical display
/// decoder. Validation never rewrites the saved JSON, fetches current prices,
/// authorizes an adjustment, or publishes accounting data.
enum CatalogSnapshotPayload {
    enum Invalid: LocalizedError, Equatable {
        case evidence
        var errorDescription: String? {
            "The saved line-item details need review before this document can be changed, approved, or published. The original document has been kept."
        }
    }
    struct Snapshot {
        let lines: [CatalogLineItemSnapshot]
        let discount: AuthorizedDocumentDiscount?
        let taxAddresses: BillingTaxAddressContext?
    }
    private struct Envelope: Decodable {
        let version: Int
        let lines: [CatalogLineItemSnapshot]
        let documentDiscount: AuthorizedDocumentDiscount?
        let taxAddresses: BillingTaxAddressContext?
    }
    private typealias JSON = FieldFormJSON

    static func read(_ text: String?) throws -> Snapshot? {
        guard let text else { return nil } // Absent legacy/manual document, not corrupt JSON.
        do {
            let json = try JSON.parse(text, maximumNodes: 100_000)
            try validateAtoms(json)
            let rows: [JSON]
            let result: Snapshot
            switch json {
            case .array(let values):
                rows = values
                result = Snapshot(lines: try JSONDecoder().decode([CatalogLineItemSnapshot].self, from: Data(text.utf8)), discount: nil, taxAddresses: nil)
            case .object:
                let fields = try object(json, required: ["version", "lines"], optional: ["documentDiscount", "taxAddresses"])
                guard case .number("1") = fields["version"]! else { throw Invalid.evidence }
                rows = try fields["lines"]!.array()
                if let discount = present(fields["documentDiscount"]) {
                    _ = try object(discount, required: ["kind", "value", "grossSubtotalAtAuthorization", "reason", "authorizedByEmail", "authorizedAt"])
                }
                if let addresses = present(fields["taxAddresses"]) {
                    let address = try object(addresses, required: ["version", "scope", "service", "origin", "reviewedAt"])
                    guard case .number("1") = address["version"]! else { throw Invalid.evidence }
                    _ = try object(address["scope"]!, required: ["customerID"], optional: ["serviceLocationID", "siteAddress"])
                    for key in ["service", "origin"] {
                        _ = try object(address[key]!, required: ["Line1", "City", "CountrySubDivisionCode", "PostalCode", "Country"])
                    }
                }
                let value = try JSONDecoder().decode(Envelope.self, from: Data(text.utf8))
                result = Snapshot(lines: value.lines, discount: value.documentDiscount, taxAddresses: value.taxAddresses)
            default: throw Invalid.evidence
            }
            guard rows.count <= 750 else { throw Invalid.evidence }
            var soldCount = 0
            for row in rows { try line(row, member: false, count: &soldCount) }
            guard Set(result.lines.map(\.catalogItemID)).count == result.lines.count else { throw Invalid.evidence }
            return result
        } catch { throw Invalid.evidence }
    }

    static func reviewMessage(_ text: String?) -> String? {
        do { _ = try read(text); return nil }
        catch { return Invalid.evidence.localizedDescription }
    }

    /// Full-domain preparation needs business-valid saved evidence in addition
    /// to a decodable wire shape. Current catalog prices/roles are deliberately
    /// not used to reinterpret the original sale or its historical approver.
    static func validateBusinessEvidence(_ snapshot: Snapshot) throws {
        guard !snapshot.lines.isEmpty else { throw Invalid.evidence }
        if let addresses = snapshot.taxAddresses { try addresses.validate(for: addresses.scope) }
        var gross = Decimal.zero
        for root in snapshot.lines {
            try values(root)
            if root.bundle != nil || root.itemTypeRawValue == CatalogItemType.group.rawValue {
                try CatalogBundlePolicy.validate(root)
                for leaf in root.soldLeaves { try values(leaf) }
            }
            guard let extended = QuickBooksSalesLineContract.decimal(root.extendedAmount, places: 2) else { throw Invalid.evidence }
            gross += extended
        }
        guard gross <= 99_999_999_999 else { throw Invalid.evidence }
        if let discount = snapshot.discount {
            guard discount.value.isFinite, discount.value > 0,
                  let recorded = QuickBooksSalesLineContract.decimal(discount.grossSubtotalAtAuthorization, places: 2), recorded == gross,
                  !discount.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !discount.authorizedByEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  validDate(discount.authorizedAt) else { throw Invalid.evidence }
            switch discount.kind {
            case .percentage: guard discount.value <= 100 else { throw Invalid.evidence }
            case .fixedAmount:
                guard let amount = QuickBooksSalesLineContract.decimal(discount.value, places: 2), amount <= gross else { throw Invalid.evidence }
            }
        }
    }

    private static func values(_ line: CatalogLineItemSnapshot) throws {
        guard !line.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              QuickBooksSalesLineContract.decimal(line.unitPrice, places: 5) != nil,
              QuickBooksSalesLineContract.decimal(line.pricebookUnitPrice, places: 5) != nil,
              let quantity = QuickBooksSalesLineContract.decimal(line.quantity, places: 5, maximum: 999_999), quantity > 0,
              line.purchaseCost.map({ $0.isFinite && $0 >= 0 && $0 <= 99_999_999_999 }) ?? true,
              validDate(line.catalogUpdatedAt) else { throw Invalid.evidence }
        if let type = line.itemTypeRawValue {
            guard let type = CatalogItemType(rawValue: type), type.isDirectSalesItem || type == .group else { throw Invalid.evidence }
        }
        if let reference = line.quickBooksItemID, !QuickBooksSalesLineContract.validReference(reference) { throw Invalid.evidence }
        let hasAdjustment = line.priceAdjustmentReason != nil || line.priceAdjustmentAuthorizedByEmail != nil || line.priceAdjustmentAuthorizedAt != nil
        if hasAdjustment || abs(line.unitPrice - line.pricebookUnitPrice) >= 0.005 {
            guard let reason = line.priceAdjustmentReason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let actor = line.priceAdjustmentAuthorizedByEmail, !actor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let date = line.priceAdjustmentAuthorizedAt, validDate(date) else { throw Invalid.evidence }
        }
        if let equipment = line.servicedEquipment, equipment.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw Invalid.evidence }
        if let assembly = line.assembly {
            guard line.bundle == nil, assembly.revision > 0, !assembly.components.isEmpty, assembly.components.count <= 750,
                  !assembly.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  Set(assembly.components.map(\.itemID)).count == assembly.components.count else { throw Invalid.evidence }
            if assembly.presentation == .flatRate, assembly.assemblyItemID != line.catalogItemID { throw Invalid.evidence }
            for component in assembly.components {
                guard !component.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      component.quantity.isFinite, component.quantity > 0, component.quantity <= 999_999,
                      component.purchaseCost.map({ $0.isFinite && $0 >= 0 && $0 <= 99_999_999_999 }) ?? true else { throw Invalid.evidence }
            }
        }
    }

    private static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite && abs(date.timeIntervalSinceReferenceDate) <= 100_000_000_000
    }
    private static func present(_ value: JSON?) -> JSON? {
        guard let value else { return nil }
        if case .null = value { return nil }; return value
    }
    private static func object(_ value: JSON, required: Set<String>, optional: Set<String> = []) throws -> [String: JSON] {
        guard case .object(let fields) = value, required.isSubset(of: Set(fields.keys)),
              Set(fields.keys).isSubset(of: required.union(optional)) else { throw Invalid.evidence }
        for key in required where present(fields[key]) == nil { throw Invalid.evidence }
        return fields
    }
    private static func line(_ value: JSON, member: Bool, count: inout Int) throws {
        count += 1; guard count <= 750 else { throw Invalid.evidence }
        let fields = try object(value,
            required: ["catalogItemID", "name", "unitPrice", "isTaxable", "catalogUpdatedAt"],
            optional: ["itemTypeRawValue", "quickBooksItemID", "description", "sku", "pricebookUnitPrice", "purchaseCost", "quantity",
                       "priceAdjustmentReason", "priceAdjustmentAuthorizedByEmail", "priceAdjustmentAuthorizedAt", "servicedEquipment", "assembly", "bundle"])
        // Only an absent legacy quantity/pricebook value has the documented
        // default. Explicit null cannot silently become a quantity or price.
        for key in ["quantity", "pricebookUnitPrice"] where fields[key] != nil && present(fields[key]) == nil { throw Invalid.evidence }
        if let equipment = present(fields["servicedEquipment"]) {
            _ = try object(equipment, required: ["equipmentID", "name"], optional: ["equipmentType", "manufacturer", "modelNumber", "serialNumber", "location"])
        }
        if let assembly = present(fields["assembly"]) {
            let value = try object(assembly, required: ["assemblyItemID", "name", "revision", "presentation", "components"])
            let components = try value["components"]!.array()
            guard components.count <= 750 else { throw Invalid.evidence }
            for component in components {
                _ = try object(component, required: ["itemID", "name", "quantity", "tracksInventory"], optional: ["sku", "purchaseCost"])
            }
        }
        if let bundle = present(fields["bundle"]) {
            guard !member else { throw Invalid.evidence }
            let value = try object(bundle, required: ["scope", "printGroupedItems", "members"])
            _ = try object(value["scope"]!, required: ["companyID", "realmID", "environment"])
            let members = try value["members"]!.array()
            guard !members.isEmpty, members.count < 750 else { throw Invalid.evidence }
            var identities = Set<String>()
            for entry in members {
                let entry = try object(entry, required: ["id", "line", "tracksInventory"])
                guard let id = UUID(uuidString: try entry["id"]!.string()), identities.insert(id.uuidString).inserted else { throw Invalid.evidence }
                try line(entry["line"]!, member: true, count: &count)
            }
        }
    }
    private static func validateAtoms(_ value: JSON) throws {
        switch value {
        case .object(let fields):
            for (key, child) in fields {
                guard !key.unicodeScalars.contains(where: { $0.value == 0 }) else { throw Invalid.evidence }
                try validateAtoms(child)
            }
        case .array(let values): for child in values { try validateAtoms(child) }
        case .string: _ = try value.string()
        case .number(let text): guard let value = Double(text), value.isFinite else { throw Invalid.evidence }
        case .flag, .null: break
        }
    }
}
