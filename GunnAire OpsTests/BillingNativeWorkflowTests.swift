import Foundation
import CryptoKit
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor struct BillingNativeWorkflowTests {
    @MainActor final class Fixture {
        let app: QuickBooksBillingWorkflowTests.Fixture
        var journals: [String: BillingNativeJournal] = [:]
        var calls: [(String, String)] = []
        var request: BillingPublicationRequest?
        var record: [String: Any]?
        var remote: [String: Any]?
        var writes = 0
        var failReply = false
        var reserveOnly = false
        var failJournal = false
        var beforeReply: (() -> Void)?
        let attempt = UUID()
        let company = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        var epoch = String(repeating: "a", count: 64)
        var milestoneOriginal: [String: Any]?
        var milestoneVersion: Int? = 1

        init(linked: Bool = false) throws {
            app = try .init(linkedInvoice: linked)
            app.billingJournal = .init(read: { [unowned self] scope in self.journals[scope.key] ?? .init(scope: scope) },
                write: { [unowned self] journal in
                    if self.failJournal { throw BillingNativeError.storage }
                    self.journals[journal.scope.key] = journal
                })
            app.billingPublisher = .init { [unowned self] path, method, body in try self.reply(path, method, body) }
        }

        func encoded(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
        func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
        func response() throws -> Data { try encoded(["publication": record!, "document": remote!]) }

        func reply(_ path: String, _ method: String, _ body: Data?) throws -> Data {
            calls.append((path, method)); beforeReply?()
            let url = URLComponents(string: path)!
            let query = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            if method == "GET", url.path == "/api/billing-publications/context" {
                return try encoded(["companyID": company.uuidString, "realmID": "billing-realm", "environment": Config.QuickBooks.environment,
                    "documentType": query["documentType"]!, "localDocumentID": query["localDocumentID"]!,
                    "localCustomerID": app.customer.id.uuidString, "serviceCallID": query["serviceCallID"] as Any? ?? NSNull(),
                    "connectionRevision": epoch, "customerProviderID": "C1", "providerID": remote?["Id"] as Any? ?? NSNull(),
                    "authority": "office", "assignment": NSNull(), "document": remote as Any? ?? NSNull(),
                    "milestoneIdentityVersion": milestoneVersion as Any? ?? NSNull(),
                    "milestone": milestoneOriginal as Any? ?? NSNull()])
            }
            if method == "GET", url.path == "/api/billing-publications" {
                return try encoded(["publications": record.map { [$0] } ?? [], "nextCursor": NSNull()])
            }
            if method == "GET", let request {
                return try encoded(["publication": record!, "proposal": object(request), "reviewableByOffice": reserveOnly])
            }
            if path.hasSuffix("/recover") { return try response() }
            if path.hasSuffix("/cancel") {
                record?["state"] = "cancelled"
                return try encoded(["publication": record!])
            }
            if path.hasSuffix("/approve") { return try encoded(["id": UUID().uuidString]) }
            #expect(path == "/api/billing-publications" && method == "POST")
            let request = try JSONDecoder().decode(BillingPublicationRequest.self, from: body!)
            // The exact proposal must already be durable before the POST.
            #expect(try journals.values.contains { try $0.pending?.request.matches(request) == true && $0.pending?.submitted == true })
            self.request = request
            record = ["id": attempt.uuidString, "companyID": request.companyID.uuidString, "realmID": request.realmID,
                "environment": request.environment, "documentType": request.documentType.rawValue,
                "localDocumentID": request.localDocumentID.uuidString, "localCustomerID": request.localCustomerID.uuidString,
                "operation": request.operation.rawValue, "state": reserveOnly ? "reserved" : "confirmed",
                "providerID": reserveOnly ? NSNull() : "D1", "updatedAt": "2026-09-07T12:00:00Z"]
            if reserveOnly { throw GunnAireBackendError.server(statusCode: 409, message: "fixture field price review") }
            writes += 1
            remote = try object(request.document) as? [String: Any]
            let total = QuickBooksSalesLineContract.double(try QuickBooksSalesLineContract.totals(request.document.Line).net)
            remote?.merge(["Id": "D1", "SyncToken": "8", "TotalAmt": total, "Balance": total, "TxnTaxDetail": ["TotalTax": 0],
                "PrivateNote": [request.document.PrivateNote, "GunnAire \(request.documentType.rawValue) ID: \(request.localDocumentID.uuidString.uppercased())\nGunnAire Publication: \(attempt.uuidString.lowercased())"].compactMap { $0 }.joined(separator: "\n")]) { _, new in new }
            if failReply { throw URLError(.timedOut) }
            return try response()
        }
        func flow(estimate: Bool = false, save: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws -> QuickBooksBillingWorkflow {
            try app.flow(estimate: estimate, save: save)
        }
        func finish(_ flow: QuickBooksBillingWorkflow) { app.owner.finish(flow.run) }
    }

    @Test func nativeInvoiceAndEstimateUseOnlySharedPublisherAndPersistOriginalFirst() async throws {
        for estimate in [false, true] {
            let f = try Fixture(), flow = try f.flow(estimate: estimate)
            let outcome = try await flow.execute()
            #expect(f.writes == 1); #expect(f.app.requests.isEmpty)
            #expect(outcome.invoice?.Id == "D1" || outcome.estimate?.Id == "D1")
            #expect(f.request?.document.Line.first?.SalesItemLineDetail.UnitPrice == 190)
            #expect(f.request?.connectionRevision == f.epoch)
            #expect(f.journals.values.first?.pending?.settled == true)
            f.finish(flow)
        }
    }

    @Test func lostReplyAfterAcceptanceRecoversAcrossOwnerRestartWithoutAnotherPublish() async throws {
        let f = try Fixture(); f.failReply = true
        let first = try f.flow()
        await #expect(throws: (any Error).self) { try await first.execute() }
        #expect(f.app.invoice.quickBooksID == nil); #expect(f.writes == 1)
        f.finish(first); f.failReply = false
        let second = try f.flow()
        let outcome = try await second.execute()
        #expect(outcome.recovered); #expect(f.app.invoice.quickBooksID == "D1"); #expect(f.writes == 1)
        #expect(f.calls.filter { $0.0 == "/api/billing-publications" && $0.1 == "POST" }.count == 1)
        #expect(f.app.requests.isEmpty)
        f.finish(second)
    }

    @Test func changedDraftAfterTimeoutRetainsOriginalAndSendsNothingElse() async throws {
        let f = try Fixture(); f.failReply = true
        let first = try f.flow()
        await #expect(throws: (any Error).self) { try await first.execute() }
        f.finish(first)
        f.app.invoice.notes = "Revised after lost reply"
        let count = f.calls.count, second = try f.flow()
        await #expect(throws: BillingNativeError.originalDraft) { try await second.execute() }
        #expect(f.calls.count == count); #expect(f.writes == 1)
        #expect(f.journals.values.first?.pending?.request.document.PrivateNote != f.app.invoice.notes)
        f.finish(second)
    }

    @Test func anotherDeviceWithSameCloudKitDraftRecoversTheSharedOriginalWithoutCreating() async throws {
        let f = try Fixture(); f.failReply = true
        let first = try f.flow()
        await #expect(throws: (any Error).self) { try await first.execute() }
        f.finish(first)
        f.journals.removeAll() // A different device has the saved model, not this device-only key.
        f.failReply = false
        let second = try f.flow()
        let outcome = try await second.execute()
        #expect(outcome.recovered); #expect(f.writes == 1)
        #expect(f.app.invoice.quickBooksID == "D1")
        #expect(f.journals.values.first?.pending?.settled == true)
        f.finish(second)
    }

    @Test func anotherDeviceCannotMarkAChangedUnlinkedDraftSyncedFromOldConfirmation() async throws {
        let f = try Fixture(); f.failReply = true
        let first = try f.flow()
        await #expect(throws: (any Error).self) { try await first.execute() }
        f.finish(first); f.journals.removeAll()
        f.app.invoice.notes = "Changed on the other device"
        let second = try f.flow()
        await #expect(throws: BillingNativeError.originalDraft) { try await second.execute() }
        #expect(f.app.invoice.quickBooksID == nil); #expect(f.writes == 1)
        f.finish(second)
    }

    @Test func changedRoleDuringContextReadStopsBeforePreparingOrPublishing() async throws {
        let f = try Fixture(), flow = try f.flow()
        f.beforeReply = { f.app.authorized = false }
        await #expect(throws: (any Error).self) { try await flow.execute() }
        #expect(f.writes == 0); #expect(f.journals.isEmpty); #expect(f.app.requests.isEmpty)
        f.finish(flow)
    }

    @Test func journalWriteFailurePreventsAccountingPost() async throws {
        let f = try Fixture(); f.failJournal = true
        let flow = try f.flow()
        await #expect(throws: BillingNativeError.storage) { try await flow.execute() }
        #expect(f.writes == 0)
        #expect(!f.calls.contains { $0.1 == "POST" })
        #expect(f.app.invoice.quickBooksID == nil)
        f.finish(flow)
    }

    @Test func localSaveFailureRetainsServerConfirmationForReadOnlyRecovery() async throws {
        let f = try Fixture(), flow = try f.flow(save: { _ in throw QuickBooksBillingWorkflowError.saveFailed })
        await #expect(throws: QuickBooksBillingWorkflowError.saveFailed) { try await flow.execute() }
        #expect(f.app.invoice.quickBooksID == nil); #expect(f.writes == 1)
        #expect(f.journals.values.first?.pending?.publicationID == f.attempt)
        f.finish(flow)
        let recovery = try f.flow()
        #expect(try await recovery.execute().recovered)
        #expect(f.writes == 1); #expect(f.app.invoice.quickBooksID == "D1")
        f.finish(recovery)
    }

    @Test func reservedPriceReviewDoesNotAutomaticallyRepublishAndExplicitResumeKeepsPrices() async throws {
        let f = try Fixture(); f.reserveOnly = true
        let first = try f.flow()
        await #expect(throws: (any Error).self) { try await first.execute() }
        f.finish(first)
        let second = try f.flow()
        await #expect(throws: BillingNativeError.pending) { try await second.execute() }
        #expect(f.calls.filter { $0.1 == "POST" && $0.0 == "/api/billing-publications" }.count == 1)
        f.reserveOnly = false
        let outcome = try await second.resumeOriginalFromReview()
        #expect(outcome.invoice?.TotalAmt == 190); #expect(f.writes == 1)
        #expect(f.request?.document.Line.first?.SalesItemLineDetail.UnitPrice == 190)
        f.finish(second)
    }

    @Test func cancelOnlyUnsentReservationKeepsSavedDocumentAndNeverDeletesAccounting() async throws {
        let f = try Fixture(); f.reserveOnly = true
        let flow = try f.flow()
        await #expect(throws: (any Error).self) { try await flow.execute() }
        let shared = try #require(flow.sharedPublication)
        try await shared.cancelUnsent()
        #expect(f.journals.values.first?.pending == nil)
        #expect(f.app.invoice.amount == 190); #expect(f.app.invoice.quickBooksID == nil); #expect(f.writes == 0)
        #expect(!f.calls.contains { $0.0.contains("delete") })
        f.finish(flow)
    }

    @Test func acceptedUnknownRequestCannotBeCancelledOrExplicitlyResent() async throws {
        let f = try Fixture(); f.failReply = true
        let flow = try f.flow()
        await #expect(throws: (any Error).self) { try await flow.execute() }
        f.record?["state"] = "unknown"; f.record?["providerID"] = NSNull()
        let shared = try #require(flow.sharedPublication)
        await #expect(throws: BillingNativeError.pending) { try await shared.cancelUnsent() }
        await #expect(throws: BillingNativeError.pending) { try await shared.submitOriginal() }
        #expect(f.writes == 1); #expect(shared.journal.pending != nil)
        f.finish(flow)
    }

    @Test func importedMappedEstimateRecoversWithoutRequiringForgedLineageOrWriting() async throws {
        let f = try Fixture()
        f.app.estimate.quickBooksID = "D1"
        var remote = try f.app.documentResponse(estimate: true)
        remote["TxnDate"] = "2026-07-02"; remote["PrivateNote"] = "Imported estimate"
        f.remote = remote
        let flow = try f.flow(estimate: true)
        #expect(try await flow.execute().recovered)
        #expect(f.writes == 0); #expect(f.app.requests.isEmpty)
        f.finish(flow)
    }

    @Test func mappedInvoiceUpdateRetainsAccountingPostingDateAndSyncToken() async throws {
        let f = try Fixture(linked: true)
        var remote = try f.app.documentResponse()
        remote["TxnDate"] = "2026-07-02"; f.remote = remote
        let flow = try f.flow()
        _ = try await flow.execute()
        #expect(f.request?.operation == .update)
        #expect(f.request?.document.TxnDate == "2026-07-02")
        #expect(f.request?.document.SyncToken == "7")
        #expect(f.request?.document.Id == "D1")
        #expect(f.app.requests.isEmpty)
        f.finish(flow)
    }

    @Test func paidMappedInvoiceCannotRewriteLines() async throws {
        let f = try Fixture(linked: true)
        var remote = try f.app.documentResponse()
        remote["TxnDate"] = "2026-07-02"; remote["Balance"] = 50; f.remote = remote
        let flow = try f.flow()
        await #expect(throws: QuickBooksBillingWorkflowError.paidRemoteInvoice) { try await flow.execute() }
        #expect(f.writes == 0); #expect(f.app.requests.isEmpty)
        f.finish(flow)
    }

    @Test func localOnlyMappingCannotSilentlyCreateASecondInvoice() async throws {
        let f = try Fixture(linked: true), flow = try f.flow()
        await #expect(throws: BillingNativeError.mapping) { try await flow.execute() }
        #expect(f.writes == 0); #expect(f.app.invoice.quickBooksID == "D1")
        f.finish(flow)
    }

    @Test func originalCanonicalComparisonIgnoresOnlyReferenceLabelsAndUUIDCasing() async throws {
        let f = try Fixture(), flow = try f.flow()
        _ = try await flow.execute()
        let request = try #require(f.request)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        json["localDocumentID"] = request.localDocumentID.uuidString.lowercased()
        var document = json["document"] as! [String: Any]
        document["CustomerRef"] = ["value": "C1", "name": "Cosmetic name"]
        json["document"] = document
        let renamed = try JSONDecoder().decode(BillingPublicationRequest.self, from: f.encoded(json))
        #expect(try request.matches(renamed))
        document["TxnDate"] = "2025-01-01"; json["document"] = document
        let changed = try JSONDecoder().decode(BillingPublicationRequest.self, from: f.encoded(json))
        #expect(try !request.matches(changed))
        f.finish(flow)
    }

    @Test func encryptedJournalSurvivesReloadAndRejectsWrongKeyTamperingAndOtherActor() async throws {
        let f = try Fixture(), flow = try f.flow()
        _ = try await flow.execute()
        let journal = try #require(f.journals.values.first)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("billing-journal-test-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Data(repeating: 7, count: 32)
        let store = BillingNativeJournalStore.encrypted(directory: directory, key: { _ in key })
        try store.write(journal)
        let restored = try store.read(journal.scope)
        #expect(try restored.pending?.request.matches(journal.pending!.request) == true)
        let file = directory.appendingPathComponent(journal.scope.key + ".sealed")
        let bytes = try Data(contentsOf: file)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("CustomerRef"))
        let wrong = BillingNativeJournalStore.encrypted(directory: directory, key: { _ in Data(repeating: 8, count: 32) })
        #expect(throws: BillingNativeError.storage) { try wrong.read(journal.scope) }
        let other = BillingNativeJournalScope(document: journal.scope.document, actorEmail: "different@example.invalid")
        #expect(try store.read(other).pending == nil)
        try bytes.dropLast().write(to: file)
        #expect(throws: BillingNativeError.storage) { try store.read(journal.scope) }
        f.finish(flow)
    }
}
