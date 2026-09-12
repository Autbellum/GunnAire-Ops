import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor struct SharedCatalogConnectionTests {
    @MainActor final class Fixture {
        let context: ModelContext
        let item = Item(name: "Diagnostic", unitPrice: 190)
        let company = UUID(), publication = UUID()
        let lifecycle = QuickBooksSyncLifecycle()
        var epoch = String(repeating: "a", count: 64)
        var authorized = true, visible = true, offline = false, loseReply = false
        var requests: [(String, String)] = []
        var writes = 0
        var remote: QuickBooksItem?
        var contextChanges: [String: Any] = [:]
        var beforeContext: () throws -> Void = {}

        init() throws {
            let schema = GunnAireModelSchema.schema
            context = ModelContext(try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            ]))
            context.insert(item); try context.save()
        }
        func remoteItem(price: Double = 190, token: String = "1") -> QuickBooksItem {
            .init(Id: "I1", SyncToken: token, Name: "Diagnostic", ItemType: "Service", Description: nil, Sku: nil,
                  PurchaseDesc: nil, UnitPrice: price, PurchaseCost: nil, Taxable: false, Active: true,
                  IncomeAccountRef: .init(value: "INCOME", name: nil), ExpenseAccountRef: nil, PrefVendorRef: nil)
        }
        func object<T: Encodable>(_ value: T) throws -> Any {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        }
        func response(created: Bool = false, operation: String = "create") throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "publication": ["id": publication.uuidString, "companyID": company.uuidString,
                    "localItemID": item.id.uuidString, "realmID": "catalog-realm", "environment": Config.QuickBooks.environment,
                    "operation": operation, "state": "confirmed", "providerID": "I1", "updatedAt": "2026-09-08T00:00:00Z"],
                "item": try object(remote!), "created": created
            ])
        }
        var client: SharedCatalogClient { .init { [self] path, method, body in
            requests.append((path, method))
            if offline { throw URLError(.notConnectedToInternet) }
            if path.hasPrefix("/api/catalog-publications/context?") {
                #expect(method == "GET" && body == nil)
                try beforeContext()
                var values: [String: Any] = ["companyID": company.uuidString, "localItemID": item.id.uuidString,
                    "realmID": "catalog-realm", "environment": Config.QuickBooks.environment, "protocolVersion": 1,
                    "connectionRevision": epoch, "incomeAccount": ["value": "INCOME"]]
                if let remote { values["item"] = try object(remote) }
                values.merge(contextChanges) { _, new in new }
                return try JSONSerialization.data(withJSONObject: values)
            }
            if path.hasSuffix("/recover") {
                #expect(path.contains(publication.uuidString.lowercased()))
                #expect(method == "POST" && body == Data("{}".utf8))
                return try response()
            }
            #expect(path == "/api/catalog-publications" && method == "POST")
            let payload = try JSONSerialization.jsonObject(with: #require(body)) as! [String: Any]
            #expect(UUID(uuidString: payload["companyID"] as! String) == company)
            #expect(UUID(uuidString: payload["localItemID"] as! String) == item.id)
            guard payload["connectionRevision"] as? String == epoch else { throw CatalogPublicationError.needsReview }
            let operation = payload["operation"] as! String
            let values = payload["item"] as! [String: Any]
            if remote == nil || operation == "update" {
                writes += 1; remote = remoteItem(price: values["UnitPrice"] as! Double, token: String(writes))
            }
            if loseReply { throw URLError(.networkConnectionLost) }
            return try response(created: operation == "create", operation: operation)
        } }
        func prepare() throws -> SharedCatalogPreparation {
            try .init(item: item, context: context, isCurrent: { [self] in visible }, client: client,
                      fixtureCompanyID: company, validateAccess: { [self] in
                          if !authorized { throw CatalogPublicationError.accessRequired }
                      })
        }
        func flow(_ mode: QuickBooksCatalogWorkflow.Mode = .publish) async throws -> QuickBooksCatalogWorkflow {
            try await prepare().makeWorkflow(lifecycle: lifecycle, mode: mode)
        }
        func finish(_ flow: QuickBooksCatalogWorkflow) { lifecycle.finish(flow.run) }
    }

    @Test func transportIsBusinessCatalogOnlyWithBoundedBodiesAndExactRoutes() {
        let base = "/api/catalog-publications", id = UUID().uuidString.lowercased()
        for path in [base + "?companyID=\(id)&localItemID=\(id)", base + "/context?companyID=\(id)&localItemID=\(id)"] {
            #expect(CatalogPublicationTransportPolicy.allows(path: path, method: "GET", bodyBytes: nil))
            #expect(!CatalogPublicationTransportPolicy.allows(path: path + "&realmID=foreign", method: "GET", bodyBytes: nil))
        }
        for path in [base, base + "/\(id)/recover", base + "/\(id)/cancel"] {
            #expect(CatalogPublicationTransportPolicy.allows(path: path, method: "POST", bodyBytes: 2))
            #expect(!CatalogPublicationTransportPolicy.allows(path: path, method: "POST", bodyBytes: 32769))
        }
        for path in ["https://foreign.invalid" + base, "//foreign.invalid" + base, base + "/", base + "//\(id)/recover",
                     base + "/\(id)/recover/", base + "/\(id)/delete", base + "/../users", base + "#fragment", "/api/payments",
                     base + "/context?companyID=\(id)&companyID=\(id)", base + "/context?companyID=bad&localItemID=\(id)"] {
            #expect(!CatalogPublicationTransportPolicy.allows(path: path, method: "POST", bodyBytes: 2))
            #expect(!CatalogPublicationTransportPolicy.allows(path: path, method: "GET", bodyBytes: nil))
        }
    }

    @Test func approvedFieldItemPublishesThroughBusinessLoginWithoutRepricingSoldInvoice() async throws {
        let f = try Fixture(), customer = Customer(name: "Fixture customer")
        f.item.markForPricebookReview(createdByEmail: "field@example.invalid")
        let invoice = Invoice(customer: customer, catalogSnapshotJSON: CatalogLineItemSnapshot.encoded(from: [f.item]), amount: 190)
        f.context.insert(customer); f.context.insert(invoice); try f.context.save()
        let original = invoice.catalogSnapshotJSON
        await #expect(throws: QuickBooksCatalogWorkflowError.invalidItem) { try await f.flow() }
        #expect(f.writes == 0)
        f.item.approveForPricebook(by: "office@example.invalid"); f.item.unitPrice = 250; try f.context.save()
        let flow = try await f.flow()
        #expect(flow.run.workflow.sharedBillingConnectionRevision == f.epoch)
        let result = try await flow.execute()
        #expect(result.created && f.writes == 1 && f.item.quickBooksID == "I1")
        #expect(invoice.catalogSnapshotJSON == original && invoice.amount == 190)
        #expect(f.requests.allSatisfy { $0.0.hasPrefix("/api/catalog-publications") })
        f.finish(flow)
    }

    @Test func comparisonSnapshotSurvivesRunCompletionAndAllowsFreshExplicitVersionChoice() async throws {
        let f = try Fixture(); f.item.quickBooksID = "I1"; f.remote = f.remoteItem(price: 240)
        let comparison = try await f.flow(.compare)
        let result = try await comparison.execute(); f.finish(comparison)
        try comparison.snapshotOwner.check()
        #expect(f.item.unitPrice == 190 && result.link == .reconciliationRequired(differenceCount: 1))
        let apply = try await f.flow(.useProvider(result.remote))
        _ = try await apply.execute(); f.finish(apply)
        #expect(f.item.unitPrice == 240 && f.writes == 0)
    }

    @Test func reviewedLocalUpdateUsesSharedPublisherAndOriginalItemOnly() async throws {
        let f = try Fixture(); f.item.quickBooksID = "I1"; f.item.unitPrice = 225; f.remote = f.remoteItem()
        let flow = try await f.flow(.update(f.remote!))
        _ = try await flow.execute(); f.finish(flow)
        #expect(f.item.quickBooksID == "I1" && f.item.unitPrice == 225 && f.writes == 1)
    }

    @Test func comparisonScopesCannotReuseAnotherGrantOrBusinessSnapshot() async throws {
        let f = try Fixture(), other = try Fixture()
        let first = try await f.flow(), differentBusiness = try await other.flow()
        let original = try #require(SharedCatalogComparisonScope(first.snapshotOwner))
        #expect(original != SharedCatalogComparisonScope(differentBusiness.snapshotOwner))
        f.finish(first); other.finish(differentBusiness)
        let same = try await f.flow()
        #expect(original == SharedCatalogComparisonScope(same.snapshotOwner)); f.finish(same)
        f.epoch = String(repeating: "b", count: 64)
        let replacement = try await f.flow()
        #expect(original != SharedCatalogComparisonScope(replacement.snapshotOwner)); f.finish(replacement)
        #expect(SharedCatalogComparisonScope(nil) == nil)
    }

    @Test func providerChangeAfterComparisonCannotApplyEitherReviewedVersion() async throws {
        for useProvider in [false, true] {
            let f = try Fixture(); f.item.quickBooksID = "I1"; let reviewed = f.remoteItem(); f.remote = f.remoteItem(price: 260, token: "2")
            let flow = try await f.flow(useProvider ? .useProvider(reviewed) : .update(reviewed))
            await #expect(throws: QuickBooksCatalogWorkflowError.reviewChanged) { try await flow.execute() }
            #expect(f.item.unitPrice == 190 && f.writes == 0); f.finish(flow)
        }
    }

    @Test func unavailableMappingDoesNotAdoptADeviceProviderIDOrCreateAnotherItem() async throws {
        let f = try Fixture(); f.item.quickBooksID = "legacy-I1"
        let flow = try await f.flow(.compare)
        await #expect(throws: QuickBooksCatalogWorkflowError.remoteIdentity) { try await flow.execute() }
        #expect(f.writes == 0 && f.item.quickBooksID == "legacy-I1"); f.finish(flow)
    }

    @Test func lostCreateReplyRecoversOriginalWithoutAnotherPublicationAndKeepsChangedProposal() async throws {
        let f = try Fixture(); f.loseReply = true
        let first = try await f.flow()
        await #expect(throws: (any Error).self) { try await first.execute() }
        f.finish(first); f.loseReply = false; f.item.unitPrice = 250
        let recovery = try await f.flow(.recover(f.publication))
        let outcome = try await recovery.execute(); f.finish(recovery)
        #expect(outcome.link == .reconciliationRequired(differenceCount: 1))
        #expect(f.item.unitPrice == 250 && f.item.quickBooksID == "I1" && f.writes == 1)
    }

    @Test func staleIdentityOrMalformedServerContextNeverStartsCatalogWork() async throws {
        for changes: [String: Any] in [["companyID": UUID().uuidString], ["localItemID": UUID().uuidString],
            ["realmID": ""], ["environment": "other"], ["protocolVersion": 2], ["connectionRevision": "A"],
            ["incomeAccount": ["value": "../foreign"]]] {
            let f = try Fixture(); f.contextChanges = changes
            await #expect(throws: CatalogPublicationError.invalidResponse) { try await f.flow() }
            #expect(f.lifecycle.activeID == nil && f.writes == 0 && f.item.quickBooksID == nil)
        }
    }

    @Test func discoveryCannotAdoptEditedDeletedDuplicateOrRevokedLocalWork() async throws {
        for kind in 0..<5 {
            let f = try Fixture(), preparation = try f.prepare()
            f.beforeContext = {
                switch kind {
                case 0: f.item.unitPrice += 1
                case 1: f.context.delete(f.item)
                case 2: let duplicate = Item(name: "Duplicate", unitPrice: 1); duplicate.id = f.item.id; f.context.insert(duplicate)
                case 3: f.authorized = false
                default: f.visible = false
                }
            }
            await #expect(throws: (any Error).self) { try await preparation.makeWorkflow(lifecycle: f.lifecycle, mode: .publish) }
            #expect(f.lifecycle.activeID == nil && f.writes == 0)
        }
    }

    @Test func offlineRetainsApprovedItemAndNeverFallsBackToIntuit() async throws {
        let f = try Fixture(); f.offline = true; let original = QuickBooksCatalogItemRevision(f.item)
        await #expect(throws: CatalogPublicationError.unavailable) { try await f.flow() }
        #expect(QuickBooksCatalogItemRevision(f.item) == original && f.writes == 0)
    }

    @Test func replacedConnectionAfterPreparationCannotReadOrPublishUnderNewGrant() async throws {
        for compare in [false, true] {
            let f = try Fixture()
            if compare { f.item.quickBooksID = "I1"; f.remote = f.remoteItem() }
            let flow = try await f.flow(compare ? .compare : .publish)
            f.epoch = String(repeating: "b", count: 64)
            await #expect(throws: CatalogPublicationError.needsReview) { try await flow.execute() }
            #expect(f.writes == 0); f.finish(flow)
        }
    }
}
