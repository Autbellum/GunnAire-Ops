# Production acceptance

Status: PARTIALLY DEPLOYED. Updated during closeout on 2026-09-12.

| Target | Verified evidence | Remaining acceptance |
|---|---|---|
| Repository | Cumulative PR 23 committed and pushed; first full commit-bound release run passed all 12 scopes | Follow-up release run, remote CI, merge |
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
