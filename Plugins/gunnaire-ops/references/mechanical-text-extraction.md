# Mechanical text extraction candidates

`extract-text drawing.pdf` ingests a supplied drawing and prints a source-anchored candidate report. `extract-review project.json` reviews text already retained in a self-contained project archive. Both are read-only; use the wrapper's usual `--workspace` when selecting a checkout. The SDK exposes `extractMechanicalText` on `LoadSightServicing` and `LocalLoadSightService`.

The v1 matcher recognizes RTU/AHU/MAU/DOAS/FCU/VAV/CU/HP/EF/SF/RF/UH tag-shaped text, explicit CFM text and MBH/BTUH/BTU-per-hour text. It retains literal signs, punctuation, source SHA-256, page, whole text anchor, coordinate space, UTF-16 token range and recognition confidence. No unit conversion or equipment/value association is made. Comma-decimal numbers, tons, other units, unsupported tag forms and non-text symbols are not covered. Lack of matches does not prove absence of mechanical work.

Every occurrence needs source review. Repeated tag text in a plan, legend, detail or schedule is not another physical unit. Recognition below 0.75 is flagged for human verification; recognition confidence never establishes engineering confidence. Bounds identify the whole text anchor, not an independently localized symbol. The native Extraction workspace opens the original source page with that anchor highlighted.

## Local RFI handoff

After drawings have been imported into the project and exported as self-contained JSON, use `extract-review` to obtain current candidate IDs. The strict apply request is:

```json
{
  "operation": "text.rfi.create",
  "candidateID": "copy the exact current candidate ID",
  "question": "the specific clarification required",
  "impact": "known impact or what remains unknown",
  "author": "recorded reviewer"
}
```

Run with `apply project.json --request request.json --output new-project.json`. The engine regenerates candidates from the project's archive; a missing/changed ID rejects before writing. The RFI stores the candidate ID, exact source/anchor/text evidence, question, impact and recorded author. It remains Open, reopens QA and does not create quantities, equipment associations, costs or approvals. Existing output paths reject. No recipient is contacted. The native review form uses the same source validation and RFI engine and protects unsaved edits.

This is the text-occurrence stage of extraction. Complete schedule rows, physical-object deduplication, symbols/linework/geometry, lifecycle, manufacturer models, cross-sheet associations and full extracted-versus-calculated audit remain unfinished. See the checkout's `Reference/verification/Mechanical-text-extraction.md` and `BUILD_STATUS.md` for actual verification scope.
