# Isolated Linux quota validation

This is validation preparation, not deployment authorization. Product/backend/native
source is unchanged by this patch. Linux execution has not yet been performed.

## Execution route

The existing `backend-regression.yml` already exists on GitHub's default branch
and supports manual dispatch. A new `linux-quota` job calls the local reusable
`linux-quota-validation.yml` only for `workflow_dispatch` on
`validation/linux-quota-*`. The reusable job repeats that guard and restricts the
repository to `Autbellum/GunnAire-Ops`. No new push, PR or main trigger is added.
Ordinary backend matrix tests still run as part of the existing manual workflow.
A new standalone dispatch workflow would require default-branch registration;
this route does not require merging the candidate to main first.

The reusable job uses standard `ubuntu-24.04`, exact Python 3.14.3 and canonical
requirements. Official checkout/setup-python/upload-artifact actions are pinned
to verified commit objects. Permission is only `contents: read`; checkout does
not persist credentials; no secrets are passed or inherited. Synthetic reports
are retained for 14 days even after failure. The repository is public: branch
source and workflow artifacts must be treated as public. No customer data or
production tokens belong in this workflow.

No Docker installation, image pull, Parallels initialization, Mac daemon or
persistent remote service is needed. Python/dependencies are installed only in
the ephemeral hosted runner. A uniquely named transient systemd service runs
as the unprivileged runner user, using an explicit synthetic environment. Only
that service is stopped/reset during cleanup. No host-wide cache flush occurs.

## Required gates

`Tools/validate_linux_quota.py` starts the actual `python gunnaire_backend.py`
from `Backend`, not a wrapper server. `Tools/quota_runtime.py` verifies its PID,
command, working directory and cgroup membership, and verifies the workload
client is outside that cgroup. The kernel must report:

- `memory.max = 512000000` bytes;
- `memory.swap.max = 0`;
- `cpu.max` quota/period ratio exactly 0.5;
- valid `memory.current`, `memory.peak`, and OOM counters.

Missing controls or telemetry fail; no unconstrained fallback exists. Memory
peak includes cgroup-accounted file cache, unlike Mac process RSS. Fixture-file
cache receives a scoped `POSIX_FADV_DONTNEED` request before service startup;
shared host/runtime pages can still differ from Render. This is not a complete
replica of Render's host, disk quota, configuration or live database.

Both the 15-wave and 45-wave runs keep the original 24-client mix: eight 64 MiB
slow downloads, eight 12 MiB uploads, four near-1 MiB invalid metadata writes,
four prepared replica reads, plus health checks, partial headers and automatic
fixture backup. The unchanged headroom target is **409600000 bytes**. Full
workload completion, no OOM, health under five seconds, exact document hashes,
prepared replica hash equality and verified backup are mandatory. Definite GET
rejections retry the original route. Uncertain uploads are recorded, never
blindly replayed. Certifi must resolve to at least 2026.10.19.

Client/source fixtures and synthetic keys never come from production. Local
`--local-smoke` tests fixture/verdict logic only and labels its result explicitly
as not Linux quota evidence. CI never supplies that flag. The CI controller
refuses Mac, self-hosted, wrong-repository, non-manual and non-validation refs.

## Local validation performed

- Workflow YAML parsed with Ruby/Psych; trigger/permission/pinning/credential
  safety assertions passed. `actionlint` is not installed; GitHub's server-side
  validation and actual Ubuntu/systemd execution remain pending.
- Expanded Tools suite: 104 tests passed, including malformed/missing cgroup
  data, swapped/unlimited CPU/memory controls, invalid triggers, incomplete
  evidence, OOM/headroom failure, corrupt content and missing retry checks.
- Packaged same fifteen-wave local smoke: 246677504-byte sampled RSS peak,
  93.112 seconds, all checks passed. Python 3.14.7 / Certifi 2026.10.23 on macOS;
  this is not the required Python 3.14.3 Linux result.

## Approval and commands (not executed)

First recheck Render's tracked branch, preview/deploy hooks and any external
webhooks. Local workflow inspection shows existing push triggers restricted to
main, but that does not establish Render behavior. If a deployment freeze is
needed, obtain separate approval before changing it. Never force-push.

After the exact local preparation commit is approved:

```sh
git push https://github.com/Autbellum/GunnAire-Ops.git <APPROVED_SHA>:refs/heads/validation/linux-quota-20261030
gh workflow run backend-regression.yml --repo Autbellum/GunnAire-Ops --ref validation/linux-quota-20261030
```

Verify the remote branch and resulting run `head_sha` equal the approved SHA;
do not interpret an older run as evidence. The job also checks checkout HEAD
against `GITHUB_SHA`. Stop for permission/runner/billing errors; no grants,
credentials, paid runners or policy changes are implied.

GitHub read-only policy inspection on October 30 found Actions enabled,
`allowed_actions: all`, `sha_pinning_required: false`, default workflow permission
`read`, and PR-review approval disabled. Repository is public, enabled and not
archived. Standard public-repository hosted runner compute is free under current
GitHub documentation; artifact storage allowances/billing were not inspected.
No spending limit or paid-service change is proposed.

References:
- https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_dispatch
- https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html
- https://docs.github.com/en/billing/concepts/product-billing/github-actions
