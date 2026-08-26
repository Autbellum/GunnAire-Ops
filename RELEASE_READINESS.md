# GunnAire Ops release readiness

Last reviewed: 2026-08-26

## Current result

The iOS target builds for the configured iPhone and iPad simulators and launches successfully. The current iPad verification passed **355 tests** (**349 unit + 6 UI**) on an iPad Pro 13-inch simulator on 2026-08-26 with **0 failures and 0 skipped tests**. Unsigned iPhone Simulator, iPad Simulator, and Mac Catalyst **Release** builds also compile successfully. Release builds use the deployed HTTPS Render backend and explicitly clear the legacy shared API token, preventing a developer LAN endpoint or static administrator-equivalent token from being archived accidentally. The project is still **not ready to upload to TestFlight, Mac App Store, or submit to App Review** until the physical-device, OAuth, privacy, App Store Connect, and Mac Catalyst provisioning requirements below are complete. See `COMPLETION_EVIDENCE_MATRIX.md` for the product-by-product evidence and gate owners.

## What is implemented

- HVAC customer, equipment, work-order, repair, replacement, maintenance, estimate, invoice, payment, document, email-history, purchase-order, inventory ledger/replenishment, qualified lead intake, exception-safe warranty/callback/no-access outcomes, and role-aware operations workflows. Dispatch considers crew conflicts, equipment qualifications, declared service areas, and dispatcher-managed breaks, training, time off, and unavailable time. A dedicated full-screen iPad/Mac week board supports drag or accessible-menu rescheduling with conflict rejection, durable activity history, and safe Google Calendar ownership boundaries; none of these tools claim live GPS or traffic accuracy.
- QBO authorization-code exchange, refresh, and revoke through the backend. The QBO client secret is server-only and is no longer included in the iOS app's Info.plist.
- Google sign-in, Gmail and Calendar workflow integration, with backend identity-token mode for production authorization.
- A small Python/SQLite backend for approved users and roles, shared documents, communications, payment records, and QBO confidential OAuth operations. See `Backend/README.md`.
- Vendor connector contracts and purchase-order workflow. Live Lennox/Johnstone ordering remains deliberately disabled until vendor credentials, terms, and a server-side connector have been approved. See `VENDOR_CONNECTORS.md`.
- Safe local-data startup behavior: if SwiftData cannot open the persistent store, the app now preserves the existing store and presents recovery guidance rather than deleting data or silently using a temporary in-memory database.
- iPad-first split navigation that remains expanded on iPad and Mac Catalyst, with iPhone retaining a compact detail flow. The sign-in surface has been visually checked at iPhone and iPad scales.
- A device-level CloudKit readiness check is shown in administrator settings before staff rely on cross-device continuity. The 21-model SwiftData schema has been initialized in the development container and deployed to the production CloudKit environment. Private CloudKit sync supports the approved company iCloud account across its devices; it is not a replacement for the shared-company backend when staff use individual iCloud accounts.
- The Payments workspace includes a deployed, server-authorized field-collection task flow for separately signed-in technicians. It is ready for field use after testing the production service with an office account plus a technician account on physical devices.
- Invoice-capable users can add existing catalog lines or create a service/non-inventory item inline, set quantities, and preserve those quantities in local totals, job cost, document revisions, and the QBO invoice payload. A connected QBO session publishes newly created items immediately; each locally created item retains a durable pending/needs-attention/synced state, and a compact `Publish Pending` action retries items created while offline. Confirm production QBO income-account configuration and reconcile a live item/invoice before release.

## Required deployment decisions before TestFlight

1. Complete production-service operations. The Render backend is deployed behind HTTPS at `https://gunnaire-api.onrender.com`, reports healthy at `/health`, and has Google ID-token mode plus server-only QBO production configuration. Before TestFlight, confirm persistent-disk/database retention, automated backups, a restoration drill, monitoring/alerts, and key-rotation ownership. Release builds already point to this HTTPS service and clear the legacy static API token.
2. Validate the new Google iOS OAuth client on physical devices. The production client is registered for bundle ID `com.gunnaire.businesssuite` and Apple Team ID `7C4B3RR7RD`; the app and Render backend use the same public client ID. Verify sign-in, Gmail send, Calendar create/update/delete, and backend role denial with production business accounts. Existing sessions created with the superseded client may need to sign in again. Intuit Development and Production already contain the exact `https://gunnaire.com/wp-json/ga/v1/qbo/oauth/callback` redirect; still verify token refresh and QBO company selection end to end.
3. Validate Universal Links on physical devices. The app has `applinks:gunnaire.com`, and the live Apple App Site Association file now lists `7C4B3RR7RD.com.gunnaire.businesssuite` while retaining the superseded identifier during migration. Confirm the QBO and Google callback paths open the installed release candidate as expected.
4. Complete App Store Connect privacy answers using the actual deployed app and every third-party service. The app processes contact details, customer HVAC/equipment records, documents/photos, emails, invoice/payment information, and user identity. Provide public privacy-policy and customer data/deletion URLs; this repository does not contain those public policy pages.
5. Create the App Store Connect record, confirm the bundle identifier `com.gunnaire.businesssuite`, signing team, App ID capabilities, age rating, export-compliance response, screenshots, support URL, and privacy URLs. Do not upload a build until steps 1-4 are complete and the full test suite is rerun against the release candidate.
6. For external TestFlight, provide beta description, test instructions, demo/approved business-account access if required, and a monitored feedback email. Include instructions that exercise a technician, dispatcher, accounting user, and administrator without exposing a production customer account.
7. Before distributing a Mac build, create/select the Mac Catalyst distribution profile, signing configuration, and Mac App Store Connect availability. The project has `SUPPORTS_MACCATALYST=YES`; a signed development build now succeeds with Apple Development and the generated `Mac Catalyst Team Provisioning Profile: com.gunnaire.businesssuite`, but that does not prove App Store distribution readiness.

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

The current implementation has been verified in simulators, local backend tests, and against the deployed backend health endpoint. A signed archive, physical-device OAuth/role/Handoff validation, deployed-backend recovery test, production vendor onboarding, and App Store Connect submission remain intentionally unclaimed.
