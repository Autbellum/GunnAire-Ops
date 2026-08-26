# GunnAire Ops completion evidence matrix

Last audited: 2026-08-26

This matrix evaluates the requested business suite against the repository and
recorded build evidence. **Project verified** means the behavior is implemented
and covered by the listed source/tests or build. **External gate** means the
code cannot prove production readiness because it requires an account owner,
provider contract, signed device, or deployed service.

## Product requirements

| Requirement | Evidence in project | Status | Remaining proof / owner |
| --- | --- | --- | --- |
| HVAC service lifecycle | CRM, equipment/serial/warranty history, requests, estimates, work orders, field forms, reports, invoices, payments, agreements, callbacks, warranty, no-access and follow-up flows; see `CAPABILITY_AUDIT.md` and tests such as `noAccessVisitCannotCreateBillingButKeepsRescheduleContext`. | Project verified | Exercise with representative production data during staff acceptance. |
| Repair, replacement, and service files | `ServiceCall`, `ServiceDocumentAttachment`, generated documentation, customer/equipment history, and invoice/estimate links; attachment-linking and generated-report tests cover the trace. | Project verified | Validate retention policy and storage limits on deployed backend. |
| Transaction emails and invoices | `CustomerCommunication`, Gmail workflow, invoice/estimate links and attachment selection; tests cover report selection, invoice links, and record deduplication. | Project verified | Google production consent and a real outbound delivery test. |
| Scheduling and dispatch | Schedule workspace, customer arrival windows, skills, territory cues, lead/crew assignments, conflict handling, availability blocks, activity timeline, and Google Calendar safeguards. | Project verified | Confirm operational policy for overrides and staff-calendar permissions. |
| Inventory, pricebook, and purchasing | Inventory ledger, stock locations/reservations, job-linked POs, receipt traceability, vendor catalog fields, QBO vendor mapping, and safe supplier-order copy action. Invoice-capable users can create/select service or non-inventory lines and set quantities; the quantity is retained through document revisions, totals, job cost, and the QBO invoice payload. New items publish to QBO immediately when connected; locally created items retain durable pending/needs-attention/synced state and a compact batch retry action. | Project verified in source/build, catalog-state, snapshot, and QBO payload tests | Reconcile physical starting inventory, configure QBO income-account references, and perform a production item/invoice reconciliation. |
| Roles and account restrictions | Google business login, role-scoped navigation/actions, job-level field visibility, backend authorization, restricted-route cleanup, and duplicate CloudKit staff-record convergence. | Project verified | Deploy backend in Google ID-token mode and test each role on physical devices. |
| iPad/Mac-first usability | Persistent split navigation on iPad/Mac Catalyst, compact phone flow, Command Center priority/dispatch first, discoverable search, and lower-frequency dashboard details collapsed by default. | Project verified | Staff usability review on actual iPad and Mac displays. |
| iPad-to-iPhone payment handoff | Handoff activity carries only invoice ID/amount; role/job access and paid/balance validation are applied on receiving device. In addition, the backend has an auditable field-collection assignment contract: office roles create/cancel, technicians view/accept only their own active tasks, and the iPad Payments workspace exposes the workflow without adding a separate overloaded destination. | Project verified locally | Publish and deploy the backend assignment endpoint in Google-ID-token mode, then verify separate technician and office accounts on physical devices. Apple Handoff itself still requires the same Apple Account. |
| CloudKit continuity | Private container configuration, remote notification mode, optional relationships with explicit inverses, offline disclosure/recovery, duplicate-role convergence guard, and a live device iCloud-account readiness check in administrator settings. | Project verified | Initialize development schema, test two signed devices online/offline, and deploy schema in CloudKit Console. Private CloudKit sync is for company devices using the same approved iCloud account; individually signed-in staff require the shared-company backend. |
| QuickBooks Online | OAuth bridge, local reconciliation, attachment queues, payment metadata/idempotency, role boundary, QBO management workspace, and encrypted server-side refresh-token rotation. Mobile clients receive only short-lived QBO access tokens; refreshes must match the saved company realm and sandbox/production environment. | Project verified | Intuit production approval, deployed HTTPS backend with a stable secret-manager encryption key and matching QBO environment, realm authorization, accounting-owner reconciliation, webhook validation. |
| Google Gmail/Calendar | Google sign-in, calendar create/update/delete only for app-managed events, Gmail delivery records, and account-scoped routing. | Project verified | OAuth consent/scopes/redirect approval and real production-account tests. |
| Vendor connectors | Supplier connector contract exists with no app-held credentials; PO workflow and manual supplier fallback are available. Johnstone DirectConnect/Punch-out and Lennox remain provider-gated. | Project verified for boundary | Supplier onboarding, approved adapter contract/test account, server-side adapter, order approval policy, and live test. |
| Tap to Pay on iPhone | iPad-to-iPhone entry flow is implemented; no card data travels via Handoff. The receiving workflow directs contactless collection to the matching invoice in QuickBooks Mobile or GoPayment, which is Intuit’s supported Tap to Pay experience. | Project verified for safe handoff; first-party QuickBooks capture is external | Enable and test Tap to Pay in QuickBooks Mobile/GoPayment on each field iPhone. If GunnAire needs embedded card-present capture rather than the Intuit app, choose a PSP that offers Apple Tap to Pay support, obtain its entitlement/approval, then complete its sandbox and production certification. |

## Build and test evidence

| Check | Evidence | Result |
| --- | --- | --- |
| iPad Simulator test suite | iPad Pro 13-inch (M5), iOS 26.5, `xcodebuild test`; result bundle `/tmp/GunnAireOps-full-regression-20260826.xcresult`. | **345 passed, 0 failed, 0 skipped**; includes unauthenticated sign-in, authenticated admin iPad sidebar, Schedule, Payments navigation, CloudKit readiness, CloudKit-schema catalog persistence, field-payment Handoff guards, sequential field-task prompts, catalog-state lifecycle, catalog reconciliation, and quantity/legacy invoice-snapshot coverage. |
| QBO OAuth token hardening regression | iPad Pro 13-inch (M5), iOS 26.5, `xcodebuild test -only-testing:'GunnAire OpsTests'`; result bundle `/tmp/GunnAireOps-qbo-token-hardening-20260826.xcresult`; `python3 -m unittest Backend.test_qbo_token_storage -v`. | **345 passed, 0 failed, 0 skipped** after moving QBO refresh-token rotation to encrypted backend storage. Backend regression coverage also passed for access-token-only responses, ciphertext storage/decryption, connection-schema initialization, and fail-closed missing-key behavior. |
| iPad UI navigation suite | iPad Pro 13-inch (M5), iOS 26.5, `xcodebuild test -only-testing:'GunnAire OpsUITests'`; result bundle `/tmp/GunnAireOps-ui-regression-fixed-20260826.xcresult`. | **5 tests passed, 0 failed** (8 runs including appearance/orientation screenshot variants); verifies secure unauthenticated launch, authenticated administrator iPad workspace, primary sidebar navigation, and launch performance. |
| Mac Catalyst compile | Unsigned Release `xcodebuild` Mac Catalyst build, rerun after the current CloudKit, pricebook, handoff, and QBO token-hardening changes. | Passed; only the environment’s missing Metal toolchain search-path warning remains. |
| iPad Simulator Release compile | Unsigned Release build. | Passed. |
| iPhone Simulator Release compile | iPhone 17 Pro, iOS 26.5; unsigned Release build rerun after the current CloudKit, pricebook, and handoff changes. | Passed. |
| CloudKit readiness behavior | Focused iPad simulator unit test for available, no-account, restricted, and undetermined device states. | Passed; physical iCloud account status still requires a signed device. |
| Backend syntax | `python3 -m py_compile Backend/gunnaire_backend.py`. | Passed. |
| Diff integrity | `git diff --check`. | Passed at the audit point. |

## Production gates that the repository cannot complete alone

1. **Apple Account Holder:** Enable the CloudKit container and Remote
   notifications for the App ID, regenerate profiles, initialize/deploy the
   CloudKit schema, request the Tap to Pay entitlement only if an embedded PSP
   integration is selected, and create the App Store Connect/Mac Catalyst records.
2. **Business owner / deployment operator:** Deploy the backend behind HTTPS in
   `google-id-token` mode, set durable database backups and restoration tests,
   configure public privacy/support/deletion URLs, and protect all provider
   secrets outside the app.
3. **Accounting owner:** Approve QBO mapping, company/realm authorization,
   reconciliation procedure, payment accounting rules, and production test
   results before enabling accounting mutations.
4. **Google administrator:** Approve OAuth consent, production redirects,
   Gmail/Calendar scopes, and staff-account policy.
5. **Supplier account manager / business owner:** Approve Johnstone, Lennox,
   or other vendor terms, branch/account pricing, ordering authority, and test
   credentials before any server connector can send an order.
6. **Field operations lead:** Run a physical-device acceptance script covering
   no-network field documentation, CloudKit recovery, iPad-to-iPhone Handoff,
   declined/interrupted payment recovery, dispatch overrides, and each role.

Until the gates above are evidenced, the app is not represented as TestFlight
or App Store ready. The project-side implementation is prepared for those
steps without shipping development credentials or pretending provider
capabilities are live.
