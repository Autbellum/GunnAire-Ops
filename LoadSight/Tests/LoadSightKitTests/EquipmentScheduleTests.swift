import XCTest
import LoadSightKit

@MainActor final class EquipmentScheduleTests: XCTestCase {
    private func fixture() async throws -> (DrawingArchive, EquipmentScheduleRequest) {
        let pdf = Bundle.module.url(forResource: "EquipmentSchedule", withExtension: "pdf", subdirectory: "Fixtures")!
        let mapping = Bundle.module.url(forResource: "EquipmentScheduleMapping", withExtension: "json", subdirectory: "Fixtures")!
        return (try await DrawingIngestor().ingest(url: pdf, ocr: .disabled), try EquipmentScheduleRequest.decode(Data(contentsOf: mapping)))
    }
    func testOriginalPDFRowsUnitsMissingCellsAndCrossReferences() async throws {
        let (archive, request) = try await fixture(), original = archive
        let service: any LoadSightServicing = LocalLoadSightService()
        let result = try await service.extractEquipmentSchedules(archive, request: request, progress: { _ in })
        XCTAssertEqual(result.rows.map(\.tag), ["RTU-1", "EF-2", "RTU-1"])
        XCTAssertEqual(result.rows[0].cells.first { $0.field == .manufacturer }?.text, "Example Co")
        XCTAssertEqual(result.rows[0].cells.first { $0.field == .airflow }?.text, "1,200")
        XCTAssertEqual(result.rows[0].cells.first { $0.field == .airflow }?.unitText, "CFM")
        XCTAssertNil(result.rows[1].cells.first { $0.field == .minimumCircuitAmpacity }?.text)
        XCTAssertTrue(result.rows[1].cells.first { $0.field == .minimumCircuitAmpacity }!.evidence.isEmpty)
        XCTAssertEqual(result.rows[0].matchingTagOccurrences.map(\.matchedText), ["RTU-1"])
        XCTAssertEqual(result.unmatchedTagOccurrences.map(\.matchedText), ["AHU-9"])
        XCTAssertTrue(result.warnings.contains { $0.contains("Repeated schedule tag RTU-1") })
        XCTAssertTrue(result.unassigned.isEmpty)
        XCTAssertEqual(archive, original)
        XCTAssertEqual(Set(result.rows.map(\.id)).count, 3)
        for row in result.rows { try row.validate(in: archive) }
        XCTAssertEqual(try EquipmentScheduleExtractor.extract(archive, request: request).rows, result.rows)
    }
    func testColumnCrossingDoesNotBorrowOrTruncateValues() async throws {
        let (archive, original) = try await fixture()
        var request = original
        request.regions[0].columns[1].maxX = 215 // 'Co' and 'Inc' cross or fall beyond this boundary.
        let result = try EquipmentScheduleExtractor.extract(archive, request: request)
        XCTAssertEqual(result.rows.count, 3)
        XCTAssertFalse(result.unassigned.isEmpty)
        XCTAssertTrue(result.unassigned.allSatisfy { $0.reason.contains("boundary") })
        // Partial cells are explicitly flagged rather than silently represented as complete.
        XCTAssertTrue(result.rows[0].warnings.contains { $0.contains("unassigned") })
    }
    func testInvalidMappingFailsAtomically() async throws {
        let (archive, valid) = try await fixture()
        for variant in 0..<7 {
            var request = valid
            switch variant {
            case 0: request.regions[0].sourceID = String(repeating: "0", count: 64)
            case 1: request.regions[0].columns[1].minX = 100
            case 2: request.regions[0].columns[0].field = .model
            case 3: request.regions[0].recordedBy = " "
            case 4: request.regions[0].bodyBounds.width = 9999
            case 5: request.regions.append(request.regions[0])
            default: request.schemaVersion = 2
            }
            XCTAssertThrowsError(try EquipmentScheduleExtractor.extract(archive, request: request), "Variant \(variant)")
        }
    }
    func testStrictRequestsRejectTyposAndUnsupportedField() async throws {
        let (_, request) = try await fixture()
        let data = try JSONEncoder().encode(request)
        var root = try JSONDecoder().decode(JSONValue.self, from: data).object!
        root["autor"] = .string("typo")
        XCTAssertThrowsError(try EquipmentScheduleRequest.decode(JSONEncoder().encode(root)))
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "minimumCircuitAmpacity", with: "inventedField")
        XCTAssertThrowsError(try EquipmentScheduleRequest.decode(Data(text.utf8)))
    }
    func testRowForgeryAndChangedOriginalAreRejected() async throws {
        let (archive, request) = try await fixture()
        let row = try XCTUnwrap(EquipmentScheduleExtractor.extract(archive, request: request).rows.first)
        var raw = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(row)).object!
        raw["tag"] = .string("Forged tag")
        let forged = try JSONDecoder().decode(EquipmentScheduleRow.self, from: JSONEncoder().encode(raw))
        XCTAssertThrowsError(try forged.validate(in: archive))
        XCTAssertThrowsError(try row.validate(in: DrawingArchive()))
    }
    func testRecordedAnchorsRetainLowConfidenceAndUnknownUnits() async throws {
        let (original, mapped) = try await fixture()
        var record = original.records[0]
        // Explicit synthetic OCR evidence, not a claim that OCR recognized these cells.
        let raw = """
        [{"id":"tag","text":"EF-2","bounds":{"x":50,"y":600,"width":40,"height":12},"method":"Synthetic OCR","confidence":0.4},
         {"id":"value","text":"0","bounds":{"x":340,"y":600,"width":8,"height":12},"method":"Synthetic OCR","confidence":0.5}]
        """
        record.pages[0].text = try JSONDecoder().decode([DrawingText].self, from: Data(raw.utf8))
        var archive = DrawingArchive(); try archive.insert(record: record, data: original.files[record.id]!)
        var request = mapped; request.regions[0].textMode = .recordedAnchors; request.regions[0].columns[2].unitText = nil
        let result = try EquipmentScheduleExtractor.extract(archive, request: request)
        XCTAssertEqual(result.rows.count, 1)
        let airflow = result.rows[0].cells.first { $0.field == .airflow }!
        XCTAssertEqual(airflow.text, "0"); XCTAssertNil(airflow.unitText)
        XCTAssertTrue(result.rows[0].warnings.contains { $0.contains("Low recognition confidence") })
    }
    func testCancellationAtLastRegionReturnsNoResult() async throws {
        let (archive, request) = try await fixture()
        let operation = Task {
            do {
                _ = try await LocalLoadSightService().extractEquipmentSchedules(archive, request: request) { progress in
                    if progress.completedUnits == progress.totalUnits { withUnsafeCurrentTask { $0?.cancel() } }
                }
                XCTFail("Cancelled extraction returned rows")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        await operation.value
    }
}
