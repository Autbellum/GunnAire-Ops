import Foundation
import Testing
@testable import GunnAire_Ops

@MainActor
struct ContentStartupUploadAuthorizationTests {
    @Test func identityChangeBeforeMainActorEntryCannotAdoptReplacementWorkspace() async {
        var current = true
        let original = WorkspaceProviderOperation { current }
        let entered = Task.detached {
            try await GunnAireBackendService.retainingUploadOperation(original)
        }
        // The MainActor cannot accept the background entry until this task yields.
        current = false
        await #expect(throws: WorkspaceProviderAccessError.changed(mayHaveReachedProvider: false)) {
            try await entered.value
        }
        #expect(!original.mayHaveReachedProvider)
    }

    @Test func invalidOriginDoesNotInvokeFallbackCapture() {
        let original = WorkspaceProviderOperation { false }
        var captures = 0
        #expect(throws: WorkspaceProviderAccessError.changed(mayHaveReachedProvider: false)) {
            try GunnAireBackendService.retainingUploadOperation(original, capture: {
                captures += 1
                return WorkspaceProviderOperation { true }
            })
        }
        #expect(captures == 0)
    }

    @Test func validOriginKeepsItsIdentityAndSentRisk() async throws {
        let original = WorkspaceProviderOperation { true }
        _ = try await original.performExternalMutation { "synthetic-confirmation" }
        var captures = 0
        let retained = try GunnAireBackendService.retainingUploadOperation(original, capture: {
            captures += 1
            return WorkspaceProviderOperation { true }
        })
        #expect(retained === original)
        #expect(retained.mayHaveReachedProvider)
        #expect(captures == 0)
    }

    @Test func directCallerCapturesOnceBeforePayloadPreparation() throws {
        let original = WorkspaceProviderOperation { true }
        var captures = 0
        let retained = try GunnAireBackendService.retainingUploadOperation(nil, capture: {
            captures += 1
            return original
        })
        #expect(retained === original)
        #expect(captures == 1)
        #expect(!retained.mayHaveReachedProvider)
    }
}
