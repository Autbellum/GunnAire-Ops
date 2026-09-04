# CloudKit and field-payment release checklist

## CloudKit

The app uses the private CloudKit database container
`iCloud.com.gunnaire.businesssuite` for its SwiftData store. Apple configuration
and schema status as of 2026-08-31.

### Current capability and schema status

- A refreshed authenticated Apple Developer inspection confirms the explicit
  App ID `com.gunnaire.businesssuite` under team `7C4B3RR7RD` has Associated
  Domains, iCloud/CloudKit, Push Notifications, and Sign in with Apple enabled.
  Sign in with Apple is primary, and the assigned container is
  `iCloud.com.gunnaire.businesssuite`. In-App Purchase is Apple-managed and
  shown enabled and non-editable by the portal. The inspection clicked no Save
  button, changed no capability or container, and submitted no request. Exact
  retained evidence is
  `/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-08-30/Verification/apple-app-id-capabilities-2026083015.json`.
- Handoff does not have an App ID checkbox. The app declares
  `com.gunnaire.businesssuite.field-payment-handoff` in `NSUserActivityTypes`;
  signed physical Mac/iPad-to-iPhone acceptance remains required. Native
  MapKit geocoding/directions, Apple Maps URLs, and the system Mail and Messages
  composers do not need the portal's Maps or Messages Collaboration
  capabilities. The route estimate uses only staff-entered service addresses,
  requests no device location, and adds no location usage description. Those
  unrelated portal capabilities remain off deliberately.
- The selected App ID's Capability Requests list shows no Tap to Pay on
  iPhone, Proximity Reader, or payment-acceptance request or assignment.
  GunnAire's current field-payment workflow hands a verified QBO invoice to
  QuickBooks Mobile/GoPayment and therefore does not add the native payment
  acceptance entitlement. A future embedded ProximityReader flow remains
  gated on a participating certified payment service provider, Account Holder
  entitlement approval, provider integration, and signed physical-iPhone
  acceptance.
- Exact current build `1.0 (2026083101)` is retained as a development-signed iOS
  Release archive and universal arm64/x86_64 Mac Catalyst Release app. Strict
  signature verification confirms Apple login, CloudKit, Push Notifications,
  and Associated Domains in both products. The iOS app/dSYM UUID matches at
  `C62573CC-15F9-3413-A341-8452EF322FBA`; Mac app/dSYM UUIDs match at
  `641B4DEA-FB67-3D3C-831F-8CF5B0A3F309` and
  `B8BC1EC8-08FF-3F56-92F5-DD6289C6E767`. Exact retained-artifact and CloudKit
  export preflight reports **61 checks, 4 expected warnings, and 0 failures**;
  one warning records that online probes were intentionally omitted. The exact
  read-only online probe reports **64/3/0**: production serves reviewed backend
  `2026.08.30.16`, Apple notification routing rejects a malformed envelope with
  HTTP 400, and the QBO callback reaches the app scheme. Complete iPad and Mac
  logic suites pass **672/672** each, and the complete iPad UI target passes
  **92/92 logical workflows** with **95/95 device executions**. The retained
  consolidated evidence is
  `/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-08-30/Verification/release-verification-2026083101.json`.
- The final signed-hardware gate is executable rather than an informal
  checklist. Run `Tools/physical_device_acceptance.py` with the exact retained
  archive and Mac app, then follow `PHYSICAL_DEVICE_ACCEPTANCE.md`. The
  read-only inventory omits device names, serial numbers, UDIDs, ECIDs,
  accounts, customer data, and credentials. Its structured record validator
  requires real evidence for every iPad/Mac/iPhone, CloudKit, offline, Handoff,
  QBO sandbox item/invoice, payment recovery, Google, APNs, scanning, role,
  accessibility, and revocation scenario; it refuses stale builds, missing
  evidence, privacy-unsafe records, or Production QBO/CloudKit claims without
  an explicit authorization reference.
- Prior exact build `1.0 (2026083021)` is retained as a development-signed iOS
  Release archive and universal arm64/x86_64 Mac Catalyst Release app. Strict
  signature verification confirms Apple login, CloudKit, Push Notifications,
  and Associated Domains in both products. The iOS app/dSYM UUID matches at
  `7C335331-C438-3C6E-B889-77AE067DE476`; Mac app/dSYM UUIDs match at
  `97010FC5-A7B9-3148-9B2D-7906D4ED0D9B` and
  `B88F9531-0261-36DD-9C29-0B5EAA729A24`. Exact retained-artifact and CloudKit
  export preflight reports **61 checks, 4 expected warnings, and 0 failures**;
  one warning records that online probes were intentionally omitted. The exact
  read-only online probe reports **64/3/0**: production serves reviewed backend
  `2026.08.30.16`, Apple notification routing rejects a malformed envelope with
  HTTP 400, and the QBO callback reaches the app scheme. Complete iPad and Mac logic
  suites pass **672/672** each; role-scoped iPad Find/navigation passes **4/4**,
  direct Mac global Find passes **1/1** after a controlled stale-test-service
  recycle, and the compact field iPhone Find passes **1/1**. This authorization
  and navigation increment changes no SwiftData field, CloudKit schema,
  backend contract, Apple capability, provider credential, QBO mapping, or
  accounting record.
- Exact build `1.0 (2026083020)` is retained as a development-signed iOS
  Release archive and universal arm64/x86_64 Mac Catalyst Release app under
  `/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-08-30`. Strict
  signature verification confirms Apple login, CloudKit, Push Notifications,
  and Associated Domains in both products. The iOS app/dSYM UUID matches at
  `8924005C-2D14-3B0A-8309-48B7CE5BE564`; Mac app/dSYM UUIDs match at
  `28FB2D3B-F171-3C24-BDFA-2F1DE56ECC94` and
  `02C8193A-987A-35CE-953A-78F9D3A691C3`. Exact retained-artifact and CloudKit
  preflight passes **61 checks, 4 expected warnings, and 0 failures**. The
  read-only online probe passes every unchanged production route but reports
  **63/3/1** because production remains backend `2026.08.30.15` while source is
  undeployed `2026.08.30.16`. Complete iPad and Mac logic suites pass
  **671/671** each; the iPhone Handoff lifecycle passes **3/3**, and the iPad
  origin journey passes **1/1**. This build adds no SwiftData field, CloudKit
  schema, backend contract, Apple capability, provider credential, or
  accounting mutation.
- Exact build `1.0 (2026083019)` is retained as a development-signed iOS
  Release archive and universal arm64/x86_64 Mac Catalyst Release app under
  `/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-08-30`. Strict
  signature verification confirms Apple login, CloudKit, Push Notifications,
  and Associated Domains in both products. The iOS app/dSYM UUID matches at
  `F5B71EF8-AAB7-3616-8C4F-0F85F276BC7F`; Mac app/dSYM UUIDs match at
  `CDA62558-5A45-3673-AD64-47C7C58B44F8` and
  `5BE78D12-A4A3-3973-8C33-3099DCAA27D8`. Exact retained-artifact and CloudKit
  preflight passes **61 checks, 4 expected warnings, and 0 failures**. The
  read-only online probe passes every unchanged production route but reports
  **63/3/1** because production remains backend `2026.08.30.15` while source is
  undeployed `2026.08.30.16`. An Apple Distribution private key, separate Mac
  distribution signing, signed representative-device acceptance, and App
  Store upload remain external release gates.
- Build `2026083019` changes no SwiftData field or CloudKit schema. Weekly
  employee attestation reuses the existing versioned `reviewAuditJSON`; its
  period, employee workflow-revision IDs, and SHA-256 snapshot digest bind the
  signature to the exact closed, job-valid entries, and any later addition or
  correction request requires another review. Office approval and QBO state do
  not alter that employee digest. Approved-time CSV export fails closed until each employee snapshot is
  signed and every entry office-approved. It retains entry/job/QBO evidence but
  performs no wage, overtime, tax, commission, deduction, or net-pay math.
  Explicit UI-test roles now win over the screenshot-fixture fallback, allowing
  a privacy-safe technician screenshot without changing that account into an
  Administrator. Complete iPad and Mac logic suites pass **671/671** each, and
  the exact technician sign-off journey passes **1/1**; unchanged backend source
  `.16` retains its prior **70/70** result. No CloudKit bootstrap, Development
  mutation, Production promotion, provider authorization, accounting write,
  refund, or payment was required or performed.
- Production remains schema v15 across 24 record types in retained export
  `/Users/gunnaire/Downloads/cloudkit-production-7.ckdb`, SHA-256
  `f81de36537620a10fe34fde22883a94dc6f5b00deea6fec08004160c0aae7594`.
  The signed isolated bootstrap now initializes the complete Development schema
  v22 across 33 record types. Fresh export
  `/Users/gunnaire/Downloads/cloudkit-development-11.ckdb` has SHA-256
  `9d357a64b9b17b7efcc8256c5c0d8bb6670b86357e2b48a145d95a5603f77f8b`.
- Source schema v22 retains the exact v16 attachment delta;
  adds the v17 fleet vehicle/event pair and attachment linkage; the v18 field
  expense record and receipt linkage; the v19 customer operational-alert record;
  the v20 business-task/event pair; and the v21 technician-time-off
  request/event pair plus seven audit/cancellation fields on
  `CD_TechnicianAvailabilityBlock`; then adds the v22 19-field
  `CD_TechnicianWorkShift` record for regular/on-call weekly capacity,
  effective dates, time zone, stable creation evidence, and reason-required
  retirement history. The isolated Debug bootstrap writes every optional value
  through v22, and unit contracts assert the complete seed. The signed staging
  run exposed and fixed ten previously absent optional values: six expense
  review/reimbursement fields and four operational-alert resolution fields.
  The release
  preflight accepts only the exact cumulative additive v22 delta or an
  exact post-promotion match, requires each new record family to be all-or-none,
  and rejects partial v21 availability-block fields or a partial v22 shift
  record.
- Exact export comparison proves Development differs from Production by only
  the nine approved additive record families and 212 additive fields across 11
  affected record types. No existing Production field, system field, or
  security grant is removed or changed, and every added record uses the
  approved system fields and default private-database grants. The exact schema
  audit passes **9/9**; the strengthened verifier regression suite passes
  **5/5**.
- Versioned marker cleanup identifies the synthetic operational alert by the
  dedicated bootstrap actor rather than its title, because CloudKit truncates
  that title to 32 characters. A regression now proves cleanup removes the
  complete 32-model synthetic graph. The final signed cleanup left zero marker
  strings, only the 16 intended starter rows, no pending bootstrap process, and
  **29/29** successful CloudKit mirroring events with zero failures.
- Production was not promoted. Complete representative signed two-device
  iPad/Mac/iPhone role, offline, conflict, and reconnect acceptance before
  deploying the reviewed v22 schema. After promotion, export Production again
  and require exact Development/Production parity before business use.

Historical deployment evidence follows:

1. The App ID `com.gunnaire.businesssuite` has the CloudKit container and Remote
   notifications capability enabled. The project declares Push Notifications,
   and the verified signed Catalyst product contains development APNs,
   Associated Domains, and CloudKit entitlements.
2. The exact schema-version-thirteen source builds as universal arm64/x86_64
   Mac Catalyst Release app `1.0 (2026082889)` using Apple Development and the
   managed `Mac Catalyst Team Provisioning Profile: com.gunnaire.businesssuite`.
   Strict signing, hardened runtime, privacy/export metadata, production
   configuration, both app/dSYM UUID slices, and Release-string hygiene pass;
   Xcode reports zero errors and analyzer warnings plus one host-only missing
   optional Metal-toolchain search-path warning.
   The exact current source also archives successfully as optimized arm64 iOS
   Release build `1.0 (2026082889)`. Xcode store validation, privacy-manifest
   validation, Release-string hygiene, strict archive-signature verification,
   and binary/dSYM UUID matching pass. The archive is development-signed; a
   local-only App Store export correctly stopped because the installed
   production profile has no corresponding Apple Distribution private key.
   No Apple certificate, profile, portal setting, upload, or submission changed.
   A separate Mac distribution profile/private key remains required if the Mac
   Catalyst product is distributed through the Mac App Store.
3. The signed version-eight bootstrap completed on 2026-08-27 and initialized
   all 22 model types that existed in that release candidate. CloudKit Console
   then verified and Apple deployed the complete additive five-record-type delta
   to Production. The retained version-eight Development and Production exports
   match at
   `CD_CustomerEquipment` 13 fields, `CD_CustomerServiceLocation` 18,
   `CD_ServiceCall` 40, `CD_Estimate` 25, and `CD_Invoice` 18. Both Estimate and
   Invoice include indexed `CD_serviceLocationID` plus `CD_siteAddress`, which
   preserve the selected service property through proposals, approved-work
   scheduling, estimate-to-invoice conversion, customer PDFs, and QuickBooks
   `ShipAddr` synchronization. Fresh `cloudkit-development.ckdb` and
   `cloudkit-production.ckdb` exports are byte-for-byte identical with SHA-256
   `b998e05777e3778ee8427d4e57cc6b5fdd3358e4d186cda1624cbe2c491eca39`.
   Temporary bootstrap records were removed and the local Development store was
   verified marker-free. Versioned bootstrap, cleanup, persistence, and deletion
   paths retain focused regression coverage.
4. Schema version nine is deployed and verified for all 23 SwiftData model
   types. The signed development bootstrap created `CD_ProjectMilestone` with
   23 fields, added five indexed project-lineage fields to `CD_Invoice` for a
   total of 23 fields, and added the indexed `CD_qualificationNotes` field to
   `CD_ServiceRequest` for a total of 16 fields. Apple CloudKit Console reviewed
   exactly those three additive record-type changes, deployed them to
   Production, and reported **Changes Deployed**. Fresh retained exports at
   `/Users/gunnaire/Downloads/cloudkit-development-3.ckdb` and
   `/Users/gunnaire/Downloads/cloudkit-production-3.ckdb` are byte-for-byte
   identical with SHA-256
   `484d5e58c7b353561d9f642df04ae8a0280f1be94b2c67e3bbc1da1ef6b511f9`.
   The marker-only cleanup exported successfully and the local Development
   store was verified marker-free. The post-cleanup unit result
   `/tmp/GunnAireOps-cloudkit-v9-cleanup-units.xcresult` contains 420 passed,
   0 failed, and 0 skipped tests.
5. Schema version ten keeps the same 23 models and adds exactly five fields to
   `CD_TimeEntry`: `CD_reviewAuditJSON`, `CD_reviewNote`,
   `CD_reviewStatusRawValue`, `CD_reviewedAt`, and `CD_reviewedByEmail`. The
   signed bootstrap completed, and Apple CloudKit Console reviewed one record
   type modification plus the 14 expected query/search/sort indexes. No record
   type deletions, unrelated changes, or security-role changes were present.
   Apple reported **Changes Deployed**, and Production now reports 18
   `CD_TimeEntry` fields. Fresh retained exports at
   `/Users/gunnaire/Downloads/cloudkit-development-4.ckdb` and
   `/Users/gunnaire/Downloads/cloudkit-production-4.ckdb` are byte-identical
   with SHA-256
   `af1bddceab339193a255236f71e41386ef35d2703a56c03b3398fbd9761c5676`.
   Cleanup runs from a Debug-only versioned isolated store so an old local
   developer store cannot block schema operations; both delayed cleanup passes
   saved, the current tables/columns were present, and all bootstrap marker
   searches returned zero.
6. Schema version eleven keeps the same 23 models and adds exactly seven fields
   to `CD_CustomerCommunication`: `CD_actorEmail`,
   `CD_consentSnapshotJSON`, `CD_deliveredAt`,
   `CD_maintenanceContractID`, `CD_providerStatusDetail`,
   `CD_templateVersion`, and `CD_workflowRawValue`. Apple CloudKit Console
   reviewed one record-type modification plus exactly 20 indexes, with no
   deletion or security-role change, and reported **Changes Deployed**.
   Production now reports 24 `CD_CustomerCommunication` fields. Fresh retained
   exports at `/Users/gunnaire/Downloads/cloudkit-development-5.ckdb` and
   `/Users/gunnaire/Downloads/cloudkit-production-5.ckdb` are byte-identical
   with SHA-256
   `70a3c475727051ea2efe4cbf4de6186aed55c81fd6ab8c0254c2e084cfc089ff`.
   Both delayed cleanup passes saved, all model tables were empty afterward,
   and local marker inspection returned zero.
7. Schema version twelve keeps the same 23 models and adds exactly two string
   fields: `CD_RecurringMaintenanceContract.CD_lifecycleJSON` and
   `CD_ServiceDocumentAttachment.CD_maintenanceContractID`. Under Apple team
   `7C4B3RR7RD`, CloudKit Console reviewed only those two record-type changes and
   their generated indexes, reported zero security-role changes, and confirmed
   **Changes Deployed**. Production now reports 15
   `CD_RecurringMaintenanceContract` fields and 17
   `CD_ServiceDocumentAttachment` fields. Fresh retained exports at
   `/Users/gunnaire/Downloads/cloudkit-development-6.ckdb` and
   `/Users/gunnaire/Downloads/cloudkit-production-6.ckdb` are byte-identical at
   27,791 bytes with SHA-256
   `ca498d9cefc1d2e783c03dd80f12460baef81603c21d894debbc1f041bd04244`.
8. Schema version thirteen keeps the same 23 models and stages exactly six
   additive QBO-authoritative tax fields in Development: `CD_salesTaxAmount`
   (Double), `CD_taxCalculatedAt` (Date/Time), and
   `CD_taxCalculationStatusRawValue` (String) on both `CD_Estimate` and
   `CD_Invoice`. The signed Mac Catalyst bootstrap completed through the
   supported Launch Services path; the isolated local store contains the
   expected typed values, and CloudKit setup/import/export events all report
   success with no error domain or code. CloudKit Console reports 28 Estimate
   fields and 26 Invoice fields in Development versus 25 and 23 in Production.
   Apple's deployment preview contains exactly two modified record types,
   three fields per type, seven generated indexes per type, and zero security
   role changes. Retained pre-deployment exports are
   `/Users/gunnaire/Downloads/cloudkit-development-7.ckdb` (28,337 bytes,
   SHA-256
   `309a440fec8d4fe2617610babe619033e4ba23bee45680b251400fdd9db43709`)
   and `/Users/gunnaire/Downloads/cloudkit-production-6.ckdb` (27,791 bytes,
   SHA-256
   `ca498d9cefc1d2e783c03dd80f12460baef81603c21d894debbc1f041bd04244`).
   A textual diff contains only those six fields and their intended indexes.
   All three marker cleanup passes exported successfully; the current marker,
   Estimate, and Invoice table counts are zero. The retained iPad result
   `/tmp/GunnAireOps-cloudkit-v13-final.xcresult` contains both focused
   versioned-store and complete optional-field seed tests: 2 passed, 0 failed,
   and 0 skipped. Production schema deployment remains an explicit release
   action and has not been performed for version thirteen.
9. Schema source version fourteen keeps the same 23 models and adds exactly one
   optional Date/Time field, `CD_Invoice.CD_dueDate`. The source and bootstrap
   marker are versioned, and the complete build-`2026082898` iPad and Mac
   Catalyst logic suites each pass 532/532. No signed v14 bootstrap has been
   run, so this field has not been added to CloudKit Development. Development
   remains v13 and Production remains v12. Before any promotion, run the signed
   isolated Development bootstrap, verify that its incremental delta is only
   `CD_dueDate`, clean every marker record, export Development, and review the
   cumulative Production deployment preview: the six already-reviewed v13 tax
   fields plus this one invoice due-date field, with no deletion or security-role
   change. Then complete a signed two-device invoice merge and QBO due-date
   round trip.
10. Sign the company iPad and Mac into the same approved business iCloud account
   and sign every staff member into GunnAire Ops with their own business login.
11. Verify offline edits made on each physical device merge after reconnection before
   relying on CloudKit for live dispatch.

The CloudKit private database keeps the company-owned iPad and Mac in sync. It
does not replace server-side business authorization, and it should not be used
as a multi-employee permission system.

The SwiftData schema uses optional CloudKit relationships with explicit
inverses. Local workflows still require a customer for a job, estimate,
invoice, agreement, payment, and customer communication; the optional storage
shape only lets CloudKit reconcile records that arrive in a different order.

CloudKit cannot enforce SwiftData unique constraints during asynchronous sync.
The app uses immutable UUIDs for record identity and treats the backend as the
authority for staff roles. If independently created staff records with the
same email conflict or any matching row is inactive, the app denies access
until verified backend refresh applies the authoritative role and active state
to every matching row, then collapses the duplicates. Do not use a local unique
annotation as the sole accounting, authorization, or external-ID deduplication
control.

## Latest signed iOS distribution artifact

Build `2026082785` was archived and locally exported for App Store Connect on
2026-08-27 without uploading or submitting it:

- Archive: `/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-08-27/GunnAire Ops 1.0 (2026082785).xcarchive`
- IPA: `/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-08-27/GunnAire Ops 1.0 (2026082785).ipa`
- Packaging log: `/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-08-27/GunnAire Ops 1.0 (2026082785) Packaging.log`
- IPA SHA-256: `a21341fad083337237aa96a4dd4751fee2ddbfbcaebf876021790be7047ab85e`

The exported app is signed by Cloud Managed Apple Distribution using App Store
profile `e3c0c5af-432b-4711-9c76-6e31503e7d25`, which expires 2027-06-01.
Strict deep code-signature verification passes. The export contains production
APNs, CloudKit Production, Associated Domains, `get-task-allow = false`, the
valid privacy manifest, the production backend and QuickBooks configuration,
and a matching app/dSYM UUID. Release-string scans contain no UI-test identity,
CloudKit bootstrap marker, or fixture content.

The archive audit removed the Time Clock's former fabricated test-email
fallback. Time entries fail closed until a real business user is signed in.
The proposal/QBO regression result
`/tmp/GunnAireOps-qbo-proposal-units-final-20260827.xcresult` contains 428
passed, 0 failed, and 0 skipped unit tests. Focused UI result
`/tmp/GunnAireOps-qbo-estimate-ui-20260827.xcresult` passed the QuickBooks
local-estimate recovery workspace flow.

The prior signed artifact includes team time review/correction/approval plus
typed customer communication lifecycle evidence and all twelve fields deployed
across schema versions ten and eleven. The newer working source passes **472/472**
Mac Catalyst unit tests in
`/tmp/GunnAireOps-business-session-final-20260827-2015.xcresult` and a
zero-warning iPad Pro 13-inch build-for-testing in
`/tmp/GunnAireOps-iPad13-build-20260827-2020.xcresult`, but has not yet been
archived. Version twelve is deployed and export-matched. App Store upload
remains a separate release action after App ID capability/profile regeneration,
physical-device, provider, privacy-questionnaire, and business acceptance gates
are complete.

## Staff assignment alerts

The project now uses the enabled Push Notifications capability for optional staff assignment alerts. A signed-in user opts in from Settings; the app does not prompt during launch and never stores the APNs token locally. On each opted-in launch or foreground transition, Apple supplies the current token and the app sends it directly to the backend under the existing revocable application session. The server binds it to the approved email, session, installation, bundle, environment, and platform, then encrypts it with a key that is separate from QuickBooks token encryption.

A new field-payment assignment queues one idempotent delivery per active device without delaying assignment creation. APNs previews are intentionally generic and omit customer names, addresses, balances, amounts, and payment data. The route contains only a versioned invoice UUID; the receiving app still applies its current role, assignment, invoice-visibility, and balance policy before opening Payments → Collect. Logout, session expiry, user deactivation, and permanent APNs token errors deactivate the registration and suppress its pending deliveries.

Backend source `2026.08.30.16` is deployed and passes the 70-test suite. Native push and compact Settings behavior retain framework-appropriate unit/UI coverage. Before activation, create and store an authorized APNs signing key plus a separate Fernet device-token key in Render; confirm Admin readiness; update App Store privacy answers for the linked device identifier used only for app functionality; and prove sandbox and TestFlight/production delivery, tap routing, logout, deactivation, credential revocation, and invalid-token cleanup on signed hardware.

## Field iPhone payment handoff

The Payments workspace can hand an unpaid invoice from the iPad or Mac to the
company iPhone with Apple Handoff. The handoff contains only an invoice
identifier; the receiving device resolves the current balance from its
authorized local invoice. A new activity invalidates the prior one, embeds an
exact 30-minute `NSUserActivity` expiration that survives origin-process
suspension or termination, exposes **Stop Field Handoff** from the origin, and
is invalidated on app sign-out or credential revocation. A receiver rejects a
missing or expired deadline before routing.
It never transfers an amount, card data, customer contact details, processor
tokens, or QuickBooks credentials. Apple Handoff and the separate-account
server assignment both open the same dedicated contactless guide only after the
iPhone reapplies the field user's current role, invoice visibility,
assigned-job, and unpaid-balance restrictions. A QBO-linked invoice shows the
freshly resolved balance, its copyable provider identifier, and documented
QuickBooks Mobile/GoPayment navigation without inventing an unsupported deep
link. It also exposes static HTTPS actions to Intuit's official QuickBooks
Mobile and GoPayment App Store records so staff can open or install the supported
payment app without sending invoice or customer data to that URL. An unpublished
invoice hides those unusable QuickBooks steps, explains
the publication dependency, and offers a direct verified cash/check/other
payment fallback; a local UUID is never presented as a QuickBooks reference.
Apple Handoff requires nearby devices signed
into the same Apple Account. Staff using separate business accounts instead use
the server-authorized field collection assignment path.

A signed-in field technician receives a compact, non-modal collection prompt
from any app workspace after foreground refresh or the periodic assignment
check. The client re-verifies that the assignment belongs to the signed-in
business email, presents the oldest pending assignment deterministically, and
announces each assignment only once. Selecting **View Task** opens Payments →
Collect and prefers the same contactless guide without treating a missing local
invoice as authorization. Outstanding invoice actions use an adaptive layout
instead of a horizontally clipped row: narrow devices retain a compact column,
while iPad and Mac use the available width for multiple columns.

If the authorized CloudKit invoice graph has not arrived yet, the app retains
the invoice, contactless-guide preference, and the same expiration as one
account-bound deferred route across navigation and relaunch, shows a
retry/dismiss recovery row, and automatically retries when the invoice becomes
visible. Expiration clears the route automatically and points staff to the
existing server field-collection tasks instead of leaving an indefinite wait.
The route opens payment entry only for an invoice the current role can see with
a remaining balance. It is also cleared on settlement, dismissal, restricted
routing, sign-out, or business-account mismatch.

The shared server permits only one active field collection assignment per
invoice. It derives the collector from the authenticated principal instead of
trusting a client-provided email, recomputes partial totals from idempotent
payment records, and closes the assignment only when its target is met. A
completed assignment retains its completion time, collector, and final payment
ID and cannot be cancelled. Local display methods such as a masked card or
authorization reference are reduced to the canonical `card`, `ach`, `cash`, or
`check` code before crossing the server validation boundary.

For the currently supported production card-present route, the field user opens
the matching invoice in QuickBooks Mobile or GoPayment on a compatible iPhone.
GunnAire Ops does not claim that Intuit provides an embedded custom-app Tap to
Pay SDK. Intuit's current documented invoice route is Menu → Sales & Get Paid →
Invoice payments → select the open invoice → Charge → Tap to Pay on iPhone.

Live **Tap to Pay on iPhone** is intentionally not represented as available
until all external prerequisites are complete:

1. Choose and contract with an Apple-supported payment service provider.
2. Request Apple's Tap to Pay on iPhone entitlement as the organization Account
   Holder and regenerate the affected provisioning profiles.
3. Add the PSP's approved iOS SDK/bridge and keep all processor secrets outside
   the app.
4. Perform PSP sandbox and production certification, then test successful,
   declined, interrupted, duplicate, and accounting-retry cases.

Apple documents that a custom Tap to Pay integration requires a participating
Level 3 certified PSP, the managed
`com.apple.developer.proximity-reader.payment.acceptance` entitlement, updated
App ID/provisioning, PSP-linked merchant terms, and a compatible iPhone (iPhone
XS or later). It is not available as an iPadOS or macOS card reader.

Primary references: [Intuit Tap to Pay in QuickBooks Mobile/GoPayment](https://quickbooks.intuit.com/learn-support/en-us/help-article/receive-payments/use-tap-pay-quickbooks-gopayment-quickbooks-mobile/L38jd9HdC_US_en_US), [Apple Tap to Pay on iPhone](https://developer.apple.com/tap-to-pay/), [Apple entitlement setup](https://developer.apple.com/documentation/proximityreader/setting-up-the-entitlement-for-tap-to-pay-on-iphone), and [Apple payment-card reader integration](https://developer.apple.com/documentation/proximityreader/adding-support-for-tap-to-pay-on-iphone-to-your-app).
