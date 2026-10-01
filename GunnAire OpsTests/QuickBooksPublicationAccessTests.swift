import Foundation
import Security
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor
struct QuickBooksPublicationAccessTests {
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
    @MainActor private struct Fixture {
        let item: Item
        let invoice: Invoice
        let estimate: Estimate

        init() {
            let customer = Customer(quickBooksID: "C1", name: "Synthetic customer", email: "fixture@example.invalid")
            item = Item(quickBooksID: "I1", name: "Diagnostic", unitPrice: 190)
            let snapshot = CatalogLineItemSnapshot.encoded(from: [item])
            invoice = Invoice(customer: customer, catalogSnapshotJSON: snapshot, amount: 190)
            estimate = Estimate(customer: customer, catalogSnapshotJSON: snapshot, amount: 190)
        }
    }

    @Test func invoiceRevalidatesAccessAfterPreparingLinesOffMain() async throws {
        let fixture = Fixture()
        var validations = 0
        await #expect(throws: QuickBooksBillingWorkflowError.accessDenied) {
            try await QuickBooksInvoicePublicationRecovery.publicationInputsAsync(
                for: fixture.invoice, catalogItems: [fixture.item], payments: [], validateCurrent: {
                    validations += 1
                    if validations > 1 { throw QuickBooksBillingWorkflowError.accessDenied }
                })
        }
        #expect(validations == 2)
    }

    @Test func estimateRevalidatesAccessAfterPreparingLinesOffMain() async throws {
        let fixture = Fixture()
        var validations = 0
        await #expect(throws: QuickBooksBillingWorkflowError.accessDenied) {
            try await QuickBooksEstimatePublicationRecovery.publicationInputsAsync(
                for: fixture.estimate, catalogItems: [fixture.item], validateCurrent: {
                    validations += 1
                    if validations > 1 { throw QuickBooksBillingWorkflowError.accessDenied }
                })
        }
        #expect(validations == 2)
    }

    @Test func unchangedWorkspaceProducesBothDocumentsAfterRevalidation() async throws {
        let fixture = Fixture()
        var validations = 0
        let invoice = try await QuickBooksInvoicePublicationRecovery.publicationInputsAsync(
            for: fixture.invoice, catalogItems: [fixture.item], payments: [], validateCurrent: { validations += 1 })
        let estimate = try await QuickBooksEstimatePublicationRecovery.publicationInputsAsync(
            for: fixture.estimate, catalogItems: [fixture.item], validateCurrent: { validations += 1 })
        #expect(validations == 4)
        #expect(invoice.customerRef.value == "C1")
        #expect(estimate.customerRef.value == "C1")
        #expect(invoice.lines.count == 1)
        #expect(estimate.lines.count == 1)
        #expect(invoice.lines.first?.Amount == 190)
        #expect(estimate.lines.first?.Amount == 190)
    }

    @Test func automaticRecoveryIncludesSavedEstimatesAndInvoicesButSkipsConfirmedDocuments() {
        let fixture = Fixture()
        let pending = AutomaticOutboundSync.pendingDocumentKeys(
            invoices: [fixture.invoice], estimates: [fixture.estimate])
        #expect(pending == [.estimate(fixture.estimate.id), .invoice(fixture.invoice.id)])

        fixture.estimate.quickBooksID = "E1"
        fixture.invoice.quickBooksSyncStatus = "synced"
        #expect(AutomaticOutboundSync.pendingDocumentKeys(
            invoices: [fixture.invoice], estimates: [fixture.estimate]).isEmpty)
    }

    @Test func automaticRecoveryIncludesUnlinkedCustomerWithoutRepublishingLinkedCustomer() {
        let unlinked = Customer(name: "Saved local customer")
        let linked = Customer(quickBooksID: "C2", name: "Already linked")
        #expect(AutomaticOutboundSync.pendingCustomerKeys([unlinked, linked]) == [.customer(unlinked.id)])
        unlinked.quickBooksID = "C3"
        #expect(AutomaticOutboundSync.pendingCustomerKeys([unlinked, linked]).isEmpty)
    }

    @Test func backendBillingRecoveryDoesNotRequireDeviceQuickBooksAuthentication() {
        let fixture = Fixture()
        let unlinked = Customer(name: "Saved local customer")
        let withoutDeviceOAuth = AutomaticOutboundSync.pendingRecoveryKeys(
            invoices: [fixture.invoice], estimates: [fixture.estimate],
            customers: [unlinked], includeCustomers: false)
        #expect(withoutDeviceOAuth == [.estimate(fixture.estimate.id), .invoice(fixture.invoice.id)])

        let withAdministrativeDeviceOAuth = AutomaticOutboundSync.pendingRecoveryKeys(
            invoices: [fixture.invoice], estimates: [fixture.estimate],
            customers: [unlinked], includeCustomers: true)
        #expect(withAdministrativeDeviceOAuth == [
            .estimate(fixture.estimate.id), .invoice(fixture.invoice.id), .customer(unlinked.id)
        ])
    }

    @Test func automaticBillingRealmFenceRejectsLegacyAndChangedCompanies() {
        let companyID = UUID()
        let documentID = UUID()
        let customerID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let expected = AutomaticOutboundSync.RealmRecord(companyID: companyID,
            documentType: "estimate", documentID: documentID, customerID: customerID,
            createdAt: createdAt, realmID: "realm-a", environment: "production")
        let unattempted = AutomaticOutboundSync.RealmRecord(companyID: companyID,
            documentType: "estimate", documentID: documentID, customerID: customerID,
            createdAt: createdAt, realmID: nil, environment: nil)
        let otherRealm = AutomaticOutboundSync.RealmRecord(companyID: companyID,
            documentType: "estimate", documentID: documentID, customerID: customerID,
            createdAt: createdAt, realmID: "realm-b", environment: "production")
        let otherCustomer = AutomaticOutboundSync.RealmRecord(companyID: companyID,
            documentType: "estimate", documentID: documentID, customerID: UUID(),
            createdAt: createdAt, realmID: nil, environment: nil)

        #expect(AutomaticOutboundSync.realmDecision(stored: nil, expected: expected,
            explicitReview: false) == .reviewRequired)
        #expect(AutomaticOutboundSync.realmDecision(stored: nil, expected: expected,
            explicitReview: true) == .bind)
        #expect(AutomaticOutboundSync.realmDecision(stored: unattempted, expected: expected,
            explicitReview: false) == .reviewRequired)
        #expect(AutomaticOutboundSync.realmDecision(stored: unattempted, expected: expected,
            explicitReview: true) == .bind)
        #expect(AutomaticOutboundSync.realmDecision(stored: expected, expected: expected,
            explicitReview: false) == .proceed)
        #expect(AutomaticOutboundSync.realmDecision(stored: otherRealm, expected: expected,
            explicitReview: true) == .wrongRealm)
        #expect(AutomaticOutboundSync.realmDecision(stored: otherCustomer, expected: expected,
            explicitReview: false) == .reviewRequired)
    }

    @Test func savedEstimateAndKeychainRealmProofSurviveContextRestart() throws {
        let schema = GunnAireModelSchema.schema
        let store = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let writer = ModelContext(store)
        let customer = Customer(name: "Restart fixture")
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let estimate = Estimate(customer: customer, amount: 190, createdAt: createdAt)
        writer.insert(customer)
        writer.insert(estimate)
        try writer.save()

        let companyID = UUID()
        let unattempted = AutomaticOutboundSync.RealmRecord(companyID: companyID,
            documentType: "estimate", documentID: estimate.id, customerID: customer.id,
            createdAt: estimate.createdAt, realmID: nil, environment: nil)
        let account = unattempted.account
        defer { try? KeychainStore.remove(account: account) }
        let marker = try persistedRoundTrip(unattempted, account: account)

        let restarted = ModelContext(store)
        let saved = try #require(restarted.fetch(FetchDescriptor<Estimate>()).first)
        let savedCustomer = try #require(saved.customer)
        let expected = AutomaticOutboundSync.RealmRecord(companyID: companyID,
            documentType: "estimate", documentID: saved.id, customerID: savedCustomer.id,
            createdAt: saved.createdAt, realmID: "realm-a", environment: "production")
        #expect(marker.sameDocument(as: expected))
        #expect(AutomaticOutboundSync.realmDecision(stored: marker, expected: expected,
            explicitReview: false) == .reviewRequired)

        let afterRestart = try persistedRoundTrip(expected, account: account)
        #expect(AutomaticOutboundSync.realmDecision(stored: afterRestart, expected: expected,
            explicitReview: false) == .proceed)
    }

    @Test func proofBindingWakesOnlyMatchingEarlyScanAndConsumesHandoffOnce() throws {
        let schema = GunnAireModelSchema.schema
        let store = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let writer = ModelContext(store)
        let customer = Customer(name: "Recovery race fixture")
        let estimate = Estimate(customer: customer, amount: 190,
            createdAt: Date(timeIntervalSince1970: 1_700_000_001))
        writer.insert(customer)
        writer.insert(estimate)
        try writer.save()

        let companyID = UUID()
        let marker = AutomaticOutboundSync.RealmRecord(companyID: companyID,
            documentType: "estimate", documentID: estimate.id, customerID: customer.id,
            createdAt: estimate.createdAt, realmID: nil, environment: nil)
        let account = marker.account
        defer { try? KeychainStore.remove(account: account) }
        let earlyScanProof = try persistedRoundTrip(marker, account: account)
        let deferred = Date.distantFuture
        #expect(AutomaticOutboundSync.realmDecision(stored: earlyScanProof,
            expected: marker, explicitReview: false) == .reviewRequired)

        let reopened = ModelContext(store)
        let saved = try #require(reopened.fetch(FetchDescriptor<Estimate>()).first)
        let savedCustomer = try #require(saved.customer)
        let verified = AutomaticOutboundSync.RealmRecord(companyID: companyID,
            documentType: "estimate", documentID: saved.id, customerID: savedCustomer.id,
            createdAt: saved.createdAt, realmID: "realm-a", environment: "production")
        let persistedProof = try persistedRoundTrip(verified, account: account)
        let proofMatches = AutomaticOutboundSync.realmDecision(stored: persistedProof,
            expected: verified, explicitReview: false) == .proceed
        #expect(AutomaticOutboundSync.proofWakeDisposition(deferred,
            sameGeneration: true, sameContainer: true, proofMatches: proofMatches,
            checkingProof: false) == .enqueue)
        #expect(AutomaticOutboundSync.proofWakeDisposition(nil,
            sameGeneration: true, sameContainer: true, proofMatches: proofMatches,
            checkingProof: true) == .handoff)
        let key = AutomaticOutboundSync.DocumentKey.estimate(saved.id)
        var handoffs: Set<AutomaticOutboundSync.DocumentKey> = [key]
        var pending: [AutomaticOutboundSync.DocumentKey] = []
        let firstHandoff = AutomaticOutboundSync.requeueAfterProofCheck(key,
            pending: &pending, handoffs: &handoffs, explicitReviews: [])
        #expect(firstHandoff)
        #expect(pending == [key])
        let repeatedHandoff = AutomaticOutboundSync.requeueAfterProofCheck(key,
            pending: &pending, handoffs: &handoffs, explicitReviews: [])
        #expect(!repeatedHandoff)
        #expect(pending == [key])
        #expect(AutomaticOutboundSync.proofWakeDisposition(deferred,
            sameGeneration: false, sameContainer: true, proofMatches: proofMatches,
            checkingProof: true) == .ignore)
        #expect(AutomaticOutboundSync.proofWakeDisposition(deferred,
            sameGeneration: true, sameContainer: false, proofMatches: proofMatches,
            checkingProof: false) == .ignore)
        #expect(AutomaticOutboundSync.proofWakeDisposition(deferred,
            sameGeneration: true, sameContainer: true, proofMatches: false,
            checkingProof: false) == .ignore)
        #expect(AutomaticOutboundSync.proofWakeDisposition(Date().addingTimeInterval(300),
            sameGeneration: true, sameContainer: true, proofMatches: proofMatches,
            checkingProof: false) == .ignore)
        let differentRealm = AutomaticOutboundSync.RealmRecord(companyID: companyID,
            documentType: "estimate", documentID: saved.id, customerID: savedCustomer.id,
            createdAt: saved.createdAt, realmID: "realm-b", environment: "production")
        #expect(AutomaticOutboundSync.realmDecision(stored: persistedProof,
            expected: differentRealm, explicitReview: false) == .wrongRealm)
        #expect(AutomaticOutboundSync.proofWakeDisposition(deferred,
            sameGeneration: true, sameContainer: true,
            proofMatches: AutomaticOutboundSync.realmDecision(stored: persistedProof,
                expected: differentRealm, explicitReview: false) == .proceed,
            checkingProof: false) == .ignore)
    }

    @Test func explicitReviewDuringProofCheckRequeuesTheSavedDocumentOnlyOnce() {
        let key = AutomaticOutboundSync.DocumentKey.estimate(UUID())
        var pending: [AutomaticOutboundSync.DocumentKey] = []
        var handoffs: Set<AutomaticOutboundSync.DocumentKey> = []
        let explicitReviews: Set<AutomaticOutboundSync.DocumentKey> = [key]

        let first = AutomaticOutboundSync.requeueAfterProofCheck(key,
            pending: &pending, handoffs: &handoffs, explicitReviews: explicitReviews)
        #expect(first)
        #expect(pending == [key])
        let repeated = AutomaticOutboundSync.requeueAfterProofCheck(key,
            pending: &pending, handoffs: &handoffs, explicitReviews: explicitReviews)
        #expect(!repeated)
        #expect(pending == [key])

        pending.removeAll()
        let differentKey = AutomaticOutboundSync.DocumentKey.invoice(UUID())
        let unrelated = AutomaticOutboundSync.requeueAfterProofCheck(differentKey,
            pending: &pending, handoffs: &handoffs, explicitReviews: explicitReviews)
        #expect(!unrelated)
        #expect(pending.isEmpty)
    }

    @Test func oneRejectedDraftDoesNotPauseOtherAutomaticPublications() {
        #expect(!AutomaticOutboundSync.shouldPauseAfterFailure(QuickBooksBillingWorkflowError.changed))
        #expect(!AutomaticOutboundSync.shouldPauseAfterFailure(SharedBillingConnectionError.updateRequired))
        #expect(AutomaticOutboundSync.shouldPauseAfterFailure(URLError(.notConnectedToInternet)))
        #expect(AutomaticOutboundSync.shouldPauseAfterFailure(SharedBillingConnectionError.unavailable))
    }

    @Test func pendingCustomerScanAdvancesPastTheFirstHundredRecords() throws {
        let schema = GunnAireModelSchema.schema
        let context = ModelContext(try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ]))
        for index in 0..<105 {
            context.insert(Customer(name: String(format: "Customer %03d", index)))
        }
        try context.save()
        let descriptor = FetchDescriptor<Customer>(sortBy: [SortDescriptor(\.name)])
        var offset = 0
        let first = try AutomaticOutboundSync.nextPage(descriptor, context: context, offset: &offset)
        let second = try AutomaticOutboundSync.nextPage(descriptor, context: context, offset: &offset)
        #expect(first.count == 100)
        #expect(second.count == 5)
        #expect(Set(first.map(\.id)).isDisjoint(with: Set(second.map(\.id))))
        #expect(offset == 0)
    }
}
