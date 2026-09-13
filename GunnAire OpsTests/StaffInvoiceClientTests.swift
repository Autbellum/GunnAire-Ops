import Foundation
import XCTest
@testable import GunnAire_Ops

@MainActor final class StaffInvoiceClientTests: XCTestCase {
    @MainActor final class Fixture {
        let helpers = StaffInvoiceRequestTests()
        let memory = StaffInvoiceRequestTests.Memory()
        let plan = UUID()
        var allowed = true
        var refreshing = false
        var offline = false
        var afterSend: (() async -> Void)?
        var response: ((StaffInvoiceRequest) throws -> Data)?
        var sent: [StaffInvoiceRequest] = []
        var source: StaffInvoiceSource
        var scope: CloudKitStaffSetupScope
        nonisolated deinit {}
        init() {
            source = .init(origin: helpers.origin(), catalog: [], equipment: [], editable: true)
            scope = helpers.scope()
        }
        func client() throws -> StaffInvoiceClient {
            try .init(dependencies: .init(current: { [unowned self] local in
                guard allowed else { throw StaffReplicaDeliveryError.access }
                if refreshing && !local { throw StaffReplicaDeliveryError.pending }
                return .init(scope: scope, plan: plan, source: source)
            }, store: memory.store, send: { [unowned self] path, data in
                XCTAssertTrue(StaffInvoiceHTTPPolicy.allows(path: path, method: "POST", body: data))
                let request = try StaffWorkspacePublicationContract.decode(StaffInvoiceRequest.self, from: data)
                sent.append(request); await afterSend?()
                if offline { throw StaffReplicaDeliveryError.offline }
                if let response { return try response(request) }
                return try StaffWorkspacePublicationContract.encode(helpers.receipt(request, plan: plan))
            }))
        }
        func stage(_ client: StaffInvoiceClient) throws -> StaffInvoiceJournal {
            let saved = try client.draft(helpers.draft(source.origin), expected: client.load())
            return try client.stage(expected: saved)
        }
    }

    func testRealPythonHTTPVectorsDecodeAndVerifyInSwift() throws {
        struct Vector: Codable { let request: StaffInvoiceRequest; let receipt: StaffInvoiceReceipt }
        struct File: Codable { let vectors: [Vector] }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "StaffInvoiceRequestInterop", withExtension: "json"))
        let file = try StaffWorkspacePublicationContract.decode(File.self, from: Data(contentsOf: url))
        XCTAssertEqual(file.vectors.count, 3)
        for vector in file.vectors {
            try vector.request.validate()
            try vector.receipt.validate(request: vector.request, email: "field.technician@gunnaire.com", plan: XCTUnwrap(UUID(uuidString: vector.receipt.shareID)))
        }
        XCTAssertEqual(file.vectors.last?.receipt.lineSubtotal, "0.00")
    }
    func testOfflineSubmissionRestoresSameRequestAfterClientRestart() async throws {
        let f = Fixture(), client = try f.client(), staged = try f.stage(client)
        let original = try XCTUnwrap(staged.entries.first)
        f.offline = true
        do { _ = try await client.send(id: original.id); XCTFail("Expected offline") } catch {}
        XCTAssertEqual(try client.load(), staged)
        f.offline = false
        let completed = try await f.client().send(id: original.id)
        XCTAssertEqual(completed.entries[0].request, original.request)
        XCTAssertNotNil(completed.entries[0].receipt)
        XCTAssertEqual(f.sent, [original.request, original.request])
        XCTAssertEqual(f.memory.values.count, 1)
    }
    func testLostReceiptCanRecoverAfterSourceAdvanceButNewStageCannotRebase() async throws {
        let f = Fixture(), client = try f.client(), staged = try f.stage(client)
        f.offline = true
        do { _ = try await client.send(id: staged.entries[0].id); XCTFail() } catch {}
        let oldDraft = f.helpers.draft(f.source.origin)
        f.source = .init(origin: f.helpers.origin(sequence: 2), catalog: [], equipment: [], editable: false)
        let saved = try client.draft(oldDraft, expected: client.load())
        XCTAssertThrowsError(try client.stage(expected: saved))
        f.offline = false
        let completed = try await client.send(id: staged.entries[0].id)
        XCTAssertEqual(completed.entries[0].request.origin.sourceSequence, 1)
        XCTAssertEqual(completed.draft, oldDraft)
    }
    func testRevocationDuringAwaitNeverAttachesReceiptAndKeepsQueuedWork() async throws {
        let f = Fixture(), client = try f.client(), staged = try f.stage(client)
        let bytes = f.memory.values
        f.afterSend = { f.allowed = false }
        do { _ = try await client.send(id: staged.entries[0].id); XCTFail() } catch {}
        XCTAssertEqual(f.memory.values, bytes)
        XCTAssertThrowsError(try client.load())
        f.afterSend = nil; f.allowed = true
        let recovered = try await client.send(id: staged.entries[0].id)
        XCTAssertNotNil(recovered.entries[0].receipt)
    }
    func testReceiptWriteAcknowledgmentLossDoesNotSendAgain() async throws {
        let f = Fixture(), client = try f.client(), staged = try f.stage(client)
        f.afterSend = { f.memory.loseAcknowledgment = true }
        do { _ = try await client.send(id: staged.entries[0].id); XCTFail() } catch {}
        f.memory.loseAcknowledgment = false; f.afterSend = nil
        let recovered = try await f.client().send(id: staged.entries[0].id)
        XCTAssertNotNil(recovered.entries[0].receipt); XCTAssertEqual(f.sent.count, 1)
    }
    func testReceiptAttachmentPreservesOtherWindowDraft() async throws {
        let f = Fixture(), client = try f.client(), staged = try f.stage(client)
        let otherDraft = f.helpers.draft()
        f.afterSend = { _ = try? client.draft(otherDraft, expected: client.load()) }
        let saved = try await client.send(id: staged.entries[0].id)
        XCTAssertEqual(saved.draft, otherDraft)
        XCTAssertNotNil(saved.entries[0].receipt)
    }
    func testMalformedOrForeignReceiptNeverReplacesQueuedOriginal() async throws {
        let f = Fixture(), client = try f.client(), staged = try f.stage(client)
        let bytes = f.memory.values
        for key in ["actorEmail", "qboPublished", "extra"] {
            f.response = { request in
                let data = try StaffWorkspacePublicationContract.encode(f.helpers.receipt(request, plan: f.plan))
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                object[key] = key == "actorEmail" ? "foreign@example.invalid" : true
                return try JSONSerialization.data(withJSONObject: object)
            }
            do { _ = try await client.send(id: staged.entries[0].id); XCTFail("Unverified receipt accepted") } catch {}
            XCTAssertEqual(f.memory.values, bytes)
        }
        f.response = nil
        let recovered = try await client.send(id: staged.entries[0].id)
        XCTAssertEqual(recovered.entries[0].request, staged.entries[0].request)
        XCTAssertNotNil(recovered.entries[0].receipt)
    }
    func testConcurrentRetryIsFencedAcrossClientInstances() async throws {
        let f = Fixture(), client = try f.client(), staged = try f.stage(client)
        f.afterSend = {
            do { _ = try await f.client().send(id: staged.entries[0].id); XCTFail("Concurrent send accepted") } catch {}
        }
        let saved = try await client.send(id: staged.entries[0].id)
        XCTAssertEqual(f.sent.count, 1); XCTAssertNotNil(saved.entries[0].receipt)
    }
    func testCancellationAfterResponseRetainsOriginalForRetry() async throws {
        let f = Fixture(), client = try f.client(), staged = try f.stage(client), bytes = f.memory.values
        f.afterSend = { withUnsafeCurrentTask { $0?.cancel() } }
        let cancelled = Task { try await client.send(id: staged.entries[0].id) }
        do { _ = try await cancelled.value; XCTFail("Cancelled response accepted") } catch {}
        XCTAssertEqual(f.memory.values, bytes)
        f.afterSend = nil
        let saved = try await client.send(id: staged.entries[0].id)
        XCTAssertNotNil(saved.entries[0].receipt)
        XCTAssertEqual(f.sent, [staged.entries[0].request, staged.entries[0].request])
    }
    func testRefreshAllowsKeystrokePersistenceButNotStageOrSend() async throws {
        let f = Fixture(), client = try f.client(), staged = try f.stage(client)
        f.refreshing = true
        let saved = try client.draft(f.helpers.draft(), expected: staged)
        XCTAssertNotNil(saved.draft)
        XCTAssertThrowsError(try client.stage(expected: saved))
        do { _ = try await client.send(id: staged.entries[0].id); XCTFail() } catch {}
        XCTAssertTrue(f.sent.isEmpty)
    }
    func testAnotherAccountCannotReuseJournalOrClientIdentity() throws {
        let f = Fixture(), client = try f.client(), staged = try f.stage(client)
        f.scope = .init(origin: f.scope.origin, company: f.scope.company, email: "other@example.invalid", environment: f.scope.environment, accountHash: f.scope.accountHash)
        XCTAssertThrowsError(try client.load())
        XCTAssertThrowsError(try client.draft(f.helpers.draft(), expected: staged))
        XCTAssertNil(try f.client().load())
    }
    func testControllerUsesPrimaryJournalForUnfinishedInputAndActualSubmission() async throws {
        let f = Fixture(), editor = StaffInvoiceEditorController(client: try f.client())
        editor.open()
        let command = try XCTUnwrap(editor.draft?.commandID)
        editor.change { $0.name = "Capacitor"; $0.price = "123.375"; $0.quantity = "2"; $0.reason = "Office review" }
        XCTAssertTrue(editor.canStage); XCTAssertFalse(editor.hasUnprotectedChanges)
        f.offline = true; await editor.submit()
        XCTAssertNil(editor.draft); XCTAssertEqual(editor.entries.first?.id, command)
        XCTAssertNil(editor.entries.first?.receipt)
        let reopened = StaffInvoiceEditorController(client: try f.client()); reopened.open()
        XCTAssertEqual(reopened.entries, editor.entries); XCTAssertNil(reopened.draft)
        f.offline = false; await reopened.retry(id: command)
        XCTAssertNotNil(reopened.entries.first?.receipt)
        XCTAssertTrue(reopened.message.contains("not been changed"))
    }
    func testControllerNeverSilentlyRepricesOldCatalogChoiceOnRefresh() throws {
        let f = Fixture(); var catalog = f.helpers.line(); catalog.kind = "catalog"; catalog.itemRevision = 1
        catalog.quantity = 1 // Verified source choices carry one unit, not a draft's quantity.
        f.source = .init(origin: f.source.origin, catalog: [catalog], equipment: [], editable: true)
        let editor = StaffInvoiceEditorController(client: try f.client()); editor.open()
        XCTAssertTrue(editor.selectCatalog(catalog))
        editor.change { $0.reason = "Office review" }
        let oldID = editor.draft?.commandID
        var current = catalog; current.unitPrice = 999; current.itemRevision = 2
        f.source = .init(origin: f.helpers.origin(sequence: 2), catalog: [current], equipment: [], editable: true)
        editor.checkLifetime(); XCTAssertTrue(editor.needsReview); XCTAssertFalse(editor.canStage)
        XCTAssertEqual(editor.draft?.catalog, catalog)
        XCTAssertFalse(editor.selectCatalog(catalog))
        editor.useCurrentInvoice(reviewed: f.source)
        XCTAssertNil(editor.draft?.catalog); XCTAssertFalse(editor.canStage)
        XCTAssertEqual(editor.draft?.commandID, oldID)
        XCTAssertTrue(editor.selectCatalog(current)); XCTAssertTrue(editor.canStage)
    }
    func testControllerKeepsUnprotectedTypingOnWriteFailureAndStaleWindow() throws {
        let f = Fixture(), first = StaffInvoiceEditorController(client: try f.client())
        first.open()
        let second = StaffInvoiceEditorController(client: try f.client()); second.open()
        first.change { $0.name = "First window" }
        second.change { $0.name = "Second window" }
        XCTAssertTrue(second.hasUnprotectedChanges)
        XCTAssertEqual(second.draft?.name, "Second window")
        XCTAssertEqual(try f.client().load()?.draft?.name, "First window")
        XCTAssertFalse(second.discardDraft())
        second.reloadSaved(); XCTAssertEqual(second.draft?.name, "First window")
    }
    func testControllerScrubsPresentationAfterAuthorityLossWithoutDeletingStorage() throws {
        let f = Fixture(), editor = StaffInvoiceEditorController(client: try f.client()); editor.open()
        editor.change { $0.name = "Saved finding" }
        let saved = f.memory.values; f.allowed = false; editor.checkLifetime()
        XCTAssertFalse(editor.available); XCTAssertNil(editor.draft); XCTAssertNil(editor.journal); XCTAssertNil(editor.source)
        XCTAssertEqual(saved, f.memory.values)
    }
}
