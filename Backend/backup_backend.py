#!/usr/bin/env python3
"""Create and verify portable GunnAire SQLite/document backup artifacts."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sqlite3
from datetime import datetime, timezone
from pathlib import Path


MANIFEST_VERSION = 1
DATABASE_FILENAME = "gunnaire_backend.sqlite3"
MANIFEST_FILENAME = "manifest.json"


class BackupVerificationError(RuntimeError):
    pass


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_record(path: Path, relative_to: Path) -> dict[str, object]:
    return {
        "path": path.relative_to(relative_to).as_posix(),
        "bytes": path.stat().st_size,
        "sha256": sha256_file(path),
    }


def sqlite_integrity(path: Path) -> None:
    try:
        connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        result = connection.execute("PRAGMA integrity_check").fetchone()
    except sqlite3.Error as error:
        raise BackupVerificationError("Backup database cannot be opened.") from error
    finally:
        if "connection" in locals():
            connection.close()
    if result is None or str(result[0]).lower() != "ok":
        raise BackupVerificationError("Backup database integrity check failed.")


def write_json_atomic(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def create_backup(
    database: Path,
    storage: Path,
    destination: Path,
    *,
    state_file: Path | None = None,
    created_at: datetime | None = None,
) -> dict[str, object]:
    source_database = database.expanduser().resolve()
    source_storage = storage.expanduser().resolve()
    artifact = destination.expanduser().resolve()
    if not source_database.is_file():
        raise BackupVerificationError("Source database does not exist.")
    if not source_storage.is_dir():
        raise BackupVerificationError("Source document storage does not exist.")
    if artifact.exists():
        raise BackupVerificationError("Backup destination already exists; choose a new artifact directory.")
    if artifact == source_storage or source_storage in artifact.parents:
        raise BackupVerificationError("Backup destination cannot be inside shared document storage.")

    timestamp = created_at or utc_now()
    artifact.mkdir(parents=True)
    try:
        database_copy = artifact / DATABASE_FILENAME
        source_connection = sqlite3.connect(source_database)
        destination_connection = sqlite3.connect(database_copy)
        try:
            source_connection.backup(destination_connection)
        finally:
            destination_connection.close()
            source_connection.close()
        sqlite_integrity(database_copy)

        storage_copy = artifact / "storage"
        storage_copy.mkdir()
        for source in sorted(source_storage.rglob("*")):
            if source.is_symlink():
                raise BackupVerificationError("Shared document storage contains a symbolic link; backup stopped.")
            relative = source.relative_to(source_storage)
            target = storage_copy / relative
            if source.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            elif source.is_file():
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)

        document_records = [
            file_record(path, artifact)
            for path in sorted(storage_copy.rglob("*"))
            if path.is_file()
        ]
        manifest: dict[str, object] = {
            "schemaVersion": MANIFEST_VERSION,
            "createdAt": timestamp.isoformat(),
            "database": file_record(database_copy, artifact),
            "documents": document_records,
        }
        write_json_atomic(artifact / MANIFEST_FILENAME, manifest)
        summary = verify_backup(artifact)
        if state_file is not None:
            write_json_atomic(
                state_file.expanduser(),
                {
                    "artifactID": summary["artifactID"],
                    "verifiedAt": utc_now().isoformat(),
                    "createdAt": manifest["createdAt"],
                    "databaseBytes": summary["databaseBytes"],
                    "documentCount": summary["documentCount"],
                    "totalBytes": summary["totalBytes"],
                },
            )
        return summary
    except Exception:
        shutil.rmtree(artifact, ignore_errors=True)
        raise


def verified_record(artifact: Path, record: object) -> tuple[Path, int]:
    if not isinstance(record, dict):
        raise BackupVerificationError("Backup manifest contains an invalid file record.")
    relative = record.get("path")
    expected_size = record.get("bytes")
    expected_hash = record.get("sha256")
    if not isinstance(relative, str) or not isinstance(expected_size, int) or not isinstance(expected_hash, str):
        raise BackupVerificationError("Backup manifest file metadata is invalid.")
    candidate = (artifact / relative).resolve()
    if artifact not in candidate.parents:
        raise BackupVerificationError("Backup manifest contains an unsafe file path.")
    if not candidate.is_file() or candidate.stat().st_size != expected_size or sha256_file(candidate) != expected_hash:
        raise BackupVerificationError(f"Backup file verification failed: {relative}")
    return candidate, expected_size


def verify_backup(destination: Path) -> dict[str, object]:
    artifact = destination.expanduser().resolve()
    manifest_path = artifact / MANIFEST_FILENAME
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BackupVerificationError("Backup manifest is missing or invalid.") from error
    if not isinstance(manifest, dict) or manifest.get("schemaVersion") != MANIFEST_VERSION:
        raise BackupVerificationError("Backup manifest version is unsupported.")
    database_path, database_bytes = verified_record(artifact, manifest.get("database"))
    sqlite_integrity(database_path)
    documents = manifest.get("documents")
    if not isinstance(documents, list):
        raise BackupVerificationError("Backup document manifest is invalid.")
    expected_document_paths: set[str] = set()
    document_bytes = 0
    for record in documents:
        path, size = verified_record(artifact, record)
        relative = path.relative_to(artifact).as_posix()
        if not relative.startswith("storage/") or relative in expected_document_paths:
            raise BackupVerificationError("Backup document manifest contains an invalid or duplicate path.")
        expected_document_paths.add(relative)
        document_bytes += size
    actual_document_paths = {
        path.relative_to(artifact).as_posix()
        for path in (artifact / "storage").rglob("*")
        if path.is_file()
    }
    if actual_document_paths != expected_document_paths:
        raise BackupVerificationError("Backup document set differs from the manifest.")
    manifest_hash = sha256_file(manifest_path)
    return {
        "artifactID": manifest_hash[:16],
        "databaseBytes": database_bytes,
        "documentCount": len(documents),
        "totalBytes": database_bytes + document_bytes,
    }


def restore_drill(backup: Path, destination: Path) -> dict[str, object]:
    source = backup.expanduser().resolve()
    target = destination.expanduser().resolve()
    verify_backup(source)
    if target.exists():
        raise BackupVerificationError("Restore-drill destination already exists; choose a new empty target.")
    try:
        shutil.copytree(source, target, symlinks=False)
        summary = verify_backup(target)
        write_json_atomic(
            target / "restore_drill.json",
            {
                "restoredAt": utc_now().isoformat(),
                "sourceArtifactID": summary["artifactID"],
                "verified": True,
            },
        )
        return summary
    except Exception:
        shutil.rmtree(target, ignore_errors=True)
        raise


def parser() -> argparse.ArgumentParser:
    command_parser = argparse.ArgumentParser(description=__doc__)
    subcommands = command_parser.add_subparsers(dest="command", required=True)

    backup = subcommands.add_parser("backup", help="Create and verify a new backup artifact directory.")
    backup.add_argument("--database", type=Path, required=True)
    backup.add_argument("--storage", type=Path, required=True)
    backup.add_argument("--destination", type=Path, required=True)
    backup.add_argument("--state-file", type=Path)

    verify = subcommands.add_parser("verify", help="Verify every database and document file in an artifact.")
    verify.add_argument("--backup", type=Path, required=True)

    drill = subcommands.add_parser("restore-drill", help="Copy an artifact to a new target and verify the restored data.")
    drill.add_argument("--backup", type=Path, required=True)
    drill.add_argument("--destination", type=Path, required=True)
    return command_parser


def main() -> None:
    arguments = parser().parse_args()
    if arguments.command == "backup":
        summary = create_backup(
            arguments.database,
            arguments.storage,
            arguments.destination,
            state_file=arguments.state_file,
        )
    elif arguments.command == "verify":
        summary = verify_backup(arguments.backup)
    else:
        summary = restore_drill(arguments.backup, arguments.destination)
    print(json.dumps(summary, sort_keys=True))


if __name__ == "__main__":
    main()
