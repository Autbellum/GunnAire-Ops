# Staff command recovery and bounded document delivery

## Scope and current status

This slice preserves an original technician finding through a lost HTTP reply,
process restart, interrupted local receipt write, and newer company snapshots.
It does **not** apply that finding to an office SwiftData record or an invoice.
`recorded` means retained by the server, not applied or synchronized to QuickBooks.

The subsequent [owner field-edit slice](STAFF_OWNER_FIELD_EDITS.md) adds actual
saved-model application and company-source confirmation. The original recovery
receipt and the remaining physical CloudKit/provider release gates are unchanged.

The full business-suite goal remains active. Independent-account CloudKit/device
acceptance, owner-record command application, parallel navigation changes, and
live Google/QBO/payment acceptance remain separate release requirements.

## Recovery contract

- Current business session, CloudKit account generation, membership, role, share,
  replica, original selection and exact content remain mandatory authority.
- A previously recorded, identical command returns its original author, time,
  request and receipt even after source advancement. A new command against that
  stale source is rejected; original field intent is never silently rebased.
- Staff refresh retries complete write-ahead originals, not fields reconstructed
  from a newer mount. The request ID, selection, revision and value stay intact.
- Each pass attempts at most 16 originals. A durable scheduling cursor rotates
  past a blocked first page. Failed originals remain encrypted and discoverable;
  the sync status reports how many still need synchronization or review.
- Scalar type, nullability, enumeration, identifiers, request size, author and
  timestamp are validated again on recovery. Receipt journals reserve capacity
  for both copies of an HTTP-valid long finding. No global rollback or cache
  clearing discards another person's changes.
- Account changes cannot be swallowed as a harmless full-workspace fallback.
  Visible cached handles are cleared; saved original work remains on disk.

## Document boundaries

Both staff media and ordinary document downloads use the same bounded reader.
It opens beneath pinned directory descriptors, rejects symlinks/special files,
checks file size before allocation, handles short reads, and rejects detected
growth, truncation or writes during reading. The hard read cap is 64 MiB; staff
downloads must also match their prepared attachment size.

Staff media rechecks current authority and the exact document binding after the
read. Shared attachment IDs do not bypass billing-document role restrictions.
Response metadata rejects embedded header controls and invalid MIME types;
ordinary downloads now also use private-cache and no-sniff response headers.

The later [document-content integrity slice](COMPANY_DOCUMENT_CONTENT_INTEGRITY.md)
adds upload-time hashes and native verification to reject same-size replacements
before the first read. Legacy rows remain explicitly unverified; no download or
migration backfills historical evidence from today's file.

## Next application boundary

An owner command inbox must carry original base-field evidence, original author
and timestamp, current share eligibility, and a separate application receipt.
The native owner path must compare the saved office field to that base, preserve
conflicts for review, durably journal before saving, recover a save/reply split,
then publish through the existing source/CloudKit workflow. It must not pretend
that a backend journal automatically updates the owner's live models.

## Evidence

Local evidence is retained in
`/Users/gunnaire/Downloads/GunnAire Ops Releases/Staff Command Recovery.7dk4TM`.
Red cases are retained, not overwritten. Tests use isolated fixtures and
headless unit-test execution only: no screen capture, visible app interaction,
production accounting writes, signing changes, deployment, or push.

Storage implementation reference: Python's official
[descriptor-relative open](https://docs.python.org/3/library/os.html#os.open) and
[bounded read](https://docs.python.org/3/library/os.html#os.read) contracts.
