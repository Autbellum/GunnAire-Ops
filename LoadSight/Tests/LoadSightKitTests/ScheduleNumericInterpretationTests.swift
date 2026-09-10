import XCTest
import LoadSightKit

final class ScheduleNumericInterpretationTests: XCTestCase {
    func testFractionalCountsCannotRoundIntoIntegers() {
        for (field, unit) in [(EquipmentScheduleField.quantity, "each"), (.phase, "ph")] {
            for value in ["1.0000000000000001", "0.99999999999999999", "3.00000000000000001"] {
                let result = ScheduleNumericInterpreter.interpret(field: field, text: value, unitText: unit)
                XCTAssertEqual(result.status, .unresolved, value)
                XCTAssertNil(result.value)
            }
        }
        XCTAssertEqual(ScheduleNumericInterpreter.interpret(field: .quantity, text: "9007199254740990.5", unitText: "each").status, .unresolved)
        XCTAssertEqual(ScheduleNumericInterpreter.interpret(field: .quantity, text: "1,200.000", unitText: "each").value, 1200)
        XCTAssertEqual(ScheduleNumericInterpreter.interpret(field: .phase, text: "+3.000", unitText: "ph").value, 3)
    }
    func testKnownPhysicalConversionsAndOffsets() throws {
        let cases: [(EquipmentScheduleField, String, String, Double, String)] = [
            (.airflow, "1,200", "CFM", 0.56633693184, "m³/s"),
            (.outdoorAir, "250", "L/s", 0.25, "m³/s"),
            (.waterFlow, "60", "US GPM", 0.003785411784, "m³/s"),
            (.airflow, "3600", "m³/h", 1, "m³/s"),
            (.coolingTotal, "1", "tonR", 3516.852842066667, "W"),
            (.heatingCapacity, "3600", "Btu_IT/h", 1055.05585262, "W"),
            (.furnaceOutput, "12.5", "kW", 12500, "W"),
            (.externalStaticPressure, "0.25", "kPa", 250, "Pa"),
            (.enteringWaterTemperature, "32", "°F", 0, "°C"),
            (.leavingWaterTemperature, "212", "F", 100, "°C"),
            (.enteringWaterTemperature, "273.15", "K", 0, "°C"),
            (.weight, "100", "lb", 45.359237, "kg"),
            (.minimumCircuitAmpacity, "18", "A", 18, "A"),
            (.voltage, "208", "V", 208, "V"),
            (.phase, "3", "ph", 3, "phase"),
            (.quantity, "0", "each", 0, "each")
        ]
        for (field, text, unit, expected, normalizedUnit) in cases {
            let result = ScheduleNumericInterpreter.interpret(field: field, text: text, unitText: unit)
            XCTAssertEqual(result.status, .interpreted, "\(field): \(unit)")
            XCTAssertEqual(try XCTUnwrap(result.value), expected, accuracy: 1e-9)
            XCTAssertEqual(result.unit, normalizedUnit)
        }
    }
    func testMissingAndAmbiguousValuesNeverProduceNumbers() {
        for value in [nil, "", " "] as [String?] {
            XCTAssertEqual(ScheduleNumericInterpreter.interpret(field: .airflow, text: value, unitText: "CFM").status, .missing)
        }
        for value in ["1,20", "1.200,5", "1 200", "1,200*", "100-200", "208/230", "1e309", "NaN", "∞", "1200 CFM", "≤1200", "(1200)", "1O00", "1\n2"] {
            let result = ScheduleNumericInterpreter.interpret(field: .airflow, text: value, unitText: "CFM")
            XCTAssertEqual(result.status, .unresolved, value); XCTAssertNil(result.value)
        }
        XCTAssertEqual(ScheduleNumericInterpreter.interpret(field: .airflow, text: "0", unitText: nil).status, .unresolved)
        XCTAssertEqual(ScheduleNumericInterpreter.interpret(field: .model, text: "1200", unitText: "CFM").status, .notNumeric)
    }
    func testUnitsAreFieldSpecificAndCaseSensitiveWhereNecessary() {
        for (field, unit) in [(EquipmentScheduleField.airflow, "A"), (.coolingTotal, "mW"), (.waterFlow, "GPM"), (.heatingCapacity, "MBH"), (.heatingCapacity, "Btu/h"), (.externalStaticPressure, "in.w.c."), (.weight, "ton")] {
            let result = ScheduleNumericInterpreter.interpret(field: field, text: "1", unitText: unit)
            XCTAssertEqual(result.status, .unresolved, unit); XCTAssertNil(result.value)
        }
        XCTAssertEqual(ScheduleNumericInterpreter.interpret(field: .coolingTotal, text: "1", unitText: "MW").value, 1_000_000)
    }
    func testInvalidDomainsAndUnrepresentableCountsAreHeld() {
        for (field, value, unit) in [(EquipmentScheduleField.airflow, "-1", "CFM"), (.enteringWaterTemperature, "-274", "C"), (.phase, "2", "ph"), (.quantity, "1.5", "each"), (.quantity, "9007199254740992", "each")] {
            XCTAssertEqual(ScheduleNumericInterpreter.interpret(field: field, text: value, unitText: unit).status, .unresolved)
        }
        XCTAssertEqual(ScheduleNumericInterpreter.interpret(field: .enteringWaterTemperature, text: "-40", unitText: "F").value, -40)
    }
    @MainActor func testExtractionIncludesDerivedReviewWithoutMutatingLiteralRows() async throws {
        let pdf = Bundle.module.url(forResource: "EquipmentSchedule", withExtension: "pdf", subdirectory: "Fixtures")!
        let mapping = Bundle.module.url(forResource: "EquipmentScheduleMapping", withExtension: "json", subdirectory: "Fixtures")!
        let archive = try await DrawingIngestor().ingest(url: pdf, ocr: .disabled)
        let result = try EquipmentScheduleExtractor.extract(archive, request: .decode(Data(contentsOf: mapping)))
        XCTAssertEqual(result.numericReview.map(\.rowID), result.rows.map(\.id))
        XCTAssertEqual(result.rows[0].cells.first { $0.field == .airflow }?.text, "1,200")
        XCTAssertEqual(result.numericReview[0].cells.first { $0.field == .airflow }?.value, 0.56633693184)
        XCTAssertEqual(result.numericReview[1].cells.first { $0.field == .minimumCircuitAmpacity }?.status, .missing)
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(json["numericReview"].array?.count, 3)
        for row in result.rows { try row.validate(in: archive) }
    }
}
