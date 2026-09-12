# Office invoice → QuickBooks → collection guards

Candidate backend version `2026.09.11.64`, 2026-09-11. This integrates the
server journals; it does not yet connect the native office Apply UI or prove
live-provider, CloudKit multi-account, payment-handoff or production acceptance.
The full application goal remains ACTIVE.

## Integrated workflow

Reviewed field request → exclusive office claim → original local invoice/item
save → exact owner-source confirmation → verified catalog links → exact invoice
publication → verified provider confirmation → payment reservation/dispatch.

- Both directions are checked under the existing `BEGIN IMMEDIATE` transaction.
  A new office claim cannot race an open invoice/catalog publication or existing
  payment. An approved new item cannot reuse a prior shared catalog identity.
- Prepared claims hold involved catalog items, invoice publication and collection.
  This prevents catalog sync from changing a new item's fields before the exact
  owner-source acknowledgment. Recovery reads and immutable receipt retries remain
  available; no provider request is made while holding a database transaction.
- Owner-source confirmation does **not** mean QBO publication. An encrypted link
  binds the original application/proposal hash to a particular immutable billing
  publication/payload hash. Both are revalidated before dispatch. The existing
  provider verifier, not a client flag or callback, establishes confirmation.
- Publication must preserve the complete approved sale: customer/job/invoice
  identities, scoped catalog mappings, ordered sold rows and Group members,
  quantities, prices, taxability and discounts. Descriptive labels may differ;
  charge-bearing facts may not. Current owner-source financial evidence is also
  checked, including paid/finalized state, progress-billing conversion and any
  intervening QuickBooks identity. Existing QBO invoices must be updated, not
  recreated under a new identity.
- Multiple sequential source-confirmed field applications can bind to one final
  complete invoice publication. Mixed CloudKit replica/environment histories
  require review; CloudKit development/production is never inferred to mean
  QuickBooks sandbox/production.
- Payment remains held until a linked publication is confirmed in the original
  QBO realm/environment for the actual provider invoice. Shared aliases and legacy
  invoice IDs prevent a duplicate native UUID from bypassing the hold. An uncertain
  unmapped create also holds collection until its identity is recovered.
- Cancelled unsent publication links are retained. A fresh exact retry gets its
  own link; unknown sends recover through the existing provider-read workflow,
  without another write. Missing/corrupt proof fails closed. The original owner
  receipt intentionally retains `qboPublished: false` as an immutable source-only
  receipt, even after the separate QBO workflow succeeds.

No new native request fields, model endpoint, dependencies, accounts, credentials,
role grants or production settings are introduced. Existing authorization and
connection-grant checks remain in place. The live payment HTTP factory supplies
the existing encrypted-storage decoder; read-only review journals remain usable.

## Failure-pattern corrections

The shared gates cover reservation and the final dispatch callback, not only
the initial review screen. Tests reproduce an approval/payment race, restored
pre-migration reservations, lost provider acknowledgment and intervening source
changes. Only one side of the race can reserve work.

An additional provider-response defect was reproduced: invalid QBO line amounts,
quantities, references or discounts could surface as a local draft `400` error.
The common provider-line validator now reports `provider_unconfirmed` (`409`) to
its recovery, mapped-read and response-projection consumers. The consumed send
permit stays uncertain and collection remains blocked. Local input validation
has not been relaxed.

## Verification and evidence

Evidence directory:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/Invoice Publication Guards.S8gjvj`.
`sources-final.sha256` freezes seven implementation/test files.

- Initial existing owner/billing/catalog/payment regressions: 166 passed in
  37.118s (`existing-focused.log`). This predates the final additional guards.
- Integrated fences plus billing regression: 77 passed in 18.909s
  (`fences-6.log`), before the final current-identity/progress-billing check.
- Final Python 3.12 focused fences/billing regression: 78 passed in 19.485s
  (`focused-final.log`).
- Approval/payment reservation race repeated ten times against independent
  temporary databases: ten passed in 5.631s (`race-repeat.log`).
- Final Python 3.9.6 integration/native-contract regression: 38 passed in 18.680s
  (`python39-final.log`), including all 32 new integration tests and six actual
  native-proposal interoperability tests.
- Initial complete Python 3.12 backend: 1,202 passed before the final added
  source-identity/progress-billing check; historical report
  `/Users/gunnaire/Documents/GunnAireLocalQA/runs/backend-k48_5mzd/report.json`.
- Tools: 75 passed in 4.186s; report
  `/Users/gunnaire/Documents/GunnAireLocalQA/runs/tools-vw20gd33/report.json`.
- Final complete Python 3.12.14 backend: 1,203 passed in 296.422s, zero failures
  or skips; report `/Users/gunnaire/Documents/GunnAireLocalQA/runs/backend-262w5cat/report.json`.
  All seven frozen source hashes still match after the run. The prior full run
  is retained but is not substituted for this final-snapshot qualification.
- Python 3.9 standalone deployment imports and lazy module identities verified
  from the Backend directory, without starting the server.

Earlier `fences-1` through `fences-5` logs retain fixture mistakes and the actual
provider-error classification reproduction. They are not presented as passing
runs. Synthetic fixtures preserve existing Group members and discounts; tests do
not simplify the invoice to obtain a green result. Temporary databases and fake
provider implementations perform no real accounting writes or charges.

No Swift/app source or Xcode project changed in this slice, so the previous native
test/build artifacts are historical evidence, not a new native acceptance run.
No screen access/capture, UI test target, foreground activation, physical install,
deployment, push, signing change, customer message or live provider call occurred.

## Remaining work

Connect the durable native proposal/claim journal and recovery coordinator to the
existing atomic SwiftData save, owner-source/CloudKit publisher, separate catalog
and invoice publication workflows, and a concise office review UI. Do not expose
live Apply before its exact receipt/retry behavior is qualified and a deployed
guard-capable backend is verified (this candidate is `.64`; endpoint presence on
the older `.63` backend is insufficient). Native wiring must also retain the
existing reviewed tax-address workflow alongside the sold-line checks. Then verify
independent-account/two-device CloudKit delivery, iPad/Mac navigation, provider
acceptance, supported iPhone payment handoff and the remaining suite-wide release
gates. This server slice is not the full requested production application.

Skill guidance shaped tenant isolation, preserved sale evidence, transaction
ordering, recovery semantics and the sibling-error sweep. Audit:
`/Users/gunnaire/.codex/skill-audits/skill-usage.jsonl`, task “Connect office invoice
applications to provider and payment recovery boundaries”.

Local coding remains Ollama-only on loopback port 11434. The advisory helper
declined the Backend source path because that directory is outside its approved
source roots; no inference was performed and its read boundary was not expanded.
All test execution here is local and deterministic; the coordinating chat remains
hosted and consumes its normal allowance.
