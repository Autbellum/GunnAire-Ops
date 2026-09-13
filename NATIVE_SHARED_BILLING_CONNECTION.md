# Shared business-session billing

Candidate backend **2026.09.08.40**, following PR #18 head `3f0b42d`.
This checkpoint removes the device-local QuickBooks OAuth gate from native
invoice/estimate publication and original Billing Review. It is not a deployment,
an accounting transaction, or certification that the full suite is complete.

## Actual entry points

- Saved invoices, new/updated invoice and estimate builders, converted estimates,
  agreement invoices and progress invoices discover the shared connection using
  the verified business login. The focused Management composer and Management
  publication queues use the same preparation and existing billing workflow.
- Billing Review discovers the connection without a device QBO token, then reads
  the original proposal and device journal. Cancellation and recovery retain the
  original identity and immutable sold prices. Checking status cannot create a
  new invoice or send an email/collect a payment.
- Offline drafts remain saved. An unavailable or old server gives a short,
  actionable saved-work message. It never causes direct Intuit fallback or asks
  a technician to connect their own QuickBooks account.
- Other direct-provider tools, including catalog imports, catalog compare/update,
  broad accounting downloads and explicit provider-email actions, still retain
  their existing OAuth gates. This is not a completed migration of every QBO API.

## Contract and boundaries

`GET /api/billing-publications/connection` requires an application session and
the original company, document kind, local document/customer IDs and optional
job/milestone IDs. Caller-supplied realm/environment, extra/repeated fields and
unknown document kinds are rejected. The server derives its own connected realm,
environment and opaque authorization revision. No OAuth credential, customer
contact, provider payload or assignment roster is returned. Discovery performs
no provider call and makes no database mutation.

Existing server billing permissions remain authoritative: Admin; Accounting for
invoices; Dispatcher for estimates; or an active technician with a current,
approved assignment to that job. Existing document/job/customer bindings cannot
be replaced by discovery. An administrator can prepare a not-yet-mapped customer,
but customer/catalog publication retains its separate administrator permission.
New field-created items still wait for approval; a later catalog price does not
rewrite an already saved sold price.

The native preparation is captured before Task scheduling. It retains the
mounted workspace operation identity, current authorization and original local
document, customer, selected-item revisions and payment records. Changes or
navigation cancellation during discovery stop before creating a billing owner.
The ephemeral API has no QBO tokens, Keychain load or refresh timer, and its
direct Intuit transport is disabled. It cannot enable unrelated OAuth-only UI.

The discovered authorization revision is pinned through billing context reads
and new publication requests. Administrator customer/catalog prerequisites also
carry the pin: the server checks it inside the reservation transaction, then
retains the existing immutable internal grant fingerprint. The pin is not a
replacement for encrypted payload integrity, provider mappings or duplicate
prevention. Original payload hashes remain compatible with earlier journals.
Uncertain writes are recovered by the existing original-attempt workflow.

The shared billing transport requires the exact current business-session bearer,
not a Google identity-token fallback. It is bounded, ephemeral and redirect-free,
with explicit supported-route/verb/body rules. Existing job-assignment and draft
approval/revocation routes remain supported. Raw server errors are not presented
as an inbox or billing document.

The design retains server-side OAuth management described by
[Intuit's OAuth client documentation](https://github.com/intuit/oauth-jsclient/blob/master/README.md).
The brief checking state follows [Apple's progress guidance](https://developer.apple.com/design/human-interface-guidelines/progress-indicators?changes=_7);
no extra settings dashboard or diagnostic payload is added to field billing.

## Qualification and remaining work

Evidence directory:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-08/Shared Billing.isbL8s`.

Final Mac logic passes **1,513 cases**, including ten new shared-connection tests.
Final iPad runs pass the same **1,513 logic cases plus all ten selected UI journeys
(1,523 total)**, with zero failures or skips. Both xcresult test trees confirm
actual execution rather than only test discovery. All **12 final screenshots**
were visually reviewed: original billing review, milestone return, offline
invoice/estimate saves and simple Mail remain readable, without raw API payloads
or an account-email footer. Ordinary sender/recipient fields remain in Mail.
All **648 backend tests** (local Python 3.9.6) and **56 Tools tests** pass; both workflows pass
actionlint. Native fixture tests cover invoice/estimate publication without
device credentials, exact sold-price retention, field-item approval gating,
changed context, malformed responses, offline/old servers, replacement grants,
lost-reply recovery and the complete supported billing route set. Backend tests
exercise real isolated SQLite authorization, strict HTTP shapes and original
customer/catalog reservation/replay pins. They do not contact live accounting.

Earlier failures are retained. The first backend pass exposed a proposal-hash
compatibility defect; preserving the original business-payload digest while
checking the authorization pin atomically fixes it. Route review found and
restored existing assignment and draft-revocation paths, now covered by a
positive/negative route matrix. The first iPad pass still expected the old
device-login message; its assertion now requires the saved-work guidance while
preserving original-item, price-review and invoice-update checks.

Unsigned universal Mac Release builds successfully for arm64 and x86_64, both
verified in the produced binary. The first architecture-check command used the
wrong argument order; rerunning `lipo <binary> -verify_arch arm64 x86_64` passes
without rebuilding or modifying the binary. The workflow definitions remain
unchanged; a newly published commit requires its own hosted CI qualification.

The business server must be separately deployed before distributing this client.
An older backend fails closed with the server-update message. No signing,
entitlement, SwiftData schema or CloudKit bootstrap/promotion is changed here.
Cross-device mixed-version/signed CloudKit convergence, independent staff data
sharing, real iPad/iPhone Handoff and approved Tap to Pay, remaining accounting
and catalog entry-point migration, vendor access and the full ten-comparator
HVAC/Google/QBO feature acceptance remain part of the unchanged active goal.
Existing document actor-isolation and optional Metal-toolchain warnings remain.
