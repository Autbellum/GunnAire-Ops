import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor
struct CatalogServerPublicationTests {
    private let companyID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private let attemptID = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!

    private func context(_ item: Item) throws -> ModelContext {
        let schema = GunnAireModelSchema.schema
        let context = ModelContext(try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ]))
        context.insert(item)
        try context.save()
        return context
    }

    private func configuration() -> BackendQuickBooksAccountingConfiguration {
        .init(realmID: "catalog-realm", environment: Config.QuickBooks.environment,
            defaultSalesItemRef: "I1", defaultSalesItemName: "Service", defaultSalesItemType: "Service",
            defaultIncomeAccountRef: "INCOME", defaultIncomeAccountName: "Sales", defaultIncomeAccountType: "Income",
            defaultExpenseAccountRef: "EXPENSE", defaultExpenseAccountName: "Costs", defaultExpenseAccountType: "Expense",
            defaultAPAccountRef: "AP", defaultAPAccountName: "Payable", defaultAPAccountType: "Accounts Payable",
            defaultBankAccountRef: "BANK", defaultBankAccountName: "Bank", defaultBankAccountType: "Bank",
            defaultCreditCardAccountRef: "CC", defaultCreditCardAccountName: "Card", defaultCreditCardAccountType: "Credit Card",
            updatedAt: nil, updatedBy: nil)
    }

    private func remote(price: Double = 190, id: String = "I1") -> QuickBooksItem {
        .init(Id: id, SyncToken: "1", Name: "Diagnostic", ItemType: "Service", Description: nil, Sku: nil,
            PurchaseDesc: nil, UnitPrice: price, PurchaseCost: nil, Taxable: false, Active: true,
            IncomeAccountRef: .init(value: "INCOME", name: nil), ExpenseAccountRef: nil, PrefVendorRef: nil)
    }

    private func response(_ itemID: UUID, price: Double = 190, operation: String = "create",
                          company: UUID? = nil, attempt: UUID? = nil, state: String = "confirmed",
                          providerID: String = "I1", remoteID: String = "I1") -> CatalogPublicationResponse {
        .init(publication: .init(id: attempt ?? attemptID, companyID: company ?? companyID,
            realmID: "catalog-realm", environment: Config.QuickBooks.environment, localItemID: itemID,
            operation: operation, state: state, providerID: providerID, updatedAt: "2026-09-07T00:00:00+00:00"),
            item: remote(price: price, id: remoteID), created: operation == "create")
    }

    private func api(publisher: @escaping CatalogPublicationBoundary.Transport,
                     recovery: @escaping (UUID) async throws -> CatalogPublicationResponse = { _ in throw CatalogPublicationError.unavailable },
                     direct: @escaping WorkspaceProviderOperation.Transport = { _ in
                         Issue.record("A server catalog workflow used direct provider transport")
                         throw CatalogPublicationError.unavailable
                     }) -> QuickBooksDataAPI {
        QuickBooksDataAPI(testTokens: .init(accessToken: "fixture", expiration: .distantFuture),
            realmID: "catalog-realm", environment: Config.QuickBooks.environment,
            catalogCompanyID: companyID, catalogPublisher: publisher, catalogRecovery: recovery, transport: direct)
    }

    private func flow(_ item: Item, context: ModelContext, api: QuickBooksDataAPI,
                      mode: QuickBooksCatalogWorkflow.Mode = .publish, lifecycle: QuickBooksSyncLifecycle? = nil,
                      validate: @escaping () throws -> Void = {},
                      save: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws -> QuickBooksCatalogWorkflow {
        try .init(item: item, context: context, api: api, lifecycle: lifecycle ?? QuickBooksSyncLifecycle(),
                  mode: mode, configuration: configuration(), validateAccess: validate, save: save)
    }

    @Test func createRoutesThroughSharedPublisherWithExactScopeAndValues() async throws {
        let item = Item(name: "Diagnostic", unitPrice: 190)
        let context = try context(item)
        var calls = 0
        let api = api { request in
            calls += 1
            #expect(request.companyID == companyID)
            #expect(request.localItemID == item.id)
            #expect(request.realmID == "catalog-realm")
            #expect(request.operation == "create")
            let body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
            let payload = try #require(body["item"] as? [String: Any])
            #expect(payload["Name"] as? String == "Diagnostic")
            #expect(payload["UnitPrice"] as? Double == 190)
            #expect((payload["IncomeAccountRef"] as? [String: Any])?["value"] as? String == "INCOME")
            return response(item.id)
        }
        let result = try await flow(item, context: context, api: api).execute()
        #expect(calls == 1)
        #expect(result.created)
        #expect(item.quickBooksID == "I1")
    }

    @Test func serverFailureNeverFallsBackToDirectQuickBooks() async throws {
        let item = Item(name: "Diagnostic", unitPrice: 190)
        let context = try context(item)
        let api = api { _ in throw CatalogPublicationError.unavailable }
        do { _ = try await flow(item, context: context, api: api).execute(); Issue.record("Server failure ignored") }
        catch { #expect(error as? CatalogPublicationError == .unavailable) }
        #expect(item.quickBooksID == nil)
        #expect(item.unitPrice == 190)
    }

    @Test func responseCannotChangeCompanyItemStateOrProviderIdentity() async throws {
        for kind in 0..<4 {
            let item = Item(name: "Diagnostic", unitPrice: 190)
            let context = try context(item)
            let api = api { _ in
                response(kind == 1 ? UUID() : item.id, company: kind == 0 ? UUID() : nil,
                         state: kind == 2 ? "sending" : "confirmed", providerID: kind == 3 ? "OTHER" : "I1")
            }
            do { _ = try await flow(item, context: context, api: api).execute(); Issue.record("Wrong scope applied") }
            catch { #expect(error as? CatalogPublicationError == .invalidResponse) }
            #expect(item.quickBooksID == nil)
        }
    }

    @Test func changedProposalDuringServerRequestIsNotConfirmedLocally() async throws {
        let item = Item(name: "Diagnostic", unitPrice: 190)
        let context = try context(item)
        let api = api { _ in item.unitPrice = 210; return response(item.id) }
        do { _ = try await flow(item, context: context, api: api).execute(); Issue.record("Edited item overwritten") }
        catch { #expect(error as? QuickBooksCatalogWorkflowError == .itemChanged) }
        #expect(item.quickBooksID == nil)
        #expect(item.unitPrice == 210)
    }

    @Test func cancelledWorkflowRejectsLateServerConfirmation() async throws {
        let item = Item(name: "Diagnostic", unitPrice: 190)
        let context = try context(item)
        let lifecycle = QuickBooksSyncLifecycle()
        let api = api { _ in lifecycle.cancel(); return response(item.id) }
        do { _ = try await flow(item, context: context, api: api, lifecycle: lifecycle).execute(); Issue.record("Cancellation ignored") }
        catch { #expect(error is CancellationError) }
        #expect(item.quickBooksID == nil)
    }

    @Test func revokedAdminCannotApplyServerSuccess() async throws {
        let item = Item(name: "Diagnostic", unitPrice: 190)
        let context = try context(item)
        var allowed = true
        let api = api { _ in allowed = false; return response(item.id) }
        let run = try flow(item, context: context, api: api, validate: {
            if !allowed { throw CompanyWorkspaceFailure.administratorRequired }
        })
        do { _ = try await run.execute(); Issue.record("Revoked role applied") }
        catch { #expect(error as? CompanyWorkspaceFailure == .administratorRequired) }
        #expect(item.quickBooksID == nil)
    }

    @Test func failedLocalSaveRestoresProposalAndLeavesRecoverableOriginalItem() async throws {
        let item = Item(name: "Diagnostic", unitPrice: 190)
        let context = try context(item)
        let api = api { _ in response(item.id) }
        let run = try flow(item, context: context, api: api, save: { _ in throw CatalogPublicationError.unavailable })
        do { _ = try await run.execute(); Issue.record("Failed save reported success") }
        catch { #expect(error as? QuickBooksCatalogWorkflowError == .saveFailed) }
        #expect(item.quickBooksID == nil)
        #expect(item.quickBooksSyncStatus == "pending")
        #expect(run.committedRevision == nil)
    }

    @Test func recoveryUsesReadOnlyEndpointAndRetainsNewApprovedLocalValues() async throws {
        let item = Item(name: "Diagnostic", unitPrice: 220)
        let context = try context(item)
        var recovered: UUID?
        let api = api(publisher: { _ in Issue.record("Recovery published a new item"); throw CatalogPublicationError.unavailable },
                      recovery: { id in recovered = id; return response(item.id, price: 190) })
        let result = try await flow(item, context: context, api: api, mode: .recover(attemptID)).execute()
        #expect(recovered == attemptID)
        #expect(!result.created)
        #expect(result.link == .reconciliationRequired(differenceCount: 1))
        #expect(item.quickBooksID == "I1")
        #expect(item.unitPrice == 220)
    }

    @Test func recoveryRejectsDifferentAttemptResponse() async throws {
        let item = Item(name: "Diagnostic", unitPrice: 190)
        let context = try context(item)
        let api = api(publisher: { _ in response(item.id) }, recovery: { _ in response(item.id, attempt: UUID()) })
        do { _ = try await flow(item, context: context, api: api, mode: .recover(attemptID)).execute(); Issue.record("Wrong attempt recovered") }
        catch { #expect(error as? CatalogPublicationError == .invalidResponse) }
        #expect(item.quickBooksID == nil)
    }

    @Test func reviewedUpdateReadsExactVersionThenUsesServerPublisherOnly() async throws {
        let item = Item(quickBooksID: "I1", name: "Diagnostic", unitPrice: 220)
        let context = try context(item)
        var reads = 0
        var writes = 0
        let api = api(publisher: { request in
            writes += 1
            #expect(request.operation == "update")
            if case .update(let payload) = request.item {
                #expect(payload.Id == "I1")
                #expect(payload.SyncToken == "1")
                #expect(payload.UnitPrice == 220)
            } else { Issue.record("Update sent create payload") }
            return response(item.id, price: 220, operation: "update")
        }, direct: { request in
            reads += 1
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path.hasSuffix("/item/I1") == true)
            return (try JSONEncoder().encode(QuickBooksItemResponse(Item: remote())),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        _ = try await flow(item, context: context, api: api, mode: .update(remote())).execute()
        #expect(reads == 1)
        #expect(writes == 1)
        #expect(item.unitPrice == 220)
    }

    @Test func serverUpdateCannotReplaceTheExistingProviderID() async throws {
        let item = Item(quickBooksID: "I1", name: "Diagnostic", unitPrice: 220)
        let context = try context(item)
        let api = api(publisher: { _ in
            response(item.id, price: 220, operation: "update", providerID: "OTHER", remoteID: "OTHER")
        }, direct: { request in
            (try JSONEncoder().encode(QuickBooksItemResponse(Item: remote())),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        do { _ = try await flow(item, context: context, api: api, mode: .update(remote())).execute(); Issue.record("Existing QBO ID replaced") }
        catch { #expect(error as? QuickBooksCatalogWorkflowError == .remoteIdentity) }
        #expect(item.quickBooksID == "I1")
        #expect(item.unitPrice == 220)
    }

    @Test func recoveryCannotReplaceADifferentExistingProviderLink() async throws {
        let item = Item(quickBooksID: "I1", name: "Diagnostic", unitPrice: 190)
        let context = try context(item)
        let api = api(publisher: { _ in throw CatalogPublicationError.unavailable }, recovery: { _ in
            response(item.id, providerID: "OTHER", remoteID: "OTHER")
        })
        do { _ = try await flow(item, context: context, api: api, mode: .recover(attemptID)).execute(); Issue.record("Existing link replaced") }
        catch { #expect(error as? QuickBooksCatalogWorkflowError == .remoteIdentity) }
        #expect(item.quickBooksID == "I1")
    }


    @Test func malformedUnknownReviewStatesAreRejected() throws {
        let record = CatalogPublicationRecord(id: attemptID, companyID: companyID, realmID: "catalog-realm",
            environment: Config.QuickBooks.environment, localItemID: UUID(), operation: "create",
            state: "auto-retry", providerID: nil, updatedAt: "")
        #expect(throws: CatalogPublicationError.invalidResponse) {
            try record.validate(companyID: companyID, realmID: "catalog-realm", environment: Config.QuickBooks.environment,
                                itemID: record.localItemID)
        }
    }

    @Test func missingCompanyProofCannotConstructAPublicationRequest() throws {
        let api = QuickBooksDataAPI(testTokens: .init(accessToken: "fixture", expiration: .distantFuture),
            realmID: "catalog-realm", environment: Config.QuickBooks.environment,
            transport: { _ in throw CatalogPublicationError.unavailable })
        let workflow = try api.captureWorkspaceWorkflow()
        #expect(throws: CatalogPublicationError.accessRequired) {
            try CatalogPublicationBoundary.request(workflow: workflow, itemID: UUID(), payload: .create(
                QuickBooksCatalogCreateOperation.payload(for: Item(name: "Diagnostic", unitPrice: 190),
                    incomeAccountRef: .init(value: "INCOME", name: nil), expenseAccountRef: nil)))
        }
    }
}
