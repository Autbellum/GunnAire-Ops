# Change order drafts

Implemented shared Swift draft creation and recomputed review, plus native Change orders workspace with new-draft form and saved-record detail. The native form supports sourced quantities, all cost categories, explicit markup basis, linked RFIs and a live draft review. Invalid numeric text stays available for correction; unsaved dismissal requires discard. CO Word export is available from the native list and `co-docx`; see [change-order-word-export.md](change-order-word-export.md). Existing records support authored corrections with full snapshots and stale-edit checks. Authenticated approval and Ops publishing remain pending. A draft is not an approved change and does not alter the base estimate. Entitlement classification records the supplied claim; it does not determine contractual rights.

Use `python3 scripts/loadsight.py apply /absolute/project.json --request /absolute/request.json --output /absolute/new-project.json`, then `python3 scripts/loadsight.py change-review /absolute/new-project.json`. Input projects remain unchanged. Output must be a new path. Local self-contained JSON only.

Request fields are exactly operation, author, draft. Draft fields and nested fields must match the example below, including nulls. A blank text field records missing information. Unknown numeric values must be null, never a guessed zero. All known amounts, including zero, require a source. Dates are blank or real YYYY-MM-DD calendar dates. Numbers are unique within the project, ignoring case and surrounding whitespace. RFI links must identify existing RFIs at creation. Project name, author, creation time and draft-only status are saved with the record.

```json
{
  "operation": "changeorder.create",
  "author": "Recorded author",
  "draft": {
    "number": "CO-001",
    "date": "",
    "customer": "",
    "entitlement": null,
    "entitlementBasis": "",
    "originalScope": "Supplied original mechanical scope",
    "proposedScope": "Supplied proposed mechanical scope",
    "drawingRevision": "",
    "rfiIDs": [],
    "auditReference": "",
    "quantities": [],
    "costs": [
      {"category": "labor", "delta": {"amount": null, "source": ""}},
      {"category": "material", "delta": {"amount": null, "source": ""}},
      {"category": "equipment", "delta": {"amount": null, "source": ""}},
      {"category": "subcontractor", "delta": {"amount": null, "source": ""}}
    ],
    "markupPercent": {"amount": null, "source": ""},
    "markupBasis": null,
    "tax": {"amount": null, "source": ""},
    "bond": {"amount": null, "source": ""},
    "timeImpact": "",
    "exclusions": "",
    "approvalLanguage": ""
  }
}
```

Entitlement values: Owner change, Hidden condition, Document conflict, Code interpretation, Design revision, Field condition, Schedule acceleration. Null remains unknown.

Quantity entries have exactly name, unit, original and proposed. Each original/proposed object has amount and source. Quantities are nonnegative or null; delta is proposed minus original when both are known. An empty ledger is reported as unknown. Quantity deltas do not automatically price the work; supplied quoted cost deltas are independent.

Costs are signed USD deltas and must include all four categories exactly once. Negative means credit. `knownCostDelta` sums only known amounts and is not a complete subtotal; `costDelta` is absent until all four costs are known. Markup percentage is nonnegative and needs an explicit basis: `signedNetCosts` applies to the signed net cost delta; `positiveAdditionsOnly` applies to positive category deltas only. Tax and bond are supplied signed dollar deltas, not automatically derived rates. Total equals cost delta + markup delta + tax delta + bond delta, and is withheld until each is known. JSON optional calculated amounts may be absent, never interpret absence as zero. Nonfinite values/overflow fail. Display currency rounded to cents; the model uses double precision and does not round intermediate arithmetic.

`change-review` returns each saved record and recomputed arithmetic, quantity deltas, missing fields and limitations. A calculated total does not establish completeness or approval. Creating a draft reopens QA; records are retained within native packages and portable JSON. No delete or approval operation is exposed. See revision instructions below.

## Revise a saved draft

Read `change-review` to obtain the record ID and its `editFingerprint`. Use operation `changeorder.revise` with exactly `author`, `id`, `expectedFingerprint`, `reason` and `draft` in addition to `operation`. Draft uses the complete create schema above, including null optional fields. Author and reason must be nonblank. Do not reuse the creation author as the editor unless that person actually records the correction.

The revision retains the record ID, original project name, creator and creation time, and draft status. It replaces supplied draft values, including optional fields explicitly cleared to null, and appends full before/after snapshots with revision author/date/reason. New RFI links must exist; unchanged historical links may remain if their RFI was removed. QA reopens. Root and record extension fields are preserved.

Stale edit tokens fail without changing the project. Tokens bind the full record and latest revision ID; even a same-values revision invalidates an earlier token. Unrelated CO or QA changes do not invalidate this record token. Reopen the current record and reconcile changes before retrying; do not silently fetch a new token and replay an old draft.

`change-review` includes each record's token and history. History validation rejects duplicate revision IDs, broken snapshot chains, invalid before/after records, changed creation metadata/status and disagreement with the current record. This is local consistency evidence, not authenticated approval or tamper-proof storage. Native Revise draft loads saved values, clears the editor author, requests a reason and preserves failed/stale form input. Native detail opens complete Before/After revision snapshots. Word export adds the latest revision metadata and a changed-field appendix with sources and before/after totals.
