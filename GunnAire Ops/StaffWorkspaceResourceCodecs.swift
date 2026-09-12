import Foundation
import SwiftData

/// Explicit owner-side values. These mappings are not staff role projections,
/// authorization, content delivery, or permission to activate a staff store.
extension StaffWorkspaceModelCodecs {
    static var vendor: StaffWorkspaceModelCodec<Vendor> {
        .init(kind: "vendor", id: \.id, fields: [
            .value("name", \.name),
            .optional("quickBooksID", \.quickBooksID),
            .optional("contactInfo", \.contactInfo),
        ], excludedAttributes: [:], inverseRelationships: [], make: { record, resolver in
            Vendor(id: record.id, name: "")
        })
    }
    static var purchaseOrder: StaffWorkspaceModelCodec<PurchaseOrder> {
        .init(kind: "purchaseOrder", id: \.id, fields: [
            .value("number", \.number),
            .value("vendorName", \.vendorName),
            .value("itemName", \.itemName),
            .value("quantity", \.quantity),
            .value("unitCost", \.unitCost),
            .value("shippingCost", \.shippingCost),
            .value("statusRaw", \.statusRaw),
            .value("createdAt", \.createdAt),
            .value("updatedAt", \.updatedAt),
            .optional("vendorQuickBooksID", \.vendorQuickBooksID),
            .optional("serviceCallID", \.serviceCallID),
            .optional("itemSKU", \.itemSKU),
            .optional("vendorPartNumber", \.vendorPartNumber),
            .optional("notes", \.notes),
            .optional("createdByEmail", \.createdByEmail),
            .optional("orderedAt", \.orderedAt),
            .optional("receivedAt", \.receivedAt),
            .optional("receivedToLocation", \.receivedToLocation),
        ], excludedAttributes: [:], inverseRelationships: [], make: { record, resolver in
            // Explicit number avoids the new-order numbering path. No order is submitted.
            PurchaseOrder(id: record.id, number: "", vendorName: "", itemName: "", quantity: 0, unitCost: 0)
        })
    }
    static var movement: StaffWorkspaceModelCodec<InventoryMovement> {
        .init(kind: "movement", id: \.id, fields: [
            .value("itemID", \.itemID),
            .value("itemName", \.itemName),
            .value("movementTypeRaw", \.movementTypeRaw),
            .value("quantity", \.quantity),
            .value("createdAt", \.createdAt),
            .optional("itemSKU", \.itemSKU),
            .optional("sourceLocation", \.sourceLocation),
            .optional("destinationLocation", \.destinationLocation),
            .optional("serviceCallID", \.serviceCallID),
            .optional("notes", \.notes),
            .optional("createdByEmail", \.createdByEmail),
        ], excludedAttributes: [:], inverseRelationships: [], make: { record, resolver in
            // Historical item snapshots survive catalog retirement; this creates no ledger event.
            InventoryMovement(id: record.id, item: Item(id: record.id, name: "", unitPrice: 0), type: .adjust, quantity: 0)
        })
    }
    static var vehicle: StaffWorkspaceModelCodec<FleetVehicle> {
        .init(kind: "vehicle", id: \.id, fields: [
            .value("unitNumber", \.unitNumber),
            .value("stockLocation", \.stockLocation),
            .value("administrativeStatusRaw", \.administrativeStatusRaw),
            .value("createdAt", \.createdAt),
            .value("updatedAt", \.updatedAt),
            .optional("vin", \.vin),
            .optional("licensePlate", \.licensePlate),
            .optional("vehicleYear", \.vehicleYear),
            .optional("make", \.make),
            .optional("model", \.model),
            .optional("assignedTechnicianID", \.assignedTechnicianID),
            .optional("assignedTechnicianName", \.assignedTechnicianName),
            .optional("odometer", \.odometer),
            .optional("odometerUpdatedAt", \.odometerUpdatedAt),
            .optional("latestInspectionAt", \.latestInspectionAt),
            .optional("nextInspectionDueAt", \.nextInspectionDueAt),
            .optional("nextServiceDueAt", \.nextServiceDueAt),
            .optional("nextServiceDueOdometer", \.nextServiceDueOdometer),
            .optional("notes", \.notes),
            .optional("updatedByEmail", \.updatedByEmail),
        ], excludedAttributes: [:], inverseRelationships: [], make: { record, resolver in
            FleetVehicle(id: record.id, unitNumber: "", stockLocation: "")
        })
    }
    static var vehicleEvent: StaffWorkspaceModelCodec<FleetVehicleEvent> {
        .init(kind: "vehicleEvent", id: \.id, fields: [
            .value("vehicleID", \.vehicleID),
            .value("vehicleUnitNumber", \.vehicleUnitNumber),
            .value("kindRaw", \.kindRaw),
            .value("occurredAt", \.occurredAt),
            .value("actorEmail", \.actorEmail),
            .value("detail", \.detail),
            .optional("odometer", \.odometer),
            .optional("inspectionResultsJSON", \.inspectionResultsJSON),
            .optional("failedInspectionItemsRaw", \.failedInspectionItemsRaw),
            .optional("serviceCategoryRaw", \.serviceCategoryRaw),
            .optional("serviceCost", \.serviceCost),
            .optional("serviceCenter", \.serviceCenter),
            .optional("invoiceNumber", \.invoiceNumber),
            .optional("assignmentTechnicianID", \.assignmentTechnicianID),
            .optional("assignmentTechnicianName", \.assignmentTechnicianName),
            .optional("priorStatusRaw", \.priorStatusRaw),
            .optional("newStatusRaw", \.newStatusRaw),
            .optional("resolvesOutOfService", \.resolvesOutOfService),
        ], excludedAttributes: [:], inverseRelationships: [], make: { record, resolver in
            FleetVehicleEvent(id: record.id, vehicleID: record.id, vehicleUnitNumber: "", kind: .created, actorEmail: "", detail: "")
        })
    }
    static var expense: StaffWorkspaceModelCodec<FieldExpenseClaim> {
        .init(kind: "expense", id: \.id, fields: [
            .value("claimantEmail", \.claimantEmail),
            .value("claimantName", \.claimantName),
            .value("claimTypeRaw", \.claimTypeRaw),
            .value("categoryRaw", \.categoryRaw),
            .value("expenseDate", \.expenseDate),
            .value("merchant", \.merchant),
            .value("businessPurpose", \.businessPurpose),
            .value("amount", \.amount),
            .value("reimbursable", \.reimbursable),
            .value("statusRaw", \.statusRaw),
            .value("submittedAt", \.submittedAt),
            .value("createdAt", \.createdAt),
            .value("updatedAt", \.updatedAt),
            .optional("serviceCallID", \.serviceCallID),
            .optional("customerID", \.customerID),
            .optional("customerName", \.customerName),
            .optional("jobSummary", \.jobSummary),
            .optional("mileageMiles", \.mileageMiles),
            .optional("mileageRatePerMile", \.mileageRatePerMile),
            .optional("mileageOrigin", \.mileageOrigin),
            .optional("mileageDestination", \.mileageDestination),
            .optional("receiptAttachmentID", \.receiptAttachmentID),
            .optional("reviewedByEmail", \.reviewedByEmail),
            .optional("reviewedAt", \.reviewedAt),
            .optional("reviewNote", \.reviewNote),
            .optional("reimbursedByEmail", \.reimbursedByEmail),
            .optional("reimbursedAt", \.reimbursedAt),
            .optional("reimbursementReference", \.reimbursementReference),
            .optional("auditJSON", \.auditJSON),
        ], excludedAttributes: [:], inverseRelationships: [], make: { record, resolver in
            FieldExpenseClaim(id: record.id, claimantEmail: "", claimantName: "", claimType: .expense, category: .other, expenseDate: Date(timeIntervalSinceReferenceDate: 0), merchant: "", businessPurpose: "", amount: 0, reimbursable: false)
        })
    }
}
