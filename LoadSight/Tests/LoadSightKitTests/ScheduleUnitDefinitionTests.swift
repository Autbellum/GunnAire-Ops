import XCTest
import LoadSightKit
@testable import LoadSightUI

@MainActor final class ScheduleUnitDefinitionTests: XCTestCase {
    let legend = "Synthetic schedule page 1 legend: MBH = 1000 BTU_IT/H; BTU denotes International Table units."
    private func fixture() async throws -> (DrawingArchive, EquipmentScheduleRequest) {
        let pdf = Bundle.module.url(forResource: "UnitConventionSchedule", withExtension: "pdf", subdirectory: "Fixtures")!
        let map = Bundle.module.url(forResource: "UnitConventionScheduleMapping", withExtension: "json", subdirectory: "Fixtures")!
        return (try await DrawingIngestor().ingest(url: pdf, ocr: .disabled), try .decode(Data(contentsOf: map)))
    }
    func testAmbiguousUnitsRequireMatchingSourcedConventions() throws {
        let cases: [(EquipmentScheduleField, String, String, ScheduleUnitConvention, Double)] = [
            (.coolingTotal, "12", "MBH", .thousandBtuInternationalTablePerHour, 3516.852842066667),
            (.heatingCapacity, "3600", "Btu/h", .btuInternationalTablePerHour, 1055.05585262),
            (.coolingSensible, "1", "tons", .refrigerationTon, 3516.852842066667),
            (.waterFlow, "60", "GPM", .usLiquidGallonsPerMinute, 0.003785411784),
            (.waterFlow, "60", "GPM", .imperialGallonsPerMinute, 0.00454609)
        ]
        for (field, text, unit, convention, expected) in cases {
            XCTAssertEqual(ScheduleNumericInterpreter.interpret(field: field, text: text, unitText: unit).status, .unresolved)
            let definition = ScheduleUnitDefinition(convention: convention, source: "Synthetic specification explicitly defines \(convention.title)")
            let result = ScheduleNumericInterpreter.interpret(field: field, text: text, unitText: unit, definition: definition)
            XCTAssertEqual(result.status, .interpreted)
            XCTAssertEqual(try XCTUnwrap(result.value), expected, accuracy: 1e-10)
            XCTAssertTrue(result.explanation.contains(definition.source))
        }
        for source in ["", " \n ", String(repeating: "x", count: 4097)] {
            let invalid = ScheduleUnitDefinition(convention: .thousandBtuInternationalTablePerHour, source: source)
            XCTAssertThrowsError(try invalid.validate(field: .coolingTotal, unitText: "MBH"))
            XCTAssertEqual(ScheduleNumericInterpreter.interpret(field: .coolingTotal, text: "12", unitText: "MBH", definition: invalid).status, .unresolved)
        }
        let definition = ScheduleUnitDefinition(convention: .thousandBtuInternationalTablePerHour, source: legend)
        for (field, unit) in [(EquipmentScheduleField.weight, "MBH"), (.coolingTotal, "kW"), (.coolingTotal, "GPM"), (.coolingTotal, nil)] as [(EquipmentScheduleField, String?)] {
            XCTAssertThrowsError(try definition.validate(field: field, unitText: unit))
        }
    }
    func testExtractionPreservesLiteralAndBindsConventionEvidenceToIdentity() async throws {
        let (archive, original) = try await fixture()
        let old = try EquipmentScheduleExtractor.extract(archive, request: original)
        var request = original
        request.regions[0].columns[1].unitDefinition = .init(convention: .thousandBtuInternationalTablePerHour, source: legend)
        let result = try EquipmentScheduleExtractor.extract(archive, request: request)
        XCTAssertEqual(result.rows.map { $0.cells[1].text }, ["12", nil, "30"])
        XCTAssertEqual(result.rows.map { $0.cells[1].unitText }, ["MBH", "MBH", "MBH"])
        XCTAssertEqual(result.rows[0].cells[1].unitDefinition?.source, legend)
        XCTAssertEqual(result.rows.map { $0.cells[1].numericInterpretation.status }, [.interpreted, .missing, .interpreted])
        XCTAssertEqual(try XCTUnwrap(result.rows[0].cells[1].numericInterpretation.value), 3516.852842066667, accuracy: 1e-10)
        XCTAssertNotEqual(old.rows.map(\.id), result.rows.map(\.id))
        for row in result.rows { try row.validate(in: archive) }
        request.regions[0].columns[1].unitDefinition?.source += " Corrected source citation."
        let revised = try EquipmentScheduleExtractor.extract(archive, request: request)
        XCTAssertNotEqual(revised.rows.map(\.id), result.rows.map(\.id))
        XCTAssertEqual(revised.rows.map { $0.cells[1].text }, result.rows.map { $0.cells[1].text })
        XCTAssertEqual(try EquipmentScheduleRequest.decode(JSONEncoder().encode(original)).regions, original.regions)
        XCTAssertEqual(try EquipmentScheduleExtractor.extract(archive, request: original).rows, old.rows)
    }
    func testStrictNestedContractAndInvalidSaveAreAtomic() async throws {
        let (archive, original) = try await fixture()
        for nested in [
            ["convention": "thousandBtuInternationalTablePerHour", "source": legend, "guess": "yes"],
            ["convention": "unknown", "source": legend],
            ["convention": "thousandBtuInternationalTablePerHour"]
        ] {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
            var regions = object["regions"] as! [[String: Any]]
            var columns = regions[0]["columns"] as! [[String: Any]]
            columns[1]["unitDefinition"] = nested; regions[0]["columns"] = columns; object["regions"] = regions
            XCTAssertThrowsError(try EquipmentScheduleRequest.decode(JSONSerialization.data(withJSONObject: object)))
        }
        var project = try LoadSightTests().readyProject()
        let before = try project.data()
        for definition in [ScheduleUnitDefinition(convention: .thousandBtuInternationalTablePerHour, source: ""), .init(convention: .usLiquidGallonsPerMinute, source: legend)] {
            var request = original; request.regions[0].columns[1].unitDefinition = definition
            XCTAssertThrowsError(try project.saveScheduleMap(name: "Invalid definition", request: request, drawings: archive, expectedFingerprint: project.scheduleMapEditFingerprint(), author: "Mapper", reason: "Definition review"))
            XCTAssertEqual(try project.data(), before)
        }
    }
    func testDefinitionRevisionSurvivesPackageJSONAndDraftWhileSourceChangeClearsIt() async throws {
        let (archive, original) = try await fixture()
        var document = try LoadSightDocument(project: LoadSightTests().readyProject())
        try document.addDrawings(archive)
        let id = try document.project.saveScheduleMap(name: "Legend review", request: original, drawings: archive, expectedFingerprint: document.project.scheduleMapEditFingerprint(), author: "Mapper", reason: "Initial unresolved abbreviation")
        let items = document.project.items
        let oldFingerprint = try document.project.scheduleMapEditFingerprint()
        var request = original
        request.regions[0].columns[1].unitDefinition = .init(convention: .thousandBtuInternationalTablePerHour, source: legend)
        try document.project.saveScheduleMap(id: id, name: "Legend review", request: request, drawings: archive, expectedFingerprint: oldFingerprint, author: "Checker", reason: "Read the source legend")
        XCTAssertThrowsError(try document.project.saveScheduleMap(id: id, name: "Stale", request: original, drawings: archive, expectedFingerprint: oldFingerprint, author: "Mapper", reason: "Stale map"))
        for package in [true, false] {
            let reopened = try LoadSightDocument(wrapper: document.wrapper(asPackage: package))
            let saved = try reopened.project.scheduleMaps()[0].columnMap()
            XCTAssertEqual(saved.regions[0].columns[1].unitDefinition?.source, legend)
            let history = try reopened.project.scheduleMapHistory()
            XCTAssertEqual(history.count, 2)
            XCTAssertNil(try ProjectDocument.decodeScheduleMaps(history[1].before)[0].columnMap().regions[0].columns[1].unitDefinition)
            XCTAssertEqual(reopened.project.items, items)
            XCTAssertEqual(reopened.drawings.files, archive.files)
            var draft = ScheduleMapDraft(drawings: archive, name: "Legend review", request: saved)
            XCTAssertEqual(try draft.request(author: "Checker").regions[0].columns[1].unitDefinition, saved.regions[0].columns[1].unitDefinition)
            draft.regions[0].changeSource(archive.records[0])
            XCTAssertNil(draft.regions[0].columns[1].convention)
            XCTAssertTrue(draft.regions[0].columns[1].conventionSource.isEmpty)
        }
    }
}
