"""Authenticated HTTP operations for exact billing PDF reservations."""

from __future__ import annotations

from dataclasses import asdict
from datetime import datetime, timezone
import hashlib

try:
    from . import google_connections
    from .billing_pdf_archive_ledger import (
        BillingPDFArchiveLedger, BillingPDFKey, InvalidReservation,
        ReservationBusy, ReservationChanged,
    )
    from .billing_pdf_drive_readback import BillingPDFDriveReadback, ProviderReadbackError
except ImportError:
    import google_connections
    from billing_pdf_archive_ledger import (
        BillingPDFArchiveLedger, BillingPDFKey, InvalidReservation,
        ReservationBusy, ReservationChanged,
    )
    from billing_pdf_drive_readback import BillingPDFDriveReadback, ProviderReadbackError


_DRIVE_SCOPE = google_connections.FEATURE_SCOPES["drive"]
_BASE = "/api/google/drive/billing-pdf-intents"
_WORKSPACE = {"companyID", "grantID", "containerID", "environment",
              "replicaID", "cloudAccountHash"}
_IDENTITY = _WORKSPACE | {"expectedDriveAccount", "documentKind", "documentID",
                          "sourceDigest", "rendererVersion"}


class RouteFailure(Exception):
    def __init__(self, code: str, status: int, message: str):
        super().__init__(message)
        self.code, self.status = code, status


class BillingPDFArchiveRoutes:
    def __init__(self, database, google_service, *, primary_admin_email: str,
                 container_id: str, ledger: BillingPDFArchiveLedger,
                 readback: BillingPDFDriveReadback | None = None):
        self.database = database
        self.google_service = google_service
        self.primary_admin_email = primary_admin_email
        self.container_id = container_id
        self.ledger = ledger
        self.readback = readback or BillingPDFDriveReadback()

    def dispatch(self, method: str, path: str, payload: dict,
                 session_id: str) -> dict:
        if not isinstance(payload, dict):
            raise RouteFailure("invalid_request", 400, "Review the PDF archive request.")
        if method == "GET" and path == _BASE + "/identity":
            if set(payload) != _WORKSPACE or any(not isinstance(value, str) for value in payload.values()):
                raise RouteFailure("invalid_request", 400, "Review the PDF archive identity request.")
            company, account = self._authorized_account(payload, session_id)
            return {"companyID": company, "grantID": payload["grantID"], "driveAccount": account}
        if method == "GET" and path == _BASE:
            operation, extra = "read", set()
        elif method == "POST" and path in {_BASE + "/reserve", _BASE + "/content", _BASE + "/file", _BASE + "/confirm"}:
            operation = path.rsplit("/", 1)[1]
            extra = {
                "reserve": set(),
                "content": {"leaseToken", "contentDigest"},
                "file": {"leaseToken", "fileID"},
                "confirm": {"leaseToken", "fileID", "contentDigest"},
            }[operation]
        else:
            raise RouteFailure("invalid_request", 400, "Review the PDF archive endpoint.")
        if set(payload) != _IDENTITY | extra or any(not isinstance(value, str) for value in payload.values()):
            raise RouteFailure("invalid_request", 400, "Review the PDF archive request.")
        key = self._authorized_key(payload, session_id)
        now = datetime.now(timezone.utc)
        try:
            if operation == "confirm":
                saved = self.ledger.read(key)
                if (saved is None or saved.content_digest != payload["contentDigest"] or
                        saved.drive_file_id != payload["fileID"]):
                    raise ReservationChanged("PDF content or Drive file differs from the reservation")
                reservation = self.ledger.bind_drive_file_id(
                    key, payload["leaseToken"], payload["fileID"], now=now)
                token = self.google_service.access(session_id, key.company_id,
                    payload["grantID"], _DRIVE_SCOPE)
                link = self.readback.verify(key, reservation, token)
                if self._authorized_key(payload, session_id) != key:
                    raise ReservationChanged("Google account or workspace changed during readback")
                result = self.ledger.confirm(key, payload["leaseToken"],
                    file_id=payload["fileID"], link=link,
                    content_digest=payload["contentDigest"], now=datetime.now(timezone.utc))
                return {"reservation": self._public(result)}
            if operation == "read":
                reservation = self.ledger.read(key)
                return {"reservation": self._public(reservation)}
            if operation == "reserve":
                reservation = self.ledger.reserve(key, now=now)
            elif operation == "content":
                reservation = self.ledger.bind_content_digest(
                    key, payload["leaseToken"], payload["contentDigest"], now=now)
            else:
                reservation = self.ledger.bind_drive_file_id(
                    key, payload["leaseToken"], payload["fileID"], now=now)
            return {"reservation": self._public(reservation, include_token=True)}
        except InvalidReservation as error:
            raise RouteFailure("invalid_request", 400, str(error)) from error
        except ReservationBusy as error:
            raise RouteFailure("reservation_busy", 409, str(error)) from error
        except ReservationChanged as error:
            raise RouteFailure("reservation_changed", 409, str(error)) from error
        except ProviderReadbackError as error:
            raise RouteFailure("provider_unconfirmed", 502, str(error)) from error

    def _authorized_key(self, payload: dict, session_id: str) -> BillingPDFKey:
        company, account = self._authorized_account(payload, session_id)
        if payload["expectedDriveAccount"] != account:
            raise RouteFailure("account_changed", 403, "Reconnect the original Google account.")
        try:
            return BillingPDFKey(company, account,
                payload["documentKind"], payload["documentID"],
                payload["sourceDigest"], payload["rendererVersion"]).normalized()
        except InvalidReservation as error:
            raise RouteFailure("invalid_request", 400, str(error)) from error

    def _authorized_account(self, payload: dict, session_id: str) -> tuple[str, str]:
        try:
            company = google_connections.identifier(payload["companyID"])
            grant_id = google_connections.identifier(payload["grantID"])
            replica_id = google_connections.identifier(payload["replicaID"])
            if (payload["containerID"] != self.container_id or
                    payload["environment"] not in {"development", "production"} or
                    not payload["cloudAccountHash"]):
                raise RouteFailure("workspace_changed", 403, "Reopen the approved workspace.")
            self.google_service.configured()
            with self.database() as connection:
                actor = self.google_service.authorize(connection, session_id, company)
                if actor["role"] != "Admin" or actor["email"] != self.primary_admin_email:
                    raise RouteFailure("admin_required", 403, "The approved administrator is required.")
                workspace = connection.execute("""
                    SELECT 1 FROM cloudkit_workspace_bindings
                    WHERE container_id = ? AND environment = ? AND replica_id = ?
                      AND cloud_account_hash = ?
                """, (self.container_id, payload["environment"], replica_id,
                      payload["cloudAccountHash"])).fetchone()
                if workspace is None:
                    raise RouteFailure("workspace_changed", 403, "Reopen the approved workspace.")
                grant = self.google_service.grant(connection, company, actor["email"])
                self.google_service.check_grant(grant, grant_id, _DRIVE_SCOPE)
                bound = connection.execute("""
                    SELECT 1 FROM google_account_bindings
                    WHERE company_id = ? AND actor_email = ? AND subject = ?
                """, (company, actor["email"], grant["subject"])).fetchone()
                if bound is None:
                    raise RouteFailure("account_changed", 403, "Reconnect the approved Google account.")
                account = "google-subject:" + hashlib.sha256(grant["subject"].encode("utf-8")).hexdigest()
            return company, account
        except InvalidReservation as error:
            raise RouteFailure("invalid_request", 400, str(error)) from error

    @staticmethod
    def _public(reservation, *, include_token: bool = False):
        if reservation is None:
            return None
        value = asdict(reservation)
        value["key"] = asdict(reservation.key)
        if not include_token:
            value.pop("lease_token")
        return value
