# Storage rotation release gates

This change prepares compatible storage readers. It does not rotate live keys on
startup, run a production migration, alter provider credentials, or send jobs.
Absent the new keyring variables, existing single-key writes remain unchanged.

## Stages

1. Preserve a fresh verified database/document backup and protected custody of
   each existing key. Old backups require their original keys indefinitely.
2. Deploy the reader implementation with existing settings. Verify the exact
   deployed commit and normal reads. Preserve this both-key-capable build as the
   rollback target; the earlier single-key builds cannot read versioned writes.
3. Prepare distinct new keys in protected custody. Configure each domain's
   `GUNNAIRE_*_STORAGE_KEYRING` with version 1, both keys, active `old`, and
   write_format `legacy`. Verify every process reads both keys while writes
   remain compatible with the existing legacy key. Do not log settings.
4. Only after reader rollout is verified, activate new-key/versioned writes.
   First establish exclusion of all old writers and in-flight provider calls.
   A SQLite transaction does not fence an OAuth refresh that already changed a
   remote refresh token. Do not run the offline batch primitive on a live service.
5. Rehearse and execute bounded migration under verified writer/provider
   exclusion. Preserve historical and terminal rows, NULLs, realm/environment,
   authorization and integer revisions, queues, audit and idempotency state.
   Reconcile any current writes; never restore an older database over them.
6. Verify every ciphertext family from the beginning, including normal service
   readers and exact plaintext preservation. Persist progress only after a batch
   commits; a failed batch rolls back. Complete another from-zero scan before
   removing old readers. Resume is safe only while writer exclusion still holds.
7. Client-held mail and billing pagination cursors are not database rows and
   have no legacy expiry. Old cursors remain usable during overlap. Retirement
   deliberately requires users to refresh old pagination; it must not replay
   business writes. Do not describe overlap as completed key retirement.

## Compatibility safeguards

The storage envelope is inside standard Fernet encoding, retaining canonical
base64 cursor syntax. Its authenticated domain and key ID bind the reader.
An authenticated stable revision preserves original document-upload/link-review
approvals when ciphertext changes; their existing identity and hash checks stay
in force. A migrated roster gets its matching local ciphertext hash in the same
transaction without changing its business revision. Google mail fingerprints
accept both keys during overlap and migrate atomically with original payloads.
CloudKit's inner key, nonce, AAD and published bytes remain unchanged.

Push token decryption failure now preserves the device and pending delivery,
including attempt counts. It is not treated as a provider rejection.

`storage_rotation.migrate_batch` is an offline primitive, not a live migration
runner. It has no provider clients, network calls, queue reset, pruning or
automatic retries. It limits rows and input bytes per transaction. A caller must
provide a row-factory connection and independently establish exclusive ownership
of its offline database. Oversized or corrupt cells fail closed.

## Protected custody and transfer

`Tools/storage_rotation_custody.py` creates a fresh owner-only directory and
file, rejects symlink traversal/overwrite, retains original recovery keys and
produces old-write reader configurations. Its caller must first verify that the
parent is private and not synchronized/shared, including applicable ACLs.
Synthetic tests verify the helper; actual protected custody status is recorded
only in the private release packet, outside this repository.

This helper does not transfer credentials to Render or provider consoles.
No authenticated first-class API credential is currently established for that
operation. Browser credential replacement requires the user's entry and
submission under the Computer Use handoff policy. Do not capture secret-bearing
forms, extract browser credentials, or put values in tool arguments or logs.

## Outstanding production gates

- Independent review and exact-source Linux quota validation, unchanged gates.
- Secure supported transfer or user-operated credential entry, with no secret
  snapshots. Provider replacement and verification remain separate per provider.
- Fresh backup/custody and demonstrated live process/provider exclusion before
  any ciphertext migration; the offline primitive alone does not satisfy this.
- A tested both-key rollback deployment and current-data rollback procedure.
- Apple multi-capability/key-consumer reconciliation; Google exact-client match;
  an authoritative Intuit secret/verifier rotation procedure preserving events.

No provider key has been generated, revoked, replaced or submitted by this change.

## Review corrections

Verified replaced-device tombstones retain their empty token only when inactive
and their replacement fingerprint binds the same device ID. Empty active or
malformed tokens still fail migration. APNs accepts a validated new-only keyring
without retaining the exposed legacy key variable.

The unchanged baseline server workload is supplemented by a separate activated
storage-envelope workload: 45 waves of 64 concurrent 1 MiB writes/readbacks,
followed by bounded migration and new-key-only verification. It uses the same
512000000-byte kernel cap, zero swap, half CPU and 409600000-byte headroom gate.
It is crypto allocation evidence, not a claim of combined server E2E coverage.

## Live exclusion support

`rotation_gate.RotationGate` holds a shared file lock around complete GET/POST/
DELETE handler operations and both runtime background workers, not merely their
SQLite transactions or HTTP provider calls. An authorized local operator creates
an exclusive freeze marker, stops new business requests before authentication
writes/claims, and waits for existing operations (including refresh persistence)
to finish. Health remains available; webhook ingress gets 503, never a fake ACK.
Startup database initialization also respects exclusion. Do not restart/deploy
while the operator holds a freeze: startup fails closed in that state.

A failed drain removes only its owned marker. A migration failure after entry or
operator crash leaves the marker for explicit recovery; do not blindly remove it.
All deployed writers must first be verified to run gate-aware code with the
intended new-write configuration. File locking cannot fence an older application
or unrelated external database writer. No production freeze/migration is automatic.

## APNs replacement compatibility

The backend accepts optional `GUNNAIRE_APNS_PRODUCTION_KEY_ID` and
`GUNNAIRE_APNS_PRODUCTION_PRIVATE_KEY_BASE64`, plus corresponding
`GUNNAIRE_APNS_SANDBOX_KEY_ID` and `GUNNAIRE_APNS_SANDBOX_PRIVATE_KEY_BASE64`.
Each environment falls back to the existing combined-environment key only when
its new pair is wholly absent. A partial pair fails closed. Signing and token
caches are environment-specific; team/topic restrictions remain unchanged.
Both environments must remain configured. Existing multi-capability key consumers
still need reconciliation before that old provider key can be revoked.
