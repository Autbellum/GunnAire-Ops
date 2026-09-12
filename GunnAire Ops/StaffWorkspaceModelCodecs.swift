import Foundation
import SwiftData

/// Complete persisted attribute mappings for these operational models, except
/// explicitly classified payment-service handles. This is the owner-side codec,
/// NOT a field-staff projection: costs and provider metadata still require
/// server-side filtering. Other business models and role projection remain required.
@MainActor enum StaffWorkspaceModelCodecs {
    static var customer: StaffWorkspaceModelCodec<Customer> {
        .init(kind: "customer", id: \.id, fields: [
            .value("name", \.name),
            .value("allowsTransactionalEmail", \.allowsTransactionalEmail),
            .value("allowsServiceText", \.allowsServiceText),
            .value("allowsMarketing", \.allowsMarketing),
            .value("preferredContactMethodRaw", \.preferredContactMethodRaw),
            .optional("quickBooksID", \.quickBooksID),
            .optional("phone", \.phone),
            .optional("email", \.email),
            .optional("address", \.address),
            .optional("communicationConsentUpdatedAt", \.communicationConsentUpdatedAt),
        ], excludedAttributes: ["storedPaymentMethodsJSON": "Payment-method handles require the separate authenticated payment service."], inverseRelationships: ["storedRecurringContracts", "storedServiceCalls", "storedInvoices", "storedEstimates", "storedCommunications", "storedDocumentAttachments", "storedEquipmentProfiles", "storedServiceLocations"], make: { record, resolver in
            let value = Customer(id: record.id, name: ""); value.storedPaymentMethodsJSON = nil; return value
        })
    }
    static var location: StaffWorkspaceModelCodec<CustomerServiceLocation> {
        .init(kind: "location", id: \.id, fields: [
            .value("name", \.name),
            .value("address", \.address),
            .value("isPrimary", \.isPrimary),
            .value("isActive", \.isActive),
            .value("createdAt", \.createdAt),
            .value("updatedAt", \.updatedAt),
            .optional("contactName", \.contactName),
            .optional("contactPhone", \.contactPhone),
            .optional("accessNotes", \.accessNotes),
            .reference("customer", \.customer, id: \Customer.id, kind: "customer", required: true),
        ], excludedAttributes: [:], inverseRelationships: [], make: { record, resolver in
            return CustomerServiceLocation(id: record.id, name: "", address: "")
        })
    }
    static var equipment: StaffWorkspaceModelCodec<CustomerEquipment> {
        .init(kind: "equipment", id: \.id, fields: [
            .value("name", \.name),
            .value("isActive", \.isActive),
            .value("createdAt", \.createdAt),
            .optional("serviceLocationID", \.serviceLocationID),
            .optional("equipmentTypeRaw", \.equipmentTypeRaw),
            .optional("manufacturer", \.manufacturer),
            .optional("modelNumber", \.modelNumber),
            .optional("serialNumber", \.serialNumber),
            .optional("location", \.location),
            .optional("installDate", \.installDate),
            .optional("warrantyExpiration", \.warrantyExpiration),
            .optional("filterSize", \.filterSize),
            .optional("notes", \.notes),
            .optional("technicalBaselineReadingsJSON", \.technicalBaselineReadingsJSON),
            .reference("customer", \.customer, id: \Customer.id, kind: "customer", required: true),
        ], excludedAttributes: [:], inverseRelationships: [], make: { record, resolver in
            return CustomerEquipment(id: record.id, name: "")
        })
    }
    static var technician: StaffWorkspaceModelCodec<Technician> {
        .init(kind: "technician", id: \.id, fields: [
            .value("name", \.name),
            .optional("contactInfo", \.contactInfo),
            .optional("supportedEquipmentTypesJSON", \.supportedEquipmentTypesJSON),
            .optional("qualificationNotes", \.qualificationNotes),
            .optional("serviceAreasJSON", \.serviceAreasJSON),
            .optional("laborCostPerHour", \.laborCostPerHour),
            .optional("quickBooksTimeEntityKindRawValue", \.quickBooksTimeEntityKindRawValue),
            .optional("quickBooksTimeEntityRef", \.quickBooksTimeEntityRef),
        ], excludedAttributes: [:], inverseRelationships: ["storedAssignedServiceCalls"], make: { record, resolver in
            return Technician(id: record.id, name: "")
        })
    }
    static var item: StaffWorkspaceModelCodec<Item> {
        .init(kind: "item", id: \.id, fields: [
            .value("quickBooksSyncStatus", \.quickBooksSyncStatus),
            .value("name", \.name),
            .value("itemTypeRawValue", \.itemTypeRawValue),
            .value("unitPrice", \.unitPrice),
            .value("isTaxable", \.isTaxable),
            .value("tracksInventory", \.tracksInventory),
            .value("createdAt", \.createdAt),
            .value("timestamp", \.timestamp),
            .optional("quickBooksID", \.quickBooksID),
            .optional("quickBooksSyncDetail", \.quickBooksSyncDetail),
            .optional("quickBooksLastSyncedAt", \.quickBooksLastSyncedAt),
            .optional("quickBooksCatalogReceiptJSON", \.quickBooksCatalogReceiptJSON),
            .optional("quickBooksInventorySetupJSON", \.quickBooksInventorySetupJSON),
            .optional("quickBooksCatalogDetailsJSON", \.quickBooksCatalogDetailsJSON),
            .optional("pricebookReviewStatusRawValue", \.pricebookReviewStatusRawValue),
            .optional("pricebookCreatedByEmail", \.pricebookCreatedByEmail),
            .optional("pricebookReviewedByEmail", \.pricebookReviewedByEmail),
            .optional("pricebookReviewedAt", \.pricebookReviewedAt),
            .optional("purchaseCost", \.purchaseCost),
            .optional("itemDescription", \.itemDescription),
            .optional("sku", \.sku),
            .optional("preferredVendorName", \.preferredVendorName),
            .optional("preferredVendorQuickBooksID", \.preferredVendorQuickBooksID),
            .optional("vendorPartNumber", \.vendorPartNumber),
            .optional("purchaseURL", \.purchaseURL),
            .optional("purchaseDescription", \.purchaseDescription),
            .optional("reorderPoint", \.reorderPoint),
            .optional("defaultInventoryLocation", \.defaultInventoryLocation),
            .optional("flatRateAssemblyJSON", \.flatRateAssemblyJSON),
        ], excludedAttributes: [:], inverseRelationships: [], make: { record, resolver in
            return Item(id: record.id, name: "", unitPrice: 0)
        })
    }
    static var job: StaffWorkspaceModelCodec<ServiceCall> {
        .init(kind: "job", id: \.id, fields: [
            .value("googleEventManagedByApp", \.googleEventManagedByApp),
            .value("dispatchUrgencyRaw", \.dispatchUrgencyRaw),
            .value("scheduledDate", \.scheduledDate),
            .value("duration", \.duration),
            .value("visitDispositionRaw", \.visitDispositionRaw),
            .value("followUpRequired", \.followUpRequired),
            .value("diagnosticsCaptured", \.diagnosticsCaptured),
            .value("quoteReviewedWithCustomer", \.quoteReviewedWithCustomer),
            .value("equipmentVerifiedChecklist", \.equipmentVerifiedChecklist),
            .value("startupChecklistComplete", \.startupChecklistComplete),
            .value("maintenanceChecklistComplete", \.maintenanceChecklistComplete),
            .value("safetyChecklistComplete", \.safetyChecklistComplete),
            .value("customerNotified", \.customerNotified),
            .value("arrivalConfirmed", \.arrivalConfirmed),
            .value("workCompletedChecklist", \.workCompletedChecklist),
            .value("documentationChecklist", \.documentationChecklist),
            .value("paymentCollectedChecklist", \.paymentCollectedChecklist),
            .value("beforePhotoCount", \.beforePhotoCount),
            .value("afterPhotoCount", \.afterPhotoCount),
            .optional("googleCalendarID", \.googleCalendarID),
            .optional("googleEventID", \.googleEventID),
            .optional("eventTitle", \.eventTitle),
            .optional("siteAddress", \.siteAddress),
            .optional("serviceLocationID", \.serviceLocationID),
            .optional("equipmentName", \.equipmentName),
            .optional("equipmentManufacturer", \.equipmentManufacturer),
            .optional("equipmentModel", \.equipmentModel),
            .optional("equipmentSerialNumber", \.equipmentSerialNumber),
            .optional("equipmentLocation", \.equipmentLocation),
            .optional("equipmentInstallDate", \.equipmentInstallDate),
            .optional("equipmentWarrantyExpiration", \.equipmentWarrantyExpiration),
            .optional("customerEquipmentID", \.customerEquipmentID),
            .optional("equipmentTypeRaw", \.equipmentTypeRaw),
            .optional("equipmentNotes", \.equipmentNotes),
            .optional("serviceReportReadingsJSON", \.serviceReportReadingsJSON),
            .optional("serviceActionChecklistJSON", \.serviceActionChecklistJSON),
            .optional("filterSize", \.filterSize),
            .optional("filterCondition", \.filterCondition),
            .optional("indoorCoilCondition", \.indoorCoilCondition),
            .optional("outdoorCoilCondition", \.outdoorCoilCondition),
            .optional("drainLineCondition", \.drainLineCondition),
            .optional("thermostatOperation", \.thermostatOperation),
            .optional("serviceReportSummary", \.serviceReportSummary),
            .optional("promisedArrivalWindowStart", \.promisedArrivalWindowStart),
            .optional("promisedArrivalWindowEnd", \.promisedArrivalWindowEnd),
            .optional("additionalTechnicianIDsJSON", \.additionalTechnicianIDsJSON),
            .optional("cancelledAt", \.cancelledAt),
            .optional("cancellationReason", \.cancellationReason),
            .optional("notes", \.notes),
            .optional("findingsSummary", \.findingsSummary),
            .optional("recommendedWorkSummary", \.recommendedWorkSummary),
            .optional("visitDispositionNotes", \.visitDispositionNotes),
            .optional("followUpAction", \.followUpAction),
            .optional("followUpDueDate", \.followUpDueDate),
            .optional("maintenanceAgreementID", \.maintenanceAgreementID),
            .optional("maintenanceAgreementDueDate", \.maintenanceAgreementDueDate),
            .optional("originatingServiceCallID", \.originatingServiceCallID),
            .optional("scheduledFollowUpServiceCallID", \.scheduledFollowUpServiceCallID),
            .optional("correctiveWorkReasonRaw", \.correctiveWorkReasonRaw),
            .optional("technicianEnRouteAt", \.technicianEnRouteAt),
            .optional("technicianArrivedAt", \.technicianArrivedAt),
            .optional("documentationStartedAt", \.documentationStartedAt),
            .optional("documentationCompletedAt", \.documentationCompletedAt),
            .optional("linkedEstimateID", \.linkedEstimateID),
            .optional("linkedInvoiceID", \.linkedInvoiceID),
            .enumeration("type", \.type),
            .enumeration("status", \.status),
            .reference("customer", \.customer, id: \Customer.id, kind: "customer", required: true),
            .reference("assignedTechnician", \.assignedTechnician, id: \Technician.id, kind: "technician", required: false),
        ], excludedAttributes: [:], inverseRelationships: ["storedTimeEntries"], make: { record, resolver in
            return ServiceCall(id: record.id, type: .service, scheduledDate: Date(timeIntervalSinceReferenceDate: 0), customer: try resolver.parent(Customer.self, kind: "customer", field: "customer", record: record))
        })
    }
}
