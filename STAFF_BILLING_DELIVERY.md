# Server-enforced staff billing content

This adds the invoice/estimate content adapter and its durable HTTP preparation path to the full32 server selection. It is **not a complete staff workspace**, a staff lease, a payment instruction, a QBO write, or a staff-store import. The remaining 30 domain field adapters and native full-content publication/receipt path are still required. Existing core6 activation gates stay in place.

## Contract and authority

Local backend source version is `2026.09.09.52`; it is not deployed. The routes are under `/api/workspace/staff-shares/{shareID}/full-selections/{selectionID}/billing`:

- `POST` prepares content. Exact body: `companyID`, `environment`, `replicaID`, `contentSchema: "staff-billing-view-v1"`. The existing immutable selection ID is also the billing operation identity; callers cannot supply a role, record list, total, price or replacement content.
- `GET` recovers the original receipt, with the three company/environment/replica query fields.
- `GET .../documents` returns the same receipt, a `projection` with a bounded document page, the matching original `recordIndex` including unavailable scalar links, and `nextCursor`. Continue with `after=kind:original-lowercase-uuid`. Duplicate query keys, foreign cursors, unknown fields and route suffixes fail.

Every action requires the exact active Admin creator of the original selection, current tenant/replica binding, current accepted share, member revision/role/policy, and approver authority. The target staff member cannot call this owner-preparation endpoint. Authority is rechecked inside a database transaction. Role or assignment grants cannot come from local user records or hidden UI controls.

`staff_billing_projections` is an additive table using the existing authenticated owner-storage encryption. Preparing a selection's content validates the current complete original graph and verifies its recomputed record index equals the immutable selection before copying any fields. Content, hash and audit commit atomically. Lost replies and concurrent retries recover the same original result. Corrupt ciphertext, altered content digests and source-head rollback require storage recovery; they do not rebuild the original content.

Any owner-source advance blocks old content pages. The original receipt stays recoverable with `sourceCurrent: false`; prepare a new current selection and content before publishing. Revocation, membership deactivation and changed role/approver authority block continued use. The original remains stored. A production retention policy and operational restore drill covering this new table remain required before rollout.

The delivery envelope is `staff-billing-delivery-v1`; its content is the existing native `StaffWorkspaceBillingProjection` schema `staff-billing-view-v1`. The receipt binds selection ID/hash, content hash, business, environment, replica, membership revision, share revision, policy and original source sequence. `coverage` explicitly names only invoice/estimate; `sourceCoverage` names all32 kinds. Every response keeps `operationalWorkspaceReady: false`, `fieldProjectionRequired: true` and `localCloudKitProofRequired: true`.

Content is capped at 32 MiB, input JSON at 1 MiB/100,000 nodes/depth16, sold rows at750 including bundle members, and each response page at100 documents/6 MiB of actual ASCII-escaped wire JSON. Page boundaries also split by bytes; an oversized single document fails without truncating or rewriting it. Clients must combine pages and verify the full content hash before use. Independent signed CloudKit proof and a current staff lease remain separate mandatory gates.

## Business evidence and disclosure

All original live invoice and estimate snapshots are checked before role filtering, including documents the target role cannot read. Validation covers exact supported JSON shapes, duplicate keys, typed numbers/booleans, supported saved item types, original catalog/equipment references and customer/company lineage, prices and quantity precision, authorized price adjustments, rounded sold amounts, discount scope and original net-plus-tax totals, complete reviewed US tax-address scope, assemblies and non-recursive bundles. Absent legacy quantity/pricebook fields use the native historical defaults; explicit null does not. Empty/corrupt saved line JSON is not converted into a manual document.

Admin gets invoices and estimates; Accounting invoices; Dispatcher estimates; Field Technician only assigned-job invoices; Standard neither. Record selection is server-enforced before disclosure. All original scalar billing fields receive an explicit schema-pinned disposition. Raw synchronization detail, payment-review JSON and milestone draft receipts are service-only, even for Admin. `quickBooksID` and nested provider IDs, purchase costs and bundle accounting scope are restricted for non-financial roles.

The native disclosure enum distinguishes recorded zero, absent original value and restricted value. Restricted data does not become zero or null. Private cost changes or presence alone do not change the role-filtered content bytes when the source metadata is held fixed. Digests are of disclosed content, not private field values.

Historical sales prices, approved adjustments, tax, discounts, signatures, serial/equipment details, repeated bundle member IDs/order, and physical assembly parts are retained. Already-extended bundle member quantities are not multiplied by root quantity again. Sold catalog IDs remain historical references, not grants to open an otherwise restricted current catalog record. No current catalog price rewrites historical evidence. This adapter cannot authorize accounting publication or payment.

## Evidence and preservation

Evidence directory: `/Users/gunnaire/Downloads/GunnAire Ops Releases/Staff Billing Delivery.f2GoUg`.

- `BackendFocused1`: 19 initial policy and real HTTP tests passed.
- `IPadFocused1`: 48 headless iPad unit tests passed across four explicitly verified selectors. This includes all five server role projections compared for exact decoded equality with native preparation from the same original 33-record/all32-kind fixture, then native original-source verification. Bundles and assembly disclosures also have independent assertions. No app presentation or screen capture was used.
- `BackendFocused2`: all 30 expanded backend tests passed, including reviewed tax-address scope, legacy saved arrays, fixed discounts, recursive/duplicate item rejection, original-creator isolation, exact session revocation between HTTP/transaction, member deactivation, share revocation, byte/count limits, encrypted-write rollback and content-digest corruption.
- `Tools1`: all 75 tooling tests passed.
- `IPadFull1`: all 1,918 headless iPad unit tests passed with five explicitly verified selectors, including the three new cross-language cases; zero failures/skips and process exit 0. Simulator-only AppShortcut/haptic diagnostic messages remain in the retained log; this is not visual/runtime acceptance.
- `BackendFull1`: all 943 backend tests passed on Python 3.9.6 in 163.139 seconds. `BackendPython312`: all 943 passed on Python 3.12.14 with cryptography 50.0.1 in 163.193 seconds. Both process handles closed with exit 0, without failures or skips. Hosted Python 3.13/3.14 exact-head CI is not claimed; no branch push was performed.

The source app's Swift implementation, UI, entitlements, signing and build settings are unchanged. Only two native test resources are added. Earlier unsigned iOS/Mac build evidence is for that unchanged app source, not proof that the new backend is deployed or full staff delivery works.

`OriginalPreflight1.json` freezes all six non-document candidate files and protects eight scoped paths, 435 unrelated owner changes, and the owner's branch/HEAD/index; 423 other tracked sources are byte-equal. Protected copy-back verification is required before committing only the isolated review branch. The owner checkout is not staged or committed. GitHub publishing still awaits workflow-token permission; no push, merge, deployment, credential expansion or production mutation occurs here. Screen recording/capture/inspection, browser/tab changes, foreground apps and UI tests remain prohibited by the user.

`OriginalCopyBack1.json` confirms all eight scoped files are byte-equal to the qualified review candidate, all 435 unrelated owner changes are preserved, and the owner's branch/HEAD/index are unchanged. `OriginalCopyBack2.json` repeats the verification after this evidence update. No owner source is staged or committed.

API/access-control skills drove the immutable current-authority contract; offline/reliability guidance drove retained original recovery and stale-data rejection; payments/inventory/HVAC guidance drove historical totals, equipment and nested-cost disclosure; Xcode guidance drove exact server/native interoperability checks. The live skill audit is `/Users/gunnaire/.codex/skill-audits/skill-usage.jsonl`.

## Remaining full application goal

The native publisher does not yet request this new content. Full32 field projections, durable complete staff content assembly/transport, native read/write adapters and commands, secure media, authenticated staff lease and independent-account signed CloudKit convergence remain unfinished. Live QBO/Google/vendor acceptance, physical iPad-to-iPhone Tap-to-Pay/Handoff, and complete competitor-feature, navigation, accessibility and performance acceptance remain outstanding. This checkpoint does not replace or narrow that full objective.
