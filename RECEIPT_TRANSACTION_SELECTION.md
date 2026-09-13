# Receipt transaction selection

## User outcome

The normal Receipts & Bills destination shows the job and human-readable billing information, not a QuickBooks entity-ID form. Advanced manual linking remains available to administrators. Standalone files can browse all six existing transaction types: invoices, estimates, bills, payments, sales receipts, and purchases (labeled Expenses). Search uses names, document numbers, amounts, and dates. Provider IDs remain opaque identities, never customer names or document numbers.

Apple's [disclosure-control guidance](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls), read in Safari on September 9, 2026, informed keeping common controls visible and infrequent technical controls collapsed. The picker uses a native searchable list and a cancel action. This is an implementation rationale, not accessibility acceptance evidence.

## Preserved guarantees

- Browsing has its own transaction type and request generation. Cancel does not change the parent's type, ID, job, or files.
- Every explicit selection rechecks the captured business/QuickBooks access. A new category, canceled picker, changed account, or revoked role invalidates old results.
- Empty, duplicate, wrong-type, or nonfinite provider choices cannot be selected. Matching names, amounts, or document numbers do not merge identities.
- A job's destination is resolved through the existing invoice/estimate lineage and reconciliation checks. The normal picker does not offer another job's document. Advanced changes that disagree with the job block syncing and offer restoration of the original target where it can be resolved.
- No changes to the original-file capture journal, customer/job ownership checks, upload confirmation, retry/recovery, accounting writes, or CloudKit schema.
- Without a job, choosing a QuickBooks transaction does not promise a new local customer/job file association. Company receipt storage and existing recovery remain separate functions.
- Existing administrator/field workspace restrictions remain. CompanyWorkspaceHost replaces the operational view on access-generation changes; the picker additionally checks its captured access at response and selection.

## Qualification

Evidence directory: `/Users/gunnaire/Downloads/GunnAire Ops Releases/Receipt Selection.POk9YX`.

- `MacFull3`: 1,755 actual cases, no failures or skips, verified from the result tree.
- `IPadFull2`: 1,760 actual cases, including the complete logic target and all five requested UI journeys on the 13-inch M5 iPad simulator, iOS 26.2. All six selectors verified from the result tree; no failures or skips.
- The 11 new picker tests cover business labels, search, date handling, six distinct entity types, canceled/late responses, category changes, revoked access, invalid/duplicate rows, redacted errors, and original job lineage.
- The receipt UI tests retain the original type/ID assertions and now exercise collapsed advanced fields, offline recovery, search, explicit selection, cancel, clearing selection, equal IDs in different entity types, restoration, wrong-job rejection, and technician restrictions. The invoice-opening and simple-mail regressions also pass.
- `Tools3`: all 72 repository tooling tests pass. Both unchanged workflows pass actionlint; no UI selector was removed or added to the workflow.
- Two final frames in `FinalReceipt2` were inspected: the picker (`A9DFF0AA-0ACB-4C9B-B5CA-D18CF1CE5ED2.png`) and original-selection summary (`BF4B5625-B59B-4AD9-BB4D-0AEB917401B4.png`). Business data uses system label colors; no opaque transaction IDs or account-email footers appear in the default flow. This is not a full accessibility audit: extreme text sizes, all color/contrast states, pointer/keyboard/VoiceOver acceptance, and the rest of the app remain to be qualified.

Earlier evidence is retained honestly: `MacFocused1` failed compilation for a missing Combine import; `IPadFocused1` exposed the disclosure-group identifier overriding its child fields and the stale section-heading assertion. These were corrected without removing the original identity/access assertions. `IPadFocused2` then verified all 28 focused cases. A later date/search/readability review led to the final full-suite runs above. No new compiler warning is suppressed; existing unrelated document-workflow actor and host framework diagnostics remain.

`DeviceRelease3` (unsigned arm64 iOS) and `MacRelease3` (unsigned arm64/x86_64 Mac Catalyst) both build successfully. Architecture checks pass. These are compile/architecture checks, not signed App Store, physical-device, or Mac UI acceptance.

`OriginalCopyBack1.json` verifies all six scoped files byte-equal in the original GunnAire-Ops project, 365 unrelated changes preserved, and the original branch, HEAD, and index unchanged. Preflight also verified 380 other tracked sources equal. No signing, entitlement, schema, account configuration, provider write, deployment, or main merge was performed. The source candidate is ready for the review-branch commit; do not push it while the published predecessor's iPad job remains live.

Executable SHA-256: iOS `4377d3a02b849c263b708869f40f74a413c5ae3e786731fdc6c74c5df8911fa1`; Mac `aa1ff0fdc961207e0b3a80e331846e3172211ce2a1c8d18a6936b4f4d4cad09e`.

## Hosted predecessor startup finding

PR head `33413e42b307b47c6d0e02c617105c9afe0a9fa6`, native run `34354492697`, iPad shard 2 job `102475601110` failed before test execution. Its simulator-preparation step started at 13:01:56 UTC; bootstatus reported `Finished` at approximately 13:05:50 UTC; GitHub then reported the five-minute preparation timeout at 13:07:13 UTC. The script next reads and validates simulator inventory before exporting the exact destination. The retained `iPad-1-native-1` artifact (19,545 compressed bytes) contains a complete 194,553-byte `simulators-ready.json`; the owned device `CE16AF2C-1F0C-4756-AD8C-195DEA1A0874` is available, Booted, and the exact requested M5 model. Thus this is a preparation failure, not an app test failure. The precise subcommand timing is not established. Next CI work should retain the exact-device verification, provide stage timing, and allow sufficient bounded preparation time; it must not skip boot verification, change the OS, or erase an existing device. Backend run `34354492663` passed for Python 3.13 and 3.14, and the hosted Mac job passed. iPad shard 1 remains live at the latest poll; do not cancel it or publish a successor while the workflow would cancel it automatically.

## Remaining full-suite acceptance

This receipts improvement does not complete the business suite. Signed independent-account CloudKit convergence, full operational staff-role projections and commands, provider-connected acceptance, physical iPad/Mac/iPhone handoffs, supported Tap to Pay setup, and full usability/accessibility review remain separate required evidence. Fixture and unsigned local tests must not stand in for these checks.
