import Foundation

enum FieldPaymentReviewFixture {
    @MainActor static func client(invoice: Invoice) throws -> FieldPaymentReviewClient? {
        #if DEBUG
        let flags = ProcessInfo.processInfo.arguments
        guard GunnAireCloudKit.usesTestDatabase, flags.contains("-uiTestFieldPaymentReview") else { return nil }
        guard let customer = invoice.customer, let providerID = invoice.quickBooksID else { throw FieldPaymentReviewError.invalid }
        let identity = FieldPaymentReviewIdentity(companyID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            invoiceID: invoice.id, localCustomerID: customer.id, invoiceQuickBooksID: providerID,
            customerQuickBooksID: customer.quickBooksID ?? "fixture-customer", serviceCallID: invoice.serviceCallID)
        return try .init(identity: identity, check: {
            guard invoice.customer === customer, invoice.quickBooksID == providerID else { throw FieldPaymentReviewError.access }
        }, request: { path in
            if flags.contains("-uiTestFieldPaymentReviewOffline") { throw URLError(.notConnectedToInternet) }
            var value: [String: Any] = identity.query
            value["realmID"] = "fixture-realm"; value["environment"] = "sandbox"
            value["connectionRevision"] = String(repeating: "a", count: 64)
            if !path.hasPrefix("/api/field-payment-review/context?") {
                let paid = flags.contains("-uiTestFieldPaymentReviewPaid")
                let hold = flags.contains("-uiTestFieldPaymentReviewHold")
                value.merge(["protocolVersion": 1, "invoiceNumber": flags.contains("-uiTestFieldPaymentReviewNoNumber") ? NSNull() : "1069",
                    "invoiceDate": "2026-09-08", "syncToken": "2", "observedAt": ISO8601DateFormatter().string(from: Date()),
                    "currency": "USD", "totalCents": 18900, "balanceCents": paid ? 0 : 18900,
                    "collectionLimitCents": paid || hold ? 0 : 18900, "hasOpenAttempt": hold,
                    "fundsSettlementVerified": false, "authority": "assigned",
                    "payments": paid ? [["paymentQuickBooksID": "fixture-payment", "syncToken": "0", "postingDate": "2026-09-08", "appliedCents": 18900, "includesCreditOrAdjustment": false]] : []
                ]) { _, new in new }
            }
            return try JSONSerialization.data(withJSONObject: value)
        })
        #else
        return nil
        #endif
    }
}
