---
name: gunnaire-perf-measure
description: How to measure GunnAire Ops performance so the number means what it appears to mean. Use before trusting any launch, hang, or CPU figure, before profiling on Eric's iPad, and before claiming a fix worked. Covers the CloudKit-environment trap, the evidence sources that are safe, and the exact scoring method.
---

# Measuring GunnAire Ops performance

Every rule here was paid for on 2026-09-18. Read the "why" before skipping one.

## Rule 1: never install a dev-signed build on Eric's iPad

Eric's iPad and iPhone run TestFlight builds as production. `CompanyWorkspaceHost`
derives the CloudKit environment from the provisioning profile; both the development
and store profiles allow both environments, so it falls back to `get-task-allow`
(`CompanyWorkspaceHost.swift`, "Both permitted: disambiguate with get-task-allow").
Any debuggable build therefore reports **development**. Eric's lease is bound to
**production**, so `lease.isValid` fails, `authorizedContainer` is nil, and the app
runs with the workspace **denied**: an empty dashboard with no role.

Consequences, both observed:
- Every Instruments trace on such a build measures the denied state. A "0 hangs"
  result on it says nothing about his real app.
- Switching between a dev-signed install and TestFlight under the same local store
  has twice coincided with the store being lost or fully re-imported, which then
  freezes the app for a long time on his real data.

Instruments cannot attach to the TestFlight build at all: "must be signed with
'get-task-allow'". There is no supported way to profile his authorized production
workspace with Instruments. Do not try to invent one in the access gate.

## Rule 2: evidence from the real app comes from inside the app

`AppPerformanceDiagnostics` (shipped in 2026091612) records on the device:
- launch time from kernel process start to first drawn frame,
- every main-thread stall over 0.5 s with the screen that was open,
- MetricKit crash, hang, and slow-launch diagnostics with Apple's call stacks,
  delivered about once a day for the previous day.

Eric shares it from **Sync & Integrations → App Performance → Share this record**.
Ask for it first. Crash stacks arrive unsymbolicated as `GunnAire Ops +0x…`; resolve
them with `atos` against the matching archive's dSYM.

## Rule 2a: the iPad's own crash logs need no navigation and no GUI

When the recorder cannot be reached (the app is frozen, or the installed build
predates it), pull the system crash logs over the cable:
```
xcrun devicectl device copy from --device 77009867-44B8-550E-B726-5C8BE1E7E883 \
  --domain-type systemCrashLogs --source . --destination DIR
```
`GunnAire Ops-<date>.ips` (bug_type 309) is a crash; the JSON body after the first
line has `termination.reasons` (`0x8BADF00D` = watchdog), `faultingThread`, and
`usedImages[i].base`. `GunnAire Ops.cpu_resource-<date>.ips` (bug_type 202) is a
CPU-limit report with a "Heaviest stack" section. Symbolicate app frames with
```
atos -o "<archive>/dSYMs/GunnAire Ops.app.dSYM/Contents/Resources/DWARF/GunnAire Ops" \
  -arch arm64 -l <image base from the log> <absolute addresses>
```
Archives for builds 12 to 15 are under the unsandboxed temp dir `ship-<build>/`.
On 2026-09-19 this is what proved the three morning crashes were build 14 in the
formatter stack, while the recorder had been silent since the previous evening.

## Rule 2b: confirm which build is installed and which is available

```
xcrun devicectl device info apps --device <id> --bundle-id com.gunnaire.businesssuite
python3 .claude/skills/gunnaire-perf-measure/asc-builds.py
```
The second signs an App Store Connect token with the upload key (openssl, no
PyJWT) and prints each build's `processingState`; `VALID` means installable. Eric
was on the rollback build 14 while 15 sat processed and uninstalled; every
conclusion about "the fix did not work" must first check this.

## Rule 3: when Instruments is appropriate

Only on a simulator or on a device whose workspace is *meant* to be development,
and only with a Release build (`-configuration Release`, whole-module `-O`). Debug
is `-Onone` and exaggerates exactly the array work this app does. Every xctrace and
devicectl call needs the Bash sandbox disabled.

Record with:
```
xcrun xctrace record --template 'Time Profiler' --device <udid> --time-limit 45s \
  --no-prompt --output out.trace --launch -- com.gunnaire.businesssuite
```
Templates that worked: App Launch, Time Profiler, Data Persistence. Allocations
failed to attach twice (dyld overlap); memory is still unmeasured.

## Rule 4: score a trace by samples, not by frame definitions

Export with `xcrun xctrace export --input X.trace --xpath
'/trace-toc/run[@number="1"]/data/table[@schema="potential-hangs"]'` (and
`time-profile`). Sum `potential-hangs` durations for total hang time. For hot
frames, resolve `<frame id=… name=…>` once, then count how many **backtraces**
contain each symbol. Counting frame definitions instead overstated ICU frames on
the first pass and nearly produced a wrong conclusion. Use one script for before and
after so the comparison is like for like.

## Rule 5: confirm the state before believing the number

Before reading any figure, confirm in the same run that the workspace was
**authorized** (role present, data present). A fast run on a denied or empty
dashboard is not a result. State the environment and data condition next to every
number you report.

## What the 2026-09-18 baseline looked like

Denied dashboard, Release, no interaction: launch 626 ms; main thread hung 40.5 s
of 45 s; 98.6% of samples in `OperationsDashboardView.body`; 74.6% in
`CompanyCloudKitBinding.isValid` from per-call `ISO8601DateFormatter` construction.
Data Persistence showed app-entity fetches were cheap (32 µs to 1.1 ms); CloudKit
mirroring metadata fetches dominated. See `gunnaire-perf-rules` for what to do
about each.
