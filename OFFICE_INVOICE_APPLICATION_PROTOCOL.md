# Office invoice application protocol — 2026-09-11

## Delivered boundary

Backend candidate `2026.09.10.63` adds explicit office-reviewed application
proposals for the original staff invoice-line requests. This is a server
prerequisite for the native office workflow, not a completed invoice/QBO UI or
production deployment. The full application goal remains ACTIVE.

The existing staff composer and immutable recorded-only receipts remain
unchanged. Preparing a proposal changes only its encrypted recovery claim and
audit entry. It does not write invoice/item source records, SwiftData, CloudKit,
inventory movements, tax calculations, customer approval, payments or QBO.

## Contract and authority

Schema: `staff-owner-invoice-application-v1`.

| Route | Request | Result |
| --- | --- | --- |
| `GET /api/workspace/invoice-applications/{commandID}` | Exact `companyID`, `environment`, `replicaID` query | Original proposal and receipt, or an explicit null application; the original staff request must exist. |
| `POST /api/workspace/invoice-applications/{commandID}/prepare` | Scope, schema, original command/operation/owner-store IDs, unchanged original request, complete expected invoice, approved invoice fields, optional complete new-item fields, reviewed dependencies, `reviewed: true`, reason | Immutable exclusive claim and receipt; exact retries recover the same claim. |
| `POST /api/workspace/invoice-applications/{commandID}/confirm` | Exact scope, schema, command/operation/owner-store IDs | Published-to-owner-source receipt, only after both exact approved invoice and any new item are observed. |

Every route requires a current application session and the existing Admin/owner
workspace authorization. Technician, Accounting, Dispatcher, Standard and
legacy static-token access is rejected. Business, environment and replica are
checked server-side. A changed account, device/store, operation or proposal
cannot replace an existing claim. Staff revocation prevents staff replay but
does not delete the original author-attributed request or bar authorized office
review of it.

No route permits extra path components, query fields, duplicate query keys,
unknown JSON fields, duplicate JSON keys or numeric substitutes for booleans.
POST bodies are limited to 7 MiB; the existing bounded-body policy returns 400
before reading an oversized declared body. Nested catalog evidence remains
limited by its existing 1 MiB/domain-validation rules. Replies contain a full
proposal plus receipt; native recovery must allow bounded envelope overhead.
The SHA-256 field identifies the retained server proposal; native clients must
also validate the returned original proposal instead of assuming Swift and
Python encode JSON numbers identically.

## Financial and operational checks

- Customer, job, service location, payment state, accounting identity and all
  unrelated invoice fields/lines remain unchanged. Paid, partial, finalized and
  milestone/progress invoices require their separate correction workflow.
- Exactly the requested sold quantity is added; unrelated existing quantities
  are retained. Existing nonzero manual balances cannot disappear during
  conversion to catalog lines. Requested serviced equipment stays associated.
- Original catalog snapshots, bundle members, itemized package recipes,
  historical dependencies, discounts and tax-address evidence are validated by
  the existing billing domain. A complete itemized package uses one consistent
  recipe and every included component quantity. An older flat-rate root is
  retained unchanged instead of charging that root again with the components.
  Group totals use actual member prices, not a zero header price.
- Changes clear stale customer signatures and tax amounts/calculation dates.
  Taxable work remains pending tax calculation. QBO-linked invoices are marked
  `balance_needs_refresh`; unlinked invoices remain `pending`, never synced.
- New Service/NonInventory items retain the original requested identity and
  attributes, staff author, current office approver/time, approved pricebook
  state and pending QBO status. They cannot inherit another item's provider
  IDs/receipts or fabricate inventory tracking. Existing new-item IDs are not
  silently adopted by a fresh claim.

## Recovery, audit and rollout

One prepared claim per invoice and unique operation IDs serialize retries.
Preparation checks current source invoice/dependency revisions. The complete
proposal is encrypted; metadata contains routing identities, not line content.
Encryption and audit writes share one database transaction. A lost response
can be recovered without creating another operation. Partial invoice/item
publication cannot produce a success receipt. Repeated confirmation returns
the original historical receipt without reapplying later office changes.

`published` means **the approved records reached the owner source**, not CloudKit
participant convergence or QBO success. `qboPublished` remains literal `false`.
Corrupt saved claims fail closed, retain their original bytes and return a
generic recovery error. Request identities are redacted from HTTP logs.

The additive SQLite table/index retain recovery history without silent eviction.
New claims stop at 64 MiB of encrypted history per business/environment/replica;
existing reads and exact retries remain available. Archival requires a separate
coordinated workflow. Preserve the database, WAL-consistent backup and existing
encryption-key recovery procedure before any separately approved deployment.
Rollback must retain this table and pending proposals; an old server cannot
complete new native applications and must not trigger a legacy write fallback.

## Verification

Evidence directory:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/Office Invoice Applications.AKETB9`.

- Earlier focused runs passed 3, 17, 24 and 30 cases. The 28-case run exposed a
  test that continued transmitting after the server rejected an oversized
  Content-Length and expected 413 instead of the existing 400 policy. The test
  now sends headers only and verifies early rejection; the body-limit policy
  was not relaxed.
- The first two package tests exposed a fixture missing `schemaVersion` in its
  assembly definition. Correcting the fixture yielded 32 passing cases.
- Final focused run (`focused7.log`): 35 passed on Python 3.9.6, no failures or
  skips. Coverage includes real loopback HTTP, authorization/scope, concurrent
  prepare/confirm, encrypted restart/replay, partial source saves, dependency
  conflicts, storage/audit failures, history capacity, bounds, money/equipment,
  multi-part packages and corrupt/numeric-substituted receipts.
- Full backend Python 3.12.14: 1,165 passed in 277.620 seconds; local QA report
  `/Users/gunnaire/Documents/GunnAireLocalQA/runs/backend-swdf8_6q/report.json`.
- Full backend Python 3.9.6: 1,165 passed in 278.532 seconds
  (`backend-python39.log`). Both full runs exited 0 with no failures or skips.
- Standalone/direct backend import smoke check passed for `2026.09.10.63`
  with synthetic temporary storage and no running server/provider calls.
- Tool regression: 75 passed, exit 0 with no failures/skips; local QA report
  `/Users/gunnaire/Documents/GunnAireLocalQA/runs/tools-jwg8u41p/report.json`.
- Owner project post-copy check: 63 passed in 37.340 seconds, exit 0, no failures
  or skips (`owner-post-copy.log`); covers both original staff requests and the
  new application protocol. All five scoped files were byte-verified against
  validation. Owner branch, HEAD and index remain unchanged; unrelated owner
  edits were neither copied over nor staged.

The sibling sweep confirmed that existing staff request and command receipt
readers already compare canonical JSON. The new application reader now does
the same, rejecting numeric `0` in place of the required `false` without
rewriting damaged history.

## Still required for the actual user workflow

1. Native office request list/detail, explicit full-proposal review and a durable
   original-account/store journal. Reuse existing owner authority and clean
   ModelContext boundaries; do not import private owner records into staff stores.
2. Safe pre-write fencing, cancellation/decline and cross-device recovery or
   handoff. This protocol deliberately does not release a possibly-applied
   claim. A stale prepared claim must not be silently deleted or replaced.
3. Apply exact approved native invoice/item records, recover every interrupted
   local-save/source-publication boundary, then confirm this server receipt.
   Add a separate verified application status for staff; never relabel the
   immutable original recorded-only receipt as financial success.
4. Integrate the existing reviewed native QBO publication/reconciliation flow,
   including customer/item/account mappings, current tax and explicit provider
   approval. Confirm owner-source application before QBO item publication
   changes its provider fields. Avoid direct-provider fallback or new identities
   on retries. No Intuit endpoint or live accounting mutation changes here.
5. Resolve catalog-row identity limitations for repeated products at different
   prices or different serviced systems. Current top-level snapshots identify
   rows by catalog item; native planning must not silently combine incompatible
   historical sales or fake distinct catalog/QBO identities.
6. Qualify the complete iPad/Mac workflow, independent-account signed CloudKit
   convergence, provider acceptance and release requirements. Hidden unit tests
   cannot prove visual usability, physical Handoff or production readiness.

No Swift/UI changes or fresh native-build qualification are claimed by this
backend slice. No screenshots, screen reading, foreground activity, UI tests,
physical installs, browser changes, provider writes, customer communications,
deployment, push/merge, signing changes or NAS/recovery-key access occurred.
Tests use synthetic temporary data and stripped provider environment. No local
LLM inference is needed for deterministic test execution; no Stable Diffusion
or app LLM configuration was added.

The API, identity, offline, HVAC, pricebook and payments/QBO skills shaped the
explicit approval, original-evidence and retained-recovery boundary. Audit:
`/Users/gunnaire/.codex/skill-audits/skill-usage.jsonl`, task
`Complete and qualify office invoice application protocol`. Broader native
office/QBO integration and the full application goal remain active.
