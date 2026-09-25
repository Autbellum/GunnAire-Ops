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

## Known approximations

- **Fenestration solar gain** uses provisional peak irradiance by orientation. It is not
  latitude-specific and not hour-specific. This is the largest single approximation in the
  build; it is replaced by NSRDB clear-sky irradiance when the radiant-time-series engine
  lands.
- **Manual S percentage bounds** are held as data in `SizingLimits`, not verified against
  the current edition of the manual. Confirm before any permit submittal.
- **Fitting equivalent lengths** are entered by the user from their own copy of Manual D.
- Design weather defaults are derived from NOAA observations, not ASHRAE published tables.
