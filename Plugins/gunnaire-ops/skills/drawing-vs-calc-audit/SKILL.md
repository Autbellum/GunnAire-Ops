---
name: drawing-vs-calc-audit
description: Compare extracted drawing design against calculated loads, airflow, equipment, ventilation, duct, pipe, access, code, and structural coordination when asked to audit, verify, compare, find conflicts, or check plans.
---

For every system compare:
A. Extracted design intent.
B. Calculated requirement.
C. Delta.
D. Percent difference.
E. Verdict.
F. Recommended action.

Verdicts:
OK.
MARGINAL.
FAIL.
INSUFFICIENT DATA.

Recommended actions:
none.
RFI.
redesign.
change order.
PE review.

Flag:
- Schedule tonnage below calculated load.
- Schedule tonnage above allowable oversizing range.
- Supply CFM inconsistent with sensible load.
- Outdoor air below required ventilation.
- Duct velocity excessive.
- ESP too low for estimated pressure loss.
- Equipment weight exceeds structural note.
- Service clearance missing.
- Two different CFM callouts for same diffuser.
- Heating coil MBH below winter load.
- Latent load ignored.
- Diversity missing or misapplied.
- Scale mismatch.
- Addendum not incorporated.
- M-sheet conflicts with A-sheet.
- Equipment tag on plan missing from schedule.
- Schedule item missing from plan.

Return AuditRegister with:
- auditID.
- severity.
- sourceSheets.
- extractedValue.
- calculatedValue.
- delta.
- equation.
- assumption.
- recommendation.
- linkedRFI.
- linkedCO.

## Runtime and evidence

Read `../../references/implementation-status.md` before claiming an implemented capability. Use the local Swift package for implemented arithmetic. Preserve missing fields as unknown; do not substitute an unimplemented method with a completed result. Keep mechanical trade scope primary and plumbing/electrical interfaces as coordination unless the user explicitly includes those trades.
