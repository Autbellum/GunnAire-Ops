# Optional outbound Mac worker

`outbound_worker.py` is an explicitly invoked, serial worker for the hosted
business backend's Local AI relay. It opens no listener, exposes no Ollama port,
installs no service and changes no production configuration. It performs no
business action: model output is a draft requiring staff review.

The hosted relay must be deployed with one process and one replica while its
queue is process-local. A healthy backend is not evidence that a Mac worker is
connected. The relay's live worker heartbeat, an accepted synthetic job, and
independent end-to-end evidence are separate readiness checks. This worker's
unit tests use injected clients, temporary files and loopback HTTP fixtures;
they do not prove deployed backend, physical app or current Mac availability.

## Backend relay configuration for owner review

This is a preparatory runbook, not evidence of a deployment or authorization to
change production. Review the selected commit, existing deployment settings and
rollback plan before applying a configuration change. No credentials, service
installation or deployment is performed by this document.

The backend must run the `Backend.gunnaire_local_ai_backend` entrypoint to serve
these routes. Setting relay variables on an older business-only entrypoint does
not add them. Use one backend process and one replica, with all app and worker
requests routed to that process. The queue, claims and heartbeat are in memory;
multiple processes/replicas do not share them. A load-balanced multi-replica
configuration is unsupported by this implementation.

| Backend environment variable | Optional relay configuration and source |
| --- | --- |
| `GUNNAIRE_LOCAL_AI_TRANSPORT` | Set to `outbound-worker` only for the reviewed relay deployment. Default is `loopback`; other values fail configuration. |
| `GUNNAIRE_LOCAL_AI_ENABLED` | Default enabled. `0`, `false`, `no`, `off` or `disabled` disable assistance; `1` explicitly enables it. |
| `GUNNAIRE_LOCAL_AI_COMPANY_ID` | Required canonical company UUID from the authoritative business database's `company_identity` singleton. It must equal the Mac configuration's `company_id`. Do not invent a second company identity. |
| `GUNNAIRE_LOCAL_AI_WORKER_ID` | Required dedicated worker ID, 1–64 characters from `[A-Za-z0-9_-]`, exactly matching the Mac's `worker_id`. |
| `GUNNAIRE_LOCAL_AI_WORKER_TOKEN` | Required separate secret provisioned through the backend's protected secret configuration; 32–512 ASCII characters from `[A-Za-z0-9._~+/=-]`. The Mac receives the same value in its protected token file, never in its JSON configuration or process arguments. |
| `GUNNAIRE_LOCAL_AI_MODEL_DIGEST` | Required `81a62afe947e7718a8f075fd78f1e9a98597e1bf4d521c5a770eb7531c47977b`. The backend parser accepts an optional `sha256:` prefix and normalizes case; the worker requires the exact digest above. |

`RelaySettings.from_env` exposes those four required identity/credential/digest
fields; it does not expose model choice, job lifetime, heartbeat lifetime or
queue capacity as environment overrides. The model is fixed to
`gunnaire-coder:ops`; defaults are a 90-second maximum job lifetime, a 15-second
heartbeat lifetime and at most four jobs. Existing gateway input/context limits
still apply. Increasing a gateway timeout does not extend the relay admission
deadline or the worker's remaining lifetime.

Read the company identity using an approved read-only database inspection:
`SELECT company_id FROM company_identity WHERE singleton = 1`. Do not alter that
row to make a worker match. The route checks the authoritative identity again,
and rejects a mismatch. The worker secret is rejected if it equals the backend
API token or hashes to any retained application-session credential. Provision
a new dedicated worker secret rather than reusing either credential. A worker
credential authorizes only the three worker routes, never the business API.

Outbound assistance requires the existing `GUNNAIRE_BACKEND_AUTH_MODE` to be
`google-id-token` and a real, active business application session in the
`Authorization` header. That is the configured mode's historical name, not a
Google-provider-only restriction: supported Apple-created business sessions
remain valid. The existing Google mode configuration/dependencies, including
`GUNNAIRE_GOOGLE_CLIENT_ID`, must already be correct; do not replace those values
with worker credentials. A standalone `X-GunnAire-Google-ID-Token` without an
application session, or development `api-token` mode, cannot submit relay jobs.
The original session, active user, role and company are rechecked before result
release; the model cannot grant authority.

With the default `loopback` transport, the backend uses its existing local
Ollama gateway and worker POST routes return 404. Worker GET routes always
return 404. Setting `GUNNAIRE_LOCAL_AI_ENABLED=0` prevents assistance but does not
by itself remove worker route definitions when `outbound-worker` is selected.
Transport/configuration is cached for the process, including configuration
failures: environment changes require a controlled backend restart to take
effect. They are not a live toggle.

## Acceptance and rollback

For a later approved deployment/configuration change:

1. Confirm the reviewed source revision, single process/replica, protected
   secret separation and exact company/worker/model mapping. Preserve the prior
   configuration for rollback without copying secret values into a report.
2. Start the Mac worker explicitly with the protected configuration. A first
   `--once` can heartbeat and return `idle`; it does not remain connected as a
   polling service. Use an explicitly bounded loop for subsequent requests.
3. Through a current authenticated business session, read
   `GET /api/local-ai/status`. Before a heartbeat or after its expiry, expect
   `available: false`. A fresh eligible worker may report
   `endpointScope: outbound-worker`, `status: ready` and available tasks. A
   heartbeat proves authenticated readiness, not successful inference.
4. Submit one clearly synthetic, authorized request to
   `POST /api/local-ai/assist` while the worker is polling. Use a reviewed client
   that reads credentials from protected storage; do not put bearer tokens in
   shell arguments. Retain HTTP status, elapsed time, exact source/model digest,
   validated response, empty queue and one hashed ledger entry. Require a fresh
   response (`cached: false`), advisory/review flags and no hosted fallback.
5. Independently check authorization revocation, unavailable-worker behavior and
   duplicate/expired-claim rejection with synthetic fixtures. Then verify the
   signed app's actual navigation, current session and review-only draft flow
   on its target device before claiming app or field readiness. Do not send
   customer messages or apply a generated result as part of this smoke test.

To stop the Mac side, interrupt its explicitly invoked worker; no daemon needs
to be uninstalled. Preserve the attempt ledger. The heartbeat becomes stale
within 15 seconds, and outstanding jobs expire by their original admission
deadlines, at most 90 seconds; stopping the worker does not renew or requeue
them. A timed-out or interrupted completion remains unconfirmed, not permission
to regenerate the same attempt.

To disable the optional backend path after an approved rollback decision, set
`GUNNAIRE_LOCAL_AI_TRANSPORT=loopback` and
`GUNNAIRE_LOCAL_AI_ENABLED=0`, then perform the controlled backend restart.
Worker POST routes should return 404 and assistance should be unavailable. To
restore an intentionally enabled former loopback gateway instead, restore its
previous reviewed enabled setting as well. Merely selecting `loopback` can
still allow backend-local Ollama assistance if that gateway is enabled; it is
not an all-AI off switch. A stopped/restarted backend loses its ephemeral queue;
there is no persisted job replay. Do not clear the Mac ledger to retry an
uncertain job. Leave existing provider/business configuration unchanged.

## Retained synthetic execution evidence

The source-bound `outbound-real-model-e2e-root.json` in
`/Users/gunnaire/Documents/GunnAireCompletion/2026-09-23-team-completion/`
records a successful synthetic loopback HTTP request through
`BoundedBusinessServer`, the real relay, a temporary business application
session and the actual pinned Ollama model. The worker used its default resource
guards and existing shared lock. It returned HTTP 200 / `completed` in 5.112
seconds overall, with an empty queue and exactly one hash-only ledger entry.
The response remained advisory, required human approval and was not cached.
No production credential or customer record was used. Source hashes in that
record bind the result to the tested code; later edits need their own checks.

The earlier `outbound-real-model-e2e.json` remains retained as a blocked attempt:
its sandbox denied the unchanged memory-pressure guard before heartbeat, claim
or inference. The successful root execution ran with that guard intact in an
authorized environment. Neither result proves a Render deployment, HTTPS
production connectivity, a physical iPad/Mac app flow, ongoing worker uptime or
permission to deploy. This runbook does not enable any of them.

## Operator configuration

Provision a dedicated company/worker credential through the reviewed backend
configuration process. Do not reuse a staff session, provider token or general
backend API token. This implementation does not create or install credentials.
Store its value in a regular, owner-only file (mode `0600`, no symlink/hardlink).
The token is read into memory; it is never placed in arguments, printed, or
written to the job ledger. TLS uses Python's default certificate verification.

Create a separate private JSON configuration with these exact keys:

```json
{
  "backend_origin": "https://your-reviewed-business-backend.example",
  "company_id": "00000000-0000-4000-8000-000000000001",
  "worker_id": "mac-studio-worker",
  "token_file": "/absolute/private/path/worker-token",
  "ledger_file": "/absolute/private/path/worker-attempts",
  "lock_file": "/Users/gunnaire/Documents/GunnAireLocalQA/runs/.lock"
}
```

The example is a schema illustration, not a usable deployment configuration.
Use the provisioned company UUID and worker ID. Configuration must be mode
`0600`; token/ledger parents must already exist and be owned by the operator.
The ledger and shared lock parent must be private (`0700`). CLI configuration
pins the existing GunnAireLocalQA lock path: no alternate production lock can
silently bypass other local workers. Synthetic constructors may use temporary
lock paths and explicit HTTP loopback fixtures; the CLI accepts HTTPS only.
The backend origin permits no user info, query, fragment or path prefix.

From the repository root, inspect one available job with:

```sh
python3 -m LocalAI.outbound_worker --config /absolute/private/path/worker.json --once
```

This command can run inference if a job is waiting. There is no automatic
startup. A repeated run must be explicit and bounded, for example `--loop 12`
(12 iterations with five seconds between them, at most 1,000). A busy lock,
resource failure, uncertain completion or expired job stops the invocation.
No scheduler or launch agent is installed. Only status codes are printed.
`completed` means the relay acknowledged an inference result, not that a user
applied it; `failed` means the relay acknowledged a failure report.

## Boundaries and failure behavior

- The only model is `gunnaire-coder:ops`, digest
  `81a62afe947e7718a8f075fd78f1e9a98597e1bf4d521c5a770eb7531c47977b`, at
  `http://127.0.0.1:11434`. Every job rechecks installed digest, active models,
  memory pressure and a 2 GiB disk reserve. An existing copy of that exact model
  may stay warm briefly. Another model or elevated pressure defers work.
  There is no model download, fallback, image endpoint or model tool execution.
- The shared `flock(LOCK_EX | LOCK_NB)` spans readiness, heartbeat, claim,
  inference and completion. It matches the existing `local_qa.py` lock protocol.
  It does not kill a competing model, steal a lock or import another checkout.
- HTTPS requests go directly to the configured origin, with no environment
  proxy or redirects. Requests and responses are capped at 128 KiB. Duplicate
  JSON keys, nonfinite numbers, malformed bindings and oversized responses are
  rejected. Each actual HTTP request runs in a short-lived spawned child with
  socket/read deadlines and a parent-enforced monotonic deadline, including OS
  name resolution. Timeout terminates and reaps that child; no prompt/token is
  passed in command arguments or written to disk. This is not a service.
- Admission lifetime is supplied by the backend (at most 90 seconds), measured
  conservatively from the start of the claim request. Queue age is already
  deducted by the relay. Discovery and inference use the remaining budget with
  a one-second completion margin. Expiry is checked before and after inference;
  an expired result is discarded. No phase starts a fresh 90-second budget.
- The worker reuses `LocalAIGateway` role, task, input, context, redaction and
  result validation. All model roles resolve to the same pinned model. Gateway
  prompt/result caches are disabled; input/output is retained only in memory
  for the current operation. This is not a guarantee of secure RAM erasure.
- Before inference, a durable ledger appends and fsyncs only the SHA-256 of
  `(company UUID, worker ID, job ID)`. Restarting the worker cannot rerun an
  attempted job. Neither prompt, result, token nor claim token is persisted.
  The ledger stops at 4,096 attempts; an operator must review retention and use
  a new approved worker identity/ledger when appropriate. Do not clear it to
  retry uncertain jobs. Preserve it across worker restarts.
- A claimed job is never requeued or automatically regenerated. Completion is
  sent once. Lost claim replies leave the backend's claim to expire; lost
  completion replies return `completion_uncertain`. Review the relay result
  before submitting a new business request. Model inference has no authority
  to send mail, change money, modify records, run commands or apply code.

## Wire contract and tests

All three calls are `POST /api/local-ai/worker/{heartbeat,claim,complete}` with
`Authorization: Bearer` from the separate token file and pinned `companyID` /
`workerID`. Heartbeat includes `ready`, `busy`, model/digest and local-only
capability flags. Claim returns `job: null` or a company/worker/job/claim-bound
request, actor role, task, exact model/digest and remaining `expiresInSeconds`.
Completion repeats its job/claim/task binding and supplies the validated gateway
envelope or a finite failure code. Expired, duplicate and unknown claims must
be rejected by the relay.

```sh
python3 -m unittest -v LocalAI.test_outbound_worker
```

Tests cover successful serial operation, disabled caches, expiry around claim
and inference, uncertain completion across restarts, unrelated identity/model
rejection, sensitive-input blocking, lock/resource refusal, protected token
files, ledger corruption/limits, JSON/HTTP bounds and exact model validation.
The HTTP regression uses only an ephemeral loopback fixture and checks both
direct and spawned transports. Tests never contact a deployed backend or invoke
an installed model.
