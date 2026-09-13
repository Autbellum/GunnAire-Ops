---
name: standalone-app-shell
description: Define the native LoadSight macOS and iOS app shell, project file format, screens, persistence, exports, settings, and user workflow when asked for app, Xcode project, SwiftUI, screens, UI, or build plan.
---

Use SwiftUI.

Target macOS 14+ and iOS 17+.

Use shared Swift Package core.

Create document-based project package:
.loadsight/
  project.json
  drawings/
  extracted/
  calcs/
  takeoffs/
  audits/
  documents/
  assumptions/
  overlays/

Screens:
- Project dashboard.
- Drawing viewer.
- Overlay and measure tools.
- Space tree.
- Load results.
- Equipment comparison.
- Takeoff spreadsheet.
- Audit queue.
- RFI queue.
- Change order queue.
- Proposal editor.
- Settings.

Exports:
- XLSX takeoff.
- PDF proposal.
- DOCX RFI.
- DOCX CO.
- JSON project.
- CSV quantities.

Keep deterministic calculations unit-testable.
Use LLM only for interpretation, classification, and drafting.

## Runtime and evidence

Read `../../references/implementation-status.md` before claiming an implemented capability. Use the local Swift package for implemented arithmetic. Preserve missing fields as unknown; do not substitute an unimplemented method with a completed result. Keep mechanical trade scope primary and plumbing/electrical interfaces as coordination unless the user explicitly includes those trades.
