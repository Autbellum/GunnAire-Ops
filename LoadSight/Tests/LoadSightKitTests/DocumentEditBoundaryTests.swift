import XCTest
import LoadSightKit
@testable import LoadSightUI

@MainActor
final class DocumentEditBoundaryTests: XCTestCase {
    func testClosingRevokesPendingResultsWithoutChangingDocumentBytes() async throws {
        var document = LoadSightDocument()
        let originalID = document.editSessionID, originalData = try document.project.data()
        document.invalidatePendingEdits()
        XCTAssertNotEqual(document.editSessionID, originalID)
        XCTAssertThrowsError(try document.applyEdit(for: originalID) { try $0.project.replace("name", with: .string("Arrived after close")) })
        XCTAssertEqual(try document.project.data(), originalData)
    }

    func testEarlierFlushReceiptCannotStandInForLatestDocumentSaveState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LoadSightCloseBoundary-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceRecoveryStore(directory: directory), recovery = WorkspaceRecoverySession(scope: "Synthetic scope", store: store)
        await recovery.load()
        var document = LoadSightDocument()
        let earlierReceipt = await recovery.flush(project: document.project, drawings: document.drawings)
        try document.project.replace("name", with: .string("Import updated the current document"))
        XCTAssertTrue(earlierReceipt)
        XCTAssertFalse(recovery.isSaved(project: document.project, drawings: document.drawings))
        _ = await recovery.flush(project: document.project, drawings: document.drawings)
        XCTAssertTrue(recovery.isSaved(project: document.project, drawings: document.drawings))
        let restored = try await store.load(scope: "Synthetic scope")
        XCTAssertEqual(restored?.project["name"].string, document.project.name)
    }

    func testReplacementWithIdenticalProjectBytesRejectsLateEdit() async throws {
        let original = LoadSightDocument()
        var replacement = try LoadSightDocument(project: original.project)
        XCTAssertEqual(replacement.project.root, original.project.root)
        let before = try replacement.project.data()
        XCTAssertThrowsError(try replacement.applyEdit(for: original.editSessionID) {
            try $0.project.replace("name", with: .string("Late result"))
        })
        XCTAssertEqual(try replacement.project.data(), before)
    }

    func testCopyKeepsSessionWhilePackageAndJSONReopenStartNewSessions() async throws {
        let original = LoadSightDocument(), copy = original
        XCTAssertEqual(copy.editSessionID, original.editSessionID)
        for package in [true, false] {
            let reopened = try LoadSightDocument(wrapper: original.wrapper(asPackage: package))
            XCTAssertNotEqual(reopened.editSessionID, original.editSessionID)
            XCTAssertFalse(String(data: try reopened.project.data(), encoding: .utf8)!.contains(original.editSessionID.uuidString))
        }
    }

    func testSameDocumentConcurrentEditsAreRetainedWhenAttachmentFinishes() async throws {
        var document = LoadSightDocument()
        let destination = document.editSessionID
        try document.project.replace("name", with: .string("Edited while reading"))
        try document.applyEdit(for: destination) {
            try $0.project.addAttachment(data: Data("Synthetic attachment".utf8), filename: "synthetic.txt", author: "Recorder", source: "Same document", rfiID: nil)
        }
        XCTAssertEqual(document.project.name, "Edited while reading")
        XCTAssertEqual(try document.project.attachments().count, 1)
        XCTAssertEqual(document.editSessionID, destination)
    }

    func testReplacementCannotReceiveLateAttachment() async throws {
        let original = LoadSightDocument()
        var replacement = LoadSightDocument()
        let before = try replacement.project.data()
        XCTAssertThrowsError(try replacement.applyEdit(for: original.editSessionID) {
            try $0.project.addAttachment(data: Data("Private to original project".utf8), filename: "synthetic.txt", author: "Recorder", source: "Original document", rfiID: nil)
        })
        XCTAssertTrue(try replacement.project.attachments().isEmpty)
        XCTAssertEqual(try replacement.project.data(), before)
    }

    func testReplacementCannotReceiveLateDrawingBatch() async throws {
        let original = LoadSightDocument()
        let file = Bundle.module.url(forResource: "DrawingIntake", withExtension: "pdf", subdirectory: "Fixtures")!
        let batch = try await DrawingIngestor().ingest(url: file)
        var replacement = LoadSightDocument()
        let before = try replacement.project.data()
        XCTAssertThrowsError(try replacement.applyEdit(for: original.editSessionID) { try $0.addDrawings(batch) })
        XCTAssertTrue(replacement.drawings.files.isEmpty)
        XCTAssertEqual(try replacement.project.data(), before)
    }

    func testFailedEditDoesNotPartiallyMutateTheCurrentDocument() async throws {
        enum FailedImport: Error { case invalid }
        var document = LoadSightDocument()
        let before = try document.project.data(), destination = document.editSessionID
        XCTAssertThrowsError(try document.applyEdit(for: destination) {
            try $0.project.replace("name", with: .string("Partial edit"))
            throw FailedImport.invalid
        })
        XCTAssertEqual(try document.project.data(), before)
    }

    func testRestoredRecoveryStartsNewSessionAndRetainsOriginalEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LoadSightDocumentSession-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let original = LoadSightDocument(), store = WorkspaceRecoveryStore(directory: directory)
        let draft = try await store.save(project: original.project, drawings: original.drawings, scope: "Synthetic scope", expectedRevision: nil)
        var restored = try LoadSightDocument(recoveryDraft: draft)
        XCTAssertNotEqual(restored.editSessionID, original.editSessionID)
        let before = try restored.project.data()
        XCTAssertThrowsError(try restored.applyEdit(for: original.editSessionID) { try $0.project.replace("name", with: .string("Late result")) })
        XCTAssertEqual(try restored.project.data(), before)
        XCTAssertEqual(restored.drawings, original.drawings)
    }
}
