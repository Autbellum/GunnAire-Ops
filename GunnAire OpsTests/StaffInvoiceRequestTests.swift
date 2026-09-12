import Foundation
import XCTest
@testable import GunnAire_Ops

@MainActor final class StaffInvoiceRequestTests: XCTestCase {
    final class Memory {
        nonisolated deinit {}
        var values: [String: Data] = [:]
        var failWrite = false
        var loseAcknowledgment = false
        var writes = 0
        var store: SharedTimeLocalStore {
            .init(read: { self.values[$0] }, write: {
                if self.failWrite { throw StaffReplicaDeliveryError.storage }
                self.values[$0] = $1; self.writes += 1
                if self.loseAcknowledgment { throw StaffReplicaDeliveryError.storage }
            })
        }
    }
    func origin(sequence: Int = 1) -> StaffInvoiceOrigin {
        .init(companyID: "a1000000-0000-4000-8000-000000000001", environment: "development",
              replicaID: "a1000000-0000-4000-8000-000000000002", selectionID: "a1000000-0000-4000-8000-000000000003",
              sourceSequence: sequence, contentSHA256: String(repeating: "a", count: 64),
              invoiceID: "a1000000-0000-4000-8000-000000000004", invoiceRevision: 1,
              customerID: "a1000000-0000-4000-8000-000000000005", jobID: nil)
    }
    func line() -> StaffInvoiceLine {
        .init(kind: "new", itemID: UUID().uuidString.lowercased(), itemRevision: 0, itemType: "Service",
              name: "Synthetic capacitor replacement", description: nil, sku: nil, unitPrice: 123.375,
              quantity: 2, isTaxable: false, equipmentID: nil)
    }
    func request(line: StaffInvoiceLine? = nil) -> StaffInvoiceRequest {
        .init(origin: origin(), commandID: UUID().uuidString.lowercased(), line: line ?? self.line(), reason: "Office review requested")
    }
    func scope() -> CloudKitStaffSetupScope {
        .init(origin: "https://example.invalid", company: UUID(uuidString: origin().companyID)!, email: "technician@example.invalid",
              environment: "development", accountHash: String(repeating: "b", count: 64))
    }
    func receipt(_ request: StaffInvoiceRequest, plan: UUID, subtotal: String? = "246.75") -> StaffInvoiceReceipt {
        .init(schema: StaffInvoiceRequest.schema, request: request, actorEmail: scope().email, shareID: plan.uuidString.lowercased(),
              createdAt: "2026-09-11T07:00:00.123456+00:00", state: "recorded", officeReviewRequired: true, qboPublished: false, lineSubtotal: subtotal)
    }
    func draft(_ origin: StaffInvoiceOrigin? = nil) -> StaffInvoiceDraft {
        var draft = StaffInvoiceDraft(origin: origin ?? self.origin(), commandID: UUID().uuidString.lowercased(), newItemID: UUID().uuidString.lowercased())
        draft.name = "Capacitor"; draft.price = "123.375"; draft.quantity = "2"; draft.reason = "Office review"
        return draft
    }
    func journal(plan: UUID = UUID()) -> StaffInvoiceJournal {
        .init(scope: scope(), planID: plan, replicaID: origin().replicaID, invoiceID: origin().invoiceID)
    }
    func mutate(_ data: Data, _ action: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        action(&object); return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func testFlattenedWireIncludesAllExplicitNullsAndRoundTrips() throws {
        let request = request(), data = try StaffWorkspacePublicationContract.encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["origin"]); XCTAssertTrue(json["jobID"] is NSNull)
        XCTAssertEqual(Set(json.keys), Set("companyID environment replicaID schema commandID selectionID sourceSequence contentSHA256 invoiceID invoiceRevision customerID jobID line reason".split(separator: " ").map(String.init)))
        let line = try XCTUnwrap(json["line"] as? [String: Any])
        for field in ["description", "sku", "equipmentID"] { XCTAssertTrue(line[field] is NSNull) }
        XCTAssertEqual(try StaffWorkspacePublicationContract.decode(StaffInvoiceRequest.self, from: data), request)
        try request.validate()
    }
    func testUnknownFieldsMissingNullAndBoolAmountsFailStrictDecode() throws {
        let data = try StaffWorkspacePublicationContract.encode(request())
        for key in ["ownerOnly", "qboPublished"] {
            let changed = try mutate(data) { $0[key] = true }
            XCTAssertThrowsError(try StaffWorkspacePublicationContract.decode(StaffInvoiceRequest.self, from: changed))
        }
        XCTAssertThrowsError(try StaffWorkspacePublicationContract.decode(StaffInvoiceRequest.self, from: mutate(data) { $0.removeValue(forKey: "jobID") }))
        for value in [true as Any, "2" as Any] {
            let changed = try mutate(data) { var line = $0["line"] as! [String: Any]; line["quantity"] = value; $0["line"] = line }
            XCTAssertThrowsError(try StaffWorkspacePublicationContract.decode(StaffInvoiceRequest.self, from: changed))
        }
    }
    func testScalarBoundsAndNewVersusCatalogRules() throws {
        for value in [0.0, -1, 0.000001, 1_000_000, .nan, .infinity] {
            var line = line(); line.quantity = value; XCTAssertThrowsError(try line.validate())
        }
        for value in [-1.0, 100_000_000_000, 1.000001, .nan, .infinity] {
            var line = line(); line.unitPrice = value; XCTAssertThrowsError(try line.validate())
        }
        var catalog = line(); catalog.kind = "catalog"; catalog.itemRevision = 1
        catalog.description = "  "; catalog.sku = ""; try catalog.validate()
        catalog.kind = "new"; catalog.itemRevision = 0; XCTAssertThrowsError(try catalog.validate())
        catalog.description = nil; catalog.sku = nil; catalog.itemType = "Inventory"
        XCTAssertThrowsError(try catalog.validate())
    }
    func testFractionalPriceHalfUpAndGroupSubtotalReceipt() throws {
        let plan = UUID(), request = request()
        XCTAssertEqual(request.line.unitPriceSubtotal, Decimal(string: "246.75"))
        try receipt(request, plan: plan).validate(request: request, email: scope().email, plan: plan)
        var half = line(); half.unitPrice = 1.005; half.quantity = 1
        XCTAssertEqual(half.unitPriceSubtotal, Decimal(string: "1.01"))
        half.unitPrice = -0.0; XCTAssertEqual(half.unitPriceSubtotal, 0)
        var group = line(); group.kind = "catalog"; group.itemRevision = 1; group.itemType = "Group"
        let grouped = self.request(line: group)
        try receipt(grouped, plan: plan, subtotal: nil).validate(request: grouped, email: scope().email, plan: plan)
        XCTAssertThrowsError(try receipt(grouped, plan: plan, subtotal: "0.00").validate(request: grouped, email: scope().email, plan: plan))
    }
    func testWrongReceiptAuthorPlanStateSubtotalAndMissingNullFail() throws {
        let plan = UUID(), request = self.request(), receipt = self.receipt(self.request(), plan: UUID())
        XCTAssertThrowsError(try receipt.validate(request: request, email: scope().email, plan: plan))
        let original = self.receipt(request, plan: plan), bytes = try StaffWorkspacePublicationContract.encode(original)
        for (key, value) in [("state", "applied" as Any), ("actorEmail", "other@example.invalid"), ("qboPublished", true),
                             ("officeReviewRequired", false), ("lineSubtotal", "246.76"), ("createdAt", "wrong")] {
            let result = try StaffWorkspacePublicationContract.decode(StaffInvoiceReceipt.self, from: mutate(bytes) { $0[key] = value })
            XCTAssertThrowsError(try result.validate(request: request, email: scope().email, plan: plan), key)
        }
    }
    func testTransportIsExactAndNeverUsesOperationalOrOwnerRoute() throws {
        let request = request(), plan = UUID(), bytes = try StaffWorkspacePublicationContract.encode(request)
        let path = StaffInvoiceHTTPPolicy.path(plan: plan, request: request)
        XCTAssertTrue(StaffInvoiceHTTPPolicy.allows(path: path, method: "POST", body: bytes))
        for bad in [path + "/", path + "?x=1", path + "#x", "https://example.invalid" + path,
                    path.replacingOccurrences(of: "invoice-line-requests", with: "commands"),
                    path.replacingOccurrences(of: request.origin.selectionID, with: UUID().uuidString.lowercased()),
                    path.replacingOccurrences(of: "/content/", with: "/%63ontent/")] {
            XCTAssertFalse(StaffInvoiceHTTPPolicy.allows(path: bad, method: "POST", body: bytes), bad)
        }
        XCTAssertFalse(StaffInvoiceHTTPPolicy.allows(path: path, method: "GET", body: bytes))
        XCTAssertFalse(StaffWorkspaceContentHTTPPolicy.allows(path: path, method: "POST", body: bytes))
    }
    func testRawIncompleteInputIsSavedButCannotBeQueued() throws {
        let memory = Memory(); var journal = journal(); var draft = draft(); draft.price = ""
        journal.draft = draft
        try StaffInvoiceJournalStore.write(store: memory.store, next: journal, expected: nil, check: {})
        let loaded = try StaffInvoiceJournalStore.load(store: memory.store, scope: journal.scope, plan: journal.planID, replica: journal.replicaID, invoice: journal.invoiceID)
        XCTAssertEqual(loaded, journal); XCTAssertThrowsError(try loaded!.draft!.request())
    }
    func testAtomicStageRetainsCompleteRequestWithoutSecondaryIndex() throws {
        let memory = Memory(); var original = journal(); original.draft = draft()
        try StaffInvoiceJournalStore.write(store: memory.store, next: original, expected: nil, check: {})
        var next = original; next.revision += 1; next.entries = [.init(request: try original.draft!.request(), receipt: nil)]; next.draft = nil
        try StaffInvoiceJournalStore.write(store: memory.store, next: next, expected: original, check: {})
        XCTAssertEqual(memory.values.count, 1)
        let recovered = try StaffInvoiceJournalStore.load(store: memory.store, scope: next.scope, plan: next.planID, replica: next.replicaID, invoice: next.invoiceID)
        XCTAssertEqual(recovered, next); XCTAssertEqual(recovered?.pending.count, 1)
        XCTAssertEqual(recovered?.entries[0].id, original.draft?.commandID)
    }
    func testLostWriteAcknowledgmentReplaysSameJournalButStaleWindowConflicts() throws {
        let memory = Memory(); var original = journal(); original.draft = draft()
        memory.loseAcknowledgment = true
        XCTAssertThrowsError(try StaffInvoiceJournalStore.write(store: memory.store, next: original, expected: nil, check: {}))
        memory.loseAcknowledgment = false
        try StaffInvoiceJournalStore.write(store: memory.store, next: original, expected: nil, check: {})
        XCTAssertEqual(memory.writes, 1)
        var changed = original; changed.draft?.name = "Different window"
        XCTAssertThrowsError(try StaffInvoiceJournalStore.write(store: memory.store, next: changed, expected: nil, check: {}))
    }
    func testOriginalRequestsAndReceiptsCannotBeEditedReorderedOrRemoved() throws {
        let memory = Memory(); var original = journal()
        let request = request(); original.entries = [.init(request: request, receipt: receipt(request, plan: original.planID))]
        try StaffInvoiceJournalStore.write(store: memory.store, next: original, expected: nil, check: {})
        var changed = original; changed.revision += 1; changed.entries = []
        XCTAssertThrowsError(try StaffInvoiceJournalStore.write(store: memory.store, next: changed, expected: original, check: {}))
        changed.entries = [.init(request: request, receipt: nil)]
        XCTAssertThrowsError(try StaffInvoiceJournalStore.write(store: memory.store, next: changed, expected: original, check: {}))
        changed.entries = [.init(request: self.request(), receipt: nil)]
        XCTAssertThrowsError(try StaffInvoiceJournalStore.write(store: memory.store, next: changed, expected: original, check: {}))
    }
    func testStorageFailureOrAuthorityLossDoesNotDiscardPriorBytes() throws {
        let memory = Memory(); let original = journal()
        try StaffInvoiceJournalStore.write(store: memory.store, next: original, expected: nil, check: {})
        let bytes = memory.values; var changed = original; changed.revision += 1; changed.draft = draft()
        memory.failWrite = true
        XCTAssertThrowsError(try StaffInvoiceJournalStore.write(store: memory.store, next: changed, expected: original, check: {}))
        memory.failWrite = false
        XCTAssertThrowsError(try StaffInvoiceJournalStore.write(store: memory.store, next: changed, expected: original, check: { throw StaffReplicaDeliveryError.access }))
        XCTAssertEqual(memory.values, bytes)
    }
}
