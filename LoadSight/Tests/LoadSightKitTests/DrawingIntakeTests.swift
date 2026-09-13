import XCTest
import LoadSightKit
import LoadSightUI

@MainActor
final class DrawingIntakeTests: XCTestCase {
    private func url(_ name: String, _ ext: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")!
    }
    private func pdf(ocr: DrawingOCRMode = .disabled) async throws -> DrawingArchive {
        try await DrawingIngestor().ingest(url: url("DrawingIntake", "pdf"), ocr: ocr)
    }
    func testVectorTextHasPageCoordinatesAndCropRotation() async throws {
        let archive = try await pdf()
        let source = try XCTUnwrap(archive.records.first)
        XCTAssertEqual(source.pages.count, 3)
        let title = try XCTUnwrap(source.pages[0].text.first { $0.text == "M101 MECHANICAL PLAN" })
        XCTAssertEqual(title.bounds.x, 72, accuracy: 1)
        XCTAssertTrue((710...740).contains(title.bounds.y))
        XCTAssertEqual(title.method, "PDF text layer")
        XCTAssertTrue(source.pages[0].sheetCandidates.contains("M101"))
        XCTAssertTrue(source.pages[1].text.isEmpty)
        XCTAssertEqual(source.pages[2].rotation, 90)
        XCTAssertEqual(source.pages[2].bounds.x, 50)
        XCTAssertEqual(source.pages[2].bounds.y, 80)
        XCTAssertTrue(source.pages[2].text.contains { $0.text.contains("M303") })
        XCTAssertEqual(archive.files[source.id], try Data(contentsOf: url("DrawingIntake", "pdf")))
    }
    func testRasterPageOCRAndStandaloneImageCoordinates() async throws {
        let archive = try await pdf(ocr: .whenNoText)
        let page = archive.records[0].pages[1]
        XCTAssertTrue(page.text.contains { $0.text.contains("1200") && $0.text.contains("CFM") })
        XCTAssertTrue(page.sheetCandidates.contains("M202"))
        XCTAssertTrue(page.text.allSatisfy { $0.method == "Vision OCR" && $0.bounds.rect.intersects(page.bounds.rect) })
        let image = try await DrawingIngestor().ingest(url: url("Scan", "png"))
        let imagePage = image.records[0].pages[0]
        XCTAssertEqual(imagePage.bounds.width, 1400)
        XCTAssertEqual(imagePage.bounds.height, 800)
        let text = try XCTUnwrap(imagePage.text.first { $0.text.contains("M202") })
        XCTAssertEqual(text.bounds.x, 100, accuracy: 20)
        // Image text starts around y=100 from top; evidence uses bottom-left coordinates.
        XCTAssertTrue(text.bounds.y > 600 && text.bounds.y < 720)
    }
    func testReimportDeduplicatesSourceAndDoesNotDuplicateSheets() async throws {
        let archive = try await pdf()
        var document = LoadSightDocument()
        try document.addDrawings(archive)
        let original = document.project.root
        try document.addDrawings(archive)
        XCTAssertEqual(document.drawings.records.count, 1)
        XCTAssertEqual(document.project.root, original)
        XCTAssertEqual(document.project.root["sheets"].array?.count, 3)
    }
    func testPackageAndJSONRoundTripPreserveSourceAndExtraction() async throws {
        var document = LoadSightDocument()
        try document.addDrawings(await pdf())
        for asPackage in [true, false] {
            let restored = try LoadSightDocument(wrapper: document.wrapper(asPackage: asPackage))
            XCTAssertEqual(restored.drawings, document.drawings)
            XCTAssertEqual(restored.project.items, document.project.items)
            XCTAssertEqual(restored.project.root["sheets"], document.project.root["sheets"])
        }
    }
    func testPackageRejectsMissingTamperedAndUnindexedSources() async throws {
        var document = LoadSightDocument(); try document.addDrawings(await pdf())
        let id = document.drawings.records[0].id
        let wrapper = try document.wrapper(asPackage: true)
        let files = try XCTUnwrap(wrapper.fileWrappers?["drawings"])
        files.removeFileWrapper(try XCTUnwrap(files.fileWrappers?[id]))
        XCTAssertThrowsError(try LoadSightDocument(wrapper: wrapper))
        let bad = FileWrapper(regularFileWithContents: Data("modified".utf8)); bad.preferredFilename = id
        files.addFileWrapper(bad)
        XCTAssertThrowsError(try LoadSightDocument(wrapper: wrapper))
        let extraWrapper = try document.wrapper(asPackage: true)
        let extra = FileWrapper(regularFileWithContents: Data()); extra.preferredFilename = "unindexed"
        extraWrapper.fileWrappers!["drawings"]!.addFileWrapper(extra)
        XCTAssertThrowsError(try LoadSightDocument(wrapper: extraWrapper))
    }
    func testUnsupportedAndCancelledImportReturnNoArchive() async throws {
        do {
            _ = try await DrawingIngestor().ingest(data: Data("not a drawing".utf8), filename: "broken.pdf")
            XCTFail("Corrupt file was accepted")
        } catch { XCTAssertTrue(error is LoadSightError) }
        let source = url("DrawingIntake", "pdf")
        let task = Task { try await DrawingIngestor().ingest(url: source, ocr: .everyPage) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled import produced an archive") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testImportReopensPriorQAWithoutChangingTakeoffFacts() async throws {
        var document = try LoadSightDocument(project: ProjectDocument(data: Data(contentsOf: url("Dental_Office_Seed", "json"))))
        let items = document.project.items
        try document.addDrawings(await pdf())
        XCTAssertEqual(document.project.items, items)
        XCTAssertTrue(document.project.root["qa"].array!.allSatisfy { $0["status"].string == "Open" })
    }
    func testMatchingLegacyFingerprintLinksExistingPageInsteadOfDuplicatingIt() async throws {
        let archive = try await pdf()
        var document = LoadSightDocument()
        try document.project.replace("sourceSha256", with: .string(archive.records[0].id))
        try document.project.replace("sheets", with: .array([.object(["sheet": .string("M101 verified title"), "page": .number(1)])]))
        try document.addDrawings(archive)
        let sheets = document.project.root["sheets"].array!
        XCTAssertEqual(sheets.count, 3)
        XCTAssertEqual(sheets[0]["sheet"].string, "M101 verified title")
        XCTAssertEqual(sheets[0]["nativePageID"].string, archive.records[0].pages[0].id)
    }
}
