import XCTest

final class WorkbookExportUITests: XCTestCase {
    @MainActor func testPrepareWorkbookAndCancelSavePanel() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.staticTexts["Synthetic comparison project"].waitForExistence(timeout: 15))
        app.staticTexts["Takeoff"].firstMatch.tap()
        let prepare = app.buttons["PrepareWorkbookExport"]
        XCTAssertTrue(prepare.waitForExistence(timeout: 5)); prepare.tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 15))
        print("WORKBOOK_SAVE_PANEL_BEGIN\n" + app.debugDescription + "\nWORKBOOK_SAVE_PANEL_END")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Workbook save panel"; shot.lifetime = .keepAlways; add(shot)
        cancel.tap()
        XCTAssertTrue(prepare.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: prepare)
        waitForExpectations(timeout: 5)
        prepare.tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 15)); cancel.tap()
        XCTAssertTrue(prepare.waitForExistence(timeout: 5))
    }
    @MainActor func testSaveWorkbookToLocalFiles() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.staticTexts["Synthetic comparison project"].waitForExistence(timeout: 15))
        app.staticTexts["Takeoff"].firstMatch.tap()
        let prepare = app.buttons["PrepareWorkbookExport"]
        XCTAssertTrue(prepare.waitForExistence(timeout: 5)); prepare.tap()
        let name = app.textFields["DOCPicker.filenameTextField"]
        XCTAssertTrue(name.waitForExistence(timeout: 15))
        let folder = app.cells["LoadSight, Container"]
        if folder.exists { folder.tap() }
        let filename = "LoadSight-Async-" + UUID().uuidString
        name.tap()
        let old = name.value as? String ?? ""
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + filename)
        XCTAssertEqual(name.value as? String, filename)
        let save = app.buttons["Save"].firstMatch
        XCTAssertTrue(save.isEnabled); save.tap()
        XCTAssertTrue(prepare.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: prepare)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        print("WORKBOOK_SAVED_NAME=" + filename)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Workbook saved and export available again"; shot.lifetime = .keepAlways; add(shot)
    }

}
