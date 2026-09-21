import AuthenticationServices
import Foundation
import Testing
@testable import GunnAire_Ops

struct AppleCredentialValidationTests {
    @Test func missingAppleCallbackHasABoundedResult() async {
        let result = await AppleCredentialValidation.check(timeout: 0) { _ in }
        #expect(result == .unavailable)
    }

    @Test func immediateAuthorizationWinsAndDuplicateCallbackIsIgnored() async {
        let result = await AppleCredentialValidation.check {
            $0(.authorized)
            $0(.revoked)
        }
        #expect(result == .authorized)
    }

    @Test func cancellationDoesNotWaitForTheProvider() async {
        let (started, signal) = AsyncStream<Void>.makeStream()
        let task = Task {
            await AppleCredentialValidation.check(timeout: 60) { _ in signal.yield(()) }
        }
        for await _ in started { break }
        task.cancel()
        #expect(await task.value == .unavailable)
    }

    @Test func providerErrorsDoNotTurnTheDefaultRevokedStateIntoRevocation() {
        #expect(AppleCredentialValidation.result(state: .revoked, hadError: true) == .unavailable)
        #expect(AppleCredentialValidation.result(state: .authorized, hadError: false) == .authorized)
        for state in [ASAuthorizationAppleIDProvider.CredentialState.revoked, .notFound, .transferred] {
            #expect(AppleCredentialValidation.result(state: state, hadError: false) == .revoked)
        }
    }

    @Test func transientFailurePreservesOnlyAnUnexpiredBackendSession() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AppleCredentialValidation.permitsSession(result: .unavailable, expiresAt: now.addingTimeInterval(60), now: now))
        #expect(!AppleCredentialValidation.permitsSession(result: .unavailable, expiresAt: now, now: now))
        #expect(!AppleCredentialValidation.permitsSession(result: .unavailable, expiresAt: nil, now: now))
        #expect(!AppleCredentialValidation.permitsSession(result: .revoked, expiresAt: now.addingTimeInterval(60), now: now))
    }
}
