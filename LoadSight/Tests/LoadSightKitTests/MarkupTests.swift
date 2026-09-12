import XCTest
import LoadSightKit
import LoadSightUI

@MainActor
final class MarkupTests: XCTestCase {
    let descriptor = TakeoffDescriptor(label: "Supply duct", lifecycle: .new, system: "Supply air", size: "12 inch round")
    func view(pageID: String = "source:1", checked: Bool = true, checkFeet: Double = 20) -> CalibratedView {
        .init(id: "view", pageID: pageID, name: "Main", min: .init(x: 0,y: 0), max: .init(x: 500,y: 500),
              dimension: .init(points: [.init(x: 10,y: 10),.init(x: 110,y: 10)], feet: 10, source: "Known dimension A"),
              check: checked ? .init(points: [.init(x: 10,y: 10),.init(x: 10,y: 210)], feet: checkFeet, source: "Known dimension B") : nil, author: "Estimator")
    }
    func testRepeatedViewCountsOnePhysicalItemAndUndoRetainsEvidence() throws {
        var ledger = MarkupLedger()
        try ledger.count(id: "device", descriptor: descriptor, anchor: .init(pageID: "source:1", point: .init(x: 20,y: 30), author: "A"))
        try ledger.count(id: "device", descriptor: descriptor, anchor: .init(pageID: "source:2", point: .init(x: 40,y: 50), author: "B"))
        XCTAssertEqual(ledger.objects.count,1); XCTAssertEqual(ledger.objects[0].anchors.count,2)
        XCTAssertEqual(try ledger.takeoffRows()[0]["quantity"], .number(1))
        try ledger.undoLast(author: "B")
        XCTAssertEqual(ledger.objects[0].anchors.count,1)
        XCTAssertEqual(ledger.history.count,3)
        XCTAssertEqual(ledger.history.last?.evidence["anchors"].array?.count,2)
        try ledger.undoLast(author: "A")
        XCTAssertTrue(ledger.objects.isEmpty); XCTAssertNil(ledger.lastUndoableAction)
        XCTAssertEqual(ledger.history.count,4)
    }
    func testRepeatedObjectCannotChangeLifecycleOrDuplicateAnchor() throws {
        var ledger = MarkupLedger()
        let anchor = DrawingAnchor(pageID: "source:1", point: .init(x: 20,y: 30), author: "A")
        try ledger.count(id: "device", descriptor: descriptor, anchor: anchor)
        XCTAssertThrowsError(try ledger.count(id: "device", descriptor: descriptor, anchor: anchor))
        var reused = descriptor; reused.lifecycle = .reuse
        XCTAssertThrowsError(try ledger.count(id: "device", descriptor: reused, anchor: .init(pageID: "source:2", point: .init(x: 20,y: 30), author: "A")))
        XCTAssertEqual(ledger.objects[0].anchors.count,1)
    }
    func testRouteUsesCalibratedPolylineAndKeepsDraftStatus() throws {
        var ledger = MarkupLedger(); try ledger.addView(view())
        try ledger.measure(id: "route", viewID: "view", descriptor: descriptor, points: [.init(x: 10,y: 10),.init(x: 40,y: 50),.init(x: 70,y: 50)], author: "Estimator")
        XCTAssertEqual(try ledger.length(of: ledger.routes[0]),8)
        let row = try ledger.takeoffRows()[0]
        XCTAssertEqual(row["quantity"], .number(8)); XCTAssertEqual(row["unit"], .string("LF"))
        XCTAssertEqual(row["quantityStatus"], .string("Measured-draft")); XCTAssertEqual(row["materialUnit"], .null)
        let restored = try MarkupLedger(json: ledger.json())
        XCTAssertEqual(try restored.length(of: restored.routes[0]),8)
        XCTAssertEqual(restored.history.count,2)
    }
    func testRouteRejectsUncheckedInaccurateAndCrossViewMeasurements() throws {
        for checked in [false,true] {
            var ledger = MarkupLedger(); try ledger.addView(view(checked: checked,checkFeet: 30))
            XCTAssertThrowsError(try ledger.measure(viewID: "view", descriptor: descriptor, points: [.init(x: 10,y: 10),.init(x: 40,y: 50)], author: "A"))
            XCTAssertTrue(ledger.routes.isEmpty)
        }
        var ledger = MarkupLedger(); try ledger.addView(view())
        XCTAssertThrowsError(try ledger.measure(viewID: "view", descriptor: descriptor, points: [.init(x: 10,y: 10),.init(x: 501,y: 50)], author: "A"))
    }
    func testIndependentCheckCannotReuseCalibrationDimension() throws {
        var ledger = MarkupLedger(); let region = view(checked: false); try ledger.addView(region)
        XCTAssertThrowsError(try ledger.checkView(id: region.id, dimension: region.dimension, author: "Checker"))
        XCTAssertNil(ledger.views[0].check)
        let check = view().check!
        XCTAssertThrowsError(try ledger.checkView(id: region.id, dimension: check, author: " "))
        try ledger.checkView(id: region.id, dimension: check, author: "Checker")
        XCTAssertEqual(ledger.history.last?.author, "Checker")
        XCTAssertEqual(ledger.views[0].author, "Estimator")
    }
    func testDerivedQuantityCannotBeOverriddenAndPricingDetectsTampering() throws {
        var document = LoadSightDocument()
        var ledger = MarkupLedger(); try ledger.addView(view())
        try ledger.measure(id: "route", viewID: "view", descriptor: descriptor, points: [.init(x: 10,y: 10),.init(x: 40,y: 50)], author: "A")
        try document.project.applyMarkup(ledger)
        XCTAssertThrowsError(try document.project.updateItem(id: "markup-route", fields: ["quantity": .number(999)]))
        try document.project.updateItem(id: "markup-route", fields: ["materialUnit": .number(12)])
        XCTAssertEqual(document.project.items[0]["quantity"], .number(5))
        var row = document.project.items[0]; row["quantity"] = .number(999)
        try document.project.replace("items", with: .array([.object(row)]))
        XCTAssertThrowsError(try EstimatePricing.review(document.project))
    }
    func testUndoRouteRemovesDerivedLineAndReopensQA() throws {
        var document = LoadSightDocument(); var ledger = MarkupLedger(); try ledger.addView(view())
        try ledger.measure(id: "route", viewID: "view", descriptor: descriptor, points: [.init(x: 10,y: 10),.init(x: 40,y: 50)], author: "A")
        try document.project.applyMarkup(ledger)
        try ledger.undoLast(author: "A"); try document.project.applyMarkup(ledger)
        XCTAssertTrue(document.project.items.isEmpty)
        XCTAssertTrue(document.project.root["qa"].array!.allSatisfy { $0["status"].string == "Open" })
        XCTAssertEqual(try document.project.markupLedger().history.last?.kind,"undo")
    }
    func testDocumentValidatesSourcePageAndPersistsMarkup() async throws {
        let url = Bundle.module.url(forResource: "DrawingIntake", withExtension: "pdf", subdirectory: "Fixtures")!
        var document = LoadSightDocument(); try document.addDrawings(await DrawingIngestor().ingest(url: url,ocr: .disabled))
        let pageID = document.drawings.records[0].pages[0].id
        var ledger = MarkupLedger(); try ledger.addView(view(pageID: pageID))
        try ledger.measure(id: "route", viewID: "view", descriptor: descriptor, points: [.init(x: 10,y: 10),.init(x: 40,y: 50)], author: "A")
        try document.applyMarkup(ledger)
        for package in [true,false] {
            let restored = try LoadSightDocument(wrapper: document.wrapper(asPackage: package))
            XCTAssertEqual(restored.project.items,document.project.items)
            XCTAssertEqual(try restored.project.markupLedger().routes.count,1)
        }
        let before = document.project.root
        try ledger.count(descriptor: descriptor,anchor: .init(pageID: "missing:1",point: .init(x: 30,y: 30),author: "A"))
        XCTAssertThrowsError(try document.applyMarkup(ledger))
        XCTAssertEqual(document.project.root,before)
    }
}
