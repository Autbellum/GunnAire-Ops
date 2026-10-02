import Foundation
import Security
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor
struct AutomaticPaymentSyncTests {
    /// The Mac test host carries no keychain entitlement, so the platform
    /// keychain answers errSecMissingEntitlement there while the signed iOS
    /// host stores normally. Persist through the real keychain wherever it is
    /// available - which is where the product actually depends on it - and fall
    /// back to an equivalent encode/decode round trip otherwise, so every
    /// assertion below still runs. Any other keychain failure still fails.
    private func persistedRoundTrip<T: Codable>(_ value: T, account: String) throws -> T {
        do {
            try KeychainStore.saveCodable(value, account: account)
            return try #require(try KeychainStore.loadCodable(T.self, account: account))
        } catch KeychainStore.KeychainError.unexpectedStatus(let status)
            where status == errSecMissingEntitlement {
            return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
        }
    }
    private let companyID = UUID()
    private let realmID = "QBO-REALM-A"
    private let environment = "production"

    private func container() throws -> ModelContainer {
        let schema = GunnAireModelSchema.schema
        return try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
    }

    private func proof(for payment: Payment) throws -> AutomaticPaymentSync.RealmProof {
        let invoice = try #require(payment.invoice)
        let customer = try #require(invoice.customer)
        let quickBooksInvoiceID = try #require(invoice.quickBooksID)
        let quickBooksCustomerID = try #require(customer.quickBooksID)
        return AutomaticPaymentSync.RealmProof(companyID: companyID, paymentID: payment.id,
            invoiceID: invoice.id, customerID: customer.id,
            quickBooksInvoiceID: quickBooksInvoiceID,
            quickBooksCustomerID: quickBooksCustomerID,
            realmID: realmID, environment: environment)
    }

    private func eligible(_ payment: Payment, proof: AutomaticPaymentSync.RealmProof?) -> Bool {
        AutomaticPaymentSync.shouldRecover(payment, proof: proof, companyID: companyID,
            realmID: realmID, environment: environment)
    }

    @Test func savedManualPaymentAndKeychainProofSurviveAContextRestart() throws {
        let store = try container()
        let writer = ModelContext(store)
        let customer = Customer(quickBooksID: "QBO-C1", name: "Synthetic customer")
        let invoice = Invoice(customer: customer, quickBooksID: "QBO-I1", amount: 240)
        let payment = Payment(invoice: invoice, quickBooksAccountingSyncStatus: "pending",
            processorSyncStatus: "recorded", amount: 80, method: "check")
        writer.insert(customer)
        writer.insert(invoice)
        writer.insert(payment)
        try writer.save()

        let account = AutomaticPaymentSync.RealmProof.account(
            companyID: companyID, paymentID: payment.id)
        defer { try? KeychainStore.remove(account: account) }
        let restoredProof = try persistedRoundTrip(try proof(for: payment), account: account)

        let restarted = ModelContext(store)
        let saved = try #require(restarted.fetch(FetchDescriptor<Payment>()).first)
        #expect(saved.id == payment.id)
        #expect(eligible(saved, proof: restoredProof))
        saved.processorSyncStatus = "company_queued"
        saved.quickBooksAccountingSyncStatus = "needs_attention"
        try restarted.save()
        let reconnected = ModelContext(store)
        #expect(try reconnected.fetch(FetchDescriptor<Payment>()).contains {
            eligible($0, proof: restoredProof)
        })
    }

    @Test func recoveryNeverRepeatsAProviderChargeOrPublishesAnUnlinkedOrConfirmedPayment() throws {
        let customer = Customer(quickBooksID: "QBO-C1", name: "Synthetic customer")
        let invoice = Invoice(customer: customer, quickBooksID: "QBO-I1", amount: 240)
        let manual = Payment(invoice: invoice, quickBooksAccountingSyncStatus: "pending",
            processorSyncStatus: "recorded", amount: 80, method: "cash")
        let manualProof = try proof(for: manual)
        #expect(eligible(manual, proof: manualProof))

        let captured = Payment(invoice: invoice, quickBooksChargeID: "charge-1",
            quickBooksAccountingSyncStatus: "needs_attention", processorSyncStatus: "recorded",
            amount: 80, method: "card")
        #expect(!eligible(captured, proof: try proof(for: captured)))
        let attempted = Payment(invoice: invoice, collectionAttemptID: UUID(),
            quickBooksAccountingSyncStatus: "needs_attention", processorSyncStatus: "recorded",
            amount: 80, method: "card")
        #expect(!eligible(attempted, proof: try proof(for: attempted)))
        let refund = Payment(invoice: invoice, quickBooksAccountingSyncStatus: "pending",
            processorSyncStatus: "recorded", amount: 80, method: "cash", isRefund: true)
        #expect(!eligible(refund, proof: try proof(for: refund)))

        manual.quickBooksID = "QBO-P1"
        #expect(!eligible(manual, proof: manualProof))
        manual.quickBooksID = nil
        invoice.quickBooksID = nil
        #expect(!eligible(manual, proof: manualProof))
        invoice.quickBooksID = "QBO-I1"
        customer.quickBooksID = nil
        #expect(!eligible(manual, proof: manualProof))
    }

    @Test func missingProofAndRealmOrEnvironmentSwitchFailClosed() throws {
        let customer = Customer(quickBooksID: "C1", name: "Synthetic customer")
        let invoice = Invoice(customer: customer, quickBooksID: "I1", amount: 80)
        let payment = Payment(invoice: invoice, quickBooksAccountingSyncStatus: "pending",
            processorSyncStatus: "recorded", amount: 80)
        let savedProof = try proof(for: payment)
        #expect(!eligible(payment, proof: nil))
        #expect(eligible(payment, proof: savedProof))
        #expect(!AutomaticPaymentSync.shouldRecover(payment, proof: savedProof,
            companyID: companyID, realmID: "QBO-REALM-B", environment: environment))
        #expect(!AutomaticPaymentSync.shouldRecover(payment, proof: savedProof,
            companyID: companyID, realmID: realmID, environment: "sandbox"))
        #expect(!AutomaticPaymentSync.shouldRecover(payment, proof: savedProof,
            companyID: UUID(), realmID: realmID, environment: environment))
        payment.invoice = Invoice(customer: customer, quickBooksID: "I2", amount: 80)
        #expect(!eligible(payment, proof: savedProof))
        payment.invoice = invoice
        invoice.quickBooksID = "I2"
        #expect(!eligible(payment, proof: savedProof))
        invoice.quickBooksID = "I1"
        customer.quickBooksID = "C2"
        #expect(!eligible(payment, proof: savedProof))
    }

    @Test func accountingRoleKeepsItsExistingExplicitSyncWithoutGainingAutomaticAdministration() {
        #expect(AutomaticPaymentSync.permitsAccountingPublication(role: .admin, automatic: true))
        #expect(AutomaticPaymentSync.permitsAccountingPublication(role: .admin, automatic: false))
        #expect(!AutomaticPaymentSync.permitsAccountingPublication(role: .accounting, automatic: true))
        #expect(AutomaticPaymentSync.permitsAccountingPublication(role: .accounting, automatic: false))
        #expect(!AutomaticPaymentSync.permitsAccountingPublication(role: .fieldTechnician, automatic: false))
    }

    @Test func scopeRotationKeepsAnIssuedPaymentClaimUntilItsTaskReturns() throws {
        let sync = AutomaticPaymentSync()
        let containerA = NSObject()
        let containerB = NSObject()
        let paymentID = UUID()
        sync.adoptScope(containerID: ObjectIdentifier(containerA),
            operationStamp: nil, realmID: "QBO-REALM-A")
        let firstGeneration = sync.generation
        let originalClaim = try sync.claim(paymentID)

        sync.adoptScope(containerID: ObjectIdentifier(containerA),
            operationStamp: nil, realmID: "QBO-REALM-B")
        #expect(sync.generation != firstGeneration)
        sync.adoptScope(containerID: ObjectIdentifier(containerB),
            operationStamp: nil, realmID: "QBO-REALM-B")
        do {
            _ = try sync.claim(paymentID)
            Issue.record("A rotated workspace released an in-flight payment claim")
        } catch AutomaticPaymentSync.SyncError.alreadyRunning {
            // The original provider write may still be awaiting its response.
        } catch {
            Issue.record("Unexpected claim error: \(error)")
        }

        sync.release(paymentID, token: UUID())
        do {
            _ = try sync.claim(paymentID)
            Issue.record("An unrelated token released the original claim")
        } catch AutomaticPaymentSync.SyncError.alreadyRunning {
        } catch {
            Issue.record("Unexpected claim error: \(error)")
        }
        sync.release(paymentID, token: originalClaim)
        let nextClaim = try sync.claim(paymentID)
        #expect(nextClaim != originalClaim)
        sync.release(paymentID, token: nextClaim)
    }
}
