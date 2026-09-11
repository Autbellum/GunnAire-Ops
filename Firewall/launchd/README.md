# Scheduled Suricata reporting

Run `../setup_local_reporting.sh` only after OPNsense exports or forwards a readable EVE JSON file to the Mac or a hardened Synology share. The installer generates the user LaunchAgent with exact paths, runs at 6:30 AM, stores reports with restrictive permissions, and never invokes AI or changes firewall policy.
