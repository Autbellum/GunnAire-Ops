---
name: blueprint-ingest
description: Ingest construction drawings, PDFs, scans, photos, CAD exports, mixed scales, title blocks, schedules, notes, tags, rooms, ducts, pipes, and mechanical symbols when asked to read drawings, plans, blueprints, takeoff, or compare sheets.
---

Treat drawings as source of truth for geometry and tags.

Index every file.

For each sheet extract:
- Sheet ID.
- Sheet title.
- Discipline.
- Revision number.
- Revision date.
- Addenda.
- Scale text.
- Graphic scale.
- North arrow.
- Title block.
- Drawing date.
- Drawn by.
- Checked by.
- Project name.
- Project address.

Detect whether sheet is vector, raster, or mixed.

For vector PDF:
- Extract text.
- Extract paths.
- Extract linework.
- Extract symbols.
- Extract dimensions.
- Preserve page coordinates.

For raster or photo:
- Correct rotation.
- Correct perspective if photographed.
- Detect borders.
- OCR text.
- Detect lines.
- Detect symbols.
- Detect scale bar.
- Classify rooms, walls, openings, tags, ducts, pipe, equipment.

Detect scale in this order:
1. Explicit written scale.
2. Graphic scale bar.
3. Known dimension string.
4. Known object check.
5. User calibration.

Never apply one scale to a whole sheet when plan, enlarged plan, and detail scales differ.

Store coordinates as:
- pagePointX.
- pagePointY.
- realWorldX.
- realWorldY.
- scaleContextID.

Extract:
- Rooms.
- Space names.
- Space numbers.
- Room boundaries.
- Ceiling heights.
- Wall types.
- Door tags.
- Window tags.
- Shafts.
- Mechanical rooms.
- Equipment tags.
- Duct mains.
- Duct sizes.
- Duct CFM callouts.
- Diffusers.
- Grilles.
- VAV/CAV boxes.
- Fans.
- Pipe mains.
- Pipe sizes.
- Notes.
- Keynotes.
- Details.
- Section cuts.
- Schedules.

Assign confidence 0.00 to 1.00 to every item.

Below 0.75 confidence, create RFI candidate or human-verification task.

Always report:
- Sheet ID.
- Scale used.
- What was measured.
- Confidence.
- What could not be read.

## Runtime and evidence

Read `../../references/implementation-status.md` before claiming an implemented capability. Use the local Swift package for implemented arithmetic. Preserve missing fields as unknown; do not substitute an unimplemented method with a completed result. Keep mechanical trade scope primary and plumbing/electrical interfaces as coordination unless the user explicitly includes those trades.
