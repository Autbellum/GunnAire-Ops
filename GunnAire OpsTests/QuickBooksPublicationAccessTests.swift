import Foundation
import Security
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor
struct QuickBooksPublicationAccessTests {
    /// A host without a keychain entitlement answers errSecMissingEntitlement:
    /// the Mac test host carries none, and CI builds the iOS host with
    /// CODE_SIGNING_ALLOWED=NO, so an unsigned simulator run has none either.
    /// A signed host - a local simulator run and the device, which is where the
    /// product actually depends on the keychain - stores normally. Probe once
    /// rather than guessing from the platform, then exercise the real
    /// keychain-backed store wherever it works and the equivalent serialized
    /// assertions otherwise. Any other keychain failure still fails.
    private func platformKeychainIsAvailable() -> Bool {
        let account = "gunnaire.tests.keychain-probe.\(UUID().uuidString)"
        defer { try? KeychainStore.remove(account: account) }
        do {
            try KeychainStore.saveCodable(["probe": true], account: account)
            return true
        } catch KeychainStore.KeychainError.unexpectedStatus(let status)
            where status == errSecMissingEntitlement {
            return false
        } catch {
            // Any other failure belongs to the assertions below, not here.
            return true
        }
    }

    /// Persist through the real keychain where it is available and fall back to
    /// an equivalent encode/decode round trip otherwise, so every assertion
    /// below still runs. Any other keychain failure still fails.
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

    @Test func automaticRecoveryDiscoversApprovedSavedCatalogOnlyWithAdministratorAccess() {
        let fixture = Fixture()
        let pending = Item(name: "Offline approved line", unitPrice: 190)
        let review = Item(pricebookReviewStatus: .needsReview, name: "Field draft", unitPrice: 45)
        let archived = Item(pricebookReviewStatus: .archived, name: "Old line", unitPrice: 30)
        let linked = Item(quickBooksID: "I2", name: "Published line", unitPrice: 60)
        let whitespaceID = Item(quickBooksID: "  ", name: "Legacy unlinked line", unitPrice: 70)
        let items = [pending, review, archived, linked, whitespaceID]

        let staffKeys = AutomaticOutboundSync.pendingRecoveryKeys(
            invoices: [fixture.invoice], estimates: [fixture.estimate], customers: [],
            includeCustomers: false, catalogItems: items, includeCatalog: false)
        #expect(staffKeys == [.estimate(fixture.estimate.id), .invoice(fixture.invoice.id)])

        let adminKeys = AutomaticOutboundSync.pendingRecoveryKeys(
            invoices: [fixture.invoice], estimates: [fixture.estimate], customers: [],
            includeCustomers: false, catalogItems: items, includeCatalog: true)
        #expect(adminKeys == [.catalog(pending.id), .catalog(whitespaceID.id),
                              .estimate(fixture.estimate.id), .invoice(fixture.invoice.id)])

        pending.quickBooksID = "I3"
        #expect(AutomaticOutboundSync.pendingCatalogKeys(items) == [.catalog(whitespaceID.id)])
        whitespaceID.quickBooksID = "I4"
        #expect(AutomaticOutboundSync.pendingCatalogKeys(items).isEmpty)
    }

    @Test func catalogAutomaticRetryBacksOffUncertainAttemptsAndStopsInvalidProposals() {
        #expect(AutomaticOutboundSync.catalogRetryDelay(after: CatalogPublicationError.needsReview) == 600.0)
        #expect(AutomaticOutboundSync.catalogRetryDelay(after: CatalogPublicationError.invalidProposal) == nil)
        #expect(AutomaticOutboundSync.catalogRetryDelay(after: QuickBooksCatalogWorkflowError.remoteIdentity) == nil)
        #expect(AutomaticOutboundSync.catalogRetryDelay(after: QuickBooksCatalogWorkflowError.saveFailed) == 300.0)
        #expect(AutomaticOutboundSync.catalogRetryDelay(after: CatalogPublicationError.unavailable) == 300.0)
        #expect(AutomaticOutboundSync.catalogRetryDelay(after: URLError(.notConnectedToInternet)) == 300.0)
    }

    @Test func catalogRecoveryFindsWhitespaceIdentityBeyondFirstBoundedPage() throws {
        let schema = GunnAireModelSchema.schema
        let context = ModelContext(try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ]))
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<250 {
            context.insert(Item(quickBooksID: "I\(index)", name: "Linked \(index)",
                unitPrice: 1, createdAt: start.addingTimeInterval(Double(index))))
        }
        let unlinked = Item(quickBooksID: "   ", name: "Late offline line", unitPrice: 190,
            createdAt: start.addingTimeInterval(250))
        context.insert(unlinked)
        try context.save()

        var offset = 0
        let first = try AutomaticOutboundSync.nextCatalogPage(context: context, offset: &offset)
        let second = try AutomaticOutboundSync.nextCatalogPage(context: context, offset: &offset)
        #expect(first.count == 250)
        #expect(AutomaticOutboundSync.pendingCatalogKeys(first).isEmpty)
        #expect(AutomaticOutboundSync.pendingCatalogKeys(second) == [.catalog(unlinked.id)])
    }

    @Test func convertedEstimateRequiresVisibleReconciliationInsteadOfASecondAutomaticProposal() {
        let customer = Customer(name: "Converted estimate customer")
        let estimate = Estimate(customer: customer, amount: 190)
        let invoice = Invoice(customer: customer, amount: 190)
        estimate.status = "invoiced"

        #expect(QuickBooksEstimatePublicationRecovery.queuedEstimates(from: [estimate]).isEmpty)
        #expect(AutomaticOutboundSync.pendingDocumentKeys(invoices: [invoice], estimates: [estimate]) == [.invoice(invoice.id)])
        #expect(QuickBooksEstimatePublicationRecovery.convertedEstimatesNeedingReview(from: [estimate]).map(\.id) == [estimate.id])

        let rejected = Estimate(customer: customer, amount: 90, status: "rejected")
        let notSelected = Estimate(customer: customer, amount: 95, status: "not-selected")
        #expect(QuickBooksEstimatePublicationRecovery.convertedEstimatesNeedingReview(
            from: [rejected, notSelected, estimate]).map(\.id) == [estimate.id])

        estimate.quickBooksID = "EST-1"
        #expect(QuickBooksEstimatePublicationRecovery.queuedEstimates(from: [estimate]).isEmpty)
        #expect(QuickBooksEstimatePublicationRecovery.convertedEstimatesNeedingReview(from: [estimate]).isEmpty)
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
        let intended = AutomaticOutboundSync.RealmRecord(companyID: companyID,
            documentType: "estimate", documentID: documentID, customerID: customerID,
            createdAt: createdAt, realmID: nil, environment: nil,
            intendedRealmID: "realm-a", intendedEnvironment: "production")
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
        #expect(!AutomaticOutboundSync.isNewMarker(unattempted, for: expected))
        #expect(AutomaticOutboundSync.isNewMarker(intended, for: expected))
        #expect(AutomaticOutboundSync.realmDecision(stored: intended, expected: expected,
            explicitReview: false) == .reviewRequired)
        #expect(AutomaticOutboundSync.realmDecision(stored: intended, expected: otherRealm,
            explicitReview: true) == .wrongRealm)
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

    @Test func firstSaveMarkersRecoverBothDocumentsAfterRestartAndRejectForeignRealm() async throws {
        let keychainIsAvailable = platformKeychainIsAvailable()
        let schema = GunnAireModelSchema.schema
        let store = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let writer = ModelContext(store)
        let customer = Customer(name: "Write-ahead fixture")
        let estimate = Estimate(customer: customer, amount: 190)
        let invoice = Invoice(customer: customer, amount: 190)
        let companyID = UUID()
        let estimateMarker = AutomaticOutboundSync.RealmRecord(companyID: companyID,
            documentType: "estimate", documentID: estimate.id, customerID: customer.id,
            createdAt: estimate.createdAt, realmID: nil, environment: nil,
            intendedRealmID: "realm-a", intendedEnvironment: "production")
        let invoiceMarker = AutomaticOutboundSync.RealmRecord(companyID: companyID,
            documentType: "invoice", documentID: invoice.id, customerID: customer.id,
            createdAt: invoice.createdAt, realmID: nil, environment: nil,
            intendedRealmID: "realm-a", intendedEnvironment: "production")
        defer {
            try? KeychainStore.remove(account: estimateMarker.account)
            try? KeychainStore.remove(account: invoiceMarker.account)
        }

        // Save-time intent is durable before the only local save. Provider
        // proof remains absent until an exact backend connection is checked.
        if keychainIsAvailable {
            try await QuickBooksDocumentRealmProofStore.shared.markNew(estimateMarker)
            try await QuickBooksDocumentRealmProofStore.shared.markNew(invoiceMarker)
        }
        let storedEstimateMarker = try persistedRoundTrip(estimateMarker, account: estimateMarker.account)
        let storedInvoiceMarker = try persistedRoundTrip(invoiceMarker, account: invoiceMarker.account)
        writer.insert(customer)
        writer.insert(estimate)
        writer.insert(invoice)
        try writer.save()

        let restarted = ModelContext(store)
        let savedEstimate = try #require(restarted.fetch(FetchDescriptor<Estimate>()).first)
        let savedInvoice = try #require(restarted.fetch(FetchDescriptor<Invoice>()).first)
        #expect(savedEstimate.id == estimate.id && savedInvoice.id == invoice.id)
        #expect(AutomaticOutboundSync.isNewMarker(storedEstimateMarker, for: estimateMarker))
        #expect(AutomaticOutboundSync.isNewMarker(storedInvoiceMarker, for: invoiceMarker))
        #expect(!AutomaticOutboundSync.isNewMarker(nil, for: estimateMarker))
        let foreignCompany = AutomaticOutboundSync.RealmRecord(companyID: UUID(),
            documentType: "estimate", documentID: estimate.id, customerID: customer.id,
            createdAt: estimate.createdAt, realmID: nil, environment: nil)
        #expect(!AutomaticOutboundSync.isNewMarker(storedEstimateMarker, for: foreignCompany))
        let foreignCustomer = AutomaticOutboundSync.RealmRecord(companyID: companyID,
            documentType: "estimate", documentID: estimate.id, customerID: UUID(),
            createdAt: estimate.createdAt, realmID: nil, environment: nil)
        #expect(!AutomaticOutboundSync.isNewMarker(storedEstimateMarker, for: foreignCustomer))

        if keychainIsAvailable {
            let proofStore = QuickBooksDocumentRealmProofStore.shared
            #expect(try await proofStore.hasNewMarker(estimateMarker))
            #expect(try await proofStore.hasNewMarker(invoiceMarker))
            #expect(!(try await proofStore.hasBoundProof(estimateMarker)))
            let noIntent = AutomaticOutboundSync.RealmRecord(companyID: companyID,
                documentType: "estimate", documentID: UUID(), customerID: customer.id,
                createdAt: estimate.createdAt, realmID: "realm-a", environment: "production")
            #expect(!(try await proofStore.hasNewMarker(noIntent)))
            await #expect(throws: AutomaticOutboundSync.RealmError.self) {
                try await proofStore.bindNewMarker(noIntent)
            }
            let bound = AutomaticOutboundSync.RealmRecord(companyID: companyID,
                documentType: "estimate", documentID: estimate.id, customerID: customer.id,
                createdAt: estimate.createdAt, realmID: "realm-a", environment: "production")
            try await proofStore.bindNewMarker(bound)
            #expect(try await proofStore.hasBoundProof(estimateMarker))
            #expect(!(try await proofStore.hasNewMarker(estimateMarker)))
            let otherRealm = AutomaticOutboundSync.RealmRecord(companyID: companyID,
                documentType: "estimate", documentID: estimate.id, customerID: customer.id,
                createdAt: estimate.createdAt, realmID: "realm-b", environment: "production")
            await #expect(throws: AutomaticOutboundSync.RealmError.self) {
                try await proofStore.bindNewMarker(otherRealm)
            }
        } else {
            let bound = AutomaticOutboundSync.RealmRecord(companyID: companyID,
                documentType: "estimate", documentID: savedEstimate.id, customerID: customer.id,
                createdAt: savedEstimate.createdAt, realmID: "realm-a", environment: "production")
            let foreign = AutomaticOutboundSync.RealmRecord(companyID: companyID,
                documentType: "estimate", documentID: savedEstimate.id, customerID: customer.id,
                createdAt: savedEstimate.createdAt, realmID: "realm-b", environment: "production")
            #expect(AutomaticOutboundSync.realmDecision(stored: storedEstimateMarker,
                expected: bound, explicitReview: false) == .reviewRequired)
            #expect(AutomaticOutboundSync.realmDecision(stored: storedEstimateMarker,
                expected: foreign, explicitReview: true) == .wrongRealm)
            let serializedBound = try JSONDecoder().decode(AutomaticOutboundSync.RealmRecord.self,
                from: JSONEncoder().encode(bound.boundWithIntent(from: storedEstimateMarker)))
            #expect(serializedBound.intendedScope == storedEstimateMarker.intendedScope)
            #expect(AutomaticOutboundSync.realmDecision(stored: serializedBound,
                expected: bound, explicitReview: false) == .proceed)
        }
    }

    @Test func abortedDeterministicInvoiceSaveCanReplaceOnlySameRealmOrphan() async throws {
        let keychainIsAvailable = platformKeychainIsAvailable()
        let companyID = UUID()
        let invoiceID = UUID()
        let customerID = UUID()
        let old = AutomaticOutboundSync.RealmRecord(companyID: companyID,
            documentType: "invoice", documentID: invoiceID, customerID: customerID,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            realmID: "realm-a", environment: "production",
            intendedRealmID: "realm-a", intendedEnvironment: "production")
        let retry = AutomaticOutboundSync.RealmRecord(companyID: companyID,
            documentType: "invoice", documentID: invoiceID, customerID: customerID,
            createdAt: Date(timeIntervalSince1970: 1_700_000_001),
            realmID: "realm-a", environment: "production",
            intendedRealmID: "realm-a", intendedEnvironment: "production")
        let foreignRetry = AutomaticOutboundSync.RealmRecord(companyID: companyID,
            documentType: "invoice", documentID: invoiceID, customerID: customerID,
            createdAt: Date(timeIntervalSince1970: 1_700_000_002),
            realmID: nil, environment: nil,
            intendedRealmID: "realm-b", intendedEnvironment: "production")
        defer { try? KeychainStore.remove(account: old.account) }

        if keychainIsAvailable {
            let proofStore = QuickBooksDocumentRealmProofStore.shared
            try await proofStore.markNew(old)
            await #expect(throws: AutomaticOutboundSync.RealmError.self) {
                try await proofStore.markNew(retry)
            }
            try await proofStore.markNew(retry, replacingOrphan: true)
            #expect(try await proofStore.savedRecord(retry) == retry)
            #expect(try await proofStore.savedRecord(old) == nil)
            await #expect(throws: AutomaticOutboundSync.RealmError.self) {
                try await proofStore.markNew(foreignRetry, replacingOrphan: true)
            }
            #expect(try await proofStore.savedRecord(retry) == retry)
        } else {
            let serialized = try persistedRoundTrip(old, account: old.account)
            #expect(serialized.sameDocumentKeyAndCustomer(as: retry))
            #expect(!serialized.sameDocument(as: retry))
            #expect(serialized.originalScope == retry.originalScope)
            #expect(serialized.originalScope != foreignRetry.originalScope)
            #expect(AutomaticOutboundSync.realmDecision(stored: serialized,
                expected: retry, explicitReview: false) == .reviewRequired)
        }
    }

    @Test func orphanReplacementDistinguishesInsertedDraftFromCommittedInvoice() throws {
        let schema = GunnAireModelSchema.schema
        let store = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let writer = ModelContext(store)
        let customer = Customer(name: "Deterministic retry fixture")
        let invoiceID = UUID()
        let draft = Invoice(id: invoiceID, customer: customer, amount: 190)
        writer.insert(customer)
        writer.insert(draft)
        #expect(try !AutomaticOutboundSync.hasPersistedDocument(for: .invoice(draft), context: writer))

        try writer.save()
        let retry = Invoice(id: invoiceID, customer: customer, amount: 190)
        #expect(try AutomaticOutboundSync.hasPersistedDocument(for: .invoice(retry), context: writer))
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

    @Test func offlineSavedEstimateNeedsVisibleReviewUntilOriginalRealmIsExplicitlyBound() throws {
        let schema = GunnAireModelSchema.schema
        let store = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let writer = ModelContext(store)
        let customer = Customer(name: "Offline estimate customer")
        let estimate = Estimate(customer: customer, amount: 190)
        writer.insert(customer)
        writer.insert(estimate)
        try writer.save()

        let reopened = ModelContext(store)
        let saved = try #require(reopened.fetch(FetchDescriptor<Estimate>()).first)
        let savedCustomer = try #require(saved.customer)
        #expect(QuickBooksEstimatePublicationRecovery.queuedEstimates(from: [saved]).map(\.id) == [saved.id])
        #expect(AutomaticOutboundSync.pendingDocumentKeys(invoices: [], estimates: [saved]) == [.estimate(saved.id)])
        let identity = AutomaticOutboundSync.RealmRecord(companyID: UUID(),
            documentType: "estimate", documentID: saved.id, customerID: savedCustomer.id,
            createdAt: saved.createdAt, realmID: nil, environment: nil)
        #expect(AutomaticOutboundSync.estimateReviewState(quickBooksID: saved.quickBooksID,
            stored: nil, identity: identity, activeScope: nil) == .reviewRequired)

        let connected = AutomaticOutboundSync.RealmScope(companyID: identity.companyID,
            realmID: "realm-a", environment: "production")
        #expect(AutomaticOutboundSync.estimateReviewState(quickBooksID: saved.quickBooksID,
            stored: nil, identity: identity, activeScope: connected) == .reviewRequired)
        let reviewed = AutomaticOutboundSync.RealmRecord(companyID: identity.companyID,
            documentType: identity.documentType, documentID: identity.documentID,
            customerID: identity.customerID, createdAt: identity.createdAt,
            realmID: connected.realmID, environment: connected.environment)
        #expect(AutomaticOutboundSync.realmDecision(stored: nil,
            expected: reviewed, explicitReview: true) == .bind)
        #expect(AutomaticOutboundSync.estimateReviewState(quickBooksID: saved.quickBooksID,
            stored: reviewed, identity: identity, activeScope: connected) == .automaticPending)
        saved.quickBooksID = "EST-1"
        #expect(AutomaticOutboundSync.estimateReviewState(quickBooksID: saved.quickBooksID,
            stored: reviewed, identity: identity, activeScope: connected) == .published)
        let foreign = AutomaticOutboundSync.RealmScope(companyID: identity.companyID,
            realmID: "realm-b", environment: "production")
        saved.quickBooksID = nil
        #expect(AutomaticOutboundSync.estimateReviewState(quickBooksID: saved.quickBooksID,
            stored: reviewed, identity: identity, activeScope: foreign) == .reviewRequired)
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

    @Test func syncedBillingDocumentsStillRecoverTheirMissingSupportingFilesAfterRestart() throws {
        let schema = GunnAireModelSchema.schema
        let store = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let writer = ModelContext(store)
        let customer = Customer(quickBooksID: "C1", name: "Attachment recovery fixture")
        let invoice = Invoice(customer: customer, quickBooksID: "I1", amount: 190)
        invoice.quickBooksSyncStatus = "synced"
        let estimate = Estimate(customer: customer, quickBooksID: "E1", amount: 190)
        let invoiceURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let estimateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("invoice file".utf8).write(to: invoiceURL)
        try Data("estimate file".utf8).write(to: estimateURL)
        defer {
            try? FileManager.default.removeItem(at: invoiceURL)
            try? FileManager.default.removeItem(at: estimateURL)
        }
        let invoiceFile = ServiceDocumentAttachment(customer: customer, serviceCallID: nil,
            invoiceID: invoice.id, kind: .invoiceSupport, displayName: "invoice.pdf",
            localFilePath: invoiceURL.path, contentType: "application/pdf", fileSizeBytes: 12)
        let estimateFile = ServiceDocumentAttachment(customer: customer, serviceCallID: nil,
            estimateID: estimate.id, kind: .estimateSupport, displayName: "estimate.pdf",
            localFilePath: estimateURL.path, contentType: "application/pdf", fileSizeBytes: 13)
        writer.insert(customer)
        writer.insert(invoice)
        writer.insert(estimate)
        writer.insert(invoiceFile)
        writer.insert(estimateFile)
        try writer.save()
        let restarted = ModelContext(store)
        #expect(AutomaticOutboundSync.pendingDocumentKeys(invoices: [invoice], estimates: [estimate]).isEmpty)
        var offset = 0
        let pending = try QuickBooksInvoiceAttachmentSync.pendingLinkedUploadPage(context: restarted, offset: &offset)
        #expect(Set(pending.map { $0.attachment.id }) == Set([invoiceFile.id, estimateFile.id]))
        #expect(Set(pending.flatMap { $0.references.map { $0.EntityRef.type } }) == Set(["Invoice", "Estimate"]))

        let invoiceReference = try #require(pending.first { $0.attachment.id == invoiceFile.id }?.references.first)
        let savedInvoiceFile = try #require(restarted.fetch(FetchDescriptor<ServiceDocumentAttachment>()).first { $0.id == invoiceFile.id })
        savedInvoiceFile.quickBooksAttachableID = "A1"
        savedInvoiceFile.markQuickBooksAttached(to: [invoiceReference])
        try restarted.save()
        let afterReceipt = try QuickBooksInvoiceAttachmentSync.pendingLinkedUploadPage(context: restarted, offset: &offset)
        #expect(afterReceipt.map { $0.attachment.id } == [estimateFile.id])
        #expect(AutomaticOutboundSync.pendingDocumentKeys(invoices: [invoice], estimates: [estimate]).isEmpty)
    }

    @Test func reportSavedBeforeQuickBooksConnectionLinksToItsExplicitJobInvoice() throws {
        let schema = GunnAireModelSchema.schema
        let store = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let writer = ModelContext(store)
        let customer = Customer(quickBooksID: "C1", name: "Disconnected report fixture")
        let call = ServiceCall(type: .service, scheduledDate: Date(), customer: customer)
        let invoice = Invoice(serviceCallID: call.id, customer: customer, quickBooksID: "I1", amount: 190)
        invoice.quickBooksSyncStatus = "synced"
        call.linkedInvoiceID = invoice.id
        let reportURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("report file".utf8).write(to: reportURL)
        defer { try? FileManager.default.removeItem(at: reportURL) }
        let report = ServiceDocumentAttachment(customer: customer, serviceCallID: call.id,
            kind: .serviceReport, displayName: "report.pdf", localFilePath: reportURL.path,
            contentType: "application/pdf", fileSizeBytes: 11)
        writer.insert(customer)
        writer.insert(call)
        writer.insert(invoice)
        writer.insert(report)
        try writer.save()

        let restarted = ModelContext(store)
        var offset = 0
        let pending = try QuickBooksInvoiceAttachmentSync.pendingLinkedUploadPage(context: restarted, offset: &offset)
        #expect(pending.count == 1)
        #expect(pending.first?.attachment.id == report.id)
        #expect(pending.first?.references.first?.EntityRef.value == "I1")
        let saved = try #require(restarted.fetch(FetchDescriptor<ServiceDocumentAttachment>()).first)
        #expect(saved.invoiceID == invoice.id)
        #expect(saved.quickBooksAttachableID == nil)
        #expect(AutomaticOutboundSync.pendingDocumentKeys(invoices: [invoice], estimates: []).isEmpty)
    }

    @Test func anotherDevicesMissingLocalFileIsNotAutomaticallyQueuedOrMarkedFailed() throws {
        let schema = GunnAireModelSchema.schema
        let store = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let context = ModelContext(store)
        let customer = Customer(quickBooksID: "C1", name: "Other device fixture")
        let invoice = Invoice(customer: customer, quickBooksID: "I1", amount: 190)
        invoice.quickBooksSyncStatus = "synced"
        let file = ServiceDocumentAttachment(customer: customer, serviceCallID: nil,
            invoiceID: invoice.id, kind: .invoiceSupport, displayName: "invoice.pdf",
            localFilePath: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path,
            contentType: "application/pdf", fileSizeBytes: 12)
        context.insert(customer)
        context.insert(invoice)
        context.insert(file)
        try context.save()
        var offset = 0
        #expect(try QuickBooksInvoiceAttachmentSync.pendingLinkedUploadPage(context: context, offset: &offset).isEmpty)
        #expect(file.quickBooksSyncError == nil)
    }
}
