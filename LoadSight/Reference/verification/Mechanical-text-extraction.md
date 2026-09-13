# Mechanical text extraction — 2026-09-10

## Implemented boundary

`MechanicalTextExtractor` produces review candidates from imported drawing text. The v1 grammar covers selected equipment prefixes (RTU, AHU, MAU, DOAS, FCU, VAV, CU, HP, EF, SF, RF, UH), CFM and MBH/BTUH/BTU per hour. This is an implementation grammar, not a universal drawing standard. Literal text, signs and comma grouping are preserved without numeric conversion or automatic equipment assignment.

Each candidate retains source SHA-256, filename, page, full recognition anchor, coordinate space, UTF-16 range, method and recognition confidence. The displayed rectangle covers the whole anchor, not the individual symbol or substring. Stable candidate identity binds this evidence. Recognition below 0.75 requests an additional check; every candidate still requires source review regardless of confidence.

The SDK exposes asynchronous extraction. Native Extraction scans imported drawings, previews their original page and can create an Open local RFI. The CLI/plugin exposes `extract-text`, `extract-review` and strict `text.rfi.create` edits. RFI handoff validates current source evidence, retains the candidate reference and reopens QA without changing takeoff quantities or costs. Plugin edits require a new output path. No external RFI is sent.

## Recorded verification

Five extraction tests cover real PDF anchors, repeated text, UTF-16 offsets, signed/grouped values, low confidence, unsupported text, forged/stale evidence and atomic RFI handoff. The combined snapshot passes 241 XCTest tests. Nine wrapper boundary tests pass at repository handoff.

Both repository and installed plugin end-to-end checks found four occurrences in the controlled three-page PDF, created an Open RFI, preserved input bytes and takeoff items, and rejected stale candidate IDs and overwrite. Original PDF SHA-256: `267146be9bcd99fc5dad357f7f0061ec28e1dc115efbecc69d11dac391bf9fc1`. Installed plugin `0.1.0+codex.20260910184814` matches personal source for its wrapper, extraction/status references and manifest.

The synthetic iPad simulator test `MechanicalExtractionUITests.testSourcePreviewAndRFIDraft` passed in 29.047 seconds on iOS 26.2. It scanned the controlled PDF, opened source page 1, saved a question and found it in RFIs. Inspected screenshots show the rectangle around the original `RTU-1 1200 CFM` anchor and the completed RFI fields. The saved-status text is partly below the visible form while the keyboard is open; test assertions establish save and register presence. No flawless-layout or physical-device claim is made.

Mac and iPad builds passed for the recorded source. An earlier incremental test build crashed after candidate struct layout changed. Stale dependent build objects are the likely cause, not a proven compiler defect: a clean scratch build, forced dependent rebuild and subsequent standard `swift test --package-path LoadSight` all passed 241 tests.

Local evidence is under `output/verification/mechanical-text-extraction/`: source manifest, clean/incremental/final logs, native test JSON and screenshots, repository/installed summaries, and handoff validation. Generated evidence is excluded from Git. Reproduction harnesses and tests are retained under `Tools/fixtures`, `Tools/verify_text_extraction.py`, and `Tests/LoadSightKitTests/MechanicalTextExtractionTests.swift`.

## Snapshot and remaining work

Eight existing production files changed concurrently after the native source snapshot; `handoff-validation.json` records exact paths and `REPOSITORY_READY.md` lists them. Native evidence applies to the captured implementation. Preserve later edits and rerun CI on the reviewed commit.

This stage does not extract full schedule rows, reconcile repeated views, identify physical equipment, associate ratings with equipment, infer quantities, analyze geometry, or perform complete engineering calculations. Absence of a matching occurrence is not evidence that work is absent. Human approval is not persisted as a separate candidate-review register. Full application scope remains active in `BUILD_STATUS.md`.
