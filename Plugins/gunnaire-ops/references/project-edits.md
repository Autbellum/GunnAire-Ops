# Validated local project edits

Use this only for changes within the user's authorized project task. This command does not send RFIs, approve estimates, contact third parties, or publish to Ops/accounting.

From the plugin directory:

```sh
python3 scripts/loadsight.py apply /absolute/project.json --request /absolute/edit.json --output /absolute/new-project.json
```

The input is self-contained JSON exported from LoadSight, including embedded drawing originals when present. `.loadsight` directories are not CLI inputs yet. Output must be a new path; the engine never replaces existing files or symlinks. A successful command prints JSON with `status`, `operation`, `recordID` (for RFI actions), and `output`. Inspect the result and run `review` before reporting readiness. Failed commands return a nonzero exit and do not publish a new output.

Each request is one JSON object. All fields shown for an operation are required; unknown keys are rejected. Populate facts, names and sources from supplied evidence; do not copy example authors into actual records. Empty numeric inputs use JSON null. Intentional zero is numeric 0. No shell interpolation of request contents is needed.

## Create or edit an open RFI

```json
{
  "operation": "rfi.create",
  "author": "Actual person recording the question",
  "title": "One specific conflict",
  "question": "One answerable question",
  "source": "Drawing, detail, keynote or specification reference",
  "impact": "Known scope impact, or Unknown with explanation",
  "priority": "High",
  "itemIDs": []
}
```

Priority is Normal, High or Urgent. `itemIDs` must contain existing unique takeoff IDs or be empty. To edit, use `rfi.edit` and add `id` with the existing RFI identity. Resolved RFIs must be reopened before editing.

## Optional RFI routing and response plan

Both rfi.create and rfi.edit accept an optional `communication` object. If omitted, existing values are preserved. If supplied, it replaces all five fields and must contain exactly these text keys; use an empty string for an unknown value or to explicitly clear one. Null, missing nested keys and unknown keys are rejected.

```json
{
  "to": "Recorded recipient",
  "from": "Recorded sender",
  "date": "2026-09-10",
  "requiredResponseDate": "2026-09-17",
  "suggestedResolution": "Proposed resolution requiring the recipient's response"
}
```

Use actual supplied dates, not these examples. Dates must be blank or a valid Gregorian YYYY-MM-DD date. No date is inferred from the export time, and recorded-by is not the sender. Past deadlines remain source facts; this operation does not schedule reminders or send RFIs. Saved fields have communicationVersion1, follow the same history/QA invalidation as question edits, and survive resolution/reopening. Changing a resolved question or its communication fields requires reopening first. Word export includes current and historical supplied values.

## Record an evidenced resolution

```json
{
  "operation": "rfi.resolve",
  "author": "Actual person recording the answer",
  "id": "Existing RFI identity",
  "response": "Documented answer",
  "responseSource": "Answer document or correspondence reference",
  "respondent": "Actual person who supplied the answer"
}
```

This records an answer already available to the user; it does not ask the recipient or send a message. Quantities, prices and holds are not automatically changed. Review affected takeoff rows separately.

## Reopen

```json
{
  "operation": "rfi.reopen",
  "author": "Actual recorder",
  "id": "Existing RFI identity",
  "reason": "Why the documented answer needs review"
}
```

The earlier answer remains in history. The current answer is cleared and QA reopens.

## Commercial assumptions

```json
{
  "operation": "commercial.update",
  "author": "Actual recorder",
  "name": "Project name",
  "estimator": "Responsible estimator",
  "basis": "Source or reason for changed assumptions",
  "fields": {"laborRate": null, "customer": "Customer name"}
}
```

`fields` is a partial update. Allowed numeric keys: laborRate ($/hour), markupPct (markup on total cost, not margin), taxAllowance ($), jobCosts ($), contingency ($). Values must be nonnegative finite numbers or null. Text keys: customer, proposalTerms. Other inputs and extensions are retained. Changes record before/after history and reopen QA; no-op updates preserve review state. This does not authenticate approval.

## Proposal details

Use `operation: "proposal.update"`, `author`, `source` (reason or document basis), and `fields` containing text values. Allowed keys: address, scopeOfWork, inclusions, exclusions, assumptions, alternates, bonds, schedule, leadTimes, validity, addendaBasis, attachments. Fields are partial updates. Narratives do not change prices; attachment references do not import files.

## Item quantity and scope review

Use `operation: "item.review"`, `author` (actual reviewer), `id`, `scope`, `status`, `allowanceNote`, and `evidence`.

Scope: Base, Allowance, Hold, Excluded. Status: Review required, Verified, Field-verified, Cross-checked, Scope-defined, Approved allowance. Approvals require known quantity, unit and source; approved allowances require written allowanceNote and Allowance scope. The reviewed values are retained for stale-review detection. This command does not change quantity or resolve an RFI. Record a review only when its stated evidence has actually been reviewed; never invent a field verification or reviewer identity.

## QA review or reopening

Use `operation: "qa.review"`, `author` (actual reviewer), `id` (QA-01 through QA-12), `complete` (JSON true/false), and `evidence`. A completed review binds to the current semantic project state. Final QA-12 requires current reviews for the prior checks and a different reviewer name from the responsible estimator. These are local records, not authenticated identities. Do not mark checks complete merely because software tests pass or the command exists. Record only the user's actual review decision and supporting evidence; keep other checks open. This command does not publish a proposal or issue purchase authorization.

## Retain an attachment

Use `operation: "attachment.add"`, `author`, `filename` (single filename), `dataBase64` (base64 of the exact supplied file bytes), `source`, and `rfiID` (existing RFI identity or JSON null). Read and encode the user-supplied file with a local script; do not invent bytes or execute the attachment. The SDK retains original bytes, computes SHA-256, deduplicates identical content and preserves source references. Limit: 64 MB per file. Adding an attachment reopens QA but never resolves its RFI. The returned recordID is its content hash.

## Air conditions and processes

`aircondition.create`, `aircondition.derive` and `airprocess.create` use the same project lifecycle and new-file output. See [air-processes.md](air-processes.md) for required fields, exact units, limits and the read-only `air-review` output.

## Envelope assemblies

`assembly.create` creates an append-only sourced envelope assembly, reopening QA. `envelope-review` reports all saved assemblies and recomputed equation traces. Required nested schema, units and limitations are in [envelope-assemblies.md](envelope-assemblies.md).

## Room transmission

`room.transmission.create` appends a sourced room transmission case linked to existing assemblies. `room-review` returns recalculated partial opaque loads and supporting assembly records. Exact nested fields and exclusions: [room-transmission.md](room-transmission.md).

`room.transmission.revise` revises a stable room ID using a current room-review editFingerprint, explicit reason and complete replacement inputs. See room-transmission.md for revision payload, snapshot retention and stale-edit behavior.

## Change order creation

`changeorder.create` accepts a strict draft object. See [change-orders.md](change-orders.md) for the complete schema, unknown/credit semantics and review command.

`changeorder.revise` uses the same complete draft plus id, expectedFingerprint and reason; see change-orders.md for history and stale-edit semantics.

## Ops project context

`ops.context.update` records or removes an explicit customer/job snapshot with a current `ops-review` fingerprint. See [ops-project-context.md](ops-project-context.md). It does not change Ops records or authorize billing.

Catalog material snapshots are available through `catalog-review` and `catalog.material.update`. See [catalog-material-mapping.md](catalog-material-mapping.md) for exact fields, explicit USD/unit evidence, unknown costs, history, removal and stale-edit protection. No live catalog fetch or accounting publication is performed.
