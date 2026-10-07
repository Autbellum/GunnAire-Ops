# GunnAire Ops launch health

**Assessment:** Limited observation. No explicit stall, watchdog, or crash signal was found in the captured entries.

**Capture:** 1627 log lines; 727 timestamped app entries.
**Observed window:** 2026-09-19 15:07:06.392 to 2026-09-19 15:09:30.571 (144.179 s between first and last app entries).
**App-reported launch time:** 1.300 s, 0.600 s.

## Failure signals

No explicit failure signal observed in the analyzed entries.

This report covers only the simulator log capture. Process-exit crashes are detected when the capture includes system logs. A launch timing message does not prove the interface was responsive, and absence of a signal does not rule out an unlogged or later failure.
Raw log messages are excluded to keep credentials and private data out of this report.
