# QBO inventory publication — server prerequisite

Candidate `2026.09.08.35`, September 8, 2026. This extends the actual shared
catalog publisher with inventory creation and reviewed price updates. It is
not completion of native item-type integration or of the business-app goal.

## Ownership and accounting behavior

QBO owns the accounting item ID, inventory asset valuation and company-wide
quantity on hand. GunnAire's explicit truck/warehouse movements remain separate.
A create proposal includes its opening quantity/date and all three per-item
account references. No stock adjustment, account creation or transaction
rewrite is added to the catalog endpoint.

The existing authenticated administrator-only routes, original company/realm/
environment/grant checks, encrypted immutable proposals, one-time dispatch
claim and one-to-one item mappings remain in use. Field technicians may propose
items in the app; this contract does not grant them accounting publication.

### Inventory creation

`POST /api/catalog-publications` retains its existing envelope. The `item`
object now accepts `Type: Inventory` with:

- `QtyOnHand`: explicit finite nonnegative opening quantity, including zero or
  fractional units. The application bounds it to 99,999,999,999; this is not a
  claimed provider maximum. Neither quantities nor unit rates are rounded.
- `InvStartDate`: an explicit valid calendar date in `YYYY-MM-DD` format.
- `TrackQtyOnHand: true`.
- `AssetAccountRef`: an active **Other Current Asset / Inventory** account.
- `IncomeAccountRef`: an active **Income / SalesOfProductIncome** account.
- `ExpenseAccountRef`: an active **Cost of Goods Sold** account.

The server reads the three exact account IDs from the original QBO company.
Account names are presentation metadata, not identity. Inventory accounts are
explicit per-item choices; they are not silently borrowed from the configured
service defaults. Service/NonInventory creation retains its existing default-
mapping checks. Only fixed-origin Account GETs were added to the transport;
Account POST/PUT/PATCH/DELETE remain rejected.

Complete catalog comparison still happens first. An administrator-reviewed
exact existing name/SKU/type match returns the original item without applying
the proposed opening balance. Linking is not proof that the proposed opening
quantity/date was applied. Conflicting types, ambiguous identities and unknown
attempts do not cause another create.

### Existing inventory updates and recovery

An inventory update includes `Type: Inventory` as immutable review evidence
beside its exact ID/SyncToken and the ordinary supported sparse price/name/
description/tax/vendor fields. Type must match the provider before dispatch or
uncertain-result recovery. It is removed from the outgoing QBO update, so this
cannot convert the item. Legacy Service/NonInventory proposals without Type
remain compatible.

Opening quantity/date, stock-tracking and accounting references are forbidden
on updates. The outgoing request also uses `include=donotupdateaccountontxns`.
Inventory activation/inactivation needs a separate stock/accounting workflow;
the existing simple catalog availability toggle is not such authorization.
No backend stock-movement or adjustment endpoint is introduced here.

Creation is dispatched once per durable intent. After a lost reply or process
restart, recovery reads the original catalog identity. Current negative stock
is retained as evidence, not replaced with the original opening quantity.
Successful replay returns current provider data, not a cached original balance.
A mismatched immediate write response leaves the attempt unknown and unlinked.
External QBO activity is not transactionally locked by local preflight reads.
Provider rejection, current subscription/locale support and sandbox acceptance
must still be verified before production rollout.

## Qualification

Frozen source passes **513 backend tests** in 58.502 seconds, including **69
focused catalog/provider tests** (20 added), and **40 release/CloudKit/device
tool tests**. `compileall` for Backend/root entry point/Tools, `actionlint` and
`git diff --check` also pass. No earlier assertion or failure gate was removed.
The fixture provider now honors sparse-update preservation of existing fields.

Coverage includes valid and malformed opening fields, actual spaced QBO account
types, wrong/inactive accounts, role/company/grant rejection, revocation during
account reads and at dispatch, two-device dispatch races, changed stock after
creation, lost-reply/restart recovery, immutable type review, sparse price
updates, forbidden stock/account mutations, stale SyncToken, unconfirmed values,
and the real localhost application HTTP create/recover/update routes. All
provider operations are fixtures; no live accounting request was sent.

Evidence retained in:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/QBO Inventory Contract.kHP3g5/`
(`Backend.log`, `Tools.log`). Native source, project/signing settings and the
CloudKit v24 schema are unchanged, so native builds/screenshots were not rerun
for this server-only checkpoint. Hosted checks qualify each published head
separately; preceding green runs do not qualify this candidate.

Source SHA-256:

- `Backend/catalog_publications.py`:
  `8fb57fcbe78ace03527de289a739949a706f3470ee938c8276e1199653a1eec9`
- `Backend/gunnaire_backend.py`:
  `5e09c7e7c3e943ea1e84e944f975cef591b30c3851dad1d93014d2ee197a26e3`
- `Backend/test_catalog_publications.py`:
  `295103c361a4f7ab7f5dd0f927919949339a8b5b2a6af9da052dcee2d53f829c`
- `Backend/test_catalog_provider.py`:
  `a0db41c16d208ef6c12bab7f4eea11d1cc59d0d8c5e206d94bd481ffd211c09d`

## Required native continuation — still incomplete

1. Preserve all actual QBO types instead of the current unknown-to-Service
   fallback. Import and retain inventory/account, category and bundle details.
2. Add the inventory setup fields and explicit account selectors to native
   creation/admin review, with offline draft durability, original-workspace
   checks and clear disclosure that linking does not apply opening stock.
3. Add the outgoing immutable Type evidence for inventory updates, and keep
   stock/activation/account changes separate from routine price edits.
4. Extend the additive CloudKit model and versioned application receipt without
   invalidating v1 receipts, pending edits, existing stores or sold prices.
5. Retain sold item type/provider identity on invoice/estimate snapshots and
   verify native inventory selection, publication, recovery and navigation.
6. Implement category organization and existing bundle contents/transaction
   semantics. Intuit does not support creating Group items through the QBO API;
   do not replace bundles with zero-price Service lines or invent an endpoint.
7. Verify the actual iPad/Mac journeys and signed multi-device behavior, then
   obtain concrete sandbox/production acceptance before authorized rollout.

These steps remain part of the full objective, alongside the broader competitor
feature coverage, Google/vendor integrations, tenant/role controls, CloudKit,
Handoff/Tap to Pay and release acceptance. No merge, deployment, schema promotion
or claim of production readiness occurred in this checkpoint.

## Primary references

Inspected in Safari September 8, 2026:

- [Intuit Item API](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/item):
  inventory creation fields, date read/update distinction, quantity tracking,
  categories, existing bundles and transaction-account update behavior.
- [Intuit Account API](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/account):
  expanded AccountType table verifies Other Current Asset/Inventory,
  Income/SalesOfProductIncome and Cost of Goods Sold classifications.
