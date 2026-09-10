import Foundation
import Testing
@testable import GunnAire_Ops

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
}
