# Envelope assembly calculation — v1

Implementation: `Sources/LoadSightCalc/EnvelopeAssemblies.swift` and `Sources/LoadSightKit/EnvelopeAssemblyRecords.swift`.

Primary reference: DOE Building America, *Measure Guideline: Incorporating Thick Layers of Exterior Rigid Insulation on Walls*, Appendix C, [Parallel Paths U-Factor and Effective R-Value](https://www1.eere.energy.gov/buildings/publications/pdfs/building_america/incorporating-thick-layers-exterior-insulation.pdf). The published appendix supports summing resistances along each path, then adding area-weighted conductances and taking the reciprocal for effective resistance. No material values from that guide are seeded into projects.

Numerical contract: Rpath = sum of positive finite layer R-values; Upath = 1/Rpath; Uassembly = sum(fraction × Upath); Reffective = 1/Uassembly. IP units: R h·ft²·°F/Btu; U Btuh/(ft²·°F). Positive fractions must sum to 1 within 1e-9, without normalization. Overflow/underflow and duplicate/empty path names are rejected. At most 100 paths and 100 layers per path.

Saved input records carry individual sources/classifications, assembly author/source/date, construction category, surface-film basis and assumptions. Missing numeric inputs do not become zero. No film or material values are supplied. RFI-REQUIRED values cannot be saved as calculated assemblies. Homogeneous layers require one path. The native editor clears preview results whenever inputs change. All portable validation paths recompute saved records; no cached U-value is authoritative. Raw existing records are retained during append, preserving extensions and provenance.

This is an independent-path steady-state model. It excludes lateral spreading, metal framing, ground coupling, moisture effects and transient/solar behavior. Construction category and source text record the user's basis, not independent verification of the actual drawing/material. No room load linkage, design temperatures, climate selection, equipment sizing, adopted-code or complete ACCA method is implied.

Verification: analytical two-path fixture (75% R20; 25% R5) yields U0.0875, Reffective80/7. Single-path and order invariance, invalid coverage/resistance, unsupported construction/method, required metadata, strict command fields, QA reopening, atomic failures, duplicate IDs, source-extension preservation and native package roundtrip are covered in EnvelopeAssemblyTests. The installed plugin fixture exercises assembly.create and envelope-review. Tests establish arithmetic/persistence behavior, not a physical assembly validation.
