import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor struct QuickBooksLinkReviewTests {
    @MainActor final class Fixture {
        let company = UUID(), operation = UUID()
        let context: ModelContext
        let api: QuickBooksDataAPI
        let customer = Customer(name: "Original customer")
        let item = Item(name: "Sold labor", unitPrice: 189)
        let invoice: Invoice
        var saved: QuickBooksLinkReviewRequest?
        var remote: QuickBooksLinkReviewRecord?
        var calls: [(String, String)] = []
        var writes = 0
        var failSave = false
        var loseDecision = false
        var failPreview = false
        var granted = true
        var connectionRevision = String(repeating: "a", count: 64)
        var beforeReply: (() -> Void)?

        init() throws {
            let schema = GunnAireModelSchema.schema
            context = ModelContext(try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]))
            invoice = Invoice(customer: customer, amount: 189)
            customer.quickBooksID = "C1"; item.quickBooksID = "I1"; invoice.quickBooksID = "D1"
            context.insert(customer); context.insert(item); context.insert(invoice); try context.save()
            api = .init(testTokens: .init(accessToken: "fixture", expiration: .distantFuture), realmID: "realm", environment: Config.QuickBooks.environment,
                catalogCompanyID: company, transport: { _ in Issue.record("Link review called direct QBO transport"); throw QuickBooksLinkReviewError.unavailable })
        }
        var store: QuickBooksLinkReviewStore { .init(read: { _ in self.saved }, write: { _, value in
            if self.failSave { throw QuickBooksLinkReviewError.storage }
            self.saved = value; self.writes += 1
        }) }
        func record(_ request: QuickBooksLinkReviewRequest, state: QuickBooksLinkReviewRecord.State = .review,
                    id: UUID? = nil, providerID: String? = nil) -> QuickBooksLinkReviewRecord {
            .init(id: id ?? operation, companyID: request.companyID, realmID: request.realmID, environment: request.environment,
                operationID: request.operationID, revision: String(repeating: "b", count: 64), state: state,
                expiresAt: "2026-12-31T00:00:00.123456+00:00", links: request.links.map { entry in
                    .init(kind: entry.kind, localID: entry.localID, providerID: entry.providerID, localName: entry.localName,
                        localCustomerID: entry.localCustomerID, serviceCallID: entry.serviceCallID,
                        quickBooks: .init(Id: providerID ?? entry.providerID, SyncToken: "0", DisplayName: entry.localName,
                            Active: true, UnitPrice: entry.kind == .item ? 189 : nil,
                            TotalAmt: entry.kind.document ? 189 : nil, Balance: entry.kind == .invoice ? 189 : nil,
                            CustomerRef: entry.kind.document ? .init(value: "C1", name: nil) : nil))
                })
        }
        var client: QuickBooksLinkReviewClient { .init { path, method, body in
            self.calls.append((path, method))
            defer { self.beforeReply?() }
            if method == "GET" {
                let operation = URLComponents(string: path)?.queryItems?.first(where: { $0.name == "operationID" })?.value
                let review = operation.flatMap(UUID.init(uuidString:)) == self.remote?.operationID ? self.remote : nil
                return try JSONSerialization.data(withJSONObject: ["connectionRevision": self.connectionRevision,
                    "review": try review.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } ?? NSNull()])
            }
            if path == "/api/qbo-link-reviews" {
                #expect(self.saved != nil)
                let request = try JSONDecoder().decode(QuickBooksLinkReviewRequest.self, from: #require(body))
                if self.failPreview { throw QuickBooksLinkReviewError.unavailable }
                self.remote = self.record(request)
            } else {
                #expect(path.hasSuffix("/confirm") || path.hasSuffix("/cancel"))
                self.remote = self.record(try #require(self.saved), state: path.hasSuffix("/confirm") ? .confirmed : .cancelled)
                if self.loseDecision { throw QuickBooksLinkReviewError.unavailable }
            }
            return try JSONEncoder().encode(#require(self.remote))
        } }
        func owner() throws -> QuickBooksLinkReviewOwner {
            try .init(context: context, api: api, client: client, store: store, actorEmail: "admin@example.invalid", validateAccess: {
                guard self.granted else { throw QuickBooksLinkReviewError.access }
            })
        }
        func selected(_ kind: QuickBooksLinkKind, owner: QuickBooksLinkReviewOwner) throws -> Set<String> {
            Set(try owner.candidates().filter { $0.kind == kind }.map(\.id))
        }
    }

    @Test func actualOwnerPreviewsAndConfirmsExistingInvoiceWithOriginalCustomerAndPrices() async throws {
        let f = try Fixture(), owner = try f.owner()
        try await owner.preview(selected: f.selected(.invoice, owner: owner))
        let request = try #require(owner.request)
        #expect(Set(request.links.map(\.kind)) == [.customer, .invoice])
        #expect(request.links.first(where: { $0.kind == .invoice })?.localCustomerID == f.customer.id)
        #expect(f.writes == 1)
        try await owner.decide(confirm: true)
        #expect(owner.record?.state == .confirmed)
        #expect(f.invoice.quickBooksID == "D1"); #expect(f.customer.quickBooksID == "C1")
        #expect(f.invoice.amount == 189); #expect(f.item.unitPrice == 189)
        #expect(f.calls.filter { $0.1 == "POST" }.count == 2)
    }

    @Test func lostDecisionMustRecoverWithGetAndNeverResubmitDecision() async throws {
        let f = try Fixture(), owner = try f.owner()
        try await owner.preview(selected: f.selected(.customer, owner: owner)); f.loseDecision = true
        await #expect(throws: QuickBooksLinkReviewError.unavailable) { try await owner.decide(confirm: true) }
        let count = f.calls.count
        await #expect(throws: QuickBooksLinkReviewError.unavailable) { try await owner.decide(confirm: true) }
        #expect(f.calls.count == count); #expect(owner.decisionNeedsRecovery)
        try await owner.recover()
        #expect(f.calls.last?.1 == "GET"); #expect(owner.record?.state == .confirmed)
        #expect(!owner.decisionNeedsRecovery)
    }

    @Test func reopeningOwnerRecoversTheOriginalOperationAfterLostPreview() async throws {
        let f = try Fixture(), owner = try f.owner()
        try await owner.preview(selected: f.selected(.customer, owner: owner))
        let id = owner.request?.operationID; owner.cancel()
        let reopened = try f.owner()
        try await reopened.recover()
        #expect(reopened.request?.operationID == id); #expect(reopened.record?.operationID == id)
        #expect(f.calls.filter { $0.1 == "POST" }.count == 1)
    }

    @Test func failedLocalRetentionPreventsPreviewPost() async throws {
        let f = try Fixture(), owner = try f.owner(); f.failSave = true
        await #expect(throws: QuickBooksLinkReviewError.storage) { try await owner.preview(selected: f.selected(.customer, owner: owner)) }
        #expect(f.calls.allSatisfy { $0.1 == "GET" }); #expect(owner.request == nil)
    }

    @Test func requestRemainsRecoverableAfterUnavailablePreview() async throws {
        let f = try Fixture(), owner = try f.owner(); f.failPreview = true
        await #expect(throws: QuickBooksLinkReviewError.unavailable) { try await owner.preview(selected: f.selected(.customer, owner: owner)) }
        #expect(owner.request != nil); #expect(f.saved == owner.request)
        let operation = owner.request?.operationID; f.failPreview = false
        try await owner.preview(selected: [])
        #expect(owner.request?.operationID == operation)
    }

    @Test func changedLocalLinkPreventsConfirmButKeepsCancellationAndRecovery() async throws {
        let f = try Fixture(), owner = try f.owner()
        try await owner.preview(selected: f.selected(.customer, owner: owner)); f.customer.quickBooksID = "OTHER"
        let count = f.calls.count
        await #expect(throws: QuickBooksLinkReviewError.changed) { try await owner.decide(confirm: true) }
        #expect(f.calls.count == count)
        try await owner.decide(confirm: false)
        #expect(owner.record?.state == .cancelled); #expect(f.customer.quickBooksID == "OTHER")
    }

    @Test func duplicateLocalOrProviderIdentitiesBlockBatchBeforeTransport() throws {
        let f = try Fixture(), owner = try f.owner()
        let duplicate = Customer(name: "Duplicate"); duplicate.quickBooksID = "C1"; f.context.insert(duplicate)
        #expect(throws: QuickBooksLinkReviewError.changed) { _ = try owner.candidates() }
        #expect(f.calls.isEmpty)
    }

    @Test func missingCustomerLinkStopsDocumentMigrationWithoutReplacementCustomer() throws {
        let f = try Fixture(), owner = try f.owner(); f.customer.quickBooksID = nil
        let selected = try f.selected(.invoice, owner: owner)
        #expect(throws: QuickBooksLinkReviewError.changed) { _ = try owner.batch(selected) }
        #expect(f.calls.isEmpty)
    }

    @Test func revokedAccessOrClosedWorkspaceCannotAcceptLatePreview() async throws {
        let f = try Fixture(), owner = try f.owner()
        f.beforeReply = { f.granted = false }
        await #expect(throws: (any Error).self) { try await owner.preview(selected: f.selected(.customer, owner: owner)) }
        #expect(owner.record == nil); #expect(f.calls.count == 1)
        f.granted = true; f.beforeReply = nil
        let next = try f.owner(); next.cancel()
        await #expect(throws: (any Error).self) { try await next.recover() }
    }

    @Test func responseMustMatchExactOperationLocalProviderAndJobIdentities() async throws {
        let f = try Fixture(), owner = try f.owner()
        try await owner.preview(selected: f.selected(.invoice, owner: owner))
        let request = try #require(owner.request)
        #expect(throws: QuickBooksLinkReviewError.invalid) { try f.record(request, providerID: "WRONG").validate(request) }
        var modified = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.record(request))) as! [String: Any]
        for key in ["companyID", "operationID"] {
            modified[key] = UUID().uuidString
            let invalid = try JSONDecoder().decode(QuickBooksLinkReviewRecord.self, from: JSONSerialization.data(withJSONObject: modified))
            #expect(throws: QuickBooksLinkReviewError.invalid) { try invalid.validate(request) }
        }
    }

    @Test func journalRoundTripPreservesOriginalBatchAndCannotAdoptAnotherScope() throws {
        let f = try Fixture(), owner = try f.owner()
        let value = QuickBooksLinkReviewRequest(companyID: UUID(), realmID: "realm", environment: Config.QuickBooks.environment,
            operationID: UUID(), connectionRevision: String(repeating: "a", count: 64), links: try owner.batch(f.selected(.customer, owner: owner)))
        f.saved = try JSONDecoder().decode(QuickBooksLinkReviewRequest.self, from: JSONEncoder().encode(value))
        #expect(f.saved == value)
        #expect(throws: QuickBooksLinkReviewError.storage) { _ = try f.owner() }
    }

    @Test func newBatchCannotDiscardUnconfirmedReview() async throws {
        let f = try Fixture(), owner = try f.owner()
        try await owner.preview(selected: f.selected(.customer, owner: owner))
        #expect(throws: QuickBooksLinkReviewError.changed) { try owner.nextBatch() }
        try await owner.decide(confirm: false); try owner.nextBatch()
        #expect(f.saved == nil); #expect(owner.record == nil); #expect(owner.request == nil)
    }

    @Test func reconnectedReviewRecoversForCancellationButCannotBeConfirmed() async throws {
        let f = try Fixture(), owner = try f.owner()
        try await owner.preview(selected: f.selected(.customer, owner: owner))
        f.connectionRevision = String(repeating: "c", count: 64)
        try await owner.recover()
        #expect(owner.connectionChanged); #expect(owner.record?.state == .review)
        let calls = f.calls.count
        await #expect(throws: QuickBooksLinkReviewError.changed) { try await owner.decide(confirm: true) }
        #expect(f.calls.count == calls)
        try await owner.decide(confirm: false); try owner.nextBatch()
        #expect(!owner.connectionChanged); #expect(owner.request == nil)
        try await owner.preview(selected: f.selected(.customer, owner: owner))
        #expect(owner.request?.connectionRevision == f.connectionRevision)
    }

    @Test func retiringUnsubmittedRequestRequiresVerifiedConnectionChangeAndNoServerReview() async throws {
        let f = try Fixture(), owner = try f.owner(); f.failPreview = true
        await #expect(throws: QuickBooksLinkReviewError.unavailable) { try await owner.preview(selected: f.selected(.customer, owner: owner)) }
        #expect(throws: QuickBooksLinkReviewError.changed) { try owner.retireUnsubmittedRequest() }
        try await owner.recover()
        #expect(throws: QuickBooksLinkReviewError.changed) { try owner.retireUnsubmittedRequest() }
        f.connectionRevision = String(repeating: "c", count: 64)
        try await owner.recover()
        #expect(owner.connectionChanged); #expect(owner.record == nil)
        await #expect(throws: QuickBooksLinkReviewError.changed) { try await owner.preview(selected: []) }
        f.failSave = true
        #expect(throws: QuickBooksLinkReviewError.storage) { try owner.retireUnsubmittedRequest() }
        #expect(owner.request != nil)
        f.failSave = false; try owner.retireUnsubmittedRequest()
        #expect(f.saved == nil); #expect(!owner.connectionChanged)
    }

    @Test func reconnectionNeverDiscardsAReviewWithAPossibleAcceptedDecision() async throws {
        let f = try Fixture(), owner = try f.owner()
        try await owner.preview(selected: f.selected(.customer, owner: owner)); f.loseDecision = true
        await #expect(throws: QuickBooksLinkReviewError.unavailable) { try await owner.decide(confirm: true) }
        f.connectionRevision = String(repeating: "c", count: 64)
        #expect(throws: QuickBooksLinkReviewError.changed) { try owner.retireUnsubmittedRequest() }
        try await owner.recover()
        #expect(owner.record?.state == .confirmed)
        #expect(throws: QuickBooksLinkReviewError.changed) { try owner.retireUnsubmittedRequest() }
        try owner.nextBatch()
        #expect(owner.request == nil)
        #expect(f.calls.filter { $0.0.hasSuffix("/confirm") }.count == 1)
    }
}
