import base64
import hashlib
import json
import unittest
import urllib.parse
import uuid
from concurrent.futures import ThreadPoolExecutor
from unittest import mock

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.exceptions import InvalidTag
from Backend import test_staff_replica as fixtures, gunnaire_backend as backend


class StaffReplicaTransportTests(unittest.TestCase):
    def setUp(self):
        self.f = fixtures.StaffReplicaTests()
        self.addCleanup(self.f.doCleanups)
        self.f.setUp()
        self.addCleanup(self.f.tearDown)
        self.f.prepare()
        self.share = self.f.accepted()
        self.source = self.f.seed()
        self.value, self.receipt = self.f.payload(self.share)

    def read(self, action="cloud-payload", role="Admin", share=None, operation=None, **query):
        share = share or self.share
        path = self.f.root + "/" + share["id"] + "/projections/" + (operation or self.receipt["operationID"]) + "/" + action
        values = {"companyID": self.f.company, "environment": "development", **query}
        return self.f.request(token=self.f.tokens[role], path=path + "?" + urllib.parse.urlencode(values))

    @staticmethod
    def aad(receipt):
        return "\n".join(str(value) for value in ["gunnaire-staff-cloud-seal-v1", receipt["companyID"], receipt["environment"],
            receipt["replicaID"], receipt["membershipID"], receipt["memberRevision"], receipt["projectionPolicy"],
            receipt["operationID"], receipt["sourceSequence"], receipt["authorizationSequence"], receipt["payloadSHA256"]]).encode()

    def test_owner_packages_once_and_staff_receives_key_not_business_payload(self):
        status, original_key = self.read("cloud-key", "Field Technician")
        self.assertEqual(status, 200)
        self.assertEqual(self.read("cloud-payload", "Field Technician")[0], 403)
        status, owner = self.read()
        self.assertEqual(status, 200, owner)
        status, staff = self.read("cloud-key", "Field Technician")
        self.assertEqual(status, 200, staff)
        self.assertEqual(staff["keyBase64"], owner["keyBase64"])
        self.assertEqual(staff["keyBase64"], original_key["keyBase64"])
        self.assertNotIn("sealedBase64", staff)
        self.assertNotIn("payloadBase64", staff)
        sealed = base64.b64decode(owner["sealedBase64"], validate=True)
        key = base64.b64decode(staff["keyBase64"], validate=True)
        self.assertEqual(len(key), 32)
        self.assertEqual(len(sealed), owner["payloadBytes"] + 28)
        self.assertNotIn(b"Authorized customer", sealed)
        raw = AESGCM(key).decrypt(sealed[:12], sealed[12:], self.aad(staff))
        self.assertEqual(json.loads(raw), self.value)
        self.assertEqual(hashlib.sha256(raw).hexdigest(), staff["payloadSHA256"])
        self.assertFalse(staff["operationalWorkspaceReady"])
        with backend.db() as connection:
            cached = connection.execute("SELECT ciphertext FROM staff_replica_transport_keys").fetchone()[0]
            self.assertNotIn(staff["keyBase64"], cached)

    def test_restart_lost_reply_and_concurrent_reads_keep_original_key_nonce_and_bytes(self):
        first = self.read()
        self.assertEqual(first[0], 200)
        backend.initialize_database()
        self.assertEqual(self.read(), first)
        with ThreadPoolExecutor(max_workers=3) as pool:
            replies = list(pool.map(lambda _: self.read(), range(3)))
        self.assertTrue(all(value == first for value in replies))
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM staff_replica_transport_keys").fetchone()[0], 1)

    def test_assignment_away_and_back_never_releases_the_old_snapshot_key(self):
        self.assertEqual(self.read()[0], 200)
        original = self.source["changes"][9]
        changed = {**original["fields"], "assignedTechnicianIDs": [self.f.identifier(32)]}
        self.assertEqual(self.f.apply(self.f.batch([self.f.record("job", 40, changed, revision=1)], sequence=1))[0], 200)
        self.assertEqual(self.read("cloud-key", "Field Technician")[0], 409)
        self.assertEqual(self.f.apply(self.f.batch([self.f.record("job", 40, original["fields"], revision=2)], sequence=2))[0], 200)
        for action, role in [("cloud-key", "Field Technician"), ("cloud-payload", "Admin")]:
            self.assertEqual(self.read(action, role)[1]["code"], "source_changed")
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM staff_replica_transport_keys").fetchone()[0], 1)

    def test_ordinary_content_update_does_not_replace_original_inflight_seal(self):
        first = self.read()[1]
        self.assertEqual(self.f.apply(self.f.batch([self.f.record("customer", 1, {"name": "Updated name"}, revision=1)], sequence=1))[0], 200)
        current = self.read()[1]
        self.assertEqual(current["sealedBase64"], first["sealedBase64"])
        self.assertEqual(current["keyBase64"], first["keyBase64"])
        self.assertFalse(current["isCurrent"])
        self.assertTrue(current["authorizationCurrent"])

    def test_revoked_share_or_member_and_foreign_scope_cannot_obtain_key(self):
        self.assertEqual(self.read()[0], 200)
        self.assertEqual(self.read("cloud-key", "Dispatcher")[0], 404)
        self.assertNotEqual(self.read("cloud-key", "Field Technician", companyID=str(uuid.uuid4()))[0], 200)
        self.assertNotEqual(self.read("cloud-key", "Field Technician", environment="production")[0], 200)
        self.f.advance(self.share, "revoke")
        self.assertEqual(self.read("cloud-key", "Field Technician")[0], 403)
        self.assertEqual(self.read()[0], 403)

    def test_revoked_member_revision_blocks_key_without_changing_share_record(self):
        self.assertEqual(self.read()[0], 200)
        with backend.db() as connection:
            connection.execute("UPDATE users SET role='Standard',updated_at=? WHERE email='field.technician@gunnaire.com'", (backend.utc_now(),))
        self.assertEqual(self.read("cloud-key", "Field Technician")[0], 403)

    def test_corrupt_or_cross_operation_key_is_retained_and_never_regenerated(self):
        self.assertEqual(self.read()[0], 200)
        with backend.db() as connection:
            cached = connection.execute("SELECT ciphertext FROM staff_replica_transport_keys").fetchone()[0]
        (status, second), _ = self.f.prepare_projection(self.share)
        self.assertEqual(status, 200)
        with backend.db() as connection:
            connection.execute("UPDATE staff_replica_transport_keys SET ciphertext=? WHERE id=?", (cached, second["operationID"]))
        self.assertEqual(self.read(operation=second["operationID"])[0], 503)
        with backend.db() as connection:
            connection.execute("UPDATE staff_replica_transport_keys SET ciphertext='corrupt' WHERE id=?", (self.receipt["operationID"],))
        self.assertEqual(self.read()[0], 503)
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT ciphertext FROM staff_replica_transport_keys WHERE id=?", (self.receipt["operationID"],)).fetchone()[0], "corrupt")

    def test_failed_key_read_audit_releases_no_response_or_replacement_key(self):
        real = backend.record_audit_event
        with backend.db() as connection:
            before = connection.execute("SELECT ciphertext FROM staff_replica_transport_keys").fetchone()[0]
        def fail(*args, **kwargs):
            if args[1] == "read-cloud-sealed-payload":
                raise RuntimeError("fixture audit failure")
            return real(*args, **kwargs)
        with mock.patch.object(backend, "record_audit_event", side_effect=fail):
            self.assertEqual(self.read()[0], 503)
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT ciphertext FROM staff_replica_transport_keys").fetchone()[0], before)
        self.assertEqual(self.read()[0], 200)

    def test_sealed_bytes_reject_changed_payload_key_and_associated_scope(self):
        owner = self.read()[1]
        data = base64.b64decode(owner["sealedBase64"])
        key = base64.b64decode(owner["keyBase64"])
        for changed_key, sealed, aad in [(bytes(32), data, self.aad(owner)), (key, data[:-1] + bytes([data[-1] ^ 1]), self.aad(owner)),
                                         (key, data, self.aad(owner) + b"other")]:
            with self.assertRaises(InvalidTag):
                AESGCM(changed_key).decrypt(sealed[:12], sealed[12:], aad)

    def test_malformed_cached_key_nonce_and_original_payload_fail_without_replacement(self):
        self.assertEqual(self.read()[0], 200)
        with backend.db() as connection:
            original = connection.execute("SELECT ciphertext FROM staff_replica_transport_keys").fetchone()[0]
        cached = json.loads(backend.decrypt_catalog_payload(original))
        for values in [{**cached, "key": base64.b64encode(bytes(31)).decode()}, {**cached, "nonce": "invalid"}, {**cached, "extra": True}]:
            ciphertext = backend.encrypt_catalog_payload(json.dumps(values))
            with backend.db() as connection:
                connection.execute("UPDATE staff_replica_transport_keys SET ciphertext=?", (ciphertext,))
            self.assertEqual(self.read()[0], 503)
            with backend.db() as connection:
                self.assertEqual(connection.execute("SELECT ciphertext FROM staff_replica_transport_keys").fetchone()[0], ciphertext)
        with backend.db() as connection:
            connection.execute("UPDATE staff_replica_transport_keys SET ciphertext=?", (original,))
            connection.execute("UPDATE staff_replica_projections SET ciphertext=?", (backend.encrypt_catalog_payload("{}"),))
        self.assertEqual(self.read()[0], 503)

    def test_packaging_survives_database_backup_restore_without_rekeying(self):
        import sqlite3
        first = self.read()
        backup = sqlite3.connect(":memory:")
        self.addCleanup(backup.close)
        with backend.db() as connection:
            connection.backup(backup)
        with backend.db() as connection:
            connection.execute("DELETE FROM staff_replica_transport_keys")
        with backend.db() as connection:
            backup.backup(connection)
        backend.initialize_database()
        self.assertEqual(self.read(), first)

    def test_missing_legacy_or_lost_key_never_generates_replacement_on_read(self):
        with backend.db() as connection:
            connection.execute("DELETE FROM staff_replica_transport_keys")
        for action, role in [("cloud-key", "Field Technician"), ("cloud-payload", "Admin")]:
            self.assertEqual(self.read(action, role)[1]["code"], "transport_unavailable")
        backend.initialize_database()
        self.assertEqual(self.read()[0], 409)
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM staff_replica_transport_keys").fetchone()[0], 0)
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM staff_replica_projections").fetchone()[0], 1)

    def test_projection_and_key_rollback_together_on_creation_audit_failure(self):
        real = backend.record_audit_event
        def fail(*args, **kwargs):
            if args[1] == "prepare-projection":
                raise RuntimeError("fixture audit failure")
            return real(*args, **kwargs)
        with mock.patch.object(backend, "record_audit_event", side_effect=fail):
            (status, _), _ = self.f.prepare_projection(self.share)
            self.assertEqual(status, 503)
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM staff_replica_transport_keys").fetchone()[0], 1)
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM staff_replica_projections").fetchone()[0], 1)

    def test_native_interop_fixture_uses_current_backend_authenticated_scope_and_format(self):
        from pathlib import Path
        from Backend import staff_replica, staff_replica_contract
        source = (Path(__file__).resolve().parents[1] / "GunnAire OpsTests" / "StaffReplicaServerInteropTests.swift").read_text()
        vector = json.loads(source.split('private static let fixture = #"', 1)[1].split('"#', 1)[0])
        receipt = vector["owner"]
        member = {"id": receipt["membershipID"], "member_revision": receipt["memberRevision"], "projection_policy": receipt["projectionPolicy"]}
        scope = (receipt["companyID"], receipt["environment"], receipt["replicaID"])
        aad = staff_replica.StaffReplica.transport_aad(scope, member, receipt["operationID"], receipt["sourceSequence"],
                                                      receipt["authorizationSequence"], receipt["payloadSHA256"])
        self.assertEqual(aad.encode(), self.aad(receipt))
        sealed = base64.b64decode(receipt["sealedBase64"], validate=True)
        key = base64.b64decode(vector["staff"]["keyBase64"], validate=True)
        raw = AESGCM(key).decrypt(sealed[:12], sealed[12:], aad.encode())
        self.assertEqual(hashlib.sha256(raw).hexdigest(), receipt["payloadSHA256"])
        value = json.loads(raw)
        self.assertEqual(len(value["records"]), 8)
        for record in value["records"]:
            staff_replica_contract.validate(record["kind"], record["fields"])
