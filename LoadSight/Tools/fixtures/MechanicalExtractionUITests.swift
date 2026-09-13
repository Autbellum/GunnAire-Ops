import XCTest

final class MechanicalExtractionUITests: XCTestCase {
    @MainActor func testSourcePreviewAndRFIDraft() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.staticTexts["Synthetic extraction project"].waitForExistence(timeout: 15))
        app.staticTexts["Extraction"].firstMatch.tap()
        let scan = app.buttons["ScanMechanicalText"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5)); scan.tap()
        let candidate = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'TextCandidate-'")).firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 15)); candidate.tap()
        let preview = app.buttons["ViewCandidateSource"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5)); preview.tap()
        let close = app.buttons["Close source"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let source = XCTAttachment(screenshot: app.screenshot()); source.name = "Candidate original source page"; source.lifetime = .keepAlways; add(source)
        close.tap()
        func fill(_ id: String, _ text: String) {
            let field = app.textFields[id]
            for _ in 0..<10 { if field.isHittable { break }; app.swipeUp() }
            field.tap(); field.typeText(text)
        }
        fill("CandidateRFIQuestion", "Confirm applicability and the associated equipment before takeoff.")
        fill("CandidateRFIImpact", "Quantity and equipment relationship remain unverified.")
        fill("CandidateRFIAuthor", "Synthetic reviewer")
        let save = app.buttons["SaveCandidateRFI"]
        for _ in 0..<10 { if save.isHittable { break }; app.swipeUp() }
        save.tap()
        XCTAssertTrue(app.staticTexts["CandidateRFISaved"].waitForExistence(timeout: 5))
        let saved = XCTAttachment(screenshot: app.screenshot()); saved.name = "Candidate RFI saved"; saved.lifetime = .keepAlways; add(saved)
        app.buttons["Done"].firstMatch.tap()
        app.staticTexts["RFIs"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Confirm applicability and the associated equipment before takeoff."].waitForExistence(timeout: 5))
    }
}
