# GunnAire Firewall Deployment Checklist

Generated from the checked-in proposed network, rule, and update-policy files.

> This is a controlled checklist, not an importable OPNsense configuration. Proposed addresses and rules require live verification.

## 1. Evidence and rollback before change

- [ ] Photograph and label the modem/ONT, router, switch, access points, NAS, firewall appliance, and cables.
- [ ] Export the existing router/firewall configuration and verify the backup can be opened.
- [ ] Record ISP addressing, bridge/passthrough requirements, current subnets, reservations, port forwards, VPNs, and SSIDs.
- [ ] Inventory every connected device and required application flow.
- [ ] Confirm local-console access to the firewall and a tested physical rollback cable path.
- [ ] Name a stop/rollback decision owner and schedule a maintenance window.

## 2. Dedicated OPNsense appliance

- [ ] Verify NIC compatibility and assign WAN/LAN interfaces by physical port and MAC address.
- [ ] Install the current OPNsense production release and supported security fixes.
- [ ] Create unique administrator credentials and retain emergency recovery material offline.
- [ ] Disable UPnP and NAT-PMP.
- [ ] Restrict the management UI to MGMT and later authenticated VPN_ADMIN clients.
- [ ] Export and hash the known-good base configuration before adding VLANs.

## 3. VLANs, switch, and wireless

- [ ] Create MGMT VLAN 10 using 10.77.10.0/24 only after conflict checks; Firewall, switch, and access-point administration.
- [ ] Create BUSINESS VLAN 20 using 10.77.20.0/24 only after conflict checks; Trusted office Macs, iPads, and workstations.
- [ ] Create SERVERS VLAN 30 using 10.77.30.0/24 only after conflict checks; GunnAire application and backend services.
- [ ] Create NAS VLAN 40 using 10.77.40.0/24 only after conflict checks; Synology storage, encrypted backups, and retained logs.
- [ ] Create IOT VLAN 50 using 10.77.50.0/24 only after conflict checks; Printers, thermostats, cameras, and constrained devices.
- [ ] Create GUEST VLAN 60 using 10.77.60.0/24 only after conflict checks; Internet-only guest access with client isolation.
- [ ] Create DEV_AI VLAN 70 using 10.77.70.0/24 only after conflict checks; Xcode, local Ollama, testing, and development systems.
- [ ] Create VPN_ADMIN VLAN 80 using 10.77.80.0/24 only after conflict checks; WireGuard administrative remote-access clients.
- [ ] Configure switch trunks and access ports; migrate one device class at a time.
- [ ] Map approved SSIDs to VLANs and enable guest/client isolation where supported.
- [ ] Reserve infrastructure addresses and document DHCP ranges outside static blocks.
- [ ] Force clients to use firewall DNS and NTP services.

## 4. Firewall policy

- [ ] Apply default deny between VLANs and to egress before adding explicit allows.
- [ ] Create aliases for approved cloud APIs, Synology updates, and individual IoT vendors.
- [ ] Implement and review actual OPNsense evaluation order and quick-rule behavior.
- [ ] Enable logging for WAN, administrative, cross-zone, server, NAS, and default-deny decisions.
- [ ] Approve WAN-010 (disabled in proposal): WAN → FIREWALL UDP/51820; WireGuard endpoint; enable only after keys, routing, logging, revocation, and recovery are verified.
- [ ] Approve MGMT-010 (enabled in proposal): MGMT → FIREWALL TCP/443; Firewall web administration from the management VLAN.
- [ ] Approve VPN-010 (disabled in proposal): VPN_ADMIN → FIREWALL TCP/443; Firewall administration after authenticated WireGuard connection.
- [ ] Approve BUS-040 (enabled in proposal): BUSINESS → NAS TCP/443,445; Approved Synology management and SMB access.
- [ ] Approve BUS-050 (enabled in proposal): BUSINESS → SERVERS TCP/443; Production application access over TLS.
- [ ] Approve SRV-030 (enabled in proposal): SERVERS → INTERNET TCP/443; Apple, Google, QuickBooks, payment, and approved vendor APIs.
- [ ] Approve SRV-040 (enabled in proposal): SERVERS → NAS TCP/443,445; Application backup and retained artifacts.
- [ ] Approve NAS-030 (enabled in proposal): NAS → INTERNET TCP/443; Synology updates and approved backup targets.
- [ ] Approve IOT-030 (disabled in proposal): IOT → INTERNET TCP/443; Per-device vendor updates after traffic observation and approval.
- [ ] Approve DEV-030 (enabled in proposal): DEV_AI → INTERNET TCP/80,443; Development packages, documentation, and model downloads.
- [ ] Approve DEV-040 (disabled in proposal): DEV_AI → SERVERS TCP/443; Explicit development-to-staging access; never production by default.

### Rules intentionally disabled

- [ ] Keep WAN-010 disabled until prerequisites are verified: WireGuard endpoint; enable only after keys, routing, logging, revocation, and recovery are verified.
- [ ] Keep VPN-010 disabled until prerequisites are verified: Firewall administration after authenticated WireGuard connection.
- [ ] Keep IOT-030 disabled until prerequisites are verified: Per-device vendor updates after traffic observation and approval.
- [ ] Keep DEV-040 disabled until prerequisites are verified: Explicit development-to-staging access; never production by default.

## 5. IDS/IPS and threat updates

- [ ] Enable Suricata in IDS alert-only mode on the correct parent interfaces.
- [ ] Set HOME_NET to every approved internal subnet and disable incompatible hardware offloading where required.
- [ ] Use multiple supported feeds; do not treat a free feed as complete standalone coverage.
- [ ] Refresh Suricata rules every 4 hours and alert after 12 hours of staleness.
- [ ] Validate and compile updates before activation, retain the last-known-good ruleset, and test rollback.
- [ ] Observe alerts for at least 48 hours before promoting selected high-confidence signatures to drop.
- [ ] Document every suppressed signature with evidence, owner, scope, and review date.

## 6. DNS protection

- [ ] Use Unbound as the local resolver and enable DNSSEC unless a verified incompatibility exists.
- [ ] Block direct client DNS/DoT bypass except narrow documented exceptions.
- [ ] Refresh DNS threat lists every 24 hours and alert after 36 hours.
- [ ] Use narrow allowlists instead of disabling protection for an entire zone.

## 7. WireGuard administration

- [ ] Generate unique per-device keys and maintain an owner/device/revocation inventory.
- [ ] Keep the WAN WireGuard rule disabled until endpoint, routing, logs, loss/revocation, and recovery are tested.
- [ ] Limit VPN_ADMIN to required administrative destinations.
- [ ] Verify lost-device revocation without exposing the firewall or NAS management UI to the internet.

## 8. Business acceptance

- [ ] Verify GunnAire Ops sign-in, CloudKit sync, push notifications, and associated-domain callbacks.
- [ ] Verify QuickBooks authorization, token refresh, callbacks/webhooks, and read/write boundaries.
- [ ] Verify Google sign-in, mail/calendar workflows, and callbacks.
- [ ] Verify payment handoff without unauthorized live charges or marking an invoice paid.
- [ ] Verify Apple signing/notarization traffic only from approved development systems.
- [ ] Verify Synology backup, restore, and log receipt with least-privilege service accounts.
- [ ] Verify printers and required IoT devices without lateral access.

## 9. Security validation

- [ ] Run an external scan from outside the business connection; only the approved VPN endpoint may answer.
- [ ] Test every prohibited cross-VLAN path and retain evidence.
- [ ] Test DNS bypass, rogue DHCP resistance, client isolation, and management-interface restrictions.
- [ ] Confirm Ollama remains loopback-only and is unreachable from another device.
- [ ] Test failed/stale threat-feed alerts, Suricata restart, and last-known-good rollback.
- [ ] Review false positives and unexplained egress before enabling additional drop policies.

## 10. Accepted configuration and recovery

- [ ] Export the accepted configuration and record its checksum, software version, and date.
- [ ] Store encrypted copies offline and on the hardened Synology share.
- [ ] Document device-to-port/VLAN assignments and administrator recovery steps.
- [ ] Perform a controlled restore test or vendor-supported equivalent.
- [ ] Record the go/no-go decision, unresolved risks, and responsible approver.

## Acceptance statement

The firewall is not production-accepted until critical checklist items are complete, prohibited paths are proven blocked, required business workflows pass, recovery evidence is retained, and every enabled WAN or administrative rule has explicit approval.
