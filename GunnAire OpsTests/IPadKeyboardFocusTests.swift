import Testing
import UIKit
@testable import GunnAire_Ops

@Suite(.serialized)
@MainActor struct IPadKeyboardFocusTests {
    private final class InitiallyUnavailableResponder: GunnAireIPadKeyCommandBridge.KeyCommandResponderView {
        var refusesActivation = true
        private(set) var activationAttempts = 0

        override func becomeFirstResponder() -> Bool {
            activationAttempts += 1
            return refusesActivation ? false : super.becomeFirstResponder()
        }
    }

    private func withWindow(_ body: (UIWindow, UIViewController) async throws -> Void) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        // makeKeyAndVisible() only requests key status; UIKit does not promise
        // it has taken effect by the time the call returns. A view can only
        // become first responder while its window is key, so the body must not
        // start until the request has actually landed.
        try #require(await spin { window.isKeyWindow }, "window never became key")
        do {
            try await body(window, controller)
        } catch {
            await restoreKeyWindow(from: window, to: previous)
            throw error
        }
        await restoreKeyWindow(from: window, to: previous)
    }

    /// Hands key status back and waits for the handoff to finish.
    ///
    /// `makeKey()` is asynchronous. Releasing the window in a `defer` let the
    /// hand-back land *after* the next test had already made its own window
    /// key, which stole key status back, resigned that window's first responder
    /// and failed an unrelated expectation partway through the test. `.serialized`
    /// orders the tests but does not wait for UIKit, so the wait has to be here.
    /// That is why this suite began failing intermittently — on a varying test —
    /// as the rest of the test target grew and the main queue got busier.
    private func restoreKeyWindow(from window: UIWindow, to previous: UIWindow?) async {
        window.isHidden = true
        previous?.makeKey()
        _ = await spin { !window.isKeyWindow && (previous.map(\.isKeyWindow) ?? true) }
    }

    /// Turns the main queue until `condition` holds, bounded so a genuine
    /// regression still fails instead of hanging.
    private func spin(attempts: Int = 200, until condition: () -> Bool) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        return condition()
    }

    private func finishQueuedActivation() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func shortcutUpdatePreservesFocusedTextFieldAndItsText() async throws {
        try await withWindow { _, controller in
            let host = GunnAireIPadKeyCommandBridge.KeyCommandResponderView()
            controller.view.addSubview(host)
            let field = UITextField(frame: CGRect(x: 20, y: 60, width: 280, height: 44))
            controller.view.addSubview(field)
            #expect(field.becomeFirstResponder())
            field.text = "12 Main Street"
            host.activateIfAvailable()
            await finishQueuedActivation()
            #expect(field.isFirstResponder)
            #expect(!host.isFirstResponder)
            #expect(field.text == "12 Main Street")
        }
    }

    @Test func shortcutUpdatePreservesFocusedMultilineComposer() async throws {
        try await withWindow { _, controller in
            let host = GunnAireIPadKeyCommandBridge.KeyCommandResponderView()
            controller.view.addSubview(host)
            let editor = UITextView(frame: CGRect(x: 20, y: 60, width: 280, height: 150))
            controller.view.addSubview(editor)
            #expect(editor.becomeFirstResponder())
            editor.text = "Service visit notes\nKeep this draft."
            host.activateIfAvailable()
            await finishQueuedActivation()
            #expect(editor.isFirstResponder)
            #expect(!host.isFirstResponder)
            #expect(editor.text == "Service visit notes\nKeep this draft.")
        }
    }

    @Test func shortcutHostCanActivateAgainAfterEditingEnds() async throws {
        try await withWindow { _, controller in
            let host = GunnAireIPadKeyCommandBridge.KeyCommandResponderView()
            controller.view.addSubview(host)
            let field = UITextField(frame: CGRect(x: 20, y: 60, width: 280, height: 44))
            controller.view.addSubview(field)
            #expect(field.becomeFirstResponder())
            #expect(field.resignFirstResponder())
            host.activateIfAvailable()
            await finishQueuedActivation()
            #expect(host.isFirstResponder)
            #expect(host.keyCommands?.isEmpty == false)
        }
    }

    @Test func queuedActivationCannotEvictInputFocusedAfterTheRequest() async throws {
        try await withWindow { _, controller in
            let host = InitiallyUnavailableResponder()
            controller.view.addSubview(host)
            // didMoveToWindow makes the first request fail and queue a retry.
            try #require(host.activationAttempts == 1)
            host.refusesActivation = false
            let field = UITextField(frame: CGRect(x: 20, y: 60, width: 280, height: 44))
            controller.view.addSubview(field)
            #expect(field.becomeFirstResponder())
            await finishQueuedActivation()
            #expect(field.isFirstResponder)
            #expect(!host.isFirstResponder)
            #expect(host.activationAttempts == 1)
        }
    }

    @Test func queuedActivationRetriesOnceWhenNoEditorOwnsFocus() async throws {
        try await withWindow { _, controller in
            let host = InitiallyUnavailableResponder()
            controller.view.addSubview(host)
            try #require(host.activationAttempts == 1)
            host.refusesActivation = false
            await finishQueuedActivation()
            #expect(host.activationAttempts == 2)
            #expect(host.isFirstResponder)
        }
    }

    @Test func shortcutFallbackDoesNotTakeFocusBehindAPresentedSheet() async throws {
        try await withWindow { _, controller in
            let host = GunnAireIPadKeyCommandBridge.KeyCommandResponderView()
            controller.view.addSubview(host)
            let sheet = UIViewController()
            // The nonanimated presentation establishes the ownership queried
            // by the bridge. Do not depend on a window-system animation
            // completion callback: Catalyst can omit it for a test window.
            controller.present(sheet, animated: false)
            await finishQueuedActivation()
            defer { controller.dismiss(animated: false) }
            try #require(controller.presentedViewController === sheet)
            _ = host.resignFirstResponder()
            host.activateIfAvailable()
            await finishQueuedActivation()
            #expect(controller.presentedViewController === sheet)
            #expect(!host.isFirstResponder)
        }
    }
}
