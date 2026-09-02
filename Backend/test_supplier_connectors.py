from __future__ import annotations

import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest import mock

from Backend import gunnaire_backend as backend


class SuccessfulSupplierAdapter(backend.SupplierConnectorAdapter):
    kind = "johnstoneDirectConnect"

    def __init__(self) -> None:
        self.submit_calls = 0
        self.recover_calls = 0

    @staticmethod
    def acceptance(order: dict[str, object]) -> dict[str, object]:
        confirmed_at = datetime.now(timezone.utc)
        lines = order["lines"]
        assert isinstance(lines, list)
        return {
            "externalOrderID": "JOHNSTONE-ORDER-48291",
            "reference": "JS-48291",
            "supplierLocation": "Winston-Salem",
            "confirmedLines": [
                {
                    "lineID": line["lineID"],
                    "supplierPartNumber": line["supplierPartNumber"],
                    "confirmedQuantity": line["quantity"],
                    "confirmedUnitCost": max(float(line["expectedUnitCost"]) - 0.5, 0),
                }
                for line in lines
            ],
            "confirmedShippingCost": 4.0,
            "currencyCode": "USD",
            "confirmedAt": confirmed_at.isoformat(),
            "priceAvailabilityCheckedAt": (confirmed_at - timedelta(minutes=2)).isoformat(),
        }

    def submit_order(self, order: dict[str, object], idempotency_key: str) -> dict[str, object]:
        self.submit_calls += 1
        return self.acceptance(order)

    def recover_order(self, order: dict[str, object], idempotency_key: str) -> dict[str, object] | None:
        self.recover_calls += 1
        return self.acceptance(order)


class UnknownOutcomeSupplierAdapter(SuccessfulSupplierAdapter):
    def __init__(self, *, recover_successfully: bool) -> None:
        super().__init__()
        self.recover_successfully = recover_successfully

    def submit_order(self, order: dict[str, object], idempotency_key: str) -> dict[str, object]:
        self.submit_calls += 1
        raise backend.SupplierConnectorFailure(
            "supplier-timeout",
            "The supplier did not return a final acknowledgement.",
            outcome_unknown=True,
        )

    def recover_order(self, order: dict[str, object], idempotency_key: str) -> dict[str, object] | None:
        self.recover_calls += 1
        return self.acceptance(order) if self.recover_successfully else None


class MismatchedLineSupplierAdapter(SuccessfulSupplierAdapter):
    @staticmethod
    def acceptance(order: dict[str, object]) -> dict[str, object]:
        acknowledgement = SuccessfulSupplierAdapter.acceptance(order)
        confirmed_lines = acknowledgement["confirmedLines"]
        assert isinstance(confirmed_lines, list)
        confirmed_lines[-1] = dict(confirmed_lines[-1], confirmedQuantity=999)
        return acknowledgement


class SupplierConnectorTests(unittest.TestCase):
    api_token = "supplier-connector-admin-token"

    @staticmethod
    def valid_payload() -> dict[str, object]:
        return {
            "contractVersion": backend.SUPPLIER_CONNECTOR_CONTRACT_VERSION,
            "connectorKind": "johnstoneDirectConnect",
            "purchaseOrderID": str(uuid.uuid4()),
            "purchaseOrderNumber": "PO-20260828-0001",
            "serviceCallID": str(uuid.uuid4()),
            "vendorName": "Johnstone Supply",
            "lines": [
                {
                    "lineID": str(uuid.uuid4()),
                    "itemName": "40A Contactor",
                    "internalSKU": "CNT-40A",
                    "supplierPartNumber": "JS-CNT-40A",
                    "quantity": 3,
                    "expectedUnitCost": 31.0,
                }
            ],
            "expectedShippingCost": 5.0,
            "currencyCode": "USD",
            "supplierLocation": "Winston-Salem",
            "priceAvailabilityCheckedAt": datetime.now(timezone.utc).isoformat(),
            "orderNotes": "Do not substitute the coil voltage.",
        }

    @staticmethod
    def request(
        url: str,
        *,
        token: str | None = None,
        payload: dict[str, object] | None = None,
        idempotency_key: str | None = None,
    ) -> urllib.request.Request:
        headers = {"Accept": "application/json"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        method = "GET"
        body = None
        if payload is not None:
            method = "POST"
            body = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
        if idempotency_key:
            headers["Idempotency-Key"] = idempotency_key
        return urllib.request.Request(url, data=body, method=method, headers=headers)

    @staticmethod
    def error_payload(error: urllib.error.HTTPError) -> dict[str, object]:
        return json.loads(error.read().decode("utf-8"))

    def configured_backend(self, root: Path):
        return mock.patch.multiple(
            backend,
            DB_PATH=root / "backend.sqlite3",
            STORAGE_ROOT=root / "storage",
            AUTH_MODE="api-token",
            API_TOKEN=self.api_token,
        )

    def serve(self) -> tuple[ThreadingHTTPServer, threading.Thread, str]:
        server = ThreadingHTTPServer(("127.0.0.1", 0), backend.GunnAireBackendHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        return server, thread, f"http://127.0.0.1:{server.server_port}"

    def test_connector_discovery_is_admin_only_and_never_exposes_credentials(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.configured_backend(root), mock.patch.dict(
                backend.SUPPLIER_CONNECTOR_ADAPTERS, {}, clear=True
            ):
                backend.initialize_database()
                server, thread, base_url = self.serve()
                try:
                    with self.assertRaises(urllib.error.HTTPError) as unauthorized:
                        urllib.request.urlopen(f"{base_url}/api/supplier-connectors", timeout=5)
                    self.assertEqual(unauthorized.exception.code, 401)

                    with urllib.request.urlopen(
                        self.request(
                            f"{base_url}/api/supplier-connectors",
                            token=self.api_token,
                        ),
                        timeout=5,
                    ) as response:
                        payload = json.loads(response.read().decode("utf-8"))
                    self.assertEqual(response.status, 200)
                    self.assertEqual(len(payload["connectors"]), 4)
                    self.assertTrue(all(
                        record["contractVersion"] == backend.SUPPLIER_CONNECTOR_CONTRACT_VERSION
                        for record in payload["connectors"]
                    ))
                    self.assertFalse(any(record["canSubmitOrders"] for record in payload["connectors"]))
                    kinds = {record["kind"]: record for record in payload["connectors"]}
                    self.assertEqual(kinds["johnstonePunchOut"]["status"], "onboardingRequired")
                    self.assertEqual(kinds["johnstoneDirectConnect"]["accessModel"], "accountRepresentativeProvisioned")
                    self.assertEqual(kinds["johnstoneDirectConnect"]["integrationProtocol"], "formattedDataOrFile")
                    self.assertEqual(kinds["johnstoneDirectConnect"]["capabilities"], ["purchaseOrders"])
                    self.assertEqual(kinds["johnstonePunchOut"]["integrationProtocol"], "cXMLPunchOut")
                    self.assertEqual(kinds["lennoxPartner"]["status"], "thirdPartyOnly")
                    self.assertEqual(kinds["lennoxPartner"]["accessModel"], "exclusiveThirdParty")
                    self.assertEqual(kinds["lennoxPartner"]["integrationProtocol"], "serviceTitanMarketplace")
                    self.assertFalse(kinds["lennoxPartner"]["publicAPIDocumented"])
                    self.assertIn("ServiceTitan", kinds["lennoxPartner"]["detail"])
                    self.assertEqual(kinds["lennoxPartner"]["publicDocumentationReviewedAt"], "2026-09-02")
                    self.assertGreaterEqual(len(kinds["lennoxPartner"]["onboardingRequirements"]), 4)
                    self.assertIsNone(kinds["genericCatalog"]["publicAPIDocumented"])
                    serialized = json.dumps(payload).lower()
                    self.assertNotIn("token", serialized)
                    self.assertNotIn("password", serialized)
                    self.assertNotIn("secret", serialized)
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=5)

    def test_disabled_connector_rejects_before_creating_an_attempt(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.configured_backend(root), mock.patch.dict(
                backend.SUPPLIER_CONNECTOR_ADAPTERS, {}, clear=True
            ):
                backend.initialize_database()
                server, thread, base_url = self.serve()
                try:
                    with self.assertRaises(urllib.error.HTTPError) as unavailable:
                        urllib.request.urlopen(
                            self.request(
                                f"{base_url}/api/supplier-connectors/orders",
                                token=self.api_token,
                                payload=self.valid_payload(),
                                idempotency_key="supplier-order-disabled-0001",
                            ),
                            timeout=5,
                        )
                    self.assertEqual(unavailable.exception.code, 409)
                    error = self.error_payload(unavailable.exception)
                    self.assertFalse(error["connector"]["canSubmitOrders"])
                    with backend.db() as connection:
                        count = connection.execute(
                            "SELECT COUNT(*) FROM supplier_order_attempts"
                        ).fetchone()[0]
                    self.assertEqual(count, 0)
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=5)

    def test_success_is_idempotent_audited_and_rejects_payload_or_order_reuse(self) -> None:
        adapter = SuccessfulSupplierAdapter()
        payload = self.valid_payload()
        lines = payload["lines"]
        assert isinstance(lines, list)
        lines.append(
            {
                "lineID": str(uuid.uuid4()),
                "itemName": "60A Disconnect",
                "internalSKU": "DISC-60A",
                "supplierPartNumber": "JS-DISC-60A",
                "quantity": 1,
                "expectedUnitCost": 45.0,
            }
        )
        key = "supplier-order-johnstone-0001"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.configured_backend(root), mock.patch.dict(
                backend.SUPPLIER_CONNECTOR_ADAPTERS,
                {adapter.kind: adapter},
                clear=True,
            ):
                backend.initialize_database()
                server, thread, base_url = self.serve()
                endpoint = f"{base_url}/api/supplier-connectors/orders"
                try:
                    with urllib.request.urlopen(
                        self.request(
                            endpoint,
                            token=self.api_token,
                            payload=payload,
                            idempotency_key=key,
                        ),
                        timeout=5,
                    ) as response:
                        first = json.loads(response.read().decode("utf-8"))["acceptance"]
                    self.assertEqual(response.status, 201)
                    self.assertFalse(first["replayed"])
                    self.assertEqual(first["contractVersion"], backend.SUPPLIER_CONNECTOR_CONTRACT_VERSION)
                    self.assertEqual(first["connectorKind"], adapter.kind)
                    self.assertEqual(first["purchaseOrderID"], payload["purchaseOrderID"])
                    self.assertEqual(first["confirmedByEmail"], backend.PRIMARY_ADMIN_EMAIL)
                    self.assertEqual(first["confirmedLines"][0]["lineID"], payload["lines"][0]["lineID"])
                    self.assertEqual(first["confirmedLines"][0]["confirmedQuantity"], 3)
                    self.assertEqual(first["confirmedLines"][0]["confirmedUnitCost"], 30.5)
                    self.assertEqual(len(first["confirmedLines"]), 2)
                    self.assertEqual(first["confirmedLines"][1]["lineID"], payload["lines"][1]["lineID"])
                    self.assertEqual(first["confirmedLines"][1]["confirmedUnitCost"], 44.5)

                    with urllib.request.urlopen(
                        self.request(
                            endpoint,
                            token=self.api_token,
                            payload=payload,
                            idempotency_key=key,
                        ),
                        timeout=5,
                    ) as response:
                        replay = json.loads(response.read().decode("utf-8"))["acceptance"]
                    self.assertEqual(response.status, 200)
                    self.assertTrue(replay["replayed"])
                    self.assertEqual(adapter.submit_calls, 1)

                    changed = dict(payload)
                    changed["lines"] = [dict(payload["lines"][0], quantity=4)]
                    with self.assertRaises(urllib.error.HTTPError) as mismatch:
                        urllib.request.urlopen(
                            self.request(
                                endpoint,
                                token=self.api_token,
                                payload=changed,
                                idempotency_key=key,
                            ),
                            timeout=5,
                        )
                    self.assertEqual(mismatch.exception.code, 409)

                    with self.assertRaises(urllib.error.HTTPError) as duplicate_order:
                        urllib.request.urlopen(
                            self.request(
                                endpoint,
                                token=self.api_token,
                                payload=payload,
                                idempotency_key="supplier-order-johnstone-0002",
                            ),
                            timeout=5,
                        )
                    self.assertEqual(duplicate_order.exception.code, 409)

                    with backend.db() as connection:
                        attempt = connection.execute(
                            "SELECT * FROM supplier_order_attempts WHERE idempotency_key = ?",
                            (key,),
                        ).fetchone()
                        audits = connection.execute(
                            "SELECT * FROM audit_events WHERE subject_type = 'supplier-order'"
                        ).fetchall()
                    self.assertEqual(attempt["status"], "accepted")
                    self.assertEqual(attempt["request_hash"], backend.hashlib.sha256(
                        attempt["request_json"].encode("utf-8")
                    ).hexdigest())
                    self.assertEqual(len(audits), 1)
                    retained = (attempt["request_json"] + attempt["acceptance_json"]).lower()
                    self.assertNotIn("secret", retained)
                    self.assertNotIn("password", retained)
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=5)

    def test_adapter_line_mismatch_is_unknown_and_never_persisted_as_accepted(self) -> None:
        adapter = MismatchedLineSupplierAdapter()
        payload = self.valid_payload()
        lines = payload["lines"]
        assert isinstance(lines, list)
        lines.append(
            {
                "lineID": str(uuid.uuid4()),
                "itemName": "60A Disconnect",
                "internalSKU": "DISC-60A",
                "supplierPartNumber": "JS-DISC-60A",
                "quantity": 1,
                "expectedUnitCost": 45.0,
            }
        )
        key = "supplier-order-line-mismatch-0001"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.configured_backend(root), mock.patch.dict(
                backend.SUPPLIER_CONNECTOR_ADAPTERS,
                {adapter.kind: adapter},
                clear=True,
            ):
                backend.initialize_database()
                server, thread, base_url = self.serve()
                try:
                    with self.assertRaises(urllib.error.HTTPError) as mismatch:
                        urllib.request.urlopen(
                            self.request(
                                f"{base_url}/api/supplier-connectors/orders",
                                token=self.api_token,
                                payload=payload,
                                idempotency_key=key,
                            ),
                            timeout=5,
                        )
                    self.assertEqual(mismatch.exception.code, 502)
                    error = self.error_payload(mismatch.exception)
                    self.assertEqual(error["errorCode"], "invalid-adapter-response")
                    self.assertTrue(error["outcomeUnknown"])
                    with backend.db() as connection:
                        attempt = connection.execute(
                            "SELECT status, acceptance_json FROM supplier_order_attempts WHERE idempotency_key = ?",
                            (key,),
                        ).fetchone()
                    self.assertEqual(attempt["status"], "unknown")
                    self.assertIsNone(attempt["acceptance_json"])
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=5)

    def test_unknown_outcome_requires_provider_recovery_and_never_resubmits(self) -> None:
        payload = self.valid_payload()
        key = "supplier-order-unknown-0001"
        adapter = UnknownOutcomeSupplierAdapter(recover_successfully=False)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.configured_backend(root), mock.patch.dict(
                backend.SUPPLIER_CONNECTOR_ADAPTERS,
                {adapter.kind: adapter},
                clear=True,
            ):
                backend.initialize_database()
                server, thread, base_url = self.serve()
                endpoint = f"{base_url}/api/supplier-connectors/orders"
                try:
                    with self.assertRaises(urllib.error.HTTPError) as uncertain:
                        urllib.request.urlopen(
                            self.request(
                                endpoint,
                                token=self.api_token,
                                payload=payload,
                                idempotency_key=key,
                            ),
                            timeout=5,
                        )
                    self.assertEqual(uncertain.exception.code, 502)
                    self.assertTrue(self.error_payload(uncertain.exception)["outcomeUnknown"])

                    with self.assertRaises(urllib.error.HTTPError) as pending:
                        urllib.request.urlopen(
                            self.request(
                                endpoint,
                                token=self.api_token,
                                payload=payload,
                                idempotency_key=key,
                            ),
                            timeout=5,
                        )
                    self.assertEqual(pending.exception.code, 409)
                    self.assertTrue(self.error_payload(pending.exception)["outcomeUnknown"])
                    self.assertEqual(adapter.submit_calls, 1)
                    self.assertEqual(adapter.recover_calls, 1)
                    with backend.db() as connection:
                        status = connection.execute(
                            "SELECT status FROM supplier_order_attempts WHERE idempotency_key = ?",
                            (key,),
                        ).fetchone()[0]
                    self.assertEqual(status, "unknown")
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=5)

    def test_provider_recovery_converts_unknown_attempt_without_second_submit(self) -> None:
        payload = self.valid_payload()
        key = "supplier-order-recovery-0001"
        adapter = UnknownOutcomeSupplierAdapter(recover_successfully=True)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.configured_backend(root), mock.patch.dict(
                backend.SUPPLIER_CONNECTOR_ADAPTERS,
                {adapter.kind: adapter},
                clear=True,
            ):
                backend.initialize_database()
                server, thread, base_url = self.serve()
                endpoint = f"{base_url}/api/supplier-connectors/orders"
                try:
                    with self.assertRaises(urllib.error.HTTPError) as uncertain:
                        urllib.request.urlopen(
                            self.request(
                                endpoint,
                                token=self.api_token,
                                payload=payload,
                                idempotency_key=key,
                            ),
                            timeout=5,
                        )
                    self.assertEqual(uncertain.exception.code, 502)

                    with urllib.request.urlopen(
                        self.request(
                            endpoint,
                            token=self.api_token,
                            payload=payload,
                            idempotency_key=key,
                        ),
                        timeout=5,
                    ) as response:
                        recovered = json.loads(response.read().decode("utf-8"))["acceptance"]
                    self.assertEqual(response.status, 200)
                    self.assertTrue(recovered["replayed"])
                    self.assertEqual(adapter.submit_calls, 1)
                    self.assertEqual(adapter.recover_calls, 1)
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=5)

    def test_invalid_or_secret_shaped_payload_is_rejected_without_persistence(self) -> None:
        adapter = SuccessfulSupplierAdapter()
        invalid = self.valid_payload()
        invalid["supplierPassword"] = "must-never-enter-the-app"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.configured_backend(root), mock.patch.dict(
                backend.SUPPLIER_CONNECTOR_ADAPTERS,
                {adapter.kind: adapter},
                clear=True,
            ):
                backend.initialize_database()
                server, thread, base_url = self.serve()
                try:
                    with self.assertRaises(urllib.error.HTTPError) as rejected:
                        urllib.request.urlopen(
                            self.request(
                                f"{base_url}/api/supplier-connectors/orders",
                                token=self.api_token,
                                payload=invalid,
                                idempotency_key="supplier-order-invalid-0001",
                            ),
                            timeout=5,
                        )
                    self.assertEqual(rejected.exception.code, 400)
                    self.assertEqual(adapter.submit_calls, 0)

                    outdated = self.valid_payload()
                    outdated["contractVersion"] = 1
                    with self.assertRaises(urllib.error.HTTPError) as unsupported_version:
                        urllib.request.urlopen(
                            self.request(
                                f"{base_url}/api/supplier-connectors/orders",
                                token=self.api_token,
                                payload=outdated,
                                idempotency_key="supplier-order-invalid-version-0001",
                            ),
                            timeout=5,
                        )
                    self.assertEqual(unsupported_version.exception.code, 400)
                    self.assertEqual(adapter.submit_calls, 0)
                    with backend.db() as connection:
                        count = connection.execute(
                            "SELECT COUNT(*) FROM supplier_order_attempts"
                        ).fetchone()[0]
                    self.assertEqual(count, 0)
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=5)

    def test_active_non_admin_cannot_discover_or_submit_connectors(self) -> None:
        adapter = SuccessfulSupplierAdapter()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with mock.patch.multiple(
                backend,
                DB_PATH=root / "backend.sqlite3",
                STORAGE_ROOT=root / "storage",
                AUTH_MODE="google-id-token",
            ), mock.patch.dict(
                backend.SUPPLIER_CONNECTOR_ADAPTERS,
                {adapter.kind: adapter},
                clear=True,
            ):
                backend.initialize_database()
                email = "tech@gunnaire.com"
                with backend.db() as connection:
                    connection.execute(
                        "INSERT INTO users(email, role, is_active, created_at, updated_at) VALUES (?, 'Field Technician', 1, 'now', 'now')",
                        (email,),
                    )
                session_token, _ = backend.create_app_session(email, "google", "tech-subject")
                server, thread, base_url = self.serve()
                try:
                    with self.assertRaises(urllib.error.HTTPError) as forbidden_get:
                        urllib.request.urlopen(
                            self.request(
                                f"{base_url}/api/supplier-connectors",
                                token=session_token,
                            ),
                            timeout=5,
                        )
                    self.assertEqual(forbidden_get.exception.code, 403)

                    with self.assertRaises(urllib.error.HTTPError) as forbidden_post:
                        urllib.request.urlopen(
                            self.request(
                                f"{base_url}/api/supplier-connectors/orders",
                                token=session_token,
                                payload=self.valid_payload(),
                                idempotency_key="supplier-order-forbidden-0001",
                            ),
                            timeout=5,
                        )
                    self.assertEqual(forbidden_post.exception.code, 403)
                    self.assertEqual(adapter.submit_calls, 0)
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
