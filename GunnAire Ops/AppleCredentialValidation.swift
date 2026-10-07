import AuthenticationServices
import Foundation

nonisolated enum AppleCredentialValidation {
    enum Result: Equatable, Sendable {
        case authorized
        case revoked
        case unavailable
    }

    static func result(
        state: ASAuthorizationAppleIDProvider.CredentialState,
        hadError: Bool
    ) -> Result {
        guard !hadError else { return .unavailable }
        switch state {
        case .authorized: return .authorized
        case .revoked, .notFound, .transferred: return .revoked
        @unknown default: return .unavailable
        }
    }

    /// Apple outages do not revoke a still-current backend session. The workspace
    /// controller continues to enforce its independent company authorization.
    static func permitsSession(result: Result, expiresAt: Date?, now: Date) -> Bool {
        guard result != .revoked, let expiresAt, expiresAt > now else { return false }
        return true
    }

    static func check(
        timeout: TimeInterval = 6,
        request: @escaping @Sendable (@escaping @Sendable (Result) -> Void) -> Void
    ) async -> Result {
        let completion = AppleCredentialCompletion()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard completion.install(continuation) else { return }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, timeout)) {
                    completion.finish(.unavailable)
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    request { completion.finish($0) }
                }
            }
        } onCancel: {
            completion.finish(.unavailable)
        }
    }
}

/// Callback, cancellation and deadline may race; only the first result resumes
/// the caller. A provider that never calls back cannot hold launch open.
nonisolated private final class AppleCredentialCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AppleCredentialValidation.Result, Never>?
    private var result: AppleCredentialValidation.Result?

    func install(_ continuation: CheckedContinuation<AppleCredentialValidation.Result, Never>) -> Bool {
        lock.lock()
        let result = self.result
        if result == nil { self.continuation = continuation }
        lock.unlock()
        if let result { continuation.resume(returning: result) }
        return result == nil
    }

    func finish(_ result: AppleCredentialValidation.Result) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}
