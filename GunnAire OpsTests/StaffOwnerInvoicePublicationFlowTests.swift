import Foundation
import SwiftData
import XCTest
@testable import GunnAire_Ops

@MainActor final class StaffOwnerInvoicePublicationFlowTests: XCTestCase {
    func testActualOwnerPublicationConfirmsRecoveredInvoiceAndItemBeforeCoreCapture() async throws {
        let f = try StaffOwnerInvoiceCoordinatorTests.Fixture()
        func local() throws -> [StaffWorkspaceModelRecord] {
            let context = ModelContext(f.models.container); context.autosaveEnabled = false
            return try StaffWorkspaceModelCatalog.all.flatMap { try $0.readSavedRecords(context) }
                .sorted { StaffWorkspaceHistory.key($0) < StaffWorkspaceHistory.key($1) }
        }
        var remote = try local().map { f.models.record($0) }, sequence = 1, publicationCalls = 0
        let storage = StaffWorkspaceRecoveryBoundaryTests.Memory()
        let publisher = StaffWorkspacePublicationCoordinator(dependencies: .init(check: f.check,
            prepare: { context in
                .init(version: 1, scope: context.scope, records: try local(), cursor: nil, deletionKeys: [])
            }, request: { path, method, body in
                XCTAssertTrue(StaffWorkspacePublicationTransportPolicy.allows(path: path, method: method, body: body))
                if method == "POST" {
                    publicationCalls += 1
                    let batch = try StaffWorkspacePublicationContract.decode(StaffWorkspacePublicationBatch.self, from: XCTUnwrap(body))
                    try batch.validate(f.models.scope); XCTAssertEqual(batch.expectedSequence, sequence)
                    for change in batch.changes {
                        let prior = remote.first { $0.key == change.key }
                        XCTAssertEqual(change.expectedRevision, prior?.revision ?? 0)
                        XCTAssertEqual(change.action, "upsert")
                        let record = StaffWorkspaceModelRecord(version: 1, kind: change.kind,
                            id: try XCTUnwrap(UUID(uuidString: change.id)), fields: change.fields)
                        remote.removeAll { $0.key == change.key }
                        remote.append(f.models.record(record, revision: change.expectedRevision + 1))
                    }
                    sequence += 1
                    if let saved = f.saved {
                        f.published = remote.contains { $0.key == saved.proposal.expectedInvoice.key && $0.fields == saved.proposal.invoiceFields && $0.revision > saved.proposal.expectedInvoice.revision }
                            && remote.contains { $0.kind == "item" && $0.id == saved.proposal.request.line.itemID && $0.fields == saved.proposal.newItemFields }
                    }
                    return try StaffWorkspacePublicationContract.encode(StaffWorkspacePublicationReceipt(
                        companyID: batch.companyID, environment: batch.environment, replicaID: batch.replicaID,
                        schema: batch.schema, schemaDigest: batch.schemaDigest, operationID: batch.operationID,
                        sequence: sequence, currentSequence: sequence,
                        changes: batch.changes.map { .init(kind: $0.kind, id: $0.id, revision: $0.expectedRevision + 1, deleted: false) }))
                }
                let items = try XCTUnwrap(URLComponents(string: path)?.queryItems)
                let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
                if let expected = query["sequence"] { XCTAssertEqual(expected, String(sequence)) }
                let rows = remote.sorted { $0.key < $1.key }.filter { $0.key > (query["after"] ?? "") }
                return try StaffWorkspacePublicationContract.encode(StaffWorkspacePublicationPage(
                    companyID: f.original.request.origin.companyID, environment: f.original.request.origin.environment,
                    replicaID: f.original.request.origin.replicaID, schema: StaffWorkspacePublicationContract.schema,
                    schemaDigest: StaffWorkspacePublicationContract.schemaDigest, sequence: sequence,
                    records: rows, nextCursor: nil))
            }, store: storage.store, now: { f.models.now }))
        let baseline = try await publisher.synchronize(f.context)
        XCTAssertTrue(baseline.conflicts.isEmpty); XCTAssertFalse(baseline.hasMore)
        let invoices = f.coordinator(), draft = try await f.draft(invoices)
        f.losePrepare = true
        do { try await invoices.applyReviewed(draft, context: f.context); XCTFail("Expected lost acknowledgment") } catch { }
        XCTAssertEqual(f.models.invoice.amount, 0)
        var captured = false
        let sourceStorage = StaffWorkspaceRecoveryBoundaryTests.Memory()
        let source = StaffReplicaSourceCoordinator(dependencies: .init(context: { f.context }, check: f.check,
            capture: { _, _ in
                captured = true
                XCTAssertEqual(f.models.invoice.amount, 246.75)
                XCTAssertEqual(f.saved?.receipt.state, "published")
                XCTAssertFalse(f.saved?.receipt.qboPublished ?? true)
                XCTAssertTrue(try f.journal().pending.isEmpty)
                throw StaffReplicaSourceSyncError.history // Core provider tested separately; no live connection.
            }, request: { _, _, _ in XCTFail("Unexpected core transport"); throw StaffReplicaSourceSyncError.invalid },
            store: sourceStorage.store, fullWorkspace: publisher, ownerInvoices: invoices))
        await source.sync()
        // Publishing a changed batch deliberately requests another pass to
        // recheck the owner head. Do not confirm or capture core facts early.
        XCTAssertFalse(captured); XCTAssertTrue(source.hasMore)
        XCTAssertEqual(f.saved?.receipt.state, "prepared")
        XCTAssertEqual(try f.journal().pending[f.original.id]?.phase, "saved")
        XCTAssertFalse(f.saved?.receipt.qboPublished ?? true)
        for _ in 0..<8 where !captured {
            await source.sync()
            if !captured && !source.hasMore { break }
        }
        XCTAssertTrue(captured, source.message); XCTAssertGreaterThan(publicationCalls, 0)
        XCTAssertTrue(f.published); XCTAssertEqual(try f.itemCount(), 1); XCTAssertEqual(f.applyCalls, 1)
        XCTAssertEqual(f.posts.first, f.posts.last)
        XCTAssertTrue(invoices.reviews.isEmpty)
    }
}
