import Foundation
import Testing
@testable import GunnAire_Ops

struct StaffPushNotificationRestorationTests {
    @Test func pendingSignOutPreservesTheRestoredInstallationAndOwner() {
        let saved = StaffPushNotificationPreference(
            installationID: UUID(), ownerEmail: "tech@example.test", isOptedIn: true,
            pendingServerDeactivation: false, lastRegisteredAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let signedOut = saved.disablingDeliveryForSignOut()
        #expect(signedOut.installationID == saved.installationID)
        #expect(signedOut.ownerEmail == saved.ownerEmail)
        #expect(signedOut.lastRegisteredAt == saved.lastRegisteredAt)
        #expect(!signedOut.isOptedIn)
        #expect(signedOut.pendingServerDeactivation)
        #expect(signedOut.disablingDeliveryForSignOut() == signedOut)
    }

    @Test func signOutWithoutARegisteredOwnerDoesNotInventServerRemoval() {
        let saved = StaffPushNotificationPreference.newInstallation()
        let signedOut = saved.disablingDeliveryForSignOut()
        #expect(signedOut.installationID == saved.installationID)
        #expect(!signedOut.isOptedIn)
        #expect(!signedOut.pendingServerDeactivation)
    }
}
