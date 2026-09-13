# Native staff invoice requests — 2026-09-11

## Scope

This slice connects the staff invoice reader to a focused native item-request composer. Recording a request is **not** an invoice mutation, owner approval, customer approval, tax calculation, payment, or QBO publication. The overall production-suite goal remains active.

Technicians and authorized accounting/admin staff can request an approved catalog item or a new service/non-inventory part, enter quantity and work performed, and associate a shared system belonging to the invoice customer. Paid/finalized invoices require office correction. Catalog prices are not silently updated; refreshing shared work retains typed input and requires explicit review and catalog reselection.

The composer uses the existing verified CloudKit staff projection and staff session authority, never an owner model container. Each invoice has one encrypted device journal containing unfinished input, stable operation/item IDs, complete queued requests, and verified office receipts. Writes use revision checks and immutable request/receipt history. Offline errors, lost acknowledgments, source advances, cancellation, account changes, and concurrent windows retain original work. No secondary discovery index or silent capacity eviction is introduced.

The dedicated POST client validates its exact route and 16 KiB request contract, rejects redirects through the existing bounded transfer, limits responses to 32 KiB, and checks current session authority before and after transmission. A receipt must match the original request, author, share and recorded-only state. It cannot claim a financial write or QBO publication.

## Navigation and presentation

The invoice toolbar opens one scoped form with catalog search, new-item fields, system selection, saved-draft feedback and retry status. No protocol IDs or raw payloads are displayed. The invoice editor is mutually exclusive with the field editor and lives above the changing hosted workspace identity. Revocation clears displayed data without deleting encrypted drafts.

The UI follows Apple's guidance for [scoped sheets](https://developer.apple.com/design/human-interface-guidelines/sheets) and [data entry](https://developer.apple.com/design/human-interface-guidelines/entering-data). The offline and access-control skills required stable durable intent and fresh authority checks; the financial skills kept recording separate from accounting changes. Interactive UI/accessibility qualification remains unperformed under the user's no-screen/no-UI-automation constraint.

## Cross-language repair and sibling coverage

Actual local Python HTTP request/receipt vectors exposed a Foundation mismatch: Python `-0.0` and Swift `-0` compare differently after JSONSerialization. The shared strict decoder now normalizes only literal signed-zero number tokens for structural comparison. Strings, booleans, nonzero values, original stored/wire bytes and digests are not normalized. Duplicate keys, unknown fields, missing required nulls, numeric/type substitution and malformed JSON remain rejected. Using the shared decoder closes the same zero-value gap in sibling publication/receipt readers. Backend version `2026.09.10.62` formats a zero line subtotal as `0.00`.

An initial catalog regression fixture incorrectly used a two-unit draft line as a one-unit catalog choice; the fixture was corrected to match the actual source builder. This did not relax catalog equality checks.

## Local AI and verification

Ollama `gunnaire-coder:ops` on loopback port 11434 provided an advisory journal-test draft (298 generated tokens; 11.576 seconds). It invented helper APIs and incorrectly rejected exact replay. Its raw output was neither applied nor executed; three corrected boundary tests were implemented and run. No Stable Diffusion endpoint, app LLM client, model download or cloud fallback was introduced. Hosted orchestration still uses the account's normal allowance.

Evidence directory: `/Users/gunnaire/Downloads/GunnAire Ops Releases/Native Invoice Requests.h0Q0JI`.

- Initial focused request/storage run: 11 passed.
- Expanded focused run: 34 executed, 2 failures; both investigated and repaired.
- Corrected focused run: 40 passed; all six required suites verified from xcresult test identities, with no skips.
- Full iPad simulator native suite: 2,290 passed (373 XCTest + 1,917 Swift Testing cases); zero failures/skips. All seven required target/suite selectors were verified from the authoritative xcresult tree. The 36 new tests include cancellation, concurrent retry, malformed receipts and the shared signed-zero decoder regression.
- Backend Python 3.12: 1,130 passed; local QA report `backend-ivdx4z5t`.
- Tool regression: 75 passed; local QA report `tools-dcev1qfz`.
- Backend Python 3.9.6: 1,130 passed in 258.102 seconds, with temporary synthetic storage and provider environment stripped.
- Mac Catalyst Release build: passed with signing disabled; binary contains both `x86_64` and `arm64`. The app was not launched or installed. These build/test results qualify the validation checkout, not an App Store release.
- Owner checkout post-copy backend request tests: 28 passed. All 22 copied source/test/report files were byte-identical to validation; owner branch, HEAD and index were preserved. No unrelated owner files were copied or staged.

Only hidden simulator unit tests are used. No screenshots, screen reading, foreground activation, UI tests, physical-device installs, signing changes, deployment, git push/merge, NAS changes or live provider/accounting writes occur in this slice.

## Remaining

Office review/application into original invoice/item models, approval and tax/account mapping, idempotent QBO publication and reconciliation, and their complete native recovery/UI workflow remain to be implemented and qualified. This request-capture slice must not be represented as that completed financial workflow or as production release approval.

Skill audit: `/Users/gunnaire/.codex/skill-audits/skill-usage.jsonl`, task `Connect native staff invoice requests and durable composer`. Broader task `Complete native staff invoice item creation and QBO handoff` remains active.
