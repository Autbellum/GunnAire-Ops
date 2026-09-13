import XCTest
import LoadSightKit
@testable import LoadSightUI

@MainActor
final class DocumentExportSessionTests: XCTestCase {
    func testClosedDocumentCannotReceiveLateExportReceipt() async throws {
        var operation = DocumentExportSession(), document = LoadSightDocument()
        try operation.begin(document)
        document.invalidatePendingEdits()
        XCTAssertNil(operation.finish(for: document.editSessionID))
        XCTAssertFalse(operation.isExporting)
    }

    func testConcurrentExportCannotReplaceTheOriginalSnapshot() async throws {
        var operation = DocumentExportSession()
        let original = LoadSightDocument(), another = LoadSightDocument()
        try operation.begin(original)
        XCTAssertThrowsError(try operation.begin(another))
        XCTAssertEqual(operation.snapshot?.editSessionID, original.editSessionID)
        XCTAssertTrue(operation.isExporting)
    }

    func testLateCompletionForReplacementWithIdenticalBytesIsIgnored() async throws {
        var operation = DocumentExportSession()
        let original = LoadSightDocument(), replacement = try LoadSightDocument(project: original.project)
        try operation.begin(original)
        XCTAssertNil(operation.finish(for: replacement.editSessionID))
        XCTAssertFalse(operation.isExporting)
        try operation.begin(replacement)
        XCTAssertEqual(operation.finish(for: replacement.editSessionID)?.editSessionID, replacement.editSessionID)
    }

    func testNewerEditsInSameDocumentDoNotRewriteTheExportReceipt() async throws {
        var operation = DocumentExportSession(), document = LoadSightDocument()
        let originalRoot = document.project.root
        try operation.begin(document)
        try document.project.replace("name", with: .string("Edited during export"))
        let receipt = try XCTUnwrap(operation.finish(for: document.editSessionID))
        XCTAssertEqual(receipt.project.root, originalRoot)
        XCTAssertNotEqual(receipt.project.root, document.project.root)
        XCTAssertFalse(operation.isExporting)
    }

    func testCancellationUnlocksNextExportWithoutProducingReceipt() async throws {
        var operation = DocumentExportSession()
        let original = LoadSightDocument(), next = LoadSightDocument()
        try operation.begin(original)
        operation.cancel()
        XCTAssertNil(operation.finish(for: original.editSessionID))
        try operation.begin(next)
        XCTAssertEqual(operation.finish(for: next.editSessionID)?.editSessionID, next.editSessionID)
    }

    func testCompletionConsumesSnapshotExactlyOnce() async throws {
        var operation = DocumentExportSession()
        let document = LoadSightDocument()
        try operation.begin(document)
        XCTAssertNotNil(operation.finish(for: document.editSessionID))
        XCTAssertNil(operation.finish(for: document.editSessionID))
        XCTAssertNil(operation.snapshot)
    }
}
