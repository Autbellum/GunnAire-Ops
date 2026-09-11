# GunnAire Firewall Deployment Checklist

Generated from the checked-in proposed network, rule, and update-policy files.

> This checklist is not an importable firewall configuration. Proposed addresses and rules require live verification.

## 1. Evidence and rollback

- [ ] Photograph and label modem/ONT, router, switch, access points, NAS and every cable.
- [ ] Export the current router/firewall configuration and verify the backup is readable.
- [ ] Record ISP WAN addressing, bridge/passthrough requirements, DHCP reservations, static addresses, VPNs, port forwards and SSIDs.
- [ ] Confirm direct local-console access to the new firewall and a physical rollback cable path.
- [ ] Inventory all business devices, applications, destinations and ports.
- [ ] Schedule a maintenance window and name the stop/rollback decision owner.

## 2. Dedicated OPNsense appliance

- [ ] Verify firewall NIC compatibility and assign WAN/LAN by physical MAC address.
- [ ] Install the current production release and supported security updates.
- [ ] Create unique administrator credentials and store recovery material offline.
- [ ] Disable UPnP and NAT-PMP.
- [ ] Restrict management to MGMT and, after acceptance, authenticated VPN_ADMIN clients.
- [ ] Export and hash the known-good base configuration.

## 3. VLANs and DHCP

- [ ] Create MGMT VLAN 10 using 10.77.10.0/24 only after conflict checks; Firewall, switch and access-point administration.
- [ ] Create BUSINESS VLAN 20 using 10.77.20.0/24 only after conflict checks; Trusted office Macs, iPads and business workstations.
- [ ] Create SERVERS VLAN 30 using 10.77.30.0/24 only after conflict checks; GunnAire application and backend services.
- [ ] Create NAS VLAN 40 using 10.77.40.0/24 only after conflict checks; Synology storage, encrypted backups and retained logs.
- [ ] Create IOT VLAN 50 using 10.77.50.0/24 only after conflict checks; Printers, thermostats, cameras and constrained devices.
- [ ] Create GUEST VLAN 60 using 10.77.60.0/24 only after conflict checks; Guest internet access with client isolation.
- [ ] Create DEV_AI VLAN 70 using 10.77.70.0/24 only after conflict checks; Xcode, local Ollama, test services and development systems.
- [ ] Create VPN_ADMIN VLAN 80 using 10.77.80.0/24 only after conflict checks; WireGuard administrative remote-access clients.
- [ ] Configure managed-switch trunks/access ports and migrate one device group at a time.
- [ ] Map wireless SSIDs to approved VLANs and enable guest/client isolation.
- [ ] Reserve infrastructure addresses and document DHCP ranges.
- [ ] Enforce firewall DNS and NTP per VLAN.

## 4. Policy staging

- [ ] Apply default deny between VLANs before specific allows.
- [ ] Create aliases for business cloud APIs, Synology updates and approved IoT vendors.
- [ ] Confirm actual OPNsense rule evaluation order before cutover.
- [ ] Log WAN, cross-zone, administrative, server, NAS and default-deny rules.
- [ ] Approve WAN-010: WAN → FIREWALL UDP/51820; WireGuard endpoint; enable only after keys, routing, revocation and recovery are tested.
- [ ] Approve MGMT-010: MGMT → FIREWALL TCP/443; Firewall administration from management VLAN.
- [ ] Approve VPN-010: VPN_ADMIN → FIREWALL TCP/443; Firewall administration after authenticated WireGuard connection.
- [ ] Approve BUS-040: BUSINESS → NAS TCP/443,445; Approved Synology management and SMB access.
- [ ] Approve BUS-050: BUSINESS → SERVERS TCP/443; Production application access over TLS.
- [ ] Approve SRV-030: SERVERS → INTERNET TCP/443; Apple, Google, QuickBooks, payment and approved vendor APIs.
- [ ] Approve SRV-040: SERVERS → NAS TCP/443,445; Application backup and retained artifacts.
- [ ] Approve NAS-030: NAS → INTERNET TCP/443; Synology updates and approved backup destinations.
- [ ] Approve IOT-030: IOT → INTERNET TCP/443; Per-device vendor access after traffic observation and approval.
- [ ] Approve DEV-030: DEV_AI → INTERNET TCP/80,443; Development packages, documentation and model downloads.
- [ ] Approve DEV-040: DEV_AI → SERVERS TCP/443; Explicit development-to-staging access; never production by default.

### Keep disabled until prerequisites pass

- [ ] Keep WAN-010 disabled: WireGuard endpoint; enable only after keys, routing, revocation and recovery are tested.
- [ ] Keep VPN-010 disabled: Firewall administration after authenticated WireGuard connection.
- [ ] Keep IOT-030 disabled: Per-device vendor access after traffic observation and approval.
- [ ] Keep DEV-040 disabled: Explicit development-to-staging access; never production by default.

## 5. IDS/IPS and threat intelligence

- [ ] Enable Suricata in IDS alert-only mode on the correct interfaces.
- [ ] Set HOME_NET to all approved internal subnets and verify offloading compatibility.
- [ ] Enable multiple supported feeds; never treat one free feed as complete coverage.
- [ ] Refresh signatures every 4 hours and alert after 12 hours.
- [ ] Validate/compile before activation; retain and test the last-known-good rollback.
- [ ] Observe alert-only behavior for at least 48 hours before selected high-confidence drops.
- [ ] Document suppressed signatures with reason, owner, scope and review date.

## 6. DNS protection

- [ ] Use Unbound locally and enable DNSSEC unless a documented compatibility issue exists.
- [ ] Block direct DNS/DoT bypass except narrowly approved services.
- [ ] Refresh DNS threat lists every 24 hours and alert after 36 hours.
- [ ] Use narrow allowlist entries rather than disabling a whole VLAN policy.

## 7. WireGuard

- [ ] Generate unique per-device keys and maintain owner/device inventory.
- [ ] Keep WAN-010 disabled until endpoint, keys, routing, logging and revocation are tested.
- [ ] Limit VPN_ADMIN to required administrative destinations.
- [ ] Test lost-device revocation and emergency access without exposing the management UI.

## 8. Business workflow acceptance

- [ ] Verify GunnAire Ops sign-in, CloudKit sync, push and associated-domain callbacks.
- [ ] Verify QuickBooks OAuth, refresh, callback/webhook and read/write boundaries.
- [ ] Verify Google sign-in, mail/calendar and callback workflows.
- [ ] Verify payment handoff without unauthorized charges or marking invoices paid.
- [ ] Verify Apple signing/notarization traffic only from approved development systems.
- [ ] Verify Synology backup, restore and log receipt through least-privilege accounts.
- [ ] Verify printers/IoT without lateral access.

## 9. Security verification

- [ ] Run an outside port scan; only the approved VPN endpoint may answer.
- [ ] Test every prohibited cross-VLAN path and retain results.
- [ ] Test DNS bypass, rogue DHCP, guest isolation and management restrictions.
- [ ] Confirm Ollama remains loopback-only and unreachable from another device.
- [ ] Test failed/stale feed alerts, Suricata restart and last-known-good rollback.
- [ ] Review false positives and unexplained egress before enabling new drops.

## 10. Acceptance and recovery

- [ ] Export accepted configuration and record checksum, version and date.
- [ ] Store encrypted copies offline and on the hardened Synology share.
- [ ] Document device-to-port/VLAN assignments and administrator recovery.
- [ ] Perform a controlled restore validation.
- [ ] Record final go/no-go, unresolved risks and approver.

## Acceptance statement

Production acceptance requires completed critical items, verified blocked paths, passing business workflows, retained recovery evidence, and explicit approval for every enabled WAN or administrative rule.
