import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor struct FieldPaymentReceiptTests {
    @MainActor final class Fixture {
        let context: ModelContext
        let customer: Customer
        let invoice: Invoice
        let company = UUID()
        let now = ISO8601DateFormatter().date(from: "2026-09-08T20:00:00Z")!
        var identity: FieldPaymentReviewIdentity {
            .init(companyID: company, invoiceID: invoice.id, localCustomerID: customer.id,
                  invoiceQuickBooksID: "D1", customerQuickBooksID: "C1", serviceCallID: invoice.serviceCallID)
        }
        init() throws {
            let schema = GunnAireModelSchema.schema
            context = ModelContext(try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            ]))
            context.autosaveEnabled = false
            customer = Customer(quickBooksID: "C1", name: "Receipt fixture")
            invoice = Invoice(customer: customer, quickBooksID: "D1", quickBooksBalanceDue: 100,
                amount: 100, taxCalculationStatus: .notApplicable, createdAt: now.addingTimeInterval(-3600))
            context.insert(customer); context.insert(invoice); try context.save()
        }
        func snapshot(_ changes: [String: Any] = [:]) throws -> FieldPaymentReviewSnapshot {
            let value: [String: Any] = identity.query.mapValues { $0 as Any }.merging([
                "realmID": "R1", "environment": "sandbox", "connectionRevision": String(repeating: "a", count: 64),
                "protocolVersion": 1, "invoiceNumber": "1069", "invoiceDate": "2026-09-08", "syncToken": "2",
                "observedAt": ISO8601DateFormatter().string(from: now), "currency": "USD",
                "totalCents": 10000, "balanceCents": 6000, "collectionLimitCents": 6000,
                "hasOpenAttempt": false, "fundsSettlementVerified": false, "authority": "assigned",
                "payments": [["paymentQuickBooksID": "P1", "syncToken": "1", "postingDate": "2026-09-08",
                              "appliedCents": 4000, "includesCreditOrAdjustment": false]]
            ]) { _, new in new }.merging(changes) { _, new in new }
            return try JSONDecoder().decode(FieldPaymentReviewSnapshot.self, from: JSONSerialization.data(withJSONObject: value))
        }
        func apply(_ value: FieldPaymentReviewSnapshot? = nil, check: () throws -> Void = {}, persist: (() throws -> Void)? = nil) throws {
            try FieldPaymentReceiptReconciliation.apply(value ?? snapshot(), to: invoice, identity: identity,
                context: context, now: now, check: check, persist: persist ?? { try self.context.save() })
        }
    }

    @Test func repeatApplicationSavesOneInvoiceObservationAndNoSyntheticPayment() throws {
        let f = try Fixture()
        try f.apply()
        let first = try #require(f.invoice.quickBooksPaymentReviewJSON)
        try f.apply()
        #expect(FieldPaymentReceiptReconciliation.decode(first) == FieldPaymentReceiptReconciliation.receipt(for: f.invoice))
        #expect(f.invoice.quickBooksBalanceDue == 60)
        #expect(f.invoice.status == "partial")
        #expect(f.invoice.quickBooksLastSyncedAt == f.now)
        #expect(f.invoice.quickBooksReconciliationReviewMessage == nil)
        #expect(try f.context.fetchCount(FetchDescriptor<Payment>()) == 0)
        #expect(try f.context.fetchCount(FetchDescriptor<Invoice>()) == 1)
    }

    @Test func nativeACHCaptureAndItsPendingStatusRemainUnchanged() throws {
        let f = try Fixture()
        let payment = Payment(invoice: f.invoice, quickBooksID: "P1", quickBooksChargeID: "original-charge",
            collectionAttemptID: UUID(), providerPaymentStatus: "PENDING", amount: 40,
            date: f.now.addingTimeInterval(-15), method: "ach", notes: "Original capture", processor: "quickbooks_payments")
        f.context.insert(payment); try f.context.save()
        let before = try FieldPaymentReceiptReconciliation.paymentDigest(invoice: f.invoice, context: f.context)
        try f.apply()
        #expect(try FieldPaymentReceiptReconciliation.paymentDigest(invoice: f.invoice, context: f.context) == before)
        #expect(payment.isProviderSettlementPending)
        #expect(payment.notes == "Original capture")
        #expect(f.invoice.quickBooksReconciliationReviewMessage == nil)
        #expect(try f.context.fetchCount(FetchDescriptor<Payment>()) == 1)
    }

    @Test func creditApplicationUpdatesAccountingBalanceWithoutInventingCollectedCash() throws {
        let f = try Fixture()
        try f.apply(f.snapshot(["balanceCents": 0, "collectionLimitCents": 0,
            "payments": [["paymentQuickBooksID": "P-credit", "syncToken": "0", "postingDate": "2026-09-08",
                          "appliedCents": 10000, "includesCreditOrAdjustment": true]]]))
        #expect(Invoice.isPaid(f.invoice, payments: []))
        #expect(try f.context.fetchCount(FetchDescriptor<Payment>()) == 0)
        let receipt = try #require(FieldPaymentReceiptReconciliation.receipt(for: f.invoice))
        #expect(receipt.snapshot.payments.first?.includesCreditOrAdjustment == true)
        #expect(!receipt.snapshot.fundsSettlementVerified)
    }

    @Test func unmatchedChangedOrDuplicateNativeRecordsPreserveEverything() throws {
        for mode in ["unmatched", "changed", "duplicate"] {
            let f = try Fixture()
            let payment = Payment(invoice: f.invoice, quickBooksID: mode == "unmatched" ? nil : "P1",
                amount: mode == "changed" ? 41 : 40, method: "cash")
            f.context.insert(payment)
            if mode == "duplicate" { f.context.insert(Payment(invoice: f.invoice, quickBooksID: "P1", amount: 40)) }
            try f.context.save()
            #expect(throws: FieldPaymentReceiptError.history) { try f.apply() }
            #expect(f.invoice.quickBooksBalanceDue == 100)
            #expect(f.invoice.quickBooksPaymentReviewJSON == nil)
            #expect(payment.amount == (mode == "changed" ? 41 : 40))
        }
    }

    @Test func originalIdentityAndUniqueMappingsAreRequired() throws {
        for mode in ["invoice", "customer", "invoiceReplica", "providerReplica", "customerReplica", "job"] {
            let f = try Fixture()
            let snapshot = try f.snapshot()
            switch mode {
            case "invoice": f.invoice.quickBooksID = "other"
            case "customer": f.customer.quickBooksID = "other"
            case "invoiceReplica": f.context.insert(Invoice(id: f.invoice.id, customer: f.customer, amount: 100))
            case "providerReplica": f.context.insert(Invoice(customer: f.customer, quickBooksID: "D1", amount: 100))
            case "customerReplica": f.context.insert(Customer(quickBooksID: "C1", name: "Duplicate"))
            default: f.invoice.serviceCallID = UUID()
            }
            #expect(throws: (any Error).self) { try f.apply(snapshot) }
            #expect(f.invoice.quickBooksBalanceDue == 100)
            #expect(f.invoice.quickBooksPaymentReviewJSON == nil)
        }
    }

    @Test func taxIdentityAndDocumentTotalReviewAreNotClearedByBalanceCheck() throws {
        for mode in ["tax", "identity", "amount", "draft", "pending"] {
            let f = try Fixture()
            switch mode {
            case "tax": f.invoice.taxCalculationStatusRawValue = BillingTaxCalculationStatus.pendingQuickBooks.rawValue
            case "identity": f.invoice.quickBooksSyncStatus = QuickBooksBillingIdentity.invoiceReviewState
            case "amount": f.invoice.amount = 101
            case "draft": f.invoice.milestoneDraftReceiptJSON = "preserved draft"
            default: f.invoice.quickBooksSyncStatus = "pending"
            }
            #expect(throws: FieldPaymentReceiptError.changed) { try f.apply() }
            #expect(f.invoice.quickBooksBalanceDue == 100)
        }
    }

    @Test func failedSaveRestoresOnlyTouchedFieldsAndKeepsUnrelatedDraftEdits() throws {
        let f = try Fixture()
        f.customer.name = "Unsaved customer correction"
        f.invoice.notes = "Unsaved technician notes"
        f.invoice.quickBooksSyncStatus = QuickBooksBalanceReconciliation.reviewState
        f.invoice.quickBooksSyncDetail = "Previous balance needs review"
        #expect(throws: FieldPaymentReceiptError.save) {
            try f.apply(persist: { throw CocoaError(.fileWriteOutOfSpace) })
        }
        #expect(f.invoice.quickBooksPaymentReviewJSON == nil)
        #expect(f.invoice.quickBooksBalanceDue == 100)
        #expect(f.invoice.status == "unpaid")
        #expect(f.invoice.quickBooksLastSyncedAt == nil)
        #expect(f.invoice.quickBooksSyncStatus == QuickBooksBalanceReconciliation.reviewState)
        #expect(f.invoice.quickBooksSyncDetail == "Previous balance needs review")
        #expect(f.customer.name == "Unsaved customer correction")
        #expect(f.invoice.notes == "Unsaved technician notes")
    }

    @Test func revokedAccessImmediatelyBeforeCommitPerformsNoSave() throws {
        let f = try Fixture()
        var checks = 0, saves = 0
        #expect(throws: FieldPaymentReviewError.access) {
            try f.apply(check: { checks += 1; if checks == 2 { throw FieldPaymentReviewError.access } }, persist: { saves += 1 })
        }
        #expect(checks == 2 && saves == 0)
        #expect(f.invoice.quickBooksPaymentReviewJSON == nil)
        #expect(f.invoice.quickBooksBalanceDue == 100)
    }

    @Test func newerOrEquallyTimedConflictingEvidenceCannotBeOverwritten() throws {
        let f = try Fixture()
        try f.apply()
        #expect(throws: FieldPaymentReceiptError.newer) {
            try f.apply(f.snapshot(["balanceCents": 5000, "collectionLimitCents": 5000]))
        }
        #expect(throws: FieldPaymentReceiptError.newer) {
            try f.apply(f.snapshot(["observedAt": ISO8601DateFormatter().string(from: f.now.addingTimeInterval(-1))]))
        }
        #expect(f.invoice.quickBooksBalanceDue == 60)
    }

    @Test func newerReallocationObservationReplacesSnapshotWithoutDeletingCapturedHistory() throws {
        let f = try Fixture()
        try f.apply()
        let next = try f.snapshot(["observedAt": ISO8601DateFormatter().string(from: f.now.addingTimeInterval(1)),
            "syncToken": "3", "balanceCents": 10000, "collectionLimitCents": 10000, "payments": []])
        try f.apply(next)
        #expect(f.invoice.quickBooksBalanceDue == 100)
        #expect(FieldPaymentReceiptReconciliation.receipt(for: f.invoice)?.snapshot.payments.isEmpty == true)
        #expect(try f.context.fetchCount(FetchDescriptor<Payment>()) == 0)
    }

    @Test func incompleteCloudKitDeliveryBlocksCollectionAndStatementsUntilCoherent() throws {
        for change in ["balance", "timestamp", "futureTimestamp", "status", "document", "payment", "corrupt"] {
            let f = try Fixture()
            try f.apply()
            switch change {
            case "balance": f.invoice.quickBooksBalanceDue = 0
            case "timestamp": f.invoice.quickBooksLastSyncedAt = nil
            case "futureTimestamp": f.invoice.quickBooksLastSyncedAt = f.now.addingTimeInterval(60)
            case "status": f.invoice.status = "paid"
            case "document": f.invoice.lineItemSummary = "Changed scope"
            case "payment": f.context.insert(Payment(invoice: f.invoice, amount: 10))
            default: f.invoice.quickBooksPaymentReviewJSON = "{broken receipt"
            }
            #expect(f.invoice.paymentCollectionBlockedMessage != nil)
            #expect(!Invoice.isPaid(f.invoice, payments: []))
            let statement = CustomerAccountStatementPolicy.snapshot(customer: f.customer, invoices: [f.invoice],
                payments: [], asOf: nil, calendar: .current, now: f.now)
            #expect(!statement.reviewMessages.isEmpty)
        }
    }

    @Test func openAttemptSurvivesSaveAsCollectionHoldAndFreshReviewCanClearIt() throws {
        let f = try Fixture()
        try f.apply(f.snapshot(["hasOpenAttempt": true, "collectionLimitCents": 0]))
        #expect(f.invoice.paymentCollectionBlockedMessage?.contains("Another payment") == true)
        try f.apply(f.snapshot(["observedAt": ISO8601DateFormatter().string(from: f.now.addingTimeInterval(1))]))
        #expect(f.invoice.paymentCollectionBlockedMessage == nil)
    }

    @Test func receiptRoundTripAndCurrentStatementUseAuthoritativeBalanceNotAnExtraPayment() throws {
        let f = try Fixture()
        QuickBooksBalanceReconciliation.markForRefresh(f.invoice)
        try f.apply()
        let anotherContext = ModelContext(f.context.container)
        let restored = try #require(anotherContext.fetch(FetchDescriptor<Invoice>()).first)
        #expect(restored.quickBooksBalanceDue == 60)
        #expect(FieldPaymentReceiptReconciliation.receipt(for: restored)?.snapshot.invoiceNumber == "1069")
        #expect(restored.quickBooksReconciliationReviewMessage == nil)
        let statement = CustomerAccountStatementPolicy.snapshot(customer: f.customer, invoices: [f.invoice], payments: [],
            asOf: nil, calendar: .current, now: f.now)
        #expect(statement.reviewMessages.isEmpty)
        #expect(statement.entries.first?.balanceDue == 60)
        #expect(statement.entries.first?.paymentActivity.isEmpty == true)
        #expect(statement.entries.first?.usesQuickBooksBalance == true)
    }

    @Test func malformedFutureStaleOrWrongCompanyReplyDoesNotChangeSavedInvoice() throws {
        let f = try Fixture()
        for changes: [String: Any] in [["companyID": UUID().uuidString], ["currency": "EUR"], ["fundsSettlementVerified": true],
            ["observedAt": ISO8601DateFormatter().string(from: f.now.addingTimeInterval(-121))],
            ["observedAt": ISO8601DateFormatter().string(from: f.now.addingTimeInterval(31))]] {
            #expect(throws: (any Error).self) { try f.apply(f.snapshot(changes)) }
            #expect(f.invoice.quickBooksBalanceDue == 100)
            #expect(f.invoice.quickBooksPaymentReviewJSON == nil)
        }
    }

    @Test func downgradedInvoiceOrPaymentVersionsCannotSupersedeSavedEvidence() throws {
        for mode in ["invoice", "payment", "malformed"] {
            let f = try Fixture()
            try f.apply()
            var changes: [String: Any] = ["observedAt": ISO8601DateFormatter().string(from: f.now.addingTimeInterval(1))]
            if mode == "invoice" { changes["syncToken"] = "1" }
            if mode == "malformed" { changes["syncToken"] = "not-a-version" }
            if mode == "payment" {
                changes["payments"] = [["paymentQuickBooksID": "P1", "syncToken": "0", "postingDate": "2026-09-08",
                                        "appliedCents": 4000, "includesCreditOrAdjustment": false]]
            }
            #expect(throws: (any Error).self) { try f.apply(f.snapshot(changes)) }
            #expect(FieldPaymentReceiptReconciliation.receipt(for: f.invoice)?.snapshot.syncToken == "2")
        }
    }

    @Test func unresolvedRefundCannotBeHiddenByAnAccountingBalanceRefresh() throws {
        let f = try Fixture()
        let refund = Payment(invoice: f.invoice, quickBooksChargeID: "original-refund", amount: 10, method: "ach", isRefund: true)
        f.context.insert(refund); try f.context.save()
        #expect(throws: FieldPaymentReceiptError.history) { try f.apply() }
        #expect(f.invoice.quickBooksBalanceDue == 100)
        #expect(refund.quickBooksChargeID == "original-refund")
        refund.quickBooksRefundReceiptID = "original-accounting-refund"
        let before = try FieldPaymentReceiptReconciliation.paymentDigest(invoice: f.invoice, context: f.context)
        try f.apply()
        #expect(try FieldPaymentReceiptReconciliation.paymentDigest(invoice: f.invoice, context: f.context) == before)
    }
}
