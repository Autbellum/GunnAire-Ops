import Foundation
import Testing
@testable import GunnAire_Ops

@MainActor struct FieldPaymentReviewTests {
    private let identity = FieldPaymentReviewIdentity(companyID: UUID(), invoiceID: UUID(), localCustomerID: UUID(),
        invoiceQuickBooksID: "130", customerQuickBooksID: "24", serviceCallID: nil)
    private let now = Date(timeIntervalSince1970: 1_788_890_400)

    private func scopePayload() -> [String: Any] {
        var value: [String: Any] = identity.query
        value["realmID"] = "fixture-realm"; value["environment"] = "sandbox"
        value["connectionRevision"] = String(repeating: "a", count: 64)
        return value
    }
    private func payload(_ changes: [String: Any] = [:]) -> [String: Any] {
        scopePayload().merging(["protocolVersion": 1, "invoiceNumber": "1037", "invoiceDate": "2026-09-08",
            "syncToken": "1", "observedAt": ISO8601DateFormatter().string(from: now), "currency": "USD",
            "totalCents": 10000, "balanceCents": 6000, "collectionLimitCents": 6000, "hasOpenAttempt": false,
            "fundsSettlementVerified": false, "authority": "assigned", "payments": [allocation()]
        ]) { _, new in new }.merging(changes) { _, new in new }
    }
    private func allocation(_ changes: [String: Any] = [:]) -> [String: Any] {
        ["paymentQuickBooksID": "163", "syncToken": "0", "postingDate": "2026-09-08",
         "appliedCents": 4000, "includesCreditOrAdjustment": false].merging(changes) { _, new in new }
    }
    private func data(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func snapshot(_ changes: [String: Any] = [:]) throws -> FieldPaymentReviewSnapshot {
        try JSONDecoder().decode(FieldPaymentReviewSnapshot.self, from: data(payload(changes)))
    }
    private func scope() throws -> FieldPaymentReviewScope { try JSONDecoder().decode(FieldPaymentReviewScope.self, from: data(scopePayload())) }

    @Test func invoiceNumberIsDistinctFromInternalIDAndMissingNumberStaysMissing() throws {
        let result = try snapshot()
        try result.validate(scope(), now: now)
        #expect(result.invoiceNumber == "1037")
        #expect(result.scope.invoiceQuickBooksID == "130")
        let noNumber = try snapshot(["invoiceNumber": NSNull()])
        try noNumber.validate(scope(), now: now)
        #expect(noNumber.invoiceNumber == nil)
    }

    @Test func mismatchedCompanyInvoiceCustomerConnectionOrJobIsRejected() throws {
        for change: [String: Any] in [["companyID": UUID().uuidString], ["invoiceID": UUID().uuidString],
            ["localCustomerID": UUID().uuidString], ["serviceCallID": UUID().uuidString],
            ["invoiceQuickBooksID": "another"], ["customerQuickBooksID": "another"], ["realmID": "other"],
            ["environment": "production"], ["connectionRevision": String(repeating: "b", count: 64)]] {
            #expect(throws: FieldPaymentReviewError.invalid) { try snapshot(change).validate(scope(), now: now) }
        }
    }

    @Test func rejectsInvalidFinancialShapeAndSettlementClaim() throws {
        for change: [String: Any] in [["protocolVersion": 2], ["totalCents": -1], ["balanceCents": 10001],
            ["collectionLimitCents": 6001], ["hasOpenAttempt": true], ["fundsSettlementVerified": true],
            ["authority": "Dispatcher"], ["currency": "EUR"], ["invoiceDate": "2026-02-31"],
            ["invoiceNumber": "bad\nnumber"], ["invoiceNumber": " "], ["invoiceNumber": String(repeating: "1", count: 22)]] {
            #expect(throws: FieldPaymentReviewError.invalid) { try snapshot(change).validate(scope(), now: now) }
        }
    }

    @Test func rejectsStaleFutureAndMalformedObservations() throws {
        for date in [now.addingTimeInterval(-121), now.addingTimeInterval(31)] {
            #expect(throws: FieldPaymentReviewError.invalid) {
                try snapshot(["observedAt": ISO8601DateFormatter().string(from: date)]).validate(scope(), now: now)
            }
        }
        #expect(throws: FieldPaymentReviewError.invalid) { try snapshot(["observedAt": "yesterday"]).validate(scope(), now: now) }
    }

    @Test func duplicateOverallocatedAndMalformedPaymentsAreRejected() throws {
        for records in [[allocation(), allocation()], [allocation(["appliedCents": 4001])],
            [allocation(["appliedCents": -1])], [allocation(["paymentQuickBooksID": "../private"])],
            [allocation(["postingDate": "2026-02-30"])], Array(repeating: allocation(), count: 33)] {
            #expect(throws: FieldPaymentReviewError.invalid) { try snapshot(["payments": records]).validate(scope(), now: now) }
        }
    }

    @Test func creditAndOpenAttemptStayReadOnlyWithoutNewCollectionAllowance() throws {
        let result = try snapshot(["hasOpenAttempt": true, "collectionLimitCents": 0,
                                   "payments": [allocation(["includesCreditOrAdjustment": true])]])
        try result.validate(scope(), now: now)
        #expect(!result.fundsSettlementVerified)
        #expect(result.payments.first?.includesCreditOrAdjustment == true)
        #expect(result.collectionLimitCents == 0)
    }

    @Test func clientReadsOnlyScopedContextAndReviewAndPinsConnection() async throws {
        var paths: [String] = []
        let client = try FieldPaymentReviewClient(identity: identity, check: {}, request: { path in
            paths.append(path)
            let components = try #require(URLComponents(string: path))
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(query["invoiceQuickBooksID"] == "130")
            #expect(query["localCustomerID"] == identity.localCustomerID.uuidString.lowercased())
            if paths.count == 1 {
                #expect(components.path == "/api/field-payment-review/context")
                #expect(query["connectionRevision"] == nil)
                return try data(scopePayload())
            }
            #expect(components.path == "/api/field-payment-review")
            #expect(query["connectionRevision"] == String(repeating: "a", count: 64))
            return try data(payload())
        }, now: { now })
        #expect(try await client.review().invoiceNumber == "1037")
        #expect(paths.count == 2)
    }

    @Test func changedAccessAfterEitherAwaitDiscardsReply() async throws {
        for at in [1, 2] {
            var valid = true, count = 0
            let client = try FieldPaymentReviewClient(identity: identity, check: {
                if !valid { throw FieldPaymentReviewError.access }
            }, request: { _ in
                count += 1
                if count == at { valid = false }
                return try data(count == 1 ? scopePayload() : payload())
            }, now: { now })
            await #expect(throws: FieldPaymentReviewError.access) { try await client.review() }
            #expect(count == at)
        }
    }

    @Test func invalidContextNeverStartsInvoiceRead() async throws {
        var count = 0
        let client = try FieldPaymentReviewClient(identity: identity, check: {}, request: { _ in
            count += 1
            return try data(scopePayload().merging(["invoiceID": UUID().uuidString]) { _, new in new })
        })
        await #expect(throws: FieldPaymentReviewError.invalid) { try await client.review() }
        #expect(count == 1)
    }

    @Test func oversizedOrRawErrorBodyNeverBecomesUserMessage() async throws {
        let client = try FieldPaymentReviewClient(identity: identity, check: {}, request: { _ in
            Data(repeating: 65, count: FieldPaymentReviewClient.maximumBytes + 1)
        })
        await #expect(throws: FieldPaymentReviewError.invalid) { try await client.review() }
        #expect(FieldPaymentReviewError.safe(GunnAireBackendError.server(statusCode: 500, message: "PRIVATE_RAW_JSON")).localizedDescription.contains("PRIVATE") == false)
        #expect(FieldPaymentReviewError.safe(GunnAireBackendError.server(statusCode: 404, message: "PRIVATE_RAW_JSON")) == .serviceUpdate)
    }
}
