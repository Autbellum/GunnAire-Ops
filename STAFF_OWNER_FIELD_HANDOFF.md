# Cooperative owner-device field-edit handoff

## Implemented workflow

The existing Field updates review offers **Continue on Another Device** only
when the original device has retained evidence that its model-save boundary has
not been entered. The owner confirms the action; the app durably fences this
command on its original private store before POST `/api/workspace/field-edits/{id}/release`.
After a confirmed release, another approved owner device can prepare the same
original staff command through the existing claim/apply/publish workflow.
No office value is changed by the handoff itself, and no top-level tab is added.

This is cooperative release, not an absent-device timeout or remote takeover.
Use the same approved business/CloudKit owner workspace on the receiving device.
Normal server-side administrator, company, replica and current staff eligibility
checks still govern the receiving device's new claim.

## Write and ownership fences

- Newly created application intents have `writeBoundaryVersion = 1`. The app
  durably records phase `applying` before invoking the synchronous typed model
  writer. Failed or ambiguous saves remain `applying`, never relabeled untouched.
- Release requires phase `prepared`, version-1 before-save evidence, the exact
  original claim/author/operation, and agreement between the saved local field,
  reviewed current source field and original claim's expected value. The value
  must not already equal the requested technician update.
- The immutable encrypted local fence contains the original pending application,
  current review and exact release request. It is stored separately from the
  retry queue, verified by read-back before HTTP, and checked on every apply
  path, including the live model writer's current-authority check. Queue cleanup
  or reconstruction does not remove the fence or enable another write.
- The server uses one transaction to archive the complete encrypted original
  claim and release receipt, then vacate only its active claim slot. Original
  staff commands and saved model records are unchanged. Archive UPDATE/DELETE
  triggers preserve evidence; encryption/audit failure rolls back the transaction.
- The released store cannot prepare or confirm the command again, even with a
  new operation ID. Released claim and handoff operation IDs cannot be recycled
  for a new preparation. Every prior handoff for the command is validated before
  allowing a new preparation. History is bounded to 32 releases per command;
  reaching the limit requires review, never automatic history deletion.
- Lost replies retry the exact original operation and return its historical
  release receipt, even after another store claims or publishes the update.
  Receipt validation includes the original owner, request and nonregressing time.

The local fence is a cooperative native-client guarantee, not remote attestation
against a modified client or protection from arbitrary host compromise. It does
not claim that a server lease can stop an offline private-store write.

## Recovery and legacy limits

An interrupted fence/receipt/queue write retains all original evidence. Corrupt
fences or receipts fail closed. Changed accounts cannot complete a local cleanup
under another account. An unresolved release is retried on later field sync.

If office data changes after the fence is saved but before the release is
accepted, the fence remains in force. The original owner can freshly review and
choose **Keep Office Value** while the original claim is still current. That
closes the command without any model write and retains the fence. It cannot
resolve another device's new claim or silently cancel an accepted handoff.

Legacy journals have no before-save proof and are not upgraded by guessing that
no model save occurred. Already-saved, attempted or uncertain edits retain their
original-device apply/confirmation/Keep Office recovery. Same-owner observation
of an already-published value remains available separately. An unavailable old
device with an unproven prepared claim is still a recovery requirement; it is
not falsely declared safe for unilateral takeover.

## Verification and promotion

Tests exercise file-backed SwiftData save boundaries, every local handoff write
interruption, queue reconstruction, corrupted fences, lost release replies, newer
claims, authority changes, rejected-release resolution and exact native/backend
wire interoperability. HTTP tests exercise another store's prepare/publication,
immutable original history, revoked roles, stale values, exact routes, malformed
payloads, clock regression and encryption failure.

Qualification evidence is retained at
`/Users/gunnaire/Downloads/GunnAire Ops Releases/Staff Handoff.ZMWZm8`.
Final run outcomes are recorded there after completion; this document alone is
not proof of passing tests or deployment.

Promote matched app/backend versions. Old native readers reject the new journal
fields/states; do not mix old and new processes against one private store.
Independent-account physical CloudKit acceptance, deployment/schema/signing,
real iPad/iPhone handoff and broader QBO/Google/payment integration acceptance
remain required. The full business-suite goal remains ACTIVE. No production
provider writes, screens, visible launches or deployment are part of this slice.
