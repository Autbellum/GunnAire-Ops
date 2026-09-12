# Production acceptance

Status: PARTIALLY DEPLOYED. Updated during closeout on 2026-09-12.

| Target | Verified evidence | Remaining acceptance |
|---|---|---|
| Repository | Main and open PRs inspected; combined worktree; full backend regression exits 0; routing audit zero violations | Commit-bound release run, remote CI, merge |
| Mac Studio | M4 Max, 64 GB; Ollama 0.34.0 listening on 127.0.0.1:11434; local model advisory returned | Candidate benchmarks, selected configuration/service deployment, authenticated app request, reboot recovery |
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
