import Foundation
import XCTest
import UIKit
@testable import GunnAire_Ops

@MainActor final class StaffWorkspaceSceneContinuityTests: XCTestCase {
    typealias Fixture = StaffWorkspaceOpenSessionTests.Fixture

    func testApplicationHandoffRetainsVerifiedWorkspaceAndDraft() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let receive = f.controller(); await f.refresh(receive)
        let hosted = try XCTUnwrap(receive.hostedStore), job = try XCTUnwrap(hosted.plan.records.first { $0.kind == "job" })
        let editor = StaffWorkspaceFieldEditorController(dependencies: .live(hosted: hosted, kind: job.kind,
            recordID: job.id, revision: job.revision, field: "notes", receive: receive, coordinator: f.engine))
        editor.open(); editor.setText("Finding retained when switching to the phone handoff")
        let draft = try XCTUnwrap(editor.draft), saved = f.saved
        receive.applicationActivityChanged(false)
        editor.checkLifetime(forceRefresh: true)
        XCTAssertTrue(receive.hostedStore === hosted)
        XCTAssertEqual(editor.draft, draft)
        XCTAssertEqual(editor.input.text, draft.input?.text)
        XCTAssertEqual(f.saved, saved)
        XCTAssertTrue(receive.showingSavedWorkspace)
        XCTAssertFalse(editor.canSave)
        receive.applicationActivityChanged(true)
        f.downloadFailure = URLError(.notConnectedToInternet); await f.refresh(receive)
        XCTAssertTrue(receive.hostedStore === hosted)
        editor.checkLifetime(forceRefresh: true); XCTAssertEqual(editor.draft, draft)
    }

    private func editor(_ f: Fixture, _ receive: StaffReplicaReceiveController) throws -> StaffWorkspaceFieldEditorController {
        let hosted = try XCTUnwrap(receive.hostedStore), job = try XCTUnwrap(hosted.plan.records.first { $0.kind == "job" })
        let editor = StaffWorkspaceFieldEditorController(dependencies: .live(hosted: hosted, kind: job.kind,
            recordID: job.id, revision: job.revision, field: "notes", receive: receive, coordinator: f.engine))
        editor.open(); return editor
    }

    func testLatestInputIsDurableBeforeCancelledTransportAcknowledgesPause() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let receive = f.controller(); await f.refresh(receive)
        let hosted = try XCTUnwrap(receive.hostedStore), editor = try editor(f, receive)
        editor.setText("Initial draft"); let initial = try XCTUnwrap(editor.draft)
        let entered = expectation(description: "Server read suspended")
        var release: CheckedContinuation<Void, Never>?
        f.serverWait = { await withCheckedContinuation { release = $0; entered.fulfill() } }
        let task = Task { await f.refresh(receive) }
        await fulfillment(of: [entered], timeout: 5)
        editor.checkLifetime(forceRefresh: true)
        XCTAssertTrue(editor.available)
        XCTAssertFalse(editor.canUseCurrentRecord)
        editor.setText("Last keystrokes before app switch")
        XCTAssertFalse(editor.hasUnprotectedChanges)
        XCTAssertEqual(editor.draft?.commandID, initial.commandID)
        XCTAssertFalse(editor.canSave)
        receive.applicationActivityChanged(false)
        XCTAssertTrue(receive.hostedStore === hosted)
        XCTAssertTrue(editor.persistDraft())
        let saved = f.saved
        let started = await receive.refresh(context: f.context, plan: f.plan, invitation: f.invitation)
        XCTAssertFalse(started)
        release?.resume(); release = nil; await task.value; f.serverWait = nil
        XCTAssertFalse(receive.isRunning); XCTAssertTrue(receive.hostedStore === hosted)
        XCTAssertEqual(f.saved, saved)
        XCTAssertEqual(editor.draft?.input?.text, "Last keystrokes before app switch")
        receive.applicationActivityChanged(true); await f.refresh(receive)
        editor.checkLifetime(forceRefresh: true)
        XCTAssertTrue(editor.available); XCTAssertTrue(editor.canUseCurrentRecord)
        XCTAssertFalse(editor.hasUnprotectedChanges)
    }

    func testDraftWriteFailureDuringRefreshRemainsExplicitAndRetryableWhilePaused() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let receive = f.controller(); await f.refresh(receive)
        let editor = try editor(f, receive); editor.setText("Protected first draft")
        let original = try XCTUnwrap(editor.draft)
        let entered = expectation(description: "Server read suspended")
        var release: CheckedContinuation<Void, Never>?
        f.serverWait = { await withCheckedContinuation { release = $0; entered.fulfill() } }
        let task = Task { await f.refresh(receive) }
        await fulfillment(of: [entered], timeout: 5)
        f.failWrites = true; editor.setText("Input not yet protected")
        XCTAssertTrue(editor.hasUnprotectedChanges); XCTAssertEqual(editor.draft, original)
        XCTAssertTrue(editor.draftMessage.contains("not verified"))
        receive.applicationActivityChanged(false)
        f.failWrites = false
        XCTAssertTrue(editor.persistDraft()); XCTAssertFalse(editor.hasUnprotectedChanges)
        XCTAssertEqual(editor.draft?.commandID, original.commandID)
        let saved = f.saved
        release?.resume(); release = nil; await task.value; f.serverWait = nil
        XCTAssertEqual(f.saved, saved); XCTAssertEqual(editor.input.text, "Input not yet protected")
    }

    func testExpiredChangedAccountOrDeviceCannotResumeCachedWorkspace() async throws {
        for change in 0..<3 {
            let f = try Fixture(); defer { f.cleanup() }
            let receive = f.controller(); await f.refresh(receive)
            let editor = try editor(f, receive); editor.setText("Private original draft")
            receive.applicationActivityChanged(false); let saved = f.saved
            switch change {
            case 0: f.currentTime = f.context.stamp.session.expiresAt
            case 1: f.allowed = false
            default: f.device = String(repeating: "d", count: 64)
            }
            receive.applicationActivityChanged(true); editor.checkLifetime(forceRefresh: true)
            XCTAssertNil(receive.presentation); XCTAssertFalse(receive.showingSavedWorkspace)
            XCTAssertEqual(editor.input.text, ""); XCTAssertEqual(f.saved, saved)
        }
    }

    func testRepeatedWindowRecoveryRequestsShareOneWorkerAndPauseStopsIt() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let waiting = expectation(description: "Worker waiting after one receive")
        let receive = f.controller(recoveryWait: { waiting.fulfill(); try await Task.sleep(for: .seconds(60)) })
        var calls = 0
        let action = { calls += 1; await f.refresh(receive) }
        receive.startRecovery(using: action)
        await fulfillment(of: [waiting], timeout: 5)
        let hosted = try XCTUnwrap(receive.hostedStore)
        for _ in 0..<20 {
            receive.applicationActivityChanged(true) // Aggregate remains active with another window.
            receive.startRecovery(using: action)
        }
        XCTAssertEqual(calls, 1)
        receive.applicationActivityChanged(false); await receive.waitForRecovery()
        XCTAssertEqual(calls, 1); XCTAssertTrue(receive.hostedStore === hosted)
        receive.stopRecovery(); await receive.waitForRecovery()
        XCTAssertNil(receive.presentation)
    }

    func testRapidResumeWaitsForOldWorkerBeforeOpeningOneSuccessor() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let receive = f.controller(); await f.refresh(receive)
        let hosted = try XCTUnwrap(receive.hostedStore)
        let entered = expectation(description: "First auto receive suspended")
        let resumed = expectation(description: "One successor receive completed")
        var release: CheckedContinuation<Void, Never>?
        var calls = 0
        f.serverWait = { await withCheckedContinuation { release = $0; entered.fulfill() } }
        let action = {
            calls += 1
            await f.refresh(receive)
            if calls == 2 { resumed.fulfill() }
        }
        receive.startRecovery(using: action)
        await fulfillment(of: [entered], timeout: 5)
        receive.applicationActivityChanged(false); receive.applicationActivityChanged(true)
        receive.startRecovery(using: action)
        XCTAssertEqual(calls, 1); XCTAssertTrue(receive.hostedStore === hosted)
        f.serverWait = nil; release?.resume(); release = nil
        await fulfillment(of: [resumed], timeout: 5)
        XCTAssertEqual(calls, 2); XCTAssertNotNil(receive.authorizedPresentation)
        receive.applicationActivityChanged(false); await receive.waitForRecovery()
        receive.stopRecovery(); await receive.waitForRecovery()
    }

    func testStoppingRecoveryPreventsLateCompletionAndFutureAutomaticResume() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let receive = f.controller(); await f.refresh(receive)
        let entered = expectation(description: "Auto receive suspended before stop")
        var release: CheckedContinuation<Void, Never>?
        var calls = 0
        f.serverWait = { await withCheckedContinuation { release = $0; entered.fulfill() } }
        receive.startRecovery(using: { calls += 1; await f.refresh(receive) })
        await fulfillment(of: [entered], timeout: 5)
        receive.stopRecovery()
        f.serverWait = nil; release?.resume(); release = nil
        await receive.waitForRecovery()
        receive.applicationActivityChanged(false); receive.applicationActivityChanged(true)
        XCTAssertEqual(calls, 1); XCTAssertNil(receive.presentation)
    }

    func testAccessRevokedDuringRapidResumeCannotRecoverOldPresentation() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let receive = f.controller(); await f.refresh(receive)
        let entered = expectation(description: "Receive awaiting response before revocation")
        let retried = expectation(description: "Resume checked current authority")
        var release: CheckedContinuation<Void, Never>?
        var calls = 0
        f.serverWait = { await withCheckedContinuation { release = $0; entered.fulfill() } }
        receive.startRecovery(using: {
            calls += 1; await f.refresh(receive)
            if calls == 2 { retried.fulfill() }
        })
        await fulfillment(of: [entered], timeout: 5)
        let saved = f.saved
        receive.applicationActivityChanged(false); f.allowed = false
        receive.applicationActivityChanged(true)
        XCTAssertNil(receive.presentation)
        f.serverWait = nil; release?.resume(); release = nil
        await fulfillment(of: [retried], timeout: 5)
        XCTAssertNil(receive.presentation); XCTAssertEqual(f.saved, saved)
        receive.stopRecovery(); await receive.waitForRecovery()
    }

    func testAlreadyCancelledCallerCannotStartOrClearAnotherVerifiedWorkspace() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let receive = f.controller(); await f.refresh(receive)
        let hosted = try XCTUnwrap(receive.hostedStore), checks = f.serverChecks
        // MainActor inheritance prevents this task running before cancel below.
        let caller = Task { await receive.refresh(context: f.context, plan: f.plan, invitation: f.invitation) }
        caller.cancel()
        let started = await caller.value
        XCTAssertFalse(started); XCTAssertFalse(receive.isRunning)
        XCTAssertEqual(f.serverChecks, checks); XCTAssertTrue(receive.hostedStore === hosted)
    }

    func testRecoveryCanStopItselfAfterCompletionWithoutRestarting() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let receive = f.controller()
        let stopped = expectation(description: "Recovery stopped from completion")
        var calls = 0
        receive.startRecovery(using: {
            calls += 1; await f.refresh(receive)
            receive.stopRecovery(); stopped.fulfill()
        })
        await fulfillment(of: [stopped], timeout: 5)
        await receive.waitForRecovery()
        receive.applicationActivityChanged(false); receive.applicationActivityChanged(true)
        XCTAssertEqual(calls, 1); XCTAssertNil(receive.presentation); XCTAssertFalse(receive.isRunning)
    }

    private func hiddenWindow() throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        XCTAssertTrue(window.isHidden)
        return window
    }

    func testPrivacyCoverIsOpaqueIdempotentAndDoesNotReplaceWindowContent() throws {
        let window = try hiddenWindow()
        let content = UIView(frame: window.bounds); content.accessibilityIdentifier = "OriginalFixtureContent"
        window.addSubview(content)
        let privacy = GunnAireScenePrivacyCover()
        privacy.install(in: [window])
        let cover = window.subviews.last
        XCTAssertEqual(cover?.accessibilityIdentifier, "GunnAireScenePrivacyCover")
        XCTAssertEqual(cover?.isOpaque, true); XCTAssertEqual(cover?.frame, window.bounds)
        XCTAssertTrue(content.superview === window); XCTAssertTrue(window.isHidden)
        privacy.install(in: [window]); XCTAssertTrue(window.subviews.last === cover)
        XCTAssertEqual(window.subviews.count, 2)
        privacy.remove(); XCTAssertEqual(window.subviews.count, 1); XCTAssertTrue(window.subviews.first === content)
        XCTAssertTrue(window.isHidden) // Never activate a test window or capture its screen.
    }

    func testPrivacyCoversAreScopedToTheirOwnSceneWindows() throws {
        let first = try hiddenWindow()
        let second = try hiddenWindow()
        let privacy1 = GunnAireScenePrivacyCover(), privacy2 = GunnAireScenePrivacyCover()
        privacy1.install(in: [first]); XCTAssertTrue(second.subviews.isEmpty)
        privacy2.install(in: [second]); privacy1.remove()
        XCTAssertTrue(first.subviews.isEmpty)
        XCTAssertEqual(second.subviews.last?.accessibilityIdentifier, "GunnAireScenePrivacyCover")
        privacy2.remove(); XCTAssertTrue(second.subviews.isEmpty)
    }
}
