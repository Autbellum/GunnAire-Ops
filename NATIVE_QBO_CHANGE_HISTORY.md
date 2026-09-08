# Native QuickBooks change-history consumption

September 8, 2026. Source checkpoint on PR #18; backend candidate
2026.09.08.34. This is not a deployment or completed application acceptance.

## Actual integration

The existing QuickBooks Management refresh now consumes the server's encrypted
census/CDC history for all thirteen accounting collections when the shared
backend is configured. QuickBooksSyncRun.receiveResource is the routing
boundary. It has no direct-provider fallback after a shared-history failure.
The existing account lists and six local-domain import arrays receive the
verified latest records; this is not an additional read-only diagnostics page.
The UI's existing refresh, cancellation, progress and return navigation remain.

The source still captures the original native QBO workflow at the user action,
so the current Management sign-in gate and device connection are still required.
Removing that device-credential dependency, moving stored payment methods and
all other operations to shared authority, and automatic background refresh
remain required. Fixture runs inject their own transports and never use the
production backend.

Intuit's current [CDC reference](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/changedatacapture)
was read in Safari on September 8. Full records, deleted records, the 30-day
window and the 1,000-object limit are provider rules. The native integrity and
projection rules below are application decisions, not additional Intuit
guarantees.

## Contract and interpretation

The existing capture endpoint adds:

- Optional connectionRevision on POST and GET, checked before any provider
  access or history read. Responses return the original opaque grant revision;
  it contains no bearer/refresh token. Ordinary token rotation does not change
  it, but a new authorization grant does.
- Optional GET captureRevision, which rejects a superseding collection capture.
  The fresh-state authorization check also rejects capture metadata changed
  during decryption.
- afterSequence and scoped versionCount, alongside the existing pinned
  throughSequence and nextAfterSequence.
- Per-version recordJSON containing the original canonical bytes and
  payloadSHA256. The existing record object remains for earlier readers.
  Response-size accounting includes both forms and JSON-string escaping.

The native client:

1. Captures company, realm, environment and the existing workspace/role/run
   lifetime. Every request uses the original application session. The bounded
   ephemeral HTTP receiver rejects redirects and caches no private responses.
2. Pins one server grant across collections and a capture revision, upper
   sequence, version count and baseline/capture metadata across each collection.
   Missing, repeated, wrong-scope, prematurely terminated or changed pages
   cannot produce a successful collection.
3. Verifies the original canonical digest, ID, status, full-record marker,
   SyncToken and timezone-aware provider time. It preserves microseconds and
   selects latest provider time, never latest arrival sequence. Unicode escapes
   and exponent spelling are verified without recreating Python JSON in Swift.
   Latest financial records also require finite reported totals and payment-line
   amounts. Missing or malformed evidence cannot invoke a legacy decoder's
   zero-amount default.
4. Keeps an explicit empty collection distinct from missing/incomplete history.
   Missing baselines, capture issues and unscoped legacy events require review.
   A latest tombstone or same-time conflicting payload stops the shared refresh,
   rather than masquerading as an empty collection or deleting local history.
5. Rechecks each completed collection using an empty pinned page. Before local
   import, all thirteen collections must have succeeded and their saved server
   revisions are revalidated again. Native role, company and run checks also
   surround the actual local import.

These checks do not make thirteen independent provider collections an atomic
financial snapshot, nor do they prove every event was applied to every device.
The server retains the complete observed versions; native projections use
transient memory and retain only small in-memory verification metadata afterward.
There is no raw-history UserDefaults cache or device cursor that could skip a
late version. Current limits are 16 MiB per wire page and 64 MiB/100,000 versions
per complete collection read; staged large-history transfers remain required.

## Pending field work and accounting events

The existing local import's explicit technician-review and staged-admin-price
guards remain. Catalog refresh must preserve unsent proposals, approval identity,
stock/location metadata and immutable sold-document prices. Updated provider
prices are for the current catalog, not a repricing of already sold invoices.

Management no longer invokes the generic all-ID webhook acknowledgement.
Successful reads can leave pending local edits and therefore cannot stand in
for individual application receipts. Existing server events remain pending.
The old server endpoint is retained for compatibility; it is not used by the
new native refresh.

This does **not** implement durable per-model provider-version receipts,
device-consumption cursors, CloudKit conflict ownership for this history,
deletion/merge/void/payment-reallocation application, or the associated natural
review/recovery actions. Those are the next actual synchronization requirements,
not completed features. The server's applicationState remains not_applied.

## Qualification and retained evidence

Evidence directory:
/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/Native QBO History.uYWA55/
(the directory retains the initiating release-date grouping).

The initial focused server run passes 43 tests. FocusedMac.xcresult is a
retained compiler failure: Xcode could not diagnose a conditional function-
reference expression. It was replaced with an explicit typed closure, without
changing the routing or validation rule. This failed result is not acceptance.
FocusedMac2 passes 38 logical tests (new history and existing lifecycle suites).
FullMac passes 1,292 logic tests before the additional financial-amount guard;
FinalMac passes **1,293 logic tests** with that guard. FinalIPad passes the same
1,293 logic tests plus four UI journeys. The first universal Mac Release builds
both architectures, but exposed a new actor-isolation warning when a stateless
reference validator was passed to Optional.map. Both pure string validators are
now explicitly nonisolated; no mutable actor state or access check is bypassed.
FrozenMac passes **1,293 logic tests** on that corrected source.

FrozenIPad passes **1,293 logic tests and all four selected UI journeys** on
the same corrected source: 1,297 logical tests / 1,358 parameter-expanded
executions, no failures or skips. The UI journeys cover Invoice launch, simple
Mail, existing-link selection/cancellation/return and offline invoice/estimate
creation inside Management. FrozenMac has 1,354 parameter-expanded executions,
also without failures or skips. Both use Xcode 26.6, the GunnAire Ops scheme,
serial testing and CODE_SIGNING_ALLOWED=NO; exact commands are in their logs.

FrozenUniversalMacRelease.xcresult succeeds, and lipo verifies arm64 and x86_64.
The new actor warning is gone; only the pre-existing external Metal-toolchain
linker search-path warning remains. The unsigned executable SHA-256 is
c801a666890f29e2c280d2cdd004d5f290396b0c92ffab2d8d607d3c8326148b.

The actual frozen iPad screenshots were inspected: selection is visible,
the review/cancellation status and Back control are clear, technical identifiers
remain behind disclosure, and there is no account-email footer. The retained
images are FrozenSelectionUI/CE3B35EA-4AC8-4AB7-8211-519DAE2541A2.png and
FrozenSelectionUI/E5EE81FC-C007-4B90-A0BD-ED275D07946E.png. This is fixture UI
qualification, not production-provider or physical-device acceptance.

The final backend source passes **493 tests** in Backend.log; Tools.log passes
**37 tests**. These include original grant/revision checks, real fixture HTTP
routes, wire-size accounting, encrypted persistence, concurrency and recovery.
The sixteen new native logical tests include parameterized malformed pages,
amounts, tombstones/conflicts and revoked/replaced sessions, actual thirteen-type
decoding/routing, no-fallback behavior, and an in-memory item import preserving
technician/admin proposals, inactive-item history, truck-stock metadata and a
real versioned sold-invoice snapshot. Test transports use fixture data only.

Current source SHA-256:

| Source | SHA-256 |
| --- | --- |
| QuickBooksChangeHistory.swift | 0b07996c704fa479b84cded3b4d9d5e86bcb9cc7186280eae0500e74ca524bfd |
| QuickBooksChangeHistoryTests.swift | c07ba118499fe5060f2818b4a54b355891c70c4ff4545096442a14eb36adc324 |
| QuickBooksSyncLifecycle.swift | e5942808b003d17cc447fef52b18916e55bf0d0a4e77b11d0fef51577043d932 |
| QuickBooksManagementView.swift | d1944926b70fb411bdf6adad3d383d8d456d389a73eac835502b83ecb86ab909 |
| GunnAireBackendService.swift | bbade7a6d2e64ece6bd398b27fadb8ef86bec5e5023d074a70473c7666f36bd5 |
| Backend/qbo_change_capture.py | 63a1d3e3e6bc4064c97b9a501120483169ae581476d8c0997c57a2663e0bd5f4 |
| Backend/gunnaire_backend.py | f01b4023a30dcf99c3dc22ecf838f1cd91bfcdb528ea814e21325597fa9c662b |
| Backend/test_qbo_change_capture.py | e538080e31206c64cdb2634863136bc070a6ce57f9f563fb993817cea3af4be5 |

The app manifest remains 52ecaabdb59c9d554d286f448a121eecd5a319afd6961bd9de62c3c075b315f7.
No model schema, entitlement, signing identity or shared scheme changed. The
original iCloud app, logic/UI-test and Backend trees match the reviewed copies
(excluding generated Python caches), with unrelated original Git changes kept.

## Rollout and full-goal boundary

Deploy and verify the matching backend contract before distributing this native
candidate. An older server cannot silently trigger direct-provider fallback.
Preserve the encrypted database and key in a verified backup. The server schema
is unchanged and new response fields are additive; source rollback must retain
the journal and pending events rather than remove captured business history.
No merge, deployment, live accounting call, email, payment, entitlement,
provisioning, CloudKit promotion or physical-device installation is authorized
by this source checkpoint.

Complete top-ten-suite feature acceptance, all required QBO entities and item
publication/reconciliation, staff/vendor onboarding, shared Google workflows,
CloudKit offline/multi-device acceptance, iPad/Mac UI qualification, physical
iPad-to-iPhone Handoff/Tap to Pay and App Store/provider release gates remain
part of the active full application goal.
