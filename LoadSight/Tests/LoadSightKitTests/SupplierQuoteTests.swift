import XCTest
import LoadSightKit
@testable import LoadSightUI

final class SupplierQuoteTests: XCTestCase {
    private func quote(end: String? = "2026-09-11T12:00:00Z", source: String = "Synthetic quote.pdf page 1") -> SupplierQuoteEvidence {
        .init(supplier: "Synthetic supplier", reference: "Q-100", source: source, issuedAt: "2026-09-10T12:00:00Z", validUntil: end, conditions: "Synthetic only; 5-foot lengths; freight excluded; availability unconfirmed")
    }
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func mapping(_ quote: SupplierQuoteEvidence?) -> CatalogMaterialMapping {
        .init(catalog: .init(id: UUID(uuidString: "30000000-0000-4000-8000-000000000001")!, source: "Synthetic catalog", name: "Duct", purchaseCost: 50, updatedAt: "2026-09-10T12:00:00Z"), currency: "USD", purchaseUnit: "5-foot length", catalogUnitsPerTakeoffUnit: 0.2, takeoffUnit: "LF", itemDescription: "Duct", lifecycle: "", basis: "Synthetic unit confirmation", quote: quote)
    }
    func testTimeBoundariesAndUnknownExpiry() throws {
        XCTAssertEqual(try quote().review(asOf: date("2026-09-10T11:59:59Z")).status, .notYetIssued)
        XCTAssertEqual(try quote().review(asOf: date("2026-09-10T12:00:00Z")).status, .withinRecordedPeriod)
        XCTAssertEqual(try quote().review(asOf: date("2026-09-11T11:59:59Z")).status, .withinRecordedPeriod)
        XCTAssertEqual(try quote().review(asOf: date("2026-09-11T08:00:00-04:00")).status, .expired)
        XCTAssertEqual(try quote(end: nil).review(asOf: date("2026-09-12T12:00:00Z")).status, .expiryUnknown)
        XCTAssertThrowsError(try quote(end: "2026-09-10T12:00:00Z").validate())
        XCTAssertThrowsError(try quote(end: "2026-09-10").validate())
        XCTAssertThrowsError(try quote(source: " ").validate())
        XCTAssertThrowsError(try quote().review(asOf: Date(timeIntervalSince1970: .infinity)))
    }
    func testExpiryChangesReviewWithoutEditingPriceOrHistory() throws {
        var p = try LoadSightTests().readyProject()
        try p.updateCatalogMaterialMapping(itemID: "D1", mapping: mapping(quote()), expectedFingerprint: p.catalogMaterialEditFingerprint(itemID: "D1"), author: "Recorder", reason: "Quote evidence")
        let data = try p.data()
        let before = try EstimatePricing.review(p, asOf: date("2026-09-10T13:00:00Z"))
        let after = try EstimatePricing.review(p, asOf: date("2026-09-11T12:00:00Z"))
        XCTAssertFalse(before.blockers.contains { $0.contains("Supplier quote") })
        XCTAssertTrue(after.blockers.contains { $0.contains("Supplier quote for D1") && $0.contains("expired") })
        XCTAssertNil(after.releasableSellingPrice)
        XCTAssertEqual(before.knownDirectCost, after.knownDirectCost)
        XCTAssertEqual(try p.data(), data)
        let restored = try ProjectDocument(data: data)
        XCTAssertEqual(try restored.catalogMaterialMapping(itemID: "D1")?.quote, quote())
        XCTAssertEqual(try restored.catalogMaterialHistory().last?.after["quote"]["reference"], .string("Q-100"))
    }
    func testPluginQuoteFieldsRoundTripAndTypoFailsAtomically() throws {
        let p = try LoadSightTests().readyProject(); let original = try p.data()
        var raw = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(mapping(quote(end: nil)))).object!
        var request: [String: JSONValue] = ["operation": .string("catalog.material.update"), "id": .string("D1"), "author": .string("Recorder"), "reason": .string("Quote"), "expectedFingerprint": .string(try p.catalogMaterialEditFingerprint(itemID: "D1")), "mapping": .object(raw)]
        let result = try ProjectEditing.apply(.object(request), to: p)
        XCTAssertEqual(try result.project.catalogMaterialMapping(itemID: "D1")?.quote, quote(end: nil))
        XCTAssertNotNil(raw["quote"]?.object?["validUntil"])
        var q = raw["quote"]!.object!; q["validUntill"] = .string("2026-10-01T00:00:00Z"); raw["quote"] = .object(q); request["mapping"] = .object(raw)
        XCTAssertThrowsError(try ProjectEditing.apply(.object(request), to: p))
        XCTAssertEqual(try p.data(), original)
    }
    func testLegacyMappingAndFormSelectionDoNotInventOrReuseQuotes() throws {
        let data = try JSONEncoder().encode(mapping(nil))
        XCTAssertNil(try JSONDecoder().decode(CatalogMaterialMapping.self, from: data).quote)
        var form = CatalogMappingForm(); XCTAssertNil(try form.quoteEvidence())
        form.recordsQuote = true; form.quoteSupplier = "Supplier"; form.quoteReference = "Q1"
        form.quoteSource = "Source"; form.quoteIssuedAt = "2026-09-10T12:00:00Z"; form.quoteConditions = "Conditions"
        XCTAssertNil(try form.quoteEvidence()?.validUntil)
        form.select(1)
        XCTAssertFalse(form.recordsQuote); XCTAssertEqual(form.quoteReference, ""); XCTAssertNil(try form.quoteEvidence())
    }
}
