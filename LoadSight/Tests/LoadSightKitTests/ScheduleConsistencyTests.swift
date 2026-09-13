import XCTest
import LoadSightKit

@MainActor final class ScheduleConsistencyTests: XCTestCase {
    private func row(_ values: [(EquipmentScheduleField, String?, String?)], confidence: Double = 1, partial: Bool = false) async throws -> EquipmentScheduleRow {
        let pdf = Bundle.module.url(forResource: "EquipmentSchedule", withExtension: "pdf", subdirectory: "Fixtures")!
        let map = Bundle.module.url(forResource: "EquipmentScheduleMapping", withExtension: "json", subdirectory: "Fixtures")!
        let archive = try await DrawingIngestor().ingest(url: pdf, ocr: .disabled)
        let seed = try EquipmentScheduleExtractor.extract(archive, request: .decode(Data(contentsOf: map))).rows[0]
        var raw = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(seed)).object!
        // Controlled synthetic review inputs; not a claim these altered values came from the PDF.
        raw["cells"] = .array(values.map { field, text, unit in
            var cell: [String: JSONValue] = ["field": .string(field.rawValue), "evidence": .array([])]
            if let text {
                cell["text"] = .string(text)
                cell["evidence"] = .array([.object(["id": .string(field.rawValue), "text": .string(text), "method": .string("Synthetic fixture"), "confidence": .number(confidence), "bounds": .object(["x": .number(1), "y": .number(1), "width": .number(10), "height": .number(10)])])])
            }
            if let unit { cell["unitText"] = .string(unit) }
            return .object(cell)
        })
        raw["warnings"] = .array(partial ? [.string(EquipmentScheduleExtractor.partialRowWarning)] : [])
        return try JSONDecoder().decode(EquipmentScheduleRow.self, from: JSONEncoder().encode(raw))
    }
    func testOriginalPDFContainsConflictMissingAndNoConflictCases() async throws {
        let pdf = Bundle.module.url(forResource: "ConsistencySchedule", withExtension: "pdf", subdirectory: "Fixtures")!
        let map = Bundle.module.url(forResource: "ConsistencyScheduleMapping", withExtension: "json", subdirectory: "Fixtures")!
        let archive = try await DrawingIngestor().ingest(url: pdf, ocr: .disabled), before = archive
        let result = try EquipmentScheduleExtractor.extract(archive, request: .decode(Data(contentsOf: map)))
        XCTAssertEqual(result.consistencyReview.map { $0.checks.first { $0.id == "airflow.outdoorTotal" }!.status }, [.needsReview, .unresolved, .noConflict])
        XCTAssertEqual(result.consistencyReview.map(\.rowID), result.rows.map(\.id))
        XCTAssertEqual(result.rows[0].cells.first { $0.field == .outdoorAir }?.text, "1,800")
        XCTAssertEqual(archive, before)
        for row in result.rows { try row.validate(in: archive) }
    }
    func testMissingColumnsAndMissingCellsAreDistinct() async throws {
        let review = try await row([(.minimumCircuitAmpacity, nil, "A")]).consistencyReview
        let mca = try XCTUnwrap(review.checks.first { $0.id == "coordination.minimumCircuitAmpacity" })
        let mop = try XCTUnwrap(review.checks.first { $0.id == "coordination.maximumOvercurrentProtection" })
        XCTAssertEqual(mca.status, .missing); XCTAssertTrue(mca.detail.contains("Mapped cell"))
        XCTAssertEqual(mop.status, .missing); XCTAssertTrue(mop.detail.contains("Column not mapped"))
        XCTAssertEqual(review.checks.first { $0.id == "cooling.sensibleTotal" }?.status, .unresolved)
    }
    func testMixedUnitsFindConditionalConflicts() async throws {
        let review = try await row([(.coolingSensible, "12", "kW"), (.coolingTotal, "10000", "W"), (.outdoorAir, "600", "L/s"), (.airflow, "1200", "CFM")]).consistencyReview
        for id in ["cooling.sensibleTotal", "airflow.outdoorTotal"] {
            let check = try XCTUnwrap(review.checks.first { $0.id == id })
            XCTAssertEqual(check.status, .needsReview); XCTAssertEqual(check.values.count, 2)
            XCTAssertTrue(check.detail.contains("same"))
        }
    }
    func testNoConflictIsNotAnApprovalAndZeroIsNotMissing() async throws {
        let review = try await row([(.coolingSensible, "10", "kW"), (.coolingTotal, "10000", "W"), (.outdoorAir, "0", "CFM"), (.airflow, "100", "CFM"), (.heatingCapacity, "0", "W")]).consistencyReview
        XCTAssertEqual(review.checks.first { $0.id == "cooling.sensibleTotal" }?.status, .noConflict)
        XCTAssertEqual(review.checks.first { $0.id == "coordination.outdoorAir" }?.status, .recorded)
        XCTAssertEqual(review.checks.first { $0.id == "zero.heatingCapacity" }?.status, .needsReview)
        XCTAssertTrue(review.limitations.contains("No finding proves"))
    }
    func testUnresolvedUnitsCannotSilentlyPassComparisons() async throws {
        let review = try await row([(.coolingSensible, "100", "MBH"), (.coolingTotal, "10", "kW"), (.minimumCircuitAmpacity, "18", nil)]).consistencyReview
        XCTAssertEqual(review.checks.first { $0.id == "cooling.sensibleTotal" }?.status, .unresolved)
        XCTAssertEqual(review.checks.first { $0.id == "coordination.minimumCircuitAmpacity" }?.status, .unresolved)
        XCTAssertEqual(review.checks.first { $0.id == "capacity.coolingSensible" }?.status, .unresolved)
    }
    func testPartialAndLowConfidenceRowsWithholdConclusions() async throws {
        let values: [(EquipmentScheduleField, String?, String?)] = [(.outdoorAir, "1000", "CFM"), (.airflow, "100", "CFM")]
        for (confidence, partial) in [(0.4, false), (1.0, true)] {
            let review = try await row(values, confidence: confidence, partial: partial).consistencyReview
            XCTAssertEqual(review.checks.first { $0.id == "airflow.outdoorTotal" }?.status, .unresolved)
            XCTAssertEqual(review.checks.first { $0.id == "coordination.outdoorAir" }?.status, .unresolved)
        }
    }
    func testRecomputedReviewDoesNotAlterSourceRowAndEncodesStableFindings() async throws {
        let value = try await row([(.weight, "100", "lb")]), before = try JSONEncoder().encode(value)
        let review = value.consistencyReview
        XCTAssertEqual(review, value.consistencyReview)
        XCTAssertEqual(try JSONDecoder().decode(EquipmentScheduleRow.self, from: before), value)
        XCTAssertEqual(Set(review.checks.map(\.id)).count, review.checks.count)
        XCTAssertEqual(try JSONDecoder().decode(ScheduleConsistencyReview.self, from: JSONEncoder().encode(review)), review)
        XCTAssertEqual(review.rowID, value.id)
    }
}
