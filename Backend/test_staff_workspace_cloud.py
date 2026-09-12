from __future__ import annotations

import base64
import hashlib
import unittest
import urllib.parse
import uuid
from concurrent.futures import ThreadPoolExecutor
from unittest import mock

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from Backend import gunnaire_backend as backend
from Backend import staff_workspace_cloud as cloud
from Backend import staff_workspace_delivery as delivery
from Backend import staff_workspace_projection as projection
from Backend import test_staff_workspace_delivery as content_http


class StaffWorkspaceCloudHTTPTests(unittest.TestCase):
    Fixture = content_http.StaffWorkspaceDeliveryHTTPTests
    setUp, tearDown, request = Fixture.setUp, Fixture.tearDown, Fixture.request
    workspace, binding_payload, bind = Fixture.workspace, Fixture.binding_payload, Fixture.bind
    prepare, enroll, change = Fixture.prepare, Fixture.enroll, Fixture.change
    requested, advance, accepted = Fixture.requested, Fixture.advance, Fixture.accepted
    root, participant_name, participant_hash = Fixture.root, Fixture.participant_name, Fixture.participant_hash
    write_source, post = Fixture.write_source, Fixture.post

    def seed(self, role="Field Technician", prepare=True):
        self.prepare()
        self.scope = dict(companyID=self.company, environment="development",
                          replicaID=self.workspace()["bindings"][0]["replicaID"])
        self.records = content_http.content_fixtures.rich_records(self.company, self.scope["replicaID"])
        self.write_source(self.records, 0)
        self.sequence = 1
        self.share = self.accepted(role)
        self.endpoint = self.root + "/" + self.share["id"] + "/full-selections"
        self.payload = dict(**self.scope, operationID=str(uuid.uuid4()), expectedSourceSequence=1,
                            expectedShareRevision=self.share["revision"],
                            sourceSchemaDigest=content_http.contract.SCHEMA_DIGEST)
        status, result = self.post()
        self.assertEqual(status, 200, result)
        self.content_path = self.endpoint + "/" + self.payload["operationID"] + "/content"
        self.seal_path = self.content_path + "/cloud-seal"
        self.key_endpoint = self.content_path + "/cloud-key"
        if prepare:
            status, receipt = self.deliver()
            self.assertEqual(status, 200, receipt)
            return status, receipt
        return status, result

    def deliver(self, role="Admin", payload=None):
        return self.request(token=self.tokens[role], path=self.content_path, method="POST",
                            payload=payload if payload is not None else dict(**self.scope, contentSchema=projection.SCHEMA))

    def seal(self, role="Admin", method="POST", payload=None, query=None):
        if method == "POST":
            body = payload if payload is not None else dict(**self.scope, contentSchema=projection.SCHEMA)
            return self.request(token=self.tokens[role], path=self.seal_path, method="POST", payload=body)
        values = dict(self.scope) if query is None else query
        path = self.seal_path + "?" + urllib.parse.urlencode(values)
        return self.request(token=self.tokens[role], path=path)

    def key_path(self):
        return self.content_path + "/cloud-key"

    def cloud_key(self, role="Field Technician", method="GET", query=None, payload=None):
        if method == "POST":
            body = payload if payload is not None else dict(**self.scope)
            return self.request(token=self.tokens[role], path=self.key_path(), method="POST", payload=body)
        values = dict(self.scope) if query is None else query
        path = self.key_path() + "?" + urllib.parse.urlencode(values)
        return self.request(token=self.tokens[role], path=path)

    def chunks(self, role="Admin"):
        path = self.content_path + "/chunks?" + urllib.parse.urlencode(dict(self.scope, offset="0"))
        return self.request(token=self.tokens[role], path=path)

    def seal_count(self):
        with backend.db() as connection:
            return connection.execute("SELECT COUNT(*) FROM staff_workspace_cloud_seals").fetchone()[0]

    def test_prepare_creates_immutable_owner_seal_matching_content_bytes(self):
        self.assertEqual(self.seed()[0], 200)
        status, chunk = self.chunks()
        self.assertEqual(status, 200, chunk)
        raw = base64.b64decode(chunk["payloadBase64"], validate=True)
        status, sealed = self.seal()
        self.assertEqual(status, 200, sealed)
        self.assertEqual(sealed["schema"], cloud.SCHEMA)
        self.assertEqual(sealed["content"]["contentSHA256"], delivery.digest(raw))
        self.assertEqual(sealed["content"]["payloadBytes"], len(raw))
        self.assertEqual(sealed["sealedBytes"], len(raw) + 28)
        key = base64.b64decode(sealed["keyBase64"], validate=True)
        nonce = base64.b64decode(sealed["nonceBase64"], validate=True)
        self.assertEqual(len(key), 32)
        self.assertEqual(len(nonce), 12)
        package = nonce + AESGCM(key).encrypt(nonce, raw, cloud.aad(sealed["content"]))
        self.assertEqual(delivery.digest(package), sealed["sealedSHA256"])
        self.assertEqual(AESGCM(key).decrypt(nonce, package[12:], cloud.aad(sealed["content"])), raw)
        self.assertNotIn("sealedBase64", sealed)
        self.assertNotIn(b"PRIVATE-CREDIT-AMOUNT", package)
        with backend.db() as connection:
            row = connection.execute("SELECT seal_sha256, ciphertext FROM staff_workspace_projections").fetchone()
            cached = connection.execute("SELECT ciphertext FROM staff_workspace_cloud_seals").fetchone()[0]
            self.assertEqual(row["seal_sha256"], sealed["sealedSHA256"])
            self.assertNotIn(sealed["keyBase64"], cached)
            self.assertNotIn("R-410A", cached)

    def test_get_restart_and_concurrent_reads_keep_original_key_nonce_and_hash(self):
        self.assertEqual(self.seed()[0], 200)
        first = self.seal()
        self.assertEqual(first[0], 200, first[1])
        backend.initialize_database()
        second = self.seal(method="GET")
        self.assertEqual(second, first)
        with ThreadPoolExecutor(max_workers=3) as pool:
            replies = list(pool.map(lambda _: self.seal(method="GET"), range(3)))
        self.assertTrue(all(value == first for value in replies))
        again = self.seal()
        self.assertEqual(again, first)
        self.assertEqual(self.seal_count(), 1)

    def test_get_before_prepare_and_prepare_before_content_are_explicit(self):
        self.seed(prepare=False)
        self.assertEqual(self.seal(method="GET")[1]["code"], "content_not_prepared")
        self.assertEqual(self.seal()[1]["code"], "content_not_prepared")
        self.assertEqual(self.seal_count(), 0)
        self.assertEqual(self.deliver()[0], 200)
        self.assertEqual(self.seal(method="GET")[1]["code"], "seal_not_prepared")
        self.assertEqual(self.seal()[0], 200)
        self.assertEqual(self.seal_count(), 1)

    def test_invalid_schema_scope_query_and_extra_fields_are_rejected(self):
        self.assertEqual(self.seed()[0], 200)
        for update in (dict(contentSchema="core-field-v1"), dict(memberRole="Admin"), dict(companyID=str(uuid.uuid4()))):
            self.assertNotEqual(self.seal(payload=dict(self.scope, contentSchema=projection.SCHEMA) | update)[0], 200)
        self.assertEqual(self.seal()[0], 200)
        self.assertEqual(self.seal(method="GET", query=dict(self.scope, offset="0"))[0], 400)
        path = self.seal_path + "?" + urllib.parse.urlencode(self.scope) + "&environment=development"
        self.assertEqual(self.request(token=self.tokens["Admin"], path=path)[0], 400)
        self.assertEqual(self.seal_count(), 1)

    def test_source_advance_blocks_release_without_replacing_key(self):
        self.assertEqual(self.seed()[0], 200)
        first = self.seal()[1]
        equipment = content_http.fixtures.row(self.records, "equipment")
        content_http.fixtures.set_value(equipment, "notes", "advanced after seal")
        self.write_source([equipment], 1, 1)
        status, result = self.seal(method="GET")
        self.assertEqual(status, 409, result)
        self.assertEqual(result["code"], "source_changed")
        self.assertEqual(self.seal()[1]["code"], "source_changed")
        with backend.db() as connection:
            marker = connection.execute("SELECT seal_sha256 FROM staff_workspace_projections").fetchone()[0]
            self.assertEqual(marker, first["sealedSHA256"])
        self.assertEqual(self.seal_count(), 1)

    def test_corrupt_seal_or_marker_mismatch_requires_recovery(self):
        self.assertEqual(self.seed()[0], 200)
        self.assertEqual(self.seal()[0], 200)
        with backend.db() as connection:
            saved = connection.execute("SELECT ciphertext FROM staff_workspace_cloud_seals").fetchone()[0]
            connection.execute("UPDATE staff_workspace_cloud_seals SET ciphertext='damaged'")
        self.assertEqual(self.seal(method="GET")[0], 503)
        self.assertEqual(self.seal()[0], 503)
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT ciphertext FROM staff_workspace_cloud_seals").fetchone()[0], "damaged")
            connection.execute("UPDATE staff_workspace_cloud_seals SET ciphertext=?", (saved,))
            connection.execute("UPDATE staff_workspace_projections SET seal_sha256=?", ("f" * 64,))
        self.assertEqual(self.seal(method="GET")[0], 503)
        self.assertEqual(self.seal_count(), 1)

    def test_orphan_marker_without_seal_row_is_unavailable(self):
        self.assertEqual(self.seed()[0], 200)
        with backend.db() as connection:
            connection.execute("UPDATE staff_workspace_projections SET seal_sha256=?", ("a" * 64,))
        self.assertEqual(self.seal()[0], 503)
        self.assertEqual(self.seal(method="GET")[1]["code"], "storage_unavailable")
        self.assertEqual(self.seal_count(), 0)

    def test_staff_and_revoked_session_cannot_prepare_or_read_seal(self):
        self.assertEqual(self.seed()[0], 200)
        self.assertEqual(self.seal(role="Field Technician")[0], 403)
        self.assertEqual(self.seal()[0], 200)
        self.assertEqual(self.seal(method="GET", role="Field Technician")[0], 403)
        original = backend.GunnAireBackendHandler.require_application_session

        def revoke(handler):
            result = original(handler)
            with backend.db() as connection:
                connection.execute("UPDATE auth_sessions SET revoked_at=? WHERE email='admin@gunnaire.com'",
                                   (backend.utc_now(),))
            return result

        with mock.patch.object(backend.GunnAireBackendHandler, "require_application_session", revoke):
            self.assertEqual(self.seal(method="GET")[0], 403)

    def test_aad_rejects_changed_key_ciphertext_and_scope(self):
        self.assertEqual(self.seed()[0], 200)
        status, chunk = self.chunks()
        raw = base64.b64decode(chunk["payloadBase64"], validate=True)
        sealed = self.seal()[1]
        key = base64.b64decode(sealed["keyBase64"], validate=True)
        nonce = base64.b64decode(sealed["nonceBase64"], validate=True)
        package = nonce + AESGCM(key).encrypt(nonce, raw, cloud.aad(sealed["content"]))
        for changed_key, blob, aad in [
            (bytes(32), package, cloud.aad(sealed["content"])),
            (key, package[:-1] + bytes([package[-1] ^ 1]), cloud.aad(sealed["content"])),
            (key, package, cloud.aad(sealed["content"]) + b"other"),
        ]:
            with self.assertRaises(InvalidTag):
                AESGCM(changed_key).decrypt(blob[:12], blob[12:], aad)


    def test_staff_cloud_key_release_matches_owner_seal_without_payload(self):
        self.assertEqual(self.seed()[0], 200)
        status, owner = self.seal()
        self.assertEqual(status, 200, owner)
        status, staff = self.cloud_key("Field Technician")
        self.assertEqual(status, 200, staff)
        self.assertEqual(staff["schema"], cloud.SCHEMA)
        self.assertEqual(staff["keyBase64"], owner["keyBase64"])
        self.assertEqual(staff["nonceBase64"], owner["nonceBase64"])
        self.assertEqual(staff["sealedSHA256"], owner["sealedSHA256"])
        self.assertEqual(staff["sealedBytes"], owner["sealedBytes"])
        self.assertNotIn("sealedBase64", staff)
        self.assertNotIn("payloadBase64", staff)
        status, admin = self.cloud_key("Admin")
        self.assertEqual(status, 200, admin)
        self.assertEqual(admin["keyBase64"], owner["keyBase64"])
        self.assertEqual(self.seal_count(), 1)

    def test_staff_cannot_post_or_get_cloud_seal_or_post_cloud_key(self):
        self.assertEqual(self.seed()[0], 200)
        self.assertEqual(self.seal(role="Field Technician")[0], 403)
        self.assertEqual(self.seal()[0], 200)
        self.assertEqual(self.seal(method="GET", role="Field Technician")[0], 403)
        self.assertEqual(self.cloud_key(method="POST")[0], 404)
        self.assertEqual(self.seal_count(), 1)

    def test_wrong_member_foreign_company_and_revoked_share_cannot_get_cloud_key(self):
        self.assertEqual(self.seed()[0], 200)
        self.assertEqual(self.seal()[0], 200)
        self.assertEqual(self.cloud_key("Dispatcher")[0], 404)
        self.assertNotEqual(self.cloud_key(query=dict(self.scope, companyID=str(uuid.uuid4())))[0], 200)
        self.advance(self.share, "revoke")
        self.assertEqual(self.cloud_key("Field Technician")[0], 403)
        self.assertEqual(self.seal_count(), 1)

    def test_source_advance_blocks_cloud_key_without_replacing_key(self):
        self.assertEqual(self.seed()[0], 200)
        first = self.seal()[1]
        equipment = content_http.fixtures.row(self.records, "equipment")
        content_http.fixtures.set_value(equipment, "notes", "advanced after seal key")
        self.write_source([equipment], 1, 1)
        status, result = self.cloud_key()
        self.assertEqual(status, 409, result)
        self.assertEqual(result["code"], "source_changed")
        with backend.db() as connection:
            marker = connection.execute("SELECT seal_sha256 FROM staff_workspace_projections").fetchone()[0]
            self.assertEqual(marker, first["sealedSHA256"])
        self.assertEqual(self.seal_count(), 1)

    def test_cloud_key_before_seal_is_explicit(self):
        self.assertEqual(self.seed()[0], 200)
        status, result = self.cloud_key()
        self.assertEqual(status, 404, result)
        self.assertEqual(result["code"], "seal_not_prepared")
        self.assertEqual(self.seal_count(), 0)
        self.assertEqual(self.seal()[0], 200)
        self.assertEqual(self.cloud_key()[0], 200)

    def test_corrupt_seal_blocks_cloud_key_and_retains_key(self):
        self.assertEqual(self.seed()[0], 200)
        self.assertEqual(self.seal()[0], 200)
        with backend.db() as connection:
            connection.execute("UPDATE staff_workspace_cloud_seals SET ciphertext='damaged'")
        self.assertEqual(self.cloud_key()[0], 503)
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT ciphertext FROM staff_workspace_cloud_seals").fetchone()[0], "damaged")
        self.assertEqual(self.seal_count(), 1)


if __name__ == "__main__":
    unittest.main()
