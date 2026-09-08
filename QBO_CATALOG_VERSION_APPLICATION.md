# Versioned QBO catalog application

Source checkpoint: September 8, 2026. This follows the shared-history reader at
8aadb75. It applies dated versions to real local Items; it does not redefine the
full business-suite goal as observation-only sync.

## Contract and ownership

The existing Management refresh carries a verified catalog batch through the
thirteen-collection final revalidation and synchronous local-import boundary.
The batch binds company UUID, realm, sandbox/production, original server grant,
QBO Item ID, provider update time, SyncToken, canonical payload digest and typed
record digest. Changed, omitted, duplicated or substituted input rows fail
before any local import changes. No additional provider endpoint or write is
introduced.

Each applied Item receives an optional quickBooksCatalogReceiptJSON value in
the same ModelContext save as its provider-owned values. Projection version 1
binds the local UUID and a digest of exactly these persisted fields: QBO ID,
name, item type, unit price, purchase cost, taxability, sales description, SKU,
purchase description, preferred vendor name/ID and pricebook availability.
The receipt records the application date separately from provider update time.
It contains no raw accounting payload, credential, customer email or token.

This is local application evidence, not a signed server attestation, a webhook
acknowledgement, or proof that another CloudKit device has received the record.
The server still reports applicationState=not_applied. Management still leaves
webhook alerts pending. Inventory balances, account postings, group contents,
categories, deletion/merge/void outcomes and payment allocation are not falsely
declared applied by this catalog projection.

## Conflict and recovery rules

- Exact linked identity is used. Name/SKU candidates require administrator
  review; refresh neither claims a technician draft nor creates another Item
  beside unresolved candidates. Candidate lookups are indexed once per import.
- Both technician approval and staged administrator decisions remain pending,
  even when their amounts happen to match the provider. Other nonconflicting
  records may be saved, but the overall refresh reports review required.
- Provider timestamps preserve microsecond ordering. Older versions and
  same-time/different-payload versions cannot replace applied values. A new
  grant in the same realm does not remove this ordering barrier.
- A company, realm, environment, local UUID or receipt format mismatch requires
  review. Unknown future receipt formats are not guessed or overwritten.
- Divergent provider-owned local fields invalidate current-projection evidence.
  An explicit catalog-review acceptance of the exact incoming projection can
  converge on the next verified refresh without losing the time barrier.
- Truck stock controls, local vendor part numbers, location, reorder point and
  flat-rate definitions are not provider-price edits and remain unchanged.
  Existing invoices retain their immutable sold catalog snapshots and totals.
- Active=false retains identity and archives the item instead of deleting
  historical references.
- Existing unsaved editor work blocks shared import before mutation. Autosave
  is suspended for the synchronous import; failed saves restore every touched
  catalog field and the old receipt before context rollback. New imported
  records are rolled back. Review errors after a successful save are distinct
  from persistence failures.

## CloudKit and release boundary

Bootstrap v24 adds one optional STRING field to CD_Item:
CD_quickBooksCatalogReceiptJSON. Existing fields, entities, entitlements and
security grants remain unchanged. The development-only seed includes a marker
that deliberately cannot decode as an applied receipt.

The schema preflight recognizes the exact cumulative v24 addition and rejects
unexpected fields even when Production already contains all v23 fields. The
promotion manifest format is version 2, targets bootstrap 24, and refuses
promotion when the receipt field is missing or has the wrong definition. An
old v23-only development export is identified as not ready for v24.

No signed bootstrap, schema export, production promotion or physical-device
installation was performed. A real pre-receipt SQLite Item store is created
with the prior persisted attributes, reopened using the new Item model, and
checked for retained identity, pending edits, vendor/assembly metadata and nil
receipt. This does not substitute for production-like full-store migration or
multi-device CloudKit acceptance.

## Primary references checked in Safari

[Intuit Item reference](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/item)
defines Item identity, SyncToken, read-only update metadata, category/bundle
differences and inactivation with historical references retained.
[Intuit CDC reference](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/changedatacapture)
defines full changed payloads, update-time ordering and deletion evidence.
[Apple SwiftData/CloudKit guidance](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices)
describes asynchronous synchronization and additive production schemas.

## Retained qualification

Evidence directory:
/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/QBO Item Application.zkVl9S/

FocusedMac is a retained test-compilation failure from a nested Testing require
macro; the nested expression was separated. FocusedMac2 and FocusedMac3 expose
the actual held-model rollback defect: disk/fresh-context values recover, but
the original Item still displays the candidate price and receipt. Processing
pending changes alone does not fix it. Explicit restoration of import-owned
catalog fields before rollback resolves both assertions; neither assertion was
removed or weakened. FocusedMac4 passes all 58 focused tests in three suites.

FullMac and FullIPad retain one legacy-contract regression each: the prior
non-history duplicate-mapping import unexpectedly throws the new review error.
The added error is now limited to shared-history batches; the old mapping
protection and every test assertion remain. All four selected iPad interface
journeys pass in that intermediate run. The first universal Release build
passes but predates the final no-import/unsaved-edits error wording, so it is
not substituted for final-source qualification.

The unsaved-edit precondition uses its own no-import error rather than the
post-save partial-review error, avoiding a false statement that records were
refreshed when the import never began.

FinalIPad passes 1,308 logic tests plus all four selected interface journeys
(1,312 logical tests / 1,373 parameter-expanded executions), with no failures or
skips. Backend.log passes 493 tests; Tools.log passes 40 tests. These are local
fixtures, not live provider or physical-device acceptance. Final Mac logic and
universal Release checks are recorded below. Earlier hosted
checks qualify their exact published head, not this candidate.

FinalUniversalMacRelease passes the unsigned optimized build and the lipo
arm64/x86_64 verification. Executable SHA-256:
b6e429926e1344f0459d4deb8a16dad99e71669732f0be0543d09f107b3ac230.
Both architectures are present. No new compiler warning is reported; the
pre-existing external Metal-toolchain linker search-path warning remains.
FinalMac passes 1,308 logic tests (1,369 parameter-expanded executions), with
no failures or skips. App/test source remained frozen through FinalIPad,
FinalMac and FinalUniversalMacRelease; only evidence documentation changed.

Preceding head 8aadb75 passes all four hosted jobs: Native run 34188092219
(iPad and Mac) and Backend run 34188092174 (Python 3.13 and 3.14). That terminal
success was verified before publication of this new catalog candidate.

Final iPad visual review inspected the simple Inbox, Compose with keyboard, and
original saved Invoice. They remain readable, with no account-email footer or
new internal receipt data displayed. The Invoice launch test has no screenshot
attachment; saved-invoice evidence comes from the complete Management billing
journey, not an invented launch capture. Retained images:

- FinalMailUI/E7E42188-836B-4722-A661-05663B2BCD2A.png (Inbox)
- FinalMailUI/E24895A5-3DE6-40BF-A6C0-EE835ED7A3B3.png (Compose)
- FinalBillingUI/CBE5F536-4AD2-4403-B69D-77018BF8826F.png (saved Invoice)

Final source SHA-256 values:

- QuickBooksCatalogHistory.swift: 37bd2eaaa5eb8ae0aa96e6f51cc5e0f9fda743434951f0f675e84af2f952b3b5
- QuickBooksLocalSync.swift: 00a7391ed82245d2cb8f881b2b925300e1d2983c0fd908655de19c718486e4ee
- Item.swift: 50c4c7374d2e2986df5c7232d55db9725e62d8efb039717b0ddb2979dfcd824b
- QuickBooksCatalogHistoryTests.swift: e694957a5cb86be194459792a752346af8c9146a528cfeb4acd7269e9a0192a6

## Remaining full-goal requirements

Per-event server acceptance and per-device consumption, complete financial and
item lifecycle semantics, quantities/account/bundle/category integration,
durable cross-device conflict resolution and large-history staging remain open.
This receipt does not make CloudKit an ordered transaction journal or resolve
an older whole-record cloud merge over unsent edits. Non-catalog held-model
failure recovery also needs end-to-end audit. Server-only native QBO access,
the broader Google/vendor features, top-ten competitor parity, complete iPad/Mac
navigation qualification and physical iPad-to-iPhone Handoff/Tap to Pay plus
provider/distribution acceptance are still required. No full-goal completion,
merge, deployment or live accounting mutation is claimed.
