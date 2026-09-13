import XCTest

final class EquipmentScheduleUITests: XCTestCase {
    @MainActor func testRowSourceAndMissingCellReview() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'ScheduleRow-'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15)); XCTAssertEqual(rows.count, 3)
        rows.element(boundBy: 1).tap()
        XCTAssertTrue(app.buttons["ViewScheduleSource"].waitForExistence(timeout: 5))
        app.buttons["ViewScheduleSource"].tap()
        XCTAssertTrue(app.buttons["Close source"].waitForExistence(timeout: 5))
        let source = XCTAttachment(screenshot: app.screenshot()); source.name = "Schedule original page and cell rectangles"; source.lifetime = .keepAlways; add(source)
        app.buttons["Close source"].tap()
        let missing = app.staticTexts["Unknown — no recognized cell text"]
        for _ in 0..<8 { if missing.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(missing.isHittable)
        let row = XCTAttachment(screenshot: app.screenshot()); row.name = "Schedule missing MCA remains unknown"; row.lifetime = .keepAlways; add(row)
        app.buttons["Done"].tap()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
    }
}
