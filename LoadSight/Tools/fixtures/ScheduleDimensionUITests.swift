import XCTest
final class ScheduleDimensionUITests: XCTestCase {
 @MainActor func testOrderedDimensionsAndMissingSourceCell() throws {
  continueAfterFailure = false
  let app = XCUIApplication(); app.launch()
  let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'ScheduleRow-'"))
  XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15)); rows.element(boundBy: 0).tap()
  let dimension = app.staticTexts["ScheduleDimensions"]
  for _ in 0..<10 { if dimension.isHittable { break }; app.swipeUp() }
  XCTAssertTrue(dimension.isHittable)
  XCTAssertEqual(dimension.label, "Dimensions in source order: 0.6096 × 0.9144 × 1.2192 m")
  XCTAssertTrue(app.staticTexts["24 x 36 x 48"].exists)
  let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Literal dimensions and ordered metre interpretation"; shot.lifetime = .keepAlways; add(shot)
  app.buttons["Done"].tap(); rows.element(boundBy: 1).tap()
  let missing = app.staticTexts["Dimensions: missing"]
  for _ in 0..<10 { if missing.isHittable { break }; app.swipeUp() }
  XCTAssertTrue(missing.isHittable)
 }
}
