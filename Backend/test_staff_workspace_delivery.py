from __future__ import annotations

import base64
import copy
import json
import unittest
import urllib.parse
import uuid
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
from unittest import mock

from Backend import gunnaire_backend as backend
from Backend import staff_workspace_delivery as delivery, staff_workspace_projection as projection
from Backend import staff_workspace_contract as contract
from Backend import test_staff_billing_delivery as billing_fixtures
from Backend import test_staff_workspace_projection as content_fixtures
from Backend import test_staff_workspace_selections as fixtures


def interop():
    records = content_fixtures.rich_records()
    graph = delivery.selection.Graph(records)
    meta = billing_fixtures.metadata()
    index = graph.index(meta["memberRole"], fixtures.EMAIL)
    snapshot = dict(meta, operationID="a1000000-0000-4000-8000-000000000077", records=index)
    raw = contract.wire(projection.prepare(graph, index, meta, fixtures.EMAIL)).encode("utf-8")
    service = delivery.StaffWorkspaceDelivery.__new__(delivery.StaffWorkspaceDelivery)
    service.selection = delivery.billing_delivery.selections.StaffWorkspaceSelections
    return dict(receipt=service.receipt(raw, snapshot, 1), payloadUtf8=raw.decode("utf-8"))


class StaffWorkspaceDeliveryHTTPTests(unittest.TestCase):
    Fixture = fixtures.FullStaffSelectionHTTPTests
    setUp, tearDown, request = Fixture.setUp, Fixture.tearDown, Fixture.request
    workspace, binding_payload, bind = Fixture.workspace, Fixture.binding_payload, Fixture.bind
    prepare, enroll, change = Fixture.prepare, Fixture.enroll, Fixture.change
    requested, advance, accepted = Fixture.requested, Fixture.advance, Fixture.accepted
    root, participant_name, participant_hash = Fixture.root, Fixture.participant_name, Fixture.participant_hash
    write_source, post = Fixture.write_source, Fixture.post

    def seed(self, role="Field Technician", prepare=True):
        self.prepare()
        self.scope = dict(companyID=self.company, environment="development", replicaID=self.workspace()["bindings"][0]["replicaID"])
        self.records = content_fixtures.rich_records(self.company, self.scope["replicaID"])
        self.write_source(self.records, 0); self.sequence = 1
        self.share = self.accepted(role)
        self.endpoint = self.root + "/" + self.share["id"] + "/full-selections"
        self.payload = dict(**self.scope, operationID=str(uuid.uuid4()), expectedSourceSequence=1,
                            expectedShareRevision=self.share["revision"], sourceSchemaDigest=contract.SCHEMA_DIGEST)
        status, result = self.post(); self.assertEqual(status, 200, result)
        self.content_path = self.endpoint + "/" + self.payload["operationID"] + "/content"
        return self.deliver() if prepare else (status, result)

    def deliver(self, role="Admin", payload=None):
        return self.request(token=self.tokens[role], path=self.content_path, method="POST",
                            payload=payload if payload is not None else dict(**self.scope, contentSchema=projection.SCHEMA))

    def get(self, chunks=False, role="Admin", query=None):
        values = dict(self.scope, **({"offset": "0"} if chunks else {})) if query is None else query
        path = self.content_path + ("/chunks" if chunks else "") + "?" + urllib.parse.urlencode(values)
        return self.request(token=self.tokens[role], path=path)

    def count(self):
        with backend.db() as connection:
            return connection.execute("SELECT COUNT(*) FROM staff_workspace_projections").fetchone()[0]

    def test_actual_http_full_content_exact_bytes_and_role_disclosures(self):
        status, receipt = self.seed(); self.assertEqual(status, 200, receipt)
        status, chunk = self.get(True); self.assertEqual(status, 200, chunk)
        raw = base64.b64decode(chunk["payloadBase64"], validate=True)
        view = json.loads(raw)
        self.assertEqual(receipt["contentSHA256"], delivery.digest(raw))
        self.assertEqual(receipt["payloadBytes"], len(raw))
        self.assertEqual(chunk["chunkSHA256"], delivery.digest(raw))
        self.assertIsNone(chunk["nextOffset"])
        self.assertEqual(view["coverage"], sorted(contract.SPECS))
        self.assertEqual(receipt["recordCount"], len(view["records"]))
        self.assertFalse(receipt["operationalWorkspaceReady"] or receipt["fieldProjectionRequired"])
        self.assertTrue(receipt["localCloudKitProofRequired"])
        self.assertIn(b"R-410A", raw)
        self.assertNotIn(b"PRIVATE-CREDIT-AMOUNT", raw)
        self.assertNotIn(b"PRIVATE-VENDOR-REF", raw)
        self.assertNotIn(b"ORIGINAL-REALM", raw)
        self.assertNotIn(b"providerResponseJSON", raw)  # Not present in this schema.
        with backend.db() as connection:
            encrypted = connection.execute("SELECT ciphertext FROM staff_workspace_projections").fetchone()[0]
            self.assertNotIn("R-410A", encrypted)
            self.assertNotIn(chunk["payloadBase64"], encrypted)

    def test_committed_native_transport_vector_matches_exact_server_bytes(self):
        path = Path(__file__).resolve().parents[1] / "GunnAire OpsTests" / "StaffWorkspaceContentTransportInterop.json"
        self.assertEqual(json.loads(path.read_text()), interop())

    def test_all_five_roles_match_their_exact_pure_preparation(self):
        for role in delivery.sharing.POLICIES:
            # Isolate each membership's source/authority fixture.
            with self.subTest(role=role):
                if hasattr(self, "scope"):
                    self.tearDown(); self.setUp()
                status, receipt = self.seed(role); self.assertEqual(status, 200, receipt)
                _, page = self.get(True)
                view = json.loads(base64.b64decode(page["payloadBase64"]))
                graph = delivery.selection.Graph(self.records)
                email = self.share["memberEmail"]
                expected = projection.prepare(graph, graph.index(role, email), receipt, email)
                self.assertEqual(view, expected)

    def test_staff_and_other_administrators_cannot_adopt_original_preparation(self):
        self.assertEqual(self.seed()[0], 200)
        for role in self.tokens:
            if role != "Admin":
                self.assertEqual(self.deliver(role)[0], 403)
                self.assertEqual(self.get(True, role)[0], 403)
        with backend.db() as connection:
            connection.execute("UPDATE users SET role='Admin' WHERE email='dispatcher@gunnaire.com'")
        self.assertEqual(self.get(True, "Dispatcher")[0], 404)
        self.assertEqual(self.deliver("Dispatcher")[0], 404)

    def test_concurrent_lost_reply_restart_replays_one_immutable_payload(self):
        original = self.seed(); self.assertEqual(original[0], 200, original)
        page = self.get(True)
        backend.initialize_database()
        self.assertEqual(self.get(), original)
        with ThreadPoolExecutor(max_workers=3) as pool:
            self.assertTrue(all(result == original for result in pool.map(lambda _: self.deliver(), range(3))))
        self.assertEqual(self.get(True), page)
        self.assertEqual(self.count(), 1)

    def test_exact_chunk_boundaries_and_hashes_reassemble_without_json_reencoding(self):
        self.assertEqual(self.seed()[0], 200)
        _, original = self.get()
        parts, offset = [], 0
        with mock.patch.object(delivery, "CHUNK_BYTES", 701):
            while offset is not None:
                status, page = self.get(True, query=dict(self.scope, offset=str(offset)))
                self.assertEqual(status, 200, page)
                part = base64.b64decode(page["payloadBase64"], validate=True)
                self.assertTrue(0 < len(part) <= 701)
                self.assertEqual(page["offset"], sum(map(len, parts)))
                self.assertEqual(page["chunkSHA256"], delivery.digest(part))
                self.assertEqual(page["contentSHA256"], original["contentSHA256"])
                parts.append(part); offset = page["nextOffset"]
            self.assertGreater(len(parts), 1)
            self.assertEqual(self.get(True, query=dict(self.scope, offset="1"))[0], 400)
        raw = b"".join(parts)
        self.assertEqual(len(raw), original["payloadBytes"])
        self.assertEqual(delivery.digest(raw), original["contentSHA256"])

    def test_source_advance_retains_receipt_but_refuses_old_chunks(self):
        _, original = self.seed()
        job = copy.deepcopy(fixtures.row(self.records, "job")); fixtures.set_value(job, "assignedTechnician", None)
        self.write_source([job], 1, 1)
        status, recovered = self.deliver(); self.assertEqual(status, 200, recovered)
        self.assertEqual(recovered["contentSHA256"], original["contentSHA256"])
        self.assertFalse(recovered["sourceCurrent"])
        self.assertEqual(self.get(True)[1]["code"], "source_changed")

    def test_stale_unprepared_selection_does_not_create_any_content(self):
        self.seed(prepare=False)
        job = copy.deepcopy(fixtures.row(self.records, "job")); fixtures.set_value(job, "assignedTechnician", None)
        self.write_source([job], 1, 1)
        self.assertEqual(self.deliver()[1]["code"], "source_changed")
        self.assertEqual(self.count(), 0)

    def test_revoked_membership_role_or_share_denies_recovery_and_chunks(self):
        self.assertEqual(self.seed()[0], 200)
        with backend.db() as connection:
            connection.execute("UPDATE users SET is_active=0 WHERE email=?", (fixtures.EMAIL,))
        self.assertEqual(self.deliver()[0], 403)
        self.assertEqual(self.get(True)[0], 403)
        with backend.db() as connection:
            connection.execute("UPDATE users SET is_active=1,role='Dispatcher' WHERE email=?", (fixtures.EMAIL,))
        self.assertEqual(self.get(True)[0], 403)
        with backend.db() as connection:
            connection.execute("UPDATE users SET role='Field Technician' WHERE email=?", (fixtures.EMAIL,))
        self.advance(self.share, "revoke")
        self.assertEqual(self.get()[0], 403)
        self.assertEqual(self.count(), 1)

    def test_revoked_session_between_http_gate_and_transaction_is_denied(self):
        self.assertEqual(self.seed()[0], 200)
        original = backend.GunnAireBackendHandler.require_application_session
        def revoke(handler):
            result = original(handler)
            with backend.db() as connection:
                connection.execute("UPDATE auth_sessions SET revoked_at=? WHERE email='admin@gunnaire.com'", (backend.utc_now(),))
            return result
        with mock.patch.object(backend.GunnAireBackendHandler, "require_application_session", revoke):
            self.assertEqual(self.get(True)[0], 403)

    def test_corrupted_ciphertext_and_hash_require_recovery_not_regeneration(self):
        self.assertEqual(self.seed()[0], 200)
        with backend.db() as connection:
            saved = connection.execute("SELECT * FROM staff_workspace_projections").fetchone()
            connection.execute("UPDATE staff_workspace_projections SET ciphertext='damaged'")
        self.assertEqual(self.deliver()[1]["code"], "storage_unavailable")
        self.assertEqual(self.get(True)[0], 503)
        with backend.db() as connection:
            connection.execute("UPDATE staff_workspace_projections SET ciphertext=?,content_sha256=?", (saved["ciphertext"], "f" * 64))
        self.assertEqual(self.get()[0], 503)
        self.assertEqual(self.count(), 1)

    def test_rollback_source_head_requires_recovery(self):
        self.assertEqual(self.seed()[0], 200)
        with backend.db() as connection:
            connection.execute("UPDATE staff_workspace_source_heads SET sequence=0")
        self.assertEqual(self.get(True)[0], 503)
        self.assertEqual(self.deliver()[0], 503)

    def test_failed_encryption_is_atomic_and_retry_recovers(self):
        self.seed(prepare=False)
        with mock.patch.object(backend, "encrypt_catalog_payload", side_effect=RuntimeError("test failure")):
            self.assertEqual(self.deliver()[0], 503)
        self.assertEqual(self.count(), 0)
        self.assertEqual(self.deliver()[0], 200)
        self.assertEqual(self.count(), 1)

    def test_invalid_scope_schema_cursors_duplicate_and_extra_fields_are_rejected(self):
        self.seed(prepare=False)
        self.assertEqual(self.get()[1]["code"], "content_not_prepared")
        for update in (dict(contentSchema="core-field-v1"), dict(memberRole="Admin"), dict(companyID=str(uuid.uuid4()))):
            self.assertNotEqual(self.deliver(payload=dict(self.scope, contentSchema=projection.SCHEMA) | update)[0], 200)
        self.assertEqual(self.deliver()[0], 200)
        for offset in ("-1", "01", "+0", "1", "0.0", "١", "999999999", str(projection.MAX_BYTES)):
            self.assertEqual(self.get(True, query=dict(self.scope, offset=offset))[0], 400)
        self.assertEqual(self.get(True, query=self.scope)[0], 400)
        self.assertEqual(self.get(query=dict(self.scope, offset="0"))[0], 400)
        path = self.content_path + "/chunks?" + urllib.parse.urlencode(dict(self.scope, offset="0")) + "&offset=0"
        self.assertEqual(self.request(token=self.tokens["Admin"], path=path)[0], 400)

    def test_invalid_hidden_operational_evidence_never_creates_partial_payload(self):
        self.seed("Standard", prepare=False)
        equipment = fixtures.row(self.records, "equipment")
        fixtures.set_value(equipment, "technicalBaselineReadingsJSON", '{"version":1,"warrantyClaims":"private invalid"}')
        self.write_source([equipment], 1, 1)
        self.payload.update(operationID=str(uuid.uuid4()), expectedSourceSequence=2)
        status, result = self.post(); self.assertEqual(status, 200, result)
        self.content_path = self.endpoint + "/" + self.payload["operationID"] + "/content"
        self.assertEqual(self.deliver()[1]["code"], "operational_evidence_pending")
        self.assertEqual(self.count(), 0)


if __name__ == "__main__":
    unittest.main()
