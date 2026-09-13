import XCTest

final class LoadSightUITests: XCTestCase {
    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        print("LOADSIGHT_\(name)_TREE\n" + app.debugDescription)
        let capture = XCTAttachment(screenshot:app.screenshot())
        capture.name = name; capture.lifetime = .keepAlways; add(capture)
    }
    @MainActor
    func testCreateDocumentAndCalculationNavigation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for:.runningForeground,timeout:20))
        let create = app.buttons["Create Document"]
        if !create.waitForExistence(timeout:5), app.buttons["BackButton"].firstMatch.isHittable {
            app.buttons["BackButton"].firstMatch.tap()
        }
        XCTAssertTrue(create.waitForExistence(timeout:25))
        create.tap()
        let ready = app.staticTexts["Estimate readiness"].waitForExistence(timeout:20)
        capture(app,"New project workspace")
        XCTAssertTrue(ready,"Creating a document must open the project workspace.")
        app.staticTexts["Calculations"].firstMatch.tap()
        if app.buttons["Hide Sidebar"].isHittable { app.buttons["Hide Sidebar"].tap() }
        let mode = app.buttons["calculation.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout:10))
        mode.tap()
        app.buttons["Envelope assemblies"].tap()
        XCTAssertTrue(app.textFields["Assembly name"].waitForExistence(timeout:5))
        capture(app,"Envelope form")
        mode.tap()
        app.buttons["Room transmission"].tap()
        XCTAssertTrue(app.textFields["Room / design-case name"].waitForExistence(timeout:5))
        capture(app,"Room transmission form")
        let fresh = app.buttons["Start a new case"]
        fresh.tap()
        XCTAssertFalse(app.buttons["Discard form changes"].exists,"An unchanged empty form must reset without a discard prompt.")
        let roomName = app.textFields["Room / design-case name"]
        roomName.tap(); roomName.typeText("Unsaved UI fixture")
        fresh.tap()
        XCTAssertTrue(app.buttons["Discard form changes"].waitForExistence(timeout:5))
        app.otherElements["PopoverDismissRegion"].tap()
        XCTAssertEqual(roomName.value as? String,"Unsaved UI fixture")
        fresh.tap(); app.buttons["Discard form changes"].tap()
        XCTAssertNotEqual(roomName.value as? String,"Unsaved UI fixture")
        mode.tap()
        app.buttons["Air conditions"].tap()
        let dry = app.textFields["Dry bulb (°F)"]
        XCTAssertTrue(dry.waitForExistence(timeout:5)); dry.tap(); dry.typeText("70")
        let rh = app.textFields["Relative humidity (%)"]; XCTAssertTrue(rh.exists); rh.tap(); rh.typeText("50")
        let pressure = app.textFields["Absolute station pressure (psia)"]; XCTAssertTrue(pressure.exists); pressure.tap(); pressure.typeText("14.696")
        let calculate = app.buttons["Calculate air state"]
        if !calculate.isHittable { app.swipeUp() }
        calculate.tap()
        let result = app.staticTexts["Calculated air state"]
        if !result.isHittable { app.swipeUp() }
        XCTAssertTrue(result.exists)
        let ratio = app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","grains/lb dry air")).firstMatch
        for _ in 0..<4 { if ratio.isHittable { break }; app.swipeUp() }
        capture(app,"Calculated air state")
        XCTAssertTrue(ratio.isHittable,"Calculated humidity ratio and its units must be visible.")
        XCTAssertFalse(app.keyboards.firstMatch.exists,"Calculation dismisses the numeric entry keyboard.")
    }
    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<16 {
            let bottom = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY - 60 : app.frame.height - 20
            if element.exists && element.isHittable && element.frame.minY > 210 && element.frame.maxY < bottom { return }
            let down = element.exists && element.frame.minY < 210
            let start = app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:down ? 0.3 : 0.5))
            let end = app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:down ? 0.5 : 0.3))
            start.press(forDuration:0.05,thenDragTo:end)
        }
        capture(app,"Unreachable control")
        XCTFail("Unable to reach " + element.debugDescription)
    }
    @MainActor
    private func fill(_ label: String, _ text: String, in app: XCUIApplication, replacing: Bool = false) {
        let field = app.textFields[label].firstMatch
        for _ in 0..<8 {
            if field.isHittable && field.frame.minY > 210 && field.frame.maxY < app.frame.height * 0.65 { break }
            let down = field.exists && field.frame.minY < 210
            let start = app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:down ? 0.3 : 0.5))
            let end = app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:down ? 0.5 : 0.3))
            start.press(forDuration:0.05,thenDragTo:end)
        }
        reveal(field,in:app)
        field.coordinate(withNormalizedOffset:CGVector(dx:0.9,dy:0.5)).tap()
        if replacing {
            field.press(forDuration:1.1)
            let selectAll = app.menuItems["Select All"]
            if selectAll.waitForExistence(timeout:2) { selectAll.tap() }
            else if app.buttons["Select All"].exists { app.buttons["Select All"].tap() }
            else { field.doubleTap() }
        }
        field.typeText(text)
        XCTAssertEqual(field.value as? String,text,"Input did not match the entered fixture value: " + label)
    }
    @MainActor
    private func chooseMode(_ label: String, in app: XCUIApplication) {
        let mode = app.buttons["calculation.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout:8)); mode.tap(); app.buttons[label].tap()
    }
    @MainActor
    func testRoomSaveRevisionAndReopen() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        let create = app.buttons["Create Document"]
        if !create.waitForExistence(timeout:5), app.buttons["BackButton"].firstMatch.isHittable { app.buttons["BackButton"].firstMatch.tap() }
        XCTAssertTrue(create.waitForExistence(timeout:25)); create.tap()
        XCTAssertTrue(app.staticTexts["Estimate readiness"].waitForExistence(timeout:20))
        let documentName = app.navigationBars.element(boundBy:0).identifier
        app.staticTexts["Calculations"].firstMatch.tap()
        if app.buttons["Hide Sidebar"].isHittable { app.buttons["Hide Sidebar"].tap() }
        chooseMode("Envelope assemblies",in:app)
        fill("Assembly name","UI verification wall",in:app)
        fill("Recorded by","UI test",in:app)
        fill("Drawing / assembly reference","Synthetic fixture",in:app)
        fill("Surface films: included layers or reason for omission","Synthetic total R includes films",in:app)
        fill("Path name (e.g. cavity or framing)","Full wall",in:app)
        fill("Area fraction (0–1)","1",in:app)
        fill("Area fraction source","Synthetic full area",in:app)
        let layer = app.buttons["New resistance layer"]; reveal(layer,in:app); layer.tap()
        fill("Layer name","Complete test stack",in:app)
        fill("R-value (h·ft²·°F/Btu)","10",in:app)
        fill("Resistance source / thickness basis","Synthetic fixture only",in:app)
        let saveAssembly = app.buttons["Save assembly to project"]; reveal(saveAssembly,in:app); saveAssembly.tap()
        XCTAssertTrue(app.staticTexts["Assembly saved. Project QA reopened."].waitForExistence(timeout:5))
        capture(app,"Saved assembly")
        chooseMode("Room transmission",in:app)
        fill("Room / design-case name","UI verification room",in:app)
        fill("Recorded by","UI test",in:app)
        fill("Room drawing and design-case source","Synthetic room fixture",in:app)
        fill("Indoor design temperature (°F)","70",in:app)
        fill("Indoor design temperature (°F) source","Synthetic setpoint",in:app)
        fill("Surface name / drawing location","Exterior wall",in:app)
        let assembly = app.buttons.matching(NSPredicate(format:"label CONTAINS %@","Choose a saved assembly")).firstMatch
        reveal(assembly,in:app); assembly.tap(); app.buttons["UI verification wall"].tap()
        fill("Gross area including openings (ft²)","100",in:app)
        fill("Gross area including openings (ft²) source","Synthetic area",in:app)
        fill("Adjacent design temperature (°F)","10",in:app)
        fill("Adjacent design temperature (°F) source","Synthetic design weather",in:app)
        if app.buttons["Hide keyboard"].isHittable { app.buttons["Hide keyboard"].tap() }
        let noOpenings = app.switches["This surface has no openings"]; reveal(noOpenings,in:app)
        noOpenings.coordinate(withNormalizedOffset:CGVector(dx:0.95,dy:0.5)).tap()
        XCTAssertEqual(noOpenings.value as? String,"1")
        let saveRoom = app.buttons["Save room transmission"]; reveal(saveRoom,in:app); saveRoom.tap()
        capture(app,"Room save response")
        reveal(app.staticTexts["Room transmission saved. Project QA reopened."],in:app)
        let room = app.buttons["UI verification room"]; reveal(room,in:app); room.tap()
        reveal(app.staticTexts["Entered envelope loss (Btuh), 600.00"].firstMatch,in:app)
        capture(app,"Saved room transmission")
        let revise = app.buttons["Revise this case"]
        for _ in 0..<12 { if revise.exists { break }; app.swipeDown() }
        reveal(revise,in:app); revise.tap()
        XCTAssertFalse(app.buttons["Discard form changes"].exists,"Saved form should not be treated as an unsaved draft.")
        for _ in 0..<8 { if app.descendants(matching:.any).matching(identifier:"Revision reason").firstMatch.isHittable { break }; app.swipeDown() }
        fill("Revision reason","Synthetic setpoint correction",in:app)
        fill("Recorded by","UI reviser",in:app)
        fill("Indoor design temperature (°F)","75",in:app,replacing:true)
        let saveRevision = app.buttons["Save revision"]; reveal(saveRevision,in:app); saveRevision.tap()
        reveal(app.staticTexts["Room transmission saved. Project QA reopened."],in:app)
        let revisedValue = app.staticTexts["Entered envelope loss (Btuh), 650.00"].firstMatch; reveal(revisedValue,in:app)
        capture(app,"Revised room transmission")
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(create.waitForExistence(timeout:20))
        capture(app,"Document browser after save")
        let savedDocument = app.cells[documentName + ", loadsight"].images.firstMatch
        XCTAssertTrue(savedDocument.waitForExistence(timeout:10)); savedDocument.tap()
        XCTAssertTrue(app.staticTexts["Estimate readiness"].waitForExistence(timeout:20))
        app.staticTexts["Calculations"].firstMatch.tap()
        if app.buttons["Hide Sidebar"].isHittable { app.buttons["Hide Sidebar"].tap() }
        chooseMode("Room transmission",in:app)
        reveal(room,in:app); room.tap(); reveal(revisedValue,in:app)
        capture(app,"Reopened revised room")
    }

    @MainActor
    func testChangeOrderDraftSaveAndReopen() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        let create = app.buttons["Create Document"]
        if !create.waitForExistence(timeout:5), app.buttons["BackButton"].firstMatch.isHittable { app.buttons["BackButton"].firstMatch.tap() }
        XCTAssertTrue(create.waitForExistence(timeout:25)); create.tap()
        XCTAssertTrue(app.staticTexts["Estimate readiness"].waitForExistence(timeout:20))
        let documentName = app.navigationBars.element(boundBy:0).identifier
        app.staticTexts["Change orders"].firstMatch.tap()
        app.buttons["New change order"].tap()
        fill("CO number", "UI-CO-001", in:app)
        fill("Recorded author", "UI recorder", in:app)
        fill("Original contract scope", "Synthetic original duct route", in:app)
        fill("Proposed revised scope", "Synthetic revised duct route", in:app)
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Discard draft"].waitForExistence(timeout:5))
        app.buttons["Keep editing"].tap()
        XCTAssertTrue(app.textFields["Proposed revised scope"].exists)
        app.buttons["Save draft"].tap()
        XCTAssertTrue(app.staticTexts["UI-CO-001"].waitForExistence(timeout:10))
        capture(app,"Saved change order draft")
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(create.waitForExistence(timeout:20))
        let savedDocument = app.cells[documentName + ", loadsight"].images.firstMatch
        XCTAssertTrue(savedDocument.waitForExistence(timeout:10)); savedDocument.tap()
        XCTAssertTrue(app.staticTexts["Estimate readiness"].waitForExistence(timeout:20))
        app.staticTexts["Change orders"].firstMatch.tap()
        app.staticTexts["UI-CO-001"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["UI recorder"].waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["Synthetic revised duct route"].exists)
        capture(app,"Reopened change order draft")
    }

    @MainActor
    func testChangeOrderRevisionAndReopen() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        let create = app.buttons["Create Document"]
        if !create.waitForExistence(timeout:5), app.buttons["BackButton"].firstMatch.isHittable { app.buttons["BackButton"].firstMatch.tap() }
        XCTAssertTrue(create.waitForExistence(timeout:25)); create.tap()
        XCTAssertTrue(app.staticTexts["Estimate readiness"].waitForExistence(timeout:20))
        let documentName = app.navigationBars.element(boundBy:0).identifier
        app.staticTexts["Change orders"].firstMatch.tap()
        app.buttons["New change order"].tap()
        fill("CO number", "UI-CO-REV", in:app)
        fill("Recorded author", "UI recorder", in:app)
        fill("Original contract scope", "Synthetic original duct route", in:app)
        fill("Proposed revised scope", "Synthetic revised duct route", in:app)
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Discard draft"].waitForExistence(timeout:5))
        app.buttons["Keep editing"].tap()
        XCTAssertTrue(app.textFields["Proposed revised scope"].exists)
        app.buttons["Save draft"].tap()
        XCTAssertTrue(app.staticTexts["UI-CO-REV"].waitForExistence(timeout:10))
        app.buttons["Revise draft UI-CO-REV"].tap()
        fill("Recorded author", "UI reviser", in:app)
        fill("Revision reason", "Synthetic drawing correction", in:app)
        fill("Proposed revised scope", "Corrected mechanical route", in:app, replacing:true)
        app.buttons["Save draft"].tap()
        XCTAssertTrue(app.staticTexts["Corrected mechanical route"].waitForExistence(timeout:10))
        capture(app,"Revised change order draft")
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(create.waitForExistence(timeout:20))
        let savedDocument = app.cells[documentName + ", loadsight"].images.firstMatch
        XCTAssertTrue(savedDocument.waitForExistence(timeout:10)); savedDocument.tap()
        XCTAssertTrue(app.staticTexts["Estimate readiness"].waitForExistence(timeout:20))
        app.staticTexts["Change orders"].firstMatch.tap()
        app.staticTexts["UI-CO-REV"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Revision 1 · UI reviser"].waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["Synthetic drawing correction"].exists)
        capture(app,"Reopened change order history")
        app.buttons["Before revision 1"].tap()
        XCTAssertTrue(app.staticTexts["UI recorder"].waitForExistence(timeout:10))
        let earlierScope = app.staticTexts["Synthetic revised duct route"].firstMatch
        reveal(earlierScope,in:app)
        XCTAssertTrue(earlierScope.isHittable)
        capture(app,"Before change order revision")
    }
}
