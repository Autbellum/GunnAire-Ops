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

The v2 inner envelope stores a bounded JSON metadata header followed by raw
plaintext, all authenticated by one Fernet token. It avoids encoding the payload
in base64 twice. Readers retain v1 JSON-envelope support and stable revisions.
This does not change public cursor encoding, workload size or memory gates.
Both supported server entrypoints share keyring validation and startup exclusion;
local-AI model execution and subsequent audit persistence hold one operation lock.
Freeze-marker creation and removal fsync the parent directory.

## Protected file transport

For an operator with existing authorized SSH access, `GUNNAIRE_STORAGE_KEYRING_FILE`
can name an absolute private file containing the custody bundle shape
`{"version":1,"readers":{"qbo":{...},"google":{...},"push":{...}}}`.
This transports storage encryption settings only, never provider authentication.
The immediate parent must be owner-only 0700; the regular file must be owned by
this process user and mode 0600, at most 16 KiB. Every path component rejects
symlinks. All three keyrings validate before any global setting changes, database
initialization or worker startup. Explicit environment keyring overrides conflict
and stop startup rather than silently taking precedence. With no file path,
existing environment configuration is unchanged.

Transfer through the already-authorized SSH connection with stdin, never command
arguments or terminal output, to an atomically replaced private file outside the
application's database/storage backup roots. Keep old/new recovery custody on the
approved private Mac destination. Set only the non-secret absolute path in Render
with Save only; then deploy the exact tested reader-capable SHA. Reader staging
keeps `active=old,write_format=legacy` and the existing three legacy variables.
Verify the running process uses the prepared settings before writer activation.
File changes require a process replacement; never assume a running process reloads
keys. A missing/insecure/invalid explicit file intentionally prevents startup.
No file or setting is installed by this module; no credential is generated.

V2 writes require every serving process and the selected rollback build to read
v2. Earlier dual-reader commits 78ba9c0, d8901f8 and ed1d6d8 do not understand this
inner format and are not rollback candidates after activation. When using file
transport, the rollback build must also load the protected file. Keep current
DB/storage and both keys; never restore an old database over post-cutover writes.

Text-facing keyring APIs hold admission across UTF-8/ASCII encode, authenticated
crypto and decode. The 64-caller workload still retains all caller results until
its original barrier. Workspace source POST admission precedes body parsing and
holds through response; a bounded 250 ms wait preserves ordinary small concurrent
replays, followed by honest 503 on sustained overload. Clients retain the pending
operation. Ordinary migration rotates once; separate plaintext is read only for
the Google-mail fingerprint dependency.

Crypto admission now submits to one reusable allocation worker while retaining the
caller-side semaphore. Only one operation can be queued/running. This prevents
crypto temporaries being allocated independently on every caller thread; it does
not shorten caller payload/result lifetimes or alter their concurrency barrier.
No database or provider operation runs on that worker. Exact Linux validation is
required; source reasoning alone does not establish memory headroom.
