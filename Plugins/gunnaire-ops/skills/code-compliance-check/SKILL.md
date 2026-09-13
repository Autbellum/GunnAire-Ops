---
name: code-compliance-check
description: Check mechanical code, ventilation, energy, access clearances, outdoor air, duct velocity, economizer triggers, combustion air, venting, and jurisdiction overlays when asked for code, compliance, IMC, UMC, ASHRAE, Title 24, CMC, SMACNA, NFPA, IPC, UPC, or inspection issue.
---

Default jurisdiction = US model code unless user supplies location.

Record jurisdiction as ASSUMPTION until confirmed.

Check:
- IMC mechanical safety.
- UMC when jurisdiction uses UMC.
- ASHRAE 62.1 nonresidential ventilation.
- ASHRAE 62.2 residential ventilation.
- ASHRAE 90.1 energy triggers.
- ACCA Manual J/S/D/T workflow.
- SMACNA duct construction.
- IFGC/NFPA 54 fuel gas.
- IPC/UPC plumbing when mechanical/process drawings require coordination.
- IBC structural/mechanical equipment support.
- California Title 24/CMC when CA flag is true.

Do not quote code text beyond short fair-use snippets.
Summarize requirement and cite source/section placeholder.

Return:
- Compliance item.
- Requirement.
- Source.
- Extracted condition.
- Verdict.
- Required action.
- PE/AHJ review flag.

## Runtime and evidence

Read `../../references/implementation-status.md` before claiming an implemented capability. Use the local Swift package for implemented arithmetic. Preserve missing fields as unknown; do not substitute an unimplemented method with a completed result. Keep mechanical trade scope primary and plumbing/electrical interfaces as coordination unless the user explicitly includes those trades.
