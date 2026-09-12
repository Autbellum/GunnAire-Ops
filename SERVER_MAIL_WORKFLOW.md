# Company-scoped server Mail

Backend candidate **2026.09.07.32**, September 7, 2026. This adds the mailbox
service and shared immutable outbox required for native Mail's server migration.
It does **not** yet switch the app's transport, replace the device draft journal,
enable automated customer communications, or establish production acceptance.
That server-only checkpoint retained the device Gmail connection. The subsequent
native migration is tracked in `NATIVE_SERVER_MAIL.md`; it connects the office
mailbox without changing domain-linked sending. No live email was sent.

## Interface and account boundary

The service supports the existing simple Inbox, Sent, All Mail and Trash views,
search, older-message pagination, message reading, attachment retrieval,
read/unread, archive, recoverable trash/restore, explicit office composition,
attachments and replies. It returns message content rather than Gmail routing
or authentication diagnostics. There is no permanent-delete, import, forwarding,
delegation, caller-selected URL, mailbox selection, or provider-token endpoint.

Mailbox access requires a current opaque application session, exact company,
Google grant and original business actor, an active Admin/Dispatcher role, and
the granted `gmail.modify` scope. This matches the current native general-mailbox
role boundary. An administrator cannot select another employee's mailbox.
Field Technician, Accounting, Standard, revoked/expired, foreign-company and
replacement-grant requests cannot use this general mailbox route.

Each request captures the actor and role, rechecking them with the exact grant
before token acquisition, before every provider call, after errors/responses,
and before persistence or delivery. A replacement login/grant cannot turn a late
response into another workspace's result. Existing Google OAuth encryption and
refresh controls apply; provider credentials never return to the client.

Customer/job/invoice/estimate/maintenance/marketing automation needs a separate
server-owned domain authorization contract: current contact consent, original
recipient, assignment/role, linked record identity and approved document/content
revision. Such metadata is explicitly rejected by the general compose endpoint,
not treated as trusted authorization. The existing native business checks remain;
they are not proof that this required server-domain migration is complete.

## Durable dispatch and recovery

The client must retain one UUID before preparing an operation, use that same ID
after a lost reply, and read its original outcome before doing anything else.
An operation's company, actor, grant, kind and normalized content are immutable.
Repeated identical preparation returns the same record; changes require review.
The client must not replace an uncertain operation with a fresh UUID to retry.

SQLite commits `prepared → dispatching` together with its audit event before any
send POST. Only the transaction that claims that transition can send. Concurrent
workers, restarted processes and repeated Send requests cannot acquire another
dispatch for that ID. Confirmed rejection, uncertain response and cancellation
remain explicit states. Only a prepared original can be cancelled; cancellation
does not erase a message Gmail has already accepted. Unknown cancellation IDs
are not represented as cancelled.

The server constructs MIME, including the stable RFC Message-ID derived from the
original operation ID. From is the authenticated actor; supplied sender headers
are not accepted. Recipients, body, subject, all attachments and reply references
are validated before preparing. Replies re-read the exact parent message and
verify its thread, subject, Message-ID and references before dispatch.

After a successful POST, the accepted provider message/thread identity is saved
before verification. Recovery GETs inspect that original identity or search Sent
by the exact RFC Message-ID if the POST reply was lost. Confirmation requires one
unambiguous result, the Sent label, original identity/thread and matching decoded
MIME recipients, subject, Message-ID, reply headers, body, charset and attachment
names/types/bytes. Missing/duplicate results, mismatched content or a failed GET
cannot authorize another POST. Gmail acceptance/Sent presence is **not recipient
delivery**; delivery/bounce outcomes remain a separate requirement. Message-ID
search is recovery evidence, not a claim that Gmail provides an idempotency key.

Read/unread/archive/trash/restore also retain an immutable operation ID, message,
thread and desired action. A repeated operation checks its current exact target
instead of repeating the provider mutation. If the desired labels cannot be
confirmed, the operation remains review-required. Clients still need to retain
these operation IDs across relaunch; this backend is not that native UI journal.

## Storage, privacy and limits

One additive `google_mail_operations` table stores encrypted content and compact,
separately authenticated summaries. Both are bound to exact company, actor and
operation identity with distinct encryption purposes. Content fingerprints use
HMAC, not a plaintext recipient/subject hash. Summaries permit recent-first,
25-row outbox listings without decrypting every attachment. Full content is
available only when the authorized caller explicitly opens its original record.
Pagination uses created-time/ID ordering and a canonical encrypted cursor bound
to the same company, actor and grant. Old records without the summary column
retain their body and use a non-destructive compatibility read.

The existing dedicated Google encryption key protects these additional envelopes;
missing/changed keys never create a replacement empty store. Back up the complete
SQLite database with the existing consistent-backup tooling, escrow the key
independently, and retain the additive tables during rollback. A backup restore
test verifies that the original message and prepared state survive without sending.
Restoring historical dispatch state into a live sender still needs an operational
reconciliation procedure; a storage test does not prove safe production replay.

Application bounds: 100 recipients, 900 subject UTF-8 bytes, 2 MiB text body,
50 attachments and 25,000,000 decoded attachment bytes, 48 MiB generated MIME,
68 MiB provider JSON response, 500 new operations/hour, 65,536 retained operations,
and a bounded encrypted-content storage budget per actor. Provider requests use
a fixed HTTPS own-mailbox origin, reject redirects, have a 20-second transport
timeout and a 90-second request budget, and do not retry. These are application
limits, not Gmail quota claims. Deployment edge/body/concurrency limits and large
message performance still require operational qualification.

API responses are no-store. Mail search terms and provider IDs are redacted in
application access logs; provider bodies and secrets are never used as error
messages. Hosting/reverse-proxy log redaction remains a deployment gate.

## HTTP contract

All paths below begin with `/api/google/mail/` and require an application bearer.
GET queries require one `companyID` and `grantID`. POST JSON requires those same
fields and rejects query parameters, duplicate keys and unsupported fields.

| Route | Additional fields / result |
| --- | --- |
| GET `messages` | Optional `folder`, `query`, `pageToken`, `maxResults` (1–50); scoped metadata page |
| GET `messages/{id}` | Scoped full message content |
| GET `messages/{id}/attachments/{attachmentID}` | Exact advertised parent/attachment and validated byte count |
| POST `messages/{id}/actions` | Original `id`, `threadID`, allowlisted `action`; original outcome and confirmed target |
| POST `outbox` | Original `id`, structured `message` (`to`, `subject`, `body`, `attachments`, optional `reply`); prepare only |
| POST `operations/{id}/send` | No additional fields; at most one provider dispatch for that ID |
| POST `operations/{id}/cancel` | No additional fields; cancels only a prepared original |
| GET `operations/{id}` | Scoped original state, provider identity and compact summary |
| GET `operations/{id}/message` | Explicit authorized opening of the retained immutable message |
| GET `operations/{id}/recovery` | Reads exact provider evidence; never sends again |
| GET `outbox` | Optional opaque `pageToken`; recent-first own-grant summaries |

Every success includes `companyID`, `actorEmail` and `grantID`; native consumers
must validate all three before displaying or saving the result. Status uses
`prepared`, `dispatching`, `accepted`, `confirmed`, `rejected`, `review`, or
`cancelled`. Error bodies contain safe text and a stable code; they do not expose
Google error bodies or classify a failed verification GET as permission to resend.

## Qualification and remaining work

Evidence directory:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/Server Mail/`.
Focused tests cover service calls and real loopback HTTP → handler → service →
fixture-provider requests, concurrency, encryption, lost replies, exact MIME,
replies, permissions, account changes, storage/audit failures and backup/restore.
All provider/customer interactions are synthetic.

Final source passes **447 Backend tests**, including **42 focused Mail tests**,
and **37 Tools tests**, without failures or skips. Authoritative logs are
`FinalBackendAcceptance2.log`, `FinalFocusedBackend2.log` and `ToolsAcceptance.log`.
The earlier complete 439-test run passed before additional summary/restore/cursor
coverage; the intermediate 446-test run includes the retained Path fixture error.
Both package and direct backend imports, compileall, actionlint and whitespace
checks pass. App, native logic-test and UI-test directories are byte-identical to
published `cad60f5`; this backend work does not claim a newly built native UI.

At `cad60f5`, [Native CI](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34170779743)
passes iPad and Mac, including both new Google-access journeys and the existing
tax-address test. [Backend CI](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34170779787)
passes Python 3.13 and 3.14. This proves that checkpoint's exact-head tests, not
this new Mail source's hosted acceptance or the cause of the prior intermittent
tax-input failure. Fresh hosted checks are required after publication.

Intermediate failures are retained: an adverse fixture originally changed both
the simulated accepted thread and later read, so it did not model an identity
mismatch; its POST reference is now captured before the simulated later change.
The backup test initially passed a string where the backend requires a Path;
the fixture was corrected and the exact restore test rerun. A cursor test found
that Fernet accepts appended noncanonical base64 spelling; the public cursor now
requires strict canonical encoding before authenticated decryption. The original
assertions remain, including rejection of modified data and duplicate dispatch.

Native inbox/compose/attachment transport cutover, durable native mailbox-action
IDs, shared draft editing and original-outbox recovery UI remain required next.
The domain-authorized technician/accounting/customer workflows, consent authority,
received-mail-to-customer/job/file archival, shared communication-history updates,
reconnected-grant review, retention/deletion policy and delivery/bounce events
also remain required. Do not activate the service as a generic bypass for them.
Existing device drafts and native provider connections are not discarded.

The full business-suite goal remains open: complete QBO entity synchronization
and reconciliation, field-created invoice items, independent staff CloudKit
sharing and signed offline/multi-device proof, approved iPhone Tap to Pay/Handoff,
supplier onboarding, competitor-suite coverage and provider/distribution acceptance.
This server checkpoint does not replace those requirements with fixture coverage.
No merge, deployment, credentials change, live provider mutation, signing,
CloudKit promotion or device installation is part of this work.

## Primary references reviewed in Safari

- [Gmail messages list](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/list): pagination, labels and exact Message-ID search.
- [Gmail Message resource](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages): immutable message IDs, raw MIME and threading requirements.
- [Gmail send](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/send): own-mailbox POST and returned Message identity.
- [Gmail modify](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/modify): supported label mutations and permissions.
- [Gmail attachment get](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages.attachments/get): exact parent/message/attachment relationship.

OAuth and server credential boundaries are documented in
[GOOGLE_SERVER_CONNECTION.md](GOOGLE_SERVER_CONNECTION.md).
