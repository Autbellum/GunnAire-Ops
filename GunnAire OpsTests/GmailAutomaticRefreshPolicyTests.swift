import Foundation
import Testing
@testable import GunnAire_Ops

/// Mail gained four unattended refresh triggers - a repeating task, restored
/// connectivity, a restored Google session and a workspace stamp change - and
/// they reached the UI-test fixture mailbox, where a reload replaces the loaded
/// messages underneath an open message and takes its attachments with it.
///
/// The fixture rule belongs to those four triggers alone. Entry and foreground
/// return share the same condition set but must not be gated by it, because
/// entry is also how a fixture mailbox is seeded - gating them emptied the
/// inbox and took every Mail test with it.
struct GmailAutomaticRefreshPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func wakes(lastAttempt: Date? = nil, isSceneActive: Bool = true,
                       showingDrafts: Bool = false, hasComposeDraft: Bool = false,
                       canUseGoogleIntegration: Bool = true, connectingMail: Bool = false,
                       isLoading: Bool = false, hasBusyMessages: Bool = false) -> Bool {
        GmailAutomaticRefreshPolicy.wakes(
            isSceneActive: isSceneActive, showingDrafts: showingDrafts,
            hasComposeDraft: hasComposeDraft, canUseGoogleIntegration: canUseGoogleIntegration,
            connectingMail: connectingMail, isLoading: isLoading,
            hasBusyMessages: hasBusyMessages, lastAttempt: lastAttempt, now: now)
    }

    /// The regression that emptied the fixture inbox: the condition set carries
    /// no fixture term, so entry still seeds a synthetic mailbox.
    @Test func theConditionSetDoesNotKnowAboutFixtures() {
        #expect(wakes())
        #expect(wakes(lastAttempt: now.addingTimeInterval(-GmailAutomaticRefreshPolicy.interval)))
    }

    /// Only the unattended triggers consult this, and only they are suppressed.
    @Test func onlyUnattendedWakesAreKeptFromASyntheticMailbox() {
        #expect(!GmailAutomaticRefreshPolicy.refreshesUnattended(
            usesMailUITestFixture: true, usesServerMailFixture: false))
        // The server-mail fixture models a server, so it keeps its recovery.
        #expect(GmailAutomaticRefreshPolicy.refreshesUnattended(
            usesMailUITestFixture: true, usesServerMailFixture: true))
        // A real mailbox, and a release build, are never affected.
        #expect(GmailAutomaticRefreshPolicy.refreshesUnattended(
            usesMailUITestFixture: false, usesServerMailFixture: false))
        #expect(GmailAutomaticRefreshPolicy.refreshesUnattended(
            usesMailUITestFixture: false, usesServerMailFixture: true))
    }

    @Test func everyPreexistingConditionStillStopsARefresh() {
        #expect(!wakes(isSceneActive: false))
        #expect(!wakes(showingDrafts: true))
        #expect(!wakes(hasComposeDraft: true))
        #expect(!wakes(canUseGoogleIntegration: false))
        #expect(!wakes(connectingMail: true))
        #expect(!wakes(isLoading: true))
        #expect(!wakes(hasBusyMessages: true))
    }

    @Test func theIntervalStillBoundsARefresh() {
        #expect(!wakes(lastAttempt: now))
        #expect(!wakes(lastAttempt: now.addingTimeInterval(1 - GmailAutomaticRefreshPolicy.interval)))
        #expect(wakes(lastAttempt: now.addingTimeInterval(-GmailAutomaticRefreshPolicy.interval)))
        // A clock that moved backwards must not strand the mailbox.
        #expect(wakes(lastAttempt: now.addingTimeInterval(1)))
        #expect(GmailAutomaticRefreshPolicy.isDue(lastAttempt: nil, now: now))
    }
}
