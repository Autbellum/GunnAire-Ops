# Billing PDF Drive delivery candidate

This branch builds on the 0123 release source and the backend-only PDF/QBO
candidate in PR #59. The server owns an immutable PDF artifact and a SQLite
reservation for one company, Google subject, document, source digest, and
renderer version. `POST /api/google/drive/billing-pdf-intents/deliver` accepts
only that reservation's lease and content digest from an authenticated admin
session. It obtains the server-held Google `drive.file` grant, gets one Drive
file ID, commits that ID to SQLite before upload, creates the PDF using the
same ID, and confirms only after metadata and byte readback. A timeout leaves
the ID and artifact for a later retry. Google documents that a repeated create
with a pre-generated ID returns HTTP 409 rather than creating another file:
https://developers.google.com/workspace/drive/api/guides/create-file

The native queue attempts this session-bound handoff after saving a PDF and
again when it recovers a rendered journal entry. It keeps the local checkpoint
until the exact server reservation is confirmed. When the business session,
workspace, native Google identity, or server Drive grant is unavailable, the
checkpoint remains pending and the existing UI says the Drive archive needs
review. The queue does not perform network calls or PDF rendering on SwiftUI's
main actor.

This is not closed-app server delivery. The server's current Google access
method requires a live application session, and there is no service-owned
grant refresh worker or scheduler for pending artifacts. It also does not
publish a file for legacy documents that have never entered the queue. The
native save trigger from PR #51 must be merged with the 0123 estimate-send
changes before users will enter this flow. PR #59 must be deployed before any
app build calls the new backend endpoint. Production Google OAuth scope and
account approval, provider file creation, external Drive visibility, and
physical-device behavior remain to be verified on the intended account.

For recovery, inspect the authenticated reservation status and retained PDF
artifact, then resume the same intent after reconnecting the original account.
Do not clear `drive_file_id` after an uncertain create. If readback fails, keep
the original reservation and investigate the exact ID, marker, size and SHA-256
before any replacement. A changed source digest or Google subject is a review
event, not permission to reuse the old file.
