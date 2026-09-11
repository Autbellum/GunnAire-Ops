# Staff invoice-line requests — backend capture and review

## Status

Backend source version `2026.09.10.61`. This is a local, synthetic-test-qualified request-capture slice, not a deployment or a completed staff billing workflow. Full production goal remains active.

New files: `Backend/staff_invoice_lines.py`, `Backend/test_staff_invoice_lines.py`. Backend routing, schema initialization, service version and access-log redaction are updated in `Backend/gunnaire_backend.py`.

No Swift source, signing, CloudKit capabilities, provider accounts, live invoices, payments, catalog items, deployment or UI automation were changed. Existing scalar staff commands still exclude financial and structured-field writes.

## Contract

Schema: `staff-invoice-line-request-v1`.

| Route | Authority | Meaning |
| --- | --- | --- |
| `POST /api/workspace/staff-shares/{shareID}/full-selections/{selectionID}/content/invoice-line-requests` | Original active staff account, currently accepted share, matching membership/role, company and replica | Record one immutable proposed invoice line. No query string. Maximum body 16 KiB. |
| `GET /api/workspace/invoice-line-requests` | Current business Admin and approved owner workspace | List request IDs; exact companyID/environment/replicaID query and optional canonical UUID `after`. 50 IDs per page, nullable nextCursor. |
| `GET /api/workspace/invoice-line-requests/{commandID}` | Current business Admin and approved owner workspace | Read original request, receipt, private base invoice/item and current owner invoice/item for review. Same exact scope query, no cursor. |

Request fields are exact: schema, companyID, environment, replicaID, commandID, selectionID, sourceSequence, contentSHA256, invoiceID, invoiceRevision, customerID, nullable jobID, line, reason.

Line fields are exact: kind (`catalog` or `new`), itemID, itemRevision, itemType, name, nullable description, nullable sku, unitPrice, quantity, isTaxable, nullable equipmentID.

- UUIDs are canonical lowercase. CloudKit environment is development/production, not QBO's sandbox/production selector.
- Names: 200 UTF-8 bytes; description/reason: 2,000 bytes; SKU: 100 bytes. New input is trimmed and nonempty when present; catalog text is preserved exactly, including blank optional fields.
- Quantity is positive and at most 999,999. Unit price is nonnegative. Both permit up to five decimal places. Price and quantity-times-price must be at most 99,999,999,999. No bool-as-number, NaN, infinity or numeric strings.
- New items are document-scoped proposals of type Service/NonInventory, revision 0. They are not approved pricebook items or QBO mappings.
- Catalog selections require the exact shared item revision, sales values and approved review status (legacy null means approved). Archived/unapproved items cannot be selected for new work. Types: Service, NonInventory, Inventory, Group.
- The invoice must be visible under the original role-filtered projection, match original customer/job/revision, and remain unpaid/overdue and unfinalized. Field technicians require an assigned job. Supplied equipment must be shared and belong to that customer.
- New requests require current source sequence. An exact original request can recover its receipt after source changes, provided its current account/share authority still holds.

Receipt fields: schema, complete original request, actorEmail, shareID, createdAt, state=`recorded`, officeReviewRequired=true, qboPublished=false, lineSubtotal.

`lineSubtotal` is a two-decimal, half-up quantity-times-unit-price subtotal string, not an expanded package price, invoice total, tax quote, approval, amount due or payment. Groups return null until their members are resolved in the owner workflow. Itemized service assemblies also require owner expansion; clients must not treat this unit-price arithmetic as their final package quote. Receipt does not include private base invoice/item, purchase cost or owner-only fields.

Office detail includes immutable baseInvoice/baseItem and their SHA-256 digests, currentInvoice/currentItem, invoiceUnchanged, itemUnchanged, currentSourceSequence and sourceUnchanged. The last flag requires both original records and the original source sequence to remain unchanged. Missing/deleted/changed originals do not become permission to auto-apply anything. Owner review remains available after staff revocation, but revocation blocks staff replay.

## Durability, privacy and retry rules

- A single SQLite transaction stores the encrypted complete request, receipt and original invoice/catalog base; indexes retain only routing/author metadata.
- commandID is immutable. Same author/share/body replays the same receipt, including after server initialization or concurrent delivery. Changed body conflicts rather than replacing intent.
- New-item UUIDs are reserved uniquely within company/environment/replica across requests, in addition to checking original catalog records including tombstones. A retry must retain the original command ID and item ID.
- Maximum 128 recorded requests per staff author/share/invoice. Replays still work at capacity. No request is silently evicted. Resolution and archival policy remain work for the owner-application slice.
- Saved envelope, metadata, original record types/scope/revision, customer/job, base digests and receipt values are checked on replay/review. Corruption fails closed and retains the original stored bytes.
- Encryption/audit failure rolls back the request. New routes redact query/document IDs from access logs. Static API tokens cannot substitute for application sessions.

## Verification

Evidence directory: `/Users/gunnaire/Downloads/GunnAire Ops Releases/Staff Invoice Requests.rapgZP`.

- Before routing: 2 HTTP happy-path tests failed with 404, establishing the missing path (`before-routing.log`).
- Initial routes: 2/2 passed (`focused1.log`).
- Expanded first run: 23 tests, with 2 incorrect test expectations for private-share 404s and 1 incorrect fixture session-table name; corrected without relaxing account boundaries (`focused2.log`).
- Final focused: 28/28 passed (`focused3.log`). Includes real local HTTP, concurrency, encryption rollback, lost receipts, owner conflicts, revocation, session expiry, role/tenant isolation, immutable prices, new-item identity reservation, archived/unapproved catalog rejection, validation, route/body bounds, pagination/capacity, corruption preservation and log privacy.
- Full backend: 1,130/1,130 passed on Python 3.12, 255.864 seconds; helper report `/Users/gunnaire/Documents/GunnAireLocalQA/runs/backend-dqj9jdqi/report.json` and raw log in that directory. The helper used `python -m unittest discover -s Backend -p test_*.py` in the validation checkout, with stripped provider configuration and synthetic storage.
- Full backend: 1,130/1,130 passed independently on system Python 3.9.6, 257.547 seconds (`backend-python39-final.log`). Same test discovery command, installed local dependencies, stripped provider configuration and temporary synthetic storage. Neither full run had failures or skips.
- Tools: 75/75 passed; `/Users/gunnaire/Documents/GunnAireLocalQA/runs/tools-jwmlxwsr/report.json`. No model inference or cloud fallback was requested for any suite.
- Python 3.9's first isolated launch disabled its installed user-site cryptography dependency and failed import discovery; that run is not a qualifying test result. Rerun preserves installed dependencies while stripping provider configuration and using temporary synthetic storage.
- The local QA helper serializes suites; the simultaneous Tools launch was refused by its existing lock, not counted as a test failure. Tools is rerun after Backend releases the lock.

No native build is claimed for this backend-only slice. Native source is unchanged from the previous qualified billing-workspace commit `f4af439a07afa553e4224a490b64491dd148e9de`.

## Required next slice

1. Native typed request/receipt and exact bounded authenticated transport. Preserve the current account/share lease and recheck it across async waits; no owner credential substitution.
2. One durable, account/plan/invoice-bound encrypted primary journal containing full immutable requests and receipts. Stage before sending, keep original IDs and recover lost acknowledgments. Do not use an independently written discovery index that can lose requests.
3. Staff compose/catalog/new-item UI and clear states: locally saved, sending, recorded for office review, conflict, unavailable. Never present `recorded` as invoiced, approved or QBO-synced.
4. Office review, rejection and conflict-aware recoverable claim/save/source-confirm workflow in the original owner ModelContainer. Resolve catalog package members (including itemized service assemblies), document pricing/taxes/discounts, existing customer approvals/signatures, item provenance and duplicate-line semantics before applying.
5. Only then hand approved native work to existing explicit QBO publication/reconciliation workflows, with exact company/realm/mapping and stable publication identity. Staff requests must not directly create QBO entities or collect payments.

## Local AI and skill governance

Ops coding AI remains Ollama on `127.0.0.1:11434`, using `gunnaire-coder:ops` or `gunnaire-coder:v1`. No Stable Diffusion/ComfyUI/LocalCanvas route or in-app LLM configuration was added. Heavy regression execution is deterministic and local; no model inference is needed to run these tests.

Account-wide weekly usage after qualification: 26% used / 74% remaining. The project's conservative stop threshold remains 45% used to preserve the user's requested 50% reserve; this is a shared account measurement, not a project-specific spending lock.

API/QBO, identity, payments, HVAC and offline guidance shaped the immutable, author-bound, review-only financial boundary. Swift/interface skills were considered/read for the following native phase; this slice makes no Swift/UI change. Image generation/training, Apple release and unrelated platform skills do not apply to this backend slice. Live audit: `/Users/gunnaire/.codex/skill-audits/skill-usage.jsonl`; bounded task: `Qualify immutable staff invoice-line request backend`. The broader native invoice/item/QBO workflow remains started.
