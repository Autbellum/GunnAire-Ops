# GunnAire Ops Mac Studio Backend

This is a small backend for sharing app users, roles, uploaded field receipts, and field payment records across iPads.

## Start It On The Mac Studio

```sh
cd "/Users/gunnaire/Library/Mobile Documents/com~apple~CloudDocs/GunnAire-Ops/Backend"
export GUNNAIRE_BACKEND_API_TOKEN="replace-with-a-long-random-token"
export GUNNAIRE_BACKEND_PORT=8787
# QBO confidential credentials belong here, never in the iOS app or xcconfig.
export GUNNAIRE_QBO_CLIENT_ID="your-intuit-client-id"
export GUNNAIRE_QBO_CLIENT_SECRET="your-intuit-client-secret"
export GUNNAIRE_QBO_REDIRECT_URI="https://gunnaire.com/wp-json/ga/v1/qbo/oauth/callback"
export GUNNAIRE_QBO_ENVIRONMENT="production" # or sandbox; must match the app build
# Copy this value from Intuit's Webhooks settings; never invent or expose it.
export GUNNAIRE_QBO_WEBHOOK_VERIFIER_TOKEN="your-intuit-webhook-verifier-token"
# Generate once with: python3 -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())'
# Save this only in the host secret manager; do not rotate it while a QBO connection is active.
export GUNNAIRE_QBO_TOKEN_ENCRYPTION_KEY="your-fernet-encryption-key"
# Optional browser clients only; native iPad/Mac requests do not need CORS.
export GUNNAIRE_ALLOWED_CORS_ORIGINS="https://ops.gunnaire.com"
# Default is 12 MiB; set within the supported 1–25 MiB range if needed.
export GUNNAIRE_MAX_DOCUMENT_BYTES=$((12 * 1024 * 1024))
python3 gunnaire_backend.py
```

Use the Mac Studio LAN name or IP address in the iOS app config:

```xcconfig
GUNNAIRE_BACKEND_BASE_URL = http://macstudio.local:8787
GUNNAIRE_BACKEND_API_TOKEN = replace-with-a-long-random-token
```

The token in the backend environment and the app config must match.

## Production identity mode

`api-token` mode is retained only for a physically controlled LAN/development server. It grants the holder of the shared token administrator-equivalent backend access and must not be exposed outside that environment.

For a deployed multi-user server, terminate TLS before the backend and use verified business identity plus revocable GunnAire application sessions:

```sh
python3 -m pip install -r requirements.txt
export GUNNAIRE_BACKEND_AUTH_MODE="google-id-token"
export GUNNAIRE_GOOGLE_CLIENT_ID="your-iOS-google-client-id.apps.googleusercontent.com"
export GUNNAIRE_GOOGLE_ALLOWED_DOMAIN="gunnaire.com"
export GUNNAIRE_APPLE_CLIENT_ID="com.gunnaire.businesssuite"
# Optional: application sessions are capped at 30 days and remain revocable server-side.
export GUNNAIRE_APP_SESSION_DAYS=30
python3 gunnaire_backend.py
```

Then set `GUNNAIRE_BACKEND_AUTH_MODE = google-id-token` in the app build configuration, use an HTTPS `GUNNAIRE_BACKEND_BASE_URL`, and omit the shared API token. The historical mode name is retained for deployment compatibility, but fresh Apple and Google sign-ins both exchange their one-time provider identity for the same revocable GunnAire application-session contract. Protected requests use that opaque application session. A legacy Google ID token may still be accepted while an existing client renews, but it is not persisted by the app. Both providers must resolve to an already-approved active backend user; neither provider creates or promotes a user. Apple private-relay addresses therefore require an explicit administrator-created user record and are never mapped automatically to another email.

Apple identity exchange is available at `POST /api/auth/apple`. The token is verified against Apple's current RS256 public keys, issuer, app audience, expiry, issue time, nonce, subject, and verified email. Google identity exchange is available at `POST /api/auth/google`. The token is verified through Google's supported verifier for the exact configured iOS client audience, hosted business domain, verified email, and subject. Provider identity tokens are used only for exchange and are not stored. The backend persists only a SHA-256 hash of each random application-session token, rechecks the user's active state and current role on every protected request, and supports immediate revocation at `POST /api/auth/logout`. The app stores only the opaque application session in Keychain; Apple additionally checks the credential state on relaunch and responds immediately to Apple's native credential-revocation notification.

After source `2026.08.28.13` is deployed, configure the primary App ID's Sign in with Apple server-to-server notification URL as `https://gunnaire-api.onrender.com/api/auth/apple/notifications`. The public endpoint accepts only Apple's exact JSON envelope, verifies the signed JWS against Apple's RS256 keys plus issuer, app audience, issue/event times, event ID, type, and subject, and idempotently processes `email-enabled`, `email-disabled`, `consent-revoked`, and `account-deleted`. Consent and deletion events revoke only Apple application sessions and their push registrations; delayed events older than a fresh Apple reauthorization cannot revoke that newer session. The raw JWS and private-relay address are not retained in the event ledger. Do not enter the URL in Apple Developer before the reviewed backend version is live and the endpoint is reachable over TLS 1.2 or later.

## Render deployment

Deploy this directory as a Python **Web Service** with the start command:

```sh
python3 gunnaire_backend.py
```

Render's existing repository-root start command is supported by a thin launcher
that imports this canonical module. Do not copy backend implementation into the
root file. The deployment regression tests verify that the launcher resolves to
`Backend.gunnaire_backend.main`, that the root dependency file delegates here,
and that the deployed QBO client contract cannot return a refresh token.

Render provides `PORT` automatically. Attach a persistent disk at `/var/data` and set `GUNNAIRE_BACKEND_DATA_DIR=/var/data`; this keeps both the SQLite database and uploaded field documents outside Render's ephemeral filesystem. Configure the following as encrypted Render environment variables, never in the repository:

```sh
GUNNAIRE_BACKEND_AUTH_MODE=google-id-token
GUNNAIRE_GOOGLE_CLIENT_ID=your-iOS-google-client-id.apps.googleusercontent.com
GUNNAIRE_GOOGLE_ALLOWED_DOMAIN=gunnaire.com
GUNNAIRE_APPLE_CLIENT_ID=com.gunnaire.businesssuite
GUNNAIRE_APP_SESSION_DAYS=30
# Keep disabled until a provider approves the business and production link.
GUNNAIRE_CUSTOMER_FINANCING_ENABLED=false
GUNNAIRE_CUSTOMER_FINANCING_PROVIDER_NAME=your-approved-provider
GUNNAIRE_CUSTOMER_FINANCING_APPLICATION_URL=https://provider.example.com/your-production-application
GUNNAIRE_CUSTOMER_FINANCING_MIN_AMOUNT=500
GUNNAIRE_CUSTOMER_FINANCING_MAX_AMOUNT=50000
GUNNAIRE_QBO_CLIENT_ID=your-intuit-client-id
GUNNAIRE_QBO_CLIENT_SECRET=your-intuit-client-secret
GUNNAIRE_QBO_REDIRECT_URI=https://gunnaire.com/wp-json/ga/v1/qbo/oauth/callback
GUNNAIRE_QBO_ENVIRONMENT=production
GUNNAIRE_QBO_TOKEN_ENCRYPTION_KEY=your-fernet-encryption-key
GUNNAIRE_QBO_WEBHOOK_VERIFIER_TOKEN=your-intuit-webhook-verifier-token
# Use a separate Fernet key for APNs device tokens; never reuse the QBO key.
GUNNAIRE_PUSH_TOKEN_ENCRYPTION_KEY=your-separate-fernet-encryption-key
GUNNAIRE_APNS_TEAM_ID=7C4B3RR7RD
GUNNAIRE_APNS_KEY_ID=your-10-character-apple-key-id
# Base64 of the complete Apple .p8 file, stored only in Render's secret manager.
GUNNAIRE_APNS_PRIVATE_KEY_BASE64=your-base64-p8-private-key
GUNNAIRE_APNS_TOPIC=com.gunnaire.businesssuite
GUNNAIRE_BACKEND_DATA_DIR=/var/data
```

Use `api.gunnaire.com` as the custom HTTPS domain after Render provides its DNS target. Do not enable public booking, customer portal, or customer financing until the corresponding customer-facing route, privacy notice, provider approval, and production acceptance tests are complete. Establish an off-host backup of the mounted data before production use.

## What It Stores

- Approved GunnAire app users and roles.
- Active/inactive access state.
- Revocable Apple and Google application sessions. Only a one-way SHA-256 session-token hash, provider, provider subject, approved email, creation/use/expiry times, and revocation state are retained; provider identity tokens are not stored.
- The stable Apple subject-to-approved-user link plus a minimal idempotent account-event ledger. The event ledger stores a subject hash, event type/time, processing time, matched business account, and revocation counts; it does not store Apple's signed payload or a private-relay address.
- Opt-in staff-notification registrations. The APNs device token is encrypted with a dedicated Fernet key and linked to the exact approved email, application session, app installation, bundle, environment, and platform. API responses and audit events never return the token or its fingerprint. Durable delivery rows retain only generic routing metadata and provider status; customer names, addresses, balances, card data, and payment amounts are excluded from notification payloads.
- Uploaded receipt/document files under `Backend/storage`, retaining their service call, invoice, estimate, customer-equipment, equipment-name, and customer links for cross-device retrieval.
- Field payment collection records for admin QuickBooks reconciliation.
- QuickBooks change-event metadata for the currently authorized company realm. The raw provider payload, realm ID, customer content, and credentials are not retained or returned to the app.
- Transactional email and staff-reviewed service-text audit records, linked to the customer, job, maintenance agreement, estimate/invoice, and attachment names. Each attempt retains its channel, typed workflow/template, authenticated staff actor, consent snapshot, sent/failed/suppressed state, safe provider detail, and result time. Text recipients are normalized and validated before storage. Active staff may append their own evidence; only administrators may list company-wide communication history. The backend stores no message body and does not itself send automated SMS.
- Administrator-only server activity events for role changes, shared-document uploads, payment metadata, customer-communication records, booking claims, and QuickBooks authorization lifecycle actions. Tokens, card data, and customer-content fields are intentionally not recorded.
- An optional public online-booking request inbox. It never creates a job directly: dispatch imports, qualifies, and schedules each request.
- Optional customer-portal link metadata. Only a SHA-256 token hash is stored; management responses contain no URL or token. Open count and last-opened time are operational hints only and may include mail or security previews.
- No customer-financing application data. The backend returns only a static approved provider name, HTTPS handoff URL, and optional estimate amount limits; applicant, credit, underwriting, rate, term, and decision data remain with the provider.
- Administrator supplier-order attempts. The server retains the idempotency key, exact safe request hash/snapshot, purchase-order identity, connector kind, original actor, state, safe error code, and sanitized accepted acknowledgement. Supplier credentials, account secrets, and raw provider responses are never stored in these rows or returned to the app.
- Backend metadata in `gunnaire_backend.sqlite3`.

The primary admin `eric.gunn@gunnaire.com` is seeded automatically and cannot be deactivated.

Shared-document uploads validate all metadata before a file is written and reject files above `GUNNAIRE_MAX_DOCUMENT_BYTES` (12 MiB by default). Browser CORS is deny-by-default; configure only the specific HTTPS origins that need it with `GUNNAIRE_ALLOWED_CORS_ORIGINS`. Native GunnAire Ops clients are unaffected.

## Staff push notifications

Staff alerts are optional and account-bound. GunnAire Ops asks for Apple notification permission only after a signed-in user chooses **Settings → Staff Notifications → Enable Staff Alerts**. The app registers with APNs on every opted-in launch/foreground, forwards the current token directly to the backend, and never caches that token locally. Registration, lookup, and removal use `POST /api/push-devices`, `GET /api/push-devices/current`, and `DELETE /api/push-devices/{installationID}`; all three require a current revocable GunnAire application session. The shared development API token and legacy one-time provider token cannot create a registration.

The backend queues one idempotent alert per active installation when a new field-payment collection task is assigned. Assignment creation never waits for APNs. A background worker sends through Apple's HTTP/2 provider API, retains transient failures with bounded retry, and deactivates invalid or unregistered device tokens. Logout, session expiry, and user deactivation immediately suppress pending deliveries for that registration. The visible alert is deliberately generic—**New collection task**—and its private route contains only a version, event identifier, route type, and invoice UUID. The app re-applies current business-account, role, assignment, invoice-visibility, and outstanding-balance checks after a tap.

Create the APNs signing key only in the authorized Apple Developer account. Put its Team ID, Key ID, base64-encoded `.p8` contents, bundle topic, and the separate token-encryption key into the deployment secret manager. Never commit or upload the `.p8` file to this repository. The service accepts only topic `com.gunnaire.businesssuite`; Debug registrations use Apple's sandbox and Release/TestFlight registrations use production APNs. `GET /api/readiness` reports missing/invalid provider configuration, undecryptable registrations, credential rejection, stale backlog, and recent permanent failures without exposing a token or notification payload.

Source `2026.08.28.13` includes this path, but it is not production-active until that reviewed source is deployed, the APNs secrets are configured, the App Store privacy answers include the linked device identifier used for app functionality, and an opted-in signed physical device passes sandbox and production delivery tests.

## Online booking handoff

Keep public intake disabled by default. When a reviewed website form and HTTPS deployment are ready, set `GUNNAIRE_PUBLIC_BOOKING_ENABLED=true`. The form posts JSON to `POST /api/public/service-requests` with `customerName`, a `phone` or `email`, `summary`, `requestedServiceType` (`service`, `estimate`, `install`, or `maintenance`), `urgency`, and explicit `contactConsent: true`. An empty `website` honeypot may be included.

The endpoint is rate-limited per source IP (default: five requests/hour), stores only request data, and returns an acknowledgement. It does not expose availability or create a customer/job. Authenticated Dispatch/Admin inbox responses label these requests with `source: website`; production backend `2026.08.27.3` and newer clients support the attribution, while clients remain tolerant of older responses. Dispatchers import requests from **Schedule → Incoming Requests → Import Online**, qualify them, and create the appointment; scheduling claims the server request so it cannot be imported again. Add website-specific bot protection, terms/privacy links, and a contact-consent notice before enabling it publicly.

## Customer portal handoff

The customer portal is intentionally disabled by default. It is not a general customer-login system or a public business API. When the business is ready to publish it behind HTTPS, set:

```sh
export GUNNAIRE_CUSTOMER_PORTAL_ENABLED=true
export GUNNAIRE_CUSTOMER_PORTAL_BASE_URL="https://portal.gunnaire.com"
export GUNNAIRE_CUSTOMER_PORTAL_MAX_DAYS=30
```

An administrator can then create an expiring, revocable link from a job in GunnAire Ops. The link shows only the escaped appointment and linked-invoice snapshot provided at creation time. It cannot browse customer data, change scheduling, download files, or take a payment. The server requires valid customer email and UUID business references, rejects malformed/negative/non-finite amounts and non-integral expiry values, and accepts one normalized HTTPS origin without credentials, path, query, or fragment.

Tokens are random, only their SHA-256 hashes are retained, capability URLs are redacted from access logs, and create/revoke actions enter the audit log. Public responses are non-cacheable and use CSP, frame, referrer, MIME, permissions, and cross-origin isolation headers. Successful opens increment non-sensitive management metadata; this is deliberately labeled **Opened**, not **Viewed** or **Read**, because email and security scanners may follow a link. Staff must still explicitly share the link; no email is sent automatically.

Before enabling it for customers, deploy the reviewed backend version, host the route on the exact configured HTTPS origin, publish a customer-facing privacy notice, add edge abuse/rate controls, and verify create/open/expiry/revocation from approved production accounts. Backend readiness reports the portal as needing attention while disabled, error for an unsafe origin, and ready only for a valid enabled HTTPS origin.

## Customer financing handoff

Customer financing is disabled by default. After an approved provider supplies a production, provider-hosted application URL, configure:

```sh
export GUNNAIRE_CUSTOMER_FINANCING_ENABLED=true
export GUNNAIRE_CUSTOMER_FINANCING_PROVIDER_NAME="Approved HVAC Finance"
export GUNNAIRE_CUSTOMER_FINANCING_APPLICATION_URL="https://provider.example.com/gunnaire/apply"
export GUNNAIRE_CUSTOMER_FINANCING_MIN_AMOUNT=500
export GUNNAIRE_CUSTOMER_FINANCING_MAX_AMOUNT=50000
```

`GET /api/customer-financing` requires an active staff session and returns contract version 1. It contains only the static provider name, validated HTTPS application URL, optional amount limits, and explicit `providerHostedApplication: true` / `canSubmitApplication: false` controls. The endpoint rejects credential-bearing, non-HTTPS, fragmented, or malformed URLs and invalid amount ranges without returning the unsafe URL.

Eligible open or accepted estimates expose the referral inside **More Estimate Actions**. GunnAire Ops opens the provider's site without appending customer, estimate, or amount data to the URL and records only a CloudKit-backed job activity that the referral link opened. The app and backend never collect an application, Social Security number, credit response, underwriting result, rate, term, or approval status. Complete provider onboarding, legal/privacy review, staff training, and production-device acceptance before enabling this flag.

## Supplier connector boundary

`GET /api/supplier-connectors` and `POST /api/supplier-connectors/orders` require an active Admin application session. Discovery returns safe readiness records only. Backend source `2026.08.30.16` requires supplier contract version 2. Submission requires a 16–128 character `Idempotency-Key`, validates a strict USD purchase-order payload with one to one hundred stable-ID lines, rejects unsupported or secret-shaped fields, and stores no supplier credential or raw provider response. Every line contains a bounded item name, internal SKU and/or supplier part number, positive quantity, and nonnegative expected unit cost.

The built-in registry intentionally contains no live adapter. A deployment module may register a reviewed `SupplierConnectorAdapter` only after the supplier authorizes the business account and provides the exact integration contract, test account, branch/pricing rules, and order authority. The adapter must implement `submit_order` and `recover_order`. Its acknowledgement must return one `confirmedLines` entry for every requested line ID, no extras or duplicates, the exact requested quantity, a compatible supplier part number when present, and a valid confirmed unit cost. Any mismatch is an invalid/unknown adapter outcome and cannot be stored as accepted. A timeout or unknown provider result moves the attempt to `unknown`; every retry calls only `recover_order` with the original request and key. The backend never resubmits an uncertain order. One active or accepted attempt is permitted per local purchase order, and an accepted response is replayed only when the request hash and idempotency key match. Discovery treats an active contract-version-1 adapter as upgrade-required rather than ready.

The app exposes a compact **Approved Connector** lane in the existing supplier-confirmation sheet and otherwise retains manual confirmation. Johnstone DirectConnect/Punch-out and Lennox Partner remain unavailable until their separate provider onboarding is complete. See `VENDOR_CONNECTORS.md`.

## QuickBooks OAuth bridge

`POST /api/qbo/exchange`, `/api/qbo/refresh`, and `/api/qbo/revoke` are administrator-only backend operations used by the app after the registered HTTPS callback hands the authorization code back to `gunnaireops://`. The bridge encrypts and retains the rotating Intuit refresh token in its persistent database; the app receives only a short-lived access token. The client realm and sandbox/production environment must match the saved backend connection before it can refresh. Set a valid `GUNNAIRE_QBO_TOKEN_ENCRYPTION_KEY` and `GUNNAIRE_QBO_ENVIRONMENT` before authorizing QuickBooks. Store that Fernet key only in the deployment secret manager, keep it stable while a QBO connection exists, and rotate it only through a planned decrypt/re-encrypt migration. Run this backend behind HTTPS in production business-identity mode before connecting a production QBO company; an approved Google or Apple application session receives the same server-enforced role.

The realm-bound accounting configuration includes the default sales item plus income, expense/COGS, Accounts Payable, bank, and credit-card accounts. Version `2026.08.30.15` adds the three Accounts Payable columns as a forward-compatible migration with empty defaults for an existing database. An existing realm therefore remains readable but intentionally fails readiness until an administrator using GunnAire Ops build `2026083001` or later reopens **QuickBooks Management → Overview → Accounting Mappings**, selects a provider account whose type is exactly `Accounts Payable`, and saves the reviewed configuration. Do not populate or guess that reference from an environment variable.

## QuickBooks change webhooks

Configure Intuit's current CloudEvents v1.0 webhook destination as:

```text
https://gunnaire-api.onrender.com/api/qbo/webhooks
```

Copy the verifier token supplied by Intuit into the encrypted Render variable `GUNNAIRE_QBO_WEBHOOK_VERIFIER_TOKEN`. The receiver verifies the `intuit-signature` HMAC against the exact request body, rejects legacy or malformed payloads, accepts only events for the currently authorized QBO company realm, and deduplicates Intuit event IDs. It retains only the event ID, entity type/ID, operation, and timestamps. Admin clients can read pending metadata at `GET /api/qbo/webhook-events`; the app acknowledges the exact event IDs only after a complete successful QBO refresh. Failed syncs and events that arrive during a sync remain pending.

Subscribe the entities the app reconciles: Customer, Item, Estimate, Invoice, Vendor, Bill, Purchase, Payment, SalesReceipt, Deposit, PaymentMethod, and Attachable. Add `VendorCredit` only after GunnAire Ops build `2026083001` or later is deployed; that build includes Vendor Credit pagination in the required complete-sync path, so its pending events are acknowledged only after the fetch succeeds. Use Intuit's portal test-event function after both sandbox and production are configured. Until the verifier token exists, the endpoint fails closed and backend readiness reports QuickBooks Change Alerts as requiring attention.

## Quick Checks

```sh
curl http://macstudio.local:8787/health
curl -H "Authorization: Bearer replace-with-a-long-random-token" http://macstudio.local:8787/api/users
curl -H "Authorization: Bearer replace-with-a-long-random-token" http://macstudio.local:8787/api/customer-financing
# Requires Backend/requirements.txt, including cryptography and google-auth.
python3 -m unittest discover -s Backend -p 'test_*.py' -v
```

`/health` includes a non-secret `serviceVersion` marker. After every production
backend change, verify that the live HTTPS response reports the expected marker
before treating the deployment as current.

Field payment records are accepted at `POST /api/payments`. The app sends metadata only: amount, method, customer/invoice references, last four digits, authorization reference, notes, and collector email. Full card numbers, CVC values, and bank account numbers are not stored by this backend.

Administrators can review recent shared-server activity from **Settings → Sync → Shared Server Activity**, or request `GET /api/audit-events`. This log supports operational review; it is not a replacement for an immutable compliance archive or tested backup policy.

Administrators can request `GET /api/readiness` or use **Settings → Sync →
Shared Server Readiness** to verify persistent data placement, SQLite integrity
and write access, document-storage write access, business authentication mode,
customer-financing handoff readiness, encrypted QBO authorization, and recent backup evidence. Details never include
paths, tokens, secrets, or customer content.

Use `Backend/backup_backend.py` for manifest-backed backup creation,
verification, and a non-overwriting restore drill. See
`BACKEND_OPERATIONS_RUNBOOK.md` for the production procedure and ownership
gates. A `backup_status.json` record proves local verification only; retain the
artifact outside Render and its persistent disk.
