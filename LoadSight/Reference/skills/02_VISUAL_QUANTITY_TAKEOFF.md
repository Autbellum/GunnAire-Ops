---
name: mechanical-visual-quantity-takeoff
version: 1.0.0
---
# 2. Quantity extraction and graphical takeoff

## Device counts
Perform an organized spatial sweep, system by system and area by area. Assign each physical item a stable ID and anchor. Identify lifecycle before adding quantity. Count tags as evidence, then check the associated symbol and leader endpoint; one leader can cover more than one object and one object can have repeated annotations. Trace every new diffuser back to its branch/system. Record room, tag, airflow, neck, face size, finish, accessories, existing/new state and sources.

Independently reconcile layout and ceiling-plan counts. The same diffuser shown twice is one physical diffuser, not two. Schedules normally specify types rather than quantities; a schedule illustration is not a device. Do not conflate type tags (S1, R1) with equipment-specific identification. Internally assigned zone IDs must be labeled as estimating IDs, not engineered box tags.

Demolition is a separate takeoff: count removals, retained items, protected components and salvaged equipment independently. New and demo totals need not match. Record capped openings, disconnect/reconnect work, handling and disposal when supported. Exposed/hatched linework must be interpreted with the project legend and explicit keynotes; ambiguity becomes a query, not an invented quantity.

## Lengths, areas and fittings
Do not issue final lengths from uncalibrated images. Record the original page size, the view used and any resampling/crop. Calibrate each scale region against a stated known dimension or another independently confirmed reference. Check a second known length, preferably in another direction to detect unequal x/y scale. Never apply the main-plan scale to an enlarged room detail. Never assume a screenshot retains the printed drawing scale or a ceiling tile is a known size without source support.

Trace centerlines with changes in size, material, system and lifecycle split into separate segments. Identify starts/ends, risers, drops, offsets, fittings and connection points. Plan-view lengths omit unknown vertical elevation changes; add documented vertical segments separately. Keep measured geometry, field adjustments and waste distinct.

Count elbows by angle/size/type, transitions by inlet/outlet size, branches/taps, dampers, caps, access doors, flexible connectors, boots/plenums and hangers. Do not automatically set takeoff count equal to diffuser count: one branch can serve multiple outlets. Do not hide extra elbows or offsets in an allegedly measured straight-run total.

Raw external bare-metal area estimates, before fittings, laps or insulation stretch-out:
- rectangular straight duct: 2 × (width_in + height_in) / 12 × length_ft;
- round straight duct: pi × diameter_in / 12 × length_ft.

These are geometry calculations, not finished insulation purchase quantities or shop-development patterns. Insulation thickness, joint overlaps, fittings and waste require their own basis. Weight requires a selected material/gauge and documented mass-per-area; do not infer gauge solely from diameter without the applicable construction requirement.

For a straight run with a support at each end, a preliminary spacing count may be ceil(length / maximum_spacing) + 1. This is only an estimating check: actual endpoint conditions, fittings, equipment, support details and shared supports govern. Do not apply this blindly to every fragmented segment or double-count shared endpoints.

A maximum flexible-duct length is a limit per connection, not an assumed purchased length. Count and measure actual flex separately from rigid round duct. Track installed quantity, explicitly justified waste and supplier purchase rounding separately.

## Evidence categories
Cross-checked symbol counts may be used as a count basis while unresolved sizes stay on hold. Scaled measurements remain Measured-draft until visual route review and calibration evidence are signed off. Missing geometry remains null or a clearly described Approved allowance; it must never silently become zero.
