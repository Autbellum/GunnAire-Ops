#!/usr/bin/env python3
"""Record a bounded, unauthenticated public-health observation for 0124 review.

The public version marker cannot identify Render's deployed Git commit or prove
off-host backup custody. This packet always leaves those as separate gates.
"""

from __future__ import annotations

import argparse
import ast
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import tempfile
import urllib.error
import urllib.request

HEALTH_URL = "https://gunnaire-api.onrender.com/health"
_VERSION = re.compile(r"\d{4}\.\d{2}\.\d{2}\.\d+\Z")
_ARTIFACT = re.compile(r"[0-9a-f]{16}\Z")


class PacketError(RuntimeError):
    pass


def candidate_version() -> str:
    """Read the backend's literal release marker without importing server dependencies."""
    source = Path(__file__).with_name("gunnaire_backend.py")
    try:
        tree = ast.parse(source.read_text(encoding="utf-8"), filename=str(source))
    except (OSError, UnicodeError, SyntaxError) as error:
        raise PacketError("Candidate backend source could not be read") from error
    assignments = [node for node in tree.body
                   if isinstance(node, ast.Assign) and any(
                       isinstance(target, ast.Name) and target.id == "SERVICE_VERSION"
                       for target in node.targets)]
    if len(assignments) != 1 or len(assignments[0].targets) != 1 or \
            not isinstance(assignments[0].value, ast.Constant) or \
            not isinstance(assignments[0].value.value, str) or \
            _VERSION.fullmatch(assignments[0].value.value) is None:
        raise PacketError("Candidate backend version is not a single literal")
    return assignments[0].value.value


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        return None


def _in_temporary_directory(path: Path) -> bool:
    if not path.is_absolute() or path.is_symlink():
        return False
    resolved = path.resolve()
    roots = {Path(tempfile.gettempdir()).resolve(), Path("/tmp").resolve()}
    return any(root in resolved.parents for root in roots)


def _strict_json(raw: bytes) -> dict:
    if len(raw) > 4096:
        raise PacketError("Public health response exceeded its bound")

    def unique(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise PacketError("Public health response repeated a key")
            value[key] = item
        return value

    try:
        result = json.loads(raw.decode("utf-8"), object_pairs_hook=unique)
    except (UnicodeError, ValueError) as error:
        raise PacketError("Public health response was invalid JSON") from error
    if not isinstance(result, dict):
        raise PacketError("Public health response was not an object")
    return result


def fetch_health() -> tuple[int, dict[str, str], bytes]:
    request = urllib.request.Request(HEALTH_URL, headers={
        "Accept": "application/json", "Cache-Control": "no-cache"}, method="GET")
    opener = urllib.request.build_opener(_NoRedirect, urllib.request.ProxyHandler({}))
    try:
        with opener.open(request, timeout=10) as response:
            if response.url != HEALTH_URL:
                raise PacketError("Public health changed origin or path")
            headers = {key.lower(): value for key, value in response.headers.items()
                       if key.lower() in {"content-type", "cache-control", "cf-cache-status"}}
            return response.status, headers, response.read(4097)
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, OSError) as error:
        raise PacketError("Public health was unavailable without credentials") from error


def _data_summary(path: Path | None, expected_version: str) -> dict[str, object]:
    if path is None:
        return {"status": "not_supplied"}
    try:
        if not _in_temporary_directory(path) or not path.is_file() or path.stat().st_size > 16_384:
            raise PacketError("Data preflight report is unavailable or oversized")
        report = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError) as error:
        raise PacketError("Data preflight report is invalid") from error
    if not isinstance(report, dict) or report.get("status") != "copy_verified" or \
            report.get("serviceVersion") != expected_version or \
            not isinstance(report.get("backupArtifactID"), str) or \
            _ARTIFACT.fullmatch(report["backupArtifactID"]) is None or \
            report.get("restoreDrill") != "verified" or \
            report.get("migrationCopy") != "verified" or \
            report.get("offHostCustody") != "operator_evidence_required":
        raise PacketError("Data preflight report does not match this candidate")
    return {"status": "report_consistent_source_unverified", "backupArtifactID": report["backupArtifactID"],
            "offHostCustody": "operator_evidence_required"}


def capture(fetch=fetch_health, *, data_report: Path | None = None,
            observed_at: datetime | None = None) -> dict[str, object]:
    expected = candidate_version()
    moment = observed_at or datetime.now(timezone.utc)
    if moment.tzinfo is None:
        raise PacketError("Observation time must include a time zone")
    data = _data_summary(data_report, expected)
    health: dict[str, object] = {"status": "unavailable"}
    try:
        status, headers, raw = fetch()
        payload = _strict_json(raw)
        cache_control = headers.get("cache-control", "").lower()
        cache_status = headers.get("cf-cache-status", "").upper()
        fresh = "no-store" in cache_control and cache_status not in {"HIT", "STALE"}
        version = payload.get("serviceVersion")
        if (status == 200 and payload.get("status") == "ok" and
                isinstance(version, str) and _VERSION.fullmatch(version) is not None and
                headers.get("content-type", "").lower().startswith("application/json") and fresh):
            health = {"status": "observed", "serviceVersion": version,
                      "matchesCandidateVersion": version == expected,
                      "cacheControl": "no-store"}
        else:
            health = {"status": "unverified"}
    except PacketError:
        pass
    return {
        "schemaVersion": 1,
        "observedAt": moment.astimezone(timezone.utc).isoformat(),
        "candidateServiceVersion": expected,
        "publicHealth": health,
        "dataCopyPreflight": data,
        "deployedGitSHA": "not_publicly_verifiable",
        "renderDeploymentID": "not_publicly_verifiable",
        "offHostBackupCustody": "operator_evidence_required",
        "decision": "NO_GO_PENDING_OPERATOR_EVIDENCE",
        "requiredOperatorEvidence": [
            "Render live deployment ID and exact Git SHA from its authenticated deployment record",
            "independent encrypted off-host backup custody and matching artifact ID",
            "production-data copy restore and migration preflight result",
            "reviewed old-writer drain and approved live provider acceptance",
        ],
    }


def _write_new(path: Path, packet: dict[str, object]) -> None:
    if not _in_temporary_directory(path):
        raise PacketError("Packet output must be a new path under the system temporary root")
    payload = (json.dumps(packet, indent=2, sort_keys=True) + "\n").encode("utf-8")
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
    except OSError as error:
        raise PacketError("Packet output could not be created without replacement") from error


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True,
                        help="New absolute JSON path for the no-go evidence packet")
    parser.add_argument("--data-preflight-report", type=Path,
                        help="Optional JSON stdout saved from release_data_preflight")
    arguments = parser.parse_args()
    try:
        packet = capture(data_report=arguments.data_preflight_report)
        _write_new(arguments.output, packet)
    except PacketError as error:
        parser.exit(2, f"packet failed: {error}\n")
    print(json.dumps({"decision": packet["decision"], "output": str(arguments.output)},
                     sort_keys=True))


if __name__ == "__main__":
    main()
