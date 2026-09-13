---
name: mechanical-load-core
description: Calculate heating/cooling loads, psychrometrics, zoning, peak/block loads, airflow, and capacity checks when asked for Manual J, Manual N, ASHRAE loads, CFM, Btuh, tonnage, ventilation, infiltration, envelope, sensible, latent, or load audit.
---

Use IP units by default.

Create an AssumptionsLog before calculating.

Record:
- Jurisdiction assumed.
- Climate zone assumed.
- Indoor heating design temperature.
- Indoor cooling dry-bulb and relative humidity.
- Outdoor winter 99% design temperature.
- Outdoor summer 1% dry-bulb and coincident wet-bulb.
- Building type.
- Occupancy type.
- Safety factor.
- Source of every dimension.
- Source of every U-factor.
- Source of every airflow.
- Source of every internal gain.

Never invent missing geometry as fact.

Classify every input as EXTRACTED, USER-PROVIDED, CODE-DEFAULT, ENGINEERING-ASSUMPTION, or RFI-REQUIRED.

Calculate envelope loads using:
Q = U × A × ΔT

Calculate total assembly U-factor using:
U = 1 / R_total

Calculate sensible air load using:
Q_s = 1.08 × CFM × ΔT
Use this only when standard-air assumptions are acceptable.

Calculate latent load using:
Q_l = 0.68 × CFM × ΔGrains
Use this only when humidity difference is in grains/lb dry air.

Calculate total air load using:
Q_t = 4.5 × CFM × Δh
Use enthalpy in Btu/lb dry air.

Calculate SHR using:
SHR = Q_s / Q_t

Reject impossible SHR values below 0 or above 1 unless clearly labeled as data error.

Calculate ventilation outdoor air from applicable code or standard:
V_bz = R_p × P_z + R_a × A_z
V_oz = V_bz / E_z
Require the applicable zone effectiveness and rate sources. Calculate multizone system efficiency separately when applicable; never label breathing-zone flow as zone outdoor airflow before applying E_z.

Calculate infiltration as ACH, CFM, or method-specific leakage model.
Show method used.

Separate:
- Room load.
- Zone load.
- Block load.
- Coil load.
- Equipment capacity.
- Delivered capacity.

Do not size equipment directly from nominal tons.

Compare calculated load to selected equipment capacity at actual design conditions.

Flag:
- oversized equipment.
- undersized equipment.
- latent mismatch.
- airflow mismatch.
- heating output mismatch.
- missing design conditions.
- missing envelope values.
- missing duct location/leakage assumptions.
- peak-vs-block confusion.

Return:
- SpaceLoad table.
- ZoneLoad table.
- SystemLoad table.
- Equations used.
- Substituted numbers.
- Result with units.
- AssumptionsLog.
- RFI candidates.
- PEReview items.

## Runtime and evidence

Read `../../references/implementation-status.md` before claiming an implemented capability. Use the local Swift package for implemented arithmetic. Preserve missing fields as unknown; do not substitute an unimplemented method with a completed result. Keep mechanical trade scope primary and plumbing/electrical interfaces as coordination unless the user explicitly includes those trades.
