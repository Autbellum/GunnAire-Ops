# Change order Word export

Export one saved change order as an editable draft review copy:

```sh
python3 scripts/loadsight.py co-docx /absolute/project.json --co-id CO-RECORD-ID --output /absolute/new-change-order.docx
```

Use the stable record ID returned by `changeorder.create` or `change-review`, not the display CO number. The input is self-contained project JSON; export native packages to JSON first. The native Change orders list also provides Export Word copy for each record.

The shared native engine includes original/proposed scope, supplied entitlement classification and source, drawing/specification revision, originating RFI/audit references, customer/date/author, time impact, exclusions and approval-language placeholders. Separate quantity and cost tables retain original/proposed values, signed deltas, sources and units. Markup basis, tax/bond deltas, cost summary, missing-field list, record ID, export timestamp and project fingerprint accompany the draft.

Unknown amounts are shown as Unknown and incomplete totals are withheld. Known zero stays zero; negative costs remain credits. Costs are USD, displayed to two decimal places; calculations retain unrounded intermediates. The recorded markup basis controls treatment of credits. A calculated total does not imply complete scope or approval.

Linked RFI subject/status/source are labeled current metadata from the project at export time, not a frozen snapshot from CO creation. Removed RFI identities remain listed with a missing-record note. No referenced file contents are embedded. No macros, external relationships or remote data are added.

Export never changes the project, sends the change, records approval or authorizes work. Word edits do not update project records. The wrapper rejects existing output paths and symlinks. Missing IDs, invalid project records or text illegal in XML fail without replacing output. Revised records include latest revision metadata and a changed-field appendix with before/after sources and totals. Complete snapshots remain in project history. Authenticated approval remains pending.
