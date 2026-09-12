# Mail composition, attachments and send recovery

The current [draft-recovery candidate](GMAIL_DRAFT_RECOVERY.md) adds encrypted
device-local drafts and persistent send locks to the existing coordinator.
It supersedes the workflow-instance-only restart limitation below, not the
remaining server-owned cross-device dispatch or received-mail archive gates.
Its final qualification is recorded separately; prior results are historical.

## Scope and observed defects

September 7, 2026. This is a native Mail implementation checkpoint, not
production delivery or full business-suite acceptance.

The previous Mail code classified ordinary Reply/Forward drafts as business
templates, dismissed the composer before the send result, silently omitted
unreadable routed attachments, and forwarded messages without their files.
Reply threading lacked the original RFC message references. A text/plain
file could be displayed as the message body, recreating the reported
technical-content problem. Generated billing-document email used a separate
send/audit callback path. Follow-up GET failures after an accepted POST could
also be mislabeled as permission to retry a possibly sent message.

## Integrated behavior

- Mail keeps normal inbox, read, reply, reply-all, forward and Trash actions.
  The composer retains editable fields after a definite rejection. An uncertain
  result keeps a read-only draft and directs the user to Gmail Sent; it does
  not offer another send of the same workflow instance.
- Reply-To, quoted display names, deduplicated recipient lists, original
  Message-ID/References and matching Subject are explicit. Changing the subject
  starts a new conversation. Unicode subjects and bodies use MIME encoding;
  control-character header injection is rejected before transport.
- The message screen separates actual body text from attachments. Files open
  in the existing read-only native Quick Look viewer. Forward loads every
  attachment before opening the draft; an unavailable file fails the whole
  forward. Long text bodies stored behind Gmail's attachment endpoint are
  resolved before reply/forward is available. Actual files remain lazy until
  preview or forward.
- Compose uses the native file picker to add files and offers explicit removal.
  File-provider reads run off the UI actor. Selection is all-or-nothing and
  keeps existing attachments on failure. Application bounds are 50 files and
  25,000,000 decoded bytes, not a claim about Google's service maximum.
  Valid empty files are retained. Preview files use unique app-owned temporary
  directories, sanitized names and file protection; dismissal removes only
  the corresponding owned directory.
- General messages may address contacts outside the customer database.
  Explicit business drafts retain their customer/job/document linkage and
  current role/assignment. Ambiguous customer identities, changed linked work,
  missing CloudKit relationships and consent changes stop the workflow.
  Transactional and marketing consent are distinct.
- Customer-linked pending/suppressed history is saved before POST. A successful
  response alone is not delivery proof: the workflow reads the exact returned
  message and verifies SENT, thread, Message-ID, From and recipients before
  marking local acceptance or advancing operational follow-up. A failed
  verification GET cannot turn the accepted POST into a retryable failure.
  The wording distinguishes Gmail acceptance from recipient delivery.
- Billing Documents uses the same send coordinator for generated customer
  files. Save failures, lost responses and account/role changes retain the
  original context. Pending/unconfirmed records are not uploaded as confirmed
  company communication outcomes.

No schema, signing identity, entitlement or provider configuration changes are
part of this checkpoint. Tests use isolated stores and fixture transport; no
customer messages, accounting writes or payments are sent.

## Verification record

The published pre-Mail PR head `d9a83d801a8059b38114163297d379ed52df568b`
passes all four hosted jobs:
[native](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34113375386) and
[backend](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34113375391).
That is not evidence for these unpublished Mail changes.

Intermediate focused validation passed 58/58 logic tests on both Mac Catalyst
and the M5 13-inch iPad Simulator. Three of four selected iPad journeys passed;
the first attachment preview journey stopped on an incorrect test expectation
that Quick Look includes the extension in its navigation title. Its retained
recording was inspected: Quick Look presents “Equipment”, not “Equipment.txt”.
The revised journey requires the actual fixture file contents before continuing
through preview dismissal, forward, attachment removal and return to Mail.

Earlier tests exposed and corrected CRLF-as-one-grapheme header validation.
An attachment test incorrectly assumed an opaque ID containing `?` must be
rejected; the implementation safely percent-encodes it. Separate assertions now
reject invalid path components and prove reserved characters cannot become a
query or fragment. No regression is skipped or marked continue-on-error.

Final local acceptance passes **1049/1049 logic tests on each native platform,
8/8 selected iPad UI journeys, 173/173 Backend tests and 37/37 Tools tests**.
The 51 new Mail logic tests cover sends, consent, retained identity, uncertainty,
MIME/header validation, complete attachment loading and file import. The eight
serial iPad journeys cover four Mail flows, Invoice launch, customer statement
generation, technician-created invoice items and field billing controls.

The first expanded UI run checked all matching filename text immediately after
removal, including the original message behind the composer. The corrected test
waits for the draft-specific removal control to disappear. The final run passes
all eight journeys together; retained before/after screenshots prove the draft
attachment is removed while the original message remains unchanged. All five
final Mail screenshots were visually inspected: readable body/file/status,
working native preview, no code/header panels and no account-email footer.

Exact retained artifacts are under
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/Mail Composition Workflow/`:

- `MacAcceptance.xcresult`: final run started at 08:15:22 local time.
- `iPadAcceptance.xcresult`: final run started at 08:15:21 local time; 1049 logic
  plus 8 UI tests, no failures or skips. Parameterized executions are counted
  separately by Xcode and are not additional logical test cases.
- `Preview/`, `FailedSend/`, `UncertainSend/`: final exported PNGs and manifests.
- `gunnaire-mail-final-mac-20260907.log`, `gunnaire-mail-final-ipad-20260907.log`,
  `gunnaire-mail-release-mac-20260907.log`, and Backend/Tools logs.
- `source-sha256.json`: exact selected source and manifest identities.

The unsigned optimized universal Mac Release succeeds; `lipo -verify_arch
arm64 x86_64` succeeds. Its executable SHA-256 is
`3623e07cb82f97908df4b62ed6a5135f6efb39ff1456b11e6cb7ad9982a921f4`.
Only the existing external Metal-toolchain search-path warning remains in that
Release log. The new Mail fixture-control strings are absent from the Release
executable. Native builds use Xcode 26.6, the shared GunnAire Ops scheme,
`CODE_SIGNING_ALLOWED=NO`, Mac Catalyst arm64 for logic, and the M5 13-inch iPad
Simulator on iOS 26.2. The project manifest is unchanged.

New-head hosted CI is still a separate gate. The native workflow candidate adds
the failed-send, uncertain-send and attachment preview/forward/removal journeys
to the existing seven hosted journeys. No merge or deployment is authorized by
this test evidence; the full application goal remains open.

## Remaining requirements — goal stays active

- Durable server-owned Google send intents, immutable dispatch and outcome
  recovery across app restarts and devices. The current one-shot guarantee is
  workflow-instance scoped. Customer-linked pending history is durable, but
  complete drafts/MIME/dispatch identities are not a cross-device outbox;
  general vendor messages do not yet have a local customer-linked history.
- Inbox pagination, Sent/Trash folder navigation, saved drafts, complete
  received-mail/customer/job linkage and a persisted searchable email archive.
- Recovery of an accepted send whose local history save failed, without
  resending; provider delivery/bounce events; end-to-end production Google
  approval/consent and mailbox acceptance.
- Wider international MIME/charset/filename interoperability and large,
  malformed, provider-hosted file cases. Fixture file-picker and preview tests
  do not qualify every iCloud/third-party file-provider combination.
- Complete role/tenant authority at server boundaries and current financial
  reconciliation for all customer statements and payment-reminder paths.
- The full ten-suite capability inventory is not proof of complete integration.
  Server-owned remaining QBO workflows, historical accounting/payment-event
  reconciliation, signed CloudKit/offline multi-device convergence, reviewed
  Production promotion/deployment, supplier onboarding, and approved physical
  iPhone Tap to Pay/Handoff acceptance remain required by the broader goal.

## Primary references

Reviewed in Safari, September 7, 2026:

- [Gmail attachment body](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages.attachments#MessagePartBody): external attachment ID, decoded size and base64url content.
- [Attachment GET](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages.attachments/get): exact original message/file endpoint and scopes.
- [Gmail threads](https://developers.google.com/workspace/gmail/api/guides/threads): target thread, RFC references and matching subject.
- [Sending mail](https://developers.google.com/workspace/gmail/api/guides/sending): MIME and base64url request format.
- [Gmail errors](https://developers.google.com/workspace/gmail/api/guides/handle-errors): status distinctions and the warning that a 200 response alone does not guarantee successful sending.
- [Apple progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators): visible progress, useful recovery feedback and consistent placement.
