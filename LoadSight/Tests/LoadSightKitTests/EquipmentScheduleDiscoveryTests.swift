import XCTest
import LoadSightKit

@MainActor final class EquipmentScheduleDiscoveryTests: XCTestCase {
    private func fixture() async throws -> DrawingArchive {
        try await DrawingIngestor().ingest(url: Bundle.module.url(forResource: "EquipmentSchedule", withExtension: "pdf", subdirectory: "Fixtures")!, ocr: .disabled)
    }
    func testPDFDiscoveryNeedsNoMapAndPreservesUnknownCellsAndPhysicalCounts() async throws {
        let archive = try await fixture(), before = archive
        let service: any LoadSightServicing = LocalLoadSightService()
        let result = try await service.discoverEquipmentSchedules(archive, progress: { _ in })
        XCTAssertEqual(result.pageCount, 1)
        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(candidate.headers.compactMap(\.field), [.tag, .manufacturer, .airflow, .minimumCircuitAmpacity])
        XCTAssertEqual(candidate.tagEvidence.map { $0.map(\.text).joined(separator: " ") }, ["RTU-1", "EF-2", "RTU-1"])
        XCTAssertNil(candidate.headers.last?.unitText, "MCA does not transcribe a literal A header unit")
        let request = try await service.prepareDiscoveredSchedule(candidate, drawings: archive)
        let rows = try EquipmentScheduleExtractor.extract(archive, request: request).rows
        XCTAssertEqual(rows.map(\.tag), ["RTU-1", "EF-2", "RTU-1"])
        XCTAssertEqual(rows[0].cells.first { $0.field == .manufacturer }?.text, "Example Co")
        XCTAssertEqual(rows[0].cells.first { $0.field == .airflow }?.text, "1,200")
        XCTAssertNil(rows[1].cells.first { $0.field == .minimumCircuitAmpacity }?.text)
        XCTAssertEqual(archive, before)
        XCTAssertEqual(try EquipmentScheduleDiscoverer.discover(archive).candidates, result.candidates)
        XCTAssertTrue(result.limitations.contains { $0.contains("never physical") })
    }
    func testForgedAndChangedCandidatesCannotBecomeMapDrafts() async throws {
        let archive = try await fixture()
        let candidate = try XCTUnwrap(EquipmentScheduleDiscoverer.discover(archive).candidates.first)
        var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate)) as! [String: Any]
        raw["filename"] = "different.pdf"
        let changed = try JSONDecoder().decode(EquipmentScheduleCandidate.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertThrowsError(try changed.draftRequest(in: archive))
        XCTAssertThrowsError(try candidate.draftRequest(in: .init()))
        XCTAssertEqual(try JSONDecoder().decode(EquipmentScheduleCandidate.self, from: JSONEncoder().encode(candidate)), candidate)
    }
    func testUnknownAndDuplicateHeadersRemainUnmappedAcrossSeparateTables() async throws {
        let original = try await fixture()
        var record = original.records[0]
        var entries: [[String: Any]] = []
        func word(_ text: String, _ x: Double, _ y: Double, width: Double = 40) {
            entries.append(["id": "synthetic-\(entries.count)", "text": text,
                "bounds": ["x": x, "y": y, "width": width, "height": 12], "method": "Synthetic OCR", "confidence": 0.5])
        }
        for (y, second, third) in [(700.0, "UNRECOGNIZED", "cfm"), (450.0, "CFM", "CFM")] {
            word("TAG", 50, y); word(second, 180, y, width: 110); word(third, 340, y); word("MCA", 450, y)
            for row in 1...2 { word("EF-\(row)", 50, y-Double(row)*50); word("250", 340, y-Double(row)*50) }
        }
        record.pages[0].text = try JSONDecoder().decode([DrawingText].self, from: JSONSerialization.data(withJSONObject: entries))
        var archive = DrawingArchive(); try archive.insert(record: record, data: original.files[record.id]!)
        let result = try EquipmentScheduleDiscoverer.discover(archive)
        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertNil(result.candidates[0].headers[1].field)
        XCTAssertEqual(result.candidates[0].headers[2].unitText, "cfm")
        XCTAssertEqual(result.candidates[0].proposedRegion.columns.map(\.field), [.tag, .airflow, .minimumCircuitAmpacity])
        XCTAssertEqual(result.candidates[1].proposedRegion.columns.map(\.field), [.tag, .minimumCircuitAmpacity])
        XCTAssertTrue(result.candidates.allSatisfy { $0.tagEvidence.count == 2 && $0.warnings.contains { $0.contains("Low recognition") } })
        XCTAssertTrue(result.candidates[1].warnings.contains { $0.contains("ambiguous") })
        var rotated = record; rotated.pages[0].rotation = 90
        var rotatedArchive = DrawingArchive(); try rotatedArchive.insert(record: rotated, data: original.files[record.id]!)
        let held = try EquipmentScheduleDiscoverer.discover(rotatedArchive)
        XCTAssertTrue(held.candidates.isEmpty); XCTAssertTrue(held.warnings.contains { $0.contains("rotated") })
    }
    func testCancellationAtLastPageDoesNotReturnCandidates() async throws {
        let archive = try await fixture()
        let task = Task {
            try EquipmentScheduleDiscoverer.discover(archive) { done, total in
                if done == total { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await task.value; XCTFail("Cancelled discovery returned candidates") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testAdjacentTablesKeepSeparateTagRowsAndBounds() async throws {
        let original = try await fixture(); var record = original.records[0]
        var entries: [[String: Any]] = []
        for (offset, prefix) in [(0.0, "EF"), (300.0, "RTU")] {
            for (text, x, y) in [("TAG", 20.0, 700.0), ("CFM", 100, 700), ("MCA", 200, 700),
                                 (prefix+"-1", 20, 650), ("250", 100, 650), (prefix+"-2", 20, 600), ("300", 100, 600)] {
                entries.append(["id": "side-\(entries.count)", "text": text,
                    "bounds": ["x": x+offset, "y": y, "width": 40, "height": 12], "method": "Synthetic anchors", "confidence": 1])
            }
        }
        record.pages[0].text = try JSONDecoder().decode([DrawingText].self, from: JSONSerialization.data(withJSONObject: entries))
        var archive = DrawingArchive(); try archive.insert(record: record, data: original.files[record.id]!)
        let result = try EquipmentScheduleDiscoverer.discover(archive)
        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertEqual(result.candidates.map { $0.tagEvidence.map { $0.map(\.text).joined(separator: " ") } }, [["EF-1", "EF-2"], ["RTU-1", "RTU-2"]])
        XCTAssertFalse(result.candidates[0].proposedRegion.bodyBounds.rect.intersects(result.candidates[1].proposedRegion.bodyBounds.rect))
    }
    func testNoTablesIsExplicitAndCancellationPropagates() async throws {
        let result = try EquipmentScheduleDiscoverer.discover(.init())
        XCTAssertEqual(result.pageCount, 0); XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertTrue(result.warnings.contains { $0.contains("not evidence") })
        let task = Task { try Task.checkCancellation(); return try EquipmentScheduleDiscoverer.discover(.init()) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled discovery returned success") } catch { XCTAssertTrue(error is CancellationError) }
    }
}
