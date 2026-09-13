# Mapped equipment schedule rows

This local reader extracts literal row candidates from a source-bound table body and explicit column map. It does not automatically choose a table, interpret a header, approve an equipment relationship or count physical equipment.

## Commands

```sh
python3 scripts/loadsight.py schedule-text /absolute/drawing.pdf --schedule /absolute/column-map.json
python3 scripts/loadsight.py schedule-review /absolute/project.json --schedule /absolute/column-map.json
```

The first command imports a local drawing; the second uses a self-contained project JSON. Both print review JSON and reject output/edit flags. Sources and projects remain unchanged. The native Schedules workspace imports the same map and previews row cells on the original source page. Host apps can call `LoadSightServicing.extractEquipmentSchedules` with progress/cancellation.

## Column-map contract

The root object has exactly `schemaVersion: 1` and `regions` (1–100 entries). Each region requires:

- `sourceID`: exact original-file SHA-256 from drawing intake.
- `pageID`: exact imported page identity, normally SHA-256 followed by `:1`, `:2`, etc.
- `bodyBounds`: `x`, `y`, `width`, `height`, excluding table titles, headers and unrelated notes.
- `columns`: unique fields with nonoverlapping `minX`/`maxX`, exact `headerText`, and optional literal `unitText`. Omitting units means not recorded.
- `textMode`: `nativePDFWords` for fresh PDF text-range selections, or `recordedAnchors` for the existing archive text/OCR. The latter never guesses how to split an anchor across columns.
- `recordedBy` and `mappingBasis`: who mapped the columns and the drawing/header evidence used. These are local declarations, not authentication.

Use unrotated page coordinates: PDF points with bottom-left origin, or oriented image pixels for recorded image anchors. The body must fit the page; columns must fit the body; regions cannot overlap. A tag column and at least one value column are required. Unknown keys, missing required fields and unsupported field names reject the request. No default table positions, units or equipment ratings are supplied.

Supported fields: `tag`, `equipmentType`, `manufacturer`, `model`, `quantity`, `coolingTotal`, `coolingSensible`, `heatingCapacity`, `furnaceInput`, `furnaceOutput`, `airflow`, `outdoorAir`, `externalStaticPressure`, `enteringWaterTemperature`, `leavingWaterTemperature`, `waterFlow`, `voltage`, `phase`, `minimumCircuitAmpacity`, `maximumOvercurrentProtection`, `weight`, `dimensions`, `sound`, `accessories`, `notes`. Electrical fields are HVAC coordination only.

A complete controlled example lives at `LoadSight/Tests/LoadSightKitTests/Fixtures/EquipmentScheduleMapping.json` beside its synthetic PDF. Do not reuse that geometry or fingerprint for customer drawings.

## Review output and limits

Rows retain original source/page identities, mapping evidence, row bounds, cell text and recognition rectangles. Missing mapped cells omit `text` and retain an empty evidence array; this means unknown, not zero. Unmapped fields are also unknown. Numeric text (including zero and thousands separators) remains literal; units retain their exact transcription. A separate numericReview array now supplies supported scalar conversions without altering row IDs or cell evidence.

Text crossing boundaries or occupying gaps is returned in `unassigned`. Affected rows warn that their text may be partial. Repeated schedule tags remain separate rows and trigger reconciliation warnings. Exact case-insensitive tag matches elsewhere are possible links only; unmatched tag occurrences do not establish missing equipment. Neither row count nor the schedule quantity column updates takeoff.

Row identity binds evidence and the column map. `EquipmentScheduleRow.validate(in:)` recomputes current evidence before downstream use and rejects changes or forged results. No accepted-equipment or approved-association record is created.

Automatic table/header detection, merged-cell/continuation reconciliation, broader unit conventions, plausibility review, manufacturer selection, persisted approval and confirmed plan/schedule associations remain unfinished. Native PDF mode reads no raster text; low-confidence and unread content still need source review.

## Native authoring and durable maps

The Schedules workspace now creates maps without an external JSON authoring step. Choose a source/page, set the body and column edges using two-point drawing selection or precise bounds, transcribe headers/units and provide a name, mapper and change reason. Multiple table regions are supported. Changing a region's source/page clears old geometry and header evidence. Save commits the map to the project and reopens QA. Imported/current maps can also be saved explicitly through Current map → Save as a map.

Saved maps survive `.loadsight` packages, self-contained JSON and project recovery. Edit/remove operations preserve full before/after snapshots with author, reason and date. Current maps must match that history; source references and geometry are validated during native/portable project loading. The history is a local consistency record, not authenticated approval.

```sh
python3 scripts/loadsight.py schedule-map-review /absolute/project.json
python3 scripts/loadsight.py schedule-saved /absolute/project.json --map-id SAVED-MAP-UUID
```

`schedule-map-review` returns raw saved maps/history and the current `editFingerprint`. Before the first map exists, maps/history may be null. `schedule-saved` reads the selected map through the same extraction engine. Both commands are read-only.

Use the standard new-output-only `apply` command for changes. Creation/revision fields are:

```json
{
  "operation": "schedule.map.save",
  "id": null,
  "name": "Reviewed column mapping",
  "request": {"schemaVersion": 1, "regions": []},
  "expectedFingerprint": "copy the current schedule-map-review fingerprint",
  "author": "Recorded mapper",
  "reason": "Source header and body mapping basis"
}
```

Replace the empty example `regions` with the complete valid mapping described above; the empty array is intentionally rejected. Use `id: null` only for creation. Revision requires the existing UUID and complete replacement map request. Omitted/invalid IDs, unknown request keys, invalid source geometry, missing author/reason, stale fingerprints and unchanged revisions reject without writing output.

Removal requires exactly `operation: "schedule.map.remove"`, `id`, `expectedFingerprint`, `author`, and `reason`. It removes the active map while retaining its complete history. No quantities, costs, source originals or external records are changed. The native history view remains available after removal.

This authoring/storage workflow does not perform automatic table/header detection, equipment plausibility checks, equipment approval or confirmed plan/schedule association. Saving a map is not approving its extracted rows.

## Scalar numeric review

`schedule-text`, `schedule-review` and `schedule-saved` include `numericReview`, joined to literal rows by `rowID`. Each mapped scalar field reports interpreted, missing, unresolved or notNumeric; only interpreted results contain a numeric value, canonical unit, factor and offset. Values remain unreviewed source interpretations, never approved engineering inputs or physical counts. Original text, unit transcription and evidence stay unchanged.

Supported explicit units include CFM, L/s, m³/s, m³/h and US GPM to m³/s; W/kW/MW, Btu_IT/h and tonR to W; Pa/kPa; F/C/K to °C; lb/kg; V/A; explicitly labeled each/count and phase. SI symbol case matters. Count and phase use integer validation. Conversion factors follow NIST SP 811; see the source workspace's `Reference/engineering/Schedule-numeric-units.md` for exact aliases and limitations.

Missing units are not inferred. Bare GPM, MBH and Btu/h remain unresolved without the source-defined conventions below. Water-column pressure, ranges, embedded units, footnotes, OCR corrections and mixed voltage values remain unresolved. Clarify the actual source convention before revising a map; never relabel a source merely to force conversion. Sound remains literal. Dimensions retain literal text and now have a separate ordered-length interpretation as documented below. A converted zero stays zero; unknown stays absent. Decimal parsing uses a point and optional strict three-digit comma grouping, which still requires locale/source review.

## Conditional consistency screening

Schedule commands also return `consistencyReview`, keyed by unchanged row ID. Native review displays the same checks and their evidence. MCA, MOP, weight, ESP and outdoor-air fields distinguish unmapped columns, empty cells, unresolved text/units and recorded values. Applicability is never assumed from a tag or absence.

Sensible/total cooling and outdoor/total airflow comparisons use converted compatible units and state the required common equipment/operating/rating basis. Results are needsReview, noConflict or unresolved; noConflict is not approval. Missing data, partial rows or recognition confidence below 0.75 withhold comparison. Zero capacities receive review prompts, never invented replacements. This does not size electrical protection, choose equipment or establish code compliance. Full manufacturer/operating-condition plausibility and confirmed associations remain unfinished.

## Sourced schedule RFI drafts

`schedule.rfi.create` creates a local unanswered RFI and linked JSON evidence attachment atomically. It requires `operation`, `author`, the full strict schedule `request`, current `rowID`, a `findingID` from consistencyReview, `question` and `impact`. Use the normal `apply project.json --request edit.json --output new-project.json` command. No recipient is contacted.

The engine re-extracts and validates the row against current originals and rejects stale row IDs, unavailable sources and unknown findings. The RFI source retains row/source IDs, page, bounds, mapping basis, literal affected cells, finding basis and evidence SHA-256. The linked snapshot retains the complete row and selected recomputed finding. Question, impact and author must be supplied; the system does not invent answers or approval. Failure leaves the original project unchanged. Native finding disclosures provide the same draft action with document/drawing-session protection.

Evidence is a historical local snapshot. Its hash verifies retained bytes, not authenticated author identity or engineering approval. Later source or map changes do not rewrite an existing RFI; review its history and create or edit a question explicitly. Package and portable JSON retain the attachment; DOCX references attachments without embedding their bytes.

## Ordered dimension interpretation

Schedule commands include `dimensionReview`, joined to unchanged source rows by rowID. It reports interpreted, missing or unresolved dimensions. Supported sequences have two or three positive decimal components separated by x, X or × and an explicit common header unit: in/inch/inches/double-quote, ft/foot/feet/apostrophe, mm, cm or m. Components convert to metres in their original order. Axis names, orientation and clearance versus equipment size remain unconfirmed; no area, volume or physical quantity is derived.

Missing units, single dimensions, labeled axes, fractions, mixed inline units, ranges, footnotes, nonpositive values, excess components and ambiguous separators remain unresolved with no partial values returned. Never change the literal source to force conversion. Native cell review shows the ordered values and the conversion basis beside the original text. NIST SP 811 length relationships supply the inch/foot/SI factors.

## Source-defined unit conventions

A column may optionally include `unitDefinition` with exactly `convention` and `source`. Keep `unitText` as the literal drawing/header abbreviation. `source` must name the actual drawing legend, specification or other evidence defining the convention (nonblank, at most 4,096 characters). A general conversion table alone does not establish a drawing's convention. Author names and citations are recorded evidence, not authenticated verification.

Example for a source that explicitly defines MBH as thousands of International Table Btu per hour:

```json
"unitText": "MBH",
"unitDefinition": {
  "convention": "thousandBtuInternationalTablePerHour",
  "source": "Drawing M1 legend: MBH = 1000 BTU_IT/H; BTU denotes International Table units."
}
```

The fragment belongs inside a complete mapped column. Supported definitions and matching literal aliases (case-insensitive, ignoring whitespace):

| Convention | Matching literal units | Permitted fields |
| --- | --- | --- |
| `btuInternationalTablePerHour` | Btu/h, Btu/hr, Btuh | Cooling/heating/furnace capacities |
| `thousandBtuInternationalTablePerHour` | MBH, MBtu/h, MBtu/hr, kBtu/h, kBtu/hr | Same capacities |
| `refrigerationTon` | ton, tons, TR | Same capacities |
| `usLiquidGallonsPerMinute` | GPM, gal/min | Airflow, outdoor air, water flow |
| `imperialGallonsPerMinute` | GPM, gal/min | Same flow fields |

Missing definitions leave these ambiguous units unresolved. Definitions cannot override explicit/conflicting units or be applied to incompatible fields. Unknown keys/conventions and blank evidence reject the map. Explicit `kBtu_IT/h` and `ImperialGPM` are also recognized without an abbreviation definition; source units remain literal.

The native map editor exposes the convention and source citation, and clears them when the field/unit or drawing source changes. Saved maps/history, package/JSON storage, extracted cells and RFI row snapshots retain definitions. Changing the definition or citation changes row identity, so downstream requests must use fresh extraction IDs. No equipment count, quantity, cost or engineering approval is inferred. Water-column pressure still requires an unimplemented reference-condition convention.

## Automatic discovery and editable drafts

`schedule-discover drawing.pdf` searches imported text without a supplied map. `schedule-discover-review project.json` searches the self-contained project's drawings. Both return `method`, `pageCount`, `candidates`, `warnings` and `limitations`, and reject mutation/output/map flags. No map or takeoff is saved by discovery.

Each candidate retains its source/page, full recognized header evidence, proposed field meanings and literal units, aligned tag evidence, an unreviewed `proposedRegion`, warnings and a deterministic source-bound ID. Unknown and duplicate field headers stay visible but are omitted from mapped columns, leaving gaps. Header words are grouped by horizontal spacing and vertical overlap; column edges and body limits are text-layout heuristics. Recognition confidence is not engineering confidence.

The supported first pass finds horizontal single-line headers with a leftmost TAG, EQUIPMENT TAG, MARK or EQUIPMENT MARK cell and at least one other recognized field. It requires aligned tag rows, searches all imported pages regardless of trade filename, separates repeated/adjacent supported headers, and reports rotated/empty/unsupported layouts for manual review. It can miss stacked/merged headers, multiline continuations, footer data, unfamiliar labels and unusable OCR anchors. No-result output does not prove absence of schedules. Repeated tag rows never establish physical quantities.

To inspect a proposal through the CLI, put its `proposedRegion` in a schemaVersion-1 `regions` array and use `schedule-text` or `schedule-review`. Treat its automatically proposed author/basis as unreviewed. Inspect and correct the source body, every field/column and literal unit, then supply an actual author/reason through the existing map-save workflow. Ambiguous MBH/GPM/etc. receive no invented convention.

Native Schedules provides **Find equipment schedules**, candidate source overlays and **Review map draft**. Candidate preparation runs through the asynchronous SDK and revalidates the complete discovery candidate against current evidence. Replacing the document or drawings prevents applying the old review. The existing map editor requires authored saving and retains history; discovery itself leaves project state unchanged.

SDK consumers can call `discoverEquipmentSchedules` and `prepareDiscoveredSchedule` on `LoadSightServicing`. Cancellation withholds final results, including cancellation at the last page. The concrete engine is `EquipmentScheduleDiscoverer`; no hosted AI/model or remote provider is invoked. Full semantic schedule extraction and confirmed equipment/plan associations remain unfinished.
