---
name: xcode-plugin-bridge
description: Expose LoadSight skills as Swift protocols, async APIs, Sendable data models, local REST calls, Combine progress streams, and plugin-safe SDK components for any Xcode app.
---

Build as Swift Package named LoadSightKit.

Expose deterministic calculation APIs.

Keep LLM calls optional.

Keep drawings on device by default.

Use async/await.

Mark public models Sendable.

Publish progress updates with AsyncStream and Combine.

Support:
- macOS document apps.
- contractor estimating apps.
- iPad markup apps.
- local REST service.
- offline deterministic mode.
- optional cloud processing.

Never require app-specific UI.

Separate:
- LoadSightCore.
- LoadSightIngest.
- LoadSightCalc.
- LoadSightTakeoff.
- LoadSightAudit.
- LoadSightDocuments.
- LoadSightLLMBridge.

## Runtime and evidence

Read `../../references/implementation-status.md` before claiming an implemented capability. Use the local Swift package for implemented arithmetic. Preserve missing fields as unknown; do not substitute an unimplemented method with a completed result. Keep mechanical trade scope primary and plumbing/electrical interfaces as coordination unless the user explicitly includes those trades.
