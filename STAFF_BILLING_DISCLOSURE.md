# Role-safe staff billing disclosure

This checkpoint prepares the billing portion of full staff workspace delivery. It does **not** open a staff workspace or claim that all 32 models are delivered. The six-kind CloudKit receiver and its incomplete-workspace gate remain unchanged.

## Contract

`StaffWorkspaceBillingProjection` produces a separate `staff-billing-view-v1` value from the encrypted full owner journal and exact expected source scope. The current server share plan, company/environment/replica binding, membership revision, share revision, role policy, and positive source sequence are required. The complete original graph is validated before selection, including nested billing evidence and customer relationships. Its caller must independently fence source sequence and authenticated session; this pure preparation helper is not a source-sequence or CloudKit proof.

The explicit invoice/estimate field lists are checked against the pinned owner schema. New fields fail closed. This is not an Invoice/Estimate import, does not create default-filled owner models, and cannot authorize charges, accounting publication, role changes, or a staff lease.

## Disclosure policy

| Role | Documents prepared | Costs / provider item mapping |
| --- | --- | --- |
| Admin | Invoices and estimates | Recorded values or explicit not-recorded state |
| Accounting | Invoices | Recorded values or explicit not-recorded state |
| Dispatcher | Estimates | Restricted |
| Field Technician | Invoices linked to jobs assigned as lead or crew | Restricted |
| Standard | None; no implicit billing grant | No documents |

Field identity requires one exact normalized technician email match. Missing and duplicate matches fail as unresolved identity. An unassigned invoice is not selected merely because it has the same customer. Local AppUser role values cannot increase the server plan's role.

Restricted purchase costs remain restricted even when the original was nil or zero. Unknown and actual zero are distinct for financial roles. No digest of private owner record values is included in the disclosure. Raw catalog JSON is replaced with explicit sold-line types, including nested assembly components and bundle members. Stable row identity/order, already-extended member quantities, historical sale price, customer totals, discount/price authorization, equipment identity, and tax addresses are preserved. A bundle from a different company fails. CloudKit environment and QBO environment are separate concepts, not equated.

Raw provider diagnostics, payment-review JSON, and milestone draft receipts remain service-only for all roles; appropriate typed review adapters are still required. The disclosure itself is a technical value, not a new diagnostics-heavy UI.

## Verification

Evidence root: `/Users/gunnaire/Downloads/GunnAire Ops Releases/Staff Billing Projection.KorcUi`.

- `IPadFocused1`: 68 passing cases across all five required suite selectors, zero failures/skips. This preceded the final all-document company check and cost-presence test; it is retained intermediate evidence.
- `IPadFocused2`: 69 passing cases across all five selectors, zero failures/skips, on final candidate source.
- `IPadFull1`: 1,915 passing unit cases, zero failures/skips; the result-tree verifier confirms the complete unit target and all five required suites (six selectors). The new billing projection suite contributes 18 passing tests.
- `MacRelease1`: unsigned Mac Catalyst Release build and arm64+x86_64 architecture verification passed. Binary SHA-256: `5f3165e69da12f4c4027fb206cb7941d8a9e02097e07609c571cc2dcf7dc45c3`.
- `DeviceRelease1`: unsigned iOS Release build and arm64 architecture verification passed. Binary SHA-256: `d7d1c9fc08f51423e2e28619e79c10ee495a527acf66a81f3e7678930cfca148`.
- The four existing QuickBooks actor-isolation warnings and Mac Metal-toolchain search-path warning remain. No warning originates in the new projection. Signing and release settings are unchanged; unsigned builds are not App Store or physical-device acceptance.

The 18 new tests cover complete invoice/estimate field classification; all five roles; lead/crew assignment; unrelated invoices for the same customer; missing/duplicate staff identity; revoked/pending/foreign plans; original journal/store scope; malformed hidden records and customer links; hidden/absent/zero costs; unchanged disclosure bytes when only private cost/presence changes; historical sale prices, tax, approvals, discounts and equipment; recursive assembly costs; ordered/repeated bundle rows and already-extended quantities; foreign-company bundles even when hidden from the selected role; usable dispatch estimate rows; service-only diagnostics/review receipts; malformed/unknown nested JSON and invalid totals/prices; strict duplicate-key/cost-injection/changed-binding verification; and unchanged owner source with no owner-model decoding of a billing view.

All work is background-only under the user's privacy restriction. No screenshots, recordings, screen inspection, browser manipulation, foreground Mac runtime, or UI tests are authorized for this checkpoint.

Original-source protection is captured in `OriginalPreflight2.json`: four scoped files, 429 unrelated original changes protected, and 419 other tracked sources byte-equal. `OriginalCopyBack1.json` confirms all four copied files are byte-equal and all 429 unrelated edits plus the owner's original branch, HEAD, and index are preserved. `OriginalCopyBack2.json` repeats the frozen-source and copy check after this final report update. Only the isolated review checkout is staged/committed; the owner checkout is not.

The skill-governance audit is `/Users/gunnaire/.codex/skill-audits/skill-usage.jsonl`. API/access-control guidance shaped exact source and role boundaries; offline/native guidance kept original owner data separate from a read-only projected value; HVAC/payments guidance preserved equipment, sale identity, money and approval evidence without authorizing accounting actions; reliability guidance required isolated qualification and owner-edit protection.

## Remaining delivery work

This owner-side billing projection is not yet used by the six-kind production transfer. Complete role-safe selection for the other 30 models, server enforcement and immutable projection transport, staff-side native read/write adapters, full media delivery, an authenticated staff lease, and signed independent-account CloudKit convergence remain required. Never treat this billing slice as an operationally complete staff workspace.

Full app acceptance still includes QBO/Google/vendor/payment integration, physical iPad-to-iPhone Tap-to-Pay handoff, and the broader competitor-capability/navigation/accessibility/performance audit. No live provider data, payment, schema, entitlement, provisioning, or production deployment changes are made here. GitHub publishing remains gated by the unresolved workflow-token permission; no credentials are expanded.
