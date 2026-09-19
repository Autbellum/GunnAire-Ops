import Foundation
import Testing
@testable import GunnAire_Ops

/// The registration timestamp was added after devices had saved preferences;
/// those records must keep decoding, and the timestamp must survive a save.
@MainActor
struct StaffPushNotificationPreferenceTests {
    @Test func preferencesSavedBeforeTheRegistrationTimestampStillDecode() throws {
        let legacy = """
        {"installationID":"6B29FC40-CA47-1067-B31D-00DD010662DA","ownerEmail":"owner@example.com","isOptedIn":true,"pendingServerDeactivation":false}
        """
        let decoded = try JSONDecoder().decode(StaffPushNotificationPreference.self, from: Data(legacy.utf8))
        #expect(decoded.lastRegisteredAt == nil)
        #expect(decoded.isOptedIn)
        #expect(decoded.ownerEmail == "owner@example.com")

        var updated = decoded
        updated.lastRegisteredAt = Date(timeIntervalSince1970: 1_788_800_000)
        let roundTrip = try JSONDecoder().decode(StaffPushNotificationPreference.self, from: JSONEncoder().encode(updated))
        #expect(roundTrip == updated)
    }
}
