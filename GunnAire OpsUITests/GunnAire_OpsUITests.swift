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
    private let maintenanceServiceCallID = "A1000000-0000-4000-8000-000000000012"
    private let serviceRequestID = "A1000000-0000-4000-8000-000000000019"
    private let projectDepositMilestoneID = "A1000000-0000-4000-8000-000000000023"
    private let catalogItemID = "A1000000-0000-4000-8000-000000000007"
    private let unassignedScheduleServiceCallID = "A1000000-0000-4000-8000-000000000029"
    private let servicePackageItemID = "A1000000-0000-4000-8000-000000000032"
    private let warrantyClaimID = "A1000000-0000-4000-8000-000000000037"
    private let fieldExpenseClaimID = "A1000000-0000-4000-8000-000000000041"
    private let operationalAlertID = "A1000000-0000-4000-8000-000000000042"
    private let businessTaskID = "A1000000-0000-4000-8000-000000000043"
    private let timeOffRequestID = "A1000000-0000-4000-8000-000000000045"
    private let archivedCatalogItemID = "A1000000-0000-4000-8000-000000000049"
    private let adminWorkspaceDestinations: [(sidebar: String, route: String, title: String)] = [
        ("Command Center", "commandCenter", "Command Center"),
        ("Clock In/Out", "timeClock", "Time Clock"),
        ("Schedule & Jobs", "scheduleAndJobs", "Schedule"),
        ("Customers", "customers", "Customers"),
        ("Onsite Documentation", "onsiteDocumentation", "Onsite Documentation"),
        ("Mail", "mail", "Inbox"),
        ("Estimates", "estimates", "Estimates"),
        ("Invoices", "invoices", "Invoices"),
        ("Payments", "payments", "Payments"),
        ("Reports", "reports", "Business Reports"),
        ("Receipts & Bills", "receiptsBills", "Receipts & Bills"),
        ("Sync & Integrations", "syncIntegrations", "Sync & Integrations"),
        ("QuickBooks Management", "quickBooksManagement", "QuickBooks Management")
    ]

    private func dispatchCapacityIdentifier(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "DispatchCapacityDate-%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private func startOfDispatchWeek(containing date: Date) -> Date {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)
        let offsetFromMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -offsetFromMonday, to: day) ?? day
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: element
        )
        return XCTWaiter.wait(for: [hittable], timeout: timeout) == .completed
    }

    @MainActor
    private func openRoleAwareFind(in app: XCUIApplication) {
        let globalFind = app.buttons["GlobalFindButton"]
        if waitForHittable(globalFind, timeout: 1) {
            globalFind.tap()
            return
        }

        let commandCenterFind = app.buttons["CommandCenterToolbarFindButton"]
        XCTAssertTrue(
            waitForHittable(commandCenterFind),
            "Find must remain reachable from the visible compact or regular navigation surface."
        )
        commandCenterFind.tap()
    }

    @MainActor
    private func revealSidebar(in app: XCUIApplication) -> XCUIElement {
        let regularSidebar = app.collectionViews["Sidebar"]
        if regularSidebar.waitForExistence(timeout: 1) {
            return regularSidebar
        }

        let compactRoot = app.navigationBars["GunnAire Ops"]
        if !compactRoot.exists {
            let sidebarButton = app.buttons["GunnAire Ops"]
            XCTAssertTrue(
                waitForHittable(sidebarButton),
                "The compact workspace must provide a route back to GunnAire Ops navigation."
            )
            sidebarButton.tap()
        }
        XCTAssertTrue(
            compactRoot.waitForExistence(timeout: 3),
            "GunnAire Ops navigation did not appear."
        )

        // NavigationSplitView exposes the regular-width sidebar with the
        // "Sidebar" label. Its compact iPhone root is the same SwiftUI List,
        // but UIKit intentionally leaves that collection view unlabeled.
        let compactSidebar = app.collectionViews.firstMatch
        XCTAssertTrue(
            compactSidebar.waitForExistence(timeout: 3),
            "The compact GunnAire Ops navigation list did not appear."
        )
        return compactSidebar
    }

    @MainActor
    private func revealSidebarDestination(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let destination = app.staticTexts[title]
        let sidebar = revealSidebar(in: app)
        for _ in 0..<18 where !destination.exists || !destination.isHittable {
            sidebar.swipeUp()
        }
        if !destination.exists || !destination.isHittable {
            for _ in 0..<18 where !destination.exists || !destination.isHittable {
                sidebar.swipeDown()
            }
        }
        XCTAssertTrue(destination.waitForExistence(timeout: 3), "Missing navigation destination: \(title)")
        XCTAssertTrue(destination.isHittable, "Navigation destination is not tappable: \(title)")
        return destination
    }

    @MainActor
    private func assertAllAdminWorkspacesRemainReachable(in app: XCUIApplication) {
        let sidebar = app.collectionViews["Sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))

        // A prior launch may restore the native List's scroll position. Start
        // at the top so this top-to-bottom journey never confuses a matching
        // detail-pane heading with its sidebar destination.
        for _ in 0..<12 {
            sidebar.swipeDown()
        }

        for destination in adminWorkspaceDestinations {
            let sidebarItem = sidebar.staticTexts[destination.sidebar]
            for _ in 0..<24 where !(sidebarItem.exists && sidebarItem.isHittable) {
                sidebar.swipeUp()
            }
            XCTAssertTrue(
                waitForHittable(sidebarItem),
                "Missing reachable sidebar item: \(destination.sidebar)"
            )
            sidebarItem.tap()
            XCTAssertTrue(
                app.navigationBars[destination.title].waitForExistence(timeout: 3),
                "Failed to open \(destination.title) from the iPad sidebar"
            )
        }
    }

    private func replaceText(in field: XCUIElement, with replacement: String) {
        field.tap()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(replacement)

        guard (field.value as? String) != replacement else { return }
        let currentValue = field.value as? String ?? ""
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        field.typeText(
            String(
                repeating: XCUIKeyboardKey.delete.rawValue,
                count: max(currentValue.count, 1)
            )
        )
        field.typeText(replacement)
    }

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
        XCUIDevice.shared.orientation = .portrait
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
        XCTAssertTrue(app.staticTexts["Sign in with your approved GunnAire business account."].exists)
        XCTAssertTrue(app.buttons["Sign In With Google"].exists)
        let appleSignIn = app.buttons["Sign In With Apple"]
        XCTAssertTrue(appleSignIn.exists)
        XCTAssertTrue(appleSignIn.isEnabled)
        XCTAssertFalse(app.staticTexts["Sign in with Apple requires the secure GunnAire backend configuration."].exists)
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
        let accountIdentity = app.staticTexts["SidebarAccountIdentity"]
        XCTAssertTrue(accountIdentity.exists)
        XCTAssertTrue(accountIdentity.label.contains("@"))

        revealSidebarDestination("Schedule & Jobs", in: app).tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        app.staticTexts["Payments"].tap()
        XCTAssertTrue(app.navigationBars["Payments"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testMailWorkspaceUsesASimpleInboxInterface() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-appStoreScreenshotFixtures",
            "-uiTestSeedMailInbox",
            "-GunnAirePendingAppRoute", "mail"
        ]
        app.launchEnvironment["GUNNAIRE_BACKEND_AUTH_MODE"] = "disabled-for-screenshot"
        app.launch()

        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.descendants(matching: .any)["MailInboxList"].exists)
        XCTAssertTrue(app.buttons["MailRefreshButton"].exists)
        XCTAssertTrue(app.buttons["MailComposeButton"].exists)
        XCTAssertFalse(app.staticTexts["Headers"].exists)
        XCTAssertFalse(app.staticTexts["Snippet"].exists)
        XCTAssertFalse(app.staticTexts["Message Body"].exists)
        XCTAssertFalse(app.staticTexts["Status"].exists)

        let inboxEvidence = XCTAttachment(screenshot: app.screenshot())
        inboxEvidence.name = "Simple Mail Inbox"
        inboxEvidence.lifetime = .keepAlways
        add(inboxEvidence)

        app.buttons["MailComposeButton"].tap()
        XCTAssertTrue(app.navigationBars["Compose"].waitForExistence(timeout: 3))
        let composeTo = app.textFields["MailComposeTo"]
        let composeBody = app.textFields["MailComposeBody"]
        XCTAssertTrue(composeTo.exists)
        XCTAssertTrue(app.textFields["MailComposeSubject"].exists)
        XCTAssertTrue(composeBody.exists)
        XCTAssertFalse(app.buttons["MailSendButton"].isEnabled)
        composeTo.tap()
        composeTo.typeText("customer@example.com")
        composeBody.tap()
        composeBody.typeText("Your appointment is confirmed.")
        XCTAssertTrue(app.buttons["MailSendButton"].isEnabled)
        let composeEvidence = XCTAttachment(screenshot: app.screenshot())
        composeEvidence.name = "Simple Mail Compose"
        composeEvidence.lifetime = .keepAlways
        add(composeEvidence)
        app.navigationBars["Compose"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 3))

        let message = app.descendants(matching: .any)["MailMessage-ui-mail-1"]
        XCTAssertTrue(message.waitForExistence(timeout: 3))
        message.tap()

        XCTAssertTrue(app.navigationBars["Mail"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Service appointment confirmed"].exists)
        XCTAssertTrue(app.staticTexts["Jordan Customer <jordan@example.com>"].exists)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'We will see you Tuesday morning'")
        ).firstMatch.exists)
        XCTAssertTrue(app.buttons["MailReplyButton"].exists)
        XCTAssertTrue(app.buttons["MailMoreActionsButton"].exists)
        XCTAssertFalse(app.staticTexts["MIME-Version"].exists)
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] '<div>'")
        ).firstMatch.exists)

        let messageEvidence = XCTAttachment(screenshot: app.screenshot())
        messageEvidence.name = "Simple Mail Message"
        messageEvidence.lifetime = .keepAlways
        add(messageEvidence)

        app.buttons["MailReplyButton"].tap()
        XCTAssertTrue(app.navigationBars["Compose"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields["MailComposeTo"].value as? String, "jordan@example.com")
        XCTAssertEqual(app.textFields["MailComposeSubject"].value as? String, "Re: Service appointment confirmed")
        app.navigationBars["Compose"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Mail"].waitForExistence(timeout: 3))

        app.buttons["MailMoreActionsButton"].tap()
        XCTAssertTrue(app.buttons["Reply All"].exists)
        XCTAssertTrue(app.buttons["Forward"].exists)
        app.buttons["Move to Trash"].tap()
        XCTAssertTrue(app.staticTexts["Move this message to Trash?"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["You can recover it later from Gmail Trash."].exists)
        let trashEvidence = XCTAttachment(screenshot: app.screenshot())
        trashEvidence.name = "Simple Mail Trash Confirmation"
        trashEvidence.lifetime = .keepAlways
        add(trashEvidence)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Mail"].exists)
    }

    @MainActor
    func testInvoiceWorkspaceOpensWithoutTerminating() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-appStoreScreenshotFixtures",
            "-GunnAirePendingAppRoute", "invoices"
        ]
        app.launchEnvironment["GUNNAIRE_BACKEND_AUTH_MODE"] = "disabled-for-screenshot"
        app.launch()

        XCTAssertTrue(
            app.navigationBars["Invoices"].waitForExistence(timeout: 8),
            "The Invoices workspace must open without exhausting the SwiftUI view-construction stack."
        )
        let lanePicker = app.segmentedControls["InvoiceWorkspaceLanePicker"]
        XCTAssertTrue(lanePicker.waitForExistence(timeout: 3))
        XCTAssertTrue(lanePicker.buttons["Overview"].isSelected)
        XCTAssertTrue(app.staticTexts["Collections Queue"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Invoice Details"].exists)

        lanePicker.buttons["New Invoice"].tap()
        XCTAssertTrue(app.staticTexts["Invoice Details"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Collections Queue"].exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testInvoiceSidebarTransitionRemainsStable() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-appStoreScreenshotFixtures"
        ]
        app.launchEnvironment["GUNNAIRE_BACKEND_AUTH_MODE"] = "disabled-for-screenshot"
        app.launch()

        XCTAssertTrue(
            app.navigationBars["Command Center"].waitForExistence(timeout: 8),
            "The authenticated fixture must begin in Command Center."
        )

        revealSidebarDestination("Invoices", in: app).tap()
        XCTAssertTrue(
            app.navigationBars["Invoices"].waitForExistence(timeout: 8),
            "Tapping Invoices from the normal sidebar must not exhaust the SwiftUI view-construction stack."
        )
        XCTAssertTrue(app.segmentedControls["InvoiceWorkspaceLanePicker"].waitForExistence(timeout: 3))

        revealSidebarDestination("Payments", in: app).tap()
        XCTAssertTrue(app.navigationBars["Payments"].waitForExistence(timeout: 5))

        revealSidebarDestination("Invoices", in: app).tap()
        XCTAssertTrue(app.navigationBars["Invoices"].waitForExistence(timeout: 8))

        let survivesDeferredUpdates = expectation(description: "Invoices remains foregrounded after deferred view updates")
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            if app.state == .runningForeground,
               app.navigationBars["Invoices"].exists {
                survivesDeferredUpdates.fulfill()
            }
        }
        wait(for: [survivesDeferredUpdates], timeout: 20)
    }

    /// Opt-in physical-device diagnostic that deliberately retains the installed
    /// production store and authentication state. Normal UI runs skip it so
    /// seeded fixtures remain deterministic.
    @MainActor
    func testRetainedStoreInvoiceSidebarNavigationRemainsStable() throws {
        guard ProcessInfo.processInfo.environment["GUNNAIRE_RUN_RETAINED_STORE_TEST"] == "1" else {
            throw XCTSkip("Requires an explicitly backed-up physical-device store.")
        }

        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO"
        ]
        app.launch()

        XCTAssertFalse(
            app.staticTexts["Sign in with your approved GunnAire business account."].waitForExistence(timeout: 2),
            "The retained-store diagnostic requires the device's existing authenticated session."
        )

        revealSidebarDestination("Invoices", in: app).tap()
        XCTAssertTrue(
            app.navigationBars["Invoices"].waitForExistence(timeout: 8),
            "Opening Invoices from the sidebar terminated or failed against the retained device store."
        )

        let remainedForeground = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "state == %d", XCUIApplication.State.runningForeground.rawValue),
            object: app
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [remainedForeground], timeout: 30),
            .completed,
            "Invoices must remain foregrounded long enough to expose deferred view or relationship failures."
        )
    }

    @MainActor
    func testReducedMotionSkipsTheSplashAndKeepsCoreNavigationAvailable() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "YES",
            "-maximumSplashDurationSeconds", "6",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestReduceMotion"
        ]
        app.launch()

        let regularNavigation = app.navigationBars["GunnAire Ops"]
        let compactNavigation = app.navigationBars["Command Center"]
        XCTAssertTrue(
            regularNavigation.waitForExistence(timeout: 1) ||
                compactNavigation.waitForExistence(timeout: 3)
        )
        XCTAssertFalse(app.staticTexts["Tap to skip"].exists)

        revealSidebarDestination("Schedule & Jobs", in: app).tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        revealSidebarDestination("Payments", in: app).tap()
        XCTAssertTrue(app.navigationBars["Payments"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testGlobalFindReturnsToCommandCenterFromAnyIPadWorkspace() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["GunnAire Ops"].waitForExistence(timeout: 6))
        app.staticTexts["Payments"].tap()
        XCTAssertTrue(app.navigationBars["Payments"].waitForExistence(timeout: 3))

        let globalFind = app.buttons["GlobalFindButton"]
        XCTAssertTrue(globalFind.waitForExistence(timeout: 3))
        globalFind.tap()

        XCTAssertTrue(app.navigationBars["Find"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.searchFields.firstMatch.placeholderValue, "Customer, Job, Invoice, Estimate, Address")
        app.searchFields.firstMatch.tap()
        app.searchFields.firstMatch.typeText("UI Test Collectible Customer")
        XCTAssertTrue(app.buttons["CommandFindCustomer-\(screenshotCustomerID)"].exists)

#if !targetEnvironment(macCatalyst)
        // Touch platforms can scroll the sheet from the application root. On
        // Mac Catalyst that synthetic gesture has no application hit point;
        // the Mac acceptance path instead proves the global entry, role-aware
        // prompt, authorized customer result, dismissal, and return below.
        let jobResult = app.buttons["CommandFindJob-\(screenshotServiceCallID)"]
        for _ in 0..<3 where !jobResult.exists {
            app.swipeUp()
        }
        XCTAssertTrue(jobResult.waitForExistence(timeout: 3))
        let invoiceResult = app.buttons["CommandFindInvoice-\(screenshotInvoiceID)"]
        for _ in 0..<3 where !invoiceResult.exists {
            app.swipeUp()
        }
        XCTAssertTrue(invoiceResult.waitForExistence(timeout: 3))
#endif

        app.buttons["Close"].tap()
        XCTAssertTrue(app.navigationBars["Command Center"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testFieldFindExposesOnlyAssignedJobAndCollectibleInvoiceContext() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedTechnician",
            "-uiTestSeedCollectibleJob"
        ]
        app.launch()

        openRoleAwareFind(in: app)

        XCTAssertTrue(app.navigationBars["Find"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.searchFields.firstMatch.placeholderValue, "Job, Invoice, Address")
        XCTAssertFalse(app.buttons["CommandFindCustomer-\(screenshotCustomerID)"].exists)
        XCTAssertTrue(app.buttons["CommandFindJob-\(screenshotServiceCallID)"].exists)
        XCTAssertTrue(app.buttons["CommandFindInvoice-\(screenshotInvoiceID)"].exists)
        XCTAssertFalse(app.buttons["CommandFindOpenReports"].exists)
        XCTAssertFalse(app.buttons["CommandFindOpenSync"].exists)
    }

    @MainActor
    func testCompactFieldCommandCenterKeepsItsFocusedFindEntry() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedTechnician",
            "-uiTestSeedCollectibleJob"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Command Center"].waitForExistence(timeout: 6))
        let commandFind = app.buttons["CommandCenterToolbarFindButton"]
        XCTAssertTrue(commandFind.waitForExistence(timeout: 3))
        commandFind.tap()

        XCTAssertTrue(app.navigationBars["Find"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.searchFields.firstMatch.placeholderValue, "Job, Invoice, Address")
        XCTAssertTrue(app.buttons["CommandFindJob-\(screenshotServiceCallID)"].exists)
        XCTAssertTrue(app.buttons["CommandFindInvoice-\(screenshotInvoiceID)"].exists)
        XCTAssertFalse(app.buttons["CommandFindCustomer-\(screenshotCustomerID)"].exists)
    }

    @MainActor
    func testAccountingFindShowsFinancialResultsWithoutDispatchOrAdminActions() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAccounting",
            "-uiTestSeedCollectibleJob"
        ]
        app.launch()

        openRoleAwareFind(in: app)

        XCTAssertTrue(app.navigationBars["Find"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.searchFields.firstMatch.placeholderValue, "Customer, Invoice, Address")
        XCTAssertTrue(app.buttons["CommandFindCustomer-\(screenshotCustomerID)"].exists)
        XCTAssertFalse(app.buttons["CommandFindJob-\(screenshotServiceCallID)"].exists)
        XCTAssertTrue(app.buttons["CommandFindInvoice-\(screenshotInvoiceID)"].exists)
        XCTAssertTrue(app.buttons["CommandFindOpenInvoices"].exists)
        XCTAssertTrue(app.buttons["CommandFindOpenReports"].exists)
        XCTAssertFalse(app.buttons["CommandFindOpenSchedule"].exists)
        XCTAssertFalse(app.buttons["CommandFindOpenSync"].exists)
    }

    @MainActor
    func testStandardCommandCenterNeverOffersTechnicianAssignmentMutation() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedStandard",
            "-uiTestSeedScheduleAuthorization"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Command Center"].waitForExistence(timeout: 6))
        let unassignedRow = app.descendants(matching: .any)["CommandCenterDispatchJob-\(unassignedScheduleServiceCallID)"]
        for _ in 0..<12 where !unassignedRow.exists {
            app.swipeUp()
        }
        XCTAssertTrue(unassignedRow.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["CommandCenterAssign-\(unassignedScheduleServiceCallID)"].exists)
    }

    @MainActor
    func testCloudKitContinuityWarningIsCompactAndExplainsOfflineRecovery() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCloudKitUnavailable"
        ]
        app.launch()

        let notice = app.buttons["CloudKitContinuityNotice"]
        if !notice.waitForExistence(timeout: 3) {
            _ = revealSidebar(in: app)
        }

        XCTAssertTrue(notice.waitForExistence(timeout: 3))
        XCTAssertEqual(notice.label, "Cloud sync unavailable")
        XCTAssertFalse(app.staticTexts["Cloud sync not verified"].exists)
        notice.tap()

        XCTAssertTrue(app.alerts["Cloud sync unavailable"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'approved business iCloud account'")
        ).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'retained locally while offline'")
        ).firstMatch.exists)
        XCTAssertTrue(app.buttons["Check Again"].exists)
        XCTAssertTrue(app.buttons["OK"].exists)
    }

    @MainActor
    func testCloudKitExportFailureKeepsSavedWorkVisibleWithoutAddingADashboard() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCloudKitExportFailure"
        ]
        app.launch()

        let notice = app.buttons["CloudKitContinuityNotice"]
        if !notice.waitForExistence(timeout: 3) {
            let sidebarButton = app.buttons["GunnAire Ops"]
            XCTAssertTrue(sidebarButton.waitForExistence(timeout: 3))
            sidebarButton.tap()
        }

        XCTAssertTrue(notice.waitForExistence(timeout: 3))
        XCTAssertEqual(notice.label, "Changes waiting for CloudKit")
        XCTAssertFalse(app.staticTexts["Cloud updates need attention"].exists)
        notice.tap()

        let alert = app.alerts["Changes waiting for CloudKit"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'could not upload the latest work'")
        ).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'remains saved on this device'")
        ).firstMatch.exists)
        XCTAssertTrue(app.buttons["Check Again"].exists)
        XCTAssertTrue(app.buttons["OK"].exists)
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

        assertAllAdminWorkspacesRemainReachable(in: app)
    }

    /// At the largest accessibility text size the role-aware sidebar is
    /// intentionally scrollable. Every workspace must remain discoverable and
    /// tappable without shrinking text or replacing the native navigation.
    @MainActor
    func testMaximumDynamicTypeKeepsEveryAdminWorkspaceReachable() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestMaximumDynamicType"
        ]
        app.launch()

        assertAllAdminWorkspacesRemainReachable(in: app)
    }

    /// VoiceOver and Voice Control depend on a useful accessibility name for
    /// each visible action. Audit the real seeded accessibility tree for all
    /// primary Administrator workspaces and retain the inventory as evidence.
    @MainActor
    func testPrimaryWorkspacesExposeNamedVisibleActions() throws {
        for destination in adminWorkspaceDestinations {
            let app = XCUIApplication()
            app.launchArguments = [
                "-enableSplashVideo", "NO",
                "-disableCloudKitForTesting",
                "-appStoreScreenshotFixtures",
                "-GunnAirePendingAppRoute", destination.route
            ]
            app.launchEnvironment["GUNNAIRE_BACKEND_AUTH_MODE"] = "disabled-for-screenshot"
            app.launch()

            XCTAssertTrue(
                app.navigationBars[destination.title].waitForExistence(timeout: 8),
                "Failed to reach accessibility audit route: \(destination.title)"
            )

            let visibleActions = app.buttons.allElementsBoundByIndex.filter {
                $0.exists && $0.isHittable
            }
            XCTAssertFalse(
                visibleActions.isEmpty,
                "No visible actions were exposed in \(destination.title)"
            )

            let namedVisibleActions = visibleActions.filter {
                !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            var inventory: [String] = []
            for action in visibleActions {
                let name = action.label.trimmingCharacters(in: .whitespacesAndNewlines)
                if name.isEmpty {
                    let isNestedImplementationControl = namedVisibleActions.contains { candidate in
                        candidate.frame != action.frame && candidate.frame.contains(action.frame)
                    }
                    XCTAssertTrue(
                        isNestedImplementationControl,
                        "Unnamed independent action in \(destination.title): \(action.debugDescription)"
                    )
                    continue
                }
                inventory.append("\(name) | \(action.identifier)")
            }

            let ambiguousLabelsByRoute: [String: Set<String>] = [
                "commandCenter": ["Open", "Docs", "Collect", "Find", "Schedule"],
                "onsiteDocumentation": ["Open Documents", "Open Schedule", "Collect Payment", "Documents"]
            ]
            if let ambiguousLabels = ambiguousLabelsByRoute[destination.route] {
                let remainingAmbiguousActions = namedVisibleActions.filter {
                    ambiguousLabels.contains($0.label.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                XCTAssertTrue(
                    remainingAmbiguousActions.isEmpty,
                    "Ambiguous visible actions remain in \(destination.title): \(remainingAmbiguousActions.map(\.debugDescription).joined(separator: "\n"))"
                )
            }

            let contextualActionPrefixes: [String: [String]] = [
                "commandCenter": ["CommandCenterDispatchJob-"],
                "onsiteDocumentation": [
                    "DocumentationQueueJob-",
                    "DocumentationQueueOpenDocuments-",
                    "DocumentationQueueOpenSchedule-",
                    "DocumentationQueueDocumentActions-",
                    "DocumentationQueueCreateInvoice-",
                    "DocumentationQueueCollectPayment-",
                    "InvoiceCloseoutOpenDocuments-",
                    "InvoiceCloseoutOpenSchedule-",
                    "InvoiceCloseoutCollectPayment-",
                    "InvoiceCloseoutDocumentActions-"
                ]
            ]
            if let prefixes = contextualActionPrefixes[destination.route] {
                for action in namedVisibleActions where prefixes.contains(where: { prefix in
                    action.identifier.hasPrefix(prefix)
                }) {
                    XCTAssertTrue(
                        action.label.localizedCaseInsensitiveContains(" for ") &&
                            action.label.filter { $0 == "," }.count >= 2,
                        "Job-specific action lacks customer context in \(destination.title): \(action.debugDescription)"
                    )
                }
            }

            let evidence = XCTAttachment(
                string: inventory.sorted().joined(separator: "\n")
            )
            evidence.name = "Accessible actions - \(destination.title)"
            evidence.lifetime = .keepAlways
            add(evidence)
            app.terminate()
        }
    }

    @MainActor
    func testAdminResolvesFleetInspectionExceptionFromTheCompactWorkspace() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedFleetReadiness",
            "-appStoreScreenshotFixtures"
        ]
        app.launch()

        XCTAssertTrue(
            app.navigationBars["Command Center"].waitForExistence(timeout: 6) ||
                app.navigationBars["GunnAire Ops"].waitForExistence(timeout: 3)
        )
        let review = app.buttons["ReviewFleetReadiness"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        review.tap()

        // The compact fleet sheet automatically selects the only seeded
        // vehicle, so its detail title replaces the regular Fleet list title.
        XCTAssertTrue(
            app.navigationBars["Fleet"].waitForExistence(timeout: 2) ||
                app.navigationBars["Fleet UI Truck 21"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.staticTexts["Fleet UI Truck 21"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Inspection Due"].exists)
        let beforeInspection = XCTAttachment(screenshot: app.screenshot())
        beforeInspection.name = "Fleet readiness without account email"
        beforeInspection.lifetime = .keepAlways
        add(beforeInspection)
        let inspect = app.buttons["RecordFleetInspection"]
        for _ in 0..<4 where !inspect.exists || !inspect.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(inspect.waitForExistence(timeout: 3))
        XCTAssertTrue(inspect.isHittable)
        inspect.tap()

        XCTAssertTrue(app.navigationBars["Inspect Fleet UI Truck 21"].waitForExistence(timeout: 3))
        for item in [
            "tires_wheels",
            "brakes_steering",
            "lights_signals",
            "fluids_leaks",
            "windshield_body",
            "safety_equipment"
        ] {
            let picker = app.buttons["FleetInspection_\(item)"]
            for _ in 0..<4 where !picker.exists || !picker.isHittable {
                app.swipeUp()
            }
            XCTAssertTrue(picker.waitForExistence(timeout: 3), "Missing inspection picker: \(item)")
            XCTAssertTrue(picker.isHittable, "Inspection picker is not tappable: \(item)")
            picker.tap()
            let pass = app.buttons["Pass"]
            XCTAssertTrue(pass.waitForExistence(timeout: 3), "Missing Pass option for: \(item)")
            pass.tap()
        }

        let record = app.buttons["SaveFleetInspection"]
        for _ in 0..<6 where !record.exists || !record.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(record.waitForExistence(timeout: 3))
        XCTAssertTrue(record.isHittable)
        record.tap()
        XCTAssertTrue(
            app.navigationBars["Fleet"].waitForExistence(timeout: 2) ||
                app.navigationBars["Fleet UI Truck 21"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.staticTexts["Recorded a passing inspection for Fleet UI Truck 21."].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Ready"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Inspection Due"].exists)
        let afterInspection = XCTAttachment(screenshot: app.screenshot())
        afterInspection.name = "Fleet ready without account email"
        afterInspection.lifetime = .keepAlways
        add(afterInspection)
    }

    @MainActor
    func testFieldTechnicianSubmitsJobLinkedMileageFromTimeClock() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedTechnician",
            "-uiTestSeedCollectibleJob",
            "-GunnAirePendingAppRoute", "timeClock"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Time Clock"].waitForExistence(timeout: 8))
        let expenses = app.buttons["OpenFieldExpenses"]
        XCTAssertTrue(expenses.waitForExistence(timeout: 3))
        expenses.tap()

        XCTAssertTrue(app.navigationBars["Expenses & Mileage"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["No Expense Claims"].waitForExistence(timeout: 3))
        let addClaim = app.buttons["AddFieldExpense"]
        XCTAssertTrue(addClaim.waitForExistence(timeout: 3))
        addClaim.tap()

        XCTAssertTrue(app.navigationBars["New Expense Claim"].waitForExistence(timeout: 3))
        let type = app.segmentedControls["FieldExpenseType"]
        XCTAssertTrue(type.waitForExistence(timeout: 3))
        type.buttons["Mileage"].tap()

        let job = app.buttons["FieldExpenseJob"]
        XCTAssertTrue(job.waitForExistence(timeout: 3))
        job.tap()
        let jobChoice = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'UI Test Collectible Customer'")
        ).firstMatch
        XCTAssertTrue(jobChoice.waitForExistence(timeout: 3))
        jobChoice.tap()

        let origin = app.textFields["FieldMileageOrigin"]
        for _ in 0..<6 where !origin.exists || !origin.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(origin.waitForExistence(timeout: 3))
        XCTAssertTrue(origin.isHittable)
        origin.tap()
        origin.typeText("GunnAire shop")
        let doneEditingExpense = app.buttons["Done Editing Expense"]
        XCTAssertTrue(doneEditingExpense.waitForExistence(timeout: 3))
        doneEditingExpense.tap()

        let destination = app.textFields["FieldMileageDestination"]
        XCTAssertTrue(waitForHittable(destination))
        destination.tap()
        destination.typeText("Johnstone Supply")
        XCTAssertTrue(doneEditingExpense.waitForExistence(timeout: 3))
        doneEditingExpense.tap()

        let miles = app.textFields["FieldMileageMiles"]
        XCTAssertTrue(waitForHittable(miles))
        miles.tap()
        miles.typeText("20")
        XCTAssertTrue(doneEditingExpense.waitForExistence(timeout: 3))
        doneEditingExpense.tap()
        let rate = app.textFields["FieldMileageRate"]
        XCTAssertTrue(waitForHittable(rate))
        rate.tap()
        rate.typeText("0.655")
        XCTAssertTrue(doneEditingExpense.waitForExistence(timeout: 3))
        doneEditingExpense.tap()
        let purpose = app.textFields["FieldExpensePurpose"]
        for _ in 0..<3 where !purpose.exists || !purpose.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(purpose.waitForExistence(timeout: 3))
        XCTAssertTrue(purpose.isHittable)
        purpose.tap()
        purpose.typeText("Supply house run")

        let submit = app.buttons["SubmitFieldExpense"]
        XCTAssertTrue(submit.waitForExistence(timeout: 3))
        submit.tap()

        XCTAssertTrue(app.navigationBars["Expenses & Mileage"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Supply house run"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["UI Test Collectible Customer"].exists)
        XCTAssertTrue(app.staticTexts["$13.10"].exists)
        XCTAssertTrue(app.staticTexts["Submitted"].exists)
    }

    @MainActor
    func testAdministratorApprovesAndReimbursesAFieldExpenseWithoutPostingAccounting() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedFieldExpenseReview",
            "-appStoreScreenshotFixtures",
            "-GunnAirePendingAppRoute", "timeClock"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Time Clock"].waitForExistence(timeout: 8))
        let expenses = app.buttons["OpenFieldExpenses"]
        XCTAssertTrue(expenses.waitForExistence(timeout: 3))
        expenses.tap()

        XCTAssertTrue(app.navigationBars["Expenses & Mileage"].waitForExistence(timeout: 3))
        let lane = app.segmentedControls["FieldExpenseLanePicker"]
        XCTAssertTrue(lane.waitForExistence(timeout: 3))
        lane.buttons["Review"].tap()
        XCTAssertTrue(app.staticTexts["1"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Downtown Parking Garage"].exists)

        let claim = app.buttons["FieldExpenseClaim-\(fieldExpenseClaimID)"]
        XCTAssertTrue(claim.waitForExistence(timeout: 3))
        claim.tap()

        XCTAssertTrue(app.navigationBars["Expense Claim"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["$18.50"].exists)
        let review = app.buttons["ReviewFieldExpense"]
        XCTAssertTrue(review.waitForExistence(timeout: 3))
        review.tap()

        XCTAssertTrue(app.navigationBars["Review Claim"].waitForExistence(timeout: 3))
        let saveReview = app.buttons["SaveFieldExpenseReview"]
        XCTAssertTrue(saveReview.isEnabled)
        saveReview.tap()

        XCTAssertTrue(app.navigationBars["Expense Claim"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Approved"].waitForExistence(timeout: 3))
        let reimburse = app.buttons["ReimburseFieldExpense"]
        for _ in 0..<4 where !reimburse.exists || !reimburse.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(reimburse.waitForExistence(timeout: 3))
        XCTAssertTrue(reimburse.isHittable)
        reimburse.tap()

        XCTAssertTrue(app.navigationBars["Record Reimbursement"].waitForExistence(timeout: 3))
        let reference = app.textFields["FieldExpenseReimbursementReference"]
        XCTAssertTrue(reference.waitForExistence(timeout: 3))
        reference.tap()
        reference.typeText("CHECK-UI-1042")
        let saveReimbursement = app.buttons["SaveFieldExpenseReimbursement"]
        XCTAssertTrue(saveReimbursement.isEnabled)
        saveReimbursement.tap()

        XCTAssertTrue(app.navigationBars["Expense Claim"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Reimbursed"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["CHECK-UI-1042"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["SidebarAccountIdentity"].exists)
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] '@gunnaire.com'")
        ).firstMatch.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Expense reimbursement evidence without account email"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testAccountingBoundaryRequiresTeamTimeApprovalBeforeQuickBooksPublication() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedTeamTimeReview"
        ]
        app.launch()

        let timeClock = revealSidebarDestination("Clock In/Out", in: app)
        timeClock.tap()
        XCTAssertTrue(app.navigationBars["Time Clock"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Ready"].exists)
        XCTAssertTrue(app.buttons.matching(identifier: "TeamTimeActivitySummary").firstMatch.exists)

        let teamTime = app.staticTexts["Team Time"]
        for _ in 0..<6 where !teamTime.exists {
            app.swipeUp()
        }
        XCTAssertTrue(teamTime.waitForExistence(timeout: 3))

        let technician = app.staticTexts["UI Test Technician"]
        for _ in 0..<4 where !technician.exists || !technician.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(technician.waitForExistence(timeout: 3))
        XCTAssertTrue(technician.isHittable)
        technician.tap()

        let approve = app.buttons.matching(identifier: "ApproveTimeEntry-A1000000-0000-4000-8000-000000000026").firstMatch
        for _ in 0..<4 where !approve.exists || !approve.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(approve.waitForExistence(timeout: 3))
        XCTAssertTrue(approve.isHittable)
        XCTAssertTrue(app.staticTexts["Ready for review"].exists)
        XCTAssertTrue(app.staticTexts["Job Labor"].exists)
        let beforeApproval = XCTAttachment(screenshot: app.screenshot())
        beforeApproval.name = "Team Time ready for approval"
        beforeApproval.lifetime = .keepAlways
        add(beforeApproval)
        approve.tap()

        XCTAssertTrue(app.staticTexts["Approved"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons.matching(identifier: "ApproveTimeEntry-A1000000-0000-4000-8000-000000000026").firstMatch.exists)
        let afterApproval = XCTAttachment(screenshot: app.screenshot())
        afterApproval.name = "Team Time approved and locked"
        afterApproval.lifetime = .keepAlways
        add(afterApproval)
    }

    @MainActor
    func testFieldTechnicianReviewsOnlyTheirOwnPerformanceScorecard() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedTechnician",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedPendingEstimate",
            "-uiTestSeedTeamTimeReview",
            "-GunnAirePendingAppRoute", "timeClock"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Time Clock"].waitForExistence(timeout: 8))

        let workspace = app.segmentedControls["TimeClockWorkspacePicker"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 3))
        XCTAssertTrue(workspace.buttons["My Time"].exists)
        XCTAssertTrue(workspace.buttons["My Performance"].exists)
        XCTAssertFalse(workspace.buttons["Team Review"].exists)
        workspace.buttons["My Performance"].tap()

        let scorecard = app.otherElements["MyTechnicianScorecard"]
        for _ in 0..<12 where !scorecard.exists {
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["My Scorecard"].waitForExistence(timeout: 3))
        XCTAssertTrue(scorecard.waitForExistence(timeout: 3))
        for metric in ["Assigned Completed", "Lead Invoiced", "Estimate Close", "Recorded Hours", "Job Time Mix"] {
            let element = app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS[c] %@", metric)
            ).firstMatch
            for _ in 0..<8 where !element.exists {
                app.swipeUp()
            }
            XCTAssertTrue(element.waitForExistence(timeout: 3), "Missing personal scorecard metric: \(metric)")
        }
        XCTAssertFalse(app.staticTexts["Known Labor"].exists)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Field technician own performance scorecard"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testFieldTechnicianSignsTheCurrentWeeklyTimeSnapshot() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedTechnician",
            "-uiTestSeedTeamTimeReview",
            "-appStoreScreenshotFixtures",
            "-GunnAirePendingAppRoute", "timeClock"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Time Clock"].waitForExistence(timeout: 8))
        let signSnapshot = app.buttons["SignTimesheetSnapshot"]
        for _ in 0..<14 where !signSnapshot.exists || !signSnapshot.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(signSnapshot.waitForExistence(timeout: 3))
        XCTAssertTrue(signSnapshot.isEnabled)
        XCTAssertTrue(app.staticTexts["Ready for your sign-off"].exists)
        signSnapshot.tap()

        let confirm = app.buttons.matching(identifier: "ConfirmTimesheetSignOff").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()

        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Signed '")
        ).firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(signSnapshot.isEnabled)
        XCTAssertFalse(app.descendants(matching: .any)["SidebarAccountIdentity"].exists)
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] '@gunnaire.com'")
        ).firstMatch.exists)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Field technician weekly time snapshot signed without account email"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testFieldTechnicianClassifiesOfflineTimeBeforeOfficeReview() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedTechnician",
            "-uiTestSeedTimeClassification",
            "-GunnAirePendingAppRoute", "timeClock"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Time Clock"].waitForExistence(timeout: 8))
        let activityPicker = app.buttons.matching(identifier: "TimeActivityPicker").firstMatch
        XCTAssertTrue(activityPicker.waitForExistence(timeout: 3))
        activityPicker.tap()
        XCTAssertTrue(app.buttons["Travel"].waitForExistence(timeout: 3))
        app.buttons["Travel"].tap()

        let clockIn = app.buttons["Clock In"]
        XCTAssertTrue(clockIn.waitForExistence(timeout: 3))
        XCTAssertTrue(clockIn.isEnabled)
        clockIn.tap()

        XCTAssertTrue(app.staticTexts["Travel"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons.matching(identifier: "ActiveTimeActivityPicker").firstMatch.exists)
        let clockOut = app.buttons["Clock Out & Submit"]
        XCTAssertTrue(clockOut.waitForExistence(timeout: 3))
        clockOut.tap()

        let readyForReview = app.staticTexts["Ready for review"]
        for _ in 0..<4 where !readyForReview.exists {
            app.swipeUp()
        }
        XCTAssertTrue(readyForReview.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Travel"].exists)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'submitted for office review'")
        ).firstMatch.exists)
    }

    @MainActor
    func testDispatcherLeadQualificationKeepsSourceVisibleAndEnablesScheduling() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedServiceRequest"
        ]
        app.launch()

        revealSidebarDestination("Schedule & Jobs", in: app).tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Google Lead Customer"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Google Business Profile"].exists)

        let qualify = app.buttons["QualifyServiceRequest-\(serviceRequestID)"]
        XCTAssertTrue(qualify.waitForExistence(timeout: 3))
        qualify.tap()

        XCTAssertTrue(app.navigationBars["Qualify Request"].waitForExistence(timeout: 3))
        let confirm = app.buttons["ConfirmServiceRequestQualification"]
        XCTAssertTrue(confirm.exists)
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()

        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.descendants(matching: .any)["ServiceRequestReady-\(serviceRequestID)"].waitForExistence(timeout: 3)
        )
        let schedule = app.buttons["ScheduleServiceRequest-\(serviceRequestID)"]
        XCTAssertTrue(schedule.exists)
        XCTAssertTrue(schedule.isEnabled)
        XCTAssertTrue(app.buttons["QualifyServiceRequest-\(serviceRequestID)"].exists)
    }

    @MainActor
    func testIPadHardwareKeyboardShortcutOpensBusinessReports() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["GunnAire Ops"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 3))
        app.typeKey("7", modifierFlags: .command)
        let reports = app.navigationBars["Business Reports"]
        if !reports.waitForExistence(timeout: 2) {
            app.typeKey("7", modifierFlags: .command)
        }
        XCTAssertTrue(reports.waitForExistence(timeout: 3))
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

        let syncIntegrations = app.staticTexts["Sync & Integrations"]
        if !syncIntegrations.waitForExistence(timeout: 2) {
            let sidebarButton = app.buttons["GunnAire Ops"]
            XCTAssertTrue(sidebarButton.waitForExistence(timeout: 3))
            sidebarButton.tap()
            for _ in 0..<6 where !syncIntegrations.exists {
                app.swipeUp()
            }
        }
        XCTAssertTrue(syncIntegrations.waitForExistence(timeout: 3))
        syncIntegrations.tap()
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
    func testAdministratorSeesExpiredTechnicianQualificationBeforeDispatch() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedQualificationReview"
        ]
        app.launch()

        let syncIntegrations = app.staticTexts["Sync & Integrations"]
        if !syncIntegrations.waitForExistence(timeout: 2) {
            let sidebarButton = app.buttons["GunnAire Ops"]
            XCTAssertTrue(sidebarButton.waitForExistence(timeout: 3))
            sidebarButton.tap()
            for _ in 0..<6 where !syncIntegrations.exists {
                app.swipeUp()
            }
        }
        XCTAssertTrue(syncIntegrations.waitForExistence(timeout: 3))
        syncIntegrations.tap()
        XCTAssertTrue(app.navigationBars["Sync & Integrations"].waitForExistence(timeout: 3))

        let form = app.collectionViews["SyncIntegrationsForm"]
        XCTAssertTrue(form.waitForExistence(timeout: 3))
        let editTechnician = app.buttons["EditTechnician-A1000000-0000-4000-8000-000000000006"]
        for _ in 0..<12 where !editTechnician.exists {
            form.swipeUp()
        }
        XCTAssertTrue(editTechnician.waitForExistence(timeout: 3))
        editTechnician.tap()

        let editor = app.navigationBars["Edit Technician"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        let reviewStatus = app.staticTexts["QualificationReviewStatus"]
        for _ in 0..<8 where !reviewStatus.exists {
            app.swipeUp()
        }
        XCTAssertTrue(reviewStatus.waitForExistence(timeout: 3))
        XCTAssertTrue(reviewStatus.label.contains("Expired"))
        editor.buttons["Cancel"].tap()

        let schedule = app.staticTexts["Schedule & Jobs"]
        if !schedule.waitForExistence(timeout: 2) {
            let sidebarButton = app.buttons["GunnAire Ops"]
            XCTAssertTrue(sidebarButton.waitForExistence(timeout: 3))
            sidebarButton.tap()
            for _ in 0..<6 where !schedule.exists {
                app.swipeDown()
            }
        }
        XCTAssertTrue(schedule.waitForExistence(timeout: 3))
        schedule.tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        let editJob = app.buttons["EditSchedule-\(screenshotServiceCallID)"]
        for _ in 0..<8 where !editJob.exists {
            app.swipeUp()
        }
        XCTAssertTrue(editJob.waitForExistence(timeout: 3))
        editJob.tap()
        XCTAssertTrue(app.navigationBars["Edit Service Call"].waitForExistence(timeout: 3))
        let dispatchQualification = app.staticTexts["EditServiceCallTechnicianQualification"]
        XCTAssertTrue(dispatchQualification.waitForExistence(timeout: 3))
        XCTAssertTrue(dispatchQualification.label.contains("review expired"))
    }

    @MainActor
    func testBusinessReportsUsesFocusedManagementWorkspaces() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedMaintenanceReporting",
            "-uiTestSeedServiceRequest"
        ]
        app.launch()

        let reports = revealSidebarDestination("Reports", in: app)
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
        let leadSourceCard = app.descendants(matching: .any)["LeadSourcePerformanceReportCard"]
        for _ in 0..<5 where !leadSourceCard.exists {
            app.swipeUp()
        }
        XCTAssertTrue(leadSourceCard.waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["LeadSourceReportRow-googleBusinessProfile"].exists)
        let leadSourceDisclosure = app.buttons["Review lead source performance"]
        XCTAssertTrue(leadSourceDisclosure.waitForExistence(timeout: 3))
        leadSourceDisclosure.tap()
        let googleLeadSource = app.staticTexts["Google Business Profile"]
        for _ in 0..<5 where !googleLeadSource.exists {
            app.swipeUp()
        }
        XCTAssertTrue(googleLeadSource.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Request Conversion"].exists)
        XCTAssertTrue(app.staticTexts["Estimate Close"].exists)
        let maintenanceAgreements = app.staticTexts["Maintenance Agreements"]
        for _ in 0..<5 where !maintenanceAgreements.exists {
            app.swipeUp()
        }
        XCTAssertTrue(maintenanceAgreements.waitForExistence(timeout: 3))
        workspace.buttons["Operations"].tap()
        XCTAssertTrue(app.staticTexts["Operations Quality"].waitForExistence(timeout: 3))
        let agreementDelivery = app.staticTexts["Agreement Delivery"]
        for _ in 0..<6 where !agreementDelivery.exists {
            app.swipeUp()
        }
        XCTAssertTrue(agreementDelivery.waitForExistence(timeout: 3))
        workspace.buttons["Team"].tap()
        XCTAssertTrue(app.staticTexts["Team Scorecards"].waitForExistence(timeout: 3))
        let scorecard = app.buttons["TechnicianScorecard-A1000000-0000-4000-8000-000000000006"]
        XCTAssertTrue(scorecard.waitForExistence(timeout: 3))
        scorecard.tap()
        XCTAssertTrue(app.staticTexts["Lead Invoiced"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Estimate Close"].exists)
        let jobTimeMix = app.staticTexts["Job Time Mix"]
        for _ in 0..<6 where !jobTimeMix.exists {
            app.swipeUp()
        }
        XCTAssertTrue(jobTimeMix.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Known Labor"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testBusinessReportsProgressivelyDisclosesJobProfitabilityExceptions() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob"
        ]
        app.launch()

        let reports = revealSidebarDestination("Reports", in: app)
        reports.tap()
        XCTAssertTrue(app.navigationBars["Business Reports"].waitForExistence(timeout: 3))

        let profitabilityCard = app.descendants(matching: .any)["JobProfitabilityReportCard"]
        for _ in 0..<6 where !profitabilityCard.exists || !profitabilityCard.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(profitabilityCard.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Job Profitability"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'need review'")).firstMatch.exists)

        let disclosure = app.buttons["Review job costing"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 3))
        disclosure.tap()

        let row = app.descendants(matching: .any)["JobProfitabilityRow-\(screenshotServiceCallID)"]
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["UI Test Collectible Customer"].exists)
        XCTAssertTrue(app.staticTexts["Cost review"].exists)
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let knownMaterials = app.staticTexts["Known materials"]
        for _ in 0..<6 where !knownMaterials.exists {
            app.swipeUp()
        }
        XCTAssertTrue(knownMaterials.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Known labor"].exists)
        XCTAssertTrue(app.staticTexts["Gross profit"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'no completed labor time'")).firstMatch.exists)
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
        if !settings.waitForExistence(timeout: 3) {
            let sidebarButton = app.buttons["GunnAire Ops"]
            XCTAssertTrue(sidebarButton.waitForExistence(timeout: 3))
            sidebarButton.tap()
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
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
    func testFieldStaffNotificationsStayCompactPrivateAndReachableInSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedTechnician",
            "-uiTestSeedStaffNotificationsReady"
        ]
        app.launch()

        let settings = app.buttons["Settings"]
        if !settings.waitForExistence(timeout: 3) {
            let sidebarButton = app.buttons["GunnAire Ops"]
            XCTAssertTrue(sidebarButton.waitForExistence(timeout: 3))
            sidebarButton.tap()
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.segmentedControls.firstMatch.exists)

        let settingsForm = app.collectionViews["SettingsForm"]
        XCTAssertTrue(settingsForm.waitForExistence(timeout: 3))
        let status = app.descendants(matching: .any)["StaffNotificationsStatus"]
        if !status.waitForExistence(timeout: 1) {
            settingsForm.swipeUp()
        }
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertTrue(status.label.localizedCaseInsensitiveContains("Assignment Alerts"))
        XCTAssertTrue(status.label.localizedCaseInsensitiveContains("Ready"))
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'previews omit customer, address, balance, and payment details'")
        ).firstMatch.exists)
        XCTAssertTrue(app.buttons["DisableStaffNotifications"].exists)
        XCTAssertFalse(app.staticTexts["Private Customer Name"].exists)
    }

    @MainActor
    func testAdministratorCanCreateARequiredFieldFormTemplate() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin"
        ]
        app.launch()

        let settings = app.buttons["Settings"]
        if !settings.waitForExistence(timeout: 3) {
            let sidebarButton = app.buttons["GunnAire Ops"]
            XCTAssertTrue(sidebarButton.waitForExistence(timeout: 3))
            sidebarButton.tap()
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))

        let settingsArea = app.segmentedControls.firstMatch
        XCTAssertTrue(settingsArea.waitForExistence(timeout: 3))
        settingsArea.buttons["Workflow"].tap()

        let settingsForm = app.collectionViews["SettingsForm"]
        let manageForms = app.buttons["ManageFieldFormTemplates"]
        for _ in 0..<8 where !manageForms.exists || !manageForms.isHittable {
            settingsForm.swipeUp()
        }
        XCTAssertTrue(manageForms.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(manageForms.isHittable, app.debugDescription)
        manageForms.tap()

        let createForm = app.buttons["CreateFieldFormTemplate"]
        XCTAssertTrue(createForm.waitForExistence(timeout: 6), app.debugDescription)
        XCTAssertTrue(app.navigationBars["Field Form Templates"].waitForExistence(timeout: 3))
        createForm.tap()

        XCTAssertTrue(app.navigationBars["New Field Form"].waitForExistence(timeout: 3))
        let title = app.textFields["FieldFormTemplateTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        title.tap()
        title.typeText("UI Commissioning Form")

        let fieldLabel = app.textFields["Field label"]
        XCTAssertTrue(fieldLabel.waitForExistence(timeout: 3))
        fieldLabel.tap()
        fieldLabel.typeText("Start-up confirmed")

        let save = app.buttons["SaveFieldFormTemplate"]
        XCTAssertTrue(save.exists)
        save.tap()

        XCTAssertTrue(app.staticTexts["UI Commissioning Form"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["1 field • All job types"].exists)
    }

    @MainActor
    func testFieldTechnicianScheduleShowsAssignedWorkWithoutDispatchMutationControls() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedTechnician",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedScheduleAuthorization"
        ]
        app.launch()

        let schedule = app.staticTexts["Schedule & Jobs"]
        if !schedule.waitForExistence(timeout: 2) {
            _ = revealSidebar(in: app)
        }
        XCTAssertTrue(schedule.waitForExistence(timeout: 3))
        schedule.tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        XCTAssertFalse(app.buttons["AddServiceCall"].exists)
        XCTAssertFalse(app.buttons["EditScheduleList"].exists)
        XCTAssertFalse(app.buttons["DispatchWeekBoard"].exists)
        XCTAssertFalse(app.buttons["ManageTechnicianAvailability"].exists)
        XCTAssertFalse(app.buttons["SyncGoogleCalendar"].exists)

        let assignedJob = app.buttons["OpenServiceCall-\(screenshotServiceCallID)"]
        for _ in 0..<8 where !assignedJob.exists {
            XCTAssertFalse(app.staticTexts["Unassigned confidential dispatch job"].exists)
            app.swipeUp()
        }
        XCTAssertTrue(assignedJob.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["OpenDocumentation-\(screenshotServiceCallID)"].exists)
        XCTAssertFalse(app.buttons["EditSchedule-\(screenshotServiceCallID)"].exists)
        XCTAssertFalse(app.buttons["DeleteSchedule-\(screenshotServiceCallID)"].exists)

        for _ in 0..<10 {
            XCTAssertFalse(app.staticTexts["Unassigned confidential dispatch job"].exists)
            XCTAssertFalse(app.buttons["OpenServiceCall-\(unassignedScheduleServiceCallID)"].exists)
            XCTAssertFalse(app.buttons["Assign To Me"].exists)
            app.swipeUp()
        }
        XCTAssertFalse(app.staticTexts["Unassigned confidential dispatch job"].exists)
        XCTAssertFalse(app.buttons["OpenServiceCall-\(unassignedScheduleServiceCallID)"].exists)
    }

    @MainActor
    func testFieldTechnicianScheduleShowsOnlyAuthorizedAdjacentTravel() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedTechnician",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedScheduleAuthorization",
            "-uiTestSeedTechnicianRoute"
        ]
        app.launch()

        let schedule = app.staticTexts["Schedule & Jobs"]
        if !schedule.waitForExistence(timeout: 2) {
            _ = revealSidebar(in: app)
        }
        XCTAssertTrue(schedule.waitForExistence(timeout: 3))
        schedule.tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        XCTAssertFalse(app.buttons["DispatchWeekBoard"].exists)
        XCTAssertFalse(app.buttons["AddServiceCall"].exists)
        XCTAssertFalse(app.staticTexts["Unassigned confidential dispatch job"].exists)
        XCTAssertFalse(app.buttons["OpenServiceCall-\(unassignedScheduleServiceCallID)"].exists)

        let routeDisclosure = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Travel between appointments'")
        ).firstMatch
        for _ in 0..<8 where !routeDisclosure.exists {
            XCTAssertFalse(app.staticTexts["Unassigned confidential dispatch job"].exists)
            app.swipeUp()
        }
        XCTAssertTrue(routeDisclosure.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(routeDisclosure.label.localizedCaseInsensitiveContains("travel between appointments"), routeDisclosure.label)
        XCTAssertTrue(routeDisclosure.label.localizedCaseInsensitiveContains("2 scheduled legs"), routeDisclosure.label)
        XCTAssertFalse(routeDisclosure.label.localizedCaseInsensitiveContains("@gunnaire.com"), routeDisclosure.label)
        routeDisclosure.tap()

        let authorizedRouteTitle = app.staticTexts["Comfort Care maintenance → Follow-up airflow repair"]
        XCTAssertTrue(authorizedRouteTitle.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.staticTexts["30m appointment overlap"].exists)
        XCTAssertFalse(authorizedRouteTitle.label.localizedCaseInsensitiveContains("@gunnaire.com"))

        let routeLegID = "A1000000-0000-4000-8000-000000000012-A1000000-0000-4000-8000-000000000048"
        let estimateRoute = app.buttons["FieldTechnicianRouteEstimate-\(routeLegID)"]
        for _ in 0..<4 where !estimateRoute.exists {
            app.swipeUp()
        }
        XCTAssertTrue(estimateRoute.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.buttons["FieldTechnicianRouteOpenMaps-\(routeLegID)"].exists)
        XCTAssertFalse(app.buttons["DispatchTechnicianRouteEstimate-\(routeLegID)"].exists)
        XCTAssertFalse(app.staticTexts["Unassigned confidential dispatch job"].exists)
        XCTAssertFalse(app.buttons["OpenServiceCall-\(unassignedScheduleServiceCallID)"].exists)

        let routeFooter = app.staticTexts.matching(
            NSPredicate(
                format: "label == %@",
                "Optional Apple Maps estimates require a connection and account for expected traffic. They are informational only and never change appointments, capacity, or promised arrival windows."
            )
        ).firstMatch
        XCTAssertTrue(routeFooter.exists)

        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "Field technician authorized day with compact adjacent travel"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    @MainActor
    func testFieldJobDirectionsStayVisibleFromScheduleToJobDetails() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedTechnician",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedScheduleAuthorization",
            "-GunnAirePendingAppRoute", "scheduleAndJobs"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["NavigateNextStop"].waitForExistence(timeout: 3))

        app.terminate()
        app.launchArguments += [
            "-GunnAirePendingScheduleServiceCallID", maintenanceServiceCallID
        ]
        app.launch()

        let workspace = app.segmentedControls["ServiceCallWorkspacePicker"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Call Details"].exists)
        workspace.buttons["Overview"].tap()
        let directions = app.buttons["Driving Directions"]
        for _ in 0..<20 where !directions.exists {
            app.swipeUp()
        }
        XCTAssertTrue(directions.waitForExistence(timeout: 3))
    }

    @MainActor
    func testEnRouteHandoffKeepsETACommunicationAndDirectionsInOneCompactFlow() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedTechnician",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedScheduleAuthorization"
        ]
        app.launch()

        let schedule = revealSidebarDestination("Schedule & Jobs", in: app)
        schedule.tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        let maintenanceJob = app.buttons["OpenServiceCall-\(maintenanceServiceCallID)"]
        for _ in 0..<10 where !maintenanceJob.exists {
            app.swipeUp()
        }
        XCTAssertTrue(maintenanceJob.waitForExistence(timeout: 3))
        maintenanceJob.tap()
        XCTAssertTrue(app.navigationBars["Call Details"].waitForExistence(timeout: 3))

        let enRoute = app.buttons["En Route"]
        for _ in 0..<6 where !enRoute.exists {
            app.swipeUp()
        }
        XCTAssertTrue(enRoute.waitForExistence(timeout: 3))
        enRoute.tap()

        XCTAssertTrue(app.navigationBars["Start Travel"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["EnRouteOpenDirections"].exists)
        XCTAssertTrue(app.otherElements["EnRouteArrivalEstimatePicker"].exists || app.buttons["EnRouteArrivalEstimatePicker"].exists)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'does not use live traffic'")
        ).firstMatch.exists)
        let handoffScreenshot = XCTAttachment(screenshot: app.screenshot())
        handoffScreenshot.name = "En Route Handoff – iPhone Portrait"
        handoffScreenshot.lifetime = .keepAlways
        add(handoffScreenshot)

        let reviewedDraftsNote = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'staff-reviewed drafts'")
        ).firstMatch
        let handoffForm = app.collectionViews.firstMatch
        XCTAssertTrue(handoffForm.exists)
        for _ in 0..<6 where !reviewedDraftsNote.exists {
            handoffForm.swipeUp()
        }
        XCTAssertTrue(reviewedDraftsNote.waitForExistence(timeout: 3))

        let noDraft = app.buttons["No customer draft"]
        XCTAssertTrue(noDraft.waitForExistence(timeout: 3))
        noDraft.tap()
        app.buttons["ConfirmEnRouteHandoff"].tap()

        XCTAssertTrue(app.navigationBars["Call Details"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Arrived"].waitForExistence(timeout: 3))
        let status = app.staticTexts["JobActionStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertTrue(status.label.contains("approximate 30-minute"))
    }

    @MainActor
    func testStandardScheduleIsCompanyWideReadOnly() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedStandard",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedScheduleAuthorization"
        ]
        app.launch()

        let schedule = app.staticTexts["Schedule & Jobs"]
        if !schedule.waitForExistence(timeout: 2) {
            let sidebarButton = app.buttons["GunnAire Ops"]
            XCTAssertTrue(sidebarButton.waitForExistence(timeout: 3))
            sidebarButton.tap()
        }
        XCTAssertTrue(schedule.waitForExistence(timeout: 3))
        schedule.tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["NavigateNextStop"].exists)

        XCTAssertFalse(app.buttons["AddServiceCall"].exists)
        XCTAssertFalse(app.buttons["EditScheduleList"].exists)
        XCTAssertFalse(app.buttons["DispatchWeekBoard"].exists)
        XCTAssertFalse(app.buttons["ManageTechnicianAvailability"].exists)
        XCTAssertFalse(app.buttons["SyncGoogleCalendar"].exists)

        let unassignedJob = app.buttons["OpenServiceCall-\(unassignedScheduleServiceCallID)"]
        for _ in 0..<8 where !unassignedJob.exists {
            app.swipeUp()
        }
        XCTAssertTrue(unassignedJob.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Unassigned confidential dispatch job"].exists)
        XCTAssertFalse(app.buttons["EditSchedule-\(unassignedScheduleServiceCallID)"].exists)
        XCTAssertFalse(app.buttons["DeleteSchedule-\(unassignedScheduleServiceCallID)"].exists)
        XCTAssertFalse(app.buttons["Assign To Me"].exists)
        XCTAssertFalse(app.buttons["Assign Technician"].exists)

        unassignedJob.tap()
        XCTAssertTrue(app.navigationBars["Call Details"].waitForExistence(timeout: 3))
        for _ in 0..<8 {
            app.swipeUp()
        }
        XCTAssertFalse(app.buttons["En Route"].exists)
        XCTAssertFalse(app.buttons["Arrived"].exists)
        XCTAssertFalse(app.buttons["Start Work"].exists)
        XCTAssertFalse(app.buttons["Complete Job"].exists)
    }

    @MainActor
    func testAdminScheduleRetainsDispatchMutationControls() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedScheduleAuthorization"
        ]
        app.launch()

        let schedule = app.staticTexts["Schedule & Jobs"]
        if !schedule.waitForExistence(timeout: 2) {
            let sidebarButton = app.buttons["GunnAire Ops"]
            XCTAssertTrue(sidebarButton.waitForExistence(timeout: 3))
            sidebarButton.tap()
        }
        XCTAssertTrue(schedule.waitForExistence(timeout: 3))
        schedule.tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        XCTAssertTrue(app.buttons["AddServiceCall"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["EditScheduleList"].exists)
        XCTAssertTrue(app.buttons["DispatchWeekBoard"].exists)
        XCTAssertTrue(app.buttons["ManageTechnicianAvailability"].exists)
        XCTAssertTrue(app.buttons["SyncGoogleCalendar"].exists)

        let assignedJob = app.buttons["OpenServiceCall-\(screenshotServiceCallID)"]
        for _ in 0..<8 where !assignedJob.exists {
            app.swipeUp()
        }
        XCTAssertTrue(assignedJob.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["EditSchedule-\(screenshotServiceCallID)"].exists)
        XCTAssertTrue(app.buttons["DeleteSchedule-\(screenshotServiceCallID)"].exists)

        let unassignedJob = app.buttons["OpenServiceCall-\(unassignedScheduleServiceCallID)"]
        for _ in 0..<5 where !unassignedJob.exists {
            app.swipeUp()
        }
        XCTAssertTrue(unassignedJob.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Unassigned confidential dispatch job"].exists)
    }

    @MainActor
    func testAdminCanChooseRepairAndReplacementAsDistinctWorkTypes() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin"
        ]
        app.launch()

        let schedule = app.staticTexts["Schedule & Jobs"]
        if !schedule.waitForExistence(timeout: 2) {
            let sidebarButton = app.buttons["GunnAire Ops"]
            XCTAssertTrue(sidebarButton.waitForExistence(timeout: 3))
            sidebarButton.tap()
        }
        XCTAssertTrue(schedule.waitForExistence(timeout: 3))
        schedule.tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        let addJob = app.buttons["AddServiceCall"]
        XCTAssertTrue(addJob.waitForExistence(timeout: 3))
        addJob.tap()
        XCTAssertTrue(app.navigationBars["New Service Call"].waitForExistence(timeout: 3))

        let typePicker = app.descendants(matching: .any)["NewServiceCallType"]
        XCTAssertTrue(typePicker.waitForExistence(timeout: 3))
        typePicker.tap()
        XCTAssertTrue(app.buttons["Repair"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Replacement"].exists)
    }

    @MainActor
    func testDispatchWeekBoardOpensAsDedicatedWorkspace() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedTechnicianRoute"
        ]
        app.launch()

        let schedule = revealSidebarDestination("Schedule & Jobs", in: app)
        schedule.tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        let weekBoard = app.buttons["Week Board"]
        XCTAssertTrue(weekBoard.waitForExistence(timeout: 3))
        weekBoard.tap()

        XCTAssertTrue(app.navigationBars["Dispatch Week"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Drag a job to another day. Its time stays the same."].exists)
        XCTAssertTrue(app.buttons["Today"].exists)
        XCTAssertTrue(app.buttons["Done"].exists)

        let capacity = app.descendants(matching: .any)[dispatchCapacityIdentifier(for: Date())]
        XCTAssertTrue(capacity.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(capacity.label.localizedCaseInsensitiveContains("capacity"))
        XCTAssertFalse(capacity.label.localizedCaseInsensitiveContains("@gunnaire.com"))

        capacity.tap()
        XCTAssertTrue(app.navigationBars["Team Capacity"].waitForExistence(timeout: 3), app.debugDescription)
        let technicianCapacity = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'DispatchTechnicianCapacity-'")
        ).firstMatch
        XCTAssertTrue(technicianCapacity.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(technicianCapacity.label.localizedCaseInsensitiveContains("UI Test Technician"))
        XCTAssertTrue(technicianCapacity.label.localizedCaseInsensitiveContains("hours not configured"))
        XCTAssertFalse(technicianCapacity.label.localizedCaseInsensitiveContains("@gunnaire.com"))
        XCTAssertTrue(app.staticTexts["Regular hours are reduced by unavailable time. On-call remains separate, and travel time is not estimated."].exists)

        technicianCapacity.tap()
        XCTAssertTrue(app.navigationBars["Technician Day"].waitForExistence(timeout: 3), app.debugDescription)
        let technicianDay = app.descendants(matching: .any)["DispatchTechnicianDaySchedule"]
        XCTAssertTrue(technicianDay.waitForExistence(timeout: 3), app.debugDescription)
        let dayJob = app.descendants(matching: .any)["DispatchTechnicianDayJob-A1000000-0000-4000-8000-000000000002"]
        XCTAssertTrue(dayJob.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(dayJob.label.localizedCaseInsensitiveContains("Collectible HVAC service"), dayJob.label)
        XCTAssertTrue(dayJob.label.localizedCaseInsensitiveContains("outside configured hours"), dayJob.label)
        XCTAssertFalse(dayJob.label.localizedCaseInsensitiveContains("@gunnaire.com"))

        let routeDisclosure = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Travel between appointments'")
        ).firstMatch
        XCTAssertTrue(routeDisclosure.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(routeDisclosure.label.localizedCaseInsensitiveContains("travel between appointments"), routeDisclosure.label)
        XCTAssertTrue(routeDisclosure.label.localizedCaseInsensitiveContains("1 scheduled leg"), routeDisclosure.label)
        routeDisclosure.tap()

        let routeLegID = "A1000000-0000-4000-8000-000000000002-A1000000-0000-4000-8000-000000000048"
        let routeTitle = app.staticTexts["Collectible HVAC service → Follow-up airflow repair"]
        for _ in 0..<3 where !routeTitle.exists {
            technicianDay.swipeUp()
        }
        XCTAssertTrue(routeTitle.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.staticTexts["1h scheduled gap"].exists)
        XCTAssertFalse(routeTitle.label.localizedCaseInsensitiveContains("@gunnaire.com"))
        XCTAssertTrue(app.buttons["DispatchTechnicianRouteEstimate-\(routeLegID)"].exists)
        XCTAssertTrue(app.buttons["DispatchTechnicianRouteOpenMaps-\(routeLegID)"].exists)
        let routeFooter = app.staticTexts.matching(
            NSPredicate(
                format: "label == %@",
                "Optional Apple Maps estimates require a connection and account for expected traffic. They are informational only and never change appointments, capacity, or promised arrival windows."
            )
        ).firstMatch
        for _ in 0..<3 where !routeFooter.exists {
            technicianDay.swipeUp()
        }
        XCTAssertTrue(routeFooter.exists)

        let dayEvidence = XCTAttachment(screenshot: app.screenshot())
        dayEvidence.name = "Technician day appointments, compact route awareness, and private-note-safe availability"
        dayEvidence.lifetime = .keepAlways
        add(dayEvidence)

        for _ in 0..<4 where !routeDisclosure.isHittable {
            technicianDay.swipeDown()
        }
        XCTAssertTrue(routeDisclosure.isHittable, app.debugDescription)
        routeDisclosure.tap()
        technicianDay.swipeDown()
        let editableDayJob = app.descendants(matching: .any)["DispatchTechnicianDayJob-A1000000-0000-4000-8000-000000000002"]
        XCTAssertTrue(editableDayJob.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(editableDayJob.isHittable, app.debugDescription)
        editableDayJob.tap()
        XCTAssertTrue(app.navigationBars["Edit Service Call"].waitForExistence(timeout: 3))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Technician Day"].waitForExistence(timeout: 3))
        let teamCapacityBack = app.navigationBars["Technician Day"].buttons["Team Capacity"]
        XCTAssertTrue(teamCapacityBack.waitForExistence(timeout: 2), app.debugDescription)
        teamCapacityBack.tap()
        XCTAssertTrue(app.navigationBars["Team Capacity"].waitForExistence(timeout: 3))
        app.buttons["DispatchCapacityDetailDone"].tap()
        XCTAssertTrue(app.navigationBars["Dispatch Week"].waitForExistence(timeout: 3))

        let seededJob = app.descendants(matching: .any)["DispatchJobCard-A1000000-0000-4000-8000-000000000002"]
        XCTAssertTrue(seededJob.waitForExistence(timeout: 3))
        seededJob.tap()
        XCTAssertTrue(app.navigationBars["Edit Service Call"].waitForExistence(timeout: 3))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Dispatch Week"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testDispatchWeekBoardRequiresReasonBeforeOverridingCrewConflict() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob"
        ]
        app.launch()

        let schedule = revealSidebarDestination("Schedule & Jobs", in: app)
        schedule.tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        let weekBoard = app.buttons["Week Board"]
        XCTAssertTrue(weekBoard.waitForExistence(timeout: 3))
        weekBoard.tap()
        XCTAssertTrue(app.navigationBars["Dispatch Week"].waitForExistence(timeout: 3))

        let moveMenu = app.buttons["Move UI Test Collectible Customer"].firstMatch
        XCTAssertTrue(moveMenu.waitForExistence(timeout: 3))
        moveMenu.tap()

        let tomorrow = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: Date()))
        let tomorrowLabel = tomorrow.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        let tomorrowMove = app.buttons[tomorrowLabel]
        XCTAssertTrue(tomorrowMove.waitForExistence(timeout: 3))
        tomorrowMove.tap()

        XCTAssertTrue(app.navigationBars["Override Conflict"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Scheduling Conflict"].exists)
        let confirm = app.buttons["ConfirmDispatchConflictOverride"]
        XCTAssertTrue(confirm.exists)
        XCTAssertFalse(confirm.isEnabled)
        let blockedMove = XCTAttachment(screenshot: app.screenshot())
        blockedMove.name = "Dispatch conflict requires reason"
        blockedMove.lifetime = .keepAlways
        add(blockedMove)

        let reason = app.textViews["DispatchConflictOverrideReason"]
        XCTAssertTrue(reason.waitForExistence(timeout: 3))
        reason.tap()
        reason.typeText("Emergency callback requires the assigned lead technician.")
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()

        XCTAssertTrue(app.navigationBars["Dispatch Week"].waitForExistence(timeout: 3))
        let success = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "documented conflict override")
        ).firstMatch
        XCTAssertTrue(success.waitForExistence(timeout: 3))
        let completedOverride = XCTAttachment(screenshot: app.screenshot())
        completedOverride.name = "Dispatch conflict override completed"
        completedOverride.lifetime = .keepAlways
        add(completedOverride)
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

        let schedule = revealSidebarDestination("Schedule & Jobs", in: app)
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

        let schedule = revealSidebarDestination("Schedule & Jobs", in: app)
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

        let paymentTerms = app.descendants(matching: .any)["InvoicePaymentTerms"]
        for _ in 0..<6 where !paymentTerms.exists || !paymentTerms.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(paymentTerms.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Due Date"].waitForExistence(timeout: 3))
        let dueDateExplanation = app.staticTexts[
            "The same due date drives customer documents, overdue queues, reminders, and QuickBooks."
        ]
        for _ in 0..<4 where !dueDateExplanation.exists {
            app.swipeUp()
        }
        XCTAssertTrue(
            dueDateExplanation.waitForExistence(timeout: 3)
        )
    }

    @MainActor
    func testJobPhotoCanOpenCopyPreservingMarkup() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedPhotoMarkup"
        ]
        app.launch()

        let schedule = revealSidebarDestination("Schedule & Jobs", in: app)
        schedule.tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        let documentation = app.buttons["OpenDocumentation-A1000000-0000-4000-8000-000000000002"]
        for _ in 0..<6 where !documentation.exists || !documentation.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(documentation.waitForExistence(timeout: 3))
        documentation.tap()

        XCTAssertTrue(app.navigationBars["Job Documentation"].waitForExistence(timeout: 3))
        let stagePicker = app.segmentedControls["JobDocumentationStagePicker"]
        XCTAssertTrue(stagePicker.waitForExistence(timeout: 3))
        stagePicker.buttons["Files"].tap()

        let attachmentGroup = app.buttons["Diagnostic Photo, 1"]
        for _ in 0..<12 where !attachmentGroup.exists || !attachmentGroup.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(attachmentGroup.waitForExistence(timeout: 3))
        attachmentGroup.tap()

        let annotate = app.buttons["AnnotateAttachment-A1000000-0000-4000-8000-000000000050"]
        for _ in 0..<4 where !annotate.exists || !annotate.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(annotate.waitForExistence(timeout: 3))
        XCTAssertEqual(annotate.label, "Annotate")
        annotate.tap()

        let previewNavigationBar = app.navigationBars.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "UI-Diagnostic-Photo")
        ).firstMatch
        XCTAssertTrue(previewNavigationBar.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 3))
        let markup = app.switches["QLOverlayMarkupButtonAccessibilityIdentifier"]
        XCTAssertTrue(markup.waitForExistence(timeout: 5))
        markup.tap()
        let markupCanvas = app.descendants(matching: .any)[
            "QLMarkupImageItemViewControllerMarkupImageViewAccessibilityIdentifier"
        ]
        XCTAssertTrue(markupCanvas.waitForExistence(timeout: 5))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Copy-preserving job photo markup"
        attachment.lifetime = .keepAlways
        add(attachment)

        let strokeStart = markupCanvas.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.55))
        let strokeEnd = markupCanvas.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.55))
        strokeStart.press(forDuration: 0.2, thenDragTo: strokeEnd)
        markup.tap()

        XCTAssertTrue(app.navigationBars["Job Documentation"].waitForExistence(timeout: 8))
        let updatedGroup = app.buttons["Diagnostic Photo, 2"]
        for _ in 0..<10 where !updatedGroup.exists || !updatedGroup.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(updatedGroup.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["UI-Diagnostic-Photo.png"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts[
                "Annotated copy of UI-Diagnostic-Photo.png — Control-board wiring before repair"
            ].waitForExistence(timeout: 5)
        )
    }

    @MainActor
    func testJobCloseoutNextActionOpensTheRequiredWorkflowStage() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob"
        ]
        app.launch()

        let schedule = revealSidebarDestination("Schedule & Jobs", in: app)
        schedule.tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        let documentation = app.buttons["OpenDocumentation-A1000000-0000-4000-8000-000000000002"]
        for _ in 0..<5 {
            if documentation.exists && documentation.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(documentation.waitForExistence(timeout: 3))
        documentation.tap()

        XCTAssertTrue(app.navigationBars["Job Documentation"].waitForExistence(timeout: 3))
        let stagePicker = app.segmentedControls["JobDocumentationStagePicker"]
        XCTAssertTrue(stagePicker.waitForExistence(timeout: 3))
        stagePicker.buttons["Closeout"].tap()

        let nextAction = app.buttons["JobCloseoutNextAction"]
        XCTAssertTrue(nextAction.waitForExistence(timeout: 3))
        XCTAssertTrue(nextAction.label.localizedCaseInsensitiveContains("complete technical report"))
        nextAction.tap()

        XCTAssertTrue(stagePicker.buttons["Work"].isSelected)
        XCTAssertTrue(app.staticTexts["Technical HVAC Report"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testJobCloseoutShowsCompactTimeAndMaterialRecoveryStatus() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedInventoryJob",
            "-uiTestSeedOpenJobTime"
        ]
        app.launch()

        let schedule = revealSidebarDestination("Schedule & Jobs", in: app)
        schedule.tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        let documentation = app.buttons["OpenDocumentation-A1000000-0000-4000-8000-000000000002"]
        for _ in 0..<6 where !documentation.exists || !documentation.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(documentation.waitForExistence(timeout: 3))
        documentation.tap()

        XCTAssertTrue(app.navigationBars["Job Documentation"].waitForExistence(timeout: 3))
        let stagePicker = app.segmentedControls["JobDocumentationStagePicker"]
        XCTAssertTrue(stagePicker.waitForExistence(timeout: 3))
        stagePicker.buttons["Closeout"].tap()

        let timeStatus = app.staticTexts["JobTimeCloseoutStatus"]
        let materialStatus = app.staticTexts["JobMaterialCloseoutStatus"]
        for _ in 0..<10 where !timeStatus.exists || !materialStatus.exists {
            app.swipeUp()
        }
        XCTAssertTrue(timeStatus.waitForExistence(timeout: 3))
        XCTAssertTrue(timeStatus.label.localizedCaseInsensitiveContains("1 job timer still running"))
        XCTAssertTrue(materialStatus.waitForExistence(timeout: 3))
        XCTAssertTrue(materialStatus.label.localizedCaseInsensitiveContains("material record"))
        XCTAssertTrue(materialStatus.label.localizedCaseInsensitiveContains("billing"))
    }

    @MainActor
    func testJobWorkStageSurfacesRequiredFieldFormsWithoutOverloadingTheWorkspace() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob"
        ]
        app.launch()

        let schedule = revealSidebarDestination("Schedule & Jobs", in: app)
        schedule.tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        let documentation = app.buttons["OpenDocumentation-A1000000-0000-4000-8000-000000000002"]
        for _ in 0..<5 {
            if documentation.exists && documentation.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(documentation.waitForExistence(timeout: 3))
        documentation.tap()

        XCTAssertTrue(app.navigationBars["Job Documentation"].waitForExistence(timeout: 3))
        let stagePicker = app.segmentedControls["JobDocumentationStagePicker"]
        XCTAssertTrue(stagePicker.waitForExistence(timeout: 3))
        stagePicker.buttons["Work"].tap()

        let readiness = app.descendants(matching: .any)["JobFieldFormsReadiness"]
        for _ in 0..<10 {
            if readiness.exists && readiness.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(readiness.waitForExistence(timeout: 3))
        XCTAssertTrue(readiness.label.localizedCaseInsensitiveContains("0/2 required forms complete"))
        let safetyCheck = app.staticTexts["Complete HVAC Safety Check"]
        for _ in 0..<3 where !safetyCheck.exists {
            app.swipeUp()
        }
        XCTAssertTrue(safetyCheck.exists)
        let serviceDiagnostic = app.staticTexts["Complete Service Diagnostic"]
        for _ in 0..<3 where !serviceDiagnostic.exists {
            app.swipeUp()
        }
        XCTAssertTrue(
            serviceDiagnostic.exists,
            "The second required form was not present in the current iPad accessibility viewport."
        )
        let otherForms = app.staticTexts["Other and completed forms"]
        for _ in 0..<3 where !otherForms.exists {
            app.swipeUp()
        }
        XCTAssertTrue(otherForms.exists)
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

        let schedule = revealSidebarDestination("Schedule & Jobs", in: app)
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
        app.typeKey(.escape, modifierFlags: [])
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
    func testJobBillingSharesOnlyTheExactPendingEstimateInCustomerPortal() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedPendingEstimate"
        ]
        app.launchEnvironment["GUNNAIRE_BACKEND_BASE_URL"] = "https://portal-test.example.invalid"
        app.launchEnvironment["GUNNAIRE_BACKEND_AUTH_MODE"] = "google-id-token"
        app.launch()

        let schedule = revealSidebarDestination("Schedule & Jobs", in: app)
        schedule.tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        let job = app.buttons["OpenServiceCall-\(screenshotServiceCallID)"]
        for _ in 0..<8 where !job.exists || !job.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(job.waitForExistence(timeout: 3))
        XCTAssertTrue(job.isHittable)
        job.tap()

        XCTAssertTrue(app.navigationBars["Call Details"].waitForExistence(timeout: 3))
        let workspacePicker = app.segmentedControls["ServiceCallWorkspacePicker"]
        XCTAssertTrue(workspacePicker.waitForExistence(timeout: 3))
        workspacePicker.buttons["Billing"].tap()

        let sharePortal = app.buttons["Share Customer Portal"]
        for _ in 0..<14 where !sharePortal.exists || !sharePortal.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(sharePortal.waitForExistence(timeout: 3))
        XCTAssertTrue(sharePortal.isHittable)
        sharePortal.tap()

        XCTAssertTrue(app.navigationBars["Customer Portal"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Estimate Approval"].exists)
        XCTAssertTrue(app.staticTexts["Estimate"].exists)
        let amount = app.staticTexts["PortalEstimateAmount"]
        XCTAssertTrue(amount.exists)
        XCTAssertEqual(amount.label, "$425.00")
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'exact amount and line-item revision'")
        ).firstMatch.exists)
        XCTAssertTrue(app.buttons["Create Link"].exists)
    }

    @MainActor
    func testEligibleEstimatePresentsSecureProviderHostedFinancingHandoff() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedPendingEstimate",
            "-uiTestCustomerFinancingReady"
        ]
        app.launch()

        let schedule = revealSidebarDestination("Schedule & Jobs", in: app)
        schedule.tap()

        let documentation = app.buttons["OpenDocumentation-A1000000-0000-4000-8000-000000000002"]
        for _ in 0..<6 {
            if documentation.exists && documentation.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(documentation.waitForExistence(timeout: 3))
        documentation.tap()

        let moreActions = app.buttons["EstimateMoreActions"]
        for _ in 0..<10 {
            if moreActions.exists && moreActions.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(moreActions.waitForExistence(timeout: 3))
        moreActions.tap()

        let financing = app.buttons["Offer Customer Financing"]
        XCTAssertTrue(financing.waitForExistence(timeout: 3))
        financing.tap()

        XCTAssertTrue(app.navigationBars["Customer Financing"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["CustomerFinancingProvider"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["CustomerFinancingProvider"].label.contains("Approved HVAC Finance"))
        XCTAssertTrue(app.staticTexts["CustomerFinancingEstimateTotal"].label.contains("$425.00"))
        XCTAssertTrue(app.staticTexts["CustomerFinancingProviderHost"].label.contains("finance.example.com"))
        let privacyBoundary = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'does not collect or store applicant'")
        ).firstMatch
        XCTAssertTrue(privacyBoundary.exists)
        XCTAssertTrue(app.buttons["OpenCustomerFinancingApplication"].isEnabled)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Job Documentation"].waitForExistence(timeout: 3))
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
        let workspacePicker = app.segmentedControls["ServiceCallWorkspacePicker"]
        XCTAssertTrue(workspacePicker.waitForExistence(timeout: 3))
        workspacePicker.buttons["Overview"].tap()
        let propertyName = app.staticTexts["Primary Service Location"]
        for _ in 0..<4 {
            if propertyName.exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(propertyName.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["100 Test Air Way"].waitForExistence(timeout: 3))
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

        let schedule = revealSidebarDestination("Schedule & Jobs", in: app)
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
        let diagnosticLine = app.staticTexts["HVAC Diagnostic Service"]
        for _ in 0..<6 where !diagnosticLine.exists {
            app.swipeUp()
        }
        XCTAssertTrue(diagnosticLine.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["DocumentDiscountAction"].exists)

        let servicedSystemPicker = app.descendants(matching: .any)["LineEquipmentPicker-\(catalogItemID)"]
        XCTAssertTrue(servicedSystemPicker.waitForExistence(timeout: 3))
        let servicedSystemContext = "\(servicedSystemPicker.label) \(servicedSystemPicker.value ?? "")"
        XCTAssertTrue(servicedSystemContext.contains("Test Heat Pump"))

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
        let saveItem = app.navigationBars["Create Item"].buttons["Save"]
        XCTAssertTrue(saveItem.waitForExistence(timeout: 3))
        XCTAssertTrue(saveItem.isEnabled)
        XCTAssertFalse(saveItem.frame.isEmpty)
        saveItem.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        if app.navigationBars["Create Item"].exists {
            // iPad's decimal keyboard can consume the first toolbar tap solely
            // to resign focus. The second tap activates the still-visible Save.
            saveItem.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }

        XCTAssertTrue(app.navigationBars["Job Documentation"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["UI Test Added Repair"].waitForExistence(timeout: 3))
        let catalogState = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "CatalogSyncState-")
        ).firstMatch
        XCTAssertTrue(catalogState.waitForExistence(timeout: 3))
        XCTAssertEqual(catalogState.label, "Admin pricebook review")
        let removeAddedRepair = app.buttons.matching(
            NSPredicate(format: "label == %@", "Remove UI Test Added Repair from invoice")
        ).firstMatch
        XCTAssertTrue(removeAddedRepair.waitForExistence(timeout: 3))
        XCTAssertTrue(removeAddedRepair.identifier.hasPrefix("RemoveBillingLine-"))
        XCTAssertTrue(removeAddedRepair.isHittable)
        XCTAssertGreaterThanOrEqual(removeAddedRepair.frame.width, 44)
        XCTAssertGreaterThanOrEqual(removeAddedRepair.frame.height, 44)
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
    func testFieldBillingKeepsProviderControlsOutOfDocumentScopedDraftFlow() throws {
        let app = XCUIApplication()
        let draftName = "Scoped Draft \(UUID().uuidString.prefix(8))"
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedTechnician",
            "-uiTestSeedCollectibleJob",
            "-uiTestForceQuickBooksConnected"
        ]
        app.launch()

        let schedule = revealSidebarDestination("Schedule & Jobs", in: app)
        schedule.tap()

        let documentation = app.buttons["OpenDocumentation-A1000000-0000-4000-8000-000000000002"]
        for _ in 0..<6 where !documentation.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(waitForHittable(documentation))
        documentation.tap()

        XCTAssertTrue(app.navigationBars["Job Documentation"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Sync Catalog"].exists)
        XCTAssertEqual(
            app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH 'Publish ' AND label ENDSWITH ' Pending'")
            ).count,
            0
        )

        let createNewItem = app.buttons["Create New Item"]
        for _ in 0..<6 where !createNewItem.exists || !createNewItem.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(createNewItem.waitForExistence(timeout: 3))
        XCTAssertTrue(createNewItem.isHittable)
        createNewItem.tap()

        XCTAssertTrue(app.navigationBars["Create Item"].waitForExistence(timeout: 3))
        let itemName = app.textFields["Item name"]
        XCTAssertTrue(itemName.waitForExistence(timeout: 3))
        replaceText(in: itemName, with: draftName)
        let hideKeyboard = app.buttons["Hide keyboard"]
        if hideKeyboard.waitForExistence(timeout: 2) {
            if waitForHittable(hideKeyboard, timeout: 10) {
                hideKeyboard.tap()
            }
        }
        let saveItem = app.buttons["Save"]
        XCTAssertTrue(waitForHittable(saveItem))
        saveItem.tap()

        XCTAssertTrue(app.navigationBars["Job Documentation"].waitForExistence(timeout: 3))
        let draft = app.staticTexts[draftName]
        for _ in 0..<6 where !draft.exists {
            app.swipeUp()
        }
        XCTAssertTrue(draft.waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "CatalogSyncState-", "Admin pricebook review")
            ).firstMatch.exists
        )
        let removeDraft = app.buttons.matching(
            NSPredicate(format: "label == %@", "Remove \(draftName) from invoice")
        ).firstMatch
        XCTAssertTrue(waitForHittable(removeDraft))
        removeDraft.tap()

        let addLineItems = app.buttons["Add Line Items"]
        for _ in 0..<6 where !addLineItems.exists || !addLineItems.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(addLineItems.waitForExistence(timeout: 3))
        XCTAssertTrue(addLineItems.isHittable)
        addLineItems.tap()
        XCTAssertTrue(app.navigationBars["Select Items"].waitForExistence(timeout: 3))
        let scopedDraft = app.staticTexts[draftName]
        XCTAssertTrue(scopedDraft.waitForExistence(timeout: 3))
        scopedDraft.tap()
        XCTAssertTrue(app.staticTexts["2 lines selected"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()

        XCTAssertTrue(app.navigationBars["Job Documentation"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "label == %@", "Remove \(draftName) from invoice")
            ).firstMatch.waitForExistence(timeout: 3)
        )
    }

    @MainActor
    func testAssignedTechnicianSelectsFlatRatePackageWithServicedSystemContext() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedTechnician",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedServicePackage"
        ]
        app.launch()

        let schedule = revealSidebarDestination("Schedule & Jobs", in: app)
        schedule.tap()

        let documentation = app.buttons["OpenDocumentation-A1000000-0000-4000-8000-000000000002"]
        for _ in 0..<6 {
            if documentation.exists && documentation.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(documentation.waitForExistence(timeout: 3))
        documentation.tap()

        XCTAssertTrue(app.navigationBars["Job Documentation"].waitForExistence(timeout: 3))
        let addLineItems = app.buttons["Add Line Items"]
        for _ in 0..<6 where !addLineItems.exists || !addLineItems.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(addLineItems.waitForExistence(timeout: 3))
        XCTAssertTrue(addLineItems.isHittable)
        addLineItems.tap()

        XCTAssertTrue(app.navigationBars["Select Items"].waitForExistence(timeout: 3))
        let packageName = app.staticTexts["Cooling Tune-Up Package"]
        XCTAssertTrue(packageName.waitForExistence(timeout: 3))
        let packageDefinition = app.staticTexts["ItemAssemblyContext-\(servicePackageItemID)"]
        XCTAssertTrue(packageDefinition.waitForExistence(timeout: 3))
        XCTAssertTrue(packageDefinition.label.contains("Flat Rate package • 2 included"))
        packageName.tap()
        XCTAssertTrue(app.staticTexts["2 lines selected"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()

        XCTAssertTrue(app.navigationBars["Job Documentation"].waitForExistence(timeout: 3))
        let packageContext = app.staticTexts["SelectedAssemblyContext-\(servicePackageItemID)"]
        for _ in 0..<4 {
            if packageContext.exists && packageContext.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(packageContext.waitForExistence(timeout: 3))
        XCTAssertTrue(packageContext.label.contains("Flat-rate package"))

        let servicedSystemPicker = app.descendants(matching: .any)["LineEquipmentPicker-\(servicePackageItemID)"]
        for _ in 0..<4 {
            if servicedSystemPicker.exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(servicedSystemPicker.waitForExistence(timeout: 3))
        let servicedSystemContext = "\(servicedSystemPicker.label) \(servicedSystemPicker.value ?? "")"
        XCTAssertTrue(servicedSystemContext.contains("Test Heat Pump"))
        let updateInvoice = app.buttons["Update Invoice"]
        for _ in 0..<5 {
            if updateInvoice.exists && updateInvoice.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(updateInvoice.waitForExistence(timeout: 3))
        XCTAssertTrue(updateInvoice.isEnabled)
    }

    @MainActor
    func testAdministratorCreatesExactLockedProgressInvoiceFromApprovedProjectMilestone() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedProjectMilestones"
        ]
        app.launch()

        let invoices = revealSidebarDestination("Invoices", in: app)
        invoices.tap()
        XCTAssertTrue(app.navigationBars["Invoices"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Project Milestones Ready"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["$5,550.00"].exists)

        let openReadyMilestone = app.buttons["OpenReadyProjectMilestone-\(projectDepositMilestoneID)"]
        for _ in 0..<8 where !openReadyMilestone.exists || !openReadyMilestone.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(openReadyMilestone.waitForExistence(timeout: 3))
        openReadyMilestone.tap()

        XCTAssertTrue(app.navigationBars["Job Documentation"].waitForExistence(timeout: 8))
        let stagePicker = app.segmentedControls["JobDocumentationStagePicker"]
        XCTAssertTrue(stagePicker.waitForExistence(timeout: 3))
        stagePicker.buttons["Billing"].tap()

        let projectBilling = app.staticTexts["Project Billing"]
        for _ in 0..<8 where !projectBilling.exists {
            app.swipeUp()
        }
        XCTAssertTrue(projectBilling.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["$0.00 invoiced • $0.00 paid • $18,500.00 remaining"].exists)

        let createProgressInvoice = app.buttons["CreateProgressInvoice-\(projectDepositMilestoneID)"]
        for _ in 0..<8 where !createProgressInvoice.exists || !createProgressInvoice.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(createProgressInvoice.waitForExistence(timeout: 3))
        XCTAssertTrue(createProgressInvoice.isHittable)
        createProgressInvoice.tap()

        XCTAssertTrue(app.staticTexts["Create Progress Invoice?"].waitForExistence(timeout: 3))
        let confirm = app.buttons["Create $5,550.00 Invoice"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()

        let reviewInvoice = app.buttons["ReviewProgressInvoice-\(projectDepositMilestoneID)"]
        XCTAssertTrue(reviewInvoice.waitForExistence(timeout: 5))
        reviewInvoice.tap()

        let lockedAllocation = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Progress-invoice lines are locked'")
        ).firstMatch
        for _ in 0..<12 where !lockedAllocation.exists {
            app.swipeUp()
        }
        XCTAssertTrue(lockedAllocation.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["InvoicePrimaryAction"].isEnabled)

        let progressInvoice = app.staticTexts["Progress Invoice 1"]
        for _ in 0..<24 where !progressInvoice.exists {
            app.swipeUp()
        }
        XCTAssertTrue(progressInvoice.waitForExistence(timeout: 5))
        let progressInvoiceStatus = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '$5,550.00' AND label CONTAINS[c] 'Open'")
        ).firstMatch
        for _ in 0..<6 where !progressInvoiceStatus.exists {
            app.swipeUp()
        }
        XCTAssertTrue(progressInvoiceStatus.waitForExistence(timeout: 3))
    }

    @MainActor
    func testAdministratorAuthorizesAJobSpecificLinePriceWithoutChangingThePricebook() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob"
        ]
        app.launch()

        revealSidebarDestination("Schedule & Jobs", in: app).tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        let documentation = app.buttons["OpenDocumentation-A1000000-0000-4000-8000-000000000002"]
        for _ in 0..<6 where !documentation.exists || !documentation.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(documentation.waitForExistence(timeout: 3))
        documentation.tap()

        XCTAssertTrue(app.navigationBars["Job Documentation"].waitForExistence(timeout: 3))
        let stagePicker = app.segmentedControls["JobDocumentationStagePicker"]
        XCTAssertTrue(stagePicker.waitForExistence(timeout: 3))
        stagePicker.buttons["Billing"].tap()

        let adjustPrice = app.buttons["AdjustPrice-A1000000-0000-4000-8000-000000000007"]
        for _ in 0..<5 where !adjustPrice.exists || !adjustPrice.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(adjustPrice.waitForExistence(timeout: 3))
        adjustPrice.tap()

        XCTAssertTrue(app.navigationBars["Discount or Adjust"].waitForExistence(timeout: 3))
        let reason = app.textFields["PriceAdjustmentReason"]
        XCTAssertTrue(reason.waitForExistence(timeout: 3))
        reason.tap()
        reason.typeText("Approved service-plan price")

        let unitPrice = app.textFields["PriceAdjustmentUnitPrice"]
        XCTAssertTrue(unitPrice.waitForExistence(timeout: 3))
        unitPrice.tap()
        let currentPriceText = unitPrice.value as? String ?? "189.00"
        unitPrice.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentPriceText.count))
        unitPrice.typeText("175")
        let authorize = app.buttons["Authorize Price"]
        XCTAssertTrue(authorize.isEnabled)
        authorize.tap()

        XCTAssertFalse(app.navigationBars["Discount or Adjust"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.navigationBars["Job Documentation"].waitForExistence(timeout: 3))
        XCTAssertEqual(adjustPrice.label, "Edit Adjustment")
        XCTAssertTrue(
            app.staticTexts["AuthorizedPriceAdjustment-A1000000-0000-4000-8000-000000000007"]
                .waitForExistence(timeout: 3)
        )

        let updateInvoice = app.buttons["Update Invoice"]
        for _ in 0..<5 where !updateInvoice.exists || !updateInvoice.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(updateInvoice.waitForExistence(timeout: 3))
        XCTAssertTrue(updateInvoice.isEnabled)
        updateInvoice.tap()
        XCTAssertTrue(app.staticTexts["QuickBooks update pending"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testAdministratorAuthorizesDocumentDiscountWithoutChangingCatalogLines() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob"
        ]
        app.launch()

        revealSidebarDestination("Schedule & Jobs", in: app).tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        let documentation = app.buttons["OpenDocumentation-\(screenshotServiceCallID)"]
        for _ in 0..<6 where !documentation.exists || !documentation.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(documentation.waitForExistence(timeout: 3))
        documentation.tap()

        XCTAssertTrue(app.navigationBars["Job Documentation"].waitForExistence(timeout: 3))
        let stagePicker = app.segmentedControls["JobDocumentationStagePicker"]
        XCTAssertTrue(stagePicker.waitForExistence(timeout: 3))
        stagePicker.buttons["Billing"].tap()

        let discountAction = app.buttons["DocumentDiscountAction"]
        for _ in 0..<7 where !discountAction.exists || !discountAction.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(discountAction.waitForExistence(timeout: 3))
        XCTAssertEqual(discountAction.label, "Add Document Discount")
        discountAction.tap()

        XCTAssertTrue(app.navigationBars["Add Discount"].waitForExistence(timeout: 3))
        let discountValue = app.textFields["DocumentDiscountValue"]
        XCTAssertTrue(discountValue.waitForExistence(timeout: 3))
        discountValue.tap()
        discountValue.typeText("10")

        let reason = app.textFields["DocumentDiscountReason"]
        XCTAssertTrue(reason.waitForExistence(timeout: 3))
        let expectedReason = "Plan"
        reason.tap()
        reason.typeText(expectedReason)
        let completeReason = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expectedReason),
            object: reason
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [completeReason], timeout: 5),
            .completed,
            "Discount reason did not finish entering before the keyboard was dismissed. Current value: \(String(describing: reason.value))"
        )
        if app.keyboards.firstMatch.exists {
            app.typeKey(.escape, modifierFlags: [])
        }

        let authorize = app.buttons["AuthorizeDocumentDiscount"]
        XCTAssertTrue(authorize.waitForExistence(timeout: 3))
        XCTAssertTrue(authorize.isEnabled)
        authorize.tap()

        XCTAssertTrue(app.navigationBars["Job Documentation"].waitForExistence(timeout: 3))
        let summary = app.staticTexts["AuthorizedDocumentDiscount"]
        XCTAssertTrue(summary.waitForExistence(timeout: 3))
        XCTAssertTrue(summary.label.contains("10%"))
        XCTAssertTrue(
            summary.label.contains(expectedReason),
            "Unexpected authorized discount summary: \(summary.label)"
        )
        XCTAssertFalse(summary.label.contains("@"))
        XCTAssertTrue(app.staticTexts["−$18.90"].exists)
        let netSubtotal = app.staticTexts["DocumentNetSubtotal"]
        for _ in 0..<3 where !netSubtotal.exists {
            app.swipeUp()
        }
        XCTAssertTrue(netSubtotal.waitForExistence(timeout: 3))
        XCTAssertTrue(netSubtotal.label.contains("$170.10"))

        let updateInvoice = app.buttons["Update Invoice"]
        for _ in 0..<6 where !updateInvoice.exists || !updateInvoice.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(updateInvoice.waitForExistence(timeout: 3))
        XCTAssertTrue(updateInvoice.isEnabled)
        updateInvoice.tap()
        XCTAssertTrue(app.staticTexts["QuickBooks update pending"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testTaxableBillingShowsOneClearQuickBooksTotalHandoff() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedPendingQuickBooksTax"
        ]
        app.launch()

        revealSidebarDestination("Schedule & Jobs", in: app).tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        let documentation = app.buttons["OpenDocumentation-\(screenshotServiceCallID)"]
        for _ in 0..<6 where !documentation.exists || !documentation.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(documentation.waitForExistence(timeout: 3))
        documentation.tap()

        XCTAssertTrue(app.navigationBars["Job Documentation"].waitForExistence(timeout: 3))
        let stagePicker = app.segmentedControls["JobDocumentationStagePicker"]
        XCTAssertTrue(stagePicker.waitForExistence(timeout: 3))
        stagePicker.buttons["Billing"].tap()

        let notice = app.staticTexts["QuickBooksTaxCalculationNotice"]
        for _ in 0..<6 where !notice.exists {
            app.swipeUp()
        }
        XCTAssertTrue(notice.waitForExistence(timeout: 3))
        XCTAssertTrue(notice.label.contains("QuickBooks calculates sales tax"))
        XCTAssertTrue(app.staticTexts["DocumentNetSubtotal"].exists)
        XCTAssertFalse(app.staticTexts["Sales Tax Rate"].exists)
        XCTAssertTrue(app.buttons["Discount / Adjust"].exists)
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

        let schedule = revealSidebarDestination("Schedule & Jobs", in: app)
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

        let schedule = revealSidebarDestination("Schedule & Jobs", in: app)
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

        let receiptsBills = revealSidebarDestination("Receipts & Bills", in: app)
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
    func testAdministratorRecordsSupplierEvidenceBeforeReceivingAPurchaseOrder() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedPurchaseOrderDraft"
        ]
        app.launch()

        let receiptsBills = app.staticTexts["Receipts & Bills"]
        if !receiptsBills.waitForExistence(timeout: 2) {
            let sidebarButton = app.buttons["GunnAire Ops"]
            XCTAssertTrue(sidebarButton.waitForExistence(timeout: 3))
            sidebarButton.tap()
        }
        XCTAssertTrue(receiptsBills.waitForExistence(timeout: 3))
        receiptsBills.tap()
        XCTAssertTrue(app.navigationBars["Receipts & Bills"].waitForExistence(timeout: 3))

        let workspacePicker = app.segmentedControls["ReceiptsBillsWorkspacePicker"]
        XCTAssertTrue(workspacePicker.waitForExistence(timeout: 3))
        workspacePicker.buttons["Purchasing"].tap()

        let confirmOrder = app.buttons["ConfirmPurchaseOrder-A1000000-0000-4000-8000-000000000018"]
        for _ in 0..<8 where !confirmOrder.exists || !confirmOrder.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(confirmOrder.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Receive Shipment"].exists)
        confirmOrder.tap()

        XCTAssertTrue(app.navigationBars["Confirm Supplier Order"].waitForExistence(timeout: 3))
        let reference = app.textFields["SupplierOrderReference"]
        XCTAssertTrue(reference.waitForExistence(timeout: 3))
        reference.tap()
        reference.typeText("JS-UI-48291\n")

        let location = app.textFields["SupplierOrderLocation"]
        XCTAssertTrue(location.waitForExistence(timeout: 3))
        location.tap()
        location.typeText("Winston-Salem")

        let recordConfirmation = app.buttons["ConfirmSupplierOrder"]
        XCTAssertTrue(recordConfirmation.isEnabled)
        recordConfirmation.tap()

        XCTAssertFalse(app.navigationBars["Confirm Supplier Order"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.navigationBars["Receipts & Bills"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.descendants(matching: .any)["SupplierOrderEvidence-A1000000-0000-4000-8000-000000000018"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.staticTexts["Ordered"].exists)
        let receiveShipment = app.buttons["ReceiveShipment-A1000000-0000-4000-8000-000000000018"]
        XCTAssertTrue(receiveShipment.waitForExistence(timeout: 3))
        XCTAssertFalse(confirmOrder.exists)

        receiveShipment.tap()
        XCTAssertTrue(app.navigationBars["Receive Shipment"].waitForExistence(timeout: 3))

        let note = app.textFields["PurchaseOrderReceiptNote"]
        XCTAssertTrue(waitForHittable(note))
        note.tap()
        note.typeText("Packing slip UI-1; one unit backordered.")

        let doneEditingShipment = app.buttons["Done Editing Shipment"]
        XCTAssertTrue(doneEditingShipment.waitForExistence(timeout: 3))
        doneEditingShipment.tap()

        let quantity = app.textFields["PurchaseOrderReceiptQuantity"]
        XCTAssertTrue(waitForHittable(quantity))
        replaceText(in: quantity, with: "1")
        XCTAssertEqual(quantity.value as? String, "1", app.debugDescription)
        XCTAssertTrue(doneEditingShipment.waitForExistence(timeout: 3))
        doneEditingShipment.tap()

        let confirmReceipt = app.buttons["ConfirmPurchaseOrderReceipt"]
        let receiptEnabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: confirmReceipt
        )
        XCTAssertEqual(XCTWaiter.wait(for: [receiptEnabled], timeout: 3), .completed)
        confirmReceipt.tap()

        XCTAssertFalse(app.navigationBars["Receive Shipment"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.staticTexts["Partially Received"].waitForExistence(timeout: 3))
        let receivingSummary = app.staticTexts[
            "PurchaseOrderReceivingSummary-A1000000-0000-4000-8000-000000000018"
        ]
        XCTAssertTrue(receivingSummary.waitForExistence(timeout: 3))
        XCTAssertTrue(receivingSummary.label.contains("1 of 2 received"))
        XCTAssertTrue(receivingSummary.label.contains("1 backordered"))
        XCTAssertTrue(app.buttons["Receive Balance"].exists)

        let recordBill = app.buttons["RecordVendorBill-A1000000-0000-4000-8000-000000000018"]
        for _ in 0..<8 where !recordBill.exists || !recordBill.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(recordBill.waitForExistence(timeout: 3))
        XCTAssertTrue(recordBill.isHittable)
        recordBill.tap()

        XCTAssertTrue(app.navigationBars["Record Vendor Bill"].waitForExistence(timeout: 3))
        let invoiceNumber = app.textFields["PurchaseOrderBillInvoiceNumber"]
        XCTAssertTrue(invoiceNumber.waitForExistence(timeout: 3))
        invoiceNumber.tap()
        invoiceNumber.typeText("JS-UI-INV-1")

        let doneEditingBill = app.buttons["Done Editing Vendor Bill"]
        if doneEditingBill.exists && doneEditingBill.isHittable {
            doneEditingBill.tap()
        }

        let billDocument = app.textFields["PurchaseOrderBillDocumentName"]
        for _ in 0..<6 where !billDocument.exists || !billDocument.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(billDocument.waitForExistence(timeout: 3))
        XCTAssertTrue(billDocument.isHittable)
        billDocument.tap()
        billDocument.typeText("johnstone-ui-invoice.pdf")
        if doneEditingBill.exists && doneEditingBill.isHittable {
            doneEditingBill.tap()
        }

        let quickBooksBillID = app.textFields["PurchaseOrderBillQuickBooksID"]
        for _ in 0..<3 where !quickBooksBillID.exists || !quickBooksBillID.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(quickBooksBillID.waitForExistence(timeout: 3))
        XCTAssertTrue(quickBooksBillID.isHittable)
        quickBooksBillID.tap()
        quickBooksBillID.typeText("QBO-BILL-UI-1")
        if doneEditingBill.exists && doneEditingBill.isHittable {
            doneEditingBill.tap()
        }

        let confirmBill = app.buttons["ConfirmPurchaseOrderBill"]
        XCTAssertTrue(confirmBill.waitForExistence(timeout: 3))
        XCTAssertTrue(confirmBill.isEnabled)
        confirmBill.tap()

        XCTAssertFalse(app.navigationBars["Record Vendor Bill"].waitForExistence(timeout: 1))
        let billMatch = app.staticTexts[
            "PurchaseOrderBillMatch-A1000000-0000-4000-8000-000000000018"
        ]
        XCTAssertTrue(billMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(billMatch.label.contains("1 of 2 billed"))
        XCTAssertTrue(recordBill.exists)
    }

    @MainActor
    func testAdministratorCompletesMultiLinePurchaseOrderReceiptAndBillHandoff() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedMultiLinePurchaseOrderDraft"
        ]
        app.launch()

        let receiptsBills = app.staticTexts["Receipts & Bills"]
        if !receiptsBills.waitForExistence(timeout: 2) {
            let sidebarButton = app.buttons["GunnAire Ops"]
            XCTAssertTrue(sidebarButton.waitForExistence(timeout: 3))
            sidebarButton.tap()
        }
        XCTAssertTrue(receiptsBills.waitForExistence(timeout: 3))
        receiptsBills.tap()
        XCTAssertTrue(app.navigationBars["Receipts & Bills"].waitForExistence(timeout: 3))

        let workspacePicker = app.segmentedControls["ReceiptsBillsWorkspacePicker"]
        XCTAssertTrue(workspacePicker.waitForExistence(timeout: 3))
        workspacePicker.buttons["Purchasing"].tap()

        let confirmOrder = app.buttons["ConfirmPurchaseOrder-A1000000-0000-4000-8000-000000000018"]
        for _ in 0..<8 where !confirmOrder.exists || !confirmOrder.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(confirmOrder.waitForExistence(timeout: 3))
        confirmOrder.tap()

        XCTAssertTrue(app.navigationBars["Confirm Supplier Order"].waitForExistence(timeout: 3))
        let lineCountSummary = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "2 item lines")
        ).firstMatch
        XCTAssertTrue(lineCountSummary.waitForExistence(timeout: 3))
        let reference = app.textFields["SupplierOrderReference"]
        XCTAssertTrue(reference.waitForExistence(timeout: 3))
        reference.tap()
        reference.typeText("JS-UI-MULTI-100")
        let doneSupplier = app.buttons["Done Editing Supplier Order"]
        if doneSupplier.exists && doneSupplier.isHittable {
            doneSupplier.tap()
        }
        let supplierLineCosts = app.textFields.matching(
            NSPredicate(format: "identifier BEGINSWITH 'SupplierOrderUnitCost'")
        )
        for _ in 0..<6 where supplierLineCosts.count < 2 {
            app.swipeUp()
        }
        XCTAssertEqual(supplierLineCosts.count, 2)
        let recordConfirmation = app.buttons["ConfirmSupplierOrder"]
        XCTAssertTrue(recordConfirmation.isEnabled)
        recordConfirmation.tap()

        let receiveShipment = app.buttons["ReceiveShipment-A1000000-0000-4000-8000-000000000018"]
        XCTAssertTrue(receiveShipment.waitForExistence(timeout: 3))
        receiveShipment.tap()
        XCTAssertTrue(app.navigationBars["Receive Shipment"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["PurchaseOrderReceiptLine"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields["PurchaseOrderReceiptQuantity"].value as? String, "2")
        let firstReceipt = app.buttons["ConfirmPurchaseOrderReceipt"]
        XCTAssertTrue(firstReceipt.isEnabled)
        firstReceipt.tap()

        XCTAssertTrue(app.staticTexts["Partially Received"].waitForExistence(timeout: 3))
        let receivingSummary = app.staticTexts[
            "PurchaseOrderReceivingSummary-A1000000-0000-4000-8000-000000000018"
        ]
        XCTAssertTrue(receivingSummary.waitForExistence(timeout: 3))
        XCTAssertTrue(receivingSummary.label.contains("2 of 3 received"))

        let receiveBalance = app.buttons["ReceiveShipment-A1000000-0000-4000-8000-000000000018"]
        XCTAssertTrue(receiveBalance.waitForExistence(timeout: 3))
        receiveBalance.tap()
        XCTAssertTrue(app.navigationBars["Receive Shipment"].waitForExistence(timeout: 3))
        let remainingLine = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Premium Pleated Filter")
        ).firstMatch
        XCTAssertTrue(remainingLine.waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields["PurchaseOrderReceiptQuantity"].value as? String, "1")
        let finalReceipt = app.buttons["ConfirmPurchaseOrderReceipt"]
        XCTAssertTrue(finalReceipt.isEnabled)
        finalReceipt.tap()

        let completedReceivingMessage = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "PO-UI-CONFIRM is complete")
        ).firstMatch
        XCTAssertTrue(completedReceivingMessage.waitForExistence(timeout: 3))
        let recordBill = app.buttons["RecordVendorBill-A1000000-0000-4000-8000-000000000018"]
        for _ in 0..<8 where !recordBill.exists || !recordBill.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(recordBill.waitForExistence(timeout: 3))
        recordBill.tap()

        XCTAssertTrue(app.navigationBars["Record Vendor Bill"].waitForExistence(timeout: 3))
        let invoiceNumber = app.textFields["PurchaseOrderBillInvoiceNumber"]
        XCTAssertTrue(invoiceNumber.waitForExistence(timeout: 3))
        invoiceNumber.tap()
        invoiceNumber.typeText("JS-UI-MULTI-INV-100")
        let doneBill = app.buttons["Done Editing Vendor Bill"]
        if doneBill.exists && doneBill.isHittable {
            doneBill.tap()
        }
        let billLineQuantities = app.textFields.matching(
            NSPredicate(format: "identifier BEGINSWITH 'PurchaseOrderBillQuantity'")
        )
        for _ in 0..<6 where billLineQuantities.count < 2 {
            app.swipeUp()
        }
        XCTAssertEqual(billLineQuantities.count, 2)
        let confirmBill = app.buttons["ConfirmPurchaseOrderBill"]
        for _ in 0..<6 where !confirmBill.exists || !confirmBill.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(confirmBill.waitForExistence(timeout: 3))
        XCTAssertTrue(confirmBill.isEnabled)
        confirmBill.tap()

        let matchedMessage = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Recorded vendor invoice JS-UI-MULTI-INV-100")
        ).firstMatch
        XCTAssertTrue(matchedMessage.waitForExistence(timeout: 3))
        XCTAssertTrue(matchedMessage.label.contains("Three-Way Matched"))
        XCTAssertTrue(matchedMessage.label.contains("3 billed"))
    }

    @MainActor
    func testAdministratorReceivesSerializedEquipmentAndAddsTheInstalledCustomerSystem() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedSerializedPurchaseOrderDraft"
        ]
        app.launch()

        let receiptsBills = app.staticTexts["Receipts & Bills"]
        if !receiptsBills.waitForExistence(timeout: 2) {
            let sidebarButton = app.buttons["GunnAire Ops"]
            XCTAssertTrue(sidebarButton.waitForExistence(timeout: 3))
            sidebarButton.tap()
        }
        XCTAssertTrue(receiptsBills.waitForExistence(timeout: 3))
        receiptsBills.tap()
        XCTAssertTrue(app.navigationBars["Receipts & Bills"].waitForExistence(timeout: 3))

        let workspacePicker = app.segmentedControls["ReceiptsBillsWorkspacePicker"]
        XCTAssertTrue(workspacePicker.waitForExistence(timeout: 3))
        workspacePicker.buttons["Purchasing"].tap()

        let confirmOrder = app.buttons["ConfirmPurchaseOrder-A1000000-0000-4000-8000-000000000018"]
        for _ in 0..<8 where !confirmOrder.exists || !confirmOrder.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(confirmOrder.waitForExistence(timeout: 3))
        confirmOrder.tap()

        XCTAssertTrue(app.navigationBars["Confirm Supplier Order"].waitForExistence(timeout: 3))
        let reference = app.textFields["SupplierOrderReference"]
        XCTAssertTrue(reference.waitForExistence(timeout: 3))
        reference.tap()
        reference.typeText("LEN-UI-SERIAL-100")
        let doneSupplier = app.buttons["Done Editing Supplier Order"]
        if doneSupplier.exists && doneSupplier.isHittable {
            doneSupplier.tap()
        }
        let recordConfirmation = app.buttons["ConfirmSupplierOrder"]
        XCTAssertTrue(recordConfirmation.waitForExistence(timeout: 3))
        XCTAssertTrue(recordConfirmation.isEnabled)
        recordConfirmation.tap()

        let receiveShipment = app.buttons["ReceiveShipment-A1000000-0000-4000-8000-000000000018"]
        XCTAssertTrue(receiveShipment.waitForExistence(timeout: 3))
        receiveShipment.tap()
        XCTAssertTrue(app.navigationBars["Receive Shipment"].waitForExistence(timeout: 3))
        let manufacturer = app.textFields["PurchaseOrderReceiptManufacturer"]
        for _ in 0..<4 where !manufacturer.exists || !manufacturer.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(manufacturer.waitForExistence(timeout: 3))
        manufacturer.tap()
        manufacturer.typeText("Lennox")
        let doneReceipt = app.buttons["Done Editing Shipment"]
        if doneReceipt.waitForExistence(timeout: 1), doneReceipt.isHittable {
            doneReceipt.tap()
        }

        let model = app.textFields["PurchaseOrderReceiptModel"]
        XCTAssertTrue(model.waitForExistence(timeout: 3))
        model.tap()
        model.typeText("ML17XP1-036")
        if doneReceipt.waitForExistence(timeout: 1), doneReceipt.isHittable {
            doneReceipt.tap()
        }

        let serials = app.textFields["PurchaseOrderReceiptSerialNumbers"]
        XCTAssertTrue(serials.waitForExistence(timeout: 3))
        serials.tap()
        serials.typeText("LEN-UI-9000")
        if doneReceipt.exists && doneReceipt.isHittable {
            doneReceipt.tap()
        }
        let serialCount = app.staticTexts["PurchaseOrderReceiptSerialCount"]
        XCTAssertTrue(serialCount.waitForExistence(timeout: 3))
        XCTAssertTrue(serialCount.label.contains("1 of 1"))

        let confirmReceipt = app.buttons["ConfirmPurchaseOrderReceipt"]
        XCTAssertTrue(confirmReceipt.waitForExistence(timeout: 3))
        XCTAssertTrue(confirmReceipt.isEnabled)
        confirmReceipt.tap()

        let capturedMessage = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Captured 1 serialized asset")
        ).firstMatch
        XCTAssertTrue(capturedMessage.waitForExistence(timeout: 3))

        let shipmentHistory = app.buttons["Shipment history"]
        for _ in 0..<8 where !shipmentHistory.exists || !shipmentHistory.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(shipmentHistory.waitForExistence(timeout: 3))
        shipmentHistory.tap()

        let addCustomerSystem = app.buttons["Add Customer System"]
        for _ in 0..<6 where !addCustomerSystem.exists || !addCustomerSystem.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(addCustomerSystem.waitForExistence(timeout: 3))
        addCustomerSystem.tap()

        XCTAssertTrue(app.navigationBars["Add Customer System"].waitForExistence(timeout: 3))
        let installedSerial = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "LEN-UI-9000")
        ).firstMatch
        XCTAssertTrue(installedSerial.waitForExistence(timeout: 3))
        let equipmentName = app.textFields["PurchaseOrderInstallEquipmentName"]
        for _ in 0..<5 where !equipmentName.exists || !equipmentName.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(equipmentName.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue((equipmentName.value as? String)?.hasPrefix("Lennox Elite Heat") == true)
        let confirmInstallation = app.buttons["ConfirmPurchaseOrderAssetInstallation"]
        XCTAssertTrue(confirmInstallation.waitForExistence(timeout: 3))
        XCTAssertTrue(confirmInstallation.isEnabled)
        confirmInstallation.tap()

        let installedMessage = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Added Lennox Elite Heat Pump")
        ).firstMatch
        XCTAssertTrue(installedMessage.waitForExistence(timeout: 3))
        XCTAssertTrue(installedMessage.label.contains("LEN-UI-9000"))
        XCTAssertFalse(app.buttons["Add Customer System"].exists)
    }

    @MainActor
    func testAdministratorCompletesSerializedSupplierReturnAndVendorCredit() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedSerializedPurchaseOrderDraft"
        ]
        app.launch()

        let receiptsBills = app.staticTexts["Receipts & Bills"]
        if !receiptsBills.waitForExistence(timeout: 2) {
            let sidebarButton = app.buttons["GunnAire Ops"]
            XCTAssertTrue(sidebarButton.waitForExistence(timeout: 3))
            sidebarButton.tap()
        }
        XCTAssertTrue(receiptsBills.waitForExistence(timeout: 3))
        receiptsBills.tap()
        XCTAssertTrue(app.navigationBars["Receipts & Bills"].waitForExistence(timeout: 3))

        let workspacePicker = app.segmentedControls["ReceiptsBillsWorkspacePicker"]
        XCTAssertTrue(workspacePicker.waitForExistence(timeout: 3))
        workspacePicker.buttons["Purchasing"].tap()

        let confirmOrder = app.buttons["ConfirmPurchaseOrder-A1000000-0000-4000-8000-000000000018"]
        for _ in 0..<8 where !confirmOrder.exists || !confirmOrder.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(confirmOrder.waitForExistence(timeout: 3))
        confirmOrder.tap()

        XCTAssertTrue(app.navigationBars["Confirm Supplier Order"].waitForExistence(timeout: 3))
        let supplierReference = app.textFields["SupplierOrderReference"]
        XCTAssertTrue(supplierReference.waitForExistence(timeout: 3))
        supplierReference.tap()
        supplierReference.typeText("LEN-UI-RETURN-100")
        let doneSupplier = app.buttons["Done Editing Supplier Order"]
        if doneSupplier.exists && doneSupplier.isHittable {
            doneSupplier.tap()
        }
        let recordConfirmation = app.buttons["ConfirmSupplierOrder"]
        XCTAssertTrue(recordConfirmation.waitForExistence(timeout: 3))
        XCTAssertTrue(recordConfirmation.isEnabled)
        recordConfirmation.tap()

        let receiveShipment = app.buttons["ReceiveShipment-A1000000-0000-4000-8000-000000000018"]
        XCTAssertTrue(receiveShipment.waitForExistence(timeout: 3))
        receiveShipment.tap()
        XCTAssertTrue(app.navigationBars["Receive Shipment"].waitForExistence(timeout: 3))

        let manufacturer = app.textFields["PurchaseOrderReceiptManufacturer"]
        for _ in 0..<4 where !manufacturer.exists || !manufacturer.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(manufacturer.waitForExistence(timeout: 3))
        manufacturer.tap()
        manufacturer.typeText("Lennox")
        let doneReceipt = app.buttons["Done Editing Shipment"]
        if doneReceipt.exists && doneReceipt.isHittable {
            doneReceipt.tap()
        }

        let model = app.textFields["PurchaseOrderReceiptModel"]
        XCTAssertTrue(model.waitForExistence(timeout: 3))
        model.tap()
        model.typeText("ML17XP1-036")
        if doneReceipt.exists && doneReceipt.isHittable {
            doneReceipt.tap()
        }

        let serials = app.textFields["PurchaseOrderReceiptSerialNumbers"]
        XCTAssertTrue(serials.waitForExistence(timeout: 3))
        serials.tap()
        serials.typeText("LEN-UI-RETURN-9000")
        if doneReceipt.exists && doneReceipt.isHittable {
            doneReceipt.tap()
        }
        XCTAssertTrue(app.staticTexts["PurchaseOrderReceiptSerialCount"].waitForExistence(timeout: 3))

        let confirmReceipt = app.buttons["ConfirmPurchaseOrderReceipt"]
        XCTAssertTrue(confirmReceipt.waitForExistence(timeout: 3))
        XCTAssertTrue(confirmReceipt.isEnabled)
        confirmReceipt.tap()

        let createReturn = app.buttons["CreateVendorReturn-A1000000-0000-4000-8000-000000000018"]
        for _ in 0..<10 where !createReturn.exists || !createReturn.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(createReturn.waitForExistence(timeout: 3))
        createReturn.tap()

        XCTAssertTrue(app.navigationBars["Create Supplier Return"].waitForExistence(timeout: 3))
        let returnReference = app.textFields["VendorReturnReference"]
        XCTAssertTrue(returnReference.waitForExistence(timeout: 3))
        returnReference.tap()
        returnReference.typeText("RMA-UI-RETURN-100")
        let doneReturn = app.buttons["Done Editing Supplier Return"]
        if doneReturn.exists && doneReturn.isHittable {
            doneReturn.tap()
        }
        let returnReason = app.textFields["VendorReturnReason"]
        XCTAssertTrue(returnReason.waitForExistence(timeout: 3))
        returnReason.tap()
        returnReason.typeText("Data plate damage found before installation")
        if doneReturn.exists && doneReturn.isHittable {
            doneReturn.tap()
        }

        let serializedAsset = app.switches.matching(
            NSPredicate(format: "label CONTAINS %@", "LEN-UI-RETURN-9000")
        ).firstMatch
        for _ in 0..<5 where !serializedAsset.exists || !serializedAsset.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(serializedAsset.waitForExistence(timeout: 3))
        let selectAllReturnable = app.buttons["SelectAllVendorReturnItems"]
        XCTAssertTrue(selectAllReturnable.waitForExistence(timeout: 3))
        selectAllReturnable.tap()
        XCTAssertEqual(serializedAsset.value as? String, "1")

        let confirmReturn = app.buttons["ConfirmVendorReturn"]
        XCTAssertTrue(confirmReturn.waitForExistence(timeout: 3))
        XCTAssertTrue(confirmReturn.isEnabled)
        confirmReturn.tap()

        let createdMessage = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Created supplier return RMA-UI-RETURN-100")
        ).firstMatch
        XCTAssertTrue(createdMessage.waitForExistence(timeout: 3))

        let supplierReturns = app.buttons["Supplier returns"]
        for _ in 0..<8 where !supplierReturns.exists || !supplierReturns.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(supplierReturns.waitForExistence(timeout: 3))
        supplierReturns.tap()

        let actionMenu = app.buttons["Return Actions"]
        for _ in 0..<5 where !actionMenu.exists || !actionMenu.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(actionMenu.waitForExistence(timeout: 3))
        actionMenu.tap()
        XCTAssertTrue(app.buttons["Mark Sent"].waitForExistence(timeout: 3))
        app.buttons["Mark Sent"].tap()

        XCTAssertTrue(app.navigationBars["Mark Return Sent"].waitForExistence(timeout: 3))
        let confirmSent = app.buttons["ConfirmVendorReturnAction"]
        XCTAssertTrue(confirmSent.waitForExistence(timeout: 3))
        confirmSent.tap()
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Marked supplier return RMA-UI-RETURN-100 sent")
        ).firstMatch.waitForExistence(timeout: 3))

        for _ in 0..<5 where !actionMenu.exists || !actionMenu.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(actionMenu.waitForExistence(timeout: 3))
        actionMenu.tap()
        XCTAssertTrue(app.buttons["Mark Returned"].waitForExistence(timeout: 3))
        app.buttons["Mark Returned"].tap()

        XCTAssertTrue(app.navigationBars["Mark Return Complete"].waitForExistence(timeout: 3))
        let confirmReturned = app.buttons["ConfirmVendorReturnAction"]
        XCTAssertTrue(confirmReturned.waitForExistence(timeout: 3))
        confirmReturned.tap()
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Completed supplier return RMA-UI-RETURN-100")
        ).firstMatch.waitForExistence(timeout: 3))

        for _ in 0..<5 where !actionMenu.exists || !actionMenu.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(actionMenu.waitForExistence(timeout: 3))
        actionMenu.tap()
        XCTAssertTrue(app.buttons["Record Vendor Credit"].waitForExistence(timeout: 3))
        app.buttons["Record Vendor Credit"].tap()

        XCTAssertTrue(app.navigationBars["Record Vendor Credit"].waitForExistence(timeout: 3))
        let creditReference = app.textFields["VendorCreditReference"]
        XCTAssertTrue(creditReference.waitForExistence(timeout: 3))
        creditReference.tap()
        creditReference.typeText("VC-UI-RETURN-100")
        let doneCredit = app.buttons["Done"].firstMatch
        if doneCredit.exists && doneCredit.isHittable {
            doneCredit.tap()
        }
        let confirmCredit = app.buttons["ConfirmVendorCredit"]
        XCTAssertTrue(confirmCredit.waitForExistence(timeout: 3))
        XCTAssertTrue(confirmCredit.isEnabled)
        confirmCredit.tap()

        let creditMessage = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Recorded supplier credit VC-UI-RETURN-100")
        ).firstMatch
        XCTAssertTrue(creditMessage.waitForExistence(timeout: 3))
        XCTAssertTrue(creditMessage.label.contains("Vendor Credit Matched"))
        XCTAssertFalse(actionMenu.exists)
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

        let schedule = revealSidebarDestination("Schedule & Jobs", in: app)
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

        let historyWorkspace = workspacePicker.buttons["History"]
        historyWorkspace.tap()
        let historySelected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"),
            object: historyWorkspace
        )
        XCTAssertEqual(XCTWaiter.wait(for: [historySelected], timeout: 3), .completed)
        XCTAssertTrue(app.staticTexts["Job Activity"].exists)
        XCTAssertTrue(app.staticTexts["Membership & History"].exists)
        XCTAssertFalse(app.staticTexts["Completion Checklist"].exists)

        workspacePicker.buttons["Overview"].tap()
        XCTAssertTrue(workspacePicker.buttons["Overview"].isSelected)
        XCTAssertTrue(app.staticTexts["Customer Contact"].exists)
        XCTAssertFalse(app.staticTexts["Membership & History"].exists)
    }

    @MainActor
    func testPostJobReviewDraftRequiresExplicitCustomerMarketingConsent() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-appStoreScreenshotFixtures",
            "-enableMarketingCampaigns", "YES",
            "-customerReviewURL", "https://review.example.invalid/gunnaire"
        ]
        app.launchEnvironment["GUNNAIRE_BACKEND_AUTH_MODE"] = "disabled-for-screenshot"
        app.launch()

        let schedule = revealSidebarDestination("Schedule & Jobs", in: app)
        schedule.tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        let job = app.buttons["OpenServiceCall-\(screenshotServiceCallID)"]
        for _ in 0..<8 where !job.exists || !job.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(job.waitForExistence(timeout: 3))
        XCTAssertTrue(job.isHittable)
        job.tap()

        XCTAssertTrue(app.navigationBars["Call Details"].waitForExistence(timeout: 3))
        let workspacePicker = app.segmentedControls["ServiceCallWorkspacePicker"]
        XCTAssertTrue(workspacePicker.waitForExistence(timeout: 3))
        workspacePicker.buttons["Overview"].tap()

        // Customer Contact is rendered after the optional review action, so
        // reaching it proves this absence is the consent gate rather than an
        // unexamined portion of the job overview.
        let customerContact = app.staticTexts["Customer Contact"]
        for _ in 0..<12 where !customerContact.exists {
            app.swipeUp()
        }
        XCTAssertTrue(customerContact.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Draft Review Request"].exists)
        XCTAssertFalse(app.staticTexts["Optional marketing follow-up. It opens as a draft and is recorded only after staff sends it."].exists)

        let customers = revealSidebarDestination("Customers", in: app)
        customers.tap()
        XCTAssertTrue(app.navigationBars["Customers"].waitForExistence(timeout: 3))

        let customerRecord = app.buttons["OpenCustomerRecord-\(screenshotCustomerID)"]
        for _ in 0..<6 where !customerRecord.exists || !customerRecord.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(customerRecord.waitForExistence(timeout: 3))
        XCTAssertTrue(customerRecord.isHittable)
        customerRecord.tap()
        XCTAssertTrue(app.navigationBars["Edit Customer"].waitForExistence(timeout: 3))

        let marketingConsent = app.switches["Allow marketing email"]
        let customerForm = app.collectionViews.firstMatch
        for _ in 0..<8 where !marketingConsent.exists || !marketingConsent.isHittable {
            customerForm.swipeUp()
        }
        XCTAssertTrue(marketingConsent.waitForExistence(timeout: 3))
        XCTAssertTrue(marketingConsent.isHittable)
        XCTAssertEqual(marketingConsent.value as? String, "0")
        marketingConsent.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(marketingConsent.value as? String, "1")

        let save = app.navigationBars["Edit Customer"].buttons["Save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.navigationBars["Customers"].waitForExistence(timeout: 3))

        let scheduleAgain = revealSidebarDestination("Schedule & Jobs", in: app)
        scheduleAgain.tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        let restoredJob = app.buttons["OpenServiceCall-\(screenshotServiceCallID)"]
        for _ in 0..<8 where !restoredJob.exists || !restoredJob.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(restoredJob.waitForExistence(timeout: 3))
        XCTAssertTrue(restoredJob.isHittable)
        restoredJob.tap()
        XCTAssertTrue(app.navigationBars["Call Details"].waitForExistence(timeout: 3))

        let restoredWorkspacePicker = app.segmentedControls["ServiceCallWorkspacePicker"]
        XCTAssertTrue(restoredWorkspacePicker.waitForExistence(timeout: 3))
        restoredWorkspacePicker.buttons["Overview"].tap()

        let reviewDraft = app.buttons["Draft Review Request"]
        for _ in 0..<12 where !reviewDraft.exists || !reviewDraft.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(reviewDraft.waitForExistence(timeout: 3))
        XCTAssertTrue(reviewDraft.isHittable)
        XCTAssertTrue(app.staticTexts["Optional marketing follow-up. It opens as a draft and is recorded only after staff sends it."].exists)

        // The evidence intentionally stops before launching Mail or Gmail.
        // Screenshot fixtures also suppress the signed-in account identity.
        XCTAssertFalse(app.descendants(matching: .any)["SidebarAccountIdentity"].exists)
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] '@gunnaire.com'")
        ).firstMatch.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Consent-gated post-job review draft without account email"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testAdministratorRecordsAppendOnlyWorkAndReviewsTheCustomerSummary() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-appStoreScreenshotFixtures"
        ]
        app.launch()

        let schedule = revealSidebarDestination("Schedule & Jobs", in: app)
        schedule.tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        let job = app.buttons["OpenServiceCall-\(screenshotServiceCallID)"]
        for _ in 0..<8 where !job.exists || !job.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(job.waitForExistence(timeout: 3))
        XCTAssertTrue(job.isHittable)
        job.tap()

        XCTAssertTrue(app.navigationBars["Call Details"].waitForExistence(timeout: 3))
        let workspacePicker = app.segmentedControls["ServiceCallWorkspacePicker"]
        XCTAssertTrue(workspacePicker.waitForExistence(timeout: 3))
        workspacePicker.buttons["Work"].tap()

        let addWorkLog = app.buttons["AddWorkPerformedLog"]
        for _ in 0..<10 where !addWorkLog.exists || !addWorkLog.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(addWorkLog.waitForExistence(timeout: 3))
        XCTAssertTrue(addWorkLog.isHittable)

        let firstEntry = "Diagnosed a low-voltage short and isolated the failed contactor circuit."
        addWorkLog.tap()
        XCTAssertTrue(app.navigationBars["Add Work Log"].waitForExistence(timeout: 3))
        let firstEditor = app.textViews["WorkPerformedLogContent"]
        XCTAssertTrue(firstEditor.waitForExistence(timeout: 3))
        firstEditor.tap()
        firstEditor.typeText(firstEntry)
        let firstSave = app.buttons["SaveWorkPerformedLog"]
        XCTAssertTrue(firstSave.isEnabled)
        firstSave.tap()

        XCTAssertTrue(app.navigationBars["Call Details"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[firstEntry].waitForExistence(timeout: 3))

        let secondEntry = "Replaced the failed contactor, verified amp draw, and confirmed normal cooling operation."
        XCTAssertTrue(addWorkLog.isHittable)
        addWorkLog.tap()
        XCTAssertTrue(app.navigationBars["Add Work Log"].waitForExistence(timeout: 3))
        let secondEditor = app.textViews["WorkPerformedLogContent"]
        XCTAssertTrue(secondEditor.waitForExistence(timeout: 3))
        secondEditor.tap()
        secondEditor.typeText(secondEntry)
        let secondSave = app.buttons["SaveWorkPerformedLog"]
        XCTAssertTrue(secondSave.isEnabled)
        secondSave.tap()

        XCTAssertTrue(app.staticTexts[firstEntry].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts[secondEntry].waitForExistence(timeout: 3))

        let reviewSummary = app.buttons["ReviewCustomerWorkSummary"]
        XCTAssertTrue(reviewSummary.waitForExistence(timeout: 3))
        XCTAssertTrue(reviewSummary.isEnabled)
        reviewSummary.tap()

        XCTAssertTrue(app.navigationBars["Create Work Summary"].waitForExistence(timeout: 3))
        let summaryEditor = app.textViews["CustomerWorkSummaryContent"]
        XCTAssertTrue(summaryEditor.waitForExistence(timeout: 3))
        let suggestedSummary = summaryEditor.value as? String ?? ""
        XCTAssertTrue(suggestedSummary.contains(firstEntry))
        XCTAssertTrue(suggestedSummary.contains(secondEntry))
        XCTAssertTrue(app.buttons["UseWorkLogsForSummary"].isEnabled)
        app.buttons["UseWorkLogsForSummary"].tap()

        let saveSummary = app.buttons["SaveCustomerWorkSummary"]
        XCTAssertTrue(saveSummary.isEnabled)
        saveSummary.tap()

        XCTAssertTrue(app.navigationBars["Call Details"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["CurrentCustomerWorkSummary"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["1 retained summary revision"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["SidebarAccountIdentity"].exists)
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] '@gunnaire.com'")
        ).firstMatch.exists)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Append-only work log and reviewed customer summary without account email"
        attachment.lifetime = .keepAlways
        add(attachment)
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

        let schedule = revealSidebarDestination("Schedule & Jobs", in: app)
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

        let customers = revealSidebarDestination("Customers", in: app)
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
        let agreementGuidance = app.staticTexts["MaintenanceAgreementLifecycleGuidance"]
        for _ in 0..<6 {
            if agreementGuidance.exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(agreementGuidance.waitForExistence(timeout: 3))
        let agreementVisitHistory = app.staticTexts["Visit history: 0 completed • 1 scheduled"]
        for _ in 0..<6 {
            if agreementVisitHistory.exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(agreementVisitHistory.waitForExistence(timeout: 3))

        let createAgreement = app.buttons["CreateMaintenanceAgreementButton"]
        let customerForm = app.collectionViews.firstMatch
        let visibleCustomerFormBottom = customerForm.frame.maxY - 80
        for _ in 0..<6 {
            if createAgreement.exists,
               createAgreement.isHittable,
               createAgreement.frame.midY < visibleCustomerFormBottom {
                break
            }
            customerForm.swipeUp()
        }
        XCTAssertTrue(createAgreement.waitForExistence(timeout: 3))
        XCTAssertTrue(createAgreement.isHittable)
        XCTAssertLessThan(createAgreement.frame.midY, visibleCustomerFormBottom)
        createAgreement.tap()
        XCTAssertTrue(app.navigationBars["Create Service Agreement"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Save Draft"].exists)
        XCTAssertTrue(app.buttons["Review & Approve"].exists)
        app.navigationBars["Create Service Agreement"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Edit Customer"].waitForExistence(timeout: 3))

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
    func testAdministratorResolvesDoNotServiceFromCustomerRecordAndRestoresJobStart() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedOperationalAlert"
        ]
        app.launch()

        let schedule = revealSidebarDestination("Schedule & Jobs", in: app)
        schedule.tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        let alertBadge = app.descendants(matching: .any)["ScheduleOperationalAlert-\(screenshotServiceCallID)"]
        for _ in 0..<6 where !alertBadge.exists {
            app.swipeUp()
        }
        XCTAssertTrue(alertBadge.waitForExistence(timeout: 3))
        XCTAssertTrue(alertBadge.label.localizedCaseInsensitiveContains("Do Not Service"))

        let job = app.buttons["OpenServiceCall-\(screenshotServiceCallID)"]
        XCTAssertTrue(job.waitForExistence(timeout: 3))
        job.tap()
        XCTAssertTrue(app.navigationBars["Call Details"].waitForExistence(timeout: 3))
        let jobWorkspace = app.segmentedControls["ServiceCallWorkspacePicker"]
        XCTAssertTrue(jobWorkspace.waitForExistence(timeout: 3))
        jobWorkspace.buttons["Overview"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["ServiceCallOperationalAlerts"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Start Job"].isEnabled)

        app.navigationBars["Call Details"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))
        let sidebarButton = app.buttons["GunnAire Ops"]
        if sidebarButton.waitForExistence(timeout: 2) {
            sidebarButton.tap()
        }
        let customers = app.staticTexts["Customers"]
        XCTAssertTrue(customers.waitForExistence(timeout: 3))
        customers.tap()
        XCTAssertTrue(app.navigationBars["Customers"].waitForExistence(timeout: 3))

        let customerRecord = app.buttons["OpenCustomerRecord-\(screenshotCustomerID)"]
        for _ in 0..<5 where !customerRecord.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(customerRecord.waitForExistence(timeout: 3))
        customerRecord.tap()
        XCTAssertTrue(app.navigationBars["Edit Customer"].waitForExistence(timeout: 3))
        let alertSummary = app.staticTexts["CustomerOperationalAlertSummary"]
        for _ in 0..<6 where !alertSummary.exists {
            app.swipeUp()
        }
        XCTAssertTrue(alertSummary.waitForExistence(timeout: 3))
        let alertReason = app.staticTexts["Management review hold"]
        for _ in 0..<3 where !alertReason.exists {
            app.swipeUp()
        }
        XCTAssertTrue(alertReason.waitForExistence(timeout: 3))

        let manage = app.buttons["ManageCustomerOperationalAlerts"]
        for _ in 0..<4 where !manage.exists || !manage.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(manage.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(manage.isHittable)
        manage.tap()
        XCTAssertTrue(app.navigationBars["Operational Alerts"].waitForExistence(timeout: 3))
        let resolve = app.buttons["ResolveOperationalAlert-\(operationalAlertID)"]
        XCTAssertTrue(resolve.waitForExistence(timeout: 3))
        resolve.tap()
        XCTAssertTrue(app.navigationBars["Resolve Alert"].waitForExistence(timeout: 3))

        let resolution = app.textFields["OperationalAlertResolutionNote"]
        XCTAssertTrue(resolution.waitForExistence(timeout: 3))
        resolution.tap()
        resolution.typeText("Management reviewed the account and approved continued service.")
        let confirm = app.buttons["ConfirmResolveOperationalAlert"]
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()

        XCTAssertTrue(app.navigationBars["Operational Alerts"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["ResolveOperationalAlert-\(operationalAlertID)"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Edit Customer"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["No active customer or site alerts"].waitForExistence(timeout: 3))

        app.navigationBars["Edit Customer"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Customers"].waitForExistence(timeout: 3))
        let customersSidebarButton = app.buttons["GunnAire Ops"]
        if customersSidebarButton.waitForExistence(timeout: 2) {
            customersSidebarButton.tap()
        }
        let scheduleAgain = app.staticTexts["Schedule & Jobs"]
        XCTAssertTrue(scheduleAgain.waitForExistence(timeout: 3))
        scheduleAgain.tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        let restoredJob = app.buttons["OpenServiceCall-\(screenshotServiceCallID)"]
        for _ in 0..<6 where !restoredJob.exists {
            app.swipeUp()
        }
        XCTAssertTrue(restoredJob.waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["ScheduleOperationalAlert-\(screenshotServiceCallID)"].exists)
        restoredJob.tap()
        XCTAssertTrue(app.navigationBars["Call Details"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Start Job"].isEnabled)
    }

    @MainActor
    func testAdministratorCompletesAuditedCustomerJobTaskFromCommandCenter() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedBusinessTask",
            "-GunnAirePendingAppRoute", "commandCenter"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Command Center"].waitForExistence(timeout: 5))

        let taskQuickAction = app.buttons["Tasks"]
        XCTAssertTrue(taskQuickAction.waitForExistence(timeout: 3))
        taskQuickAction.tap()
        XCTAssertTrue(app.navigationBars["Team Tasks"].waitForExistence(timeout: 3))

        let taskRow = app.buttons["BusinessTask-\(businessTaskID)"]
        XCTAssertTrue(taskRow.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(taskRow.label.localizedCaseInsensitiveContains("overdue"))
        XCTAssertFalse(taskRow.label.localizedCaseInsensitiveContains("@gunnaire.com"))
        taskRow.tap()
        XCTAssertTrue(app.navigationBars["Task Details"].waitForExistence(timeout: 3))

        let completionNote = app.descendants(matching: .any)["BusinessTaskCompletionNote"]
        XCTAssertTrue(completionNote.waitForExistence(timeout: 3))
        completionNote.tap()
        completionNote.typeText("Property manager confirmed the roof key and access window.")
        let complete = app.buttons["CompleteBusinessTask"]
        XCTAssertTrue(complete.isEnabled)
        complete.tap()

        XCTAssertTrue(app.buttons["Reopen Task"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Property manager confirmed the roof key and access window."].exists)
        app.navigationBars["Task Details"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Team Tasks"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["No Open Tasks"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["BusinessTask-\(businessTaskID)"].exists)
    }

    @MainActor
    func testAdministratorApprovesTimeOffWithoutMovingAssignedJobsOrExposingPrivateReasonOnDashboard() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedTimeOffRequest"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Command Center"].waitForExistence(timeout: 5))
        let reviewPriority = app.buttons["ReviewTimeOffRequest"]
        XCTAssertTrue(reviewPriority.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(reviewPriority.label.localizedCaseInsensitiveContains("capacity review required"))
        XCTAssertFalse(reviewPriority.label.localizedCaseInsensitiveContains("private appointment"))
        XCTAssertFalse(reviewPriority.label.localizedCaseInsensitiveContains("@gunnaire.com"))
        reviewPriority.tap()

        XCTAssertTrue(app.navigationBars["Time-Off Review"].waitForExistence(timeout: 3))
        let request = app.buttons["TimeOffRequest-\(timeOffRequestID)"]
        XCTAssertTrue(request.waitForExistence(timeout: 3), app.debugDescription)
        request.tap()

        XCTAssertTrue(app.navigationBars["Time-Off Request"].waitForExistence(timeout: 3))
        let privateReason = app.descendants(matching: .any)["TimeOffPrivateReasonValue"]
        XCTAssertTrue(privateReason.exists)
        XCTAssertTrue(privateReason.label.localizedCaseInsensitiveContains("Private appointment"))
        let approve = app.buttons["ApproveTimeOffRequest"]
        XCTAssertTrue(approve.exists)
        XCTAssertTrue(approve.isEnabled)
        approve.tap()

        XCTAssertTrue(app.navigationBars["Time-Off Review"].waitForExistence(timeout: 3))
        let approvedHistory = app.buttons["TimeOffRequestHistory-\(timeOffRequestID)"]
        XCTAssertTrue(approvedHistory.waitForExistence(timeout: 3))
        XCTAssertTrue(approvedHistory.label.localizedCaseInsensitiveContains("Approved"))
        XCTAssertFalse(app.buttons["TimeOffRequest-\(timeOffRequestID)"].exists)
    }

    @MainActor
    func testAdministratorCreatesAndRetiresCompactRecurringTechnicianHours() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-appStoreScreenshotFixtures"
        ]
        app.launch()

        let schedule = revealSidebarDestination("Schedule & Jobs", in: app)
        schedule.tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        let availability = app.buttons["ManageTechnicianAvailability"]
        XCTAssertTrue(availability.waitForExistence(timeout: 3), app.debugDescription)
        availability.tap()
        XCTAssertTrue(app.navigationBars["Technician Availability"].waitForExistence(timeout: 3))
        let technicianPicker = app.descendants(matching: .any)["TechnicianAvailabilityPicker"]
        for _ in 0..<6 where !technicianPicker.exists {
            app.swipeUp()
        }
        XCTAssertTrue(technicianPicker.waitForExistence(timeout: 3))
        let noRecurringHours = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'No recurring hours are configured'")
        ).firstMatch
        for _ in 0..<4 where !noRecurringHours.exists {
            app.swipeUp()
        }
        XCTAssertTrue(noRecurringHours.waitForExistence(timeout: 3), app.debugDescription)

        let addShift = app.buttons["AddRecurringTechnicianShift"]
        XCTAssertTrue(addShift.waitForExistence(timeout: 3))
        addShift.tap()
        XCTAssertTrue(app.navigationBars["Recurring Work Shift"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Regular"].exists)
        XCTAssertTrue(app.switches["RecurringShiftDay-2"].isEnabled)
        if !app.switches["RecurringShiftDay-6"].exists {
            app.swipeUp()
        }
        XCTAssertTrue(app.switches["RecurringShiftDay-6"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.switches["RecurringShiftDay-6"].isEnabled)

        let save = app.buttons["SaveRecurringTechnicianShift"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.navigationBars["Technician Availability"].waitForExistence(timeout: 4))

        let shiftRows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'TechnicianWorkShift-'")
        )
        XCTAssertTrue(shiftRows.firstMatch.waitForExistence(timeout: 3), app.debugDescription)
        let activeShiftCount = app.staticTexts["ActiveTechnicianWorkShiftCount"]
        XCTAssertTrue(activeShiftCount.waitForExistence(timeout: 2))
        XCTAssertEqual(activeShiftCount.label, "5 active")
        XCTAssertTrue(shiftRows.firstMatch.label.localizedCaseInsensitiveContains("regular"))
        XCTAssertFalse(shiftRows.firstMatch.label.localizedCaseInsensitiveContains("@gunnaire.com"))

        let created = XCTAttachment(screenshot: app.screenshot())
        created.name = "Compact recurring technician hours without account email"
        created.lifetime = .keepAlways
        add(created)

        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))
        let weekBoard = app.buttons["Week Board"]
        XCTAssertTrue(weekBoard.waitForExistence(timeout: 3))
        weekBoard.tap()
        XCTAssertTrue(app.navigationBars["Dispatch Week"].waitForExistence(timeout: 3))
        let nextWeek = app.buttons["Next week"]
        XCTAssertTrue(nextWeek.exists)
        nextWeek.tap()
        let nextMonday = Calendar.current.date(
            byAdding: .day,
            value: 7,
            to: startOfDispatchWeek(containing: Date())
        ) ?? Date()
        let mondayCapacity = app.descendants(matching: .any)[dispatchCapacityIdentifier(for: nextMonday)]
        XCTAssertTrue(mondayCapacity.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(mondayCapacity.label.localizedCaseInsensitiveContains("9 hours open"))
        XCTAssertTrue(mondayCapacity.label.localizedCaseInsensitiveContains("9 hours staffed"))
        XCTAssertTrue(mondayCapacity.label.localizedCaseInsensitiveContains("0 minutes booked"))
        XCTAssertFalse(mondayCapacity.label.localizedCaseInsensitiveContains("@gunnaire.com"))

        mondayCapacity.tap()
        XCTAssertTrue(app.navigationBars["Team Capacity"].waitForExistence(timeout: 3), app.debugDescription)
        let technicianCapacity = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH 'DispatchTechnicianCapacity-' AND label CONTAINS[c] '9 hours staffed'"
            )
        ).firstMatch
        XCTAssertTrue(technicianCapacity.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(technicianCapacity.label.localizedCaseInsensitiveContains("9 hours staffed"), technicianCapacity.label)
        XCTAssertTrue(technicianCapacity.label.localizedCaseInsensitiveContains("0 minutes booked"), technicianCapacity.label)
        XCTAssertTrue(technicianCapacity.label.localizedCaseInsensitiveContains("9 hours open"), technicianCapacity.label)
        XCTAssertFalse(technicianCapacity.label.localizedCaseInsensitiveContains("@gunnaire.com"))

        technicianCapacity.tap()
        XCTAssertTrue(app.navigationBars["Technician Day"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.staticTexts["No assigned appointments"].waitForExistence(timeout: 2), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Regular hours"].waitForExistence(timeout: 2), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["DispatchTechnicianDaySchedule"].label.localizedCaseInsensitiveContains("@gunnaire.com"))

        let scheduleEvidence = XCTAttachment(screenshot: app.screenshot())
        scheduleEvidence.name = "Configured technician day hours without dashboard overload"
        scheduleEvidence.lifetime = .keepAlways
        add(scheduleEvidence)

        let teamCapacityBack = app.navigationBars["Technician Day"].buttons["Team Capacity"]
        XCTAssertTrue(teamCapacityBack.waitForExistence(timeout: 2), app.debugDescription)
        teamCapacityBack.tap()
        XCTAssertTrue(app.navigationBars["Team Capacity"].waitForExistence(timeout: 3))

        let detailEvidence = XCTAttachment(screenshot: app.screenshot())
        detailEvidence.name = "Progressive technician capacity detail without account email"
        detailEvidence.lifetime = .keepAlways
        add(detailEvidence)

        app.buttons["DispatchCapacityDetailDone"].tap()
        XCTAssertTrue(app.navigationBars["Dispatch Week"].waitForExistence(timeout: 3))

        let capacityEvidence = XCTAttachment(screenshot: app.screenshot())
        capacityEvidence.name = "Weekly dispatch capacity from recurring technician hours"
        capacityEvidence.lifetime = .keepAlways
        add(capacityEvidence)

        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))
        XCTAssertTrue(availability.waitForExistence(timeout: 3))
        availability.tap()
        XCTAssertTrue(app.navigationBars["Technician Availability"].waitForExistence(timeout: 3))
        XCTAssertEqual(activeShiftCount.label, "5 active")

        shiftRows.firstMatch.swipeLeft()
        let retire = app.buttons["Retire"]
        XCTAssertTrue(retire.waitForExistence(timeout: 3))
        retire.tap()
        XCTAssertTrue(app.navigationBars["Retire Work Shift"].waitForExistence(timeout: 3))
        let reason = app.descendants(matching: .any)["RecurringShiftRetirementReason"]
        XCTAssertTrue(reason.exists)
        reason.tap()
        reason.typeText("Changed summer coverage hours")
        let confirm = app.buttons["ConfirmRecurringShiftRetirement"]
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()

        XCTAssertTrue(app.navigationBars["Technician Availability"].waitForExistence(timeout: 4))
        XCTAssertEqual(activeShiftCount.label, "4 active")
        let retiredHistory = app.buttons["Retired History"]
        for _ in 0..<3 where !retiredHistory.exists {
            app.swipeUp()
        }
        XCTAssertTrue(retiredHistory.waitForExistence(timeout: 3))
        retiredHistory.tap()
        let retirementReason = app.staticTexts["Retired: Changed summer coverage hours"]
        if !retirementReason.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(retirementReason.waitForExistence(timeout: 3))
    }

    @MainActor
    func testEquipmentProfileActionsStayCompactAndRequireDeleteConfirmation() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-appStoreScreenshotFixtures",
            "-GunnAirePendingAppRoute", "customers",
            "-GunnAirePendingCustomerID", screenshotCustomerID
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Edit Customer"].waitForExistence(timeout: 5))
        let workspace = app.segmentedControls["CustomerProfileWorkspacePicker"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 3))
        workspace.buttons["Systems"].tap()
        XCTAssertTrue(app.staticTexts["Equipment Profiles"].waitForExistence(timeout: 3))

        let deleteEquipment = app.buttons["DeleteEquipment-\(screenshotEquipmentID)"]
        let compactActions = app.descendants(matching: .any)["EquipmentActionsMenu-\(screenshotEquipmentID)"]
        let customerForm = app.collectionViews.firstMatch
        for _ in 0..<10 {
            if deleteEquipment.isHittable || compactActions.isHittable { break }
            customerForm.swipeUp()
        }

        if compactActions.exists {
            XCTAssertTrue(compactActions.waitForExistence(timeout: 3))
            XCTAssertTrue(compactActions.isHittable)
            compactActions.tap()
            XCTAssertTrue(deleteEquipment.waitForExistence(timeout: 3))
        } else {
            XCTAssertTrue(deleteEquipment.waitForExistence(timeout: 3))
        }

        XCTAssertTrue(deleteEquipment.isHittable)
        deleteEquipment.tap()
        XCTAssertTrue(app.staticTexts["Delete Main Office Heat Pump?"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["ConfirmDeleteEquipment"].exists)
        let deleteMessage = "This removes the installed-system profile from this customer. Linked job history and files remain preserved under the customer, but the equipment profile cannot be restored."
        let deleteMessageText = app.staticTexts.matching(NSPredicate(format: "label == %@", deleteMessage)).firstMatch
        XCTAssertTrue(deleteMessageText.exists)

        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Main Office Heat Pump"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testEquipmentEditorUsesProgressiveDisclosureInTheCustomerRecord() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-appStoreScreenshotFixtures",
            "-GunnAirePendingAppRoute", "customers",
            "-GunnAirePendingCustomerID", screenshotCustomerID
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Edit Customer"].waitForExistence(timeout: 5))
        let workspace = app.segmentedControls["CustomerProfileWorkspacePicker"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 3))
        workspace.buttons["Systems"].tap()
        XCTAssertTrue(app.staticTexts["Equipment Profiles"].waitForExistence(timeout: 3))
        let editor = app.staticTexts["EquipmentProfileEditor"]
        XCTAssertFalse(editor.exists)

        let customerForm = app.collectionViews.firstMatch
        let lifecycle = app.staticTexts["EquipmentLifecycle-\(screenshotEquipmentID)"]
        for _ in 0..<10 {
            if lifecycle.exists { break }
            customerForm.swipeUp()
        }
        XCTAssertTrue(lifecycle.waitForExistence(timeout: 3))
        XCTAssertTrue(lifecycle.label.contains("Installed"))
        XCTAssertTrue(lifecycle.label.contains("Warranty active through"))

        let addEquipment = app.buttons["StartAddEquipmentProfile"]
        for _ in 0..<10 {
            if addEquipment.exists && addEquipment.isHittable { break }
            customerForm.swipeUp()
        }
        XCTAssertTrue(addEquipment.waitForExistence(timeout: 3))
        XCTAssertTrue(addEquipment.isHittable)
        addEquipment.tap()

        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertEqual(editor.label, "New Equipment")

        let nameplateButton = app.buttons["ReadCustomerEquipmentNameplate"]
        for _ in 0..<6 {
            if nameplateButton.exists && nameplateButton.isHittable { break }
            customerForm.swipeUp()
        }
        XCTAssertTrue(nameplateButton.waitForExistence(timeout: 3))
        XCTAssertTrue(nameplateButton.isHittable)
        nameplateButton.tap()

        XCTAssertTrue(app.navigationBars["Read Equipment Data Plate"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Recognition runs on this device. Review every suggested value before applying it to the open equipment editor."].exists)
        let manualPlateText = app.textViews["EquipmentNameplateManualText"]
        XCTAssertTrue(manualPlateText.waitForExistence(timeout: 3))
        manualPlateText.tap()
        manualPlateText.typeText("LENNOX MODEL: ML14XC1-036-230 SERIAL: 1926A12345")
        app.buttons["ReadEquipmentNameplateText"].tap()

        let manufacturerSuggestion = app.textFields["EquipmentNameplateManufacturer"]
        XCTAssertTrue(manufacturerSuggestion.waitForExistence(timeout: 3))
        XCTAssertEqual(manufacturerSuggestion.value as? String, "Lennox")
        let nameplateForm = app.collectionViews.firstMatch
        let modelSuggestion = app.textFields["EquipmentNameplateModel"]
        for _ in 0..<4 {
            if modelSuggestion.exists { break }
            nameplateForm.swipeUp()
        }
        XCTAssertTrue(modelSuggestion.waitForExistence(timeout: 3))
        XCTAssertEqual(modelSuggestion.value as? String, "ML14XC1-036-230")
        let serialSuggestion = app.textFields["EquipmentNameplateSerial"]
        for _ in 0..<4 {
            if serialSuggestion.exists { break }
            nameplateForm.swipeUp()
        }
        XCTAssertTrue(serialSuggestion.waitForExistence(timeout: 3))
        XCTAssertEqual(serialSuggestion.value as? String, "1926A12345")
        let applyNameplate = app.buttons["ApplyEquipmentNameplate"]
        for _ in 0..<4 {
            if applyNameplate.exists && applyNameplate.isHittable { break }
            nameplateForm.swipeUp()
        }
        XCTAssertTrue(applyNameplate.waitForExistence(timeout: 3))
        XCTAssertTrue(applyNameplate.isHittable)
        applyNameplate.tap()
        XCTAssertFalse(app.navigationBars["Read Equipment Data Plate"].waitForExistence(timeout: 1))

        let cancel = app.buttons["CancelEquipmentProfileEdit"]
        for _ in 0..<5 {
            if cancel.exists && cancel.isHittable { break }
            customerForm.swipeUp()
        }
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        cancel.tap()
        XCTAssertFalse(editor.waitForExistence(timeout: 1))

        let editEquipment = app.buttons["EditEquipment-\(screenshotEquipmentID)"]
        for _ in 0..<10 {
            if editEquipment.exists && editEquipment.isHittable { break }
            customerForm.swipeDown()
        }
        XCTAssertTrue(editEquipment.waitForExistence(timeout: 3))
        XCTAssertTrue(editEquipment.isHittable)
        editEquipment.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertEqual(editor.label, "Edit Equipment")
    }

    @MainActor
    func testEquipmentPlanningCueConsolidatesRepairHistoryWithoutOverloadingSystems() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedEquipmentDecision",
            "-GunnAirePendingAppRoute", "customers",
            "-GunnAirePendingCustomerID", screenshotCustomerID
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Edit Customer"].waitForExistence(timeout: 5))
        let workspace = app.segmentedControls["CustomerProfileWorkspacePicker"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 3))
        workspace.buttons["Systems"].tap()
        XCTAssertTrue(app.staticTexts["Equipment Profiles"].waitForExistence(timeout: 3))

        let customerForm = app.collectionViews.firstMatch
        let planningCue = app.descendants(matching: .any)["EquipmentServicePlanning-\(screenshotEquipmentID)"]
        for _ in 0..<10 {
            if planningCue.exists && planningCue.isHittable { break }
            customerForm.swipeUp()
        }
        XCTAssertTrue(planningCue.waitForExistence(timeout: 3))
        XCTAssertTrue(
            planningCue.label.contains("Repair vs. replacement review"),
            "Unexpected equipment planning title in accessibility label: \(planningCue.label)"
        )
        XCTAssertTrue(
            planningCue.label.contains("2 service visits in the past 12 months"),
            "Unexpected equipment planning summary in accessibility label: \(planningCue.label)"
        )
        XCTAssertTrue(
            planningCue.label.contains("Planning cue only"),
            "Missing advisory language in equipment planning accessibility label: \(planningCue.label)"
        )

        let evidence = app.descendants(matching: .any)["EquipmentServiceEvidence-\(screenshotEquipmentID)"]
        let evidenceDetails = app.staticTexts["EquipmentServiceEvidenceDetails-\(screenshotEquipmentID)"]
        XCTAssertTrue(evidence.waitForExistence(timeout: 3))
        XCTAssertFalse(evidenceDetails.exists)
        evidence.tap()
        XCTAssertTrue(evidenceDetails.waitForExistence(timeout: 3))
    }

    @MainActor
    func testAdministratorSubmitsAnEquipmentWarrantyClaimWithLinkedEvidence() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedWarrantyClaim",
            "-GunnAirePendingAppRoute", "customers",
            "-GunnAirePendingCustomerID", screenshotCustomerID
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Edit Customer"].waitForExistence(timeout: 5))
        let workspace = app.segmentedControls["CustomerProfileWorkspacePicker"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 3))
        workspace.buttons["Systems"].tap()
        XCTAssertTrue(app.staticTexts["Equipment Profiles"].waitForExistence(timeout: 3))

        let openClaims = app.buttons["OpenEquipmentWarrantyClaims-\(screenshotEquipmentID)"]
        let customerForm = app.collectionViews.firstMatch
        for _ in 0..<10 {
            if openClaims.exists && openClaims.isHittable { break }
            customerForm.swipeUp()
        }
        XCTAssertTrue(openClaims.waitForExistence(timeout: 3))
        XCTAssertTrue(openClaims.label.contains("1 open warranty claim"))
        openClaims.tap()

        XCTAssertTrue(app.navigationBars["Warranty Claims"].waitForExistence(timeout: 3))
        let claim = app.buttons["WarrantyClaim-\(warrantyClaimID)"]
        XCTAssertTrue(claim.waitForExistence(timeout: 3))
        XCTAssertTrue(claim.label.contains("Requested"))
        claim.tap()

        let submit = app.buttons["SubmitWarrantyClaim-\(warrantyClaimID)"]
        let claimList = app.collectionViews.firstMatch
        for _ in 0..<5 {
            if submit.exists && submit.isHittable { break }
            claimList.swipeUp()
        }
        XCTAssertTrue(submit.waitForExistence(timeout: 3))
        submit.tap()

        XCTAssertTrue(app.navigationBars["Submit Warranty Claim"].waitForExistence(timeout: 3))
        let claimNumber = app.textFields["WarrantyClaimNumber"]
        XCTAssertTrue(claimNumber.waitForExistence(timeout: 3))
        claimNumber.tap()
        claimNumber.typeText("UI-WARRANTY-100")
        XCTAssertTrue(app.staticTexts["UI Warranty Failure Evidence.jpg"].exists)

        let confirm = app.buttons["ConfirmWarrantySubmission"]
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()
        XCTAssertTrue(app.navigationBars["Warranty Claims"].waitForExistence(timeout: 3))
        XCTAssertTrue(claim.waitForExistence(timeout: 3))
        XCTAssertTrue(claim.label.contains("UI-WARRANTY-100"))
        XCTAssertTrue(claim.label.contains("Submitted"))
    }

    @MainActor
    func testPurchasingShowsTheCompactWarrantyRecoveryQueue() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedWarrantyClaim"
        ]
        app.launch()

        let receiptsBills = app.staticTexts["Receipts & Bills"]
        if !receiptsBills.waitForExistence(timeout: 3) {
            let sidebarButton = app.buttons["GunnAire Ops"]
            XCTAssertTrue(sidebarButton.waitForExistence(timeout: 3))
            sidebarButton.tap()
        }
        XCTAssertTrue(receiptsBills.waitForExistence(timeout: 3))
        receiptsBills.tap()
        XCTAssertTrue(app.navigationBars["Receipts & Bills"].waitForExistence(timeout: 3))
        let workspace = app.segmentedControls["ReceiptsBillsWorkspacePicker"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 3))
        workspace.buttons["Purchasing"].tap()

        XCTAssertTrue(app.staticTexts["Warranty Claims"].waitForExistence(timeout: 3))
        let queueClaim = app.buttons["OpenWarrantyQueueClaim-\(warrantyClaimID)"]
        XCTAssertTrue(queueClaim.waitForExistence(timeout: 3))
        XCTAssertTrue(queueClaim.label.contains("Office submission needed"))
        queueClaim.tap()
        XCTAssertTrue(app.navigationBars["Warranty Claims"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["WarrantyClaim-\(warrantyClaimID)"].exists)
    }

    @MainActor
    func testAccountingCanReachWarrantyCreditRecoveryWithoutPurchasingAuthority() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAccounting",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedWarrantyClaim"
        ]
        app.launch()

        let receiptsBills = app.staticTexts["Receipts & Bills"]
        if !receiptsBills.waitForExistence(timeout: 3) {
            let sidebarButton = app.buttons["GunnAire Ops"]
            XCTAssertTrue(sidebarButton.waitForExistence(timeout: 3))
            sidebarButton.tap()
        }
        XCTAssertTrue(receiptsBills.waitForExistence(timeout: 3))
        receiptsBills.tap()
        XCTAssertTrue(app.navigationBars["Receipts & Bills"].waitForExistence(timeout: 3))

        let workspace = app.segmentedControls["ReceiptsBillsWorkspacePicker"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 3))
        XCTAssertEqual(workspace.buttons.count, 2)
        XCTAssertTrue(workspace.buttons["Documents"].exists)
        XCTAssertTrue(workspace.buttons["Purchasing"].exists)
        XCTAssertFalse(workspace.buttons["Inventory"].exists)
        XCTAssertFalse(workspace.buttons["Recovery"].exists)

        workspace.buttons["Purchasing"].tap()
        XCTAssertTrue(app.staticTexts["Warranty Claims"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Purchase Orders"].exists)
        let queueClaim = app.buttons["OpenWarrantyQueueClaim-\(warrantyClaimID)"]
        XCTAssertTrue(queueClaim.waitForExistence(timeout: 3))
        queueClaim.tap()
        XCTAssertTrue(app.navigationBars["Warranty Claims"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["WarrantyClaim-\(warrantyClaimID)"].exists)
        XCTAssertFalse(app.buttons["SubmitWarrantyClaim-\(warrantyClaimID)"].exists)
    }

    @MainActor
    func testAccountingReviewsAndCreatesOneDueMaintenanceAgreementInvoice() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAccounting",
            "-uiTestSeedAgreementBilling",
            "-uiTestForceQuickBooksDisconnected",
            "-GunnAirePendingAppRoute", "invoices"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Invoices"].waitForExistence(timeout: 8))
        let dueHeader = app.staticTexts["Service Agreements Due for Billing"]
        XCTAssertTrue(dueHeader.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["UI Test Collectible Customer"].exists)
        XCTAssertTrue(app.staticTexts["Comfort Care • Monthly"].exists)

        let review = app.buttons["Review & Create Invoice"]
        XCTAssertTrue(review.waitForExistence(timeout: 3))
        review.tap()

        XCTAssertTrue(app.navigationBars["Review Agreement Invoice"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Approved amount"].exists)
        XCTAssertTrue(app.staticTexts["$49.00"].exists)
        let mappedItem = app.staticTexts["HVAC Diagnostic Service"]
        let compactMappedItem = app.staticTexts["Catalog item, HVAC Diagnostic Service"]
        for _ in 0..<3 where !(mappedItem.exists || compactMappedItem.exists) {
            app.swipeUp()
        }
        XCTAssertTrue(mappedItem.exists || compactMappedItem.waitForExistence(timeout: 3))
        let noAutomaticChargeNotice = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'does not charge a saved card'")
        ).firstMatch
        for _ in 0..<3 where !noAutomaticChargeNotice.exists {
            app.swipeUp()
        }
        XCTAssertTrue(noAutomaticChargeNotice.waitForExistence(timeout: 3))
        let quickBooksQueueNotice = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'queued for QuickBooks publication'")
        ).firstMatch
        XCTAssertTrue(quickBooksQueueNotice.waitForExistence(timeout: 3))

        let create = app.buttons["CreateAgreementInvoice"]
        XCTAssertTrue(create.exists)
        XCTAssertTrue(create.isEnabled)
        create.tap()

        XCTAssertTrue(app.navigationBars["Invoices"].waitForExistence(timeout: 5))
        let queueCleared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: dueHeader
        )
        XCTAssertEqual(XCTWaiter.wait(for: [queueCleared], timeout: 5), .completed)
        XCTAssertTrue(app.staticTexts["Balance due: $49.00"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testCustomerHistoryShowsTypedCommunicationEvidence() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCustomerCommunication"
        ]
        app.launch()

        let customers = revealSidebarDestination("Customers", in: app)
        customers.tap()
        XCTAssertTrue(app.navigationBars["Customers"].waitForExistence(timeout: 3))

        let customerRecord = app.buttons["OpenCustomerRecord-A1000000-0000-4000-8000-000000000001"]
        for _ in 0..<5 {
            if customerRecord.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(customerRecord.waitForExistence(timeout: 3))
        customerRecord.tap()
        XCTAssertTrue(app.navigationBars["Edit Customer"].waitForExistence(timeout: 3))

        let workspacePicker = app.segmentedControls["CustomerProfileWorkspacePicker"]
        XCTAssertTrue(workspacePicker.waitForExistence(timeout: 3))
        workspacePicker.buttons["History"].tap()

        XCTAssertTrue(app.staticTexts["Sent Documents & Emails"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Appointment confirmation"].exists)
        XCTAssertTrue(app.staticTexts["Your GunnAire appointment is confirmed"].exists)
        XCTAssertTrue(app.staticTexts["By eric.gunn@gunnaire.com • appointmentConfirmation-v1"].exists)
        XCTAssertTrue(app.buttons["Job"].exists)
        XCTAssertFalse(app.staticTexts["Company history sync will retry"].exists)
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

        let schedule = revealSidebarDestination("Schedule & Jobs", in: app)
        schedule.tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        let workQueue = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Work Queue'")
        ).firstMatch
        for _ in 0..<4 where !workQueue.exists || !workQueue.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(workQueue.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["MaintenanceVisitAction-A1000000-0000-4000-8000-000000000011"].exists)
        workQueue.tap()

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

        let schedule = revealSidebarDestination("Schedule & Jobs", in: app)
        schedule.tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 3))

        let workQueue = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Work Queue'")
        ).firstMatch
        if workQueue.waitForExistence(timeout: 3) {
            workQueue.tap()
        }
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

        let customers = revealSidebarDestination("Customers", in: app)
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
    func testPricebookReviewCorrectsFieldItemBeforeApprovalWithoutLosingDocumentPriority() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedPricebookReview",
            "-GunnAirePendingAppRoute", "quickBooksManagement"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["QuickBooks Management"].waitForExistence(timeout: 8))

        let workspacePicker = app.segmentedControls["QuickBooksWorkspacePicker"]
        XCTAssertTrue(workspacePicker.waitForExistence(timeout: 3))
        workspacePicker.buttons["Sales"].tap()

        let reviewItem = app.buttons["ReviewPricebookItem-\(catalogItemID)"]
        for _ in 0..<8 where !reviewItem.exists {
            app.swipeUp()
        }
        XCTAssertTrue(reviewItem.waitForExistence(timeout: 3))

        let impact = app.staticTexts["PricebookReviewImpact-\(catalogItemID)"]
        XCTAssertTrue(impact.exists)
        XCTAssertEqual(impact.label, "Required by 1 estimate and 1 invoice waiting for QuickBooks.")

        reviewItem.tap()
        XCTAssertTrue(app.navigationBars["Review Pricebook Item"].waitForExistence(timeout: 3))
        let itemType = app.segmentedControls["PricebookReviewItemType"]
        XCTAssertTrue(itemType.exists)
        itemType.buttons["NonInventory"].tap()
        app.buttons["SavePricebookReviewChanges"].tap()

        XCTAssertTrue(app.navigationBars["QuickBooks Management"].waitForExistence(timeout: 3))
        let approveItem = app.buttons["ApprovePricebookItem-\(catalogItemID)"]
        for _ in 0..<6 where !approveItem.exists {
            app.swipeUp()
        }
        XCTAssertTrue(approveItem.waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] 'NonInventory'")
            ).firstMatch.exists
        )
        XCTAssertTrue(reviewItem.exists)

        approveItem.tap()
        XCTAssertTrue(app.staticTexts["No field-created catalog items need review."].waitForExistence(timeout: 3))
    }

    @MainActor
    func testLinkedPricebookApprovalStagesComparisonWithoutChoosingQuickBooksValues() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedLinkedPricebookReview",
            "-uiTestForceQuickBooksConnected",
            "-GunnAirePendingAppRoute", "quickBooksManagement"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["QuickBooks Management"].waitForExistence(timeout: 8))
        let workspacePicker = app.segmentedControls["QuickBooksWorkspacePicker"]
        XCTAssertTrue(workspacePicker.waitForExistence(timeout: 3))
        workspacePicker.buttons["Sales"].tap()

        let approveItem = app.buttons["ApprovePricebookItem-\(catalogItemID)"]
        for _ in 0..<8 where !approveItem.exists {
            app.swipeUp()
        }
        XCTAssertTrue(approveItem.waitForExistence(timeout: 3))
        XCTAssertEqual(approveItem.label, "Approve & Compare")
        XCTAssertTrue(app.staticTexts["$189.00"].exists)
        approveItem.tap()

        let approvalMessage = app.staticTexts["QuickBooksActionMessage"]
        XCTAssertTrue(approvalMessage.waitForExistence(timeout: 3))
        XCTAssertTrue(approvalMessage.label.contains("Approved and linked HVAC Diagnostic Service"))
        XCTAssertFalse(approveItem.exists)
        XCTAssertTrue(app.staticTexts["QuickBooksCatalogReconciliationQueue"].waitForExistence(timeout: 3))
        let comparison = app.staticTexts["QBO QBO-UI-PRICEBOOK-REVIEW • 1 changed field"]
        for _ in 0..<4 where !comparison.exists {
            app.swipeUp()
        }
        XCTAssertTrue(comparison.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Sales price"].exists)
        XCTAssertTrue(app.staticTexts["$189.00"].exists)
        XCTAssertTrue(app.staticTexts["$239.00"].exists)
        XCTAssertTrue(app.buttons["Use QuickBooks Version"].exists)
        XCTAssertTrue(app.buttons["Publish GunnAire Version"].exists)
    }

    @MainActor
    func testAdministratorEditsCompanyPricebookOfflineAndStagesQuickBooksComparison() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedOfflineCompanyPricebook",
            "-uiTestForceQuickBooksDisconnected",
            "-GunnAirePendingAppRoute", "quickBooksManagement"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["QuickBooks Management"].waitForExistence(timeout: 8))
        let workspacePicker = app.segmentedControls["QuickBooksWorkspacePicker"]
        XCTAssertTrue(workspacePicker.waitForExistence(timeout: 3))
        workspacePicker.buttons["Sales"].tap()

        let companyPricebook = app.buttons["CompanyPricebookDisclosure"]
        for _ in 0..<14 where !(companyPricebook.exists && companyPricebook.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(waitForHittable(companyPricebook))
        companyPricebook.tap()

        let syncStatus = app.staticTexts["Synced with QuickBooks"]
        for _ in 0..<4 where !(syncStatus.exists && syncStatus.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(waitForHittable(syncStatus))
        XCTAssertTrue(app.staticTexts["$189.00"].exists)

        let edit = app.buttons["Edit HVAC Diagnostic Service"]
        XCTAssertTrue(waitForHittable(edit))
        edit.tap()

        XCTAssertTrue(app.navigationBars["Edit Catalog Item"].waitForExistence(timeout: 3))
        let salesPrice = app.textFields["CatalogEditSalesPrice"]
        XCTAssertTrue(salesPrice.waitForExistence(timeout: 3))
        replaceText(in: salesPrice, with: "215")
        let doneEditing = app.buttons["DoneEditingCatalogItem"]
        XCTAssertTrue(doneEditing.waitForExistence(timeout: 3))
        doneEditing.tap()
        let editorNavigation = app.navigationBars["Edit Catalog Item"]
        let stage = editorNavigation.buttons["Stage Changes"]
        XCTAssertTrue(waitForHittable(stage))
        XCTAssertTrue(stage.isEnabled)
        stage.tap()

        let editorDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.navigationBars["Edit Catalog Item"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [editorDismissed], timeout: 3), .completed)
        let comparisonPending = app.staticTexts["QuickBooks comparison pending"]
        for _ in 0..<10 where !comparisonPending.exists || !comparisonPending.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(comparisonPending.waitForExistence(timeout: 3))
        XCTAssertTrue(comparisonPending.isHittable)
        XCTAssertTrue(app.staticTexts["$215.00"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Publish GunnAire Version"].exists)
    }

    @MainActor
    func testAdministratorCreatesTaxableCatalogItemOfflineBeforeQuickBooksPublication() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-GunnAirePendingAppRoute", "quickBooksManagement"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["QuickBooks Management"].waitForExistence(timeout: 8))
        let workspacePicker = app.segmentedControls["QuickBooksWorkspacePicker"]
        XCTAssertTrue(workspacePicker.waitForExistence(timeout: 3))
        workspacePicker.buttons["Sales"].tap()

        let addCatalogItem = app.buttons["Add Catalog Item"]
        for _ in 0..<14 where !addCatalogItem.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(waitForHittable(addCatalogItem))
        addCatalogItem.tap()

        XCTAssertTrue(app.navigationBars["Add Catalog Item"].waitForExistence(timeout: 3))
        let name = app.textFields["QuickBooksCatalogItemName"]
        let sku = app.textFields["QuickBooksCatalogItemSKU"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        replaceText(in: name, with: "Offline Taxable Capacitor")
        replaceText(in: sku, with: "OFF-CAP-45")
        let returnKey = app.keyboards.buttons["Return"]
        if returnKey.exists {
            returnKey.tap()
        }
        let taxable = app.switches["QuickBooksCatalogItemTaxable"]
        XCTAssertTrue(taxable.exists)
        if (taxable.value as? String) != "1" {
            taxable.tap()
        }

        let create = app.buttons["CreateQuickBooksCatalogItem"]
        XCTAssertTrue(create.exists)
        XCTAssertTrue(create.isEnabled)
        XCTAssertTrue(waitForHittable(create))
        create.tap()

        let composerDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.navigationBars["Add Catalog Item"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [composerDismissed], timeout: 3), .completed)
        XCTAssertTrue(app.navigationBars["QuickBooks Management"].exists)
        let result = app.staticTexts["QuickBooksActionMessage"]
        for _ in 0..<14 where !result.isHittable {
            app.swipeDown()
        }
        XCTAssertTrue(waitForHittable(result))
        XCTAssertEqual(
            result.label,
            "Saved Offline Taxable Capacitor locally. Connect QuickBooks to publish it."
        )

        let queuedItem = app.staticTexts["Offline Taxable Capacitor"]
        for _ in 0..<14 where !queuedItem.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(waitForHittable(queuedItem))
        XCTAssertTrue(app.staticTexts["SKU OFF-CAP-45 • Service"].exists)
        XCTAssertTrue(app.staticTexts["Publication pending"].exists)
        let retry = app.buttons["Retry Catalog Publication"]
        XCTAssertTrue(retry.exists)
        XCTAssertFalse(retry.isEnabled)
    }

    @MainActor
    func testAdministratorCreatesCustomerOfflineAndHandsItToCustomerSync() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-GunnAirePendingAppRoute", "quickBooksManagement"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["QuickBooks Management"].waitForExistence(timeout: 8))
        let workspacePicker = app.segmentedControls["QuickBooksWorkspacePicker"]
        XCTAssertTrue(workspacePicker.waitForExistence(timeout: 3))
        workspacePicker.buttons["Sales"].tap()

        let addCustomer = app.buttons["Add Customer"]
        for _ in 0..<14 where !addCustomer.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(waitForHittable(addCustomer))
        XCTAssertTrue(addCustomer.isEnabled)
        addCustomer.tap()

        XCTAssertTrue(app.navigationBars["Add Customer"].waitForExistence(timeout: 3))
        let name = app.textFields["QuickBooksCustomerName"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        replaceText(in: name, with: "Offline QBO Customer")
        let create = app.buttons["CreateQuickBooksCustomer"]
        XCTAssertTrue(create.exists)
        XCTAssertTrue(create.isEnabled)
        create.tap()

        let composerDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.navigationBars["Add Customer"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [composerDismissed], timeout: 3), .completed)
        let result = app.staticTexts["QuickBooksActionMessage"]
        XCTAssertTrue(waitForHittable(result))
        XCTAssertEqual(
            result.label,
            "Saved Offline QBO Customer locally. Connect QuickBooks or use Customers → Sync to publish it."
        )

        let sidebar = revealSidebar(in: app)
        let customers = sidebar.staticTexts["Customers"]
        for _ in 0..<18 where !customers.isHittable {
            sidebar.swipeDown()
        }
        XCTAssertTrue(waitForHittable(customers))
        customers.tap()

        XCTAssertTrue(app.navigationBars["Customers"].waitForExistence(timeout: 3))
        let createdCustomer = app.staticTexts["Offline QBO Customer"]
        for _ in 0..<10 where !createdCustomer.exists {
            app.swipeUp()
        }
        XCTAssertTrue(createdCustomer.waitForExistence(timeout: 3))
        let sync = app.buttons["Sync"]
        XCTAssertTrue(sync.exists)
        XCTAssertFalse(sync.isEnabled)
    }

    @MainActor
    func testAdministratorCreatesVendorOfflineAndQueuesOneSafePublication() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-GunnAirePendingAppRoute", "quickBooksManagement"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["QuickBooks Management"].waitForExistence(timeout: 8))
        let workspacePicker = app.segmentedControls["QuickBooksWorkspacePicker"]
        XCTAssertTrue(workspacePicker.waitForExistence(timeout: 3))
        workspacePicker.buttons["Expenses"].tap()

        let addVendor = app.buttons["Add Vendor"]
        for _ in 0..<24 where !addVendor.isHittable {
            app.swipeUp()
        }
        for _ in 0..<6 where !addVendor.isHittable {
            app.swipeDown()
        }
        XCTAssertTrue(waitForHittable(addVendor))
        XCTAssertTrue(addVendor.isEnabled)
        addVendor.tap()

        XCTAssertTrue(app.navigationBars["Add Vendor"].waitForExistence(timeout: 3))
        let name = app.textFields["QuickBooksVendorName"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        replaceText(in: name, with: "Offline QBO Vendor")
        let create = app.buttons["CreateQuickBooksVendor"]
        XCTAssertTrue(create.exists)
        XCTAssertTrue(create.isEnabled)
        create.tap()

        let composerDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.navigationBars["Add Vendor"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [composerDismissed], timeout: 3), .completed)

        let result = app.staticTexts["QuickBooksActionMessage"]
        XCTAssertTrue(waitForHittable(result))
        XCTAssertEqual(
            result.label,
            "Saved Offline QBO Vendor locally. Connect QuickBooks, then publish it from the pending vendor queue."
        )

        let pendingCount = app.descendants(matching: .any)["PendingQuickBooksVendorCount"]
        for _ in 0..<12 where !pendingCount.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(waitForHittable(pendingCount))
        XCTAssertEqual(pendingCount.label, "1 local vendor awaiting QuickBooks")

        let publish = app.buttons["PublishPendingQuickBooksVendors"]
        XCTAssertTrue(publish.exists)
        XCTAssertFalse(publish.isEnabled)

        for _ in 0..<6 where !addVendor.isHittable {
            app.swipeDown()
        }
        XCTAssertTrue(waitForHittable(addVendor))
        addVendor.tap()
        XCTAssertTrue(app.navigationBars["Add Vendor"].waitForExistence(timeout: 3))
        let duplicateName = app.textFields["QuickBooksVendorName"]
        XCTAssertTrue(duplicateName.waitForExistence(timeout: 3))
        replaceText(in: duplicateName, with: "Offline QBO Vendor")
        app.buttons["CreateQuickBooksVendor"].tap()

        let duplicateComposerDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.navigationBars["Add Vendor"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [duplicateComposerDismissed], timeout: 3), .completed)
        XCTAssertTrue(waitForHittable(result))
        XCTAssertEqual(
            result.label,
            "Offline QBO Vendor is already saved locally. Review it in the pending vendor queue before publishing."
        )
        XCTAssertEqual(pendingCount.label, "1 local vendor awaiting QuickBooks")
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

        let quickBooks = revealSidebarDestination("QuickBooks Management", in: app)
        quickBooks.tap()
        XCTAssertTrue(app.navigationBars["QuickBooks Management"].waitForExistence(timeout: 3))

        let workspacePicker = app.segmentedControls["QuickBooksWorkspacePicker"]
        XCTAssertTrue(workspacePicker.exists)
        XCTAssertTrue(workspacePicker.buttons["Overview"].isSelected)
        XCTAssertTrue(app.staticTexts["Connection"].exists)
        let syncHealth = app.staticTexts["Sync Health"]
        for _ in 0..<5 where !syncHealth.exists {
            app.swipeUp()
        }
        XCTAssertTrue(syncHealth.waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.descendants(matching: .any)["QuickBooksWebhookPendingCount"].waitForExistence(timeout: 3)
        )

        let salesWorkspacePicker = app.segmentedControls["QuickBooksWorkspacePicker"]
        for _ in 0..<8 where !salesWorkspacePicker.exists {
            app.swipeDown()
        }
        XCTAssertTrue(salesWorkspacePicker.waitForExistence(timeout: 3))
        let salesWorkspace = salesWorkspacePicker.buttons["Sales"]
        XCTAssertTrue(waitForHittable(salesWorkspace))
        salesWorkspace.tap()
        XCTAssertTrue(salesWorkspace.isSelected)
        let estimatePublication = app.staticTexts["Local Estimate Publication"]
        for _ in 0..<5 where !estimatePublication.exists {
            app.swipeUp()
        }
        XCTAssertTrue(estimatePublication.waitForExistence(timeout: 3))
        let estimateQueue = app.buttons["Review 1 open estimate"]
        XCTAssertTrue(estimateQueue.waitForExistence(timeout: 3))
        estimateQueue.tap()
        let recoverEstimate = app.buttons["Recover or Publish"]
        for _ in 0..<5 where !recoverEstimate.exists {
            app.swipeUp()
        }
        XCTAssertTrue(recoverEstimate.waitForExistence(timeout: 3))
        XCTAssertFalse(recoverEstimate.isEnabled)
        let invoicePublication = app.staticTexts["Local Invoice Publication"]
        for _ in 0..<6 where !invoicePublication.exists {
            app.swipeUp()
        }
        XCTAssertTrue(invoicePublication.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Retry Publication"].exists)
        let invoiceQueue = app.buttons["Review 1 pending invoice"]
        for _ in 0..<3 where !invoiceQueue.exists {
            app.swipeUp()
        }
        XCTAssertTrue(invoiceQueue.waitForExistence(timeout: 3))
        XCTAssertEqual(invoiceQueue.label, "Review 1 pending invoice")
        invoiceQueue.tap()
        XCTAssertTrue(app.staticTexts["UI Test Collectible Customer"].exists)
        XCTAssertTrue(app.buttons["Retry Publication"].exists)
        XCTAssertFalse(app.buttons["Retry Publication"].isEnabled)
        XCTAssertTrue(app.buttons["Open Job Billing"].exists)
        let pricebookReview = app.staticTexts["Pricebook Review"]
        for _ in 0..<6 where !pricebookReview.exists {
            app.swipeUp()
        }
        XCTAssertTrue(pricebookReview.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["HVAC Diagnostic Service"].waitForExistence(timeout: 3))
        let approvePricebookItem = app.buttons["ApprovePricebookItem-\(catalogItemID)"]
        for _ in 0..<3 where !approvePricebookItem.exists {
            app.swipeUp()
        }
        XCTAssertTrue(approvePricebookItem.waitForExistence(timeout: 3))
        approvePricebookItem.tap()
        XCTAssertTrue(app.staticTexts["No field-created catalog items need review."].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Customers"].exists)
        XCTAssertTrue(app.staticTexts["Company Pricebook"].exists)
        let quickBooksCatalog = app.staticTexts["QuickBooks Catalog"]
        for _ in 0..<4 where !quickBooksCatalog.exists {
            app.swipeUp()
        }
        XCTAssertTrue(quickBooksCatalog.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Record QB Payment"].exists)
        XCTAssertFalse(app.staticTexts["Sync Health"].exists)

        let paymentsWorkspacePicker = app.segmentedControls["QuickBooksWorkspacePicker"]
        for _ in 0..<12 where !paymentsWorkspacePicker.exists {
            app.swipeDown()
        }
        XCTAssertTrue(paymentsWorkspacePicker.waitForExistence(timeout: 3))
        paymentsWorkspacePicker.buttons["Payments"].tap()
        XCTAssertTrue(paymentsWorkspacePicker.buttons["Payments"].isSelected)
        XCTAssertTrue(app.buttons["Record Payment"].exists)
        let linkedPaymentMethods = app.descendants(matching: .any)["QuickBooksLinkedPaymentMethods"]
        for _ in 0..<8 where !linkedPaymentMethods.exists {
            app.swipeUp()
        }
        XCTAssertTrue(linkedPaymentMethods.waitForExistence(timeout: 3))
    }

    @MainActor
    func testAdministratorReviewsRealmBoundQuickBooksAccountingMappings() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedQBOAccountingMappings",
            "-GunnAirePendingAppRoute", "quickBooksManagement"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["QuickBooks Management"].waitForExistence(timeout: 8))
        let status = app.staticTexts["QBOAccountingMappingStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertTrue(status.label.localizedCaseInsensitiveContains("Ready for this company"))

        let reviewMappings = app.buttons["QBOAccountingMappingsButton"]
        for _ in 0..<4 where !reviewMappings.exists {
            app.swipeUp()
        }
        XCTAssertTrue(reviewMappings.waitForExistence(timeout: 3))
        XCTAssertTrue(reviewMappings.isEnabled)
        reviewMappings.tap()

        XCTAssertTrue(app.navigationBars["Accounting Mappings"].waitForExistence(timeout: 3))
        let realmValue = app.staticTexts["QBOAccountingRealmValue"]
        XCTAssertTrue(realmValue.waitForExistence(timeout: 3))
        XCTAssertTrue(realmValue.label.contains("9341455327810551"))
        XCTAssertTrue(app.descendants(matching: .any)["QBOAccountingSalesItemPicker"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["QBOAccountingIncomePicker"].exists)

        let expensePicker = app.descendants(matching: .any)["QBOAccountingExpensePicker"]
        let accountsPayablePicker = app.descendants(matching: .any)["QBOAccountingAPPicker"]
        let bankPicker = app.descendants(matching: .any)["QBOAccountingBankPicker"]
        let creditCardPicker = app.descendants(matching: .any)["QBOAccountingCreditCardPicker"]
        for _ in 0..<6 where !creditCardPicker.exists {
            app.swipeUp()
        }
        XCTAssertTrue(expensePicker.exists)
        XCTAssertTrue(accountsPayablePicker.exists)
        XCTAssertTrue(bankPicker.exists)
        XCTAssertTrue(creditCardPicker.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Accounts Payable"].exists)
        XCTAssertTrue(app.staticTexts["Operating Checking"].exists)
        XCTAssertTrue(app.staticTexts["Company Card"].exists)

        let save = app.buttons["QBOAccountingSaveButton"]
        XCTAssertTrue(save.exists)
        XCTAssertTrue(save.isEnabled)
        save.tap()

        XCTAssertTrue(app.navigationBars["QuickBooks Management"].waitForExistence(timeout: 3))
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertTrue(status.label.localizedCaseInsensitiveContains("Ready for this company"))
    }

    @MainActor
    func testAdministratorReviewsLinkedCatalogDifferencesBeforeChoosingAQuickBooksDirection() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedCatalogReconciliation",
            "-GunnAirePendingAppRoute", "quickBooksManagement"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["QuickBooks Management"].waitForExistence(timeout: 8))

        let workspacePicker = app.segmentedControls["QuickBooksWorkspacePicker"]
        XCTAssertTrue(workspacePicker.waitForExistence(timeout: 3))
        workspacePicker.buttons["Sales"].tap()

        let reconciliationQueue = app.descendants(matching: .any)["QuickBooksCatalogReconciliationQueue"]
        for _ in 0..<8 where !reconciliationQueue.exists {
            app.swipeUp()
        }
        XCTAssertTrue(reconciliationQueue.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Catalog Reconciliation"].exists)
        XCTAssertTrue(app.staticTexts["HVAC Diagnostic Service"].exists)
        XCTAssertTrue(app.staticTexts["Sales price"].exists)
        XCTAssertTrue(app.staticTexts["GunnAire"].exists)
        XCTAssertTrue(app.staticTexts["QuickBooks"].exists)

        let publish = app.buttons["Publish GunnAire Version"]
        let useQuickBooks = app.buttons["Use QuickBooks Version"]
        for _ in 0..<4 where !useQuickBooks.exists {
            app.swipeUp()
        }
        XCTAssertTrue(publish.exists)
        XCTAssertFalse(publish.isEnabled)

        XCTAssertTrue(useQuickBooks.exists)
        XCTAssertTrue(useQuickBooks.isEnabled)
        useQuickBooks.tap()

        let resolved = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !reconciliationQueue.exists },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [resolved], timeout: 3), .completed)
    }

    @MainActor
    func testAdministratorRestoresArchivedCatalogItemIntoExplicitQuickBooksReconciliation() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedArchivedCatalog",
            "-GunnAirePendingAppRoute", "quickBooksManagement"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["QuickBooks Management"].waitForExistence(timeout: 8))
        let workspacePicker = app.segmentedControls["QuickBooksWorkspacePicker"]
        XCTAssertTrue(workspacePicker.waitForExistence(timeout: 3))
        workspacePicker.buttons["Sales"].tap()

        let archivedSection = app.staticTexts["ArchivedPricebookSection"]
        for _ in 0..<10 where !archivedSection.exists {
            app.swipeUp()
        }
        XCTAssertTrue(archivedSection.waitForExistence(timeout: 3))
        let disclosure = app.buttons["Review 1 archived item"]
        for _ in 0..<4 where !(disclosure.exists && disclosure.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(waitForHittable(disclosure))
        disclosure.tap()
        let archivedItem = app.staticTexts["Archived Blower Motor"]
        for _ in 0..<4 where !archivedItem.exists {
            app.swipeUp()
        }
        XCTAssertTrue(archivedItem.waitForExistence(timeout: 3))

        let restore = app.buttons["RestoreArchivedCatalogItem-\(archivedCatalogItemID)"]
        for _ in 0..<4 where !restore.exists {
            app.swipeUp()
        }
        XCTAssertTrue(restore.waitForExistence(timeout: 3))
        restore.tap()

        let archivedRemoved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: archivedSection
        )
        XCTAssertEqual(XCTWaiter.wait(for: [archivedRemoved], timeout: 3), .completed)
        let comparisonWaiting = app.staticTexts["QuickBooksCatalogComparisonWaiting"]
        for _ in 0..<12 where !comparisonWaiting.exists || !comparisonWaiting.isHittable {
            app.swipeDown()
        }
        if !comparisonWaiting.exists || !comparisonWaiting.isHittable {
            for _ in 0..<18 where !comparisonWaiting.exists || !comparisonWaiting.isHittable {
                app.swipeUp()
            }
        }
        XCTAssertTrue(comparisonWaiting.waitForExistence(timeout: 3))
        XCTAssertTrue(comparisonWaiting.isHittable)
        XCTAssertTrue(app.staticTexts["QBO QBO-UI-ARCHIVED-CATALOG • Staged locally"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testStagedCatalogUpdateRemainsVisibleWhileQuickBooksComparisonIsUnavailable() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedCatalogReconciliation",
            "-uiTestCatalogComparisonUnavailable",
            "-GunnAirePendingAppRoute", "quickBooksManagement"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["QuickBooks Management"].waitForExistence(timeout: 8))
        let workspacePicker = app.segmentedControls["QuickBooksWorkspacePicker"]
        XCTAssertTrue(workspacePicker.waitForExistence(timeout: 3))
        workspacePicker.buttons["Sales"].tap()

        let waiting = app.staticTexts["QuickBooksCatalogComparisonWaiting"]
        for _ in 0..<8 where !waiting.exists {
            app.swipeUp()
        }
        XCTAssertTrue(waiting.waitForExistence(timeout: 3))
        XCTAssertEqual(waiting.label, "Waiting for a live QuickBooks comparison")
        XCTAssertTrue(app.staticTexts["HVAC Diagnostic Service"].exists)
        XCTAssertTrue(app.staticTexts["QBO QBO-UI-CATALOG-RECONCILE • Staged locally"].exists)
        XCTAssertTrue(app.staticTexts["The local changes remain saved and no QuickBooks update has been sent. Reconnect or refresh before choosing which version wins."].exists)
        let refresh = app.buttons["RefreshQuickBooksCatalogComparison"]
        XCTAssertTrue(refresh.exists)
        XCTAssertFalse(refresh.isEnabled)
        XCTAssertFalse(app.buttons["Retry Catalog Publication"].exists)
    }

    @MainActor
    func testAdministratorResolvesDuplicateQuickBooksCatalogMappingWithoutDeletingLocalItems() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedCatalogMappingConflict",
            "-GunnAirePendingAppRoute", "quickBooksManagement"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["QuickBooks Management"].waitForExistence(timeout: 8))
        let workspacePicker = app.segmentedControls["QuickBooksWorkspacePicker"]
        XCTAssertTrue(workspacePicker.waitForExistence(timeout: 3))
        workspacePicker.buttons["Sales"].tap()

        let conflictQueue = app.descendants(matching: .any)["QuickBooksCatalogMappingConflictQueue"]
        for _ in 0..<8 where !conflictQueue.exists {
            app.swipeUp()
        }
        XCTAssertTrue(conflictQueue.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Catalog Mapping Conflicts"].exists)

        let keepCanonical = app.buttons["KeepCatalogMapping-\(catalogItemID)"]
        for _ in 0..<4 where !keepCanonical.exists {
            app.swipeUp()
        }
        XCTAssertTrue(keepCanonical.waitForExistence(timeout: 3))
        keepCanonical.tap()

        XCTAssertTrue(app.buttons["Keep QBO Link"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Keep this QuickBooks mapping?"].exists)
        app.buttons["Keep QBO Link"].tap()

        let resolved = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !conflictQueue.exists },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [resolved], timeout: 3), .completed)
        XCTAssertTrue(app.staticTexts["Catalog Publication"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["After-Hours HVAC Diagnostic"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Publication pending"].exists)
    }

    @MainActor
    func testSyncIntegrationsUsesCompactRecoveryBreakdown() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestForceQuickBooksDisconnected",
            "-uiTestSeedSyncRecovery"
        ]
        app.launch()

        let syncIntegrations = revealSidebarDestination("Sync & Integrations", in: app)
        syncIntegrations.tap()
        // On iPadOS 26 a nested NavigationStack inside the split view does not
        // consistently expose its title as an XCUI navigation bar. A unique
        // first-section label is the stable screen-ready boundary.
        XCTAssertTrue(app.staticTexts["Sync Status"].waitForExistence(timeout: 8))

        let recoveryDisclosure = app.buttons["SyncRecoveryDisclosure"]
        XCTAssertTrue(recoveryDisclosure.waitForExistence(timeout: 3))
        let recoveryCount = recoveryDisclosure.label
            .split(separator: " ")
            .dropFirst()
            .first
            .flatMap { Int($0) }
        XCTAssertGreaterThanOrEqual(
            recoveryCount ?? 0,
            2,
            "Expected at least the two seeded recovery items: \(recoveryDisclosure.label)"
        )
        recoveryDisclosure.tap()

        XCTAssertTrue(app.buttons["SyncRecoveryQuickBooksDocuments"].waitForExistence(timeout: 3))
        let pricebookRecovery = app.buttons["SyncRecoveryPricebook"]
        XCTAssertTrue(pricebookRecovery.exists)
        XCTAssertFalse(app.buttons["SyncRecoveryPayments"].exists)
        XCTAssertFalse(app.buttons["SyncRecoveryCalendar"].exists)

        pricebookRecovery.tap()
        XCTAssertTrue(app.navigationBars["QuickBooks Management"].waitForExistence(timeout: 3))
        let workspacePicker = app.segmentedControls["QuickBooksWorkspacePicker"]
        XCTAssertTrue(workspacePicker.waitForExistence(timeout: 3))
        XCTAssertTrue(workspacePicker.buttons["Sales"].isSelected)
        XCTAssertTrue(app.staticTexts["Catalog Publication"].exists)

        let catalogDisclosure = app.descendants(matching: .any)["QuickBooksCatalogPublicationDisclosure"]
        for _ in 0..<4 where !catalogDisclosure.exists {
            app.swipeUp()
        }
        XCTAssertTrue(catalogDisclosure.waitForExistence(timeout: 3))
        catalogDisclosure.tap()

        let retryCatalogPublication = app.buttons["Retry Catalog Publication"]
        XCTAssertTrue(app.staticTexts["HVAC Diagnostic Service"].waitForExistence(timeout: 3))
        XCTAssertTrue(retryCatalogPublication.exists)
        XCTAssertFalse(retryCatalogPublication.isEnabled)
    }

    @MainActor
    func testGoogleDriveArchiveIsCompactRoleAwareAndFailsClosedUntilAuthorized() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedWarrantyClaim"
        ]
        app.launch()

        let syncIntegrations = revealSidebarDestination("Sync & Integrations", in: app)
        syncIntegrations.tap()
        XCTAssertTrue(app.staticTexts["Sync Status"].waitForExistence(timeout: 8))

        let driveSection = app.descendants(matching: .any)["GoogleDriveArchiveSection"]
        for _ in 0..<8 where !driveSection.exists {
            app.swipeUp()
        }
        XCTAssertTrue(driveSection.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Google Drive Archive"].exists)
        XCTAssertTrue(app.staticTexts["Connect Google"].exists)
        let waitingCount = app.descendants(matching: .any)["GoogleDriveWaitingCount"]
        for _ in 0..<3 where !waitingCount.exists {
            app.swipeUp()
        }
        XCTAssertTrue(waitingCount.waitForExistence(timeout: 3))
        XCTAssertTrue(waitingCount.label.contains("1"), "Unexpected Drive waiting count: \(waitingCount.label)")

        let archivePending = app.buttons["ArchivePendingGoogleDriveFiles"]
        XCTAssertTrue(archivePending.exists)
        XCTAssertFalse(archivePending.isEnabled)
        XCTAssertTrue(app.buttons["GoogleDriveArchiveQueue"].exists)
        XCTAssertFalse(app.buttons["ReconnectGoogleForDrive"].exists)
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

        let payments = revealSidebarDestination("Payments", in: app)
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
        let recordPayment = app.staticTexts["Record Payment"]
        for _ in 0..<5 where !recordPayment.exists {
            app.swipeUp()
        }
        XCTAssertTrue(recordPayment.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Collections Dashboard"].exists)

        for _ in 0..<6 {
            app.swipeDown()
        }
        let historyWorkspace = app.segmentedControls["PaymentsWorkspacePicker"].buttons["History"]
        XCTAssertTrue(waitForHittable(historyWorkspace))
        historyWorkspace.tap()
        let sharedCollections = app.staticTexts["Shared Field Collections"]
        for _ in 0..<5 where !sharedCollections.exists {
            app.swipeUp()
        }
        XCTAssertTrue(sharedCollections.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Payment History"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Outstanding Invoices"].exists)
    }

    @MainActor
    func testIPadOutstandingInvoiceActionsKeepFieldHandoffReachable() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedQuickBooksLinkedCollection"
        ]
        app.launch()

        guard app.windows.firstMatch.frame.width >= 700 else {
            throw XCTSkip("This assertion verifies the primary iPad collection layout.")
        }

        let payments = app.staticTexts["Payments"]
        XCTAssertTrue(payments.waitForExistence(timeout: 5))
        payments.tap()
        let workspacePicker = app.segmentedControls["PaymentsWorkspacePicker"]
        XCTAssertTrue(workspacePicker.waitForExistence(timeout: 3))
        workspacePicker.buttons["Collect"].tap()

        let actionGrid = app.descendants(matching: .any)["InvoiceCollectionActions-\(screenshotInvoiceID)"]
        XCTAssertTrue(actionGrid.waitForExistence(timeout: 10))
        let sendToFieldIPhone = actionGrid.buttons["Send to Field iPhone"]
        for _ in 0..<4 where !sendToFieldIPhone.exists || !sendToFieldIPhone.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(sendToFieldIPhone.exists)
        XCTAssertTrue(sendToFieldIPhone.isHittable)
        sendToFieldIPhone.tap()

        app.swipeDown()
        let handoffStatus = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "Payment handoff is ready")
        ).firstMatch
        XCTAssertTrue(handoffStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(handoffStatus.label.contains("Tap to Pay on iPhone"))

        let stopFieldHandoff = app.buttons["Stop Field Handoff"]
        XCTAssertTrue(stopFieldHandoff.waitForExistence(timeout: 3))

        // The Handoff activity is app-scoped while status copy is view-local. Recreate
        // the Payments screen and prove that cancellation never disappears with the
        // transient message state.
        app.staticTexts["Command Center"].tap()
        XCTAssertTrue(app.navigationBars["Command Center"].waitForExistence(timeout: 3))
        app.staticTexts["Payments"].tap()
        XCTAssertTrue(app.navigationBars["Payments"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Stop Field Handoff"].waitForExistence(timeout: 3))
        app.buttons["Stop Field Handoff"].tap()
        XCTAssertFalse(app.buttons["Stop Field Handoff"].exists)
    }

    @MainActor
    func testFieldCollectionPromptOpensAuthorizedInvoiceFromAnyWorkspace() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedTechnician",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedQuickBooksLinkedCollection",
            "-uiTestSeedFieldCollectionPrompt"
        ]
        app.launch()

        // The compact iPhone root does not expose the split-view navigation title that
        // appears on iPad. The app-wide prompt is the platform-neutral launch boundary.
        XCTAssertTrue(app.descendants(matching: .any)["AppWideFieldCollectionPrompt"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Field collection assigned"].exists)
        XCTAssertTrue(app.staticTexts["UI Test Collectible Customer • $189.00"].exists)

        app.buttons["View Task"].tap()

        XCTAssertTrue(app.navigationBars["Payments"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Contactless Payment"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["UI Test Collectible Customer"].exists)
        XCTAssertTrue(app.staticTexts["Use Tap to Pay on iPhone in QuickBooks"].exists)
        let quickBooksInvoiceID = app.descendants(matching: .any)["ContactlessQuickBooksInvoiceID"]
        XCTAssertTrue(quickBooksInvoiceID.exists)
        XCTAssertTrue(quickBooksInvoiceID.label.contains("QBO-UI-INVOICE-189"))
        XCTAssertTrue(app.buttons["Copy QuickBooks Invoice ID"].exists)
        let quickBooksAppHandoff = app.descendants(matching: .any)["Open or Install QuickBooks Mobile"]
        let goPaymentAppHandoff = app.descendants(matching: .any)["Open or Install GoPayment"]
        for _ in 0..<3 where !quickBooksAppHandoff.exists || !goPaymentAppHandoff.exists {
            app.swipeUp()
        }
        XCTAssertTrue(quickBooksAppHandoff.exists)
        XCTAssertTrue(goPaymentAppHandoff.exists)
        let accountingInstruction = app.staticTexts["ContactlessAccountingVerificationInstruction"]
        for _ in 0..<3 where !accountingInstruction.exists {
            app.swipeUp()
        }
        XCTAssertTrue(accountingInstruction.exists)
        XCTAssertTrue(accountingInstruction.label.contains("Leave the invoice open. Accounting will verify"))
        XCTAssertFalse(app.buttons["VerifyContactlessQuickBooksPayment"].exists)
    }

    @MainActor
    func testFinancialContactlessGuideKeepsVerificationBesideTheHandoff() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedQuickBooksLinkedCollection",
            "-uiTestForceQuickBooksDisconnected",
            "-GunnAirePendingAppRoute", "payments",
            "-GunnAirePendingInvoiceID", screenshotInvoiceID,
            "-GunnAirePendingOpenPaymentCollection", "YES",
            "-GunnAirePendingContactlessPaymentGuide", "YES"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Contactless Payment"].waitForExistence(timeout: 8))
        let connectQuickBooks = app.buttons["ConnectQuickBooksForContactlessVerification"]
        for _ in 0..<5 where !connectQuickBooks.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(connectQuickBooks.exists)
        XCTAssertTrue(connectQuickBooks.isHittable)
        XCTAssertFalse(app.buttons["VerifyContactlessQuickBooksPayment"].exists)
        XCTAssertTrue(app.buttons["Record Cash, Check, or Another Verified Payment"].exists)

        app.terminate()
        app.launchArguments.removeAll { $0 == "-uiTestForceQuickBooksDisconnected" }
        app.launchArguments.append("-uiTestForceQuickBooksConnected")
        app.launch()

        XCTAssertTrue(app.navigationBars["Contactless Payment"].waitForExistence(timeout: 8))
        let verifyPayment = app.buttons["VerifyContactlessQuickBooksPayment"]
        for _ in 0..<5 where !verifyPayment.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(verifyPayment.exists)
        XCTAssertTrue(verifyPayment.isEnabled)
        XCTAssertTrue(verifyPayment.isHittable)
        XCTAssertFalse(app.buttons["ConnectQuickBooksForContactlessVerification"].exists)

        app.terminate()
        app.launchArguments.removeAll {
            $0 == "-uiTestAuthenticatedAdmin" || $0 == "-uiTestForceQuickBooksConnected"
        }
        app.launchArguments.append(contentsOf: [
            "-uiTestAuthenticatedAccounting",
            "-uiTestForceQuickBooksDisconnected"
        ])
        app.launch()

        XCTAssertTrue(app.navigationBars["Contactless Payment"].waitForExistence(timeout: 8))
        let adminConnectionInstruction = app.staticTexts["ContactlessQuickBooksAdminConnectionInstruction"]
        for _ in 0..<5 where !adminConnectionInstruction.exists {
            app.swipeUp()
        }
        XCTAssertTrue(adminConnectionInstruction.exists)
        XCTAssertFalse(app.buttons["ConnectQuickBooksForContactlessVerification"].exists)
        XCTAssertFalse(app.buttons["VerifyContactlessQuickBooksPayment"].exists)
    }

    @MainActor
    func testContactlessCollectionExplainsQuickBooksPublicationAndRecoversToVerifiedEntry() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedTechnician",
            "-uiTestSeedCollectibleJob",
            "-GunnAirePendingAppRoute", "payments",
            "-GunnAirePendingInvoiceID", screenshotInvoiceID,
            "-GunnAirePendingOpenPaymentCollection", "YES",
            "-GunnAirePendingContactlessPaymentGuide", "YES"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Contactless Payment"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["QuickBooks Invoice Required"].exists)
        XCTAssertTrue(app.staticTexts["Contactless collection is waiting for QuickBooks publication."].exists)
        XCTAssertFalse(app.staticTexts["Use Tap to Pay on iPhone in QuickBooks"].exists)

        app.buttons["Record Cash, Check, or Another Verified Payment"].tap()

        XCTAssertTrue(app.navigationBars["Record Payment"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["UI Test Collectible Customer"].exists)
    }

    @MainActor
    func testFieldCollectionHandoffWaitsForAuthorizedInvoiceSyncWithoutLosingRoute() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedTechnician",
            "-GunnAirePendingAppRoute", "payments",
            "-GunnAirePendingInvoiceID", "B2000000-0000-4000-8000-000000000001",
            "-GunnAirePendingOpenPaymentCollection", "YES"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Payments"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Collection Handoff"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Waiting for the assigned invoice"].exists)
        XCTAssertTrue(app.buttons["Retry"].exists)
        XCTAssertTrue(app.buttons["Dismiss"].exists)
        XCTAssertFalse(app.navigationBars["Record Payment"].exists)

        let commandCenter = app.staticTexts["Command Center"]
        if !commandCenter.exists {
            let compactBack = app.navigationBars["Payments"].buttons.firstMatch
            XCTAssertTrue(compactBack.waitForExistence(timeout: 3))
            compactBack.tap()
        }
        XCTAssertTrue(commandCenter.waitForExistence(timeout: 3))
        commandCenter.tap()
        XCTAssertTrue(app.navigationBars["Command Center"].waitForExistence(timeout: 3))
        let paymentsDestination = app.staticTexts["Payments"]
        let compactCollectDestination = app.staticTexts["Collect"]
        let visiblePaymentDestination = paymentsDestination.exists
            ? paymentsDestination
            : compactCollectDestination
        XCTAssertTrue(visiblePaymentDestination.waitForExistence(timeout: 3))
        visiblePaymentDestination.tap()
        XCTAssertTrue(app.navigationBars["Payments"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Waiting for the assigned invoice"].waitForExistence(timeout: 3))
        app.buttons["Dismiss"].tap()
        XCTAssertFalse(app.staticTexts["Waiting for the assigned invoice"].exists)
    }

    @MainActor
    func testExpiredFieldCollectionHandoffClearsWithoutOpeningAnInvoice() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        let expiresAt = Date().addingTimeInterval(10).timeIntervalSince1970
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedTechnician",
            "-GunnAirePendingAppRoute", "payments",
            "-GunnAirePendingInvoiceID", "B2000000-0000-4000-8000-000000000002",
            "-GunnAirePendingOpenPaymentCollection", "YES",
            "-GunnAirePendingContactlessPaymentGuide", "YES",
            "-GunnAirePendingPaymentCollectionExpiresAt", String(expiresAt)
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Payments"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Waiting for the assigned invoice"].waitForExistence(timeout: 5))

        let expiredMessage = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "nearby-device handoff expired")
        ).firstMatch
        XCTAssertTrue(expiredMessage.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Waiting for the assigned invoice"].exists)
        XCTAssertFalse(app.navigationBars["Contactless Payment"].exists)
        XCTAssertFalse(app.navigationBars["Record Payment"].exists)
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

        let receiptsBills = revealSidebarDestination("Receipts & Bills", in: app)
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
    func testAdministratorReconcilesAPhysicalInventoryCountWithAuditEvidence() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-disableCloudKitForTesting",
            "-uiTestAuthenticatedAdmin",
            "-uiTestSeedCollectibleJob",
            "-uiTestSeedInventoryJob"
        ]
        app.launch()

        let receiptsBills = app.staticTexts["Receipts & Bills"]
        if !receiptsBills.waitForExistence(timeout: 2) {
            let sidebarButton = app.buttons["GunnAire Ops"]
            XCTAssertTrue(sidebarButton.waitForExistence(timeout: 3))
            sidebarButton.tap()
        }
        XCTAssertTrue(receiptsBills.waitForExistence(timeout: 3))
        receiptsBills.tap()
        XCTAssertTrue(app.navigationBars["Receipts & Bills"].waitForExistence(timeout: 3))

        let workspacePicker = app.segmentedControls["ReceiptsBillsWorkspacePicker"]
        XCTAssertTrue(workspacePicker.waitForExistence(timeout: 3))
        workspacePicker.buttons["Inventory"].tap()

        let itemPicker = app.buttons["InventoryItemPicker"]
        XCTAssertTrue(itemPicker.waitForExistence(timeout: 3))
        itemPicker.tap()
        let capacitor = app.buttons["45/5 Dual Run Capacitor"]
        XCTAssertTrue(capacitor.waitForExistence(timeout: 3))
        capacitor.tap()

        let startCount = app.buttons["StartInventoryCount"]
        for _ in 0..<6 where !startCount.exists || !startCount.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(startCount.waitForExistence(timeout: 3))
        startCount.tap()

        XCTAssertTrue(app.navigationBars["Count Inventory"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Ledger quantity"].exists)

        let count = app.textFields["InventoryCountQuantity"]
        XCTAssertTrue(count.waitForExistence(timeout: 3))
        count.tap()
        count.typeText("2.5")
        let doneEditingCount = app.buttons["Done Editing Inventory Count"]
        XCTAssertTrue(doneEditingCount.waitForExistence(timeout: 3))
        doneEditingCount.tap()

        let reason = app.textFields["InventoryCountReason"]
        XCTAssertTrue(reason.waitForExistence(timeout: 3))
        XCTAssertTrue(reason.isHittable)
        reason.tap()
        reason.typeText("Damaged during truck bin inspection")
        XCTAssertTrue(doneEditingCount.waitForExistence(timeout: 3))
        doneEditingCount.tap()

        let save = app.buttons["SaveInventoryCount"]
        XCTAssertTrue(save.isEnabled)
        save.tap()

        XCTAssertTrue(app.navigationBars["Receipts & Bills"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["InventoryActionMessage"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["On hand: 2.5 • Reserved: 1 • Available: 1.5"].exists)
        let recentCount = app.staticTexts["Inventory count: 45/5 Dual Run Capacitor"]
        for _ in 0..<8 where !recentCount.exists {
            app.swipeUp()
        }
        XCTAssertTrue(recentCount.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Damaged during truck bin inspection"].exists)
    }

    /// Produces customer-safe, repeatable App Store assets from Debug-only
    /// fixture data. The same route-driven workflow runs on iPad and iPhone;
    /// the capture command selects the appropriate simulator and orientation.
    @MainActor
    func testCaptureAppStoreScreenshots() throws {
        XCUIDevice.shared.orientation = .portrait

        captureAppStoreScreenshot(
            name: "01-command-center",
            route: "commandCenter",
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
                let assetLabel = app.buttons["EquipmentAssetLabel-\(screenshotEquipmentID)"]
                let actionsMenu = app.buttons["EquipmentActionsMenu-\(screenshotEquipmentID)"]
                let customerForm = app.collectionViews.firstMatch
                let visibleCustomerFormBottom = customerForm.frame.maxY - 80
                for _ in 0..<10 {
                    if editEquipment.waitForExistence(timeout: 1),
                       editEquipment.isHittable,
                       assetLabel.exists,
                       assetLabel.isHittable,
                       actionsMenu.exists,
                       actionsMenu.isHittable,
                       actionsMenu.frame.midY < visibleCustomerFormBottom {
                        break
                    }
                    customerForm.swipeUp()
                }
                XCTAssertTrue(editEquipment.waitForExistence(timeout: 5))
                XCTAssertTrue(editEquipment.isHittable)
                XCTAssertTrue(assetLabel.exists)
                XCTAssertTrue(assetLabel.isHittable)
                XCTAssertTrue(actionsMenu.exists)
                XCTAssertTrue(actionsMenu.isHittable)
                XCTAssertLessThan(actionsMenu.frame.midY, visibleCustomerFormBottom)
                XCTAssertFalse(app.buttons["EquipmentStatus-\(screenshotEquipmentID)"].exists)
                XCTAssertFalse(app.buttons["DeleteEquipment-\(screenshotEquipmentID)"].exists)
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
            expectedNavigationTitle: "Record Payment",
            afterLaunch: { app in
                let staleServerError = app.staticTexts.matching(
                    NSPredicate(
                        format: "label CONTAINS[c] %@",
                        "before accessing the shared business server"
                    )
                ).firstMatch
                XCTAssertFalse(
                    staleServerError.exists,
                    "App Store payment fixture exposed a stale shared-server authentication error"
                )
            }
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
        // Keep App Store fixture capture deterministic without changing the
        // production app. An unsupported test-process auth mode makes the
        // shared backend intentionally unconfigured for these launches only.
        app.launchEnvironment["GUNNAIRE_BACKEND_AUTH_MODE"] = "disabled-for-screenshot"
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

        XCTAssertFalse(
            app.descendants(matching: .any)["SidebarAccountIdentity"].exists,
            "App Store screenshot \(name) exposed the signed-in account identity"
        )
        waitForSystemBannerToClear(beforeCapturing: name)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    @MainActor
    private func waitForSystemBannerToClear(beforeCapturing screenshotName: String) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let banner = springboard.descendants(matching: .any)["NotificationShortLookView"]
        guard banner.exists else { return }

        let bannerCleared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: banner
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [bannerCleared], timeout: 12),
            .completed,
            "System notification obscured App Store screenshot \(screenshotName)"
        )
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
