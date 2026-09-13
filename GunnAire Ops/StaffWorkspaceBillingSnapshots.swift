import Foundation

/// Sold rows are historical evidence, not instructions to create catalog items
/// or an authority to charge. Current catalog prices and equipment descriptions
/// may differ; original identity and customer lineage may not.
enum StaffWorkspaceBillingSnapshots {
    static func validate(_ records: [StaffWorkspaceModelRecord]) throws {
        guard Set(records.map { StaffWorkspaceRecordKey(kind: $0.kind, id: $0.id) }).count == records.count else {
            throw StaffWorkspaceModelError.invalid
        }
        let index = Dictionary(uniqueKeysWithValues: records.map { (StaffWorkspaceRecordKey(kind: $0.kind, id: $0.id), $0) })
        for record in records where ["invoice", "estimate"].contains(record.kind) {
            guard let value = record.fields["catalogSnapshotJSON"] else { throw StaffWorkspaceModelError.incomplete }
            if value == .null { continue }
            guard let snapshot = try CatalogSnapshotPayload.read(String.fromStaffValue(value)) else { throw StaffWorkspaceModelError.invalid }
            try CatalogSnapshotPayload.validateBusinessEvidence(snapshot)
            let source = StaffWorkspaceRecordKey(kind: record.kind, id: record.id)
            func identifier(_ field: String) throws -> UUID? {
                guard let value = record.fields[field] else { throw StaffWorkspaceModelError.incomplete }
                return value == .null ? nil : try UUID.fromStaffValue(value)
            }
            if let addresses = snapshot.taxAddresses {
                guard let customerID = try identifier("customer"), let address = record.fields["siteAddress"] else {
                    throw StaffWorkspaceModelError.incomplete
                }
                try addresses.validate(for: .init(customerID: customerID, serviceLocationID: identifier("serviceLocationID"),
                    siteAddress: address == .null ? nil : String.fromStaffValue(address)))
            }
            guard let amountValue = record.fields["amount"], let taxValue = record.fields["salesTaxAmount"],
                  let amount = try QuickBooksSalesLineContract.decimal(Double.fromStaffValue(amountValue), places: 2),
                  let tax = try QuickBooksSalesLineContract.decimal(Double.fromStaffValue(taxValue), places: 2), amount >= tax else {
                throw CatalogSnapshotPayload.Invalid.evidence
            }
            try QuickBooksDocumentLinePublication.validateSnapshotTotals(snapshotJSON: String.fromStaffValue(value),
                expectedSubtotal: QuickBooksSalesLineContract.double(amount - tax))
            func requireItem(_ id: UUID) throws {
                let target = StaffWorkspaceRecordKey(kind: "item", id: id)
                guard index[target] != nil else { throw StaffWorkspaceLinkError.missing(source: source, field: "catalogSnapshotJSON", target: target) }
            }
            for root in snapshot.lines {
                for line in root.bundle == nil ? [root] : [root] + root.soldLeaves {
                    try requireItem(line.catalogItemID)
                    if let assembly = line.assembly {
                        try requireItem(assembly.assemblyItemID)
                        for component in assembly.components { try requireItem(component.itemID) }
                    }
                    if let system = line.servicedEquipment {
                        let target = StaffWorkspaceRecordKey(kind: "equipment", id: system.equipmentID)
                        guard let equipment = index[target] else { throw StaffWorkspaceLinkError.missing(source: source, field: "catalogSnapshotJSON", target: target) }
                        guard equipment.fields["customer"] == record.fields["customer"] else {
                            throw StaffWorkspaceLinkError.conflictingScope(source: source, field: "catalogSnapshotJSON", scope: .customer)
                        }
                    }
                }
            }
        }
    }
}
