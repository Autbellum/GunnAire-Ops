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
import subprocess
import sys
import urllib.error
import urllib.request
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
        malformed_existing_v22_fields: list[str] = []
        for record_name, expected_fields in EXPECTED_CLOUDKIT_V22_ADDITIONS.items():
            production_fields = prod.get(record_name, {})
            for field_name, expected_definition in expected_fields.items():
                if (
                    field_name in production_fields
                    and production_fields[field_name] != expected_definition
                ):
                    malformed_existing_v22_fields.append(
                        f"{record_name}.{field_name}"
                    )
        results.require(
            not malformed_existing_v22_fields,
            "Existing Production fields through v22 match their approved definitions",
            "CloudKit Production contains malformed approved fields through v22: "
            f"{malformed_existing_v22_fields}",
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

        expected_remaining_v22_additions = expected_remaining(EXPECTED_CLOUDKIT_V22_ADDITIONS)
        expected_remaining_v21_additions = expected_remaining(EXPECTED_CLOUDKIT_V21_ADDITIONS)
        expected_remaining_v20_additions = expected_remaining(EXPECTED_CLOUDKIT_V20_ADDITIONS)
        expected_remaining_v19_additions = expected_remaining(EXPECTED_CLOUDKIT_V19_ADDITIONS)
        expected_remaining_v18_additions = expected_remaining(EXPECTED_CLOUDKIT_V18_ADDITIONS)
        expected_remaining_v17_additions = expected_remaining(EXPECTED_CLOUDKIT_V17_ADDITIONS)
        expected_remaining_v16_additions = expected_remaining(EXPECTED_CLOUDKIT_V16_ADDITIONS)
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
            not dev_missing_v22
            and (
                not prod_missing_v22
                or actual_additions == expected_remaining_v22_additions
            )
        ):
            results.pass_(
                "CloudKit Development contains exactly the approved additive v22 recurring technician work-shift record plus the cumulative v21 schema relative to Production"
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
                "CloudKit source v22 recurring technician work-shift record is not staged in Development; run the signed v22 bootstrap before promotion review"
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
                "CloudKit source v21 technician time-off and v22 recurring work-shift records are not staged in Development; run the signed v22 bootstrap before promotion review"
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
                "CloudKit source v20 team task, v21 technician time-off, and v22 recurring work-shift records are not staged in Development; run the signed v22 bootstrap before promotion review"
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
                "CloudKit source v19 operational alert, v20 task, v21 technician time-off, and v22 recurring work-shift records are not staged in Development; run the signed v22 bootstrap before promotion review"
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
                "CloudKit source v18 expense, v19 operational alert, v20 task, v21 technician time-off, and v22 recurring work-shift records are not staged in Development; run the signed v22 bootstrap before promotion review"
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
                "CloudKit source v17 fleet, v18 expense, v19 operational alert, v20 task, v21 technician time-off, and v22 recurring work-shift records are not staged in Development; run the signed v22 bootstrap before promotion review"
            )
        elif actual_additions == EXPECTED_CLOUDKIT_V13_ADDITIONS:
            results.pass_(
                "CloudKit Development v13 delta is exactly six additive tax fields on Estimate and Invoice"
            )
            results.warn(
                "CloudKit source additions through v22 are not staged in Development; run the signed v22 bootstrap before promotion review"
            )
        elif actual_additions == EXPECTED_CLOUDKIT_V14_ADDITIONS:
            results.pass_(
                "CloudKit Development v14 cumulative delta is exactly six tax fields plus Invoice.dueDate"
            )
            results.warn(
                "CloudKit source additions through v22 are not staged in Development; run the signed v22 bootstrap before promotion review"
            )
        elif actual_additions == EXPECTED_CLOUDKIT_V15_ADDITIONS:
            results.pass_(
                "CloudKit Development v15 cumulative delta is exactly the approved tax, due-date, inventory continuity, Item continuity, and service-package fields"
            )
            results.warn(
                "CloudKit source additions through v22 are not staged in Development; run the signed v22 bootstrap before promotion review"
            )
        elif actual_additions == EXPECTED_CLOUDKIT_V16_ADDITIONS:
            results.pass_(
                "CloudKit Development v16 cumulative delta is exactly the approved tax, due-date, inventory continuity, Item continuity, service-package, document-linkage, and Google Drive fields"
            )
            results.warn(
                "CloudKit source v17 fleet, v18 expense, v19 operational alert, v20 task, v21 technician time-off, and v22 recurring work-shift records are not staged in Development; run the signed v22 bootstrap before promotion review"
            )
        else:
            results.fail(
                "Unexpected CloudKit v13/v14/v15/v16/v17/v18/v19/v20/v21/v22 delta: "
                f"{actual_additions}; missing Development v22 fields: {dev_missing_v22}"
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
        results.warn("CloudKit exports were not supplied; the exact v13/v14/v15/v16/v17/v18/v19/v20/v21/v22 Production delta was not rechecked")

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
