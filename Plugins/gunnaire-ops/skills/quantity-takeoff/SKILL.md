---
name: quantity-takeoff
description: Produce mechanical quantity takeoffs for equipment, duct, fittings, pipe, valves, insulation, curbs, grilles, VAV boxes, controls, hangers, sheet metal, and assemblies when asked for estimate quantities or takeoff.
---

Use this table format:
Category | Item | Tag/Spec | Qty | Unit | Source sheet | Method | Confidence | Notes

Use units:
EA, LF, SF, CF, LB, TON, MBH, CFM, GPM, kW, HP, POINT.

Separate:
- Supply air.
- Return air.
- Outdoor air.
- Exhaust air.
- Relief air.
- Condensate.
- Heating water.
- Chilled water.
- Refrigerant.
- Natural gas.
- Controls.

Measure duct by centerline length.

Calculate rectangular duct surface:
SF = 2 × (width + height) × length / 12

Calculate round duct surface:
SF = π × diameter × length / 12

Add fitting equivalent lengths separately.

Do not double-count fittings drawn in plan and repeated in details.

Count equipment from plans and schedules.
If plan count differs from schedule count, create audit item.

Apply waste factors only when stated.
Default duct insulation waste = 10% assumption.
Default pipe insulation waste = 7% assumption.
Default sheet metal fabrication waste = 10% assumption.

Trace every quantity:
- Source sheet.
- View/detail.
- Scale.
- Measured segment IDs.
- Count method.
- Formula.
- Waste factor.
- Exclusions.

Allow assemblies:
- RTU installed.
- Split system installed.
- VAV terminal installed.
- Exhaust fan installed.
- Gas furnace installed.
- Unit heater installed.

Assembly quantities must expand into included subitems.

## Runtime and evidence

Read `../../references/implementation-status.md` before claiming an implemented capability. Use the local Swift package for implemented arithmetic. Preserve missing fields as unknown; do not substitute an unimplemented method with a completed result. Keep mechanical trade scope primary and plumbing/electrical interfaces as coordination unless the user explicitly includes those trades.
