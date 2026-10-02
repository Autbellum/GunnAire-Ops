"""Local database foundation for one Drive reservation per billing PDF revision.

This module performs no Google request. An authenticated HTTP handler must bind
the company and Drive account from verified server credentials before calling it.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from contextlib import contextmanager
import re
import sqlite3
import uuid


_HEX = re.compile(r"[0-9a-f]{64}\Z")
_ACCOUNT = re.compile(r"google-subject:[0-9a-f]{64}\Z")
_DRIVE_ID = re.compile(r"[A-Za-z0-9_-]{1,200}\Z")
_RENDERER = re.compile(r"[A-Za-z0-9_.-]{1,40}\Z")


class InvalidReservation(ValueError):
    pass


class ReservationBusy(RuntimeError):
    pass


class ReservationChanged(RuntimeError):
    pass


@dataclass(frozen=True)
class BillingPDFKey:
    company_id: str
    drive_account: str
    document_kind: str
    document_id: str
    source_digest: str
    renderer_version: str

    def normalized(self) -> BillingPDFKey:
        try:
            company = str(uuid.UUID(self.company_id))
            document = str(uuid.UUID(self.document_id))
        except (ValueError, AttributeError) as error:
            raise InvalidReservation("Invalid company or billing document ID") from error
        account = self.drive_account.strip().lower()
        if not _ACCOUNT.fullmatch(account):
            raise InvalidReservation("Invalid authorized Drive account")
        if self.document_kind not in ("estimate", "invoice"):
            raise InvalidReservation("Invalid billing document kind")
        if not _HEX.fullmatch(self.source_digest):
            raise InvalidReservation("Invalid source digest")
        if not _RENDERER.fullmatch(self.renderer_version):
            raise InvalidReservation("Invalid renderer version")
        return BillingPDFKey(company, account, self.document_kind, document,
                             self.source_digest, self.renderer_version)


@dataclass(frozen=True)
class BillingPDFReservation:
    key: BillingPDFKey
    attachment_id: str
    rendered_at: str
    lease_token: str | None
    lease_until: str | None
    content_digest: str | None
    drive_file_id: str | None
    confirmed_link: str | None


def initialize_schema(connection: sqlite3.Connection) -> None:
    connection.execute("""
                CREATE TABLE IF NOT EXISTS billing_pdf_archive_intents (
                    company_id TEXT NOT NULL,
                    drive_account TEXT NOT NULL,
                    document_kind TEXT NOT NULL,
                    document_id TEXT NOT NULL,
                    source_digest TEXT NOT NULL,
                    renderer_version TEXT NOT NULL,
                    attachment_id TEXT NOT NULL,
                    rendered_at TEXT NOT NULL,
                    lease_token TEXT,
                    lease_until TEXT,
                    content_digest TEXT,
                    drive_file_id TEXT,
                    confirmed_link TEXT,
                    PRIMARY KEY (company_id, drive_account, document_kind,
                                 document_id, source_digest, renderer_version),
                    UNIQUE (attachment_id),
                    UNIQUE (drive_file_id)
                )
            """)


class BillingPDFArchiveLedger:
    def __init__(self, database: str | Path):
        self.database = str(database)

    def install(self) -> None:
        with self._connection() as connection:
            initialize_schema(connection)

    def reserve(self, key: BillingPDFKey, *, now: datetime,
                lease_seconds: int = 300) -> BillingPDFReservation:
        key = key.normalized()
        if lease_seconds < 1 or lease_seconds > 900:
            raise InvalidReservation("Invalid lease duration")
        now = self._utc(now)
        until = (now + timedelta(seconds=lease_seconds)).isoformat()
        token = str(uuid.uuid4())
        with self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                row = self._row(connection, key)
                if row is None:
                    connection.execute("""
                        INSERT INTO billing_pdf_archive_intents
                          (company_id, drive_account, document_kind, document_id,
                           source_digest, renderer_version, attachment_id,
                           rendered_at, lease_token, lease_until)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, (*self._parts(key), str(uuid.uuid4()), now.isoformat(), token, until))
                elif row["confirmed_link"] is None:
                    if row["lease_until"] is not None and row["lease_until"] > now.isoformat():
                        raise ReservationBusy("Another device owns this revision lease")
                    connection.execute("""
                        UPDATE billing_pdf_archive_intents
                        SET lease_token = ?, lease_until = ?
                        WHERE company_id = ? AND drive_account = ? AND document_kind = ?
                          AND document_id = ? AND source_digest = ? AND renderer_version = ?
                    """, (token, until, *self._parts(key)))
                result = self._row(connection, key)
                connection.execute("COMMIT")
                if result is None:
                    raise ReservationChanged("Reservation disappeared")
                return self._reservation(key, result, include_token=result["confirmed_link"] is None)
            except Exception:
                connection.execute("ROLLBACK")
                raise

    def read(self, key: BillingPDFKey) -> BillingPDFReservation | None:
        key = key.normalized()
        with self._connection() as connection:
            row = self._row(connection, key)
            return None if row is None else self._reservation(key, row)

    def bind_content_digest(self, key: BillingPDFKey, lease_token: str,
                            content_digest: str, *, now: datetime) -> BillingPDFReservation:
        if not _HEX.fullmatch(content_digest):
            raise InvalidReservation("Invalid PDF content digest")
        return self._update_with_lease(key, lease_token, now,
            "content_digest = ?", (content_digest,), expected_content_digest=content_digest)

    def bind_drive_file_id(self, key: BillingPDFKey, lease_token: str,
                           file_id: str, *, now: datetime) -> BillingPDFReservation:
        if not _DRIVE_ID.fullmatch(file_id):
            raise InvalidReservation("Invalid Google Drive file ID")
        return self._update_with_lease(key, lease_token, now,
            "drive_file_id = ?", (file_id,), expected_file_id=file_id,
            require_content_digest=True)

    def confirm(self, key: BillingPDFKey, lease_token: str, *, file_id: str,
                link: str, content_digest: str, now: datetime) -> BillingPDFReservation:
        if not _DRIVE_ID.fullmatch(file_id) or not link.startswith("https://drive.google.com/"):
            raise InvalidReservation("Invalid Google Drive confirmation")
        if not _HEX.fullmatch(content_digest):
            raise InvalidReservation("Invalid content digest")
        return self._update_with_lease(key, lease_token, now,
            "confirmed_link = ?, lease_token = NULL, lease_until = NULL", (link,),
            expected_file_id=file_id, require_file_id=True,
            expected_content_digest=content_digest, require_content_digest=True)

    def _update_with_lease(self, key: BillingPDFKey, lease_token: str, now: datetime,
                           assignment: str, values: tuple, *, expected_file_id: str | None = None,
                           require_file_id: bool = False,
                           expected_content_digest: str | None = None,
                           require_content_digest: bool = False) -> BillingPDFReservation:
        key = key.normalized()
        now = self._utc(now)
        try:
            uuid.UUID(lease_token)
        except (ValueError, AttributeError) as error:
            raise InvalidReservation("Invalid lease token") from error
        with self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                row = self._row(connection, key)
                if (row is None or row["lease_token"] != lease_token or row["lease_until"] is None
                        or row["lease_until"] <= now.isoformat() or row["confirmed_link"] is not None):
                    raise ReservationChanged("Lease is no longer current")
                if require_file_id and row["drive_file_id"] != expected_file_id:
                    raise ReservationChanged("Confirmed file differs from saved reservation")
                if expected_file_id is not None and row["drive_file_id"] is not None and row["drive_file_id"] != expected_file_id:
                    raise ReservationChanged("Drive file ID cannot change after reservation")
                if require_content_digest and row["content_digest"] is None:
                    raise ReservationChanged("PDF bytes must be recorded before Drive upload")
                if (expected_content_digest is not None and row["content_digest"] is not None
                        and row["content_digest"] != expected_content_digest):
                    raise ReservationChanged("PDF content digest cannot change for this revision")
                connection.execute(f"""
                    UPDATE billing_pdf_archive_intents SET {assignment}
                    WHERE company_id = ? AND drive_account = ? AND document_kind = ?
                      AND document_id = ? AND source_digest = ? AND renderer_version = ?
                """, (*values, *self._parts(key)))
                result = self._row(connection, key)
                connection.execute("COMMIT")
                if result is None:
                    raise ReservationChanged("Reservation disappeared")
                return self._reservation(key, result, include_token=True)
            except Exception:
                connection.execute("ROLLBACK")
                raise

    @contextmanager
    def _connection(self):
        connection = sqlite3.connect(self.database, timeout=2, isolation_level=None)
        try:
            connection.row_factory = sqlite3.Row
            connection.execute("PRAGMA busy_timeout = 2000")
            yield connection
        finally:
            connection.close()

    @staticmethod
    def _utc(value: datetime) -> datetime:
        if value.tzinfo is None:
            raise InvalidReservation("A timezone-aware clock is required")
        return value.astimezone(timezone.utc)

    @staticmethod
    def _parts(key: BillingPDFKey) -> tuple[str, ...]:
        return (key.company_id, key.drive_account, key.document_kind,
                key.document_id, key.source_digest, key.renderer_version)

    def _row(self, connection: sqlite3.Connection, key: BillingPDFKey) -> sqlite3.Row | None:
        return connection.execute("""
            SELECT * FROM billing_pdf_archive_intents
            WHERE company_id = ? AND drive_account = ? AND document_kind = ?
              AND document_id = ? AND source_digest = ? AND renderer_version = ?
        """, self._parts(key)).fetchone()

    @staticmethod
    def _reservation(key: BillingPDFKey, row: sqlite3.Row,
                     *, include_token: bool = False) -> BillingPDFReservation:
        return BillingPDFReservation(key, row["attachment_id"], row["rendered_at"],
            row["lease_token"] if include_token else None,
            row["lease_until"], row["content_digest"], row["drive_file_id"], row["confirmed_link"])
