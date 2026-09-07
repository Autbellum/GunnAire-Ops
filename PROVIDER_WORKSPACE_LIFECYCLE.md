# Direct provider workspace lifecycle — 2026-09-06

Status: request-boundary implementation and fixture verification. This is not
end-to-end tenant, payment, or production acceptance.

## Corrected behavior

Every QBO Accounting/Payments request and document upload now captures the
verified company-workspace generation and initiating QBO connection generation,
realm and environment. The same operation identity is retained across token
readiness, 429 retries, paginated queries and multipart uploads. Checks occur
before transport and before response delivery; an old 401 cannot clear replacement
credentials. A bearer refresh inside the same connection preserves the original
request URL, body and idempotency identifier.

Google Mail and Calendar handlers and Drive metadata/resumable-upload requests
capture the workspace and Google connection identity before token refresh.
Calendar pages, Gmail list/detail fanout, Drive upload continuation and recovery
retain that identity. Changed connections reject even HTTP-success responses
before returning them to the initiating handler.

OAuth establishment and the exact Google userinfo endpoint remain available
before workspace proof. This is not an exemption for Mail, Calendar or Drive.
Sign-out/replacement invalidates pending OAuth callbacks and refresh results,
including queued delivery of user-profile and application-session results.
An old browser callback cannot clear a replacement browser session.

The shared operation contains no credential and is not persisted. A write that
may have reached a provider is returned as unconfirmed after an identity change,
with instructions to reconcile in the original provider account before retrying.
UI wording no longer prefixes those QuickBooks payment outcomes with a claim
that the charge failed. These checks preserve saved work; they do not undo an
external transaction or prove the remote transaction did not happen.

### Actual attachment defect found by the transport tests

The previous decoder expected a flat `AttachableResponse[].Id`, and an older
test repeated that mistaken shape. Intuit's upload-result schema nests either
`Attachable` or `Fault` in each array entry. The implementation now requires
exactly one non-fault result with a nonblank `Attachable.Id`, matching the
one-file request. Empty results, missing identifiers, flat/malformed entries,
faults and multiple/contradictory entries cannot mark a file synchronized.
The provider-shaped regression fixture was retained; the decoder and old
incorrect fixture were corrected.

## Verification

Focused M5 13-inch iPad Simulator (iOS 26.2): **44/44 tests**, zero failures.
This includes 23 workspace-controller, 8 shared-operation, 4 actual QBO-handler
and 9 actual Google/Drive-handler tests. A parameterized test exercises multiple
request families and transitions; counts are test functions, not HTTP attempts.

The QBO tests cover Accounting reads, Payments cards/tokens/charges and uploads;
sign-out and same-realm reconnection; late 401 rejection without clearing new
credentials; disconnect before first send; exact retained 429 retry requests;
and nested upload outcomes. Google coverage includes userinfo bootstrap,
Mail read/send/trash, Calendar list/create/patch/delete, business-login change,
sign-out during refresh, valid refreshed bearer use, pagination/fanout rejection,
and Drive metadata/initiation/content/recovery boundaries. Valid Drive recovery
queries the same upload session and uses the same reserved file identifier.

All transports use fixtures; isolated Debug-only constructors do not load,
write or clear real Keychain/UserDefaults credentials. No live card, ACH,
invoice, email, calendar or Drive write occurs.

Full current-source iPad regression passes **765/765 logic tests and 6/6 UI
journeys**, zero failures/skips, on the same M5/iOS 26.2 simulator. The UI journeys
cover workspace denial/sign-out, primary admin navigation, existing-invoice
line-item editing, direct Invoice launch, reachable field-payment Handoff and
simple Mail actions. This is focused navigation coverage, not a fresh rerun of
the entire historical UI target.

Mac Catalyst optimized Release builds successfully for arm64/x86_64. The
pre-existing external Metal-toolchain search-path linker warning remains.
No new source compiler warning or error is recorded. Full Mac Catalyst Debug
logic passes **765/765 tests**, zero failures/skips. The unsigned Mac test host
also emits system LinkDaemon/ScreenTime accessibility diagnostics; those logs
are retained and do not establish signed Shortcuts/platform acceptance.

Retained iPad result:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-06/Provider Workspace iPad Logic and Navigation.xcresult`.
Retained Mac result in that directory: `Provider Workspace Mac Logic.xcresult`.
Companion logs are `provider-workspace-ipad.log`,
`provider-workspace-mac-release.log` and `provider-workspace-mac-logic.log`.
The unsigned simulator emits the existing AppShortcut discovery diagnostic;
passing fixtures do not constitute signed Siri/Shortcuts acceptance.

Focused result:
`/tmp/GunnAireQBORetryDerivedData/Logs/Test/Test-GunnAire Ops-2026.09.06_21-55-30--0400.xcresult`

## Still required for end-to-end correctness

1. Retain operation identity across **higher-level multi-step workflows**, not
   just individual request families. For example, a validated callback can
   resume an async payment/sync service after the workspace changed; starting
   a new request must not treat that retained old model as new-account data.
   Likewise, model-context saves after callback delivery need lifecycle checks.
2. Introduce durable, original-account-scoped payment-attempt evidence before
   sending a charge/refund, with reconciliation before another collection.
   `QuickBooksPaymentsService` and the payment entry screens currently create
   per-attempt UUIDs and create local Payment records after success. Generic
   errors/connection changes can therefore leave an uncertain external charge
   without a durable local journal. UI wording alone does not fix that gap.
3. Stop exposing raw provider response bodies/headers in legacy QBO decoding
   diagnostics. Restrict customer-facing errors and logs to safe diagnostic
   metadata, particularly on Payments token/charge paths.
4. Complete server-role enforcement versus synchronized local roles and the
   legacy primary-admin-email special case.
5. Prove Core Data mirroring lifetime, signed-device offline identity,
   unsynced-work retention and actual cross-device CloudKit convergence.
6. Correct historical statement cutoffs and obtain the existing production
   signing/provider/CloudKit/backend/physical-iPhone acceptance evidence.

See [company workspace architecture](CLOUDKIT_WORKSPACE_IDENTITY.md) and
[full completion evidence](COMPLETION_EVIDENCE_MATRIX.md). No merge, production
deployment, workspace approval, signing change or physical install is part of
this checkpoint. Backend 2026.09.06.20 remains required for the native gate.

## Primary provider references

- [Google installed-app OAuth](https://developers.google.com/identity/protocols/oauth2/native-app)
- [Google resumable-upload recovery](https://developers.google.com/workspace/drive/api/guides/manage-uploads)
- [Intuit upload-result schema](https://github.com/intuit/QuickBooks-V3-PHP-SDK/blob/master/src/Data/IPPAttachableResponse.php)
- [Intuit request-ID retry guidance](https://github.com/IntuitDeveloper/SampleApp-Batch-Java/blob/main/docs/building-smarter-batch.md)

These sources establish provider protocol shapes and recovery behavior.
The company's session/role lifecycle checks are application security rules,
not a claim that the providers enforce the native workspace identity.
