import Foundation
import Testing
@testable import GunnAire_Ops

/// The single serialized home for every test that touches
/// `GunnAireAppIntentRouter`. The router is process-global static state that
/// persists pending routes to `UserDefaults.standard`, so router tests spread
/// across parallel suites trampled each other's pending routes - failing on
/// a varying test, only under the full suite, and only on some simulators.
/// `.serialized` protects tests within one suite and nothing across suites,
/// so they all live here, and each one starts and ends from a clean slate.
@MainActor
@Suite(.serialized)
struct FieldCollectionNavigationTests {
    @Test func explicitFieldCollectionRequestsGuideAndConsumesOnce() throws {
        GunnAireAppIntentRouter.discardAllPendingPayloads()
        defer { GunnAireAppIntentRouter.discardAllPendingPayloads() }
        let id = UUID()
        GunnAireAppIntentRouter.storeFieldPaymentCollectionRoute(id)
        #expect(GunnAireAppIntentRouter.consumePendingRoute() == .payments)
        let route = try #require(GunnAireAppIntentRouter.consumePendingPaymentCollectionRoute())
        #expect(route.invoiceID == id)
        #expect(route.prefersContactlessGuide)
        #expect(route.expiresAt == nil)
        #expect(GunnAireAppIntentRouter.consumePendingPaymentCollectionRoute() == nil)
    }

    @Test func accountingReviewDoesNotInheritPreviousFieldIntentOrExpiration() throws {
        GunnAireAppIntentRouter.discardAllPendingPayloads()
        defer { GunnAireAppIntentRouter.discardAllPendingPayloads() }
        GunnAireAppIntentRouter.storePaymentCollectionRoute(UUID(), prefersContactlessGuide: true,
            expiresAt: Date(timeIntervalSince1970: 1))
        let reviewID = UUID()
        GunnAireAppIntentRouter.storePaymentCollectionRoute(reviewID)
        let route = try #require(GunnAireAppIntentRouter.consumePendingPaymentCollectionRoute())
        #expect(route.invoiceID == reviewID)
        #expect(!route.prefersContactlessGuide)
        #expect(route.expiresAt == nil)
    }

    @Test func fieldIntentDoesNotBypassDeferredAccountBoundary() throws {
        GunnAireAppIntentRouter.discardAllPendingPayloads()
        defer { GunnAireAppIntentRouter.discardAllPendingPayloads() }
        let id = UUID()
        GunnAireAppIntentRouter.storeFieldPaymentCollectionRoute(id)
        let pending = try #require(GunnAireAppIntentRouter.consumePendingPaymentCollectionRoute())
        GunnAireAppIntentRouter.storeDeferredPaymentCollectionRoute(pending.invoiceID,
            ownerEmail: "assigned@example.invalid", prefersContactlessGuide: pending.prefersContactlessGuide)
        #expect(GunnAireAppIntentRouter.deferredPaymentCollectionRoute(ownerEmail: "assigned@example.invalid")?.prefersContactlessGuide == true)
        #expect(GunnAireAppIntentRouter.deferredPaymentCollectionRoute(ownerEmail: "other@example.invalid") == nil)
    }

    @MainActor
    @Test func fieldPaymentHandoffSurvivesAuthenticationBoundaryWithoutBypassingAuthorization() {
        GunnAireAppIntentRouter.discardAllPendingPayloads()
        defer { GunnAireAppIntentRouter.discardAllPendingPayloads() }

        let invoiceID = UUID()
        let issuedAt = Date(timeIntervalSinceReferenceDate: 910_000)
        let activity = FieldPaymentHandoff.makeActivity(invoiceID: invoiceID, now: issuedAt)

        #expect(FieldPaymentHandoff.storeContinuationRoute(from: activity, now: issuedAt))
        #expect(GunnAireAppIntentRouter.consumePendingRoute() == .payments)

        let route = GunnAireAppIntentRouter.consumePendingPaymentCollectionRoute(now: issuedAt)
        #expect(route?.invoiceID == invoiceID)
        #expect(route?.prefersContactlessGuide == true)
        #expect(route?.expiresAt == activity.expirationDate)

        let expiredAt = issuedAt.addingTimeInterval(FieldPaymentHandoff.validityDuration)
        #expect(!FieldPaymentHandoff.storeContinuationRoute(from: activity, now: expiredAt))
        #expect(GunnAireAppIntentRouter.consumePendingRoute() == nil)
        #expect(GunnAireAppIntentRouter.consumePendingPaymentCollectionRoute(now: expiredAt) == nil)

        let unrelatedActivity = NSUserActivity(activityType: "com.gunnaire.businesssuite.unrelated")
        unrelatedActivity.userInfo = ["invoiceID": invoiceID.uuidString]
        unrelatedActivity.expirationDate = issuedAt.addingTimeInterval(60)
        #expect(!FieldPaymentHandoff.storeContinuationRoute(from: unrelatedActivity, now: issuedAt))
        #expect(GunnAireAppIntentRouter.consumePendingRoute() == nil)
    }

    @Test func invoiceBuilderRoutePreservesServiceCallContext() async throws {
        GunnAireAppIntentRouter.discardAllPendingPayloads()
        defer { GunnAireAppIntentRouter.discardAllPendingPayloads() }

        _ = GunnAireAppIntentRouter.consumePendingRoute()
        _ = GunnAireAppIntentRouter.consumePendingServiceCallID()
        let serviceCallID = UUID()

        GunnAireAppIntentRouter.storeInvoiceBuilderRoute(serviceCallID)

        #expect(GunnAireAppIntentRouter.consumePendingRoute() == .invoices)
        #expect(GunnAireAppIntentRouter.consumePendingServiceCallID() == serviceCallID)
    }

    @Test func discardedRestrictedRouteDoesNotLeaveSensitiveHandoffContext() async throws {
        GunnAireAppIntentRouter.discardAllPendingPayloads()
        defer { GunnAireAppIntentRouter.discardAllPendingPayloads() }

        let serviceCallID = UUID()
        GunnAireAppIntentRouter.storeInvoiceBuilderRoute(serviceCallID)
        _ = GunnAireAppIntentRouter.consumePendingRoute()

        GunnAireAppIntentRouter.discardPendingPayload(for: .invoices)

        #expect(GunnAireAppIntentRouter.consumePendingServiceCallID() == nil)
    }

    @Test func quickBooksSalesRoutePreservesAndClearsTheRequestedWorkspace() async throws {
        GunnAireAppIntentRouter.discardAllPendingPayloads()
        defer { GunnAireAppIntentRouter.discardAllPendingPayloads() }

        _ = GunnAireAppIntentRouter.consumePendingRoute()
        _ = GunnAireAppIntentRouter.consumePendingQuickBooksWorkspace()

        GunnAireAppIntentRouter.storeQuickBooksRoute(workspace: .sales)

        #expect(GunnAireAppIntentRouter.consumePendingRoute() == .quickBooks)
        #expect(GunnAireAppIntentRouter.consumePendingQuickBooksWorkspace() == .sales)
        #expect(GunnAireAppIntentRouter.consumePendingQuickBooksWorkspace() == nil)

        GunnAireAppIntentRouter.storeQuickBooksRoute(workspace: .payments)
        _ = GunnAireAppIntentRouter.consumePendingRoute()
        GunnAireAppIntentRouter.discardPendingPayload(for: .quickBooks)
        #expect(GunnAireAppIntentRouter.consumePendingQuickBooksWorkspace() == nil)
    }

    @Test func deferredFieldCollectionRouteSurvivesNavigationButFailsClosedAcrossAccounts() async throws {
        GunnAireAppIntentRouter.discardAllPendingPayloads()
        defer { GunnAireAppIntentRouter.discardAllPendingPayloads() }

        let invoiceID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 910_000)
        let expiresAt = now.addingTimeInterval(300)
        GunnAireAppIntentRouter.clearDeferredPaymentCollectionRoute()

        GunnAireAppIntentRouter.storeDeferredPaymentCollectionRoute(
            invoiceID,
            ownerEmail: " Tech@GunnAire.com ",
            prefersContactlessGuide: true,
            expiresAt: expiresAt
        )
        let savedRoute = GunnAireAppIntentRouter.deferredPaymentCollectionRoute(
            ownerEmail: "tech@gunnaire.com",
            now: now
        )
        #expect(savedRoute?.invoiceID == invoiceID)
        #expect(savedRoute?.prefersContactlessGuide == true)
        #expect(savedRoute?.expiresAt == expiresAt)
        #expect(GunnAireAppIntentRouter.deferredPaymentCollectionRoute(
            ownerEmail: "tech@gunnaire.com",
            now: expiresAt
        ) == nil)

        GunnAireAppIntentRouter.storeDeferredPaymentCollectionRoute(
            invoiceID,
            ownerEmail: "tech@gunnaire.com",
            prefersContactlessGuide: true,
            expiresAt: expiresAt
        )
        #expect(GunnAireAppIntentRouter.deferredPaymentCollectionRoute(
            ownerEmail: "another@gunnaire.com",
            now: now
        ) == nil)
        #expect(GunnAireAppIntentRouter.deferredPaymentCollectionRoute(
            ownerEmail: "tech@gunnaire.com",
            now: now
        ) == nil)
    }

    @Test func paymentCollectionRoutePreservesContactlessPresentationOnlyForHandoff() async throws {
        GunnAireAppIntentRouter.discardAllPendingPayloads()
        defer { GunnAireAppIntentRouter.discardAllPendingPayloads() }

        let invoiceID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 920_000)
        let expiresAt = now.addingTimeInterval(300)
        GunnAireAppIntentRouter.discardPendingPayload(for: .payments)

        GunnAireAppIntentRouter.storePaymentCollectionRoute(
            invoiceID,
            prefersContactlessGuide: true,
            expiresAt: expiresAt
        )
        let contactlessRoute = GunnAireAppIntentRouter.consumePendingPaymentCollectionRoute(now: now)
        #expect(contactlessRoute?.invoiceID == invoiceID)
        #expect(contactlessRoute?.prefersContactlessGuide == true)
        #expect(contactlessRoute?.expiresAt == expiresAt)
        #expect(GunnAireAppIntentRouter.consumePendingPaymentCollectionRoute(now: now) == nil)

        GunnAireAppIntentRouter.storePaymentCollectionRoute(invoiceID)
        let ordinaryRoute = GunnAireAppIntentRouter.consumePendingPaymentCollectionRoute(now: now)
        #expect(ordinaryRoute?.invoiceID == invoiceID)
        #expect(ordinaryRoute?.prefersContactlessGuide == false)
        #expect(ordinaryRoute?.expiresAt == nil)

        GunnAireAppIntentRouter.storePaymentCollectionRoute(
            invoiceID,
            prefersContactlessGuide: true,
            expiresAt: expiresAt
        )
        #expect(GunnAireAppIntentRouter.consumePendingPaymentCollectionRoute(now: expiresAt) == nil)
        _ = GunnAireAppIntentRouter.consumePendingRoute()
    }

    @Test func signOutHandoffCleanupRemovesEveryQueuedSensitiveContext() async throws {
        GunnAireAppIntentRouter.discardAllPendingPayloads()
        defer { GunnAireAppIntentRouter.discardAllPendingPayloads() }

        let customerID = UUID()
        let serviceCallID = UUID()
        let invoiceID = UUID()

        GunnAireAppIntentRouter.storeCustomerRoute(customerID)
        GunnAireAppIntentRouter.storeDocumentationRoute(serviceCallID)
        GunnAireAppIntentRouter.storePaymentCollectionRoute(invoiceID)
        GunnAireAppIntentRouter.storeDeferredPaymentCollectionRoute(invoiceID, ownerEmail: "tech@gunnaire.com")
        GunnAireAppIntentRouter.storeMailDraftRoute(
            to: "customer@example.com",
            subject: "Private job update",
            body: "Private service details",
            customerID: customerID,
            serviceCallID: serviceCallID,
            invoiceID: invoiceID
        )

        GunnAireAppIntentRouter.discardAllPendingPayloads()

        #expect(GunnAireAppIntentRouter.consumePendingRoute() == nil)
        #expect(GunnAireAppIntentRouter.consumePendingCustomerID() == nil)
        #expect(GunnAireAppIntentRouter.consumePendingServiceCallID() == nil)
        #expect(GunnAireAppIntentRouter.consumePendingPaymentCollectionRoute() == nil)
        #expect(GunnAireAppIntentRouter.deferredPaymentCollectionRoute(ownerEmail: "tech@gunnaire.com") == nil)
        #expect(GunnAireAppIntentRouter.consumePendingMailDraft() == nil)
    }

    @Test func mailDraftRoutePersistsAttachmentsRecordLinksAndWorkflow() async throws {
        GunnAireAppIntentRouter.discardAllPendingPayloads()
        defer { GunnAireAppIntentRouter.discardAllPendingPayloads() }

        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "GunnAirePendingMailTo")
        defaults.removeObject(forKey: "GunnAirePendingMailSubject")
        defaults.removeObject(forKey: "GunnAirePendingMailBody")
        defaults.removeObject(forKey: "GunnAirePendingMailAttachmentPaths")
        defaults.removeObject(forKey: "GunnAirePendingMailMaintenanceContractID")
        defaults.removeObject(forKey: "GunnAirePendingMailWorkflow")
        let customerID = UUID()
        let serviceCallID = UUID()
        let invoiceID = UUID()
        let maintenanceContractID = UUID()

        GunnAireAppIntentRouter.storeMailDraftRoute(
            to: "customer@example.com",
            subject: "Service Report",
            body: "Attached.",
            attachmentPaths: ["/tmp/report.pdf"],
            customerID: customerID,
            serviceCallID: serviceCallID,
            invoiceID: invoiceID,
            maintenanceContractID: maintenanceContractID,
            workflow: .maintenanceRenewal
        )
        // Consume navigation as the real handoff does, not just its draft.
        // Leaving Mail pending causes the next Accounting launch to correctly
        // present an access-restriction alert over its otherwise valid Find UI.
        #expect(GunnAireAppIntentRouter.consumePendingRoute() == .mail)
        let draft = GunnAireAppIntentRouter.consumePendingMailDraft()

        #expect(draft?.to == "customer@example.com")
        #expect(draft?.subject == "Service Report")
        #expect(draft?.body == "Attached.")
        #expect(draft?.attachmentPaths == ["/tmp/report.pdf"])
        #expect(draft?.customerID == customerID)
        #expect(draft?.serviceCallID == serviceCallID)
        #expect(draft?.invoiceID == invoiceID)
        #expect(draft?.maintenanceContractID == maintenanceContractID)
        #expect(draft?.workflow == .maintenanceRenewal)
        #expect(GunnAireAppIntentRouter.consumePendingRoute() == nil)
    }
}
