import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

private actor RetainedMediaReadGate {
    private var reached = false
    private var reachWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        reached = true
        for waiter in reachWaiters { waiter.resume() }
        reachWaiters.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilReached() async {
        if reached { return }
        await withCheckedContinuation { reachWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

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

    @Test func defaultDocumentAccessStillRejectsAnUnmountedContext() throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        #expect(throws: QBODocumentError.access) {
            try QBODocumentNativeWorkflow.access(context: app.context)
        }
        #expect(app.requests.isEmpty)
    }

    @Test func injectedAPIStaysOnMainActorAcrossUploadAndEnqueue() async throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let attachment = try app.addAttachment()
        defer { try? FileManager.default.removeItem(at: attachment.localFileURL) }
        let base = files.dependencies()
        var checks = 0
        let dependencies = QBODocumentNativeWorkflow.Dependencies(owner: base.owner, access: { context, api in
            MainActor.preconditionIsolated()
            #expect(api === app.api)
            checks += 1
            return try base.access(context, api)
        }, store: base.store, transport: base.transport, realmProof: base.realmProof)
        _ = try await QBODocumentNativeWorkflow.upload(attachment, references: references, context: app.context,
            api: app.api, dependencies: dependencies)
        let queued = try #require(QBODocumentNativeWorkflow.enqueue(attachment, references: references,
            context: app.context, api: app.api, dependencies: dependencies))
        await queued.value
        #expect(checks == 3)
        #expect(files.sends == 1)
        #expect(attachment.quickBooksAttachableID == "A1")
    }

    @Test func uploadListsTheEncryptedJournalOnceAndWritesOnlyThroughTheSerialStore() async throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let attachment = try app.addAttachment()
        defer { try? FileManager.default.removeItem(at: attachment.localFileURL) }
        let base = files.dependencies(), journal = base.store
        var lists = 0, inserts = 0, writes: [Bool] = []
        let counted = QBODocumentCaptureStore(read: journal.read, list: { owner in
            lists += 1
            return try await journal.list(owner)
        }, bytes: journal.bytes, write: { row, expected, original in
            writes.append(row.dispatchStarted)
            try await journal.write(row, expected, original)
        }, insert: { row, original, known in
            inserts += 1
            try await journal.insert(row, original, known)
        })
        let dependencies = QBODocumentNativeWorkflow.Dependencies(owner: base.owner, access: base.access,
            store: counted, transport: base.transport, realmProof: base.realmProof)
        _ = try await QBODocumentNativeWorkflow.upload(attachment, references: references, context: app.context,
            api: app.api, dependencies: dependencies)
        #expect(lists == 1 && inserts == 1)
        #expect(writes.contains(true), "dispatchStarted is persisted through the store before the send.")
        #expect(attachment.quickBooksAttachableID == "A1" && files.sends == 1)
        // A retry reuses the confirmed row from one listing: no new row, no new send.
        _ = try await QBODocumentNativeWorkflow.upload(attachment, references: references, context: app.context,
            api: app.api, dependencies: dependencies)
        #expect(lists == 2 && inserts == 1 && files.sends == 1)
    }

    @Test func backgroundJournalListingDecryptsOffTheMainActorWithOneKeyRead() async throws {
        final class KeyReads: @unchecked Sendable {
            private let lock = NSLock(); private var values: [Bool] = []
            func record() { lock.lock(); values.append(Thread.isMainThread); lock.unlock() }
            var onMain: [Bool] { lock.lock(); defer { lock.unlock() }; return values }
        }
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let reads = KeyReads(), secret = files.secret
        let store = QBODocumentCaptureStore.encrypted(directory: files.root.appendingPathComponent("probe")) { _ in
            reads.record(); return secret
        }
        for name in ["One.txt", "Two.txt", "Three.txt"] {
            let data = Data("Original \(name)".utf8)
            let row = QBODocumentCapture(id: UUID(), owner: files.owner, scope: files.scope,
                file: try .init(filename: name, contentType: "text/plain", data: data),
                targets: [.init(type: "Invoice", id: "D1")], jobDocument: nil, createdAt: Date())
            try await store.write(row, nil, data)
        }
        let written = reads.onMain.count
        let listed = try await store.list(files.owner)
        #expect(listed.count == 3)
        #expect(Array(reads.onMain.dropFirst(written)) == [false],
                "Three headers decrypt off the main actor with a single key read.")
    }

    @Test func insertFromAStaleListingFailsInsteadOfCreatingADuplicateCapture() async throws {
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let store = files.store
        func row(_ name: String) throws -> (QBODocumentCapture, Data) {
            let data = Data("Original \(name)".utf8)
            return (QBODocumentCapture(id: UUID(), owner: files.owner, scope: files.scope,
                file: try .init(filename: name, contentType: "text/plain", data: data),
                targets: [.init(type: "Invoice", id: "D1")], jobDocument: nil, createdAt: Date()), data)
        }
        let listing = try await store.list(files.owner)
        // Another window captures while this upload awaited its proof check.
        let (other, otherData) = try row("Other.txt")
        try await store.write(other, nil, otherData)
        let (late, lateData) = try row("Late.txt")
        await #expect(throws: QBODocumentError.changed) { try await store.insert(late, lateData, listing) }
        #expect(try await store.list(files.owner).map(\.id) == [other.id])
        // A fresh listing proceeds.
        try await store.insert(late, lateData, try await store.list(files.owner))
        #expect(Set(try await store.list(files.owner).map(\.id)) == [other.id, late.id])
    }

    // MARK: - Reviewer invariants for the off-main snapshot and async fences

    private func requireSendable<T: Sendable>(_: T.Type) {}
    private nonisolated static func onMainThread() -> Bool { Thread.isMainThread }

    private func proof(_ app: QuickBooksBillingWorkflowTests.Fixture, _ files: QuickBooksDocumentWorkflowFixture,
                       realmID: String? = nil, createdAt: Date? = nil, customerID: UUID? = nil) -> AutomaticOutboundSync.RealmRecord {
        .init(companyID: files.owner.companyID, documentType: "invoice", documentID: app.invoice.id,
              customerID: customerID ?? app.customer.id, createdAt: createdAt ?? app.invoice.createdAt,
              realmID: realmID ?? files.scope.realmID, environment: files.scope.environment)
    }

    @Test func detachedSnapshotRunsOffTheMainActorAndReturnsOnlyImmutableValues() async throws {
        // Compile-time: only Sendable values cross the actor boundary.
        requireSendable(QBODocumentNativeWorkflow.SnapshotRead.self)
        requireSendable(QBODocumentNativeWorkflow.AttachmentSnapshot.self)
        requireSendable(QBODocumentNativeWorkflow.DocumentFact.self)
        requireSendable(QBODocumentNativeWorkflow.ManualJobDestination.self)
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let attachment = try app.addAttachment()
        defer { try? FileManager.default.removeItem(at: attachment.localFileURL) }
        let container = app.context.container, id = attachment.id, model = attachment.persistentModelID, targets = targets
        let (read, onMain) = try await Task.detached {
            (try QBOAttachmentSnapshotReader.read(container: container, attachmentID: id, expectedModel: model,
                                                  targets: targets, retainedOriginal: nil), Self.onMainThread())
        }.value
        #expect(!onMain)
        let entry = try await QBODocumentNativeWorkflow.snapshot(attachment, targets: targets, context: app.context)
        #expect(entry == read)
        #expect(read.attachmentModel == model && read.snapshot.id == id)
        #expect(read.documents.map(\.localID) == [app.invoice.id] && read.documents.map(\.createdAt) == [app.invoice.createdAt])
        #expect(read.snapshot.file.sha256 == QBODocumentFileInfo.hash(Data("Fixture service report".utf8)))
    }

    @Test func unsavedEditToTheOriginalFailsTheFenceBeforeAnyRequest() async throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let attachment = try app.addAttachment()
        defer { try? FileManager.default.removeItem(at: attachment.localFileURL) }
        // The store still holds the saved label; the context holds an unsaved one.
        attachment.displayName = "Relabeled before upload"
        await #expect(throws: QBODocumentError.changed) {
            _ = try await QBODocumentNativeWorkflow.upload(attachment, references: references, context: app.context,
                api: app.api, dependencies: files.dependencies())
        }
        #expect(files.requests.isEmpty && files.realmProofRequests.isEmpty)
        #expect(try await files.store.list(files.owner).isEmpty)
    }

    @Test func workspaceLossDuringTheProofAwaitStopsBeforeAnyCaptureOrPost() async throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let attachment = try app.addAttachment()
        defer { try? FileManager.default.removeItem(at: attachment.localFileURL) }
        // The proof itself passes, but the workspace is lost while it was awaited.
        files.realmProofDecision = { _ in files.authorized = false }
        await #expect(throws: QBODocumentError.access) {
            _ = try await QBODocumentNativeWorkflow.upload(attachment, references: references, context: app.context,
                api: app.api, dependencies: files.dependencies())
        }
        #expect(files.realmProofRequests.count == 1)
        #expect(files.requests.isEmpty, "No upload service read, reservation or send after the workspace changed.")
        files.authorized = true
        #expect(try await files.store.list(files.owner).isEmpty)
    }

    @Test func proofMustMatchTheExactDocumentCustomerAndCreationTime() async throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let attachment = try app.addAttachment()
        defer { try? FileManager.default.removeItem(at: attachment.localFileURL) }
        let memory = QuickBooksBillingWorkflowTests.RealmProofMemory()
        files.realmProofDecision = { try memory.requireProceed($0) }
        for stale in [proof(app, files, createdAt: app.invoice.createdAt.addingTimeInterval(1)),
                      proof(app, files, customerID: UUID())] {
            memory.stored = [stale.account: stale]
            await #expect(throws: AutomaticOutboundSync.RealmError.reviewRequired) {
                _ = try await QBODocumentNativeWorkflow.upload(attachment, references: references, context: app.context,
                    api: app.api, dependencies: files.dependencies())
            }
            // A file retry never binds or rewrites the stored proof.
            #expect(memory.stored == [stale.account: stale])
        }
        #expect(files.requests.isEmpty)
        #expect(try await files.store.list(files.owner).isEmpty)
    }

    @Test func uncertainSendOnlyReconcilesTheSameOperationAndNeverRePosts() async throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let attachment = try app.addAttachment()
        defer { try? FileManager.default.removeItem(at: attachment.localFileURL) }
        files.beforeResponse = { path in if path.hasSuffix("/send") { throw URLError(.networkConnectionLost) } }
        await #expect(throws: (any Error).self) {
            _ = try await QBODocumentNativeWorkflow.upload(attachment, references: references, context: app.context,
                api: app.api, dependencies: files.dependencies())
        }
        let row = try #require(try await files.store.list(files.owner).first)
        #expect(row.dispatchStarted, "The send intent was persisted before the request left.")
        let before = files.requests.count
        files.beforeResponse = nil
        _ = try await QBODocumentNativeWorkflow.upload(attachment, references: references, context: app.context,
            api: app.api, dependencies: files.dependencies())
        let retry = files.requests.dropFirst(before)
        #expect(!retry.isEmpty)
        #expect(retry.allSatisfy { !$0.path.hasSuffix("/send") && !($0.path == "/api/qbo-document-uploads" && $0.method == "POST") },
                "An uncertain send is only reconciled, never re-posted or re-reserved.")
        #expect(retry.allSatisfy { $0.path.contains(row.server?.id.uuidString.lowercased() ?? "missing") || $0.method == "GET" })
        #expect(files.sends == 1 && files.reservations == 1)
        #expect(try await files.store.list(files.owner).map(\.id) == [row.id], "The same journal operation, not a new one.")
        #expect(attachment.quickBooksAttachableID == "A1")
    }

    @Test func dispatchedRowIsNotReconciledOrResentUnderAnotherCompanyScope() async throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let attachment = try app.addAttachment()
        defer { try? FileManager.default.removeItem(at: attachment.localFileURL) }
        let memory = QuickBooksBillingWorkflowTests.RealmProofMemory()
        files.realmProofDecision = { try memory.requireProceed($0) }
        memory.stored = [proof(app, files).account: proof(app, files)]
        files.beforeResponse = { path in if path.hasSuffix("/send") { throw URLError(.networkConnectionLost) } }
        await #expect(throws: (any Error).self) {
            _ = try await QBODocumentNativeWorkflow.upload(attachment, references: references, context: app.context,
                api: app.api, dependencies: files.dependencies())
        }
        let dispatched = try #require(try await files.store.list(files.owner).first)
        #expect(dispatched.dispatchStarted && dispatched.scope == files.scope)
        let before = files.requests.count
        files.beforeResponse = nil
        // The connected company changes: the original dispatched row does not
        // match this scope, so this is a new write that needs proof here.
        let base = files.dependencies()
        let otherScope = QBODocumentScope(companyID: files.owner.companyID, realmID: "other-realm", environment: files.scope.environment)
        let switched = QBODocumentNativeWorkflow.Dependencies(owner: base.owner, access: { _, _ in
            .init(owner: files.owner, scope: otherScope, check: files.check)
        }, store: base.store, transport: base.transport, realmProof: base.realmProof)
        await #expect(throws: AutomaticOutboundSync.RealmError.wrongRealm) {
            _ = try await QBODocumentNativeWorkflow.upload(attachment, references: references, context: app.context,
                api: app.api, dependencies: switched)
        }
        #expect(files.requests.count == before, "Nothing is reconciled or sent under another company scope.")
        #expect(try await files.store.list(files.owner).map(\.id) == [dispatched.id])
    }

    @Test func recoveryPageSendOfASavedDocumentOriginalRequiresItsCompanyProof() async throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let data = Data("Original captured before proof".utf8)
        let local = QBODocumentLocalAttachment(attachmentID: UUID(), customerID: app.customer.id,
            customerQuickBooksID: "C1", serviceCallID: nil, invoiceID: app.invoice.id, estimateID: nil, kind: "serviceReport")
        let row = QBODocumentCapture(id: UUID(), owner: files.owner, scope: files.scope,
            file: try .init(filename: "Original.txt", contentType: "text/plain", data: data),
            targets: targets, jobDocument: nil, createdAt: Date(), localAttachment: local)
        let memory = QuickBooksBillingWorkflowTests.RealmProofMemory()
        files.realmProofDecision = { try memory.requireProceed($0) }
        let prove: ([AutomaticOutboundSync.RealmRecord]) async throws -> Void = { try files.proveRealm($0) }
        await #expect(throws: AutomaticOutboundSync.RealmError.reviewRequired) {
            try await QBODocumentNativeWorkflow.requireRealmProof(for: row, context: app.context, realmProof: prove)
        }
        let expected = AutomaticOutboundSync.RealmRecord(companyID: files.owner.companyID, documentType: "invoice",
            documentID: app.invoice.id, customerID: app.customer.id, createdAt: app.invoice.createdAt,
            realmID: files.scope.realmID, environment: files.scope.environment)
        memory.stored[expected.account] = expected
        try await QBODocumentNativeWorkflow.requireRealmProof(for: row, context: app.context, realmProof: prove)
        #expect(files.realmProofRequests == [[expected], [expected]])
        // Operator-entered targets with no saved local document are outside this gate.
        let manual = QBODocumentCapture(id: UUID(), owner: files.owner, scope: files.scope,
            file: try .init(filename: "Receipt.txt", contentType: "text/plain", data: data),
            targets: targets, jobDocument: nil, createdAt: Date())
        try await QBODocumentNativeWorkflow.requireRealmProof(for: manual, context: app.context, realmProof: prove)
        #expect(files.realmProofRequests.count == 2)
        #expect(files.requests.isEmpty)
    }

    @Test func legacyJobDocumentRowWithoutLocalAttachmentStillRequiresItsSavedDocumentProof() async throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let call = try job(app)
        let data = Data("Legacy job original".utf8)
        func legacyRow(_ job: QBODocumentJob, local: QBODocumentLocalAttachment? = nil) throws -> QBODocumentCapture {
            QBODocumentCapture(id: UUID(), owner: files.owner, scope: files.scope,
                file: try .init(filename: "Legacy.txt", contentType: "text/plain", data: data),
                targets: targets, jobDocument: job, createdAt: Date(), localAttachment: local)
        }
        let saved = QBODocumentJob(attachmentID: UUID(), serviceCallID: call.id, localCustomerID: app.customer.id,
            customerQuickBooksID: "C1", kind: "receipt", stage: "supporting",
            documents: [.init(type: "Invoice", localID: app.invoice.id, id: "D1")])
        let memory = QuickBooksBillingWorkflowTests.RealmProofMemory()
        files.realmProofDecision = { try memory.requireProceed($0) }
        let prove: ([AutomaticOutboundSync.RealmRecord]) async throws -> Void = { try files.proveRealm($0) }
        let legacy = try legacyRow(saved)
        await #expect(throws: AutomaticOutboundSync.RealmError.reviewRequired) {
            try await QBODocumentNativeWorkflow.requireRealmProof(for: legacy, context: app.context, realmProof: prove)
        }
        let expected = AutomaticOutboundSync.RealmRecord(companyID: files.owner.companyID, documentType: "invoice",
            documentID: app.invoice.id, customerID: app.customer.id, createdAt: app.invoice.createdAt,
            realmID: files.scope.realmID, environment: files.scope.environment)
        #expect(files.realmProofRequests == [[expected]], "The proof is derived from the job document's saved invoice.")
        memory.stored[expected.account] = expected
        try await QBODocumentNativeWorkflow.requireRealmProof(for: legacy, context: app.context, realmProof: prove)

        // Fail closed: a job document naming no saved invoice, another customer,
        // or a local attachment that disagrees with it never reaches the proof.
        let before = files.realmProofRequests.count
        let missing = QBODocumentJob(attachmentID: UUID(), serviceCallID: call.id, localCustomerID: app.customer.id,
            customerQuickBooksID: "C1", kind: "receipt", stage: "supporting",
            documents: [.init(type: "Invoice", localID: UUID(), id: "D1")])
        let foreign = QBODocumentJob(attachmentID: UUID(), serviceCallID: call.id, localCustomerID: UUID(),
            customerQuickBooksID: "C1", kind: "receipt", stage: "supporting",
            documents: [.init(type: "Invoice", localID: app.invoice.id, id: "D1")])
        let disagreeing = QBODocumentLocalAttachment(attachmentID: UUID(), customerID: app.customer.id,
            customerQuickBooksID: "C1", serviceCallID: call.id, invoiceID: UUID(), estimateID: nil, kind: "receipt")
        for invalid in [try legacyRow(missing), try legacyRow(foreign), try legacyRow(saved, local: disagreeing)] {
            await #expect(throws: QBODocumentError.invalid) {
                try await QBODocumentNativeWorkflow.requireRealmProof(for: invalid, context: app.context, realmProof: prove)
            }
        }
        #expect(files.realmProofRequests.count == before)
        #expect(files.requests.isEmpty)
    }

    @Test func receiptsRouteNeedsSavedJobDocumentProofBeforeANewSend() async throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let call = try job(app), url = try files.file()
        let row = try await QBODocumentNativeWorkflow.captureManual(access: files.access(), url: url, call: call,
            stage: "supporting", targets: targets, context: app.context, store: files.store, directory: files.root)
        #expect(row.jobDocument != nil && row.localAttachment != nil)
        let memory = QuickBooksBillingWorkflowTests.RealmProofMemory()
        files.realmProofDecision = { try memory.requireProceed($0) }
        let prove: ([AutomaticOutboundSync.RealmRecord]) async throws -> Void = { try files.proveRealm($0) }
        let check = { try files.check(); try await QBODocumentNativeWorkflow.checkLocalOriginal(row, context: app.context) }
        await #expect(throws: AutomaticOutboundSync.RealmError.reviewRequired) {
            _ = try await QBODocumentNativeWorkflow.deliverCaptured(row, context: app.context, store: files.store,
                transport: files.request, check: check, realmProof: prove)
        }
        #expect(files.requests.isEmpty, "No reservation or send without the saved invoice's company proof.")

        // The session is re-checked after the proof read: a lost session sends nothing.
        let expected = AutomaticOutboundSync.RealmRecord(companyID: files.owner.companyID, documentType: "invoice",
            documentID: app.invoice.id, customerID: app.customer.id, createdAt: app.invoice.createdAt,
            realmID: files.scope.realmID, environment: files.scope.environment)
        memory.stored[expected.account] = expected
        files.realmProofDecision = { records in try memory.requireProceed(records); files.authorized = false }
        await #expect(throws: QBODocumentError.access) {
            _ = try await QBODocumentNativeWorkflow.deliverCaptured(row, context: app.context, store: files.store,
                transport: files.request, check: check, realmProof: prove)
        }
        #expect(files.requests.isEmpty)

        files.authorized = true
        files.realmProofDecision = { try memory.requireProceed($0) }
        let session = try await QBODocumentNativeWorkflow.deliverCaptured(row, context: app.context, store: files.store,
            transport: files.request, check: check, realmProof: prove)
        try await QBODocumentNativeWorkflow.applyConfirmed(session.record, context: app.context)
        let original = try #require(try app.context.fetch(FetchDescriptor<ServiceDocumentAttachment>()).first)
        #expect(original.quickBooksAttachableID == "A1")
        #expect(files.reservations == 1 && files.sends == 1)
        #expect(files.realmProofRequests.allSatisfy { $0 == [expected] })
    }

    @Test func receiptsRouteReconcilesADispatchedOriginalWithoutAnotherProofOrSend() async throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let call = try job(app), url = try files.file()
        let row = try await QBODocumentNativeWorkflow.captureManual(access: files.access(), url: url, call: call,
            stage: "supporting", targets: targets, context: app.context, store: files.store, directory: files.root)
        let memory = QuickBooksBillingWorkflowTests.RealmProofMemory()
        files.realmProofDecision = { try memory.requireProceed($0) }
        let prove: ([AutomaticOutboundSync.RealmRecord]) async throws -> Void = { try files.proveRealm($0) }
        let expected = AutomaticOutboundSync.RealmRecord(companyID: files.owner.companyID, documentType: "invoice",
            documentID: app.invoice.id, customerID: app.customer.id, createdAt: app.invoice.createdAt,
            realmID: files.scope.realmID, environment: files.scope.environment)
        memory.stored[expected.account] = expected
        let check = { try files.check(); try await QBODocumentNativeWorkflow.checkLocalOriginal(row, context: app.context) }
        files.beforeResponse = { path in if path.hasSuffix("/send") { throw URLError(.networkConnectionLost) } }
        await #expect(throws: (any Error).self) {
            _ = try await QBODocumentNativeWorkflow.deliverCaptured(row, context: app.context, store: files.store,
                transport: files.request, check: check, realmProof: prove)
        }
        #expect(files.sends == 1)
        let dispatched = try #require(try await files.store.read(files.owner, row.id))
        #expect(QBODocumentNativeWorkflow.isDispatched(dispatched))
        memory.stored.removeAll()
        files.beforeResponse = nil
        let session = try await QBODocumentNativeWorkflow.deliverCaptured(dispatched, context: app.context,
            store: files.store, transport: files.request, check: check, realmProof: prove)
        #expect(session.record.server?.providerID == "A1")
        #expect(files.sends == 1 && files.reservations == 1)
        #expect(files.realmProofRequests.count == 1)
    }

    @Test func repeatedManualCaptureKeepsOneOriginalJobFileAndPhotoCount() async throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let call = try job(app), bytes = Data([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3])
        let url = try files.file("Before repair.png", data: bytes)
        let row = try await QBODocumentNativeWorkflow.captureManual(access: files.access(), url: url, call: call,
            stage: "before", targets: targets, context: app.context, store: files.store, directory: files.root)
        let repeated = try await QBODocumentNativeWorkflow.captureManual(access: files.access(), url: url, call: call,
            stage: "before", targets: targets, context: app.context, store: files.store, directory: files.root)
        #expect(repeated == row)
        #expect(call.beforePhotoCount == 1 && call.afterPhotoCount == 0)
        #expect(call.documentationCompletedAt == nil)
        #expect(try app.context.fetch(FetchDescriptor<ServiceDocumentAttachment>()).count == 1)
        #expect(try await files.store.bytes(files.owner, row.id) == bytes)
        #expect(files.requests.isEmpty)
        #expect(row.jobDocument?.serviceCallID == call.id && row.jobDocument?.stage == "before")
    }

    @Test func missingForeignAndMismatchedJobDestinationsCannotCaptureFinancialOwnership() async throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let call = try job(app), url = try files.file()
        for invalid in [[], [QBODocumentTarget(type: "Bill", id: "D1")], [.init(type: "Invoice", id: "another")]] {
            await #expect(throws: QBODocumentError.jobDestination) {
                try await QBODocumentNativeWorkflow.captureManual(access: files.access(), url: url, call: call,
                    stage: "supporting", targets: invalid, context: app.context, store: files.store, directory: files.root)
            }
        }
        app.invoice.customer = Customer(name: "Different business customer")
        // A saved foreign-customer invoice is not this job's destination.
        // (An unsaved billing edit fails closed as `.changed`; see the capture fence test.)
        try app.context.save()
        await #expect(throws: QBODocumentError.jobDestination) {
            try await QBODocumentNativeWorkflow.captureManual(access: files.access(), url: url, call: call,
                stage: "supporting", targets: targets, context: app.context, store: files.store, directory: files.root)
        }
        #expect(try await files.store.list(files.owner).isEmpty && files.requests.isEmpty)
    }

    @Test func nonPhotoAndUnknownStageCannotAdvanceJobDocumentation() async throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let call = try job(app), url = try files.file()
        await #expect(throws: QBODocumentError.photoRequired) {
            try await QBODocumentNativeWorkflow.captureManual(access: files.access(), url: url, call: call,
                stage: "before", targets: targets, context: app.context, store: files.store, directory: files.root)
        }
        await #expect(throws: QBODocumentError.invalid) {
            try await QBODocumentNativeWorkflow.captureManual(access: files.access(), url: url, call: call,
                stage: "finished", targets: targets, context: app.context, store: files.store, directory: files.root)
        }
        #expect(call.beforePhotoCount == 0 && call.afterPhotoCount == 0 && call.documentationStartedAt == nil)
        #expect(try await files.store.list(files.owner).isEmpty)
    }

    @Test func manualCaptureListsOffMainAndRechecksAccessAndDestinationAfterAwaiting() async throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let call = try job(app), url = try files.file()
        let journal = files.store
        var backgroundLists = 0, inserts = 0
        var duringListing: (() -> Void)?
        let guarded = QBODocumentCaptureStore(read: journal.read, list: { owner in
            backgroundLists += 1
            let rows = try await journal.list(owner)
            duringListing?()
            return rows
        }, bytes: journal.bytes, write: journal.write, insert: { row, original, known in
            inserts += 1
            try await journal.insert(row, original, known)
        })
        // Access lost while the journal was listed: nothing is captured.
        duringListing = { files.authorized = false }
        await #expect(throws: QBODocumentError.access) {
            try await QBODocumentNativeWorkflow.captureManual(access: files.access(), url: url, call: call,
                stage: "supporting", targets: targets, context: app.context, store: guarded, directory: files.root)
        }
        #expect(inserts == 0)
        #expect(try await journal.list(files.owner).isEmpty)
        // The job's billing destination changed while listing: nothing is captured.
        files.authorized = true
        duringListing = { app.invoice.customer = Customer(name: "Different business customer") }
        let original = app.customer
        await #expect(throws: (any Error).self) {
            try await QBODocumentNativeWorkflow.captureManual(access: files.access(), url: url, call: call,
                stage: "supporting", targets: targets, context: app.context, store: guarded, directory: files.root)
        }
        #expect(inserts == 0)
        #expect(try await journal.list(files.owner).isEmpty)
        app.invoice.customer = original
        // An unsaved billing edit fails closed; once saved, the store is authoritative again.
        try app.context.save()
        // Unchanged: one off-main listing and one insert; a repeat reuses the row.
        duringListing = nil
        let row = try await QBODocumentNativeWorkflow.captureManual(access: files.access(), url: url, call: call,
            stage: "supporting", targets: targets, context: app.context, store: guarded, directory: files.root)
        let repeated = try await QBODocumentNativeWorkflow.captureManual(access: files.access(), url: url, call: call,
            stage: "supporting", targets: targets, context: app.context, store: guarded, directory: files.root)
        #expect(repeated == row && inserts == 1)
        #expect(backgroundLists == 4)
        #expect(try await journal.list(files.owner).map(\.id) == [row.id])
        #expect(files.requests.isEmpty)
    }

    @Test func operationalSaveFailureRetainsOriginalWithoutClaimingAJobFile() async throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let call = try job(app), url = try files.file()
        await #expect(throws: QBODocumentError.storage) {
            try await QBODocumentNativeWorkflow.captureManual(access: files.access(), url: url, call: call,
                stage: "supporting", targets: targets, context: app.context, store: files.store, directory: files.root,
                save: { _ in throw QBODocumentError.storage })
        }
        let rows = try await files.store.list(files.owner)
        #expect(rows.count == 1)
        let original = try #require(rows.first)
        #expect(try await files.store.bytes(files.owner, original.id) == Data(contentsOf: url))
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
        let row = try await QBODocumentNativeWorkflow.captureManual(access: files.access(), url: url, call: call,
            stage: "after", targets: targets, context: app.context, store: files.store, directory: files.root)
        let session = try await QBODocumentCaptureSession(record: row, store: files.store, check: files.check)
        try await session.send(client: .init(transport: files.request, check: files.check))
        try await QBODocumentNativeWorkflow.applyConfirmed(session.record, context: app.context)
        try await QBODocumentNativeWorkflow.applyConfirmed(session.record, context: app.context)
        let original = try #require(try app.context.fetch(FetchDescriptor<ServiceDocumentAttachment>()).first)
        #expect(original.quickBooksAttachableID == "A1" && original.isQuickBooksAttached(to: references))
        #expect(original.serviceCallID == call.id)
        #expect(call.afterPhotoCount == 1 && other.afterPhotoCount == 0)
        #expect(call.documentationCompletedAt == nil && other.documentationStartedAt == nil)
        #expect(files.sends == 1)
    }

    @Test func changedOriginalBytesStopBeforeAnyDispatchAndRetainCapturedBytes() async throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let call = try job(app), url = try files.file()
        let row = try await QBODocumentNativeWorkflow.captureManual(access: files.access(), url: url, call: call,
            stage: "supporting", targets: targets, context: app.context, store: files.store, directory: files.root)
        let original = try #require(try app.context.fetch(FetchDescriptor<ServiceDocumentAttachment>()).first)
        try Data("Changed after selection".utf8).write(to: original.localFileURL)
        await #expect(throws: QBODocumentError.changed) { try await QBODocumentNativeWorkflow.checkLocalOriginal(row, context: app.context) }
        #expect(try await files.store.bytes(files.owner, row.id) == Data(contentsOf: url))
        #expect(files.requests.isEmpty && original.quickBooksAttachableID == nil)
    }

    @Test func localConfirmationSaveFailureCanApplyOriginalLaterWithoutAnotherUpload() async throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let call = try job(app), url = try files.file()
        let row = try await QBODocumentNativeWorkflow.captureManual(access: files.access(), url: url, call: call,
            stage: "supporting", targets: targets, context: app.context, store: files.store, directory: files.root)
        let session = try await QBODocumentCaptureSession(record: row, store: files.store, check: files.check)
        try await session.send(client: .init(transport: files.request, check: files.check))
        let original = try #require(try app.context.fetch(FetchDescriptor<ServiceDocumentAttachment>()).first)
        await #expect(throws: QBODocumentError.storage) {
            try await QBODocumentNativeWorkflow.applyConfirmed(session.record, context: app.context,
                save: { _ in throw QBODocumentError.storage })
        }
        #expect(original.quickBooksAttachableID == nil && original.quickBooksAttachedEntityKeysRaw == nil)
        #expect(session.record.needsAttention && session.record.needsLocalApplication)
        #expect(session.record.status == "Saved in QuickBooks — finish local link")
        try await QBODocumentNativeWorkflow.applyConfirmed(session.record, context: app.context)
        try await session.markLocalApplied()
        #expect(!session.record.needsAttention && session.record.localAppliedAt != nil)
        let restored = try #require(try await files.store.read(files.owner, row.id))
        #expect(!restored.needsAttention)
        var reset = restored; reset.revision += 1; reset.localAppliedAt = nil
        await #expect(throws: QBODocumentError.changed) { try await files.store.write(reset, restored.revision, nil) }
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
        #expect(try await files.store.list(files.owner).isEmpty)
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
        #expect(try await files.store.list(files.owner).isEmpty)
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
        let saved = try #require(try await files.store.list(files.owner).first)
        #expect(saved.jobDocument == nil && saved.localAttachment?.attachmentID == attachment.id)
        files.beforeResponse = nil
        let recovery = try await QBODocumentCaptureSession(record: saved, store: files.store, check: files.check)
        let beforeCancel = files.requests.count
        await #expect(throws: QBODocumentError.review) {
            try await recovery.cancel(client: .init(transport: files.request, check: files.check))
        }
        #expect(files.requests.count == beforeCancel)
        try await recovery.recover(client: .init(transport: files.request, check: files.check))
        app.customer.quickBooksID = "C2"
        await #expect(throws: QBODocumentError.changed) {
            try await QBODocumentNativeWorkflow.applyConfirmed(recovery.record, context: app.context)
        }
        #expect(attachment.quickBooksAttachableID == nil)
        app.customer.quickBooksID = "C1"
        try await QBODocumentNativeWorkflow.applyConfirmed(recovery.record, context: app.context)
        #expect(attachment.quickBooksAttachableID == "A1" && files.sends == 1)
        var relabeled = recovery.record; relabeled.revision += 1; relabeled.localAttachment = nil
        await #expect(throws: QBODocumentError.changed) { try await files.store.write(relabeled, recovery.record.revision, nil) }
    }

    @Test func backgroundRetainedMediaReadKeepsOriginalOwnerAndBytes() async throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let user = AppUser(email: files.owner.actorEmail, role: .admin)
        app.context.insert(user)
        try app.context.save()
        let call = try job(app)
        let url = try files.file()
        let expected = try Data(contentsOf: url)
        let row = try await QBODocumentNativeWorkflow.captureManual(access: files.access(), url: url,
            call: call, stage: "supporting", targets: targets, context: app.context,
            store: files.store, directory: files.root)
        let attachment = try #require(try app.context.fetch(FetchDescriptor<ServiceDocumentAttachment>()).first)
        try FileManager.default.removeItem(at: attachment.localFileURL)
        let secret = files.secret
        let reader = QBODocumentRetainedMediaReader(container: app.context.container,
            directory: files.root.appendingPathComponent("journal"), loadKey: { secret })
        let media = try await reader.read(ownerStorageKey: files.owner.storageKey,
                                          actorEmail: files.owner.actorEmail,
                                          attachmentID: attachment.id)
        #expect(media.bytes == expected)
        #expect(media.sha256 == row.file.sha256)
        await #expect(throws: QBODocumentError.review) {
            try await reader.read(ownerStorageKey: String(repeating: "a", count: 64),
                                  actorEmail: files.owner.actorEmail, attachmentID: attachment.id)
        }
    }

    @Test func retainedMediaReadRejectsRoleAndDocumentRotationAcrossHandoff() async throws {
        let app = try QuickBooksBillingWorkflowTests.Fixture(linkedInvoice: true)
        let files = try QuickBooksDocumentWorkflowFixture(); defer { files.cleanup() }
        let user = AppUser(email: files.owner.actorEmail, role: .admin)
        app.context.insert(user)
        try app.context.save()
        let call = try job(app)
        let url = try files.file()
        _ = try await QBODocumentNativeWorkflow.captureManual(access: files.access(), url: url,
            call: call, stage: "supporting", targets: targets, context: app.context,
            store: files.store, directory: files.root)
        let attachment = try #require(try app.context.fetch(FetchDescriptor<ServiceDocumentAttachment>()).first)
        try FileManager.default.removeItem(at: attachment.localFileURL)
        let secret = files.secret
        let directory = files.root.appendingPathComponent("journal")

        let roleGate = RetainedMediaReadGate()
        let roleReader = QBODocumentRetainedMediaReader(container: app.context.container,
            directory: directory, loadKey: { secret }, afterSnapshot: { await roleGate.pause() })
        let roleTask = Task {
            try await roleReader.read(ownerStorageKey: files.owner.storageKey,
                                      actorEmail: files.owner.actorEmail, attachmentID: attachment.id)
        }
        await roleGate.waitUntilReached()
        user.role = .standard
        try app.context.save()
        await roleGate.release()
        await #expect(throws: QBODocumentError.access) { try await roleTask.value }

        user.role = .admin
        try app.context.save()
        let documentGate = RetainedMediaReadGate()
        let documentReader = QBODocumentRetainedMediaReader(container: app.context.container,
            directory: directory, loadKey: { secret }, afterSnapshot: { await documentGate.pause() })
        let documentTask = Task {
            try await documentReader.read(ownerStorageKey: files.owner.storageKey,
                                          actorEmail: files.owner.actorEmail, attachmentID: attachment.id)
        }
        await documentGate.waitUntilReached()
        let otherCustomer = Customer(quickBooksID: "C2", name: "Different customer")
        app.context.insert(otherCustomer)
        attachment.customer = otherCustomer
        try app.context.save()
        await documentGate.release()
        await #expect(throws: QBODocumentError.changed) { try await documentTask.value }
    }
}
