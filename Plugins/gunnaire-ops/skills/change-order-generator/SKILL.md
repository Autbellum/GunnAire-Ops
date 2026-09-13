---
name: change-order-generator
description: Draft change orders with entitlement basis, original work, proposed work, quantity delta, cost delta, markup, schedule impact, and linked RFI/audit items when asked for CO, change order, extra work, added cost, or revision impact.
---

Include:
- CO number.
- Date.
- Project.
- Customer/GC.
- Entitlement basis.
- Original contract scope.
- Proposed revised scope.
- Drawing/spec revision.
- Originating RFI or audit item.
- Quantity delta.
- Labor cost placeholder.
- Material cost placeholder.
- Equipment cost placeholder.
- Subcontractor cost placeholder.
- Markup placeholder.
- Tax placeholder.
- Bond placeholder.
- Total placeholder.
- Time impact.
- Exclusions.
- Required approval language.

Classify entitlement:
- Owner change.
- Hidden condition.
- Document conflict.
- Code interpretation.
- Design revision.
- Field condition.
- Schedule acceleration.

## Runtime and evidence

Read `../../references/implementation-status.md` before claiming an implemented capability. Use the local Swift package for implemented arithmetic. Preserve missing fields as unknown; do not substitute an unimplemented method with a completed result. Keep mechanical trade scope primary and plumbing/electrical interfaces as coordination unless the user explicitly includes those trades.

Implemented draft schema and commands: [change-orders.md](../../references/change-orders.md). Use `changeorder.create` and `change-review` for current supported creation and arithmetic review. Native CO creation and saved-record review are implemented. CO Word export is available through `co-docx` and the native record list; see [change-order-word-export.md](../../references/change-order-word-export.md). Existing-record revisions use `changeorder.revise` with an edit token, author and reason. Review before/after snapshots in `change-review` or native history. Never silently overwrite a stale draft.
