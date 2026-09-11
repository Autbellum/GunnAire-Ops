# Native office invoice boundary — 2026-09-11

## Delivered scope

This candidate adds a typed, review-only proposal planner and a tested SwiftData
application boundary for the server protocol in
`OFFICE_INVOICE_APPLICATION_PROTOCOL.md`. It does **not** enable a live Apply
button, add a backend transport permission, or complete staff-to-QBO invoicing.
The full application goal remains ACTIVE.

- Full original/current records, immutable staff requests, scoped pagination,
  explicit-null receipts and prepare/confirm bodies have strict native contracts.
- Planning changes no live model. It preserves existing sold prices, quantities,
  package components, ordered Group members, discounts and customer-system links,
  including equipment type/model/serial. Conflicting sales cannot be silently
  combined. Nonzero manual balances, locked invoices, missing dependencies and
  inconsistent saved totals stop for review.
- Recovery validation rechecks financial totals, exact requested quantities,
  customer/job/location/equipment relationships, unchanged unrelated lines,
  new-item author/approver and absence of inherited provider evidence. Changed
  work clears stale signatures/tax and remains pending QuickBooks review.
- The synchronous save boundary applies an invoice and any new item in one
  transaction under the original identities. Exact retry, lost acknowledgment,
  save failure, unsaved drafts, access loss and intervening committed changes
  have executable tests. Callers must still retain and verify the server's exact
  proposal/claim and current authority before using this boundary.

## Defects reproduced and corrected

The first 25-test run retained two failures in `focused4.log`:

1. Binary percentage arithmetic discounted 346.75 by 34.67 rather than the
   backend's decimal half-up 34.68. The original native discount proposal was
   independently rejected by the actual backend validator. Shared discount and
   currency helpers now retain decimal arithmetic through rounding and guard
   Int64 overflow. They do not rewrite stored historical invoices automatically.
2. A failed invoice save rolled storage back but left the registered model's
   amount stale. Restoring the owned accessors before rollback corrects both
   store and UI object without another save. The sibling owner field-edit path
   receives the same correction and an actual registered-object assertion.
3. The subsequent sibling sweep found an unbounded Double-to-Int64 conversion
   in QBO accounting-payment matching. Oversized and fractional-cent local or
   provider amounts now fail validation instead of trapping or rounding into
   another payment's amount. Reporting/field-receipt converters were checked;
   their existing exact-cent/range guards already exclude this failure.

`NativeOwnerInvoiceInterop.json` contains five synthetic proposals exported by
the real native planner (new, discounted, catalog, itemized, Group). All are
validated by the Python domain contract; its generated receipts round-trip
through the strict Swift types. Six Python tests guard this fixture. These are
cross-language/domain checks, not HTTP authorization or live-provider acceptance.

## Verification

Evidence directory:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/Native Office Invoice.3J5yJx`.
`sources-final.sha256` freezes all twelve changed/new implementation and test
inputs. Verification runs in the dedicated validation checkout; the owner copy
is separately compared byte-for-byte.

| Check | Confirmed result / evidence |
| --- | --- |
| Focused native regression after rounding/rollback fixes | 51 passed; `focused5.log`. |
| Final full native regression including payment-range guard | 2,320 passed, zero failures/skips: 403 XCTest + 1,917 Swift Testing; `full8.xcresult`, summary and test tree. All nine required target/suite/test selectors verified. |
| Complete Python 3.12.14 backend | 1,171 passed in 277.739s; `/Users/gunnaire/Documents/GunnAireLocalQA/runs/backend-0nozrzkb/report.json`. |
| Python 3.9.6 native/protocol interop | Six passed; `python39-interop.log`. This is not a new full Python 3.9 backend run. |
| Tools | 75 passed in 4.299s; `/Users/gunnaire/Documents/GunnAireLocalQA/runs/tools-ualkolzq/report.json`. |
| Owner post-copy interop | Six passed; `owner-post-copy.log`. |
| Unsigned Mac Catalyst Release | Passed; `mac-final.log`; binary independently verified as `x86_64 arm64`. Two Metal toolchain search-path linker warnings remain, one per architecture; none suppressed. |
| Unsigned iOS Release | Passed; `ios-final.log`; binary independently verified as `arm64`. |

All final qualification processes exited zero. Earlier release builds predate
the last payment guard and are not used in place of the final builds above.

Native tests use only `GunnAire OpsTests` on hidden simulator
`0ADE5A1A-9859-4377-AD5E-93FC6D70F1D3`, scheme `GunnAire Ops`, with signing disabled,
two build jobs and parallel test execution disabled. No UI target was run.
The original failed runtime/compile attempts are retained rather than relabeled.

## Remaining integration and production gates

The durable native journal, current-owner coordinator and office review UI are
not connected. The subsequent `INVOICE_APPLICATION_PUBLICATION_GUARDS.md` candidate
implements shared server guards between invoice applications, catalog publication,
invoice publication and collection, including final pre-send checks and recovery
of existing ambiguous attempts. Consult its separate qualification evidence before
connecting and enabling native Apply; the earlier native run does not qualify it.
Payment collection must not use the old QBO amount after an office source
confirmation. `published` is owner-source proof, never QBO success.

Resolve retained claims safely, then connect the existing owner-source/CloudKit
publisher and explicit QBO publication/reconciliation workflow. Test two-device
and independent-account CloudKit behavior, supported payment handoff, provider
acceptance and iPad/Mac navigation before production readiness. No deployment,
push, signing changes, physical-device install or live provider/accounting write
is performed by this slice. No screens are inspected, captured or recorded; no
UI test target is executed.

## Local inference and skill audit

Ollama on `127.0.0.1:11434` remains the only Ops coding backend, with approved
`gunnaire-coder:v1`/`:ops` digests. The directive and evidence already existed and
were reverified; 35 deterministic helper tests pass. One advisory `:ops` call
used only reviewed synthetic-free source code, produced 545 tokens in 13.95s,
and was rejected for inventing mock types. No generated code was applied or
executed, no app LLM endpoint was added, and no image-generation service was used.
The hosted chat was not switched to local inference.

Skill guidance materially shaped tenant/dependency checks, preservation of sold
facts, lossless retries and the sibling regression sweep. Live audit:
`/Users/gunnaire/.codex/skill-audits/skill-usage.jsonl`.

All twelve implementation/test files were copied through exact preimage and
absent-new-target checks and verified byte-for-byte in the owner project. A
broader tracked Swift/Python/project-input comparison found no unrelated input
differences. The owner's branch `codex/internal-team-tasks-20260830`, HEAD
`ff2189c3dfe9cc2d3e2ca79cbf1a6b53572aa45c` and index digest
`19b5872ad9b8c52ee43bd28c7075b93efaac46a933a09abda91dd2705bde254d`
remain unchanged. The two evidence documents are copied separately; any new
commit is local to the validation branch, not a push or owner-branch commit.
