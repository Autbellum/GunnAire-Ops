# Shared SDK host example

`ContentView.swift` is a small SwiftUI host component using only LoadSightKit. Build it with `swift build --package-path LoadSight --target LoadSightSDKExample` from the repository root. Pass a captured `ProjectDocument` and optionally a `LoadSightServicing` implementation. The example reviews recorded costs and holds, displays progress and cancels work when it leaves the screen. It does not approve or publish an estimate.

Integration contexts:

- **Document-based Mac app:** take a value snapshot from the current document and supply it to `SDKContentView(project:)`. Keep document ownership, dirty state and file exporters in the host. Apply no service result to a different document/session.
- **Contractor estimating app:** pass only a project the current user may view. Use the service's `reviewEstimate` with an explicit review time; keep company/account checks and authenticated publication in the host. SDK review is not server approval.
- **iPad markup app:** call `ingestDrawings` with Files-selected URLs. Review the returned archive and merge it into the still-current document only after success. Keep the operation handle and cancel it when the import/document closes; a failed batch returns no partial archive.

The component is compiled on Mac. These host adaptations describe integration boundaries; they are not three newly delivered production applications or verified platform-specific file-dialog flows.

## AsyncStream and result

```swift
let service = LocalLoadSightService()
let operation = LoadSightOperation { progress in
    try await service.ingestDrawings(urls, ocr: .whenNoText, progress: progress)
}
let monitor = Task {
    for await event in operation.progress {
        // Hop to MainActor before changing host UI state.
        print(event.stage)
    }
}
do {
    let archive = try await operation.result
    // Check host document identity before adopting this value.
} catch is CancellationError {
    // Retain the existing document.
}
monitor.cancel()
```

Use one consumer per operation's progress stream. The stream retains at most the latest 64 events; result values and errors come from `result`, not the progress buffer. Unit counts belong to the named stage, not an estimate of remaining wall time. Source URLs and filenames are not included in progress messages.

## Combine

On MainActor, retain `LoadSightProgressPublisher(operation.progress)` and subscribe to its `publisher`. It multicasts the latest progress to subscribers on MainActor, including terminal state. This is a state publisher: terminal status is a phase value rather than publisher completion. Retain the adapter while observing. `stopObserving()` stops observation; it does not cancel the operation. Do not also iterate the same AsyncStream elsewhere.

Call `operation.cancel()` to cancel work. Cancellation of a task awaiting `operation.result` also forwards cancellation. Cancellation is cooperative: synchronous calculation/document generation finishes its current engine call before checking cancellation, and OCR checks at its existing processing boundaries. Dropping an operation handle or stopping progress observation alone does not cancel work. The host owns operation lifetime and output file selection.

## Supported service methods

`ingestDrawings`, `reviewEstimate`, `reviewRecordedEngineering`, `draftProposal`, `draftRFI`, `draftCO`, and `exportTakeoff` call the existing shared engine. Inputs/results are Sendable values. Data stays local; the ingestion service rejects non-file URLs. Ingested files use the existing security-scoped URL access and limits. Persistent bookmarks remain the host's responsibility. Draft methods return bytes, never write, overwrite, send or publish files.

`reviewRecordedEngineering` recomputes the saved air, envelope and room-transmission worksheets and preserves their exclusions. It does not substitute for the requested semantic `extract`, complete `calculateLoads`, derived-model `takeoff` or extracted-versus-calculated `audit` pipeline. Those domain models and complete methods, local REST and optional cloud integration remain outstanding.

Native package hosts whose drawing bytes are stored separately can call the concrete local service overload `exportTakeoff(project, drawings: archive, progress: handler)`. It validates the captured archive and avoids reconstructing a self-contained JSON export on MainActor.
