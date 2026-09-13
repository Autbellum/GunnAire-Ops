# Reusable mixing outputs and source dependency graph

A saved mixed-air process can now produce a reusable condition for another mixer or cooling coil. The output state and full-stream actual CFM come directly from the evaluated process, without manual rounding or re-entry. This implements a dependency graph for recorded air states and processes, not a complete HVAC network/pressure solver.

## Native workflow and SDK

In Calculations → Air processes, expand a saved mixing process and choose **Save output as a reusable condition**. Supply name, recorder and downstream use/source basis. The new condition appears in selectors labeled calculated. Choosing it offers a separate **Use saved mixed-stream airflow** action, which copies the full-stream actual CFM and records the source-process basis. A branch flow must be supplied separately when it is not the full stream.

SDK: `saveMixedAirOutput(processID:name:author:source:)` returns the new condition ID. Only a saved mixing process is eligible. Numeric overrides are not accepted. Normal condition/process creation APIs continue to work, including legacy RH input records.

The output is classified as an engineering assumption/model state, explicitly distinguished from an independent measurement. Original process records remain intact. Saving a derived condition appends it and reopens project QA. Duplicate derivations are permitted as separate named uses; they do not silently replace previous records.

## Derivation metadata

The new condition retains `derivation` with:

- method: `Mixed-air output snapshot v1`.
- processID: source mixing identity.
- sourceFingerprint: SHA-256 binding the source process and every upstream record.
- actualCFM: computed full mixed-stream outlet volume flow at the derived state.

The condition retains its computed dry bulb, RH, pressure, source, author, timestamp, classifications and assumptions. `air-review` exposes the derivation record and a trace pointing to the source mixing process instead of labeling the computed RH as a supplied humidity measurement.

## Evaluation and invalidation

The evaluator decodes all air conditions/processes, rejects duplicate identities and missing dependencies, and evaluates nodes in topological order. It uses a queue and dependency counts rather than recursive traversal. A remaining dependency cycle fails explicitly, including a condition that depends on its own downstream mixer.

Condition nodes depend on their source process only when derived. Process nodes depend on their two input conditions. Identical first/second condition references count as one graph dependency. Each node fingerprint hashes a sorted-key JSON object containing its complete raw record and a sorted list of upstream node IDs/fingerprints. Unknown provenance fields therefore participate in validation and are preserved when appending new condition/process records.

Before a derived node is used, its source fingerprint must match the evaluated process fingerprint. Its dry bulb/RH/pressure and outlet actual CFM must agree with the recomputed mixing output. Value tolerances: 1e−8 °C and Pa, 1e−10 RH fraction, and max(1e−8 CFM, 1e−10 times outlet CFM) for flow. Its modeled-condition classifications must remain intact. These are numeric consistency tolerances, not field measurement tolerances.

Changing upstream evidence—even source text with identical numeric values—invalidates downstream derived snapshots. Adding unrelated nodes or reopening QA does not affect their fingerprints. Missing references, changed derived values, unsupported derivation methods and cycles are rejected by shared native/portable validation. This is integrity and recorded provenance, not authenticated author identity.

The current workflow appends new versions rather than editing/refreshing a graph in place. Automatic revision propagation, stale-record repair/recovery UI, archival of replaced derived chains, network-wide branch-flow balance and pressure solving remain unfinished. A stale raw project is rejected instead of being silently recalculated into a new approved record.

## Plugin workflow

`aircondition.derive` accepts only operation, author, name, source and processID. Its receipt returns the derived condition identity for downstream firstConditionID/secondConditionID. Read the condition's derivation.actualCFM to use the full stream when appropriate. `air-review` validates the graph before returning conditions, process results and traces. No author approval, equipment choice, bid release or Ops publication is implied.

## Verification

88 XCTest tests pass. Six new tests cover:

1. Structured derivation identity and rejection of numeric overrides.
2. Mixing output feeding a coil at the full computed flow, dry-air mass continuity, native package round trip and fingerprint retention.
3. Upstream source-evidence changes invalidating a derived condition without numeric changes.
4. Cycle rejection and changed derived-temperature rejection.
5. Missing-source and invalid-save rejection without partial mutation.
6. Eight linked mixing stages, raw unknown-provenance retention during subsequent append, and shared validation.

Mac and iOS builds pass. The installed plugin completed a 16-operation temporary-fixture workflow, including derivation and the downstream coil using exact inherited airflow; mass continuity, prior ADP/humidity traces, source preservation, no overwrite and draft status checks pass. Native interaction was attempted again but computer use returned `Sky Computer Use native pipe closed before response`; UI/touch acceptance remains unverified.

Full room/zone/system loads, manufacturer capacity selection, complete distribution/network design, physical/field validation and the broader application release requirements remain active.
