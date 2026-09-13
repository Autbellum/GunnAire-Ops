# Change order Word export

Verified 2026-09-10. `ChangeOrderWordDocument.docx` exports one saved draft without mutating the project. The native Change orders list exposes Export Word copy. The shared CLI accepts `co-docx project.json record-id new.docx`; installed plugin `0.1.0+codex.20260910162808` exposes `co-docx project.json --co-id record-id --output new.docx`.

Content includes CO number/date/project/customer/author, original/proposed scope, supplied entitlement classification and basis, drawing/spec revision, originating RFI/audit references, time impact, exclusions and required approval language. Quantity comparison and cost tables retain units, signed deltas and sources. Markup basis, tax/bond, computed summary, missing-field list, creation/export dates, identity and project fingerprint accompany the draft. Current linked-RFI metadata is explicitly labeled as current at export, not frozen at creation. Removed links remain identified. Attachments are not embedded.

Unknown costs are not zero; incomplete totals show Unknown — withheld. Credit quantities and costs retain negative signs. A calculated total remains draft-only and does not establish entitlement, complete scope or approval. Output includes no macros or external relationships. Illegal XML text fails instead of being silently dropped. Sources are never overwritten.

The shared WordPackage engine now supports typed paragraph/table blocks; the existing RFI exporter uses the same paragraph path. Tables have explicit widths, wrapping cells, repeated headers and readable compact paragraph spacing. Document geometry remains US Letter with 0.75-inch margins, black headings and Arial body text.

Evidence:

- `output/verification/co-word-tests.log`: 134 tests, zero failures. Three CO export tests cover source immutability, unknown/credit handling, quantity/source/RFI metadata, XML escaping and missing/illegal inputs. Existing RFI export tests still pass.
- `output/verification/co-word-mac-build.log` and `co-word-ios-build.log`: final Mac and generic iOS Simulator builds pass.
- `Tools/verify_co_word.py`: installed-plugin creation/export, valid ZIP/XML, missing-ID rejection, overwrite rejection and source hashes. Final output and summary are under `output/verification/co-word-release/`.
- `Unknown-cost-change.docx` and `Priced-credit-change.docx` are synthetic QA examples. Each was rendered with the bundled document renderer and LibreOffice into two pages; all four final PNGs were visually inspected. Unknown total remains withheld; priced example retains -30 LF and -40 USD credits, +10 USD markup, +2 USD tax, +1 USD bond and +73 USD total. No clipping or extra mostly empty page remains.
- Earlier layout iterations in `co-word/` and `co-word-final/` are diagnostic artifacts, superseded by `co-word-release/`.
- `co-word-plugin-regression.json`: installed plugin's existing 20 operations pass, including source preservation, stale-edit and overwrite rejection.

Native export action compiled, but the platform save-dialog interaction has not been independently UI-tested in this pass. Existing CO draft entry/save/reopen runtime evidence remains in Native-change-orders.md. CO correction/history, authenticated release and direct Ops integration remain pending; this is not full application completion. Nothing was sent or approved.
