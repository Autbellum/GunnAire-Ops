# LoadSight

Native mechanical takeoff, evidence review and entered-input engineering calculations for Mac and iPad. The same Swift engine serves the app, GunnAire Ops and the Codex plugin. This is an active implementation, not a complete ACCA design or approved bidding system.

## Build from a checkout

Use macOS with Xcode and Swift 6. Package minimums are macOS 14 and iOS 17; the Ops application has its own iOS 26 requirements. From the repository root:

```sh
swift test --package-path LoadSight
swift run --package-path LoadSight loadsight validate LoadSight/Tests/LoadSightKitTests/Fixtures/Blank_Project.json
python3 LoadSight/Tools/build_mac.py
open LoadSight/output/LoadSight.app
```

For iPad, open `LoadSight/Native/LoadSight.xcodeproj`, select the shared LoadSight scheme and an installed iPad simulator. An unsigned compile is:

```sh
xcodebuild -project LoadSight/Native/LoadSight.xcodeproj -scheme LoadSight -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Open `GunnAire Ops.xcodeproj` to use **Estimates → Open LoadSight workspace**. The embedded editor retains a local recovery draft for the current Ops account context; use explicit project export for a portable record. It offers explicit customer/job linking with authored snapshot history. In Takeoff, **Catalog cost** records an Ops material purchase-cost snapshot, explicit USD/unit conversion, and revision history. It does not create or approve Ops billing documents.

## Project layout

| Directory | Responsibility |
| --- | --- |
| `Sources/LoadSightCore` | Project schema, evidence, QA and edit histories |
| `Sources/LoadSightCalc` | Sourced finite calculations and method traces |
| `Sources/LoadSightTakeoff` | Calibrated drawing quantities and markup |
| `Sources/LoadSightIngest` | Original drawing intake and extraction |
| `Sources/LoadSightKit` | Shared review, edit and export APIs |
| `Sources/LoadSightUI` | Native editors and document hosts |
| `Sources/LoadSightCLI` | CLI used by the plugin |
| `Tests` | Model, export and source-backed fixture checks |
| `Reference/engineering` | Methods, assumptions and attribution |
| `Requirements` | Recovered specifications and source register |

Projects are `.loadsight` packages or self-contained JSON. Keep original drawings, source hashes, calibrated geometry and revision histories together. Unknown cost is distinct from zero; incomplete totals remain withheld. RFI and CO Word exports remain review drafts. Recorded names are not authenticated approvals.

## Verification and remaining work

See [BUILD_STATUS.md](BUILD_STATUS.md), [repository preparation](REPOSITORY_READY.md) and [contribution guide](CONTRIBUTING.md). CI checks the Swift package, portable plugin and native simulator compilation. Existing Ops and backend workflows remain separate.

Full room/building/distribution and equipment/code methods, semantic drawing extraction, customer/job synchronization, broader catalog/supplier integration, authenticated release and broader physical-device acceptance remain unfinished. No proprietary ACCA tables or unlicensed source documents are supplied by this repository. Existing third-party attribution is retained in `Reference/engineering/PsychroLib-LICENSE.txt`.
