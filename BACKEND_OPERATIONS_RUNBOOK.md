# GunnAire backend operations runbook

Last verified: 2026-08-30

This runbook covers the shared GunnAire service at
`https://gunnaire-api.onrender.com`. It does not authorize accounting changes,
credential rotation, production restores, or customer communications.

## Ownership and proposed recovery targets

- Deployment/backup owner: GunnAire business owner or designated operator.
- Accounting escalation: the approved QuickBooks company administrator.
- Field-impact escalation: the dispatch/operations lead.
- Proposed recovery point objective: 24 hours. This is not approved until an
  automated off-host backup schedule is configured and observed.
- Proposed recovery time objective: 4 hours. This is not proven until a timed
  restore drill is completed by the deployment owner.

## Release verification

1. Run the read-only local release preflight against the exact current-source
   archive and retained CloudKit exports:

   ```sh
   python3 Tools/release_preflight.py \
     --archive "/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-08-30/GunnAire Ops 1.0 (2026083011 Current Source).xcarchive" \
     --mac-app "/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-08-30/GunnAire Ops 1.0 (2026083011 Current Source Mac Catalyst).app" \
     --mac-result "/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-08-30/Verification/GunnAire Ops 1.0 (2026083011 Current Source Mac Catalyst).xcresult" \
     --cloudkit-development-export /Users/gunnaire/Downloads/cloudkit-development-11.ckdb \
     --cloudkit-production-export /Users/gunnaire/Downloads/cloudkit-production-7.ckdb
   ```

   The utility validates source/archive version parity, strict signing,
   entitlements and development-profile identity, the independently installed
   App Store profile's production APNs/TestFlight/Production CloudKit/Apple
   login scope, the exact universal Mac Catalyst Release app/result, privacy
   manifests, hardened runtime, release configuration, QBO/Google OAuth
   identifiers, app/dSYM UUIDs, binary hygiene, and the exact additive CloudKit
   delta including record system fields and security grants. Build 3011's exact
   local run passes 61 checks with four expected warnings and zero failures.
   Development-signing warnings are expected until the Apple
   Distribution private key is installed. Use
   `--require-app-store-signing` only for the final upload candidate.
2. Install the canonical dependency set with `python3 -m pip install -r requirements.txt`.
3. Run the complete backend suite rather than a hand-selected subset:

   ```sh
   python3 -m unittest discover -s Backend -p 'test_*.py' -v
   ```

   Source `2026.08.30.15` has 69 expected tests. A different count requires
   review before deployment even when the discovered subset is green.
   The same suite must pass in the **Backend regression** GitHub workflow on
   Python 3.13 and the production-aligned Python 3.14 job. A green workflow is
   evidence for the reviewed commit; it does not itself authorize Render to
   deploy that commit.
4. Record the current GitHub commit, `/health` response, and deployment ID.
   Confirm a recent verified off-host backup exists before a release that adds
   database tables. The `.12` Apple identity tables, `.13` supplier-attempt
   table/indexes, and `.15` Accounts Payable configuration columns are additive;
   rolling code back does not require deleting them or restoring the database.
5. Do not push release source directly to `main`. The repository's secret-free
   **Backend regression / Python 3.13** and **Backend regression / Python
   3.14** checks have unfiltered pull-request and push-to-`main` triggers.
   Ref-scoped concurrency intentionally cancels an older in-progress run when
   a newer commit supersedes it, so completed checks prove the exact current
   ref head rather than every superseded commit. Merge commit `3df24b5` proves
   both jobs succeed on that exact `main` head. The main branch should also have
   an active GitHub ruleset requiring a pull
   request, resolved review conversations, an up-to-date branch, and both
   successful GitHub Actions checks, with deletion and force pushes blocked and
   no bypass actor. Repository-owner sudo-mode confirmation is still required
   before that ruleset can be created. Until it is enabled, record the control
   gap and manually verify both checks on the exact head commit before merging.
   Prepare a release branch, review the exact diff against the recorded commit,
   and merge only with deployment-owner authorization. Render follows `main`,
   so the merge is a production deployment. Do not change Render secrets as
   part of a routine code deploy.
6. After the authorized deployment, rerun the same preflight with `--online`.
   Confirm `/health` returns HTTP 200 and exact `serviceVersion`
   `2026.08.30.15`.
7. Confirm the new public Apple route is present without fabricating an Apple
   event or storing data:

   ```sh
   curl -i -X POST \
     -H 'Content-Type: application/json' \
     --data '{}' \
     https://gunnaire-api.onrender.com/api/auth/apple/notifications
   ```

   The expected result is HTTP 400 with `Invalid Apple account notification`.
   HTTP 401 indicates the previous backend is still serving the route. Never
   use a locally invented payload as production acceptance evidence.
8. From an authenticated Admin account, open **Settings → Sync → Shared Server
   Readiness**. Investigate every attention/error component before enabling a
   provider workflow.
9. When staff alerts are intended for the release, confirm **Staff Push
   Notifications** is ready. The APNs Team ID, Key ID, base64 `.p8`, exact app
   topic, HTTP/2 dependency, and dedicated device-token encryption key must all
   be present in the deployment secret manager. Do not create or rotate the
   Apple key as part of an ordinary code deployment.
10. Confirm the primary App ID's existing Sign in with Apple server-to-server
   notification URL remains
   `https://gunnaire-api.onrender.com/api/auth/apple/notifications`. Record the
   Apple configuration time and test signed-device sign-in, relay status,
   consent revocation, delayed-event protection, and account deletion. The raw
   Apple JWS, private-relay address, and provider subject must not appear in
   logs or incident notes.
11. Roll back if health remains unavailable, the version does not advance, the
   Admin readiness request fails, or database/document probes report an error.
   If the Apple notification URL was already activated, remove it before
   rolling back to a version that does not expose the endpoint so Apple does
   not repeatedly deliver events to an unauthorized route. Roll back code to
   the last reviewed commit; do not restore the database solely to remove
   additive `.12`, `.13`, or `.15` schema changes.

## Create and verify a backup

The utility uses SQLite's online backup API, copies every shared document,
records sizes and SHA-256 hashes, and verifies SQLite integrity before it writes
the readiness status file. The destination must be a new directory and must not
be inside shared document storage.

```sh
python3 Backend/backup_backend.py backup \
  --database /var/data/gunnaire_backend.sqlite3 \
  --storage /var/data/storage \
  --destination /path/to/off-host/gunnaire-backup-YYYYMMDD-HHMMSS \
  --state-file /var/data/backup_status.json

python3 Backend/backup_backend.py verify \
  --backup /path/to/off-host/gunnaire-backup-YYYYMMDD-HHMMSS
```

The verified artifact must then be retained outside the Render service and its
persistent disk using an approved encrypted business-storage account. A local
artifact or `backup_status.json` alone is not an off-host backup.

## Non-destructive restore drill

Never use the live `/var/data` directory as the drill destination. The command
refuses to overwrite an existing path.

```sh
python3 Backend/backup_backend.py restore-drill \
  --backup /path/to/off-host/gunnaire-backup-YYYYMMDD-HHMMSS \
  --destination /tmp/gunnaire-restore-drill-YYYYMMDD
```

Confirm that the command passes, the restored SQLite database can be queried,
document counts match the manifest, and `restore_drill.json` was created. Record
the elapsed time and artifact ID outside the server. Delete the temporary drill
copy only after evidence is retained.

## Production restore decision

A production restore requires explicit business-owner authorization. Before
replacement, stop writes, preserve the current database/documents as a separate
incident artifact, identify the exact verified backup ID, and record the outage
window. Restore both the database and document directory together; restoring
only one breaks traceability. Start the service, verify `/health`, Admin
readiness, user login, document download, dispatch visibility, and read-only QBO
connection health before reopening field work. Do not test an accounting write
as part of restore validation without accounting-owner approval.

## Alert and incident cues

- Sustained `/health` failures or repeated 5xx responses: roll back the newest
  deployment and inspect Render logs.
- Database or storage readiness error: stop document/payment intake and protect
  the persistent disk before attempting repair.
- Backup attention: create/verify a new artifact and confirm it exists off-host;
  do not clear the warning manually.
- QuickBooks mismatch/decryption error: stop QBO mutations and reconnect only
  with the accounting owner. Never replace the encryption key opportunistically.
- QuickBooks Change Alerts attention: confirm the Intuit-supplied verifier token
  is present in Render, the CloudEvents v1.0 destination is
  `https://gunnaire-api.onrender.com/api/qbo/webhooks`, and the Intuit app is
  subscribed in the matching sandbox or production environment. Send an Intuit
  portal test event and inspect Render logs plus Admin readiness. Never bypass
  signature verification, realm binding, event-ID deduplication, or the rule
  that acknowledgement follows a complete successful reconciliation.
- Staff Push Notifications error: keep alerts disabled while checking the
  dedicated Fernet key, Apple Team/Key IDs, exact bundle topic, base64 `.p8`,
  and installed HTTP/2 dependency. Never print the private key, device token,
  ciphertext, or payload. An APNs credential rejection leaves delivery rows
  pending for recovery; correct the secret through the deployment manager and
  verify readiness before retrying.
- Staff Push Notifications backlog: first verify `/health`, persistent-disk
  access, worker startup, and APNs reachability. `BadDeviceToken`,
  `DeviceTokenNotForTopic`, `ExpiredToken`, `Unregistered`, and HTTP 410 are
  permanent for that registration and must deactivate it; 429 and 5xx failures
  remain bounded retries. Do not reactivate a token manually—have the opted-in
  user reopen the signed app so Apple supplies the current token again.
- Google authentication attention: keep shared routes closed until approved
  business identity mode is restored.
- Sign in with Apple account-notification failures: keep Apple login available
  only if normal identity exchange remains healthy, but treat consent and
  deletion handling as release-blocking. Confirm the deployed version, TLS,
  Apple audience/bundle ID, Apple signing-key retrieval, database availability,
  and the exact configured URL. Invalid signature or claim responses must stay
  `401`; malformed envelopes must stay `400`; unknown but correctly signed
  subjects are acknowledged without creating a user. Never bypass verification
  or manually mark an event processed. If the endpoint cannot be restored,
  remove the URL in Apple Developer with owner authorization and preserve the
  incident timeline until a signed-device revocation retest passes.
- Customer communication is required when an outage delays a confirmed visit,
  prevents field access to required records, or creates a credible risk that a
  payment/document was not retained. Do not include secrets or internal logs.

After resolution, preserve the incident timeline, affected workflow, version,
backup artifact ID, diagnostics, corrective action, and verification evidence.
