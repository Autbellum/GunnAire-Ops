import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor
struct QuickBooksBillingWorkflowTests {
    @MainActor final class Fixture {
        let context: ModelContext
        let customer: Customer
        let item: Item
        let invoice: Invoice
        let estimate: Estimate
        let owner = QuickBooksSyncLifecycle()
        var requests: [URLRequest] = []
        var authorized = true
        var catalogAuthorized = true
        var documents: [[String: Any]] = []
        var customers: [[String: Any]] = []
        var remoteItems: [[String: Any]] = []
        var customerPublisher: CustomerPublicationBoundary.Transport?
        var billingPublisher: BillingPublicationClient?
        var billingJournal: BillingNativeJournalStore?
        var documentFixture: QuickBooksDocumentWorkflowFixture?
        var beforeResponse: ((URLRequest) throws -> Void)?
        var transformDocument: (([String: Any]) -> [String: Any])?
        lazy var api = QuickBooksDataAPI(testTokens: .init(accessToken: "billing-fixture", expiration: .distantFuture),
            realmID: "billing-realm", environment: Config.QuickBooks.environment,
            catalogCompanyID: UUID(uuidString: "10000000-0000-4000-8000-000000000001"),
            customerPublisher: customerPublisher, billingPublisher: billingPublisher) { [unowned self] request in
                self.requests.append(request)
                try self.beforeResponse?(request)
                return try self.reply(request)
            }

        init(mapped: Bool = true, linkedInvoice: Bool = false) throws {
            let schema = GunnAireModelSchema.schema
            context = ModelContext(try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            ]))
            customer = Customer(quickBooksID: mapped ? "C1" : nil, name: "Fixture customer", email: "fixture@example.invalid")
            item = Item(quickBooksID: mapped ? "I1" : nil, name: "Diagnostic", unitPrice: 190)
            invoice = Invoice(customer: customer, quickBooksID: linkedInvoice ? "D1" : nil,
                catalogSnapshotJSON: CatalogLineItemSnapshot.encoded(from: [item]), amount: 190,
                dueDate: QuickBooksDateOnly.date(from: "2026-09-30"))
            estimate = Estimate(customer: customer, catalogSnapshotJSON: CatalogLineItemSnapshot.encoded(from: [item]), amount: 190)
            context.insert(customer); context.insert(item); context.insert(invoice); context.insert(estimate)
            try context.save()
        }

        func flow(estimate: Bool = false, save: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws -> QuickBooksBillingWorkflow {
            try QuickBooksBillingWorkflow(document: estimate ? .estimate(self.estimate) : .invoice(invoice),
                context: context, api: api, lifecycle: owner,
                validateAccess: { if !self.authorized { throw QuickBooksBillingWorkflowError.accessDenied } },
                validateCatalogAccess: { if !self.catalogAuthorized { throw CompanyWorkspaceFailure.administratorRequired } },
                billingJournal: billingJournal,
                documentUploads: documentFixture?.dependencies(check: {
                    if !self.authorized { throw QuickBooksBillingWorkflowError.accessDenied }
                }),
                save: save)
        }

        var configuration: BackendQuickBooksAccountingConfiguration {
            .init(realmID: "billing-realm", environment: Config.QuickBooks.environment,
                  defaultSalesItemRef: "I1", defaultSalesItemName: "Service", defaultSalesItemType: "Service",
                  defaultIncomeAccountRef: "INCOME", defaultIncomeAccountName: "Sales", defaultIncomeAccountType: "Income",
                  defaultExpenseAccountRef: "EXPENSE", defaultExpenseAccountName: "Costs", defaultExpenseAccountType: "Expense",
                  defaultAPAccountRef: "AP", defaultAPAccountName: "Payable", defaultAPAccountType: "Accounts Payable",
                  defaultBankAccountRef: "BANK", defaultBankAccountName: "Bank", defaultBankAccountType: "Bank",
                  defaultCreditCardAccountRef: "CC", defaultCreditCardAccountName: "Card", defaultCreditCardAccountType: "Credit Card",
                  updatedAt: nil, updatedBy: nil)
        }

        var customerResponse: [String: Any] {
            ["Id": "C1", "DisplayName": "Fixture customer", "PrimaryEmailAddr": ["Address": "fixture@example.invalid"]]
        }
        var itemResponse: [String: Any] {
            ["Id": "I1", "Name": "Diagnostic", "Type": "Service", "UnitPrice": item.unitPrice, "Taxable": false,
             "Active": true, "IncomeAccountRef": ["value": "INCOME"]]
        }
        func documentResponse(estimate: Bool = false) throws -> [String: Any] {
            let lines = try QuickBooksDocumentLinePublication.lines(snapshotJSON: invoice.catalogSnapshotJSON,
                expectedSubtotal: 190, catalogItems: [item])
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(lines))
            return ["Id": "D1", "SyncToken": "7", "CustomerRef": ["value": "C1"], "TotalAmt": 190,
                    "Balance": 190, "TxnTaxDetail": ["TotalTax": 0], "Line": encoded,
                    "PrivateNote": estimate ? QuickBooksEstimateLineage.operationMarker(for: self.estimate)
                        : QuickBooksInvoiceLineage.operationMarker(for: invoice)]
        }

        func reply(_ request: URLRequest) throws -> (Data, URLResponse) {
            let path = request.url!.path
            var result: [String: Any]
            if path.hasSuffix("/query") {
                let sql = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value ?? ""
                let entity = sql.contains("Customer") ? "Customer" : sql.contains("Item") ? "Item" : sql.contains("Estimate") ? "Estimate" : "Invoice"
                result = ["QueryResponse": [entity: entity == "Customer" ? customers : entity == "Item" ? remoteItems : documents]]
            } else if path.hasSuffix("/customer") {
                result = ["Customer": customerResponse]
            } else if path.hasSuffix("/item") {
                result = ["Item": itemResponse]
            } else if path.hasSuffix("/upload") {
                result = ["AttachableResponse": [["Attachable": ["Id": "A1"]]]]
            } else {
                let isEstimate = path.hasSuffix("/estimate")
                var remote = try documentResponse(estimate: isEstimate)
                if let data = request.httpBody, let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    for key in ["Line", "PrivateNote", "DueDate", "CustomerRef"] { if let value = payload[key] { remote[key] = value } }
                }
                remote = transformDocument?(remote) ?? remote
                result = [isEstimate ? "Estimate" : "Invoice": remote]
            }
            return (try JSONSerialization.data(withJSONObject: result),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        func addAttachment() throws -> ServiceDocumentAttachment {
            // A unique fixture-only file, never a user document.
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("billing-fixture-\(UUID()).txt")
            try Data("Fixture service report".utf8).write(to: url)
            let value = ServiceDocumentAttachment(customer: customer, serviceCallID: nil, invoiceID: invoice.id,
                kind: .serviceReport, displayName: "Fixture report", localFilePath: url.path,
                contentType: "text/plain", fileSizeBytes: 22)
            context.insert(value); try context.save()
            return value
        }
    }

    private func fails(_ body: () async throws -> Void) async {
        do { try await body(); Issue.record("Expected guarded workflow to stop") } catch {}
    }

    private func addTaxAddresses(_ f: Fixture) throws {
        f.item.isTaxable = true
        let address = BillingPublicationAddress(Line1: "12 Main Street", City: "Raleigh",
            CountrySubDivisionCode: "NC", PostalCode: "27601")
        let tax = try BillingTaxAddressContext(scope: .init(customerID: f.customer.id,
            serviceLocationID: nil, siteAddress: nil), service: address,
            origin: .init(Line1: "40 Shop Street", City: "Cary", CountrySubDivisionCode: "NC", PostalCode: "27511"))
        let json = try BillingTaxAddressContext.attaching(tax, to: CatalogLineItemSnapshot.encoded(from: [f.item])!)
        f.invoice.catalogSnapshotJSON = json; f.estimate.catalogSnapshotJSON = json
        try f.context.save()
    }

    @Test func taxablePublicationChecksAddressesBeforeCustomerOrItemWrites() async throws {
        let f = try Fixture(mapped: false)
        f.item.isTaxable = true
        f.invoice.catalogSnapshotJSON = CatalogLineItemSnapshot.encoded(from: [f.item])
        try f.context.save()
        let flow = try f.flow()
        await #expect(throws: BillingTaxAddressError.required) { try await flow.execute() }
        #expect(f.requests.isEmpty); #expect(!flow.attemptedWrite)
        #expect(f.invoice.catalogLineSnapshots.first?.unitPrice == 190)
    }

    @Test func invoiceCreateAndUpdateSendReviewedServiceAndSaleAddresses() async throws {
        for linked in [false, true] {
            let f = try Fixture(linkedInvoice: linked)
            try addTaxAddresses(f)
            _ = try await f.flow().execute()
            let post = try #require(f.requests.last?.httpBody)
            let value = try JSONSerialization.jsonObject(with: post) as! [String: Any]
            #expect((value["ShipAddr"] as? [String: String])?["City"] == "Raleigh")
            #expect((value["ShipFromAddr"] as? [String: String])?["PostalCode"] == "27511")
            #expect(f.invoice.catalogLineSnapshots.first?.unitPrice == 190)
        }
    }

    @Test func estimatePublicationSendsBothAddressesWithoutCustomerEmailSend() async throws {
        let f = try Fixture()
        try addTaxAddresses(f)
        _ = try await f.flow(estimate: true).execute()
        let value = try JSONSerialization.jsonObject(with: #require(f.requests.last?.httpBody)) as! [String: Any]
        #expect((value["ShipAddr"] as? [String: String])?["CountrySubDivisionCode"] == "NC")
        #expect((value["ShipFromAddr"] as? [String: String])?["Line1"] == "40 Shop Street")
        #expect(f.requests.allSatisfy { !$0.url!.path.contains("/send") })
    }

    @Test func changedSiteStopsTaxablePublicationWithoutChangingSoldLines() async throws {
        let f = try Fixture()
        try addTaxAddresses(f)
        f.invoice.siteAddress = "A different property"
        let flow = try f.flow()
        await #expect(throws: BillingTaxAddressError.changed) { try await flow.execute() }
        #expect(f.requests.isEmpty); #expect(f.invoice.amount == 190)
    }

    @Test func changedAddressDuringProviderReadRejectsTheOldPublication() async throws {
        let f = try Fixture()
        try addTaxAddresses(f)
        f.beforeResponse = { _ in f.invoice.siteAddress = "Changed during request" }
        await fails { _ = try await f.flow().execute() }
        #expect(!f.requests.contains { $0.httpMethod == "POST" })
        #expect(f.invoice.quickBooksID == nil)
    }


    @Test func invalidSubtotalCannotCreateCustomerOrCatalogRecords() throws {
        let f = try Fixture(mapped: false)
        f.invoice.amount = 250
        #expect(throws: (any Error).self) { _ = try f.flow() }
        #expect(f.requests.isEmpty)
        #expect(f.customer.quickBooksID == nil)
    }

    @Test func invoiceUsesServerConfirmedCustomerAndRetainsSoldLines() async throws {
        let f = try Fixture(mapped: false)
        f.item.quickBooksID = "I1"
        var publications = 0
        f.customerPublisher = { request in
            publications += 1
            #expect(request.localCustomerID == f.customer.id)
            return .init(publication: .init(id: UUID(), companyID: request.companyID, realmID: request.realmID,
                environment: request.environment, localCustomerID: request.localCustomerID, state: "confirmed", providerID: "C1",
                updatedAt: "2026-09-07T00:00:00+00:00"), customer: .init(Id: "C1", DisplayName: "Fixture customer",
                    PrimaryPhone: nil, PrimaryEmailAddr: .init(Address: "fixture@example.invalid"), BillAddr: nil, Active: true), created: true)
        }
        f.beforeResponse = { request in
            let sql = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value ?? ""
            #expect(!sql.contains("Customer"))
            #expect(!request.url!.path.hasSuffix("/customer"))
        }
        let sold = f.invoice.catalogSnapshotJSON
        _ = try await f.flow().execute()
        #expect(publications == 1)
        #expect(f.customer.quickBooksID == "C1")
        #expect(f.invoice.quickBooksID == "D1")
        #expect(f.invoice.catalogSnapshotJSON == sold)
        #expect(f.invoice.amount == 190)
    }

    @Test func customerOfficeApprovalFailureLeavesFieldDocumentAndStopsInvoiceWrites() async throws {
        let f = try Fixture(mapped: false)
        f.item.quickBooksID = "I1"
        f.customerPublisher = { _ in throw CustomerPublicationError.accessRequired }
        let sold = f.invoice.catalogSnapshotJSON
        do { _ = try await f.flow().execute(); Issue.record("Customer approval denial bypassed") }
        catch { #expect(error as? CustomerPublicationError == .accessRequired) }
        #expect(f.requests.isEmpty)
        #expect(f.customer.quickBooksID == nil)
        #expect(f.invoice.quickBooksID == nil)
        #expect(f.invoice.catalogSnapshotJSON == sold)
        #expect(try f.context.fetch(FetchDescriptor<Invoice>()).count == 1)
    }


    @Test func deletedDocumentStopsAccessAndCannotReceiveALateFailure() async throws {
        let f = try Fixture()
        let flow = try f.flow()
        f.beforeResponse = { _ in
            f.context.delete(f.invoice)
            try f.context.save()
            throw URLError(.timedOut)
        }
        await fails { _ = try await flow.execute() }
        #expect(throws: QuickBooksBillingWorkflowError.accessDenied) {
            try QuickBooksBillingAccessPolicy.validate(context: f.context, document: .invoice(f.invoice))
        }
        #expect(throws: QuickBooksBillingWorkflowError.changed) { try flow.recordFailure(URLError(.timedOut)) }
        #expect(try f.context.fetch(FetchDescriptor<Invoice>()).isEmpty)
    }

    @Test func deletedCatalogRecordStopsBeforeReadingAnInvalidatedModel() async throws {
        let f = try Fixture()
        let flow = try f.flow()
        f.context.delete(f.item)
        try f.context.save()
        await fails { _ = try await flow.execute() }
        #expect(f.requests.isEmpty)
        #expect(f.invoice.quickBooksID == nil)
    }

    @Test func invalidStoredMoneyCannotBeHiddenByAClampedSubtotal() throws {
        let f = try Fixture(mapped: false)
        f.invoice.amount = -10
        f.invoice.salesTaxAmount = -200
        #expect(throws: QuickBooksBillingWorkflowError.changed) { _ = try f.flow() }
        #expect(f.requests.isEmpty)
    }

    @Test func currencyBoundaryFailsValidationWithoutAnIntegerTrap() throws {
        let f = try Fixture()
        f.item.unitPrice = Double(Int64.max) / 100
        f.invoice.catalogSnapshotJSON = CatalogLineItemSnapshot.encoded(from: [f.item])
        f.invoice.amount = f.item.unitPrice
        #expect(throws: (any Error).self) { _ = try f.flow() }
        #expect(throws: (any Error).self) {
            _ = try QuickBooksDocumentLinePublication.lines(snapshotJSON: f.invoice.catalogSnapshotJSON,
                expectedSubtotal: f.invoice.amount, catalogItems: [f.item])
        }
    }

    @Test func zeroPricedLineStillRequiresAnExplicitProviderAmount() throws {
        let f = try Fixture()
        f.item.unitPrice = 0
        let expected = try QuickBooksDocumentLinePublication.lines(snapshotJSON: CatalogLineItemSnapshot.encoded(from: [f.item]),
            expectedSubtotal: 0, catalogItems: [f.item])
        let data = try JSONEncoder().encode(expected)
        var rows = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        rows[0].removeValue(forKey: "Amount")
        let remote = try JSONDecoder().decode([QuickBooksLineItem].self, from: JSONSerialization.data(withJSONObject: rows))
        #expect(!QuickBooksBillingLineEvidence.matches(expected: expected, reported: remote))
    }

    @Test func providerLinePriceQuantityItemAndTaxMustMatchSoldSnapshot() throws {
        let f = try Fixture()
        let expected = try QuickBooksDocumentLinePublication.lines(snapshotJSON: f.invoice.catalogSnapshotJSON,
            expectedSubtotal: 190, catalogItems: [f.item])
        let data = try JSONEncoder().encode(expected)
        let rows = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let changes: [[String: Any]] = [
            ["ItemRef": ["value": "OTHER"]], ["Qty": 2], ["UnitPrice": 95], ["TaxCodeRef": ["value": "TAX"]]
        ]
        for change in changes {
            var altered = rows
            var details = try #require(altered[0]["SalesItemLineDetail"] as? [String: Any])
            details.merge(change) { _, new in new }
            altered[0]["SalesItemLineDetail"] = details
            let remote = try JSONDecoder().decode([QuickBooksLineItem].self,
                from: JSONSerialization.data(withJSONObject: altered))
            #expect(!QuickBooksBillingLineEvidence.matches(expected: expected, reported: remote))
        }
    }

    @Test func lateDocumentEditPreservesTheEditAndUnconfirmedStatus() async throws {
        let f = try Fixture()
        let flow = try f.flow()
        f.beforeResponse = { request in if request.httpMethod == "POST" { f.invoice.notes = "Changed after dispatch" } }
        await fails { _ = try await flow.execute() }
        #expect(f.invoice.notes == "Changed after dispatch")
        #expect(f.invoice.quickBooksID == nil)
        #expect(flow.attemptedWrite)
        #expect(throws: QuickBooksBillingWorkflowError.changed) { try flow.recordFailure(URLError(.timedOut)) }
    }

    @Test func wrongUpdateIdentityAndMissingTokenNeverSendAnUpdate() async throws {
        for change: [String: Any] in [["Id": "OTHER"], ["CustomerRef": ["value": "OTHER"]], ["SyncToken": ""]] {
            let f = try Fixture(linkedInvoice: true)
            f.transformDocument = { response in response.merging(change) { _, new in new } }
            await fails { _ = try await f.flow().execute() }
            #expect(f.requests.count == 1)
            #expect(f.requests.first?.httpMethod == "GET")
        }
    }

    @Test func attachmentSaveFailureDoesNotUndoConfirmedInvoice() async throws {
        let f = try Fixture()
        let attachment = try f.addAttachment()
        defer { try? FileManager.default.removeItem(at: attachment.localFileURL) }
        var saves = 0
        let flow = try f.flow(save: { context in
            saves += 1
            if saves > 1 { throw CocoaError(.fileWriteUnknown) }
            try context.save()
        })
        _ = try await flow.execute()
        await fails { try await flow.uploadLinkedAttachments() }
        #expect(f.invoice.quickBooksID == "D1")
        #expect(f.invoice.quickBooksSyncStatus == "synced")
        #expect(attachment.quickBooksAttachableID == nil)
        #expect(attachment.quickBooksAttachedEntityKeysRaw == nil)
    }

    @Test func completeCustomerItemInvoiceChainKeepsOriginalContextAndSoldPrice() async throws {
        let f = try Fixture(mapped: false)
        f.item.unitPrice = 210
        try f.context.save()
        let flow = try f.flow()
        _ = try await flow.execute(configuration: f.configuration)
        #expect(f.requests.map(\.httpMethod) == ["GET", "POST", "GET", "POST", "GET", "POST"])
        #expect(f.requests.allSatisfy { $0.url!.path.contains("/billing-realm/") })
        #expect(f.customer.quickBooksID == "C1")
        #expect(f.item.quickBooksID == "I1")
        #expect(f.item.unitPrice == 210)
        #expect(f.invoice.amount == 190)
        #expect(f.invoice.quickBooksID == "D1")
        #expect(f.invoice.quickBooksSyncStatus == "synced")
        let post = try #require(f.requests.last)
        let payload = try JSONDecoder().decode(QuickBooksInvoiceCreate.self, from: #require(post.httpBody))
        #expect(payload.Line.first?.SalesItemLineDetail.UnitPrice == 190)
        #expect(payload.DueDate == "2026-09-30")
        let ids = f.requests.filter { $0.httpMethod == "POST" }.compactMap {
            URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "requestid" }?.value
        }
        #expect(ids == [QuickBooksCustomerCreateOperation.requestID(for: f.customer.id),
            QuickBooksCatalogCreateOperation.requestID(for: f.item.id), QuickBooksInvoiceLineage.createRequestID(for: f.invoice)])
    }

    @Test func estimateUsesStableIdentityAndRetainsChangeOrderReason() async throws {
        let f = try Fixture()
        f.estimate.changeOrderReason = "Customer requested a higher-efficiency replacement"
        let flow = try f.flow(estimate: true)
        _ = try await flow.execute()
        #expect(f.estimate.quickBooksID == "D1")
        let request = try #require(f.requests.last)
        let payload = try JSONDecoder().decode(QuickBooksEstimateCreate.self, from: #require(request.httpBody))
        #expect(payload.PrivateNote?.contains("Change order reason: Customer requested") == true)
        #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "requestid" }?.value == QuickBooksEstimateLineage.createRequestID(for: f.estimate))
    }

    @Test func recoveryLinksExactDocumentWithoutAnotherWrite() async throws {
        let f = try Fixture()
        f.documents = [try f.documentResponse()]
        let result = try await f.flow().execute()
        #expect(result.recovered)
        #expect(f.requests.count == 1)
        #expect(f.invoice.quickBooksID == "D1")
    }

    @Test func conflictingRecoveryCannotAdoptAnotherCustomersDocument() async throws {
        let f = try Fixture()
        var remote = try f.documentResponse()
        remote["CustomerRef"] = ["value": "OTHER"]
        f.documents = [remote]
        await fails { _ = try await f.flow().execute() }
        #expect(f.invoice.quickBooksID == nil)
        #expect(f.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func duplicateLineageMarkersNeverStartAnotherCreate() async throws {
        let f = try Fixture()
        var other = try f.documentResponse(); other["Id"] = "D2"
        f.documents = [try f.documentResponse(), other]
        await fails { _ = try await f.flow().execute() }
        #expect(f.requests.count == 1)
        #expect(f.invoice.quickBooksID == nil)
    }

    @Test func olderReplayedLinesAreNotReportedAsTheCurrentInvoice() async throws {
        let f = try Fixture()
        var remote = try f.documentResponse()
        remote["Line"] = []
        f.documents = [remote]
        await fails { _ = try await f.flow().execute() }
        #expect(f.invoice.quickBooksSyncStatus == "pending")
        #expect(f.invoice.quickBooksID == nil)
    }

    @Test func paidOrMissingRemoteBalanceStopsUpdateBeforePOST() async throws {
        for balance: Double? in [0, 100, nil, -1, 200] {
            let f = try Fixture(linkedInvoice: true)
            f.transformDocument = { response in
                var changed = response; changed["Balance"] = balance
                return changed
            }
            await fails { _ = try await f.flow().execute() }
            #expect(f.requests.count == 1)
            #expect(f.requests.first?.httpMethod == "GET")
            #expect(f.invoice.quickBooksBalanceDue == nil)
        }
    }

    @Test func unpaidUpdateUsesFreshSyncTokenAndCompleteSnapshot() async throws {
        let f = try Fixture(linkedInvoice: true)
        _ = try await f.flow().execute()
        let request = try #require(f.requests.last)
        let payload = try JSONDecoder().decode(QuickBooksInvoiceUpdate.self, from: #require(request.httpBody))
        #expect(payload.SyncToken == "7")
        #expect(payload.Id == "D1")
        #expect(payload.Line.count == 1)
        #expect(f.requests.count == 2)
        #expect(f.invoice.quickBooksBalanceDue == 190)
    }

    @Test func missingCreateBalanceLinksButBlocksCollectionUntilRefresh() async throws {
        let f = try Fixture()
        f.transformDocument = { response in var result = response; result.removeValue(forKey: "Balance"); return result }
        let result = try await f.flow().execute()
        #expect(f.invoice.quickBooksID == "D1")
        #expect(f.invoice.quickBooksSyncStatus == QuickBooksBalanceReconciliation.reviewState)
        #expect(f.invoice.quickBooksLastSyncedAt == nil)
        #expect(result.message.contains("Review"))
    }

    @Test func accountReplacementBeforeSchedulingSendsNothing() async throws {
        let f = try Fixture()
        let flow = try f.flow()
        f.api.storeTokens(.init(accessToken: "replacement-fixture", expiration: .distantFuture), realmID: "another-realm")
        await fails { _ = try await flow.execute() }
        #expect(f.requests.isEmpty)
    }

    @Test func accountReplacementBetweenCustomerAndItemsStopsTheWholeChain() async throws {
        let f = try Fixture(mapped: false)
        let flow = try f.flow()
        f.beforeResponse = { request in
            if request.url!.path.hasSuffix("/customer") {
                f.api.storeTokens(.init(accessToken: "replacement-fixture", expiration: .distantFuture), realmID: "another-realm")
            }
        }
        await fails { _ = try await flow.execute(configuration: f.configuration) }
        #expect(f.requests.count == 2)
        #expect(f.customer.quickBooksID == nil)
        #expect(f.item.quickBooksID == nil)
        #expect(f.invoice.quickBooksID == nil)
    }

    @Test func revokedRoleOrCancellationCannotSaveLateInvoiceResult() async throws {
        for cancel in [false, true] {
            let f = try Fixture()
            let flow = try f.flow()
            f.beforeResponse = { request in
                if request.httpMethod == "POST" {
                    if cancel { f.owner.cancel() } else { f.authorized = false }
                }
            }
            await fails { _ = try await flow.execute() }
            #expect(f.invoice.quickBooksID == nil)
            #expect(flow.failureMessage(URLError(.timedOut)).contains("may have accepted"))
            #expect(throws: (any Error).self) { try flow.recordFailure(URLError(.timedOut)) }
        }
    }

    @Test func editsWhileLookingUpCustomerCannotCreateCustomerOrDocument() async throws {
        let f = try Fixture(mapped: false)
        let flow = try f.flow()
        f.beforeResponse = { _ in f.invoice.notes = "A newer customer instruction" }
        await fails { _ = try await flow.execute(configuration: f.configuration) }
        #expect(f.requests.count == 1)
        #expect(f.customer.quickBooksID == nil)
        #expect(f.invoice.notes == "A newer customer instruction")
    }

    @Test func editsWhilePublishingCatalogCannotPublishInvoiceOrOverwriteTheEdit() async throws {
        let f = try Fixture(mapped: false)
        let flow = try f.flow()
        f.beforeResponse = { request in
            if request.url!.path.hasSuffix("/item") { f.invoice.amount = 250 }
        }
        await fails { _ = try await flow.execute(configuration: f.configuration) }
        #expect(f.requests.count == 4)
        #expect(f.customer.quickBooksID == "C1")
        #expect(f.item.quickBooksID == nil)
        #expect(f.invoice.amount == 250)
        #expect(f.invoice.quickBooksID == nil)
    }

    @Test func newPaymentWhileRefreshingInvoiceStopsUpdate() async throws {
        let f = try Fixture(linkedInvoice: true)
        let flow = try f.flow()
        f.beforeResponse = { _ in f.context.insert(Payment(invoice: f.invoice, amount: 50)) }
        await fails { _ = try await flow.execute() }
        #expect(f.requests.count == 1)
    }

    @Test func orphanPaymentDoesNotCrashInvoiceMutationPolicy() throws {
        let f = try Fixture(linkedInvoice: true)
        let payment = Payment(invoice: f.invoice, amount: 20)
        payment.invoice = nil
        #expect(BillingInvoiceMutationPolicy.blockedMessage(for: f.invoice, payments: [payment]) == nil)
    }

    @Test func customerContactEditsAndDuplicateMappingsAreRejected() async throws {
        let f = try Fixture()
        let flow = try f.flow()
        f.customer.email = "changed@example.invalid"
        await fails { _ = try await flow.execute() }
        #expect(f.requests.isEmpty)
        let second = try Fixture()
        second.context.insert(Customer(quickBooksID: "C1", name: "Another customer"))
        #expect(throws: QuickBooksBillingWorkflowError.customerConflict) { _ = try second.flow() }
    }

    @Test func duplicateLocalDocumentAndCatalogUUIDsFailClosed() throws {
        let f = try Fixture()
        f.context.insert(Invoice(id: f.invoice.id, customer: f.customer, amount: 190))
        #expect(throws: QuickBooksBillingWorkflowError.changed) { _ = try f.flow() }
        let g = try Fixture()
        g.context.insert(Item(id: g.item.id, quickBooksID: "I2", name: "Duplicate", unitPrice: 190))
        #expect(throws: QuickBooksBillingWorkflowError.changed) { _ = try g.flow() }
    }

    @Test func localConfirmationSaveFailureRestoresOnlyWorkflowFields() async throws {
        let f = try Fixture()
        let flow = try f.flow(save: { _ in throw CocoaError(.fileWriteUnknown) })
        await fails { _ = try await flow.execute() }
        #expect(f.invoice.quickBooksID == nil)
        #expect(f.invoice.quickBooksBalanceDue == nil)
        #expect(f.invoice.quickBooksLastSyncedAt == nil)
        #expect(f.invoice.quickBooksSyncStatus == "pending")
        #expect(f.invoice.amount == 190)
        #expect(flow.attemptedWrite)
    }

    @Test func customerConfirmationSaveFailureStopsBeforeCatalogWork() async throws {
        let f = try Fixture(mapped: false)
        let flow = try f.flow(save: { _ in throw CocoaError(.fileWriteUnknown) })
        await fails { _ = try await flow.execute(configuration: f.configuration) }
        #expect(f.requests.count == 2)
        #expect(f.customer.quickBooksID == nil)
        #expect(f.item.quickBooksID == nil)
    }

    @Test func failedReconciliationReadNeverFallsThroughToCreate() async throws {
        let f = try Fixture()
        f.beforeResponse = { _ in throw URLError(.timedOut) }
        let flow = try f.flow()
        await fails { _ = try await flow.execute() }
        #expect(f.requests.count == 1)
        #expect(!flow.attemptedWrite)
        try flow.recordFailure(URLError(.timedOut))
        #expect(f.invoice.quickBooksSyncStatus == "needs_attention")
        #expect(f.invoice.quickBooksLastSyncedAt == nil)
    }

    @Test func fieldRoleCanUseApprovedMappedItemsButCannotPromoteNewCatalogItems() async throws {
        let f = try Fixture()
        f.catalogAuthorized = false
        _ = try await f.flow().execute()
        #expect(f.invoice.quickBooksID == "D1")
        let g = try Fixture()
        g.item.quickBooksID = nil
        g.catalogAuthorized = false
        await fails { _ = try await g.flow().execute(configuration: g.configuration) }
        #expect(g.requests.isEmpty)
        #expect(g.invoice.quickBooksID == nil)
    }

    @Test func rolesRequireMatchingActiveRecordsAndCurrentAssignment() {
        let email = "tech@fixture.invalid"
        for role in AppUserRole.allCases {
            let user = AppUser(email: email, role: role)
            for invoice in [true, false] {
                let allowed = QuickBooksBillingAccessPolicy.allows(email: email, users: [user],
                    verifiedRole: role, isInvoice: invoice, assignedToJob: false)
                #expect(allowed == (role == .admin || (role == .accounting && invoice) || (role == .dispatcher && !invoice)))
            }
            user.isActive = false
            #expect(!QuickBooksBillingAccessPolicy.allows(email: email, users: [user], verifiedRole: role,
                isInvoice: true, assignedToJob: true))
        }
        let tech = AppUser(email: email, role: .fieldTechnician)
        #expect(QuickBooksBillingAccessPolicy.allows(email: email, users: [tech], verifiedRole: .fieldTechnician,
            isInvoice: true, assignedToJob: true))
        #expect(!QuickBooksBillingAccessPolicy.allows(email: email, users: [tech], verifiedRole: .admin,
            isInvoice: true, assignedToJob: true))
        #expect(!QuickBooksBillingAccessPolicy.allows(email: AppAccess.primaryAdminEmail, users: [], verifiedRole: .admin,
            isInvoice: true, assignedToJob: true))
    }

    @Test func overlappingDocumentRunDoesNotReplaceTheOriginal() throws {
        let f = try Fixture()
        let flow = try f.flow()
        #expect(throws: QuickBooksBillingWorkflowError.busy) { _ = try f.flow() }
        #expect(f.owner.isCurrent(flow.run))
    }

    @Test func fileFollowupUsesTheSameWorkflowAndSavesReferenceEvidence() async throws {
        let f = try Fixture()
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        f.documentFixture = files
        let attachment = try f.addAttachment()
        defer { try? FileManager.default.removeItem(at: attachment.localFileURL) }
        let flow = try f.flow()
        _ = try await flow.execute()
        try await flow.uploadLinkedAttachments()
        #expect(attachment.quickBooksAttachableID == "A1")
        #expect(attachment.quickBooksAttachedEntityKeysRaw?.contains("D1") == true)
        #expect(files.requests.last?.path.hasSuffix("/send") == true)
        #expect(try files.store.list(files.owner).first?.file.filename == "Fixture report.txt")
        #expect(f.requests.allSatisfy { !$0.url!.path.hasSuffix("/upload") })
        try await flow.uploadLinkedAttachments()
        #expect(files.sends == 1); #expect(files.reservations == 1)
    }

    @Test func editedFileCannotReceiveALateUploadConfirmation() async throws {
        let f = try Fixture()
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        f.documentFixture = files
        let attachment = try f.addAttachment()
        defer { try? FileManager.default.removeItem(at: attachment.localFileURL) }
        let flow = try f.flow()
        _ = try await flow.execute()
        files.beforeResponse = { path in
            if path.hasSuffix("/send") { attachment.caption = "Newer file description" }
        }
        await fails { try await flow.uploadLinkedAttachments() }
        #expect(attachment.quickBooksAttachableID == nil)
        #expect(attachment.quickBooksSyncError == nil)
        #expect(f.invoice.quickBooksID == "D1")
        #expect(f.invoice.quickBooksSyncStatus == "synced")
        #expect(files.sends == 1)
        #expect(try files.store.list(files.owner).first?.dispatchStarted == true)
    }
}
