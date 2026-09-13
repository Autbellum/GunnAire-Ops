# Business-session job billing handoff

Candidate backend 2026.09.08.41, following published head c2a66bb. This is an
implementation checkpoint, not a deployment or full-suite acceptance claim.

## User workflow

Saving a crew change must not silently skip field billing because a particular
device lacks QuickBooks OAuth credentials. The native dispatcher now saves the
job and its durable intent using the verified business identity. First-use
offline intent contains no guessed accounting realm or provider grant. The
existing Field Billing link on the original job remains the place to see pending
work, review server access, apply the saved crew, and return to the job.

## Authorization and durability

The new GET `/api/job-billing-assignments/connection?companyID=…` accepts only the
original business ID and an application session. The server checks active
Admin/Dispatcher access, derives its own accounting realm/environment, and
returns protocol version 1 and an opaque authorization revision. It returns no
credentials, roster or customer data and performs no accounting call or write.
Field, accounting, unrelated-business and malformed/repeated-query requests
cannot use this office discovery endpoint. Existing assignment compare-and-set,
active crew-account checks, encrypted roster storage and audit writes remain.

The native shared descriptor is not an OAuth credential or a new permission.
Every network run rediscovers it under the initiating business/workspace/actor.
The descriptor revision is pinned through assignment reads and writes. A grant
replacement cannot silently revive an old assignment. Changing to a different
accounting realm does not move or discard the original queue; the administrator
must review/restore the original business connection before those edits resume.

A new encrypted business-and-office-account bootstrap journal stores first-use
offline intent and the last verified descriptor. Authenticated encryption binds
the file to that account; corruption or unavailable keys never resets it to an
empty queue. Files are device-protected and excluded from backup. The existing
realm-bound journal stays byte-format compatible with earlier pending requests.
Its optional import receipt makes the two-file transfer recoverable: the bound
record and receipt are written before bootstrap intent is removed. Repeating
the transfer cannot resurrect an already completed imported operation.

Prepared intent is written before the local job save. Fresh stored rows, original
customer/crew and the stable edit ID are checked before a server mutation. The
first live save can bind its own still-current intent; first-use recovery after
restart requires visible review. Known offline reassignment retains its prior
revision. Conflicting decisions, missing crew accounts, cancellation, revoked
roles and stale navigation must retain work without a guessed approval or new
accounting transaction.

The approach retains server OAuth management documented by
[Intuit](https://github.com/intuit/oauth-jsclient/blob/master/README.md). The
existing checking indicator follows [Apple's progress guidance](https://developer.apple.com/design/human-interface-guidelines/progress-indicators?changes=_7)
without adding a diagnostic panel to the job.

## Qualification status

Final local qualification passes. Evidence is retained under
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-08/Shared Dispatch.6fom4b`.
Mac and iPad each pass **1,525 logic tests**; iPad additionally passes all eight
selected UI journeys (**1,533 total**), with no failures or skips. The xcresult
test trees independently verify that every selected target/journey executed.
The native focused run passes 46 cases, including all 12 new shared-dispatch
tests. All **652 Backend tests** on local Python 3.9.6 and **56 Tools tests** pass;
both unchanged GitHub workflows pass actionlint.

All eight exported iPad screenshots were visually reviewed. Saved-crew conflict,
confirmation and original recovery remain a compact part of the original job;
Mail has a plain inbox, message, compose and recoverable Trash confirmation.
Original invoice recovery is preserved. No account-email footer or raw API
payload appears; ordinary email sender and recipient fields remain in Mail.

The unsigned optimized Mac Catalyst Release succeeds and the produced binary
contains both arm64 and x86_64. Its SHA-256 is
`5dc7891372bc13d20c5933f1433ce609a098b9f9cce7b76bb106a53cb377f631`.
Existing document actor-isolation and optional Metal-toolchain warnings remain.
Original-project preflight verifies 17 scoped files, 248 unrelated changes, an
unchanged empty index and 290 other byte-identical tracked source files. The
15 changed source/test file hashes are frozen in FinalSourceHashes.json.

The initial backend run's new malformed-ID test expected a different error name;
the corrected test preserves the established `invalid_request` contract.
The first new native-test build required two explicit throwing test-expression
evaluations, and the first Tools invocation used an unsuitable import root.
Those failures remain alongside the corrected results; no assertion was removed.
The published predecessor c2a66bb has hosted Backend success on Python 3.13 and
3.14; its native jobs were still running at the prepublication read. A new head
requires its own hosted qualification.

No merge, deployment, production role/roster mutation, QBO accounting write,
customer message, entitlement/schema change or physical install is part of this
checkpoint. Signed CloudKit convergence and independent staff sharing, approved
real Tap to Pay/Handoff, remaining OAuth-only accounting/catalog paths, vendor
access, and complete ten-comparator HVAC/Google/QBO acceptance remain open.
The business backend must be deployed before distributing this client; an older
server retains saved work and presents update guidance rather than using a
technician's device OAuth connection.
