//
//  GunnAire_OpsUITests.swift
//  GunnAire OpsUITests
//
//  Created by Eric Gunn on 2/23/26.
//

import XCTest

final class GunnAire_OpsUITests: XCTestCase {

    private let screenshotCustomerID = "A1000000-0000-4000-8000-000000000001"
    private let screenshotServiceCallID = "A1000000-0000-4000-8000-000000000002"
    private let screenshotInvoiceID = "A1000000-0000-4000-8000-000000000003"
    private let screenshotEquipmentID = "A1000000-0000-4000-8000-000000000010"

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
            ("Reports", "Business Reports"),
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
    func testAdministratorCanMapTechnicianToAnExplicitQuickBooksTimeWorker() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob"
        ]
        app.launch()

        app.staticTexts["Sync & Integrations"].tap()
        XCTAssertTrue(app.navigationBars["Sync & Integrations"].waitForExistence(timeout: 3))

        let form = app.collectionViews["SyncIntegrationsForm"]
        XCTAssertTrue(form.waitForExistence(timeout: 3))
        let editButton = app.buttons["EditTechnician-A1000000-0000-4000-8000-000000000006"]
        for _ in 0..<12 where !editButton.exists {
            form.swipeUp()
        }
        XCTAssertTrue(editButton.waitForExistence(timeout: 3))
        editButton.tap()

        let editor = app.navigationBars["Edit Technician"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        let quickBooksWorkerID = app.textFields["TechnicianQBOTimeEntityRef"]
        XCTAssertTrue(quickBooksWorkerID.waitForExistence(timeout: 3))
        quickBooksWorkerID.tap()
        quickBooksWorkerID.typeText("QBO-EMP-42")
        editor.buttons["Save"].tap()

        XCTAssertTrue(app.navigationBars["Sync & Integrations"].waitForExistence(timeout: 3))
        XCTAssertTrue(editButton.waitForExistence(timeout: 3))
        editButton.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields["TechnicianQBOTimeEntityRef"].value as? String, "QBO-EMP-42")
    }

    @MainActor
    func testBusinessReportsUsesFocusedManagementWorkspaces() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob"
        ]
        app.launch()

        let reports = app.staticTexts["Reports"]
        XCTAssertTrue(reports.waitForExistence(timeout: 5))
        reports.tap()
        XCTAssertTrue(app.navigationBars["Business Reports"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Financial Pulse"].exists)
        XCTAssertTrue(app.buttons["Export CSV"].exists)

        let overviewAttachment = XCTAttachment(screenshot: app.screenshot())
        overviewAttachment.name = "Business Reports Overview"
        overviewAttachment.lifetime = .keepAlways
        add(overviewAttachment)

        let workspace = app.segmentedControls["BusinessReportWorkspacePicker"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 3))
        workspace.buttons["Sales"].tap()
        XCTAssertTrue(app.staticTexts["Sales Performance"].waitForExistence(timeout: 3))
        workspace.buttons["Operations"].tap()
        XCTAssertTrue(app.staticTexts["Operations Quality"].waitForExistence(timeout: 3))
        workspace.buttons["Team"].tap()
        XCTAssertTrue(app.staticTexts["Team Activity"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testAdministratorSettingsKeepsServerReadinessFocusedAndDiscoverable() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin"
        ]
        app.launch()

        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))

        let settingsArea = app.segmentedControls.firstMatch
        XCTAssertTrue(settingsArea.waitForExistence(timeout: 3))
        settingsArea.buttons["Sync"].tap()

        let settingsForm = app.collectionViews["SettingsForm"]
        XCTAssertTrue(settingsForm.waitForExistence(timeout: 3))
        func reveal(_ element: XCUIElement, maximumSwipes: Int = 4) -> Bool {
            if element.waitForExistence(timeout: 1) {
                return true
            }
            for _ in 0..<maximumSwipes {
                settingsForm.swipeUp()
                if element.waitForExistence(timeout: 1) {
                    return true
                }
            }
            return false
        }

        XCTAssertTrue(reveal(app.staticTexts["Shared Server Readiness"]))
        XCTAssertTrue(app.buttons["BackendReadinessRefreshButton"].exists)
        XCTAssertTrue(reveal(app.staticTexts["Customer Portal"], maximumSwipes: 2))
        XCTAssertTrue(reveal(app.staticTexts["Shared Server Activity"], maximumSwipes: 2))
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
    func testPendingEstimateRequiresTraceableCustomerApprovalEvidence() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedPendingEstimate"
        ]
        app.launch()

        let schedule = app.staticTexts["Schedule & Jobs"]
        XCTAssertTrue(schedule.waitForExistence(timeout: 5))
        schedule.tap()

        let documentation = app.buttons["OpenDocumentation-A1000000-0000-4000-8000-000000000002"]
        for _ in 0..<6 {
            if documentation.exists && documentation.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(documentation.waitForExistence(timeout: 3))
        documentation.tap()

        let approval = app.buttons["Record Customer Approval"]
        for _ in 0..<10 {
            if approval.exists && approval.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(approval.waitForExistence(timeout: 3))
        approval.tap()

        XCTAssertTrue(app.navigationBars["Customer Approval"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Customer"].exists)
        XCTAssertTrue(app.staticTexts["Total"].exists)
        XCTAssertFalse(app.buttons["Approve"].isEnabled)

        app.buttons["EstimateApprovalMethodPicker"].tap()
        app.buttons["Email approval"].tap()
        let reference = app.textFields["Email subject, message ID, or brief note"]
        XCTAssertTrue(reference.waitForExistence(timeout: 2))
        reference.tap()
        reference.typeText("Approved by reply to estimate email")
        if app.keyboards.buttons["Hide keyboard"].exists {
            app.keyboards.buttons["Hide keyboard"].tap()
        }
        let confirmation = app.switches["Customer reviewed the scope, total price, and terms"]
        confirmation.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(confirmation.value as? String, "1")
        let approveButton = app.buttons["Approve"]
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: approveButton
        )
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 3), .completed)
        approveButton.tap()

        XCTAssertTrue(app.navigationBars["Job Documentation"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Method: Email approval"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testAcceptedStandaloneEstimateCreatesOneScheduledWorkOrderAndHandsOffToDispatch() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedAcceptedStandaloneEstimate"
        ]
        app.launch()

        let estimates = app.staticTexts["Estimates"]
        if !estimates.waitForExistence(timeout: 2) {
            let sidebarButton = app.buttons["GunnAire Ops"]
            XCTAssertTrue(sidebarButton.waitForExistence(timeout: 3))
            sidebarButton.tap()
        }
        XCTAssertTrue(estimates.waitForExistence(timeout: 3))
        estimates.tap()
        XCTAssertTrue(app.navigationBars["Estimates"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Accepted Estimates"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Choose the work type and appointment time to create an unassigned work order."].exists)

        let scheduleWork = app.buttons["Schedule Work"]
        for _ in 0..<6 {
            if scheduleWork.exists && scheduleWork.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(scheduleWork.waitForExistence(timeout: 3))
        scheduleWork.tap()

        XCTAssertTrue(app.navigationBars["Schedule Approved Work"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Approved Scope"].exists)
        let unassignedGuidance = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'The work order starts unassigned'")
        ).firstMatch
        XCTAssertTrue(unassignedGuidance.exists)
        let createWorkOrder = app.buttons["Create Work Order"]
        XCTAssertTrue(createWorkOrder.isEnabled)
        createWorkOrder.tap()

        XCTAssertTrue(app.navigationBars["Call Details"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Customer: UI Test Collectible Customer"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Technician: Unassigned"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testAssignedTechnicianAddsInvoiceItemAndUpdatesExistingInvoice() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedTechnician",
            "-uiTestSeedCollectibleJob"
        ]
        app.launch()

        let schedule = app.staticTexts["Schedule & Jobs"]
        XCTAssertTrue(schedule.waitForExistence(timeout: 5))
        schedule.tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        let documentation = app.buttons["OpenDocumentation-A1000000-0000-4000-8000-000000000002"]
        for _ in 0..<6 {
            if documentation.exists && documentation.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(documentation.waitForExistence(timeout: 3))
        documentation.tap()

        XCTAssertTrue(app.navigationBars["Job Documentation"].waitForExistence(timeout: 3))
        let stagePicker = app.segmentedControls["JobDocumentationStagePicker"]
        XCTAssertTrue(stagePicker.waitForExistence(timeout: 3))
        XCTAssertTrue(stagePicker.buttons["Billing"].isSelected)
        XCTAssertFalse(app.buttons["Create Invoice"].exists)
        XCTAssertTrue(app.staticTexts["HVAC Diagnostic Service"].exists)

        let addLineItems = app.buttons["Add Line Items"]
        XCTAssertTrue(addLineItems.exists)
        let createNewItem = app.buttons["Create New Item"]
        XCTAssertTrue(createNewItem.exists)
        createNewItem.tap()

        XCTAssertTrue(app.navigationBars["Create Item"].waitForExistence(timeout: 3))
        let itemName = app.textFields["Item name"]
        XCTAssertTrue(itemName.exists)
        itemName.tap()
        itemName.typeText("UI Test Added Repair")
        let salesPrice = app.textFields["Sales price (optional)"]
        XCTAssertTrue(salesPrice.exists)
        salesPrice.tap()
        salesPrice.typeText("100")
        app.buttons["Save"].tap()

        XCTAssertTrue(app.navigationBars["Job Documentation"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["UI Test Added Repair"].waitForExistence(timeout: 3))
        let updateInvoice = app.buttons["Update Invoice"]
        for _ in 0..<5 {
            if updateInvoice.exists && updateInvoice.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(updateInvoice.waitForExistence(timeout: 3))
        XCTAssertTrue(updateInvoice.isEnabled)
        updateInvoice.tap()

        XCTAssertTrue(app.staticTexts["QuickBooks update pending"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.staticTexts["QuickBooks is not connected. Reconnect and update this invoice again to publish its current line items."].exists
        )
        XCTAssertTrue(app.buttons["Update Invoice"].exists)
    }

    @MainActor
    func testAssignedTechnicianRecordsBilledPartUseAgainstTruckStock() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedTechnician",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedInventoryJob"
        ]
        app.launch()

        let schedule = app.staticTexts["Schedule & Jobs"]
        XCTAssertTrue(schedule.waitForExistence(timeout: 5))
        schedule.tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        let documentation = app.buttons["OpenDocumentation-A1000000-0000-4000-8000-000000000002"]
        for _ in 0..<6 {
            if documentation.exists && documentation.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(documentation.waitForExistence(timeout: 3))
        documentation.tap()

        XCTAssertTrue(app.navigationBars["Job Documentation"].waitForExistence(timeout: 3))
        let stagePicker = app.segmentedControls["JobDocumentationStagePicker"]
        XCTAssertTrue(stagePicker.waitForExistence(timeout: 3))
        XCTAssertTrue(stagePicker.buttons["Billing"].isSelected)

        let recordUse = app.buttons["RecordJobMaterialUse-A1000000-0000-4000-8000-000000000013"]
        for _ in 0..<8 {
            if recordUse.exists && recordUse.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(recordUse.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Invoice 1 • Used 0 • Reserved 1"].exists)
        XCTAssertTrue(app.staticTexts["Available to this job: 3"].exists)
        recordUse.tap()

        XCTAssertTrue(app.staticTexts["Stock use recorded"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Invoice 1 • Used 1 • Reserved 0"].exists)
        XCTAssertFalse(recordUse.exists)
    }

    @MainActor
    func testJobMaterialShortageBecomesAnAdministratorReviewedRestockDraft() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedInventoryShortage"
        ]
        app.launch()

        let schedule = app.staticTexts["Schedule & Jobs"]
        XCTAssertTrue(schedule.waitForExistence(timeout: 5))
        schedule.tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        let documentation = app.buttons["OpenDocumentation-A1000000-0000-4000-8000-000000000002"]
        for _ in 0..<6 {
            if documentation.exists && documentation.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(documentation.waitForExistence(timeout: 3))
        documentation.tap()
        XCTAssertTrue(app.navigationBars["Job Documentation"].waitForExistence(timeout: 3))

        let recordUse = app.buttons["RecordJobMaterialUse-A1000000-0000-4000-8000-000000000013"]
        for _ in 0..<8 {
            if recordUse.exists && recordUse.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(recordUse.waitForExistence(timeout: 3))
        recordUse.tap()
        XCTAssertTrue(app.staticTexts["Stock use recorded"].waitForExistence(timeout: 3))

        let requestRestock = app.buttons["RequestRestock-A1000000-0000-4000-8000-000000000013"]
        for _ in 0..<4 {
            if requestRestock.exists && requestRestock.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(requestRestock.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Truck – UI Test Technician needs 1.5 to reach its reorder point"].exists)
        requestRestock.tap()

        let requestStatus = app.staticTexts["RestockRequestStatus-A1000000-0000-4000-8000-000000000013"]
        XCTAssertTrue(requestStatus.waitForExistence(timeout: 3))
        XCTAssertTrue(requestStatus.label.hasPrefix("Requested • PO-"))

        let jobBackButton = app.navigationBars["Job Documentation"].buttons.firstMatch
        XCTAssertTrue(jobBackButton.exists)
        jobBackButton.tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        let receiptsBills = app.staticTexts["Receipts & Bills"]
        XCTAssertTrue(receiptsBills.waitForExistence(timeout: 3))
        receiptsBills.tap()
        XCTAssertTrue(app.navigationBars["Receipts & Bills"].waitForExistence(timeout: 3))
        let workspacePicker = app.segmentedControls["ReceiptsBillsWorkspacePicker"]
        XCTAssertTrue(workspacePicker.waitForExistence(timeout: 3))
        workspacePicker.buttons["Purchasing"].tap()

        let prepareDraft = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'PrepareRestockRequest-'")
        ).firstMatch
        for _ in 0..<10 {
            if prepareDraft.exists && prepareDraft.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(prepareDraft.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Field restock request • review the supplier, quantity, and cost before creating an order."].exists)
        prepareDraft.tap()

        let preparedMessage = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Prepared PO-'")
        ).firstMatch
        XCTAssertTrue(preparedMessage.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Draft"].exists)
        XCTAssertFalse(prepareDraft.exists)
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
        for _ in 0..<6 {
            if seededJob.exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(seededJob.waitForExistence(timeout: 3))
        for _ in 0..<3 {
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
    func testCorrectiveVisitLinksOriginalAndFollowUpJobs() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedCorrectiveLineage"
        ]
        app.launch()

        let schedule = app.staticTexts["Schedule & Jobs"]
        XCTAssertTrue(schedule.waitForExistence(timeout: 5))
        schedule.tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        let sourceJob = app.buttons["OpenServiceCall-A1000000-0000-4000-8000-000000000008"]
        for _ in 0..<6 {
            if sourceJob.exists && sourceJob.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(sourceJob.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["CorrectiveStatus-A1000000-0000-4000-8000-000000000008"].exists)
        sourceJob.tap()
        XCTAssertTrue(app.navigationBars["Call Details"].waitForExistence(timeout: 3))

        let workspacePicker = app.segmentedControls["ServiceCallWorkspacePicker"]
        XCTAssertTrue(workspacePicker.waitForExistence(timeout: 3))
        workspacePicker.buttons["Overview"].tap()
        XCTAssertTrue(app.staticTexts["Corrective Work"].exists)
        XCTAssertTrue(app.staticTexts["Reason: Workmanship"].exists)

        let openFollowUp = app.buttons["OpenScheduledFollowUpServiceCall"]
        XCTAssertTrue(openFollowUp.waitForExistence(timeout: 3))
        openFollowUp.tap()
        XCTAssertTrue(app.navigationBars["Call Details"].waitForExistence(timeout: 3))

        let followUpPicker = app.segmentedControls["ServiceCallWorkspacePicker"]
        followUpPicker.buttons["Overview"].tap()
        XCTAssertTrue(app.buttons["OpenOriginatingServiceCall"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Reason: Workmanship"].exists)
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
        XCTAssertTrue(app.staticTexts["Service Locations"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Primary Service Location"].exists)
        XCTAssertTrue(app.staticTexts["Equipment Profiles"].exists)
        XCTAssertTrue(app.staticTexts["Maintain installed equipment, warranty context, service trends, and maintenance agreements."].exists)
        let agreementVisitHistory = app.staticTexts["Visit history: 0 completed • 1 scheduled"]
        for _ in 0..<6 {
            if agreementVisitHistory.exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(agreementVisitHistory.waitForExistence(timeout: 3))
        let storedPaymentMethods = app.descendants(matching: .any)["CustomerStoredPaymentMethods"]
        for _ in 0..<6 {
            if storedPaymentMethods.exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(storedPaymentMethods.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Contact Preferences"].exists)

        for _ in 0..<6 {
            if app.segmentedControls["CustomerProfileWorkspacePicker"].exists { break }
            app.swipeDown()
        }
        let restoredWorkspacePicker = app.segmentedControls["CustomerProfileWorkspacePicker"]
        XCTAssertTrue(restoredWorkspacePicker.waitForExistence(timeout: 3))
        restoredWorkspacePicker.buttons["Files"].tap()
        XCTAssertTrue(restoredWorkspacePicker.buttons["Files"].isSelected)
        XCTAssertTrue(app.staticTexts["Documents & Photos"].exists)
        XCTAssertFalse(app.staticTexts["Service Agreements"].exists)

        restoredWorkspacePicker.buttons["History"].tap()
        XCTAssertTrue(restoredWorkspacePicker.buttons["History"].isSelected)
        XCTAssertTrue(app.staticTexts["Recent Jobs"].exists)
        XCTAssertFalse(app.staticTexts["Documents & Photos"].exists)
    }

    @MainActor
    func testScheduledMaintenanceAgreementOpensItsExistingVisitWithoutDuplicatingIt() throws {
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

        let agreementAction = app.buttons["MaintenanceVisitAction-A1000000-0000-4000-8000-000000000011"]
        for _ in 0..<8 {
            if agreementAction.exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(agreementAction.waitForExistence(timeout: 3))
        XCTAssertEqual(agreementAction.label, "Open Scheduled Visit")
        agreementAction.tap()

        XCTAssertTrue(app.navigationBars["Call Details"].waitForExistence(timeout: 3))
        let workspacePicker = app.segmentedControls["ServiceCallWorkspacePicker"]
        XCTAssertTrue(workspacePicker.waitForExistence(timeout: 3))
        workspacePicker.buttons["Overview"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["LinkedMaintenanceAgreementVisit"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Comfort Care"].exists)
    }

    @MainActor
    func testFieldTechnicianScheduleHidesAgreementManagementAttention() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedTechnician",
            "-uiTestSeedCollectibleJob"
        ]
        app.launch()

        let schedule = app.staticTexts["Schedule & Jobs"]
        XCTAssertTrue(schedule.waitForExistence(timeout: 5))
        schedule.tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        for _ in 0..<8 {
            XCTAssertFalse(app.staticTexts["Maintenance Attention"].exists)
            XCTAssertFalse(app.buttons["MaintenanceVisitAction-A1000000-0000-4000-8000-000000000011"].exists)
            app.swipeUp()
        }
    }

    @MainActor
    func testStandardCustomerRecordIsReadOnlyAndKeepsReviewNavigation() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedStandard",
            "-uiTestSeedCollectibleJob"
        ]
        app.launch()

        let customers = app.staticTexts["Customers"]
        XCTAssertTrue(customers.waitForExistence(timeout: 5))
        customers.tap()
        XCTAssertTrue(app.navigationBars["Customers"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Add Customer"].exists)
        XCTAssertFalse(app.buttons["Sync"].exists)

        let customerRecord = app.buttons["OpenCustomerRecord-A1000000-0000-4000-8000-000000000001"]
        for _ in 0..<5 {
            if customerRecord.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(customerRecord.waitForExistence(timeout: 3))
        customerRecord.tap()
        XCTAssertTrue(app.navigationBars["Customer Record"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["CustomerRecordReadOnlyNotice"].exists)
        XCTAssertFalse(app.buttons["Save"].exists)
        XCTAssertTrue(app.buttons["Done"].exists)

        let workspacePicker = app.segmentedControls["CustomerProfileWorkspacePicker"]
        XCTAssertTrue(workspacePicker.exists)
        workspacePicker.buttons["Systems"].tap()
        XCTAssertTrue(app.staticTexts["Equipment Profiles"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["CustomerStoredPaymentMethods"].exists)
        XCTAssertFalse(app.buttons["Add Equipment Profile"].exists)
        XCTAssertFalse(app.buttons["Edit"].exists)

        workspacePicker.buttons["Files"].tap()
        XCTAssertTrue(app.staticTexts["Documents & Photos"].exists)
        XCTAssertFalse(app.buttons["Camera"].exists)
        XCTAssertFalse(app.staticTexts["Attachment Type"].exists)
    }

    @MainActor
    func testQuickBooksManagementUsesFocusedAccountingWorkspaces() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedPricebookReview"
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
        XCTAssertTrue(app.descendants(matching: .any)["QuickBooksWebhookPendingCount"].exists)

        workspacePicker.buttons["Sales"].tap()
        XCTAssertTrue(workspacePicker.buttons["Sales"].isSelected)
        XCTAssertTrue(app.staticTexts["Local Invoice Publication"].exists)
        XCTAssertTrue(app.staticTexts["UI Test Collectible Customer"].exists)
        XCTAssertTrue(app.buttons["Retry Publication"].exists)
        XCTAssertFalse(app.buttons["Retry Publication"].isEnabled)
        XCTAssertTrue(app.buttons["Open Job Billing"].exists)
        XCTAssertTrue(app.staticTexts["Pricebook Review"].exists)
        XCTAssertTrue(app.staticTexts["HVAC Diagnostic Service"].exists)
        let approvePricebookItem = app.buttons["Approve Pricebook Item"]
        for _ in 0..<3 where !approvePricebookItem.exists {
            app.swipeUp()
        }
        XCTAssertTrue(approvePricebookItem.waitForExistence(timeout: 3))
        approvePricebookItem.tap()
        XCTAssertTrue(app.staticTexts["No field-created catalog items need review."].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Customers"].exists)
        XCTAssertTrue(app.staticTexts["Product Catalog"].exists)
        XCTAssertFalse(app.staticTexts["Sync Health"].exists)

        workspacePicker.buttons["Payments"].tap()
        XCTAssertTrue(workspacePicker.buttons["Payments"].isSelected)
        XCTAssertTrue(app.descendants(matching: .any)["QuickBooksLinkedPaymentMethods"].exists)
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

    /// Produces customer-safe, repeatable App Store assets from Debug-only
    /// fixture data. The same route-driven workflow runs on iPad and iPhone;
    /// the capture command selects the appropriate simulator and orientation.
    @MainActor
    func testCaptureAppStoreScreenshots() throws {
        XCUIDevice.shared.orientation = .portrait

        captureAppStoreScreenshot(
            name: "01-command-center",
            expectedNavigationTitle: "Command Center"
        )
        captureAppStoreScreenshot(
            name: "02-schedule",
            route: "scheduleAndJobs",
            expectedNavigationTitle: "Schedule"
        )
        captureAppStoreScreenshot(
            name: "03-customer-systems",
            route: "customers",
            extraArguments: ["-GunnAirePendingCustomerID", screenshotCustomerID],
            expectedNavigationTitle: "Edit Customer",
            afterLaunch: { app in
                let workspace = app.segmentedControls["CustomerProfileWorkspacePicker"]
                XCTAssertTrue(workspace.waitForExistence(timeout: 5))
                workspace.buttons["Systems"].tap()
                XCTAssertTrue(app.staticTexts["Equipment Profiles"].waitForExistence(timeout: 3))
                let editEquipment = app.buttons["EditEquipment-\(screenshotEquipmentID)"]
                for _ in 0..<5 where !editEquipment.exists || !editEquipment.isHittable {
                    app.swipeUp()
                }
                XCTAssertTrue(editEquipment.waitForExistence(timeout: 3))
                editEquipment.tap()
                XCTAssertTrue(app.staticTexts["Heat Pump"].waitForExistence(timeout: 3))
            }
        )
        captureAppStoreScreenshot(
            name: "04-job-billing",
            route: "onsiteDocumentation",
            extraArguments: ["-GunnAirePendingServiceCallID", screenshotServiceCallID],
            expectedNavigationTitle: "Job Documentation"
        )
        captureAppStoreScreenshot(
            name: "05-field-collection",
            route: "payments",
            extraArguments: [
                "-GunnAirePendingInvoiceID", screenshotInvoiceID,
                "-GunnAirePendingOpenPaymentCollection", "YES"
            ],
            expectedNavigationTitle: "Record Payment"
        )
        captureAppStoreScreenshot(
            name: "06-quickbooks-sales",
            route: "quickBooksManagement",
            expectedNavigationTitle: "QuickBooks Management",
            afterLaunch: { app in
                let workspace = app.segmentedControls["QuickBooksWorkspacePicker"]
                XCTAssertTrue(workspace.waitForExistence(timeout: 5))
                workspace.buttons["Sales"].tap()
                XCTAssertTrue(app.staticTexts["Local Invoice Publication"].waitForExistence(timeout: 3))
            }
        )
    }

    @MainActor
    private func captureAppStoreScreenshot(
        name: String,
        route: String? = nil,
        extraArguments: [String] = [],
        expectedNavigationTitle: String,
        afterLaunch: (XCUIApplication) -> Void = { _ in }
    ) {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-appStoreScreenshotFixtures"
        ]
        if let route {
            app.launchArguments += ["-GunnAirePendingAppRoute", route]
        }
        app.launchArguments += extraArguments
        app.launch()

        XCTAssertTrue(
            app.navigationBars[expectedNavigationTitle].waitForExistence(timeout: 8),
            "Failed to reach screenshot route \(name)"
        )
        let window = app.windows.firstMatch
        let orientationExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in window.frame.height > window.frame.width },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [orientationExpectation], timeout: 5),
            .completed,
            "App window did not finish rotating for screenshot \(name)"
        )
        afterLaunch(app)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
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
