# Encrypted staff CloudKit delivery — September 9, 2026

## Scope and remaining application work

Backend `2026.09.09.49` and the native delivery coordinator connect already
prepared `core-field-v1` projections to accepted private staff shares. This is
CloudKit SDK transport code tested through injected I/O using real records,
assets and cryptographic types. No live CloudKit operation was performed.
The service is callable, but not yet scheduled or presented as a completed staff
workspace. The existing private owner-store gate remains unchanged.

Source bootstrap/change history, field-edit reconciliation, atomic imports into
an independently registered store, full business-domain schemas, background
delivery/subscriptions and signed cross-account acceptance remain required.
Staging is not an applied business-store checkpoint. See the preceding
[source authority and schema coverage](STAFF_REPLICA_DELIVERY.md) checkpoint.

## Server-owned sealing and current key authority

Two GET routes extend
`/api/workspace/staff-shares/{membershipID}/projections/{operationID}`:

- `/cloud-payload`: active Admin only; original metadata, seal version 1,
  AES-256-GCM key and sealed bytes. The native caller also requires a verified
  private owner store and the actual bound Apple owner account.
- `/cloud-key`: that current member or Admin; original metadata and key, never
  plaintext or sealed business data. Original packaging must exist. Staff receives
  the asset through Apple's shared database, not a business-data HTTP bypass.

Both recheck session, membership/approver revisions, company/environment/replica
binding and assignment authorization sequence transactionally. Assigning away
and back cannot release an older key. Ordinary content edits may leave an older
in-flight snapshot authorized; its source sequence stays explicitly old.

Projection creation atomically stores one random 256-bit key and 12-byte nonce
with the immutable snapshot, encrypted using the existing server payload key.
They are one backup/restore unit. Reads never generate keys. Retries recover the
original pair; corrupt or missing keys never silently produce a replacement.
Pre-sealing legacy snapshots without a key remain retained for reviewed recovery
or a newly prepared snapshot, not opportunistically upgraded on read. The exact
original plaintext size/hash is verified before sealing, so the pair is never
reused for different plaintext. Wire bytes are nonce + ciphertext + 16-byte tag.
Authenticated data binds a version marker, company, environment, replica,
membership, member revision, projection policy, original operation, source and
authorization sequences, and plaintext SHA-256. Key release/packaging is audited;
audit failure commits nothing. Whole-database backups include the additive key
table and still require the existing encryption key for recovery.

CloudKit receives neither plaintext nor the per-snapshot key. An old share link
alone cannot decrypt a retained asset. Revocation cannot erase data or keys a
previously authorized recipient already copied; offline/revoked staff-store
handling still needs implementation and signed-device acceptance.

## Native original-operation recovery

An encrypted company/account/actor-scoped journal is saved before CloudKit I/O.
Each original operation has an immutable asset record under the existing shared
root; a schema-specific head points to its manifest. Asset/head are saved
atomically with `ifServerRecordUnchanged`. Conflicts have no unbounded retry loop;
old/equal-sequence different operations cannot overwrite a newer head. Lost
replies recover exact original records, manifests and bytes without another copy.
No share participant, root, SwiftData internal zone or unrelated record is changed.

Live checks bracket network operations: current business identity and share plan,
Apple account generation, accepted private/read-only membership and projection
authority. The participant derives the shared-zone owner from Apple's metadata,
reads the head/asset, obtains and rechecks its current key, decrypts using CryptoKit
and verifies the exact original envelope/hash. Downloaded staging URLs are read
immediately with a bound; they are never persisted or deleted by this code.
Owner temporary files contain only ciphertext and are removed after awaited I/O.

Participant staging is encrypted, atomic, monotonic and separate from publisher
journals and pending field work. No operational models are imported or enabled.
Existing encrypted time/setup stores retain their 1 MiB default. The additive size
parameter permits a 24 MiB local envelope for the bounded 16 MiB CloudKit payload
and JSON/base64 overhead. Wrong-key/corrupt/oversized journals remain for recovery.

## Verification

Evidence: `/Users/gunnaire/Downloads/GunnAire Ops Releases/Staff CloudKit Delivery.DTOCKY`.
The initial unsealed implementation passed 18 focused Mac tests and was never
published to CloudKit. Its encrypted successor passes 20 focused Mac tests and
11 initial backend HTTP/crypto tests. Final recovery review moved key creation
into the same transaction as projection creation; the expanded focused suite
passes 13 cases. The final full backend suite passes 852 cases, including all 14
new transport cases and the recorded native fixture check against the current
backend AAD/crypto contract. All 69 Tools cases also pass again on final source.

The final native source passes 1,650 Mac logic cases and 1,654 iPad cases (the
same 1,650 logic cases plus Invoice opening, simple Mail and two staff-onboarding
journeys). Exact execution trees verify all selected targets/cases, with zero
failures/skips. Both Mac and iPad open the actual isolated Python backend payload
using CryptoKit, returning eight records whose bytes are identical to the server
and each other (SHA-256 `cef5661a29eb687406c7584080c64b1c8ae15f4dd1e6bfa2fa5ab8363a13bbda`).
The exported records also pass the Python field contract. The fixture key is
public synthetic test data, never a production secret.

Unsigned universal arm64/x86_64 Mac and arm64 iOS Release builds pass with actual
binary architecture verification. Three current iPad screenshots were visually
inspected; the simple inbox and original invitation/recovery sheets have no
account-email footer. Existing unrelated document-concurrency/optional Metal
warnings remain unsuppressed; there are no new transfer-specific warnings.
All 69 Tools tests and both workflow lint checks pass. Original preflight covers
14 scoped files, verifies 339 other tracked sources match, and retains the
original branch/HEAD/index plus 310 unrelated changed files. Final copy-back
verifies all 14 scoped files match and all 310 unrelated changes, the original
branch, HEAD and staged index are preserved.

The preceding published head `4a865d9` has passed all hosted Backend/Mac/iPad jobs.
This new source requires its own hosted checks after publication. No main merge,
production deployment, signing/entitlement/schema promotion, physical install,
customer send, accounting/payment write or vendor order occurred.

## Primary references read in Safari

- [Apple CKAsset](https://developer.apple.com/documentation/cloudkit/ckasset):
  asset association and staged file lifetime.
- [Apple CKRecord parent](https://developer.apple.com/documentation/cloudkit/ckrecord/parent):
  shared hierarchy and required `.none` parent reference action.
- [Apple CryptoKit combined sealed box](https://developer.apple.com/documentation/cryptokit/aes/gcm/sealedbox/combined):
  nonce/ciphertext/tag representation.
- [Cryptography AESGCM](https://cryptography.io/en/latest/hazmat/primitives/aead/#cryptography.hazmat.primitives.ciphers.aead.AESGCM):
  key generation, unique nonces, authenticated data and tag validation. Local
  backend tests use Cryptography 45.0.7 and its stable AESGCM APIs.
