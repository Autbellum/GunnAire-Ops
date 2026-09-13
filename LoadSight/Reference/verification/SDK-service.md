# Local asynchronous SDK service — 2026-09-10

## Delivered interface

`LoadSightServicing` and `LocalLoadSightService` expose existing batch drawing ingestion, pricing review, recorded engineering review and proposal/RFI/CO/workbook output to host apps without importing LoadSightUI. The actor isolates synchronous engine work from MainActor; inputs/results are Sendable snapshots. Batch import retains original bytes, deduplicates source fingerprints and returns no partial result on failure. Non-file URLs and empty/excessive batches reject. Drawing security-scoped access remains in the ingestor; persistent bookmarks remain host-owned.

`LoadSightOperation` adds an owned task, result, cancellation and a per-operation AsyncStream. Buffering retains the latest 64 events, including terminal state. Progress counts describe stages/files, not time estimates. Cancellation of a result waiter cancels the task; current synchronous engine calls and OCR boundaries determine cancellation latency. Stopping observation or dropping a handle alone does not cancel the task. The MainActor Combine adapter multicasts the latest state; terminal phase is a value, not publisher completion.

The 40-line `Examples/SDKClient/ContentView.swift` uses the protocol, displays review progress/results, and cancels when dismissed. Its README covers host responsibilities for document-based Mac apps, contractor estimating apps and iPad markup apps. It is a compiled reusable component, not three separately completed applications.

## Verified evidence

- **232 shared Swift tests pass** in the combined tree. Ten SDK tests verify shared pricing/workbook equivalence and source preservation, real three-page PDF batch deduplication, failure without a partial archive, cancellation after work starts, waiter cancellation forwarding, bounded terminal progress, main-thread Combine multicast, local-input boundaries, draft output/missing-record validation and explicit partial engineering scope.
- The SDK host example compiles as `LoadSightSDKExample`; its source is exactly 40 lines.
- Native Mac bundle build and unsigned arm64 iPad simulator build pass. The iPad build uses an isolated source copy; final source hashes match. No new host-example UI or physical-device acceptance is asserted by compilation.
- Plugin documentation is installed at `0.1.0+codex.20260910182859`; its SDK reference and implementation-status files match personal source. The wrapper command surface is unchanged.
- CI adds a host-example compilation step. Local YAML and embedded shell syntax are checked; hosted execution is not claimed.

The initial 223-test run was followed by concurrent shared-module changes. The final combined 232-test run and repeated Mac/iPad builds passed, with final production hashes matching the isolated build copy. The example target explicitly excludes its README to keep package builds warning-free.

Logs and source hashes are retained locally under `output/verification/sdk-service/`.

## Remaining full scope

The requested semantic `extract`, complete `calculateLoads`, derived-model `takeoff` and extracted-versus-calculated `audit` pipeline still require their domain models and full engineering/extraction implementations. `reviewRecordedEngineering` explicitly returns partial recorded worksheets and their exclusions. Local REST, optional cloud processing, persistent bookmark integration and complete host/runtime acceptance also remain open. This SDK layer does not authenticate, publish or place orders.

## Subsequent extraction services

`LoadSightServicing` now also exposes `extractMechanicalText` and `extractEquipmentSchedules`, using the local actor and progress/cancellation contract. The latter requires explicit source regions and column mapping. See [mechanical text](Mechanical-text-extraction.md) and [mapped equipment schedules](Equipment-schedules.md) for the exact evidence and incomplete semantic/engineering scope.
