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

For a deployed multi-user server, terminate TLS before the backend and use Google ID-token verification:

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

Then set `GUNNAIRE_BACKEND_AUTH_MODE = google-id-token` in the app build configuration, use an HTTPS `GUNNAIRE_BACKEND_BASE_URL`, and omit the shared API token. This production mode accepts either a verified Google ID token or a short-lived GunnAire application session created from a verified Sign in with Apple identity. Both providers must resolve to an already-approved active backend user; neither provider creates or promotes a user. Apple private-relay addresses therefore require an explicit administrator-created user record and are never mapped automatically to another email.

The Apple identity token is verified against Apple's current RS256 public keys, issuer, app audience, expiry, issue time, nonce, subject, and verified email. It is used once and is not stored. The backend persists only a SHA-256 hash of the random application-session token, rechecks the user's active status on every protected request, and supports immediate revocation at `POST /api/auth/logout`. The app stores only that opaque application session in Keychain and checks Apple's credential state on relaunch.

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
GUNNAIRE_QBO_CLIENT_ID=your-intuit-client-id
GUNNAIRE_QBO_CLIENT_SECRET=your-intuit-client-secret
GUNNAIRE_QBO_REDIRECT_URI=https://gunnaire.com/wp-json/ga/v1/qbo/oauth/callback
GUNNAIRE_QBO_ENVIRONMENT=production
GUNNAIRE_QBO_TOKEN_ENCRYPTION_KEY=your-fernet-encryption-key
GUNNAIRE_QBO_WEBHOOK_VERIFIER_TOKEN=your-intuit-webhook-verifier-token
GUNNAIRE_BACKEND_DATA_DIR=/var/data
```

Use `api.gunnaire.com` as the custom HTTPS domain after Render provides its DNS target. Do not enable the public booking or customer portal flags until their customer-facing web routes, privacy notices, and rate-limit testing are ready. Establish an off-host backup of the mounted data before production use.

## What It Stores

- Approved GunnAire app users and roles.
- Active/inactive access state.
- Revocable Sign in with Apple application sessions. Only a one-way SHA-256 session-token hash, provider subject, approved email, creation/use/expiry times, and revocation state are retained; Apple identity tokens are not stored.
- Uploaded receipt/document files under `Backend/storage`, retaining their service call, invoice, estimate, customer-equipment, equipment-name, and customer links for cross-device retrieval.
- Field payment collection records for admin QuickBooks reconciliation.
- QuickBooks change-event metadata for the currently authorized company realm. The raw provider payload, realm ID, customer content, and credentials are not retained or returned to the app.
- Transactional email and staff-reviewed service-text audit records, linked to the customer, job, maintenance agreement, estimate/invoice, and attachment names. Each attempt retains its channel, typed workflow/template, authenticated staff actor, consent snapshot, sent/failed/suppressed state, safe provider detail, and result time. Text recipients are normalized and validated before storage. Active staff may append their own evidence; only administrators may list company-wide communication history. The backend stores no message body and does not itself send automated SMS.
- Administrator-only server activity events for role changes, shared-document uploads, payment metadata, customer-communication records, booking claims, and QuickBooks authorization lifecycle actions. Tokens, card data, and customer-content fields are intentionally not recorded.
- An optional public online-booking request inbox. It never creates a job directly: dispatch imports, qualifies, and schedules each request.
- Optional customer-portal link metadata. Only a SHA-256 token hash is stored; management responses contain no URL or token. Open count and last-opened time are operational hints only and may include mail or security previews.
- Backend metadata in `gunnaire_backend.sqlite3`.

The primary admin `eric.gunn@gunnaire.com` is seeded automatically and cannot be deactivated.

Shared-document uploads validate all metadata before a file is written and reject files above `GUNNAIRE_MAX_DOCUMENT_BYTES` (12 MiB by default). Browser CORS is deny-by-default; configure only the specific HTTPS origins that need it with `GUNNAIRE_ALLOWED_CORS_ORIGINS`. Native GunnAire Ops clients are unaffected.

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

## QuickBooks OAuth bridge

`POST /api/qbo/exchange`, `/api/qbo/refresh`, and `/api/qbo/revoke` are administrator-only backend operations used by the app after the registered HTTPS callback hands the authorization code back to `gunnaireops://`. The bridge encrypts and retains the rotating Intuit refresh token in its persistent database; the app receives only a short-lived access token. The client realm and sandbox/production environment must match the saved backend connection before it can refresh. Set a valid `GUNNAIRE_QBO_TOKEN_ENCRYPTION_KEY` and `GUNNAIRE_QBO_ENVIRONMENT` before authorizing QuickBooks. Store that Fernet key only in the deployment secret manager, keep it stable while the QBO connection exists, and rotate it only through a planned decrypt/re-encrypt migration. Run this backend behind HTTPS and in Google ID-token mode before connecting a production QBO company.

## QuickBooks change webhooks

Configure Intuit's current CloudEvents v1.0 webhook destination as:

```text
https://gunnaire-api.onrender.com/api/qbo/webhooks
```

Copy the verifier token supplied by Intuit into the encrypted Render variable `GUNNAIRE_QBO_WEBHOOK_VERIFIER_TOKEN`. The receiver verifies the `intuit-signature` HMAC against the exact request body, rejects legacy or malformed payloads, accepts only events for the currently authorized QBO company realm, and deduplicates Intuit event IDs. It retains only the event ID, entity type/ID, operation, and timestamps. Admin clients can read pending metadata at `GET /api/qbo/webhook-events`; the app acknowledges the exact event IDs only after a complete successful QBO refresh. Failed syncs and events that arrive during a sync remain pending.

Subscribe the entities the app reconciles: Customer, Item, Estimate, Invoice, Vendor, Bill, Purchase, Payment, SalesReceipt, Deposit, PaymentMethod, and Attachable. Use Intuit's portal test-event function after both sandbox and production are configured. Until the verifier token exists, the endpoint fails closed and backend readiness reports QuickBooks Change Alerts as requiring attention.

## Quick Checks

```sh
curl http://macstudio.local:8787/health
curl -H "Authorization: Bearer replace-with-a-long-random-token" http://macstudio.local:8787/api/users
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
encrypted QBO authorization, and recent backup evidence. Details never include
paths, tokens, secrets, or customer content.

Use `Backend/backup_backend.py` for manifest-backed backup creation,
verification, and a non-overwriting restore drill. See
`BACKEND_OPERATIONS_RUNBOOK.md` for the production procedure and ownership
gates. A `backup_status.json` record proves local verification only; retain the
artifact outside Render and its persistent disk.
