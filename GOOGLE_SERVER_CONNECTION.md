# Server-owned Google connection

Candidate backend **2026.09.07.30**, September 7, 2026. This implements the
server OAuth/credential authority required for shared Google workflows. It does
not yet migrate the native Mail/Calendar/Drive transports, implement the shared
Mail outbox, or qualify production Google access. Existing native Google login
and the deployed backend are unchanged.

## Account and storage boundary

Each connection belongs to one durable backend company and one currently
approved business actor. Admin, Dispatcher, Field Technician and Accounting
may connect their own account; no role can select another employee's mailbox.
Standard, inactive, unknown and expired/revoked sessions cannot use the API.
Starting authorization or disconnecting requires a business sign-in less than
ten minutes old. Legacy API tokens and raw Google identity tokens cannot enter
this contract. Google and Apple opaque application sessions are supported;
neither connection flow creates or promotes an employee.

Google's verified ID token must match the configured web audience, issuer,
presenter, nonce, verified email, hosted domain and stable subject. Google
application sessions must also match their existing Google subject. Apple
application sessions still require the same verified business email; private
relay or a different mailbox is not silently mapped. The first stable Google
subject binding survives disconnect. Another subject or a subject already bound
to another employee requires a separate reviewed identity migration, not a
reconnect workaround. Company/user checks run again before provider contact
and before saving a late response.

SQLite contains three additive tables: authorization attempts, permanent account
bindings and current connection metadata. Access/refresh tokens are Fernet
encrypted with a dedicated Google key. Each authenticated envelope embeds its
version, purpose, company, actor and record ID; copying ciphertext to another
scope or record fails closed. Access/refresh expiry and scope metadata are
checked against the encrypted value before a token can be used. Missing or
changed keys do not generate replacement keys or clear saved connections.
The public API has no endpoint returning a provider token.

## Authorization and refresh lifecycle

Authorization requests use a client UUID, a ten-minute single-use random state,
an OIDC nonce and S256 PKCE. Only the state hash and encrypted secret envelope
are retained. Retrying the identical pending request returns the original
authorization URL; changing its company, actor, session or feature set does
not reuse its identity. One pending/exchanging request is allowed per actor,
with a separate limit of 30 newly created attempts per hour.

The callback claims `pending → exchanging` in an immediate SQLite transaction
before exchanging the code. Concurrent workers or a restarted process cannot
exchange it again. Google denial, expiration and cancellation preserve the
previous connection. A lost exchange reply becomes review-required; the user
can explicitly start a new authorization. Cancellation/revocation/company
changes while an exchange is running cannot install the late grant.

Each confirmed reconnect receives a new opaque grant ID. An old disconnect or
late refresh cannot overwrite it. Internal token acquisition requires the exact
company, actor, current application session, grant ID and allowed scope set.
Expired access tokens are claimed as `refreshing` before the refresh POST.
Concurrent workers cannot refresh the same connection simultaneously. Missing
new refresh tokens retain the original encrypted refresh token; time-limited
refresh grants are honored. Scope loss, failed persistence, revoked access or
uncertain provider outcomes do not return a token as successful. Interrupted
refresh currently needs explicit reconnect; bounded lease-based recovery of
safe transient refresh failures remains a usability/reliability follow-up.

Provider transport is fixed to Google's HTTPS token endpoint, does not follow
redirects, has a 20-second timeout and 64 KiB response bound, and does not expose
provider error bodies. JSON rejects duplicate fields and nonfinite values.
Callback query strings are redacted in application access logs. Callback HTML
shows only a generic completion/recovery instruction, with no-store,
no-referrer and restrictive CSP headers. It contains no account footer, token,
scope, state, authorization code or customer details. Reverse-proxy/hosting
access-log redaction must also be configured and verified before activation.

## HTTP contract

All routes except the browser callback require an opaque application session.

| Method and path | Request | Response/action |
| --- | --- | --- |
| POST `/api/google/authorizations` | `id`, `companyID`, unique `features` array | Original attempt ID and fixed-origin Google authorization URL |
| GET `/api/google/authorizations/{id}` | No query | Original attempt state and confirmed grant ID, if present |
| POST `/api/google/authorizations/{id}/cancel` | Empty object | Cancels only an unfinished original request |
| GET `/api/google/connection` | One `companyID` query | Own connection metadata; no provider tokens |
| POST `/api/google/connection/disconnect` | `companyID`, exact `grantID` | Removes the server credential copy and cancels pending authorization |
| GET `/api/google/oauth/callback` | Google state and code or error | Single-use exchange and generic browser result |

Errors use safe `error` and stable `code` fields: 400 invalid input, 401 missing
session, 403 denied identity/access/scope, 404 absent request, 409 changed or
finished state, 429 local request limit, 502 unconfirmed provider exchange and
503 configuration/storage failure. Expired pending requests report `expired`
instead of appearing live. No list API exposes other employees' connections.

Feature consent is incremental and requested only from this allowlist:

- `mail`: `gmail.modify`, covering the existing read/compose/send/archive/trash
  journey without requesting permanent deletion or mailbox sharing settings.
- `calendar`: `calendar.events` plus `calendar.calendarlist.readonly`.
- `drive`: `drive.file`, not full-Drive access.

OIDC identity scopes accompany those requests. The token response's actual
granted scopes determine available features; partial consent never activates
unapproved features. Feature consent is not server authorization for a customer
send, job edit or file disclosure. Each future service must enforce that domain
operation separately. No Mail message or Calendar/Drive resource is sent or
changed by connecting an account.

Disconnect is explicitly **server-copy only**. It does not call Google's
project-wide revocation endpoint because that would also invalidate existing
native-client grants. Full provider revocation requires a separately reviewed
cross-client workflow and must not be disguised as local sign-out.

## Configuration, rollout and recovery

Keep the existing `GUNNAIRE_GOOGLE_CLIENT_ID` (native business sign-in audience).
Provision these separately in the deployment secret manager, never in Git:

- `GUNNAIRE_GOOGLE_WEB_CLIENT_ID`
- `GUNNAIRE_GOOGLE_WEB_CLIENT_SECRET`
- `GUNNAIRE_GOOGLE_WEB_REDIRECT_URI` — exact registered HTTPS backend origin plus
  `/api/google/oauth/callback`, with no query, fragment, credentials or custom port.
- `GUNNAIRE_GOOGLE_TOKEN_ENCRYPTION_KEY` — a dedicated stable Fernet key, distinct
  from QBO/push keys. Do not rotate it without a reviewed re-encryption migration.

The existing allowed business domain applies. Missing settings disable new
authorization without disabling existing native sign-in. Before activation:
review the registered web client, exact production callback, Google scope/API
enablement and verification/consent requirements, edge rate limits and log
redaction, encrypted off-host backup, native recovery UI and provider acceptance.
No setting was provisioned or token rotated in this checkpoint.

Back up the complete SQLite database and keep the encryption key in independent
secure escrow. Restore into a separate directory and verify company, immutable
bindings and decryptable credentials. Code rollback must retain the additive
tables and user data. Restoring an older credential backup can reintroduce an
obsolete provider token; require explicit reconnect rather than assuming it is
still valid. Never expose tokens to diagnose restoration.

## Evidence and remaining work

35 focused tests pass, including real loopback HTTP → handler → service →
fixture provider, one-time concurrent exchange, stale/revoked identity,
cross-user/company denial, PKCE/nonce, partial scopes, ciphertext isolation,
audit rollback, backup/restore, refresh races, cancellation/reconnect and safe
log/HTML boundaries. The initial transport test expected a handler instance;
`urllib.build_opener` correctly accepts the configured handler class. The test
was corrected to inspect that class and its redirect rejection. No assertion
was skipped. Both the initial and final hardened-source complete Backend runs
pass **401 tests**, with zero failures or skips; Tools passes **37**. The final
focused run passes all **35** connection tests, including strict HTTP and provider
JSON parsing. Compileall, workflow actionlint and `git diff --check` pass. The
app, logic-test and UI-test source directories are byte-identical to published
head `8b368b5`; no new native build or rendered-interface acceptance is claimed.
The final-source logs are retained separately in the evidence directory:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/Google Server Connection/`.

Native consent/callback/status integration, migration of Mail/Calendar/Drive
requests away from device bearer tokens, durable shared send intents and
received-message/job/file archival remain required. Other required Google
features need explicit scopes and domain services; this is not an unrestricted
proxy for all Google APIs. Signed CloudKit/offline multidevice proof, independent
staff sharing, remaining QBO synchronization/reconciliation, approved iPhone
Tap to Pay, supplier onboarding and full-suite/provider/distribution acceptance
also remain open. No native UI, signing, entitlement, production setting,
deployment, live provider transaction or customer message changed here.

## Primary sources reviewed in Safari

- [Google web-server OAuth](https://developers.google.com/identity/protocols/oauth2/web-server)
  — offline consent, exact redirects, state, granular permissions and combined-grant revocation.
- [Google OpenID Connect](https://developers.google.com/identity/openid-connect/openid-connect)
  — stable subject, verified identity, nonce, audience and supported S256 PKCE.
- [Google API scopes](https://developers.google.com/identity/protocols/oauth2/scopes)
  — Mail/Calendar feature scopes and least-privilege selection; Drive's per-file
  scope is also documented by the server OAuth guidance.
