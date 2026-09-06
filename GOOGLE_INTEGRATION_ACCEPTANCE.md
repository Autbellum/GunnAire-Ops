# Google Workspace Integration Acceptance

Last reviewed: 2026-09-05

## Supported business surface

GunnAire Ops integrates the Google capabilities that have an explicit HVAC
operations workflow:

- Google business identity for the exact signed-in GunnAire account;
- Gmail Inbox, search, read, compose, reply, reply all, forward, send with
  generated business-file attachments, mark read, and recoverable Trash;
- Google Calendar list/import plus app-managed create, schedule-only reschedule,
  and delete for dispatch and technician schedules; and
- Google Drive archive for app-created service reports, billing support files,
  receipts, agreements, and related customer documents.

This is intentionally not a request for blanket access to every Google or
Workspace product. Google Contacts/People and Workspace administrator scopes are
not requested: GunnAire customer records remain authoritative, and copying a
user's full address book would expand personal-data access without a defined
operational need. The app uses Apple Maps for native route handoff and traffic
estimates, so it does not need Google Maps account access. Google Docs and Sheets
files can be retained through the normal Drive file/archive boundary without
granting broad Drive browsing.

## Implemented controls

| Boundary | Implemented behavior |
| --- | --- |
| OAuth | Native iOS client, authorization-code flow with PKCE, state validation, registered reversed-client callback, hosted-domain hint and post-login domain validation. No Google client secret is stored in the app. |
| Identity | The normalized Google email must exactly match the primary GunnAire business-login email before any Google integration is usable. The backend-issued app session is also bound to the verified provider subject and email. |
| Scopes | `openid`, `profile`, `email`, Calendar, `gmail.modify`, and least-privilege `drive.file`; broad Drive and Workspace administrator scopes are excluded. Legacy tokens without confirmed Drive scope fail closed. |
| Gmail | Conventional mail presentation hides provider payload/MIME details. Customer sends revalidate role, record relationship, recipient, consent, and workflow context. Provider-confirmed delivery is required before operational success is recorded. Delete moves mail to Gmail Trash. |
| Calendar | Imports preserve external event detail and remain read-only. Only current-version GunnAire-owned events can be patched or deleted, and updates are limited to start/end time. Calendar and event lists now follow every `nextPageToken`, preserve the original filters, accept empty collections, and reject repeated or unexpectedly unbounded page chains rather than returning a partial dispatch schedule. |
| Drive | Administrators archive only supported internal/customer files. The app reserves a stable Drive ID, uses resumable upload, reconciles ambiguous outcomes against app-owned metadata, validates returned links, retains retry state, and cannot list unrelated Drive content. |
| Local storage | OAuth tokens and the verified application session are stored in Keychain. Provider tokens are not copied into customer records, audit text, screenshots, or this acceptance file. |

## Verified evidence

- Mac Catalyst Debug build with signing disabled: passed on 2026-09-05.
- iPad Pro 13-inch (M5), iOS 26.5 simulator logic suite: **716 passed,
  0 failed, 0 skipped**.
- Result bundle:
  `/tmp/GunnAireGoogleAuditDerivedData/Logs/Test/Test-GunnAire Ops-2026.09.05_21-04-37--0400.xcresult`.
- The focused pagination checks verify preserved filters/token encoding, empty
  collection decoding, repeated-token rejection, and bounded traversal.
- The behavior follows Google's documented `nextPageToken` contract for
  Calendar list resources:
  <https://developers.google.com/workspace/calendar/api/guides/pagination>.

## Production acceptance still required

These are provider/account actions and are not inferred from source tests:

1. In the exact Google Cloud project, enable Gmail API, Google Calendar API, and
   Google Drive API.
2. Publish and, where required, verify the OAuth consent configuration for the
   exact scopes above; approve `gunnaire.com` and the Workspace organization
   policy.
3. Confirm the production iOS OAuth client, bundle identifier, reversed-client
   URL scheme, and callback values match the signed build.
4. Reconnect the matching GunnAire business account so the current scope grant
   is recorded.
5. On a signed test device and noncustomer test records, accept: login/logout
   and revoked-grant recovery; Gmail read/send/reply/trash with an attachment;
   multi-calendar import and app-managed create/reschedule/delete; and Drive
   initial upload, interrupted retry, duplicate reconciliation, link open, and
   trashed-file recovery.
6. Retain redacted evidence, verify that unrelated Drive files and unrelated
   business identities remain inaccessible, then obtain the business owner's
   activation approval.

No Google account, email, calendar event, contact, Drive file, consent setting,
or organization policy was changed during this source audit.
