# Technician field editing

The hosted staff workspace now exposes an editor on available operations-policy scalar fields. It is not a generic owner-model editor. Service findings, checklists, equipment notes, access notes and other allowed operational fields use typed text, choice, boolean, date and numeric controls. Restricted fields, structured JSON, relationships, invoice money/status and unsupported identifiers remain outside this workflow. Main record detail no longer displays transport revision/body/record-ID diagnostics.

## Authority and original intent

An editor borrows only the context of the currently published staff host. The receive controller checks exact host identity, company/account/session, role, accepted share and expiry before returning it. This allows local field capture without a fresh network round trip after an authorized workspace was opened; it does not grant new offline login, bypass expiry or use the owner's private store. Access refresh temporarily disables edits; revocation/account changes clear private display state while retaining encrypted originals.

Opening binds the editor to the displayed selection, source sequence, content digest, record, revision, field and projected value. Saving verifies that exact mounted field again. A changed head cannot silently rebase the user's draft. New commands receive one stable operation ID. Retry can send only an existing durable original, even when the original mount is no longer available; it cannot create a new request from retry parameters.

Save writes the complete original to the encrypted command queue before network work. The UI then reports either a confirmed server receipt for office review or a locally saved update still needing confirmation. It never reports that local capture or server recording replaced the office record, collected money or completed QBO/CloudKit convergence. The existing Submitted Updates view provides the historical office disposition.

## Restart and sibling recovery

A bounded encrypted field-discovery reference preserves original requests alongside the existing immutable per-command journals. Global/background retries establish that reference before a recorded receipt can prune the pending index. Interrupted queue/reference writes therefore remain discoverable without an in-memory operation ID. One rejected legacy request cannot block unrelated saved requests for the same field.

References retain up to 128 original submissions per field in discovery order; only references to confirmed recorded originals can be trimmed. Per-command journals are never deleted, pending originals are never trimmed, and full recorded history remains available from the author-only server endpoint. Reference corruption fails closed without replacing evidence. The editor shows pending originals and the most recent locally referenced recorded update; older results stay in Submitted Updates.

Reopening shows saved submissions instead of silently generating another command ID. Creating a subsequent update is explicit and is disabled while a local original remains pending. Repeating the same value does not create a duplicate. Office conflict review remains separate from field capture.

## Drafts and acceptance limits

Unfinished input is automatically persisted in an encrypted, author/company/iCloud-account/share-scoped draft, separately from the immutable command queue. Typing does not submit a command. Reopening restores the original snapshot, stable intended operation ID and raw input, including incomplete numeric text. Every control uses the same persistence boundary; lifecycle changes retry unverified saves. A failed save retains visible input and requires confirmation before closing without its latest changes. Account loss clears private display but retains the encrypted draft for the original authorized account.

Draft writes use serialized compare-and-swap. Another window cannot replace newer text or resurrect a discarded draft. Submission checks the exact persisted draft before creating a new command. Once an original is queued, its draft is no longer editable and reopening shows the saved submission instead. A discarded draft leaves a terminal marker, not a resurrectable empty record. An advanced office snapshot restores the old draft for review; explicit adoption creates a new intended operation bound to the verified current field without sending it. Original submitted commands are never rebased or overwritten by this workflow.

See `STAFF_FIELD_DRAFTS.md` for recovery and acceptance boundaries. Historical ordering refinement, removed-record/superseded-intent disposition, cross-device draft sharing and claim recovery remain separate work. This must not be described as full offline application completion.

Tests cover mounted-data editing, exact snapshot binding, typed validation, every queue write interruption, background recovery, original-ID preservation, corrupt references, bounded discovery, repeated values, access changes and late replies. Physical iPad/independent-account CloudKit acceptance, live provider/payment tests and parallel UI qualification remain required. No screen capture, visible app launch, signing, production mutations, push or deployment is part of local qualification.

## Release-only teardown regression

The new synchronous editor path exposed a runtime abort in `StaffWorkspaceContentCoordinator.__deallocating_deinit`, through `swift_task_deinitOnExecutorImpl` and `TaskLocal::StopLookupScope`, on the iOS 26.2 simulator with Xcode 26.6 / Swift 6.3.3. Empty nonisolated teardown is explicit on that coordinator and the adjacent editor, outcome and receive controllers. Their methods and mutable state remain main-actor isolated; no storage, UI or authorization work runs in deinitialization. A synchronous XCTest stress case releases all four 100 times and asserts their weak references clear, rather than retaining test objects to hide the crash. This follows the release-only distinction in [Swift SE-0371](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0371-isolated-synchronous-deinit.md). Physical-device acceptance remains separate.
