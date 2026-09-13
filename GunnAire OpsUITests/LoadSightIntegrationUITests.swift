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
        XCTAssertTrue(app.alerts["Project changes are not exported"].waitForExistence(timeout: 3))
        app.buttons["Keep editing"].tap()
        XCTAssertTrue(app.staticTexts["Job, Cooling system diagnostic"].exists)
        app.buttons["Done"].tap(); app.buttons["Discard changes"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
    }

    @MainActor
    func testLocalDraftRecoversAfterTermination() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let storeID = UUID().uuidString
        app.launchArguments = ["-enableSplashVideo", "NO", "-disableCloudKitForTesting",
            "-uiTestIsolatedStore", storeID, "-appStoreScreenshotFixtures",
            "-GunnAirePendingAppRoute", "estimates"]
        app.launchEnvironment["GUNNAIRE_BACKEND_AUTH_MODE"] = "disabled-for-screenshot"
        app.launch()
        let entry = app.buttons["OpenLoadSightWorkspace"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15)); entry.tap()
        let create = app.buttons["New mechanical project"]
        XCTAssertTrue(create.waitForExistence(timeout: 5)); create.tap()
        let review = app.buttons["ReviewOpsContext"]
        XCTAssertTrue(review.waitForExistence(timeout: 5)); review.tap()
        app.buttons["OpsContextSelection"].tap()
        let job = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Cooling system diagnostic")).firstMatch
        XCTAssertTrue(job.waitForExistence(timeout: 3)); job.tap()
        let author = app.textFields["OpsContextAuthor"]
        author.tap(); author.typeText("UI recovery recorder")
        let reason = app.textViews["OpsContextReason"].exists ? app.textViews["OpsContextReason"] : app.textFields["OpsContextReason"]
        reason.tap(); reason.typeText("Synthetic restart recovery")
        app.swipeUp(); app.buttons["SaveOpsContext"].tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.navigationBars["Ops project link"])
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Draft saved on this device"), object: app.staticTexts["MechanicalRecoveryStatus"])
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
        app.terminate(); app.launch()
        XCTAssertTrue(entry.waitForExistence(timeout: 15)); entry.tap()
        let restore = app.buttons["RestoreMechanicalDraft"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5)); restore.tap()
        XCTAssertTrue(app.staticTexts["Job, Cooling system diagnostic"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Mechanical draft restored after process restart"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["Done"].tap()
        app.buttons["KeepMechanicalDraftAndClose"].firstMatch.tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
        XCTAssertTrue(restore.waitForExistence(timeout: 5)); restore.tap()
        XCTAssertTrue(app.staticTexts["Job, Cooling system diagnostic"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap(); app.buttons["Discard changes"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
        XCTAssertTrue(create.waitForExistence(timeout: 5)); XCTAssertFalse(restore.exists)
        app.buttons["Done"].tap()
    }


    /// Seed with LoadSight/Tools/seed_catalog_ui_fixture.py after installing the simulator app.
    @MainActor
    func testCatalogMaterialSnapshotConversion() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-enableSplashVideo", "NO", "-disableCloudKitForTesting",
            "-uiTestIsolatedStore", "6A70B401-12A4-4779-BBC0-0AAFA681D499", "-appStoreScreenshotFixtures",
            "-GunnAirePendingAppRoute", "estimates"]
        app.launchEnvironment["GUNNAIRE_BACKEND_AUTH_MODE"] = "disabled-for-screenshot"
        app.launch()
        let entry = app.buttons["OpenLoadSightWorkspace"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15)); entry.tap()
        let restore = app.buttons["RestoreMechanicalDraft"]
        guard restore.waitForExistence(timeout: 5) else { throw XCTSkip("Seed the dedicated catalog recovery fixture before running this test.") }
        restore.tap()
        app.staticTexts["Takeoff"].firstMatch.tap()
        let catalog = app.buttons["CatalogCost-CAT-UI"]
        XCTAssertTrue(catalog.waitForExistence(timeout: 5)); catalog.tap()
        XCTAssertTrue(app.navigationBars["Catalog material cost"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["ApplyCatalogMapping"].isEnabled)
        func reveal(_ element: XCUIElement) {
            for _ in 0..<14 {
                if element.exists && element.isHittable && element.frame.minY > 180 && element.frame.maxY < app.frame.height - 60 { return }
                app.swipeUp()
            }
        }
        let confirm = app.switches["CatalogConfirmUSD"].firstMatch
        reveal(confirm); confirm.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["ApplyCatalogMapping"].isEnabled, "USD confirmation must enable the selected mapping")
        let factor = app.textFields["CatalogUnitFactor"]
        reveal(factor); factor.tap()
        factor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (factor.value as? String ?? "").count))
        factor.typeText("0.25")
        let author = app.textFields["CatalogMappingAuthor"]
        reveal(author); author.tap(); author.typeText("UI catalog recorder")
        let reason = app.textViews["CatalogMappingReason"].exists ? app.textViews["CatalogMappingReason"] : app.textFields["CatalogMappingReason"]
        reveal(reason); reason.tap(); reason.typeText("Synthetic revised unit conversion")
        XCTAssertTrue(app.buttons["ApplyCatalogMapping"].isEnabled)
        app.buttons["ApplyCatalogMapping"].tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.navigationBars["Catalog material cost"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue(catalog.waitForExistence(timeout: 5)); catalog.tap()
        XCTAssertTrue(app.staticTexts["Current material cost, $12.50"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Recorded catalog conversion after reopening"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["Cancel"].tap()
        app.buttons["Done"].tap()
        app.buttons["KeepMechanicalDraftAndClose"].firstMatch.tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
    }
}
