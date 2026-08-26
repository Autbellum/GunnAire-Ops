# GunnAire backend operations runbook

Last verified: 2026-08-26

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

1. Install the canonical dependency set with `python3 -m pip install -r requirements.txt`.
2. Run:

   ```sh
   python3 -m unittest \
     Backend.test_deployment_entrypoint \
     Backend.test_qbo_token_storage \
     Backend.test_backend_readiness \
     Backend.test_backup_backend -v
   ```

3. Deploy only the reviewed commit. Do not change Render secrets as part of a
   routine code deployment.
4. Confirm `/health` returns HTTP 200 and the expected `serviceVersion`.
5. From an authenticated Admin account, open **Settings → Sync → Shared Server
   Readiness**. Investigate every attention/error component before enabling a
   provider workflow.
6. Roll back if health remains unavailable, the version does not advance, the
   Admin readiness request fails, or database/document probes report an error.

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
- Google authentication attention: keep shared routes closed until approved
  business identity mode is restored.
- Customer communication is required when an outage delays a confirmed visit,
  prevents field access to required records, or creates a credible risk that a
  payment/document was not retained. Do not include secrets or internal logs.

After resolution, preserve the incident timeline, affected workflow, version,
backup artifact ID, diagnostics, corrective action, and verification evidence.
