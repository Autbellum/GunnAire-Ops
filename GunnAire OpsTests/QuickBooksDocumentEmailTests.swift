import Foundation
import Testing
@testable import GunnAire_Ops

@MainActor
struct QuickBooksDocumentEmailTests {
    @MainActor private final class Fixture {
        let journal: QuickBooksDocumentEmailJournal
        var requests: [URLRequest] = []
        var readStatus = "NotSet"
        var readDeliveryTime: String?
        var readRecipient = "customer@example.test"
        var postStatus = 200
        var postIdentifier = "42"
        var loseResponse = false
        var beforePost: (() -> Void)?
        var beforeRead: (() async -> Void)?
        var realm = "synthetic-email-realm"
        var owner: QuickBooksCredentialOwner?
        var publisher: BillingPublicationClient?
        lazy var api = makeAPI()

        init(journal: QuickBooksDocumentEmailJournal = .init(directory: nil, memoryOnly: true)) {
            self.journal = journal
        }

        func makeAPI() -> QuickBooksDataAPI {
            QuickBooksDataAPI(testTokens: .init(accessToken: "synthetic-email-token", expiration: .distantFuture),
                realmID: realm, environment: "sandbox", billingPublisher: publisher, emailJournal: journal, credentialOwner: owner) { [self] request in
                requests.append(request)
                let isPost = request.httpMethod == "POST"
                if !isPost { await beforeRead?() }
                if isPost {
                    beforePost?()
                    if loseResponse { throw URLError(.timedOut) }
                }
                let kind = request.url?.path.contains("/estimate/") == true ? "Estimate" : "Invoice"
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(url: url, statusCode: isPost ? postStatus : 200,
                    httpVersion: nil, headerFields: nil))
                var document: [String: Any] = ["Id": isPost ? postIdentifier : "42", "CustomerRef": ["value": "synthetic-customer"],
                    "TotalAmt": 10, "BillEmail": ["Address": isPost ? "customer@example.test" : readRecipient],
                    "EmailStatus": isPost ? "EmailSent" : readStatus]
                if let time = readDeliveryTime, !isPost {
                    document["DeliveryInfo"] = ["DeliveryType": "Email", "DeliveryTime": time]
                }
                let data = try JSONSerialization.data(withJSONObject: [kind: document])
                return (data, response)
            }
        }

        func send(invoice: Bool = false, recipient: String = "customer@example.test", using selectedAPI: QuickBooksDataAPI? = nil, expectedCustomerID: String? = nil, validateSend: @escaping () throws -> Void = {}) async -> Result<Void, Error> {
            let selectedAPI = selectedAPI ?? api
            return await withCheckedContinuation { continuation in
                if invoice {
                    selectedAPI.sendInvoice(id: "42", to: recipient, expectedCustomerID: expectedCustomerID, validateSend: validateSend) { continuation.resume(returning: $0.map { _ in () }) }
                } else {
                    selectedAPI.sendEstimate(id: "42", to: recipient, expectedCustomerID: expectedCustomerID, validateSend: validateSend) { continuation.resume(returning: $0.map { _ in () }) }
                }
            }
        }
        var postCount: Int { requests.filter { $0.httpMethod == "POST" }.count }
    }

    private func expectFailure(_ result: Result<Void, Error>, _ expected: QuickBooksDocumentEmailError) {
        if case .failure(let error) = result { #expect(error as? QuickBooksDocumentEmailError == expected) }
        else { Issue.record("Expected a retained email failure, received success") }
    }

    @Test func lostResponseRetainsAttemptForBothDocumentKindsAndRecipientChanges() async {
        for invoice in [false, true] {
            let fixture = Fixture(); fixture.loseResponse = true
            expectFailure(await fixture.send(invoice: invoice), .reviewRequired)
            expectFailure(await fixture.send(invoice: invoice), .reviewRequired)
            expectFailure(await fixture.send(invoice: invoice, recipient: "another@example.test"), .reviewRequired)
            #expect(fixture.postCount == 1)
            #expect(fixture.requests.count == 4)
        }
    }

    @Test func pendingAttemptSurvivesNewAPIAndJournalInstances() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = Fixture(journal: .init(directory: folder)); first.loseResponse = true
        expectFailure(await first.send(), .reviewRequired)
        let restarted = Fixture(journal: .init(directory: folder))
        expectFailure(await restarted.send(), .reviewRequired)
        #expect(restarted.postCount == 0)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let text = try String(contentsOf: #require(files.first), encoding: .utf8)
        #expect(!text.contains("customer@example.test"))
        #expect(!text.contains("synthetic-email-token"))
        #expect(text.contains("pending"))
    }

    @Test func historicalSentFlagDoesNotReconcileAnUnknownAttempt() async {
        let fixture = Fixture()
        fixture.readStatus = "EmailSent"
        fixture.readDeliveryTime = "2020-01-01T10:00:00Z"
        fixture.loseResponse = true
        expectFailure(await fixture.send(), .reviewRequired)
        expectFailure(await fixture.send(), .reviewRequired)
        fixture.readDeliveryTime = nil
        expectFailure(await fixture.send(), .reviewRequired)
        #expect(fixture.postCount == 1)
    }

    @Test func freshMatchingProviderReadbackReconcilesWithoutAnotherPost() async {
        let fixture = Fixture(); fixture.loseResponse = true
        expectFailure(await fixture.send(), .reviewRequired)
        fixture.readStatus = "EmailSent"
        fixture.readDeliveryTime = ISO8601DateFormatter().string(from: Date().addingTimeInterval(2))
        fixture.readRecipient = "another@example.test"
        expectFailure(await fixture.send(), .reviewRequired)
        fixture.readRecipient = "customer@example.test"
        expectFailure(await fixture.send(), .reconciled)
        #expect(fixture.postCount == 1)
    }

    @Test func equivalentHistoricalTimestampsAndSameSecondReadbacksRemainUncertain() throws {
        let start = try #require(ISO8601DateFormatter().date(from: "2026-09-23T02:00:00Z"))
        let attempt = QuickBooksDocumentEmailAttempt(key: "synthetic", requestID: UUID(),
            recipientDigest: QuickBooksDocumentEmailAttempt.digest("customer@example.test"),
            previousDeliveryTime: "2026-09-23T02:00:00Z", startedAt: start, state: .pending)
        let equivalent = QuickBooksDocumentEmailObservation(id: "42", recipient: "customer@example.test",
            emailStatus: "EmailSent", delivery: .init(DeliveryType: "Email", DeliveryTime: "2026-09-23T02:00:00+00:00"))
        #expect(!equivalent.confirms(attempt))
        let noBaseline = QuickBooksDocumentEmailAttempt(key: "synthetic", requestID: UUID(),
            recipientDigest: attempt.recipientDigest, previousDeliveryTime: nil,
            startedAt: start.addingTimeInterval(0.5), state: .pending)
        #expect(!equivalent.confirms(noBaseline))
    }

    @Test func definitiveProviderRejectionPermitsCorrectedAttemptWithNewRequestID() async throws {
        let fixture = Fixture(); fixture.postStatus = 400
        if case .success = await fixture.send() { Issue.record("Provider rejection was treated as acceptance") }
        fixture.postStatus = 200
        if case .failure(let error) = await fixture.send() { Issue.record("Corrected send rejected: \(error)") }
        let posts = fixture.requests.filter { $0.httpMethod == "POST" }
        #expect(posts.count == 2)
        let identifiers = try posts.map { request -> String in
            let url = try #require(request.url)
            let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            return try #require(query.first { $0.name == "requestid" }?.value)
        }
        #expect(Set(identifiers).count == 2)
        #expect(posts.allSatisfy { $0.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream" })
    }

    @Test func mismatchedSuccessPayloadCannotUnlockAnotherSend() async {
        let fixture = Fixture(); fixture.postIdentifier = "different-document"
        expectFailure(await fixture.send(), .reviewRequired)
        expectFailure(await fixture.send(), .reviewRequired)
        #expect(fixture.postCount == 1)
    }

    @Test func sessionReplacementAfterPostRetainsUnknownAttempt() async {
        let fixture = Fixture()
        fixture.beforePost = { fixture.api.clearTokens() }
        expectFailure(await fixture.send(), .reviewRequired)
        fixture.beforePost = nil
        let replacement = fixture.makeAPI()
        expectFailure(await fixture.send(using: replacement), .reviewRequired)
        #expect(fixture.postCount == 1)
    }

    @Test func wrongRemoteCustomerCannotReceiveLocallyConsentedDocuments() async {
        for invoice in [false, true] {
            let fixture = Fixture()
            expectFailure(await fixture.send(invoice: invoice, expectedCustomerID: "different-customer"), .invalidDocument)
            #expect(fixture.postCount == 0)
            if case .failure(let error) = await fixture.send(invoice: invoice, expectedCustomerID: "synthetic-customer") {
                Issue.record("Matching customer was blocked: \(error)")
            }
            #expect(fixture.postCount == 1)
        }
    }

    @Test func storageFailurePreventsProviderMutation() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let fixture = Fixture(journal: .init(directory: file))
        expectFailure(await fixture.send(), .storage)
        #expect(fixture.postCount == 0)
    }

    @Test func concurrentAPITapsCannotIssueParallelEmails() async throws {
        let fixture = Fixture()
        let (started, signal) = AsyncStream<Void>.makeStream()
        var release: CheckedContinuation<Void, Never>?
        fixture.beforeRead = {
            await withCheckedContinuation { continuation in
                release = continuation; signal.yield(())
            }
        }
        let first = Task { await fixture.send() }
        for await _ in started { break }
        expectFailure(await fixture.send(), .busy)
        #expect(fixture.postCount == 0)
        release?.resume(); fixture.beforeRead = nil
        if case .failure(let error) = await first.value { Issue.record("Original send failed: \(error)") }
        #expect(fixture.postCount == 1)
    }

    @Test func consentChangeDuringReadPreventsTheFirstPost() async throws {
        let fixture = Fixture()
        let (started, signal) = AsyncStream<Void>.makeStream()
        var release: CheckedContinuation<Void, Never>?
        var allowed = true
        fixture.beforeRead = {
            await withCheckedContinuation { continuation in release = continuation; signal.yield(()) }
        }
        let work = Task {
            await fixture.send(validateSend: {
                guard allowed else { throw GmailComposeError.consent }
            })
        }
        for await _ in started { break }
        allowed = false
        release?.resume()
        if case .failure(let error) = await work.value {
            #expect(error as? WorkspaceProviderAccessError == .changed(mayHaveReachedProvider: false))
        } else { Issue.record("Revoked customer consent was ignored") }
        #expect(fixture.postCount == 0)
    }

    @Test func billingPublisherDoesNotBlockOwnerOAuthButSharedBillingCannotSendDirectly() async {
        let publisher = BillingPublicationClient { _, _, _ in throw BillingPublicationError.unavailable }
        let owner = Fixture(); owner.publisher = publisher
        if case .failure(let error) = await owner.send() { Issue.record("Owner OAuth send blocked: \(error)") }
        #expect(owner.postCount == 1)
        let shared = QuickBooksDataAPI(sharedCompanyID: UUID(), realmID: "shared", environment: "sandbox",
            connectionRevision: "fixture", operation: .init(isCurrent: { true }), billingPublisher: publisher)
        let result = await owner.send(using: shared)
        if case .success = result { Issue.record("Business-only connection performed a direct email send") }
        #expect(owner.postCount == 1)
    }

    @Test func companyBackendAndRealmChangesNeverAdoptAnotherPendingAttempt() async {
        let journal = QuickBooksDocumentEmailJournal(directory: nil, memoryOnly: true)
        let original = Fixture(journal: journal)
        let company = UUID()
        original.owner = .init(companyID: company, backendOrigin: "https://one.invalid")
        original.loseResponse = true
        expectFailure(await original.send(), .reviewRequired)
        for variant in 0..<3 {
            let next = Fixture(journal: journal)
            next.owner = .init(companyID: variant == 0 ? UUID() : company,
                backendOrigin: variant == 1 ? "https://two.invalid" : "https://one.invalid")
            next.realm = variant == 2 ? "different-realm" : original.realm
            if case .failure(let error) = await next.send() { Issue.record("Separate scope blocked: \(error)") }
            #expect(next.postCount == 1)
        }
        expectFailure(await original.send(), .reviewRequired)
        #expect(original.postCount == 1)
    }

    @Test func acceptancePersistenceFailureKeepsOriginalPendingRecord() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let retained = folder.appendingPathExtension("retained")
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: retained)
        }
        let fixture = Fixture(journal: .init(directory: folder))
        var disruption: Error?
        fixture.beforePost = {
            do {
                try FileManager.default.moveItem(at: folder, to: retained)
                try Data("blocked journal directory".utf8).write(to: folder)
            } catch { disruption = error }
        }
        expectFailure(await fixture.send(), .reviewRequired)
        #expect(disruption == nil)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: retained, to: folder)
        let restarted = Fixture(journal: .init(directory: folder))
        expectFailure(await restarted.send(), .reviewRequired)
        #expect(restarted.postCount == 0)
    }

    @Test func journalSerializesConcurrentSendsAndScopesDocumentsIndependently() async throws {
        let journal = QuickBooksDocumentEmailJournal(directory: nil, memoryOnly: true)
        let first = QuickBooksDocumentEmailAttempt.digest("company/realm/invoice/1")
        let second = QuickBooksDocumentEmailAttempt.digest("company/realm/invoice/2")
        _ = try await journal.acquire(first)
        do { _ = try await journal.acquire(first); Issue.record("Duplicate journal lease admitted") }
        catch { #expect(error as? QuickBooksDocumentEmailError == .busy) }
        _ = try await journal.acquire(second)
        let attempt = try await journal.begin(key: first, recipient: "customer@example.test", previousDeliveryTime: nil)
        await journal.release(first)
        #expect(try await journal.acquire(first) == attempt)
        do { _ = try await journal.begin(key: first, recipient: "new@example.test", previousDeliveryTime: nil); Issue.record("Pending attempt replaced") }
        catch { #expect(error as? QuickBooksDocumentEmailError == .reviewRequired) }
        await journal.release(first); await journal.release(second)
    }
}
