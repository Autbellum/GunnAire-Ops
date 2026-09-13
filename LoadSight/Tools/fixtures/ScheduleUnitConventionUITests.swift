import XCTest
final class ScheduleUnitConventionUITests: XCTestCase {
    @MainActor func testSourceConventionRequiresEvidenceAndSurvivesDiskReopen() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-AppleLocale", "en_US"]; app.launch()
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'EditScheduleMap-'"))
        XCTAssertTrue(edit.firstMatch.waitForExistence(timeout: 15)); edit.firstMatch.tap()
        func reveal(_ element: XCUIElement) {
            for _ in 0..<20 {
                if element.isHittable { return }
                app.coordinate(withNormalizedOffset: .init(dx: 0.8, dy: 0.55))
                    .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: .init(dx: 0.8, dy: 0.32)))
            }
            XCTAssertTrue(element.isHittable)
        }
        func fill(_ id: String, _ text: String) {
            let field = app.textFields[id]; reveal(field); field.tap(); field.typeText(text)
        }
        fill("ScheduleMapAuthor", "Synthetic checker")
        fill("ScheduleMapReason", "Read the printed legend")
        let picker = app.buttons["ScheduleConvention-coolingTotal"]
        reveal(picker); picker.tap()
        app.buttons["1,000 International Table Btu per hour"].tap()
        app.buttons["SaveScheduleMap"].tap()
        XCTAssertTrue(app.alerts["Unable to save map"].waitForExistence(timeout: 5))
        app.alerts["Unable to save map"].buttons["OK"].tap()
        let sourceID = "ScheduleConventionSource-coolingTotal"
        let citation = "Page 1 legend: MBH = 1000 BTU_IT/H; BTU denotes International Table units."
        fill(sourceID, citation)
        app.buttons["SaveScheduleMap"].tap()
        let reopen = app.buttons["ReopenMapPackage"]
        XCTAssertTrue(reopen.waitForExistence(timeout: 8)); reopen.tap()
        XCTAssertTrue(edit.firstMatch.waitForExistence(timeout: 8)); edit.firstMatch.tap()
        let source = app.textFields[sourceID]; reveal(source)
        XCTAssertEqual(source.value as? String, citation)
        let evidenceShot = XCTAttachment(screenshot: app.screenshot())
        evidenceShot.name = "Reopened source convention and legend"; evidenceShot.lifetime = .keepAlways; add(evidenceShot)
        app.buttons["Cancel"].firstMatch.tap()
        let read = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'ReadScheduleMap-'"))
        XCTAssertTrue(read.firstMatch.waitForExistence(timeout: 5)); read.firstMatch.tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'ScheduleRow-'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10)); rows.firstMatch.tap()
        let literal = app.staticTexts["12"]
        reveal(literal)
        XCTAssertTrue(literal.isHittable)
        let value = app.staticTexts["ScheduleNumeric-coolingTotal"]
        reveal(value)
        XCTAssertTrue(value.isHittable)
        XCTAssertTrue(value.label.contains("3,516.8528")); XCTAssertTrue(value.label.contains("W"))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Literal MBH and sourced converted capacity"; shot.lifetime = .keepAlways; add(shot)
    }
}
