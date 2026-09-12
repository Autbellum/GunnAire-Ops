import json
import unittest
import urllib.parse
import uuid

from Backend import gunnaire_backend as backend, staff_owner_field_resolutions as resolutions
from Backend import test_staff_owner_field_edits as owner_tests


class StaffFieldUpdatesHTTPTests(unittest.TestCase):
    def setUp(self):
        self.f = owner_tests.OwnerFieldEditHTTPTests()
        self.f.setUp()
        self.addCleanup(self.f.doCleanups)
        self.root = self.f.f.root + "/" + self.f.f.share["id"] + "/field-updates"

    def read(self, command=None, role="Field Technician", **query):
        path = self.root + ("/" + command if command is not None else "")
        return self.f.f.request(token=self.f.f.tokens[role], path=path + "?" +
            urllib.parse.urlencode(dict(self.f.f.scope, **query)))

    def keep(self):
        entry = self.f.get(self.f.id)[1]
        claim = entry["application"]
        body = dict(**self.f.f.scope, schema=resolutions.SCHEMA, commandID=self.f.id,
            operationID=str(uuid.uuid4()), ownerStoreID=self.f.owner_store,
            claimOperationID=claim["operationID"] if claim else "", expectedRevision=entry["current"]["revision"],
            expectedValue=entry["current"]["value"])
        self.assertEqual(self.f.post("keep-office", body)[0], 200)

    def test_original_receipt_survives_waiting_prepared_and_published_outcomes(self):
        waiting = self.read(self.f.id)
        self.assertEqual(waiting[0], 200, waiting)
        entry = waiting[1]["entries"][0]
        self.assertEqual(entry, dict(request=self.f.command, receipt=self.f.receipt,
                                    state="awaitingOffice", decidedAt=""))
        claim = self.f.prepare_body()
        self.assertEqual(self.f.post("prepare", claim)[0], 200)
        self.assertEqual(self.read(self.f.id), waiting, "Prepared is not applied")
        self.f.advance_job(self.f.command["value"]["text"]["_0"])
        self.assertEqual(self.read(self.f.id), waiting, "Source write alone is not a confirmed application")
        published = self.f.post("confirm", self.f.confirm_body(claim))[1]
        final = self.read(self.f.id)[1]["entries"][0]
        self.assertEqual(final["state"], "appliedToOffice")
        self.assertEqual(final["decidedAt"], published["publishedAt"])
        self.assertEqual(final["request"], self.f.command)
        self.assertEqual(final["receipt"], self.f.receipt)
        fixtures = owner_tests.command_tests.content_http.fixtures
        job = fixtures.row(self.f.f.records, "job")
        fixtures.set_value(job, "notes", "Subsequent office change is not exposed")
        self.f.f.write_source([job], 2, 2)
        self.assertEqual(self.read(self.f.id)[1]["entries"][0], final)

    def test_kept_office_only_discloses_decision_not_private_comparison_or_claim(self):
        claim = self.f.prepare_body()
        self.assertEqual(self.f.post("prepare", claim)[0], 200)
        self.f.advance_job("Private office value must never reach staff response")
        self.keep()
        status, page = self.read()
        self.assertEqual(status, 200, page)
        self.assertEqual(page["entries"][0]["state"], "keptOffice")
        encoded = json.dumps(page)
        for forbidden in ("Private office value", self.f.owner_store, claim["operationID"],
                          "expectedValue", "ownerEmail", "application", "baseValue", "current"):
            self.assertNotIn(forbidden, encoded)
        self.assertEqual(set(page), {"schema", "companyID", "environment", "replicaID", "shareID", "entries", "nextCursor"})
        self.assertEqual(set(page["entries"][0]), {"request", "receipt", "state", "decidedAt"})
        original = self.f.get(self.f.id)[1]
        for _ in range(2):
            self.assertEqual(self.read()[1], page)
        self.assertEqual(self.f.get(self.f.id)[1], original, "Reading cannot mutate original or office state")

    def test_admin_other_roles_missing_session_and_foreign_scope_cannot_read(self):
        for role in ("Admin", "Dispatcher", "Accounting", "Standard"):
            self.assertIn(self.read(role=role)[0], (403, 404), role)
            self.assertIn(self.read(self.f.id, role=role)[0], (403, 404), role)
        self.assertEqual(self.f.f.request(token=None, path=self.root + self.f.query)[0], 401)
        self.assertNotEqual(self.read(companyID=str(uuid.uuid4()))[0], 200)
        self.assertNotEqual(self.read(replicaID=str(uuid.uuid4()))[0], 200)
        self.assertNotEqual(self.read(environment="production")[0], 200)
        self.assertEqual(self.read(str(uuid.uuid4()))[0], 404)

    def test_revocation_inactive_member_and_changed_membership_deny_historical_outcomes(self):
        self.keep()
        with backend.db() as connection:
            connection.execute("UPDATE users SET is_active=0 WHERE email=?", (self.f.receipt["actorEmail"],))
        self.assertEqual(self.read()[0], 401)
        self.assertEqual(self.read(self.f.id)[0], 401)
        with backend.db() as connection:
            connection.execute("UPDATE users SET is_active=1 WHERE email=?", (self.f.receipt["actorEmail"],))
            connection.execute("UPDATE cloudkit_staff_shares SET member_revision=member_revision+1 WHERE id=?", (self.f.f.share["id"],))
        self.assertNotEqual(self.read()[0], 200)

    def test_bounded_history_discovers_originals_without_local_index_and_skips_no_ids(self):
        ids = [self.f.id]
        for _ in range(10):
            body = self.f.f.command_body()
            self.assertEqual(self.f.f.submit(body=body)[0], 200)
            ids.append(body["commandID"])
        first = self.read()[1]
        self.assertEqual(len(first["entries"]), 8)
        self.assertEqual(first["nextCursor"], first["entries"][-1]["request"]["commandID"])
        second = self.read(after=first["nextCursor"])[1]
        self.assertEqual(second["nextCursor"], "")
        seen = [e["request"]["commandID"] for e in first["entries"] + second["entries"]]
        self.assertEqual(seen, sorted(ids))
        self.assertEqual(self.read(after=seen[-1])[1]["entries"], [])

    def test_exact_paths_queries_and_read_only_method(self):
        for query in ({"after": ""}, {"after": "bad"}, {"unknown": ""}):
            self.assertEqual(self.read(**query)[0], 400)
        self.assertEqual(self.read(self.f.id, after=self.f.id)[0], 400)
        for suffix in ("/", "/" + self.f.id + "/", "/" + self.f.id.upper()):
            self.assertNotEqual(self.f.f.request(token=self.f.f.tokens["Field Technician"],
                path=self.root + suffix + self.f.query)[0], 200)
        self.assertEqual(self.f.f.request(token=self.f.f.tokens["Field Technician"],
            path=self.root + self.f.query + "&companyID=" + self.f.f.company)[0], 400)
        self.assertNotEqual(self.f.f.request(token=self.f.f.tokens["Field Technician"],
            path=self.root, method="POST", payload=self.f.command)[0], 200)

    def test_history_index_is_restart_safe_and_author_filtered(self):
        backend.initialize_database()
        with backend.db() as connection:
            index = connection.execute("PRAGMA index_info(staff_workspace_commands_author)").fetchall()
        self.assertEqual([row["name"] for row in index], ["share_id", "actor_email", "command_id"])
        self.assertEqual(self.read()[1]["entries"][0]["receipt"], self.f.receipt)

    def test_corrupt_original_claim_or_resolution_fails_closed_not_waiting_or_hidden(self):
        with backend.db() as connection:
            connection.execute("UPDATE staff_workspace_commands SET source_sequence=source_sequence+1 WHERE command_id=?", (self.f.id,))
        self.assertEqual(self.read()[0], 503)
        with backend.db() as connection:
            connection.execute("UPDATE staff_workspace_commands SET source_sequence=source_sequence-1 WHERE command_id=?", (self.f.id,))
        claim = self.f.prepare_body()
        self.assertEqual(self.f.post("prepare", claim)[0], 200)
        with backend.db() as connection:
            connection.execute("UPDATE staff_owner_field_edit_applications SET state='published' WHERE command_id=?", (self.f.id,))
        self.assertEqual(self.read(self.f.id)[0], 503)
        with backend.db() as connection:
            connection.execute("UPDATE staff_owner_field_edit_applications SET state='prepared' WHERE command_id=?", (self.f.id,))
        self.keep()
        with backend.db() as connection:
            connection.execute("UPDATE staff_owner_field_resolutions SET owner_store_id=? WHERE command_id=?", (str(uuid.uuid4()), self.f.id))
        self.assertEqual(self.read()[0], 503)
