# App Store screenshot assets

## Submission metadata contract

`AppStoreSubmission.json` is the non-secret, source-controlled contract for the
App Store record. It keeps the bundle, locale, HTTPS privacy/support/marketing
URLs, App Review sign-in boundary, and every App Privacy answer aligned with
`GunnAire Ops/PrivacyInfo.xcprivacy`. Review credentials and personal contact
details belong only in App Store Connect and must never be added to this file.

`Tools/release_preflight.py` fails if a collected data type is added, removed,
duplicated, relabeled without a usage explanation, or changes its linkage,
tracking, or purpose without the corresponding App Store answer changing too.
This follows Apple's current requirement to answer comprehensively across all
platforms, include integrated third-party practices, provide an iOS privacy
policy URL, and keep the answers accurate:
https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy

Safari verification on 2026-08-31 found the live App Store draft incomplete:
the privacy-policy URL was not entered, only a subset of the source manifest's
13 data types appeared in the draft, most visible answers still showed “Set
Up,” and Publish was disabled. The exact current build `2026083104` is not
uploaded or selected. This repository contract prepares the accurate
answers; it does not claim that the App Store form has been saved or published.

## Accessibility submission boundary

Safari verification on 2026-08-31 found the live App Accessibility page at
“Get Started,” with no support claim published. Apple requires a claimed
accessibility feature to work across every common task—including first launch,
sign-in, purchases, and settings—and evaluates claims per device type. Build
`2026083104` retains the app-side Reduce Motion boundary and adds a Debug-only
largest-Dynamic-Type fixture. The complete iPad UI target passes **94/94**
logical tests with **97/97** device executions, including all 13 Administrator
workspaces at maximum accessibility text size without shrinking text. Do not
publish Reduce Motion or any other accessibility feature until the signed iPad,
iPhone, and Mac acceptance record proves the complete applicable task set.

Current Apple criteria:
https://developer.apple.com/help/app-store-connect/manage-app-accessibility/overview-of-accessibility-nutrition-labels

These screenshots are generated from the Debug-only `-appStoreScreenshotFixtures`
workflow in `GunnAire_OpsUITests.testCaptureAppStoreScreenshots`. The workflow
uses fictional customer, technician, equipment, invoice, and job data. Never
capture production customer records for App Store assets.

## Ready-to-upload sets

- `Screenshots/iPad-13-inch`: six 2064 x 2752 portrait PNG files.
- `Screenshots/iPhone-6.9-inch`: six 1320 x 2868 portrait PNG files.

Every checked-in PNG has no alpha channel. These sizes are accepted by Apple's
13-inch iPad and 6.9-inch iPhone screenshot slots as of 2026-08-31. Reconfirm
the current requirements before a later release:
https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications

The order is intentional:

1. Command Center
2. Schedule and job closeout
3. Customer equipment systems
4. Job billing and invoice creation
5. Field payment collection
6. QuickBooks invoice publication

## Current-source verification

The current iPad captures were exported from the complete sequential UI result
that passed 104/104 logical tests with 107/107 device executions on 2026-09-02
using an iPad Pro 13-inch (M5) simulator with iOS 26.5. The current iPhone
capture workflow passed 1/1 the same day on an iPhone 17 Pro Max simulator with
iOS 26.5. Evidence is retained at
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-02/GunnAire Ops 1.0 (2026090204 iPad UI Broad 104 Pass).xcresult`
and
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-02/GunnAire Ops 1.0 (2026090204 iPhone App Store Screenshots).xcresult`.
The twelve exported attachments were mapped by their manifests, visually
inspected, and mechanically verified for the expected dimensions and an opaque
RGB pixel format before replacing this retained set. None exposes the signed-in
account email or sidebar identity, and none contains a keyboard, alert, spinner,
or notification banner.

The capture contract verifies that the deterministic fixtures never expose the
signed-in sidebar identity. Customer Systems must show the compact Edit, QR,
and More actions while lifecycle and delete actions remain hidden in the closed
menu. Immediately before each attachment, the test also waits for any
SpringBoard notification banner to disappear and fails instead of retaining an
obscured image. The UI-test process sets an intentionally unsupported backend
authentication mode for deterministic capture only. That keeps the backend
unconfigured for every fixture launch, so no live request or missing-session
error can appear without changing the production app's refresh behavior.

## Regeneration

Run the same UI test on the two release screenshot simulators, changing the
device IDs if Xcode has recreated them:

```sh
xcodebuild test -project 'GunnAire Ops.xcodeproj' -scheme 'GunnAire Ops' \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:'GunnAire OpsUITests/GunnAire_OpsUITests/testCaptureAppStoreScreenshots' \
  -resultBundlePath /tmp/GunnAire-AppStore-iPad.xcresult \
  CODE_SIGNING_ALLOWED=NO

xcodebuild test -project 'GunnAire Ops.xcodeproj' -scheme 'GunnAire Ops' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'GunnAire OpsUITests/GunnAire_OpsUITests/testCaptureAppStoreScreenshots' \
  -resultBundlePath /tmp/GunnAire-AppStore-iPhone.xcresult \
  CODE_SIGNING_ALLOWED=NO

xcrun xcresulttool export attachments \
  --path /tmp/GunnAire-AppStore-iPad.xcresult \
  --output-path /tmp/GunnAire-AppStore-iPad

xcrun xcresulttool export attachments \
  --path /tmp/GunnAire-AppStore-iPhone.xcresult \
  --output-path /tmp/GunnAire-AppStore-iPhone
```

Use each export's `manifest.json` to map the generated UUID filename to the
suggested screenshot name. Do not assume attachment enumeration order.

## Required visual QA

Before replacing or uploading the checked-in files, verify all of the following:

- Correct portrait orientation, device size, and no alpha channel.
- No production or personally identifying customer data.
- No clipped controls, wrapped action labels, keyboards, alerts, or spinners.
- No system notification banner obscuring any app content.
- The displayed customer, equipment, job, invoice, and amount agree.
- QuickBooks and payment screens describe actual connection state and do not
  imply a successful live sync or card capture that did not occur.
- System status bars contain no unexpected recording, location, or privacy
  indicators.

Pixel and alpha checks can be repeated with:

```sh
for file in AppStoreAssets/Screenshots/*/*.png; do
  sips -g pixelWidth -g pixelHeight -g hasAlpha "$file"
done
```
