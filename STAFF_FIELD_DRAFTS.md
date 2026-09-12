# Recoverable technician drafts

The hosted staff field editor automatically saves unfinished local input before submission. A draft is not a command receipt, a server update or proof of CloudKit delivery. Only an explicitly submitted, valid new scalar enters the existing original-command queue.

## Storage and identity

Drafts use the existing authenticated encrypted staff-content store. Keys bind backend origin, company, signed-in author, environment, iCloud account and accepted share, plus record kind/ID/field. Restoring requires current staff authority. A refreshed session for the same authorized scope can recover work; a different scope cannot adopt it. Access revocation clears private UI state, not retained encrypted work.

The versioned closed envelope contains the original displayed snapshot, stable intended command ID, monotonic revision, initial input and current raw input. It retains unfinished numbers and optional values without coercion. Raw text is bounded at 64 KiB; the complete envelope is bounded at 256 KiB. Oversized, corrupt or unverified writes fail visibly without replacing prior evidence. Draft validity is intentionally distinct from stricter command/scalar validity.

## User flow

- Opening a new editor establishes the original authorized snapshot and local draft ID.
- Text, choices, dates, toggles and explicit null changes save locally through the same boundary. Closing a verified draft keeps it; reopening restores it without a new command ID or any HTTP submission.
- A failed or interrupted save keeps the latest visible input. A successful write followed by a lost acknowledgement is recognized by exact readback. Otherwise the UI warns that the latest text is not protected and offers retry.
- Submit verifies the persisted original draft, queues one complete original, and uses the existing receipt recovery path. A draft corresponding to a queued command cannot become a second editable copy on relaunch.
- Discard is explicit and confirmed. Its durable terminal marker prevents another old window from writing the discarded draft back. Submitted originals are never deleted by discarding a draft.
- When the shared record advances, the original input remains bound to the old snapshot. The review view compares original and current values. Explicitly choosing to use the draft with the current record creates a new local intent; it does not submit automatically. New authority/snapshot checks still apply at final submission.

## Concurrency and interruption

The same MainActor mutation gate used by original-command work serializes draft mutations. Each write compares the entire previous envelope and expected next revision; stale windows cannot overwrite each other. Autosave checks the current original-ID lock without decrypting every completed receipt for each keystroke. Teardown only clears display state and does not run storage callbacks. Original-command retry never reconstructs its request from mutable draft input.

Review confirmation freezes the exact current snapshot displayed when the user opens the confirmation. If the office head changes again, confirmation cannot adopt the newer unseen snapshot; the user must review it again.

The local command write-ahead journal is authoritative if submission was interrupted. Its original request is preserved even when the draft remains on disk. Opening the field checks existing command history before offering editable restoration. A later explicit update uses a new intended ID and cannot replace a pending original.

## Remaining acceptance

These are device-local drafts, not cross-device CloudKit draft synchronization. Lost-device/key recovery, removed-record draft discovery/disposition, cross-device claim ownership, independent-account physical CloudKit handoff, live provider/payment acceptance, complete domain-specific field forms and parallel UI qualification remain separate gates. Background unit/build checks do not prove physical-device interaction, signing or production readiness.
