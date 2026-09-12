# Full owner workspace source — local qualification, 2026-09-09

This checkpoint adds a real, authenticated backend endpoint for preserving all
32 native model kinds under `owner-workspace-v1`. It does **not** enable automatic
full-model uploads, full staff access, a staff-store lease, financial actions,
CloudKit delivery, or provider writes. The existing six-kind `core-field-v1`
ledger, owner journal and role-filtered staff projection keep their original
meaning. Full owner publication/reconciliation is the next integration step;
full-domain role projection, importer, commands, media and independent-account
signed-device acceptance remain required.

## Evidence and contract

Evidence directory:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/Full Workspace Source.jXImTQ`.

`Reproduction1.log` records the actual HTTP 404 from requesting the missing full
owner source with an approved isolated company and its real replica ID. This was
not an import or fixture failure.

Native field factories now expose their actual wire primitive, optionality,
owning reference kind and the two typed job enum value sets. The metadata does
not change field encoding, model defaults or stored values. The native catalog
contains 32 kinds and 561 fields. `Interop1` exports both the typed catalog and
all 32 serialized synthetic models into retained XCTest attachments. Those
exports are the origin of `Backend/staff_workspace_schema_v1.json` and
`Backend/fixtures/full_owner_native_v1.json`, not a separately guessed mapping.

Current canonical schema SHA-256:
`d713a48445601f87bff3a47f101bd2173793fdc0d405f3a547851df5a9e4c6d3`.

`StaffWorkspaceSourceInterop.json` is a test-bundle resource generated from the
actual local HTTP POST and GET handlers using those original native records.
Native tests verify that the current catalog still matches its schema and
digest, decode the real response, compare every original field, validate the
relationship graph, reconstruct detached models and re-encode them without
changing original values. Backend tests independently compare the test-bundle
resource with the current server contract, the original native fixture and a
fresh HTTP response. A change on either side must update and requalify the
contract explicitly. Never silently regenerate fixtures to hide a failure.

## API and authorization

The exact endpoint is `/api/workspace/full-records`.

- GET requires `companyID`, `environment` and the expected `replicaID`. Optional
  `sequence` fences a read; `after` is permitted only with that sequence.
- POST requires those three scope fields plus `schema`, `schemaDigest`,
  `operationID`, `expectedSequence` and `changes`.
- Each change has exactly `kind`, lower-case UUID `id`, `expectedRevision`,
  `action` (`upsert`, `delete`, `restore`) and `fields`.
- All known field names must be present. Values use the actual Swift Codable
  tags (`text`, `number`, `integer`, `flag`, `date`, `identifier`, `null`), with
  exact tag members and no unknown-field fallback. Dates retain Foundation's
  reference-date seconds; field UUIDs retain native upper-case encoding.
- Active application sessions are required. The database transaction rechecks
  the current active Admin role, session validity, actual company identity,
  approved environment binding and original replica ID. Dispatcher, field,
  accounting and standard roles cannot read or write this owner archive.
- Schema/digest mismatch and changed replica fail closed. A successful owner
  archive request does not grant a staff membership or authorize accounting.

Responses carry the schema, digest, company, environment, replica and sequence.
Record versions carry their revision, retained-deletion flag and original typed
fields. Receipts bind the original operation, ordered exact change identities,
revisions and deletion flags, plus the current sequence when an older operation
is replayed. Client publication must verify this entire contract before
acknowledging any local work; that client integration is not yet implemented.

## Persistence and recovery boundaries

Three new, additive `staff_workspace_source_*` tables separate heads, encrypted
records and encrypted immutable receipts. Every source key includes an explicit
schema namespace. Initialization does not alter, migrate or relabel legacy
six-kind rows. No deployment or production database change occurs here.

Record ciphertext includes its exact company/environment/replica/schema,
digest, kind, original ID, revision and deletion state. Receipt ciphertext binds
the exact actor and request hash as well as its acknowledgement. Corruption or
ciphertext substitution fails closed; the original row remains for recovery.
Existing configured authenticated encryption is required; plaintext fallback is
rejected. Audit failure and encryption failure roll back the whole transaction.

Each batch uses `BEGIN IMMEDIATE` and one durable original operation ID. Exact
concurrent or lost-reply retries acknowledge the same operation once. Altered
body, actor or scope cannot adopt that identity. Stale source/record revisions
reject the entire batch. Deletes retain the old fields; ordinary upsert cannot
resurrect a tombstone. Restore is an explicit revision-checked action.

Limits: 100 changes, 8 MiB request body, 2 MiB per original change, and 8 MiB per
actual HTTP response. Unicode response sizes account for the handler's ASCII
escaping. A short page can therefore have a next cursor even with fewer than
100 records. Retained records, including tombstones, are bounded at 100,000;
encrypted source storage is bounded at 64 MiB. Capacity rejection is atomic,
not automatic deletion or silent truncation. Archival/compaction and immutable
operation-receipt retention still need a coordinated production policy.

Incremental archive batches can contain unresolved references. This endpoint
validates the typed transport shape and primitive bounds, **not** all nested
JSON, domain enums, financial semantics, staff visibility or whole-snapshot
lineage. Those checks belong to the full-domain projection/import and mutation
boundaries and cannot be skipped because an archive request succeeded. No
private record from these tables is reachable through the old staff projection.
Local media paths remain excluded by the existing native catalog; original
attachment byte synchronization is a separate unfinished requirement.

## Qualification record

| Evidence | Result |
| --- | --- |
| Reproduction1 | Expected failure: authenticated full owner GET returned 404 |
| Interop1 | Passed: 1 native export test, all 32 kinds/561 fields |
| BackendFocused1 | Passed: 27 tests |
| Interop2 | Failed compilation: missing SwiftData import in the new test |
| BackendFocused2 | 28 passing / 1 error: oversized-body test's urllib sender hit a broken pipe after early server rejection |
| Interop3 | Passed after adding the defining module import; real native/backend schema and relationship round-trip |
| BackendFocused3 | Passed: 29 tests, including header-only verification of oversized Content-Length rejection |
| MacFull1 | 1,877 passing cases / 6 verified selectors, no failures/skips |
| IPadFull1 | Failed: 1,880 passing cases, two actual interoperability-test crashes, no skips |
| BackendFull1 / Tools1 | All 881 backend / 74 Tools tests passed |
| MacRelease1 / DeviceRelease1 | Both unsigned Release builds and architecture checks passed before the crash correction |
| IPadInterop1 | Graph cleanup corrected; export/digest pass, detached resolver cleanup still crashes |
| IPadInterop2 | Passed: all three original synchronous interoperability tests, no failures/skips |
| MacFull2 | Corrected candidate passed: 1,877 cases / 6 verified selectors, no failures/skips |
| IPadFull2 | Corrected candidate passed: 1,882 cases / 11 verified selectors, no failures/skips |
| DeviceRelease2 | Corrected unsigned arm64 iOS Release build and architecture check passed |
| MacRelease2 | Corrected unsigned universal arm64/x86_64 Mac Release build and architecture checks passed |

The oversized-body test now sends only headers and reads the server's actual
400 response before any body is consumed; it does not catch a client transport
failure and call that a pass. The initial failures remain in evidence.

### Synchronous iPad cleanup crash

The new synchronous native HTTP tests expose an actual iPadOS 26.2 memory abort,
not a failed assertion: `swift::TaskLocal::StopLookupScope` through
`swift_task_deinitOnExecutorImpl` when releasing the temporary
`StaffWorkspaceRelationshipGraph.Components` class. Exact crash summaries are
retained in `GraphCrash1-summary.json` and the failed xcresult. Converting the
per-validation union/find state to a value type lets the original export test
pass, but the unchanged detached round-trip then exposes the same abort in
`StaffWorkspaceModelResolver` cleanup (`ResolverCrash1-summary.json`).

Both helpers now use value storage. Resolver mutation is explicit `inout` through
the typed codec and catalog, and existing tests are updated only for that calling
convention. Main-actor protection, field and graph validation, missing-parent and
duplicate-ID rejection remain intact. The new synchronous tests and all their
assertions remain unchanged; they are not converted to asynchronous tests to
avoid the failing entry path. The [official Swift deinitialization guidance](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/deinitialization/)
confirms class-only deinitialization; the concrete iPad failure and affected
runtime frames are observations from the retained reports, not an assertion
that all platform versions are affected. The original synchronous tests now
pass on iPad, and full Mac/iPad requalification passes. The iPad run includes
all 1,877 logic cases plus five invoice/Mail/staff setup journeys. Both final iOS
and universal Mac Release builds pass. This is automated regression evidence, not a new
visual/accessibility review or signed physical-device acceptance.

Final iOS Release executable SHA-256:
`cab51392373e613ee4db06dc0911a8c226b2f439121ac58d38aa46eb33b19c5d`.
Final universal Mac Release executable SHA-256:
`9d66a194581ad1ed488197bb2e7914791f3fdda27d4956ed7d656abb0fb90cf6`.
The four pre-existing QBO document-workflow actor-isolation warnings remain.
An existing redundant history-test `#require` warning is also retained. Neither
is silently treated as a clean-warning build or part of this correction.
Mac linking also retains the pre-existing missing Metal toolchain search-path
warning. No new actor-isolation suppression, entitlement or signing change is
used. All local build and test processes completed before source copy-back.

`OriginalPreflight1.json` preserved the initial 12-path candidate. The expanded
`OriginalPreflight3.json` freezes 17 scoped paths, protects 406 unrelated owner
changes, verifies 399 other matching tracked sources and records the unchanged
owner branch/HEAD/index. `OriginalCopyBack3.json` verifies all 17 copied files
byte-equal and all 406 unrelated changes plus the owner branch/HEAD/index
preserved. Only the isolated review checkout is used for staging and commit.
The existing PR18 remains unmerged; publication triggers fresh hosted checks
and does not claim to fix its separately retained inventory UI failure.

### Exact hosted predecessor failure

PR18 head `a0fd766270e2f5100c1f6c87bff13cbeb1120ffa` completed hosted native
run `34411588111`: Mac and iPad group 2 passed, group 1 failed. Its actual
xcresult contains 1,891 passing cases and one failure, no skips. The failure is
`testAdministratorCreatesInventoryOfflineAndReopensExactSetup`, at line 8215:
after entering the opening date, `DoneEditingCatalogItem` is not hittable.
The original log and UI attachments are retained. Mail attachment preview and
forward, failed-send draft retention, trash restore and uncertain-send recovery
all pass on this exact hosted head. The inventory issue is not claimed fixed by
this unrelated source protocol work and still gates release readiness.

The completed-run artifact upload produced four copies with identical digest
and size after upload retries. Exact artifact `10129230618` was selected,
verified as 327,494,545 bytes / SHA-256
`db29a27ea19f00cf0ac6e81773dfc28a0f845ae5200aeba2ce942488b16bf76d`, and safely
extracted into `HostedArtifact`. Its original test remains enabled. No hosted
or local build was cancelled to publish newer code.

The selected API, identity, offline-work, Xcode and reliability skills shaped the
separate versioned namespace, transactional authorization, retained original
requests/deletions, native-generated interoperability tests and staged delivery.
Skill governance is recorded in the live audit. No provider, signing, deployment,
entitlement, live accounting, customer communication or main-branch merge is
authorized by this checkpoint.
