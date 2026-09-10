import XCTest

final class LoadSightIntegrationUITests: XCTestCase {
    @MainActor
    func testEmbeddedWorkspaceOpensFromEstimates() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-enableSplashVideo", "NO", "-disableCloudKitForTesting",
            "-uiTestIsolatedStore", UUID().uuidString, "-appStoreScreenshotFixtures",
            "-GunnAirePendingAppRoute", "estimates"]
        app.launchEnvironment["GUNNAIRE_BACKEND_AUTH_MODE"] = "disabled-for-screenshot"
        app.launch()
        XCTAssertTrue(app.navigationBars["Estimates"].waitForExistence(timeout: 15))
        let entry = app.buttons["OpenLoadSightWorkspace"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        XCTAssertTrue(app.staticTexts["Mechanical project workspace"].waitForExistence(timeout: 5))
        app.buttons["New mechanical project"].tap()
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Draft — not for bid release"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "LoadSight embedded in Ops"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Done"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
    }
    @MainActor
    func testCustomerJobLinkAndUnsavedProjectGuard() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-enableSplashVideo", "NO", "-disableCloudKitForTesting",
            "-uiTestIsolatedStore", UUID().uuidString, "-appStoreScreenshotFixtures",
            "-GunnAirePendingAppRoute", "estimates"]
        app.launchEnvironment["GUNNAIRE_BACKEND_AUTH_MODE"] = "disabled-for-screenshot"
        app.launch()
        let entry = app.buttons["OpenLoadSightWorkspace"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15)); entry.tap()
        app.buttons["New mechanical project"].tap()
        let review = app.buttons["ReviewOpsContext"]
        XCTAssertTrue(review.waitForExistence(timeout: 5)); review.tap()
        app.buttons["OpsContextSelection"].tap()
        let job = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Cooling system diagnostic")).firstMatch
        XCTAssertTrue(job.waitForExistence(timeout: 3)); job.tap()
        let author = app.textFields["OpsContextAuthor"]
        author.tap(); author.typeText("UI link recorder")
        let reason = app.textViews["OpsContextReason"].exists ? app.textViews["OpsContextReason"] : app.textFields["OpsContextReason"]
        reason.tap(); reason.typeText("Synthetic UI link")
        app.swipeUp()
        app.buttons["SaveOpsContext"].tap()
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.navigationBars["Ops project link"])
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        XCTAssertTrue(app.staticTexts["Customer, Blue Ridge Dental"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Job, Cooling system diagnostic"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Recorded Ops customer and job"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.alerts["Discard unsaved project changes?"].waitForExistence(timeout: 3))
        app.buttons["Keep editing"].tap()
        XCTAssertTrue(app.staticTexts["Job, Cooling system diagnostic"].exists)
        app.buttons["Done"].tap(); app.buttons["Discard changes"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
    }

}
