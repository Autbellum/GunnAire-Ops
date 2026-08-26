# GunnAire Ops API Setup

This app reads its API credentials from Xcode build settings, not from hardcoded Swift source.

## Files

- `Config/Base.xcconfig`: shared defaults checked into the repo.
- `Config/Local.example.xcconfig`: template for a real machine-local config.
- `Config/Local.xcconfig`: your real secrets file on this Mac. Create it locally and do not commit it.

## New Computer Setup

1. Duplicate `Config/Local.example.xcconfig` as `Config/Local.xcconfig`.
2. Paste in the public QuickBooks client ID and Google OAuth values. Keep the QuickBooks client secret only in the backend environment as `GUNNAIRE_QBO_CLIENT_SECRET`.
3. Use the provider-registered HTTPS redirect URIs documented in `OAUTH_CALLBACK_BRIDGE.md`, not the final `gunnaireops://` app callback.
4. Open `GunnAire Ops.xcodeproj` in Xcode.
5. Select the project, then the `GunnAire Ops` target.
6. For both `Debug` and `Release`, confirm the Base Configuration points at `Config/Base.xcconfig`.
7. Build and run. The app will inject those values into `Info.plist` and `Config.swift` will read them automatically.

## Required Values

- `QB_CLIENT_ID`
- `QB_REDIRECT_URI`
- `QB_CALLBACK_SCHEME`
- `QB_ENVIRONMENT`
- `QB_DEFAULT_ITEM_REF`
- `QB_DEFAULT_INCOME_ACCOUNT_REF`
- `QB_DEFAULT_EXPENSE_ACCOUNT_REF`
- `GOOGLE_CLIENT_ID`
- `GOOGLE_CLIENT_SECRET`
- `GOOGLE_REDIRECT_URI`
- `GOOGLE_CALLBACK_SCHEME`
- `GOOGLE_ALLOWED_HOSTED_DOMAIN`

## QuickBooks backend bridge

The iOS client does not use `QB_CLIENT_SECRET`. Configure these environment variables where `Backend/gunnaire_backend.py` runs:

- `GUNNAIRE_QBO_CLIENT_ID`
- `GUNNAIRE_QBO_CLIENT_SECRET`
- `GUNNAIRE_QBO_REDIRECT_URI`
- `GUNNAIRE_QBO_TOKEN_ENCRYPTION_KEY` (a Fernet key generated and retained only in the deployment secret manager)
- `GUNNAIRE_QBO_ENVIRONMENT` (`sandbox` or `production`, exactly matching `QB_ENVIRONMENT` in the app build)

For production, expose that backend only via HTTPS. Rotate any Intuit client secret that was previously stored in an `.xcconfig` file before releasing a build.

For a multi-user deployment, set `GUNNAIRE_BACKEND_AUTH_MODE = google-id-token` in the app configuration and follow the Google ID-token verification setup in `Backend/README.md`. The legacy shared `GUNNAIRE_BACKEND_API_TOKEN` mode is for a controlled LAN/development setup only.

## Product Catalog

The in-app product catalog is the SwiftData `Item` model used by the billing flow. Invoice-capable users can select existing catalog lines or create service/non-inventory items in Invoices & Estimates, set quantities, and retain the selected price/cost/quantity in each document snapshot.

When the authorized company QBO session is connected, newly created items publish immediately as QBO service or non-inventory items. Existing matching QBO items are linked rather than duplicated. Each local item keeps a durable `pending`, `needs_attention`, or `synced` state, and the invoice builder exposes a compact **Publish Pending** retry action.

The app receives only a short-lived QBO access token. The backend encrypts and retains the rotating company refresh token using `GUNNAIRE_QBO_TOKEN_ENCRYPTION_KEY`; do not copy that credential or key into a technician device or shared configuration file. For separate staff Apple accounts, deploy the backend in `google-id-token` mode and use the field-collection/task APIs for company workflows.
