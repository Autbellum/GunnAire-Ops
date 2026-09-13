# Native Google access and recovery

September 7, 2026; candidate backend **2026.09.07.31**. This connects the native
app to the company-owned Google authorization service. It does not yet move
Mail, Calendar or Drive operations onto that service. Those transports, shared
outbox and received-message/job/file archival remain required full-suite work.
No deployment, live consent, provider write, signing, entitlement or CloudKit
promotion is authorized by this checkpoint.

## Native journey

Settings → Sync → Google → **Manage Google Access** opens a focused page in the
existing Settings navigation stack. Back returns to the same Settings area.
Only the employee's own approved business account is eligible. Standard and
unknown roles do not get the action; the backend independently enforces roles.

The page distinguishes approval from synchronization. It shows human-readable
Mail, Calendar and Drive-file access, without tokens, IDs, raw scopes, code,
provider errors or an account-email footer. The existing device-based Google
connection and its sign-in/refresh behavior are retained. Choosing features
requests incremental consent, not revocation of previously approved scopes.

Apple's current `ASWebAuthenticationSession` callback API presents Google's
consent page. The URL must have the exact Google HTTPS origin and authorization
path, expected backend callback, actor/domain, selected scopes, code response,
offline consent and bounded S256/nonce/state fields. Duplicate or extra query
fields and alternate origins fail before opening a browser.

The backend's successful or denied callback redirects to the fixed route
`gunnaireops://oauth/google/connection?attemptID=<original UUID>`. This contains
no bearer, authorization code or account identity. Invalid/unknown/expired
callbacks do not emit a redirect. The native callback validates the whole route
and only then reads the authenticated original attempt and current grant.
A callback is not proof of success; partial grants activate only listed access.

## Interrupted requests and authority

Before the first prepare or disconnect POST, the app saves an operation record
in device-only Keychain: original UUID, operation type, company, backend origin,
actor, feature choices and initiating session fingerprint. No Google secret or
authorization URL is saved on the device. Storage failure prevents network work.
All windows serialize compare-and-replace journal writes on the main actor.

Reopening the page reads the original outcome without another POST. An explicit
continuation may prepare the same authorization ID and choices only under its
original business session; a replacement session may recover or cancel, but
cannot reopen that consent. The status endpoint also exposes this actor's
unfinished request so another device can discover and cancel it without
receiving any replayable OAuth data.

Cancellation includes the original company/features. If it reaches the server
before a delayed prepare, the server stores an immutable cancelled tombstone.
The late prepare cannot revive that ID. Tombstone creation shares the existing
30-per-hour request limit; cancelling an existing request is still allowed.
Cancellation racing completed consent reads the actual saved grant rather than
claiming cancellation removed an already-approved connection.

A disconnect stores and targets only the original grant. Lost replies recover
by GET; a later reconnect cannot be removed by retrying an old disconnect.
The confirmation explains that only the server credential copy is removed,
not the existing native connection or all project-wide Google permissions.

Company, role, session fingerprint, workspace generation and the actual
authorized CloudKit-backed model container are checked before/after asynchronous
work and browser callbacks. Leaving the page does not discard its journal.
Connection HTTP requests require the exact opaque application bearer, reject
redirects, and never display provider response bodies. No token proxy is added.

## API additions to the existing service

- Prepare replies include `companyID` and `actorEmail` alongside the original ID.
- Attempt replies include company, actor, requested features, state and grant ID.
- Connection replies include company, actor and the actor's `pendingAttempt`.
- Cancel accepts `{companyID, features}` and creates a non-replayable tombstone
  if necessary. The prior empty-object contract still cancels existing attempts.
- Valid callback outcomes use a fixed 303 native redirect and retain no-store,
  no-referrer, CSP and redacted application-log protections.

## Qualification and rollout

Evidence is retained under
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/Native Google Access/`.
Final native logic acceptance passes **1,244 tests on each platform**. The iPad
also passes all five selected journeys: Google relaunch/cancellation and return
to Settings, partial-permission display, administrator Settings discoverability,
Invoice launch and the simple Mail inbox. The 25 new logic tests include
parameterized hostile-URL cases. Backend passes **405**, including **39** focused
Google connection tests; Tools passes **37**. No final failures or skips.

Authoritative final bundles are `FinalMacAcceptance2.xcresult` and
`FinalIPadAcceptance.xcresult`. The final iPad capture in `FinalUIEvidence2/`
was visually inspected: clear approval rows, expandable access choices, visible
disconnect action, normal Back navigation and no account-email footer.
The first focused Mac run was a compile failure from a missing test-fixture
actor annotation; fixed explicitly, without suppressing concurrency checks.
The first iPad run exposed an offscreen next-action assertion and the system's
combined permission accessibility row. Retained hierarchy evidence confirmed
cancellation succeeded. The page was shortened and given explicit accessible
permission values; tests now also reopen the page after returning to Settings.
No assertion was skipped or weakened to accept unconfirmed permissions.

The workflow candidate adds the two new Google journeys (29 selected iPad
journeys total); actionlint and exact test-selector existence checks pass.
GitHub publication/current-head CI are separate from this local qualification.

The preceding published head `f082074` passes Backend and Mac hosted jobs,
but its [iPad job](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34168320129)
fails the existing tax-address journey: immediately after typing `12 Main Street`,
the field reports `12 Main S`, before any save. All 1,219 preceding native logic
tests pass; 26 of 27 selected iPad journeys pass. The exact unchanged tax journey
passes three consecutive local repetitions in `TaxAddressReproduction.xcresult`.
The cause remains unconfirmed; no tax input code, test assertion, retry policy,
or workflow failure gate is changed. These local repetitions do not establish
that the hosted issue is resolved. Retain `HostedIPad-f082074.log` and require
fresh exact-head hosted results for the new source and workflow.

The final unsigned universal Mac build also passes in
`FinalUniversalMacRelease.xcresult`; `lipo -verify_arch arm64 x86_64` confirms
both architectures. Google UI fixture identifiers are absent from the optimized
binary. Xcode emits the existing missing Metal-toolchain search-path warnings;
they do not prevent linking. Project signing, entitlements and deployment targets
are unchanged.
Fixture browser and HTTP tests do not constitute live Google consent, signed
CloudKit, independent staff sharing or physical multi-device acceptance.

Backend .31 must be configured and separately approved for deployment before
this flow can be used in production. Preserve the dedicated encryption key,
immutable Google bindings and attempt tombstones across rollout and rollback.
Existing native Google APIs stay in use until server feature services and
cross-device recovery are implemented and accepted. Do not distribute this as
completed shared synchronization.

## Primary guidance reviewed in Safari

- [Apple authentication sessions](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)
  and the installed Xcode 26.6 SDK callback/presentation headers.
- [Apple sheets](https://developer.apple.com/design/human-interface-guidelines/sheets)
  informed the decision to use normal navigation inside Settings instead of
  stacking another sheet on top of it.
- Google OAuth, identity and scope references remain in
  [GOOGLE_SERVER_CONNECTION.md](GOOGLE_SERVER_CONNECTION.md).
