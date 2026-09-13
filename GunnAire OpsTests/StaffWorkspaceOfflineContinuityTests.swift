import Foundation
import CloudKit
import CFNetwork
import XCTest
@testable import GunnAire_Ops

@MainActor final class StaffWorkspaceOfflineContinuityTests: XCTestCase {
    typealias Fixture = StaffWorkspaceOpenSessionTests.Fixture

    func testNetworkFailureRetainsVerifiedHostAndOriginalEditorDraft() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let receive = f.controller(); await f.refresh(receive)
        let hosted = try XCTUnwrap(receive.hostedStore)
        let job = try XCTUnwrap(hosted.plan.records.first { $0.kind == "job" })
        let editor = StaffWorkspaceFieldEditorController(dependencies: .live(hosted: hosted,
            kind: job.kind, recordID: job.id, revision: job.revision, field: "notes", receive: receive, coordinator: f.engine))
        editor.open(); editor.setText("Finding captured before the connection dropped")
        let original = try XCTUnwrap(editor.draft), saved = f.saved
        f.afterOpen = { _ in throw URLError(.networkConnectionLost) }
        await f.refresh(receive); editor.checkLifetime(forceRefresh: true)
        XCTAssertTrue(receive.hostedStore === hosted)
        XCTAssertEqual(editor.draft, original)
        XCTAssertEqual(editor.input.text, original.input?.text)
        XCTAssertTrue(editor.available)
        XCTAssertEqual(f.saved, saved)
        XCTAssertTrue(receive.showingSavedWorkspace)
        XCTAssertNil(receive.received)
        XCTAssertFalse(receive.message.contains("up to date"))
        f.afterOpen = nil; try f.advance(jobNotes: "Office update after reconnect")
        await f.refresh(receive); editor.checkLifetime(forceRefresh: true)
        XCTAssertFalse(receive.showingSavedWorkspace)
        XCTAssertFalse(receive.hostedStore === hosted)
        XCTAssertEqual(editor.draft, original)
        XCTAssertTrue(editor.needsReview); XCTAssertFalse(editor.canSave)
    }

    func testOnlyPositiveNetworkEvidenceSurvivesTransportSanitizers() {
        let transient: [Error] = [URLError(.notConnectedToInternet), URLError(.networkConnectionLost),
            URLError(.timedOut), URLError(.cannotConnectToHost), URLError(.cannotFindHost), URLError(.dnsLookupFailed),
            CKError(.networkUnavailable), CKError(.networkFailure),
            NSError(domain: CKErrorDomain, code: CKError.networkFailure.rawValue,
                userInfo: [NSUnderlyingErrorKey: URLError(.networkConnectionLost)]),
            NSError(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue,
                userInfo: [NSUnderlyingErrorKey: NSError(domain: kCFErrorDomainCFNetwork as String,
                    code: Int(CFNetworkErrors.cfurlErrorNotConnectedToInternet.rawValue))])]
        for error in transient {
            XCTAssertTrue(StaffSyncNetworkFailure.isTransient(error))
            XCTAssertEqual(CloudKitStaffSetupPolicy.safe(error), .offline)
            XCTAssertEqual(StaffReplicaDeliveryPolicy.safe(error), .offline)
            XCTAssertEqual(StaffReplicaDeliveryPolicy.safe(CloudKitStaffSetupPolicy.safe(error)), .offline)
        }
        let denied: [Error] = [URLError(.cancelled), URLError(.secureConnectionFailed), URLError(.serverCertificateUntrusted),
            URLError(.userAuthenticationRequired), CKError(.notAuthenticated), CKError(.permissionFailure),
            CKError(.unknownItem), CKError(.serviceUnavailable), CKError(.partialFailure),
            NSError(domain: kCFErrorDomainCFNetwork as String, code: Int(CFNetworkErrors.cfurlErrorSecureConnectionFailed.rawValue)),
            StaffReplicaDeliveryError.unavailable, CloudKitStaffSharingError.unavailable, CancellationError(),
            GunnAireBackendError.server(statusCode: 401, message: "fixture"),
            GunnAireBackendError.server(statusCode: 403, message: "fixture"),
            GunnAireBackendError.server(statusCode: 503, message: "fixture"),
            NSError(domain: "unknown", code: 1, userInfo: [NSUnderlyingErrorKey: URLError(.timedOut)]),
            NSError(domain: CKErrorDomain, code: CKError.networkFailure.rawValue,
                userInfo: [NSUnderlyingErrorKey: URLError(.serverCertificateUntrusted)]),
            NSError(domain: CKErrorDomain, code: CKError.networkFailure.rawValue,
                userInfo: [CKPartialErrorsByItemIDKey: ["record": CKError(.permissionFailure)]])]
        for error in denied {
            XCTAssertFalse(StaffSyncNetworkFailure.isTransient(error))
            XCTAssertNotEqual(CloudKitStaffSetupPolicy.safe(error), .offline)
            XCTAssertNotEqual(StaffReplicaDeliveryPolicy.safe(error), .offline)
        }
    }

    func testCoreFullReceiveAndServerOpenOutagesKeepOnlyAlreadyVerifiedData() async throws {
        for stage in 0..<3 {
            let f = try Fixture(); defer { f.cleanup() }
            let receive = f.controller(); await f.refresh(receive)
            let hosted = try XCTUnwrap(receive.hostedStore), saved = f.saved
            switch stage {
            case 0: f.downloadFailure = CloudKitStaffSetupPolicy.safe(URLError(.notConnectedToInternet))
            case 1: f.fullReceiveFailure = CKError(.networkFailure)
            default: f.serverFailure = StaffReplicaDeliveryPolicy.safe(URLError(.timedOut))
            }
            await f.refresh(receive)
            XCTAssertTrue(receive.hostedStore === hosted); XCTAssertTrue(receive.showingSavedWorkspace)
            XCTAssertEqual(f.saved, saved); XCTAssertFalse(receive.isRunning)
            XCTAssertNoThrow(try receive.fieldEditingAuthority(for: hosted))
            let cold = f.controller(); await f.refresh(cold)
            XCTAssertNil(cold.hostedStore); XCTAssertFalse(cold.showingSavedWorkspace)
        }
    }

    func testAccessVerificationStorageAndUnknownFailuresNeverUseOfflineFallback() async throws {
        let failures: [Error] = [StaffReplicaDeliveryError.access, StaffReplicaDeliveryError.changed,
            StaffReplicaDeliveryError.invalid, StaffReplicaDeliveryError.storage, StaffReplicaDeliveryError.pending,
            StaffReplicaDeliveryError.superseded, StaffReplicaDeliveryError.unavailable, CloudKitStaffSharingError.review,
            CKError(.permissionFailure), CKError(.notAuthenticated), URLError(.secureConnectionFailed), CancellationError(),
            GunnAireBackendError.server(statusCode: 403, message: "fixture"),
            NSError(domain: "fixture-unknown", code: 1)]
        for error in failures {
            let f = try Fixture(); defer { f.cleanup() }
            let receive = f.controller(); await f.refresh(receive)
            let hosted = try XCTUnwrap(receive.hostedStore), saved = f.saved
            f.fullReceiveFailure = error; await f.refresh(receive)
            XCTAssertNil(receive.presentation); XCTAssertFalse(receive.showingSavedWorkspace)
            XCTAssertThrowsError(try receive.fieldEditingAuthority(for: hosted))
            XCTAssertEqual(f.saved, saved)
        }
    }

    func testLateOutageCannotRestoreChangedDeviceExpiredOrInvalidatedSession() async throws {
        for change in 0..<4 {
            let f = try Fixture(); defer { f.cleanup() }
            let receive = f.controller(); await f.refresh(receive)
            let saved = f.saved
            f.afterOpen = { _ in
                switch change {
                case 0: f.device = String(repeating: "d", count: 64)
                case 1: f.currentTime = f.context.stamp.session.expiresAt
                case 2: f.allowed = false
                default: receive.clearDisplay()
                }
                throw URLError(.networkConnectionLost)
            }
            await f.refresh(receive)
            XCTAssertNil(receive.presentation); XCTAssertFalse(receive.showingSavedWorkspace)
            XCTAssertEqual(f.saved, saved)
        }
    }

    func testOfflineDeadlineClosesAccessWithoutDeletingDrafts() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let receive = f.controller(); await f.refresh(receive)
        f.downloadFailure = URLError(.notConnectedToInternet); await f.refresh(receive)
        let saved = f.saved
        f.currentTime = f.context.stamp.session.expiresAt
        XCTAssertNil(receive.authorizedPresentation)
        receive.enforceAccessDeadline()
        XCTAssertNil(receive.presentation); XCTAssertFalse(receive.showingSavedWorkspace)
        XCTAssertEqual(f.saved, saved)
    }

    func testPartialSuccessorReceiveRetainsDraftButCannotSubmitOldHead() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let receive = f.controller(); await f.refresh(receive)
        let hosted = try XCTUnwrap(receive.hostedStore), job = try XCTUnwrap(hosted.plan.records.first { $0.kind == "job" })
        let editor = StaffWorkspaceFieldEditorController(dependencies: .live(hosted: hosted, kind: job.kind,
            recordID: job.id, revision: job.revision, field: "notes", receive: receive, coordinator: f.engine))
        editor.open(); editor.setText("Original field draft"); let original = try XCTUnwrap(editor.draft)
        try f.advance(jobNotes: "Office successor")
        f.serverFailure = URLError(.timedOut); await f.refresh(receive)
        XCTAssertTrue(receive.hostedStore === hosted)
        editor.checkLifetime(forceRefresh: true)
        XCTAssertEqual(editor.draft, original); XCTAssertTrue(editor.needsReview); XCTAssertFalse(editor.canSave)
        editor.setText("More detail captured while offline")
        XCTAssertFalse(editor.hasUnprotectedChanges); XCTAssertEqual(editor.draft?.commandID, original.commandID)
        let saved = f.saved; await editor.save(); XCTAssertEqual(f.saved, saved)
        f.serverFailure = nil; await f.refresh(receive); editor.checkLifetime(forceRefresh: true)
        XCTAssertTrue(editor.needsReview); XCTAssertEqual(editor.input.text, "More detail captured while offline")
        XCTAssertEqual(editor.currentSnapshot?.sourceSequence, f.receipt.sourceSequence)
    }

    private func setupData(_ f: Fixture, path: String) throws -> Data {
        if path == "/api/workspace" {
            return try JSONSerialization.data(withJSONObject: ["workspace": JSONSerialization.jsonObject(with: JSONEncoder().encode(f.context.workspace)),
                "user": ["email": f.context.member.email, "role": f.context.member.role, "isActive": true]])
        }
        return try JSONSerialization.data(withJSONObject: ["shares": [JSONSerialization.jsonObject(with: JSONEncoder().encode(f.plan))]])
    }

    private func setup(_ f: Fixture, account: (() async throws -> CompanyCloudKitAccount)? = nil,
                       request: ((String) async throws -> Data)? = nil, corruptJournal: Bool = false) -> CloudKitStaffSetupController {
        var journal = CloudKitStaffSetupJournal(scope: f.context.scope)
        journal.originalPlans = [f.plan]; journal.invitationURLs = [f.plan.id.uuidString.lowercased(): f.invitation]
        return .init(dependencies: .init(stamp: { f.allowed ? f.context.stamp : nil },
            account: { if let account { return try await account() }; return f.context.account },
            request: { path, method, body in
                XCTAssertEqual(method, "GET"); XCTAssertNil(body)
                if let request { return try await request(path) }
                return try self.setupData(f, path: path)
            }, store: .init(read: { _ in corruptJournal ? Data("corrupt".utf8) : try JSONEncoder().encode(journal) },
                write: { _, _ in XCTFail("Refresh must not rewrite invitation recovery") }),
            remote: .init(invitation: { _, _, _, _, _ in throw CloudKitStaffSharingError.access },
                accept: { _, _, _, _, _, _ in throw CloudKitStaffSharingError.access },
                cleanup: { _, _, _, _ in throw CloudKitStaffSharingError.access }), now: { f.currentTime }))
    }

    func testSetupOutagesPreserveWorkspaceAndSuccessfulRetryClearsOfflineState() async throws {
        for stage in 0..<3 {
            let f = try Fixture(); defer { f.cleanup() }
            let receive = f.controller(); await f.refresh(receive)
            let hosted = try XCTUnwrap(receive.hostedStore)
            let model = setup(f, account: {
                if stage == 0 { throw CKError(.networkUnavailable) }
                return f.context.account
            }, request: { path in
                if stage == 1 || path != "/api/workspace" { throw URLError(.timedOut) }
                return try self.setupData(f, path: path)
            })
            await receive.refreshFromSetup(using: model)
            XCTAssertEqual(model.error, .offline); XCTAssertTrue(receive.hostedStore === hosted)
            XCTAssertTrue(receive.showingSavedWorkspace); XCTAssertFalse(receive.isRunning)
            await receive.refreshFromSetup(using: setup(f))
            XCTAssertNotNil(receive.authorizedPresentation); XCTAssertFalse(receive.showingSavedWorkspace)
        }
    }

    func testFreshAccountOrRoleChangeCannotBeHiddenByLaterSetupOutage() async throws {
        for accountChanged in [true, false] {
            let f = try Fixture(); defer { f.cleanup() }
            let receive = f.controller(); await f.refresh(receive)
            var laterRequests = 0
            let model = setup(f, account: {
                if !accountChanged { return f.context.account }
                let name = "changed-fixture-account"
                return .init(environment: "development", accountHash: CloudKitStaffSharePlan.accountHash(recordName: name,
                    environment: "development"), recordName: name)
            }, request: { path in
                if !accountChanged, path == "/api/workspace" {
                    return try JSONSerialization.data(withJSONObject: ["workspace": JSONSerialization.jsonObject(with: JSONEncoder().encode(f.context.workspace)),
                        "user": ["email": f.context.member.email, "role": "Accounting", "isActive": true]])
                }
                laterRequests += 1; throw URLError(.timedOut)
            })
            await receive.refreshFromSetup(using: model)
            XCTAssertEqual(model.error, .changed); XCTAssertEqual(laterRequests, 0)
            XCTAssertNil(receive.presentation); XCTAssertFalse(receive.showingSavedWorkspace)
        }
    }

    func testRevokedPlanOnFirstPageClosesBeforeLaterPageOutage() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let receive = f.controller(); await f.refresh(receive)
        let first = try f.base.plan(["state": "revoked", "businessAccessEligible": false, "revision": 5])
        var plans = [first]
        for index in 1..<50 {
            plans.append(try f.base.plan(["id": String(format: "b1000000-0000-4000-8000-%012d", index)]))
        }
        var pages = 0
        let model = setup(f, request: { path in
            if path == "/api/workspace" { return try self.setupData(f, path: path) }
            pages += 1
            if pages > 1 { throw URLError(.timedOut) }
            return try JSONSerialization.data(withJSONObject: ["shares": plans.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) },
                "nextCursor": plans.last!.id.uuidString.lowercased()])
        })
        await receive.refreshFromSetup(using: model)
        XCTAssertEqual(model.error, .changed); XCTAssertEqual(pages, 1)
        XCTAssertNil(receive.presentation); XCTAssertFalse(receive.showingSavedWorkspace)
    }

    func testCorruptSetupJournalCannotBeHiddenByListOutage() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let receive = f.controller(); await f.refresh(receive)
        var listCalls = 0
        let model = setup(f, request: { path in
            if path == "/api/workspace" { return try self.setupData(f, path: path) }
            listCalls += 1; throw URLError(.timedOut)
        }, corruptJournal: true)
        await receive.refreshFromSetup(using: model)
        XCTAssertEqual(model.error, .storage); XCTAssertEqual(listCalls, 0)
        XCTAssertNil(receive.presentation); XCTAssertFalse(receive.showingSavedWorkspace)
    }

    func testSetupRefreshCoalescesAndLateOutageCannotUndoClearDisplay() async throws {
        for clearWhileWaiting in [false, true] {
            let f = try Fixture(); defer { f.cleanup() }
            let receive = f.controller(); await f.refresh(receive)
            let hosted = try XCTUnwrap(receive.hostedStore)
            let entered = expectation(description: "Setup account request suspended")
            var release: CheckedContinuation<Void, Never>?
            var calls = 0
            let model = setup(f, account: {
                calls += 1
                await withCheckedContinuation { release = $0; entered.fulfill() }
                throw URLError(.timedOut)
            })
            let task = Task { await receive.refreshFromSetup(using: model) }
            await fulfillment(of: [entered], timeout: 5)
            XCTAssertTrue(receive.isRunning)
            let started = await receive.refresh(context: f.context, plan: f.plan, invitation: f.invitation)
            XCTAssertFalse(started)
            await receive.refreshFromSetup(using: model); XCTAssertEqual(calls, 1)
            if clearWhileWaiting { receive.clearDisplay() }
            release?.resume(); release = nil; await task.value
            XCTAssertFalse(receive.isRunning)
            XCTAssertEqual(receive.showingSavedWorkspace, !clearWhileWaiting)
            if clearWhileWaiting { XCTAssertNil(receive.presentation) }
            else { XCTAssertTrue(receive.hostedStore === hosted) }
        }
    }
}
