import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor struct QuickBooksDocumentSharedRecoveryTests {
    func reserve(_ fixture: QuickBooksDocumentWorkflowFixture, job: QBODocumentJob? = nil) async throws -> QBODocumentUploadRecord {
        let client = QBODocumentUploadClient(transport: fixture.request, check: fixture.check)
        return try await client.reserve(.init(companyID: fixture.owner.companyID, realmID: fixture.scope.realmID,
            environment: fixture.scope.environment, operationID: UUID(), connectionRevision: String(repeating: "b", count: 64),
            file: .init(filename: "Original.txt", contentType: "text/plain", data: Data("Retained original".utf8)),
            targets: [.init(type: "Invoice", id: "D1")], jobDocument: job))
    }
    func history(_ fixture: QuickBooksDocumentWorkflowFixture, actor: String = "second-admin@example.invalid") throws -> QBODocumentSharedRecovery {
        let owner = QBODocumentOwner(companyID: fixture.owner.companyID, backendOrigin: fixture.owner.backendOrigin, actorEmail: actor)
        return try .init(access: .init(owner: owner, scope: fixture.scope, check: fixture.check), store: fixture.store, transport: fixture.request)
    }

    @Test func secondAdministratorRestoresExactOriginalForOfflineExportWithoutSending() async throws {
        let fixture = try QuickBooksDocumentWorkflowFixture(); defer { fixture.cleanup() }
        let reserved = try await reserve(fixture)
        let browser = try history(fixture)
        try await browser.load()
        #expect(browser.rows == [reserved] && browser.loaded && !browser.hasPrevious && browser.nextCursor == nil)
        #expect(!fixture.requests.contains(where: { $0.path.hasSuffix("/file") }))
        let restored = try await browser.restore(reserved)
        #expect(restored.sharedSource == reserved && restored.id == reserved.operationID)
        #expect(restored.owner.actorEmail == "second-admin@example.invalid")
        #expect(restored.connectionRevision == nil && !restored.dispatchStarted)
        let reopened = try #require(try fixture.store.read(browser.access.owner, restored.id))
        #expect(reopened == restored)
        #expect(try fixture.store.bytes(browser.access.owner, restored.id) == Data("Retained original".utf8))
        #expect(try fixture.store.list(fixture.owner).isEmpty)
        _ = try await browser.restore(reserved)
        #expect(try fixture.store.list(browser.access.owner).count == 1)
        #expect(fixture.sends == 0 && fixture.reservations == 1)
    }

    @Test func restoredReservedFileCanOnlySendTheExistingServerOperationExplicitly() async throws {
        let fixture = try QuickBooksDocumentWorkflowFixture(); defer { fixture.cleanup() }
        let reserved = try await reserve(fixture), browser = try history(fixture)
        let local = try await browser.restore(reserved)
        let session = try QBODocumentCaptureSession(record: local, store: fixture.store, check: fixture.check)
        try await session.send(client: browser.client)
        #expect(session.record.server?.id == reserved.id && session.record.server?.state == .confirmed)
        #expect(fixture.reservations == 1 && fixture.sends == 1)
        await #expect(throws: QBODocumentError.review) { try await session.send(client: browser.client) }
        #expect(fixture.sends == 1)
    }

    @Test func uncertainSharedOriginalCannotBeResentOrResetToReserved() async throws {
        let fixture = try QuickBooksDocumentWorkflowFixture(); defer { fixture.cleanup() }
        let reserved = try await reserve(fixture), browser = try history(fixture)
        fixture.remote?["state"] = "uncertain"
        let local = try await browser.restore(reserved)
        let session = try QBODocumentCaptureSession(record: local, store: fixture.store, check: fixture.check)
        #expect(local.dispatchStarted && local.server?.state == .uncertain)
        await #expect(throws: QBODocumentError.review) { try await session.send(client: browser.client) }
        await #expect(throws: QBODocumentError.review) { try await session.cancel(client: browser.client) }
        #expect(fixture.sends == 0)
        fixture.remote?["state"] = "reserved"
        await #expect(throws: QBODocumentError.changed) { try await browser.restore(local.server!) }
        #expect(try fixture.store.read(browser.access.owner, local.id) == local)
    }

    @Test func alteredBytesAndRevokedAccessCannotCreateADeviceCopy() async throws {
        let fixture = try QuickBooksDocumentWorkflowFixture(); defer { fixture.cleanup() }
        let reserved = try await reserve(fixture), browser = try history(fixture)
        fixture.remoteBytes = Data("Different original".utf8)
        await #expect(throws: QBODocumentError.invalid) { try await browser.restore(reserved) }
        #expect(try fixture.store.list(browser.access.owner).isEmpty)
        fixture.remoteBytes = Data("Retained original".utf8)
        fixture.beforeResponse = { path in if path.hasSuffix("/file") { fixture.authorized = false } }
        await #expect(throws: QBODocumentError.access) { try await browser.restore(reserved) }
        #expect(try fixture.store.list(browser.access.owner).isEmpty)
        #expect(fixture.sends == 0)
    }

    @Test func missingCloudKitFileStaysPendingUntilExactOriginalArrives() async throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let fixture = try QuickBooksDocumentWorkflowFixture(); defer { fixture.cleanup() }
        let call = try QuickBooksDocumentNativeWorkflowTests().job(app)
        let id = UUID(), job = QBODocumentJob(attachmentID: id, serviceCallID: call.id, localCustomerID: app.customer.id,
            customerQuickBooksID: "C1", kind: "service_report", stage: "supporting",
            documents: [.init(type: "Invoice", localID: app.invoice.id, id: "D1")])
        let reserved = try await reserve(fixture, job: job), browser = try history(fixture)
        fixture.remote?["state"] = "confirmed"; fixture.remote?["providerID"] = "A1"
        let local = try await browser.restore(reserved)
        #expect(throws: QBODocumentError.syncPending) { try browser.apply(local, context: app.context) }
        #expect(local.needsLocalApplication && local.needsAttention)
        #expect(try app.context.fetch(FetchDescriptor<ServiceDocumentAttachment>()).isEmpty)
        let otherDevicePath = fixture.root.appendingPathComponent("other-device-missing/Original.txt").path
        let attachment = ServiceDocumentAttachment(id: id, customer: app.customer, serviceCallID: call.id,
            invoiceID: app.invoice.id, kind: .serviceReport, displayName: "Original.txt", localFilePath: otherDevicePath,
            contentType: "text/plain", fileSizeBytes: Data("Retained original".utf8).count)
        app.context.insert(attachment); try app.context.save()
        let dependencies = QBODocumentNativeWorkflow.Dependencies(owner: { _ in try fixture.check(); return browser.access.owner },
            access: { _, _ in browser.access }, store: fixture.store, transport: fixture.request)
        let previewFolder = fixture.root.appendingPathComponent("previews", isDirectory: true)
        let preview = try QBODocumentNativeWorkflow.previewURL(for: attachment, context: app.context,
            dependencies: dependencies, directory: previewFolder)
        #expect(try Data(contentsOf: preview) == Data("Retained original".utf8))
        #expect(preview.path != otherDevicePath && attachment.localFilePath == otherDevicePath)
        #expect(try QBODocumentNativeWorkflow.previewURL(for: attachment, context: app.context,
            dependencies: dependencies, directory: previewFolder) == preview)
        try Data("Corrupt cached preview".utf8).write(to: preview)
        #expect(throws: QBODocumentError.storage) {
            try QBODocumentNativeWorkflow.previewURL(for: attachment, context: app.context,
                dependencies: dependencies, directory: previewFolder)
        }
        #expect(try fixture.store.bytes(browser.access.owner, local.id) == Data("Retained original".utf8))
        let requestsBeforeApplication = fixture.requests.count
        let applied = try browser.apply(local, context: app.context)
        #expect(attachment.quickBooksAttachableID == "A1" && attachment.localFilePath == otherDevicePath)
        #expect(!FileManager.default.fileExists(atPath: otherDevicePath))
        #expect(!applied.needsAttention && applied.localAppliedAt != nil)
        _ = try browser.apply(applied, context: app.context)
        #expect(fixture.requests.count == requestsBeforeApplication)
        fixture.authorized = false
        #expect(throws: QBODocumentError.access) {
            try QBODocumentNativeWorkflow.previewURL(for: attachment, context: app.context,
                dependencies: dependencies, directory: previewFolder)
        }
        #expect(try app.context.fetch(FetchDescriptor<ServiceDocumentAttachment>()).count == 1)
        #expect(call.beforePhotoCount == 0 && call.afterPhotoCount == 0 && call.documentationCompletedAt == nil)
        #expect(fixture.sends == 0)
    }

    @Test func sharedApplicationCannotOverwriteChangedLocalBytesOrLocalReceiptOnSaveFailure() async throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let fixture = try QuickBooksDocumentWorkflowFixture(); defer { fixture.cleanup() }
        let call = try QuickBooksDocumentNativeWorkflowTests().job(app), id = UUID()
        let job = QBODocumentJob(attachmentID: id, serviceCallID: call.id, localCustomerID: app.customer.id,
            customerQuickBooksID: "C1", kind: "service_report", stage: "supporting",
            documents: [.init(type: "Invoice", localID: app.invoice.id, id: "D1")])
        let reserved = try await reserve(fixture, job: job), browser = try history(fixture)
        fixture.remote?["state"] = "confirmed"; fixture.remote?["providerID"] = "A1"
        let local = try await browser.restore(reserved)
        let url = try fixture.file("Original.txt", data: Data("Changed local file".utf8))
        let attachment = ServiceDocumentAttachment(id: id, customer: app.customer, serviceCallID: call.id,
            invoiceID: app.invoice.id, kind: .serviceReport, displayName: "Original.txt", localFilePath: url.path,
            contentType: "text/plain", fileSizeBytes: Data("Retained original".utf8).count)
        app.context.insert(attachment); try app.context.save()
        #expect(throws: QBODocumentError.changed) { try browser.apply(local, context: app.context) }
        #expect(attachment.quickBooksAttachableID == nil)
        _ = try fixture.file("Original.txt", data: Data("Retained original".utf8))
        #expect(throws: QBODocumentError.storage) { try browser.apply(local, context: app.context, save: { _ in throw QBODocumentError.storage }) }
        #expect(attachment.quickBooksAttachableID == nil && attachment.quickBooksAttachedEntityKeysRaw == nil)
        #expect(try fixture.store.read(browser.access.owner, local.id)?.needsLocalApplication == true)
        attachment.customer = Customer(name: "Wrong customer")
        #expect(throws: (any Error).self) { try browser.apply(local, context: app.context) }
        #expect(fixture.sends == 0)
    }

    @Test func cancelledSharedOriginalRetainsItsTombstoneAndExportWithoutResending() async throws {
        let fixture = try QuickBooksDocumentWorkflowFixture(); defer { fixture.cleanup() }
        let reserved = try await reserve(fixture), browser = try history(fixture)
        fixture.remote?["state"] = "cancelled"
        let local = try await browser.restore(reserved)
        #expect(local.status == "Cancelled — original retained" && !local.needsAttention)
        #expect(try fixture.store.bytes(browser.access.owner, local.id) == Data("Retained original".utf8))
        let session = try QBODocumentCaptureSession(record: local, store: fixture.store, check: fixture.check)
        await #expect(throws: QBODocumentError.review) { try await session.send(client: browser.client) }
        #expect(fixture.sends == 0)
    }

    @Test func foreignCompanyMetadataCannotBeBrowsedOrRetained() async throws {
        let fixture = try QuickBooksDocumentWorkflowFixture(); defer { fixture.cleanup() }
        let reserved = try await reserve(fixture), browser = try history(fixture)
        fixture.remote?["companyID"] = UUID().uuidString
        await #expect(throws: QBODocumentError.invalid) { try await browser.load() }
        await #expect(throws: QBODocumentError.invalid) { try await browser.restore(reserved) }
        #expect(browser.rows.isEmpty && !browser.loaded)
        #expect(try fixture.store.list(browser.access.owner).isEmpty)
        #expect(!fixture.requests.contains(where: { $0.path.hasSuffix("/file") }))
    }

    @Test func pagedMetadataPreservesTheCurrentPageOnFailureAndNeverDownloadsFiles() async throws {
        let fixture = try QuickBooksDocumentWorkflowFixture(); defer { fixture.cleanup() }
        let original = try await reserve(fixture)
        let seed = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        let identifiers = (1...51).map { String(format: "20000000-0000-4000-8000-%012d", $0) }
        var fail = false, paths: [String] = []
        let browser = try QBODocumentSharedRecovery(access: fixture.access(), store: fixture.store) { path, method, _ in
            paths.append(path); #expect(method == "GET")
            if fail { throw URLError(.notConnectedToInternet) }
            let after = URLComponents(string: path)?.queryItems?.first(where: { $0.name == "after" })?.value
            let values = (after == nil ? Array(identifiers.prefix(50)) : [identifiers[50]]).map { id -> [String: Any] in
                var row = seed; row["id"] = id; return row
            }
            return try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "maxFileBytes": QBODocumentFileInfo.maximum,
                "companyID": fixture.owner.companyID.uuidString, "realmID": fixture.scope.realmID,
                "environment": fixture.scope.environment, "connectionRevision": NSNull(),
                "uploads": values, "nextCursor": after == nil ? identifiers[49] as Any : NSNull()])
        }
        try await browser.load()
        #expect(browser.rows.count == 50 && browser.pageNumber == 1 && !browser.hasPrevious)
        fail = true
        await #expect(throws: QBODocumentError.unavailable) { try await browser.load(.next) }
        #expect(browser.rows.count == 50 && browser.pageNumber == 1 && !browser.working)
        fail = false; try await browser.load(.next)
        #expect(browser.rows.count == 1 && browser.pageNumber == 2 && browser.hasPrevious && browser.nextCursor == nil)
        try await browser.load(.previous)
        #expect(browser.rows.count == 50 && browser.pageNumber == 1 && !browser.hasPrevious)
        #expect(paths.allSatisfy { $0.hasPrefix("/api/qbo-document-uploads?") && !$0.contains("/file") })
        #expect(try fixture.store.list(fixture.owner).isEmpty)
    }
}
