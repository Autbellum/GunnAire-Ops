# CloudKit and field-payment release checklist

## CloudKit

The app uses the private CloudKit database container
`iCloud.com.gunnaire.businesssuite` for its SwiftData store. Apple configuration
and schema status as of 2026-08-27:

1. The App ID `com.gunnaire.businesssuite` has the CloudKit container and Remote
   notifications capability enabled. The project declares the matching runtime mode.
2. A signed Mac Catalyst development build succeeds using the regenerated team
   provisioning profile.
3. All 21 SwiftData production record types were initialized in Development,
   reviewed in CloudKit Console, deployed, and verified in Production. On
   2026-08-26 the follow-up deployment also verified 36 `CD_ServiceCall`
   fields, including `CD_correctiveWorkReasonRaw`,
   `CD_originatingServiceCallID`, and
   `CD_scheduledFollowUpServiceCallID`, plus the 16-field `CD_Invoice` type
   containing `CD_quickBooksSyncStatus`. The temporary bootstrap records were
   then removed and the local development store was verified marker-free.
   On 2026-08-27 the version-six signed bootstrap initialized and Apple
   deployed the following fourteen optional fields to Production:
   `CD_Customer.storedPaymentMethodsJSON`,
   `CD_ServiceCall.maintenanceAgreementID`,
   `CD_ServiceCall.maintenanceAgreementDueDate`, and the four
   `CD_Estimate` approval-evidence fields (`customerApprovalMethodRaw`,
   `customerApprovalReference`, `customerApprovalRecordedByEmail`, and
   `customerApprovalSignatureImageBase64`), plus
   `CD_Estimate.scheduledServiceCallID` for the accepted-estimate-to-work-order
   handoff, plus
   `CD_Technician.quickBooksTimeEntityKindRawValue` and
   `CD_Technician.quickBooksTimeEntityRef` for explicit per-technician QBO
   TimeActivity ownership, plus `CD_Item.pricebookReviewStatusRawValue`,
   `CD_Item.pricebookCreatedByEmail`, `CD_Item.pricebookReviewedByEmail`, and
   `CD_Item.pricebookReviewedAt` for the field-created item review trail.
   CloudKit Console then verified the complete Production counts and exact
   fields: Customer 14, Estimate 23, Item 20, ServiceCall 38, Technician 12,
   and Invoice 16. Matching Development and Production schema exports are
   retained as `cloudkit-development.ckdb` and `cloudkit-production.ckdb`.
   The version-six bootstrap removes only its synthetic marker graph, and its
   pending-field seed has a focused regression test.
4. Sign the company iPad and Mac into the same approved business iCloud account
   and sign every staff member into GunnAire Ops with their own business login.
5. Verify offline edits made on each physical device merge after reconnection before
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
