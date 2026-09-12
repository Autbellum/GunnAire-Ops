import XCTest
import LoadSightKit
@testable import LoadSightUI

final class CatalogSnapshotComparisonTests: XCTestCase {
    private let id = UUID(uuidString: "30000000-0000-4000-8000-000000000001")!
    private func record(cost: Double? = 50, source: String = "Account A", name: String = "Duct", date: String = "2026-09-10T12:00:00Z", otherID: UUID? = nil) -> OpsMaterialCatalogSnapshot {
        .init(id: otherID ?? id, source: source, name: name, sku: "SKU", supplier: "Supplier", supplierPartNumber: "Part", purchaseCost: cost, updatedAt: date)
    }
    func testUserSelectionResetsEvidenceIncludingReturnFromNoSelection() {
        var form = CatalogMappingForm()
        form.selection = 0; form.purchaseUnit = "box"; form.factor = "0.1"; form.basis = "Prior basis"; form.confirmsUSD = true
        form.author = "Recorder"; form.reason = "Review selection"
        form.select(1)
        XCTAssertFalse(form.confirmsUSD); XCTAssertEqual(form.factor, ""); XCTAssertEqual(form.purchaseUnit, ""); XCTAssertEqual(form.basis, "")
        XCTAssertEqual(form.author, "Recorder"); XCTAssertEqual(form.reason, "Review selection")
        form.select(-1); form.confirmsUSD = true; form.factor = "10"; form.select(0)
        XCTAssertFalse(form.confirmsUSD); XCTAssertEqual(form.factor, "")
        form.factor = "0.2"; form.select(0); XCTAssertEqual(form.factor, "0.2")
    }
    func testExactSnapshotAndEquivalentTimestampDoNotSuggestChanges() throws {
        let saved = record()
        let same = try CatalogSnapshotComparison.compare(saved: saved, available: [saved])
        XCTAssertEqual(same.status, .unchanged); XCTAssertTrue(same.differences.isEmpty); XCTAssertEqual(same.purchaseCostDelta, 0)
        let zone = try CatalogSnapshotComparison.compare(saved: saved, available: [record(date: "2026-09-10T08:00:00-04:00")])
        XCTAssertEqual(zone.status, .unchanged)
    }
    func testChangedFieldsAndKnownCostDeltaAreExplicit() throws {
        let result = try CatalogSnapshotComparison.compare(saved: record(), available: [record(cost: 75, name: "New duct", date: "2026-09-11T12:00:00Z")])
        XCTAssertEqual(result.status, .changed); XCTAssertEqual(result.purchaseCostDelta, 25)
        XCTAssertEqual(Set(result.differences.map(\.field)), Set(["Name", "Purchase cost amount", "Catalog timestamp"]))
        XCTAssertEqual(result.candidate?.purchaseCost, 75)
    }
    func testUnknownAndZeroHaveDifferentDifferencesAndNoInventedDelta() throws {
        let result = try CatalogSnapshotComparison.compare(saved: record(cost: nil), available: [record(cost: 0)])
        XCTAssertEqual(result.status, .changed); XCTAssertNil(result.purchaseCostDelta)
        XCTAssertEqual(result.differences.first?.saved, .null); XCTAssertEqual(result.differences.first?.available, .number(0))
        let unknown = try CatalogSnapshotComparison.compare(saved: record(cost: 0), available: [record(cost: nil)])
        XCTAssertNil(unknown.purchaseCostDelta); XCTAssertEqual(unknown.differences.first?.available, .null)
    }
    func testMissingDifferentSourceAndAmbiguityNeverSelectCandidate() throws {
        let saved = record()
        for (available, status) in [([], CatalogComparisonStatus.missing), ([record(otherID: UUID())], .missing), ([record(source: "Account B")], .differentSource), ([saved, saved], .ambiguous)] {
            let result = try CatalogSnapshotComparison.compare(saved: saved, available: available)
            XCTAssertEqual(result.status, status); XCTAssertNil(result.candidate); XCTAssertTrue(result.differences.isEmpty)
        }
        let result = try CatalogSnapshotComparison.compare(saved: saved, available: [record(source: "Account B"), saved])
        XCTAssertEqual(result.status, .unchanged)
    }
    func testOlderSourceIsReportedEvenWhenCostChanges() throws {
        let result = try CatalogSnapshotComparison.compare(saved: record(), available: [record(cost: 40, date: "2026-09-09T12:00:00Z")])
        XCTAssertEqual(result.status, .olderSource); XCTAssertEqual(result.purchaseCostDelta, -10)
    }
    func testComparisonPreservesSavedProjectAndRejectsInvalidInputs() throws {
        var p = try LoadSightTests().readyProject()
        let mapping = CatalogMaterialMapping(catalog: record(), currency: "USD", purchaseUnit: "length", catalogUnitsPerTakeoffUnit: 0.2, takeoffUnit: "LF", itemDescription: "Duct", lifecycle: "", basis: "Synthetic conversion")
        try p.updateCatalogMaterialMapping(itemID: "D1", mapping: mapping, expectedFingerprint: p.catalogMaterialEditFingerprint(itemID: "D1"), author: "Recorder", reason: "Initial selection")
        let before = try p.data(), token = try p.catalogMaterialEditFingerprint(itemID: "D1")
        _ = try CatalogSnapshotComparison.compare(saved: mapping.catalog, available: [record(cost: 75)])
        XCTAssertEqual(try p.data(), before); XCTAssertEqual(try p.catalogMaterialEditFingerprint(itemID: "D1"), token)
        XCTAssertThrowsError(try CatalogSnapshotComparison.compare(saved: record(), available: [record(cost: -1)]))
        XCTAssertThrowsError(try CatalogSnapshotComparison.compare(saved: record(date: "bad"), available: []))
    }
}
