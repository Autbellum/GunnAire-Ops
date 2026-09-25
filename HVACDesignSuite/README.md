# HVAC Design Suite

A native macOS design suite executing the cascading ACCA lifecycle:

    Manual J / N  ─→  Manual S  ─→  Manual T  ─→  Manual D
      loads            equipment     room CFM     duct sizes

## Layout

| Target | Contents |
|---|---|
| `HVACCore` | Data models, psychrometrics, all four calculation modules, the reactive engine. No SwiftUI. |
| `HVACUI` | The three-panel SwiftUI workspace. |
| `HVACDesignSuiteApp` | `@main` App entry point. |

`HVACCore` imports only Foundation and Observation, so the engine is testable and
reusable without a UI, and can be lifted into an iPad app unchanged.

## Running

    swift build && swift run HVACDesignSuite
    swift test

To use it from Xcode, open the package directly (`File ▸ Open` on the folder), or drag
`Sources/HVACCore` and `Sources/HVACUI` into an existing macOS app target.

## Verification status

47 tests pass. The psychrometric coefficients are anchored against published reference
values (saturation pressure at 32/70/212 °F; 1.08, 4840 and 4.5 recovered at sea level),
and the duct physics was cross-checked against an independent calculation outside Swift.

## Reference data — nothing is hand-loaded

| Data | Source |
|---|---|
| Design weather | Derived from NOAA ISD hourly observations |
| Solar irradiance | Computed: solar geometry + Bird & Hulstrom clear-sky model (NREL, public domain) |
| Envelope U-values | Computed from layers by the parallel-path method |
| Material resistances | Standard published properties |
| Glazing U / SHGC | Typical values by construction; NFRC label overrides |
| Fitting equivalent lengths | Computed as Lₑ = C·D/f, so they scale with the duct |
| Manual S limits | Verified against the published selection table |

## Remaining approximations

- **Thermal mass and lag are not modelled.** The sol-air equivalent difference is a
  steady-state upper bound: correct for a light frame assembly, overstated for masonry.
  This is what the radiant time series replaces.
- **Glazing values are typical, not certified.** Enter the NFRC label when the model is known.
- **Manufacturer expanded performance data is entered by hand**, because Manual S selects
  against the real coil at the design condition and no public database holds it.
- Design weather is derived from NOAA observations, not ASHRAE published tables, and is
  labelled as such on output.
