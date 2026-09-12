import XCTest
import LoadSightKit
@testable import LoadSightUI

@MainActor final class ScheduleMapStorageTests: XCTestCase {
    private func fixture() async throws -> (DrawingArchive, EquipmentScheduleRequest) {
        let pdf = Bundle.module.url(forResource: "EquipmentSchedule", withExtension: "pdf", subdirectory: "Fixtures")!
        let map = Bundle.module.url(forResource: "EquipmentScheduleMapping", withExtension: "json", subdirectory: "Fixtures")!
        return (try await DrawingIngestor().ingest(url: pdf, ocr: .disabled), try EquipmentScheduleRequest.decode(Data(contentsOf: map)))
    }
    func testNativePackageAndJSONRetainMapHistoryOriginalsAndUnknownQuantities() async throws {
        let (archive, request) = try await fixture()
        var document = try LoadSightDocument(project: LoadSightTests().readyProject())
        try document.addDrawings(archive)
        let before = document.project.items, oldQA = try document.project.qaFingerprint()
        let id = try document.project.saveScheduleMap(name: "Roof equipment", request: request, drawings: archive, expectedFingerprint: document.project.scheduleMapEditFingerprint(), author: "Estimator", reason: "Mapped the supplied schedule headers")
        XCTAssertEqual(document.project.items, before)
        XCTAssertNotEqual(try document.project.qaFingerprint(), oldQA)
        XCTAssertTrue(document.project.root["qa"].array!.allSatisfy { $0["status"].string == "Open" })
        for package in [true, false] {
            let reopened = try LoadSightDocument(wrapper: document.wrapper(asPackage: package))
            XCTAssertEqual(try reopened.project.scheduleMaps().first?.id, id)
            XCTAssertEqual(try reopened.project.scheduleMapHistory().count, 1)
            XCTAssertEqual(reopened.drawings, archive)
            XCTAssertEqual(reopened.project.items, before)
            XCTAssertEqual(try EquipmentScheduleExtractor.extract(reopened.drawings, request: reopened.project.scheduleMaps()[0].columnMap()).rows.count, 3)
        }
    }
    func testRevisionRemovalAndStaleEditRejectWithoutLosingHistory() async throws {
        let (archive, request) = try await fixture()
        var project = try LoadSightTests().readyProject()
        let stale = try project.scheduleMapEditFingerprint()
        let id = try project.saveScheduleMap(name: "Original map", request: request, drawings: archive, expectedFingerprint: stale, author: "Mapper", reason: "Initial mapping")
        let first = try project.data()
        XCTAssertThrowsError(try project.saveScheduleMap(id: id, name: "Stale update", request: request, drawings: archive, expectedFingerprint: stale, author: "Other", reason: "Stale change"))
        XCTAssertEqual(try project.data(), first)
        var revised = request; revised.regions[0].columns[2].minX = 325
        try project.saveScheduleMap(id: id, name: "Corrected map", request: revised, drawings: archive, expectedFingerprint: project.scheduleMapEditFingerprint(), author: "Checker", reason: "Correct left airflow boundary")
        let history = try project.scheduleMapHistory()
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(try ProjectDocument.decodeScheduleMaps(history[1].before)[0].columnMap().regions[0].columns[2].minX, 320)
        XCTAssertEqual(try project.scheduleMaps()[0].columnMap().regions[0].columns[2].minX, 325)
        try project.removeScheduleMap(id: id, drawings: archive, expectedFingerprint: project.scheduleMapEditFingerprint(), author: "Checker", reason: "Remove superseded working map")
        XCTAssertTrue(try project.scheduleMaps().isEmpty)
        XCTAssertEqual(try project.scheduleMapHistory().count, 3)
        XCTAssertEqual(try ProjectDocument.decodeScheduleMaps(project.scheduleMapHistory()[2].before)[0].name, "Corrected map")
    }
    func testHistoryForgeryAndMissingDrawingFailLoading() async throws {
        let (archive, request) = try await fixture()
        var project = try LoadSightTests().readyProject()
        try project.saveScheduleMap(name: "Schedule", request: request, drawings: archive, expectedFingerprint: project.scheduleMapEditFingerprint(), author: "Mapper", reason: "Header review")
        var raw = project.root.object!; var maps = raw["scheduleMaps"]!.array!; var map = maps[0].object!
        map["name"] = .string("Forged current map"); maps[0] = .object(map); raw["scheduleMaps"] = .array(maps)
        XCTAssertThrowsError(try ProjectDocument(data: JSONEncoder().encode(raw)))
        XCTAssertThrowsError(try LoadSightDocument(project: project)) // No embedded or supplied originals.
        try project.replace("nativeDrawings", with: archive.projectJSON())
        XCTAssertNoThrow(try LoadSightDocument(project: project))
    }
    func testInvalidOrUnauthoredMapSaveIsAtomic() async throws {
        let (archive, original) = try await fixture()
        var project = try LoadSightTests().readyProject(); let before = try project.data()
        for variant in 0..<4 {
            var request = original
            if variant == 0 { request.regions[0].columns[1].minX = 0 }
            if variant == 1 { request.regions[0].pageID = "missing" }
            XCTAssertThrowsError(try project.saveScheduleMap(name: variant == 2 ? " " : "Map", request: request, drawings: archive, expectedFingerprint: project.scheduleMapEditFingerprint(), author: variant == 3 ? " " : "Mapper", reason: "Mapped headers"))
            XCTAssertEqual(try project.data(), before)
        }
    }
    func testColdRecoveryRestoresSavedMapsAndTheirHistory() async throws {
        let (archive, request) = try await fixture()
        var project = try LoadSightTests().readyProject()
        try project.saveScheduleMap(name: "Recoverable map", request: request, drawings: archive, expectedFingerprint: project.scheduleMapEditFingerprint(), author: "Mapper", reason: "Recovery fixture")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScheduleMapRecovery-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let store = WorkspaceRecoveryStore(directory: folder)
        _ = try await store.save(project: project, drawings: archive, scope: "synthetic-account", expectedRevision: nil)
        let restoredDraft = try await WorkspaceRecoveryStore(directory: folder).load(scope: "synthetic-account")
        let document = try LoadSightDocument(recoveryDraft: XCTUnwrap(restoredDraft))
        XCTAssertEqual(document.project.root["scheduleMaps"], project.root["scheduleMaps"])
        XCTAssertEqual(document.project.root["scheduleMapHistory"], project.root["scheduleMapHistory"])
        XCTAssertEqual(document.drawings.files, archive.files)
    }
    func testDraftCapturedBoundsAndSourceChangeDoNotReuseOldGeometry() async throws {
        let (archive, request) = try await fixture()
        var draft = ScheduleMapDraft(drawings: archive, name: "Map", request: request)
        draft.regions[0].setBody(.init(x: 520, y: 680), .init(x: 40, y: 520))
        XCTAssertEqual(try draft.request(author: "Mapper").regions[0].bodyBounds, request.regions[0].bodyBounds)
        draft.regions[0].changeSource(archive.records[0])
        XCTAssertThrowsError(try draft.request(author: "Mapper"))
        XCTAssertTrue(draft.regions[0].columns.allSatisfy { $0.minX.isEmpty && $0.maxX.isEmpty && $0.header.isEmpty && $0.unit.isEmpty })
        XCTAssertTrue(draft.regions[0].basis.isEmpty)
    }
}
