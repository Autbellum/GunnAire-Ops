# Owner field-edit resolution and wire interoperability

## Delivered behavior

The secondary Field updates review now offers **Keep Office Value** alongside
the existing explicitly reviewed application action. Keeping a value does not
write a model field, undo a previous office edit, delete the technician's update,
or alter an original prepared application receipt. It records a separate owner
decision, makes the command ineligible for later application, and removes it
from the active owner inbox after durable confirmation.

Prepared edits can be resolved only by their original owner account and store.
Current tenant/admin authorization is checked on every request. Staff revocation
does not stop that owner from retaining an original without applying it.
Already-published edits cannot be reclassified as kept office values.

## API and original evidence

POST `/api/workspace/field-edits/{commandID}/keep-office` accepts the closed
`staff-owner-field-resolution-v1` contract: company/environment/replica, command,
stable decision operation, original store, original claim operation (empty only
when unclaimed), expected source revision and exact saved field value.

The server transaction checks the current field and claim, encrypts a separate
immutable decision, and returns its exact request, owner, resolution time and
`keptOffice` outcome. A retry returns the same original receipt even if later
office data changes. Altered requests, reused identities, other devices, stale
reviews and published commands fail closed. Original preparation, staff author,
time, value and receipt remain queryable. Malformed or inconsistent decisions
cannot silently hide originals from the paged inbox.

An inbox page contains at most 50 scanned commands. A fully resolved page can be
empty while still carrying a continuation cursor. The native worker processes
at most eight originals per pass and propagates its remaining backlog into the
owner sync continuation flag, without repeatedly spinning on completed pages.

## Native recovery

The keep decision is saved in the encrypted active journal before its first
POST. The exact acknowledged decision and any original application intent are
then written to a separate encrypted immutable history file before active-queue
cleanup. Tests exercise failures both before and after each of those writes.

A lost reply, account change, newer unsaved draft or restored older journal does
not permit a model write. The original device can recover the exact decision
from the authenticated server receipt without generating a replacement ID.
A corrupt history file is retained and reported; it is not overwritten to make
recovery appear successful.

If an unacknowledged decision becomes stale, another explicit review can replace
it only after a fresh server observation proves the old request cannot pass:
the monotonically increasing source revision advanced, or its originally absent
claim became an immutable prepared claim. The superseded original and that
fence are archived before the replacement is journaled. No in-flight decision
is silently rebased or discarded.

## Wire-format correction

Actual Python HTTP responses include explicit `null` for optional cursors,
current records, application receipts and publication timestamps. Native
Swift-only round trips had omitted those keys, masking a strict-decoder mismatch.

`StaffOwnerFieldEditWire` now normalizes only these documented optional positions
when comparing the received JSON with the typed re-encoding. Unknown keys,
unknown nulls, required-field nulls, duplicate keys, invalid types and oversized
payloads remain rejected. Legacy encrypted owner journals still decode. Receipt
chronology is checked against the original staff and preparation times.

`Backend/generate_staff_owner_field_edit_wire_fixture.py` captures real isolated
HTTP responses into the bundled `StaffOwnerFieldEditWireInterop.json`. Backend
tests compare its contract to current HTTP output; native tests decode the same
fixture. The full owner model workflow tests now use Python-style optional nulls.
The sibling full-workspace page already explicitly encodes its nullable cursor;
the shared strict decoder was not weakened globally.

## Scope still unverified or incomplete

Cross-device claim takeover/release, removed-record disposition, staff-facing
owner-decision status, and additional conflict outcomes remain separate work.
Keep Office Value does not claim physical CloudKit convergence, QBO publication,
payment acceptance, or complete multi-device handoff. Independent-account device
acceptance, matching backend/native deployment, parallel UI qualification, live
Google/QBO/vendor workflows and Tap-to-Pay acceptance remain release gates.

The full application goal remains active. Verification uses background commands,
file-backed model tests and headless iPad unit tests; no screen capture, visible
app/browser interaction, signing, push, deployment or live customer/provider
mutation is performed. Evidence is retained under
`/Users/gunnaire/Downloads/GunnAire Ops Releases/Owner Edit Resolution.RoDA1z`.

The explicit action label and confirmation follow Apple's
[alert guidance](https://developer.apple.com/design/human-interface-guidelines/alerts).
Visual/device acceptance is not inferred from code or model tests.
