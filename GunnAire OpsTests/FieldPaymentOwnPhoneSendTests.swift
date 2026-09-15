import Testing
@testable import GunnAire_Ops

/// "Send to My iPhone" from an iPad or Mac creates a server task for the
/// signed-in account and starts Handoff when the origin can offer it. The
/// status line must name the durable path first; Handoff is a convenience.
struct FieldPaymentOwnPhoneSendTests {
    @Test func statusNamesTheServerTaskAndTheReceivingSteps() {
        let message = FieldPaymentHandoff.ownPhoneSendMessage(assignedTo: "eric@gunnaire.com", handoffStarted: false)
        #expect(message.hasPrefix("Sent to eric@gunnaire.com."))
        // Role-neutral: administrators and technicians see different section titles.
        #expect(message.contains("Payments → Collect"))
        #expect(!message.contains("Your Field Collection Tasks"))
        #expect(!message.contains("Handoff"))
    }

    @Test func statusMentionsHandoffOnlyWhenItActuallyStarted() {
        let started = FieldPaymentHandoff.ownPhoneSendMessage(assignedTo: "eric@gunnaire.com", handoffStarted: true)
        #expect(started.contains("Handoff is also active for 30 minutes"))
        #expect(started.contains("same Apple Account"))
        let notStarted = FieldPaymentHandoff.ownPhoneSendMessage(assignedTo: "eric@gunnaire.com", handoffStarted: false)
        #expect(!notStarted.contains("Handoff"))
    }

    @Test func statusNeverCarriesAmountsOrCustomerData() {
        let message = FieldPaymentHandoff.ownPhoneSendMessage(assignedTo: "eric@gunnaire.com", handoffStarted: true)
        #expect(!message.contains("$"))
    }
}
