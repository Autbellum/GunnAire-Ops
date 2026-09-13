# Staff submission outcomes

This read-only workflow separates a server-recorded staff field update from its later office disposition. It never changes the original encrypted command, receipt, owner claim, office record, QBO transaction, or CloudKit readiness proof.

## Access and wire contract

`GET /api/workspace/staff-shares/{shareID}/field-updates` accepts exactly companyID, environment, replicaID, and an optional canonical command-ID `after` cursor. Adding `/{commandID}` reads one original and disallows pagination. There is no POST/update/delete action.

Current business membership, the accepted original share, replica binding, operations-role policy, original selection membership/revision, and original command authorship are required. Administrators do not gain an override on this staff endpoint; their separate owner inbox remains unchanged. Every original, claim, and keep-office decision is authenticated and validated before an outcome is returned. Corruption fails closed, never disguising a completed decision as awaiting review.

Pages contain at most eight originals in ascending command-ID order. `nextCursor` is the last returned ID only when another row exists; otherwise it is the empty string. A refresh restarts from the beginning to include newly submitted IDs that sort before an existing cursor. Server discovery includes historical submissions whose device pending index has already been cleared.

Each entry includes only the author's original request and receipt, `state`, and `decidedAt`:

| State | Meaning |
| --- | --- |
| awaitingOffice | Recorded; no terminal office decision is confirmed. An exclusive prepared claim alone is not application. `decidedAt` is empty. |
| appliedToOffice | The existing owner application receipt confirms publication of the field to the owner source. `decidedAt` is that publication time. |
| keptOffice | An existing immutable keep-office decision retained the original submission without replacing the reviewed office value. `decidedAt` is that decision time. |

Office comparison values, current values, owner email, device/store identifiers, claim operations, and resolution requests are never returned. Later office edits do not rewrite the historical outcome. Neither terminal state asserts QBO or physical CloudKit convergence.

## Native behavior

The staff workspace has a secondary **Submitted Updates** sheet. It shows the record title when available in the authorized staff projection, field label, submission time and plain-language outcome. The author's submitted scalar expands on demand; raw IDs/payloads and account footers are not displayed. Eight-entry pages replace one another to keep memory and the view bounded. Refresh returns to the first page.

The native decoder uses the existing strict closed contract, including duplicate-key rejection. The new cursor/time fields use explicit empty strings rather than optional/null ambiguity. The request and receipt must bind exactly; any known encrypted local original is cross-checked without being rewritten. Missing local originals may be discovered from this currently authorized server path; no new command IDs are generated.

Results are not cached as offline authority. The view shows when it last checked, clears on failed verification, account expiry/change, dismissal or scene deactivation, and rejects late replies after invalidation. Reads recheck the current account/session around awaits. Original local encrypted journals are retained through failure or access loss.

## Qualification and remaining acceptance

Automated HTTP authorization/integrity/pagination tests, native contract/session/journal tests, and native decoding of actual isolated HTTP fixture responses qualify this slice. Fixtures contain no live credentials or company data. No screen capture or visible app launch is used.

Physical independent-account CloudKit acceptance, production schema/signing, cross-device claim takeover, removed-record disposition, staff field-editor affordances, QBO/Google/vendor workflows, Tap-to-Pay acceptance and parallel UI qualification remain separate gates. This sheet is status feedback, not a new field editing surface or deployment claim.
