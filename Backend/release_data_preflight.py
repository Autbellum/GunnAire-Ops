#!/usr/bin/env python3
"""Verify a supplied backend backup and migrate only a disposable restored copy.

This command does not discover a production service, read deployment credentials,
contact a provider, or write to the supplied backup artifact. Off-host custody
and the deployed Git SHA remain independent operator evidence.
"""

from __future__ import annotations

import argparse
from contextlib import closing
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import sqlite3
import tempfile
import time

try:
    from . import (backup_backend, billing_estimate_jobs, billing_pdf_archive_ledger,
                   billing_pdf_artifacts, gunnaire_backend)
except ImportError:
    import backup_backend
    import billing_estimate_jobs
    import billing_pdf_archive_ledger
    import billing_pdf_artifacts
    import gunnaire_backend


class PreflightError(RuntimeError):
    pass


def _read_backup_time(artifact: Path, now: datetime) -> str:
    try:
        manifest = json.loads((artifact / backup_backend.MANIFEST_FILENAME).read_text(encoding="utf-8"))
        stamp = manifest["createdAt"]
        created = datetime.fromisoformat(stamp)
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        raise PreflightError("Backup creation time is missing or invalid") from error
    if created.tzinfo is None or created.utcoffset() != timedelta(0):
        raise PreflightError("Backup creation time must be UTC")
    if created > now + timedelta(minutes=5) or now - created > timedelta(hours=24):
        raise PreflightError("Backup is future-dated or older than 24 hours")
    return stamp


def _check_database(connection: sqlite3.Connection) -> None:
    result = connection.execute("PRAGMA quick_check").fetchone()
    if result != ("ok",):
        raise PreflightError("Restored SQLite quick_check failed")
    if connection.execute("PRAGMA foreign_key_check").fetchone() is not None:
        raise PreflightError("Restored SQLite foreign_key_check failed")


def _table_exists(connection: sqlite3.Connection, name: str) -> bool:
    return connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)
    ).fetchone() is not None


def _check_pdf_revisions(connection: sqlite3.Connection) -> None:
    name = "billing_pdf_archive_intents"
    if not _table_exists(connection, name):
        return
    columns = {row[1] for row in connection.execute(f"PRAGMA table_info({name})")}
    identity = {"company_id", "drive_account", "document_kind", "document_id",
                "source_digest", "renderer_version"}
    if not identity <= columns:
        raise PreflightError("Existing PDF reservation schema is incomplete")
    conflict = connection.execute("""
        SELECT 1 FROM billing_pdf_archive_intents
        GROUP BY company_id,drive_account,document_kind,document_id
        HAVING COUNT(DISTINCT source_digest || ':' || renderer_version) > 1
        LIMIT 1
    """).fetchone()
    if conflict is not None:
        raise PreflightError("Existing PDF reservations contain conflicting revisions")


def _check_migration_shape(connection: sqlite3.Connection) -> None:
    if not _table_exists(connection, "billing_publications"):
        raise PreflightError("Backup lacks the existing billing publication table")
    estimate_rows = list(connection.execute("PRAGMA table_info(billing_estimate_jobs)"))
    pdf_rows = list(connection.execute("PRAGMA table_info(billing_pdf_archive_intents)"))
    estimate = {row[1]: row for row in estimate_rows}
    pdf = {row[1]: row for row in pdf_rows}
    due = [row[2] for row in connection.execute("PRAGMA index_info(billing_estimate_jobs_due)")]
    estimate_fields = {"publication_id", "session_id", "state", "attempts",
                       "not_before", "lease_id", "lease_until", "last_error_code",
                       "created_at", "updated_at"}
    estimate_parent = {(row[2], row[3], row[4]) for row in connection.execute(
        "PRAGMA foreign_key_list(billing_estimate_jobs)")}
    if not estimate_fields <= estimate.keys() or estimate["publication_id"][5] != 1 or \
            due != ["state", "not_before", "lease_until"] or \
            ("billing_publications", "publication_id", "id") not in estimate_parent:
        raise PreflightError("Estimate worker schema did not migrate")
    pdf_fields = {"company_id", "drive_account", "document_kind", "document_id",
                  "source_digest", "renderer_version", "attachment_id", "rendered_at",
                  "lease_token", "lease_until", "content_digest", "drive_file_id",
                  "confirmed_link", "artifact_ready", "artifact_bytes"}
    key = ["company_id", "drive_account", "document_kind", "document_id",
           "source_digest", "renderer_version"]
    primary_key = [row[1] for row in sorted(pdf_rows, key=lambda row: row[5]) if row[5] > 0]
    required_nonnull = set(key) | {"attachment_id", "rendered_at", "artifact_ready"}
    unique_indexes = {
        tuple(column[0] for column in connection.execute(
            "SELECT name FROM pragma_index_info(?)", (row[1],)))
        for row in connection.execute("PRAGMA index_list(billing_pdf_archive_intents)")
        if row[2] == 1
    }
    if not pdf_fields <= pdf.keys() or primary_key != key or \
            any(pdf[column][3] != 1 for column in required_nonnull) or \
            pdf["artifact_ready"][4] not in ("0", "(0)") or \
            ("attachment_id",) not in unique_indexes or ("drive_file_id",) not in unique_indexes:
        raise PreflightError("PDF artifact schema did not migrate")


def _check_ready_artifacts(connection: sqlite3.Connection, storage: Path) -> int:
    """A manifest-valid storage tree must still match each ready DB reservation."""
    count = 0
    store = billing_pdf_artifacts.BillingPDFArtifactStore(storage)
    query = """SELECT company_id,drive_account,document_kind,document_id,source_digest,
               renderer_version,attachment_id,rendered_at,lease_token,lease_until,
               content_digest,drive_file_id,confirmed_link,artifact_ready,artifact_bytes
               FROM billing_pdf_archive_intents WHERE artifact_ready=1"""
    for row in connection.execute(query):
        key = billing_pdf_archive_ledger.BillingPDFKey(*row[:6])
        reservation = billing_pdf_archive_ledger.BillingPDFReservation(
            key, *row[6:])
        if not isinstance(reservation.artifact_bytes, int) or reservation.artifact_bytes < 5:
            raise PreflightError("Ready PDF reservation has no valid byte count")
        try:
            content = store.read(reservation)
        except billing_pdf_artifacts.ArtifactError as error:
            raise PreflightError("Ready PDF reservation has no matching stored artifact") from error
        if len(content) != reservation.artifact_bytes:
            raise PreflightError("Ready PDF reservation byte count differs from stored artifact")
        count += 1
    return count


def _validate_paths(backup: Path, scratch: Path) -> tuple[Path, Path]:
    if not backup.is_absolute() or not scratch.is_absolute():
        raise PreflightError("Backup and scratch paths must be absolute")
    if backup.is_symlink() or not backup.is_dir():
        raise PreflightError("Backup must be an existing ordinary directory")
    source = backup.resolve()
    target = scratch.resolve()
    temp_root = Path(tempfile.gettempdir()).resolve()
    if target.exists() or target == temp_root or temp_root not in target.parents:
        raise PreflightError("Scratch must be a new directory under the system temporary root")
    if source == target or source in target.parents or target in source.parents:
        raise PreflightError("Scratch and backup paths must be separate")
    return source, target


def run(backup: Path, scratch: Path, expected_artifact_id: str,
        *, now: datetime | None = None) -> dict[str, object]:
    """Return non-sensitive evidence; failures leave the original artifact intact."""
    source, target = _validate_paths(backup, scratch)
    if not isinstance(expected_artifact_id, str) or len(expected_artifact_id) != 16 or \
            any(character not in "0123456789abcdef" for character in expected_artifact_id):
        raise PreflightError("A recorded 16-character backup artifact ID is required")
    clock = now or datetime.now(timezone.utc)
    if clock.tzinfo is None:
        raise PreflightError("Preflight clock must include a time zone")
    verified = backup_backend.verify_backup(source)
    if verified["artifactID"] != expected_artifact_id:
        raise PreflightError("Backup differs from the recorded artifact ID")
    created_at = _read_backup_time(source, clock.astimezone(timezone.utc))
    restore_started = time.monotonic()
    backup_backend.restore_drill(source, target)
    restore_seconds = round(time.monotonic() - restore_started, 3)
    restored = target / backup_backend.DATABASE_FILENAME
    with closing(sqlite3.connect(restored)) as connection:
        _check_database(connection)
        if not _table_exists(connection, "billing_publications"):
            raise PreflightError("Backup lacks the existing billing publication table")
        _check_pdf_revisions(connection)
        connection.execute("PRAGMA foreign_keys=ON")
        with connection:
            billing_estimate_jobs.initialize_schema(connection)
            billing_pdf_archive_ledger.initialize_schema(connection)
            _check_migration_shape(connection)
            _check_pdf_revisions(connection)
            ready_artifacts = _check_ready_artifacts(connection, target / "storage")
            _check_database(connection)
    if backup_backend.verify_backup(source)["artifactID"] != expected_artifact_id:
        raise PreflightError("Supplied backup changed during preflight")
    return {
        "status": "copy_verified",
        "serviceVersion": gunnaire_backend.SERVICE_VERSION,
        "backupArtifactID": expected_artifact_id,
        "backupCreatedAt": created_at,
        "documentCount": verified["documentCount"],
        "readyPDFArtifactsChecked": ready_artifacts,
        "restoreDrill": "verified",
        "restoreDurationSeconds": restore_seconds,
        "migrationCopy": "verified",
        "offHostCustody": "operator_evidence_required",
        "deployedGitSHA": "operator_evidence_required",
        "providerAcceptance": "operator_evidence_required",
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backup", type=Path, required=True,
                        help="Locally accessible copy of the independently retained backup")
    parser.add_argument("--scratch", type=Path, required=True,
                        help="New disposable path under the system temporary directory")
    parser.add_argument("--expected-artifact-id", required=True,
                        help="Previously recorded 16-character manifest hash prefix")
    arguments = parser.parse_args()
    try:
        result = run(arguments.backup, arguments.scratch, arguments.expected_artifact_id)
    except (PreflightError, backup_backend.BackupVerificationError, sqlite3.Error) as error:
        parser.exit(2, f"preflight failed: {error}\n")
    except (OSError, UnicodeError):
        parser.exit(2, "preflight failed: backup or disposable copy is unavailable\n")
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
