import Foundation
import Testing
@testable import GunnAire_Ops

@MainActor
struct BillingPublicationClientTests {
    private let company = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private let customer = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
    private let documentID = UUID(uuidString: "10000000-0000-4000-8000-000000000003")!
    private let attempt = UUID(uuidString: "10000000-0000-4000-8000-000000000004")!
    private let job = UUID(uuidString: "10000000-0000-4000-8000-000000000005")!

    private func api() -> QuickBooksDataAPI {
        .init(testTokens: .init(accessToken: "fixture", expiration: .distantFuture), realmID: "billing-realm",
              environment: Config.QuickBooks.environment, catalogCompanyID: company, transport: { _ in
                  Issue.record("Shared billing client reached direct QuickBooks transport")
                  throw BillingPublicationError.unavailable
              })
    }

    private func request(kind: BillingPublicationDocumentKind = .invoice, companyID: UUID? = nil,
                         date: String = "2026-09-07", price: Double = 189, taxable: Bool = false) -> BillingPublicationRequest {
        .init(companyID: companyID ?? company, realmID: "billing-realm", environment: Config.QuickBooks.environment,
              documentType: kind, localDocumentID: documentID, localCustomerID: customer, operation: .create,
              document: .init(CustomerRef: .init(value: "C1", name: nil), Line: [
                .init(Amount: price, DetailType: "SalesItemLineDetail", Description: "Repair labor",
                      SalesItemLineDetail: .init(ItemRef: .init(value: "I1", name: nil), Qty: 1, UnitPrice: price,
                                                TaxCodeRef: .init(value: taxable ? "TAX" : "NON", name: nil)))
              ], TxnDate: date), serviceCallID: job, assignmentRevision: 1)
    }

    private func record(kind: BillingPublicationDocumentKind = .invoice, state: String = "confirmed", changes: [String: Any] = [:]) -> [String: Any] {
        var result: [String: Any] = ["id": attempt.uuidString, "companyID": company.uuidString, "realmID": "billing-realm",
            "environment": Config.QuickBooks.environment, "documentType": kind.rawValue, "localDocumentID": documentID.uuidString,
            "localCustomerID": customer.uuidString, "operation": "create", "state": state,
            "providerID": state == "confirmed" ? "D1" : NSNull(), "updatedAt": "2026-09-07T00:00:00Z"]
        result.merge(changes) { _, new in new }
        return result
    }

    private func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

    private func response(kind: BillingPublicationDocumentKind = .invoice, recordChanges: [String: Any] = [:],
                          documentChanges: [String: Any] = [:]) throws -> Data {
        var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request(kind: kind).document)) as! [String: Any]
        value.merge(["Id": "D1", "SyncToken": "0", "TotalAmt": 189, "Balance": 189, "TxnTaxDetail": ["TotalTax": 0],
                     "PrivateNote": "GunnAire \(kind.rawValue) ID: \(documentID.uuidString)"]) { _, new in new }
        value.merge(documentChanges) { _, new in new }
        return try data(["publication": record(kind: kind, changes: recordChanges), "document": value])
    }

    private func assignment(changes: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = ["companyID": company.uuidString, "realmID": "billing-realm", "environment": Config.QuickBooks.environment,
            "serviceCallID": job.uuidString, "localCustomerID": customer.uuidString, "revision": 1,
            "technicianEmails": ["field@example.invalid"], "enabled": true, "usable": true, "updatedAt": "2026-09-07T00:00:00Z"]
        value.merge(changes) { _, new in new }
        return value
    }

    private func assignmentRequest() -> JobBillingAssignmentRequest {
        .init(companyID: company, realmID: "billing-realm", environment: Config.QuickBooks.environment,
              serviceCallID: job, localCustomerID: customer, technicianEmails: ["field@example.invalid"], enabled: true,
              expectedRevision: 0, operationID: attempt, connectionRevision: String(repeating: "a", count: 64))
    }

    @Test func invoiceContractKeepsOriginalSoldValuesJobAndDateWithoutSendOrPaymentFields() async throws {
        let api = api()
        var calls = 0
        let client = BillingPublicationClient { path, method, body in
            calls += 1
            #expect(path == "/api/billing-publications"); #expect(method == "POST")
            let encoded = try #require(body)
            let payload = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            #expect(payload["localDocumentID"] as? String == documentID.uuidString)
            #expect(payload["serviceCallID"] as? String == job.uuidString)
            #expect(payload["assignmentRevision"] as? Int == 1)
            let document = payload["document"] as! [String: Any]
            #expect(document["TxnDate"] as? String == "2026-09-07")
            #expect(document["EmailStatus"] == nil); #expect(document["AllowOnlineCreditCardPayment"] == nil)
            #expect(document["Id"] == nil)
            return try response()
        }
        let result = try await client.publish(request(), workflow: api.captureWorkspaceWorkflow())
        #expect(result.invoice?.TotalAmt == 189); #expect(result.estimate == nil); #expect(calls == 1)
    }

    @Test func estimateResponseDecodesAsEstimateAndRetainsOriginalLines() async throws {
        let api = api(), client = BillingPublicationClient { _, _, _ in try response(kind: .estimate) }
        let result = try await client.publish(request(kind: .estimate), workflow: api.captureWorkspaceWorkflow())
        #expect(result.estimate?.Id == "D1"); #expect(result.invoice == nil)
        #expect(result.estimate?.Line?.first?.SalesItemLineDetail.UnitPrice == 189)
    }

    @Test func changedCompanyInvalidDateAndMissingStructuredTaxAddressesStopBeforeTransport() async throws {
        let api = api()
        var calls = 0
        let client = BillingPublicationClient { _, _, _ in calls += 1; return try response() }
        for value in [request(companyID: UUID()), request(date: "2026-02-31"), request(date: "2026-9-7"), request(taxable: true), request(price: .infinity)] {
            await #expect(throws: (any Error).self) { try await client.publish(value, workflow: api.captureWorkspaceWorkflow()) }
        }
        #expect(calls == 0)
    }

    @Test func partialOrInvalidAssignmentCannotBeClaimedByRequest() throws {
        var value = request()
        value.assignmentRevision = nil
        #expect(throws: BillingPublicationError.invalidProposal) { try value.validate() }
        value.assignmentRevision = 0
        #expect(throws: BillingPublicationError.invalidProposal) { try value.validate() }
    }

    @Test func publicationNeverFallsBackOrAutomaticallyResendsAfterTimeout() async throws {
        let api = api()
        var calls = 0
        let client = BillingPublicationClient { _, _, _ in calls += 1; throw URLError(.timedOut) }
        await #expect(throws: BillingPublicationError.unavailable) { try await client.publish(request(), workflow: api.captureWorkspaceWorkflow()) }
        #expect(calls == 1)
    }

    @Test func changedConnectionRejectsLatePublicationAndRetainsUncertainWriteEvidence() async throws {
        let api = api()
        let workflow = try api.captureWorkspaceWorkflow()
        let client = BillingPublicationClient { _, _, _ in api.clearTokens(); return try response() }
        await #expect(throws: WorkspaceProviderAccessError.changed(mayHaveReachedProvider: true)) { try await client.publish(request(), workflow: workflow) }
    }

    @Test func cancelledOwnerStopsBeforeSending() async throws {
        let api = api()
        var current = true, calls = 0
        let workflow = try api.captureWorkspaceWorkflow { current }
        current = false
        let client = BillingPublicationClient { _, _, _ in calls += 1; return try response() }
        await #expect(throws: WorkspaceProviderAccessError.changed(mayHaveReachedProvider: false)) { try await client.publish(request(), workflow: workflow) }
        #expect(calls == 0)
    }

    @Test func wrongScopeCustomerProviderOperationOrStateIsRejected() async throws {
        for changes: [String: Any] in [["companyID": UUID().uuidString], ["realmID": "other"], ["localCustomerID": UUID().uuidString],
                                      ["localDocumentID": UUID().uuidString], ["providerID": "different"], ["state": "unknown"], ["operation": "update"]] {
            let api = api(), client = BillingPublicationClient { _, _, _ in try response(recordChanges: changes) }
            await #expect(throws: BillingPublicationError.invalidResponse) { try await client.publish(request(), workflow: api.captureWorkspaceWorkflow()) }
        }
    }

    @Test func missingBalanceWrongLineageAndChangedSoldLinesAreRejected() async throws {
        for changes: [String: Any] in [["Balance": NSNull()], ["Balance": 190], ["TxnTaxDetail": ["TotalTax": -1]],
                                      ["TotalAmt": 200], ["TxnDate": "2026-09-08"],
                                      ["PrivateNote": "GunnAire Invoice ID: \(UUID())"], ["Line": []], ["CustomerRef": ["value": "other"]]] {
            let api = api(), client = BillingPublicationClient { _, _, _ in try response(documentChanges: changes) }
            await #expect(throws: BillingPublicationError.invalidResponse) { try await client.publish(request(), workflow: api.captureWorkspaceWorkflow()) }
        }
    }

    @Test func recoveryRequestsOnlyOriginalAttemptAndRejectsAnotherAttemptID() async throws {
        let api = api()
        let client = BillingPublicationClient { path, method, body in
            #expect(path == "/api/billing-publications/\(attempt.uuidString.lowercased())/recover")
            #expect(method == "POST"); #expect(body == Data("{}".utf8))
            return try response(recordChanges: ["id": UUID().uuidString])
        }
        await #expect(throws: BillingPublicationError.invalidResponse) {
            try await client.recover(attempt, scope: request().scope, customerID: customer, providerCustomerID: "C1", workflow: api.captureWorkspaceWorkflow())
        }
    }

    @Test func cancellationMustConfirmOriginalUnsentAttemptWasCancelled() async throws {
        let api = api()
        let client = BillingPublicationClient { path, _, _ in
            #expect(path.hasSuffix("/\(attempt.uuidString.lowercased())/cancel"))
            return try data(["publication": record(state: "cancelled")])
        }
        let result = try await client.cancel(attempt, scope: request().scope, customerID: customer, workflow: api.captureWorkspaceWorkflow())
        #expect(result.state == .cancelled)
    }

    @Test func cancelledResponseCannotNameAnotherOriginalAttempt() async throws {
        let api = api(), client = BillingPublicationClient { _, _, _ in
            try data(["publication": record(state: "cancelled", changes: ["id": UUID().uuidString])])
        }
        await #expect(throws: BillingPublicationError.invalidResponse) {
            try await client.cancel(attempt, scope: request().scope, customerID: customer, workflow: api.captureWorkspaceWorkflow())
        }
    }

    @Test func listUsesScopeAndOpaqueCursorWithoutQueryInjection() async throws {
        let api = api(), cursor = "opaque&companyID=other"
        let client = BillingPublicationClient { path, method, body in
            #expect(method == "GET"); #expect(body == nil)
            let query = try #require(URLComponents(string: path)?.queryItems)
            #expect(query.filter { $0.name == "companyID" }.count == 1)
            #expect(query.first { $0.name == "cursor" }?.value == cursor)
            return try data(["publications": [record()], "nextCursor": NSNull()])
        }
        let result = try await client.list(request().scope, customerID: customer, cursor: cursor, workflow: api.captureWorkspaceWorkflow())
        #expect(result.publications.count == 1)
    }

    @Test func repeatedListIDsAndRepeatedCursorAreNotAccepted() async throws {
        for value: [String: Any] in [["publications": [record(), record()], "nextCursor": NSNull()],
                                    ["publications": [], "nextCursor": "repeat"]] {
            let api = api(), client = BillingPublicationClient { _, _, _ in try data(value) }
            await #expect(throws: BillingPublicationError.invalidResponse) {
                try await client.list(request().scope, customerID: customer, cursor: "repeat", workflow: api.captureWorkspaceWorkflow())
            }
        }
    }

    @Test func assignmentSaveKeepsStableOperationAndExpectedServerRevision() async throws {
        let api = api(), value = assignmentRequest()
        let client = BillingPublicationClient { path, method, body in
            #expect(path == "/api/job-billing-assignments"); #expect(method == "POST")
            let encoded = try JSONSerialization.jsonObject(with: #require(body)) as! [String: Any]
            #expect(encoded["expectedRevision"] as? Int == 0)
            #expect(encoded["operationID"] as? String == attempt.uuidString)
            return try data(["assignment": assignment(), "connectionRevision": String(repeating: "a", count: 64)])
        }
        let saved = try await client.saveAssignment(value, workflow: api.captureWorkspaceWorkflow())
        #expect(saved.revision == 1); #expect(saved.usable)
    }

    @Test func conflictingAssignmentDoesNotRetryOrOverwriteNewerOfficeWork() async throws {
        let api = api()
        var calls = 0
        let client = BillingPublicationClient { _, _, _ in
            calls += 1
            throw GunnAireBackendError.server(statusCode: 409, message: "private diagnostic that must not become UI")
        }
        await #expect(throws: BillingPublicationError.reviewRequired) { try await client.saveAssignment(assignmentRequest(), workflow: api.captureWorkspaceWorkflow()) }
        #expect(calls == 1)
    }

    @Test func changedJobRosterCustomerRevisionAndUnusableApprovalAreRejected() async throws {
        for change: [String: Any] in [["serviceCallID": UUID().uuidString], ["localCustomerID": UUID().uuidString], ["revision": 2],
                                     ["technicianEmails": ["different@example.invalid"]], ["usable": false], ["enabled": false]] {
            let api = api(), client = BillingPublicationClient { _, _, _ in try data(["assignment": assignment(changes: change), "connectionRevision": String(repeating: "a", count: 64)]) }
            await #expect(throws: BillingPublicationError.invalidResponse) { try await client.saveAssignment(assignmentRequest(), workflow: api.captureWorkspaceWorkflow()) }
        }
    }

    @Test func readMissingAssignmentDoesNotCreateOne() async throws {
        let api = api()
        let client = BillingPublicationClient { path, method, body in
            #expect(path.hasPrefix("/api/job-billing-assignments?")); #expect(method == "GET"); #expect(body == nil)
            return try data(["assignment": NSNull(), "connectionRevision": String(repeating: "a", count: 64)])
        }
        let result = try await client.assignment(assignmentRequest().scope, customerID: customer, workflow: api.captureWorkspaceWorkflow())
        #expect(result == nil)
    }

    @Test func userNotesKeepProposalOptionsWhileServerOwnsInvoiceLineage() {
        let input = "Work completed\nGunnAire Invoice ID: old\nGunnAire Publication: old\nGunnAire Proposal Option: Best"
        #expect(BillingPublicationProposal.userNote(input) == "Work completed\nGunnAire Proposal Option: Best")
        #expect(BillingPublicationProposal.userNote(nil) == nil)
    }

    @Test func approvalAndRevocationUseExactProposalAndOriginalApprovalID() async throws {
        let api = api()
        var calls = 0
        let client = BillingPublicationClient { path, _, body in
            calls += 1
            if path.hasSuffix("/approve") {
                let payload = try JSONSerialization.jsonObject(with: #require(body)) as! [String: Any]
                #expect(payload["technicianEmail"] as? String == "field@example.invalid")
                #expect((payload["proposal"] as? [String: Any])?["localDocumentID"] as? String == documentID.uuidString)
                return try data(["id": attempt.uuidString])
            }
            #expect(path == "/api/billing-publications/draft-grants/\(attempt.uuidString.lowercased())/revoke")
            return try data(["id": attempt.uuidString, "revoked": true])
        }
        let workflow = try api.captureWorkspaceWorkflow()
        let id = try await client.approve(request(), technicianEmail: "field@example.invalid", workflow: workflow)
        try await client.revokeApproval(id, workflow: workflow)
        #expect(calls == 2)
    }
}
