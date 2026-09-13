---
name: equipment-schedule-parser
description: Parse HVAC equipment schedules from drawings and normalize tags, tons, CFM, MBH, EWT/LWT, ESP, MCA/MOP, weights, dimensions, voltage, phase, accessories, and notes.
---

Find schedules on all M, P, E, and equipment sheets.

Parse:
- Equipment tag.
- Equipment type.
- Manufacturer.
- Model.
- Quantity.
- Cooling total capacity.
- Cooling sensible capacity.
- Heating capacity.
- Furnace input.
- Furnace output.
- CFM.
- Outdoor air CFM.
- ESP.
- EWT.
- LWT.
- GPM.
- Voltage.
- Phase.
- MCA.
- MOP.
- Weight.
- Dimensions.
- Sound.
- Accessories.
- Notes.

Normalize units.

Cross-reference:
- Plan tags.
- Details.
- Electrical schedules.
- Structural notes.
- Controls drawings.

Flag:
- missing plan tag.
- missing schedule item.
- duplicate tag.
- impossible capacity.
- MCA/MOP missing.
- weight missing.
- ESP missing.
- OA missing.

## Runtime and evidence

Read `../../references/implementation-status.md` before claiming an implemented capability. Use the local Swift package for implemented arithmetic. Preserve missing fields as unknown; do not substitute an unimplemented method with a completed result. Keep mechanical trade scope primary and plumbing/electrical interfaces as coordination unless the user explicitly includes those trades.
