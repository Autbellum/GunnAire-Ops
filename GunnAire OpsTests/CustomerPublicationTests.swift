import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor
struct CustomerPublicationTests {
    private let company = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private let attempt = UUID(uuidString: "10000000-0000-4000-8000-000000000004")!

    private func customer() -> Customer {
        Customer(name: "Taylor Customer", phone: "9195550123", email: "taylor@example.invalid", address: "42 Fixture Street")
    }

    private func context(_ customer: Customer) throws -> ModelContext {
        let schema = GunnAireModelSchema.schema
        let context = ModelContext(try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ]))
        context.insert(customer)
        try context.save()
        return context
    }

    private func response(_ draft: QuickBooksCustomerCreateDraft, companyID: UUID? = nil, localID: UUID? = nil,
                          attemptID: UUID? = nil, realm: String = "customer-realm", state: String = "confirmed",
                          providerID: String = "C1", remoteID: String = "C1", active: Bool? = true) -> CustomerPublicationResponse {
        let payload = QuickBooksCustomerCreateOperation.payload(for: draft)
        return .init(publication: .init(id: attemptID ?? attempt, companyID: companyID ?? company, realmID: realm,
            environment: Config.QuickBooks.environment, localCustomerID: localID ?? draft.localCustomerID, state: state,
            providerID: providerID, updatedAt: "2026-09-07T00:00:00+00:00"),
            customer: .init(Id: remoteID, DisplayName: payload.DisplayName, PrimaryPhone: payload.PrimaryPhone,
                PrimaryEmailAddr: payload.PrimaryEmailAddr, BillAddr: payload.BillAddr, Active: active), created: true)
    }

    private func api(companyID: UUID? = nil, publisher: @escaping CustomerPublicationBoundary.Transport,
                     direct: @escaping WorkspaceProviderOperation.Transport = { _ in
                         Issue.record("Customer publication reached direct QBO transport")
                         throw CustomerPublicationError.unavailable
                     }) -> QuickBooksDataAPI {
        QuickBooksDataAPI(testTokens: .init(accessToken: "fixture", expiration: .distantFuture),
            realmID: "customer-realm", environment: Config.QuickBooks.environment, catalogCompanyID: companyID ?? company,
            customerPublisher: publisher, transport: direct)
    }

    private func publish(_ api: QuickBooksDataAPI, _ draft: QuickBooksCustomerCreateDraft,
                         snapshot: [QuickBooksCustomer]? = nil) async throws -> QuickBooksCustomer {
        try await withCheckedThrowingContinuation { continuation in
            api.recoverOrCreateCustomer(draft, remoteCustomers: snapshot) { continuation.resume(with: $0) }
        }
    }

    @Test func serverReceivesExactCompanyCustomerAndContactValuesWithoutLocalCensus() async throws {
        let draft = QuickBooksCustomerCreateOperation.draft(for: customer())
        var calls = 0
        let api = api { request in
            calls += 1
            #expect(request.companyID == company)
            #expect(request.realmID == "customer-realm")
            #expect(request.localCustomerID == draft.localCustomerID)
            #expect(request.customer.DisplayName == draft.displayName)
            #expect(request.customer.PrimaryEmailAddr?.Address == draft.email)
            return response(draft)
        }
        let result = try await publish(api, draft, snapshot: [response(draft, remoteID: "untrusted-cache").customer])
        #expect(result.Id == "C1")
        #expect(calls == 1)
    }

    @Test func unavailableSharedServiceNeverFallsBackToDirectCreateOrCache() async throws {
        let draft = QuickBooksCustomerCreateOperation.draft(for: customer())
        let api = api { _ in throw CustomerPublicationError.unavailable }
        do { _ = try await publish(api, draft, snapshot: [response(draft).customer]); Issue.record("Unconfirmed cache accepted") }
        catch { #expect(error as? CustomerPublicationError == .unavailable) }
    }

    @Test func directCreateCannotBypassConfiguredServerPublisher() async throws {
        let draft = QuickBooksCustomerCreateOperation.draft(for: customer())
        let api = api { _ in response(draft) }
        let result: Result<QuickBooksCustomer, Error> = await withCheckedContinuation { continuation in
            api.createCustomer(QuickBooksCustomerCreateOperation.payload(for: draft)) { continuation.resume(returning: $0) }
        }
        if case .failure(let error) = result { #expect(error as? CustomerPublicationError == .unavailable) }
        else { Issue.record("Direct create bypassed server") }
    }

    @Test func wrongCompanyCustomerRealmAttemptStateAndProviderIDAreRejected() async throws {
        let draft = QuickBooksCustomerCreateOperation.draft(for: customer())
        let cases = [response(draft, companyID: UUID()), response(draft, localID: UUID()), response(draft, realm: "other"),
                     response(draft, state: "unknown"), response(draft, providerID: "OTHER"), response(draft, providerID: "", remoteID: "")]
        for wrong in cases {
            let api = api { _ in wrong }
            do { _ = try await publish(api, draft); Issue.record("Wrong server identity applied") }
            catch { #expect(error as? CustomerPublicationError == .invalidResponse) }
        }
    }

    @Test func inactiveOrUnconfirmedActiveCustomerCannotBeUsedForNewBilling() async throws {
        let draft = QuickBooksCustomerCreateOperation.draft(for: customer())
        for active in [Optional(false), nil] {
            let api = api { _ in response(draft, active: active) }
            do { _ = try await publish(api, draft); Issue.record("Inactive/unconfirmed customer accepted") }
            catch { #expect(error as? CustomerPublicationError == (active == false ? .inactiveCustomer : .invalidResponse)) }
        }
    }

    @Test func serverReplyRetainsOriginalCallbackScopeAndDeliversExactlyOnce() async throws {
        let draft = QuickBooksCustomerCreateOperation.draft(for: customer())
        let api = api { _ in response(draft) }
        var completions = 0
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            api.recoverOrCreateCustomer(draft) { _ in
                completions += 1
                api.clearTokens()
                if completions == 1 { continuation.resume() }
            }
        }
        await Task.yield()
        #expect(completions == 1)
    }

    @Test func changedConnectionRejectsLateCustomerWithUncertainWriteEvidence() async throws {
        let draft = QuickBooksCustomerCreateOperation.draft(for: customer())
        var instance: QuickBooksDataAPI?
        let api = api { _ in instance?.clearTokens(); return response(draft) }
        instance = api
        do { _ = try await publish(api, draft); Issue.record("Late account response accepted") }
        catch { #expect(error as? WorkspaceProviderAccessError == .changed(mayHaveReachedProvider: true)) }
    }

    @Test func missingCompanyStopsBeforeSending() async throws {
        let draft = QuickBooksCustomerCreateOperation.draft(for: customer())
        var calls = 0
        let api = QuickBooksDataAPI(testTokens: .init(accessToken: "fixture", expiration: .distantFuture), realmID: "customer-realm",
            environment: Config.QuickBooks.environment, customerPublisher: { _ in calls += 1; return response(draft) },
            transport: { _ in throw CustomerPublicationError.unavailable })
        do { _ = try await publish(api, draft); Issue.record("Missing company allowed") }
        catch { #expect(error as? CustomerPublicationError == .accessRequired) }
        #expect(calls == 0)
    }

    @Test func modelPublicationSavesOnlyOriginalLinkAndKeepsContactDetails() async throws {
        let customer = customer(), draft = QuickBooksCustomerCreateOperation.draft(for: customer)
        let context = try context(customer)
        let api = api { _ in response(draft) }
        let owner = try CustomerPublicationWorkflow(customer: customer, context: context, api: api, validateAccess: {})
        try await owner.publish()
        #expect(customer.quickBooksID == "C1")
        #expect(QuickBooksCustomerCreateOperation.draft(for: customer) == draft)
    }

    @Test func editedCustomerCannotReceiveLatePublicationOrOverwriteNewDetails() async throws {
        let customer = customer(), draft = QuickBooksCustomerCreateOperation.draft(for: customer)
        let context = try context(customer)
        let api = api { _ in customer.email = "edited@example.invalid"; return response(draft) }
        let owner = try CustomerPublicationWorkflow(customer: customer, context: context, api: api, validateAccess: {})
        do { try await owner.publish(); Issue.record("Changed customer linked") }
        catch { #expect(error as? QuickBooksBillingWorkflowError == .changed) }
        #expect(customer.quickBooksID == nil)
        #expect(customer.email == "edited@example.invalid")
    }

    @Test func deletedOrDuplicateLocalCustomerCannotReceiveConfirmation() async throws {
        for delete in [true, false] {
            let customer = customer(), draft = QuickBooksCustomerCreateOperation.draft(for: customer)
            let context = try context(customer)
            let api = api { _ in
                if delete { context.delete(customer) } else { context.insert(Customer(id: customer.id, name: "Duplicate")) }
                try context.save()
                return response(draft)
            }
            let owner = try CustomerPublicationWorkflow(customer: customer, context: context, api: api, validateAccess: {})
            do { try await owner.publish(); Issue.record("Deleted/duplicate customer linked") }
            catch { #expect(error as? QuickBooksBillingWorkflowError == .changed) }
        }
    }

    @Test func conflictingLocalProviderMappingIsPreservedAndRejected() async throws {
        let customer = customer(), draft = QuickBooksCustomerCreateOperation.draft(for: customer)
        let context = try context(customer)
        context.insert(Customer(quickBooksID: "C1", name: "Another Customer"))
        try context.save()
        let api = api { _ in response(draft) }
        let owner = try CustomerPublicationWorkflow(customer: customer, context: context, api: api, validateAccess: {})
        do { try await owner.publish(); Issue.record("Provider link adopted twice") }
        catch { #expect(error as? QuickBooksBillingWorkflowError == .customerConflict) }
        #expect(customer.quickBooksID == nil)
        #expect(try context.fetch(FetchDescriptor<Customer>()).count == 2)
    }

    @Test func localSaveFailureRestoresLinkWithoutRollingBackUnrelatedWork() async throws {
        let customer = customer(), draft = QuickBooksCustomerCreateOperation.draft(for: customer)
        let context = try context(customer)
        let api = api { _ in response(draft) }
        let other = Customer(name: "Unsynced work")
        context.insert(other)
        let owner = try CustomerPublicationWorkflow(customer: customer, context: context, api: api, validateAccess: {},
            save: { _ in throw CustomerPublicationError.unavailable })
        do { try await owner.publish(); Issue.record("Failed save accepted") }
        catch { #expect(error as? QuickBooksBillingWorkflowError == .saveFailed) }
        #expect(customer.quickBooksID == nil)
        #expect(try context.fetch(FetchDescriptor<Customer>()).contains(where: { $0 === other }))
    }

    @Test func cancelledOrRevokedOwnerDoesNotApplyLateResult() async throws {
        for revoke in [true, false] {
            let customer = customer(), draft = QuickBooksCustomerCreateOperation.draft(for: customer)
            let context = try context(customer)
            var allowed = true
            var owner: CustomerPublicationWorkflow? = nil
            let api = api { _ in
                if revoke { allowed = false } else { owner?.cancel() }
                return response(draft)
            }
            owner = try CustomerPublicationWorkflow(customer: customer, context: context, api: api, validateAccess: {
                if !allowed { throw CustomerPublicationError.accessRequired }
            })
            do { try await owner?.publish(); Issue.record("Inactive owner applied a link") } catch {}
            #expect(customer.quickBooksID == nil)
        }
    }

    @Test func recoveryReadsExactAttemptWithoutPublishingNewCustomer() async throws {
        let customer = customer(), draft = QuickBooksCustomerCreateOperation.draft(for: customer)
        let context = try context(customer)
        let api = api { _ in Issue.record("Recovery dispatched a new customer"); throw CustomerPublicationError.unavailable }
        let owner = try CustomerPublicationWorkflow(customer: customer, context: context, api: api, validateAccess: {})
        try await owner.recover(attempt) { id in #expect(id == attempt); return response(draft) }
        #expect(customer.quickBooksID == "C1")
    }

    @Test func recoveryRejectsDifferentAttemptOrExistingLocalProviderID() async throws {
        for wrongAttempt in [true, false] {
            let customer = customer(), draft = QuickBooksCustomerCreateOperation.draft(for: customer)
            if !wrongAttempt { customer.quickBooksID = "existing-link" }
            let context = try context(customer)
            let api = api { _ in response(draft) }
            let owner = try CustomerPublicationWorkflow(customer: customer, context: context, api: api, validateAccess: {})
            do {
                try await owner.recover(attempt) { _ in response(draft, attemptID: wrongAttempt ? UUID() : attempt) }
                Issue.record("Conflicting recovery applied")
            } catch {
                if wrongAttempt { #expect(error as? CustomerPublicationError == .invalidResponse) }
                else { #expect(error as? QuickBooksBillingWorkflowError == .customerConflict) }
            }
            #expect(customer.quickBooksID == (wrongAttempt ? nil : "existing-link"))
        }
    }

    @Test func responseCodableRequiresActiveEvidenceButPreservesLegacyCustomerDecoding() throws {
        let draft = QuickBooksCustomerCreateOperation.draft(for: customer())
        let raw = "{\"Id\":\"C1\",\"DisplayName\":\"Taylor Customer\"}"
        let legacy = try JSONDecoder().decode(QuickBooksCustomer.self, from: Data(raw.utf8))
        #expect(legacy.Active == nil)
        let record = response(draft).publication
        let incomplete = CustomerPublicationResponse(publication: record, customer: legacy, created: nil)
        #expect(throws: CustomerPublicationError.invalidResponse) {
            try incomplete.validate(companyID: company, realmID: "customer-realm", environment: Config.QuickBooks.environment,
                                    customerID: draft.localCustomerID)
        }
        let active = try JSONDecoder().decode(QuickBooksCustomer.self, from: Data("{\"Id\":\"C1\",\"DisplayName\":\"Taylor Customer\",\"Active\":true}".utf8))
        #expect(active.Active == true)
    }
}
