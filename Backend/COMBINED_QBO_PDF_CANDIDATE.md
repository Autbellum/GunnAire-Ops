# Backend-only QBO estimate and billing-PDF candidate

This draft starts at `release/2026100123` (`9c34f8b`). It includes only the
backend changes from PR #48 and PR #51. It does not include either PR's native
app changes, and it has not been deployed or used for a live provider write.

## Source and ordering

- PR #48 backend source: `14bea3f` (durable estimate job, atomic reservation,
  worker and synthetic tests), `3ccbb6d` (authority-change tests), and the
  backend files in `8549079` (native connection advertises
  `estimateQueueVersion: 1`). The later PR #48 changes are native or docs.
- PR #51 backend source: `8e3020d`, `baf93b4`, `b9cb900`, `7e53823`, and
  `d7b0a4c`. Only their `Backend/` paths are included. Both proposals edit
  `gunnaire_backend.py`; this candidate combines their imports, schema
  initialization, HTTP routes, QBO worker startup, PDF artifact handling and
  log redaction explicitly.
- The signed `0123` native app does not contain PR #48's automatic estimate
  queue or PR #51's automatic PDF caller. This backend can be deployed first,
  but it cannot by itself deliver either user-visible automatic workflow.

## Migration and safe rollout

Startup adds `billing_estimate_jobs` and its due index, referencing the
existing `billing_publications` table. It adds
`billing_pdf_archive_intents`; on a database with an earlier partial PDF
schema, it adds nullable `artifact_bytes` and default-false `artifact_ready`.
These are additive SQLite migrations. They do not backfill old estimates,
invent a QBO confirmation, or create a PDF archive reservation. PDF bytes live
under the existing persistent `STORAGE_ROOT`, so database-only backup is
insufficient after artifact writes begin.

Before a production rollout, identify the currently deployed Git SHA and
deployment ID independently of `/health`: the existing `2026.09.18.69`
`serviceVersion` is shared by multiple source branches. This candidate uses
`2026.10.02.1` so its eventual live health response can be distinguished,
but that marker alone still cannot prove the deployed Git SHA. Confirm the exact
database path and one authoritative persistent store. Capture a verified,
off-host backup of both SQLite and storage, then prove a restore drill against
that artifact. Run this candidate's database initializer against a copy of
the current production data, and require `PRAGMA quick_check` and
`PRAGMA foreign_key_check` to pass. Review any preexisting PDF rows with
multiple `(source_digest, renderer_version)` pairs for one
`(company_id, drive_account, document_kind, document_id)`; the new fence
intentionally blocks such rows pending manual reconciliation. Drain older PDF
writers before enabling the new reservation route, because older code does
not enforce the cross-revision fence.

Only after backend promotion and a verified compatible route may a new native
estimate build use `estimateQueueVersion: 1`. Check authenticated readiness,
one synthetic or approved sandbox exact-proposal enqueue/status/recovery,
and the QBO worker's durable state before any production accounting action.
Test PDF reserve, artifact, Drive readback and conflict refusal with an
approved non-customer fixture. Provider acceptance, physical-device
background scheduling and closed-app first preparation require separate
evidence. No QBO or Google credential is required by the synthetic tests.

## Rollback boundary

Do not restore an older database or delete a `sending`/`unknown` QBO
publication to make retry possible. An older code deploy may stop the new
worker and routes, but it must preserve both new tables and retained PDF
artifacts. If jobs or PDF reservations have been accepted, suspend new native
handoffs during rollback, retain their original IDs and evidence, and
reconcile on a reviewed forward deployment. A rollback to older PDF writers
is unsafe while they can create a second revision; disable them or keep the
new conflict fence in the running backend. Do not merge this draft into
`main`, which triggers Render, until the deployment owner approves that
separate promotion and its production migration evidence.

## Draft validation

On the combined source with marker `2026.10.02.1`, local backend discovery
passed 1,392/1,392 tests (`/private/tmp/GunnAire-0123-backend-qbo-pdf-full-r2.log`).
The unchanged Tools suite passed 94/94, and focused QBO estimate/PDF/backup
tests passed 93/93. A synthetic `release/2026100123` SQLite database was
opened by this candidate: both new tables and the estimate due index appeared,
`PRAGMA quick_check` returned `ok`, and `PRAGMA foreign_key_check` returned no
rows. This is not a migration test against a copy of live production data.
The individual PR #48 and #51 Python 3.13/3.14 GitHub checks passed; this
combined branch requires its own exact-head CI checks before promotion.
