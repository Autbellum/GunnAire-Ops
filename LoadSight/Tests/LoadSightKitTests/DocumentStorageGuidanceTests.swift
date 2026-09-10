import SwiftUI
import XCTest
@testable import LoadSightUI

@MainActor final class DocumentStorageGuidanceTests: XCTestCase {
    func testEmbeddedHostUsesItsActualProjectExportAndDoneWorkflow() async {
        XCTAssertEqual(LoadSightFileWorkspaceView.documentStorage(localRecoveryEnabled: false), .exportedProject)
        let text = LoadSightFileWorkspaceView.documentStorage(localRecoveryEnabled: false).guidance
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
        embedded.loadSightDocumentStorage = LoadSightFileWorkspaceView.documentStorage(localRecoveryEnabled: false)
        XCTAssertEqual(embedded.loadSightDocumentStorage, .exportedProject)
        XCTAssertEqual(EnvironmentValues().loadSightDocumentStorage, .nativeDocument)
    }

    func testRecoveryGuidanceOffersKeepDraftWithoutClaimingPortableAutosave() async {
        let mode = LoadSightFileWorkspaceView.documentStorage(localRecoveryEnabled: true)
        XCTAssertEqual(mode, .recoverableProject)
        for text in ["local-save status", "Keep draft and close", "portable copy"] { XCTAssertTrue(mode.guidance.contains(text)) }
        XCTAssertTrue(mode.openingGuidance.contains("on this device"))
        XCTAssertFalse(mode.guidance.contains("native document system"))
    }

    func testDisabledRecoveryFallsBackToManualInstructionsIncludingLinkEditor() async {
        let recovery = WorkspaceRecoverySession(scope: "Synthetic scope")
        XCTAssertEqual(LoadSightFileWorkspaceView.documentStorage(localRecoveryEnabled: recovery.enabled), .recoverableProject)
        recovery.continueWithoutRecovery()
        let mode = LoadSightFileWorkspaceView.documentStorage(localRecoveryEnabled: recovery.enabled)
        XCTAssertEqual(mode, .exportedProject)
        XCTAssertTrue(mode.openingGuidance.contains("Local recovery is unavailable"))
        XCTAssertFalse(mode.guidance.contains("Keep draft and close"))
        XCTAssertEqual(mode.linkRetentionGuidance, "Export the project to retain the link.")
        XCTAssertFalse(LoadSightDocumentStorage.nativeDocument.linkRetentionGuidance.contains("Export"))
    }
}
