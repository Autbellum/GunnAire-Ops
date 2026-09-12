import XCTest
import LoadSightKit

@MainActor final class ScheduleMapCommandTests: XCTestCase {
    private func fixture() async throws -> (ProjectDocument, JSONValue) {
        let pdf = try XCTUnwrap(Bundle.module.url(forResource: "EquipmentSchedule", withExtension: "pdf", subdirectory: "Fixtures"))
        let mapping = try XCTUnwrap(Bundle.module.url(forResource: "EquipmentScheduleMapping", withExtension: "json", subdirectory: "Fixtures"))
        let drawings = try await DrawingIngestor().ingest(url: pdf, ocr: .disabled)
        var project = try LoadSightTests().readyProject()
        try project.replace("nativeDrawings", with: drawings.projectJSON())
        let raw = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: mapping))
        let command: JSONValue = .object(["operation": .string("schedule.map.save"), "id": .null,
            "author": .string("Estimator"), "name": .string("Roof schedule"), "request": raw,
            "expectedFingerprint": .string(try project.scheduleMapEditFingerprint()), "reason": .string("Mapped fixture headers")])
        return (project, command)
    }

    func testPortableSaveReviseReadAndRemoveCommandsPreserveHistoryAndOriginals() async throws {
        let (original, command) = try await fixture()
        let before = try original.data()
        let created = try ProjectEditing.apply(command, to: original)
        let id = try XCTUnwrap(created.recordID)
        let reopened = try ProjectDocument(data: created.project.data())
        let map = try XCTUnwrap(reopened.scheduleMaps().first)
        XCTAssertEqual(map.id.uuidString, id)
        let archive = try DrawingArchive(projectJSON: reopened.root["nativeDrawings"])
        XCTAssertEqual(try EquipmentScheduleExtractor.extract(archive, request: map.columnMap()).rows.count, 3)
        var update = try XCTUnwrap(command.object)
        update["id"] = .string(id); update["name"] = .string("Corrected roof schedule")
        update["reason"] = .string("Correct label after source review")
        update["expectedFingerprint"] = .string(try reopened.scheduleMapEditFingerprint())
        let revised = try ProjectEditing.apply(.object(update), to: reopened)
        let removal: JSONValue = .object(["operation": .string("schedule.map.remove"), "id": .string(id),
            "author": .string("Checker"), "reason": .string("Superseded map"),
            "expectedFingerprint": .string(try revised.project.scheduleMapEditFingerprint())])
        let removed = try ProjectEditing.apply(removal, to: revised.project)
        XCTAssertEqual(removed.recordID, id)
        XCTAssertTrue(try removed.project.scheduleMaps().isEmpty)
        XCTAssertEqual(try removed.project.scheduleMapHistory().count, 3)
        XCTAssertEqual(removed.project.root["nativeDrawings"], original.root["nativeDrawings"])
        XCTAssertEqual(removed.project.items, original.items)
        XCTAssertEqual(try original.data(), before)
        XCTAssertThrowsError(try ProjectEditing.apply(command, to: created.project))
        XCTAssertThrowsError(try ProjectEditing.apply(removal, to: removed.project))
    }

    func testMalformedSaveCommandsRejectWithoutChangingProject() async throws {
        let (project, command) = try await fixture()
        let before = try project.data()
        for variant in 0..<6 {
            var raw = try XCTUnwrap(command.object)
            switch variant {
            case 0: raw.removeValue(forKey: "id")
            case 1: raw["id"] = .string("not-a-uuid")
            case 2: raw["autor"] = .string("Misspelled")
            case 3: raw["author"] = .string(" ")
            case 4: raw["expectedFingerprint"] = .string("stale")
            default:
                var request = try XCTUnwrap(raw["request"]?.object)
                request["columnz"] = .array([]); raw["request"] = .object(request)
            }
            XCTAssertThrowsError(try ProjectEditing.apply(.object(raw), to: project), "Variant \(variant)")
            XCTAssertEqual(try project.data(), before)
        }
    }

    func testTextRFICommandUsesCurrentSourceIdentityWithoutCreatingEquipment() async throws {
        let (project, _) = try await fixture()
        let archive = try DrawingArchive(projectJSON: project.root["nativeDrawings"])
        let candidate = try XCTUnwrap(MechanicalTextExtractor.extract(archive).candidates.first)
        var command: [String: JSONValue] = ["operation": .string("text.rfi.create"),
            "candidateID": .string(candidate.id), "question": .string("Clarify this equipment occurrence"),
            "impact": .string("Count remains unknown"), "author": .string("Technician")]
        let created = try ProjectEditing.apply(.object(command), to: project)
        let id = try XCTUnwrap(created.recordID)
        let rfi = try XCTUnwrap(created.project.root["rfis"].array?.first { $0["id"].string == id })
        XCTAssertEqual(rfi["status"].string, "Open")
        XCTAssertTrue(rfi["source"].string?.contains(candidate.id) == true)
        XCTAssertEqual(created.project.items, project.items)
        XCTAssertEqual(created.project.root["nativeDrawings"], project.root["nativeDrawings"])
        let before = try project.data()
        command["candidateID"] = .string("unknown-source-candidate")
        XCTAssertThrowsError(try ProjectEditing.apply(.object(command), to: project))
        XCTAssertEqual(try project.data(), before)
    }
}
