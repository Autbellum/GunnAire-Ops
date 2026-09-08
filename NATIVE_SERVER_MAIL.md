# Native shared Mail

This checkpoint connects the existing native Inbox, Sent, All Mail, Trash,
search, full-message reader, reply/forward attachments and general office
composition to the company-scoped Mail service. It is not a separate email
dashboard. The familiar mailbox menu now also opens Outbox and checks unfinished
message changes. Google Access is reachable directly when approval is needed.

## Authority and lifetime

Office mailbox access requires the verified company workspace, original opaque
application session, original backend origin, active matching staff record and
Admin/Dispatcher role. A fresh server connection snapshot must confirm Mail.
The captured company/actor/grant capability is inherited by page, detail,
attachment, action and send operations. A missing permission, revoked session,
changed company or replacement grant does not trigger a device-token fallback.
Every successful envelope is checked against the original company, actor and
grant before its content is used.

The native Google token is no longer required for this general office mailbox.
Calendar, Drive and domain-linked customer/job/accounting messages retain their
existing workflows. The general Mail route cannot take a business context or
technician/accounting send as an unlabelled general-office request. Native
customer matching and contact preference checks still precede office sending;
server-authoritative customer consent and domain workflow migration remain
required before claiming complete shared business messaging.

## Durable actions and sending

Read/unread/archive/trash/restore save one original UUID, message, thread and
action in a company/actor/grant Keychain journal before contacting the server.
Repeated explicit actions reuse the same immutable server claim. A conflicting
action cannot replace an uncertain original. Check Mail Changes performs only
recovery reads; confirmed originals are removed using compare-and-swap. Storage
failures retain the original and never authorize another provider claim.

Device drafts keep their existing authenticated encrypted files. Optional
server-attempt fields are additive and preserve older drafts. Each send attempt
retains the exact server scope and UUID before submission; its RFC Message-ID
uses that UUID. Submitted contents and reply parent identity are immutable.
Only a confirmed rejection/cancellation permits a reviewed new attempt, while
retaining the previous attempt identity. Lost prepare/send replies retain a
locked original draft across relaunch. Check Sending Status reads the exact
saved contents and original evidence; it never sends again. A confirmed unsent
request can be explicitly cancelled to restore editing. A replacement grant or
modified saved message cannot unlock the original draft.

The Outbox is a shared, read-only recent-first view of submitted originals for
this login and grant. Full bodies are fetched only when the user opens a record.
Checks and cancellation apply to that exact original; no Outbox Send button
bypasses current customer/contact-preference review. Gmail acceptance and Sent
presence are not recipient delivery.

## Transport and UI

The native client uses the application bearer only. Ephemeral sessions disable
URL, cookie and credential stores, reject redirects and non-200 responses,
discard private error bodies, and enforce route-specific response byte limits
while receiving chunks. Each request has finite request/resource timeouts and
supports cancellation, including cancellation before transport starts. No
background send/retry is introduced.

Inbox controls remain sparse. Original recovery lives in the mailbox menu and
the existing saved-draft composer, not a new debug/status dashboard. Outbox uses
ordinary navigation with standard Back controls. Test-only synthetic transports
are compiled under DEBUG and exercise the actual mailbox/service/send/journal
paths without using a Google credential or sending a real message.

## Evidence and open requirements

Local evidence is under
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/Native Server Mail/`.
Final frozen-source qualification passes:

- `FinalMacAcceptance5.xcresult`: 1,271 named logic tests (1,301 parameterized executions), no failures or skips.
- `FinalIPadAcceptance3.xcresult`: the same 1,271 logic tests and five selected UI journeys on the 13-inch M5 iPad simulator, iOS 26.2; 1,276 named tests (1,306 executions), no failures or skips.
- `FinalUniversalMacRelease.xcresult`: unsigned Release build passes; `lipo` verifies both arm64 and x86_64. Shared-Mail DEBUG fixture names and launch flags are absent from the executable. Two Metal-toolchain search-path linker warnings remain; this is not signed distribution qualification.
- Final Inbox and recovered-original Outbox screenshots were visually inspected. They retain standard navigation, compact controls and no account-email footer.

The two new shared-Mail journeys are included in the proposed native CI workflow.
Workflow lint and whitespace checks pass. The initial focused Mac result (101
named tests) and all intermediate runs remain retained, not substituted for the
final results above.

Hosted CI is separate: preceding published head `a9dd55c` passes Backend and Mac,
but its existing iPad tax-address test fails before save because the typed value
is `12 Main` instead of `12 Main Street`. A previous head had the same incomplete
input symptom; the hosted cause is not yet established. No assertion, selector
or failure gate is weakened. Fresh exact-head hosted qualification remains
required after publication.

The first iPad run exposed a real persistence-policy omission: the encrypted
store rejected every transition from `review`, including the new exact-original
server confirmation. In-memory service tests did not exercise that disk rule.
The store now admits only an original-bound server-resolution transition while
keeping ordinary review-draft edits locked. An added regression exercises the
actual encrypted store for confirmed send and confirmed cancellation, including
rejection of a forged ordinary edit. The iPad assertion is unchanged. A separate
input-validation fixture initially used an ASCII filename already rejected by
the existing native limit; the corrected fixture uses a Unicode name under the
native scalar limit but above the server UTF-8 byte limit, preserving the
no-transport assertion. Intermediate failing results remain retained.

Still required: shared editable drafts and attachment opening in Outbox,
server-authoritative customer/job/consent actions, recovered local communication
history reconciliation, received-email/job/file archival, reconnect-grant review,
safe cancellation of an original not yet visible on the server, delivery/bounce
events, production activation, physical multi-device/offline acceptance and
distribution qualification. Existing server Mail APIs must be deployed through
a separately authorized promotion before a production app can use them. No
merge, deployment, live Google/QBO/mail/payment mutation, signing change,
CloudKit promotion or physical install is part of this checkpoint.

The full suite goal remains active, including all competitor-derived workflows,
complete QBO item/entity sync and reconciliation, independent-staff CloudKit
sharing, iPad/Mac-to-iPhone Tap to Pay/Handoff, supplier onboarding and release
acceptance. This Mail change does not substitute a smaller definition of done.

## Primary references reviewed in Safari

- [Gmail Message resource](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages): original message/thread identity, MIME and reply headers.
- [Gmail attachment read](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages.attachments/get): exact parent/attachment relationship and authenticated own-mailbox access.
- [Apple toolbar guidance](https://developer.apple.com/design/human-interface-guidelines/toolbars): deliberate controls, clear actions and native navigation.

See `SERVER_MAIL_WORKFLOW.md` for the server contract and provider-side evidence.
