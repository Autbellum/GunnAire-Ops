# Business-session catalog approval and recovery

Candidate backend: **2026.09.08.42**. This is source qualification, not a production deployment or full-suite completion claim.

## User workflow

Field-created items remain saved on their original jobs/documents and need current administrator approval before joining the shared pricebook. The office reviews the exact item, confirms publication for an unlinked item, and can compare or recover a linked item using the verified business login. Separate QuickBooks OAuth on each iPad is no longer the prerequisite for these catalog actions.

Offline creation and approval retain the original local item. Publication failure does not remove it or send a direct-provider fallback. An uncertain server attempt stays available in Catalog publication review; recovery reads the original outcome, and only an unsent reservation may be cancelled. Applying a current QuickBooks pricebook version does not reprice saved invoice/estimate line snapshots. Successful item publication exposes the existing document follow-up, rather than automatically publishing an invoice.

## Boundaries and implementation

- `SharedCatalogPreparation` captures the exact item object/UUID/revision, administrator access, business session and view visit before asynchronous discovery. Changed/deleted/duplicated items, changed approval, logout, role revocation, replacement workspace and navigation cancellation cannot be adopted by an old action.
- `GET /api/catalog-publications/context?companyID=…&localItemID=…` takes only local identity. The server derives the current realm/environment and opaque connection revision, returns the catalog's income/expense defaults, and reads only an existing authoritative item mapping. It creates no proposal or mapping and does not guess a provider ID from the device or a matching name.
- Authorization, mapping and accounting defaults are checked across provider reads. The response excludes credentials, internal grant fingerprints, arbitrary provider fields, staff emails and unrelated payment-account defaults.
- Native comparison uses a separate business-scoped snapshot, not the broad device-import list. A company/realm/environment/grant change invalidates old comparisons. The snapshot owner outlives its completed operation but not its initiating business/view. Choosing either version rereads the mapped item and compares the exact provider snapshot.
- The ephemeral shared API has no OAuth tokens, Keychain load, refresh timer or direct Intuit transport. Create/update uses the existing durable catalog publisher with the connection revision pinned; recovery retains the original publication ID. Existing server grant checks, one-to-one mappings, stable request IDs, encrypted proposals, uncertain-send holds and explicit inventory-account checks remain intact.
- Catalog transport admits only the exact bounded business-session routes. It rejects generic API paths, external hosts, extra query fields, malformed identities and oversized payloads; transfers reject redirects and cap response bytes. The HTTP handler rejects duplicate/nonfinite JSON and ambiguous/trailing routes.
- Recovery sheet tasks retain original item/business/view identity. Late results cannot repopulate a dismissed sheet. Normal users see status/actions, not raw response bodies. The Company Pricebook disclosure identifier belongs to its label, preserving child-row accessibility identities.

Existing imported device-only links are **not** silently adopted as server mappings. They require the existing explicit-link review workflow. This boundary must not be bypassed by creating another QuickBooks item.

## Evidence

Evidence directory: `/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-08/Shared Catalog.KOTCKA`.

Backend: all **659** tests pass, including seven new shared-context cases and actual HTTP coverage. The expanded catalog/provider selection passes **79** cases. All **56** Tools tests pass. The initial expanded Mac selection passes **52** cases; the first full Mac source passes **1,536** logic cases with actual-execution verification.

Initial failures are retained: a Swift actor-isolated default argument and a test fixture's actor annotation were corrected. The first iPad run exposed an incomplete historical fixture (missing explicit `Active` evidence), a duplicate accessibility match in the confirmation popover, and an unscoped company-pricebook test query. Assertions and server validation were not weakened: the fixture now supplies the required evidence, the popover activates its visible outer control, and the pricebook test targets the original item. A subsequent code review separated business comparisons from general imports and added grant/business snapshot tests.

The final `AcceptanceMac.xcresult` passes **1,537** logic tests. `AcceptanceIPad.xcresult` passes the same **1,537** logic tests and all **12** selected UI journeys (**1,549** total). Both have zero failures/skips, with passed-case tree and selector verification by `Tools/verify_native_test_execution.py`. The 12 new shared-catalog logic cases cover scoped transport, field approval and saved document prices, both comparison directions, changed provider snapshots, device-only link rejection, lost-reply recovery, malformed context, stale/revoked work, offline retention, and changed business/grant identity. UI acceptance includes Invoice opening, simple Mail, unsent catalog cancellation, exact version selection, approval and publication confirmation, offline comparison, and inventory creation/reopening, with device OAuth disabled for the shared-catalog journeys.

A later iPad failure exposed a real feedback problem: connection discovery failed safely after approval, but automatically expanding both catalog queues pushed the saved approval result offscreen. Discovery failure now keeps the current disclosures focused; only an actual workflow failure opens its relevant queue. The approval assertion remains, scrolls to its saved result when needed, and passes on the final source. All **10** final screenshots in `AcceptanceScreenshots` were visually reviewed, including the saved approval result, original offline prices, inventory setup and simple Mail. No account-email footer or raw API response is shown. Earlier failures and recordings remain available; earlier green builds do not qualify later edits.

`AcceptanceRelease.log` records a successful unsigned universal Mac Catalyst Release build. `AcceptanceReleaseVerification.log` verifies **arm64 and x86_64**, with binary SHA-256 `4271e69a2dbce55e24ab0ec35f35370270f7d84e689947c877dbd3a7a203365f`. Existing document-concurrency and optional Metal-toolchain warnings remain; no signing, distribution or physical-device acceptance is implied. Both unchanged workflow files pass actionlint. A final lint invocation initially used guessed filenames; rerunning with the observed `backend-regression.yml` and `native-app-regression.yml` paths passes.

`AcceptanceOriginalPreflight.json` freezes the qualified non-document sources and records **13** scoped paths, **255** unrelated original-project changes, the unchanged empty index and **296** other byte-identical tracked source files. Copy-back checks enforce these boundaries and verify scoped byte equality before committing.

Hosted predecessor `5287a61` passes Backend (Python 3.13/3.14), Mac and iPad group 1. iPad group 2 has one failed test among 29: `testAdministratorCreatesLockedBundleMilestoneInvoiceAndReturnsToOriginalJob`, with an Xcode timeout acquiring the target app's background assertion. `HostedPredecessorFailure.log` retains the exact error; it does not establish an application logic defect or a fix by this catalog patch. A new published head requires its own complete hosted qualification. Workflow commit `58ca6be` and its 58 named UI journeys remain unchanged.

The exact failed journey was run locally on the final source: `HostedBundleReproduction.xcresult` passes **one** requested UI test with actual-execution verification. Both additional `HostedBundleScreenshots` were visually reviewed, showing the original locked milestone invoice and its exact $5,550 subtotal/30% allocation. No change to that test or a blanket retry was used to obtain the pass. This local result does not erase the hosted failure or prove it cannot recur in the full hosted group.

## Research and remaining goal

The implementation retains the existing server-side OAuth lifecycle described by [Intuit's official OAuth client](https://github.com/intuit/oauth-pythonclient). UI choices use the existing native controls and focused feedback, informed by [Apple's progress guidance](https://developer.apple.com/design/human-interface-guidelines/progress-indicators) and [feedback guidance](https://developer.apple.com/design/human-interface-guidelines/feedback). These sources inform the design; they are not proof that this app passes provider or Apple acceptance.

The new endpoint must be deployed with the matching source before production use. No main merge, deployment, live accounting/customer-message/payment write, production roster change, signing/capability/schema change or physical-device installation is part of this checkpoint.

The full goal remains open: signed same-record CloudKit convergence and independent staff sharing; approved real iPad-to-iPhone payment Handoff/Tap to Pay; remaining direct-OAuth Google/QBO operations and explicit imported-link onboarding; supplier partner access and ordering acceptance; and complete ten-comparator business-suite, accessibility, navigation and real-device acceptance. Local automated checks do not establish flawless behavior across that entire scope.
