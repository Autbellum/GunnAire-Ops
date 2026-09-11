import XCTest
import LoadSightKit
@testable import LoadSightUI

@MainActor final class ScheduleDiscoveryPreparationTests: XCTestCase {
    func testDiscoveryResultCannotFollowReplacementDocumentOrCancellation() async throws {
        let pdf = Bundle.module.url(forResource: "EquipmentSchedule", withExtension: "pdf", subdirectory: "Fixtures")!
        let archive = try await DrawingIngestor().ingest(url: pdf, ocr: .disabled)
        let controller = ScheduleDiscoveryPreparation(), identity = UUID()
        controller.start(drawings: archive, documentSessionID: identity)
        let deadline = Date().addingTimeInterval(5)
        while controller.isScanning && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.result?.candidates.count, 1)
        XCTAssertTrue(controller.matches(drawings: archive, documentSessionID: identity))
        XCTAssertFalse(controller.matches(drawings: archive, documentSessionID: UUID()))
        controller.start(drawings: archive, documentSessionID: identity)
        controller.cancel()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(controller.result); XCTAssertFalse(controller.isScanning)
        XCTAssertFalse(controller.matches(drawings: archive, documentSessionID: identity))
    }
    func testDiscoveredMapStillRequiresAuthoredSaveAndReopensWithOriginal() async throws {
        let pdf = Bundle.module.url(forResource: "EquipmentSchedule", withExtension: "pdf", subdirectory: "Fixtures")!
        let archive = try await DrawingIngestor().ingest(url: pdf, ocr: .disabled)
        var document = LoadSightDocument(); try document.addDrawings(archive)
        let candidate = try XCTUnwrap(EquipmentScheduleDiscoverer.discover(archive).candidates.first)
        let request = try candidate.draftRequest(in: archive)
        let session = try ScheduleMapEditSession(document: document, request: request)
        var draft = session.draft; draft.name = "Reviewed discovery"
        let before = try document.project.data()
        XCTAssertThrowsError(try session.save(draft, author: "", reason: "", in: &document))
        XCTAssertEqual(try document.project.data(), before)
        try session.save(draft, author: "Mapper", reason: "Checked headers and source body", in: &document)
        let reopened = try LoadSightDocument(wrapper: document.wrapper(asPackage: true))
        XCTAssertEqual(try reopened.project.scheduleMaps().first?.name, "Reviewed discovery")
        XCTAssertEqual(reopened.drawings, archive); XCTAssertTrue(reopened.project.items.isEmpty)
        XCTAssertTrue(try reopened.project.scheduleMaps()[0].columnMap().regions[0].mappingBasis.contains(EquipmentScheduleDiscoverer.method))
        var replacement = LoadSightDocument(); try replacement.addDrawings(archive)
        let unchanged = try replacement.project.data()
        XCTAssertThrowsError(try session.save(draft, author: "Mapper", reason: "Stale document", in: &replacement))
        XCTAssertEqual(try replacement.project.data(), unchanged)
    }
}
