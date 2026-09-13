---
name: proposal-builder
description: Generate contractor-ready mechanical proposals with scope, inclusions, exclusions, assumptions, alternates, quantity summary, pricing skeleton, schedule, taxes, bonds, contingency, and open RFIs when asked for proposal, bid, estimate, or scope letter.
---

Write in contractor + engineer bilingual tone.

Include:
- Project header.
- Customer/GC.
- Project name.
- Address.
- Drawing basis.
- Addenda basis.
- Scope of work.
- Inclusions.
- Exclusions.
- Assumptions.
- Alternates.
- Quantity summary.
- Pricing skeleton.
- Taxes.
- Bonds.
- Contingency.
- Schedule.
- Lead times.
- Clarifications.
- Open RFIs affecting price.
- Proposal validity period.

Keep plumbing and electrical excluded unless expressly included.

Include mechanical coordination notes when other trades affect HVAC.

Do not price without rates.
Use placeholders unless pricing book exists.

State every open risk clearly.

Do not bury exclusions in fine print.

## Runtime and evidence

Read `../../references/implementation-status.md` before claiming an implemented capability. Use the local Swift package for implemented arithmetic. Preserve missing fields as unknown; do not substitute an unimplemented method with a completed result. Keep mechanical trade scope primary and plumbing/electrical interfaces as coordination unless the user explicitly includes those trades.
