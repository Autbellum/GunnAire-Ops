import XCTest
import LoadSightKit
@testable import LoadSightUI

@MainActor final class DrawingReviewSessionTests: XCTestCase {
    private func fixture(saved: Bool = true) async throws -> (LoadSightDocument, EquipmentScheduleRequest) {
        let pdf = try XCTUnwrap(Bundle.module.url(forResource: "EquipmentSchedule", withExtension: "pdf", subdirectory: "Fixtures"))
        let mapping = try XCTUnwrap(Bundle.module.url(forResource: "EquipmentScheduleMapping", withExtension: "json", subdirectory: "Fixtures"))
        let archive = try await DrawingIngestor().ingest(url: pdf, ocr: .disabled)
        let request = try EquipmentScheduleRequest.decode(Data(contentsOf: mapping))
        var document = try LoadSightDocument(project: LoadSightTests().readyProject())
        try document.addDrawings(archive)
        if saved {
            try document.project.saveScheduleMap(name: "Original", request: request, drawings: archive,
                expectedFingerprint: document.project.scheduleMapEditFingerprint(), author: "Estimator", reason: "Map fixture headers")
        }
        return (document, request)
    }

    func testCapturedMapEditSavesOnceWithoutChangingEquipmentQuantities() async throws {
        var (document, _) = try await fixture()
        let map = try XCTUnwrap(document.project.scheduleMaps().first)
        let session = try ScheduleMapEditSession(document: document, mapID: map.id)
        let items = document.project.items, drawings = document.drawings
        var draft = session.draft; draft.name = "Reviewed map"
        try session.save(draft, author: "Checker", reason: "Correct label", in: &document)
        XCTAssertEqual(try document.project.scheduleMaps().first?.name, "Reviewed map")
        XCTAssertEqual(try document.project.scheduleMapHistory().count, 2)
        XCTAssertEqual(document.project.items, items)
        XCTAssertEqual(document.drawings, drawings)
        let after = try document.project.data()
        XCTAssertThrowsError(try session.save(draft, author: "Checker", reason: "Duplicate", in: &document))
        XCTAssertEqual(try document.project.data(), after)
    }

    func testDelayedEditorCannotOverwriteOrRemoveANewerMapRevision() async throws {
        var (document, request) = try await fixture()
        let map = try XCTUnwrap(document.project.scheduleMaps().first)
        let delayed = try ScheduleMapEditSession(document: document, mapID: map.id)
        try document.project.saveScheduleMap(id: map.id, name: "Newer office revision", request: request,
            drawings: document.drawings, expectedFingerprint: document.project.scheduleMapEditFingerprint(), author: "Office", reason: "Another window changed this map")
        var draft = delayed.draft; draft.name = "Late old draft"
        let before = try document.project.data()
        XCTAssertThrowsError(try delayed.save(draft, author: "Field", reason: "Late save", in: &document))
        XCTAssertThrowsError(try delayed.remove(author: "Field", reason: "Late removal", in: &document))
        XCTAssertEqual(try document.project.data(), before)
        let current = try ScheduleMapEditSession(document: document, mapID: map.id)
        XCTAssertEqual(current.draft.name, "Newer office revision")
        try current.remove(author: "Office", reason: "Superseded map", in: &document)
        XCTAssertTrue(try document.project.scheduleMaps().isEmpty)
        XCTAssertEqual(try document.project.scheduleMapHistory().count, 3)
    }

    func testIdenticalBytesReopenedCannotReceiveMapSaveRemovalOrPickerCompletion() async throws {
        let (created, _) = try await fixture()
        let wrapper = try created.wrapper(asPackage: true)
        let original = try LoadSightDocument(wrapper: wrapper)
        let map = try XCTUnwrap(original.project.scheduleMaps().first)
        let session = try ScheduleMapEditSession(document: original, mapID: map.id)
        var replacement = try LoadSightDocument(wrapper: wrapper)
        XCTAssertEqual(original.project.root, replacement.project.root)
        XCTAssertEqual(original.drawings, replacement.drawings)
        XCTAssertNotEqual(original.editSessionID, replacement.editSessionID)
        let before = try replacement.project.data()
        XCTAssertThrowsError(try session.context.validate(replacement))
        XCTAssertThrowsError(try session.save(session.draft, author: "Mapper", reason: "Wrong project", in: &replacement))
        XCTAssertThrowsError(try session.remove(author: "Mapper", reason: "Wrong project", in: &replacement))
        XCTAssertEqual(try replacement.project.data(), before)
    }

    func testDrawingChangeWithinSameSessionRejectsEditsAndKeepsOriginalPreview() async throws {
        var (document, _) = try await fixture()
        let map = try XCTUnwrap(document.project.scheduleMaps().first)
        let session = try ScheduleMapEditSession(document: document, mapID: map.id)
        let original = document.drawings, identity = document.editSessionID
        let extra = try XCTUnwrap(Bundle.module.url(forResource: "DrawingIntake", withExtension: "pdf", subdirectory: "Fixtures"))
        try document.addDrawings(await DrawingIngestor().ingest(url: extra, ocr: .disabled))
        XCTAssertEqual(document.editSessionID, identity)
        XCTAssertNotEqual(document.drawings, original)
        XCTAssertEqual(session.context.drawings, original)
        let before = try document.project.data()
        XCTAssertThrowsError(try session.context.validate(document))
        XCTAssertThrowsError(try session.save(session.draft, author: "Mapper", reason: "Stale source", in: &document))
        XCTAssertThrowsError(try session.remove(author: "Mapper", reason: "Stale source", in: &document))
        XCTAssertEqual(try document.project.data(), before)
    }

    func testNewMapDraftAlsoRejectsConcurrentMapEdits() async throws {
        var (document, request) = try await fixture(saved: false)
        let first = try ScheduleMapEditSession(document: document, request: request)
        let second = try ScheduleMapEditSession(document: document, request: request)
        var draft = first.draft; draft.name = "First saved map"
        try first.save(draft, author: "First", reason: "Selected headers", in: &document)
        let before = try document.project.data()
        draft.name = "Second stale map"
        XCTAssertThrowsError(try second.save(draft, author: "Second", reason: "Stale selection", in: &document))
        XCTAssertThrowsError(try first.remove(author: "First", reason: "No captured saved ID", in: &document))
        XCTAssertEqual(try document.project.data(), before)
        XCTAssertThrowsError(try ScheduleMapEditSession(document: document, mapID: UUID()))
    }

    func testRFISelectionCreatesOnlyAnOriginalProjectDraft() async throws {
        var (document, _) = try await fixture()
        let candidate = try XCTUnwrap(MechanicalTextExtractor.extract(document.drawings).candidates.first)
        let selection = DrawingReviewSelection(document: document, value: candidate)
        let items = document.project.items
        let id = try selection.session.createRFI(from: selection.value, question: "Clarify the schedule tag", impact: "Equipment count remains unconfirmed", author: "Technician", in: &document)
        let rfi = try XCTUnwrap(document.project.root["rfis"].array?.first { $0["id"].string == id })
        XCTAssertEqual(rfi["status"].string, "Open")
        XCTAssertTrue(rfi["source"].string?.contains(candidate.id) == true)
        XCTAssertEqual(document.project.items, items)
    }

    func testDelayedRFISelectionDoesNotAdoptAReplacementOrRevokedSession() async throws {
        var (original, _) = try await fixture()
        let candidate = try XCTUnwrap(MechanicalTextExtractor.extract(original.drawings).candidates.first)
        let selection = DrawingReviewSelection(document: original, value: candidate)
        var replacement = try LoadSightDocument(wrapper: original.wrapper(asPackage: true))
        let before = try replacement.project.data()
        XCTAssertThrowsError(try selection.session.createRFI(from: candidate, question: "Question", impact: "Unknown", author: "Technician", in: &replacement))
        XCTAssertEqual(try replacement.project.data(), before)
        original.invalidatePendingEdits()
        let revoked = try original.project.data()
        XCTAssertThrowsError(try selection.session.createRFI(from: candidate, question: "Question", impact: "Unknown", author: "Technician", in: &original))
        XCTAssertEqual(try original.project.data(), revoked)
    }

    func testFailedReviewEditIsAtomicAndRepeatedSelectionGetsFreshPresentationIdentity() async throws {
        var (document, _) = try await fixture()
        let candidate = try XCTUnwrap(MechanicalTextExtractor.extract(document.drawings).candidates.first)
        let first = DrawingReviewSelection(document: document, value: candidate)
        let second = DrawingReviewSelection(document: document, value: candidate)
        XCTAssertNotEqual(first.id, second.id)
        let before = try document.project.data()
        XCTAssertThrowsError(try first.session.apply(to: &document) { copy in
            try copy.project.replace("name", with: .string("Must not survive"))
            throw LoadSightError.invalid("Simulated failure after a candidate edit")
        })
        XCTAssertEqual(try document.project.data(), before)
        XCTAssertTrue(first.session.matches(document))
    }
}
