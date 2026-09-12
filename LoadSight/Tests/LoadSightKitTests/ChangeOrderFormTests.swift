import XCTest
import LoadSightKit
import LoadSightUI

final class ChangeOrderFormTests: XCTestCase {
    func testTypingRetainsUnknownZeroCreditAndRejectsInvalidText() throws {
        XCTAssertNil(try ChangeOrderFormState.amount(" ", source: "Pending quote", label: "Cost").amount)
        XCTAssertEqual(try ChangeOrderFormState.amount("0", source: "No cost", label: "Cost").amount, 0)
        XCTAssertEqual(try ChangeOrderFormState.amount("-42.50", source: "Credit quote", label: "Cost").amount, -42.5)
        for text in ["abc", "1,000", "$20", "nan", "inf", "1e999"] { XCTAssertThrowsError(try ChangeOrderFormState.amount(text, source: "Source", label: "Cost")) }
        XCTAssertThrowsError(try ChangeOrderFormState.amount("0", source: "", label: "Cost"))
    }
    func testFormMapsAllValuesSourcesAndQuantitiesWithoutChangingTypedState() throws {
        var state = ChangeOrderFormState(); state.draft.number = "CO-42"; state.draft.originalScope = "Original duct"; state.draft.proposedScope = "Revised duct"
        for category in ChangeCostCategory.allCases { state.values[category.rawValue] = "0"; state.sources[category.rawValue] = "No cost quote" }
        state.values["labor"] = "100"; state.values["material"] = "-40"
        state.values["Markup percentage"] = "10"; state.sources["Markup percentage"] = "Terms"; state.draft.markupBasis = .positiveAdditionsOnly
        state.values["Tax delta"] = "2"; state.sources["Tax delta"] = "Tax basis"
        state.values["Bond delta"] = "1"; state.sources["Bond delta"] = "Bond basis"
        var q = ChangeQuantityInput(); q.name = "Duct"; q.unit = "LF"; q.original = "100"; q.originalSource = "M1"; q.proposed = "70"; q.proposedSource = "M2"; state.quantities = [q]
        let before = state, draft = try state.resolvedDraft()
        XCTAssertEqual(try draft.review().totalDelta, 73); XCTAssertEqual(draft.quantities[0].delta, -30); XCTAssertEqual(state, before)
        state.values["equipment"] = "bad"; XCTAssertThrowsError(try state.resolvedDraft()); XCTAssertEqual(state.values["equipment"], "bad")
    }
}
