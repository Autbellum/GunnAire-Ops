# GitHub source handoff

## Contents and baseline

The source overlay contains `LoadSight/`, `Plugins/gunnaire-ops/` and `.github/workflows/loadsight-regression.yml`, plus a generated `GITHUB_SOURCE_MANIFEST.json` with SHA-256 hashes and file modes. It is a standalone native app, shared SDK, CLI and plugin development snapshot. Generated apps, caches, local evidence and Git metadata are excluded.

GitHub `main` was checked directly on 2026-09-10 at `e17fec5fca4dfd8042096f7f833db829a0bbcb63`. A separate shallow bare clone confirmed the existing Ops app and canonical `Backend/` service. That revision has no LoadSight or plugin directory. The source overlay preserves that backend authority: local mechanical drafts and captured Ops context do not authenticate a user or publish accounting transactions.

## Reproduce the archive

From the repository root, choose a new output filename:

```sh
python3 LoadSight/Tools/prepare_github_bundle.py \
  --reviewed-base e17fec5fca4dfd8042096f7f833db829a0bbcb63 \
  --output /tmp/gunnaire-loadsight-source.zip
```

The command records the local HEAD separately from the reviewed remote base. It respects Git ignore rules, rejects symlinks and generated files, checks for changes during capture, and refuses existing output. It performs no Git staging, commit, push, merge or installation.

Extract into a separate review checkout. Compare every extracted source file with the manifest before reviewing or committing. Run:

```sh
swift test --package-path LoadSight
swift build --package-path LoadSight --target LoadSightSDKExample
python3 -m unittest discover -s Plugins/gunnaire-ops/tests -v
xcodebuild -project LoadSight/Native/LoadSight.xcodeproj -scheme LoadSight \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

The included workflow runs the broader real-engine plugin checks on macOS. Its Xcode runner availability and all final-commit checks must pass on GitHub before claiming hosted verification.

## Ops host integration requires a separate review

The current workspace also modifies the existing Ops app and backend extensively. The archive intentionally contains only the standalone source scope above. The embedded Estimates entry point depends on the current `GunnAire Ops/BillingDocumentsView.swift`, local package/product references in `GunnAire Ops.xcodeproj/project.pbxproj`, `GunnAire OpsUITests/LoadSightIntegrationUITests.swift`, and the native Ops regression workflow. Those files include or depend on other active Ops work; they are not safe to present as an isolated mechanical-only patch. Review their complete dependency set in the main workspace before merging the embedded flow.

The root README and PR template are also existing working-tree handoff files. `GITHUB_PR.md` describes the broader combined implementation; adapt it to the actual files selected for each PR.

## Evidence and unfinished work

`REPOSITORY_READY.md` and `BUILD_STATUS.md` preserve historical tested milestones. Source-defined schedule unit conventions now have their own model, plugin and native disk-reopen acceptance in `Reference/verification/Schedule-unit-conventions.md`. The earlier source archive remains an immutable snapshot with its own manifest and verification; generate a new archive to capture subsequent work.

The source includes inherited dental-project regression data and recovered requirement/skill documents with their existing provenance. Their presence does not turn inherited quantities into new drawing verification. No new release license or ownership grant is added.

The application goal remains open: complete engineering methods, automatic extraction and confirmed associations, authenticated cloud/Ops publication, and broader device/export acceptance still require implementation and verification.
