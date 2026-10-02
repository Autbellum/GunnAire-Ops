"""Durable, estimate-only QBO publication jobs.

The billing publication row, not this job, is the provider-write fence. A job
never changes a sending/unknown publication back to reserved. Restarted work
can only reconcile that original attempt through BillingPublisher.run.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone

try:
    from Backend.billing_publications import failure, validated_request, catalog_identifiers
    from Backend.payment_attempts import AttemptError, canonical_uuid
except ModuleNotFoundError:
    from billing_publications import failure, validated_request, catalog_identifiers
    from payment_attempts import AttemptError, canonical_uuid


SCHEMA = """
CREATE TABLE IF NOT EXISTS billing_estimate_jobs (
 publication_id TEXT PRIMARY KEY REFERENCES billing_publications(id),
 session_id TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('pending','running','confirmed','review')),
 attempts INTEGER NOT NULL DEFAULT 0,
 not_before TEXT NOT NULL,
 lease_id TEXT,
 lease_until TEXT,
 last_error_code TEXT,
 created_at TEXT NOT NULL,
 updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS billing_estimate_jobs_due
 ON billing_estimate_jobs(state,not_before,lease_until);
"""


def initialize_schema(connection):
    for statement in SCHEMA.split(";"):
        if statement.strip():
            connection.execute(statement)


class EstimateJobs:
    def __init__(self, database, publisher, *, now=None):
        self.database, self.publisher = database, publisher
        self.now = now or (lambda: datetime.now(timezone.utc))

    @staticmethod
    def public(row):
        return {"publicationID": row["publication_id"], "state": row["state"],
                "attempts": row["attempts"], "lastErrorCode": row["last_error_code"],
                "updatedAt": row["updated_at"]}

    def enqueue(self, session_id, payload):
        """Reserve and queue in the same transaction; return before QBO work."""
        intent = validated_request(payload)
        if intent["document_type"] != "Estimate" or intent["operation"] != "create":
            raise failure("invalid_action", "Only a saved original estimate can use background publication.", 400)
        if len(catalog_identifiers(intent["document"]["Line"])) > 20:
            raise failure("background_catalog_limit", "Review this estimate in the app; it has too many distinct sold items for background publication.")
        now = self.now().isoformat()

        def on_reserved(connection, row):
            if row["document_type"] != "Estimate" or row["operation"] != "create":
                raise failure("invalid_action", "Only a saved original estimate can use background publication.", 400)
            old = connection.execute("SELECT * FROM billing_estimate_jobs WHERE publication_id=?", (row["id"],)).fetchone()
            if old is None:
                connection.execute("""INSERT INTO billing_estimate_jobs
                    (publication_id,session_id,state,not_before,created_at,updated_at)
                    VALUES (?,?,?,?,?,?)""", (row["id"], session_id,
                    "confirmed" if row["state"] == "confirmed" else "pending", now, now, now))
            elif old["state"] == "pending":
                # Renew a valid caller without defeating the existing retry
                # delay; repeated app launches must not hammer QuickBooks.
                connection.execute("UPDATE billing_estimate_jobs SET session_id=?,updated_at=? WHERE publication_id=?",
                    (session_id, now, row["id"]))
            elif old["state"] == "review":
                # An explicitly repeated, currently authorized proposal may
                # restart reconciliation, always against the original fence.
                connection.execute("""UPDATE billing_estimate_jobs SET session_id=?,state='pending',attempts=0,
                    not_before=?,lease_id=NULL,lease_until=NULL,last_error_code=NULL,updated_at=?
                    WHERE publication_id=?""", (session_id, now, now, row["id"]))
            elif old["state"] == "running" and (old["lease_until"] is None or old["lease_until"] <= now):
                connection.execute("""UPDATE billing_estimate_jobs SET session_id=?,state='pending',
                    not_before=?,lease_id=NULL,lease_until=NULL,updated_at=? WHERE publication_id=?""",
                    (session_id, now, now, row["id"]))

        reserved = self.publisher.reserve(session_id, payload, on_reserved=on_reserved)
        return self.status(session_id, reserved["id"])

    def status(self, session_id, identifier):
        identifier = canonical_uuid(identifier)
        publication, _ = self.publisher.check(session_id, identifier)
        with self.database() as connection:
            row = connection.execute("SELECT * FROM billing_estimate_jobs WHERE publication_id=?", (identifier,)).fetchone()
            if row is None:
                raise failure("not_found", "The original estimate job was not found.", 404)
            return {"publication": self.publisher.public(publication), "background": self.public(row)}

    def claim_one(self):
        now = self.now()
        stamp = now.isoformat()
        lease_id = str(uuid.uuid4())
        with self.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute("""SELECT * FROM billing_estimate_jobs
                WHERE (state='pending' AND not_before<=?) OR (state='running' AND lease_until<=?)
                ORDER BY not_before,created_at,publication_id LIMIT 1""", (stamp, stamp)).fetchone()
            if row is None:
                return None
            connection.execute("""UPDATE billing_estimate_jobs SET state='running',attempts=attempts+1,
                lease_id=?,lease_until=?,updated_at=? WHERE publication_id=?""",
                (lease_id, (now + timedelta(hours=1)).isoformat(), stamp, row["publication_id"]))
            return {"publication_id": row["publication_id"], "session_id": row["session_id"],
                    "lease_id": lease_id, "attempts": row["attempts"] + 1}

    def finish(self, job, *, confirmed=False, error_code=None):
        now = self.now()
        if confirmed:
            state, next_run = "confirmed", now
        else:
            retryable = error_code in {"provider_unavailable", "provider_unconfirmed",
                "documents_incomplete", "storage_unavailable"}
            state = "pending" if retryable and job["attempts"] < 8 else "review"
            next_run = now + timedelta(minutes=min(60, 5 * (2 ** min(job["attempts"] - 1, 4))))
        with self.database() as connection:
            return connection.execute("""UPDATE billing_estimate_jobs SET state=?,not_before=?,
                lease_id=NULL,lease_until=NULL,last_error_code=?,updated_at=?
                WHERE publication_id=? AND state='running' AND lease_id=?""",
                (state, next_run.isoformat(), error_code, now.isoformat(),
                 job["publication_id"], job["lease_id"])).rowcount == 1

    def run_one(self):
        job = self.claim_one()
        if job is None:
            return False
        try:
            result = self.publisher.run(job["session_id"], job["publication_id"], allow_send=True)
            if result["publication"]["state"] != "confirmed":
                raise failure("provider_unconfirmed", "The original estimate remains unconfirmed.")
        except AttemptError as error:
            self.finish(job, error_code=error.code)
        except Exception:
            # A crash/lost response never resets the billing publication fence.
            self.finish(job, error_code="worker_unavailable")
            raise
        else:
            self.finish(job, confirmed=True)
        return True
