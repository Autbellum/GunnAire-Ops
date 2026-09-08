import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor struct QuickBooksDocumentNativeWorkflowTests {
    func job(_ app: QuickBooksBillingWorkflowTests.Fixture) throws -> ServiceCall {
        let call = ServiceCall(type: .repair, scheduledDate: Date(), customer: app.customer,
                               linkedInvoiceID: app.invoice.id)
        app.invoice.serviceCallID = call.id
        app.context.insert(call); try app.context.save()
        return call
    }
    let targets = [QBODocumentTarget(type: "Invoice", id: "D1")]
    let references = [QuickBooksAttachableReference(EntityRef: .init(type: "Invoice", value: "D1"), IncludeOnSend: false)]

    @Test func productionAuthorityCannotUseAnUnmountedTestOrForeignContainer() throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        #expect(throws: QBODocumentError.access) { try QBODocumentOwner.capture(context: app.context) }
        #expect(throws: QBODocumentError.access) { try QBODocumentNativeWorkflow.access(context: app.context, api: app.api) }
        #expect(app.requests.isEmpty)
    }

    @Test func repeatedManualCaptureKeepsOneOriginalJobFileAndPhotoCount() throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let call = try job(app), bytes = Data([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3])
        let url = try files.file("Before repair.png", data: bytes)
        let row = try QBODocumentNativeWorkflow.captureManual(access: files.access(), url: url, call: call,
            stage: "before", targets: targets, context: app.context, store: files.store, directory: files.root)
        let repeated = try QBODocumentNativeWorkflow.captureManual(access: files.access(), url: url, call: call,
            stage: "before", targets: targets, context: app.context, store: files.store, directory: files.root)
        #expect(repeated == row)
        #expect(call.beforePhotoCount == 1 && call.afterPhotoCount == 0)
        #expect(call.documentationCompletedAt == nil)
        #expect(try app.context.fetch(FetchDescriptor<ServiceDocumentAttachment>()).count == 1)
        #expect(try files.store.bytes(files.owner, row.id) == bytes)
        #expect(files.requests.isEmpty)
        #expect(row.jobDocument?.serviceCallID == call.id && row.jobDocument?.stage == "before")
    }

    @Test func missingForeignAndMismatchedJobDestinationsCannotCaptureFinancialOwnership() throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let call = try job(app), url = try files.file()
        for invalid in [[], [QBODocumentTarget(type: "Bill", id: "D1")], [.init(type: "Invoice", id: "another")]] {
            #expect(throws: QBODocumentError.jobDestination) {
                try QBODocumentNativeWorkflow.captureManual(access: files.access(), url: url, call: call,
                    stage: "supporting", targets: invalid, context: app.context, store: files.store, directory: files.root)
            }
        }
        app.invoice.customer = Customer(name: "Different business customer")
        #expect(throws: QBODocumentError.jobDestination) {
            try QBODocumentNativeWorkflow.captureManual(access: files.access(), url: url, call: call,
                stage: "supporting", targets: targets, context: app.context, store: files.store, directory: files.root)
        }
        #expect(try files.store.list(files.owner).isEmpty && files.requests.isEmpty)
    }

    @Test func nonPhotoAndUnknownStageCannotAdvanceJobDocumentation() throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let call = try job(app), url = try files.file()
        #expect(throws: QBODocumentError.photoRequired) {
            try QBODocumentNativeWorkflow.captureManual(access: files.access(), url: url, call: call,
                stage: "before", targets: targets, context: app.context, store: files.store, directory: files.root)
        }
        #expect(throws: QBODocumentError.invalid) {
            try QBODocumentNativeWorkflow.captureManual(access: files.access(), url: url, call: call,
                stage: "finished", targets: targets, context: app.context, store: files.store, directory: files.root)
        }
        #expect(call.beforePhotoCount == 0 && call.afterPhotoCount == 0 && call.documentationStartedAt == nil)
        #expect(try files.store.list(files.owner).isEmpty)
    }

    @Test func operationalSaveFailureRetainsOriginalWithoutClaimingAJobFile() throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let call = try job(app), url = try files.file()
        #expect(throws: QBODocumentError.storage) {
            try QBODocumentNativeWorkflow.captureManual(access: files.access(), url: url, call: call,
                stage: "supporting", targets: targets, context: app.context, store: files.store, directory: files.root,
                save: { _ in throw QBODocumentError.storage })
        }
        let rows = try files.store.list(files.owner)
        #expect(rows.count == 1)
        let original = try #require(rows.first)
        #expect(try files.store.bytes(files.owner, original.id) == Data(contentsOf: url))
        #expect(try app.context.fetch(FetchDescriptor<ServiceDocumentAttachment>()).isEmpty)
        #expect(call.beforePhotoCount == 0 && call.afterPhotoCount == 0 && call.documentationStartedAt == nil)
        #expect(files.requests.isEmpty)
    }

    @Test func confirmedResultOnlyMarksOriginalFileWithoutChangingSelectedJobOrCounts() async throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let call = try job(app), url = try files.file("After repair.png", data: Data([137, 80, 78, 71, 1, 2]))
        let other = ServiceCall(type: .repair, scheduledDate: Date(), customer: app.customer)
        app.context.insert(other); try app.context.save()
        let row = try QBODocumentNativeWorkflow.captureManual(access: files.access(), url: url, call: call,
            stage: "after", targets: targets, context: app.context, store: files.store, directory: files.root)
        let session = try QBODocumentCaptureSession(record: row, store: files.store, check: files.check)
        try await session.send(client: .init(transport: files.request, check: files.check))
        try QBODocumentNativeWorkflow.applyConfirmed(session.record, context: app.context)
        try QBODocumentNativeWorkflow.applyConfirmed(session.record, context: app.context)
        let original = try #require(try app.context.fetch(FetchDescriptor<ServiceDocumentAttachment>()).first)
        #expect(original.quickBooksAttachableID == "A1" && original.isQuickBooksAttached(to: references))
        #expect(original.serviceCallID == call.id)
        #expect(call.afterPhotoCount == 1 && other.afterPhotoCount == 0)
        #expect(call.documentationCompletedAt == nil && other.documentationStartedAt == nil)
        #expect(files.sends == 1)
    }

    @Test func changedOriginalBytesStopBeforeAnyDispatchAndRetainCapturedBytes() throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let call = try job(app), url = try files.file()
        let row = try QBODocumentNativeWorkflow.captureManual(access: files.access(), url: url, call: call,
            stage: "supporting", targets: targets, context: app.context, store: files.store, directory: files.root)
        let original = try #require(try app.context.fetch(FetchDescriptor<ServiceDocumentAttachment>()).first)
        try Data("Changed after selection".utf8).write(to: original.localFileURL)
        #expect(throws: QBODocumentError.changed) { try QBODocumentNativeWorkflow.checkLocalOriginal(row, context: app.context) }
        #expect(try files.store.bytes(files.owner, row.id) == Data(contentsOf: url))
        #expect(files.requests.isEmpty && original.quickBooksAttachableID == nil)
    }

    @Test func localConfirmationSaveFailureCanApplyOriginalLaterWithoutAnotherUpload() async throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let call = try job(app), url = try files.file()
        let row = try QBODocumentNativeWorkflow.captureManual(access: files.access(), url: url, call: call,
            stage: "supporting", targets: targets, context: app.context, store: files.store, directory: files.root)
        let session = try QBODocumentCaptureSession(record: row, store: files.store, check: files.check)
        try await session.send(client: .init(transport: files.request, check: files.check))
        let original = try #require(try app.context.fetch(FetchDescriptor<ServiceDocumentAttachment>()).first)
        #expect(throws: QBODocumentError.storage) {
            try QBODocumentNativeWorkflow.applyConfirmed(session.record, context: app.context,
                save: { _ in throw QBODocumentError.storage })
        }
        #expect(original.quickBooksAttachableID == nil && original.quickBooksAttachedEntityKeysRaw == nil)
        #expect(session.record.needsAttention && session.record.needsLocalApplication)
        #expect(session.record.status == "Saved in QuickBooks — finish local link")
        try QBODocumentNativeWorkflow.applyConfirmed(session.record, context: app.context)
        try session.markLocalApplied()
        #expect(!session.record.needsAttention && session.record.localAppliedAt != nil)
        let restored = try #require(try files.store.read(files.owner, row.id))
        #expect(!restored.needsAttention)
        var reset = restored; reset.revision += 1; reset.localAppliedAt = nil
        #expect(throws: QBODocumentError.changed) { try files.store.write(reset, restored.revision, nil) }
        #expect(original.quickBooksAttachableID == "A1")
        #expect(files.sends == 1 && files.reservations == 1)
    }

    @Test func lostSendFollowupRecoversOriginalWithoutRepostingOrChangingBytes() async throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let attachment = try app.addAttachment()
        defer { try? FileManager.default.removeItem(at: attachment.localFileURL) }
        files.beforeResponse = { path in if path.hasSuffix("/send") { throw URLError(.networkConnectionLost) } }
        do {
            _ = try await QBODocumentNativeWorkflow.upload(attachment, references: references, context: app.context,
                api: app.api, dependencies: files.dependencies())
            Issue.record("Expected lost reply")
        } catch { #expect(error as? QBODocumentError == .unavailable) }
        #expect(attachment.quickBooksAttachableID == nil)
        files.beforeResponse = nil
        _ = try await QBODocumentNativeWorkflow.upload(attachment, references: references, context: app.context,
            api: app.api, dependencies: files.dependencies())
        #expect(attachment.quickBooksAttachableID == "A1")
        #expect(files.requests.last?.path.hasSuffix("/recover") == true)
        #expect(files.sends == 1 && files.reservations == 1)
    }

    @Test func revokedAuthorityStopsBeforeCaptureAndNetwork() async throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let attachment = try app.addAttachment()
        defer { try? FileManager.default.removeItem(at: attachment.localFileURL) }
        files.authorized = false
        do {
            _ = try await QBODocumentNativeWorkflow.upload(attachment, references: references, context: app.context,
                api: app.api, dependencies: files.dependencies())
            Issue.record("Expected denied authority")
        } catch { #expect(error as? QBODocumentError == .access) }
        #expect(files.requests.isEmpty)
        #expect(try files.store.list(files.owner).isEmpty)
    }

    @Test func queuedAutomaticFileCannotAdoptAConnectionReplacedBeforeTaskStarts() async throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let attachment = try app.addAttachment()
        defer { try? FileManager.default.removeItem(at: attachment.localFileURL) }
        let task = try #require(QBODocumentNativeWorkflow.enqueue(attachment, references: references,
            context: app.context, api: app.api, dependencies: files.dependencies()))
        // No suspension before revocation: the queued MainActor task has not run.
        files.authorized = false
        await task.value
        #expect(files.requests.isEmpty)
        #expect(try files.store.list(files.owner).isEmpty)
        #expect(attachment.quickBooksAttachableID == nil && attachment.quickBooksSyncError == nil)
    }

    @Test func automaticLinkSaveFailureRestoresHistoricalProviderEvidenceBeforeEnqueue() throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let call = try job(app), attachment = try app.addAttachment()
        defer { try? FileManager.default.removeItem(at: attachment.localFileURL) }
        attachment.serviceCallID = call.id; attachment.invoiceID = nil
        attachment.quickBooksAttachableID = "legacy-file"; attachment.quickBooksAttachedEntityKeysRaw = nil
        attachment.quickBooksSyncError = "Original review"
        try app.context.save()
        #expect(throws: QBODocumentError.storage) {
            try QuickBooksInvoiceAttachmentSync.syncPendingServiceReports(invoices: [app.invoice], serviceCalls: [call],
                attachments: [attachment], modelContext: app.context, api: app.api,
                save: { _ in throw QBODocumentError.storage })
        }
        #expect(attachment.invoiceID == nil && attachment.quickBooksAttachableID == "legacy-file")
        #expect(attachment.quickBooksSyncError == "Original review" && attachment.quickBooksAttachedEntityKeysRaw == nil)
        #expect(app.requests.isEmpty)
    }

    @Test func joblessInvoiceFileCanApplyRecoveredOriginalAndRejectCustomerRelabeling() async throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let attachment = try app.addAttachment()
        defer { try? FileManager.default.removeItem(at: attachment.localFileURL) }
        files.beforeResponse = { path in if path.hasSuffix("/send") { throw URLError(.timedOut) } }
        await #expect(throws: QBODocumentError.unavailable) {
            try await QBODocumentNativeWorkflow.upload(attachment, references: references, context: app.context,
                api: app.api, dependencies: files.dependencies())
        }
        let saved = try #require(try files.store.list(files.owner).first)
        #expect(saved.jobDocument == nil && saved.localAttachment?.attachmentID == attachment.id)
        files.beforeResponse = nil
        let recovery = try QBODocumentCaptureSession(record: saved, store: files.store, check: files.check)
        let beforeCancel = files.requests.count
        await #expect(throws: QBODocumentError.review) {
            try await recovery.cancel(client: .init(transport: files.request, check: files.check))
        }
        #expect(files.requests.count == beforeCancel)
        try await recovery.recover(client: .init(transport: files.request, check: files.check))
        app.customer.quickBooksID = "C2"
        #expect(throws: QBODocumentError.changed) {
            try QBODocumentNativeWorkflow.applyConfirmed(recovery.record, context: app.context)
        }
        #expect(attachment.quickBooksAttachableID == nil)
        app.customer.quickBooksID = "C1"
        try QBODocumentNativeWorkflow.applyConfirmed(recovery.record, context: app.context)
        #expect(attachment.quickBooksAttachableID == "A1" && files.sends == 1)
        var relabeled = recovery.record; relabeled.revision += 1; relabeled.localAttachment = nil
        #expect(throws: QBODocumentError.changed) { try files.store.write(relabeled, recovery.record.revision, nil) }
    }
}
