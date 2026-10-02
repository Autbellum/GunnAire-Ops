import Foundation
import Testing
@testable import GunnAire_Ops

@MainActor
struct QuickBooksCredentialOwnershipTests {
    private let savedTokens = QuickBooksOAuthTokens(accessToken: "synthetic-owner-token", expiration: .distantFuture)

    private func api(owner: QuickBooksCredentialOwner?, current: @escaping () -> QuickBooksCredentialOwner?) -> QuickBooksDataAPI {
        QuickBooksDataAPI(testTokens: savedTokens, realmID: "synthetic-owned-realm", environment: Config.QuickBooks.environment,
                         revokeConnection: { Issue.record("Ownership rejection must not revoke a business connection."); return false },
                         credentialOwner: owner, currentCredentialOwner: current,
                         transport: { _ in Issue.record("Ownership test unexpectedly reached provider transport."); throw URLError(.notConnectedToInternet) })
    }

    @Test func sameCompanyRestoresCredentialAfterDeviceSignOut() {
        let owner = QuickBooksCredentialOwner(companyID: UUID(), backendOrigin: "https://backend.example.invalid")
        let data = api(owner: owner, current: { owner })
        #expect(data.isAuthenticated)
        data.suspendLocalSession()
        #expect(!data.isAuthenticated)
        #expect(data.realmID == nil)
        data.reloadSavedSessionForTesting(savedTokens, realmID: "synthetic-owned-realm", credentialOwner: owner)
        #expect(data.isAuthenticated)
        #expect(data.realmID == "synthetic-owned-realm")
        #expect(data.tokens?.accessToken == savedTokens.accessToken)
    }

    @Test func legacyCredentialWithoutOwnerRequiresReconnect() {
        let owner = QuickBooksCredentialOwner(companyID: UUID(), backendOrigin: "https://backend.example.invalid")
        let data = api(owner: nil, current: { owner })
        #expect(!data.isAuthenticated)
        data.reloadSavedSessionForTesting(savedTokens, realmID: "unverified-legacy-realm")
        #expect(data.tokens == nil)
        #expect(data.realmID == nil)
        #expect(data.lastAuthorizationFailureDetail != nil)
    }

    @Test func changedCompanyCannotUseOrRestorePreviousCompanyCredential() throws {
        let owner = QuickBooksCredentialOwner(companyID: UUID(), backendOrigin: "https://backend.example.invalid")
        var current = owner
        let data = api(owner: owner, current: { current })
        let operation = try data.captureWorkspaceWorkflow { true }
        current = QuickBooksCredentialOwner(companyID: UUID(), backendOrigin: owner.backendOrigin)
        #expect(!data.isAuthenticated)
        #expect(data.realmID == nil)
        #expect(throws: WorkspaceProviderAccessError.self) { try operation.check() }
        #expect(throws: WorkspaceProviderAccessError.self) { try data.captureWorkspaceWorkflow { true } }
        data.reloadSavedSessionForTesting(savedTokens, realmID: "previous-company-realm", credentialOwner: owner)
        #expect(data.tokens == nil)
        #expect(data.realmID == nil)
        #expect(data.lastAuthorizationFailureDetail != nil)
    }

    @Test func changedBackendCannotAdoptSameCompanyIdentifier() {
        let owner = QuickBooksCredentialOwner(companyID: UUID(), backendOrigin: "https://original.example.invalid")
        let replacement = QuickBooksCredentialOwner(companyID: owner.companyID, backendOrigin: "https://replacement.example.invalid")
        let data = api(owner: owner, current: { replacement })
        data.reloadSavedSessionForTesting(savedTokens, realmID: "original-backend-realm", credentialOwner: owner)
        #expect(!data.isAuthenticated)
        #expect(data.tokens == nil)
        #expect(data.realmID == nil)
    }

    @Test func missingCurrentBusinessCannotRefreshOrPublishCredential() async {
        let owner = QuickBooksCredentialOwner(companyID: UUID(), backendOrigin: "https://backend.example.invalid")
        var current: QuickBooksCredentialOwner? = owner
        let data = api(owner: owner, current: { current })
        current = nil
        #expect(await data.refreshSessionIfPossible() == false)
        data.storeTokens(.init(accessToken: "late-synthetic-token", expiration: .distantFuture), realmID: "late-realm")
        #expect(!data.isAuthenticated)
        #expect(data.tokens == nil)
        #expect(data.realmID == nil)
    }

    @Test func mismatchedBusinessCannotTreatUnexpiredTokenAsRefreshSuccess() async {
        let owner = QuickBooksCredentialOwner(companyID: UUID(), backendOrigin: "https://backend.example.invalid")
        var current = owner
        let data = api(owner: owner, current: { current })
        current = QuickBooksCredentialOwner(companyID: UUID(), backendOrigin: owner.backendOrigin)
        #expect(await data.refreshSessionIfPossible() == false)
        #expect(data.realmID == nil)
    }
}
