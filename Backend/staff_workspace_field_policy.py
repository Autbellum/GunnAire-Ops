"""Closed per-field disclosure policy for the other 30 staff model kinds.

This classifies fields; it never selects records or grants a lease. Every field
in the pinned owner schema must appear exactly once. New fields cannot acquire
staff permission simply by appearing in an owner archive.
"""
from __future__ import annotations

try:
    from Backend import staff_workspace_contract as contract, staff_workspace_selection as selection
except ModuleNotFoundError:
    import staff_workspace_contract as contract
    import staff_workspace_selection as selection

VERSION = "staff-operational-fields-v1"
# shared means readable only AFTER this exact record was selected server-side.
SHARED = {
    "customer": "address allowsMarketing allowsServiceText allowsTransactionalEmail communicationConsentUpdatedAt email name phone preferredContactMethodRaw",
    "location": "address contactName contactPhone createdAt customer isActive isPrimary name updatedAt",
    "technician": "contactInfo name",
    "equipment": "createdAt customer equipmentTypeRaw filterSize installDate isActive location manufacturer modelNumber name serialNumber serviceLocationID warrantyExpiration",
    "item": "createdAt defaultInventoryLocation isTaxable itemDescription itemTypeRawValue name preferredVendorName pricebookCreatedByEmail pricebookReviewStatusRawValue pricebookReviewedAt pricebookReviewedByEmail quickBooksLastSyncedAt quickBooksSyncStatus reorderPoint sku timestamp tracksInventory unitPrice vendorPartNumber",
    "job": "additionalTechnicianIDsJSON arrivalConfirmed assignedTechnician cancellationReason cancelledAt correctiveWorkReasonRaw customer customerEquipmentID customerNotified dispatchUrgencyRaw duration equipmentInstallDate equipmentLocation equipmentManufacturer equipmentModel equipmentName equipmentSerialNumber equipmentTypeRaw equipmentWarrantyExpiration eventTitle followUpDueDate followUpRequired linkedEstimateID linkedInvoiceID maintenanceAgreementDueDate maintenanceAgreementID originatingServiceCallID promisedArrivalWindowEnd promisedArrivalWindowStart scheduledDate scheduledFollowUpServiceCallID serviceLocationID siteAddress status technicianArrivedAt technicianEnRouteAt type visitDispositionRaw",
    "payment": "amount date invoice isRefund method providerPaymentStatus refundedPaymentID",
    "user": "createdAt email",
    "availability": "cancellationOperationID cancelledAt cancelledByEmail createdAt createdByEmail creationOperationID endsAt kindRawValue sourceTimeOffRequestID startsAt technicianID",
    "availabilityEvent": "actorEmail availabilityBlockID endsAt kindRawValue occurredAt operationID requestID requestStatusRawSnapshot startsAt technicianID technicianNameSnapshot",
    "shift": "createdAt createdByEmail creationOperationID durationMinutes effectiveFrom effectiveUntil kindRawValue retiredAt retiredByEmail retirementOperationID startMinute technicianID technicianNameSnapshot timeZoneIdentifier weekdayRawValue",
    "timeOff": "approvedAvailabilityBlockID cancellationOperationID cancelledAt cancelledByEmail createdAt creationOperationID endsAt requestedByEmail reviewOperationID reviewedAt reviewedByEmail startsAt statusRawValue technicianID technicianNameSnapshot updatedAt withdrawalOperationID withdrawnAt withdrawnByEmail",
    "timeEntry": "clockIn clockOut reviewStatusRawValue reviewedAt reviewedByEmail serviceCall userEmail",
    "agreement": "active coveredEquipmentIDsJSON customer includedVisitsPerTerm nextDate planName pricePerVisit renewalReminderDays schedulePattern termEndsOn",
    "request": "address convertedCustomerID convertedServiceCallID createdAt createdByEmail customerName email phone preferredDate qualifiedAt requestedServiceTypeRaw statusRaw summary urgencyRaw",
    "activity": "action actorEmail occurredAt serviceCallID",
    "milestone": "billingPercent billingTriggerRaw completedAt completedByEmail createdAt createdByEmail estimateID invoiceID milestoneDescription plannedAmount plannedDate projectServiceCallID scheduledVisitID sequence statusRaw title updatedAt",
    "alert": "createdAt createdByEmail creationOperationID customerID customerName kindRaw resolutionOperationID resolvedAt resolvedByEmail serviceLocationID serviceLocationName title updatedAt",
    "task": "assignedToEmail cancellationOperationID cancellationReason cancelledAt cancelledByEmail completedAt completedByEmail completionNote completionOperationID createdAt createdByEmail creationOperationID customerID customerName dueAt estimateID estimateSummary priorityRaw serviceCallID serviceCallSummary serviceLocationID serviceLocationName taskDescription title updatedAt",
    "taskEvent": "actorEmail assignedToEmailSnapshot detail dueAtSnapshot kindRaw occurredAt operationID priorityRawSnapshot taskID titleSnapshot",
    "attachment": "backendDocumentID caption contentType createdAt customer customerEquipmentID displayName estimateID expenseClaimID fileSizeBytes fleetVehicleEventID fleetVehicleID invoiceID kindRaw maintenanceContractID serviceCallID",
    "communication": "actorEmail attachmentFileNamesJSON channel createdAt customer deliveredAt deliveryStatus direction estimateID invoiceID maintenanceContractID recipient serviceCallID subject templateVersion workflowRawValue",
    "formTemplate": "applicableServiceTypesJSON createdAt isActive questionsJSON title",
    "formResponse": "answersJSON completedAt completedByEmail serviceCallID templateID templateTitle",
    "vendor": "contactInfo name",
    "purchaseOrder": "createdAt createdByEmail itemName itemSKU number orderedAt quantity receivedAt receivedToLocation serviceCallID statusRaw updatedAt vendorName vendorPartNumber",
    "movement": "createdAt createdByEmail destinationLocation itemID itemName itemSKU movementTypeRaw quantity serviceCallID sourceLocation",
    "vehicle": "administrativeStatusRaw assignedTechnicianID assignedTechnicianName createdAt latestInspectionAt licensePlate make model nextInspectionDueAt nextServiceDueAt nextServiceDueOdometer odometer odometerUpdatedAt stockLocation unitNumber updatedAt updatedByEmail vehicleYear vin",
    "vehicleEvent": "actorEmail assignmentTechnicianID assignmentTechnicianName failedInspectionItemsRaw inspectionResultsJSON kindRaw newStatusRaw occurredAt odometer priorStatusRaw resolvesOutOfService serviceCategoryRaw serviceCenter vehicleID vehicleUnitNumber",
    "expense": "categoryRaw claimTypeRaw claimantEmail claimantName createdAt customerID customerName expenseDate jobSummary receiptAttachmentID reimbursable reimbursedAt reimbursedByEmail reviewedAt reviewedByEmail serviceCallID statusRaw submittedAt updatedAt",
}
FINANCIAL = {
    "customer": "quickBooksID", "technician": "laborCostPerHour quickBooksTimeEntityKindRawValue quickBooksTimeEntityRef",
    "item": "purchaseCost purchaseDescription preferredVendorQuickBooksID quickBooksID",
    "payment": "authorizationReference cardLast4 notes processor processorSyncStatus quickBooksAccountingSyncStatus quickBooksChargeID quickBooksClientTransID quickBooksDepositID quickBooksID quickBooksRefundReceiptID quickBooksSalesReceiptID settlementBatchID",
    "vendor": "quickBooksID", "purchaseOrder": "shippingCost unitCost vendorQuickBooksID",
    "vehicleEvent": "invoiceNumber serviceCost",
}
OPERATIONS = {
    "location": "accessNotes", "equipment": "notes",
    "job": "afterPhotoCount beforePhotoCount diagnosticsCaptured documentationChecklist documentationCompletedAt documentationStartedAt drainLineCondition equipmentNotes equipmentVerifiedChecklist filterCondition filterSize findingsSummary followUpAction indoorCoilCondition maintenanceChecklistComplete notes outdoorCoilCondition paymentCollectedChecklist quoteReviewedWithCustomer recommendedWorkSummary safetyChecklistComplete serviceActionChecklistJSON serviceReportReadingsJSON serviceReportSummary startupChecklistComplete thermostatOperation visitDispositionNotes workCompletedChecklist",
    "request": "qualificationNotes", "activity": "detail", "alert": "detail resolutionNote",
    "communication": "consentSnapshotJSON", "purchaseOrder": "notes", "movement": "notes", "vehicle": "notes",
    "vehicleEvent": "detail",
}
# Only office scheduling reviewers may see private review notes, even if the
# requesting employee can read their own submitted reason.
DISPATCH = {"timeOff": "privateReviewNote", "availabilityEvent": "privateDetail"}
SELF_OR_DISPATCH = {
    "technician": "qualificationNotes serviceAreasJSON supportedEquipmentTypesJSON",
    "availability": "reason cancellationReason", "shift": "note retirementReason",
    "timeOff": "privateReason cancellationReason",
}
SELF_OR_FINANCIAL = {
    "timeEntry": "notes reviewNote reviewAuditJSON",
    "expense": "amount auditJSON businessPurpose merchant mileageDestination mileageMiles mileageOrigin mileageRatePerMile reimbursementReference reviewNote",
}
SERVICE = {
    # Current membership authority comes from the server plan, not stale local
    # AppUser role or activation values in an owner archive.
    "user": "isActive roleRawValue",
    "item": "purchaseURL quickBooksCatalogDetailsJSON quickBooksCatalogReceiptJSON quickBooksInventorySetupJSON quickBooksSyncDetail",
    "job": "googleCalendarID googleEventID googleEventManagedByApp",
    "payment": "collectionAttemptID processorSyncDetail quickBooksAccountingSyncDetail",
    "timeEntry": "quickBooksTimeActivityID quickBooksTimeActivitySyncError quickBooksTimeActivitySyncToken quickBooksTimeActivitySyncedAt",
    "request": "backendRequestID",
    "attachment": "googleDriveArchivedByEmail googleDriveFileID googleDriveLastSyncedAt googleDriveSyncDetail googleDriveSyncStatus googleDriveWebViewLink quickBooksAttachableID quickBooksAttachedEntityKeysRaw quickBooksSyncError sharedCompanySyncDetail sharedCompanySyncStatus",
    "communication": "backendCommunicationID backendSyncError providerMessageID providerStatusDetail",
}
# These need an independently validated nested adapter, not raw text copying.
STRUCTURED = {"item": "flatRateAssemblyJSON", "agreement": "lifecycleJSON", "equipment": "technicalBaselineReadingsJSON"}
GROUPS = {"shared": SHARED, "financial": FINANCIAL, "operations": OPERATIONS, "dispatch": DISPATCH,
          "selfOrDispatch": SELF_OR_DISPATCH, "selfOrFinancial": SELF_OR_FINANCIAL, "serviceOnly": SERVICE,
          "structured": STRUCTURED}


def policies():
    if contract.SCHEMA_DIGEST != selection.OWNER_DIGEST:
        raise selection.failure("schema_changed")
    result = {kind: {} for kind in SHARED}
    if set(result) != set(contract.SPECS) - {"invoice", "estimate"}:
        raise selection.failure("schema_changed")
    for policy, kinds in GROUPS.items():
        for kind, names in kinds.items():
            for name in names.split():
                if kind not in result or name in result[kind]:
                    raise selection.failure("schema_changed")
                result[kind][name] = policy
    if any(set(fields) != set(contract.SPECS[kind]) for kind, fields in result.items()):
        raise selection.failure("schema_changed")
    return result


def own(graph, record, email):
    kind, identity = record["kind"], record["id"]
    field = {"timeEntry": "userEmail", "expense": "claimantEmail", "user": "email", "task": "assignedToEmail"}.get(kind)
    if field:
        return selection.normalized(graph.value(kind, identity, field)) == selection.normalized(email)
    if kind == "technician":
        technician = identity
    elif kind in ("availability", "availabilityEvent", "shift", "timeOff"):
        technician = graph.value(kind, identity, "technicianID")
    else:
        return False
    return technician in graph.live["technician"] and selection.normalized(
        graph.value("technician", technician, "contactInfo")) == selection.normalized(email)


def allows(policy, role, owned):
    if role not in selection.sharing.POLICIES:
        raise selection.failure("sharing_changed")
    if policy in ("shared", "structured"):
        return True
    if policy == "serviceOnly":
        return False
    if policy == "financial":
        return role in ("Admin", "Accounting")
    if policy == "operations":
        return role in ("Admin", "Dispatcher", "Field Technician")
    if policy == "dispatch":
        return role in ("Admin", "Dispatcher")
    if policy == "selfOrDispatch":
        return owned or role in ("Admin", "Dispatcher")
    if policy == "selfOrFinancial":
        return owned or role in ("Admin", "Accounting")
    raise selection.failure("schema_changed")
