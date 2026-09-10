import SwiftUI
import XCTest
@testable import LoadSightUI

@MainActor final class DocumentStorageGuidanceTests: XCTestCase {
    func testEmbeddedHostUsesItsActualProjectExportAndDoneWorkflow() async {
        XCTAssertEqual(LoadSightFileWorkspaceView.documentStorage, .exportedProject)
        let text = LoadSightFileWorkspaceView.documentStorage.guidance
        for label in ["Project", "Export project package", "Export portable JSON", "Done"] { XCTAssertTrue(text.contains(label)) }
        XCTAssertFalse(text.contains("Back button")); XCTAssertFalse(text.contains("File → Open"))
        XCTAssertFalse(text.contains("save through the native document system"))
    }

    func testDocumentGroupRetainsNativeDefaultWithoutEmbeddedExportInstructions() async {
        let values = EnvironmentValues()
        XCTAssertEqual(values.loadSightDocumentStorage, .nativeDocument)
        XCTAssertTrue(values.loadSightDocumentStorage.guidance.contains("drawing evidence"))
        XCTAssertFalse(values.loadSightDocumentStorage.guidance.contains("Done"))
    }

    func testEmbeddedOverrideDoesNotChangeAnotherDocumentHostsDefault() async {
        var embedded = EnvironmentValues()
        embedded.loadSightDocumentStorage = LoadSightFileWorkspaceView.documentStorage
        XCTAssertEqual(embedded.loadSightDocumentStorage, .exportedProject)
        XCTAssertEqual(EnvironmentValues().loadSightDocumentStorage, .nativeDocument)
    }
}
