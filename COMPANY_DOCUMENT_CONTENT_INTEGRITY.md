# Company document content integrity

## Implemented boundary

New shared-company uploads persist their byte count and SHA-256 from the submitted
content. The server reads the stored file back against that proof before committing
metadata, then rechecks current upload authority. Database triggers prohibit changing
the upload proof on an existing record. A replacement must be a new document with
its own identity; a migration or download never invents historical evidence.

Both ordinary document downloads and staff attachment downloads require that proof,
in addition to the existing bounded, no-symlink, descriptor-relative reader. Same-size
replacement before the first read is rejected; growth, truncation and writes during
the read remain rejected. The byte cap stays 64 MiB for reads and the configured
upload cap stays 12 MiB by default / at most 25 MiB. MIME/header metadata is checked.

Ordinary download and manifest routes retain the current document billing-role
gate. Downloads now re-evaluate the request-cached principal after disk access and
compare the complete current database row before releasing bytes. Staff downloads
retain their independent current company/share/selection checks and post-read fence.
This is not a new role grant or a change to company ownership.

## Native verification

GET `/api/documents/{canonical UUID}/manifest` returns the closed
`company-document-content-v1` contract: document ID, original filename/content type,
upload byte count/hash and creation time. The native download client validates it,
downloads through the existing bounded ephemeral/no-redirect transfer, compares
the exact bytes, and re-fetches the manifest before returning data to existing
customer/job download callers. It checks the same mounted account/generation across
all replies; path/query/ID substitution and unknown proof fields fail closed.

Staff media now uses `staff-workspace-operational-media-v2`, with a separate
`fileSHA256` in the authenticated grant. The existing `contentSHA256` still means
the workspace selection payload and must never stand in for the file's hash.
Local IDs and file sizes alone can no longer create a media authorization.

The v2 grant namespace leaves v1 journals untouched. Staff preview bytes are
verified before writing and read back with a bounded hash check afterward. Preview
paths include the content digest: repeated opens reuse a verified file without
duplicating it or replacing an already-open preview. A corrupt cached original
is retained and rejected, not silently overwritten. Proof is checked at handoff;
this does not claim protection against arbitrary later host/filesystem compromise.

## Legacy records and release gates

Legacy document rows receive nullable proof columns, without reading their files
or backfilling a digest. Their records and files remain intact and listed. A download
without original proof returns an explicit review error; an authorized user can
import a retained original as a new document through the existing import workflow.
Do not deploy this change without reviewing existing legacy-document inventory,
retained originals and relinking needs. There is no automatic destructive migration
or claim that a newly computed legacy hash proves the original upload.

Backend/app versions must be qualified and promoted together. An old media v1
grant cannot enable a v2 download. No production data, providers or credentials
were used to create the test fixtures. All failed test/build attempts are retained
with the final qualification under
`/Users/gunnaire/Downloads/GunnAire Ops Releases/Document Integrity.UvtJGG`.

The QBO captured-upload journal already verified its original bytes; it was inspected
and regression-tested, not replaced. This slice does not add QBO item/time workflows,
prove production CloudKit handoff, supply historical hashes for uncaptured local
files, implement generic document-upload idempotency or complete the business suite.
The full goal remains ACTIVE. Screens, browser UI, signing, deployment, live
accounting writes, push and merge are out of this qualification.
