# GunnAire Ops release readiness

Last reviewed: 2026-08-26

## Current result

The iOS target builds for the configured iPhone and iPad simulators and launches successfully. The full Xcode scheme passed **348 tests** on an iPad Pro 13-inch simulator on 2026-08-26 with **0 failures and 0 skipped tests**, including unauthenticated sign-in and authenticated iPad sidebar navigation to all primary operations workspaces. Unsigned iPhone Simulator, iPad Simulator, and Mac Catalyst **Release** builds also compile successfully. Release builds use the deployed HTTPS backend and explicitly clear the legacy shared API token, preventing a developer LAN endpoint or static administrator-equivalent token from being archived accidentally. The project is still **not ready to upload to TestFlight, Mac App Store, or submit to App Review** until the external deployment, physical-device, privacy, App Store Connect, and Mac Catalyst provisioning requirements below are complete. See `COMPLETION_EVIDENCE_MATRIX.md` for the product-by-product evidence and gate owners.

## What is implemented

- HVAC customer, equipment, work-order, repair, replacement, maintenance, estimate, invoice, payment, document, email-history, purchase-order, inventory ledger/replenishment, qualified lead intake, exception-safe warranty/callback/no-access outcomes, and role-aware operations workflows. Dispatch considers crew conflicts, equipment qualifications, declared service areas, and dispatcher-managed breaks, training, time off, and unavailable time; those recommendations remain overrideable and never claim live GPS or traffic accuracy.
- QBO authorization-code exchange, refresh, and revoke through the backend. The QBO client secret is server-only and is no longer included in the iOS app's Info.plist.
- Google sign-in, Gmail and Calendar workflow integration, with backend identity-token mode for production authorization.
- A small Python/SQLite backend for approved users and roles, shared documents, communications, payment records, and QBO confidential OAuth operations. See `Backend/README.md`.
- Vendor connector contracts and purchase-order workflow. Live Lennox/Johnstone ordering remains deliberately disabled until vendor credentials, terms, and a server-side connector have been approved. See `VENDOR_CONNECTORS.md`.
- Safe local-data startup behavior: if SwiftData cannot open the persistent store, the app now preserves the existing store and presents recovery guidance rather than deleting data or silently using a temporary in-memory database.
- iPad-first split navigation that remains expanded on iPad and Mac Catalyst, with iPhone retaining a compact detail flow. The sign-in surface has been visually checked at iPhone and iPad scales.
- A device-level CloudKit readiness check is shown in administrator settings before staff rely on cross-device continuity. Private CloudKit sync supports the approved company iCloud account across its devices; it is not a replacement for the shared-company backend when staff use individual iCloud accounts.
- The Payments workspace includes a server-authorized field-collection task flow for separately signed-in technicians. It is ready for production only after the matching backend release is deployed in Google ID-token mode and tested with an office account plus a technician account.
- Invoice-capable users can add existing catalog lines or create a service/non-inventory item inline, set quantities, and preserve those quantities in local totals, job cost, document revisions, and the QBO invoice payload. A connected QBO session publishes newly created items immediately; each locally created item retains a durable pending/needs-attention/synced state, and a compact `Publish Pending` action retries items created while offline. Confirm production QBO income-account configuration and reconcile a live item/invoice before release.

## Required deployment decisions before TestFlight

1. Deploy the backend behind HTTPS. Install `Backend/requirements.txt`; set `GUNNAIRE_BACKEND_AUTH_MODE=google-id-token`, Google client ID, allowed business domain, a durable database path, backup policy, server-only QBO client credentials, stable secret-manager `GUNNAIRE_QBO_TOKEN_ENCRYPTION_KEY`, and `GUNNAIRE_QBO_ENVIRONMENT=production` matching the app build. Supply `GUNNAIRE_BACKEND_BASE_URL` only in the protected release build environment; the checked-in Release target intentionally leaves it blank. Do not ship with the legacy static API token or a local-network-only URL.
2. Register the exact production OAuth redirect URIs with Google and Intuit. Verify sign-in, token refresh, QBO company selection, Gmail send, Calendar create/update/delete, and backend role denial with production accounts.
3. Set the Apple associated-domain entitlement for the production domain and host its Apple App Site Association file. Confirm Universal Links and OAuth callback handling on physical devices.
4. Complete App Store Connect privacy answers using the actual deployed app and every third-party service. The app processes contact details, customer HVAC/equipment records, documents/photos, emails, invoice/payment information, and user identity. Provide public privacy-policy and customer data/deletion URLs; this repository does not contain those public policy pages.
5. Create the App Store Connect record, confirm the bundle identifier `com.gunnaire.businesssuite`, signing team, App ID capabilities, age rating, export-compliance response, screenshots, support URL, and privacy URLs. Do not upload a build until steps 1-4 are complete and the full test suite is rerun against the release candidate.
6. For external TestFlight, provide beta description, test instructions, demo/approved business-account access if required, and a monitored feedback email. Include instructions that exercise a technician, dispatcher, accounting user, and administrator without exposing a production customer account.
7. Before distributing a Mac build, create/select the Mac Catalyst App ID, provisioning profile, signing configuration, and Mac App Store Connect availability. The project has `SUPPORTS_MACCATALYST=YES`; unsigned Catalyst compilation verifies source compatibility but cannot prove Mac signing or distribution readiness.

## Apple privacy manifest

`GunnAire Ops/PrivacyInfo.xcprivacy` declares the data categories used to operate this HVAC field-service application. They are linked to a business account or customer record, are used only for app functionality, and are not used for tracking: contact details; outbound email or message content; work-order documents and photos; account IDs; invoice and payment-record financial information; and HVAC/job/form records. It also declares these required-reason APIs found in the target source:

- `UserDefaults` (`CA92.1`) for app-private preferences and pending in-app routes.
- File timestamps (`C617.1`) for metadata of files held in the app container.

The release manager must still confirm these declarations against the deployed backend, QBO, Google, and any subsequently enabled vendor SDKs before upload. App Store Connect privacy responses must describe the real collection and transmission performed by the deployed app and its services.

## Verification commands

```sh
xcodebuild build -project 'GunnAire Ops.xcodeproj' -scheme 'GunnAire Ops' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO

xcodebuild test -project 'GunnAire Ops.xcodeproj' -scheme 'GunnAire Ops' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO

python3 -m py_compile Backend/gunnaire_backend.py
```

The current implementation has only been verified in the simulator and with local backend checks. A signed archive, physical-device OAuth validation, deployed-backend health/recovery test, production vendor onboarding, and App Store Connect submission are intentionally not performed by this repository.
