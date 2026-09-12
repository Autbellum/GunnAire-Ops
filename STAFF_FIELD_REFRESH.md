# Bounded staff field freshness checks

The editor's five-second lifetime check previously called full mounted-workspace acceptance on every tick. A headless simulator reproduction with 1,031 synthetic records and a 3,082,346-byte payload measured three payload reads and 2,344.19 ms for three consecutive unchanged refreshes. This was synchronous MainActor work; it was not a screen-recorded or physical-device frame-rate measurement.

## Freshness is not authority

An unchanged editor now reads only the bounded mount/acceptance metadata. Both envelopes have closed-schema, scope, identity, digest and numeric-bound checks. The mount is reread after acceptance to reject a mixed pair if it changes mid-probe. Current staff authority is checked before and after, independently of the in-memory observed head.

The resulting head is only a freshness identity for previously verified display data. It does not prove that payload bytes still exist or remain valid, and cannot authorize commands, media, imports or record adoption. Opening, explicit refresh, changed-record review and final submission retain full payload integrity and semantic checks. Missing/corrupt content therefore cannot become a submitted command merely because metadata still matches.

## Changed and unavailable records

A newly observed accepted head triggers full field validation once. The resulting current field still must be explicitly reviewed before an old draft can be adopted; the draft's original snapshot is not automatically changed. If that full load fails, timer ticks retain the draft without repeatedly parsing the same unavailable/corrupt head. Another head, an explicit Refresh Shared Record action, or foreground activation can request validation again.

Metadata failures keep submission disabled and retain local draft input. They never replace damaged evidence or mask revoked access. Revocation clears private display through the existing authority fence. Recovery clears stale refresh warnings and returns to a ready or changed-record-review message without replacing the draft. Core mount and acceptance consumers share the stricter metadata checks, while full mount loading continues to verify payload length and digest.

## Acceptance scope

The repeat-refresh regression checks structural payload-read counts instead of fragile timing thresholds. Additional tests cover changed heads, retry suppression, explicit recovery, corrupt/missing payloads, metadata mismatch and mid-read races, foreign scope, unsupported fields, revocation, malformed metadata and forced full validation.

This does not make all application work constant-time. Initial opening and explicit full validation still scale with workspace content, and need separate large-workspace/device profiling. This is not physical CloudKit acceptance, cross-device draft sync, signed release acceptance, or qualification of independently edited parallel UI files.
