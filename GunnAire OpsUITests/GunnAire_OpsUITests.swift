//
//  GunnAire_OpsUITests.swift
//  GunnAire OpsUITests
//
//  Created by Eric Gunn on 2/23/26.
//

import XCTest

final class GunnAire_OpsUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testUnauthenticatedLaunchShowsTheSecureSignInGate() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-hasAuthenticatedUser", "NO",
            "-disableCloudKitForTesting"
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["GunnAire Ops"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Sign in with your GunnAire Google account."].exists)
        XCTAssertTrue(app.buttons["Sign In With Google"].exists)
    }

    @MainActor
    func testAuthenticatedAdminLaunchShowsTheIPadOperationsWorkspace() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["GunnAire Ops"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Operations"].exists)
        XCTAssertTrue(app.staticTexts["Command Center"].exists)
        XCTAssertTrue(app.staticTexts["Schedule & Jobs"].exists)
        XCTAssertTrue(app.staticTexts["Customers"].exists)
        XCTAssertTrue(app.staticTexts["Back Office"].exists)
        XCTAssertTrue(app.staticTexts["Payments"].exists)
        XCTAssertTrue(app.staticTexts["Administrator"].exists)
        XCTAssertTrue(app.staticTexts["QuickBooks Management"].exists)

        app.staticTexts["Schedule & Jobs"].tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        app.staticTexts["Payments"].tap()
        XCTAssertTrue(app.navigationBars["Payments"].waitForExistence(timeout: 3))
    }

    /// The iPad workspace intentionally has a small, role-aware sidebar rather
    /// than putting every workflow in the Command Center. This smoke test
    /// verifies that the primary administrative destinations remain reachable
    /// from that single navigation surface as the app evolves.
    @MainActor
    func testAuthenticatedAdminCanNavigatePrimaryIPadWorkspaces() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin"
        ]
        app.launch()

        let destinations: [(sidebar: String, title: String)] = [
            ("Clock In/Out", "Time Clock"),
            ("Customers", "Customers"),
            ("Mail", "Mail"),
            ("Estimates", "Estimates"),
            ("Invoices", "Invoices"),
            ("Receipts & Bills", "Receipts & Bills"),
            ("Sync & Integrations", "Sync & Integrations"),
            ("Onsite Documentation", "Onsite Documentation"),
            ("QuickBooks Management", "QuickBooks Management")
        ]

        for destination in destinations {
            let sidebarItem = app.staticTexts[destination.sidebar]
            XCTAssertTrue(sidebarItem.waitForExistence(timeout: 3), "Missing sidebar item: \(destination.sidebar)")
            sidebarItem.tap()
            XCTAssertTrue(
                app.navigationBars[destination.title].waitForExistence(timeout: 3),
                "Failed to open \(destination.title) from the iPad sidebar"
            )
        }
    }

    @MainActor
    func testDispatchWeekBoardOpensAsDedicatedIPadWorkspace() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob"
        ]
        app.launch()

        let schedule = app.staticTexts["Schedule & Jobs"]
        XCTAssertTrue(schedule.waitForExistence(timeout: 5))
        schedule.tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        let weekBoard = app.buttons["Week Board"]
        XCTAssertTrue(weekBoard.waitForExistence(timeout: 3))
        weekBoard.tap()

        XCTAssertTrue(app.navigationBars["Dispatch Week"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Drag a job to another day. Its time stays the same."].exists)
        XCTAssertTrue(app.buttons["Today"].exists)
        XCTAssertTrue(app.buttons["Done"].exists)

        let seededJob = app.descendants(matching: .any)["DispatchJobCard-A1000000-0000-4000-8000-000000000002"]
        XCTAssertTrue(seededJob.waitForExistence(timeout: 3))
        seededJob.tap()
        XCTAssertTrue(app.navigationBars["Edit Service Call"].waitForExistence(timeout: 3))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Dispatch Week"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testScheduleCollectionActionOpensInvoiceCloseout() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob"
        ]
        app.launch()

        let schedule = app.staticTexts["Schedule & Jobs"]
        XCTAssertTrue(schedule.waitForExistence(timeout: 5))
        schedule.tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        let collect = app.buttons["Collect"].firstMatch
        for _ in 0..<5 {
            if collect.exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(collect.waitForExistence(timeout: 3))
        collect.tap()

        XCTAssertTrue(app.navigationBars["Finalize Invoice"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["UI Test Collectible Customer"].exists)
        XCTAssertTrue(app.staticTexts["Balance due: $189.00"].exists)
    }

    @MainActor
    func testJobDocumentationOpensAtTheRecommendedBillingStage() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob"
        ]
        app.launch()

        let schedule = app.staticTexts["Schedule & Jobs"]
        XCTAssertTrue(schedule.waitForExistence(timeout: 5))
        schedule.tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        let documentation = app.buttons["OpenDocumentation-A1000000-0000-4000-8000-000000000002"]
        for _ in 0..<5 {
            if documentation.exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(documentation.waitForExistence(timeout: 3))
        documentation.tap()

        XCTAssertTrue(app.navigationBars["Job Documentation"].waitForExistence(timeout: 3))
        let stagePicker = app.segmentedControls["JobDocumentationStagePicker"]
        XCTAssertTrue(stagePicker.exists)
        XCTAssertTrue(stagePicker.buttons["Billing"].isSelected)
        XCTAssertTrue(app.staticTexts["Documentation Builder"].exists)
        XCTAssertFalse(app.staticTexts["Technical Service Report"].exists)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        let app = XCUIApplication()
        // Keep the performance launch on the same isolated SwiftData path as
        // the other UI tests. The simulator has no production CloudKit
        // entitlement, and allowing this one test to initialize the private
        // store can interfere with later model-container tests.
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting"
        ]
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            app.launch()
        }
    }
}
