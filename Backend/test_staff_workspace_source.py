from __future__ import annotations

import copy
import http.client
import json
import unittest
import urllib.parse
import urllib.request
import urllib.error
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest import mock
from Backend import test_cloudkit_staff_shares as fixtures
from Backend import gunnaire_backend as backend, staff_workspace_contract as contract


class StaffWorkspaceSourceTests(unittest.TestCase):
    setUp = fixtures.CloudKitStaffSharingTests.setUp
    tearDown = fixtures.CloudKitStaffSharingTests.tearDown
    request = fixtures.CloudKitStaffSharingTests.request
    workspace = fixtures.CloudKitStaffSharingTests.workspace
    binding_payload = fixtures.CloudKitStaffSharingTests.binding_payload
    bind = fixtures.CloudKitStaffSharingTests.bind
    prepare = fixtures.CloudKitStaffSharingTests.prepare
    source = "/api/workspace/full-records"

    def full_scope(self):
        value = self.prepare()
        value["replicaID"] = self.workspace()["bindings"][0]["replicaID"]
        self.scope = value
        return value

    @staticmethod
    def native_records():
        return json.loads(Path(__file__).with_name("fixtures").joinpath("full_owner_native_v1.json").read_text())

    @staticmethod
    def change(record, revision=0, action="upsert"):
        return dict(kind=record["kind"], id=record["id"].lower(), expectedRevision=revision, action=action,
                    fields=copy.deepcopy(record["fields"]) if action != "delete" else {})

    def batch(self, changes=None, sequence=0):
        return dict(**self.scope, schema=contract.SCHEMA_VERSION, schemaDigest=contract.SCHEMA_DIGEST,
                    operationID=str(uuid.uuid4()), expectedSequence=sequence,
                    changes=changes if changes is not None else [self.change(r) for r in self.native_records()])

    def apply(self, payload, role="Admin"):
        return self.request(token=self.tokens[role], path=self.source, method="POST", payload=payload)

    def page(self, role="Admin", **query):
        return self.request(token=self.tokens[role], path=self.source + "?" + urllib.parse.urlencode({**self.scope, **query}))

    def raw_post(self, raw):
        request = urllib.request.Request(self.base_url + self.source, data=raw, method="POST",
            headers={"Authorization": "Bearer " + self.tokens["Admin"], "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read())

    def source_count(self):
        with backend.db() as connection:
            return connection.execute("SELECT COUNT(*) FROM staff_workspace_source_records").fetchone()[0]

    def test_full_owner_source_has_its_own_versioned_authenticated_endpoint(self):
        scope = self.prepare()
        scope["replicaID"] = self.workspace()["bindings"][0]["replicaID"]
        status, result = self.request(token=self.tokens["Admin"], path=self.source + "?" + urllib.parse.urlencode(scope))
        self.assertEqual(status, 200, result)
        self.assertEqual(result["schema"], "owner-workspace-v1")
        self.assertEqual(result["sequence"], 0)
        self.assertEqual(result["records"], [])

    def test_all_32_native_records_and_561_fields_round_trip_without_core_relabeling(self):
        self.full_scope()
        records = self.native_records()
        self.assertEqual(len(records), 32)
        self.assertEqual(sum(len(record["fields"]) for record in records), 561)
        batch = self.batch()
        status, receipt = self.apply(batch)
        self.assertEqual(status, 200, receipt)
        self.assertEqual(receipt["sequence"], 1)
        backend.initialize_database()  # Additive restart preserves all originals.
        status, page = self.page()
        self.assertEqual(status, 200, page)
        self.assertEqual(page["schemaDigest"], contract.SCHEMA_DIGEST)
        original = {r["kind"]: r for r in records}
        for record in page["records"]:
            self.assertEqual(record["fields"], original[record["kind"]]["fields"])
            self.assertEqual(record["id"], original[record["kind"]]["id"].lower())
        self.assertEqual(len(page["records"]), 32)
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM staff_replica_records").fetchone()[0], 0)
            for row in connection.execute("SELECT ciphertext FROM staff_workspace_source_records"):
                self.assertNotIn("Original", row[0])
                self.assertNotIn("fields", row[0])
            receipt_row = connection.execute("SELECT ciphertext FROM staff_workspace_source_operations").fetchone()[0]
            self.assertNotIn("admin@", receipt_row)
            self.assertNotIn("changes", receipt_row)
        legacy_scope = {k: v for k, v in self.scope.items() if k != "replicaID"}
        status, legacy = self.request(token=self.tokens["Admin"], path="/api/workspace/replica-records?" + urllib.parse.urlencode(legacy_scope))
        self.assertEqual(status, 200)
        self.assertEqual((legacy["schema"], legacy["sequence"], legacy["records"]), ("core-field-v1", 0, []))

    def test_lost_response_replay_recovers_exact_original_even_after_later_sequence(self):
        self.full_scope()
        original = self.batch()
        status, receipt = self.apply(original)
        self.assertEqual(status, 200)
        later = self.batch([self.change(self.native_records()[0], 1)], 1)
        self.assertEqual(self.apply(later)[0], 200)
        self.assertEqual(self.apply(original), (200, {**receipt, "currentSequence": 2}))
        changed = copy.deepcopy(original)
        changed["changes"][0]["fields"]["name"] = {"text": {"_0": "Do not replace original"}}
        self.assertEqual(self.apply(changed)[1]["code"], "operation_changed")
        self.assertEqual(self.source_count(), 32)

    def test_operation_identity_cannot_be_adopted_by_a_second_administrator(self):
        self.full_scope()
        original = self.batch()
        self.assertEqual(self.apply(original)[0], 200)
        with backend.db() as connection:
            connection.execute("UPDATE users SET role='Admin' WHERE email='dispatcher@gunnaire.com'")
        self.assertEqual(self.apply(original, "Dispatcher")[1]["code"], "operation_changed")

    def test_every_nonowner_role_is_denied_reads_and_writes(self):
        self.full_scope()
        batch = self.batch()
        self.assertEqual(self.apply(batch)[0], 200)
        for role in self.tokens:
            if role != "Admin":
                with self.subTest(role=role):
                    self.assertEqual(self.page(role)[0], 403)
                    self.assertEqual(self.apply(batch, role)[0], 403)
        self.assertEqual(self.request(path=self.source)[0], 401)

    def test_revocation_between_http_check_and_transaction_blocks_writes(self):
        self.full_scope()
        original_check = backend.GunnAireBackendHandler.require_application_session
        def revoke(handler):
            result = original_check(handler)
            with backend.db() as connection:
                connection.execute("UPDATE auth_sessions SET revoked_at=? WHERE email='admin@gunnaire.com'", (backend.utc_now(),))
            return result
        with mock.patch.object(backend.GunnAireBackendHandler, "require_application_session", revoke):
            self.assertEqual(self.apply(self.batch())[0], 403)
        self.assertEqual(self.source_count(), 0)

    def test_disabled_or_demoted_owner_cannot_read_retained_private_records(self):
        self.full_scope()
        self.assertEqual(self.apply(self.batch())[0], 200)
        with backend.db() as connection:
            connection.execute("UPDATE users SET is_active=0 WHERE email='admin@gunnaire.com'")
        self.assertIn(self.page()[0], (401, 403))
        with backend.db() as connection:
            connection.execute("UPDATE users SET is_active=1,role='Field Technician' WHERE email='admin@gunnaire.com'")
        self.assertEqual(self.page()[0], 403)
        self.assertEqual(self.source_count(), 32)

    def test_original_company_environment_and_replica_are_fenced(self):
        self.full_scope()
        original = self.batch()
        for name, value in (("companyID", str(uuid.uuid4())), ("environment", "production"), ("replicaID", str(uuid.uuid4()))):
            with self.subTest(name=name):
                self.assertNotEqual(self.apply({**original, name: value})[0], 200)
                self.assertNotEqual(self.page(**{name: value})[0], 200)
        self.assertEqual(self.source_count(), 0)

    def test_schema_or_digest_mismatch_retains_original_without_relabeling(self):
        self.full_scope()
        original = self.batch()
        for name, value in (("schema", "core-field-v1"), ("schema", "owner-workspace-v2"), ("schemaDigest", "0" * 64)):
            with self.subTest(name=name, value=value):
                self.assertEqual(self.apply({**original, name: value})[1]["code"], "schema_changed")
        self.assertEqual(self.source_count(), 0)

    def test_exact_field_names_and_tag_members_are_required(self):
        self.full_scope()
        original = self.batch([self.change(self.native_records()[0])])
        fields = original["changes"][0]["fields"]
        cases = [dict(fields, unknown={"text": {"_0": "Hidden"}}), {k: v for k, v in fields.items() if k != "name"}]
        for value in ("untyped", {"text": {}}, {"text": {"_0": "x", "extra": 1}}, {"text": {"_0": "x"}, "null": {}}, {"null": {}}, {"number": {"_0": 1}}):
            cases.append({**fields, "name": value})
        for value in cases:
            with self.subTest(value=str(value)[:80]):
                changed = copy.deepcopy(original)
                changed["changes"][0]["fields"] = value
                self.assertEqual(self.apply(changed)[0], 400)
        self.assertEqual(self.source_count(), 0)

    def test_all_native_field_types_reject_wrong_nulls_and_primitive_types(self):
        records = self.native_records()
        for record in records:
            for name, spec in contract.SPECS[record["kind"]].items():
                with self.subTest(kind=record["kind"], field=name):
                    fields = copy.deepcopy(record["fields"])
                    fields[name] = {spec["type"]: {"_0": []}}
                    with self.assertRaises(fixtures.sharing.AttemptError):
                        contract.validate(record["kind"], fields)
                    fields[name] = {"null": {}}
                    if not spec["nullable"]:
                        with self.assertRaises(fixtures.sharing.AttemptError):
                            contract.validate(record["kind"], fields)
                    else:
                        contract.validate(record["kind"], fields)

    def test_unsafe_numbers_unicode_identifiers_enums_and_oversized_text_are_rejected(self):
        self.full_scope()
        records = {r["kind"]: r for r in self.native_records()}
        cases = [("customer", "name", "text", "\0private"), ("customer", "name", "text", "x" * 1_048_577),
                 ("invoice", "amount", "number", True), ("invoice", "amount", "number", 10 ** 400),
                 ("invoice", "createdAt", "date", 100_000_000_001),
                 ("invoice", "projectMilestoneSequence", "integer", 1.5),
                 ("invoice", "projectMilestoneSequence", "integer", 2_147_483_648),
                 ("invoice", "customer", "identifier", records["customer"]["id"].lower()),
                 ("job", "status", "text", "Unknown future status")]
        for kind, name, tag, value in cases:
            with self.subTest(kind=kind, name=name):
                change = self.change(records[kind])
                change["fields"][name] = {tag: {"_0": value}}
                self.assertEqual(self.apply(self.batch([change]))[0], 400)
        self.assertEqual(self.source_count(), 0)

    def test_duplicate_json_keys_nonfinite_values_and_unbounded_nesting_are_rejected(self):
        self.full_scope()
        raw = json.dumps(self.batch()).encode()
        for malformed in (b'{"companyID":"x",' + raw[1:], raw.replace(b'"expectedSequence": 0', b'"expectedSequence": NaN'), b'[' * 1100 + b']' * 1100):
            self.assertEqual(self.raw_post(malformed)[0], 400)
        self.assertEqual(self.source_count(), 0)

    def test_unknown_envelope_fields_duplicate_records_and_unbounded_batches_are_rejected(self):
        self.full_scope()
        record = self.change(self.native_records()[0])
        original = self.batch([record])
        for changed in ({**original, "admin": True}, {**original, "changes": [record, record]},
                        {**original, "changes": []}, {**original, "changes": [record] * 101},
                        {k: v for k, v in original.items() if k != "replicaID"},
                        {**original, "expectedSequence": True}):
            self.assertEqual(self.apply(changed)[0], 400)
        self.assertEqual(self.source_count(), 0)

    def test_one_revision_conflict_rolls_back_every_record_in_the_batch(self):
        self.full_scope()
        self.assertEqual(self.apply(self.batch())[0], 200)
        records = self.native_records()
        good = self.change(records[0], 1)
        good["fields"]["name"] = {"text": {"_0": "Should not persist"}}
        bad = self.change(records[1], 4)
        self.assertEqual(self.apply(self.batch([good, bad], 1))[1]["code"], "record_changed")
        page = self.page()[1]
        self.assertEqual(page["sequence"], 1)
        self.assertEqual(next(r for r in page["records"] if r["kind"] == "customer")["fields"], records[0]["fields"])

    def test_encryption_and_audit_failure_roll_back_original_batch_and_receipt(self):
        self.full_scope()
        original = self.batch()
        for name in ("encrypt_catalog_payload", "record_audit_event"):
            with mock.patch.object(backend, name, side_effect=RuntimeError("private error must not leak")):
                status, result = self.apply(original)
                self.assertEqual(status, 503)
                self.assertNotIn("private error", json.dumps(result))
            self.assertEqual(self.source_count(), 0)
            with backend.db() as connection:
                self.assertEqual(connection.execute("SELECT COUNT(*) FROM staff_workspace_source_operations").fetchone()[0], 0)
        with mock.patch.object(backend, "encrypt_catalog_payload", side_effect=lambda raw: raw):
            self.assertEqual(self.apply(original)[0], 503)
        self.assertEqual(self.apply(original)[0], 200)

    def test_concurrent_exact_replay_is_one_durable_operation(self):
        self.full_scope()
        original = self.batch()
        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda _: self.apply(original), range(4)))
        self.assertEqual(results, [results[0]] * 4)
        self.assertEqual(results[0][0], 200)
        self.assertEqual(self.page()[1]["sequence"], 1)
        self.assertEqual(self.source_count(), 32)

    def test_all_32_tombstones_retain_original_fields_and_require_explicit_restore(self):
        self.full_scope()
        records = self.native_records()
        self.assertEqual(self.apply(self.batch())[0], 200)
        deletion = self.batch([self.change(r, 1, "delete") for r in records], 1)
        self.assertEqual(self.apply(deletion)[0], 200)
        page = self.page()[1]
        self.assertTrue(all(r["deleted"] and r["revision"] == 2 for r in page["records"]))
        self.assertEqual({r["kind"]: r["fields"] for r in page["records"]}, {r["kind"]: r["fields"] for r in records})
        self.assertEqual(self.apply(self.batch([self.change(records[0], 2)], 2))[1]["code"], "deletion_changed")
        self.assertEqual(self.apply(self.batch([self.change(records[0], 2, "delete")], 2))[1]["code"], "deletion_changed")
        self.assertEqual(self.apply(self.batch([self.change(records[0], 2, "restore")], 2))[0], 200)
        self.assertEqual(sum(r["deleted"] for r in self.page()[1]["records"]), 31)

    def test_unfounded_delete_or_restore_cannot_create_an_original(self):
        self.full_scope()
        for action in ("delete", "restore"):
            self.assertEqual(self.apply(self.batch([self.change(self.native_records()[0], 0, action)]))[0], 400)
            self.assertEqual(self.apply(self.batch([self.change(self.native_records()[0], 1, action)]))[1]["code"], "record_changed")

    def test_corrupt_or_swapped_ciphertext_is_retained_and_not_exported_or_overwritten(self):
        self.full_scope()
        self.assertEqual(self.apply(self.batch())[0], 200)
        with backend.db() as connection:
            original = connection.execute("SELECT ciphertext FROM staff_workspace_source_records WHERE kind='customer'").fetchone()[0]
            connection.execute("UPDATE staff_workspace_source_records SET ciphertext=? WHERE kind='invoice'", (original,))
        self.assertEqual(self.page()[0], 503)
        invoice = next(r for r in self.native_records() if r["kind"] == "invoice")
        self.assertEqual(self.apply(self.batch([self.change(invoice, 1)], 1))[0], 503)
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT ciphertext FROM staff_workspace_source_records WHERE kind='invoice'").fetchone()[0], original)

    def test_original_receipt_tampering_cannot_reapply_acknowledged_records(self):
        self.full_scope()
        batch = self.batch()
        self.assertEqual(self.apply(batch)[0], 200)
        with backend.db() as connection:
            connection.execute("UPDATE staff_workspace_source_operations SET ciphertext='corrupt'")
        self.assertEqual(self.apply(batch)[0], 503)
        self.assertEqual(self.page()[1]["sequence"], 1)

    def test_receipt_ciphertext_is_bound_to_original_actor_and_request(self):
        self.full_scope()
        batch = self.batch()
        self.assertEqual(self.apply(batch)[0], 200)
        with backend.db() as connection:
            raw = self.cipher.decrypt(connection.execute("SELECT ciphertext FROM staff_workspace_source_operations").fetchone()[0].encode())
            value = json.loads(raw)
            value["actorEmail"] = "changed@gunnaire.com"
            connection.execute("UPDATE staff_workspace_source_operations SET ciphertext=?", (self.cipher.encrypt(json.dumps(value).encode()).decode(),))
        self.assertEqual(self.apply(batch)[0], 503)

    def test_bounded_pages_use_exact_revision_fence_and_preserve_every_record(self):
        self.full_scope()
        source = self.native_records()[0]
        changes = [self.change({**source, "id": str(uuid.UUID(int=i + 1)).upper()}) for i in range(103)]
        self.assertEqual(self.apply(self.batch(changes[:100]))[0], 200)
        self.assertEqual(self.apply(self.batch(changes[100:], 1))[0], 200)
        first = self.page()[1]
        self.assertEqual(len(first["records"]), 100)
        second = self.page(sequence=2, after=first["nextCursor"])[1]
        self.assertEqual(len(second["records"]), 3)
        self.assertIsNone(second["nextCursor"])
        self.assertEqual(len({r["id"] for r in first["records"] + second["records"]}), 103)
        self.assertEqual(self.apply(self.batch([{**changes[0], "expectedRevision": 1}], 2))[0], 200)
        self.assertEqual(self.page(sequence=2, after=first["nextCursor"])[1]["code"], "source_changed")

    def test_unicode_page_limit_counts_actual_http_bytes_and_allows_short_pages(self):
        self.full_scope()
        source = self.native_records()[0]
        source["fields"]["name"] = {"text": {"_0": "é" * 500}}
        changes = [self.change({**source, "id": str(uuid.UUID(int=i + 1)).upper()}) for i in range(5)]
        self.assertEqual(self.apply(self.batch(changes))[0], 200)
        records, query = [], {}
        with mock.patch.object(contract, "MAX_PAGE_BYTES", 8192):
            for _ in range(5):
                status, page = self.page(**query)
                self.assertEqual(status, 200, page)
                self.assertLessEqual(len(json.dumps(page, separators=(",", ":")).encode()), 8192)
                records.extend(page["records"])
                if page["nextCursor"] is None:
                    break
                self.assertLess(len(page["records"]), 100)
                query = dict(sequence=page["sequence"], after=page["nextCursor"])
        self.assertEqual(len(records), 5)
        self.assertEqual(len({r["id"] for r in records}), 5)

    def test_capacity_rejection_is_atomic_and_never_prunes_retained_history(self):
        self.full_scope()
        original = self.batch()
        for name, maximum in (("MAX_RECORDS", 31), ("MAX_SCAN_BYTES", 100)):
            with mock.patch.object(contract, name, maximum):
                self.assertEqual(self.apply(original)[1]["code"], "source_capacity")
            self.assertEqual(self.source_count(), 0)
        self.assertEqual(self.apply(original)[0], 200)

    def test_malformed_or_duplicate_page_parameters_are_not_accepted(self):
        self.full_scope()
        for query in ({"after": "customer:" + str(uuid.uuid4())}, {"sequence": 0, "after": ""},
                      {"sequence": 0, "after": "unknown:" + str(uuid.uuid4())}, {"extra": "private"}):
            self.assertEqual(self.page(**query)[0], 400)
        path = self.source + "?" + urllib.parse.urlencode(self.scope) + "&replicaID=" + self.scope["replicaID"]
        self.assertEqual(self.request(token=self.tokens["Admin"], path=path)[0], 400)
        self.assertEqual(self.request(token=self.tokens["Admin"], path=self.source + "?extra=true", method="POST", payload=self.batch())[0], 400)

    def test_legacy_source_rejects_full_tagged_record_without_losing_its_namespace(self):
        self.full_scope()
        batch = self.batch([self.change(self.native_records()[0])])
        batch.pop("replicaID")
        batch.pop("schemaDigest")
        batch["schema"] = "core-field-v1"
        self.assertEqual(self.request(token=self.tokens["Admin"], path="/api/workspace/replica-records", method="POST", payload=batch)[0], 400)
        self.assertEqual(self.source_count(), 0)

    def test_bundled_native_http_vector_cannot_drift_from_current_backend_contract(self):
        vector = json.loads(Path(__file__).resolve().parents[1].joinpath("GunnAire OpsTests", "StaffWorkspaceSourceInterop.json").read_text())
        self.assertEqual(vector["schema"], contract.SPECS)
        self.assertEqual(vector["original"], self.native_records())
        self.assertEqual(vector["page"]["schemaDigest"], contract.SCHEMA_DIGEST)
        self.full_scope()
        batch = self.batch()
        self.assertEqual(self.apply(batch)[0], 200)
        page = self.page()[1]
        self.assertEqual([r["fields"] for r in page["records"]], [r["fields"] for r in vector["page"]["records"]])
        self.assertEqual([r["id"] for r in page["records"]], [r["id"] for r in vector["page"]["records"]])

    def test_body_record_and_batch_byte_limits_do_not_accept_partial_work(self):
        self.full_scope()
        batch = self.batch()
        for name, maximum in (("MAX_RECORD_BYTES", 100), ("MAX_BATCH_BYTES", 100)):
            with mock.patch.object(contract, name, maximum):
                self.assertEqual(self.apply(batch)[0], 400)
            self.assertEqual(self.source_count(), 0)
        # The server rejects Content-Length before reading the body. Send just
        # headers to assert the actual response, not a client-side broken pipe
        # caused by urllib continuing to stream after the connection is closed.
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=10)
        try:
            connection.putrequest("POST", self.source)
            connection.putheader("Authorization", "Bearer " + self.tokens["Admin"])
            connection.putheader("Content-Type", "application/json")
            connection.putheader("Content-Length", str(8 * 1024 * 1024 + 1))
            connection.endheaders()
            self.assertEqual(connection.getresponse().status, 400)
        finally:
            connection.close()
        self.assertEqual(self.source_count(), 0)


if __name__ == "__main__":
    unittest.main()
