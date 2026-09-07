import Foundation
import Testing
@testable import GunnAire_Ops

@MainActor
struct QuickBooksPaymentWorkflowTests {
    private func api(_ transport: @escaping WorkspaceProviderOperation.Transport) -> QuickBooksDataAPI {
        QuickBooksDataAPI(testTokens: .init(accessToken: "fixture-bearer", expiration: .distantFuture),
            realmID: "fixture-realm", environment: Config.QuickBooks.environment, transport: transport)
    }

    private func reply(_ request: URLRequest, payload: String = #"{"QueryResponse":{"Customer":[]}}"#,
                       status: Int = 200) -> (Data, URLResponse) {
        (Data(payload.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                          headerFields: ["Retry-After": "0.001"])!)
    }

    private func customers(_ api: QuickBooksDataAPI) async throws -> [QuickBooksCustomer] {
        try await withCheckedThrowingContinuation { continuation in
            api.fetchCustomers { continuation.resume(with: $0) }
        }
    }

    private func replaceConnection(_ api: QuickBooksDataAPI) {
        api.storeTokens(.init(accessToken: "replacement-fixture-bearer", expiration: .distantFuture),
                        realmID: "fixture-realm")
    }

    @Test func sequentialWorkflowCannotRecaptureAReplacementConnectionAfterAwait() async {
        var sends = 0
        let api = api { request in sends += 1; return reply(request) }
        do {
            try await api.withWorkspaceOperation { _ in
                _ = try await customers(api)
                replaceConnection(api)
                _ = try await customers(api)
            }
            Issue.record("Old workflow continued after account replacement")
        } catch {
            #expect(error as? WorkspaceProviderAccessError == .changed(mayHaveReachedProvider: false))
        }
        #expect(sends == 1)
        #expect(api.tokens?.accessToken == "replacement-fixture-bearer")
    }

    @Test func workflowChecksItsFinalReturnEvenWhenNoMoreRequestsAreNeeded() async {
        let api = api { reply($0) }
        do {
            _ = try await api.withWorkspaceOperation { _ in
                _ = try await customers(api)
                replaceConnection(api)
                return "must not reach the caller"
            }
            Issue.record("A late workflow result reached its caller")
        } catch {
            #expect(error as? WorkspaceProviderAccessError == .changed(mayHaveReachedProvider: false))
        }
    }

    @Test func callbackRecoveryRetainsIdentityAfterADelayed429Retry() async {
        var sends = 0
        let api = api { request in
            sends += 1
            return reply(request, status: sends == 1 ? 429 : 200)
        }
        let result: Result<[QuickBooksCustomer], Error> = await withCheckedContinuation { continuation in
            api.fetchCustomers { first in
                guard case .success = first else { continuation.resume(returning: first); return }
                replaceConnection(api)
                api.fetchCustomers { continuation.resume(returning: $0) }
            }
        }
        if case .failure(let error) = result {
            #expect(error as? WorkspaceProviderAccessError == .changed(mayHaveReachedProvider: false))
        } else { Issue.record("Callback recovery recaptured replacement credentials") }
        #expect(sends == 2)
    }

    @Test func nestedAndChildTasksKeepTheOriginalProviderOwner() async {
        var sends = 0
        let first = api { request in sends += 1; return reply(request) }
        let second = api { request in sends += 1; return reply(request) }
        do {
            try await first.withWorkspaceOperation { _ in
                _ = try await Task { try await customers(second) }.value
            }
            Issue.record("An operation from another API instance was adopted")
        } catch {
            #expect(error as? WorkspaceProviderAccessError == .changed(mayHaveReachedProvider: false))
        }
        #expect(sends == 0)
    }

    @Test func returnedPaymentEvidenceMustBeRecheckedBeforeSavingModels() async throws {
        let api = api { reply($0) }
        let result = try await api.withWorkspaceOperation { operation in
            QuickBooksProcessedPaymentResult(
                charge: try JSONDecoder().decode(QuickBooksPaymentsChargeResponse.self,
                    from: Data(#"{"id":"fixture-charge","amount":"1.23","status":"CAPTURED"}"#.utf8)),
                accountingPayment: nil, accountingError: nil, clientTransactionID: "fixture-client",
                operation: operation)
        }
        try result.validateWorkspace()
        replaceConnection(api)
        #expect(throws: WorkspaceProviderAccessError.self) { try result.validateWorkspace() }
    }

    @Test func cardAndBankRequestsUseDistinctResourcesAndRetainExplicitRequestIDs() async throws {
        for family in 0...3 {
            var sent: [URLRequest] = []
            let requestID = UUID()
            let api = api { request in
                sent.append(request)
                return reply(request, payload: #"{"id":"fixture-result","status":"PENDING","amount":"1.23"}"#,
                             status: sent.count == 1 ? 429 : 200)
            }
            let result: Result<Void, Error> = await withCheckedContinuation { continuation in
                let done: (Result<Void, Error>) -> Void = { continuation.resume(returning: $0) }
                switch family {
                case 0:
                    api.createCharge(.init(amount: "1.23", currency: "USD", capture: true,
                        token: "fixture-token", description: nil, context: nil, paymentMode: nil, checkNumber: nil),
                        requestID: requestID) { done($0.map { _ in () }) }
                case 1:
                    api.createECheck(.init(amount: "1.23", token: "fixture-token", description: nil,
                        context: nil, paymentMode: "WEB", checkNumber: "fixture-check"),
                        requestID: requestID) { done($0.map { _ in () }) }
                case 2:
                    api.refundCharge(id: "fixture-original", amount: 1.23, description: nil,
                        requestID: requestID) { done($0.map { _ in () }) }
                default:
                    api.refundECheck(id: "fixture-original", amount: 1.23, description: nil,
                        requestID: requestID) { done($0.map { _ in () }) }
                }
            }
            try result.get()
            #expect(sent.count == 2)
            guard sent.count == 2 else { continue }
            #expect(sent[0] == sent[1])
            #expect(sent[0].value(forHTTPHeaderField: "Request-Id") == requestID.uuidString)
            let suffix = ["charges", "echecks", "charges/fixture-original/refunds", "echecks/fixture-original/refunds"][family]
            #expect(sent[0].url?.path.hasSuffix("/" + suffix) == true)
            if family == 1 {
                let body = try #require(try JSONSerialization.jsonObject(with: sent[0].httpBody!) as? [String: Any])
                #expect(body["currency"] == nil && body["capture"] == nil && body["card"] == nil)
                #expect(body["paymentMode"] as? String == "WEB")
            }
        }
    }

    @Test func invalidRefundIdentifiersNeverReachEitherProviderResource() async {
        var sends = 0
        let api = api { request in sends += 1; return reply(request) }
        for id in ["", "../charges/another", "charge?amount=1", "charge/another", String(repeating: "x", count: 129)] {
            let result = await withCheckedContinuation { continuation in
                api.refundECheck(id: id, amount: 1, description: nil) { continuation.resume(returning: $0) }
            }
            if case .success = result { Issue.record("Malformed transaction identifier accepted") }
        }
        #expect(sends == 0)
        #expect(QuickBooksPaymentRail.forMethod("ACH transfer") == .bank)
        #expect(QuickBooksPaymentRail.forMethod("card ••••1234") == .card)
        #expect(QuickBooksPaymentRail.forMethod("cash") == nil)
    }

    private func invoice() -> Invoice {
        Invoice(customer: Customer(quickBooksID: "fixture-customer", name: "Fixture customer"),
                quickBooksID: "fixture-invoice", quickBooksBalanceDue: 10, amount: 10)
    }

    @Test func actualBankCollectionServiceUsesEChecksAndDoesNotMarkMalformedResultsPaid() async {
        var sent: [URLRequest] = []
        let api = api { request in
            sent.append(request)
            return reply(request, payload: request.url!.path.hasSuffix("/tokens")
                         ? #"{"value":"fixture-bank-token"}"# : "{}")
        }
        let service = QuickBooksPaymentsService(api: api)
        let invoice = invoice()
        do {
            _ = try await service.processBankPayment(localPaymentID: UUID(), invoice: invoice, amount: 1.23,
                bankInput: .init(accountHolderName: "Fixture only", accountNumber: "1234",
                    routingNumber: "490000018", phone: "2025550100", accountType: .personalChecking,
                    checkNumber: nil), note: nil, catalogItems: [])
            Issue.record("Malformed bank response was treated as a payment")
        } catch {}
        #expect(sent.map { $0.url!.lastPathComponent } == ["tokens", "echecks"])
        #expect(invoice.status == "unpaid")
    }

    @Test func actualRefundServiceSelectsTheOriginalPaymentRail() async {
        for method in ["card", "ach"] {
            var sent: [URLRequest] = []
            let api = api { request in sent.append(request); return reply(request, payload: "{}") }
            let service = QuickBooksPaymentsService(api: api, salesItemReference: "fixture-sales-item")
            let payment = Payment(invoice: invoice(), quickBooksChargeID: "fixture-original", amount: 1.23, method: method)
            do {
                _ = try await service.refundPayment(payment: payment, amount: 1, note: nil)
                Issue.record("Malformed refund response was confirmed")
            } catch {}
            #expect(sent.count == 1)
            #expect(sent.first?.url?.path.hasSuffix(method == "ach"
                ? "/echecks/fixture-original/refunds" : "/charges/fixture-original/refunds") == true)
        }
    }
    @Test func refundAccountingRecordsNeverRequestAnotherProcessorTransaction() async throws {
        for method in ["card", "ach"] {
            var sent: [URLRequest] = []
            let api = api { request in
                sent.append(request)
                return reply(request, payload: request.url!.path.hasSuffix("/refundreceipt")
                    ? #"{"RefundReceipt":{"Id":"fixture-receipt"}}"#
                    : #"{"id":"fixture-refund","amount":"1.00","status":"REFUNDED"}"#)
            }
            let service = QuickBooksPaymentsService(api: api, salesItemReference: "fixture-sales-item")
            let payment = Payment(invoice: invoice(), quickBooksChargeID: "fixture-original",
                                  amount: 1.23, method: method)
            let result = try await service.refundPayment(payment: payment, amount: 1, note: "Fixture refund")
            try result.validateWorkspace()
            #expect(result.refundReceipt?.Id == "fixture-receipt")
            #expect(result.accountingError == nil)
            #expect(sent.count == 2)
            let accounting = try #require(sent.last?.httpBody)
            let body = try #require(try JSONSerialization.jsonObject(with: accounting) as? [String: Any])
            #expect(body["CreditCardPayment"] == nil)
            #expect(body["TxnSource"] == nil)
            #expect((body["PrivateNote"] as? String)?.contains("Client transaction ID: ") == true)
        }
    }

    @Test func accountingFollowUpOwnsSuccessAndFailureWritesAndRejectsOldConnections() async throws {
        for outcome in ["success", "error", "changed-success", "changed-error"] {
            var instance: QuickBooksDataAPI!
            instance = api { request in
                if outcome.hasPrefix("changed") { replaceConnection(instance) }
                return reply(request, payload: #"{"RefundReceipt":{"Id":"fixture-receipt"}}"#,
                             status: outcome.hasSuffix("error") ? 400 : 200)
            }
            let service = QuickBooksPaymentsService(api: instance, salesItemReference: "fixture-sales-item")
            let payment = Payment(invoice: invoice(), quickBooksChargeID: "fixture-refund",
                quickBooksAccountingSyncStatus: "pending", amount: -1, method: "ach", isRefund: true)
            do {
                let result = try await service.syncAndRecordAccountingFollowUp(for: payment)
                #expect(outcome == "success")
                try result.validateWorkspace()
                #expect(result.value == "fixture-receipt")
                #expect(payment.quickBooksRefundReceiptID == "fixture-receipt")
                #expect(payment.quickBooksAccountingSyncStatus == "synced")
                replaceConnection(instance)
                #expect(throws: WorkspaceProviderAccessError.self) { try result.validateWorkspace() }
            } catch {
                #expect(outcome != "success")
                #expect(payment.quickBooksRefundReceiptID == nil)
                if outcome.hasPrefix("changed") {
                    #expect(error as? WorkspaceProviderAccessError == .changed(mayHaveReachedProvider: true))
                    #expect(payment.quickBooksAccountingSyncStatus == "pending")
                    #expect(payment.quickBooksAccountingSyncDetail == nil)
                } else {
                    #expect(payment.quickBooksAccountingSyncStatus == "needs_attention")
                    #expect(payment.quickBooksAccountingSyncDetail != nil)
                }
            }
        }
    }

    @Test func storedCardTokenAndCustomerLinkUseOneOperationAndLateEvidenceIsRejected() async throws {
        for changeAt in [0, 1, 2] {
            var sent: [URLRequest] = []
            var instance: QuickBooksDataAPI!
            instance = api { request in
                sent.append(request)
                if sent.count == changeAt { replaceConnection(instance) }
                return reply(request, payload: sent.count == 1 ? #"{"value":"fixture-token"}"#
                    : #"{"id":"fixture-card","number":"1234","name":"Fixture only"}"#)
            }
            let service = QuickBooksPaymentsService(api: instance)
            let customer = try JSONDecoder().decode(QuickBooksCustomer.self,
                from: Data(#"{"Id":"fixture-customer","DisplayName":"Fixture"}"#.utf8))
            do {
                let result = try await service.storeCard(.init(cardholderName: "Fixture only",
                    cardNumber: "4111111111111111", expMonth: "12", expYear: "2040", cvc: "123",
                    postalCode: nil, addressLine: nil, city: nil, region: nil, country: "US"), for: customer)
                #expect(changeAt == 0)
                try result.validateWorkspace()
                #expect(result.value.id == "fixture-card")
                replaceConnection(instance)
                #expect(throws: WorkspaceProviderAccessError.self) { try result.validateWorkspace() }
            } catch {
                #expect(changeAt != 0)
                #expect(error as? WorkspaceProviderAccessError == .changed(mayHaveReachedProvider: true))
            }
            #expect(sent.count == (changeAt == 1 ? 1 : 2))
            if sent.count == 2 {
                #expect(sent[1].url?.path.hasSuffix("/customers/fixture-customer/cards/createFromToken") == true)
            }
        }
    }

    @Test func invalidAmountsFailBeforeTokenizationOrRefundAndNeverTrap() async {
        var sends = 0
        let api = api { request in sends += 1; return reply(request) }
        let service = QuickBooksPaymentsService(api: api, salesItemReference: "fixture-sales-item")
        let payment = Payment(invoice: invoice(), quickBooksChargeID: "fixture-original", amount: 10, method: "card")
        for amount in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, 0, -1, 1.001] {
            await #expect(throws: QuickBooksPaymentsServiceError.invalidAmount) {
                try await service.refundPayment(payment: payment, amount: amount, note: nil)
            }
            await #expect(throws: QuickBooksPaymentsServiceError.invalidAmount) {
                try await service.processBankPayment(localPaymentID: UUID(), invoice: invoice(), amount: amount,
                    bankInput: .init(accountHolderName: "Fixture", accountNumber: "1234",
                        routingNumber: "490000018", phone: "2025550100", accountType: .personalChecking,
                        checkNumber: nil), note: nil, catalogItems: [])
            }
        }
        await #expect(throws: QuickBooksPaymentsServiceError.invalidAmount) {
            try await service.refundPayment(payment: payment, amount: 11, note: nil)
        }
        #expect(sends == 0)
    }

    @Test func providerAndNetworkErrorsNeverExposeBodiesHeadersOrEchoedSecrets() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("privacy-fixture.txt")
        try Data("Fixture document".utf8).write(to: file)
        let marker = "FIXTURE_PRIVATE_VALUE_928371"
        for family in 0...5 {
            for status in [200, 400, 401, 403, 404, 409, 500, -1] {
                let instance = api { request in
                    if status == -1 {
                        throw NSError(domain: "Fixture network", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: marker])
                    }
                    let body = status == 200 ? marker :
                        #"{"Fault":{"Error":[{"Message":"\#(marker)","Detail":"\#(marker)","code":"3100"}]},"errors":[{"message":"\#(marker)","detail":"\#(marker)"}]}"#
                    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status,
                        httpVersion: nil, headerFields: ["Set-Cookie": marker, "Authorization": marker,
                            "Location": "https://fixture.invalid/" + marker, "intuit_tid": marker])!)
                }
                let result: Result<Void, Error> = await withCheckedContinuation { continuation in
                    let done: (Result<Void, Error>) -> Void = { continuation.resume(returning: $0) }
                    switch family {
                    case 0: instance.fetchCustomers { done($0.map { _ in () }) }
                    case 1: instance.fetchCards(forCustomerID: "fixture-customer") { done($0.map { _ in () }) }
                    case 2: instance.createCardToken(.init(card: nil, bankAccount: nil)) { done($0.map { _ in () }) }
                    case 3:
                        instance.createCharge(.init(amount: "1.23", currency: "USD", capture: true,
                            token: "fixture-token", description: nil, context: nil, paymentMode: nil,
                            checkNumber: nil)) { done($0.map { _ in () }) }
                    case 4: instance.uploadDocument(fileURL: file) { done($0.map { _ in () }) }
                    default: instance.refundECheck(id: "fixture-original", amount: 1, description: nil) {
                        done($0.map { _ in () })
                    }
                    }
                }
                switch result {
                case .success:
                    // The public stored-card API treats unavailable cards as
                    // an empty collection; retain that established contract.
                    #expect(status == 404 && family == 1)
                case .failure(let error):
                    #expect(!error.localizedDescription.contains(marker))
                    #expect(!String(describing: error).contains(marker))
                    #expect(!error.localizedDescription.contains("Set-Cookie"))
                    #expect(!error.localizedDescription.contains("Authorization:"))
                    #expect(error.localizedDescription.contains("QuickBooks"))
                    #expect(!(status == 404 && family == 1))
                }
            }
        }
    }
}
