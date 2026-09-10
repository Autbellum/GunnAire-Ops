# Full staff content preparation — work in progress

This candidate extends the existing invoice/estimate adapter with explicit field contracts for the other 30 kinds (503 fields), plus 17 structured operational fields. The combined read-only preparation has all32-kind schema coverage and preserves the exact server-selected original record identities, revisions and unavailable links.

This is not full staff delivery or activation. The candidate now includes an immutable owner-only HTTP content endpoint and a native exact-byte assembler. Native request/publishing integration, semantic acceptance of the complete operational view, staff read/write adapters, current lease, media authorization and independent signed CloudKit convergence must still be finished and verified before activating a staff store. No owner models may be reconstructed by replacing restricted data with zero, nil, defaults or empty collections.

## Boundary

The field-policy table is closed and pinned to the owner schema. Every non-billing field has exactly one disposition: selected-record shared data, financial, operations, scheduling reviewer, self-or-reviewer, self-or-financial, server-only, or separately adapted structured data. New owner fields do not inherit a grant. Selection is recalculated from the current role and member identity; a caller-supplied broader index, mismatched role policy or foreign source scope cannot prepare content.

Operational record bodies separate original typed scalar `fields`, explicit `unavailableFields`, and validated `structuredFields`. Billing bodies reuse the separately tested typed billing contract. No raw operational JSON or private provider envelope is copied as a readable scalar. This is a display/transport format, not an accounting, approval or staff-command input format.

All consumed original structured evidence is validated before role filtering, including hidden records. An invalid hidden record cannot disappear into a partial-success view. Original data is retained for review; nothing is rewritten or deleted.

## Operational evidence

- Jobs retain readings, original crew identity, action statuses, service location and equipment linkage. Accounting context does not grant operational notes, access instructions or findings.
- Forms retain original questions, answer order, choices, captured question versions, and closeout assignment. Legacy UUID/string answer arrays remain representable. Structural/history validity is separate from actual closeout completion; this adapter never completes a job.
- Pricebook assembly definitions retain original component identities, quantities, revision and presentation. Provider catalog receipts and purchase URLs remain server-only; purchase costs are financial-only.
- Equipment keeps technical baselines separately from warranty history. Field staff receive a selection of their own or assigned-job claims, never an assertion that other claims do not exist. Credit values/references and credit-bearing event detail stay restricted for non-financial roles. Accounting can receive warranty credit evidence without technical baselines. This is not authority to post vendor credits.
- Agreements retain terms, price, member discount, status and renewal/source references. Their invoice-cycle ledger is financial-only even when the agreement itself is selected. An agreement does not grant access to unrelated invoices.
- Own expense amounts, reasons, mileage and review feedback remain available without granting other workers' records. Private scheduling review notes remain restricted to scheduling reviewers. Time activity/history and legacy review arrays retain their original meaning.
- File records expose only selected metadata and non-capability identities. Files still require a separately authorized media path; IDs and unavailable links grant no access by themselves. Communication history is not permission to send a message or change consent.

## Current evidence

Evidence root: `/Users/gunnaire/Downloads/GunnAire Ops Releases/Staff Full Content.8BtTPl`.

- `ProjectionFocused1`: retained 13 errors in14 new tests. The richer fixture exposed an incorrect assumption that equipment/contact enum values were embedded in the lossless owner schema. Inspection showed those fields are text in that schema and checked separately by native `StaffWorkspaceDiscriminators`.
- `ProjectionFocused2`: all14 corrected tests pass, covering all503 non-billing fields, all32-kind combined coverage, five roles, immutable original scalars, private cost/value-presence tests, tax/billing history separation, warranty history, forms, legacy representations, and malformed/foreign hidden evidence.
- `ProjectionFocused3` passes14 tests; `ProjectionFocused4` passes20 tests, adding all48 discriminator checks, private value/presence invariance, local-user-role hiding and assembly/renewal cycle checks.
- `NativeEnumBootstrap1` passes one test/verified selector and exports actual compiled enum values for all32 kinds/48 raw fields. Matching JSON manifests are committed for server/native parity tests. Two simple native enums gain `CaseIterable`; this changes no UI, signing or build settings.
- `DeliveryFocused1` retains three role-fixture expectation failures among34 tests: Dispatcher/Accounting/Standard expected values incorrectly reused the technician email. HTTP preparation correctly used the enrolled account. Correcting the independent expected projection to use the actual member email makes `DeliveryFocused2` pass all35 tests (20 projection +15 endpoint/interop), including all five roles.
- `NativeFocused1` passes42 test cases/all five verified selectors, including both native enum contract tests, all six exact-byte transport tests, billing/server interop, native billing projection and relationship graph checks. `NativeFull1` passes1,926 test cases/all six verified selectors, zero failures/skips. Both final processes exit0.
- `BackendFull1` passes978 tests on Python3.9.6 (174.041s); `BackendPython3121` passes978 on Python3.12.14 (173.283s); `Tools1` passes75 (3.910s). All final process handles exit0, with no failures/skips.
- `MacRelease1` and `DeviceRelease1` both build successfully and exit 0; architecture checks verify arm64+x86_64 Mac Catalyst and arm64 iOS. These are unsigned compile checks, not launches, signed distribution or physical-device acceptance. The new transport file emits no warnings. QBO actor-isolation warnings remain in the unchanged native workflow/upload code, plus the Mac Metal-toolchain search-path warning.
- Release binary SHA-256: Mac `f9e14014b83ae3a543c7e497cbef40c301f67cec4a297dfcfdeb81abae4ca7b2`; iOS `6e5dd248090de96566902d2633171f2d32df6c6be4809a69a6e6d443921b1675`.
- All qualification handles are closed. The candidate is ready for its local review-branch commit; the full app is not ready for acceptance. GitHub publication remains separately gated by the existing workflow-credential permission issue; no browser or credential changes are attempted.
- Protected copy-back is verified: all 18 scoped files are byte-equal to the review checkout; 439 unrelated owner changes and the owner branch/HEAD/index are preserved; 426 other tracked source files match. `OriginalPreflight1.json` and `OriginalCopyBack1.json` retain the checks. Only the isolated review checkout will be staged/committed.

## Immutable content transport

The additive `staff_workspace_projections` table stores one encrypted payload per original full32 selection, bound to the original selection digest. Routes beneath `/api/workspace/staff-shares/{shareID}/full-selections/{selectionID}/content` prepare (`POST`) and recover a receipt (`GET`); `/chunks?companyID=…&environment=…&replicaID=…&offset=0` returns a bounded original byte chunk.

Each transaction rechecks the current active administrator session, original creator, company/environment/replica binding, accepted share, member role/revision, projection policy and source head. Staff users cannot fetch the owner's preparation. Advancing the source permits receipt recovery but refuses old data chunks. Source rollback, corrupted encrypted content or changed hashes fail closed without regenerating the original. Concurrent retry creates only one original; encryption failure leaves no partial row.

The payload is at most64 MiB; fixed1 MiB chunks carry their offsets, exact byte counts, SHA-256 and the immutable whole-payload SHA-256. The exact UTF-8 bytes are persisted as encrypted base64, so Swift never has to reproduce Python's JSON ordering or numeric spelling. The native assembler checks the accepted plan, current source sequence, original selection identity/digest, all version/coverage/size flags, chunk ordering, canonical base64, chunk hash and final hash. Invalid replies leave prior verified progress unchanged. Receipt flags explicitly keep `operationalWorkspaceReady` false and `localCloudKitProofRequired` true. `fieldProjectionRequired` is false only for this complete field-preparation schema; it is not a staff access grant.

Native assembly proves transport integrity only. It has no live HTTP caller, durable publication journal, full32 CloudKit seal/receiver, operational SwiftData importer, media fetch or command path yet. It cannot be used to bypass the existing core-only workspace activation guard. No claim is made that an assembled byte sequence is a semantically accepted staff store.

The API/access-control skills drive exact current-role boundaries and explicit field dispositions; field-service, inventory, payments, communications and dispatch guidance separate service work from private financial/workforce evidence. Offline/reliability guidance preserves original identities and invalid data for recovery. Xcode and troubleshooting guidance drive native/server contract parity and retained failure evidence. The live audit is `/Users/gunnaire/.codex/skill-audits/skill-usage.jsonl`.

No production deployment, provider/customer/accounting mutation, credential expansion, push or merge occurs here. The owner checkout is not staged or committed. All work is background-only: no screen capture, recording, inspection, browser/tab changes, foreground apps or UI tests.

The full application goal remains unchanged and incomplete: finish usable staff workflows and commands, independent-account CloudKit, native handoffs, live QBO/Google/vendor/payment acceptance, physical iPad-to-iPhone Tap-to-Pay, and full competitor-feature/navigation/accessibility/performance acceptance. This candidate is not a replacement success criterion.
