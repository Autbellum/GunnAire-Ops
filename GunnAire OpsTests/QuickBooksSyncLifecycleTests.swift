import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor
struct QuickBooksSyncLifecycleTests {
    private func api(_ transport: @escaping WorkspaceProviderOperation.Transport) -> QuickBooksDataAPI {
        QuickBooksDataAPI(testTokens: .init(accessToken: "fixture", expiration: .distantFuture),
            realmID: "fixture-realm", environment: Config.QuickBooks.environment, transport: transport)
    }

    private func reply(_ request: URLRequest, payload: String = #"{"QueryResponse":{"Customer":[]}}"#) -> (Data, URLResponse) {
        (Data(payload.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: nil)!)
    }

    private func replace(_ api: QuickBooksDataAPI) {
        api.storeTokens(.init(accessToken: "replacement-fixture", expiration: .distantFuture),
                        realmID: "replacement-realm")
    }

    private func context() throws -> ModelContext {
        let schema = GunnAireModelSchema.schema
        return ModelContext(try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ]))
    }

    @Test func capturedRunCannotAdoptAConnectionReplacedBeforeTaskStarts() async throws {
        var sends = 0
        let api = api { request in sends += 1; return reply(request) }
        let lifecycle = QuickBooksSyncLifecycle()
        let run = try lifecycle.begin(api: api, validateAccess: {})
        replace(api)
        do {
            let _: [QuickBooksCustomer] = try await run.receive(api.fetchCustomers)
            Issue.record("A queued run adopted the new connection")
        } catch { #expect(error is WorkspaceProviderAccessError) }
        #expect(sends == 0)
        #expect(api.tokens?.accessToken == "replacement-fixture")
    }

    @Test func completeRunImportsOnlyItsOriginalResourceEvidence() async throws {
        var sends = 0
        let api = api { request in
            sends += 1
            let payload = sends == 1
                ? #"{"QueryResponse":{"Customer":[{"Id":"C1","DisplayName":"Fixture Customer"}]}}"#
                : #"{"QueryResponse":{"Invoice":[{"Id":"I1","CustomerRef":{"value":"C1"},"TotalAmt":500,"Balance":300}]}}"#
            return reply(request, payload: payload)
        }
        let lifecycle = QuickBooksSyncLifecycle()
        let run = try lifecycle.begin(api: api, validateAccess: {})
        let context = try context()
        try await run.perform {
            let customers = try await run.receive(api.fetchCustomers)
            try run.markSucceeded("customers")
            let invoices = try await run.receive(api.fetchInvoices)
            try run.markSucceeded("invoices")
            try run.commit {
                try QuickBooksLocalSync.importSnapshot(customers: customers, items: [], estimates: [],
                    invoices: invoices, payments: [], vendors: [], into: context)
            }
        }
        let invoices = try context.fetch(FetchDescriptor<Invoice>())
        #expect(invoices.count == 1)
        #expect(invoices.first?.quickBooksBalanceDue == 300)
        #expect(invoices.first?.customer.quickBooksID == "C1")
        #expect(run.successfulResourceIDs == ["customers", "invoices"])
        #expect(sends == 2)
        #expect(lifecycle.finish(run))
        #expect(lifecycle.activeID == nil)
    }

    @Test func accountChangeBetweenResourcesCannotStartAnotherFetchOrSave() async throws {
        var sends = 0
        var saved = false
        let api = api { request in sends += 1; return reply(request) }
        let lifecycle = QuickBooksSyncLifecycle()
        let run = try lifecycle.begin(api: api, validateAccess: {})
        do {
            try await run.perform {
                _ = try await run.receive(api.fetchCustomers)
                replace(api)
                _ = try await run.receive(api.fetchInvoices)
                try run.commit { saved = true }
            }
            Issue.record("Cross-account resource import continued")
        } catch { #expect(error is WorkspaceProviderAccessError) }
        #expect(sends == 1)
        #expect(!saved)
    }

    @Test func delayedCallbackCannotCommitAfterItsWorkspaceIsRevoked() async throws {
        var authorized = true
        var applied = false
        let api = api { reply($0) }
        let lifecycle = QuickBooksSyncLifecycle()
        let run = try lifecycle.begin(api: api) {
            guard authorized else { throw CompanyWorkspaceFailure.administratorRequired }
        }
        do {
            let value: Int = try await run.receive { completion in
                completion(.success(7))
                authorized = false
            }
            try run.commit { applied = value == 7 }
            Issue.record("A callback resumed with revoked access")
        } catch { #expect(error as? CompanyWorkspaceFailure == .administratorRequired) }
        #expect(!applied)
    }

    @Test func aCancelledRunCannotCommitSavedModelsOrAcknowledgeEvents() async throws {
        let lifecycle = QuickBooksSyncLifecycle()
        let api = api { reply($0) }
        let run = try lifecycle.begin(api: api, validateAccess: {})
        let context = try context()
        let customer = Customer(name: "Retained fixture")
        context.insert(customer)
        try context.save()
        lifecycle.cancel()
        #expect(throws: CancellationError.self) {
            try run.commit { customer.name = "Must not change"; try context.save() }
        }
        var acknowledged = false
        do {
            try await run.perform { acknowledged = true }
            Issue.record("Cancelled run acknowledged change events")
        } catch { #expect(error is CancellationError) }
        #expect(customer.name == "Retained fixture")
        #expect(!acknowledged)
    }

    @Test func supersededRunCannotClearNewRunOrReuseItsSuccessSet() throws {
        let lifecycle = QuickBooksSyncLifecycle()
        let api = api { reply($0) }
        let first = try lifecycle.begin(api: api, validateAccess: {})
        try first.markSucceeded("customers")
        let second = try lifecycle.begin(api: api, validateAccess: {})
        #expect(!lifecycle.finish(first))
        #expect(lifecycle.isCurrent(second))
        #expect(second.successfulResourceIDs.isEmpty)
        #expect(throws: CancellationError.self) { try first.markSucceeded("invoices") }
        try second.markSucceeded("invoices")
        #expect(second.successfulResourceIDs == ["invoices"])
    }

    @Test func delayedOldRunCannotOverwriteTheNewRunsResults() async throws {
        let lifecycle = QuickBooksSyncLifecycle()
        let api = api { reply($0) }
        let first = try lifecycle.begin(api: api, validateAccess: {})
        var second: QuickBooksSyncRun?
        var displayed = "new result"
        do {
            let value: String = try await first.receive { completion in
                second = try? lifecycle.begin(api: api, validateAccess: {})
                completion(.success("old result"))
            }
            try first.commit { displayed = value }
            Issue.record("Old result replaced newer display state")
        } catch { #expect(error is CancellationError) }
        #expect(displayed == "new result")
        #expect(second.map(lifecycle.isCurrent) == true)
    }

    @Test func deniedInitialAccessNeverAllocatesASyncRun() {
        let lifecycle = QuickBooksSyncLifecycle()
        let api = api { reply($0) }
        #expect(throws: CompanyWorkspaceFailure.self) {
            _ = try lifecycle.begin(api: api) { throw CompanyWorkspaceFailure.administratorRequired }
        }
        #expect(lifecycle.activeID == nil)
    }

    @Test func revokedAccessOverridesAnUnrelatedLateNetworkError() async throws {
        var authorized = true
        let api = api { reply($0) }
        let lifecycle = QuickBooksSyncLifecycle()
        let run = try lifecycle.begin(api: api) {
            guard authorized else { throw CompanyWorkspaceFailure.administratorRequired }
        }
        do {
            try await run.perform {
                authorized = false
                throw URLError(.timedOut)
            }
            Issue.record("Revoked run completed")
        } catch { #expect(error as? CompanyWorkspaceFailure == .administratorRequired) }
    }

    @Test func ordinaryResourceFailureCanContinueWithoutClaimingItsCachedRows() async throws {
        let api = api { reply($0) }
        let lifecycle = QuickBooksSyncLifecycle()
        let run = try lifecycle.begin(api: api, validateAccess: {})
        do {
            let _: [String] = try await run.receive { $0(.failure(URLError(.timedOut))) }
            Issue.record("Failed resource reported success")
        } catch { #expect(error is URLError) }
        let customers = try await run.receive(api.fetchCustomers)
        try run.markSucceeded("customers")
        #expect(customers.isEmpty)
        #expect(QuickBooksSnapshotImportPolicy.records(["stale"], resource: "invoices",
            successfulResourceIDs: run.successfulResourceIDs).isEmpty)
        #expect(run.successfulResourceIDs == ["customers"])
    }

    @Test func backendFollowUpCannotStartAfterProviderReplacement() async throws {
        let api = api { reply($0) }
        let lifecycle = QuickBooksSyncLifecycle()
        let run = try lifecycle.begin(api: api, validateAccess: {})
        _ = try await run.receive(api.fetchCustomers)
        replace(api)
        var acknowledgementRequests = 0
        do {
            try await run.perform { acknowledgementRequests += 1 }
            Issue.record("Old event IDs were sent through a replacement connection")
        } catch { #expect(error is WorkspaceProviderAccessError) }
        #expect(acknowledgementRequests == 0)
    }

    @Test func capturedWorkflowCannotEscapeAnInvalidParentWorkflow() async throws {
        let api = api { reply($0) }
        do {
            try await api.withWorkspaceOperation { _ in
                replace(api)
                _ = try api.captureWorkspaceWorkflow()
            }
            Issue.record("Nested capture escaped invalid parent")
        } catch { #expect(error is WorkspaceProviderAccessError) }
    }

    @Test func cancelledTaskRejectsCallbackEvenIfTheTransportCompletes() async throws {
        let api = api { reply($0) }
        let lifecycle = QuickBooksSyncLifecycle()
        let run = try lifecycle.begin(api: api, validateAccess: {})
        let task = Task { @MainActor in
            try await run.receive { (completion: @escaping (Result<Int, Error>) -> Void) in
                withUnsafeCurrentTask { $0?.cancel() }
                completion(.success(1))
            }
        }
        do { _ = try await task.value; Issue.record("Cancelled task accepted callback") }
        catch { #expect(error is CancellationError) }
    }

    @Test func primaryEmailDoesNotOverrideVerifiedRoleOrInactiveRecords() {
        let user = AppUser(email: AppAccess.primaryAdminEmail, role: .admin)
        #expect(!QuickBooksSyncAccessPolicy.allows(email: user.email, users: [user], verifiedRole: .standard))
        user.isActive = false
        #expect(!QuickBooksSyncAccessPolicy.allows(email: user.email, users: [user], verifiedRole: .admin))
        #expect(!QuickBooksSyncAccessPolicy.allows(email: user.email, users: [], verifiedRole: .admin))
    }

    @Test func conflictingAdministratorClaimsFailClosed() {
        let first = AppUser(email: "admin@example.invalid", role: .admin)
        let second = AppUser(email: "ADMIN@example.invalid", role: .standard)
        #expect(!QuickBooksSyncAccessPolicy.allows(email: first.email, users: [first, second], verifiedRole: .admin))
        second.role = .admin
        #expect(QuickBooksSyncAccessPolicy.allows(email: " ADMIN@example.invalid ", users: [first, second], verifiedRole: .admin))
    }

    @Test func matchingActiveAdministratorCanSyncButOtherRolesCannot() {
        for role in [AppUserRole.admin, .standard, .dispatcher, .fieldTechnician, .accounting] {
            let user = AppUser(email: "admin@example.invalid", role: role)
            #expect(QuickBooksSyncAccessPolicy.allows(email: user.email, users: [user],
                verifiedRole: role) == (role == .admin))
        }
    }
    @Test func revokedRoleStopsPaginationBeforeAnotherProviderPage() async throws {
        var authorized = true
        var sends = 0
        let api = api { request in
            sends += 1
            authorized = false
            let rows = (0..<QuickBooksQueryPagination.pageSize).map { ["Id": "C\($0)", "DisplayName": "Fixture \($0)"] }
            let data = try JSONSerialization.data(withJSONObject: ["QueryResponse": ["Customer": rows]])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let lifecycle = QuickBooksSyncLifecycle()
        let run = try lifecycle.begin(api: api) {
            guard authorized else { throw CompanyWorkspaceFailure.administratorRequired }
        }
        do { _ = try await run.receive(api.fetchCustomers); Issue.record("Revoked pagination continued") }
        catch { #expect(error as? CompanyWorkspaceFailure == .administratorRequired) }
        #expect(sends == 1)
    }

    @Test func cancelledRunStopsPaginationBeforeAnotherProviderPage() async throws {
        let lifecycle = QuickBooksSyncLifecycle()
        var sends = 0
        let api = api { request in
            sends += 1
            lifecycle.cancel()
            let rows = (0..<QuickBooksQueryPagination.pageSize).map { ["Id": "C\($0)", "DisplayName": "Fixture \($0)"] }
            let data = try JSONSerialization.data(withJSONObject: ["QueryResponse": ["Customer": rows]])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let run = try lifecycle.begin(api: api, validateAccess: {})
        do { _ = try await run.receive(api.fetchCustomers); Issue.record("Cancelled pagination continued") }
        catch { #expect(error is CancellationError) }
        #expect(sends == 1)
    }

    @Test func nestedRunValidationRetainsUncertainParentWriteEvidence() async throws {
        let parent = WorkspaceProviderOperation { true }
        var request = URLRequest(url: URL(string: "https://example.invalid/fixture")!)
        request.httpMethod = "POST"
        _ = try await parent.data(for: request) { reply($0) }
        let child = WorkspaceProviderOperation(parent: parent) { true }
        let grandchild = WorkspaceProviderOperation(parent: child) { false }
        #expect(grandchild.failure == .changed(mayHaveReachedProvider: true))
    }


    @Test func reloadingTheSameSavedSessionDoesNotInvalidateActiveSync() async throws {
        let api = api { reply($0) }
        let saved = try #require(api.tokens)
        let lifecycle = QuickBooksSyncLifecycle()
        let run = try lifecycle.begin(api: api, validateAccess: {})
        api.reloadSavedSessionForTesting(saved, realmID: "fixture-realm")
        _ = try await run.receive(api.fetchCustomers)
        try run.check()
        #expect(lifecycle.isCurrent(run))
    }

    @Test func aChangedSavedSessionInvalidatesAnExistingRun() throws {
        let api = api { reply($0) }
        let lifecycle = QuickBooksSyncLifecycle()
        let run = try lifecycle.begin(api: api, validateAccess: {})
        api.reloadSavedSessionForTesting(.init(accessToken: "other-fixture", expiration: .distantFuture),
                                         realmID: "fixture-realm")
        #expect(throws: WorkspaceProviderAccessError.self) { try run.check() }
    }

    @Test func explicitReconnectInvalidatesRunEvenWhenRealmAndTokenLookUnchanged() throws {
        let api = api { reply($0) }
        let saved = try #require(api.tokens)
        let lifecycle = QuickBooksSyncLifecycle()
        let run = try lifecycle.begin(api: api, validateAccess: {})
        api.storeTokens(saved, realmID: "fixture-realm")
        #expect(throws: WorkspaceProviderAccessError.self) { try run.check() }
    }

    @Test func changedSavedEnvironmentOrScopeInvalidatesSync() throws {
        for changeEnvironment in [true, false] {
            let api = api { reply($0) }
            let saved = try #require(api.tokens)
            let lifecycle = QuickBooksSyncLifecycle()
            let run = try lifecycle.begin(api: api, validateAccess: {})
            api.reloadSavedSessionForTesting(saved, realmID: "fixture-realm",
                environment: changeEnvironment ? "other-environment" : nil,
                scopeSignature: changeEnvironment ? nil : "different-scope")
            #expect(throws: WorkspaceProviderAccessError.self) { try run.check() }
        }
    }

    private func configuration(_ label: String) -> BackendQuickBooksAccountingConfiguration {
        .init(realmID: "fixture-realm", environment: "sandbox",
            defaultSalesItemRef: "item", defaultSalesItemName: label, defaultSalesItemType: "Service",
            defaultIncomeAccountRef: "income", defaultIncomeAccountName: "Income", defaultIncomeAccountType: "Income",
            defaultExpenseAccountRef: "expense", defaultExpenseAccountName: "Expense", defaultExpenseAccountType: "Expense",
            defaultAPAccountRef: "ap", defaultAPAccountName: "AP", defaultAPAccountType: "Accounts Payable",
            defaultBankAccountRef: "bank", defaultBankAccountName: "Bank", defaultBankAccountType: "Bank",
            defaultCreditCardAccountRef: "card", defaultCreditCardAccountName: "Card", defaultCreditCardAccountType: "Credit Card",
            updatedAt: nil, updatedBy: nil)
    }

    private final class Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            opened = true
            let pending = waiters
            waiters = []
            for waiter in pending { waiter.resume() }
        }
    }

    @Test func accountingMappingRefreshCannotPublishAfterRunAccessChanges() async throws {
        let suite = "GunnAireSyncMappingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var allowed = true
        let store = QuickBooksAccountingConfigurationStore(defaults: defaults) {
            allowed = false
            return configuration("Must not cache")
        }
        await store.refresh(realmID: "fixture-realm", environment: "sandbox", force: true) {
            guard allowed else { throw CompanyWorkspaceFailure.administratorRequired }
        }
        #expect(store.configuration == nil)
        #expect(store.configuration(for: "fixture-realm", environment: "sandbox") == nil)
        #expect(!store.isLoading)
    }

    @Test func lateMappingRefreshCannotReplaceNewerConfigurationOrClearItsSpinner() async throws {
        let suite = "GunnAireSyncMappingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let startedFirst = Gate(), releaseFirst = Gate(), startedSecond = Gate(), releaseSecond = Gate()
        var requests = 0
        let store = QuickBooksAccountingConfigurationStore(defaults: defaults) {
            requests += 1
            if requests == 1 {
                startedFirst.open()
                await releaseFirst.wait()
                return configuration("Old mapping")
            }
            startedSecond.open()
            await releaseSecond.wait()
            return configuration("New mapping")
        }
        let first = Task { await store.refresh(realmID: "fixture-realm", environment: "sandbox", force: true) }
        await startedFirst.wait()
        let second = Task { await store.refresh(realmID: "fixture-realm", environment: "sandbox", force: true) }
        await startedSecond.wait()
        releaseFirst.open()
        await first.value
        #expect(store.isLoading)
        #expect(store.configuration == nil)
        releaseSecond.open()
        await second.value
        #expect(!store.isLoading)
        #expect(store.configuration?.defaultSalesItemName == "New mapping")
        #expect(store.configuration(for: "fixture-realm", environment: "sandbox")?.defaultSalesItemName == "New mapping")
    }

    @Test func matchingMappingRefreshPublishesAndCachesOnlyCompleteConfiguration() async throws {
        let suite = "GunnAireSyncMappingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = QuickBooksAccountingConfigurationStore(defaults: defaults) { configuration("Confirmed mapping") }
        await store.refresh(realmID: "fixture-realm", environment: "sandbox", force: true)
        #expect(store.configuration?.defaultSalesItemName == "Confirmed mapping")
        #expect(store.configuration(for: "another-realm", environment: "sandbox") == nil)
        #expect(!store.isLoading)
    }

    @Test func deniedMappingRefreshDoesNotMakeABackendRequest() async throws {
        let suite = "GunnAireSyncMappingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var requests = 0
        let store = QuickBooksAccountingConfigurationStore(defaults: defaults) {
            requests += 1
            return configuration("Must not load")
        }
        await store.refresh(realmID: "fixture-realm", environment: "sandbox", force: true) {
            throw CompanyWorkspaceFailure.administratorRequired
        }
        #expect(requests == 0)
        #expect(store.configuration == nil)
        #expect(!store.isLoading)
    }

}
