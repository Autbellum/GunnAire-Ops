import XCTest
final class ScheduleRFUITests: XCTestCase {
 @MainActor func testSaveQuestionAndFindItInRegister() throws {
  continueAfterFailure = false
  let app = XCUIApplication(); app.launch()
  let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'ScheduleRow-'"))
  XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15)); rows.element(boundBy: 0).tap()
  let conflict = app.staticTexts["Possible conflict — review required"]
  for _ in 0..<8 { if conflict.isHittable { break }; app.swipeUp() }
  XCTAssertTrue(conflict.isHittable); conflict.tap()
  let draft = app.buttons["Draft RFI for finding"].firstMatch
  for _ in 0..<4 { if draft.isHittable { break }; app.swipeUp() }
  XCTAssertTrue(draft.isHittable); draft.tap()
  let question = app.textFields["ScheduleRFIQuestion"]
  XCTAssertTrue(question.waitForExistence(timeout: 5))
  for _ in 0..<6 { if question.isHittable { break }; app.swipeUp() }
  question.tap(); question.typeText("Confirm the total and outdoor airflow rating basis.")
  let impact = app.textFields["ScheduleRFIImpact"]; impact.tap(); impact.typeText("Equipment selection remains pending.")
  let author = app.textFields["ScheduleRFIAuthor"]; author.tap(); author.typeText("Synthetic reviewer")
  let save = app.buttons["SaveScheduleRFI"]
  for _ in 0..<5 { if save.isHittable { break }; app.swipeUp() }
  XCTAssertTrue(save.isHittable); save.tap()
  let saved = app.staticTexts["ScheduleRFISaved"]
  for _ in 0..<6 { if saved.isHittable { break }; app.swipeUp() }
  XCTAssertTrue(saved.isHittable)
  XCTAssertFalse(app.textFields["ScheduleRFIAuthor"].isEnabled)
  let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Saved schedule RFI and linked evidence"; shot.lifetime = .keepAlways; add(shot)
  app.buttons["Done"].firstMatch.tap(); app.buttons["Done"].firstMatch.tap()
  app.buttons["OpenRFIWorkspace"].tap()
  let rfis = app.staticTexts["RFIs"].firstMatch
  XCTAssertTrue(rfis.waitForExistence(timeout: 5)); rfis.tap()
  XCTAssertTrue(app.staticTexts["Schedule clarification: RTU-1"].waitForExistence(timeout: 5))
 }
}
