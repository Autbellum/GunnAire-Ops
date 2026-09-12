import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor
struct QuickBooksCatalogWorkflowTests {
    private func context(_ item: Item) throws -> ModelContext {
        let schema = GunnAireModelSchema.schema
        let context = ModelContext(try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ]))
        context.insert(item)
        try context.save()
        return context
    }

    private func api(_ transport: @escaping WorkspaceProviderOperation.Transport) -> QuickBooksDataAPI {
        QuickBooksDataAPI(testTokens: .init(accessToken: "catalog-fixture", expiration: .distantFuture),
            realmID: "catalog-realm", environment: Config.QuickBooks.environment, transport: transport)
    }

    private func configuration(realm: String = "catalog-realm") -> BackendQuickBooksAccountingConfiguration {
        .init(realmID: realm, environment: Config.QuickBooks.environment,
              defaultSalesItemRef: "I1", defaultSalesItemName: "Service", defaultSalesItemType: "Service",
              defaultIncomeAccountRef: "INCOME", defaultIncomeAccountName: "Sales", defaultIncomeAccountType: "Income",
              defaultExpenseAccountRef: "EXPENSE", defaultExpenseAccountName: "Costs", defaultExpenseAccountType: "Expense",
              defaultAPAccountRef: "AP", defaultAPAccountName: "Payable", defaultAPAccountType: "Accounts Payable",
              defaultBankAccountRef: "BANK", defaultBankAccountName: "Bank", defaultBankAccountType: "Bank",
              defaultCreditCardAccountRef: "CC", defaultCreditCardAccountName: "Card", defaultCreditCardAccountType: "Credit Card",
              updatedAt: nil, updatedBy: nil)
    }

    private func remote(id: String = "I1", name: String = "Diagnostic", price: Double = 190,
                        sku: String? = nil, type: String = "Service", token: String = "1") -> QuickBooksItem {
        .init(Id: id, SyncToken: token, Name: name, ItemType: type, Description: nil, Sku: sku,
              PurchaseDesc: nil, UnitPrice: price, PurchaseCost: nil, Taxable: false, Active: true,
              IncomeAccountRef: .init(value: "INCOME", name: "Sales"), ExpenseAccountRef: nil, PrefVendorRef: nil)
    }

    private func reply(_ request: URLRequest, items: [QuickBooksItem]) throws -> (Data, URLResponse) {
        let data = request.url!.path.hasSuffix("/query")
            ? try JSONEncoder().encode(QuickBooksItemQueryResponse(QueryResponse: .init(Item: items)))
            : try JSONEncoder().encode(QuickBooksItemResponse(Item: items[0]))
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    private func workflow(_ item: Item, _ context: ModelContext, _ api: QuickBooksDataAPI,
                          lifecycle: QuickBooksSyncLifecycle? = nil,
                          mode: QuickBooksCatalogWorkflow.Mode = .publish,
                          configuration: BackendQuickBooksAccountingConfiguration? = nil,
                          validate: @escaping () throws -> Void = {}) throws -> QuickBooksCatalogWorkflow {
        try QuickBooksCatalogWorkflow(item: item, context: context, api: api, lifecycle: lifecycle ?? QuickBooksSyncLifecycle(),
            mode: mode, configuration: configuration ?? self.configuration(), validateAccess: validate)
    }

    @Test func completeCreateUsesTheReviewedPayloadAndStableIdentityBeforeSaving() async throws {
        let item = Item(name: "Diagnostic", unitPrice: 190)
        let context = try context(item)
        var requests: [URLRequest] = []
        let api = api { request in
            requests.append(request)
            return try reply(request, items: request.httpMethod == "POST" ? [remote()] : [])
        }
        let flow = try workflow(item, context, api)
        let outcome = try await flow.execute()
        #expect(outcome.created)
        #expect(outcome.link == .synchronized)
        #expect(requests.map(\.httpMethod) == ["GET", "POST"])
        #expect(item.quickBooksID == "I1")
        #expect(item.quickBooksSyncStatus == "synced")
        let write = try #require(requests.last)
        let payload = try JSONDecoder().decode(QuickBooksItemCreate.self, from: #require(write.httpBody))
        #expect(payload.UnitPrice == 190)
        #expect(payload.IncomeAccountRef?.value == "INCOME")
        #expect(URLComponents(url: write.url!, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "requestid" })?.value == QuickBooksCatalogCreateOperation.requestID(for: item.id))
        #expect(requests.allSatisfy { $0.url!.path.contains("/catalog-realm/") })
    }

    @Test func exactExistingMatchLinksWithoutSendingAnotherCreate() async throws {
        let item = Item(name: "Diagnostic", unitPrice: 190)
        let context = try context(item)
        var requests: [String?] = []
        let api = api { requests.append($0.httpMethod); return try reply($0, items: [remote()]) }
        let result = try await workflow(item, context, api).execute()
        #expect(!result.created)
        #expect(requests == ["GET"])
        #expect(item.quickBooksID == "I1")
    }

    @Test func aWorkflowCanDispatchOnlyOnceEvenIfCalledAgain() async throws {
        let item = Item(name: "Diagnostic", unitPrice: 190)
        let context = try context(item)
        var count = 0
        let api = api { count += 1; return try reply($0, items: [remote()]) }
        let flow = try workflow(item, context, api)
        _ = try await flow.execute()
        do { _ = try await flow.execute(); Issue.record("Workflow reused") }
        catch { #expect(error as? QuickBooksCatalogWorkflowError == .busy) }
        #expect(count == 1)
    }

    @Test func aReplayedOlderPriceNeverReplacesTheApprovedProposal() async throws {
        let item = Item(name: "Diagnostic", unitPrice: 210)
        let context = try context(item)
        let api = api { try reply($0, items: $0.httpMethod == "POST" ? [remote(price: 190)] : []) }
        let result = try await workflow(item, context, api).execute()
        #expect(result.link == .reconciliationRequired(differenceCount: 1))
        #expect(item.unitPrice == 210)
        #expect(item.quickBooksID == "I1")
        #expect(item.quickBooksSyncStatus == "pending_update")
    }

    @Test func approvalConfirmationRejectsEveryChangedProviderFieldAndApproval() throws {
        let changes: [(Item) -> Void] = [
            { $0.name = "Replacement" }, { $0.unitPrice += 0.001 }, { $0.purchaseCost = 30 },
            { $0.isTaxable = true }, { $0.sku = "SKU" }, { $0.itemDescription = "New" },
            { $0.purchaseDescription = "New purchase" }, { $0.preferredVendorQuickBooksID = "V1" },
            { $0.itemTypeRawValue = "NonInventory" }, { $0.quickBooksID = "OTHER" },
            { $0.pricebookReviewStatus = .archived }, { $0.pricebookReviewedByEmail = "new-reviewer@fixture.invalid" }
        ]
        for change in changes {
            let item = Item(name: "Diagnostic", unitPrice: 190)
            let confirmation = QuickBooksCatalogPublicationConfirmation.make(for: item, intent: .approval)
            try confirmation.validate(item)
            change(item)
            #expect(throws: QuickBooksCatalogWorkflowError.itemChanged) { try confirmation.validate(item) }
        }
    }

    @Test func fieldItemApprovalAndPublicationUnlockTheInvoiceWithoutChangingItsSoldPrice() async throws {
        let item = Item(pricebookReviewStatus: .needsReview, pricebookCreatedByEmail: "tech@fixture.invalid",
                        name: "Diagnostic", unitPrice: 190)
        let context = try context(item)
        let customer = Customer(quickBooksID: "C1", name: "Fixture customer")
        let invoice = Invoice(customer: customer, catalogSnapshotJSON: CatalogLineItemSnapshot.encoded(from: [item]), amount: 190)
        context.insert(customer)
        context.insert(invoice)
        try context.save()
        #expect(throws: QuickBooksDocumentLinePublicationError.pricebookReviewRequired("Diagnostic")) {
            _ = try QuickBooksInvoicePublicationRecovery.publicationInputs(for: invoice, catalogItems: [item], payments: [])
        }
        item.unitPrice = 210
        item.approveForPricebook(by: "admin@fixture.invalid")
        try context.save()
        let api = api { try reply($0, items: $0.httpMethod == "POST" ? [remote(price: 210)] : []) }
        _ = try await workflow(item, context, api).execute()
        let inputs = try QuickBooksInvoicePublicationRecovery.publicationInputs(for: invoice, catalogItems: [item], payments: [])
        let line = try #require(inputs.lines.first)
        #expect(line.SalesItemLineDetail.ItemRef.value == "I1")
        #expect(line.SalesItemLineDetail.UnitPrice == 190)
        #expect(line.Amount == 190)
        #expect(item.unitPrice == 210)
        #expect(invoice.amount == 190)
    }

    @Test func invoiceLinesCannotPickTheFirstOfTwoLocalRecordsWithTheSameIdentity() throws {
        let first = Item(quickBooksID: "I1", name: "Diagnostic", unitPrice: 190)
        let other = Item(id: first.id, quickBooksID: "I2", name: "Different item", unitPrice: 190)
        let snapshot = CatalogLineItemSnapshot.encoded(from: [first])
        for catalog in [[first, other], [other, first]] {
            #expect(throws: QuickBooksDocumentLinePublicationError.ambiguousLocalCatalogItem("Diagnostic")) {
                _ = try QuickBooksDocumentLinePublication.lines(snapshotJSON: snapshot, expectedSubtotal: 190, catalogItems: catalog)
            }
        }
        #expect(first.quickBooksID == "I1")
        #expect(other.quickBooksID == "I2")
    }

    @Test func invoiceCatalogMergingKeepsConflictsInsteadOfOverwritingByUUID() throws {
        let first = Item(quickBooksID: "I1", name: "Diagnostic", unitPrice: 190)
        let other = Item(id: first.id, quickBooksID: "I2", name: "Different item", unitPrice: 190)
        let catalog = QuickBooksDocumentLinePublication.catalogIncluding([first], storedItems: [other, first])
        #expect(catalog.count == 2)
        #expect(catalog.contains { $0 === other })
        #expect(catalog.contains { $0 === first })
        #expect(throws: QuickBooksDocumentLinePublicationError.ambiguousLocalCatalogItem("Diagnostic")) {
            _ = try QuickBooksDocumentLinePublication.lines(snapshotJSON: CatalogLineItemSnapshot.encoded(from: [first]),
                expectedSubtotal: 190, catalogItems: catalog)
        }
    }

    @Test func replacementConnectionBeforeSchedulingSendsNothing() async throws {
        let item = Item(name: "Diagnostic", unitPrice: 190)
        let context = try context(item)
        var count = 0
        let api = api { count += 1; return try reply($0, items: []) }
        let flow = try workflow(item, context, api)
        api.storeTokens(.init(accessToken: "replacement-fixture", expiration: .distantFuture), realmID: "replacement-realm")
        do { _ = try await flow.execute(); Issue.record("Replacement connection adopted") }
        catch { #expect(error is WorkspaceProviderAccessError) }
        #expect(count == 0)
        #expect(item.quickBooksID == nil)
    }

    @Test func replacementAfterTheReadCannotStartACreate() async throws {
        let item = Item(name: "Diagnostic", unitPrice: 190)
        let context = try context(item)
        var count = 0
        var current: QuickBooksDataAPI!
        current = api { request in
            count += 1
            current.storeTokens(.init(accessToken: "replacement-fixture", expiration: .distantFuture), realmID: "replacement-realm")
            return try reply(request, items: [])
        }
        let flow = try workflow(item, context, current)
        do { _ = try await flow.execute(); Issue.record("Create crossed provider identity") }
        catch { #expect(error is WorkspaceProviderAccessError) }
        #expect(count == 1)
        #expect(!flow.attemptedWrite)
    }

    @Test func anEditDuringTheReadStopsPublicationWithoutOverwritingTheEdit() async throws {
        let item = Item(name: "Diagnostic", unitPrice: 190)
        let context = try context(item)
        var count = 0
        let api = api { count += 1; item.unitPrice = 240; return try reply($0, items: []) }
        let flow = try workflow(item, context, api)
        do { _ = try await flow.execute(); Issue.record("Changed proposal was sent") }
        catch { #expect(error as? QuickBooksCatalogWorkflowError == .itemChanged) }
        #expect(count == 1)
        #expect(item.unitPrice == 240)
        #expect(throws: QuickBooksCatalogWorkflowError.itemChanged) { try flow.recordFailure(URLError(.timedOut)) }
        #expect(item.quickBooksSyncStatus == "pending")
    }

    @Test func anEditWhileCreateIsInFlightRetainsTheEditAndUnconfirmedOutcome() async throws {
        let item = Item(name: "Diagnostic", unitPrice: 190)
        let context = try context(item)
        let api = api { request in
            if request.httpMethod == "POST" { item.name = "Edited diagnostic" }
            return try reply(request, items: request.httpMethod == "POST" ? [remote()] : [])
        }
        let flow = try workflow(item, context, api)
        do { _ = try await flow.execute(); Issue.record("Late response replaced edit") }
        catch { #expect(flow.failureMessage(error).contains("may have accepted")) }
        #expect(flow.attemptedWrite)
        #expect(item.name == "Edited diagnostic")
        #expect(item.quickBooksID == nil)
    }

    @Test func cancellationAfterDispatchCannotApplyOrMarkAnOldItemFailed() async throws {
        let item = Item(name: "Diagnostic", unitPrice: 190)
        let context = try context(item)
        let lifecycle = QuickBooksSyncLifecycle()
        let api = api { request in
            if request.httpMethod == "POST" { lifecycle.cancel() }
            return try reply(request, items: request.httpMethod == "POST" ? [remote()] : [])
        }
        let flow = try workflow(item, context, api, lifecycle: lifecycle)
        do { _ = try await flow.execute(); Issue.record("Cancelled write applied") }
        catch {
            #expect(error is CancellationError)
            #expect(flow.failureMessage(error).contains("may have accepted"))
            #expect(throws: CancellationError.self) { try flow.recordFailure(error) }
        }
        #expect(item.quickBooksID == nil)
        #expect(item.quickBooksSyncStatus == "pending")
    }

    @Test func revokedAdministratorCannotSaveALateSuccessOrFailure() async throws {
        let item = Item(name: "Diagnostic", unitPrice: 190)
        let context = try context(item)
        var authorized = true
        let api = api { request in
            if request.httpMethod == "POST" { authorized = false }
            return try reply(request, items: request.httpMethod == "POST" ? [remote()] : [])
        }
        let flow = try workflow(item, context, api) {
            if !authorized { throw CompanyWorkspaceFailure.administratorRequired }
        }
        do { _ = try await flow.execute(); Issue.record("Revoked role saved") }
        catch {
            #expect(error as? CompanyWorkspaceFailure == .administratorRequired)
            #expect(throws: CompanyWorkspaceFailure.self) { try flow.recordFailure(error) }
        }
        #expect(item.quickBooksID == nil)
        #expect(item.quickBooksSyncDetail == nil)
    }

    @Test func overlappingActionsAreRejectedWithoutReplacingTheFirstRun() throws {
        let item = Item(name: "Diagnostic", unitPrice: 190)
        let context = try context(item)
        let lifecycle = QuickBooksSyncLifecycle()
        let api = api { try reply($0, items: []) }
        let first = try workflow(item, context, api, lifecycle: lifecycle)
        #expect(throws: QuickBooksCatalogWorkflowError.busy) {
            _ = try workflow(item, context, api, lifecycle: lifecycle)
        }
        #expect(lifecycle.isCurrent(first.run))
    }

    @Test func duplicateLocalIdentityAppearingDuringReadStopsTheWrite() async throws {
        let item = Item(name: "Diagnostic", unitPrice: 190)
        let context = try context(item)
        var count = 0
        let api = api { request in
            count += 1
            context.insert(Item(id: item.id, name: "Other local item", unitPrice: 55))
            return try reply(request, items: [])
        }
        do { _ = try await workflow(item, context, api).execute(); Issue.record("Ambiguous local identity sent") }
        catch { #expect(error as? QuickBooksCatalogWorkflowError == .itemChanged) }
        #expect(count == 1)
    }

    @Test func responseIdentityOwnedByAnotherItemCannotBeAssigned() async throws {
        let item = Item(name: "Diagnostic", unitPrice: 190)
        let context = try context(item)
        let owner = Item(quickBooksID: "I1", name: "Existing owner", unitPrice: 50)
        context.insert(owner)
        try context.save()
        let api = api { try reply($0, items: [remote()]) }
        do { _ = try await workflow(item, context, api).execute(); Issue.record("Identity stolen") }
        catch { #expect(error is QuickBooksCatalogMappingIntegrityError) }
        #expect(item.quickBooksID == nil)
        #expect(owner.name == "Existing owner")
    }

    @Test func successfulUpdateUsesTheReviewedRemoteVersionAndLocalProposal() async throws {
        let item = Item(quickBooksID: "I1", name: "Diagnostic", unitPrice: 230)
        let context = try context(item)
        var methods: [String?] = []
        var sent: QuickBooksItemUpdate?
        let api = api { request in
            methods.append(request.httpMethod)
            if let body = request.httpBody { sent = try JSONDecoder().decode(QuickBooksItemUpdate.self, from: body) }
            return try reply(request, items: [remote(price: request.httpMethod == "POST" ? 230 : 190)])
        }
        let result = try await workflow(item, context, api, mode: .update(remote())).execute()
        #expect(result.link == .synchronized)
        #expect(methods == ["GET", "POST"])
        #expect(sent?.SyncToken == "1")
        #expect(sent?.UnitPrice == 230)
        #expect(item.unitPrice == 230)
    }

    @Test func aNewRemoteVersionRequiresAnotherReviewBeforeEitherDirection() async throws {
        for useProvider in [false, true] {
            let item = Item(quickBooksID: "I1", name: "Diagnostic", unitPrice: 230)
            let context = try context(item)
            var methods: [String?] = []
            let api = api { methods.append($0.httpMethod); return try reply($0, items: [remote(price: 220, token: "2")]) }
            let mode: QuickBooksCatalogWorkflow.Mode = useProvider ? .useProvider(remote()) : .update(remote())
            do { _ = try await workflow(item, context, api, mode: mode).execute(); Issue.record("Unreviewed remote state applied") }
            catch { #expect(error as? QuickBooksCatalogWorkflowError == .reviewChanged) }
            #expect(methods == ["GET"])
            #expect(item.unitPrice == 230)
        }
    }

    @Test func choosingTheProviderVersionRechecksItBeforeTheLocalSave() async throws {
        let item = Item(quickBooksID: "I1", name: "Diagnostic", unitPrice: 230)
        let context = try context(item)
        var methods: [String?] = []
        let api = api { methods.append($0.httpMethod); return try reply($0, items: [remote()]) }
        let result = try await workflow(item, context, api, mode: .useProvider(remote())).execute()
        #expect(result.link == .synchronized)
        #expect(methods == ["GET"])
        #expect(item.unitPrice == 190)
    }

    @Test func aDifferentIdentityInAnUpdateResponseIsNotApplied() async throws {
        let item = Item(quickBooksID: "I1", name: "Diagnostic", unitPrice: 230)
        let context = try context(item)
        let api = api { try reply($0, items: [remote(id: $0.httpMethod == "POST" ? "OTHER" : "I1")]) }
        do { _ = try await workflow(item, context, api, mode: .update(remote())).execute(); Issue.record("Wrong update identity accepted") }
        catch { #expect(error as? QuickBooksCatalogWorkflowError == .remoteIdentity) }
        #expect(item.quickBooksID == "I1")
        #expect(item.unitPrice == 230)
    }

    @Test func failedLocalSaveRestoresExactFieldsIncludingAnUnlinkedVendorName() async throws {
        let item = Item(quickBooksID: "I1", name: "Diagnostic", unitPrice: 230,
                        preferredVendorName: "Saved supplier", purchaseDescription: "  saved purchase  ")
        let context = try context(item)
        let before = QuickBooksCatalogItemRevision(item)
        let api = api { try reply($0, items: [remote()]) }
        let flow = try QuickBooksCatalogWorkflow(item: item, context: context, api: api,
            lifecycle: QuickBooksSyncLifecycle(), mode: .useProvider(remote()), validateAccess: {},
            save: { _ in throw URLError(.cannotWriteToFile) })
        do { _ = try await flow.execute(); Issue.record("Failed save reported success") }
        catch { #expect(error as? QuickBooksCatalogWorkflowError == .saveFailed) }
        #expect(QuickBooksCatalogItemRevision(item) == before)
        #expect(item.preferredVendorName == "Saved supplier")
    }

    @Test func failureDoesNotAdvanceTheSuccessfulSyncTimestamp() throws {
        let item = Item(name: "Diagnostic", unitPrice: 190)
        item.quickBooksLastSyncedAt = Date(timeIntervalSinceReferenceDate: 100)
        let context = try context(item)
        let flow = try workflow(item, context, api { try reply($0, items: []) })
        try flow.recordFailure(URLError(.notConnectedToInternet))
        #expect(item.quickBooksSyncStatus == "needs_attention")
        #expect(item.quickBooksLastSyncedAt == Date(timeIntervalSinceReferenceDate: 100))
    }

    @Test func aLostCreateResponseIsRecoveredByReadingWithoutAnotherCreate() async throws {
        let item = Item(name: "Diagnostic", unitPrice: 190)
        let context = try context(item)
        var providerHasItem = false
        var writes = 0
        let api = api { request in
            if request.httpMethod == "POST" {
                writes += 1
                providerHasItem = true
                throw URLError(.timedOut)
            }
            return try reply(request, items: providerHasItem ? [remote()] : [])
        }
        let first = try workflow(item, context, api)
        do { _ = try await first.execute(); Issue.record("Lost response was accepted") }
        catch { try first.recordFailure(error) }
        #expect(item.quickBooksID == nil)
        #expect(item.quickBooksSyncDetail?.contains("may have accepted") == true)
        let recovered = try await workflow(item, context, api).execute()
        #expect(!recovered.created)
        #expect(writes == 1)
        #expect(item.quickBooksID == "I1")
    }

    @Test func aConfigurationFromAnotherRealmCannotSupplyAccountsForCreate() async throws {
        let item = Item(name: "Diagnostic", unitPrice: 190)
        let context = try context(item)
        var writes = 0
        let api = api { if $0.httpMethod == "POST" { writes += 1 }; return try reply($0, items: []) }
        do { _ = try await workflow(item, context, api, configuration: configuration(realm: "other")).execute(); Issue.record("Other realm mapping used") }
        catch { #expect(error is QuickBooksDataAPI.QBError) }
        #expect(writes == 0)
    }

    @Test func nameSkuAndTypeConflictsNeverBecomeAutomaticLinksOrCreates() throws {
        let item = Item(name: "Diagnostic", unitPrice: 190, sku: "DIAG")
        for candidate in [remote(sku: nil), remote(name: "Other", sku: "DIAG"),
                          remote(sku: "OTHER"), remote(sku: "DIAG", type: "NonInventory")] {
            #expect(throws: PricebookReviewPublicationError.self) {
                _ = try PricebookReviewPublication.matchingRemoteItem(for: item, in: [candidate])
            }
        }
    }

    @Test func unapprovedOrInvalidItemsCannotAllocateAPublicationRun() throws {
        for price in [-1.0, Double.infinity, Double.nan] {
            let item = Item(name: "Diagnostic", unitPrice: price)
            let context = try context(item)
            let lifecycle = QuickBooksSyncLifecycle()
            #expect(throws: QuickBooksCatalogWorkflowError.invalidItem) {
                _ = try workflow(item, context, api { try reply($0, items: []) }, lifecycle: lifecycle)
            }
            #expect(lifecycle.activeID == nil)
        }
        let item = Item(pricebookReviewStatus: .needsReview, name: "Diagnostic", unitPrice: 190)
        let context = try context(item)
        #expect(throws: QuickBooksCatalogWorkflowError.invalidItem) {
            _ = try workflow(item, context, api { try reply($0, items: []) })
        }
    }
}
