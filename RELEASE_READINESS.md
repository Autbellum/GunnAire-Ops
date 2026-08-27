# GunnAire Ops release readiness

Last reviewed: 2026-08-26

## Current result

The iOS target builds for the configured iPhone and iPad simulators and launches successfully. The current iPad verification passed **413 unique tests** (**388 unit + 25 unique UI**) on an iPad Pro 13-inch (M5) simulator running iOS 26.5 on 2026-08-26 with **0 failures and 0 skipped tests**. The results recorded 416 device executions because one launch test runs in four appearance/orientation combinations. Generic arm64 iOS device and universal arm64/x86_64 Mac Catalyst **Release** builds also compile successfully, and both binaries are clean of Debug-only test identities, fixtures, and CloudKit bootstrap flags. Release builds use the deployed HTTPS Render backend and clear the legacy shared API token. The Render entrypoint delegates to the canonical tested backend; the current deployment adds secure QBO CloudEvents change awareness to its Admin-only readiness and backup controls while retaining encrypted, server-held refresh tokens. Production deployment of `serviceVersion: 2026.08.26.4` is verified after the corresponding commit is live. The corrective-work and invoice-sync CloudKit field migration is deployed and verified in Production; thirteen newer optional Customer/ServiceCall/Estimate/Technician/Item fields remain a Production schema gate. The project is still **not ready to upload to TestFlight, Mac App Store, or submit to App Review** until the physical-device, OAuth, privacy, App Store Connect, and Mac Catalyst provisioning requirements below are complete. See `COMPLETION_EVIDENCE_MATRIX.md` for the product-by-product evidence and gate owners.

## What is implemented

- HVAC customer, equipment, work-order, repair, replacement, maintenance, estimate, invoice, payment, document, email-history, purchase-order, inventory ledger/replenishment, qualified lead intake, exception-safe warranty/callback/no-access outcomes, and role-aware operations workflows. Job documentation is staged into Work, Files, Billing, and Closeout so technicians and office users see the next relevant tools without losing access to any capability; unpaid linked invoices recommend Billing, completed/paid work recommends Closeout, and explicit collection still opens invoice closeout directly. Dispatch considers crew conflicts, equipment qualifications, declared service areas, and dispatcher-managed breaks, training, time off, and unavailable time. A dedicated full-screen iPad/Mac week board supports drag or accessible-menu rescheduling with conflict rejection, durable activity history, and safe Google Calendar ownership boundaries; none of these tools claim live GPS or traffic accuracy.
- Warranty and callback follow-ups now preserve the original-job link in both directions and retain a concise corrective reason. Dispatch sees a single conditional callback/warranty badge; authorized staff can open the original or scheduled corrective visit directly; and the new visit inherits system/schedule context without copying old readings or completed checklist evidence.
- QBO authorization-code exchange, refresh, revoke, and signed CloudEvents v1.0 change awareness through the backend. The client secret and verifier remain server-only. QuickBooks Management separates Overview, Sales, Expenses, and Payments while retaining a persistent read-only Sync action. Overview shows safe pending change metadata; exact events are acknowledged only after a complete successful refresh. Sales centralizes pending/attention invoice recovery, uses QBO's current `SyncToken` with the complete durable line list, routes missing mappings to Job Billing, protects paid/finalized history, and gives administrators a review queue for field-created pricebook items. Approval records the reviewer and time, reconciles only a unique compatible QBO item, fails closed on ambiguity, and otherwise creates the configured QBO item. Payments maps provider cards only to an exact or uniquely matched customer and persists only opaque provider IDs plus masked metadata; full card numbers, CVCs, and one-time tokens are excluded, and recurring charges remain disabled. Intuit's verifier token, sandbox/production subscriptions, and provider test events remain external configuration gates.
- QBO completed-time integration is enabled with explicit per-technician Employee/Vendor mapping in Sync & Integrations. Clock-out records remain local when QBO is unavailable or a mapping is absent. Each create carries the stable local TimeEntry ID, and Retry reconciles that marker before publishing so an uncertain response cannot silently duplicate time or switch the worker reference. Production still requires the accounting owner to enter and verify each technician's exact QBO ID.
- Google sign-in, Gmail and Calendar workflow integration, with backend identity-token mode for production authorization.
- Estimate and change-order approval now uses a focused evidence sheet instead of a one-tap status change. In-person approval requires a drawn customer signature; email, text, and phone/verbal approval require a traceable authorization reference. The customer name, method, timestamp, staff recorder, reference or signature, and exact estimate revision remain together; the PDF includes the approval fields and drawn signature. Material scope or price changes continue through a separately approved change order so the original evidence remains immutable.
- A small Python/SQLite backend for approved users and roles, shared documents, communications, payment records, and QBO confidential OAuth operations. Render's root launcher imports this canonical implementation rather than maintaining a second copy; deployment tests protect the dependency and no-refresh-token client contract. Administrators can inspect a server-enforced readiness snapshot in Settings → Sync, while manifest/hash backup verification and a non-destructive restore-drill utility support the recovery runbook without exposing server paths or secrets. See `Backend/README.md` and `BACKEND_OPERATIONS_RUNBOOK.md`.
- Vendor connector contracts and purchase-order workflow. Live Lennox/Johnstone ordering remains deliberately disabled until vendor credentials, terms, and a server-side connector have been approved. See `VENDOR_CONNECTORS.md`.
- Receipts & Bills is separated into Documents, Purchasing, Inventory, and Recovery workspaces for administrators; field users receive the Documents lane only. QuickBooks upload retry results remain visible from every lane, and deleting one retry record or clearing the queue requires confirmation that explains source files remain but automatic retry stops.
- Service-call detail is separated into Overview, Work, Billing, and History. Active jobs open Work; Accounting and Admin users with an invoiced open balance open Billing; completed/cancelled jobs open History; and field, dispatcher, and standard users never receive the Billing lane. The next status action stays directly below the workspace selector, while Schedule day cards use an explicit details chevron that cannot be confused with edit or delete.
- Customer records are separated into Overview, Systems, Files, and History. Account and consent work no longer competes with equipment editors, file capture, agreements, masked payment-method references, and job/email history; shared-company documents load when Files is selected. Financial roles can inspect masked methods on file while QuickBooks retains the credential. Customer-directory actions are independent accessible controls. Standard and Accounting records are read-only, Dispatch and Admin can maintain operations, only Admin can delete or sync customer records to QBO, and technicians use assigned-job context instead of the all-customer directory.
- Maintenance agreement work orders carry the agreement ID and original obligation due date, reopen an already-scheduled obligation instead of duplicating it, and advance cadence only through an explicit completion path. Customer Systems shows compact completed/open visit counts, job Overview identifies the obligation, and agreement-management attention is hidden from field technicians while their assigned maintenance job cards remain available.
- Accounting and Admin accounts have a dedicated Business Reports workspace with focused Overview, Sales, Operations, and Team lanes plus current-month, prior-month, rolling-90-day, and year-to-date periods. CSV export uses the same visible snapshot. Collections are net of refunds, and profit/margin stay unavailable until invoice material costs, technician loaded rates, and completed-job time coverage are complete.
- Safe local-data startup behavior: if SwiftData cannot open the persistent store, the app now preserves the existing store and presents recovery guidance rather than deleting data or silently using a temporary in-memory database.
- iPad-first split navigation that remains expanded on iPad and Mac Catalyst, with iPhone retaining a compact detail flow. The sign-in surface has been visually checked at iPhone and iPad scales.
- A device-level CloudKit readiness check is shown in administrator settings before staff rely on cross-device continuity. The 21-model SwiftData record types, 36-field `CD_ServiceCall` schema, and 16-field `CD_Invoice` schema are deployed in Production. Thirteen optional fields are implemented and locally verified but must still be initialized and deployed in CloudKit Production before TestFlight: `CD_Customer.storedPaymentMethodsJSON`; `CD_ServiceCall.maintenanceAgreementID` and `CD_ServiceCall.maintenanceAgreementDueDate`; `CD_Estimate.customerApprovalMethodRaw`, `CD_Estimate.customerApprovalReference`, `CD_Estimate.customerApprovalRecordedByEmail`, and `CD_Estimate.customerApprovalSignatureImageBase64`; `CD_Technician.quickBooksTimeEntityKindRawValue` and `CD_Technician.quickBooksTimeEntityRef`; and `CD_Item.pricebookReviewStatusRawValue`, `CD_Item.pricebookCreatedByEmail`, `CD_Item.pricebookReviewedByEmail`, and `CD_Item.pricebookReviewedAt`. Private CloudKit sync supports the approved company iCloud account across its devices; it is not a replacement for the shared-company backend when staff use individual iCloud accounts.
- The Payments destination separates balance/readiness in Overview, active field tasks and unpaid invoices in Collect, and shared records/QBO follow-up/receipts/refunds in History. Field users open directly in Collect, and every Handoff or deep-link request selects Collect before authorization, assignment, and balance checks so recovery messages remain visible. The deployed server-authorized task flow still limits technicians to their assigned work. Lead and explicitly assigned additional-crew technicians can collect only invoices linked to their own jobs; unassigned field users and non-collection roles cannot see those invoices. Schedule-card collection opens the guarded invoice closeout directly, preserves a valid Tap-to-Pay request, and rejects unauthorized, missing, or already-paid invoice routes. It is ready for field use after testing the production service with an office account plus a technician account on physical devices.
- Invoice-capable users, including technicians working an assigned job, can add existing catalog lines or create a service/non-inventory item inline, adjust quantities directly in the compact builder, and update the same unpaid invoice instead of creating a duplicate. Field-created items remain usable on that job but enter an Admin-only pricebook review queue instead of publishing directly to the company QBO catalog; legacy and Admin-created items remain approved. Quantities remain in local totals, job cost, durable document snapshots, and complete QBO create/update payloads. Saved physical-material quantities hand off to a compact, role-scoped Job Materials section where the supplying truck/warehouse, actor, job, reservation fulfillment, consumption, and returns remain traceable without mutating the customer/QBO invoice. Below-reorder stock can create one durable job/item `Requested` restock record; Purchasing requires administrator review before it becomes a supplier-backed draft, and only an ordered record can be received. Closeout points back to Billing when material use is incomplete. Job mode no longer repeats the full back-office builder/customer editor below these compact controls. Approved locally created items and invoices retain durable QBO publication state for offline retries. Signed, finalized, partially paid, or paid invoices require a separate adjustment rather than destructive line edits. Confirm production QBO income-account configuration and reconcile a live item/invoice/create-update/stock-use/restock cycle before release.

## Required deployment decisions before TestFlight

1. Initialize and deploy `CD_Customer.storedPaymentMethodsJSON`, `CD_ServiceCall.maintenanceAgreementID`, `CD_ServiceCall.maintenanceAgreementDueDate`, `CD_Estimate.customerApprovalMethodRaw`, `CD_Estimate.customerApprovalReference`, `CD_Estimate.customerApprovalRecordedByEmail`, `CD_Estimate.customerApprovalSignatureImageBase64`, `CD_Technician.quickBooksTimeEntityKindRawValue`, `CD_Technician.quickBooksTimeEntityRef`, `CD_Item.pricebookReviewStatusRawValue`, `CD_Item.pricebookCreatedByEmail`, `CD_Item.pricebookReviewedByEmail`, and `CD_Item.pricebookReviewedAt` in CloudKit Production, then verify two-device corrective-job, stored-payment-reference, maintenance-obligation, estimate-approval, technician QBO worker-mapping, and pricebook-review round trips on signed company hardware, including offline edits and recovery. The earlier corrective-work and invoice QuickBooks-sync fields were deployed and verified on 2026-08-26.
2. Complete production-service operations. The Render backend is deployed behind HTTPS at `https://gunnaire-api.onrender.com`; its versioned health response proves the canonical server-only QBO implementation is running. The app now exposes Admin-only persistent-data/database/shared-storage/QBO/backup readiness, and the repository includes verified backup plus restore-drill commands. Before TestFlight, schedule those backups to off-host storage, execute and retain one restore-drill result, configure monitoring/alerts, and assign key-rotation ownership. Release builds already point to this HTTPS service and clear the legacy static API token.
3. Validate the new Google iOS OAuth client on physical devices. The production client is registered for bundle ID `com.gunnaire.businesssuite` and Apple Team ID `7C4B3RR7RD`; the app and Render backend use the same public client ID. Verify sign-in, Gmail send, Calendar create/update/delete, and backend role denial with production business accounts. Existing sessions created with the superseded client may need to sign in again. Intuit Development and Production already contain the exact `https://gunnaire.com/wp-json/ga/v1/qbo/oauth/callback` redirect; still verify token refresh and QBO company selection end to end.
4. Validate Universal Links on physical devices. The app has `applinks:gunnaire.com`, and the live Apple App Site Association file now lists `7C4B3RR7RD.com.gunnaire.businesssuite` while retaining the superseded identifier during migration. Confirm the QBO and Google callback paths open the installed release candidate as expected.
5. Complete App Store Connect privacy answers using the actual deployed app and every third-party service. The app processes contact details, customer HVAC/equipment records, documents/photos, emails, invoice/payment information, and user identity. Provide public privacy-policy and customer data/deletion URLs; this repository does not contain those public policy pages.
6. Complete the existing App Store Connect record for Apple ID `6758308973`:
   confirm App ID capabilities, export compliance, Content Rights, DSA status,
   pricing and private availability; replace the broken support URL; publish
   privacy and data-deletion pages; add screenshots and copyright; and complete
   privacy/accessibility declarations from verified behavior. Do not upload a
   build until steps 1-5 are complete and the full test suite is rerun against
   the release candidate.
7. For external TestFlight, provide beta description, test instructions, demo/approved business-account access if required, and a monitored feedback email. Include instructions that exercise a technician, dispatcher, accounting user, and administrator without exposing a production customer account.
8. Before distributing a Mac build, create/select the Mac Catalyst distribution profile, signing configuration, and Mac App Store Connect availability. The project has `SUPPORTS_MACCATALYST=YES`; a signed development build now succeeds with Apple Development and the generated `Mac Catalyst Team Provisioning Profile: com.gunnaire.businesssuite`, but that does not prove App Store distribution readiness.

## Apple privacy manifest

`GunnAire Ops/PrivacyInfo.xcprivacy` declares the data categories used to operate this HVAC field-service application. They are linked to a business account or customer record, are used only for app functionality, and are not used for tracking: contact details; outbound email or message content; work-order documents and photos; account IDs; invoice and payment-record financial information; and HVAC/job/form records. It also declares these required-reason APIs found in the target source:

- `UserDefaults` (`CA92.1`) for app-private preferences and pending in-app routes.
- File timestamps (`C617.1`) for metadata of files held in the app container.

The release manager must still confirm these declarations against the deployed backend, QBO, Google, and any subsequently enabled vendor SDKs before upload. App Store Connect privacy responses must describe the real collection and transmission performed by the deployed app and its services.

## Live Apple distribution audit

The Apple account and App Store Connect record were inspected read-only on
2026-08-26:

- App Store Connect already contains **GunnAire Ops** (Apple ID `6758308973`),
  version `1.0`, bundle ID `com.gunnaire.businesssuite`, in **Prepare for
  Submission**.
- Distribution is configured as **Private** for Apple Business Manager / Apple
  School Manager custom-app delivery, which matches the employee-only intent.
  Do not change this irreversible choice without an explicit business decision.
- The Free Apps Agreement and U.S. W-9 are active. The Paid Apps Agreement is
  `Pending User Info`; DSA trader status is not complete. No agreement or legal
  attestation was accepted during this audit.
- The Apple Developer account has a valid managed Distribution certificate
  through 2027-06-01. The local Keychain currently has only the Apple
  Development identity, and the portal lists no manual provisioning profiles.
  Xcode has cached iOS development and App Store profiles, but both profiles
  omit the app's iCloud/CloudKit entitlements; the development profile also
  omits push notifications. A local archive therefore stops safely during
  provisioning validation. Xcode must refresh the managed iOS profiles against
  the enabled App ID capabilities before a signed archive can be produced.
  That credential-management step requires an explicit confirmation immediately
  before it runs.
- App Privacy, accessibility declarations, pricing, availability, screenshots,
  build selection, copyright, Content Rights, and DSA setup are incomplete.
  The existing support URL returns HTTP 404, and no public privacy-policy or
  data-deletion page was found on `gunnaire.com`.
- The source now declares `ITSAppUsesNonExemptEncryption = false` for the
  app's exempt use of Apple platform encryption and uses a valid empty
  `UILaunchScreen` dictionary. Both values were verified in the compiled iOS
  and Mac Catalyst Release products.
- Six fictional-data screenshots for each required device family are prepared
  under `AppStoreAssets/Screenshots`: 2064 x 2752 for 13-inch iPad and
  1320 x 2868 for 6.9-inch iPhone. All twelve PNG files passed orientation,
  content, dimension, and no-alpha visual QA. They have not been uploaded to
  App Store Connect.

## Verification commands

```sh
xcodebuild build -project 'GunnAire Ops.xcodeproj' -scheme 'GunnAire Ops' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO

xcodebuild test -project 'GunnAire Ops.xcodeproj' -scheme 'GunnAire Ops' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO

python3 -m py_compile Backend/gunnaire_backend.py
python3 -m unittest Backend.test_deployment_entrypoint Backend.test_qbo_token_storage \
  Backend.test_backend_readiness Backend.test_backup_backend Backend.test_qbo_webhooks -v
```

The current implementation has been verified in simulators, local backend tests, and against the deployed backend health endpoint. A signed archive, physical-device OAuth/role/Handoff validation, deployed-backend recovery test, production vendor onboarding, and App Store Connect submission remain intentionally unclaimed.
