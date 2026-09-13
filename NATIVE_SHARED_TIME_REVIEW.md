# Native Time Clock shared-account review

Locally qualified September 9, 2026; backend `2026.09.09.45`. This checkpoint
is not a production deployment or completion of the full business-suite goal.

## End-to-end workflow

Time Clock keeps field-created hours, activity, job/customer context, author and
review history in the native store. Office approval no longer automatically
sends time through device QuickBooks OAuth. Admin/Accounting opens the original
entry's QuickBooks Time review, prepares the exact paid duration and confirms
publication separately. Unpaid breaks remain in the timesheet and never publish.
Single and bulk approval, correction requests and corrected entries restore
their original affected fields if saving fails; unrelated context edits remain.

An administrator reviews the existing Employee/Vendor identity in the shared
business QuickBooks account, checks the returned name and confirms the mapping.
The technician editor requires its original saved name/email before opening
that review. Existing device IDs remain untouched and are suggestions only.
Worker review pushes within the current navigation stack; Back returns to the
original time task, while Close returns to Time Clock. This follows the scoped
task and single-sheet guidance checked in Safari on September 9.
[Apple sheets guidance](https://developer.apple.com/design/human-interface-guidelines/sheets).

## Identity, persistence and recovery

- Business session, company, actor, role, connection grant, worker mapping and
  original entry are checked around asynchronous boundaries. Worker changes
  require Admin; publication requires Admin or Accounting. Server checks remain
  authoritative. Duplicate/missing local identities fail closed.
- Only bounded, allowlisted shared-time routes are exposed; no arbitrary query,
  host, redirect, device Google-token fallback or raw diagnostics reach this UI.
  Plus-tagged worker addresses are encoded for the server's query parser.
- AES-GCM journals bind company, actor and original worker/entry identity. The
  device-only Keychain key protects atomic files excluded from backup. Missing
  keys or corrupt saved journals never become empty replacement queues.
- Worker save retains its original operation before sending and replays only
  that idempotent mapping operation. Time preparation saves the exact request;
  confirmation records dispatch risk before the single accounting mutation.
  An uncertain confirmation can only recover its original result, never resend.
- Server responses must preserve the original worker, note, duration, posting
  date, references, proposal and confirmed receipt across state changes. A lost
  reply survives relaunch. A confirmed receipt survives failure to save the local
  link and offers an offline Restore Time Link action.
- Changed hours never receive an older receipt. The server's original journal
  remains recoverable after reopening. Cancel affects only an unsent proposal;
  a late preparation still owns the same unique company/entry on the server.
- A legacy match needs explicit adoption. A pre-existing local QBO time ID can
  never authorize a new time create. Configured project/payroll references are
  rejected for shared setup rather than silently omitted.

The backend now returns the immutable `preparedByEmail` from the authenticated
preparing session, distinct from client-supplied source reviewer evidence. The
native app requires this field; the matching backend is required for rollout.
No TimeActivity write runs payroll or collects money. Current Intuit fields,
worker references, explicit posting date, hours/minutes and payroll boundaries
were rechecked in Safari on September 9.
[Intuit TimeActivity reference](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/timeactivity).

## Qualification evidence

Evidence directory:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-08/Native Time.UOynXB`.
The existing directory date is retained across the overnight session.

Initial focused Mac runs pass 22 logic cases. The first iPad run retains three
new UI failures: combined LabeledContent accessibility labels and duplicated
nested alert button identities did not match the initial test queries. The
captured hierarchy shows `Approved time, 2 hr 0 min` and `Employee, Alex
QuickBooks`. Tests now assert the actual exact displayed label and scope the
alert action explicitly; no duration, returned worker, recovery, cancellation,
navigation or no-resend assertion was removed.

Final-source Mac and iPad logic each pass **1,591 tests**, including all **33**
shared-time/save-recovery cases. The iPad result contains **1,600 actual passing
cases**: 1,591 logic plus all nine selected UI journeys, with zero failures or
skips. The actual xcresult tree verifies all requested methods, not only the
console success banner. The journeys cover cancellation and return, worker
mapping and exact ID on reopen, uncertain confirmation/relaunch/recovery,
approval boundaries, offline classification, weekly sign-off, simple Mail,
and offline creation of the original invoice and estimate.

The second iPad run retained one cancellation-selector failure: that row was
below the sheet's visible viewport. The final test scrolls the identified review
form and verifies the real action is hittable. Compact inline titles keep the
task context without consuming a second title row. Reopening worker review
loads its verified saved type/ID instead of an empty or stale legacy suggestion.
All seven retained final screenshots were visually inspected. Original hours,
notes, approval/result states and saved document amounts remain legible; Mail
is a simple inbox without API diagnostics, and there is no account-email footer.
Long forms still require scrolling; this is not comprehensive accessibility QA.

All **766 backend tests** and **64 Tools tests** pass; both workflows pass
actionlint and the diff whitespace check. Workflow coverage increases from 60 to
64 UI journeys without removing previous assertions or complete logic targets.
Final unsigned Mac Release builds both arm64 and x86_64 (verified with lipo),
and generic iOS device Release builds arm64. Existing document-concurrency and
optional Metal-toolchain search-path warnings remain. No warning is suppressed.

Final evidence: `MacTimeCandidate2.xcresult`, `IPadTimeCandidate3.xcresult`,
`MacTimeSummary2.json`, `MacTimeTests2.json`, `IPadTimeSummary.json`,
`IPadTimeTests.json`, `BackendFullNativeTime.log`, `ToolsFullNativeTime2.log`,
`UniversalMacTimeRelease2.log`, `DeviceTimeRelease.log`, and `FinalTimeScreenshots`.
Mac executable SHA-256:
`e0ea5ae2d50ae8f15670081a58c6a311d62868629dfa1342033c42657cec031b`.
iOS executable SHA-256:
`df687f62e12b64d67d34b16d660344f486ae57a4f978a410386449bab3bda557`.

Original-project preflight covers 21 scoped paths, 274 unrelated changed files,
the original branch/HEAD/index and 309 other identical tracked source files.
The shared scheme also matches. `OriginalNativeTimePreflight3.json` freezes the
qualified source. Copy-back is gated by source hashes and original-state checks;
`OriginalNativeTimeCopyBack.json` must verify exact scoped equality and preserved
unrelated edits before publication. Published source still needs exact-head CI.

The new synthetic UI transport is
enabled only for DEBUG with the explicit isolated test-database flag; Release
always uses the actual authorized business client. No provider/customer/payment
data is read or written by these fixtures.

## Remaining application-level gates

Independent-staff CloudKit sharing is not implemented by this checkpoint.
The existing private-store/account binding cannot provide multi-Apple-ID staff
replication. Data partitioning, migration, revocation and signed independent-user
convergence remain necessary. Matching backend deployment and real authorized
QBO acceptance, broader Google/QBO migration, vendor onboarding, approved PSP
Tap to Pay plus physical iPad-to-iPhone handoff, and full competitor-suite,
accessibility, navigation and physical-device acceptance also remain open.
No signing, entitlement, schema promotion, main merge or deployment is included.
