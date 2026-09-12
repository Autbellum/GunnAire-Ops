import Foundation
import CryptoKit
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor
struct QuickBooksChangeHistoryTests {
    private let scope = QuickBooksChangeHistoryScope(companyID: UUID(), realmID: "fixture-realm", environment: "sandbox")

    private func version(_ id: String = "42", sequence: Int = 1,
                         time: String = "2026-09-07T10:00:00.000001+00:00",
                         deleted: Bool = false, fields: [String: Any] = [:],
                         rawJSON: String? = nil) throws -> [String: Any] {
        var record: [String: Any] = ["Id": id, "SyncToken": "1", "MetaData": ["LastUpdatedTime": time],
            "Name": "Fixture service", "DisplayName": "Fixture account", "TotalAmt": 125, "Balance": 125,
            "CustomerRef": ["value": "C1"], "VendorRef": ["value": "V1"], "UnitPrice": 125,
            "Type": "Service", "Active": true]
        record.merge(fields) { _, new in new }
        if deleted { record["status"] = "Deleted"; record.removeValue(forKey: "SyncToken") }
        let raw = try rawJSON ?? String(decoding: JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), as: UTF8.self)
        return ["sequence": sequence, "entityID": id, "updatedAt": time, "status": deleted ? "deleted" : "present",
                "recordJSON": raw, "payloadSHA256": SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()]
    }

    @MainActor private final class Server {
        let scope: QuickBooksChangeHistoryScope
        var versions: [QuickBooksChangeEntity: [[String: Any]]] = [:]
        var connection = String(repeating: "a", count: 64)
        var pageSize = 2
        var requests: [(String, String, [String: String])] = []
        var changeReply: ((inout [String: Any], Int) throws -> Void)?
        init(_ scope: QuickBooksChangeHistoryScope) { self.scope = scope }

        func request(path: String, method: String, body: Data?) async throws -> Data {
            let components = try #require(URLComponents(string: path))
            #expect(components.path == "/api/qbo/change-capture")
            let payload: [String: String]
            if method == "POST" {
                #expect(components.query == nil)
                payload = try JSONDecoder().decode([String: String].self, from: #require(body))
            } else {
                #expect(method == "GET")
                #expect(body == nil)
                payload = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            }
            #expect(payload["companyID"] == scope.companyID.uuidString.lowercased())
            #expect(payload["realmID"] == scope.realmID)
            #expect(payload["environment"] == scope.environment)
            let entity = try #require(QuickBooksChangeEntity(rawValue: payload["entityType"] ?? ""))
            requests.append((path, method, payload))
            let all = versions[entity] ?? []
            let through = all.compactMap { $0["sequence"] as? Int }.max() ?? 0
            let after = Int(payload["afterSequence"] ?? "0") ?? -1
            let remaining = all.filter { ($0["sequence"] as? Int ?? 0) > after }
            let page = Array(remaining.prefix(pageSize))
            var response: [String: Any] = [
                "companyID": scope.companyID.uuidString.lowercased(), "realmID": scope.realmID,
                "environment": scope.environment, "entityType": entity.rawValue,
                "connectionRevision": connection, "revision": 7, "capturedThrough": "2026-09-08T00:00:00.000000+00:00",
                "baselineAt": "2026-09-07T12:00:00.000000+00:00", "issueCode": NSNull(),
                "legacyEventsNeedingReview": 0, "applicationState": "not_applied",
                "versions": page, "versionCount": all.count, "afterSequence": after, "throughSequence": through,
                "nextAfterSequence": remaining.count > page.count ? (page.last?["sequence"] ?? NSNull()) : NSNull()
            ]
            try changeReply?(&response, requests.count)
            return try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        }
    }

    private func client(_ server: Server, check: @escaping () throws -> Void = {}) throws -> QuickBooksChangeHistoryClient {
        try .init(scope: scope, check: check, request: server.request)
    }

    private func run(_ server: Server, lifecycle: QuickBooksSyncLifecycle,
                     check: @escaping () throws -> Void = {}) throws -> (QuickBooksSyncRun, QuickBooksDataAPI) {
        let api = QuickBooksDataAPI(testTokens: .init(accessToken: "fixture", expiration: .distantFuture),
            realmID: scope.realmID, environment: scope.environment, catalogCompanyID: scope.companyID,
            transport: { _ in Issue.record("Shared history fell back to direct provider transport"); throw QuickBooksChangeHistoryError.invalid })
        return (try lifecycle.begin(api: api, sharedHistoryRequest: server.request, validateAccess: check), api)
    }

    @Test func downloadsEveryPinnedPageAndSelectsProviderTimeInsteadOfArrivalOrder() async throws {
        let server = Server(scope)
        server.versions[.item] = [
            try version(sequence: 2, time: "2026-09-07T10:00:00.000003+00:00", fields: ["UnitPrice": 200]),
            try version("other", sequence: 7),
            try version(sequence: 11, fields: ["UnitPrice": 100])
        ]
        let reader = try client(server)
        let items: [QuickBooksItem] = try await reader.records(entity: .item)
        #expect(items.count == 2)
        #expect(items.first { $0.Id == "42" }?.UnitPrice == 200)
        #expect(server.requests.map(\.1) == ["POST", "GET", "GET"])
        #expect(server.requests[1].2["afterSequence"] == "7")
        #expect(server.requests[1].2["throughSequence"] == "11")
        #expect(server.requests[1].2["captureRevision"] == "7")
        #expect(server.requests[1].2["connectionRevision"] == server.connection)
        #expect(server.requests.last?.2["afterSequence"] == "11")
        try await reader.revalidate([.item])
        #expect(server.requests.count == 4)
    }

    @Test func canonicalPythonUnicodeAndExponentBytesAreVerifiedWithoutReserialization() async throws {
        let raw = #"{"Id":"42","MetaData":{"LastUpdatedTime":"2026-09-07T10:00:00.000001+00:00"},"Name":"\u00e9t\u00e9 \ud83d\udd27","SyncToken":"1","UnitPrice":1e-07}"#
        let server = Server(scope)
        server.versions[.item] = [try version(rawJSON: raw)]
        let values: [QuickBooksItem] = try await client(server).records(entity: .item)
        #expect(values.first?.Name == "été 🔧")
        #expect(values.first?.UnitPrice == 0.0000001)
    }

    @Test func everyManagementAccountingCollectionUsesSharedHistoryAndRevalidatesBeforeImport() async throws {
        let server = Server(scope)
        for entity in QuickBooksChangeEntity.allCases { server.versions[entity] = [try version()] }
        let lifecycle = QuickBooksSyncLifecycle()
        let (run, _) = try run(server, lifecycle: lifecycle)
        func read<T: Decodable>(_ entity: QuickBooksChangeEntity, _ type: T.Type) async throws {
            let values: [T] = try await run.receiveResource(id: entity.resourceID) { completion in
                Issue.record("An accounting collection used the legacy callback")
                completion(.failure(QuickBooksChangeHistoryError.invalid))
            }
            #expect(values.count == 1)
            try run.markSucceeded(entity.resourceID)
        }
        try await read(.account, QuickBooksAccount.self)
        try await read(.bill, QuickBooksBill.self)
        try await read(.customer, QuickBooksCustomer.self)
        try await read(.deposit, QuickBooksDeposit.self)
        try await read(.estimate, QuickBooksEstimate.self)
        try await read(.invoice, QuickBooksInvoice.self)
        try await read(.item, QuickBooksItem.self)
        try await read(.payment, QuickBooksPayment.self)
        try await read(.paymentMethod, QuickBooksPaymentMethod.self)
        try await read(.purchase, QuickBooksPurchase.self)
        try await read(.salesReceipt, QuickBooksSalesReceipt.self)
        try await read(.vendor, QuickBooksVendor.self)
        try await read(.vendorCredit, QuickBooksVendorCredit.self)
        try await run.prepareLocalImport()
        #expect(server.requests.count == 39)
        #expect(server.requests.filter { $0.1 == "POST" }.count == 13)
        #expect(server.requests.dropFirst().allSatisfy { $0.2["connectionRevision"] == server.connection })
        #expect(run.successfulResourceIDs.count == 13)
    }

    @Test func incompleteCollectionSetCannotAuthorizePartialLocalLedgerImport() async throws {
        let server = Server(scope)
        let lifecycle = QuickBooksSyncLifecycle()
        let (run, _) = try run(server, lifecycle: lifecycle)
        let items: [QuickBooksItem] = try await run.receiveResource(id: "catalog") { completion in
            Issue.record("Legacy fallback"); completion(.failure(QuickBooksChangeHistoryError.invalid))
        }
        #expect(items.isEmpty)
        try run.markSucceeded("catalog")
        do { try await run.prepareLocalImport(); Issue.record("Partial accounting set authorized import") }
        catch { #expect(error as? QuickBooksChangeHistoryError == .incomplete) }
        #expect(server.requests.count == 2)
    }

    @Test func invoicePickerCatalogRefreshRevalidatesOnlyItsCompleteItemCensus() async throws {
        let server = Server(scope), lifecycle = QuickBooksSyncLifecycle()
        server.versions[.item] = [try version()]
        let (run, api) = try run(server, lifecycle: lifecycle)
        await #expect(throws: QuickBooksChangeHistoryError.incomplete) { try await run.prepareCatalogImport() }
        let items: [QuickBooksItem] = try await run.receiveResource(id: "catalog", fetch: api.fetchItems)
        try run.markSucceeded("catalog")
        let prepared = try await run.prepareCatalogImport()
        let history = try #require(prepared)
        try history.validate(records: items)
        #expect(run.successfulResourceIDs == ["catalog"])
        #expect(server.requests.count == 3)
        #expect(server.requests.allSatisfy { $0.2["entityType"] == "Item" })
        await #expect(throws: QuickBooksChangeHistoryError.incomplete) { try await run.prepareLocalImport() }
        lifecycle.cancel()
        await #expect(throws: CancellationError.self) { try await run.prepareCatalogImport() }
    }

    @Test func changedCatalogCensusCannotCommitAPickerRefresh() async throws {
        let server = Server(scope), lifecycle = QuickBooksSyncLifecycle()
        server.versions[.item] = [try version()]
        let (run, api) = try run(server, lifecycle: lifecycle)
        let _: [QuickBooksItem] = try await run.receiveResource(id: "catalog", fetch: api.fetchItems)
        try run.markSucceeded("catalog")
        server.connection = String(repeating: "f", count: 64)
        await #expect(throws: (any Error).self) { try await run.prepareCatalogImport() }
    }

    @Test(arguments: ["companyID", "realmID", "environment", "entityType", "connectionRevision", "revision",
                      "applicationState", "versionCount", "afterSequence", "throughSequence", "nextAfterSequence",
                      "baselineAt", "capturedThrough", "issueCode", "legacyEventsNeedingReview"])
    func malformedOrIncompletePageCannotReturnRecords(field: String) async throws {
        let server = Server(scope)
        server.versions[.item] = [try version()]
        server.changeReply = { page, _ in
            switch field {
            case "companyID": page[field] = UUID().uuidString
            case "realmID": page[field] = "other"
            case "environment": page[field] = "production"
            case "entityType": page[field] = "Invoice"
            case "connectionRevision": page[field] = "bad"
            case "applicationState": page[field] = "applied"
            case "baselineAt": page[field] = NSNull()
            case "capturedThrough": page[field] = "undated"
            case "issueCode": page[field] = "history_gap"
            case "legacyEventsNeedingReview": page[field] = 1
            default: page[field] = -1
            }
        }
        do {
            let _: [QuickBooksItem] = try await client(server).records(entity: .item)
            Issue.record("Invalid history escaped into the app")
        } catch { #expect(error is QuickBooksChangeHistoryError) }
        #expect(server.requests.count == 1)
    }

    @Test(arguments: ["payloadSHA256", "entityID", "updatedAt", "status", "sparse", "SyncToken"])
    func invalidRecordEvidenceCannotReturnACollection(field: String) async throws {
        let server = Server(scope)
        var value = try version()
        switch field {
        case "sparse": value = try version(fields: ["sparse": true])
        case "SyncToken": value = try version(fields: ["SyncToken": NSNull()])
        case "updatedAt": value[field] = "2026-09-07T10:00:00.000002+00:00"
        default: value[field] = "invalid"
        }
        server.versions[.item] = [value]
        do { let _: [QuickBooksItem] = try await client(server).records(entity: .item); Issue.record("Invalid version applied") }
        catch { #expect(error as? QuickBooksChangeHistoryError == .invalid) }
    }

    @Test(arguments: ["deleted", "conflicting", "missing", "repeated", "premature"])
    func tombstonesConflictsAndIncompletePagesAreNotSuccessfulEmptySnapshots(mode: String) async throws {
        let server = Server(scope)
        server.versions[.item] = [try version(sequence: 1), try version("other", sequence: 2), try version("last", sequence: 3)]
        if mode == "deleted" { server.versions[.item]![2] = try version(sequence: 3, time: "2026-09-07T11:00:00Z", deleted: true) }
        if mode == "conflicting" { server.versions[.item]![2] = try version(sequence: 3, fields: ["UnitPrice": 300]) }
        server.changeReply = { page, number in
            if mode == "premature" && number == 1 { page["nextAfterSequence"] = NSNull() }
            if mode == "missing" { page["versionCount"] = 4 }
            if mode == "repeated" && number == 2 { page["versions"] = [try version(sequence: 2)] }
        }
        do { let _: [QuickBooksItem] = try await client(server).records(entity: .item); Issue.record("Unreconciled history applied") }
        catch {
            #expect(error as? QuickBooksChangeHistoryError == (["deleted", "conflicting"].contains(mode) ? .lifecycleReview : .invalid))
        }
    }

    @Test(arguments: ["grant", "capture", "count", "time", "revoked", "cancelled", "localConnection"])
    func changesDuringFinalVerificationCannotReachLocalImport(change: String) async throws {
        let server = Server(scope)
        server.versions[.item] = [try version()]
        let lifecycle = QuickBooksSyncLifecycle()
        var authorized = true
        let (run, api) = try run(server, lifecycle: lifecycle) {
            guard authorized else { throw CompanyWorkspaceFailure.administratorRequired }
        }
        server.changeReply = { page, number in
            guard number == 2 else { return }
            switch change {
            case "grant": page["connectionRevision"] = String(repeating: "b", count: 64)
            case "capture": page["revision"] = 8
            case "count": page["versionCount"] = 2
            case "time": page["capturedThrough"] = "2026-09-08T01:00:00Z"
            case "revoked": authorized = false
            case "cancelled": lifecycle.cancel()
            default: api.storeTokens(.init(accessToken: "replacement", expiration: .distantFuture), realmID: scope.realmID)
            }
        }
        var saved = false
        do {
            let _: [QuickBooksItem] = try await run.receiveResource(id: "catalog") { completion in
                Issue.record("Fallback"); completion(.failure(QuickBooksChangeHistoryError.invalid))
            }
            try run.commit { saved = true }
            Issue.record("Changed history committed")
        } catch { #expect(!saved) }
        #expect(server.requests.count == 2)
        #expect(run.successfulResourceIDs.isEmpty)
    }

    @Test func failuresNeverEchoProviderDataOrRetryThroughTheDeviceConnection() async throws {
        let reader = try QuickBooksChangeHistoryClient(scope: scope, check: {},
            request: { _, _, _ in throw GunnAireBackendError.server(statusCode: 503, message: "private fixture payload") })
        do { let _: [QuickBooksItem] = try await reader.records(entity: .item); Issue.record("Failed request returned data") }
        catch {
            #expect(error as? QuickBooksChangeHistoryError == .unavailable)
            #expect(!error.localizedDescription.contains("private fixture"))
        }
    }

    @Test(arguments: ["bill", "payment", "allocation"])
    func missingOrMalformedFinancialEvidenceCannotBecomeAZeroAmount(kind: String) async throws {
        for amount: Any in [NSNull(), true, "not an amount", "NaN", "Infinity"] {
            let server = Server(scope)
            let entity: QuickBooksChangeEntity = kind == "bill" ? .bill : .payment
            let fields: [String: Any] = kind == "allocation" ? ["Line": [["Amount": amount]]] : ["TotalAmt": amount]
            server.versions[entity] = [try version(fields: fields)]
            do {
                if entity == .bill { let _: [QuickBooksBill] = try await client(server).records(entity: entity) }
                else { let _: [QuickBooksPayment] = try await client(server).records(entity: entity) }
                Issue.record("Missing financial evidence defaulted to zero")
            } catch { #expect(error as? QuickBooksChangeHistoryError == .invalid) }
        }
    }

    @Test func providerTimeKeepsMicrosecondsAndComparesEquivalentTimezones() throws {
        #expect(try QuickBooksHistoryTimestamp("2026-09-07T10:00:00.000001Z") <
                    QuickBooksHistoryTimestamp("2026-09-07T10:00:00.000002Z"))
        #expect(try QuickBooksHistoryTimestamp("2026-09-07T10:00:00.1234Z") ==
                    QuickBooksHistoryTimestamp("2026-09-07T06:00:00.123400-04:00"))
        for value in ["2026-09-07", "2026-09-07T10:00:00", "2026-09-07T10:00:00.1234567Z",
                      "2026-09-07T10:00:00Z\n", "not a date"] {
            #expect(throws: QuickBooksChangeHistoryError.self) { try QuickBooksHistoryTimestamp(value) }
        }
    }

    @Test func cancelledTaskCannotStartAnAccountingCapture() async throws {
        let server = Server(scope)
        let reader = try client(server)
        let task = Task { try await reader.records(entity: .item, as: QuickBooksItem.self) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled task returned a collection") }
        catch { #expect(error is CancellationError) }
        #expect(server.requests.isEmpty)
    }

    @Test func invalidScopeCannotAllocateAReaderOrCallTransport() {
        for realm in ["", ".", "..", "realm\n", "https://example.invalid", String(repeating: "x", count: 129)] {
            #expect(throws: QuickBooksChangeHistoryError.self) {
                try QuickBooksChangeHistoryClient(
                    scope: .init(companyID: scope.companyID, realmID: realm, environment: "sandbox"), check: {},
                    request: { _, _, _ in Issue.record("Invalid scope reached transport"); return Data() })
            }
        }
        #expect(!QuickBooksChangeHistoryScope.validDigest(String(repeating: "a", count: 64) + "\n"))
    }

    @Test func oversizedWireReplyAndTooManyVersionsInOnePageAreRejected() async throws {
        let oversized = try QuickBooksChangeHistoryClient(scope: scope, check: {},
            request: { _, _, _ in Data(repeating: 32, count: QuickBooksChangeHistoryClient.maximumPageBytes + 1) })
        do { let _: [QuickBooksItem] = try await oversized.records(entity: .item); Issue.record("Oversized response accepted") }
        catch { #expect(error as? QuickBooksChangeHistoryError == .limit) }
        let server = Server(scope)
        server.pageSize = 51
        server.versions[.item] = try (1...51).map { try version(String($0), sequence: $0) }
        do { let _: [QuickBooksItem] = try await client(server).records(entity: .item); Issue.record("Oversized page accepted") }
        catch { #expect(error as? QuickBooksChangeHistoryError == .invalid) }
    }

    @Test func lostFinalVerificationRetainsOriginalWorkWithoutReturningDownloadedRows() async throws {
        let server = Server(scope)
        server.versions[.item] = [try version()]
        server.changeReply = { _, number in
            if number == 2 { throw URLError(.networkConnectionLost) }
        }
        do { let _: [QuickBooksItem] = try await client(server).records(entity: .item); Issue.record("Unverified rows escaped") }
        catch { #expect(error as? QuickBooksChangeHistoryError == .unavailable) }
        #expect(server.requests.count == 2)
    }

    @Test func importedHistoryPreservesTechnicianDraftsAdminEditsStockMetadataAndSoldPrices() async throws {
        let schema = GunnAireModelSchema.schema
        let context = ModelContext(try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]))
        let technician = Item(quickBooksID: "tech", pricebookReviewStatus: .needsReview,
            pricebookCreatedByEmail: "tech@example.invalid", name: "Field proposal", unitPrice: 321)
        let admin = Item(quickBooksID: "admin", quickBooksSyncStatus: "pending_update", name: "Approved proposal", unitPrice: 432)
        let synced = Item(quickBooksID: "synced", name: "Old label", unitPrice: 80, vendorPartNumber: "P-1",
            tracksInventory: true, reorderPoint: 3, defaultInventoryLocation: "Truck 2")
        let archived = Item(quickBooksID: "archived", name: "Old product", unitPrice: 30)
        let customer = Customer(name: "Fixture customer")
        let sold = try #require(CatalogLineItemSnapshot.encoded(from: [synced]))
        let invoice = Invoice(customer: customer, catalogSnapshotJSON: sold, amount: 80)
        for item in [technician, admin, synced, archived] { context.insert(item) }
        context.insert(customer); context.insert(invoice); try context.save()
        let server = Server(scope)
        server.versions[.item] = [try version("tech", sequence: 1), try version("admin", sequence: 2),
                                 try version("synced", sequence: 3), try version("archived", sequence: 4, fields: ["Active": false])]
        let reader = try client(server)
        let records: [QuickBooksItem] = try await reader.records(entity: .item)
        try await reader.revalidate([.item])
        #expect(throws: QuickBooksBillingImportReview.self) {
            try QuickBooksLocalSync.importSnapshot(customers: [], items: records, estimates: [],
                invoices: [], payments: [], vendors: [], into: context, catalogHistory: reader.catalogHistory())
        }
        #expect(technician.name == "Field proposal" && technician.unitPrice == 321)
        #expect(technician.requiresPricebookReview && technician.pricebookCreatedByEmail == "tech@example.invalid")
        #expect(admin.unitPrice == 432 && admin.hasPendingQuickBooksCatalogUpdate)
        #expect(synced.unitPrice == 125 && synced.name == "Fixture service")
        #expect(synced.vendorPartNumber == "P-1" && synced.tracksInventory && synced.reorderPoint == 3)
        #expect(synced.defaultInventoryLocation == "Truck 2")
        #expect(archived.isCatalogArchived && archived.quickBooksID == "archived")
        #expect(technician.quickBooksCatalogReceiptJSON == nil && admin.quickBooksCatalogReceiptJSON == nil)
        let receipt = try QuickBooksCatalogApplicationReceipt.decode(#require(synced.quickBooksCatalogReceiptJSON))
        #expect(receipt.isCurrent(on: synced, scope: scope))
        #expect(archived.quickBooksCatalogReceiptJSON != nil)
        #expect(invoice.amount == 80 && invoice.catalogSnapshotJSON == sold)
        #expect(invoice.catalogLineSnapshots.first?.unitPrice == 80)
        #expect(try context.fetchCount(FetchDescriptor<Item>()) == 4)
    }
}
