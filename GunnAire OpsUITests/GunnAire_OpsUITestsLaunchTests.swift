//
//  GunnAire_OpsUITestsLaunchTests.swift
//  GunnAire OpsUITests
//
//  Created by Eric Gunn on 2/23/26.
//

import XCTest

final class GunnAire_OpsUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        // Screenshot variants run without a signed-in iCloud account. Match the
        // isolated local-store launch used by the other UI tests so this smoke
        // test verifies the app's first screen instead of simulator account
        // state.
        app.launchArguments = [
            "-enableSplashVideo", "NO",
            "-hasAuthenticatedUser", "NO",
            "-disableCloudKitForTesting"
        ]
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
