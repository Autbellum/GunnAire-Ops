import XCTest

final class ScheduleMapAuthoringUITests: XCTestCase {
    @MainActor func testCreateMapReadRowsAndReopenPackage() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        let new = app.buttons["NewScheduleMap"]
        XCTAssertTrue(new.waitForExistence(timeout: 15)); new.tap()
        func reveal(_ element: XCUIElement) {
            for _ in 0..<16 {
                if element.isHittable { return }
                // Scroll inside the editor, clear of the navigation bar and drawing preview.
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.55))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.32))
                start.press(forDuration: 0.01, thenDragTo: end)
            }
            XCTAssertTrue(element.isHittable)
        }
        func fill(_ id: String, _ text: String) {
            let field = app.textFields[id]; reveal(field); field.tap(); field.typeText(text)
        }
        fill("ScheduleMapName", "Roof schedule")
        fill("ScheduleMapAuthor", "Synthetic mapper")
        fill("ScheduleMapReason", "Map the controlled fixture headers")
        app.buttons["SaveScheduleMap"].tap()
        XCTAssertTrue(app.alerts["Unable to save map"].waitForExistence(timeout: 5))
        app.alerts["Unable to save map"].buttons["OK"].tap()
        fill("ScheduleMappingBasis", "Header labels and table body checked in the synthetic PDF")
        let bounds = app.buttons["Precise body bounds"]; reveal(bounds); bounds.tap()
        fill("ScheduleBodyLeft", "40"); fill("ScheduleBodyBottom", "520")
        fill("ScheduleBodyRight", "520"); fill("ScheduleBodyTop", "680")
        fill("ScheduleColumnHeader-0", "TAG"); fill("ScheduleColumnLeft-0", "40"); fill("ScheduleColumnRight-0", "160")
        fill("ScheduleColumnHeader-1", "CFM"); fill("ScheduleColumnUnit-1", "CFM")
        fill("ScheduleColumnLeft-1", "320"); fill("ScheduleColumnRight-1", "430")
        app.buttons["SaveScheduleMap"].tap()
        let read = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'ReadScheduleMap-'"))
        XCTAssertTrue(read.firstMatch.waitForExistence(timeout: 8)); read.firstMatch.tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'ScheduleRow-'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10)); XCTAssertEqual(rows.count, 3)
        app.buttons["ReopenMapPackage"].tap()
        XCTAssertTrue(read.firstMatch.waitForExistence(timeout: 8))
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'EditScheduleMap-'"))
        edit.firstMatch.tap()
        XCTAssertTrue(app.textFields["ScheduleMapName"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["ScheduleMapName"].value as? String, "Roof schedule")
        let reopenedBounds = app.buttons["Precise body bounds"]; reveal(reopenedBounds); reopenedBounds.tap()
        reveal(app.textFields["ScheduleBodyLeft"])
        XCTAssertEqual(app.textFields["ScheduleBodyLeft"].value as? String, "40.0")
        XCTAssertEqual(app.textFields["ScheduleBodyTop"].value as? String, "680.0")
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Reopened native schedule map body"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(read.firstMatch.waitForExistence(timeout: 5)); read.firstMatch.tap()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10)); XCTAssertEqual(rows.count, 3)
    }
}
