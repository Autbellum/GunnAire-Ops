import Foundation

/// Choices from a verified staff projection, never owner catalog models.
struct StaffInvoiceSource: Equatable {
    struct Equipment: Identifiable, Equatable { let id: String; let name: String }
    let origin: StaffInvoiceOrigin
    let catalog: [StaffInvoiceLine]
    let equipment: [Equipment]
    let editable: Bool

    static func make(plan: StaffWorkspaceOperationalImportPlan, invoiceID: String) throws -> Self {
        guard [AppUserRole.admin.rawValue, AppUserRole.accounting.rawValue, AppUserRole.fieldTechnician.rawValue].contains(plan.memberRole),
              let invoice = plan.record(kind: "invoice", id: invoiceID), case .billing(let document) = invoice.body,
              document.kind == "invoice", document.id.uuidString.lowercased() == invoiceID,
              case .identifier(let customer) = document.fields["customer"],
              !invoice.unavailableLinks.contains("customer"), !invoice.unavailableLinks.contains("serviceCallID") else {
            throw StaffReplicaDeliveryError.access
        }
        let job: String?
        switch document.fields["serviceCallID"] {
        case .identifier(let id): job = id.uuidString.lowercased()
        case .null: job = nil
        default: throw StaffReplicaDeliveryError.invalid
        }
        guard plan.memberRole != AppUserRole.fieldTechnician.rawValue || job != nil else { throw StaffReplicaDeliveryError.access }
        let origin = StaffInvoiceOrigin(companyID: plan.companyID, environment: plan.environment, replicaID: plan.replicaID,
            selectionID: plan.selectionID, sourceSequence: plan.sourceSequence, contentSHA256: plan.contentSHA256,
            invoiceID: invoiceID, invoiceRevision: invoice.revision, customerID: customer.uuidString.lowercased(), jobID: job)
        try origin.validate()
        let editable: Bool
        if case .text(let status) = document.fields["status"], ["unpaid", "overdue"].contains(status),
           document.fields["finalizedAt"] == .null { editable = true } else { editable = false }
        var catalog: [StaffInvoiceLine] = []
        var equipment: [Equipment] = []
        for record in plan.records {
            guard case .operational(let partition) = record.body else { continue }
            let fields = partition.fields
            if record.kind == "equipment", fields["customer"] == .identifier(customer),
               !record.unavailableLinks.contains("customer"), case .text(let name) = fields["name"] {
                equipment.append(.init(id: record.id, name: name))
            }
            guard record.kind == "item", fields["pricebookReviewStatusRawValue"] == .null || fields["pricebookReviewStatusRawValue"] == .text("approved"),
                  case .text(let name) = fields["name"], case .text(let type) = fields["itemTypeRawValue"],
                  case .number(let price) = fields["unitPrice"], case .flag(let taxable) = fields["isTaxable"] else { continue }
            func optional(_ key: String) throws -> String? {
                switch fields[key] { case .text(let value): return value; case .null: return nil; default: throw StaffReplicaDeliveryError.invalid }
            }
            let line = try StaffInvoiceLine(kind: "catalog", itemID: record.id, itemRevision: record.revision, itemType: type,
                name: name, description: optional("itemDescription"), sku: optional("sku"), unitPrice: price,
                quantity: 1, isTaxable: taxable, equipmentID: nil)
            // Unknown/non-sale catalog types remain readable but cannot be added here.
            if (try? line.validate()) != nil { catalog.append(line) }
        }
        return .init(origin: origin, catalog: catalog.sorted { ($0.name, $0.itemID) < ($1.name, $1.itemID) },
                     equipment: equipment.sorted { ($0.name, $0.id) < ($1.name, $1.id) }, editable: editable)
    }
    func validate(_ request: StaffInvoiceRequest) throws {
        try request.validate()
        guard editable, request.origin == origin else { throw StaffReplicaDeliveryError.changed }
        if let id = request.line.equipmentID, !equipment.contains(where: { $0.id == id }) { throw StaffReplicaDeliveryError.changed }
        if request.line.kind == "catalog" {
            var expected = request.line; expected.quantity = 1; expected.equipmentID = nil
            guard catalog.contains(expected) else { throw StaffReplicaDeliveryError.changed }
        } else if catalog.contains(where: { $0.itemID == request.line.itemID }) { throw StaffReplicaDeliveryError.changed }
    }
}
