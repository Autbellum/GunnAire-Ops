import XCTest
@testable import HVACCore
@testable import HVACUI

@MainActor
final class ReportTests: XCTestCase {

    private func report() -> DesignReport {
        let engine = DesignEngine()
        return ReportBuilder.build(project: engine.project,
                                   load: engine.load!,
                                   systems: engine.systems,
                                   profile: engine.coolingProfile)
    }

    func testReportCoversEveryStageOfTheCascade() {
        let titles = report().sections.map(\.title)
        XCTAssertTrue(titles.contains { $0.contains("Design Conditions") })
        XCTAssertTrue(titles.contains { $0.contains("Load Summary") })
        XCTAssertTrue(titles.contains { $0.contains("Envelope") })
        // Manual S, T and D now live inside each system's own section.
        XCTAssertTrue(titles.contains { $0.uppercased().contains("SYSTEM") })
        let systemSection = report().sections.first { $0.title.uppercased().contains("SYSTEM") }
        let tableTitles = systemSection?.tables.map(\.title) ?? []
        XCTAssertTrue(tableTitles.contains { $0.contains("Manual S") })
        XCTAssertTrue(tableTitles.contains { $0.contains("Manual T") })
        XCTAssertTrue(tableTitles.contains { $0.contains("Manual D") })
    }

    /// A reviewer must be able to see every room, not a total that cannot be checked.
    func testRoomByRoomTableListsEveryZone() throws {
        let engine = DesignEngine()
        let built = report()
        let summary = try XCTUnwrap(built.sections.first { $0.title.contains("Load Summary") })
        let table = try XCTUnwrap(summary.tables.first { $0.title == "Room by Room" })
        XCTAssertEqual(table.rows.count, engine.project.zones.count)
        for zone in engine.project.zones {
            XCTAssertTrue(table.rows.contains { $0.first == zone.name }, zone.name)
        }
    }

    func testEnvelopeTableNamesTheConstructionOfEverySurface() throws {
        let engine = DesignEngine()
        let envelope = try XCTUnwrap(report().sections.first { $0.title == "Envelope" })
        let table = try XCTUnwrap(envelope.tables.first)
        let expected = engine.project.zones.flatMap { $0.surfaces.filter(\.isValid) }.count
        XCTAssertEqual(table.rows.count, expected)
        // The construction name travels with the surface, not just its U-value.
        XCTAssertTrue(table.rows.allSatisfy { !($0.last ?? "").isEmpty })
    }

    func testDuctScheduleCarriesVelocityAndEquivalentLength() throws {
        let schedule = try XCTUnwrap(report().sections
            .flatMap(\.tables).first { $0.title.contains("Duct Schedule") })
        XCTAssertTrue(schedule.columns.contains("Velocity FPM"))
        XCTAssertTrue(schedule.columns.contains("TEL ft"))
        XCTAssertFalse(schedule.rows.isEmpty)
    }

    /// The provenance and the limits have to be on the page, not only in the source.
    func testFootnotesDisclaimTheBasis() {
        let joined = report().footnotes.joined(separator: " ")
        XCTAssertTrue(joined.contains("NOAA"))
        XCTAssertTrue(joined.contains("not ASHRAE published design conditions"))
        // Thermal mass IS modelled now, so the footnote states the method rather than
        // disclaiming its absence. The disclaimers that remain must still be present.
        XCTAssertTrue(joined.contains("solved transiently"))
        XCTAssertFalse(joined.contains("not modelled"),
                       "a caveat that no longer applies must not linger in the report")
        XCTAssertTrue(joined.contains("not ACCA-approved"))
    }

    // MARK: PDF

    func testPDFRendersRealPagesWithReadableText() throws {
        let data = ReportPDF.data(for: report())
        XCTAssertGreaterThan(data.count, 4_000, "PDF is implausibly small")

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("report-test.pdf")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try XCTUnwrap(PDFKitBridge.open(url))
        XCTAssertGreaterThanOrEqual(document.pageCount, 1)
        XCTAssertLessThan(document.pageCount, 12, "report should not run away")

        let text = document.text
        XCTAssertTrue(text.contains("Sample Residence"), "project name missing")
        XCTAssertTrue(text.contains("DESIGN CONDITIONS"))
        XCTAssertTrue(text.contains("Living Room"))
        XCTAssertTrue(text.contains("Supply Trunk"))
        XCTAssertTrue(text.contains("NOAA"))
    }

    func testEmptyProjectStillProducesAValidPDF() throws {
        var empty = Project.sample
        empty.zones = []
        for index in empty.systems.indices { empty.systems[index].ductRuns = [] }
        let engine = DesignEngine(project: empty)
        let built = ReportBuilder.build(project: empty,
                                        load: engine.load ?? ProjectLoad(zoneLoads: [],
                                                                         designConditions: empty.designConditions,
                                                                         procedure: empty.procedure),
                                        systems: engine.systems,
                                        profile: engine.coolingProfile)
        XCTAssertGreaterThan(ReportPDF.data(for: built).count, 1_000)
    }
}

import PDFKit
enum PDFKitBridge {
    static func open(_ url: URL) -> (pageCount: Int, text: String)? {
        guard let document = PDFDocument(url: url) else { return nil }
        return (document.pageCount, document.string ?? "")
    }
}

extension ReportTests {
    /// Dynamic system colours resolve against the running appearance, so a report
    /// generated on a Mac in dark mode rendered its headings near-white on a white page.
    /// Print ink is fixed.
    func testReportInkIsOpaqueAndDarkRegardlessOfAppearance() throws {
        let text = ReportPDF.attributedString(for: report())
        var checked = 0
        text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            guard let colour = value as? NSColor else { return }
            let rgb = colour.usingColorSpace(.deviceRGB)
            XCTAssertNotNil(rgb)
            if let rgb {
                XCTAssertLessThan(rgb.brightnessComponent, 0.7,
                                  "ink too light to print: \(rgb)")
                XCTAssertEqual(rgb.alphaComponent, 1.0, accuracy: 0.001)
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 5, "no coloured runs found to check")
    }
}
