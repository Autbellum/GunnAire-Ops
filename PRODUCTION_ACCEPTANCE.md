# Production acceptance

Status: PARTIALLY DEPLOYED. Updated during closeout on 2026-09-12.

| Target | Verified evidence | Remaining acceptance |
|---|---|---|
| Repository | Cumulative PR 23 committed and pushed. Latest full commit-bound release run passed all 12 scopes for commit `9b027fc2efe33e00794672a513efa59b810fe416` (`dist/closeout-2026.09.12.1-wq_uo1jd/RELEASE_MANIFEST.json`) | Remote CI gate, merge, and final PR completion |
| Mac Studio | Four candidates installed and benchmarked; guarded tooling installed; workbench and Synology bridge restarted on independent Python runtime; scheduled health agent exited 0; exact model digests in `DEPLOYMENT_EVIDENCE/mac-services.json` | Native production gateway connection and FileVault reboot recovery |
| GunnAire Ops | Combined authenticated route tests pass; 322 LoadSight tests pass; unsigned simulator build and 2,377 iPad logic tests pass (`DEPLOYMENT_EVIDENCE/ipad-logic-summary.json`) | Configured private gateway, signed artifact and live business smoke tests |
| Synology | Mounted 100 GiB share; real synthetic file restore hashes match (`DEPLOYMENT_EVIDENCE/nas-file-restore.json`); auto-block enabled and reloaded (`DEPLOYMENT_EVIDENCE/dsm-login-protection.json`) | DSM snapshot/configuration restore, off-NAS backup, security log receipt, notification and least-privilege service-account checks |
| OPNsense | Existing default gateway responds as Eero; no OPNsense console confirmed | Dedicated appliance management and verified physical rollback route |
| Switch/APs | No managed-device inventory or management session confirmed | VLAN-capable hardware inventory and management access, trunk/SSID configuration and live isolation tests |

Source tests are not live provider acceptance. No accounting entry, customer charge,
Google invitation/message, production CloudKit record, or public port was changed by
these checks. No reboot acceptance has been recorded. No firewall cutover is authorized
without the verified recovery route required by the closeout directive.

## Evidence interpretation

The NAS sample restore demonstrates one ordinary file backup/restore through SMB.
It does not demonstrate Btrfs snapshots, encrypted configuration recovery, retention,
off-site protection, or a restored running application. Its synthetic original alone
was deleted for the test; the NAS backup and evidence were retained.

Previously installed workbench and Synology gateway services are not automatically
the authoritative Ops application gateway. Their existence must not be counted as
authenticated native-app end-to-end acceptance.

The real isolated backend acceptance issued synthetic app sessions and used actual
Ollama inference: unauthenticated status 401, authenticated status 200, forbidden-role
task 403, authorized draft 200, and one audit event. It did not use a fake model.
See `DEPLOYMENT_EVIDENCE/real-local-ai-gateway.json`. The temporary backend was stopped
after the test; this is not a persistent production deployment or a provider sign-in.

The public Render `/health` still reported service version `2026.09.02.17` at
2026-09-12T06:31:26Z. It cannot reach the Mac's loopback listener. A private authenticated
route must be established before native production AI can be accepted.

Model benchmark scores are heuristic, not factual-accuracy certificates. Some generated
commands and tests were incorrect or invented; none were executed as deployment work.
Devstral scored 84.8%, GPT-OSS and Qwen3 71.4%, Qwen2.5 60.7%, each across six fixed cases.
The measured configuration retains independent review and mandatory approval.

## Later target execution, 2026-09-12

A development-signed iOS archive for source `95d2ff00cd2b3b2645e3809f669a471921b1a9f8`
was produced at `dist/GunnAire-2026.09.12.1-development.xcarchive`.
`codesign --verify --deep --strict` passed. Identifier: `com.gunnaire.businesssuite`;
team: `7C4B3RR7RD`; authority: Apple Development. This is not an App Store distribution
archive, upload, physical-device acceptance, or production publication.

DSM now has separate FirewallBackups, SecurityLogs, LocalAIReports, ReleaseEvidence,
and BusinessBackups shares on its encrypted Btrfs volume, with data-integrity checks,
guest denial and administrator access. ReleaseEvidence mounts on the Mac.
Daily snapshots with seven latest retained are saved and show Scheduled for these
five shares and GunnAireLocalAI. Personal homes were not changed. Immutable/WORM
locking remains disabled. Log Center 1.3.2-2074, Snapshot Replication 7.5.1-1915 and
Hyper Backup 4.2.2-4262 were installed; package installation alone is not log receipt
or backup acceptance. Further dated target receipts are retained on the dedicated
ReleaseEvidence share under `production-closeout-20260912`.

An actual snapshot-file restore passed: a synthetic canary was snapshotted, changed,
and copied back from that snapshot into a separate empty folder. Restored SHA-256
matched the pre-change original and differed from the live modified file. See
`DEPLOYMENT_EVIDENCE/dsm-snapshot-restore.json`. No whole share or business record
was reverted. This still does not prove configuration/application or off-NAS restore.
