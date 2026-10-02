import Testing
@testable import GunnAire_Ops

@MainActor
struct GoogleForegroundSessionRecoveryTests {
    private enum FixtureError: Error { case invalidProfile }

    @MainActor private final class TransientRestore {
        var attempts = 0
        var isReady = false
        var recoveredStates: [Bool] = []
        private var releaseFirst: CheckedContinuation<Void, Never>?
        private var firstStarted: CheckedContinuation<Void, Never>?

        func restore() async {
            attempts += 1
            if attempts == 1 {
                await withCheckedContinuation { continuation in
                    releaseFirst = continuation
                    firstStarted?.resume()
                    firstStarted = nil
                }
                return
            }
            isReady = true
        }

        func waitUntilFirstRestoreStarts() async {
            guard releaseFirst == nil else { return }
            await withCheckedContinuation { firstStarted = $0 }
        }

        func finishFirstRestoreWithoutSession() {
            releaseFirst?.resume()
            releaseFirst = nil
        }
    }

    @Test func periodicOrConnectivityWakeRetriesTransientGoogleRestoreBeforePublication() async {
        let fixture = TransientRestore()
        let firstForeground = Task {
            await GoogleForegroundSessionRecovery.restoreThenWake(
                restore: { await fixture.restore() },
                wake: { fixture.recoveredStates.append(fixture.isReady) }
            )
        }
        await fixture.waitUntilFirstRestoreStarts()
        #expect(fixture.recoveredStates.isEmpty)
        fixture.finishFirstRestoreWithoutSession()
        await firstForeground.value
        #expect(fixture.attempts == 1)
        #expect(fixture.recoveredStates == [false])

        await GoogleForegroundSessionRecovery.restoreThenWake(
            restore: { await fixture.restore() },
            wake: { fixture.recoveredStates.append(fixture.isReady) }
        )
        #expect(fixture.attempts == 2)
        #expect(fixture.recoveredStates == [false, true])

        await GoogleForegroundSessionRecovery.restoreThenWake(
            restore: { await fixture.restore() },
            wake: { fixture.recoveredStates.append(fixture.isReady) }
        )
        #expect(fixture.attempts == 3)
        #expect(fixture.recoveredStates == [false, true, true])
    }

    @Test func validatedIdentityWakesPublicationEvenWhenAuthenticatedFlagWasAlreadyTrue() {
        let profile = GoogleUserProfile(
            sub: "synthetic-subject", email: "synthetic@example.invalid", hd: "example.invalid",
            name: nil, picture: nil
        )
        var isAuthenticated = true
        var verified = false
        var recoveredAfterVerification = false
        GoogleForegroundSessionRecovery.finishIdentityValidation(
            .success(profile),
            onVerified: { _ in
                isAuthenticated = true
                verified = true
            },
            onFailure: { _ in Issue.record("Valid profile was rejected") },
            wake: { recoveredAfterVerification = verified && isAuthenticated }
        )
        #expect(recoveredAfterVerification)

        var failureWokePublication = false
        GoogleForegroundSessionRecovery.finishIdentityValidation(
            .failure(FixtureError.invalidProfile),
            onVerified: { _ in Issue.record("Invalid profile was accepted") },
            onFailure: { _ in isAuthenticated = false },
            wake: { failureWokePublication = true }
        )
        #expect(!isAuthenticated)
        #expect(!failureWokePublication)
    }
}
