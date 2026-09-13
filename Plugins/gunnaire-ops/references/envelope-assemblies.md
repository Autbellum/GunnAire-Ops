# Envelope assembly commands

Use `scripts/loadsight.py apply input.json --request request.json --output new-project.json` to create an assembly. Use `scripts/loadsight.py envelope-review new-project.json` to read records and recomputed results. Existing files are never replaced. These commands run the local shared Swift workspace.

`assembly.create` requires operation, author, name, source, construction, filmBasis and paths. Construction is exactly `Wood framed` or `Homogeneous layers`; homogeneous requires one path. Each path requires exactly name, fraction, fractionSource, fractionClassification, layers. Each layer requires exactly name, resistance, source, classification. Unknown command/nested fields fail. Required sources and names cannot be blank.

Fraction is a numeric ratio (0–1), not a percentage. Positive path fractions must sum to 1 within 1e-9 and are never normalized. Resistance is positive, finite IP R in h·ft²·°F/Btu. Each path contains the complete stack, including common layers and applicable films. filmBasis records included films or the reason for omission; the engine adds none. Path names and layer names within a path must be distinct. Classifications are EXTRACTED, USER-PROVIDED, CODE-DEFAULT, ENGINEERING-ASSUMPTION, or RFI-REQUIRED; the last cannot produce a saved calculation until resolved. A classification alone is not evidence; a source is required for every numeric input.

Synthetic schema example, **not a material recommendation**:

```json
{"operation":"assembly.create","author":"Fixture","name":"Uniform example","source":"Analytical fixture","construction":"Homogeneous layers","filmBasis":"Fictional total resistance; no default films","paths":[{"name":"Full area","fraction":1,"fractionSource":"Fixture full area","fractionClassification":"ENGINEERING-ASSUMPTION","layers":[{"name":"Fictional stack","resistance":5,"source":"Fixture only","classification":"ENGINEERING-ASSUMPTION"}]}]}
```

Uassembly = sum of each path's fraction / sum of its layer resistances. Effective R = 1/Uassembly. Never average path R-values as assembly R. Results include path and assembly equations, substitutions, units and method assumptions. Saving appends a record with identity/date/author and reopens QA. Existing records and unknown provenance fields are preserved. Imports recompute rather than trusting cached outputs; malformed records fail portable/native validation.

This method assumes steady-state independent paths with common boundary temperatures. It does not model metal framing, lateral spreading, slab/ground coupling, transient solar loads or thermal-bridge corrections. These assemblies link to the partial room opaque-transmission worksheet; see room-transmission.md. No material library, measured U-factor import, complete room load or code/ACCA completion is claimed. A wood-framed label does not independently verify that a particular assembly satisfies the method assumptions.
