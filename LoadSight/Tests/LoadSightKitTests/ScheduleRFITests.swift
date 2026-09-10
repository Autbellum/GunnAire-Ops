import XCTest
import LoadSightKit
@testable import LoadSightUI

@MainActor final class ScheduleRFITests: XCTestCase {
    private func fixture() async throws -> (LoadSightDocument, EquipmentScheduleRequest, EquipmentScheduleRow) {
        let pdf = Bundle.module.url(forResource: "ConsistencySchedule", withExtension: "pdf", subdirectory: "Fixtures")!
        let map = Bundle.module.url(forResource: "ConsistencyScheduleMapping", withExtension: "json", subdirectory: "Fixtures")!
        let archive = try await DrawingIngestor().ingest(url: pdf, ocr: .disabled), request = try EquipmentScheduleRequest.decode(Data(contentsOf: map))
        var doc = try LoadSightDocument(project: LoadSightTests().readyProject()); try doc.addDrawings(archive)
        return (doc, request, try EquipmentScheduleExtractor.extract(archive, request: request).rows[0])
    }
    func testNativePackageAndJSONRetainUnansweredRFIAndExactEvidence() async throws {
        var (doc, _, row) = try await fixture(); let items = doc.project.items, drawings = doc.drawings
        let id = try doc.project.createRFI(from: row, findingID: "airflow.outdoorTotal", drawings: doc.drawings, question: "Confirm whether OA and total airflow use the same operating basis.", impact: "Equipment selection remains pending clarification.", author: "Reviewer")
        for package in [true, false] {
            let reopened = try LoadSightDocument(wrapper: doc.wrapper(asPackage: package))
            let rfi = try XCTUnwrap(reopened.project.root["rfis"].array!.first { $0["id"].string == id })
            XCTAssertEqual(rfi["status"].string, "Open"); XCTAssertEqual(rfi["response"].string, "")
            XCTAssertTrue(rfi["source"].string!.contains(row.id)); XCTAssertTrue(rfi["source"].string!.contains("same total airstream"))
            let attachment = try XCTUnwrap(reopened.project.attachments().first { $0.references.contains { $0.rfiID == id } })
            let snapshot = try JSONDecoder().decode(ScheduleRFIEvidence.self, from: attachment.data)
            XCTAssertEqual(snapshot.row, row); XCTAssertEqual(snapshot.finding, row.consistencyReview.checks.first { $0.id == "airflow.outdoorTotal" })
            XCTAssertTrue(rfi["source"].string!.contains(attachment.id))
            XCTAssertEqual(reopened.project.items, items); XCTAssertEqual(reopened.drawings, drawings)
            XCTAssertTrue(reopened.project.root["qa"].array!.allSatisfy { $0["status"].string == "Open" })
        }
    }
    func testInvalidSourceFindingQuestionAndAuthorFailAtomically() async throws {
        var (doc, _, row) = try await fixture(); let before = try doc.project.data()
        for variant in 0..<4 {
            XCTAssertThrowsError(try doc.project.createRFI(from: row, findingID: variant == 0 ? "forged" : "airflow.outdoorTotal", drawings: variant == 1 ? .init() : doc.drawings, question: variant == 2 ? " " : "Question", impact: "Impact", author: variant == 3 ? " " : "Recorder"))
            XCTAssertEqual(try doc.project.data(), before)
        }
    }
    func testStructuredEditReextractsRowAndRejectsStaleAndUnknownKeys() async throws {
        let (doc, map, row) = try await fixture()
        let portable = try LoadSightDocument(wrapper: doc.wrapper(asPackage: false)).project
        var fields: [String: JSONValue] = ["operation": .string("schedule.rfi.create"), "author": .string("Reviewer"), "request": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(map)), "rowID": .string(row.id), "findingID": .string("airflow.outdoorTotal"), "question": .string("Clarify the airflow basis."), "impact": .string("Selection pending.")]
        let result = try ProjectEditing.apply(.object(fields), to: portable)
        XCTAssertNotNil(result.recordID); XCTAssertEqual(try result.project.attachments().count, 1)
        fields["rowID"] = .string("stale"); XCTAssertThrowsError(try ProjectEditing.apply(.object(fields), to: portable))
        fields["rowID"] = .string(row.id); fields["approval"] = .bool(true)
        XCTAssertThrowsError(try ProjectEditing.apply(.object(fields), to: portable))
    }
    func testReplacementDocumentSessionCannotReceiveDraft() async throws {
        let (old, _, row) = try await fixture(); var replacement = LoadSightDocument()
        let before = try replacement.project.data()
        XCTAssertThrowsError(try replacement.applyEdit(for: old.editSessionID) { copy in
            _ = try copy.project.createRFI(from: row, findingID: "airflow.outdoorTotal", drawings: old.drawings, question: "Question", impact: "Impact", author: "Reviewer")
        })
        XCTAssertEqual(try replacement.project.data(), before)
    }

    func testIdenticalEvidenceRetainsSeparateQuestionsAuthorsAndLinks() async throws {
        var (doc, _, row) = try await fixture()
        var ids: [String] = []
        for author in ["Field technician", "Office reviewer"] {
            ids.append(try doc.project.createRFI(from: row, findingID: "airflow.outdoorTotal", drawings: doc.drawings,
                question: "Clarify basis for " + author, impact: "Selection pending", author: author))
        }
        XCTAssertNotEqual(ids[0], ids[1])
        for package in [true, false] {
            let reopened = try LoadSightDocument(wrapper: doc.wrapper(asPackage: package))
            let attachments = try reopened.project.attachments()
            XCTAssertEqual(attachments.count, 1, "Identical snapshot bytes may be stored once, not the RFI links.")
            let evidence = try XCTUnwrap(attachments.first)
            XCTAssertEqual(evidence.references.map(\.rfiID), ids.map(Optional.some))
            XCTAssertEqual(evidence.references.map(\.author), ["Field technician", "Office reviewer"])
            XCTAssertEqual(evidence.id, ProjectAttachment.fingerprint(evidence.data))
            for id in ids {
                let rfi = try XCTUnwrap(reopened.project.root["rfis"].array?.first { $0["id"].string == id })
                XCTAssertEqual(rfi["status"].string, "Open")
                XCTAssertTrue(rfi["source"].string?.contains(evidence.id) == true)
                XCTAssertEqual(reopened.project.root["rfiHistory"].array?.filter { $0["rfiID"].string == id }.count, 1)
            }
        }
    }

    func testFailureAfterEvidenceCreationRollsBackRFIHistoryAttachmentsAndQA() async throws {
        var (doc, _, row) = try await fixture()
        let session = DrawingReviewSession(document: doc), before = try doc.project.data(), drawings = doc.drawings
        var reachedEvidence = false
        XCTAssertThrowsError(try session.apply(to: &doc) { copy in
            let id = try copy.project.createRFI(from: row, findingID: "airflow.outdoorTotal", drawings: copy.drawings,
                question: "Clarify basis", impact: "Selection pending", author: "Technician")
            reachedEvidence = try copy.project.attachments().contains { $0.references.contains { $0.rfiID == id } }
            throw LoadSightError.invalid("Injected failure after creating RFI and evidence")
        })
        XCTAssertTrue(reachedEvidence, "Exercise a late failure, not just invalid draft fields.")
        XCTAssertEqual(try doc.project.data(), before)
        XCTAssertEqual(doc.drawings, drawings)
        XCTAssertTrue(session.matches(doc))
    }

    func testCapturedScheduleSelectionRejectsReopenedRevokedAndChangedDrawingSessions() async throws {
        let (original, _, row) = try await fixture()
        let selection = DrawingReviewSelection(document: original, value: row)
        var reopened = try LoadSightDocument(wrapper: original.wrapper(asPackage: true))
        var revoked = original; revoked.invalidatePendingEdits()
        var changed = original
        let extra = try XCTUnwrap(Bundle.module.url(forResource: "DrawingIntake", withExtension: "pdf", subdirectory: "Fixtures"))
        try changed.addDrawings(await DrawingIngestor().ingest(url: extra, ocr: .disabled))
        for variant in [reopened, revoked, changed] {
            var document = variant
            let before = try document.project.data(), drawings = document.drawings
            var enteredMutation = false
            XCTAssertThrowsError(try selection.session.apply(to: &document) { copy in
                enteredMutation = true
                _ = try copy.project.createRFI(from: row, findingID: "airflow.outdoorTotal", drawings: copy.drawings,
                    question: "Clarify basis", impact: "Selection pending", author: "Technician")
            })
            XCTAssertFalse(enteredMutation)
            XCTAssertEqual(try document.project.data(), before)
            XCTAssertEqual(document.drawings, drawings)
        }
        // A fresh selection must still be usable after a rejected delayed selection.
        let fresh = DrawingReviewSelection(document: reopened, value: row)
        try fresh.session.apply(to: &reopened) { copy in
            _ = try copy.project.createRFI(from: row, findingID: "airflow.outdoorTotal", drawings: copy.drawings,
                question: "Clarify basis", impact: "Selection pending", author: "Technician")
        }
        XCTAssertEqual(try reopened.project.attachments().count, 1)
    }
}
