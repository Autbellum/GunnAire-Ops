import Testing
@testable import GunnAire_Ops

@MainActor
struct AppRootAuthenticationPolicyTests {
    @Test func revokingUnselectedAppleCredentialPreservesGoogleBusinessSession() {
        #expect(!AppRootAuthenticationPolicy.shouldEndBusinessSessionAfterAppleRevocation(
            selectedProvider: .google,
            appleBusinessSessionAvailable: true,
            googleBusinessSessionAvailable: true
        ))
    }

    @Test func revokedAppleCredentialCannotPreserveAnUnverifiedGoogleSelection() {
        #expect(AppRootAuthenticationPolicy.shouldEndBusinessSessionAfterAppleRevocation(
            selectedProvider: .google,
            appleBusinessSessionAvailable: true,
            googleBusinessSessionAvailable: false
        ))
    }

    @Test func revokingSelectedAppleCredentialEndsAppleBusinessSession() {
        #expect(AppRootAuthenticationPolicy.shouldEndBusinessSessionAfterAppleRevocation(
            selectedProvider: .apple,
            appleBusinessSessionAvailable: true,
            googleBusinessSessionAvailable: true
        ))
    }

    @Test func revokingLegacyAppleCredentialEndsAppleFirstBusinessSession() {
        #expect(AppRootAuthenticationPolicy.shouldEndBusinessSessionAfterAppleRevocation(
            selectedProvider: nil,
            appleBusinessSessionAvailable: true,
            googleBusinessSessionAvailable: true
        ))
    }

    @Test func legacySelectionPreservesGoogleWhenAppleHasNoWorkspaceProof() {
        #expect(!AppRootAuthenticationPolicy.shouldEndBusinessSessionAfterAppleRevocation(
            selectedProvider: nil,
            appleBusinessSessionAvailable: false,
            googleBusinessSessionAvailable: true
        ))
    }
}
