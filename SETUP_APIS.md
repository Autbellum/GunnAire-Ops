# GunnAire Ops API Setup

This app reads its API credentials from Xcode build settings, not from hardcoded Swift source.

## Files

- `Config/Base.xcconfig`: shared defaults checked into the repo.
- `Config/Local.example.xcconfig`: template for a real machine-local config.
- `Config/Local.xcconfig`: your real secrets file on this Mac. Create it locally and do not commit it.

## New Computer Setup

1. Duplicate `Config/Local.example.xcconfig` as `Config/Local.xcconfig`.
2. Paste in your real QuickBooks and Google OAuth values.
3. Use the provider-registered HTTPS redirect URIs documented in `OAUTH_CALLBACK_BRIDGE.md`, not the final `gunnaireops://` app callback.
4. Open `GunnAire Ops.xcodeproj` in Xcode.
5. Select the project, then the `GunnAire Ops` target.
6. For both `Debug` and `Release`, confirm the Base Configuration points at `Config/Base.xcconfig`.
7. Build and run. The app will inject those values into `Info.plist` and `Config.swift` will read them automatically.

## Required Values

- `QB_CLIENT_ID`
- `QB_CLIENT_SECRET`
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

## Product Catalog

The in-app product catalog is currently the SwiftData `Item` model used by the billing flow. New catalog items are created in the Invoices & Estimates screen and stored locally on the device.

If you want the catalog to sync with QuickBooks products/services next, the place to extend is the item flow in `BillingDocumentsView.swift` plus the QuickBooks integration layer.
