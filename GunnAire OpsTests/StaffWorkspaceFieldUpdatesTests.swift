import Foundation
import XCTest
@testable import GunnAire_Ops

@MainActor final class StaffWorkspaceFieldUpdatesTests: XCTestCase {
    typealias Fixture = StaffWorkspaceCommandRecoveryTests.Fixture
    func page(_ f: Fixture, state: String = "awaitingOffice", decided: String = "") -> StaffWorkspaceFieldUpdatesPage {
        .init(schema: StaffWorkspaceFieldUpdatesPage.schema, companyID: f.request.companyID,
              environment: f.request.environment, replicaID: f.request.replicaID, shareID: f.plan.id.uuidString.lowercased(),
              entries: [.init(request: f.request, receipt: f.receipt(), state: state, decidedAt: decided)], nextCursor: "")
    }
    func modified<T: Codable>(_ value: T, _ changes: [String: Any], as type: T.Type = T.self) throws -> T {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: StaffWorkspacePublicationContract.encode(value)) as? [String: Any])
        for (key, value) in changes { object[key] = value }
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func coordinator(_ f: Fixture, response: @escaping () async throws -> StaffWorkspaceFieldUpdatesPage) -> StaffWorkspaceContentCoordinator {
        var d = f.dependencies()
        d.staffFieldUpdatesRequest = { path in
            XCTAssertTrue(StaffWorkspaceFieldUpdatesHTTPPolicy.allows(path: path, method: "GET", body: nil))
            return try StaffWorkspacePublicationContract.encode(await response())
        }
        return .init(dependencies: d)
    }

    func testWaitingIsNotAppliedAndDecisionsKeepOriginalReceipt() throws {
        let f = try Fixture(); defer { f.cleanup() }
        for state in ["awaitingOffice", "appliedToOffice", "keptOffice"] {
            let p = page(f, state: state, decided: state == "awaitingOffice" ? "" : "2026-09-10T08:01:00Z")
            try p.validate(scope: f.context.scope, plan: f.plan)
            XCTAssertEqual(p.entries[0].receipt, f.receipt())
            XCTAssertEqual(p.entries[0].request, f.request)
            XCTAssertFalse(p.entries[0].receipt.operationalWorkspaceReady)
            XCTAssertFalse(p.entries[0].status.contains("QuickBooks"))
        }
    }
    func testUnknownStatesMissingOrRegressedDecisionTimesAreRejected() throws {
        let f = try Fixture(); defer { f.cleanup() }
        for (state, date) in [("published", ""), ("awaitingOffice", "2026-09-10T08:01:00Z"),
                              ("keptOffice", ""), ("appliedToOffice", "bad"), ("keptOffice", "2026-09-10T07:00:00Z")] {
            XCTAssertThrowsError(try page(f, state: state, decided: date).validate(scope: f.context.scope, plan: f.plan))
        }
    }
    func testScopeAuthorAndOriginalReceiptMismatchesAreRejected() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let p = page(f)
        for key in ["companyID", "replicaID", "shareID", "environment", "schema"] {
            XCTAssertThrowsError(try modified(p, [key: "different"]).validate(scope: f.context.scope, plan: f.plan))
        }
        let entry = StaffWorkspaceFieldUpdate(request: f.request, receipt: f.receipt(actor: "other@example.invalid"), state: "awaitingOffice", decidedAt: "")
        XCTAssertThrowsError(try entry.validate(scope: f.context.scope, plan: f.plan))
        let receipt = try modified(f.receipt(), ["value": ["text": ["_0": "not original"]]])
        XCTAssertThrowsError(try StaffWorkspaceFieldUpdate(request: f.request, receipt: receipt, state: "awaitingOffice", decidedAt: "")
            .validate(scope: f.context.scope, plan: f.plan))
    }
    func testClosedWireRejectsUnknownNullDuplicatesAndOversizedResponses() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let raw = try StaffWorkspacePublicationContract.encode(page(f))
        for prefix in ["\"unexpected\":null,", "\"nextCursor\":\"\","] {
            let invalid = Data(("{" + prefix + String(decoding: raw.dropFirst(), as: UTF8.self)).utf8)
            XCTAssertThrowsError(try StaffWorkspacePublicationContract.decode(StaffWorkspaceFieldUpdatesPage.self, from: invalid))
        }
        let bytes = Data(repeating: 32, count: StaffWorkspaceFieldUpdatesPage.maximumBytes + 1)
        XCTAssertThrowsError(try StaffWorkspacePublicationContract.decode(StaffWorkspaceFieldUpdatesPage.self, from: bytes,
            maximum: StaffWorkspaceFieldUpdatesPage.maximumBytes))
    }
    func testCursorAndPerCommandShapeCannotSkipOrMisbindResults() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let p = page(f)
        try p.validate(scope: f.context.scope, plan: f.plan, commandID: f.request.commandID)
        XCTAssertThrowsError(try p.validate(scope: f.context.scope, plan: f.plan, after: f.request.commandID))
        XCTAssertThrowsError(try p.validate(scope: f.context.scope, plan: f.plan, commandID: UUID().uuidString.lowercased()))
        XCTAssertThrowsError(try modified(p, ["nextCursor": f.request.commandID]).validate(scope: f.context.scope, plan: f.plan))
        let entry = try JSONSerialization.jsonObject(with: StaffWorkspacePublicationContract.encode(p.entries[0]))
        XCTAssertThrowsError(try modified(p, ["entries": [entry, entry]]).validate(scope: f.context.scope, plan: f.plan))
    }
    func testEndpointPolicyRejectsAliasesQueriesWritesAndForeignURLs() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let path = StaffWorkspaceFieldUpdatesHTTPPolicy.path(plan: f.plan, scope: f.context.scope)
        XCTAssertTrue(StaffWorkspaceFieldUpdatesHTTPPolicy.allows(path: path, method: "GET", body: nil))
        for invalid in ["https://foreign.invalid" + path, path + "#secret", path + "&after=", path + "&extra=1",
                        path + "&companyID=" + f.request.companyID, path.replacingOccurrences(of: "field-updates?", with: "field-updates/?")] {
            XCTAssertFalse(StaffWorkspaceFieldUpdatesHTTPPolicy.allows(path: invalid, method: "GET", body: nil), invalid)
        }
        XCTAssertFalse(StaffWorkspaceFieldUpdatesHTTPPolicy.allows(path: path, method: "POST", body: Data()))
        XCTAssertFalse(StaffWorkspaceFieldUpdatesHTTPPolicy.allows(path: path, method: "GET", body: Data()))
        let single = StaffWorkspaceFieldUpdatesHTTPPolicy.path(plan: f.plan, scope: f.context.scope, commandID: f.request.commandID)
        XCTAssertTrue(StaffWorkspaceFieldUpdatesHTTPPolicy.allows(path: single, method: "GET", body: nil))
        XCTAssertFalse(StaffWorkspaceFieldUpdatesHTTPPolicy.allows(path: single + "&after=" + f.request.commandID, method: "GET", body: nil))
    }
    func testDiscoveryWithoutLocalIndexDoesNotRewriteOrInventOriginals() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let p = page(f, state: "keptOffice", decided: "2026-09-10T08:01:00Z")
        let c = coordinator(f) { p }
        let result = try await c.readFieldUpdates(plan: f.plan, context: f.context)
        XCTAssertEqual(result, p)
        XCTAssertTrue(f.memory.saved.isEmpty)
        try f.enqueue()
        let saved = f.memory.saved
        _ = try await c.readFieldUpdates(plan: f.plan, context: f.context)
        XCTAssertEqual(f.memory.saved, saved, "Status is not a replacement command receipt")
    }
    func testKnownOriginalRejectsDifferentReceiptAndPreservesEncryptedEvidence() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.enqueue()
        try StaffWorkspaceOperationalCommandStore.attachReceipt(store: f.memory.store, scope: f.context.scope,
            plan: f.plan.id, request: f.request, receipt: f.receipt())
        let saved = f.memory.saved
        var p = page(f)
        let c = coordinator(f) { p }
        _ = try await c.readFieldUpdates(plan: f.plan, context: f.context)
        let changed = StaffWorkspaceFieldUpdate(request: f.request, receipt: f.receipt(instant: "2026-09-10T08:00:01Z"), state: "awaitingOffice", decidedAt: "")
        p = try modified(p, ["entries": [JSONSerialization.jsonObject(with: StaffWorkspacePublicationContract.encode(changed))]])
        do { _ = try await c.readFieldUpdates(plan: f.plan, context: f.context); XCTFail("Receipt changed") } catch {}
        XCTAssertEqual(f.memory.saved, saved)
    }
    func testRevocationDuringNetworkReadRejectsReplyWithoutTouchingOriginals() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.enqueue(); let saved = f.memory.saved
        let p = page(f)
        let c = coordinator(f) { f.allowed = false; return p }
        do { _ = try await c.readFieldUpdates(plan: f.plan, context: f.context); XCTFail("Revoked reply") } catch {}
        XCTAssertEqual(f.memory.saved, saved)
    }
    func testDisplayClearsOnFailedRefreshAndExpiredSession() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let p = page(f)
        var failed = false, now = f.base.dependencies().now()
        let d = StaffWorkspaceFieldUpdatesDependencies(setup: { (f.context, [f.plan]) }, fetch: { _, _, _ in
            if failed { throw StaffReplicaDeliveryError.access }; return p
        }, stamp: { f.context.stamp }, now: { now })
        let c = StaffWorkspaceFieldUpdatesController(dependencies: d)
        await c.load(scope: f.context.scope, planID: f.plan.id)
        XCTAssertEqual(c.entries, p.entries)
        failed = true
        await c.load(scope: f.context.scope, planID: f.plan.id)
        XCTAssertTrue(c.entries.isEmpty); XCTAssertNil(c.checkedAt)
        failed = false
        await c.load(scope: f.context.scope, planID: f.plan.id)
        XCTAssertFalse(c.entries.isEmpty)
        now = f.context.stamp.session.expiresAt
        c.checkLifetime()
        XCTAssertTrue(c.entries.isEmpty); XCTAssertNil(c.checkedAt)
    }
    func testAccountChangeAndDismissalFenceLateDisplayCompletion() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let p = page(f)
        var stamp: CloudKitStaffSetupStamp? = f.context.stamp
        var controller: StaffWorkspaceFieldUpdatesController!
        let d = StaffWorkspaceFieldUpdatesDependencies(setup: { (f.context, [f.plan]) }, fetch: { _, _, _ in
            controller.clear(); stamp = nil; return p
        }, stamp: { stamp }, now: f.base.dependencies().now)
        controller = .init(dependencies: d)
        await controller.load(scope: f.context.scope, planID: f.plan.id)
        XCTAssertTrue(controller.entries.isEmpty); XCTAssertNil(controller.checkedAt); XCTAssertFalse(controller.isRunning)
    }
    func testWrongWorkspaceCannotReachDisplayFetch() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let d = StaffWorkspaceFieldUpdatesDependencies(setup: { (f.context, [f.plan]) }, fetch: { _, _, _ in
            XCTFail("Wrong plan must not fetch"); return self.page(f)
        }, stamp: { f.context.stamp }, now: f.base.dependencies().now)
        let c = StaffWorkspaceFieldUpdatesController(dependencies: d)
        await c.load(scope: f.context.scope, planID: UUID())
        XCTAssertTrue(c.entries.isEmpty)
    }

    func testNextPageIsBoundedAndRefreshReturnsToFirstPage() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let entries = try (1...9).map { number -> StaffWorkspaceFieldUpdate in
            let id = String(format: "00000000-0000-4000-8000-%012d", number)
            let request = try modified(f.request, ["commandID": id])
            return .init(request: request, receipt: f.receipt(for: request), state: "awaitingOffice", decidedAt: "")
        }
        let base = page(f)
        let first = StaffWorkspaceFieldUpdatesPage(schema: base.schema, companyID: base.companyID, environment: base.environment,
            replicaID: base.replicaID, shareID: base.shareID, entries: Array(entries.prefix(8)), nextCursor: entries[7].id)
        let last = StaffWorkspaceFieldUpdatesPage(schema: base.schema, companyID: base.companyID, environment: base.environment,
            replicaID: base.replicaID, shareID: base.shareID, entries: [entries[8]], nextCursor: "")
        var cursors: [String?] = []
        let d = StaffWorkspaceFieldUpdatesDependencies(setup: { (f.context, [f.plan]) }, fetch: { _, _, after in
            cursors.append(after); return after == nil ? first : last
        }, stamp: { f.context.stamp }, now: f.base.dependencies().now)
        let c = StaffWorkspaceFieldUpdatesController(dependencies: d)
        await c.load(scope: f.context.scope, planID: f.plan.id)
        XCTAssertEqual(c.entries.count, 8)
        await c.load(scope: f.context.scope, planID: f.plan.id, more: true)
        XCTAssertEqual(c.entries, last.entries); XCTAssertTrue(c.nextCursor.isEmpty)
        await c.load(scope: f.context.scope, planID: f.plan.id, more: true)
        XCTAssertEqual(cursors.count, 2, "No duplicate fetch after final page")
        await c.load(scope: f.context.scope, planID: f.plan.id)
        XCTAssertEqual(c.entries, first.entries)
        XCTAssertEqual(cursors, [nil, entries[7].id, nil])
    }
}
