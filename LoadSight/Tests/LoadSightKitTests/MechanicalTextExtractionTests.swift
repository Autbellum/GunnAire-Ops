import XCTest
import CryptoKit
import LoadSightKit

@MainActor final class MechanicalTextExtractionTests: XCTestCase {
    private func fixture() async throws -> DrawingArchive {
        let url = Bundle.module.url(forResource: "DrawingIntake", withExtension: "pdf", subdirectory: "Fixtures")!
        return try await DrawingIngestor().ingest(url: url, ocr: .disabled)
    }
    func synthetic(_ text: String, confidence: Double = 1) async throws -> DrawingArchive {
        let original = try await fixture()
        var record = original.records[0], anchor = record.pages[0].text[0]
        anchor.text = text; anchor.confidence = confidence
        record.pages[0].text = [anchor]
        for index in 1..<record.pages.count { record.pages[index].text = [] }
        var archive = DrawingArchive(); try archive.insert(record: record, data: original.files[record.id]!)
        return archive
    }
    func testOriginalPDFAirflowRetainsExactSourceAndNoMutation() async throws {
        let archive = try await fixture(), original = archive
        let service: any LoadSightServicing = LocalLoadSightService()
        let result = try await service.extractMechanicalText(archive, progress: { _ in })
        XCTAssertEqual(result.pageCount, 3)
        XCTAssertTrue(result.candidates.contains { $0.kind == .airflow })
        for candidate in result.candidates { try candidate.validate(in: archive) }
        XCTAssertEqual(archive, original)
        XCTAssertTrue(result.limitations.contains { $0.contains("not physical quantities") })
    }
    func testUnicodeRangesSignsThousandsAndRepeatedTagsStayOccurrences() async throws {
        let archive = try await synthetic("🌀 RTU-1 1,200 CFM; RTU-1 -50 CFM; 40 MBH; 12,000 BTU/HR; 1,2 CFM")
        let result = try MechanicalTextExtractor.extract(archive)
        XCTAssertEqual(result.candidates.filter { $0.kind == .equipmentTag }.map(\.matchedText), ["RTU-1", "RTU-1"])
        XCTAssertEqual(result.candidates.filter { $0.kind == .airflow }.map(\.matchedText), ["1,200 CFM", "-50 CFM"])
        XCTAssertEqual(result.candidates.filter { $0.kind == .thermalRating }.map(\.matchedText), ["40 MBH", "12,000 BTU/HR"])
        XCTAssertEqual(Set(result.candidates.map(\.id)).count, 6)
        let first = result.candidates[0]
        XCTAssertEqual(first.utf16Location, 3)
        XCTAssertEqual(try MechanicalTextExtractor.extract(archive).candidates, result.candidates)
        // Independent v1 recipe: saved RFI references may already contain these identities.
        for candidate in result.candidates {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let anchor = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(candidate.anchor))
            let identity: JSONValue = .object(["method": .string("Mechanical text occurrences v1"), "source": .string(candidate.sourceID), "page": .string(candidate.pageID), "anchor": anchor, "coordinates": .string(candidate.coordinateSpace), "kind": .string(candidate.kind.rawValue), "offset": .number(Double(candidate.utf16Location)), "length": .number(Double(candidate.utf16Length))])
            let id = SHA256.hash(data: try encoder.encode(identity)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(candidate.id, id)
            try candidate.validate(in: archive)
        }
    }
    func testConfidenceAndUnrecognizedInputsDoNotBecomeVerifiedZero() async throws {
        let low = try await synthetic("EF-2 250 CFM", confidence: 0.4)
        let result = try MechanicalTextExtractor.extract(low)
        XCTAssertTrue(result.candidates.allSatisfy(\.needsRecognitionCheck))
        let none = try await synthetic("Floor 1200; 15 volts; 2 tons hoist; ABC-1")
        XCTAssertTrue(try MechanicalTextExtractor.extract(none).candidates.isEmpty)
    }
    func testChangedRecognitionOrForgedRangeRejectsCandidate() async throws {
        let archive = try await synthetic("RTU-1 1200 CFM")
        let candidate = try XCTUnwrap(MechanicalTextExtractor.extract(archive).candidates.first)
        let changed = try await synthetic("RTU-2 1200 CFM")
        XCTAssertThrowsError(try candidate.validate(in: changed))
        var raw = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(candidate)).object!
        raw["utf16Location"] = .number(99)
        let forged = try JSONDecoder().decode(MechanicalTextCandidate.self, from: JSONEncoder().encode(raw))
        XCTAssertThrowsError(try forged.validate(in: archive))
    }
    func testRFIHandoffPreservesAnchorAndDoesNotCreateTakeoffQuantity() async throws {
        let archive = try await synthetic("AHU-1 1200 CFM")
        let candidate = try XCTUnwrap(MechanicalTextExtractor.extract(archive).candidates.first)
        var project = try LoadSightTests().readyProject(); let items = project.items
        let id = try project.createRFI(from: candidate, drawings: archive, question: "Confirm applicability of the repeated tag.", impact: "Quantity remains unknown pending review.", author: "Recorder")
        let row = try XCTUnwrap(project.root["rfis"].array!.first { $0["id"].string == id })
        XCTAssertEqual(row["status"], .string("Open"))
        XCTAssertTrue(row["source"].string!.contains(candidate.id))
        XCTAssertTrue(row["source"].string!.contains(candidate.sourceID))
        XCTAssertEqual(project.items, items)
        XCTAssertTrue(project.root["qa"].array!.allSatisfy { $0["status"].string == "Open" })
        let before = try project.data()
        XCTAssertThrowsError(try project.createRFI(from: candidate, drawings: .init(), question: "Question", impact: "Impact", author: "Recorder"))
        XCTAssertEqual(try project.data(), before)
    }

    func testSelectedOccurrenceValidatesWithoutRebuildingAllSiblingIdentities() async throws {
        let archive = try await synthetic(String(repeating: "RTU-1 1200 CFM ", count: 500))
        let output = try MechanicalTextExtractor.extract(archive)
        XCTAssertEqual(output.candidates.count, 1000)
        let selected = try XCTUnwrap(output.candidates.last)
        let start = Date.timeIntervalSinceReferenceDate
        try selected.validate(in: archive)
        print("Single-candidate validation with 1,000 sibling occurrences: \(Date.timeIntervalSinceReferenceDate - start)s")
        let raw = try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(selected)).object)
        for (field, value) in [("utf16Location", JSONValue.number(Double(Int.max / 2))), ("utf16Length", .number(-1)), ("matchedText", .string("Forged text")), ("kind", .string("thermalRating")), ("coordinateSpace", .string("Other coordinates")), ("id", .string("forged"))] {
            var changed = raw; changed[field] = value
            let forged = try JSONDecoder().decode(MechanicalTextCandidate.self, from: JSONEncoder().encode(changed))
            XCTAssertThrowsError(try forged.validate(in: archive), field)
        }
    }

    func testCancelledExtractionAndValidationDoNotReturnEvidence() async throws {
        let archive = try await synthetic("AHU-1 1200 CFM")
        let candidate = try XCTUnwrap(MechanicalTextExtractor.extract(archive).candidates.first)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertThrowsError(try MechanicalTextExtractor.extract(archive)) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertThrowsError(try candidate.validate(in: archive)) { XCTAssertTrue($0 is CancellationError) }
        }
        try await task.value
    }

    func testDirectServiceHonorsCancellationFromLastPageProgress() async throws {
        let archive = try await synthetic("RTU-1 1200 CFM")
        let task = Task {
            do {
                _ = try await LocalLoadSightService().extractMechanicalText(archive) { event in
                    if event.completedUnits == event.totalUnits { withUnsafeCurrentTask { $0?.cancel() } }
                }
                XCTFail("Cancelled service returned extraction evidence")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        await task.value
    }
}
