# Google Calendar schedule workflow — 2026-09-07

Status: source implementation and final local fixture acceptance passed.
The new PR head requires its own hosted checks. This is not a production
deployment or proof of signed-device / live Google acceptance.

Published source: `6f56db0`. Workflow commit `b1ad814` adds the exact-target
schedule deletion/billed-job retention journey to the existing six hosted UI
journeys on [PR #18](https://github.com/Autbellum/GunnAire-Ops/pull/18).
The fetched GitHub workflow matches the locally linted one-line change.
No merge or deployment is part of this checkpoint.

## Findings corrected

The prior active export path fetched nearby events and imported them before
publishing a saved appointment. Import could overwrite the new schedule and
clear its local-edit marker before the patch decision. Matching also fell back
from calendar/event identity to an unscoped event ID, title/location/time, or
a sole matching time slot. Different calendars or appointments could therefore
be collapsed or linked without identity evidence.

Individual Google requests already retained provider identity, but a later
callback could start the next request with a new capture. The separate Schedule
delete handler removed the local job before fetching/deleting Google and did not
retain a shared operation or use a conditional version check. Import and several
delete/save paths ignored persistence failures.

## Implemented boundary

- All active calendar import, job publication, cancellation and managed-event
  removal paths share one captured company/provider operation. Capture occurs
  before scheduling a Task. Pagination, sequential calendar reads, token refresh,
  callbacks, model checks and saves use the original identity.
- Current known dispatcher/admin authority requires both the verified workspace
  role and matching, active local user records. The primary-administrator email
  alone is insufficient. Model/context identity, related schedule/customer/
  technician revisions and cancellation are checked across async resumptions.
  One operation per model container runs at a time.
- The actual primary calendar is enumerated once. A selected unavailable or
  read-only calendar does not fall back to another calendar. Provider path
  identifiers are encoded as single components. Production Calendar write
  wrappers require the captured workflow; patch/delete also require a version.
- Import uses the exact calendar ID plus case-sensitive event ID. Duplicate
  remote identities and duplicate local links stop before partial import.
  Names/titles/times never establish a job identity; duplicate customer emails
  are not resolved by picking the first record. Shared calendars do not invent
  technician records.
- App-owned or operationally linked jobs, unsent local edits and non-scheduled
  work are retained during import. Changes requiring review are counted in the
  existing Schedule status. Only new events and unassigned calendar shells are
  imported/refreshed; customer contact/address records are not overwritten.
  Do Not Service holds remain in office review.
- Publication reads the exact linked event, not a time-window guess. It verifies
  provider ID, app-ownership markers, any local-job marker, and exact schedule.
  A fresh ETag is sent in If-Match for schedule-only patch/delete. An HTTP 412
  surfaces review and does not trigger an automatic overwrite/retry.
- New creates use a bounded UUID-derived Google event ID, with a private local
  service-call marker. The exact calendar and ID are saved on the ServiceCall
  before POST. A lost create response can be recovered by reading that same
  identity. A previously reserved/linked ID that returns 404 is not sent again
  as a new create. A save failure before reservation prevents POST.
- Managed removal retains the local entry until provider read/delete finishes.
  After a lost delete response, absence at the same verified calendar/ID can
  finish the explicitly requested local removal without another DELETE; the
  message says the event was not returned, rather than inventing a receipt.
- Removal refuses jobs with billing, time, files, stock, purchase orders, forms,
  expenses, communications, tasks, converted requests, activity, agreements or
  follow-up lineage. These use the existing Cancel Job workflow instead.
  This evidence is rechecked before each provider hop and local deletion.
- Import restores only its own changed/inserted records on save failure.
  Local deletion allows its narrow rollback only when the context has no
  preexisting unsaved changes and there is no await during delete/save.
- The confirmation dialog retains its presented target through dismissal.
  The existing Schedule page shows a single actionable status, not a new
  dashboard. The evergreen technical permission reminder was removed.
  The Google badge means a retained link, not a verified-sync checkmark.

## Verification

Final exact-source acceptance on 2026-09-07:

- Mac Catalyst: **998/998 logic tests pass**, no failures or skips.
- M5 13-inch iPad Pro Simulator, iOS 26.2: **998/998 logic tests and 7/7
  selected UI journeys pass**, no failures or skips.
- Backend: **173/173 pass**. Tools: **37/37 pass**.
- The new calendar workflow suite contains **45 tests** using the actual
  coordinator and Google request handlers with fixture transports. The nine
  existing Google request-handler tests also remain green in both aggregates.
- Final unsigned optimized Mac Release: **BUILD SUCCEEDED**, with arm64 and
  x86_64 verified by `lipo -verify_arch`. Only the existing external
  Metal-toolchain search-path linker warning remains. Executable SHA-256:
  `7951d58671bf50c908e895ab116b6f7d3fdd540bbefede665d8920484a28c79e`.

The seven local UI journeys cover administrator and technician scheduling
authority, catalog recovery, Invoice launch, simple Mail, schedule-to-billing
handoff, and exact-target deletion with billed-job retention. This local
selection is not the same as the hosted workflow's selected journeys.

The final retained iPad screenshot was visually inspected: the billed service
job remains, the unobstructed status explains using Cancel Job to preserve its
records, the customer/job actions remain readable, and no email footer appears.
The view is scrolled; this screenshot is not a full accessibility or UI audit.

Final result bundles, logs and screenshot are retained locally under
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/Google Calendar Workflow/`:

- `Mac Acceptance.xcresult` and `gunnaire-calendar-workflow-mac-final-20260907.log`
- `iPad Acceptance.xcresult` and `gunnaire-calendar-workflow-ipad-final-20260907.log`
- `gunnaire-calendar-backend-20260907.log` and `gunnaire-calendar-tools-20260907.log`
- `gunnaire-calendar-workflow-release-final-20260907.log`
- `Schedule Review iPad.png`

The unchanged project manifest SHA-256 is
`52ecaabdb59c9d554d286f448a121eecd5a319afd6961bd9de62c3c075b315f7`.
The preceding published head `455ac33` passes all four hosted jobs:
[native](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34108280415) and
[backend](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34108280424).
Those results do not establish hosted acceptance of this calendar checkpoint.

### Intermediate iterations

Initial actual Google request-handler regression: 9/9 pass. Initial new workflow
regression: 33/33 pass. Expanded Mac focused regression: 52/52 pass (43 calendar
workflow tests plus 9 existing Google request tests). Mac full logic at that
intermediate source: 996/996 pass.

The first iPad UI test found no Cancel button in the confirmation popover.
The retained hierarchy exposes a PopoverDismissRegion and only the destructive
button inside the sheet. The test now dismisses through that region, verifies
the entry remains, confirms deletion on the second opening, and verifies a
billed job is retained. That exact journey passes 1/1 after the correction.
This was a test interaction mismatch, not an app crash; no test was skipped.

Initial compile iterations caught a wrong alert property, omitted ServiceCall
type, fixture initializer ordering and a throwing Testing-macro expression.
They were corrected before acceptance; failed iterations are not counted as
passing results.

All Google/network/persistence-failure cases use isolated credentials, in-memory
stores and fixture transports. No live event, email, customer, invoice, payment,
provider credential, signing setting, entitlement or CloudKit schema changed.

## Remaining full-goal acceptance

This is not a shared-server calendar dispatch journal or a globally atomic
CloudKit/Google transaction. Independent devices can race before CloudKit
convergence. Original provider-principal/grant adoption, immutable persisted
proposal/state metadata, cross-device queue recovery, explicit reconciliation
of changed remote schedules, and comprehensive deleted/recurring-event incremental
sync remain open. The retained ID is not a complete durable outcome ledger.
Deletion tombstones and local-edit markers remain device-local metadata; their
legacy primary-calendar/account scoping needs migration and multi-device proof.

Current lease/local role checks do not replace per-action authoritative server
authorization. Old or modified clients and externally issued Google credentials
remain outside this native coordinator. Historical guessed links are not
automatically repaired or deleted.

Complete signed iPad/Mac CloudKit/offline convergence and restoration,
physical-iPhone Handoff and approved embedded Tap to Pay, remaining Google
mail/file orchestrations, server-owned accounting dispatch/settlement, supplier
onboarding, provider approval and distribution acceptance are still required.
The full business-suite goal remains open. Do not merge or deploy this checkpoint
without separate review and approval.

## Primary references

Read in Safari on 2026-09-07:

- [Google event resource and IDs](https://developers.google.com/workspace/calendar/api/v3/reference/events):
  custom IDs use the documented character set and are unique per calendar.
- [Google resource versions](https://developers.google.com/workspace/calendar/api/guides/version-resources):
  If-Match protects update/delete; a changed version produces HTTP 412.
  Inserts use custom resource identity rather than conditional modification.
- [Apple action sheets](https://developer.apple.com/design/human-interface-guidelines/action-sheets):
  destructive choices and device-specific presentation should be clear and
  tested in context. The retained iPad accessibility hierarchy, not a generic
  illustration, establishes the dismissal target used in this regression.
