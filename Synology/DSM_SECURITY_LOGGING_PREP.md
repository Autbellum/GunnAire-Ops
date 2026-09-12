# Synology DS925+ Security, Logging, and Backup Preparation

Status: **prepared, not applied**. Complete this only after DSM installation and storage-pool health checks finish.

## Intended role

The DS925+ stores retained firewall logs, encrypted firewall configuration backups, local-AI reports, test artifacts, and business backups. It is not the perimeter firewall and should have no direct internet-facing DSM, SMB, SSH, or Log Center port.

## 1. Base DSM hardening

- Install the current supported DSM production release and all applicable package/security updates.
- Create a named administrator account, verify recovery, then disable the default `admin` account.
- Require strong unique passwords and multi-factor authentication for administrators.
- Set automatic account blocking and login protection.
- Disable SSH, Telnet, FTP, WebDAV, QuickConnect, UPnP router configuration, and unused packages unless a documented business workflow requires them.
- Use HTTPS with a trusted local or public certificate; do not bypass certificate warnings during administration.
- Restrict DSM administration to the proposed `MGMT` VLAN and later authenticated `VPN_ADMIN` clients.
- Configure DSM's local firewall as a second layer: permit only required management, backup, SMB, and log traffic from explicit GunnAire subnets; deny everything else.
- Enable notifications for failed logins, storage degradation, update failures, backup failures, malware events, and unexpected shutdowns.

## 2. Storage layout

Create separate shared folders so one service account cannot access all retained data:

| Shared folder | Purpose | Suggested access |
|---|---|---|
| `GunnAire-Firewall-Config` | Encrypted OPNsense configuration exports and checksums | firewall backup writer; security administrators read |
| `GunnAire-Security-Logs` | OPNsense/Suricata/DNS/VPN retained logs | syslog writer; security administrators read |
| `GunnAire-LocalAI-Reports` | Redacted local QA and threat summaries | Mac Studio writer; project administrators read |
| `GunnAire-App-Artifacts` | Signed release evidence, test results, manifests | release process writer; project administrators read |

Use Btrfs where supported. Enable checksums, snapshots, and a retention policy appropriate to available capacity. Shared-folder encryption protects data at rest but requires a separate, tested key-recovery procedure; do not store the only encryption key on the NAS.

## 3. Least-privilege service accounts

Create separate non-administrator accounts:

- `svc_firewall_config_backup`: write-only or append-oriented access to `GunnAire-Firewall-Config` where the selected protocol permits it.
- `svc_firewall_syslog`: receives only firewall/log data into `GunnAire-Security-Logs`.
- `svc_mac_local_ai`: writes only redacted local-AI reports.
- `svc_release_archive`: writes release evidence but cannot modify firewall logs.

Deny interactive DSM access for service accounts where DSM supports that restriction. Never reuse the administrator password for SMB, rsync, syslog, or backup jobs.

## 4. Log Center

Install the full Synology **Log Center package**, not only the built-in viewer, when DSM lists it for the DS925+. The package supports receiving logs from network devices over TCP or UDP, standard RFC 3164/RFC 5424 formats, archival policies, search, alerts, and secured SSL connections when certificates are configured.

Preferred design:

1. OPNsense sends system, firewall, VPN, IDS/IPS, DNS, update, and administrative-change logs from `MGMT` to the NAS.
2. Use TLS-protected syslog when the OPNsense and DSM versions support an interoperable configuration; otherwise keep unencrypted syslog isolated to the management network and document the limitation.
3. Permit the chosen receiver port only from the firewall's management address.
4. Create alerts for authentication failures, administrator changes, Suricata stoppage, stale feeds, blocked malware/C2 events, configuration changes, disk pressure, and log-receiver failure.
5. Archive by time and capacity, and test search/export before relying on the NAS as evidence storage.

## 5. Firewall configuration backups

- Export a known-good OPNsense configuration before each approved change.
- Encrypt the export before or during transport where the chosen backup method supports it.
- Record SHA-256, firewall version, date, change ID, and the responsible approver.
- Retain the last-known-good configuration separately from routine rotating copies.
- Test restoration using vendor-supported procedures and a controlled maintenance window.

## 6. Backup design

Snapshots and RAID are not complete backups. Use a multi-version local recovery layer plus an additional disconnected or off-site copy. The purchased external drive can serve as one rotation target once Hyper Backup or another verified DSM backup method is configured.

Minimum evidence:

- Scheduled snapshots for protected Btrfs shared folders.
- Hyper Backup or equivalent to the external drive with versioning and integrity checks.
- A second off-site or normally disconnected copy for critical business data and configuration.
- Quarterly restore tests covering one file, one shared folder, and firewall configuration recovery documentation.
- Notification on missed backup, integrity failure, low space, failed snapshot, or disconnected destination.

## 7. Network cutover acceptance

Do not move the NAS into the proposed `NAS` VLAN until:

- The DSM management address, switch port, and rollback method are recorded.
- Business Macs can reach only the required DSM/SMB services.
- Servers can reach only approved backup services.
- Guest and IoT networks cannot reach the NAS.
- The NAS cannot initiate broad access to business or management networks.
- Internet egress is limited to approved update/backup destinations.
- Backups, restores, alerts, time sync, DNS, UPS shutdown, and Log Center reception pass.

## Current boundary

No DSM account, folder, package, firewall rule, share, snapshot, or backup job has been created by this package. This is the exact implementation checklist for the live DSM session once setup is complete.
