# Google Calendar delivery repair — 2026-09-11

## What changed

- Saving a new appointment or an app-managed schedule edit attempts an outbound Google write. Signed-out and failed requests are no longer silently discarded by the scheduling UI.
- Sync Google now sends pending app-owned appointments before importing. Completed history and externally owned Google events are not automatically published. Failed/uncertain proposals retain their original event identity; a missing previously reserved event requires review rather than another POST.
- Reassigning staff retains the chosen calendar instead of assuming a technician's email grants calendar write access. Assigned staff and additional crew receive invitations; new dispatch events do not automatically invite customers.
- New appointments request an explicit 30-minute popup reminder. Existing Google reminder choices, including explicit opt-out, are preserved. Fractional RFC3339 timestamps are encoded and decoded consistently so successful writes can be confirmed.
- Assignment-only changes update staff invitations with an ETag-protected, separately constrained patch. Existing guest RSVP details and non-app-added internal guests are retained. External, ambiguous or omitted guest lists require review rather than sending customer emails.
- A newer pending/error status cannot be overwritten by an older completion or a replacement Google account. The calendar status remains visible after the appointment sheet closes. Session, role, original-record, original-route, version and duplicate-prevention guards remain in place.

## Notification limits and acceptance

Google distinguishes event invitations/changes from timed reminders. Reminders belong to each authenticated calendar user; the app cannot override another person's Google or device alert preferences. See [Google reminders and notifications](https://developers.google.com/workspace/calendar/api/concepts/reminders) and [event insertion](https://developers.google.com/workspace/calendar/api/v3/reference/events/insert).

After a release containing this change is installed, verify with a staff-only appointment:

1. Connect Google under the same business identity and confirm a writable selected calendar. Give each assigned technician a valid calendar email in their contact record.
2. Save an appointment, then check the Schedule sync status. Use Sync Google to recover pending work after reconnecting. Review an old unavailable selected calendar explicitly; no linked event is silently moved to another calendar.
3. Confirm the original event appears in Google Calendar. The receiving staff member may need to accept the invitation, depending on their Google invitation settings.
4. Enable that Google account/calendar and notifications in the standalone calendar app. Verify both initial delivery and the timed alert. Apple Calendar and Google Calendar have separate device settings.
5. Reassign or move the appointment and confirm the original event is updated without duplication. For legacy events containing customer guests, review staff invitations in Google Calendar before retrying.

No live event, customer email, production deployment, signing change, physical-device installation or screen capture was used as a test. GitHub publication is not installation on the user's device. TestFlight distribution and live calendar/device acceptance remain separate release steps.

## Verification record

Evidence is retained locally in `/Users/gunnaire/Downloads/GunnAire Ops Releases/Calendar Delivery.qXC9jN`.

- Tooling: 75 passed; `/Users/gunnaire/Documents/GunnAireLocalQA/runs/tools-2ag82mwu/report.json`.
- Backend: 1,203 passed; `/Users/gunnaire/Documents/GunnAireLocalQA/runs/backend-wyaau7um/report.json`.
- LoadSight: 322 unique passing XCTest cases verified from `package-verified.xml`, zero failures/skips. The older helper incorrectly counted the empty secondary Swift Testing run as zero; that failed helper report and the detailed rerun are retained, not hidden.
- Full native unit suite: 2,377 passed, zero failures/skips, including all 62 calendar workflow tests. `full.xcresult`, `full-summary.json` and `full-tests.json`; required calendar selectors independently verified. No UI tests were executed.
- Unsigned Mac Catalyst and iOS Release build logs are retained as `mac-release.log` and `ios-release.log`; their final outcomes are reported with the pull request. Distribution/signing is separate.
- The first focused test run exposed a new email-regex defect and the existing fractional-date confirmation defect. A later test compile caught a throwing expression inside a test macro. Those unsuccessful runs are retained alongside the final checks.

Previously qualified equipment-schedule discovery/association additions were copied from the verified owner snapshot; all 14 selected files matched the current owner project before inclusion. They are rechecked with this candidate's package/native runs. Unrelated owner work, signing configuration and secrets are not staged.

The API, scheduling, communications, reliability, Xcode and troubleshooting skills guided explicit staff-only delivery, conservative recovery, and deterministic regression gates. Skill audit: `/Users/gunnaire/.codex/skill-audits/skill-usage.jsonl`, task “Ship tested updates and repair Google calendar scheduling sync”. Ollama supplied advisory edge cases; generated test code was reviewed and not applied verbatim.
