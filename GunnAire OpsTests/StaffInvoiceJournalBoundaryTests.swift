import Foundation
import XCTest
@testable import GunnAire_Ops

/// Reviewed/adapted from local Ollama suggestions. Corrects its invented helper APIs
/// and wrong assumption that an exact durable replay should fail.
@MainActor final class StaffInvoiceJournalBoundaryTests: XCTestCase {
    func testCapacityKeepsExactReplayAndRejectsAnAdditionalUniqueRequest() throws {
        let h = StaffInvoiceRequestTests(), memory = StaffInvoiceRequestTests.Memory()
        var original = h.journal()
        original.entries = (0..<128).map { _ in .init(request: h.request(), receipt: nil) }
        try StaffInvoiceJournalStore.write(store: memory.store, next: original, expected: nil, check: {})
        try StaffInvoiceJournalStore.write(store: memory.store, next: original, expected: nil, check: {})
        XCTAssertEqual(memory.writes, 1)
        var overflow = original; overflow.revision += 1; overflow.entries.append(.init(request: h.request(), receipt: nil))
        XCTAssertThrowsError(try StaffInvoiceJournalStore.write(store: memory.store, next: overflow, expected: original, check: {}))
        XCTAssertEqual(try StaffInvoiceJournalStore.load(store: memory.store, scope: original.scope, plan: original.planID,
            replica: original.replicaID, invoice: original.invoiceID), original)
    }
    func testForeignAccountAndInvoiceKeyCannotReadCopiedJournal() throws {
        let h = StaffInvoiceRequestTests(), memory = StaffInvoiceRequestTests.Memory(), original = h.journal()
        let bytes = try StaffWorkspacePublicationContract.encode(original)
        let foreign = CloudKitStaffSetupScope(origin: original.scope.origin, company: original.scope.company,
            email: "foreign@example.invalid", environment: original.scope.environment, accountHash: original.scope.accountHash)
        memory.values[StaffInvoiceJournalStore.key(scope: foreign, plan: original.planID, invoice: original.invoiceID)] = bytes
        XCTAssertThrowsError(try StaffInvoiceJournalStore.load(store: memory.store, scope: foreign, plan: original.planID,
            replica: original.replicaID, invoice: original.invoiceID))
        let invoice = UUID().uuidString.lowercased()
        memory.values[StaffInvoiceJournalStore.key(scope: original.scope, plan: original.planID, invoice: invoice)] = bytes
        XCTAssertThrowsError(try StaffInvoiceJournalStore.load(store: memory.store, scope: original.scope, plan: original.planID,
            replica: original.replicaID, invoice: invoice))
        XCTAssertEqual(Set(memory.values.values), [bytes])
    }
    func testDuplicateCommandIdentitiesNeverBecomeTwoQueuedLines() throws {
        let h = StaffInvoiceRequestTests(), memory = StaffInvoiceRequestTests.Memory(), request = h.request()
        var journal = h.journal()
        let other = StaffInvoiceRequest(origin: request.origin, commandID: request.commandID, line: h.line(), reason: "Different line")
        journal.entries = [.init(request: request, receipt: nil), .init(request: other, receipt: nil)]
        XCTAssertThrowsError(try StaffInvoiceJournalStore.write(store: memory.store, next: journal, expected: nil, check: {}))
        XCTAssertTrue(memory.values.isEmpty)
    }
}
