# Staff CloudKit receipt and import boundary

Candidate, September 9, 2026. This connects actual receiving into the encrypted
stage; it does **not** complete a technician's operational workspace. An accepted
invitation, transport receipt, or complete `core-field-v1` payload cannot open the
owner's private store or stand in for the full application's 32-model schema.

## Implemented receiving path

- The staff request detail automatically reads the original accepted invitation
  while foregrounded. The company gate independently recovers that same invitation
  from encrypted setup storage and checks for shared data. Reads repeat at bounded
  intervals, with an explicit Check Shared Data action for recovery.
- Current business login, original iCloud identity, active member role, original
  share, plan revision, source sequence and authorization sequence remain separate
  checks. Freshness is required both before key acquisition and before staging.
- Actual shared-database CKAsset bytes are decrypted through the existing delivery
  path, checked against the exact manifest, and validated as a typed core graph
  **before** replacing an existing encrypted stage. Unknown fields, wrong scalar
  types, missing parents, cross-customer relationships, excess scope and purchasing
  cost outside Admin are rejected. An invalid newer graph retains the earlier
  staged bytes exactly. Optional nulls remain absent, not invented field values.
- Field Technician projections require their exact active profile, assigned jobs,
  their related customers/properties/equipment/crew, and approved/archived catalog
  or their own pending items. Standard and Accounting receive no implicit core
  entitlement; they still require their own complete domain contracts.
- Account replacement, cancellation or a replaced view cannot restore a previous
  received state. Task identity compares the typed original plan, full session,
  account generation, invitation and foreground state directly; unordered JSON
  hashes must never trigger background read loops.
- Status explicitly says that full workspace data is still required. Ordinary
  invoice, mail and job screens do not gain transport payloads, technical panels or
  account-email footers. No ModelContext import or operational lease is issued.

## Full operational import remains required

The existing `GunnAireModelSchema.schema` has 32 models. Current core snapshots
cover selected fields from only six, and flatten lead/additional technician
identity. Copying them into those models with defaults would silently invent
facts and imply absent domains are empty. Do not activate that substitute.

| Required domain | Remaining staff import/reconciliation work |
| --- | --- |
| Customer, property, equipment, job and crew | Complete field semantics, explicit lead/additional crew, linked equipment/service history and relationship-complete atomic import |
| Catalog, inventory, suppliers and procurement | Complete approved catalog/QBO identity, inventory movements, purchase orders and role-protected cost/vendor fields |
| Estimates, invoices, payments and project milestones | Exact immutable sold lines, taxes/discounts, balances, shared publication/payment receipts and original job/customer/item lineage |
| Agreements and recurring service | Contracts, visits, renewal/completion state and original work relationships |
| Scheduling, availability and time | Shifts, blocks, leave, availability events, time entries and approved shared time receipts |
| Service requests, job activity and operational alerts | Assigned and historical work with role-filtered append-only events and conflict ownership |
| Forms, media and communications | Templates/responses, attachment content and metadata, related transaction emails/invoices and original file lineage |
| Fleet and expenses | Assigned assets/events, expense receipt content and office review state |
| Tasks and app users | Current role-appropriate task/event projection; server membership remains identity authority, not imported AppUser rows |
| Store lifecycle and field edits | Independently registered encrypted local store, atomic full snapshots/checkpoints, durable mutation queue, conflicts and retained unsynced work across logout/reassignment/revocation |
| Acceptance | Signed independent-iCloud-account iPad/Mac convergence, offline recovery, full role/navigation/accessibility journeys, production provider/vendor and physical iPhone Handoff/payment acceptance |

All rows remain part of the full goal. Read-only core transport is not a replacement
for field invoicing, item creation/sync, full HVAC workflows or CloudKit continuity.

## Verification

Evidence directory:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/Staff Receipt.xPKL2I`.

Final-source local qualification is complete for this receiving checkpoint:

| Evidence | Result |
| --- | --- |
| `MacFull2.xcresult` | 1,710 actual cases verified; complete logic target, including 11 receipt cases |
| `IPadReceipt3.xcresult` | 12 actual cases verified; 11 receipt cases and the exact original staff recovery journey |
| `IPadFull2.xcresult` | 1,714 actual cases verified; complete logic target plus staff owner review, staff recovery, invoice crash guard and simple shared Mail journeys |
| `BackendFull1.log` | All 852 cases pass, 128.115 seconds |
| `Tools2.log` | All 70 cases pass, including native/server required and optional field/type parity |
| Workflow lint and `git diff --check` | Pass; no workflow edit or coverage removal |
| `MacRelease1.log` | Unsigned Release succeeds; arm64 and x86_64 verified |
| `DeviceRelease1.log` | Unsigned generic iOS Release succeeds; arm64 verified |

Native results have no failures/skips in the passing final runs. Authoritative
`xcresulttool` summaries and test trees were checked with
`Tools/verify_native_test_execution.py`, including the four exact UI selectors.
The iPad destination is the 13-inch M5 simulator, iOS 26.2,
`147D4CB6-85CC-4B17-BD35-8684E60E672D`. Mac uses arm64 Mac Catalyst for tests;
all commands use the shared GunnAire Ops scheme and `CODE_SIGNING_ALLOWED=NO`.

Unsigned binary SHA-256:

- Universal Mac: `1eeca1466a357d80c1c83fecc3fbe882cf6f4646a3c5695d4d1d129ef71eb440`
- iOS device: `23eeda6760ca36912abf394b3620ada1981b2c8c90294b6da0b2866aed1ddbb5`

Existing QuickBooks document actor-isolation warnings and the Mac host's optional
Metal search-path warning remain in the retained logs; they are not cleared or
represented as new receiving failures. Three exact-current-source screenshots
were visually inspected: receiving/retry state, simple Inbox, and original owner
change comparison. Controls and text remain readable, with no account-email footer.
Images are under `ReceiptReview`, `FinalMail`, and `FinalStaff` in the evidence
directory.

Earlier failure evidence is retained:

- `IPadFull1` completed with 1,712 passing cases and one failed staff-receipt UI
  journey. Failure activities and the UI hierarchy show the synthetic first read
  failure had already become a success before the explicit recovery tap. The new
  task identity used unordered JSON, allowing display changes to trigger rereads.
  Typed request equality replaces that unstable identity without changing the
  fixture's one-failure behavior or weakening the original assertions.
- `IPadReceipt2` failed at compilation because the added identity regression used
  an optional fixture stamp without unwrapping it. `#require` corrects the test
  setup; no case or assertion was removed.
- `MacFull1` verified 1,709 actual test cases before the identity refinement. This
  earlier pass does not qualify the final source; reruns are retained separately.
- The native receiver test uses actual CKRecord/CKAsset types, file-backed
  encrypted assets and an in-memory journal adapter. The complete native target
  separately exercises the disk encryption adapter, large assets, wrong keys and
  bounds. The server interoperability test opens real Python-generated encrypted
  payload bytes. These component tests are not signed CloudKit service acceptance.
  UI-only receipt fixtures are Debug/test-database/exact-fixture
  scoped and never authorize a production store or perform Apple/provider I/O.

## Release boundaries and references

`OriginalPreflight1.json` freezes all scoped source bytes and covers 14 copy-back
paths, 333 unrelated changes and 353 other identical tracked sources. Copy-back
must preserve the original `codex/internal-team-tasks-20260830` branch, HEAD
`ff2189c3dfe9cc2d3e2ca79cbf1a6b53572aa45c` and index.

PR #18 remains open on published head `3a6d94a`. Its Backend run `34338126897`
has passed; native run `34338126967` was still in progress at the final read.
This candidate is committed locally, not pushed over that live run: the workflow
would cancel it on another push. Final new-head hosted acceptance remains required.

No entitlement, signing, production schema, live CloudKit/provider/customer data,
payment/accounting record, deployment or main merge is changed by this candidate.
Hosted CI and signed independent-account acceptance are separate evidence gates.

Apple's [progress guidance](https://developer.apple.com/design/human-interface-guidelines/progress-indicators)
was read in Safari on September 9: transient status, periodic automatic updates
and a user-triggered refresh inform the compact receiving UI. The existing
[CKAsset](https://developer.apple.com/documentation/cloudkit/ckasset) transport and
[CloudKit transport checkpoint](STAFF_CLOUDKIT_TRANSPORT.md) remain in effect.
