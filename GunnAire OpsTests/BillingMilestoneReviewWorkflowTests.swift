import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor struct BillingMilestoneReviewWorkflowTests {
    @MainActor final class Fixture {
        let local: BillingMilestoneReconciliationTests.Fixture
        var calls: [(String, String)] = []
        var beforeReply: ((Int) -> Void)?
        var authority = "office"
        var companyOverride: UUID?
        var hasAliasPublication = false
        var journalWrites = 0
        let aliasAttempt = UUID()
        lazy var client = BillingPublicationClient { [unowned self] path, method, _ in
            calls.append((path, method)); beforeReply?(calls.count)
            guard method == "GET" else { throw BillingPublicationError.unavailable }
            return try reply(path)
        }
        lazy var api = QuickBooksDataAPI(testTokens: .init(accessToken: "isolated-review-fixture", expiration: .distantFuture),
            realmID: local.scope.realmID, environment: local.scope.environment, catalogCompanyID: local.company,
            billingPublisher: client, transport: { _ in throw BillingPublicationError.unavailable })
        init() throws { local = try .init() }

        func object<T: Encodable>(_ value: T) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        }
        func reply(_ path: String) throws -> Data {
            let url = try #require(URLComponents(string: path))
            var result: [String: Any]
            if url.path == "/api/billing-publications/context" {
                result = ["companyID": (companyOverride ?? local.company).uuidString,
                    "realmID": local.scope.realmID, "environment": local.scope.environment,
                    "documentType": "Invoice", "localDocumentID": local.draft.id.uuidString,
                    "localCustomerID": local.app.customer.id.uuidString, "serviceCallID": local.job.uuidString,
                    "connectionRevision": String(repeating: "a", count: 64), "customerProviderID": "C1",
                    "providerID": NSNull(), "document": NSNull(), "authority": authority,
                    "assignment": NSNull(), "milestoneIdentityVersion": 1,
                    "milestone": ["projectMilestoneID": local.stage.uuidString,
                        "localDocumentID": local.original.id.uuidString,
                        "localCustomerID": local.app.customer.id.uuidString,
                        "publicationID": local.attempt.uuidString, "state": "confirmed"]]
            } else if url.path == "/api/billing-publications" {
                result = ["publications": hasAliasPublication ? [try aliasRecord()] : [], "nextCursor": NSNull()]
            } else if url.path.hasSuffix(aliasAttempt.uuidString.lowercased()) {
                var proposal = try object(local.proposal.proposal)
                proposal["localDocumentID"] = local.draft.id.uuidString
                result = ["publication": try aliasRecord(), "proposal": proposal, "reviewableByOffice": false]
            } else if url.path.hasSuffix(local.attempt.uuidString.lowercased()) {
                result = ["publication": try object(local.proposal.publication),
                    "proposal": try object(local.proposal.proposal), "reviewableByOffice": false]
            } else { throw BillingPublicationError.unavailable }
            return try JSONSerialization.data(withJSONObject: result)
        }
        func aliasRecord() throws -> [String: Any] {
            var record = try object(local.proposal.publication)
            record["id"] = aliasAttempt.uuidString
            record["localDocumentID"] = local.draft.id.uuidString
            return record
        }
        func flow(save: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws -> QuickBooksBillingWorkflow {
            let store = BillingNativeJournalStore(read: { .init(scope: $0) }, write: { [unowned self] _ in journalWrites += 1 })
            return try QuickBooksBillingWorkflow(document: .invoice(local.draft), context: local.context,
                api: api, lifecycle: local.app.owner,
                validateAccess: { [unowned self] in
                    if !local.app.authorized { throw QuickBooksBillingWorkflowError.accessDenied }
                }, validateCatalogAccess: {}, billingJournal: store, save: save, actorEmail: local.reviewer.email)
        }
    }

    @Test func officeRetentionUsesFourScopedReadsWithoutAnyPublicationOrJournalMutation() async throws {
        let f = try Fixture(), flow = try f.flow()
        let draftID = f.local.draft.id, notes = f.local.draft.notes
        try await flow.retainDuplicateMilestoneDraft()
        #expect(f.calls.count == 4 && f.calls.allSatisfy { $0.1 == "GET" })
        #expect(f.journalWrites == 0 && !flow.attemptedWrite)
        #expect(f.local.draft.id == draftID && f.local.draft.notes == notes)
        #expect(BillingMilestoneReconciliation.receipt(f.local.draft)?.reviewedBy == f.local.reviewer.id)
        #expect(f.local.original.quickBooksID == "D1" && f.local.original.amount == 190)
        f.local.app.owner.finish(flow.run)
    }

    @Test func revocationAtEveryAwaitedReadPreventsReceiptPersistence() async throws {
        for step in 1...4 {
            let f = try Fixture(), flow = try f.flow()
            f.beforeReply = { if $0 == step { f.local.app.authorized = false } }
            await #expect(throws: (any Error).self) { try await flow.retainDuplicateMilestoneDraft() }
            #expect(f.local.draft.milestoneDraftReceiptJSON == nil)
            #expect(f.calls.allSatisfy { $0.1 == "GET" } && f.journalWrites == 0)
            f.local.app.owner.finish(flow.run)
        }
    }

    @Test func originalDriftLatePaymentOrOfficeRoleLossCannotBeHiddenByAReceipt() async throws {
        for mode in 0..<3 {
            let f = try Fixture(), flow = try f.flow()
            f.beforeReply = { step in
                guard step == 3 else { return }
                if mode == 0 { f.local.original.notes = "Changed while reviewing" }
                if mode == 1 { f.local.context.insert(Payment(invoice: f.local.draft, amount: 1, method: "cash")) }
                if mode == 2 { f.local.reviewer.role = .fieldTechnician }
            }
            await #expect(throws: (any Error).self) { try await flow.retainDuplicateMilestoneDraft() }
            #expect(f.local.draft.milestoneDraftReceiptJSON == nil && f.journalWrites == 0)
            f.local.app.owner.finish(flow.run)
        }
    }

    @Test func foreignScopeNonOfficeAuthorityAndExistingAliasPublicationRequireReview() async throws {
        for mode in 0..<3 {
            let f = try Fixture(), flow = try f.flow()
            if mode == 0 { f.companyOverride = UUID() }
            if mode == 1 { f.authority = "assigned" }
            if mode == 2 { f.hasAliasPublication = true }
            await #expect(throws: (any Error).self) { try await flow.retainDuplicateMilestoneDraft() }
            #expect(f.local.draft.milestoneDraftReceiptJSON == nil && f.journalWrites == 0)
            #expect(f.calls.allSatisfy { $0.1 == "GET" })
            f.local.app.owner.finish(flow.run)
        }
    }

    @Test func workflowSaveFailureLeavesBothDocumentsAndUnrelatedEditsIntact() async throws {
        let f = try Fixture()
        struct SaveFailure: Error {}
        let flow = try f.flow(save: { _ in throw SaveFailure() })
        // An unrelated item is not part of either captured billing document.
        let unrelated = Item(name: "Unrelated local work", unitPrice: 5)
        f.local.context.insert(unrelated)
        await #expect(throws: SaveFailure.self) { try await flow.retainDuplicateMilestoneDraft() }
        #expect(f.local.draft.milestoneDraftReceiptJSON == nil)
        #expect(try f.local.context.fetch(FetchDescriptor<Invoice>()).count == 2)
        #expect(try f.local.context.fetch(FetchDescriptor<Item>()).contains { $0 === unrelated })
        #expect(f.journalWrites == 0 && f.calls.allSatisfy { $0.1 == "GET" })
        f.local.app.owner.finish(flow.run)
    }
}
