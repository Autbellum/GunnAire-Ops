# Customer portal approval review — 2026-09-06

Backend candidate `2026.09.06.19` addresses the portal approval defects found
while reviewing PR #17 against the combined application branch in PR #18.

## Reproduced defects and corrections

- Two requests can resolve the same response concurrently. Previously, a stale
  `needs_attention` request could overwrite `applied`. A conditional database
  update now prevents any update to an applied resolution. Repeated `applied`
  requests return the original detail, actor, and time without a duplicate audit.
- The resolution and its audit event now share one database transaction. An
  audit-storage failure rolls back the resolution instead of losing its history.
- Arbitrary-size JSON integers previously overflowed float conversion in both
  `balanceDue` and `estimateAmount`. Range validation now runs before conversion,
  returning HTTP 400 and allowing the next valid request to succeed.
- A replay could show approval success after revocation. The final lookup now
  checks revocation and expiry for both first submissions and replays. The
  conditional approval write also checks expiry at the time of the write.

Concurrency tests pause a real SQLite read or write while a second HTTP request
commits, then resume the first request. All four original reproduction tests
failed before the fix. Six added tests cover overflow, stale downgrade,
revocation during first submission and replay, expiry during submission,
concurrent applied replay, and audit rollback.

## Verification

- Complete backend suite: 77 passed.
- Release, CloudKit, and device tools: 37 passed.
- Python compilation and Git whitespace validation pass.
- Tests use temporary local databases and loopback HTTP servers. These results
  do not prove live customer or production-provider acceptance.

The app-side estimate selector, exact snapshot payload, response metadata,
approval import, and server resolution call already exist on PR #18; the older
PR #17 finding about a missing client flow does not describe this combined branch.

## Remaining review scope

PR #18 also identifies company-replica identity, historical statement balances,
and refreshed bearer tokens on retained QBO retries. Those findings require
separate verification and corrections. Production deployment, Apple distribution,
CloudKit Production acceptance, and physical iPhone payment acceptance remain
open release work. Neither PR has been merged by this change.
