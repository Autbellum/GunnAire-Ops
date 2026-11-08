# Hotfix working agreement

This isolated checkout starts at deployed c6d4077. Preserve the separate tested
completion checkout. No main push, PR, deployment, provider calls, credentials,
configuration or production data changes are authorized here.

## Claims
- 2026-11-08 Codex owns a narrow resource-lifetime hotfix: database context closure,
  bounded HTTP entrypoints, patched Certifi requirement, synthetic reproductions
  and regression evidence. Preserve existing schema and business behavior.
- Extend claim to unchanged synthetic Linux validation harness/workflow preparation
  copied from tested 3d405828. Do not publish or dispatch a new branch without
  branch-specific approval and fresh trigger isolation. Do not weaken gates.
- Update only the backup-startup test's server mock target to BoundedBusinessServer;
  preserve worker ordering and assertions. Full baseline suite exposed the stale
  ThreadingHTTPServer test reference after the entrypoint change.
- 2026-11-08 Codex local validation complete: deployed-code baseline reproduced
  four database-close failures and admitted excess HTTP connections. Narrow
  hotfix passes 1271 full backend tests, 25 focused tests, 97 tooling tests and
  14 quota harness tests. The first full run's sole stale mock error was fixed
  without weakening assertions; original failure log retained. Legacy fixture
  ResourceWarnings remain visible. Normal-GC 9000 empty polls closed all handles;
  no 36-hour cause claim. Handler/initializer/key-loader ASTs unchanged. New-source
  Linux quota validation remains pending; old candidate results are not reused as
  its pass. Claims released for review; no publication, dispatch or deployment.
