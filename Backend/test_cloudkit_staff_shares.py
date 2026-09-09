from __future__ import annotations

import io
import hashlib
import json
import sqlite3
import unittest
import urllib.parse
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from unittest import mock
from cryptography.fernet import Fernet

from Backend import cloudkit_staff_shares as sharing
from Backend import gunnaire_backend as backend
from Backend import test_workspace_identity as fixture


class CloudKitStaffSharingTests(unittest.TestCase):
    def setUp(self):
        fixture.WorkspaceIdentityTests.setUp(self)
        self.cipher = Fernet(Fernet.generate_key())
        for name, function in (("encrypt_catalog_payload", lambda raw: self.cipher.encrypt(raw.encode()).decode()),
                               ("decrypt_catalog_payload", lambda raw: self.cipher.decrypt(raw.encode()).decode())):
            patcher = mock.patch.object(backend, name, side_effect=function)
            patcher.start()
            self.addCleanup(patcher.stop)
    tearDown = fixture.WorkspaceIdentityTests.tearDown
    request = fixture.WorkspaceIdentityTests.request
    workspace = fixture.WorkspaceIdentityTests.workspace
    binding_payload = fixture.WorkspaceIdentityTests.binding_payload
    bind = fixture.WorkspaceIdentityTests.bind
    root = "/api/workspace/staff-shares"
    participant_name = "_fixture-staff-record"
    participant_hash = hashlib.sha256(("gunnaire-cloudkit-account-v1\niCloud.com.gunnaire.businesssuite\ndevelopment\n" + participant_name).encode()).hexdigest()

    def prepare(self):
        payload = self.binding_payload()
        self.assertEqual(self.bind(payload)[0], 201)
        self.company = payload["expectedCompanyID"]
        return {"companyID": self.company, "environment": "development"}

    def enroll(self, actor_role="Field Technician", **changes):
        payload = {"companyID": self.company, "environment": "development", "operationID": str(uuid.uuid4()),
                   "participantAccountHash": self.participant_hash, "participantRecordName": self.participant_name, **changes}
        return self.request(token=self.tokens[actor_role], payload=payload, method="POST", path=self.root), payload

    def read(self, role="Field Technician", identifier=None, **changes):
        query = {"companyID": self.company, "environment": "development", **changes}
        return self.request(token=self.tokens[role], path=self.root + ("/" + identifier if identifier else "") +
                            "?" + urllib.parse.urlencode(query))

    def change(self, row, action, role="Admin", **changes):
        confirmation = {"approve": "confirmRoleScopedReadOnlySharing", "invite": "confirmPrivateReadOnlyCloudKitShare",
                        "accept": "confirmLocalCloudKitProof", "revoke": "confirmBusinessAccessRevocation",
                        "confirm-cleanup": "confirmCloudKitAccessRemoved"}[action]
        payload = {"companyID": self.company, "environment": "development", "operationID": str(uuid.uuid4()),
                   "expectedRevision": row["revision"], confirmation: True}
        if action == "accept":
            payload["participantAccountHash"] = self.participant_hash
        payload.update(changes)
        return self.request(token=self.tokens[role], payload=payload, method="POST", path=self.root + "/" + row["id"] + "/" + action), payload

    def requested(self, role="Field Technician"):
        (status, row), _ = self.enroll(role)
        self.assertEqual(status, 200)
        return row

    def advance(self, row, action, role="Admin"):
        (status, changed), _ = self.change(row, action, role)
        self.assertEqual(status, 200, changed)
        return changed

    def accepted(self, role="Field Technician"):
        row = self.requested(role)
        for action, actor in (("approve", "Admin"), ("invite", "Admin"), ("accept", role)):
            row = self.advance(row, action, actor)
        return row

    def test_full_invitation_lifecycle_never_claims_local_cloudkit_attestation(self):
        self.prepare()
        row = self.requested()
        self.assertEqual(row["state"], "requested")
        self.assertEqual(row["projectionPolicy"], "field-assigned-jobs-v1")
        self.assertFalse(row["businessAccessEligible"])
        self.assertTrue(row["localCloudKitProofRequired"])
        self.assertFalse(row["reviewRequired"])
        for revision, action in ((2, "approve"), (3, "invite")):
            row = self.advance(row, action)
            self.assertEqual(row["revision"], revision)
            self.assertFalse(row["businessAccessEligible"])
        row = self.advance(row, "accept", "Field Technician")
        self.assertTrue(row["businessAccessEligible"])
        self.assertTrue(row["localCloudKitProofRequired"])
        self.assertNotIn("shareURL", row)
        self.assertNotIn("customer", json.dumps(row).lower())
        self.assertNotIn("sessionToken", row)

    def test_every_role_gets_only_its_own_distinct_projection_zone(self):
        self.prepare()
        rows = {role: self.requested(role) for role in self.tokens}
        self.assertEqual(len({row["zoneName"] for row in rows.values()}), 5)
        self.assertEqual(len({row["shareRecordName"] for row in rows.values()}), 5)
        for role, row in rows.items():
            self.assertEqual(row["memberRole"], role)
            self.assertEqual(row["projectionPolicy"], sharing.POLICIES[role])
            status, body = self.read(role)
            self.assertEqual(status, 200)
            expected = set(r["id"] for r in rows.values()) if role == "Admin" else {row["id"]}
            self.assertEqual({r["id"] for r in body["shares"]}, expected)
            self.assertIsNone(body["nextCursor"])
            if role != "Admin":
                self.assertEqual(self.read(role, rows["Admin"]["id"])[0], 404)

    def test_enrollment_replay_preserves_original_and_does_not_reactivate(self):
        self.prepare()
        (status, original), payload = self.enroll()
        self.assertEqual(status, 200)
        def replay():
            return self.request(token=self.tokens["Field Technician"], payload=payload, method="POST", path=self.root)
        self.assertEqual(replay(), (200, original))
        self.assertEqual(self.enroll()[0][1]["code"], "request_exists")
        revoked = self.advance(original, "revoke", "Field Technician")
        self.assertEqual(replay(), (200, revoked))
        new = self.requested()
        self.assertNotEqual(new["zoneName"], original["zoneName"])
        self.assertFalse(new["businessAccessEligible"])

    def test_enrollment_rejects_actor_account_company_and_environment_replacement(self):
        self.prepare()
        (_, row), payload = self.enroll()
        other_name = "_different-staff"
        other_hash = hashlib.sha256(("gunnaire-cloudkit-account-v1\n" + sharing.CONTAINER + "\ndevelopment\n" + other_name).encode()).hexdigest()
        self.assertEqual(self.enroll(operationID=row["id"], participantAccountHash=other_hash, participantRecordName=other_name)[0][0], 409)
        self.assertEqual(self.enroll("Admin", operationID=row["id"])[0][0], 409)
        self.assertEqual(self.enroll("Dispatcher", operationID=row["id"])[0][0], 404)
        self.assertEqual(self.enroll(companyID=str(uuid.uuid4()))[0][0], 403)
        production_hash = hashlib.sha256(("gunnaire-cloudkit-account-v1\n" + sharing.CONTAINER + "\nproduction\n" + self.participant_name).encode()).hexdigest()
        self.assertEqual(self.enroll(environment="production", participantAccountHash=production_hash)[0][1]["code"], "owner_required")
        owner_payload = {"companyID": self.company, "environment": "development", "operationID": str(uuid.uuid4()), "participantAccountHash": "a" * 64}
        self.assertEqual(self.request(token=self.tokens["Field Technician"], payload=owner_payload, method="POST", path=self.root)[1]["code"], "owner_device")
        self.assertEqual(self.read(identifier=row["id"], environment="production")[0], 409)

    def test_exact_validation_rejects_extra_authority_fields_and_noncanonical_inputs(self):
        self.prepare()
        for changes in ({"memberEmail": "admin@gunnaire.com"}, {"role": "Admin"}, {"projectionPolicy": "admin-operations-v1"},
                        {"participantAccountHash": "B" * 64}, {"participantAccountHash": "b" * 65},
                        {"participantAccountHash": ["b" * 64]}, {"environment": "Production"},
                        {"environment": []}, {"operationID": True}, {"operationID": str(uuid.uuid4()).upper()},
                        {"companyID": "bad"}):
            with self.subTest(changes=changes):
                self.assertEqual(self.enroll(**changes)[0][0], 400)
        for payload in ([], None, True, "invalid", {"excess": "x" * 9000}):
            self.assertEqual(self.request(token=self.tokens["Field Technician"], payload=payload, method="POST", path=self.root)[0], 400)
        self.assertEqual(self.read()[1]["shares"], [])

    def test_only_fresh_admin_can_approve_invite_or_confirm_cleanup(self):
        self.prepare()
        row = self.requested()
        for role in self.tokens:
            if role != "Admin":
                status, _ = self.change(row, "approve", role)[0]
                self.assertIn(status, (403, 404))
        with backend.db() as connection:
            connection.execute("UPDATE auth_sessions SET created_at=? WHERE email='admin@gunnaire.com'",
                               ((datetime.now(timezone.utc) - timedelta(seconds=601)).isoformat(),))
        self.assertEqual(self.change(row, "approve")[0][0], 403)
        self.assertEqual(self.read("Admin", row["id"])[0], 200)
        self.assertEqual(self.read(identifier=row["id"])[1]["revision"], 1)

    def test_session_revoked_between_http_authorization_and_transaction_is_denied(self):
        self.prepare()
        row = self.requested()
        original = backend.GunnAireBackendHandler.require_application_session
        def revoke(handler):
            result = original(handler)
            with backend.db() as connection:
                connection.execute("UPDATE auth_sessions SET revoked_at=? WHERE email='admin@gunnaire.com'", (backend.utc_now(),))
            return result
        with mock.patch.object(backend.GunnAireBackendHandler, "require_application_session", revoke):
            self.assertEqual(self.change(row, "approve")[0][0], 403)
        self.assertEqual(self.read(identifier=row["id"])[1]["state"], "requested")

    def test_all_actions_require_exact_confirmation_revision_and_state(self):
        self.prepare()
        row = self.requested()
        for value in (False, 1, "true", None):
            self.assertEqual(self.change(row, "approve", confirmRoleScopedReadOnlySharing=value)[0][0], 400)
        for value in (True, 0, -1, "1", 2147483647, 1.0):
            self.assertEqual(self.change(row, "approve", expectedRevision=value)[0][0], 400)
        self.assertEqual(self.change(row, "approve", expectedRevision=2)[0][1]["code"], "review_changed")
        self.assertEqual(self.change(row, "invite")[0][1]["code"], "approver_changed")
        self.assertEqual(self.change(row, "accept", "Field Technician")[0][0], 409)
        self.assertEqual(self.change(row, "approve", permission="readWrite")[0][0], 400)

    def test_participant_acceptance_cannot_be_substituted_by_admin_or_other_account(self):
        self.prepare()
        row = self.advance(self.advance(self.requested(), "approve"), "invite")
        self.assertEqual(self.change(row, "accept")[0][1]["code"], "participant_changed")
        self.assertEqual(self.change(row, "accept", "Dispatcher")[0][0], 404)
        self.assertEqual(self.change(row, "accept", "Field Technician", participantAccountHash="c" * 64)[0][0], 403)
        self.assertEqual(self.change(row, "accept", "Field Technician", confirmLocalCloudKitProof=False)[0][0], 400)
        self.assertFalse(self.read(identifier=row["id"])[1]["businessAccessEligible"])

    def test_role_change_blocks_existing_invitation_and_new_role_requires_new_zone(self):
        self.prepare()
        row = self.accepted()
        with backend.db() as connection:
            connection.execute("UPDATE users SET role='Standard',updated_at=? WHERE email='field.technician@gunnaire.com'", (backend.utc_now(),))
        changed = self.read(identifier=row["id"])[1]
        self.assertFalse(changed["businessAccessEligible"])
        self.assertTrue(changed["reviewRequired"])
        self.assertTrue(changed["cloudKitRevocationRequired"])
        self.assertEqual(changed["memberRole"], "Field Technician")
        self.advance(changed, "revoke")
        next_row = self.requested()
        self.assertEqual(next_row["memberRole"], "Standard")
        self.assertNotEqual(next_row["zoneName"], row["zoneName"])
        self.assertFalse(next_row["businessAccessEligible"])

    def test_demote_then_restore_does_not_restore_old_share_eligibility(self):
        self.prepare()
        row = self.accepted()
        for role in ("Standard", "Field Technician"):
            with backend.db() as connection:
                connection.execute("UPDATE users SET role=?,updated_at=? WHERE email='field.technician@gunnaire.com'", (role, backend.utc_now()))
        self.assertFalse(self.read(identifier=row["id"])[1]["businessAccessEligible"])

    def test_revoked_inactive_unknown_and_expired_sessions_cannot_read_or_enroll(self):
        self.prepare()
        for role, change in (("Dispatcher", "UPDATE auth_sessions SET revoked_at='2026-01-01T00:00:00Z' WHERE email='dispatcher@gunnaire.com'"),
                             ("Accounting", "UPDATE users SET is_active=0 WHERE email='accounting@gunnaire.com'"),
                             ("Standard", "UPDATE auth_sessions SET expires_at='2020-01-01T00:00:00Z' WHERE email='standard@gunnaire.com'"),
                             ("Field Technician", "UPDATE users SET role='Unrecognized' WHERE email='field.technician@gunnaire.com'")):
            with backend.db() as connection:
                connection.execute(change)
            self.assertIn(self.read(role)[0], (401, 403))
            self.assertIn(self.enroll(role)[0][0], (401, 403))

    def test_changed_or_inactive_approver_requires_review_and_cloudkit_cleanup(self):
        self.prepare()
        row = self.accepted()
        with backend.db() as connection:
            connection.execute("UPDATE users SET is_active=0,updated_at=? WHERE email='admin@gunnaire.com'", (backend.utc_now(),))
        current = self.read(identifier=row["id"])[1]
        self.assertFalse(current["businessAccessEligible"])
        self.assertTrue(current["cloudKitRevocationRequired"])
        self.assertTrue(current["reviewRequired"])
        revoked = self.advance(current, "revoke", "Field Technician")
        self.assertEqual(revoked["state"], "revoked")

    def test_lost_action_reply_returns_current_state_without_second_transition(self):
        self.prepare()
        row = self.requested()
        (status, approved), payload = self.change(row, "approve")
        self.assertEqual(status, 200)
        path = self.root + "/" + row["id"] + "/approve"
        self.assertEqual(self.request(token=self.tokens["Admin"], payload=payload, method="POST", path=path), (200, approved))
        revoked = self.advance(approved, "revoke")
        self.assertEqual(self.request(token=self.tokens["Admin"], payload=payload, method="POST", path=path), (200, revoked))
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM audit_events WHERE subject_type='cloudkit-staff-share'").fetchone()[0], 3)
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM cloudkit_staff_share_operations").fetchone()[0], 2)

    def test_operation_identifiers_cannot_be_reused_for_other_fields_actions_or_enrollment(self):
        self.prepare()
        row = self.requested()
        (_, approved), payload = self.change(row, "approve")
        self.assertEqual(self.change(row, "approve", **{**payload, "expectedRevision": 2})[0][1]["code"], "operation_changed")
        self.assertEqual(self.change(approved, "invite", operationID=payload["operationID"])[0][1]["code"], "operation_changed")
        self.assertEqual(self.change(approved, "invite", operationID=row["id"])[0][1]["code"], "operation_changed")
        self.assertEqual(self.enroll("Dispatcher", operationID=payload["operationID"])[0][1]["code"], "operation_changed")

    def test_revocation_requires_cloudkit_cleanup_even_after_unconfirmed_share_creation(self):
        self.prepare()
        row = self.advance(self.requested(), "approve")
        revoked = self.advance(row, "revoke", "Field Technician")
        self.assertFalse(revoked["businessAccessEligible"])
        self.assertTrue(revoked["cloudKitRevocationRequired"])
        self.assertEqual(self.change(revoked, "confirm-cleanup", "Field Technician")[0][0], 403)
        self.assertEqual(self.change(revoked, "confirm-cleanup", confirmCloudKitAccessRemoved=False)[0][0], 400)
        cleaned = self.advance(revoked, "confirm-cleanup")
        self.assertFalse(cleaned["cloudKitRevocationRequired"])
        self.assertFalse(cleaned["businessAccessEligible"])
        self.assertEqual(cleaned["state"], "revoked")

    def test_pending_enrollment_can_be_cancelled_without_claiming_a_share_existed(self):
        self.prepare()
        row = self.advance(self.requested(), "revoke", "Field Technician")
        self.assertFalse(row["cloudKitRevocationRequired"])
        self.assertEqual(self.change(row, "confirm-cleanup")[0][1]["code"], "cleanup_not_required")

    def test_concurrent_approval_is_compare_and_swap_and_atomic(self):
        self.prepare()
        row = self.requested()
        with ThreadPoolExecutor(max_workers=2) as executor:
            results = list(executor.map(lambda _: self.change(row, "approve")[0], range(2)))
        self.assertEqual(sorted(status for status, _ in results), [200, 409])
        self.assertEqual(self.read(identifier=row["id"])[1]["revision"], 2)

    def test_concurrent_enrollment_replay_creates_only_one_zone_and_audit(self):
        self.prepare()
        operation = str(uuid.uuid4())
        with ThreadPoolExecutor(max_workers=2) as executor:
            results = list(executor.map(lambda _: self.enroll(operationID=operation)[0], range(2)))
        self.assertEqual(results[0], results[1])
        self.assertEqual(results[0][0], 200)
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM cloudkit_staff_shares").fetchone()[0], 1)
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM audit_events WHERE subject_type='cloudkit-staff-share'").fetchone()[0], 1)

    def test_audit_failure_rolls_back_both_enrollment_and_transition(self):
        self.prepare()
        with mock.patch.object(backend, "record_audit_event", side_effect=sqlite3.OperationalError("test unavailable")):
            self.assertEqual(self.enroll()[0][0], 503)
        self.assertEqual(self.read()[1]["shares"], [])
        row = self.requested()
        with mock.patch.object(backend, "record_audit_event", side_effect=sqlite3.OperationalError("test unavailable")):
            self.assertEqual(self.change(row, "approve")[0][0], 503)
        self.assertEqual(self.read(identifier=row["id"])[1], row)
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM cloudkit_staff_share_operations").fetchone()[0], 0)

    def test_restart_and_additive_migration_preserve_original_identity_and_all_share_states(self):
        self.prepare()
        row = self.accepted()
        backend.initialize_database()
        self.assertEqual(self.read(identifier=row["id"])[1], row)
        self.assertEqual(self.workspace()["companyID"], self.company)
        with backend.db() as connection:
            connection.execute("DELETE FROM company_identity")
            connection.execute("DELETE FROM cloudkit_workspace_bindings")
        with self.assertRaises(sqlite3.DatabaseError):
            backend.initialize_database()
        with backend.db() as connection:
            self.assertIsNone(connection.execute("SELECT * FROM company_identity").fetchone())
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM cloudkit_staff_shares").fetchone()[0], 1)

    def test_foreign_replaced_owner_binding_cannot_return_or_advance_old_share(self):
        self.prepare()
        row = self.requested()
        with backend.db() as connection:
            connection.execute("UPDATE cloudkit_workspace_bindings SET cloud_account_hash=?", ("c" * 64,))
        self.assertEqual(self.read(identifier=row["id"])[1]["code"], "workspace_changed")
        self.assertEqual(self.read("Admin")[1]["code"], "workspace_changed")
        self.assertEqual(self.change(row, "approve")[0][1]["code"], "workspace_changed")

    def test_legacy_tokens_and_unauthenticated_calls_never_authorize_sharing(self):
        self.prepare()
        path = self.root + "?companyID=" + self.company + "&environment=development"
        self.assertEqual(self.request(path=path)[0], 401)
        with mock.patch.multiple(backend, AUTH_MODE="api-token", API_TOKEN="legacy-test-token"):
            self.assertEqual(self.request(token="legacy-test-token", path=path)[0], 403)
            self.assertEqual(self.request(token="legacy-test-token", method="POST", path=self.root, payload={})[0], 403)

    def test_apple_application_session_can_enroll_but_never_claim_another_member(self):
        self.prepare()
        self.tokens["Standard"] = backend.create_app_session("standard@gunnaire.com", "apple", "apple-test-subject")[0]
        row = self.requested("Standard")
        self.assertEqual(row["memberEmail"], "standard@gunnaire.com")
        self.assertEqual(self.enroll("Standard", memberEmail="admin@gunnaire.com")[0][0], 400)

    def test_listing_is_bounded_scoped_and_cursor_stable_for_retained_history(self):
        self.prepare()
        first = self.requested()
        self.advance(first, "revoke")
        with backend.db() as connection:
            row = dict(connection.execute("SELECT * FROM cloudkit_staff_shares").fetchone())
            keys = list(row)
            for number in range(52):
                values = {**row, "id": str(uuid.uuid4()), "zone_name": "ga-staff-test-" + str(number)}
                connection.execute("INSERT INTO cloudkit_staff_shares (" + ",".join(keys) + ") VALUES (" + ",".join("?" for _ in keys) + ")",
                                   [values[key] for key in keys])
        status, page1 = self.read()
        self.assertEqual(status, 200)
        self.assertEqual(len(page1["shares"]), 50)
        self.assertIsNotNone(page1["nextCursor"])
        page2 = self.read(after=page1["nextCursor"])[1]
        self.assertEqual(len(page2["shares"]), 3)
        self.assertIsNone(page2["nextCursor"])
        self.assertFalse({r["id"] for r in page1["shares"]} & {r["id"] for r in page2["shares"]})
        self.assertEqual(self.read("Dispatcher")[1]["shares"], [])
        self.assertEqual(self.read(after="bad")[0], 400)

    def test_queries_and_paths_do_not_allow_duplicate_or_ignored_authority_parameters(self):
        self.prepare()
        row = self.requested()
        for query in ("companyID=" + self.company + "&companyID=" + self.company + "&environment=development",
                      "companyID=" + self.company + "&environment=development&memberEmail=admin@gunnaire.com",
                      "companyID=" + self.company + "&environment=development&after=", ""):
            self.assertEqual(self.request(token=self.tokens["Admin"], path=self.root + "?" + query)[0], 400)
        for suffix in ("//approve", "/" + row["id"] + "/approve/extra", "/" + row["id"] + "/unknown"):
            self.assertIn(self.request(token=self.tokens["Admin"], path=self.root + suffix, method="POST", payload={})[0], (400, 404))
        self.assertEqual(self.read(identifier=row["id"], after=str(uuid.uuid4()))[0], 400)

    def test_sharing_request_identifiers_and_queries_are_redacted_from_http_logs(self):
        self.prepare()
        with mock.patch("sys.stdout", new_callable=io.StringIO) as output:
            (_, row), _ = self.enroll()
            self.read(identifier=row["id"])
        log = output.getvalue()
        self.assertIn("/api/workspace/staff-shares/[redacted]", log)
        self.assertNotIn(row["id"], log)
        self.assertNotIn(self.company, log)

    def participant(self, row, role="Admin"):
        return self.request(token=self.tokens[role], path=self.root + "/" + row["id"] + "/participant?" +
                            urllib.parse.urlencode({"companyID": self.company, "environment": "development"}))

    def test_participant_locator_is_encrypted_scoped_and_not_in_roster_responses(self):
        self.prepare()
        row = self.requested()
        self.assertTrue(row["participantIdentityAvailable"])
        self.assertNotIn(self.participant_name, json.dumps(row))
        self.assertNotIn(self.participant_name, json.dumps(self.read()[1]))
        with backend.db() as connection:
            stored = connection.execute("SELECT * FROM cloudkit_staff_shares WHERE id=?", (row["id"],)).fetchone()
            self.assertNotIn(self.participant_name, json.dumps(dict(stored)))
            decoded = json.loads(self.cipher.decrypt(stored["participant_identity_ciphertext"].encode()))
        self.assertEqual(decoded["id"], row["id"])
        self.assertEqual(decoded["recordName"], self.participant_name)
        status, identity = self.participant(row)
        self.assertEqual(status, 200)
        self.assertEqual(identity["recordName"], self.participant_name)
        self.assertEqual(identity["participantAccountHash"], row["participantAccountHash"])
        self.assertEqual(identity["revision"], row["revision"])
        for role in self.tokens:
            if role != "Admin":
                self.assertEqual(self.participant(row, role)[0], 403)

    def test_locator_requires_fresh_admin_and_current_member_authority(self):
        self.prepare()
        row = self.requested()
        with backend.db() as connection:
            connection.execute("UPDATE auth_sessions SET created_at=? WHERE email='admin@gunnaire.com'",
                               ((datetime.now(timezone.utc) - timedelta(seconds=601)).isoformat(),))
        self.assertEqual(self.participant(row)[0], 403)
        self.tokens["Admin"] = backend.create_app_session("admin@gunnaire.com", "google", "fresh-admin")[0]
        with backend.db() as connection:
            connection.execute("UPDATE users SET role='Standard',updated_at=? WHERE email='field.technician@gunnaire.com'", (backend.utc_now(),))
        self.assertEqual(self.participant(row)[0], 409)

    def test_locator_rejects_wrong_hash_record_name_and_foreign_encrypted_identity(self):
        self.prepare()
        for name in (None, "", "_foreign-record", "x" * 256, "_fixture-staff-record\n"):
            self.assertEqual(self.enroll(participantRecordName=name)[0][0], 400)
        row = self.requested()
        with backend.db() as connection:
            stored = connection.execute("SELECT participant_identity_ciphertext FROM cloudkit_staff_shares WHERE id=?", (row["id"],)).fetchone()[0]
            data = json.loads(self.cipher.decrypt(stored.encode()))
            data["id"] = str(uuid.uuid4())
            connection.execute("UPDATE cloudkit_staff_shares SET participant_identity_ciphertext=? WHERE id=?",
                               (self.cipher.encrypt(json.dumps(data).encode()).decode(), row["id"]))
        self.assertEqual(self.participant(row)[0], 503)
        self.assertEqual(self.change(row, "approve")[0][0], 503)

    def test_owner_authority_checks_fresh_admin_even_for_revoked_cleanup(self):
        self.prepare()
        row = self.advance(self.advance(self.requested(), "approve"), "revoke")
        path = self.root + "/" + row["id"] + "/owner-authority?" + urllib.parse.urlencode({"companyID": self.company, "environment": "development"})
        self.assertEqual(self.request(token=self.tokens["Admin"], path=path)[0], 200)
        self.assertTrue(self.request(token=self.tokens["Admin"], path=path)[1]["cloudKitRevocationRequired"])
        for role in self.tokens:
            if role != "Admin":
                self.assertEqual(self.request(token=self.tokens[role], path=path)[0], 403)
        with backend.db() as connection:
            connection.execute("UPDATE auth_sessions SET created_at=? WHERE email='admin@gunnaire.com'", ((datetime.now(timezone.utc) - timedelta(seconds=601)).isoformat(),))
        self.assertEqual(self.request(token=self.tokens["Admin"], path=path)[0], 403)
        self.assertEqual(self.read("Admin", identifier=row["id"])[0], 200)

    def test_corrupt_ciphertext_is_retained_and_never_exposed_or_approved(self):
        self.prepare()
        row = self.requested()
        with backend.db() as connection:
            connection.execute("UPDATE cloudkit_staff_shares SET participant_identity_ciphertext=? WHERE id=?", ("corrupted-ciphertext", row["id"]))
        status, body = self.participant(row)
        self.assertEqual(status, 503)
        self.assertNotIn("corrupted-ciphertext", json.dumps(body))
        self.assertEqual(self.change(row, "approve")[0][0], 503)
        self.assertEqual(self.read(identifier=row["id"])[1]["state"], "requested")
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT participant_identity_ciphertext FROM cloudkit_staff_shares WHERE id=?", (row["id"],)).fetchone()[0], "corrupted-ciphertext")

    def test_missing_encryption_and_failed_identity_audit_do_not_save_or_disclose(self):
        self.prepare()
        with mock.patch.object(backend, "encrypt_catalog_payload", side_effect=RuntimeError("missing-key")):
            self.assertEqual(self.enroll()[0][0], 503)
        self.assertEqual(self.read()[1]["shares"], [])
        row = self.requested()
        with mock.patch.object(backend, "record_audit_event", side_effect=sqlite3.OperationalError("failed")):
            status, body = self.participant(row)
        self.assertEqual(status, 503)
        self.assertNotIn(self.participant_name, json.dumps(body))

    def test_old_hash_only_enrollment_is_retained_but_not_silently_invited(self):
        self.prepare()
        payload = {"companyID": self.company, "environment": "development", "operationID": str(uuid.uuid4()), "participantAccountHash": self.participant_hash}
        status, row = self.request(token=self.tokens["Field Technician"], payload=payload, method="POST", path=self.root)
        self.assertEqual(status, 200)
        self.assertFalse(row["participantIdentityAvailable"])
        self.assertEqual(self.change(row, "approve")[0][1]["code"], "identity_required")
        self.assertEqual(self.participant(row)[1]["code"], "identity_required")
        self.assertEqual(self.enroll(operationID=row["id"])[0][1]["code"], "operation_changed")
        self.advance(row, "revoke", "Field Technician")
        self.assertTrue(self.requested()["participantIdentityAvailable"])


if __name__ == "__main__":
    unittest.main()
