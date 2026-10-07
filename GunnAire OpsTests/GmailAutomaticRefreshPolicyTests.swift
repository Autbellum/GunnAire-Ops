import Foundation
import Testing
@testable import GunnAire_Ops

/// Mail gained four unattended refresh triggers - a repeating task, restored
/// connectivity, a restored Google session and a workspace stamp change - and
/// they reached the UI-test fixture mailbox, where a reload replaces the loaded
/// messages underneath an open message and takes that message's attachments
/// with it. These pin the one decision every trigger now goes through.
struct GmailAutomaticRefreshPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// Every condition satisfied and a refresh long overdue, which is the state
    /// each trigger creates. This is the case that regressed: the synthetic
    /// fixture mailbox used to wake here.
    private func wakes(usesMailUITestFixture: Bool, usesServerMailFixture: Bool = false,
                       lastAttempt: Date? = nil) -> Bool {
        GmailAutomaticRefreshPolicy.wakes(
            usesMailUITestFixture: usesMailUITestFixture,
            usesServerMailFixture: usesServerMailFixture,
            isSceneActive: true, showingDrafts: false, hasComposeDraft: false,
            canUseGoogleIntegration: true, connectingMail: false,
            isLoading: false, hasBusyMessages: false,
            lastAttempt: lastAttempt, now: now)
    }

    @Test func aSyntheticFixtureMailboxNeverWakesOnItsOwn() {
        #expect(!wakes(usesMailUITestFixture: true))
        // Not merely "not yet": no elapsed time makes it due.
        #expect(!wakes(usesMailUITestFixture: true, lastAttempt: now.addingTimeInterval(-86_400)))
        #expect(!GmailAutomaticRefreshPolicy.refreshesUnattended(
            usesMailUITestFixture: true, usesServerMailFixture: false))
    }

    @Test func aRealMailboxStillWakesWhenEveryConditionHolds() {
        #expect(wakes(usesMailUITestFixture: false))
        #expect(wakes(usesMailUITestFixture: false,
                      lastAttempt: now.addingTimeInterval(-GmailAutomaticRefreshPolicy.interval)))
        #expect(GmailAutomaticRefreshPolicy.refreshesUnattended(
            usesMailUITestFixture: false, usesServerMailFixture: false))
    }

    @Test func theServerMailFixtureKeepsItsBoundedRecovery() {
        #expect(wakes(usesMailUITestFixture: true, usesServerMailFixture: true))
        #expect(GmailAutomaticRefreshPolicy.refreshesUnattended(
            usesMailUITestFixture: true, usesServerMailFixture: true))
    }

    /// The fixture rule is an addition, not a replacement: a real mailbox still
    /// answers to each pre-existing condition exactly as it did before.
    @Test func everyPreexistingConditionStillStopsARealMailbox() {
        func wakesWith(_ change: (inout (Bool, Bool, Bool, Bool, Bool, Bool, Bool)) -> Void) -> Bool {
            var c = (true, false, false, true, false, false, false)
            change(&c)
            return GmailAutomaticRefreshPolicy.wakes(
                usesMailUITestFixture: false, usesServerMailFixture: false,
                isSceneActive: c.0, showingDrafts: c.1, hasComposeDraft: c.2,
                canUseGoogleIntegration: c.3, connectingMail: c.4,
                isLoading: c.5, hasBusyMessages: c.6,
                lastAttempt: nil, now: now)
        }
        #expect(wakesWith { _ in })
        #expect(!wakesWith { $0.0 = false })
        #expect(!wakesWith { $0.1 = true })
        #expect(!wakesWith { $0.2 = true })
        #expect(!wakesWith { $0.3 = false })
        #expect(!wakesWith { $0.4 = true })
        #expect(!wakesWith { $0.5 = true })
        #expect(!wakesWith { $0.6 = true })
    }

    @Test func theIntervalStillBoundsARealMailbox() {
        #expect(!wakes(usesMailUITestFixture: false, lastAttempt: now))
        #expect(!wakes(usesMailUITestFixture: false,
                       lastAttempt: now.addingTimeInterval(1 - GmailAutomaticRefreshPolicy.interval)))
        // A clock that moved backwards must not strand the mailbox.
        #expect(wakes(usesMailUITestFixture: false, lastAttempt: now.addingTimeInterval(1)))
    }
}
