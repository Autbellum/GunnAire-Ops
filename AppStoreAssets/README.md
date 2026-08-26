# App Store screenshot assets

These screenshots are generated from the Debug-only `-appStoreScreenshotFixtures`
workflow in `GunnAire_OpsUITests.testCaptureAppStoreScreenshots`. The workflow
uses fictional customer, technician, equipment, invoice, and job data. Never
capture production customer records for App Store assets.

## Ready-to-upload sets

- `Screenshots/iPad-13-inch`: six 2064 x 2752 portrait PNG files.
- `Screenshots/iPhone-6.9-inch`: six 1320 x 2868 portrait PNG files.

Every checked-in PNG has no alpha channel. These sizes are accepted by Apple's
13-inch iPad and 6.9-inch iPhone screenshot slots as of 2026-08-26. Reconfirm
the current requirements before a later release:
https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications

The order is intentional:

1. Command Center
2. Schedule and job closeout
3. Customer equipment systems
4. Job billing and invoice creation
5. Field payment collection
6. QuickBooks invoice publication

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
