import XCTest
final class ScheduleNumericUITests: XCTestCase {
 @MainActor func testNumericValueBesideLiteralEvidence() throws {
  continueAfterFailure = false
  let app = XCUIApplication(); app.launch()
  let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'ScheduleRow-'"))
  XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15)); rows.element(boundBy: 0).tap()
  let numeric = app.staticTexts["ScheduleNumeric-airflow"]
  for _ in 0..<8 { if numeric.isHittable { break }; app.swipeUp() }
  XCTAssertTrue(numeric.isHittable)
  XCTAssertTrue(numeric.label.contains("0.56633693")); XCTAssertTrue(numeric.label.contains("m³/s"))
  XCTAssertTrue(app.staticTexts["1,200"].exists)
  let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Literal airflow and numeric interpretation"; shot.lifetime = .keepAlways; add(shot)
 }
}
