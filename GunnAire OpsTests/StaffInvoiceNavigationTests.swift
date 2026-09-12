import Foundation
import SwiftData
import XCTest
@testable import GunnAire_Ops

@MainActor final class StaffInvoiceNavigationTests: XCTestCase {
    typealias Fixture = StaffWorkspaceOpenSessionTests.Fixture
    func testInvoiceComposerSurvivesSuccessorHostWithItsOriginalDraft() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let receive = f.controller(); await f.refresh(receive)
        let initial = try XCTUnwrap(receive.authorizedPresentation), host = initial.workspace.hosted
        let invoice = try XCTUnwrap(host.plan.records.first { $0.kind == "invoice" })
        let route = StaffWorkspaceRecordRoute(kind: "invoice", id: invoice.id)
        let navigation = StaffWorkspaceNavigationController(); navigation.update(initial)
        navigation.selected = .invoices; navigation.path = [route]
        navigation.beginInvoice(hosted: host, route: route, receive: receive, store: f.store)
        let session = try XCTUnwrap(navigation.invoiceEditor), editor = session.controller
        editor.change { $0.mode = "new"; $0.name = "Field capacitor"; $0.price = "125"; $0.reason = "Repair request" }
        XCTAssertTrue(editor.canStage); let draft = try XCTUnwrap(editor.draft)
        try f.advance(); await f.refresh(receive); navigation.update(receive.authorizedPresentation)
        XCTAssertEqual(navigation.invoiceEditor?.id, session.id)
        XCTAssertTrue(navigation.invoiceEditor?.controller === editor)
        XCTAssertEqual(editor.draft, draft); XCTAssertTrue(editor.needsReview); XCTAssertFalse(editor.canStage)
        XCTAssertEqual(navigation.path, [route]); XCTAssertEqual(navigation.selected, .invoices)
        let current = try XCTUnwrap(editor.source)
        editor.useCurrentInvoice(reviewed: current)
        XCTAssertTrue(editor.canStage)
        XCTAssertEqual(editor.draft?.name, draft.name)
        XCTAssertEqual(editor.draft?.newItemID, draft.newItemID)
        XCTAssertEqual(editor.draft?.origin, current.origin)
    }
    func testInvoiceAndFieldEditorAreMutuallyExclusiveAndAccountLossClearsOnlyDisplay() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let receive = f.controller(); await f.refresh(receive)
        let host = try XCTUnwrap(receive.hostedStore)
        let invoice = try XCTUnwrap(host.plan.records.first { $0.kind == "invoice" })
        let navigation = StaffWorkspaceNavigationController(); navigation.update(receive.authorizedPresentation)
        navigation.beginInvoice(hosted: host, route: .init(kind: "invoice", id: invoice.id), receive: receive, store: f.store)
        let original = try XCTUnwrap(navigation.invoiceEditor)
        let job = try XCTUnwrap(host.container.mainContext.fetch(FetchDescriptor<StaffWorkspaceOperationalProjectionRecord>()).first { $0.kind == "job" })
        navigation.beginEditing(hosted: host, row: job, field: "notes", receive: receive, coordinator: f.engine)
        XCTAssertNil(navigation.editor); XCTAssertEqual(navigation.invoiceEditor?.id, original.id)
        original.controller.change { $0.name = "Saved before account loss" }
        let saved = f.saved; f.allowed = false; navigation.update(receive.authorizedPresentation)
        XCTAssertNil(navigation.invoiceEditor); XCTAssertFalse(original.controller.available)
        XCTAssertNil(original.controller.draft); XCTAssertEqual(f.saved, saved)
    }
    func testLiveStageRejectsLocallyMutatedProjectionEvenAfterChoicesWereCached() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let receive = f.controller(); await f.refresh(receive)
        let host = try XCTUnwrap(receive.hostedStore), invoice = try XCTUnwrap(host.plan.records.first { $0.kind == "invoice" })
        let client = try StaffInvoiceClient(dependencies: .live(hosted: host, invoice: invoice.id, receive: receive, store: f.store))
        var draft = StaffInvoiceRequestTests().draft(try client.source().origin)
        draft.equipmentID = nil
        let saved = try client.draft(draft, expected: nil)
        let row = try XCTUnwrap(host.container.mainContext.fetch(FetchDescriptor<StaffWorkspaceOperationalProjectionRecord>()).first { $0.kind == "invoice" })
        row.revision += 1; try host.container.mainContext.save()
        XCTAssertThrowsError(try client.stage(expected: saved))
        XCTAssertTrue(try client.load()?.entries.isEmpty == true)
    }
    func testSourceFiltersArchivedCatalogAndFinalizedInvoiceWithoutInventingDefaults() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let receive = f.controller(); await f.refresh(receive)
        let host = try XCTUnwrap(receive.hostedStore), plan = host.plan
        let invoice = try XCTUnwrap(plan.records.first { $0.kind == "invoice" })
        let original = try StaffInvoiceSource.make(plan: plan, invoiceID: invoice.id)
        XCTAssertTrue(original.editable); XCTAssertFalse(original.catalog.isEmpty)
        var records = plan.records
        for index in records.indices {
            let record = records[index]
            if record.kind == "item", case .operational(let partition) = record.body {
                var fields = partition.fields; fields["pricebookReviewStatusRawValue"] = .text("archived")
                records[index] = .init(kind: record.kind, id: record.id, revision: record.revision, unavailableLinks: record.unavailableLinks,
                    body: .operational(.init(fields: fields, unavailableFields: partition.unavailableFields, structuredFields: partition.structuredFields)))
            } else if record.kind == "invoice", case .billing(let doc) = record.body {
                var fields = doc.fields; fields["finalizedAt"] = .date(f.currentTime)
                records[index] = .init(kind: record.kind, id: record.id, revision: record.revision, unavailableLinks: record.unavailableLinks,
                    body: .billing(.init(kind: doc.kind, id: doc.id, fields: fields, unavailableFields: doc.unavailableFields, catalog: doc.catalog)))
            }
        }
        let changed = StaffWorkspaceOperationalImportPlan(schema: plan.schema, selectionID: plan.selectionID, contentSHA256: plan.contentSHA256,
            sourceSequence: plan.sourceSequence, companyID: plan.companyID, environment: plan.environment, replicaID: plan.replicaID,
            memberRole: plan.memberRole, records: records, operationalWorkspaceReady: plan.operationalWorkspaceReady)
        let filtered = try StaffInvoiceSource.make(plan: changed, invoiceID: invoice.id)
        XCTAssertFalse(filtered.editable); XCTAssertTrue(filtered.catalog.isEmpty)
    }
}
