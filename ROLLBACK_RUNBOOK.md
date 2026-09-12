# Closeout rollback runbook

Status: PARTIALLY DEPLOYED. Do not interpret an untested procedure as a successful rollback.

## Repository

The owner's dirty iCloud checkout is untouched. The closeout worktree is separate.
Before merging, retain current main's SHA and the final closeout SHA. Reverting a
merge must be a new reviewed revert commit, never a destructive reset of owner work.
Do not close prior PRs until replacement content is committed and verified.

## Mac services and models

Before replacing any LaunchAgent, copy the exact existing plist and service files to
a timestamped rollback directory and hash them. Quiesce the local worker first.
After replacement, verify listener, authenticated positive/negative request, and
restart persistence. On failure, stop only the newly installed service, restore its
recorded files, bootstrap the original agent, and repeat its known health check.

The actual workbench and Synology bridge interpreter migration retained original
LaunchAgent plists under `~/.gunnaire-local-ai/service-rollback-20260912.Cymefu/`.
Both now use `~/.gunnaire-local-ai/production-venv/bin/python`; both restarted and
the workbench returned HTTP 200. The original Documents QA environment remains intact.
This interpreter migration has restart evidence, not an executed rollback or reboot.

NAS model storage currently has a retained local rollback directory named
`models-local-rollback-20260912` under the owner's `.ollama` directory. It has not been
deleted. Repointing models requires stopping inference first and verifying the
selected inventory; do not replace a live model path during a request.

## Network

No network cutover has occurred. Export the real router/firewall/switch/AP configs
and hash them before changing any network. A working console or out-of-band route,
known-good original router, cabling map, and physical operator are prerequisites.
Do not enable proposed VLAN/firewall settings from this repository blindly.
If management or business connectivity fails during a future approved migration,
restore the previous device group and original config using the verified console
route. Retain failed and restored connectivity evidence.

## Synology

Retain the drive recovery key outside the NAS; never commit it or include it in release
archives. Do not disable existing management access or administrator accounts until
an independently verified recovery login exists. The synthetic file-restore evidence
does not qualify a whole-system rollback. DSM configuration and application restores
must be tested separately before relying on them.
