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
`2026090504` retains the app-side Reduce Motion boundary and Debug-only
largest-Dynamic-Type fixture. The complete iPad UI target passes **113/114**
logical tests with **116/117** device executions, one intentional physical-only
skip, and zero failures, including all 13 Administrator workspaces at maximum
accessibility text size without shrinking text. Do not
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
13-inch iPad and 6.9-inch iPhone screenshot slots as of 2026-10-01. Reconfirm
the current requirements before a later release:
https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications

The order is intentional:

1. Command Center
2. Schedule and job closeout
3. Customer equipment systems
4. Job billing and invoice creation
5. Field payment collection
6. QuickBooks invoice publication

`ScreenshotManifest.json` binds these exact twelve files to the reviewed app
version and build, the retained capture-result names, required dimensions, and
SHA-256 digests. Local release preflight fails if the source build changes,
an image is replaced, a PNG is added or removed, the dimensions drift, or an
alpha/transparency channel appears. This prevents an older screenshot set from
silently passing release preparation after the app interface changes.

## Current-source verification

The retained screenshot set was regenerated from build `1.0 (2026100120)` on
2026-10-01. Both the iPad Pro 13-inch (M5) and iPhone 17 Pro Max capture tests
passed **1/1** on iOS 26.5. The selected images show the current
Command Center, Schedule, customer equipment, job billing, payment entry, and
QuickBooks publication review. The QuickBooks light-mode background and title
remain readable in both device captures.

The retained result bundles and exported attachment manifests are in
`/Users/gunnaire/Documents/GunnAireCompletion/2026-10-01-release-0120/`.
All twelve selected images were visually reviewed and mechanically checked at
2064 x 2752 or 1320 x 2868 with no alpha channel. The fixtures show disconnected
Google Calendar and QuickBooks Payments states honestly; they do not represent
live provider delivery. No selected image exposes a signed-in account email,
keyboard, alert, spinner, or notification banner.

The capture contract disables animation only for the Debug screenshot fixture,
waits through a four-second app-and-system quiescence window, and refreshes an
interactive native iPad sidebar before capture. It also verifies that the
deterministic fixtures never expose a
GunnAire account address. When the sidebar is visible, it also requires the
role-only `Administrator` footer; the compact iPhone layout correctly keeps its
collapsed sidebar out of the screenshot. Customer Systems must show the compact
Edit, QR, and More actions while lifecycle and delete actions remain hidden in
the closed menu. Immediately before each attachment, the test also waits for any
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
suggested screenshot name. Do not assume attachment enumeration order. After
visual review, update `ScreenshotManifest.json` with the current source version,
build, evidence names, dimensions, and exact SHA-256 digest of every retained
PNG; run the release preflight before accepting the replacement set.

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
