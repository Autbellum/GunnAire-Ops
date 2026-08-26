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
| Scheduling and dispatch | Schedule workspace, customer arrival windows, skills, territory cues, lead/crew assignments, conflict handling, availability blocks, activity timeline, and Google Calendar safeguards. Dispatch-capable accounts have a full-screen iPad/Mac week board with drag-and-drop plus an accessible move menu; moves preserve time, record an audit event, reject crew/unavailability conflicts, and protect Google-owned events. | Project verified in policy tests, build, and iPad UI navigation/render | Confirm operational policy for deliberate conflict overrides and staff-calendar permissions. |
| Inventory, pricebook, and purchasing | Inventory ledger, stock locations/reservations, job-linked POs, receipt traceability, vendor catalog fields, QBO vendor mapping, and safe supplier-order copy action. Invoice-capable users can create/select service or non-inventory lines and set quantities; the quantity is retained through document revisions, totals, job cost, and the QBO invoice payload. New items publish to QBO immediately when connected; locally created items retain durable pending/needs-attention/synced state and a compact batch retry action. | Project verified in source/build, catalog-state, snapshot, and QBO payload tests | Reconcile physical starting inventory, configure QBO income-account references, and perform a production item/invoice reconciliation. |
| Roles and account restrictions | Google business login, role-scoped navigation/actions, job-level field visibility, backend authorization, restricted-route cleanup, and duplicate CloudKit staff-record convergence. The production backend is deployed in Google ID-token mode. | Project verified; production service configured | Test each role with approved business accounts on physical devices. |
| iPad/Mac-first usability | Persistent split navigation on iPad/Mac Catalyst, compact phone flow, Command Center priority/dispatch first, discoverable search, and lower-frequency dashboard details collapsed by default. | Project verified | Staff usability review on actual iPad and Mac displays. |
| iPad-to-iPhone payment handoff | Handoff activity carries only invoice ID/amount; role/job access and paid/balance validation are applied on receiving device. In addition, the deployed backend has an auditable field-collection assignment contract: office roles create/cancel, technicians view/accept only their own active tasks, and the iPad Payments workspace exposes the workflow without adding a separate overloaded destination. | Project and production endpoint verified | Verify separate technician and office accounts on physical devices. Apple Handoff itself still requires the same Apple Account. |
| CloudKit continuity | Private container configuration, remote notification mode, optional relationships with explicit inverses, offline disclosure/recovery, duplicate-role convergence guard, and a live device iCloud-account readiness check in administrator settings. The signed development build initialized all 21 production model types, and CloudKit Console deployed and verified those types in Production on 2026-08-26. | Project and production schema verified | Test two signed physical devices online/offline. Private CloudKit sync is for company devices using the same approved iCloud account; individually signed-in staff require the shared-company backend. |
| QuickBooks Online | OAuth bridge, local reconciliation, attachment queues, payment metadata/idempotency, role boundary, QBO management workspace, and encrypted server-side refresh-token rotation. Mobile clients receive only short-lived QBO access tokens; refreshes must match the saved company realm and sandbox/production environment. The HTTPS backend is deployed with a stable encryption key and production QBO environment. The exact GunnAire callback is registered in both Intuit Development and Production. | Project and server configuration verified | Authorize the company realm, complete accounting-owner reconciliation, and validate webhooks. |
| Google Gmail/Calendar | Google sign-in, calendar create/update/delete only for app-managed events, Gmail delivery records, and account-scoped routing. Google Auth Platform is Internal. A production iOS OAuth client is registered for bundle ID `com.gunnaire.businesssuite` and Apple Team ID `7C4B3RR7RD`; the app and Render backend use the same public client ID. | Project and production client configuration verified | Confirm scopes and run sign-in, Gmail, Calendar, and backend role-denial tests with production business accounts on physical devices. Existing sessions made with the superseded client may need to sign in again. |
| Universal Links | The app declares `applinks:gunnaire.com`. The live HTTPS Apple App Site Association file lists `7C4B3RR7RD.com.gunnaire.businesssuite` for the QBO and Google callback paths and retains the superseded app identifier for migration safety. | Project and production website configuration verified | Confirm both callback paths open the signed release candidate on physical iPhone and iPad hardware. |
| Vendor connectors | Supplier connector contract exists with no app-held credentials; PO workflow and manual supplier fallback are available. Johnstone DirectConnect/Punch-out and Lennox remain provider-gated. | Project verified for boundary | Supplier onboarding, approved adapter contract/test account, server-side adapter, order approval policy, and live test. |
| Tap to Pay on iPhone | iPad-to-iPhone entry flow is implemented; no card data travels via Handoff. The receiving workflow directs contactless collection to the matching invoice in QuickBooks Mobile or GoPayment, which is Intuit’s supported Tap to Pay experience. | Project verified for safe handoff; first-party QuickBooks capture is external | Enable and test Tap to Pay in QuickBooks Mobile/GoPayment on each field iPhone. If GunnAire needs embedded card-present capture rather than the Intuit app, choose a PSP that offers Apple Tap to Pay support, obtain its entitlement/approval, then complete its sandbox and production certification. |

## Build and test evidence

| Check | Evidence | Result |
| --- | --- | --- |
| iPad Simulator test suite | iPad Pro 13-inch (M5), iOS 26.5; unit result bundle `/tmp/GunnAireOps-dispatch-board-final-tests.xcresult` and UI result bundle `/tmp/GunnAireOps-dispatch-board-ui.xcresult`. | **355 passed (349 unit + 6 UI), 0 failed, 0 skipped**; includes CloudKit readiness/schema persistence, field-payment Handoff guards, dispatch-board date/conflict/ownership rules, role navigation, catalog-state lifecycle, reconciliation, quantity/legacy invoice snapshots, and secure launch coverage. |
| QBO OAuth token hardening regression | iPad Pro 13-inch (M5), iOS 26.5, `xcodebuild test -only-testing:'GunnAire OpsTests'`; result bundle `/tmp/GunnAireOps-qbo-token-hardening-20260826.xcresult`; `python3 -m unittest Backend.test_qbo_token_storage -v`. | **345 passed, 0 failed, 0 skipped** after moving QBO refresh-token rotation to encrypted backend storage. Backend regression coverage also passed for access-token-only responses, ciphertext storage/decryption, connection-schema initialization, and fail-closed missing-key behavior. |
| iPad UI navigation suite | iPad Pro 13-inch (M5), iOS 26.5, `xcodebuild test -only-testing:'GunnAire OpsUITests'`; current result bundle `/tmp/GunnAireOps-dispatch-board-ui.xcresult`. | **6 tests passed, 0 failed** (9 runs including launch variants); verifies secure unauthenticated launch, authenticated administrator iPad workspace, primary sidebar navigation, dedicated full-screen dispatch week board, and launch performance. |
| Mac Catalyst compile/signing | Unsigned Release `xcodebuild` Mac Catalyst build rerun after the dispatch week board plus a signed Debug Catalyst build using Apple Development and the generated `Mac Catalyst Team Provisioning Profile: com.gunnaire.businesssuite`. | Passed; App Store distribution profile/archive remains a release gate. |
| iPad/iPhone Simulator Release compile | Generic unsigned Release build rerun after the dispatch week board and development-only CloudKit schema bootstrap. | Passed; the bootstrap is excluded with `#if DEBUG`. |
| iPhone Simulator Release compile | iPhone 17 Pro, iOS 26.5; unsigned Release build rerun after the current CloudKit, pricebook, and handoff changes. | Passed. |
| CloudKit readiness and schema | Focused iPad simulator unit test for available, no-account, restricted, and undetermined device states; signed Debug Catalyst bootstrap saved all 21 SwiftData model types; CloudKit Console deployment confirmation reported 21 record types and verified them in Production. | Passed; physical two-device merge/recovery still requires signed company hardware. |
| Backend syntax | `python3 -m py_compile Backend/gunnaire_backend.py`. | Passed. |
| Production backend health | `GET https://gunnaire-api.onrender.com/health` on 2026-08-26 after deploying commit `f812343`. | **HTTP 200** with `status: ok`. |
| Diff integrity | `git diff --check`. | Passed at the audit point. |

## Production gates that the repository cannot complete alone

1. **Apple Account Holder:** The CloudKit container, Remote notifications,
   development provisioning, and production schema deployment are complete.
   Create the App Store Connect/Mac Catalyst distribution records and profiles,
   and request the Tap to Pay entitlement only if an embedded PSP integration is selected.
2. **Business owner / deployment operator:** Confirm Render persistent storage,
   backups, restoration tests, monitoring, and key-rotation ownership; configure
   public privacy/support/deletion URLs. The HTTPS service and server-only
   provider secrets are already deployed.
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
