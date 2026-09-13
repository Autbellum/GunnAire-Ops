# Schedule consistency screening — 2026-09-10

The shared extractor now returns `consistencyReview` keyed by unchanged row IDs. Native row review displays the same findings with expandable basis and interpreted operands. Source rows, drawing bytes, quantities and review state remain unchanged. The plugin's existing schedule commands expose this output.

## Rules

`ScheduleConsistencyReview.swift` implements `Schedule consistency screening v1`:

- MCA, MOP, weight, ESP and outdoor air distinguish an unmapped column from a mapped empty cell. Recorded numeric text without a supported unit remains unresolved. Applicability is not inferred from equipment tags.
- Sensible/total cooling and outdoor/total airflow compare only complete interpreted operands with compatible units. Findings explicitly require a common equipment/operating/rating or airstream/volume basis, which this method does not confirm. They are conditional source checks.
- Missing evidence, a partial-row flag or recognition confidence below 0.75 withholds comparison. This recognition threshold is a screening rule, not an engineering-confidence score.
- `needsReview` means a possible ordering conflict; `noConflict` means only that the converted values do not conflict in this ordering. Neither is approval. Relative tolerance of 1e-12 suppresses conversion floating-point noise only.
- A recognized zero capacity produces a review prompt. Unsupported, ambiguous or negative scalar capacities remain unresolved. No arbitrary equipment-capacity ceiling, efficiency range or replacement value is invented.

No check sizes electrical protection, selects equipment, confirms code compliance, derives physical quantities or approves a drawing association. Cross-field comparisons do not establish identical operating conditions. Broader manufacturer and system plausibility remain required.

## Evidence

281 shared tests pass, including seven new checks for missing versus unmapped fields, mixed-unit conflicts, zero versus missing, equality without approval, unresolved unit conventions, partial/low-confidence holds, deterministic nonmutating review and real original-PDF extraction. The synthetic PDF has three rows with outdoor/total states needsReview, unresolved and noConflict. Its SHA-256 is `292bff6b5ca20cd19299fd324f5b01943824ac68e5658cd1bd03b8a830d23254`.

The native iPad simulator test passes in 14.217 seconds. It opens the first row, expands its airflow conflict, verifies the same-total-airstream basis, and opens another row containing missing-field prompts. This is a controlled host using production views, not physical-device or complete engineering acceptance. The screenshot was inspected: conflict basis and both converted operands are readable. Production hashes match the native snapshot; Mac compilation passes.

Repository and installed real-engine plugin checks verify all three comparison states, missing coordination columns, unchanged source bytes and exact literal OA text. Installed plugin: `0.1.0+codex.20260910193656`. The prior generated build cache was preserved before rebuilding the changed extraction-result layout; no source data was cleared. CI adds the same verifier as its fifteenth run step. Hosted execution remains unverified.

## Reproduction

```sh
swift test --package-path LoadSight
python3 LoadSight/Tools/verify_schedule_consistency.py Plugins/gunnaire-ops /tmp/loadsight-consistency-check
```

Use a new output directory. `Tools/create_consistency_schedule_fixture.py` reproduces the controlled PDF/map. Native test source is `Tools/fixtures/ScheduleConsistencyUITests.swift`, with the existing `EquipmentScheduleApp.swift` host and the consistency fixture injected into an isolated source copy.

Generated evidence stays excluded under `output/verification/schedule-consistency/`: logs, production source hashes, native screenshot and repository/installed JSON. The full application goal still requires sourced unit-convention selection, automatic detection, confirmed equipment/geometry associations, full engineering methods, REST/cloud, authenticated Ops publication and broader device/export acceptance.
