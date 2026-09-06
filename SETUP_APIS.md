# GunnAire Ops API Setup

This app reads its API credentials from Xcode build settings, not from hardcoded Swift source.

## Files

- `Config/Base.xcconfig`: shared defaults checked into the repo.
- `Config/Local.example.xcconfig`: template for a real machine-local config.
- `Config/Local.xcconfig`: your real secrets file on this Mac. Create it locally and do not commit it.

## New Computer Setup

1. Duplicate `Config/Local.example.xcconfig` as `Config/Local.xcconfig`.
2. Paste in the public QuickBooks client ID and the Google iOS OAuth client/reversed-client values. Keep the QuickBooks client secret only in the backend environment as `GUNNAIRE_QBO_CLIENT_SECRET`; a native Google iOS client does not use a client secret.
3. Use the QuickBooks HTTPS callback bridge and the native Google reversed-client callback documented in `OAUTH_CALLBACK_BRIDGE.md`.
4. Open `GunnAire Ops.xcodeproj` in Xcode.
5. Select the project, then the `GunnAire Ops` target.
6. For both `Debug` and `Release`, confirm the Base Configuration points at `Config/Base.xcconfig`.
7. Build and run. The app will inject those values into `Info.plist` and `Config.swift` will read them automatically.

## Required Values

- `QB_CLIENT_ID`
- `QB_REDIRECT_URI`
- `QB_CALLBACK_SCHEME`
- `QB_ENVIRONMENT`
- `GOOGLE_CLIENT_ID`
- `GOOGLE_REVERSED_CLIENT_ID`
- `GOOGLE_REDIRECT_URI`
- `GOOGLE_CALLBACK_SCHEME`
- `GOOGLE_ALLOWED_HOSTED_DOMAIN`

## Google Workspace APIs

The implemented product boundary, security controls, current test evidence, and
signed-device production checklist are maintained in
`GOOGLE_INTEGRATION_ACCEPTANCE.md`.

Use one Google Cloud project and its iOS OAuth client for the GunnAire bundle.
In **Google Cloud Console → APIs & Services → Library**, enable:

- Gmail API;
- Google Calendar API; and
- Google Drive API.

In **Google Auth Platform → Data Access**, configure only the user-facing
scopes used by this app:

- `openid`, `profile`, and `email` for business identity;
- `https://www.googleapis.com/auth/calendar` for GunnAire-managed schedule
  events;
- `https://www.googleapis.com/auth/gmail.modify` for customer email delivery
  and retained provider status; and
- `https://www.googleapis.com/auth/drive.file` for files the app creates or
  the user explicitly opens with the app.

Do not substitute broad Drive access or Google Workspace administrator scopes.
Complete the Google consent-screen publishing/verification process required for
the selected user type and scopes, list `gunnaire.com` as the approved business
domain, and keep test users current until the app is published. Organization
policy must allow the scopes for the GunnAire Workspace account.

The iOS OAuth client must match the public values in `Config/Base.xcconfig`:
the client ID ends in `.apps.googleusercontent.com`; the reversed client ID and
callback scheme are `com.googleusercontent.apps.<client>`; the redirect URI is
that same scheme followed by `:/oauth2redirect`; and the reversed scheme is in
the app's URL Types. The release preflight checks all four values together.

After `drive.file` is approved, every previously connected user must open
**Settings → Google Workspace**, disconnect, and reconnect the matching
`@gunnaire.com` account. Legacy tokens without the new scope intentionally fail
closed. An administrator can then archive a queued internal service report,
invoice/estimate support file, receipt, agreement, or related customer file
from **Sync & Integrations → Google Drive Archive**. Uploads reserve a stable
Drive file ID, use resumable transfer, reconcile an uncertain response by the
app-owned ID/metadata, and retain the Drive link, actor, status, and retry detail
in CloudKit. The app cannot browse unrelated Drive content.

## QuickBooks backend bridge

The iOS client does not use `QB_CLIENT_SECRET`. Configure these environment variables where `Backend/gunnaire_backend.py` runs:

- `GUNNAIRE_QBO_CLIENT_ID`
- `GUNNAIRE_QBO_CLIENT_SECRET`
- `GUNNAIRE_QBO_REDIRECT_URI`
- `GUNNAIRE_QBO_TOKEN_ENCRYPTION_KEY` (a Fernet key generated and retained only in the deployment secret manager)
- `GUNNAIRE_QBO_ENVIRONMENT` (`sandbox` or `production`, exactly matching `QB_ENVIRONMENT` in the app build)

For production, expose that backend only via HTTPS. Rotate any Intuit client secret that was previously stored in an `.xcconfig` file before releasing a build.

For a multi-user deployment, set `GUNNAIRE_BACKEND_AUTH_MODE = google-id-token` in the app configuration and follow the Google ID-token verification setup in `Backend/README.md`. The legacy shared `GUNNAIRE_BACKEND_API_TOKEN` mode is for a controlled LAN/development setup only.

### Realm-bound accounting mappings

Do not put QuickBooks item or account IDs in the app build configuration. After the backend is deployed and the approved company is connected, an administrator must open **QuickBooks Management → Overview → Accounting Mappings** and choose:

- the default sales item;
- the income account for new pricebook items;
- the expense or cost-of-goods account;
- the Accounts Payable liability account used for reviewed supplier Bills and Vendor Credits;
- the bank account used for cash and check purchases; and
- the credit-card liability account used for credit-card purchases.

The backend stores this audited configuration against the exact Intuit company realm and environment. GunnAire Ops refuses new accounting transactions when that mapping is absent or belongs to another company; build-time fallback IDs are not used.

## Product Catalog

The in-app product catalog is the SwiftData `Item` model used by the billing flow. Invoice-capable users can select existing catalog lines or create service/non-inventory items in Invoices & Estimates, set quantities, and retain the selected price/cost/quantity in each document snapshot.

When the authorized company QBO session is connected and its realm-bound accounting mappings are complete, newly approved items publish as QBO service or non-inventory items. Existing matching QBO items are linked rather than duplicated. Each local item keeps a durable `pending`, `needs_attention`, or `synced` state, and the invoice builder exposes a compact **Publish Pending** retry action.

The app receives only a short-lived QBO access token. The backend encrypts and retains the rotating company refresh token using `GUNNAIRE_QBO_TOKEN_ENCRYPTION_KEY`; do not copy that credential or key into a technician device or shared configuration file. For separate staff Apple accounts, deploy the backend in `google-id-token` mode and use the field-collection/task APIs for company workflows.
