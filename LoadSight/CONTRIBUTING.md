# Contributing to LoadSight

Keep mechanical calculations in the shared Swift modules. Native views and the plugin must call that engine instead of implementing a second pricing or lifecycle model. Preserve the existing Ops backend as the authority for authenticated external actions.

Before a change, read `BUILD_STATUS.md`, the relevant method under `Reference/engineering/`, and its tests. Use synthetic fixtures with explicit provenance. Never manufacture dimensions, quantities, prices, weather, review signatures or release status. Do not collapse unknown values into zero.

Run `swift test --package-path LoadSight` from the repository root. For UI or document changes, also build the native target and inspect the affected interaction or rendered artifact. State exact test scope in the PR; passing model tests alone does not establish physical-device or export-dialog acceptance.

Run `python3 -m unittest discover -s Plugins/gunnaire-ops/tests -v` for wrapper changes. The wrapper uses `--workspace`, `LOADSIGHT_WORKSPACE`, or the repository sibling package. CLI edits write to a new path and must retain the original input on failure.

Do not include generated app bundles, build directories, result bundles, personal Xcode state, local configuration, credentials or live customer documents in commits. Preserve source licenses. Project release licensing remains the owner's decision; this change does not grant a new open-source license.

Describe the concrete behavior, verification, source/method assumptions and remaining limitations. Keep customer/job matching and cost-to-catalog publication explicitly reviewed; a LoadSight draft is not an approved Ops estimate.
