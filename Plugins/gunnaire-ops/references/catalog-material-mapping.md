# Catalog material mapping

`catalog-review project.json` returns each takeoff item's current fields, saved mapping, `mappingCurrent` (true, false, or null when unmapped), full mapping history and `editFingerprint`. This reads the project; it does not fetch the live Ops catalog. Obtain a source snapshot from the native Ops selector or explicit user-supplied catalog evidence. Never invent catalog IDs, purchase costs, units, currency, supplier identity or compatibility.

Use `apply` with operation `catalog.material.update` to create/revise a mapping, or explicit `mapping: null` to remove it. The command writes a new project JSON and preserves the source. Copy the current fingerprint for that item from `catalog-review`. Unknown or missing request fields are rejected; every nested field below is required. Use explicit null for unknown purchaseCost. Dates in the source are recorded catalog timestamps, not quote expiration dates.

```json
{
  "operation": "catalog.material.update",
  "id": "actual takeoff item ID",
  "author": "recorded estimator",
  "reason": "reason for selecting or changing this cost basis",
  "expectedFingerprint": "copy the current item fingerprint from catalog-review",
  "mapping": {
    "version": 1,
    "catalog": {
      "id": "actual source catalog UUID",
      "source": "actual catalog and account-context reference",
      "name": "actual catalog material name",
      "sku": "",
      "supplier": "",
      "supplierPartNumber": "",
      "purchaseCost": null,
      "updatedAt": "actual ISO-8601 catalog timestamp"
    },
    "currency": "USD",
    "purchaseUnit": "confirmed purchasing unit",
    "catalogUnitsPerTakeoffUnit": 0.2,
    "takeoffUnit": "LF",
    "itemDescription": "exact current takeoff description",
    "lifecycle": "exact current takeoff lifecycle, or empty if absent",
    "basis": "recorded currency, part compatibility and unit-conversion evidence"
  }
}
```

The text above describes required values, not a runnable source record. The factor 0.2 illustrates five-foot purchased lengths per one LF; it is not a default. The user must establish USD and the actual conversion. The engine supports only USD for this estimate. Conversion factors must be finite and greater than zero. The takeoff unit, description and lifecycle must match the current item.

Applying changes only material cost to purchaseCost × catalogUnitsPerTakeoffUnit, including replacing a known number with unknown when purchaseCost is null. Quantity, labor, other cost, waste and existing price/labor references are retained; QA reopens. Catalog selling price is never substituted for purchase cost. Removal keeps the current entered material cost and records its reason; review its manual basis afterward.

Snapshots and complete before/after history remain in package/JSON exports. Later live catalog changes do not automatically reprice the project. A manual material-cost, unit, description or lifecycle change makes the saved mapping stale for review. Reopen and explicitly revise or remove it; do not force an old fingerprint or erase history. Recorded author/source assertions are not authenticated approval, supplier confirmation, purchasing authorization or permission to publish billing.

Quote validity/lead-time policies and live catalog comparison remain separate unfinished work.

`xlsx project.json --output new-workbook.xlsx` exports the native five-tab workbook: Takeoff, RFIs, Review, Material costs and Catalog history. It retains current/stale/removed/unmapped cost states, blank unknown costs, source identities, purchasing-unit conversion and full before/after field history. Values are fixed export snapshots, not a live catalog or recalculating pricebook. Existing paths and symlinks are rejected.

## Supplied catalog comparison

Run `python3 scripts/loadsight.py catalog-compare project.json --catalog supplied-catalog.json` to print a read-only JSON report. The catalog file is an array; every record requires exactly `id` (UUID), `source`, `name`, `sku`, `supplier`, `supplierPartNumber`, `purchaseCost` (nonnegative number or explicit null), and `updatedAt` (ISO 8601). Empty arrays are valid. Unknown fields and omitted cost evidence reject.

The version-1 report provides each item's edit fingerprint, mapping currentness and comparison. Unmapped rows have `comparison: null`. Mapped rows distinguish `unchanged`, `changed`, `missing`, `ambiguous`, `differentSource` and `olderSource`; differences preserve unknown versus zero. Candidate and purchase-cost delta are explicitly null when unavailable. A raw purchase-cost delta does not establish a converted unit price, currency or quote validity.

The command compares caller-supplied records only. It does not fetch suppliers, establish freshness, edit projects, reopen QA or publish costs. Review unit/currency/compatibility evidence before making a separate `catalog.material.update` request. Missing records do not prove deletion. No output/edit flags are accepted; JSON is printed to stdout.

## Optional supplier quote evidence

A `catalog.material.update` mapping may include `quote`; omission or null asserts no supplier quote and remains compatible with older projects. A quote object requires exactly `supplier`, `reference`, `source`, `issuedAt`, `validUntil` and `conditions`. `validUntil` must be an explicit ISO 8601 instant or null for unknown. Issue/expiry instants require timezone information; expiry must follow issue and is exclusive. Conditions should retain quantity restrictions, freight/tax assumptions, lead time and exclusions from the source.

The quote belongs to this exact saved catalog cost and purchase-unit conversion and is retained in authored mapping history. Review the quote again when changing sources, costs or units; do not copy old quote evidence to a replacement record automatically. Removing the mapping retains the old cost and history, with manual price-source review required.

`catalog-review` returns `reviewedAt` and a nullable `quoteReview` per item. Recorded quote states are `withinRecordedPeriod`, `expired`, `expiryUnknown` and `notYetIssued`. The normal pricing review holds release for the latter three on included rows, while retaining draft costs. No quote is invented for a legacy/manual price basis. A period check is not supplier confirmation, document authentication or availability verification. Workbook mapping history retains the quote fields.
