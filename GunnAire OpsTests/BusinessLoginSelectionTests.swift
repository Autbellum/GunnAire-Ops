import Foundation
import Testing
@testable import GunnAire_Ops

@MainActor
struct BusinessLoginSelectionTests {
    @Test func selectedBusinessProviderSurvivesAStoreReopen() throws {
        let suite = "BusinessLoginSelectionTests.\(UUID().uuidString)"
        let first = try #require(UserDefaults(suiteName: suite))
        defer { first.removePersistentDomain(forName: suite) }

        BusinessLoginSelection.choose(.google, in: first)
        let restored = try #require(UserDefaults(suiteName: suite))
        #expect(BusinessLoginSelection.selected(in: restored) == .google)
        #expect(BusinessLoginSelection.resolvedProvider(
            selected: BusinessLoginSelection.selected(in: restored),
            appleBusinessSessionAvailable: true,
            googleBusinessSessionAvailable: true
        ) == .google)

        BusinessLoginSelection.clear(in: restored)
        #expect(BusinessLoginSelection.selected(in: first) == nil)
    }

    @Test func selectedBusinessProviderNeverFallsBackToAnotherSession() {
        #expect(BusinessLoginSelection.resolvedProvider(
            selected: .google, appleBusinessSessionAvailable: true,
            googleBusinessSessionAvailable: false
        ) == nil)
        #expect(BusinessLoginSelection.resolvedProvider(
            selected: .apple, appleBusinessSessionAvailable: false,
            googleBusinessSessionAvailable: true
        ) == nil)
    }

    @Test func legacyLoginSelectionPreservesAppleFirstMigration() {
        #expect(BusinessLoginSelection.resolvedProvider(
            selected: nil, appleBusinessSessionAvailable: true,
            googleBusinessSessionAvailable: true
        ) == .apple)
        #expect(BusinessLoginSelection.resolvedProvider(
            selected: nil, appleBusinessSessionAvailable: false,
            googleBusinessSessionAvailable: true
        ) == .google)
        #expect(BusinessLoginSelection.resolvedProvider(
            selected: nil, appleBusinessSessionAvailable: false,
            googleBusinessSessionAvailable: false
        ) == nil)
    }

    @Test func backendBearerFollowsSelectedBusinessLogin() {
        let google = BusinessLoginSelection.authorizationHeader(
            selected: .google, appleSessionToken: "old-apple-fixture",
            googleSessionToken: "new-google-fixture", googleIdentityToken: "identity-fixture"
        )
        #expect(google == .init(name: "Authorization", value: "Bearer new-google-fixture"))
        #expect(BusinessLoginSelection.authorizationHeader(
            selected: .google, appleSessionToken: "old-apple-fixture",
            googleSessionToken: nil, googleIdentityToken: "identity-fixture"
        ) == nil)

        let apple = BusinessLoginSelection.authorizationHeader(
            selected: .apple, appleSessionToken: "apple-fixture",
            googleSessionToken: "google-fixture", googleIdentityToken: nil
        )
        #expect(apple == .init(name: "Authorization", value: "Bearer apple-fixture"))
    }

    @Test func businessLoginCanReplaceAStalePrimaryWithoutRelaxingIntegrationLink() {
        #expect(GoogleAccountLinkPolicy.canAcceptOAuthProfile(
            primaryBusinessEmail: "old@example.test", googleEmail: "new@example.test",
            forBusinessLogin: true
        ))
        #expect(!GoogleAccountLinkPolicy.canAcceptOAuthProfile(
            primaryBusinessEmail: "old@example.test", googleEmail: "new@example.test",
            forBusinessLogin: false
        ))
    }
}
