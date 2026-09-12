import XCTest
import LoadSightKit

final class ScheduleDimensionTests: XCTestCase {
    func testReferenceLengthsAndSourceOrdering() throws {
        for (text, unit, expected) in [("24 x 36 x 48", "in", [0.6096,0.9144,1.2192]), ("2 × 3", "ft", [0.6096,0.9144]), ("1000 X 2000", "mm", [1.0,2.0]), ("100 x 200", "cm", [1.0,2.0]), (".25 x 2.5", "m", [0.25,2.5])] {
            let result = ScheduleDimensionInterpreter.interpret(text: text, unitText: unit)
            XCTAssertEqual(result.status, .interpreted); XCTAssertEqual(result.unit, "m")
            let values = try XCTUnwrap(result.components); XCTAssertEqual(values.count, expected.count)
            for (value, reference) in zip(values, expected) { XCTAssertEqual(value, reference, accuracy: 1e-12) }
            XCTAssertTrue(result.explanation.contains("literal source order"))
        }
    }
    func testMissingAndAmbiguousDimensionsReturnNoPartialValues() {
        XCTAssertEqual(ScheduleDimensionInterpreter.interpret(text: nil, unitText: "in").status, .missing)
        for text in ["24", "24 x", "x 24", "0 x 12", "-1 x 12", "24-36 x 48", "24 1/2 x 36", "24 in x 36 in", "24W x 36H", "NaN x 24", "1,200 x 2400", "1 x 2 x 3 x 4", "24 x 36*"] {
            let result = ScheduleDimensionInterpreter.interpret(text: text, unitText: "in")
            XCTAssertEqual(result.status, .unresolved, text); XCTAssertNil(result.components); XCTAssertNil(result.factor)
        }
        for unit in [nil, "", "M", "sq ft", "survey ft"] as [String?] {
            XCTAssertEqual(ScheduleDimensionInterpreter.interpret(text: "24 x 36", unitText: unit).status, .unresolved)
        }
    }
    @MainActor func testOriginalPDFDerivedReviewRetainsLiteralRowsAndMissingValues() async throws {
        let pdf = Bundle.module.url(forResource: "DimensionSchedule", withExtension: "pdf", subdirectory: "Fixtures")!
        let map = Bundle.module.url(forResource: "DimensionScheduleMapping", withExtension: "json", subdirectory: "Fixtures")!
        let archive = try await DrawingIngestor().ingest(url: pdf, ocr: .disabled), before = archive
        let result = try EquipmentScheduleExtractor.extract(archive, request: .decode(Data(contentsOf: map)))
        XCTAssertEqual(result.dimensionReview.map { $0.interpretation.status }, [.interpreted, .missing, .unresolved])
        XCTAssertEqual(result.dimensionReview.map(\.rowID), result.rows.map(\.id))
        XCTAssertEqual(result.rows[0].cells.first { $0.field == .dimensions }?.text, "24 x 36 x 48")
        XCTAssertEqual(result.dimensionReview[0].interpretation.components![0], 0.6096, accuracy: 1e-12)
        XCTAssertEqual(archive, before)
        for row in result.rows { try row.validate(in: archive) }
        let decoded = try JSONDecoder().decode(EquipmentScheduleExtraction.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(decoded.dimensionReview, result.dimensionReview)
    }
}
