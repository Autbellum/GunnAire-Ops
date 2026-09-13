# Mailbox navigation and message lifecycle

Implementation checkpoint: September 7, 2026. Final-source logic and selected
iPad acceptance pass. This does not qualify the full business suite or a
production release; the additional Mac UI startup gate below remains open.

## User workflow

Mail keeps the existing simple list, message reader and composer. A compact
**Mailboxes** menu selects Inbox, Sent, All Mail or Trash. Sent lists the
recipient; other mailboxes list the sender. **Load Older Messages** exposes the
next provider page without loading an entire company mailbox into memory at
once. Search remains inside the selected mailbox. Refresh and failed-page
recovery retain already loaded messages; switching folders or searches never
shows the previous collection as the new result.

Read/unread and Archive are available from row actions or the reader's existing
More menu. Delete means **Move to Trash**, with confirmation in the reader;
Trash exposes **Restore**. There is no permanent deletion endpoint. Archived
and restored messages are reachable in All Mail. Restoration does not promise
that Gmail puts the message in Inbox. No account-email footer, API headers,
MIME details or extra dashboard is added.

## Provider contract and authority

- `GmailMailbox` owns one observable collection, its cursor, consumed-page
  tokens, current search, load generation and pending message actions. The
  collection lifetime is a child of the original provider/workspace lifetime,
  so refreshing the list does not invalidate an open same-account reply.
- The live access capture rechecks the original Google connection, business
  login, authorized SwiftData container, current verified role and active local
  user records. General mailbox access uses the existing administrator/
  dispatcher policy; field and accounting business-message permission remains
  separate in `GmailSendWorkflow`.
- The API uses fixed-origin `users/me/messages` GETs, bounded 25-message pages
  (maximum 50 in the app adapter), opaque encoded page/search parameters and
  `labelIds` for Inbox/Sent/Trash. A search `OR` cannot replace the independent
  label restriction. Trash opts into `includeSpamTrash`; the other views exclude
  Spam/Trash. Provider drafts are not presented as editable sent messages.
- Every reference is validated before metadata fanout. All metadata must match
  its exact message and thread; a malformed/failed member rejects the whole
  page. Provider order is retained. Repeated/cyclic cursors do not advance the
  collection. Overlapping IDs are deduplicated without replacing a more recent
  local read state; conflicting thread identities require refresh/recovery.
- Each mutation retains its exact selected message/thread and original access.
  The reader holds its initiating provider in SwiftUI state, including through
  delete confirmation. An obsolete reader cannot act on coincidentally equal
  message IDs in a new connection or clear that new mailbox. Revoked current
  access clears the current presentation even before an action is scheduled.
  The app pauses folder changes/page reads while a message change is being
  confirmed. Same-message repeated taps cannot issue duplicate in-flight writes.
  Read/unread/archive use label modification; trash/restore use bodyless POSTs.
  Successful responses must match the original ID/thread and requested label
  state. Omitted repeated label arrays represent an empty set, as for an
  otherwise unlabeled archived message. No optimistic removal or automatic
  mutation retry occurs after an uncertain result.
- Changed access discards old results and clears local mailbox presentation.
  Failed changes retain the row and explain that Gmail has not confirmed the
  change. Search-dependent label changes requery the original search instead
  of implementing a second, inaccurate parser for Gmail search syntax.

This improves native entry-point enforcement; it does not replace the remaining
server-owned Google authority/credential-containment requirement.

## Documentation reviewed in Safari

- [Google message list](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/list):
  page tokens, matching all requested labels, metadata follow-up and Spam/Trash.
- [Google message modification](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/modify):
  add/remove labels and returned Message resource.
- [Google Trash](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/trash)
  and [restore](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/untrash):
  recoverable POSTs, empty request bodies and returned message evidence.
- [Apple menus](https://developer.apple.com/design/human-interface-guidelines/menus):
  concise familiar labels, contextual groups and compact native navigation.

## Acceptance and remaining scope

New logic tests cover folder/correspondent semantics, pagination and retry,
empty intermediate pages, overlapping/conflicting identities, stale and
cancelled loads, current access, read-state retention, search refresh, serialized
actions, uncertain outcomes and fixed-origin encoded provider contracts. Two
new iPad journeys exercise older messages/Sent/read-unread/archive and
Trash/restore/All Mail using the same collection controller and fixture-only
transport substitutes. Existing simple Mail tests retain message-body and
compose checks; the recovery instruction now points to the in-app Trash.

The first focused compile exposed a private label-request type and an
actor-isolated default argument. The type is now shared internally and the
default manager is resolved inside the main-actor initializer. No warning is
suppressed. The focused Mac pass is 39/39 (30 new mailbox tests plus 9 existing
Google transport tests). The first iPad pass is 30/30 new logic tests and 3/3
selected Mail journeys. Subsequent review added two original-reader/current-
access regressions, retained provider state in the reader, and clearer empty/
failed-page copy. A pre-final full Mac pass has 1081/1081 logic tests; final
acceptance is rerun after the last access-loss presentation correction.
Final-source results:

- Mac Catalyst arm64: **1081/1081 logic tests**, no failures/skips, at
  `/tmp/GunnAireQBORefreshMac/Logs/Test/Test-GunnAire Ops-2026.09.07_09-14-05--0400.xcresult`.
- M5 13-inch iPad Simulator / iOS 26.2: **1081/1081 logic tests and 10/10
  selected UI journeys**, no failures/skips, at
  `/tmp/GunnAireQBORetryDerivedData/Logs/Test/Test-GunnAire Ops-2026.09.07_09-10-50--0400.xcresult`.
  The UI set is six Mail journeys (simple inbox, failed draft, uncertain send,
  attachment preview/forward, mailbox navigation and restoration), Invoice
  launch, customer statement generation, assigned-technician invoice item
  editing/update, and field billing controls. This differs from hosted CI's
  twelve selected journeys and is not a fresh whole-UI acceptance run.
- Backend **173/173** and Tools **37/37**, fixture-only.
- Final unsigned optimized universal Mac Release succeeds; `lipo` verifies
  both arm64 and x86_64. New mailbox UI fixture strings are absent from the
  Release executable. Only the existing external Metal-toolchain search-path
  warnings remain. The app is retained as `Unsigned Mac - validation only.app`,
  not installed or distributed.

Retained evidence root:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/Mailbox Navigation/`.
It contains `MacAcceptance.xcresult`, `iPadAcceptance.xcresult`, source SHA-256
manifest, final logs, and the Mac UI startup diagnostics below. The earlier
Mac result remains separately named `MacPreFinalAcceptance.xcresult`.
The four final PNGs were all visually inspected: compact mailbox menu
`Mailboxes/62B81C41-03C6-4164-B709-5A47CDEEDEE8.png`, Sent recipient
`Mailboxes/D9F6D127-B202-4891-9A5F-2D1976E22D2F.png`, older messages
`Mailboxes/D2F520B3-855E-4B3B-9D1E-38C7E313BB5C.png`, and restored message
`Restored/B70F4960-6EAE-4D27-AD7E-4100F7250F3E.png`. They show readable native
mail controls without code/header panels, clipping or an account-email footer.
Fixture correspondence addresses remain normal message content.

An additional Mac Catalyst UI qualification attempt did not reach the first UI
test. Its 1081 logic tests passed, but the exact UI runner PID 73449 remained
at `_dyld_start` with a 96 KB footprint; process sampling and testmanager logs
were retained. `DevToolsSecurity -status` reported developer authorization
disabled. That is a relevant host prerequisite, not a proven app crash cause.
No system authorization was changed. The exact xcodebuild PID 73382 was
cancelled with SIGINT after startup diagnostics, and both it and its runner
exited. Xcode returned 75 with an internal cancellation assertion. This
cancelled combined run is **not** a Mac UI pass or release acceptance result.
The existing logic-only gate and universal Release build are run separately
against final source. Mac runtime UI qualification remains open; iPad success
does not substitute for it. No global daemon was reset and no unrelated app
was terminated.

The preceding published `3348725` head passes all four hosted jobs:
[Native](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34121851059) and
[Backend](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34121851023).
Those results qualify that source, not this mailbox checkpoint.

Remaining Mail requirements include cross-restart/provider drafts, durable
server-owned sending and outcome recovery, received-message links to exact
customer/job/document files, custom labels/Spam and broader MIME/charset
qualification. Live Google acceptance is still required. The full goal also
retains server-owned accounting/payment workflows, signed CloudKit multi-device
and offline convergence, approved physical-iPhone Tap to Pay/Handoff, supplier
onboarding, and platform/provider release acceptance. No merge, deployment,
signing/entitlement change, physical installation, production mail change or
live customer/accounting/payment mutation is part of this checkpoint.
