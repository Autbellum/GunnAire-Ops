import Foundation
import XCTest
import SwiftData
@testable import GunnAire_Ops

@MainActor final class StaffWorkspaceNavigationContinuityTests: XCTestCase {
    typealias Fixture = StaffWorkspaceOpenSessionTests.Fixture

    func testLiveEditorKeepsOriginalDraftAndReviewsNewHost() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let receive = f.controller(); await f.refresh(receive)
        let hosted = try XCTUnwrap(receive.hostedStore)
        let job = try XCTUnwrap(hosted.plan.records.first { $0.kind == "job" })
        let editor = StaffWorkspaceFieldEditorController(dependencies: .live(hosted: hosted,
            kind: job.kind, recordID: job.id, revision: job.revision, field: "notes", receive: receive, coordinator: f.engine))
        editor.open(); editor.setText("Technician finding retained across refresh")
        let original = try XCTUnwrap(editor.draft)
        XCTAssertFalse(editor.hasUnprotectedChanges)
        try f.advance(); await f.refresh(receive)
        XCTAssertFalse(receive.hostedStore === hosted)
        editor.checkLifetime(forceRefresh: true)
        XCTAssertEqual(editor.draft, original)
        XCTAssertEqual(editor.input.text, original.input?.text)
        XCTAssertTrue(editor.available)
        XCTAssertTrue(editor.needsReview)
        XCTAssertFalse(editor.canSave)
        XCTAssertEqual(editor.currentSnapshot?.sourceSequence, f.receipt.sourceSequence)
    }

    func jobRow(_ hosted: StaffWorkspaceOperationalHostedStore) throws -> StaffWorkspaceOperationalProjectionRecord {
        try XCTUnwrap(hosted.container.mainContext.fetch(FetchDescriptor<StaffWorkspaceOperationalProjectionRecord>()).first { $0.kind == "job" })
    }

    func testNavigationAndSameEditorSurviveChangedRecordUntilExplicitReview() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let receive = f.controller(); await f.refresh(receive)
        let initial = try XCTUnwrap(receive.authorizedPresentation), hosted = initial.workspace.hosted
        let row = try jobRow(hosted), route = row.navigationRoute
        let navigation = StaffWorkspaceNavigationController(); navigation.update(initial)
        navigation.selected = .scheduleAndJobs; navigation.path = [route]
        navigation.beginEditing(hosted: hosted, row: row, field: "notes", receive: receive, coordinator: f.engine)
        let session = try XCTUnwrap(navigation.editor), editor = session.controller
        editor.setText("Technician original finding")
        let draft = try XCTUnwrap(editor.draft)
        try f.advance(jobNotes: "Office changed the finding")
        await f.refresh(receive); navigation.update(receive.authorizedPresentation)
        XCTAssertEqual(navigation.selected, .scheduleAndJobs); XCTAssertEqual(navigation.path, [route])
        XCTAssertEqual(navigation.editor?.id, session.id); XCTAssertTrue(navigation.editor?.controller === editor)
        XCTAssertEqual(editor.draft, draft); XCTAssertTrue(editor.needsReview); XCTAssertFalse(editor.canSave)
        let current = try XCTUnwrap(editor.currentSnapshot)
        XCTAssertEqual(current.candidate.revision, row.revision + 1)
        XCTAssertEqual(current.candidate.currentValue, .text("Office changed the finding"))
        let saved = f.saved; await editor.save(); XCTAssertEqual(f.saved, saved)
        editor.useDraftWithCurrentRecord(reviewed: current)
        XCTAssertTrue(editor.canSave); XCTAssertFalse(editor.needsReview)
        XCTAssertNotEqual(editor.draft?.commandID, draft.commandID)
        XCTAssertEqual(editor.input.text, "Technician original finding")
        XCTAssertEqual(editor.snapshot, current)
        XCTAssertThrowsError(try receive.fieldEditingAuthority(for: hosted), "Old store itself is still unauthorized")
        let newRow = try jobRow(try XCTUnwrap(receive.hostedStore))
        XCTAssertEqual(newRow.navigationRoute, route); XCTAssertEqual(newRow.revision, current.candidate.revision)
        XCTAssertTrue(newRow !== row)
    }

    func testTypingDuringSuspendedRefreshIsKeptAndPersistedAfterSuccess() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let receive = f.controller(); await f.refresh(receive)
        let hosted = try XCTUnwrap(receive.hostedStore), row = try jobRow(hosted)
        let navigation = StaffWorkspaceNavigationController(); navigation.update(receive.authorizedPresentation)
        navigation.beginEditing(hosted: hosted, row: row, field: "notes", receive: receive, coordinator: f.engine)
        let editor = try XCTUnwrap(navigation.editor?.controller)
        editor.setText("Before refresh"); let original = try XCTUnwrap(editor.draft)
        try f.advance(jobNotes: "New office note")
        let entered = expectation(description: "Workspace refresh suspended")
        var release: CheckedContinuation<Void, Never>?
        f.serverWait = { await withCheckedContinuation { release = $0; entered.fulfill() } }
        let refresh = Task { await f.refresh(receive) }
        await fulfillment(of: [entered], timeout: 5)
        editor.setText("Typed while shared data was refreshing")
        XCTAssertTrue(editor.hasUnprotectedChanges); XCTAssertEqual(editor.draft, original)
        release?.resume(); release = nil; await refresh.value
        f.serverWait = nil; navigation.update(receive.authorizedPresentation)
        XCTAssertTrue(navigation.editor?.controller === editor)
        XCTAssertEqual(editor.input.text, "Typed while shared data was refreshing")
        XCTAssertFalse(editor.hasUnprotectedChanges)
        XCTAssertEqual(editor.draft?.snapshot, original.snapshot)
        XCTAssertEqual(editor.draft?.commandID, original.commandID)
        XCTAssertTrue(editor.needsReview); XCTAssertFalse(editor.canSave)
    }

    func testRevokedDeviceOrAccountClearsRoutesAndEditorButKeepsSavedDraft() async throws {
        for changedDevice in [false, true] {
            let f = try Fixture(); defer { f.cleanup() }
            let receive = f.controller(); await f.refresh(receive)
            let hosted = try XCTUnwrap(receive.hostedStore), row = try jobRow(hosted)
            let navigation = StaffWorkspaceNavigationController(); navigation.update(receive.authorizedPresentation)
            navigation.path = [row.navigationRoute]
            navigation.beginEditing(hosted: hosted, row: row, field: "notes", receive: receive, coordinator: f.engine)
            let editor = try XCTUnwrap(navigation.editor?.controller)
            editor.setText("Private saved finding"); let saved = f.saved
            if changedDevice { f.device = String(repeating: "d", count: 64) } else { f.allowed = false }
            navigation.update(receive.authorizedPresentation)
            XCTAssertNil(navigation.editor); XCTAssertTrue(navigation.path.isEmpty)
            XCTAssertEqual(editor.input.text, ""); XCTAssertNil(editor.snapshot)
            XCTAssertEqual(f.saved, saved)
        }
    }

    func testReauthenticatedSessionDoesNotInheritAnotherSessionsNavigation() async throws {
        let first = try Fixture(), second = try Fixture(); defer { first.cleanup(); second.cleanup() }
        let receive1 = first.controller(), receive2 = second.controller()
        await first.refresh(receive1); await second.refresh(receive2)
        let navigation = StaffWorkspaceNavigationController(); navigation.update(receive1.authorizedPresentation)
        let row = try jobRow(try XCTUnwrap(receive1.hostedStore))
        navigation.selected = .scheduleAndJobs; navigation.path = [row.navigationRoute]
        navigation.update(receive2.authorizedPresentation)
        XCTAssertEqual(navigation.selected, .overview); XCTAssertTrue(navigation.path.isEmpty)
    }

    func testCompoundRoutesDoNotCollideAndMissingRouteRecoversToItsList() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let receive = f.controller(); await f.refresh(receive)
        let p = try XCTUnwrap(receive.authorizedPresentation), row = try jobRow(p.workspace.hosted)
        let job = row.navigationRoute, otherKind = StaffWorkspaceRecordRoute(kind: "customer", id: row.recordID)
        XCTAssertEqual(Set([job, otherKind]).count, 2)
        XCTAssertFalse(otherKind.exists(in: p.workspace.hosted))
        XCTAssertFalse(StaffWorkspaceRecordRoute(kind: "job", id: "../bad").exists(in: p.workspace.hosted))
        let navigation = StaffWorkspaceNavigationController(); navigation.update(p)
        navigation.selected = .scheduleAndJobs; navigation.path = [otherKind]
        navigation.update(p)
        XCTAssertTrue(navigation.path.isEmpty); XCTAssertEqual(navigation.selected, .scheduleAndJobs)
        XCTAssertNotNil(navigation.notice)
        navigation.path = [job]; navigation.selected = .customers
        XCTAssertTrue(navigation.path.isEmpty); XCTAssertNil(navigation.notice)
    }

    func testStaleRowsAndRestrictedFieldsCannotOpenOrReplaceEditor() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let receive = f.controller(); await f.refresh(receive)
        let hosted = try XCTUnwrap(receive.hostedStore), row = try jobRow(hosted)
        let navigation = StaffWorkspaceNavigationController(); navigation.update(receive.authorizedPresentation)
        for field in ["status", "customer", "serviceReportReadingsJSON", "invoiceItemsJSON"] {
            navigation.beginEditing(hosted: hosted, row: row, field: field, receive: receive, coordinator: f.engine)
            XCTAssertNil(navigation.editor)
        }
        try f.advance(); await f.refresh(receive); navigation.update(receive.authorizedPresentation)
        let saved = f.saved
        navigation.beginEditing(hosted: hosted, row: row, field: "notes", receive: receive, coordinator: f.engine)
        XCTAssertNil(navigation.editor); XCTAssertEqual(f.saved, saved)
        let current = try XCTUnwrap(receive.hostedStore), currentRow = try jobRow(current)
        navigation.beginEditing(hosted: current, row: currentRow, field: "notes", receive: receive, coordinator: f.engine)
        let session = try XCTUnwrap(navigation.editor)
        session.controller.setText("Open draft must stay")
        navigation.beginEditing(hosted: current, row: currentRow, field: "findingsSummary", receive: receive, coordinator: f.engine)
        XCTAssertEqual(navigation.editor?.id, session.id)
        XCTAssertEqual(navigation.editor?.controller.input.text, "Open draft must stay")
    }
}
