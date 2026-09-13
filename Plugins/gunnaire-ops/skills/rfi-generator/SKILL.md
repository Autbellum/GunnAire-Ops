---
name: rfi-generator
description: Draft formal RFIs from missing dimensions, drawing conflicts, code conflicts, unreadable notes, equipment mismatches, load mismatches, or unclear scope when asked for RFI, clarification, question, conflict, or missing information.
---

Create one answerable question per RFI.

Include:
- RFI number.
- Date.
- Project.
- To.
- From.
- Spec reference.
- Sheet reference.
- Detail reference.
- Keynote reference.
- Description.
- Question.
- Suggested resolution.
- Cost impact.
- Schedule impact.
- Attachments.
- Required response date.

Use field-ready language.

Do not combine unrelated conflicts.

If cost/schedule impact is unknown, state Unknown and explain why.

If unresolved item affects price, mark Proposal Impact = Yes.

## Runtime and evidence

Read `../../references/implementation-status.md` before claiming an implemented capability. Use the local Swift package for implemented arithmetic. Preserve missing fields as unknown; do not substitute an unimplemented method with a completed result. Keep mechanical trade scope primary and plumbing/electrical interfaces as coordination unless the user explicitly includes those trades.

## Word export

For a saved RFI, use the native/shared exporter described in `../../references/rfi-word-export.md`. It exports recorded evidence and history without sending the document or altering RFI status. Do not claim unrecorded recipients, deadlines or approvals.
