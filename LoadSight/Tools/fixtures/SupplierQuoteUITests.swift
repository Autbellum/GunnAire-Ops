import XCTest

final class SupplierQuoteUITests: XCTestCase {
    @MainActor
    func testRecordQuoteAndReopenEvidence() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.staticTexts["Synthetic comparison project"].waitForExistence(timeout: 15))
        app.staticTexts["Takeoff"].firstMatch.tap()
        let open = app.buttons["CatalogCost-CMP-1"]
        XCTAssertTrue(open.waitForExistence(timeout: 5)); open.tap()
        func reveal(_ element: XCUIElement) {
            for _ in 0..<16 {
                let bottom = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY - 30 : app.frame.height - 30
                let top = app.navigationBars["Catalog material cost"].frame.maxY + 12
                if element.exists && element.isHittable && element.frame.minY > top && element.frame.maxY < bottom { return }
                if element.exists && element.frame.minY < top { app.swipeDown() } else { app.swipeUp() }
            }
        }
        let status = app.staticTexts["CatalogComparisonStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5)); XCTAssertTrue(status.label.contains("differs"))
        XCTAssertTrue(app.staticTexts["Current material cost, $10.00"].exists)
        let use = app.buttons["ReviewCurrentCatalogRecord"]
        reveal(use); use.tap()
        XCTAssertFalse(app.buttons["ApplyCatalogMapping"].isEnabled)
        let factor = app.textFields["CatalogUnitFactor"]
        reveal(factor); XCTAssertNotEqual(factor.value as? String, "0.2")
        // Scroll back to the USD switch rather than tapping its broad label element.
        for _ in 0..<8 { if app.switches["CatalogConfirmUSD"].firstMatch.isHittable { break }; app.swipeDown() }
        let usd = app.switches["CatalogConfirmUSD"].firstMatch
        usd.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        func fill(_ id: String, _ value: String) {
            let field = app.textFields[id]; reveal(field); field.tap(); field.typeText(value)
        }
        fill("CatalogPurchaseUnit", "five-foot length")
        fill("CatalogUnitFactor", "0.2")
        fill("CatalogMappingBasis", "Synthetic conversion reviewed")
        fill("CatalogMappingAuthor", "UI comparison recorder")
        fill("CatalogMappingReason", "Use reviewed current source")
        let recordQuote = app.switches["CatalogRecordQuote"].firstMatch
        reveal(recordQuote)
        let quoteControl = recordQuote.descendants(matching: .switch).firstMatch
        XCTAssertTrue(quoteControl.exists); quoteControl.tap()
        XCTAssertEqual(recordQuote.value as? String, "1")
        // Expanding the section can keep the old bottom anchor while the keyboard is open.
        app.swipeDown(); app.swipeDown()
        fill("QuoteSupplier", "Synthetic supplier")
        fill("QuoteReference", "QUOTE-UI-1")
        fill("QuoteSource", "Synthetic quote page 1")
        fill("QuoteIssuedAt", "2026-09-10T12:00:00Z")
        fill("QuoteValidUntil", "2099-09-11T12:00:00Z")
        fill("QuoteConditions", "Synthetic terms; freight excluded")
        XCTAssertTrue(app.buttons["ApplyCatalogMapping"].isEnabled)
        app.buttons["ApplyCatalogMapping"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.navigationBars["Catalog material cost"])
        waitForExpectations(timeout: 5)
        open.tap()
        XCTAssertTrue(app.staticTexts["Current material cost, $15.00"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["CatalogComparisonStatus"].label.contains("matches"))
        let quoteStatus = app.staticTexts["SupplierQuoteStatus"]
        reveal(quoteStatus)
        XCTAssertTrue(quoteStatus.label.contains("Within the recorded quote period"))
        // Reopen at the actual sheet position; reveal each field before reading its value.
        app.swipeDown()
        let expiry = app.textFields["QuoteValidUntil"]; reveal(expiry)
        XCTAssertEqual(expiry.value as? String, "2099-09-11T12:00:00Z")
        let reference = app.textFields["QuoteReference"]; reveal(reference)
        XCTAssertEqual(reference.value as? String, "QUOTE-UI-1")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Supplier quote evidence reopened"; shot.lifetime = .keepAlways; add(shot)
    }
}
