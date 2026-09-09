# Shared business time publication — implementation checkpoint

Candidate backend: `2026.09.08.44`, September 8, 2026. This is server-side
groundwork for the native Time Clock migration, not a claim that migration or
payroll is complete. No live provider records were read or changed in testing.

## Accounting and office workflow

The local time entry remains the operational source of clock times, activity,
notes, job and source review. QBO is the accounting destination. A current
business-session Admin or Accounting user reviews the exact proposed entry;
the explicit confirm action records the server office approval and dispatch.
Client-supplied reviewer metadata is retained as source evidence, never treated
as proof that the server previously approved the entry. Only Admin can change
which existing Employee/Vendor represents a team member.

TimeActivity records worked time for an employee or vendor. Explicit posting
date and integer hours/minutes are supported, and service-item references must
identify Service items. Payroll compensation is a separate Workforce API
capability available to eligible partners. Creating a TimeActivity is not payroll
execution, payment, or proof of an invoice linkage. These boundaries were checked
against the rendered official reference in Safari on September 8, 2026.
[Intuit TimeActivity reference](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/timeactivity).

## Worker identity contract

`GET /api/time-worker-mappings?companyID=…&workerEmail=…` returns current server
company/realm/environment, protocol version 1, the public connection revision,
and the current mapping. It makes no provider read and requires office access.

Admin may use `GET /api/time-worker-mappings/candidate` with the same query plus
`kind` (`Employee` or `Vendor`) and `providerID`. It reads only that fixed QBO
resource and returns ID, display name, kind and reference revision. Tax identifiers,
compensation, home addresses and arbitrary provider data are not returned.

`POST /api/time-worker-mappings` accepts exactly: `companyID`, `realmID`,
`environment`, `workerEmail`, `connectionRevision`, `operationID`,
`expectedRevision`, `kind`, `providerID`, `referenceRevision`, `enabled`.
The stable operation ID, compare-and-set revision, active provider identity,
same-grant administrator authority and one-to-one worker assignment are verified.
Disabling preserves the exact original identity and works without a QBO read.
Replaying a save returns the current mapping, not an old success that could
replace a later disable. Reconnection requires explicit mapping re-review.
`usable` is stored authorization evidence; publication also re-reads the worker.

## Time publication contract

All routes require signed business application sessions; legacy API keys cannot
use them. Query/body fields are exact, duplicate JSON keys and non-finite numbers
are rejected, and route logging redacts entry/worker query identifiers.

| Route | Effect |
| --- | --- |
| `GET /api/time-publications?companyID=…&localEntryID=…` | Recover original local journal records even when QBO is disconnected; no provider request |
| `POST /api/time-publications` | Save immutable encrypted proposal and verify current references; never create QBO time |
| `POST /api/time-publications/{id}/confirm` | Explicit office approval; one durable transition into sending, then at most one create |
| `POST /api/time-publications/{id}/recover` | Read-only QBO reconciliation of the original attempt; never resend |
| `POST /api/time-publications/{id}/adopt` | Explicitly link one freshly reviewed legacy time record; never modify QBO |
| `POST /api/time-publications/{id}/cancel` | Cancel only an unsent reservation; works without QBO access |

Preparation accepts exactly `companyID`, `realmID`, `environment`,
`connectionRevision`, `localEntryID`, `workerEmail`, `mappingRevision`,
`entryRevision`, `clockIn`, `clockOut`, `timeZone`, `payableMinutes`, `activity`,
`notes`, `serviceCallID`, `localCustomerID`, `localItemID`, `reviewedByEmail`,
`reviewedAt`. The last three local-reference fields are present and nullable.
Job labor requires its job and customer. Customer and optional service-item IDs
are derived from server-scoped mappings, not accepted as raw device QBO IDs.
The shared job/customer context and its revision must match. Historical office
time does not require a currently enabled field-billing assignment.

All timestamps carry UTC offsets. Elapsed minutes use positive half-up rounding
consistent with the app, including daylight-saving transitions. Posting date is
frozen in the original IANA time zone. `tzdata` is declared so a host without an
OS zone database can still resolve that zone; Python documents this first-party
fallback. [Python zoneinfo data sources](https://docs.python.org/3/library/zoneinfo.html#data-sources).

Confirm sends `companyID`, `entryRevision`, `reviewHash`. The immutable proposal
expires for sending after 15 minutes and is bound to its original office reviewer
and grant. Adoption adds `providerID`, `candidateRevision`. Cancellation sends
`companyID`, `reviewHash`; recovery sends an empty object. State, source review,
worker display identity, frozen accounting values and the original receipt are
returned. A confirmed receipt is historical evidence, not a current QBO snapshot.

## Durable recovery invariants

- States are reserved, sending, unknown, confirmed and cancelled. Only reserved
  may transition into sending. There is no transition back into reserved.
- A company/local-entry identity has one noncancelled proposal across realms and
  environments. Uncertain or confirmed time cannot be re-created by changing
  its notes, duration, connection, device or operation ID.
- A lost provider reply, authorization change after sending or failed receipt
  storage retains unknown state. Read recovery may confirm the original markers
  and exact time values, but an empty result never permits another create.
- Read recovery pins the current grant for the entire read and uses the original
  realm, values and worker, even after reconnection or later mapping revocation.
  Another currently authorized office user may recover an old result; only the
  original reviewer may send a reserved proposal.
- Duplicate/partial/conflicting markers and mismatched duration, date, worker or
  job references block new sends. New publication markers also require the
  original description. A single matching legacy record needs explicit adoption
  using freshly revalidated candidate evidence; it is not automatically linked.
- References and authorization are rechecked around provider suspensions and the
  atomic dispatch claim. Provider transport is fixed-origin, no-redirect,
  bounded, strict-JSON, and has no automatic retries or arbitrary query proxy.
- All database additions are additive. Existing time records, CloudKit schemas,
  signing, deployments and workflow permissions are unchanged.

## Verification and remaining acceptance

Evidence directory:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-08/Shared Time.wAcPHq`.

The 102 focused tests pass: 41 worker identity/transport cases and 61 publication,
HTTP and provider cases. The complete backend suite passes 766 tests with zero
failures. All 56 Tools tests pass; both existing GitHub workflows pass actionlint.
The initial publication run exposed two fixture references to a nonexistent
connection column; fixtures were corrected to the actual `authorized_at` grant
field. No production access check or regression assertion was removed.
The focused and full final logs retain the actual results. A separate isolated
environment installed the canonical requirements including tzdata 2026.3 and
passed all 766 backend tests with `PYTHONTZPATH=''`, disabling OS time-zone lookup.
Both full runs used local Python 3.9.6; hosted Python 3.13/3.14 must qualify the
published source. The synthetic backup/restore drill verifies preservation of the
encrypted original intent, worker mapping and unknown state, followed by read-only
recovery with the create count still exactly one. Its initial fixture lacked the
empty storage directory expected by the existing backup utility; creating that
fixture directory corrected the drill without changing production backup logic.

Original-project preflight checks 12 scoped files, 273 unrelated changed files,
the original index and 307 other byte-identical tracked source files. Final
copy-back verifies all 12 scoped files match in GunnAire Ops while preserving
the original index and all 273 unrelated changes (`OriginalCopyBack.json`).
Native Swift, project settings and workflow selectors are unchanged. No local
native build was repeated for this backend-only checkpoint. Predecessor cbe1a74
completed hosted qualification successfully: backend Python 3.13/3.14, Mac and
both iPad groups passed (runs 34304939001 and 34304939008). This closes the
previous catalog-keyboard checkpoint's hosted gate, but does not qualify the new
backend source; its published commit needs fresh CI.

The following are **not completed by this checkpoint**:

1. Native worker-mapping review, approved-time preview, original encrypted device
   journal, and Time Clock cutover. The current view still uses device OAuth and
   callback-based publication. Do not enable dual writers. Native completion must
   pin original business/actor/access/entry revision across every suspension,
   persist unknown recovery across relaunch, and never apply a receipt to changed
   local time. All local technician mappings are untrusted setup suggestions until
   reviewed in the correct server company.
2. Payroll compensation and optional project mappings. Unsupported configured
   fields must be presented as setup work, not silently dropped by the native
   migration. This API deliberately rejects arbitrary payroll/project values.
3. Large-history reconciliation: the adapter currently checks up to 10,000 time
   records and fails closed at that ceiling. Incremental, durable indexed history
   and real-provider pagination/rate-limit acceptance remain necessary. External
   writers can change QBO during scans; single-send guarantees cover this journal,
   not arbitrary simultaneous third-party writers.
4. Native UI/accessibility journeys, iPad/Mac final-source qualification and a
   specifically approved sandbox create/recovery trial after the complete native
   integration exists. No physical installation or production accounting change
   is authorized by this checkpoint.
5. Full-suite goal requirements: independent-staff CloudKit sharing and signed
   convergence, remaining Google/QBO workflows, vendor partner onboarding, real
   approved Tap to Pay/Handoff and complete competitor-suite acceptance.

This service should be promoted only with an approved complete native workflow,
canonical dependencies, encryption, signed-session configuration and backups.
Rollback must retain all time/mapping tables and unknown/confirmed records; never
erase a journal to make an uncertain request appear sendable. Accounting owns
review of conflicting or externally changed time records.
