import XCTest
import LoadSightKit
@testable import LoadSightUI

@MainActor final class DrawingReviewDraftTests: XCTestCase {
    private func fixture() async throws -> (LoadSightDocument, EquipmentScheduleRequest, EquipmentScheduleRow) {
        let pdf = try XCTUnwrap(Bundle.module.url(forResource: "ConsistencySchedule", withExtension: "pdf", subdirectory: "Fixtures"))
        let map = try XCTUnwrap(Bundle.module.url(forResource: "ConsistencyScheduleMapping", withExtension: "json", subdirectory: "Fixtures"))
        var document = try LoadSightDocument(project: LoadSightTests().readyProject())
        try document.addDrawings(await DrawingIngestor().ingest(url: pdf, ocr: .disabled))
        let request = try EquipmentScheduleRequest.decode(Data(contentsOf: map))
        let row = try XCTUnwrap(EquipmentScheduleExtractor.extract(document.drawings, request: request).rows.first)
        return (document, request, row)
    }

    func testSourceInvalidationKeepsOpenReviewIdentity() async throws {
        let (document, request, row) = try await fixture()
        let selected = DrawingReviewSelection(document: document, value: row)
        var review = EquipmentScheduleReviewState(request: request, selected: selected)
        for _ in 0..<3 {
            review.invalidateResults()
            XCTAssertNil(review.request, "Stale extraction inputs must be cleared.")
            XCTAssertEqual(review.selected?.id, selected.id, "Clearing the parent sheet also discards its nested RFI draft.")
            XCTAssertEqual(review.selected?.session.drawings, document.drawings)
        }
    }

    private func filledDraft() -> SourceRFIDraft {
        var draft = SourceRFIDraft()
        draft.question = "Clarify the source basis."
        draft.impact = "Equipment selection pending."
        draft.author = "Field reviewer"
        return draft
    }

    private func create(_ document: inout LoadSightDocument, _ draft: SourceRFIDraft,
                        row: EquipmentScheduleRow, schedule: Bool) throws -> String {
        if schedule {
            return try document.project.createRFI(from: row, findingID: "airflow.outdoorTotal", drawings: document.drawings,
                question: draft.question, impact: draft.impact, author: draft.author)
        }
        let candidate = try XCTUnwrap(MechanicalTextExtractor.extract(document.drawings).candidates.first)
        return try document.project.createRFI(from: candidate, drawings: document.drawings,
            question: draft.question, impact: draft.impact, author: draft.author)
    }

    func testExplicitDismissalAllowsFreshReviewWithoutRevivingOldSelection() async throws {
        let (document, request, row) = try await fixture()
        let selected = DrawingReviewSelection(document: document, value: row)
        var review = EquipmentScheduleReviewState(request: request, selected: selected)
        review.invalidateResults()
        review.request = request
        XCTAssertEqual(review.selected?.id, selected.id)
        review.selected = nil // Explicit user dismissal, not a source refresh.
        review.invalidateResults()
        XCTAssertNil(review.selected)
        review.selected = .init(document: document, value: row)
        XCTAssertNotEqual(review.selected?.id, selected.id)
    }

    func testBothComposersFreezeAfterSuccessAndRejectDuplicateSubmission() async throws {
        for schedule in [true, false] {
            var (document, _, row) = try await fixture()
            let session = DrawingReviewSession(document: document)
            var draft = filledDraft()
            XCTAssertTrue(draft.isDirty && draft.canEdit && draft.canSave(session: session, in: document))
            try draft.save(session: session, in: &document) { copy, content in
                try create(&copy, content, row: row, schedule: schedule)
            }
            let id = try XCTUnwrap(draft.savedID), before = try document.project.data()
            XCTAssertFalse(draft.isDirty || draft.canEdit || draft.canSave(session: session, in: document))
            let rfi = try XCTUnwrap(document.project.root["rfis"].array?.first { $0["id"].string == id })
            XCTAssertEqual(rfi["question"].string, draft.question)
            XCTAssertEqual(rfi["updatedBy"].string, draft.author)
            XCTAssertEqual(rfi["status"].string, "Open")
            XCTAssertThrowsError(try draft.save(session: session, in: &document) { _, _ in
                XCTFail("A saved composer cannot issue another mutation")
                return "duplicate"
            })
            XCTAssertEqual(draft.savedID, id)
            XCTAssertEqual(try document.project.data(), before)
        }
    }

    func testBothComposersRetainTextOnValidationFailureAndCanRetry() async throws {
        for schedule in [true, false] {
            var (document, _, row) = try await fixture()
            let session = DrawingReviewSession(document: document), before = try document.project.data()
            var draft = filledDraft(); draft.question = " "
            let original = draft
            XCTAssertThrowsError(try draft.save(session: session, in: &document) { copy, content in
                try create(&copy, content, row: row, schedule: schedule)
            })
            XCTAssertEqual(draft, original)
            XCTAssertTrue(draft.isDirty && draft.canEdit)
            XCTAssertEqual(try document.project.data(), before)
            draft.question = "Corrected question"
            try draft.save(session: session, in: &document) { copy, content in
                try create(&copy, content, row: row, schedule: schedule)
            }
            XCTAssertNotNil(draft.savedID)
        }
    }

    func testChangedDrawingsReopenedAndRevokedSessionsKeepDraftButCannotSave() async throws {
        let (original, request, row) = try await fixture()
        let selection = DrawingReviewSelection(document: original, value: row)
        var changed = original, revoked = original
        revoked.invalidatePendingEdits()
        let extra = try XCTUnwrap(Bundle.module.url(forResource: "DrawingIntake", withExtension: "pdf", subdirectory: "Fixtures"))
        try changed.addDrawings(await DrawingIngestor().ingest(url: extra, ocr: .disabled))
        let reopened = try LoadSightDocument(wrapper: original.wrapper(asPackage: true))
        for variant in [changed, revoked, reopened] {
            var document = variant
            var review = EquipmentScheduleReviewState(request: request, selected: selection)
            var draft = filledDraft(); let text = draft
            let before = try document.project.data()
            review.invalidateResults()
            let retained = try XCTUnwrap(review.selected)
            XCTAssertEqual(retained.id, selection.id)
            XCTAssertEqual(retained.value, row)
            XCTAssertEqual(retained.session.drawings, original.drawings)
            XCTAssertFalse(draft.canSave(session: retained.session, in: document))
            XCTAssertTrue(draft.canEdit && draft.isDirty, "Keep notes editable/copyable until explicit discard.")
            XCTAssertThrowsError(try draft.save(session: retained.session, in: &document) { _, _ in
                XCTFail("Stale source must be rejected before entering either composer mutation")
                return "wrong-source"
            })
            XCTAssertEqual(draft, text)
            XCTAssertEqual(try document.project.data(), before)
        }
    }

    func testLateFailureOrMissingIdentityRollsBackDocumentAndRetainsDraft() async throws {
        for schedule in [true, false] {
            for missingIdentity in [true, false] {
                var (document, _, row) = try await fixture()
                let session = DrawingReviewSession(document: document), before = try document.project.data()
                var draft = filledDraft(); let text = draft
                var entered = false
                XCTAssertThrowsError(try draft.save(session: session, in: &document) { copy, content in
                    _ = try create(&copy, content, row: row, schedule: schedule)
                    entered = true
                    if missingIdentity { return "" }
                    throw LoadSightError.invalid("Injected failure after saving RFI/evidence into the transaction")
                })
                XCTAssertTrue(entered)
                XCTAssertEqual(draft, text)
                XCTAssertEqual(try document.project.data(), before)
                XCTAssertTrue(draft.canSave(session: session, in: document))
            }
        }
        XCTAssertFalse(SourceRFIDraft().isDirty)
    }
}
