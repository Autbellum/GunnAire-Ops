# RFI Word export

Use the saved RFI identity from project JSON. The shared engine validates the portable project before creating a macro-free DOCX review copy. The native RFI list also offers Export Word copy.

`python3 scripts/loadsight.py rfi-docx /absolute/project.json --rfi-id RFI-ID --output /absolute/new.docx`

The output includes the exact recorded question, drawing/specification reference, combined scope/cost/schedule impact, current answer with source/respondent/date, affected item quantities and source, linked attachment names and SHA256, and before/after recorded RFI history. Unknown quantities remain Unknown. Missing textual fields are Not recorded. The native RFI form and rfi.create/rfi.edit communication payload support to/from/date/requiredResponseDate/suggestedResolution fields. See project-edits.md for exact replacement semantics and date validation. Legacy fields remain readable. Current and recorded before/after values are exported. Export neither infers deadlines or recipients nor turns recorded-by into a sender. Separate sheet/detail/keynote interpretation and contract authorization are not supplied by this exporter.

The Word copy is editable, but edits do not update LoadSight. Attachment contents are referenced rather than embedded. Local export does not send a message, change RFI lifecycle or reopen QA. Existing destination files and symlinks are rejected. The original JSON is preserved. No final price, signature or approval is inferred. Change order authoring/export remains a separate unfinished feature.
