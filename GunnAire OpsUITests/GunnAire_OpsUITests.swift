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
    func testServiceCallDetailUsesStateAwareOperationalWorkspaces() throws {
        XCUIDevice.shared.orientation = .portrait
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

        let seededJob = app.buttons["OpenServiceCall-A1000000-0000-4000-8000-000000000002"]
        XCTAssertTrue(seededJob.waitForExistence(timeout: 3))
        for _ in 0..<6 {
            if seededJob.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(seededJob.isHittable)
        seededJob.tap()
        XCTAssertTrue(app.navigationBars["Call Details"].waitForExistence(timeout: 3))

        let workspacePicker = app.segmentedControls["ServiceCallWorkspacePicker"]
        XCTAssertTrue(workspacePicker.exists)
        XCTAssertTrue(workspacePicker.buttons["Billing"].isSelected)
        XCTAssertTrue(app.staticTexts["Documentation"].exists)
        XCTAssertFalse(app.staticTexts["Completion Checklist"].exists)

        workspacePicker.buttons["Work"].tap()
        XCTAssertTrue(workspacePicker.buttons["Work"].isSelected)
        XCTAssertTrue(app.staticTexts["Field Forms"].exists)
        XCTAssertTrue(app.staticTexts["Equipment"].exists)
        XCTAssertTrue(app.staticTexts["Completion Checklist"].exists)
        XCTAssertFalse(app.staticTexts["Documentation"].exists)

        workspacePicker.buttons["History"].tap()
        XCTAssertTrue(workspacePicker.buttons["History"].isSelected)
        XCTAssertTrue(app.staticTexts["Job Activity"].exists)
        XCTAssertTrue(app.staticTexts["Membership & History"].exists)
        XCTAssertFalse(app.staticTexts["Completion Checklist"].exists)

        workspacePicker.buttons["Overview"].tap()
        XCTAssertTrue(workspacePicker.buttons["Overview"].isSelected)
        XCTAssertTrue(app.staticTexts["Customer Contact"].exists)
        XCTAssertFalse(app.staticTexts["Membership & History"].exists)
    }

    @MainActor
    func testCustomerRecordUsesFocusedOperationalWorkspaces() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob"
        ]
        app.launch()

        let customers = app.staticTexts["Customers"]
        XCTAssertTrue(customers.waitForExistence(timeout: 5))
        customers.tap()
        XCTAssertTrue(app.navigationBars["Customers"].waitForExistence(timeout: 3))

        let customerRecord = app.buttons["OpenCustomerRecord-A1000000-0000-4000-8000-000000000001"]
        for _ in 0..<5 {
            if customerRecord.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(customerRecord.waitForExistence(timeout: 3))
        XCTAssertTrue(customerRecord.isHittable)
        customerRecord.tap()
        XCTAssertTrue(app.navigationBars["Edit Customer"].waitForExistence(timeout: 3))

        let workspacePicker = app.segmentedControls["CustomerProfileWorkspacePicker"]
        XCTAssertTrue(workspacePicker.exists)
        XCTAssertTrue(workspacePicker.buttons["Overview"].isSelected)
        XCTAssertTrue(app.staticTexts["Profile Photo"].exists)
        XCTAssertTrue(app.staticTexts["Maintain contact and consent details, review account health, and resolve open balances."].exists)
        XCTAssertFalse(app.staticTexts["Equipment Profiles"].exists)

        workspacePicker.buttons["Systems"].tap()
        XCTAssertTrue(workspacePicker.buttons["Systems"].isSelected)
        XCTAssertTrue(app.staticTexts["Equipment Profiles"].exists)
        XCTAssertTrue(app.staticTexts["Maintain installed equipment, warranty context, service trends, and maintenance agreements."].exists)
        XCTAssertFalse(app.staticTexts["Contact Preferences"].exists)

        workspacePicker.buttons["Files"].tap()
        XCTAssertTrue(workspacePicker.buttons["Files"].isSelected)
        XCTAssertTrue(app.staticTexts["Documents & Photos"].exists)
        XCTAssertFalse(app.staticTexts["Service Agreements"].exists)

        workspacePicker.buttons["History"].tap()
        XCTAssertTrue(workspacePicker.buttons["History"].isSelected)
        XCTAssertTrue(app.staticTexts["Recent Jobs"].exists)
        XCTAssertFalse(app.staticTexts["Documents & Photos"].exists)
    }

    @MainActor
    func testQuickBooksManagementUsesFocusedAccountingWorkspaces() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin"
        ]
        app.launch()

        let quickBooks = app.staticTexts["QuickBooks Management"]
        XCTAssertTrue(quickBooks.waitForExistence(timeout: 5))
        quickBooks.tap()
        XCTAssertTrue(app.navigationBars["QuickBooks Management"].waitForExistence(timeout: 3))

        let workspacePicker = app.segmentedControls["QuickBooksWorkspacePicker"]
        XCTAssertTrue(workspacePicker.exists)
        XCTAssertTrue(workspacePicker.buttons["Overview"].isSelected)
        XCTAssertTrue(app.staticTexts["Connection"].exists)
        XCTAssertTrue(app.staticTexts["Sync Health"].exists)

        workspacePicker.buttons["Sales"].tap()
        XCTAssertTrue(workspacePicker.buttons["Sales"].isSelected)
        XCTAssertTrue(app.staticTexts["Customers"].exists)
        XCTAssertTrue(app.staticTexts["Product Catalog"].exists)
        XCTAssertFalse(app.staticTexts["Sync Health"].exists)
    }

    @MainActor
    func testPaymentsUsesFocusedCollectionWorkspaces() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob"
        ]
        app.launch()

        let payments = app.staticTexts["Payments"]
        XCTAssertTrue(payments.waitForExistence(timeout: 5))
        payments.tap()
        XCTAssertTrue(app.navigationBars["Payments"].waitForExistence(timeout: 3))

        let workspacePicker = app.segmentedControls["PaymentsWorkspacePicker"]
        XCTAssertTrue(workspacePicker.exists)
        XCTAssertTrue(workspacePicker.buttons["Overview"].isSelected)
        XCTAssertTrue(app.staticTexts["Collections Dashboard"].exists)
        XCTAssertTrue(app.staticTexts["Payment Status"].exists)
        XCTAssertFalse(app.staticTexts["Outstanding Invoices"].exists)

        workspacePicker.buttons["Collect"].tap()
        XCTAssertTrue(workspacePicker.buttons["Collect"].isSelected)
        XCTAssertTrue(app.staticTexts["Outstanding Invoices"].exists)
        XCTAssertTrue(app.staticTexts["Record Payment"].exists)
        XCTAssertFalse(app.staticTexts["Collections Dashboard"].exists)

        workspacePicker.buttons["History"].tap()
        XCTAssertTrue(workspacePicker.buttons["History"].isSelected)
        XCTAssertTrue(app.staticTexts["Shared Field Collections"].exists)
        XCTAssertTrue(app.staticTexts["Payment History"].exists)
        XCTAssertFalse(app.staticTexts["Outstanding Invoices"].exists)
    }

    @MainActor
    func testReceiptsBillsUsesRoleAwareOperationalWorkspaces() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin"
        ]
        app.launch()

        let receiptsBills = app.staticTexts["Receipts & Bills"]
        XCTAssertTrue(receiptsBills.waitForExistence(timeout: 5))
        receiptsBills.tap()
        XCTAssertTrue(app.navigationBars["Receipts & Bills"].waitForExistence(timeout: 3))

        let workspacePicker = app.segmentedControls["ReceiptsBillsWorkspacePicker"]
        XCTAssertTrue(workspacePicker.exists)
        XCTAssertTrue(workspacePicker.buttons["Documents"].isSelected)
        XCTAssertTrue(app.staticTexts["Upload Receipts"].exists)
        XCTAssertTrue(app.staticTexts["Sync and Transactions"].exists)
        XCTAssertFalse(app.staticTexts["Purchase Orders"].exists)

        workspacePicker.buttons["Purchasing"].tap()
        XCTAssertTrue(workspacePicker.buttons["Purchasing"].isSelected)
        XCTAssertTrue(app.staticTexts["Purchase Orders"].exists)
        XCTAssertFalse(app.staticTexts["Upload Receipts"].exists)

        workspacePicker.buttons["Inventory"].tap()
        XCTAssertTrue(workspacePicker.buttons["Inventory"].isSelected)
        XCTAssertTrue(app.staticTexts["Stock & Replenishment"].exists)
        XCTAssertFalse(app.staticTexts["Purchase Orders"].exists)

        workspacePicker.buttons["Recovery"].tap()
        XCTAssertTrue(workspacePicker.buttons["Recovery"].isSelected)
        XCTAssertTrue(app.staticTexts["Failed Upload Queue"].exists)
        XCTAssertFalse(app.staticTexts["Stock & Replenishment"].exists)
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
