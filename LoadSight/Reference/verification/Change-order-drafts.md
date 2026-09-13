# Change order draft foundation

Verified 2026-09-10 with synthetic fixtures. Shared Core model supports original/proposed mechanical scope, supplied entitlement classification and basis, drawing revision, RFI/audit references, sourced quantity ledger, four signed USD cost categories, markup basis, tax/bond deltas, time impact, exclusions and approval-language placeholders. Missing optional fields remain unknown. Saved records are immutable drafts with project snapshot, author and creation time. No approval, revision, native editor or Word exporter is included yet.

Quantity delta is proposed minus original; nonnegative known quantities require sources. Quoted cost deltas are independent of the quantity ledger. Labor/material/equipment/subcontractor are required exactly once, with null for unknown values. Sources are required for every known number, including explicit zero. Markup applies either to signed net costs or to positive category deltas, selected explicitly. Total is withheld for incomplete cost/rate/basis/tax/bond data. A calculated total remains a draft and does not mean scope completeness or entitlement. Double precision arithmetic rejects nonfinite/overflow results; display rounding is separate.

Validation evidence:

- `output/verification/change-order-tests.log`: 129 tests, zero failures. Six new cases cover unknown/zero, credits and markup policy, independent quantities, evidence/date/category/overflow validation, atomic persistence and QA reopening, unsupported approval status and strict nested request validation.
- `output/verification/change-order-mac-build.log`: native Mac build passed.
- `output/verification/change-order-ios-build.log`: generic iOS Simulator build passed.
- Installed plugin `0.1.0+codex.20260910161940` passed manifest validation and installation.
- `Tools/verify_change_orders.py` exercised that installed plugin. Evidence in `output/verification/change-orders/summary.json`: unknown total withheld, synthetic quantity credit -30 LF and cost delta +73 USD under positive-additions markup, source hash unchanged, overwrite/duplicate/nested typo rejected with no invalid output created.
- Existing installed-plugin regression retained in `output/verification/change-order-installed-plugin.json`.

Structured `changeorder.create` uses the same Core save and validation methods. `change-review` returns saved inputs and freshly computed review; no base estimate quantity/price is changed. CLI output files remain new paths only. Native document/JSON storage retains the additional root ledger. Imported record extensions stay in the raw project tree. No network action or outgoing document occurred.

Remaining: CO native authoring and review, correction/history workflow, DOCX layout and visual verification, authenticated approval and direct GunnAire Ops integration. Full application objective remains active.
