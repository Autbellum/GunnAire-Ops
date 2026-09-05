#!/usr/bin/env python3
"""Read-only GunnAire Ops release preflight.

The local checks validate the exact Xcode source/archive and retained CloudKit
schema exports.  ``--online`` adds non-mutating production health, malformed
Apple-envelope, and OAuth callback probes.  This utility never deploys code,
changes Apple/Intuit configuration, or sends an accounting mutation.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import struct
import subprocess
import sys
import urllib.error
import urllib.request
import zlib
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any


EXPECTED_BUNDLE_ID = "com.gunnaire.businesssuite"
EXPECTED_TEAM_ID = "7C4B3RR7RD"
EXPECTED_ICLOUD_CONTAINER = "iCloud.com.gunnaire.businesssuite"
EXPECTED_ASSOCIATED_DOMAIN = "applinks:gunnaire.com"
EXPECTED_BACKEND_URL = "https://gunnaire-api.onrender.com"
EXPECTED_QBO_REDIRECT = "https://gunnaire.com/wp-json/ga/v1/qbo/oauth/callback"
EXPECTED_QBO_CALLBACK_SCHEME = "gunnaireops"
EXPECTED_APP_STORE_METADATA_PATH = Path("AppStoreAssets") / "AppStoreSubmission.json"
EXPECTED_APP_STORE_SCREENSHOT_MANIFEST_PATH = (
    Path("AppStoreAssets") / "ScreenshotManifest.json"
)
EXPECTED_APP_STORE_LOCALE = "en-US"
EXPECTED_APP_STORE_PRIVACY_PURPOSE = (
    "NSPrivacyCollectedDataTypePurposeAppFunctionality"
)
EXPECTED_APP_STORE_SCREENSHOT_SETS = {
    "iPad-13-inch": {
        "width": 2064,
        "height": 2752,
        "filenames": (
            "01-command-center.png",
            "02-schedule.png",
            "03-customer-systems.png",
            "04-job-billing.png",
            "05-field-collection.png",
            "06-quickbooks-sales.png",
        ),
    },
    "iPhone-6.9-inch": {
        "width": 1320,
        "height": 2868,
        "filenames": (
            "01-command-center.png",
            "02-schedule.png",
            "03-customer-systems.png",
            "04-job-billing.png",
            "05-field-collection.png",
            "06-quickbooks-sales.png",
        ),
    },
}
EXPECTED_CLOUDKIT_V13_ADDITIONS = {
    "CD_Estimate": {
        "CD_salesTaxAmount": ("DOUBLE", "QUERYABLE", "SORTABLE"),
        "CD_taxCalculatedAt": ("TIMESTAMP", "QUERYABLE", "SORTABLE"),
        "CD_taxCalculationStatusRawValue": (
            "STRING",
            "QUERYABLE",
            "SEARCHABLE",
            "SORTABLE",
        ),
    },
    "CD_Invoice": {
        "CD_salesTaxAmount": ("DOUBLE", "QUERYABLE", "SORTABLE"),
        "CD_taxCalculatedAt": ("TIMESTAMP", "QUERYABLE", "SORTABLE"),
        "CD_taxCalculationStatusRawValue": (
            "STRING",
            "QUERYABLE",
            "SEARCHABLE",
            "SORTABLE",
        ),
    },
}
EXPECTED_CLOUDKIT_V14_ADDITIONS = {
    **EXPECTED_CLOUDKIT_V13_ADDITIONS,
    "CD_Invoice": {
        **EXPECTED_CLOUDKIT_V13_ADDITIONS["CD_Invoice"],
        "CD_dueDate": ("TIMESTAMP", "QUERYABLE", "SORTABLE"),
    },
}
EXPECTED_CLOUDKIT_V15_ADDITIONS = {
    **EXPECTED_CLOUDKIT_V14_ADDITIONS,
    "CD_InventoryMovement": {
        "CD_itemSKU": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
    },
    "CD_Item": {
        "CD_defaultInventoryLocation": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_flatRateAssemblyJSON": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_itemDescription": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_preferredVendorName": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_preferredVendorQuickBooksID": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_purchaseCost": ("DOUBLE", "QUERYABLE", "SORTABLE"),
        "CD_purchaseDescription": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_purchaseURL": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_quickBooksID": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_quickBooksLastSyncedAt": ("TIMESTAMP", "QUERYABLE", "SORTABLE"),
        "CD_quickBooksSyncDetail": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_reorderPoint": ("DOUBLE", "QUERYABLE", "SORTABLE"),
        "CD_sku": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_vendorPartNumber": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
    },
}
EXPECTED_CLOUDKIT_V16_ADDITIONS = {
    **EXPECTED_CLOUDKIT_V15_ADDITIONS,
    "CD_ServiceDocumentAttachment": {
        "CD_backendDocumentID": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_caption": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_customerEquipmentID": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_estimateID": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_googleDriveArchivedByEmail": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_googleDriveFileID": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_googleDriveLastSyncedAt": ("TIMESTAMP", "QUERYABLE", "SORTABLE"),
        "CD_googleDriveSyncDetail": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_googleDriveSyncStatus": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_googleDriveWebViewLink": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_invoiceID": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_quickBooksAttachableID": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_quickBooksAttachedEntityKeysRaw": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_quickBooksSyncError": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_sharedCompanySyncDetail": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
        "CD_sharedCompanySyncStatus": ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE"),
    },
}
_CLOUDKIT_STRING_FIELD = ("STRING", "QUERYABLE", "SEARCHABLE", "SORTABLE")
_CLOUDKIT_NUMBER_FIELD = ("DOUBLE", "QUERYABLE", "SORTABLE")
_CLOUDKIT_INTEGER_FIELD = ("INT64", "QUERYABLE", "SORTABLE")
_CLOUDKIT_DATE_FIELD = ("TIMESTAMP", "QUERYABLE", "SORTABLE")
EXPECTED_CLOUDKIT_V17_ADDITIONS = {
    **EXPECTED_CLOUDKIT_V16_ADDITIONS,
    "CD_ServiceDocumentAttachment": {
        **EXPECTED_CLOUDKIT_V16_ADDITIONS["CD_ServiceDocumentAttachment"],
        "CD_fleetVehicleEventID": _CLOUDKIT_STRING_FIELD,
        "CD_fleetVehicleID": _CLOUDKIT_STRING_FIELD,
    },
    "CD_FleetVehicle": {
        "CD_administrativeStatusRaw": _CLOUDKIT_STRING_FIELD,
        "CD_assignedTechnicianID": _CLOUDKIT_STRING_FIELD,
        "CD_assignedTechnicianName": _CLOUDKIT_STRING_FIELD,
        "CD_createdAt": _CLOUDKIT_DATE_FIELD,
        "CD_entityName": _CLOUDKIT_STRING_FIELD,
        "CD_id": _CLOUDKIT_STRING_FIELD,
        "CD_latestInspectionAt": _CLOUDKIT_DATE_FIELD,
        "CD_licensePlate": _CLOUDKIT_STRING_FIELD,
        "CD_make": _CLOUDKIT_STRING_FIELD,
        "CD_model": _CLOUDKIT_STRING_FIELD,
        "CD_nextInspectionDueAt": _CLOUDKIT_DATE_FIELD,
        "CD_nextServiceDueAt": _CLOUDKIT_DATE_FIELD,
        "CD_nextServiceDueOdometer": _CLOUDKIT_NUMBER_FIELD,
        "CD_notes": _CLOUDKIT_STRING_FIELD,
        "CD_odometer": _CLOUDKIT_NUMBER_FIELD,
        "CD_odometerUpdatedAt": _CLOUDKIT_DATE_FIELD,
        "CD_stockLocation": _CLOUDKIT_STRING_FIELD,
        "CD_unitNumber": _CLOUDKIT_STRING_FIELD,
        "CD_updatedAt": _CLOUDKIT_DATE_FIELD,
        "CD_updatedByEmail": _CLOUDKIT_STRING_FIELD,
        "CD_vehicleYear": _CLOUDKIT_INTEGER_FIELD,
        "CD_vin": _CLOUDKIT_STRING_FIELD,
    },
    "CD_FleetVehicleEvent": {
        "CD_actorEmail": _CLOUDKIT_STRING_FIELD,
        "CD_assignmentTechnicianID": _CLOUDKIT_STRING_FIELD,
        "CD_assignmentTechnicianName": _CLOUDKIT_STRING_FIELD,
        "CD_detail": _CLOUDKIT_STRING_FIELD,
        "CD_entityName": _CLOUDKIT_STRING_FIELD,
        "CD_failedInspectionItemsRaw": _CLOUDKIT_STRING_FIELD,
        "CD_id": _CLOUDKIT_STRING_FIELD,
        "CD_inspectionResultsJSON": _CLOUDKIT_STRING_FIELD,
        "CD_invoiceNumber": _CLOUDKIT_STRING_FIELD,
        "CD_kindRaw": _CLOUDKIT_STRING_FIELD,
        "CD_newStatusRaw": _CLOUDKIT_STRING_FIELD,
        "CD_occurredAt": _CLOUDKIT_DATE_FIELD,
        "CD_odometer": _CLOUDKIT_NUMBER_FIELD,
        "CD_priorStatusRaw": _CLOUDKIT_STRING_FIELD,
        "CD_resolvesOutOfService": _CLOUDKIT_INTEGER_FIELD,
        "CD_serviceCategoryRaw": _CLOUDKIT_STRING_FIELD,
        "CD_serviceCenter": _CLOUDKIT_STRING_FIELD,
        "CD_serviceCost": _CLOUDKIT_NUMBER_FIELD,
        "CD_vehicleID": _CLOUDKIT_STRING_FIELD,
        "CD_vehicleUnitNumber": _CLOUDKIT_STRING_FIELD,
    },
}
EXPECTED_CLOUDKIT_V17_RECORD_TYPES = {"CD_FleetVehicle", "CD_FleetVehicleEvent"}
EXPECTED_CLOUDKIT_V18_ADDITIONS = {
    **EXPECTED_CLOUDKIT_V17_ADDITIONS,
    "CD_ServiceDocumentAttachment": {
        **EXPECTED_CLOUDKIT_V17_ADDITIONS["CD_ServiceDocumentAttachment"],
        "CD_expenseClaimID": _CLOUDKIT_STRING_FIELD,
    },
    "CD_FieldExpenseClaim": {
        "CD_amount": _CLOUDKIT_NUMBER_FIELD,
        "CD_auditJSON": _CLOUDKIT_STRING_FIELD,
        "CD_businessPurpose": _CLOUDKIT_STRING_FIELD,
        "CD_categoryRaw": _CLOUDKIT_STRING_FIELD,
        "CD_claimTypeRaw": _CLOUDKIT_STRING_FIELD,
        "CD_claimantEmail": _CLOUDKIT_STRING_FIELD,
        "CD_claimantName": _CLOUDKIT_STRING_FIELD,
        "CD_createdAt": _CLOUDKIT_DATE_FIELD,
        "CD_customerID": _CLOUDKIT_STRING_FIELD,
        "CD_customerName": _CLOUDKIT_STRING_FIELD,
        "CD_entityName": _CLOUDKIT_STRING_FIELD,
        "CD_expenseDate": _CLOUDKIT_DATE_FIELD,
        "CD_id": _CLOUDKIT_STRING_FIELD,
        "CD_jobSummary": _CLOUDKIT_STRING_FIELD,
        "CD_merchant": _CLOUDKIT_STRING_FIELD,
        "CD_mileageDestination": _CLOUDKIT_STRING_FIELD,
        "CD_mileageMiles": _CLOUDKIT_NUMBER_FIELD,
        "CD_mileageOrigin": _CLOUDKIT_STRING_FIELD,
        "CD_mileageRatePerMile": _CLOUDKIT_NUMBER_FIELD,
        "CD_receiptAttachmentID": _CLOUDKIT_STRING_FIELD,
        "CD_reimbursable": _CLOUDKIT_INTEGER_FIELD,
        "CD_reimbursedAt": _CLOUDKIT_DATE_FIELD,
        "CD_reimbursedByEmail": _CLOUDKIT_STRING_FIELD,
        "CD_reimbursementReference": _CLOUDKIT_STRING_FIELD,
        "CD_reviewNote": _CLOUDKIT_STRING_FIELD,
        "CD_reviewedAt": _CLOUDKIT_DATE_FIELD,
        "CD_reviewedByEmail": _CLOUDKIT_STRING_FIELD,
        "CD_serviceCallID": _CLOUDKIT_STRING_FIELD,
        "CD_statusRaw": _CLOUDKIT_STRING_FIELD,
        "CD_submittedAt": _CLOUDKIT_DATE_FIELD,
        "CD_updatedAt": _CLOUDKIT_DATE_FIELD,
    },
}
EXPECTED_CLOUDKIT_V18_RECORD_TYPES = {"CD_FieldExpenseClaim"}
EXPECTED_CLOUDKIT_V19_ADDITIONS = {
    **EXPECTED_CLOUDKIT_V18_ADDITIONS,
    "CD_CustomerOperationalAlert": {
        "CD_createdAt": _CLOUDKIT_DATE_FIELD,
        "CD_createdByEmail": _CLOUDKIT_STRING_FIELD,
        "CD_creationOperationID": _CLOUDKIT_STRING_FIELD,
        "CD_customerID": _CLOUDKIT_STRING_FIELD,
        "CD_customerName": _CLOUDKIT_STRING_FIELD,
        "CD_detail": _CLOUDKIT_STRING_FIELD,
        "CD_entityName": _CLOUDKIT_STRING_FIELD,
        "CD_id": _CLOUDKIT_STRING_FIELD,
        "CD_kindRaw": _CLOUDKIT_STRING_FIELD,
        "CD_resolutionNote": _CLOUDKIT_STRING_FIELD,
        "CD_resolutionOperationID": _CLOUDKIT_STRING_FIELD,
        "CD_resolvedAt": _CLOUDKIT_DATE_FIELD,
        "CD_resolvedByEmail": _CLOUDKIT_STRING_FIELD,
        "CD_serviceLocationID": _CLOUDKIT_STRING_FIELD,
        "CD_serviceLocationName": _CLOUDKIT_STRING_FIELD,
        "CD_title": _CLOUDKIT_STRING_FIELD,
        "CD_updatedAt": _CLOUDKIT_DATE_FIELD,
    },
}
EXPECTED_CLOUDKIT_V19_RECORD_TYPES = {"CD_CustomerOperationalAlert"}
EXPECTED_CLOUDKIT_V20_ADDITIONS = {
    **EXPECTED_CLOUDKIT_V19_ADDITIONS,
    "CD_BusinessTask": {
        "CD_assignedToEmail": _CLOUDKIT_STRING_FIELD,
        "CD_cancellationOperationID": _CLOUDKIT_STRING_FIELD,
        "CD_cancellationReason": _CLOUDKIT_STRING_FIELD,
        "CD_cancelledAt": _CLOUDKIT_DATE_FIELD,
        "CD_cancelledByEmail": _CLOUDKIT_STRING_FIELD,
        "CD_completedAt": _CLOUDKIT_DATE_FIELD,
        "CD_completedByEmail": _CLOUDKIT_STRING_FIELD,
        "CD_completionNote": _CLOUDKIT_STRING_FIELD,
        "CD_completionOperationID": _CLOUDKIT_STRING_FIELD,
        "CD_createdAt": _CLOUDKIT_DATE_FIELD,
        "CD_createdByEmail": _CLOUDKIT_STRING_FIELD,
        "CD_creationOperationID": _CLOUDKIT_STRING_FIELD,
        "CD_customerID": _CLOUDKIT_STRING_FIELD,
        "CD_customerName": _CLOUDKIT_STRING_FIELD,
        "CD_dueAt": _CLOUDKIT_DATE_FIELD,
        "CD_entityName": _CLOUDKIT_STRING_FIELD,
        "CD_estimateID": _CLOUDKIT_STRING_FIELD,
        "CD_estimateSummary": _CLOUDKIT_STRING_FIELD,
        "CD_id": _CLOUDKIT_STRING_FIELD,
        "CD_priorityRaw": _CLOUDKIT_STRING_FIELD,
        "CD_serviceCallID": _CLOUDKIT_STRING_FIELD,
        "CD_serviceCallSummary": _CLOUDKIT_STRING_FIELD,
        "CD_serviceLocationID": _CLOUDKIT_STRING_FIELD,
        "CD_serviceLocationName": _CLOUDKIT_STRING_FIELD,
        "CD_taskDescription": _CLOUDKIT_STRING_FIELD,
        "CD_title": _CLOUDKIT_STRING_FIELD,
        "CD_updatedAt": _CLOUDKIT_DATE_FIELD,
    },
    "CD_BusinessTaskEvent": {
        "CD_actorEmail": _CLOUDKIT_STRING_FIELD,
        "CD_assignedToEmailSnapshot": _CLOUDKIT_STRING_FIELD,
        "CD_detail": _CLOUDKIT_STRING_FIELD,
        "CD_dueAtSnapshot": _CLOUDKIT_DATE_FIELD,
        "CD_entityName": _CLOUDKIT_STRING_FIELD,
        "CD_id": _CLOUDKIT_STRING_FIELD,
        "CD_kindRaw": _CLOUDKIT_STRING_FIELD,
        "CD_occurredAt": _CLOUDKIT_DATE_FIELD,
        "CD_operationID": _CLOUDKIT_STRING_FIELD,
        "CD_priorityRawSnapshot": _CLOUDKIT_STRING_FIELD,
        "CD_taskID": _CLOUDKIT_STRING_FIELD,
        "CD_titleSnapshot": _CLOUDKIT_STRING_FIELD,
    },
}
EXPECTED_CLOUDKIT_V20_RECORD_TYPES = {"CD_BusinessTask", "CD_BusinessTaskEvent"}
EXPECTED_CLOUDKIT_V21_ADDITIONS = {
    **EXPECTED_CLOUDKIT_V20_ADDITIONS,
    "CD_TechnicianAvailabilityBlock": {
        "CD_cancellationOperationID": _CLOUDKIT_STRING_FIELD,
        "CD_cancellationReason": _CLOUDKIT_STRING_FIELD,
        "CD_cancelledAt": _CLOUDKIT_DATE_FIELD,
        "CD_cancelledByEmail": _CLOUDKIT_STRING_FIELD,
        "CD_createdByEmail": _CLOUDKIT_STRING_FIELD,
        "CD_creationOperationID": _CLOUDKIT_STRING_FIELD,
        "CD_sourceTimeOffRequestID": _CLOUDKIT_STRING_FIELD,
    },
    "CD_TechnicianTimeOffRequest": {
        "CD_approvedAvailabilityBlockID": _CLOUDKIT_STRING_FIELD,
        "CD_cancellationOperationID": _CLOUDKIT_STRING_FIELD,
        "CD_cancellationReason": _CLOUDKIT_STRING_FIELD,
        "CD_cancelledAt": _CLOUDKIT_DATE_FIELD,
        "CD_cancelledByEmail": _CLOUDKIT_STRING_FIELD,
        "CD_createdAt": _CLOUDKIT_DATE_FIELD,
        "CD_creationOperationID": _CLOUDKIT_STRING_FIELD,
        "CD_endsAt": _CLOUDKIT_DATE_FIELD,
        "CD_entityName": _CLOUDKIT_STRING_FIELD,
        "CD_id": _CLOUDKIT_STRING_FIELD,
        "CD_privateReason": _CLOUDKIT_STRING_FIELD,
        "CD_privateReviewNote": _CLOUDKIT_STRING_FIELD,
        "CD_requestedByEmail": _CLOUDKIT_STRING_FIELD,
        "CD_reviewOperationID": _CLOUDKIT_STRING_FIELD,
        "CD_reviewedAt": _CLOUDKIT_DATE_FIELD,
        "CD_reviewedByEmail": _CLOUDKIT_STRING_FIELD,
        "CD_startsAt": _CLOUDKIT_DATE_FIELD,
        "CD_statusRawValue": _CLOUDKIT_STRING_FIELD,
        "CD_technicianID": _CLOUDKIT_STRING_FIELD,
        "CD_technicianNameSnapshot": _CLOUDKIT_STRING_FIELD,
        "CD_updatedAt": _CLOUDKIT_DATE_FIELD,
        "CD_withdrawalOperationID": _CLOUDKIT_STRING_FIELD,
        "CD_withdrawnAt": _CLOUDKIT_DATE_FIELD,
        "CD_withdrawnByEmail": _CLOUDKIT_STRING_FIELD,
    },
    "CD_TechnicianAvailabilityEvent": {
        "CD_actorEmail": _CLOUDKIT_STRING_FIELD,
        "CD_availabilityBlockID": _CLOUDKIT_STRING_FIELD,
        "CD_endsAt": _CLOUDKIT_DATE_FIELD,
        "CD_entityName": _CLOUDKIT_STRING_FIELD,
        "CD_id": _CLOUDKIT_STRING_FIELD,
        "CD_kindRawValue": _CLOUDKIT_STRING_FIELD,
        "CD_occurredAt": _CLOUDKIT_DATE_FIELD,
        "CD_operationID": _CLOUDKIT_STRING_FIELD,
        "CD_privateDetail": _CLOUDKIT_STRING_FIELD,
        "CD_requestID": _CLOUDKIT_STRING_FIELD,
        "CD_requestStatusRawSnapshot": _CLOUDKIT_STRING_FIELD,
        "CD_startsAt": _CLOUDKIT_DATE_FIELD,
        "CD_technicianID": _CLOUDKIT_STRING_FIELD,
        "CD_technicianNameSnapshot": _CLOUDKIT_STRING_FIELD,
    },
}
EXPECTED_CLOUDKIT_V21_RECORD_TYPES = {
    "CD_TechnicianTimeOffRequest",
    "CD_TechnicianAvailabilityEvent",
}
EXPECTED_CLOUDKIT_V22_ADDITIONS = {
    **EXPECTED_CLOUDKIT_V21_ADDITIONS,
    "CD_TechnicianWorkShift": {
        "CD_createdAt": _CLOUDKIT_DATE_FIELD,
        "CD_createdByEmail": _CLOUDKIT_STRING_FIELD,
        "CD_creationOperationID": _CLOUDKIT_STRING_FIELD,
        "CD_durationMinutes": _CLOUDKIT_INTEGER_FIELD,
        "CD_effectiveFrom": _CLOUDKIT_DATE_FIELD,
        "CD_effectiveUntil": _CLOUDKIT_DATE_FIELD,
        "CD_entityName": _CLOUDKIT_STRING_FIELD,
        "CD_id": _CLOUDKIT_STRING_FIELD,
        "CD_kindRawValue": _CLOUDKIT_STRING_FIELD,
        "CD_note": _CLOUDKIT_STRING_FIELD,
        "CD_retiredAt": _CLOUDKIT_DATE_FIELD,
        "CD_retiredByEmail": _CLOUDKIT_STRING_FIELD,
        "CD_retirementOperationID": _CLOUDKIT_STRING_FIELD,
        "CD_retirementReason": _CLOUDKIT_STRING_FIELD,
        "CD_startMinute": _CLOUDKIT_INTEGER_FIELD,
        "CD_technicianID": _CLOUDKIT_STRING_FIELD,
        "CD_technicianNameSnapshot": _CLOUDKIT_STRING_FIELD,
        "CD_timeZoneIdentifier": _CLOUDKIT_STRING_FIELD,
        "CD_weekdayRawValue": _CLOUDKIT_INTEGER_FIELD,
    },
}
EXPECTED_CLOUDKIT_V22_RECORD_TYPES = {"CD_TechnicianWorkShift"}
EXPECTED_CLOUDKIT_V23_ADDITIONS = {
    **EXPECTED_CLOUDKIT_V22_ADDITIONS,
    "CD_Customer": {
        "CD_address": _CLOUDKIT_STRING_FIELD,
        "CD_communicationConsentUpdatedAt": _CLOUDKIT_DATE_FIELD,
        "CD_email": _CLOUDKIT_STRING_FIELD,
        "CD_phone": _CLOUDKIT_STRING_FIELD,
        "CD_quickBooksID": _CLOUDKIT_STRING_FIELD,
    },
    "CD_CustomerCommunication": {
        "CD_backendCommunicationID": _CLOUDKIT_STRING_FIELD,
        "CD_backendSyncError": _CLOUDKIT_STRING_FIELD,
        "CD_estimateID": _CLOUDKIT_STRING_FIELD,
        "CD_invoiceID": _CLOUDKIT_STRING_FIELD,
        "CD_providerMessageID": _CLOUDKIT_STRING_FIELD,
    },
    "CD_CustomerEquipment": {
        "CD_equipmentTypeRaw": _CLOUDKIT_STRING_FIELD,
        "CD_filterSize": _CLOUDKIT_STRING_FIELD,
        "CD_installDate": _CLOUDKIT_DATE_FIELD,
        "CD_location": _CLOUDKIT_STRING_FIELD,
        "CD_manufacturer": _CLOUDKIT_STRING_FIELD,
        "CD_modelNumber": _CLOUDKIT_STRING_FIELD,
        "CD_notes": _CLOUDKIT_STRING_FIELD,
        "CD_serialNumber": _CLOUDKIT_STRING_FIELD,
        "CD_technicalBaselineReadingsJSON": _CLOUDKIT_STRING_FIELD,
        "CD_warrantyExpiration": _CLOUDKIT_DATE_FIELD,
    },
    "CD_Estimate": {
        **EXPECTED_CLOUDKIT_V22_ADDITIONS["CD_Estimate"],
        "CD_catalogSnapshotJSON": _CLOUDKIT_STRING_FIELD,
        "CD_changeOrderReason": _CLOUDKIT_STRING_FIELD,
        "CD_parentEstimateID": _CLOUDKIT_STRING_FIELD,
        "CD_proposalGroupID": _CLOUDKIT_STRING_FIELD,
        "CD_proposalOption": _CLOUDKIT_STRING_FIELD,
        "CD_quickBooksID": _CLOUDKIT_STRING_FIELD,
    },
    "CD_InventoryMovement": {
        **EXPECTED_CLOUDKIT_V22_ADDITIONS["CD_InventoryMovement"],
        "CD_destinationLocation": _CLOUDKIT_STRING_FIELD,
        "CD_serviceCallID": _CLOUDKIT_STRING_FIELD,
        "CD_sourceLocation": _CLOUDKIT_STRING_FIELD,
    },
    "CD_Invoice": {
        **EXPECTED_CLOUDKIT_V22_ADDITIONS["CD_Invoice"],
        "CD_catalogSnapshotJSON": _CLOUDKIT_STRING_FIELD,
        "CD_completionNotes": _CLOUDKIT_STRING_FIELD,
        "CD_customerSignatureImageBase64": _CLOUDKIT_STRING_FIELD,
        "CD_customerSignatureName": _CLOUDKIT_STRING_FIELD,
        "CD_customerSignedAt": _CLOUDKIT_DATE_FIELD,
        "CD_finalizedAt": _CLOUDKIT_DATE_FIELD,
        "CD_quickBooksBalanceDue": _CLOUDKIT_NUMBER_FIELD,
        "CD_quickBooksID": _CLOUDKIT_STRING_FIELD,
        "CD_quickBooksLastSyncedAt": _CLOUDKIT_DATE_FIELD,
        "CD_quickBooksSyncDetail": _CLOUDKIT_STRING_FIELD,
        "CD_serviceCallID": _CLOUDKIT_STRING_FIELD,
    },
    "CD_Payment": {
        "CD_authorizationReference": _CLOUDKIT_STRING_FIELD,
        "CD_cardLast4": _CLOUDKIT_STRING_FIELD,
        "CD_processor": _CLOUDKIT_STRING_FIELD,
        "CD_processorSyncDetail": _CLOUDKIT_STRING_FIELD,
        "CD_processorSyncStatus": _CLOUDKIT_STRING_FIELD,
        "CD_quickBooksAccountingSyncDetail": _CLOUDKIT_STRING_FIELD,
        "CD_quickBooksAccountingSyncStatus": _CLOUDKIT_STRING_FIELD,
        "CD_quickBooksChargeID": _CLOUDKIT_STRING_FIELD,
        "CD_quickBooksClientTransID": _CLOUDKIT_STRING_FIELD,
        "CD_quickBooksDepositID": _CLOUDKIT_STRING_FIELD,
        "CD_quickBooksID": _CLOUDKIT_STRING_FIELD,
        "CD_quickBooksRefundReceiptID": _CLOUDKIT_STRING_FIELD,
        "CD_quickBooksSalesReceiptID": _CLOUDKIT_STRING_FIELD,
        "CD_refundedPaymentID": _CLOUDKIT_STRING_FIELD,
        "CD_settlementBatchID": _CLOUDKIT_STRING_FIELD,
        "CD_storedCardID": _CLOUDKIT_STRING_FIELD,
    },
    "CD_ProjectMilestone": {
        "CD_milestoneDescription": _CLOUDKIT_STRING_FIELD,
        "CD_scheduledVisitID": _CLOUDKIT_STRING_FIELD,
    },
    "CD_PurchaseOrder": {
        "CD_itemSKU": _CLOUDKIT_STRING_FIELD,
        "CD_orderedAt": _CLOUDKIT_DATE_FIELD,
        "CD_receivedAt": _CLOUDKIT_DATE_FIELD,
        "CD_receivedToLocation": _CLOUDKIT_STRING_FIELD,
        "CD_vendorPartNumber": _CLOUDKIT_STRING_FIELD,
        "CD_vendorQuickBooksID": _CLOUDKIT_STRING_FIELD,
    },
    "CD_RecurringMaintenanceContract": {
        "CD_coveredEquipmentIDsJSON": _CLOUDKIT_STRING_FIELD,
        "CD_includedVisitsPerTerm": _CLOUDKIT_INTEGER_FIELD,
        "CD_pricePerVisit": _CLOUDKIT_NUMBER_FIELD,
        "CD_termEndsOn": _CLOUDKIT_DATE_FIELD,
    },
    "CD_ServiceCall": {
        "CD_additionalTechnicianIDsJSON": _CLOUDKIT_STRING_FIELD,
        "CD_cancellationReason": _CLOUDKIT_STRING_FIELD,
        "CD_cancelledAt": _CLOUDKIT_DATE_FIELD,
        "CD_customerEquipmentID": _CLOUDKIT_STRING_FIELD,
        "CD_documentationCompletedAt": _CLOUDKIT_DATE_FIELD,
        "CD_documentationStartedAt": _CLOUDKIT_DATE_FIELD,
        "CD_drainLineCondition": _CLOUDKIT_STRING_FIELD,
        "CD_equipmentInstallDate": _CLOUDKIT_DATE_FIELD,
        "CD_equipmentLocation": _CLOUDKIT_STRING_FIELD,
        "CD_equipmentManufacturer": _CLOUDKIT_STRING_FIELD,
        "CD_equipmentModel": _CLOUDKIT_STRING_FIELD,
        "CD_equipmentName": _CLOUDKIT_STRING_FIELD,
        "CD_equipmentNotes": _CLOUDKIT_STRING_FIELD,
        "CD_equipmentSerialNumber": _CLOUDKIT_STRING_FIELD,
        "CD_equipmentTypeRaw": _CLOUDKIT_STRING_FIELD,
        "CD_equipmentWarrantyExpiration": _CLOUDKIT_DATE_FIELD,
        "CD_filterCondition": _CLOUDKIT_STRING_FIELD,
        "CD_filterSize": _CLOUDKIT_STRING_FIELD,
        "CD_findingsSummary": _CLOUDKIT_STRING_FIELD,
        "CD_followUpAction": _CLOUDKIT_STRING_FIELD,
        "CD_followUpDueDate": _CLOUDKIT_DATE_FIELD,
        "CD_googleCalendarID": _CLOUDKIT_STRING_FIELD,
        "CD_googleEventID": _CLOUDKIT_STRING_FIELD,
        "CD_indoorCoilCondition": _CLOUDKIT_STRING_FIELD,
        "CD_linkedEstimateID": _CLOUDKIT_STRING_FIELD,
        "CD_linkedInvoiceID": _CLOUDKIT_STRING_FIELD,
        "CD_outdoorCoilCondition": _CLOUDKIT_STRING_FIELD,
        "CD_promisedArrivalWindowEnd": _CLOUDKIT_DATE_FIELD,
        "CD_promisedArrivalWindowStart": _CLOUDKIT_DATE_FIELD,
        "CD_recommendedWorkSummary": _CLOUDKIT_STRING_FIELD,
        "CD_serviceActionChecklistJSON": _CLOUDKIT_STRING_FIELD,
        "CD_serviceReportReadingsJSON": _CLOUDKIT_STRING_FIELD,
        "CD_serviceReportSummary": _CLOUDKIT_STRING_FIELD,
        "CD_technicianArrivedAt": _CLOUDKIT_DATE_FIELD,
        "CD_technicianEnRouteAt": _CLOUDKIT_DATE_FIELD,
        "CD_thermostatOperation": _CLOUDKIT_STRING_FIELD,
        "CD_visitDispositionNotes": _CLOUDKIT_STRING_FIELD,
    },
    "CD_ServiceRequest": {
        "CD_address": _CLOUDKIT_STRING_FIELD,
        "CD_backendRequestID": _CLOUDKIT_STRING_FIELD,
        "CD_convertedCustomerID": _CLOUDKIT_STRING_FIELD,
        "CD_convertedServiceCallID": _CLOUDKIT_STRING_FIELD,
        "CD_email": _CLOUDKIT_STRING_FIELD,
        "CD_phone": _CLOUDKIT_STRING_FIELD,
        "CD_preferredDate": _CLOUDKIT_DATE_FIELD,
        "CD_qualifiedAt": _CLOUDKIT_DATE_FIELD,
    },
    "CD_Technician": {
        "CD_laborCostPerHour": _CLOUDKIT_NUMBER_FIELD,
        "CD_qualificationNotes": _CLOUDKIT_STRING_FIELD,
        "CD_serviceAreasJSON": _CLOUDKIT_STRING_FIELD,
        "CD_supportedEquipmentTypesJSON": _CLOUDKIT_STRING_FIELD,
    },
    "CD_TimeEntry": {
        "CD_quickBooksTimeActivityID": _CLOUDKIT_STRING_FIELD,
        "CD_quickBooksTimeActivitySyncError": _CLOUDKIT_STRING_FIELD,
        "CD_quickBooksTimeActivitySyncToken": _CLOUDKIT_STRING_FIELD,
        "CD_quickBooksTimeActivitySyncedAt": _CLOUDKIT_DATE_FIELD,
    },
    "CD_Vendor": {
        "CD_contactInfo": _CLOUDKIT_STRING_FIELD,
        "CD_quickBooksID": _CLOUDKIT_STRING_FIELD,
    },
}
EXPECTED_CLOUDKIT_BASELINE_RECORD_TYPES = {
    "CD_AppUser",
    "CD_Customer",
    "CD_CustomerCommunication",
    "CD_CustomerEquipment",
    "CD_CustomerServiceLocation",
    "CD_Estimate",
    "CD_FieldFormResponse",
    "CD_FieldFormTemplate",
    "CD_InventoryMovement",
    "CD_Invoice",
    "CD_Item",
    "CD_Payment",
    "CD_ProjectMilestone",
    "CD_PurchaseOrder",
    "CD_RecurringMaintenanceContract",
    "CD_ServiceCall",
    "CD_ServiceCallActivity",
    "CD_ServiceDocumentAttachment",
    "CD_ServiceRequest",
    "CD_Technician",
    "CD_TechnicianAvailabilityBlock",
    "CD_TimeEntry",
    "CD_Vendor",
    "Users",
}
EXPECTED_CLOUDKIT_SYSTEM_FIELDS = (
    '"___createTime" TIMESTAMP',
    '"___createdBy" REFERENCE',
    '"___etag" STRING',
    '"___modTime" TIMESTAMP',
    '"___modifiedBy" REFERENCE',
    '"___recordID" REFERENCE',
)
EXPECTED_CLOUDKIT_RECORD_GRANTS = (
    'GRANT WRITE TO "_creator"',
    'GRANT CREATE TO "_icloud"',
    'GRANT READ TO "_world"',
)


@dataclass
class Results:
    passed: int = 0
    warnings: int = 0
    failures: list[str] = field(default_factory=list)

    def pass_(self, message: str) -> None:
        self.passed += 1
        print(f"PASS  {message}")

    def warn(self, message: str) -> None:
        self.warnings += 1
        print(f"WARN  {message}")

    def fail(self, message: str) -> None:
        self.failures.append(message)
        print(f"FAIL  {message}")

    def require(self, condition: bool, success: str, failure: str) -> bool:
        if condition:
            self.pass_(success)
            return True
        self.fail(failure)
        return False


def parse_args() -> argparse.Namespace:
    script_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, default=script_root)
    parser.add_argument(
        "--archive",
        type=Path,
        help="Exact .xcarchive to validate; newest matching Current Source archive is used by default.",
    )
    parser.add_argument("--cloudkit-development-export", type=Path)
    parser.add_argument("--cloudkit-production-export", type=Path)
    parser.add_argument(
        "--app-store-profile",
        type=Path,
        help="Installed App Store .mobileprovision; a matching Xcode-managed profile is discovered by default.",
    )
    parser.add_argument(
        "--mac-app",
        type=Path,
        help="Exact current-source Mac Catalyst .app; the standard derived-data artifact is discovered by default.",
    )
    parser.add_argument(
        "--mac-result",
        type=Path,
        help="Mac Catalyst build .xcresult; the standard result bundle is discovered by default.",
    )
    parser.add_argument(
        "--online",
        action="store_true",
        help="Also probe production health, Apple notification routing, and the QBO callback.",
    )
    parser.add_argument(
        "--require-app-store-signing",
        action="store_true",
        help="Treat a development-signed archive as a failure instead of a release warning.",
    )
    return parser.parse_args()


def run(command: list[str], *, check: bool = True) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(command, check=check, capture_output=True)


def load_plist(path: Path) -> dict[str, Any]:
    with path.open("rb") as stream:
        value = plistlib.load(stream)
    if not isinstance(value, dict):
        raise ValueError(f"{path} is not a dictionary property list")
    return value


def load_json_object(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise ValueError(f"{path} is not a JSON object")
    return value


def is_https_url(value: Any) -> bool:
    return isinstance(value, str) and value.startswith("https://") and len(value) > 8


def forbidden_secret_fields(value: Any, path: str = "") -> list[str]:
    matches: list[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            child_path = f"{path}.{key}" if path else str(key)
            normalized_key = re.sub(r"[^a-z0-9]", "", str(key).lower())
            if any(
                fragment in normalized_key
                for fragment in ("password", "clientsecret", "privatekey", "apitoken", "accesstoken", "refreshtoken")
            ):
                matches.append(child_path)
            matches.extend(forbidden_secret_fields(child, child_path))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            matches.extend(forbidden_secret_fields(child, f"{path}[{index}]"))
    return matches


def check_app_store_metadata(root: Path, results: Results) -> None:
    metadata_path = root / EXPECTED_APP_STORE_METADATA_PATH
    privacy_path = root / "GunnAire Ops" / "PrivacyInfo.xcprivacy"
    try:
        metadata = load_json_object(metadata_path)
        privacy_manifest = load_plist(privacy_path)
    except (OSError, ValueError, json.JSONDecodeError, plistlib.InvalidFileException) as error:
        results.fail(f"App Store metadata inspection failed: {error}")
        return

    app = metadata.get("app")
    app_review = metadata.get("appReview")
    privacy = metadata.get("privacy")
    if not isinstance(app, dict) or not isinstance(app_review, dict) or not isinstance(privacy, dict):
        results.fail("App Store metadata contract is missing app, appReview, or privacy objects")
        return

    results.require(
        metadata.get("schemaVersion") == 1
        and app.get("bundleID") == EXPECTED_BUNDLE_ID
        and app.get("primaryLocale") == EXPECTED_APP_STORE_LOCALE,
        "App Store metadata contract identifies the GunnAire bundle and primary locale",
        "App Store metadata contract has an unexpected schema, bundle identifier, or locale",
    )
    results.require(
        is_https_url(app.get("privacyPolicyURL"))
        and is_https_url(app.get("supportURL"))
        and is_https_url(app.get("marketingURL")),
        "App Store privacy, support, and marketing URLs use HTTPS",
        "App Store privacy, support, and marketing URLs must all be explicit HTTPS URLs",
    )
    forbidden_fields = forbidden_secret_fields(metadata)
    results.require(
        not forbidden_fields
        and app_review.get("requiresSignIn") is True
        and app_review.get("credentialStorage") == "App Store Connect only",
        "App Review sign-in is declared without committing credentials or secrets",
        "App Review metadata must require sign-in, keep credentials only in App Store Connect, and contain no secret fields: "
        f"{forbidden_fields}",
    )

    manifest_rows = privacy_manifest.get("NSPrivacyCollectedDataTypes", [])
    contract_rows = privacy.get("dataTypes", [])
    if not isinstance(manifest_rows, list) or not isinstance(contract_rows, list):
        results.fail("Privacy data types must be arrays in both source manifests")
        return

    manifest_by_type: dict[str, dict[str, Any]] = {}
    contract_by_type: dict[str, dict[str, Any]] = {}
    duplicate_types: set[str] = set()
    malformed_rows = False
    for row in manifest_rows:
        if not isinstance(row, dict):
            malformed_rows = True
            continue
        data_type = row.get("NSPrivacyCollectedDataType")
        if not isinstance(data_type, str) or not data_type:
            malformed_rows = True
            continue
        if data_type in manifest_by_type:
            duplicate_types.add(data_type)
        manifest_by_type[data_type] = row
    for row in contract_rows:
        if not isinstance(row, dict):
            malformed_rows = True
            continue
        data_type = row.get("manifestDataType")
        if not isinstance(data_type, str) or not data_type:
            malformed_rows = True
            continue
        if data_type in contract_by_type:
            duplicate_types.add(data_type)
        contract_by_type[data_type] = row

    results.require(
        not malformed_rows and not duplicate_types,
        "App Store privacy contract contains unique, well-formed data-type answers",
        f"App Store privacy contract contains malformed or duplicate data types: {sorted(duplicate_types)}",
    )
    results.require(
        set(contract_by_type) == set(manifest_by_type),
        "App Store privacy answers exactly cover every source privacy-manifest data type",
        "App Store privacy answers and PrivacyInfo.xcprivacy differ: "
        f"contract-only={sorted(set(contract_by_type) - set(manifest_by_type))}, "
        f"manifest-only={sorted(set(manifest_by_type) - set(contract_by_type))}",
    )

    mismatches: list[str] = []
    for data_type in sorted(set(contract_by_type) & set(manifest_by_type)):
        contract_row = contract_by_type[data_type]
        manifest_row = manifest_by_type[data_type]
        contract_purposes = contract_row.get("purposes")
        manifest_purposes = manifest_row.get("NSPrivacyCollectedDataTypePurposes")
        if (
            contract_row.get("linkedToUser")
            != manifest_row.get("NSPrivacyCollectedDataTypeLinked")
            or contract_row.get("tracking")
            != manifest_row.get("NSPrivacyCollectedDataTypeTracking")
            or not isinstance(contract_purposes, list)
            or not isinstance(manifest_purposes, list)
            or set(contract_purposes) != set(manifest_purposes)
            or set(contract_purposes) != {EXPECTED_APP_STORE_PRIVACY_PURPOSE}
            or not str(contract_row.get("category", "")).strip()
            or not str(contract_row.get("displayName", "")).strip()
            or not str(contract_row.get("usage", "")).strip()
        ):
            mismatches.append(data_type)
    results.require(
        not mismatches,
        "App Store privacy linkage, tracking, purpose, labels, and usage explanations match the source manifest",
        f"App Store privacy answers do not match PrivacyInfo.xcprivacy for: {mismatches}",
    )
    results.require(
        privacy.get("tracking") is privacy_manifest.get("NSPrivacyTracking") is False,
        "App Store metadata and source privacy manifest both declare no tracking",
        "App Store metadata and source privacy manifest disagree about tracking",
    )


def png_dimensions_and_alpha(path: Path) -> tuple[int, int, bool]:
    """Return PNG dimensions and whether the encoded image can contain transparency."""
    signature = b"\x89PNG\r\n\x1a\n"
    with path.open("rb") as stream:
        if stream.read(len(signature)) != signature:
            raise ValueError(f"{path} is not a PNG file")

        width = height = color_type = None
        has_transparency_chunk = False
        saw_idat = False
        saw_iend = False
        chunk_index = 0
        while not saw_iend:
            header = stream.read(8)
            if len(header) != 8:
                raise ValueError(f"{path} has a truncated PNG chunk header")
            length, chunk_type = struct.unpack(">I4s", header)
            if length > 256 * 1024 * 1024:
                raise ValueError(f"{path} contains an unreasonably large PNG chunk")
            chunk_data = stream.read(length)
            encoded_crc = stream.read(4)
            if len(chunk_data) != length or len(encoded_crc) != 4:
                raise ValueError(f"{path} has a truncated PNG chunk")
            expected_crc = zlib.crc32(chunk_type)
            expected_crc = zlib.crc32(chunk_data, expected_crc) & 0xFFFFFFFF
            if struct.unpack(">I", encoded_crc)[0] != expected_crc:
                raise ValueError(f"{path} has an invalid PNG chunk checksum")

            if chunk_index == 0 and chunk_type != b"IHDR":
                raise ValueError(f"{path} does not begin with a PNG IHDR chunk")
            if chunk_type == b"IHDR":
                if chunk_index != 0 or length != 13 or width is not None:
                    raise ValueError(f"{path} has an invalid PNG IHDR chunk")
                width, height, _, color_type, _, _, _ = struct.unpack(
                    ">IIBBBBB", chunk_data
                )
                if width < 1 or height < 1 or color_type not in {0, 2, 3, 4, 6}:
                    raise ValueError(f"{path} has unsupported PNG image metadata")
            elif chunk_type == b"tRNS":
                has_transparency_chunk = True
            elif chunk_type == b"IDAT":
                saw_idat = True
            elif chunk_type == b"IEND":
                if length != 0:
                    raise ValueError(f"{path} has an invalid PNG IEND chunk")
                saw_iend = True
            chunk_index += 1

        if stream.read(1):
            raise ValueError(f"{path} contains data after the PNG IEND chunk")
        if width is None or height is None or color_type is None or not saw_idat:
            raise ValueError(f"{path} is missing required PNG chunks")
        return width, height, color_type in {4, 6} or has_transparency_chunk


def check_app_store_screenshots(
    root: Path,
    marketing_version: str,
    build_version: str,
    results: Results,
) -> None:
    manifest_path = root / EXPECTED_APP_STORE_SCREENSHOT_MANIFEST_PATH
    try:
        manifest = load_json_object(manifest_path)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        results.fail(f"App Store screenshot manifest inspection failed: {error}")
        return

    contract_errors: list[str] = []
    if manifest.get("schemaVersion") != 1:
        contract_errors.append("schemaVersion must be 1")
    if manifest.get("sourceVersion") != marketing_version:
        contract_errors.append(
            f"sourceVersion must be {marketing_version!r}"
        )
    if manifest.get("sourceBuild") != build_version:
        contract_errors.append(f"sourceBuild must be {build_version!r}")
    reviewed_at = manifest.get("reviewedAt")
    try:
        parsed_reviewed_at = datetime.strptime(str(reviewed_at), "%Y-%m-%d")
    except ValueError:
        parsed_reviewed_at = None
    if (
        parsed_reviewed_at is None
        or parsed_reviewed_at.strftime("%Y-%m-%d") != reviewed_at
    ):
        contract_errors.append("reviewedAt must use YYYY-MM-DD")

    expected_set_names = set(EXPECTED_APP_STORE_SCREENSHOT_SETS)
    capture_evidence = manifest.get("captureEvidence")
    if not isinstance(capture_evidence, dict) or set(capture_evidence) != expected_set_names:
        contract_errors.append("captureEvidence must identify both expected device sets")
    else:
        for set_name, evidence_name in capture_evidence.items():
            if (
                not isinstance(evidence_name, str)
                or not evidence_name.endswith(".xcresult")
                or Path(evidence_name).name != evidence_name
                or build_version not in evidence_name
            ):
                contract_errors.append(
                    f"captureEvidence.{set_name} must be a non-path xcresult name for build {build_version}"
                )

    screenshot_sets = manifest.get("sets")
    if not isinstance(screenshot_sets, dict) or set(screenshot_sets) != expected_set_names:
        contract_errors.append("sets must exactly identify the expected device sets")
        screenshot_sets = {}

    results.require(
        not contract_errors,
        f"App Store screenshot manifest matches source version {marketing_version} ({build_version})",
        "App Store screenshot manifest is stale or malformed: "
        + "; ".join(contract_errors),
    )

    asset_errors: list[str] = []
    screenshots_root = root / "AppStoreAssets" / "Screenshots"
    if screenshots_root.is_dir():
        actual_set_names = {
            path.name for path in screenshots_root.iterdir() if path.is_dir()
        }
        if actual_set_names != expected_set_names:
            asset_errors.append(
                "screenshot directories differ: "
                f"unexpected={sorted(actual_set_names - expected_set_names)}, "
                f"missing={sorted(expected_set_names - actual_set_names)}"
            )
    else:
        asset_errors.append("AppStoreAssets/Screenshots is missing")

    for set_name, expected in EXPECTED_APP_STORE_SCREENSHOT_SETS.items():
        set_contract = screenshot_sets.get(set_name)
        if not isinstance(set_contract, dict):
            asset_errors.append(f"{set_name} manifest entry is missing")
            continue
        if (
            set_contract.get("width") != expected["width"]
            or set_contract.get("height") != expected["height"]
        ):
            asset_errors.append(
                f"{set_name} manifest dimensions must be "
                f"{expected['width']}x{expected['height']}"
            )

        file_rows = set_contract.get("files")
        if not isinstance(file_rows, list):
            asset_errors.append(f"{set_name}.files must be an array")
            continue
        hashes: dict[str, str] = {}
        malformed_rows = False
        for row in file_rows:
            if not isinstance(row, dict):
                malformed_rows = True
                continue
            name = row.get("name")
            digest = row.get("sha256")
            if (
                not isinstance(name, str)
                or Path(name).name != name
                or not re.fullmatch(r"[0-9a-f]{64}", str(digest or ""))
                or name in hashes
            ):
                malformed_rows = True
                continue
            hashes[name] = str(digest)
        if malformed_rows:
            asset_errors.append(f"{set_name} contains malformed or duplicate file rows")

        expected_names = set(expected["filenames"])
        if set(hashes) != expected_names:
            asset_errors.append(
                f"{set_name} manifest files differ: "
                f"unexpected={sorted(set(hashes) - expected_names)}, "
                f"missing={sorted(expected_names - set(hashes))}"
            )

        set_directory = screenshots_root / set_name
        actual_names = (
            {path.name for path in set_directory.glob("*.png") if path.is_file()}
            if set_directory.is_dir()
            else set()
        )
        if actual_names != expected_names:
            asset_errors.append(
                f"{set_name} PNG files differ: "
                f"unexpected={sorted(actual_names - expected_names)}, "
                f"missing={sorted(expected_names - actual_names)}"
            )

        for filename in expected["filenames"]:
            screenshot_path = set_directory / filename
            if not screenshot_path.is_file():
                continue
            recorded_digest = hashes.get(filename)
            if recorded_digest and sha256(screenshot_path) != recorded_digest:
                asset_errors.append(f"{set_name}/{filename} does not match its audited hash")
            try:
                width, height, has_alpha = png_dimensions_and_alpha(screenshot_path)
            except (OSError, ValueError, struct.error) as error:
                asset_errors.append(f"{set_name}/{filename} is invalid: {error}")
                continue
            if (width, height) != (expected["width"], expected["height"]):
                asset_errors.append(
                    f"{set_name}/{filename} is {width}x{height}, expected "
                    f"{expected['width']}x{expected['height']}"
                )
            if has_alpha:
                asset_errors.append(f"{set_name}/{filename} contains transparency")

    results.require(
        not asset_errors,
        "App Store screenshot assets match the audited 13-inch iPad and 6.9-inch iPhone sets",
        "App Store screenshot asset validation failed: " + "; ".join(asset_errors),
    )


def configured_url_schemes(info: dict[str, Any]) -> set[str]:
    schemes: set[str] = set()
    for url_type in info.get("CFBundleURLTypes", []):
        if not isinstance(url_type, dict):
            continue
        for scheme in url_type.get("CFBundleURLSchemes", []):
            if isinstance(scheme, str) and scheme:
                schemes.add(scheme)
    return schemes


def google_native_oauth_is_consistent(info: dict[str, Any]) -> bool:
    client_id = str(info.get("GOOGLE_CLIENT_ID", "")).strip()
    reversed_client_id = str(info.get("GOOGLE_REVERSED_CLIENT_ID", "")).strip()
    callback_scheme = str(info.get("GOOGLE_CALLBACK_SCHEME", "")).strip()
    redirect_uri = str(info.get("GOOGLE_REDIRECT_URI", "")).strip()
    suffix = ".apps.googleusercontent.com"
    if not client_id.endswith(suffix):
        return False
    expected_scheme = f"com.googleusercontent.apps.{client_id.removesuffix(suffix)}"
    return (
        reversed_client_id == expected_scheme
        and callback_scheme == expected_scheme
        and redirect_uri == f"{expected_scheme}:/oauth2redirect"
        and expected_scheme in configured_url_schemes(info)
    )


def source_versions(project_file: Path) -> tuple[str, str]:
    source = project_file.read_text(encoding="utf-8")
    builds = set(re.findall(r"CURRENT_PROJECT_VERSION = ([^;]+);", source))
    versions = set(re.findall(r"MARKETING_VERSION = ([^;]+);", source))
    if len(builds) != 1 or len(versions) != 1:
        raise ValueError(
            f"Expected one build/version across targets, found builds={sorted(builds)} versions={sorted(versions)}"
        )
    return versions.pop().strip('"'), builds.pop().strip('"')


def source_backend_version(backend_file: Path) -> str:
    match = re.search(
        r'^SERVICE_VERSION\s*=\s*"([^"]+)"',
        backend_file.read_text(encoding="utf-8"),
        re.MULTILINE,
    )
    if match is None:
        raise ValueError("Backend SERVICE_VERSION is missing")
    return match.group(1)


def find_archive(marketing_version: str, build_version: str) -> Path | None:
    releases = Path.home() / "Downloads" / "GunnAire Ops Releases"
    if not releases.is_dir():
        return None
    pattern = f"GunnAire Ops {marketing_version} ({build_version} Current Source).xcarchive"
    candidates = list(releases.rglob(pattern))
    return max(candidates, key=lambda path: path.stat().st_mtime) if candidates else None


def find_app_store_profile() -> Path | None:
    profiles_root = (
        Path.home()
        / "Library"
        / "Developer"
        / "Xcode"
        / "UserData"
        / "Provisioning Profiles"
    )
    if not profiles_root.is_dir():
        return None
    candidates: list[Path] = []
    for suffix in ("*.mobileprovision", "*.provisionprofile"):
        for path in profiles_root.glob(suffix):
            try:
                profile = extract_profile(path)
            except (OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError):
                continue
            entitlements = profile.get("Entitlements", {})
            if (
                entitlements.get("application-identifier")
                == f"{EXPECTED_TEAM_ID}.{EXPECTED_BUNDLE_ID}"
                and entitlements.get("get-task-allow") is False
            ):
                candidates.append(path)
    return max(candidates, key=lambda path: path.stat().st_mtime) if candidates else None


def find_mac_app(build_version: str) -> Path | None:
    releases = Path.home() / "Downloads" / "GunnAire Ops Releases"
    retained_name = f"GunnAire Ops 1.0 ({build_version} Current Source Mac Catalyst).app"
    retained = list(releases.rglob(retained_name)) if releases.is_dir() else []
    if retained:
        return max(retained, key=lambda path: path.stat().st_mtime)
    temporary = (
        Path("/tmp")
        / f"GunnAireOps-mac-release-{build_version}"
        / "Build"
        / "Products"
        / "Release-maccatalyst"
        / "GunnAire Ops.app"
    )
    return temporary if temporary.is_dir() else None


def find_mac_result(build_version: str) -> Path | None:
    releases = Path.home() / "Downloads" / "GunnAire Ops Releases"
    retained_name = f"GunnAire Ops 1.0 ({build_version} Current Source Mac Catalyst).xcresult"
    retained = list(releases.rglob(retained_name)) if releases.is_dir() else []
    if retained:
        return max(retained, key=lambda path: path.stat().st_mtime)
    temporary = Path("/tmp") / f"GunnAireOps-mac-release-{build_version}.xcresult"
    return temporary if temporary.is_dir() else None


def extract_codesign_entitlements(app_path: Path) -> dict[str, Any]:
    process = run(["codesign", "-d", "--entitlements", ":-", str(app_path)], check=False)
    payload = process.stdout if b"<?xml" in process.stdout else process.stderr
    start = payload.find(b"<?xml")
    end = payload.rfind(b"</plist>")
    if start < 0:
        raise ValueError((process.stdout + process.stderr).decode("utf-8", errors="replace").strip())
    if end < start:
        raise ValueError("codesign entitlement property list is incomplete")
    return plistlib.loads(payload[start : end + len(b"</plist>")])


def extract_profile(profile_path: Path) -> dict[str, Any]:
    process = run(["security", "cms", "-D", "-i", str(profile_path)])
    return plistlib.loads(process.stdout)


def binary_uuids(path: Path) -> set[str]:
    output = run(["dwarfdump", "--uuid", str(path)]).stdout.decode("utf-8")
    return set(re.findall(r"UUID: ([0-9A-F-]+)", output))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def is_future_datetime(value: Any) -> bool:
    return isinstance(value, datetime) and value > datetime.now(tz=value.tzinfo)


def check_source(root: Path, results: Results) -> tuple[str, str, str]:
    try:
        marketing_version, build_version = source_versions(
            root / "GunnAire Ops.xcodeproj" / "project.pbxproj"
        )
        backend_version = source_backend_version(root / "Backend" / "gunnaire_backend.py")
    except (OSError, ValueError) as error:
        results.fail(f"Source version inspection failed: {error}")
        return "", "", ""

    results.pass_(f"Source version is {marketing_version} ({build_version})")
    results.pass_(f"Backend source version is {backend_version}")

    for relative in (
        Path("GunnAire Ops") / "GunnAire Ops.entitlements",
        Path("GunnAire Ops") / "PrivacyInfo.xcprivacy",
        Path("GunnAire Ops") / "Info.plist",
    ):
        process = run(["plutil", "-lint", str(root / relative)], check=False)
        results.require(
            process.returncode == 0,
            f"{relative} is a valid property list",
            f"{relative} failed property-list validation",
        )

    try:
        source_entitlements = load_plist(root / "GunnAire Ops" / "GunnAire Ops.entitlements")
        results.require(
            source_entitlements.get("com.apple.developer.applesignin") == ["Default"],
            "Source declares Sign in with Apple",
            "Source is missing the Sign in with Apple entitlement",
        )
        results.require(
            EXPECTED_ICLOUD_CONTAINER
            in source_entitlements.get("com.apple.developer.icloud-container-identifiers", []),
            "Source declares the GunnAire CloudKit container",
            "Source is missing the GunnAire CloudKit container",
        )
        results.require(
            source_entitlements.get("com.apple.developer.icloud-services") == ["CloudKit"],
            "Source declares CloudKit service",
            "Source CloudKit service entitlement is incorrect",
        )
        results.require(
            EXPECTED_ASSOCIATED_DOMAIN
            in source_entitlements.get("com.apple.developer.associated-domains", []),
            "Source declares the GunnAire associated domain",
            "Source associated-domain entitlement is missing",
        )
        results.require(
            source_entitlements.get("aps-environment") == "development",
            "Source declares Push Notifications for development signing",
            "Source push entitlement is missing or unexpected",
        )
    except (OSError, ValueError) as error:
        results.fail(f"Source entitlement inspection failed: {error}")

    check_app_store_metadata(root, results)
    check_app_store_screenshots(root, marketing_version, build_version, results)

    return marketing_version, build_version, backend_version


def check_archive(
    archive: Path,
    marketing_version: str,
    build_version: str,
    require_app_store_signing: bool,
    results: Results,
) -> None:
    app_path = archive / "Products" / "Applications" / "GunnAire Ops.app"
    binary_path = app_path / "GunnAire Ops"
    dsym_binary = (
        archive
        / "dSYMs"
        / "GunnAire Ops.app.dSYM"
        / "Contents"
        / "Resources"
        / "DWARF"
        / "GunnAire Ops"
    )
    required_paths = (
        archive / "Info.plist",
        app_path / "Info.plist",
        app_path / "PrivacyInfo.xcprivacy",
        app_path / "embedded.mobileprovision",
        binary_path,
        dsym_binary,
    )
    if not results.require(
        archive.is_dir() and all(path.exists() for path in required_paths),
        f"Archive contains the expected app, profile, binary, privacy manifest, and dSYM: {archive}",
        f"Archive is missing or incomplete: {archive}",
    ):
        return

    verification = run(
        ["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app_path)],
        check=False,
    )
    results.require(
        verification.returncode == 0,
        "Archive passes strict code-signature verification",
        "Archive failed strict code-signature verification",
    )
    privacy = run(["plutil", "-lint", str(app_path / "PrivacyInfo.xcprivacy")], check=False)
    results.require(
        privacy.returncode == 0,
        "Archived privacy manifest is valid",
        "Archived privacy manifest is invalid",
    )

    try:
        archive_info = load_plist(archive / "Info.plist")
        app_info = load_plist(app_path / "Info.plist")
        properties = archive_info.get("ApplicationProperties", {})
        results.require(
            app_info.get("CFBundleIdentifier") == EXPECTED_BUNDLE_ID,
            f"Archived bundle identifier is {EXPECTED_BUNDLE_ID}",
            f"Archived bundle identifier is {app_info.get('CFBundleIdentifier')!r}",
        )
        results.require(
            app_info.get("CFBundleShortVersionString") == marketing_version
            and app_info.get("CFBundleVersion") == build_version,
            f"Archive exactly matches source version {marketing_version} ({build_version})",
            "Archive version/build does not match the source",
        )
        results.require(
            set(app_info.get("UIDeviceFamily", [])) == {1, 2},
            "Archive supports iPhone and iPad device families",
            f"Unexpected archived device families: {app_info.get('UIDeviceFamily')!r}",
        )
        expected_phone_orientations = {
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight",
        }
        expected_ipad_orientations = expected_phone_orientations | {
            "UIInterfaceOrientationPortraitUpsideDown"
        }
        results.require(
            set(app_info.get("UISupportedInterfaceOrientations", []))
            == expected_phone_orientations
            and set(app_info.get("UISupportedInterfaceOrientations~ipad", []))
            == expected_ipad_orientations,
            "Archive supports portrait and landscape operation, including all iPad orientations",
            "Archived iPhone/iPad orientation support is incomplete",
        )
        results.require(
            app_info.get("ITSAppUsesNonExemptEncryption") is False,
            "Archive declares no non-exempt encryption for export-compliance routing",
            "Archived export-compliance declaration is missing or unexpected",
        )

        expected_settings = {
            "GUNNAIRE_BACKEND_BASE_URL": EXPECTED_BACKEND_URL,
            "GUNNAIRE_BACKEND_AUTH_MODE": "google-id-token",
            "GUNNAIRE_BACKEND_API_TOKEN": "",
            "QB_ENVIRONMENT": "production",
            "QB_REDIRECT_URI": EXPECTED_QBO_REDIRECT,
            "QB_CALLBACK_SCHEME": EXPECTED_QBO_CALLBACK_SCHEME,
            "QB_ENABLE_PAYMENTS_SCOPE": "true",
        }
        mismatches = {
            key: app_info.get(key)
            for key, expected in expected_settings.items()
            if app_info.get(key) != expected
        }
        results.require(
            not mismatches,
            "Archive uses HTTPS business identity, an empty shared token, and production QBO settings",
            f"Archived production settings are incorrect: {mismatches}",
        )
        results.require(
            bool(str(app_info.get("QB_CLIENT_ID", "")).strip()),
            "Archive contains a non-secret QBO client identifier",
            "Archive is missing the QBO client identifier",
        )
        results.require(
            google_native_oauth_is_consistent(app_info),
            "Archive contains a consistent native Google OAuth client, reversed callback, redirect URI, and registered URL scheme",
            "Archived native Google OAuth identifiers, redirect URI, or registered URL scheme are incomplete or inconsistent",
        )

        entitlements = extract_codesign_entitlements(app_path)
        profile = extract_profile(app_path / "embedded.mobileprovision")
        profile_entitlements = profile.get("Entitlements", {})
        archived_privacy = load_plist(app_path / "PrivacyInfo.xcprivacy")
        collected_types = {
            row.get("NSPrivacyCollectedDataType")
            for row in archived_privacy.get("NSPrivacyCollectedDataTypes", [])
            if isinstance(row, dict)
        }
        results.require(
            {
                "NSPrivacyCollectedDataTypeDeviceID",
                "NSPrivacyCollectedDataTypePaymentInfo",
                "NSPrivacyCollectedDataTypeOtherFinancialInfo",
            }.issubset(collected_types),
            "Privacy manifest covers device, payment, and financial app-functionality data",
            "Privacy manifest omits a release-critical device/payment/financial data category",
        )
        expected_application_id = f"{EXPECTED_TEAM_ID}.{EXPECTED_BUNDLE_ID}"
        checks = (
            (
                entitlements.get("application-identifier") == expected_application_id,
                "Archive application identifier matches the Apple team and bundle",
                "Archive application identifier does not match the Apple team and bundle",
            ),
            (
                entitlements.get("com.apple.developer.applesignin") == ["Default"],
                "Archive includes Sign in with Apple",
                "Archive is missing Sign in with Apple",
            ),
            (
                EXPECTED_ICLOUD_CONTAINER
                in entitlements.get("com.apple.developer.icloud-container-identifiers", []),
                "Archive includes the GunnAire CloudKit container",
                "Archive is missing the GunnAire CloudKit container",
            ),
            (
                entitlements.get("com.apple.developer.icloud-services") == ["CloudKit"],
                "Archive includes the CloudKit service entitlement",
                "Archive CloudKit service entitlement is missing or unexpected",
            ),
            (
                EXPECTED_ASSOCIATED_DOMAIN
                in entitlements.get("com.apple.developer.associated-domains", []),
                "Archive includes the GunnAire associated domain",
                "Archive is missing the GunnAire associated domain",
            ),
            (
                entitlements.get("aps-environment") in {"development", "production"},
                f"Archive includes {entitlements.get('aps-environment')} APNs",
                "Archive is missing the APNs entitlement",
            ),
            (
                profile_entitlements.get("application-identifier") == expected_application_id,
                "Embedded profile matches the GunnAire application identifier",
                "Embedded profile has an unexpected application identifier",
            ),
        )
        for condition, success, failure in checks:
            results.require(condition, success, failure)

        results.require(
            is_future_datetime(profile.get("ExpirationDate"))
            and EXPECTED_TEAM_ID in profile.get("TeamIdentifier", []),
            f"Embedded profile is current and belongs to Apple team {EXPECTED_TEAM_ID}",
            "Embedded profile is expired or belongs to an unexpected Apple team",
        )

        signing_identity = str(properties.get("SigningIdentity", ""))
        uploadable = (
            signing_identity.startswith("Apple Distribution")
            and entitlements.get("get-task-allow") is False
            and entitlements.get("aps-environment") == "production"
        )
        profile_id = profile.get("UUID", "unknown")
        if uploadable:
            results.pass_(f"Archive is App Store distribution signed with profile {profile_id}")
        elif require_app_store_signing:
            results.fail(
                f"Archive is not App Store uploadable: identity={signing_identity!r}, profile={profile_id}"
            )
        else:
            results.warn(
                f"Archive is correctly validated but development signed with profile {profile_id}; "
                "an Apple Distribution private key is still required for upload"
            )
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        results.fail(f"Archive metadata/entitlement inspection failed: {error}")

    try:
        app_uuids = binary_uuids(binary_path)
        dsym_uuids = binary_uuids(dsym_binary)
        results.require(
            bool(app_uuids) and app_uuids == dsym_uuids,
            f"App and dSYM UUIDs match: {', '.join(sorted(app_uuids))}",
            f"App/dSYM UUID mismatch: app={sorted(app_uuids)} dSYM={sorted(dsym_uuids)}",
        )
        results.pass_(f"Release binary SHA-256 is {sha256(binary_path)}")
    except (OSError, subprocess.CalledProcessError) as error:
        results.fail(f"Binary/dSYM inspection failed: {error}")

    strings_process = run(["strings", str(binary_path)], check=False)
    strings_text = strings_process.stdout.decode("utf-8", errors="replace")
    forbidden = [marker for marker in ("-uiTest", "bootstrap", "localhost", "127.0.0.1") if marker in strings_text]
    results.require(
        strings_process.returncode == 0 and not forbidden,
        "Release binary contains no UI-test, bootstrap, or local-host markers",
        f"Release binary contains forbidden markers: {forbidden}",
    )


def check_app_store_profile(path: Path, results: Results) -> None:
    try:
        profile = extract_profile(path)
        entitlements = profile.get("Entitlements", {})
        expected_application_id = f"{EXPECTED_TEAM_ID}.{EXPECTED_BUNDLE_ID}"
        results.require(
            is_future_datetime(profile.get("ExpirationDate"))
            and EXPECTED_TEAM_ID in profile.get("TeamIdentifier", []),
            f"Installed App Store profile {profile.get('UUID', 'unknown')} is current and belongs to the GunnAire team",
            "Installed App Store profile is expired or belongs to an unexpected team",
        )
        results.require(
            entitlements.get("application-identifier") == expected_application_id
            and entitlements.get("get-task-allow") is False
            and entitlements.get("aps-environment") == "production"
            and entitlements.get("beta-reports-active") is True
            and "ProvisionedDevices" not in profile,
            "App Store profile is distribution-scoped with production APNs and TestFlight reporting",
            "App Store profile has an unexpected distribution, APNs, or device scope",
        )
        cloudkit_environments = entitlements.get(
            "com.apple.developer.icloud-container-environment", []
        )
        results.require(
            entitlements.get("com.apple.developer.applesignin") == ["Default"]
            and EXPECTED_ICLOUD_CONTAINER
            in entitlements.get("com.apple.developer.icloud-container-identifiers", [])
            and "Production" in cloudkit_environments,
            "App Store profile includes Sign in with Apple and Production CloudKit",
            "App Store profile is missing Sign in with Apple or Production CloudKit",
        )
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        results.fail(f"App Store profile inspection failed: {error}")


def check_mac_app(
    app_path: Path,
    marketing_version: str,
    build_version: str,
    require_app_store_signing: bool,
    results: Results,
) -> None:
    binary_path = app_path / "Contents" / "MacOS" / "GunnAire Ops"
    info_path = app_path / "Contents" / "Info.plist"
    privacy_path = app_path / "Contents" / "Resources" / "PrivacyInfo.xcprivacy"
    profile_path = app_path / "Contents" / "embedded.provisionprofile"
    adjacent_dsym_binary = (
        app_path.parent
        / f"{app_path.name}.dSYM"
        / "Contents"
        / "Resources"
        / "DWARF"
        / "GunnAire Ops"
    )
    dsym_candidates = [adjacent_dsym_binary]
    archive_root = app_path.parent.parent.parent
    if archive_root.suffix == ".xcarchive":
        dsym_candidates.append(
            archive_root
            / "dSYMs"
            / f"{app_path.name}.dSYM"
            / "Contents"
            / "Resources"
            / "DWARF"
            / "GunnAire Ops"
        )
    dsym_binary = next(
        (candidate for candidate in dsym_candidates if candidate.exists()),
        adjacent_dsym_binary,
    )
    required_paths = (binary_path, info_path, privacy_path, profile_path, dsym_binary)
    if not results.require(
        app_path.is_dir() and all(path.exists() for path in required_paths),
        f"Mac Catalyst artifact contains the app, profile, binary, privacy manifest, and dSYM: {app_path}",
        f"Mac Catalyst artifact is missing or incomplete: {app_path}",
    ):
        return

    verification = run(
        ["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app_path)],
        check=False,
    )
    results.require(
        verification.returncode == 0,
        "Mac Catalyst app passes strict code-signature verification",
        "Mac Catalyst app failed strict code-signature verification",
    )
    signature = run(["codesign", "-d", "--verbose=4", str(app_path)], check=False)
    signature_text = (signature.stdout + signature.stderr).decode("utf-8", errors="replace")
    results.require(
        signature.returncode == 0
        and "flags=0x10000(runtime)" in signature_text
        and f"TeamIdentifier={EXPECTED_TEAM_ID}" in signature_text,
        "Mac Catalyst app enables hardened runtime and matches the GunnAire Apple team",
        "Mac Catalyst hardened-runtime or team signature is missing",
    )
    privacy = run(["plutil", "-lint", str(privacy_path)], check=False)
    results.require(
        privacy.returncode == 0,
        "Mac Catalyst privacy manifest is valid",
        "Mac Catalyst privacy manifest is invalid",
    )

    try:
        app_info = load_plist(info_path)
        archived_privacy = load_plist(privacy_path)
        entitlements = extract_codesign_entitlements(app_path)
        profile = extract_profile(profile_path)
        profile_entitlements = profile.get("Entitlements", {})
        expected_application_id = f"{EXPECTED_TEAM_ID}.{EXPECTED_BUNDLE_ID}"

        results.require(
            app_info.get("CFBundleIdentifier") == EXPECTED_BUNDLE_ID
            and app_info.get("CFBundleShortVersionString") == marketing_version
            and app_info.get("CFBundleVersion") == build_version,
            f"Mac Catalyst artifact exactly matches source {marketing_version} ({build_version}) and bundle ID",
            "Mac Catalyst version/build/bundle does not match the source",
        )
        results.require(
            app_info.get("ITSAppUsesNonExemptEncryption") is False,
            "Mac Catalyst artifact declares no non-exempt encryption for export-compliance routing",
            "Mac Catalyst export-compliance declaration is missing or unexpected",
        )
        expected_settings = {
            "GUNNAIRE_BACKEND_BASE_URL": EXPECTED_BACKEND_URL,
            "GUNNAIRE_BACKEND_AUTH_MODE": "google-id-token",
            "GUNNAIRE_BACKEND_API_TOKEN": "",
            "QB_ENVIRONMENT": "production",
            "QB_REDIRECT_URI": EXPECTED_QBO_REDIRECT,
            "QB_CALLBACK_SCHEME": EXPECTED_QBO_CALLBACK_SCHEME,
            "QB_ENABLE_PAYMENTS_SCOPE": "true",
        }
        mismatches = {
            key: app_info.get(key)
            for key, expected in expected_settings.items()
            if app_info.get(key) != expected
        }
        results.require(
            not mismatches,
            "Mac Catalyst artifact uses HTTPS business identity, an empty shared token, and production QBO settings",
            f"Mac Catalyst production settings are incorrect: {mismatches}",
        )
        results.require(
            bool(str(app_info.get("QB_CLIENT_ID", "")).strip())
            and google_native_oauth_is_consistent(app_info),
            "Mac Catalyst artifact contains a QBO client ID and consistent native Google OAuth configuration",
            "Mac Catalyst QBO client ID or native Google OAuth configuration is incomplete or inconsistent",
        )
        collected_types = {
            row.get("NSPrivacyCollectedDataType")
            for row in archived_privacy.get("NSPrivacyCollectedDataTypes", [])
            if isinstance(row, dict)
        }
        results.require(
            {
                "NSPrivacyCollectedDataTypeDeviceID",
                "NSPrivacyCollectedDataTypePaymentInfo",
                "NSPrivacyCollectedDataTypeOtherFinancialInfo",
            }.issubset(collected_types),
            "Mac Catalyst privacy manifest covers device, payment, and financial data",
            "Mac Catalyst privacy manifest omits release-critical data categories",
        )
        entitlement_checks = (
            entitlements.get("application-identifier") == expected_application_id,
            entitlements.get("com.apple.developer.applesignin") == ["Default"],
            EXPECTED_ICLOUD_CONTAINER
            in entitlements.get("com.apple.developer.icloud-container-identifiers", []),
            entitlements.get("com.apple.developer.icloud-services") == ["CloudKit"],
            EXPECTED_ASSOCIATED_DOMAIN
            in entitlements.get("com.apple.developer.associated-domains", []),
            entitlements.get("aps-environment") in {"development", "production"},
        )
        results.require(
            all(entitlement_checks),
            "Mac Catalyst artifact includes Apple login, Push, CloudKit, and Associated Domains",
            "Mac Catalyst Apple capability entitlements are incomplete",
        )
        results.require(
            profile_entitlements.get("application-identifier") == expected_application_id
            and is_future_datetime(profile.get("ExpirationDate"))
            and EXPECTED_TEAM_ID in profile.get("TeamIdentifier", []),
            f"Mac Catalyst profile {profile.get('UUID', 'unknown')} is current and matches the GunnAire app/team",
            "Mac Catalyst profile is expired or does not match the GunnAire app/team",
        )

        distribution_signed = (
            "Authority=Apple Distribution" in signature_text
            and entitlements.get("get-task-allow") is False
            and entitlements.get("aps-environment") == "production"
        )
        if distribution_signed:
            results.pass_("Mac Catalyst artifact is distribution signed")
        elif require_app_store_signing:
            results.fail("Mac Catalyst artifact is not distribution signed")
        else:
            results.warn(
                "Mac Catalyst artifact is development signed; a separate Mac distribution profile/private key remains required"
            )
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        results.fail(f"Mac Catalyst metadata/entitlement inspection failed: {error}")

    architectures = run(["lipo", "-archs", str(binary_path)], check=False)
    architecture_set = set(architectures.stdout.decode("utf-8").split())
    results.require(
        architectures.returncode == 0 and architecture_set == {"arm64", "x86_64"},
        "Mac Catalyst binary is universal arm64/x86_64",
        f"Mac Catalyst binary architectures are unexpected: {sorted(architecture_set)}",
    )
    try:
        app_uuids = binary_uuids(binary_path)
        dsym_uuids = binary_uuids(dsym_binary)
        results.require(
            len(app_uuids) == 2 and app_uuids == dsym_uuids,
            f"Mac Catalyst app and dSYM UUIDs match both slices: {', '.join(sorted(app_uuids))}",
            f"Mac Catalyst app/dSYM UUID mismatch: app={sorted(app_uuids)} dSYM={sorted(dsym_uuids)}",
        )
        results.pass_(f"Mac Catalyst binary SHA-256 is {sha256(binary_path)}")
    except (OSError, subprocess.CalledProcessError) as error:
        results.fail(f"Mac Catalyst binary/dSYM inspection failed: {error}")

    strings_process = run(["strings", str(binary_path)], check=False)
    strings_text = strings_process.stdout.decode("utf-8", errors="replace")
    forbidden = [
        marker
        for marker in ("-uiTest", "bootstrap", "localhost", "127.0.0.1")
        if marker in strings_text
    ]
    results.require(
        strings_process.returncode == 0 and not forbidden,
        "Mac Catalyst binary contains no UI-test, bootstrap, or local-host markers",
        f"Mac Catalyst binary contains forbidden markers: {forbidden}",
    )


def check_mac_result(path: Path, results: Results) -> None:
    process = run(
        ["xcrun", "xcresulttool", "get", "build-results", "--path", str(path), "--compact"],
        check=False,
    )
    if process.returncode != 0:
        results.fail("Mac Catalyst build result could not be inspected")
        return
    try:
        payload = json.loads(process.stdout)
    except json.JSONDecodeError as error:
        results.fail(f"Mac Catalyst build result is not valid JSON: {error}")
        return
    results.require(
        payload.get("status") == "succeeded"
        and payload.get("errorCount") == 0
        and payload.get("analyzerWarningCount") == 0,
        "Mac Catalyst Xcode result succeeded with zero errors and analyzer warnings",
        "Mac Catalyst Xcode result contains a failure, error, or analyzer warning",
    )
    warnings = payload.get("warnings", [])
    if not warnings:
        results.pass_("Mac Catalyst Xcode result contains zero warnings")
        return
    messages = [str(warning.get("message", "")) for warning in warnings]
    known_host_warning = all(
        "Metal.xctoolchain" in message and "Search path" in message
        for message in messages
    )
    if known_host_warning:
        results.warn(
            "Mac Catalyst Xcode result contains only the host's missing optional Metal toolchain search-path warning"
        )
    else:
        results.fail(f"Mac Catalyst Xcode result contains unexpected warnings: {messages}")


def parse_cloudkit_schema(path: Path) -> dict[str, dict[str, tuple[str, ...]]]:
    text = path.read_text(encoding="utf-8")
    records: dict[str, dict[str, tuple[str, ...]]] = {}
    for match in re.finditer(r"RECORD TYPE\s+(\w+)\s*\((.*?)\n\s*\);", text, re.DOTALL):
        fields: dict[str, tuple[str, ...]] = {}
        for raw_line in match.group(2).splitlines():
            line = raw_line.strip().rstrip(",")
            if not line.startswith("CD_"):
                continue
            parts = tuple(line.split())
            fields[parts[0]] = parts[1:]
        records[match.group(1)] = fields
    if not records:
        raise ValueError(f"No CloudKit record types found in {path}")
    return records


def parse_cloudkit_record_metadata(
    path: Path,
) -> dict[str, dict[str, tuple[str, ...]]]:
    text = path.read_text(encoding="utf-8")
    records: dict[str, dict[str, tuple[str, ...]]] = {}
    for match in re.finditer(r"RECORD TYPE\s+(\w+)\s*\((.*?)\n\s*\);", text, re.DOTALL):
        system_fields: list[str] = []
        grants: list[str] = []
        for raw_line in match.group(2).splitlines():
            line = " ".join(raw_line.strip().rstrip(",").split())
            if not line or line.startswith("CD_"):
                continue
            if line.startswith("GRANT "):
                grants.append(line)
            else:
                system_fields.append(line)
        records[match.group(1)] = {
            "system_fields": tuple(system_fields),
            "grants": tuple(grants),
        }
    if not records:
        raise ValueError(f"No CloudKit record metadata found in {path}")
    return records


def check_cloudkit(development: Path, production: Path, results: Results) -> None:
    try:
        dev = parse_cloudkit_schema(development)
        prod = parse_cloudkit_schema(production)
        dev_metadata = parse_cloudkit_record_metadata(development)
        prod_metadata = parse_cloudkit_record_metadata(production)
        dev_record_types = set(dev)
        prod_record_types = set(prod)
        added_record_types = dev_record_types - prod_record_types
        results.require(
            set(dev_metadata) == dev_record_types and set(prod_metadata) == prod_record_types,
            "CloudKit field, system-field, and security-grant parsers cover the same record types",
            "CloudKit export metadata does not cover the same record types as the field schema",
        )
        changed_existing_metadata = [
            record_name
            for record_name in sorted(prod_record_types)
            if dev_metadata.get(record_name) != prod_metadata.get(record_name)
        ]
        results.require(
            not changed_existing_metadata,
            "Development changes alter no existing CloudKit system fields or security grants",
            "Development alters existing CloudKit system fields or security grants: "
            f"{changed_existing_metadata}",
        )
        invalid_added_metadata = [
            record_name
            for record_name in sorted(added_record_types)
            if dev_metadata.get(record_name, {}).get("system_fields")
            != EXPECTED_CLOUDKIT_SYSTEM_FIELDS
            or dev_metadata.get(record_name, {}).get("grants")
            != EXPECTED_CLOUDKIT_RECORD_GRANTS
        ]
        results.require(
            not invalid_added_metadata,
            "Added CloudKit record types use the approved system fields and default private-database grants",
            "Added CloudKit record types have unexpected system fields or security grants: "
            f"{invalid_added_metadata}",
        )
        fleet_types_in_dev = dev_record_types & EXPECTED_CLOUDKIT_V17_RECORD_TYPES
        fleet_types_in_prod = prod_record_types & EXPECTED_CLOUDKIT_V17_RECORD_TYPES
        expense_types_in_dev = dev_record_types & EXPECTED_CLOUDKIT_V18_RECORD_TYPES
        expense_types_in_prod = prod_record_types & EXPECTED_CLOUDKIT_V18_RECORD_TYPES
        alert_types_in_dev = dev_record_types & EXPECTED_CLOUDKIT_V19_RECORD_TYPES
        alert_types_in_prod = prod_record_types & EXPECTED_CLOUDKIT_V19_RECORD_TYPES
        task_types_in_dev = dev_record_types & EXPECTED_CLOUDKIT_V20_RECORD_TYPES
        task_types_in_prod = prod_record_types & EXPECTED_CLOUDKIT_V20_RECORD_TYPES
        time_off_types_in_dev = dev_record_types & EXPECTED_CLOUDKIT_V21_RECORD_TYPES
        time_off_types_in_prod = prod_record_types & EXPECTED_CLOUDKIT_V21_RECORD_TYPES
        work_shift_types_in_dev = dev_record_types & EXPECTED_CLOUDKIT_V22_RECORD_TYPES
        work_shift_types_in_prod = prod_record_types & EXPECTED_CLOUDKIT_V22_RECORD_TYPES
        additive_record_type_groups = (
            EXPECTED_CLOUDKIT_V17_RECORD_TYPES,
            EXPECTED_CLOUDKIT_V18_RECORD_TYPES,
            EXPECTED_CLOUDKIT_V19_RECORD_TYPES,
            EXPECTED_CLOUDKIT_V20_RECORD_TYPES,
            EXPECTED_CLOUDKIT_V21_RECORD_TYPES,
            EXPECTED_CLOUDKIT_V22_RECORD_TYPES,
        )
        approved_added_type_sets = tuple(
            set().union(*[
                group
                for index, group in enumerate(additive_record_type_groups)
                if mask & (1 << index)
            ])
            for mask in range(1 << len(additive_record_type_groups))
        )
        approved_record_type_sets = tuple(
            EXPECTED_CLOUDKIT_BASELINE_RECORD_TYPES | additions
            for additions in approved_added_type_sets
        )
        results.require(
            prod_record_types.issubset(dev_record_types)
            and dev_record_types in approved_record_type_sets
            and prod_record_types in approved_record_type_sets
            and added_record_types in approved_added_type_sets
            and fleet_types_in_dev in (set(), EXPECTED_CLOUDKIT_V17_RECORD_TYPES)
            and fleet_types_in_prod in (set(), EXPECTED_CLOUDKIT_V17_RECORD_TYPES)
            and expense_types_in_dev in (set(), EXPECTED_CLOUDKIT_V18_RECORD_TYPES)
            and expense_types_in_prod in (set(), EXPECTED_CLOUDKIT_V18_RECORD_TYPES)
            and alert_types_in_dev in (set(), EXPECTED_CLOUDKIT_V19_RECORD_TYPES)
            and alert_types_in_prod in (set(), EXPECTED_CLOUDKIT_V19_RECORD_TYPES)
            and task_types_in_dev in (set(), EXPECTED_CLOUDKIT_V20_RECORD_TYPES)
            and task_types_in_prod in (set(), EXPECTED_CLOUDKIT_V20_RECORD_TYPES)
            and time_off_types_in_dev in (set(), EXPECTED_CLOUDKIT_V21_RECORD_TYPES)
            and time_off_types_in_prod in (set(), EXPECTED_CLOUDKIT_V21_RECORD_TYPES)
            and work_shift_types_in_dev in (set(), EXPECTED_CLOUDKIT_V22_RECORD_TYPES)
            and work_shift_types_in_prod in (set(), EXPECTED_CLOUDKIT_V22_RECORD_TYPES),
            "CloudKit exports retain the exact 24-type baseline and only the approved v17 fleet, v18 expense, v19 alert, v20 task, v21 time-off, and v22 recurring-shift extensions may be additive",
            "CloudKit record types are not the approved 24-type baseline or approved v17/v18/v19/v20/v21/v22 extensions: "
            f"development={sorted(dev_record_types)} production={sorted(prod_record_types)}",
        )
        actual_additions: dict[str, dict[str, tuple[str, ...]]] = {}
        changed_or_removed: list[str] = []
        for record_name in sorted(set(dev) | set(prod)):
            dev_fields = dev.get(record_name, {})
            prod_fields = prod.get(record_name, {})
            for field_name, production_definition in prod_fields.items():
                if dev_fields.get(field_name) != production_definition:
                    changed_or_removed.append(f"{record_name}.{field_name}")
            added = {
                name: definition
                for name, definition in dev_fields.items()
                if name not in prod_fields
            }
            if added:
                actual_additions[record_name] = added
        results.require(
            not changed_or_removed,
            "Development changes remove or alter no Production CloudKit fields",
            f"Development removes or alters Production fields: {changed_or_removed}",
        )
        malformed_existing_v23_fields: list[str] = []
        for record_name, expected_fields in EXPECTED_CLOUDKIT_V23_ADDITIONS.items():
            production_fields = prod.get(record_name, {})
            for field_name, expected_definition in expected_fields.items():
                if (
                    field_name in production_fields
                    and production_fields[field_name] != expected_definition
                ):
                    malformed_existing_v23_fields.append(
                        f"{record_name}.{field_name}"
                    )
        results.require(
            not malformed_existing_v23_fields,
            "Existing Production fields through v23 match their approved definitions",
            "CloudKit Production contains malformed approved fields through v23: "
            f"{malformed_existing_v23_fields}",
        )

        def expected_remaining(
            expected: dict[str, dict[str, tuple[str, ...]]]
        ) -> dict[str, dict[str, tuple[str, ...]]]:
            remaining = {
                record_name: {
                    field_name: definition
                    for field_name, definition in expected_fields.items()
                    if prod.get(record_name, {}).get(field_name) != definition
                }
                for record_name, expected_fields in expected.items()
            }
            return {record_name: fields for record_name, fields in remaining.items() if fields}

        def missing_or_changed(
            records: dict[str, dict[str, tuple[str, ...]]],
            expected: dict[str, dict[str, tuple[str, ...]]],
        ) -> list[str]:
            return [
                f"{record_name}.{field_name}"
                for record_name, expected_fields in expected.items()
                for field_name, expected_definition in expected_fields.items()
                if records.get(record_name, {}).get(field_name) != expected_definition
            ]

        expected_remaining_v23_additions = expected_remaining(EXPECTED_CLOUDKIT_V23_ADDITIONS)
        expected_remaining_v22_additions = expected_remaining(EXPECTED_CLOUDKIT_V22_ADDITIONS)
        expected_remaining_v21_additions = expected_remaining(EXPECTED_CLOUDKIT_V21_ADDITIONS)
        expected_remaining_v20_additions = expected_remaining(EXPECTED_CLOUDKIT_V20_ADDITIONS)
        expected_remaining_v19_additions = expected_remaining(EXPECTED_CLOUDKIT_V19_ADDITIONS)
        expected_remaining_v18_additions = expected_remaining(EXPECTED_CLOUDKIT_V18_ADDITIONS)
        expected_remaining_v17_additions = expected_remaining(EXPECTED_CLOUDKIT_V17_ADDITIONS)
        expected_remaining_v16_additions = expected_remaining(EXPECTED_CLOUDKIT_V16_ADDITIONS)
        dev_missing_v23 = missing_or_changed(dev, EXPECTED_CLOUDKIT_V23_ADDITIONS)
        dev_missing_v22 = missing_or_changed(dev, EXPECTED_CLOUDKIT_V22_ADDITIONS)
        prod_missing_v22 = missing_or_changed(prod, EXPECTED_CLOUDKIT_V22_ADDITIONS)
        dev_missing_v21 = missing_or_changed(dev, EXPECTED_CLOUDKIT_V21_ADDITIONS)
        prod_missing_v21 = missing_or_changed(prod, EXPECTED_CLOUDKIT_V21_ADDITIONS)
        dev_missing_v20 = missing_or_changed(dev, EXPECTED_CLOUDKIT_V20_ADDITIONS)
        prod_missing_v20 = missing_or_changed(prod, EXPECTED_CLOUDKIT_V20_ADDITIONS)
        dev_missing_v19 = missing_or_changed(dev, EXPECTED_CLOUDKIT_V19_ADDITIONS)
        prod_missing_v19 = missing_or_changed(prod, EXPECTED_CLOUDKIT_V19_ADDITIONS)
        dev_missing_v18 = missing_or_changed(dev, EXPECTED_CLOUDKIT_V18_ADDITIONS)
        prod_missing_v18 = missing_or_changed(prod, EXPECTED_CLOUDKIT_V18_ADDITIONS)
        dev_missing_v17 = missing_or_changed(dev, EXPECTED_CLOUDKIT_V17_ADDITIONS)
        prod_missing_v17 = missing_or_changed(prod, EXPECTED_CLOUDKIT_V17_ADDITIONS)
        dev_missing_v16 = missing_or_changed(dev, EXPECTED_CLOUDKIT_V16_ADDITIONS)
        prod_missing_v16 = missing_or_changed(prod, EXPECTED_CLOUDKIT_V16_ADDITIONS)

        if (
            not dev_missing_v23
            and (
                not missing_or_changed(prod, EXPECTED_CLOUDKIT_V23_ADDITIONS)
                or actual_additions == expected_remaining_v23_additions
            )
        ):
            results.pass_(
                "CloudKit Development contains the exact cumulative v23 operational field closure across every persisted optional business attribute"
            )
        elif (
            not dev_missing_v22
            and (
                not prod_missing_v22
                or actual_additions == expected_remaining_v22_additions
            )
        ):
            results.pass_(
                "CloudKit Development contains exactly the approved additive v22 recurring technician work-shift record plus the cumulative v21 schema relative to Production"
            )
            results.warn(
                "CloudKit source v23 operational field closure is not staged in Development; run the signed v23 bootstrap before promotion review"
            )
        elif (
            not dev_missing_v21
            and (
                not prod_missing_v21
                or actual_additions == expected_remaining_v21_additions
            )
        ):
            results.pass_(
                "CloudKit Development contains exactly the approved additive v21 technician time-off request, audit-event, and availability-cancellation fields plus the cumulative v20 schema relative to Production"
            )
            results.warn(
                "CloudKit source v22 recurring technician work-shift record and v23 operational field closure are not staged in Development; run the signed v23 bootstrap before promotion review"
            )
        elif (
            not dev_missing_v20
            and (
                not prod_missing_v20
                or actual_additions == expected_remaining_v20_additions
            )
        ):
            results.pass_(
                "CloudKit Development contains exactly the approved additive v20 team task and audit-event records plus the cumulative v19 schema relative to Production"
            )
            results.warn(
                "CloudKit source v21 technician time-off, v22 recurring work-shift, and v23 operational field closure are not staged in Development; run the signed v23 bootstrap before promotion review"
            )
        elif (
            not dev_missing_v19
            and (
                not prod_missing_v19
                or actual_additions == expected_remaining_v19_additions
            )
        ):
            results.pass_(
                "CloudKit Development contains exactly the approved additive v19 customer operational alert record and cumulative v18 schema relative to Production"
            )
            results.warn(
                "CloudKit source v20 team task, v21 technician time-off, v22 recurring work-shift, and v23 operational field closure are not staged in Development; run the signed v23 bootstrap before promotion review"
            )
        elif (
            not dev_missing_v18
            and (
                not prod_missing_v18
                or actual_additions == expected_remaining_v18_additions
            )
        ):
            results.pass_(
                "CloudKit Development contains exactly the approved additive v18 expense record, receipt linkage, and cumulative fleet schema relative to Production"
            )
            results.warn(
                "CloudKit source v19 operational alert, v20 task, v21 technician time-off, v22 recurring work-shift, and v23 operational field closure are not staged in Development; run the signed v23 bootstrap before promotion review"
            )
        elif (
            not dev_missing_v17
            and (
                not prod_missing_v17
                or actual_additions == expected_remaining_v17_additions
            )
        ):
            results.pass_(
                "CloudKit Development contains exactly the approved additive v17 fleet records and document linkage relative to Production"
            )
            results.warn(
                "CloudKit source v18 expense, v19 operational alert, v20 task, v21 technician time-off, v22 recurring work-shift, and v23 operational field closure are not staged in Development; run the signed v23 bootstrap before promotion review"
            )
        elif (
            not dev_missing_v16
            and (
                not prod_missing_v16
                or actual_additions == expected_remaining_v16_additions
            )
        ):
            results.pass_("CloudKit exports exactly satisfy the approved v16 schema")
            results.warn(
                "CloudKit source v17 fleet, v18 expense, v19 operational alert, v20 task, v21 technician time-off, v22 recurring work-shift, and v23 operational field closure are not staged in Development; run the signed v23 bootstrap before promotion review"
            )
        elif actual_additions == EXPECTED_CLOUDKIT_V13_ADDITIONS:
            results.pass_(
                "CloudKit Development v13 delta is exactly six additive tax fields on Estimate and Invoice"
            )
            results.warn(
                "CloudKit source additions through v23 are not staged in Development; run the signed v23 bootstrap before promotion review"
            )
        elif actual_additions == EXPECTED_CLOUDKIT_V14_ADDITIONS:
            results.pass_(
                "CloudKit Development v14 cumulative delta is exactly six tax fields plus Invoice.dueDate"
            )
            results.warn(
                "CloudKit source additions through v23 are not staged in Development; run the signed v23 bootstrap before promotion review"
            )
        elif actual_additions == EXPECTED_CLOUDKIT_V15_ADDITIONS:
            results.pass_(
                "CloudKit Development v15 cumulative delta is exactly the approved tax, due-date, inventory continuity, Item continuity, and service-package fields"
            )
            results.warn(
                "CloudKit source additions through v23 are not staged in Development; run the signed v23 bootstrap before promotion review"
            )
        elif actual_additions == EXPECTED_CLOUDKIT_V16_ADDITIONS:
            results.pass_(
                "CloudKit Development v16 cumulative delta is exactly the approved tax, due-date, inventory continuity, Item continuity, service-package, document-linkage, and Google Drive fields"
            )
            results.warn(
                "CloudKit source v17 fleet, v18 expense, v19 operational alert, v20 task, v21 technician time-off, v22 recurring work-shift, and v23 operational field closure are not staged in Development; run the signed v23 bootstrap before promotion review"
            )
        else:
            results.fail(
                "Unexpected CloudKit v13/v14/v15/v16/v17/v18/v19/v20/v21/v22/v23 delta: "
                f"{actual_additions}; missing Development v23 fields: {dev_missing_v23}"
            )
        results.pass_(f"Development export SHA-256 is {sha256(development)}")
        results.pass_(f"Production export SHA-256 is {sha256(production)}")
    except (OSError, ValueError) as error:
        results.fail(f"CloudKit export inspection failed: {error}")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req: Any, fp: Any, code: int, msg: str, headers: Any, newurl: str) -> None:
        return None


def http_status(request: urllib.request.Request) -> tuple[int, dict[str, str], bytes]:
    opener = urllib.request.build_opener(NoRedirect())
    try:
        with opener.open(request, timeout=20) as response:
            return response.status, dict(response.headers), response.read()
    except urllib.error.HTTPError as error:
        return error.code, dict(error.headers), error.read()


def check_online(expected_backend_version: str, results: Results) -> None:
    try:
        status, _, body = http_status(
            urllib.request.Request(f"{EXPECTED_BACKEND_URL}/health")
        )
        payload = json.loads(body)
        actual_version = payload.get("serviceVersion")
        results.require(
            status == 200 and actual_version == expected_backend_version,
            f"Production backend is healthy on source version {expected_backend_version}",
            f"Production backend gate is not met: HTTP {status}, serviceVersion={actual_version!r}, expected={expected_backend_version!r}",
        )

        apple_request = urllib.request.Request(
            f"{EXPECTED_BACKEND_URL}/api/auth/apple/notifications",
            data=b"{}",
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        apple_status, _, _ = http_status(apple_request)
        results.require(
            apple_status == 400,
            "Production Apple notification route rejects a malformed envelope with HTTP 400",
            f"Production Apple notification route returned HTTP {apple_status}; HTTP 401 identifies the old backend",
        )

        callback_status, callback_headers, _ = http_status(
            urllib.request.Request(EXPECTED_QBO_REDIRECT)
        )
        location = callback_headers.get("Location", "")
        results.require(
            callback_status in {301, 302, 303, 307, 308}
            and location.startswith(f"{EXPECTED_QBO_CALLBACK_SCHEME}://"),
            "Production QBO HTTPS callback reaches the GunnAire app scheme",
            f"QBO callback gate failed: HTTP {callback_status}, Location={location!r}",
        )
    except (OSError, ValueError, json.JSONDecodeError) as error:
        results.fail(f"Online production preflight failed: {error}")


def main() -> int:
    args = parse_args()
    root = args.project_root.resolve()
    results = Results()
    marketing_version, build_version, backend_version = check_source(root, results)

    archive = args.archive
    if archive is None and marketing_version and build_version:
        archive = find_archive(marketing_version, build_version)
    if archive is None:
        results.fail("No matching Current Source archive was supplied or discovered")
    else:
        check_archive(
            archive.expanduser().resolve(),
            marketing_version,
            build_version,
            args.require_app_store_signing,
            results,
        )

    app_store_profile = args.app_store_profile or find_app_store_profile()
    if app_store_profile is None:
        results.warn("No matching installed App Store profile was supplied or discovered")
    else:
        check_app_store_profile(app_store_profile.expanduser().resolve(), results)

    mac_app = args.mac_app or (find_mac_app(build_version) if build_version else None)
    if mac_app is None:
        results.warn("No exact current-source Mac Catalyst Release app was supplied or discovered")
    else:
        check_mac_app(
            mac_app.expanduser().resolve(),
            marketing_version,
            build_version,
            args.require_app_store_signing,
            results,
        )

    mac_result = args.mac_result or (find_mac_result(build_version) if build_version else None)
    if mac_result is None:
        results.warn("No current-source Mac Catalyst build result was supplied or discovered")
    else:
        check_mac_result(mac_result.expanduser().resolve(), results)

    cloudkit_arguments = (
        args.cloudkit_development_export,
        args.cloudkit_production_export,
    )
    if any(cloudkit_arguments) and not all(cloudkit_arguments):
        results.fail("Both CloudKit export paths are required when either is supplied")
    elif all(cloudkit_arguments):
        check_cloudkit(
            args.cloudkit_development_export.expanduser().resolve(),
            args.cloudkit_production_export.expanduser().resolve(),
            results,
        )
    else:
        results.warn("CloudKit exports were not supplied; the exact v13/v14/v15/v16/v17/v18/v19/v20/v21/v22/v23 Production delta was not rechecked")

    if args.online:
        check_online(backend_version, results)
    else:
        results.warn("Online production probes were not requested")

    print()
    print(
        f"SUMMARY {results.passed} passed, {results.warnings} warnings, "
        f"{len(results.failures)} failures"
    )
    if results.failures:
        print("RELEASE PREFLIGHT FAILED")
        return 1
    print("RELEASE PREFLIGHT PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
