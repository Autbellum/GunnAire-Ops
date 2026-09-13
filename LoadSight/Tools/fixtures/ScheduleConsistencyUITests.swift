import XCTest
final class ScheduleConsistencyUITests: XCTestCase {
 @MainActor func testConditionalConflictDisclosure() throws {
  continueAfterFailure = false
  let app = XCUIApplication(); app.launch()
  let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'ScheduleRow-'"))
  XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15)); rows.element(boundBy: 0).tap()
  let check = app.otherElements["ScheduleCheck-airflow.outdoorTotal"]
  let conflict = app.staticTexts["Possible conflict — review required"]
  for _ in 0..<7 { if conflict.isHittable { break }; app.swipeUp() }
  XCTAssertTrue(conflict.isHittable); conflict.tap()
  let basis = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'First value exceeds the second after unit conversion'" )).firstMatch
  for _ in 0..<3 { if basis.isHittable { break }; app.swipeUp() }
  XCTAssertTrue(basis.isHittable)
  XCTAssertTrue(basis.label.contains("same total airstream"))
  let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Conditional outdoor airflow conflict and basis"; shot.lifetime = .keepAlways; add(shot)
  app.buttons["Done"].tap(); rows.element(boundBy: 1).tap()
  XCTAssertTrue(app.staticTexts["Missing — check source and applicability"].firstMatch.waitForExistence(timeout: 5))
 }
}
