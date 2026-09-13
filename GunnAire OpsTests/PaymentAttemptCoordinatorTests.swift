import Foundation
import Testing
@testable import GunnAire_Ops

/// Explicit in-memory journal fixture: no Keychain, backend or payment network.
@MainActor
final class FixturePaymentJournal: PaymentAttemptCoordinating {
    let businessID = UUID()
    var events: [String] = []
    var records: [UUID: [String: Any]] = [:]
    var failAt: String?
    var beforeAction: ((String) -> Void)?
    var changePermitID = false

    func companyID() throws -> UUID { businessID }
    private func decode(_ value: [String: Any]) throws -> PaymentAttemptRecord {
        try JSONDecoder().decode(PaymentAttemptRecord.self, from: JSONSerialization.data(withJSONObject: value))
    }
    func reserve(_ intent: PaymentAttemptIntent) async throws -> PaymentAttemptRecord {
        events.append("reserve")
        beforeAction?("reserve")
        if failAt == "reserve" { throw URLError(.notConnectedToInternet) }
        if let existing = records[intent.id] { return try decode(existing) }
        var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(intent)) as! [String: Any]
        value["requestID"] = UUID().uuidString
        value["clientTransactionID"] = intent.clientTransactionID
        value["state"] = "reserved"
        records[intent.id] = value
        return try decode(value)
    }
    func action(_ action: String, attemptID: UUID, reference: String?) async throws -> PaymentAttemptRecord {
        events.append(action)
        beforeAction?(action)
        guard var value = records[attemptID] else { throw PaymentAttemptError.needsReview }
        if action == "begin" {
            guard value["state"] as? String == "reserved" else { throw PaymentAttemptError.needsReview }
            value["state"] = "sending"
            if changePermitID { value["requestID"] = UUID().uuidString }
        } else if action == "confirm" {
            value["candidateProviderID"] = reference
            if failAt != action {
                value["providerID"] = reference
                value["providerStatus"] = "CAPTURED"
                value["state"] = "confirmed"
            }
        } else if action == "complete" {
            if failAt != action { value["accountingID"] = reference; value["state"] = "completed" }
        } else if action == "cancel" {
            guard value["state"] as? String == "reserved" else { throw PaymentAttemptError.needsReview }
            value["state"] = "cancelled"
        } else if action == "unknown", value["state"] as? String == "sending" { value["state"] = "unknown" }
        records[attemptID] = value
        if failAt == action { throw URLError(.timedOut) }
        return try decode(value)
    }
    func get(_ id: UUID) async throws -> PaymentAttemptRecord {
        guard let value = records[id] else { throw PaymentAttemptError.needsReview }
        return try decode(value)
    }
    func list(invoiceID: UUID) async throws -> [PaymentAttemptRecord] {
        try records.values.map(decode).filter { $0.intent.invoiceID == invoiceID }
    }
}

@MainActor
struct PaymentAttemptCoordinatorTests {
    private func intent(_ journal: FixturePaymentJournal) -> PaymentAttemptIntent {
        PaymentAttemptIntent(id: UUID(), companyID: journal.businessID, realmID: "fixture-realm",
            environment: "sandbox", invoiceID: UUID(), invoiceQuickBooksID: "fixture-invoice",
            customerQuickBooksID: "fixture-customer", amountCents: 123, rail: "card", kind: "charge")
    }

    @Test func dispatchOrderAndIdentifiersComeOnlyFromDurableReservation() async throws {
        let journal = FixturePaymentJournal()
        let intent = intent(journal)
        var sentRequestID: UUID?
        let (_, result) = try await PaymentAttemptDispatcher(journal: journal, check: {}).dispatch(intent: intent,
            prepare: { journal.events.append("token"); return "fixture-token" },
            send: { token, permit in
                #expect(token == "fixture-token")
                journal.events.append("send")
                sentRequestID = permit.requestID
                #expect(permit.clientTransactionID == intent.clientTransactionID)
                return "fixture-charge"
            }, providerID: { $0 })
        #expect(journal.events == ["reserve", "token", "begin", "send", "confirm"])
        #expect(result.requestID == sentRequestID && result.state == .confirmed)
        #expect(result.providerID == "fixture-charge")
        let stored = try #require(journal.records[intent.id])
        #expect(!String(describing: stored).contains("fixture-token"))
    }

    @Test func failedReservationOrTokenizationCannotAuthorizeCharge() async {
        for failure in ["reserve", "token"] {
            let journal = FixturePaymentJournal()
            journal.failAt = failure
            var sends = 0
            do {
                _ = try await PaymentAttemptDispatcher(journal: journal, check: {}).dispatch(intent: intent(journal),
                    prepare: {
                        if failure == "token" { throw URLError(.notConnectedToInternet) }
                        return ()
                    }, send: { _, _ in sends += 1; return "fixture-charge" }, providerID: { $0 })
                Issue.record("Failed prerequisite allowed payment")
            } catch {}
            #expect(sends == 0)
            #expect(!journal.events.contains("begin"))
            #expect(journal.events.contains("cancel") == (failure == "token"))
        }
    }

    @Test func lostPermitResponseAndUnconfirmedProviderOutcomeNeverResend() async {
        for failure in ["begin", "send", "confirm"] {
            let journal = FixturePaymentJournal()
            journal.failAt = failure
            let intent = intent(journal)
            var sends = 0
            let dispatcher = PaymentAttemptDispatcher(journal: journal, check: {})
            for _ in 0..<2 {
                do {
                    _ = try await dispatcher.dispatch(intent: intent, prepare: { () },
                        send: { _, _ in
                            sends += 1
                            if failure == "send" { throw URLError(.timedOut) }
                            return "fixture-charge"
                        }, providerID: { $0 })
                    Issue.record("Uncertain attempt was accepted")
                } catch {}
            }
            #expect(sends == (failure == "begin" ? 0 : 1))
            #expect(journal.events.filter { $0 == "begin" }.count == 1)
            #expect(!journal.events.contains("cancel"))
            #expect(journal.records[intent.id]?["state"] as? String == "unknown")
            if failure == "confirm" {
                #expect(journal.records[intent.id]?["candidateProviderID"] as? String == "fixture-charge")
            }
        }
    }

    @Test func alteredPermitCannotSend() async {
        let journal = FixturePaymentJournal()
        journal.changePermitID = true
        var sends = 0
        do {
            _ = try await PaymentAttemptDispatcher(journal: journal, check: {}).dispatch(intent: intent(journal),
                prepare: { () }, send: { _, _ in sends += 1; return "fixture-charge" }, providerID: { $0 })
            Issue.record("Changed durable request ID was accepted")
        } catch {}
        #expect(sends == 0)
    }

    @Test func accountReplacementDuringEveryJournalStageStopsSubsequentWork() async {
        for stage in ["reserve", "begin", "confirm"] {
            let journal = FixturePaymentJournal()
            var current = true
            var sends = 0
            journal.beforeAction = { if $0 == stage { current = false } }
            do {
                _ = try await PaymentAttemptDispatcher(journal: journal, check: {
                    if !current { throw WorkspaceProviderAccessError.changed(mayHaveReachedProvider: true) }
                }).dispatch(intent: intent(journal), prepare: { () },
                    send: { _, _ in sends += 1; return "fixture-charge" }, providerID: { $0 })
                Issue.record("Replacement workspace accepted old attempt")
            } catch {
                #expect(error is WorkspaceProviderAccessError)
            }
            #expect(sends == (stage == "confirm" ? 1 : 0))
            #expect(!journal.events.contains("unknown") && !journal.events.contains("cancel"))
        }
    }

    @Test func recordRejectsDifferentBusinessAmountOrState() async throws {
        let journal = FixturePaymentJournal()
        let expected = intent(journal)
        let record = try await journal.reserve(expected)
        try record.validate(for: expected, states: [.reserved])
        #expect(throws: PaymentAttemptError.self) { try record.validate(for: expected, states: [.sending]) }
        let other = intent(journal)
        #expect(throws: PaymentAttemptError.self) { try record.validate(for: other, states: [.reserved]) }
    }
}
