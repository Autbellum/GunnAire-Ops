import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor
struct PaymentAttemptRecoveryTests {
    private func response(_ request: URLRequest, _ payload: [String: Any]) throws -> (Data, URLResponse) {
        (try JSONSerialization.data(withJSONObject: payload),
         HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    private func invoice() -> Invoice {
        Invoice(customer: Customer(quickBooksID: "fixture-customer", name: "Fixture"),
                quickBooksID: "fixture-invoice", quickBooksBalanceDue: 10, amount: 10)
    }

    private func seed(_ journal: FixturePaymentJournal, invoice: Invoice, kind: String = "charge",
                      completed: Bool = true) async throws -> PaymentAttemptRecord {
        var intent = PaymentAttemptIntent(id: UUID(), companyID: journal.businessID, realmID: "fixture-realm",
            environment: Config.QuickBooks.environment, invoiceID: invoice.id,
            invoiceQuickBooksID: "fixture-invoice", customerQuickBooksID: "fixture-customer",
            amountCents: 123, rail: "card", kind: kind)
        if kind == "refund" {
            intent.sourcePaymentID = UUID()
            intent.sourceProviderID = "fixture-source"
            intent.sourceAccountingID = "fixture-source-accounting"
        }
        _ = try await journal.reserve(intent)
        _ = try await journal.action("begin", attemptID: intent.id, reference: nil)
        let confirmed = try await journal.action("confirm", attemptID: intent.id, reference: "fixture-provider")
        if completed { return try await journal.action("complete", attemptID: intent.id, reference: "fixture-accounting") }
        return confirmed
    }

    @Test func actualCardAndBankServicesUseJournalAndCompleteOriginalAccountingIdentity() async throws {
        for rail in ["card", "ach"] {
            let journal = FixturePaymentJournal()
            let paymentID = UUID()
            var requests: [URLRequest] = []
            let api = QuickBooksDataAPI(testTokens: .init(accessToken: "fixture-access", expiration: .distantFuture),
                realmID: "fixture-realm", environment: Config.QuickBooks.environment) { request in
                requests.append(request)
                let path = request.url!.lastPathComponent
                if path == "tokens" { return try response(request, ["value": "fixture-token"]) }
                if path == "charges" || path == "echecks" {
                    #expect(journal.events.last == "begin")
                    return try response(request, ["id": "fixture-provider", "amount": "1.23", "currency": "USD",
                        "status": rail == "ach" ? "PENDING" : "CAPTURED", "capture": true,
                        "context": ["clientTransID": "ga-charge-" + paymentID.uuidString.lowercased()]])
                }
                if path == "query" {
                    return try response(request, ["QueryResponse": [
                        "Payment": [],
                        "PaymentMethod": [["Id": "fixture-method", "Name": rail == "ach" ? "QuickBooks ACH" : "QuickBooks Card"]]
                    ]])
                }
                if path == "payment" { return try response(request, ["Payment": ["Id": "fixture-accounting"]]) }
                Issue.record("Unexpected provider resource")
                throw URLError(.unsupportedURL)
            }
            let service = QuickBooksPaymentsService(api: api, journal: journal)
            let result: QuickBooksProcessedPaymentResult
            if rail == "card" {
                result = try await service.processCardPayment(localPaymentID: paymentID, invoice: invoice(), amount: 1.23,
                    cardInput: .init(cardholderName: "Fixture", cardNumber: "4111111111111111", expMonth: "12",
                        expYear: "2040", cvc: "123", postalCode: nil, addressLine: nil, city: nil, region: nil, country: "US"),
                    note: nil, catalogItems: [])
            } else {
                result = try await service.processBankPayment(localPaymentID: paymentID, invoice: invoice(), amount: 1.23,
                    bankInput: .init(accountHolderName: "Fixture", accountNumber: "1234", routingNumber: "490000018",
                        phone: "2025550100", accountType: .personalChecking, checkNumber: nil), note: nil, catalogItems: [])
            }
            try result.validateWorkspace()
            #expect(result.accountingError == nil)
            #expect(result.accountingPayment?.Id == "fixture-accounting")
            let record = try await journal.get(paymentID)
            #expect(record.state == .completed)
            let send = try #require(requests.first { ["charges", "echecks"].contains($0.url!.lastPathComponent) })
            #expect(send.value(forHTTPHeaderField: "Request-Id") == record.requestID.uuidString)
            #expect(journal.events == ["reserve", "begin", "confirm", "complete"])
            let accounting = try #require(requests.first { $0.url?.lastPathComponent == "payment" })
            let body = try #require(try JSONSerialization.jsonObject(with: accounting.httpBody!) as? [String: Any])
            #expect((body["PrivateNote"] as? String)?.contains("GunnAire payment ID: " + paymentID.uuidString.lowercased()) == true)
            #expect(body["CreditCardPayment"] == nil)
        }
    }

    @Test func serverUnavailabilityStopsActualServiceBeforeAnyProviderSend() async {
        let journal = FixturePaymentJournal()
        journal.failAt = "reserve"
        var sends = 0
        let api = QuickBooksDataAPI(testTokens: .init(accessToken: "fixture", expiration: .distantFuture),
            realmID: "fixture-realm", environment: Config.QuickBooks.environment) { _ in
            sends += 1; throw URLError(.unsupportedURL)
        }
        do {
            _ = try await QuickBooksPaymentsService(api: api, journal: journal).processBankPayment(
                localPaymentID: UUID(), invoice: invoice(), amount: 1,
                bankInput: .init(accountHolderName: "Fixture", accountNumber: "1234", routingNumber: "490000018",
                    phone: "2025550100", accountType: .personalChecking, checkNumber: nil), note: nil, catalogItems: [])
            Issue.record("Missing coordinator authorized provider traffic")
        } catch {}
        #expect(sends == 0)
    }

    @Test func completedChargeAndRefundRecoveryRestoresOneOriginalLocalRecordWithoutProviderWrites() async throws {
        for kind in ["charge", "refund"] {
            let schema = GunnAireModelSchema.schema
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
            let context = container.mainContext
            let invoice = invoice()
            context.insert(invoice.customer)
            context.insert(invoice)
            try context.save()
            let journal = FixturePaymentJournal()
            let record = try await seed(journal, invoice: invoice, kind: kind)
            var sends = 0
            let api = QuickBooksDataAPI(testTokens: .init(accessToken: "fixture", expiration: .distantFuture),
                realmID: "fixture-realm", environment: Config.QuickBooks.environment) { _ in
                sends += 1; throw URLError(.unsupportedURL)
            }
            let service = QuickBooksPaymentsService(api: api, journal: journal)
            for _ in 0..<2 {
                let result = try await service.recoverPaymentAttempt(record.id, for: invoice)
                try result.validateWorkspace()
                #expect(result.value == record.id)
            }
            let payments = try context.fetch(FetchDescriptor<Payment>())
            #expect(payments.count == 1)
            let payment = try #require(payments.first)
            #expect(payment.id == record.id && payment.collectionAttemptID == record.id)
            #expect(payment.amount == 1.23)
            #expect(payment.quickBooksClientTransID == record.clientTransactionID)
            #expect(payment.isRefund == (kind == "refund"))
            #expect(payment.refundedPaymentID == record.intent.sourcePaymentID)
            #expect(sends == 0)
            #expect(journal.events.filter { $0 == "begin" }.count == 1)
        }
    }

    @Test func wrongInvoiceCannotRecoverOrCancelAnotherAttempt() async throws {
        let journal = FixturePaymentJournal()
        let record = try await seed(journal, invoice: invoice())
        let schema = GunnAireModelSchema.schema
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let wrongInvoice = invoice()
        container.mainContext.insert(wrongInvoice)
        let api = QuickBooksDataAPI(testTokens: .init(accessToken: "fixture", expiration: .distantFuture),
            realmID: "fixture-realm", environment: Config.QuickBooks.environment) { _ in
            Issue.record("Wrong invoice reached provider"); throw URLError(.unsupportedURL)
        }
        let service = QuickBooksPaymentsService(api: api, journal: journal)
        let events = journal.events
        await #expect(throws: PaymentAttemptError.needsReview) {
            try await service.recoverPaymentAttempt(record.id, for: wrongInvoice)
        }
        await #expect(throws: PaymentAttemptError.needsReview) {
            try await service.cancelPaymentReservation(record.id, for: wrongInvoice)
        }
        #expect(journal.events == events)
        #expect(try container.mainContext.fetch(FetchDescriptor<Payment>()).isEmpty)
    }

    @Test func recoveryRefreshesSavedAccountingHoldAndOfflineReadCannotFailConfirmedCapture() async throws {
        for mode in ["charge", "refund", "offline", "cancel", "cancel-offline"] {
            let schema = GunnAireModelSchema.schema
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
            let context = container.mainContext
            let invoice = invoice()
            invoice.taxCalculationStatusRawValue = BillingTaxCalculationStatus.notApplicable.rawValue
            context.insert(invoice.customer); context.insert(invoice); try context.save()
            let journal = FixturePaymentJournal()
            let cancelling = mode.hasPrefix("cancel"), offline = mode.hasSuffix("offline")
            let record: PaymentAttemptRecord
            if cancelling {
                record = try await journal.reserve(.init(id: UUID(), companyID: journal.businessID,
                    realmID: "fixture-realm", environment: Config.QuickBooks.environment, invoiceID: invoice.id,
                    invoiceQuickBooksID: "fixture-invoice", customerQuickBooksID: "fixture-customer",
                    amountCents: 123, rail: "card", kind: "charge"))
            } else {
                record = try await seed(journal, invoice: invoice, kind: mode == "refund" ? "refund" : "charge")
            }
            let identity = FieldPaymentReviewIdentity(companyID: journal.businessID, invoiceID: invoice.id,
                localCustomerID: invoice.customer.id, invoiceQuickBooksID: "fixture-invoice",
                customerQuickBooksID: "fixture-customer", serviceCallID: nil)
            func snapshot(held: Bool) throws -> FieldPaymentReviewSnapshot {
                let now = Date().addingTimeInterval(held ? -5 : 0)
                let allocations: [[String: Any]] = held || mode == "refund" || cancelling ? [] : [[
                    "paymentQuickBooksID": "fixture-accounting", "syncToken": "1",
                    "postingDate": "2026-09-08", "appliedCents": 123, "includesCreditOrAdjustment": false]]
                let balance = allocations.isEmpty ? 1000 : 877
                let payload = identity.query.mapValues { $0 as Any }.merging([
                    "realmID": "fixture-realm", "environment": Config.QuickBooks.environment.lowercased(),
                    "connectionRevision": String(repeating: "a", count: 64), "protocolVersion": 1,
                    "invoiceNumber": "1069", "invoiceDate": "2026-09-08", "syncToken": held ? "1" : "2",
                    "observedAt": ISO8601DateFormatter().string(from: now), "currency": "USD",
                    "totalCents": 1000, "balanceCents": balance, "collectionLimitCents": held ? 0 : balance,
                    "hasOpenAttempt": held, "fundsSettlementVerified": false, "authority": "office", "payments": allocations
                ]) { _, new in new }
                return try JSONDecoder().decode(FieldPaymentReviewSnapshot.self,
                    from: JSONSerialization.data(withJSONObject: payload))
            }
            try FieldPaymentReceiptReconciliation.apply(snapshot(held: true), to: invoice, identity: identity,
                context: context, check: {}, persist: { try context.save() })
            var providerSends = 0, sharedReads = 0
            let api = QuickBooksDataAPI(testTokens: .init(accessToken: "fixture", expiration: .distantFuture),
                realmID: "fixture-realm", environment: Config.QuickBooks.environment) { _ in
                providerSends += 1; throw URLError(.unsupportedURL)
            }
            let service = QuickBooksPaymentsService(api: api, journal: journal, receiptReviewClient: { original in
                #expect(original === invoice)
                let fresh = try snapshot(held: false)
                return try .init(identity: identity, check: {}, request: { path in
                    sharedReads += 1
                    if offline { throw URLError(.notConnectedToInternet) }
                    return try path.contains("/context?") ? JSONEncoder().encode(fresh.scope) : JSONEncoder().encode(fresh)
                })
            })
            let iterations = cancelling ? 1 : 2
            for _ in 0..<iterations {
                let result = try await (cancelling
                    ? service.cancelPaymentReservation(record.id, for: invoice)
                    : service.recoverPaymentAttempt(record.id, for: invoice))
                #expect(result.value == record.id)
                #expect((result.accountingReviewMessage != nil) == offline)
            }
            let payments = try context.fetch(FetchDescriptor<Payment>())
            #expect(providerSends == 0 && sharedReads == iterations * (offline ? 1 : 2))
            #expect((invoice.quickBooksReconciliationReviewMessage != nil) == offline)
            #expect(journal.events.filter { $0 == "begin" }.count == (cancelling ? 0 : 1))
            if cancelling {
                #expect(payments.isEmpty)
                #expect(try await journal.get(record.id).state == .cancelled)
                #expect(invoice.quickBooksBalanceDue == 10)
                continue
            }
            let saved = try #require(payments.first)
            #expect(payments.count == 1 && saved.id == record.id)
            #expect(saved.amount == 1.23 && saved.quickBooksAccountingSyncStatus == "synced")
            #expect(saved.isRefund == (mode == "refund"))
            if !offline {
                let statement = CustomerAccountStatementPolicy.snapshot(customer: invoice.customer,
                    invoices: [invoice], payments: payments, asOf: nil, calendar: .current, now: Date())
                #expect(statement.reviewMessages.isEmpty)
                #expect(statement.entries.first?.balanceDue == (mode == "refund" ? 10 : 8.77))
            }
        }
    }

    @Test func invoiceOrPaymentChangesDuringRecoveryCannotCommitAnOldResult() async throws {
        for mode in ["invoice", "customer", "payment", "receipt", "deleted"] {
            let schema = GunnAireModelSchema.schema
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
            let context = container.mainContext
            let invoice = invoice()
            context.insert(invoice.customer); context.insert(invoice); try context.save()
            let journal = FixturePaymentJournal()
            let record = try await seed(journal, invoice: invoice)
            journal.beforeAction = { action in
                guard action == "confirm" else { return }
                switch mode {
                case "invoice": invoice.amount = 11
                case "customer": invoice.customer.quickBooksID = "another-customer"
                case "payment": context.insert(Payment(invoice: invoice, amount: 2))
                case "receipt": invoice.quickBooksPaymentReviewJSON = "Newer writer"
                default: context.delete(invoice)
                }
            }
            var providerSends = 0
            let api = QuickBooksDataAPI(testTokens: .init(accessToken: "fixture", expiration: .distantFuture),
                realmID: "fixture-realm", environment: Config.QuickBooks.environment) { _ in
                providerSends += 1; throw URLError(.unsupportedURL)
            }
            let service = QuickBooksPaymentsService(api: api, journal: journal)
            await #expect(throws: (any Error).self) {
                try await service.recoverPaymentAttempt(record.id, for: invoice)
            }
            #expect(providerSends == 0)
            #expect(try context.fetch(FetchDescriptor<Payment>()).allSatisfy { $0.id != record.id })
            #expect(journal.events.filter { $0 == "complete" }.count == 1)
        }
    }

    @Test func refundReceiptRecoveryFailsClosedOnIncompleteConflictingAndDuplicateEvidence() async throws {
        let id = UUID()
        let marker = "Client transaction ID: ga-refund-" + id.uuidString.lowercased()
        let receipt = QuickBooksRefundReceiptCreate(Line: [
            .init(Amount: 1.23, DetailType: "SalesItemLineDetail", Description: nil,
                  SalesItemLineDetail: .init(ItemRef: .init(value: "fixture-item", name: nil)))],
            CustomerRef: .init(value: "fixture-customer", name: nil), CreditCardPayment: nil, TxnSource: nil, PrivateNote: marker)
        for outcome in ["match", "conflict", "duplicate", "missing", "read-failure", "new"] {
            var requests: [URLRequest] = []
            let api = QuickBooksDataAPI(testTokens: .init(accessToken: "fixture", expiration: .distantFuture),
                realmID: "fixture-realm", environment: Config.QuickBooks.environment) { request in
                requests.append(request)
                if request.httpMethod == "POST" {
                    #expect(outcome == "new")
                    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                    #expect(query?.first { $0.name == "requestid" }?.value == "ga-rr-" + id.uuidString.lowercased())
                    return try response(request, ["RefundReceipt": ["Id": "fixture-new"]])
                }
                if outcome == "read-failure" { throw URLError(.timedOut) }
                var remote: [String: Any] = ["Id": "fixture-existing", "TotalAmt": outcome == "conflict" ? 9.99 : 1.23,
                    "CustomerRef": ["value": "fixture-customer"], "PrivateNote": marker]
                if outcome == "missing" { remote.removeValue(forKey: "TotalAmt") }
                var records = outcome == "new" ? [] : [remote]
                if outcome == "duplicate" { remote["Id"] = "fixture-second"; records.append(remote) }
                return try response(request, ["QueryResponse": ["RefundReceipt": records]])
            }
            let result: Result<QuickBooksRefundReceipt, Error> = await withCheckedContinuation { continuation in
                api.recoverOrCreateRefundReceipt(receipt, localPaymentID: id) { continuation.resume(returning: $0) }
            }
            if outcome == "match" || outcome == "new" {
                #expect(try result.get().Id == (outcome == "new" ? "fixture-new" : "fixture-existing"))
            } else if case .success = result { Issue.record("Unverified refund evidence allowed accounting recovery") }
            #expect(requests.filter { $0.httpMethod == "POST" }.count == (outcome == "new" ? 1 : 0))
        }
    }

    @Test func bankSettlementStateSurvivesUnrelatedQueueStatusUpdates() {
        let payment = Payment(invoice: invoice(), providerPaymentStatus: "PENDING", amount: 1.23, method: "ach")
        #expect(payment.isProviderSettlementPending)
        payment.markSharedCompanyQueued()
        #expect(payment.isProviderSettlementPending)
        payment.providerPaymentStatus = "SETTLED"
        #expect(!payment.isProviderSettlementPending)
    }
}
