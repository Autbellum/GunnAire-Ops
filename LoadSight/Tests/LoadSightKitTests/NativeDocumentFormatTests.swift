import XCTest
import UniformTypeIdentifiers
import LoadSightUI

final class NativeDocumentFormatTests: XCTestCase {
    func testDynamicLoadSightTypeWritesActualPackage() throws {
        // Captured from iOS DocumentGroup's new-document write configuration.
        let dynamic = try XCTUnwrap(UTType("dyn.ah62d4rv4ge80255bqv30w35ksu"))
        XCTAssertTrue(dynamic.isDynamic); XCTAssertEqual(dynamic.preferredFilenameExtension,"loadsight")
        let doc = LoadSightDocument(), wrapper = try doc.wrapper(contentType:dynamic)
        XCTAssertTrue(wrapper.isDirectory)
        XCTAssertNotNil(wrapper.fileWrappers?["project.json"])
        XCTAssertTrue(wrapper.fileWrappers?["drawings"]?.isDirectory == true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let path = directory.appendingPathComponent("New.loadsight")
        try wrapper.write(to:path,options:.atomic,originalContentsURL:nil)
        let reopened = try LoadSightDocument(wrapper:FileWrapper(url:path))
        for (key,value) in doc.project.root.object! { XCTAssertEqual(reopened.project.root[key],value) }
        XCTAssertEqual(reopened.project.root["nativeDrawings"],.null)
    }
    func testExplicitJSONAndDeclaredPackageKeepDistinctFormats() throws {
        let doc = LoadSightDocument()
        XCTAssertTrue(try doc.wrapper(contentType:LoadSightDocument.projectType).isDirectory)
        let json = try doc.wrapper(contentType:.json)
        XCTAssertTrue(json.isRegularFile)
        let restored = try LoadSightDocument(wrapper:json)
        XCTAssertEqual(restored.project.name,doc.project.name)
        XCTAssertTrue(restored.project.items.isEmpty)
        XCTAssertThrowsError(try doc.wrapper(contentType:.plainText))
        XCTAssertThrowsError(try doc.wrapper(contentType:.package))
    }
}
