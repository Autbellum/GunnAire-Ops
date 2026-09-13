import XCTest
final class ScheduleDiscoveryUITests: XCTestCase {
    @MainActor func testDiscoverSourceReviewAuthoredMapAndDiskReopen() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        let discover = app.buttons["DiscoverEquipmentSchedules"]
        XCTAssertTrue(discover.waitForExistence(timeout: 15)); discover.tap()
        let candidates = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'DiscoveredSchedule-'"))
        XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 15)); XCTAssertEqual(candidates.count, 1)
        candidates.firstMatch.tap()
        XCTAssertTrue(app.otherElements["DiscoveredScheduleSource"].waitForExistence(timeout: 5))
        let sourceShot = XCTAttachment(screenshot: app.screenshot())
        sourceShot.name = "Discovered table on original source"; sourceShot.lifetime = .keepAlways; add(sourceShot)
        app.buttons["ReviewDiscoveredMap"].tap()
        let name = app.textFields["ScheduleMapName"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); name.tap(); name.typeText("Discovered equipment")
        let author = app.textFields["ScheduleMapAuthor"]; author.tap(); author.typeText("Synthetic reviewer")
        let reason = app.textFields["ScheduleMapReason"]; reason.tap(); reason.typeText("Checked proposed headers and body on source")
        app.buttons["SaveScheduleMap"].tap()
        XCTAssertTrue(app.buttons["CloseScheduleCandidate"].waitForExistence(timeout: 8)); app.buttons["CloseScheduleCandidate"].tap()
        XCTAssertTrue(app.buttons["CloseScheduleDiscovery"].waitForExistence(timeout: 5)); app.buttons["CloseScheduleDiscovery"].tap()
        XCTAssertTrue(app.buttons["ReopenMapPackage"].waitForExistence(timeout: 5)); app.buttons["ReopenMapPackage"].tap()
        let read = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'ReadScheduleMap-'"))
        XCTAssertTrue(read.firstMatch.waitForExistence(timeout: 8)); read.firstMatch.tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'ScheduleRow-'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10)); XCTAssertEqual(rows.count, 3)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Saved discovered map reopened and read"; shot.lifetime = .keepAlways; add(shot)
    }
}
