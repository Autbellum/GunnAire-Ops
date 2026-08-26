# CloudKit and field-payment release checklist

## CloudKit

The app now uses the private CloudKit database container
`iCloud.com.gunnaire.businesssuite` for its SwiftData store. Before a signed
build can synchronize between the company iPad and Mac:

1. In the Apple Developer account, enable iCloud/CloudKit for
   `com.gunnaire.businesssuite` and create or select that exact container.
2. Enable Background Modes with **Remote notifications** for the App ID. The
   project already declares this runtime mode so SwiftData can apply CloudKit
   server changes while the app is backgrounded.
3. Regenerate the provisioning profile after enabling the capabilities.
4. In CloudKit Console, use the development environment to validate the schema
   with non-production data, then deploy the schema to production before an
   App Store or TestFlight release.
5. Sign the company iPad and Mac into the same approved business iCloud account
   and sign every staff member into GunnAire Ops with their own business login.
6. Verify offline edits made on each device merge after reconnection before
   relying on CloudKit for live dispatch.

The CloudKit private database keeps the company-owned iPad and Mac in sync. It
does not replace server-side business authorization, and it should not be used
as a multi-employee permission system.

The SwiftData schema uses optional CloudKit relationships with explicit
inverses. Local workflows still require a customer for a job, estimate,
invoice, agreement, payment, and customer communication; the optional storage
shape only lets CloudKit reconcile records that arrive in a different order.

CloudKit cannot enforce SwiftData unique constraints during asynchronous sync.
The app uses immutable UUIDs for record identity and treats the backend as the
authority for staff roles. If independently created staff records with the
same email arrive from different devices, the app resolves the duplicate to a
single, least-privileged record until the approved server role sync restores
the authoritative account state. Do not use a local unique annotation as the
sole accounting, authorization, or external-ID deduplication control.

## Field iPhone payment handoff

The Payments workspace can hand an unpaid invoice from the iPad to the company
iPhone with Apple Handoff. The handoff contains only an invoice identifier and
amount; it never transfers card data, customer contact details, processor
tokens, or QuickBooks credentials. The iPhone opens the existing payment flow,
then applies the field user's role and assigned-job restrictions.

Live **Tap to Pay on iPhone** is intentionally not represented as available
until all external prerequisites are complete:

1. Choose and contract with an Apple-supported payment service provider.
2. Request Apple's Tap to Pay on iPhone entitlement as the organization Account
   Holder and regenerate the affected provisioning profiles.
3. Add the PSP's approved iOS SDK/bridge and keep all processor secrets outside
   the app.
4. Perform PSP sandbox and production certification, then test successful,
   declined, interrupted, duplicate, and accounting-retry cases.

Apple documents that Tap to Pay on iPhone is iPhone-only and requires both an
approved PSP and the entitlement; it is not available on iPadOS or macOS.

Primary references: [Apple Tap to Pay on iPhone](https://developer.apple.com/tap-to-pay/), [Apple entitlement setup](https://developer.apple.com/documentation/ProximityReader/setting-up-the-entitlement-for-tap-to-pay-on-iPhone), and [Apple payment-card reader integration](https://developer.apple.com/documentation/ProximityReader/adding-support-for-tap-to-pay-on-iphone-to-your-app).
