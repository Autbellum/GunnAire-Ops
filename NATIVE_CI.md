# Native GitHub Actions checks

The `Native app regression` workflow runs on pull requests, pushes to `main`,
and manual dispatch (available once the workflow is on the default branch).
It complements the existing Backend/Tools Python 3.13 and 3.14 workflow.

## Coverage

- **iPad native tests**: the complete `GunnAire OpsTests` target plus five
  serial interface journeys: direct Invoice launch, simple Mail actions,
  current customer statement generation, statement review-to-Invoices,
  and billing-identity review-to-Invoices with safe report export controls.
- **Mac native tests**: the complete logic target on arm64 Mac Catalyst,
  followed by an unsigned optimized Release build. `lipo -verify_arch`
  requires both arm64 and x86_64 in the Release executable.
- Both test jobs reject failed results and zero passing tests. Logs, summaries,
  and available `.xcresult` bundles are uploaded even after failure and retained
  for seven days. Download them from the run's **Artifacts** section and open
  the result bundle in Xcode.

The workflow selects Xcode 26.6 on the standard arm64 `macos-26` runner.
The iPad destination is the 13-inch M5 simulator on iOS 26.2, matching the
existing local acceptance baseline. These versions were checked against
[GitHub's runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)
on September 7, 2026. If that image removes the pinned Xcode or runtime,
the job must fail visibly; review and test an explicit version update rather
than silently changing the acceptance environment.

## Safety and review

This workflow only builds and tests. It has read-only repository permissions,
does not persist checkout credentials, uses commit-pinned checkout/artifact
actions, and does not consume Apple signing or provider secrets. It uses the
existing fixture-based native tests, not a live customer/payment acceptance run.
No provisioning updates, distribution upload, CloudKit promotion, backend
deployment, live charges, or accounting writes are workflow steps.

Do not add `Config/Local.xcconfig`, local authentication state, signing files,
or production credentials to CI. Test artifacts can be visible to repository
readers; retain fixture-only evidence. The shared scheme remains unchanged;
the narrow ignore exception allows shared schemes to be maintained without
including other Xcode shared/user state.

This is not a complete UI, signed-device, production integration, or release
acceptance gate. An open PR is not deployed by this workflow, but **merging to
main can trigger the separately configured Render service**. Do not merge
without the separate production review.

## Validation and maintenance

Before publishing a workflow change, run `actionlint` against both YAML files,
`git diff --check`, and:

```sh
xcodebuild -list -json -project "GunnAire Ops.xcodeproj"
xcodebuild -showdestinations -project "GunnAire Ops.xcodeproj" -scheme "GunnAire Ops"
```

After pushing, inspect the exact commit's checks on the pull request. A local
lint pass or earlier native acceptance result does not establish that the new
hosted workflow passed. Keep both matrix jobs visible when one fails; do not
add `continue-on-error` to hide failures.

The first hosted run at `991b601` failed on QR decoding in the iPad job and
argument ordering in the final Mac `lipo` command. The corrected workflow puts
the input executable before the architecture list. Source QR margin tests and
software rendering address the observed label issue; fresh hosted verification
is still required. See [BILLING_IDENTITY_RECONCILIATION.md](BILLING_IDENTITY_RECONCILIATION.md)
for reproduced failures, local acceptance, and remaining scope.
