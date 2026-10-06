import Foundation
import SwiftData
import UniformTypeIdentifiers

@MainActor enum QBODocumentNativeWorkflow {
    struct Access {
        let owner: QBODocumentOwner
        let scope: QBODocumentScope
        let check: () throws -> Void
    }

    /// The same coordinator is exercised with isolated persistence/transport in
    /// tests. App callers always use the mounted-business authority below.
    struct Dependencies {
        let owner: (ModelContext) throws -> QBODocumentOwner
        let access: (ModelContext, QuickBooksDataAPI) throws -> Access
        let store: QBODocumentCaptureStore
        let transport: QBODocumentUploadClient.Transport
        /// Throws unless every saved invoice/estimate target already carries
        /// proof for exactly this company, realm and environment. Never binds.
        let realmProof: ([AutomaticOutboundSync.RealmRecord]) async throws -> Void
        static var live: Self {
            .init(owner: QBODocumentOwner.capture, access: { try QBODocumentNativeWorkflow.access(context: $0, api: $1) }, store: .device,
                  transport: GunnAireBackendService.documentUploadRequest,
                  realmProof: { try await QuickBooksDocumentRealmProofStore.shared.requireProceed($0) })
        }
    }

    static func access(context: ModelContext, api: QuickBooksDataAPI? = nil) throws -> Access {
        let owner = try QBODocumentOwner.capture(context: context)
        // Resolve live dependencies inside this actor, never in a caller's default argument.
        let api = api ?? .shared
        let workflow = try api.captureWorkspaceWorkflow()
        guard workflow.companyID == owner.companyID, let realm = workflow.realmID else { throw QBODocumentError.access }
        let scope = QBODocumentScope(companyID: owner.companyID, realmID: realm, environment: workflow.environment)
        try scope.validate()
        return Access(owner: owner, scope: scope, check: {
            try workflow.check()
            guard try QBODocumentOwner.capture(context: context) == owner else { throw QBODocumentError.access }
        })
    }

    nonisolated static func fileData(_ url: URL) throws -> Data {
        let securityScope = url.startAccessingSecurityScopedResource()
        defer { if securityScope { url.stopAccessingSecurityScopedResource() } }
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard properties.isRegularFile == true, (1...QBODocumentFileInfo.maximum).contains(properties.fileSize ?? 0) else { throw QBODocumentError.file }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: QBODocumentFileInfo.maximum + 1), data.count == properties.fileSize,
              data.count <= QBODocumentFileInfo.maximum else { throw QBODocumentError.file }
        return data
    }

    static func capture(access: Access, url: URL, filename: String? = nil, contentType: String? = nil,
                        targets: [QBODocumentTarget], job: QBODocumentJob?, localAttachment: QBODocumentLocalAttachment? = nil,
                        store: QBODocumentCaptureStore? = nil,
                        knownRows: [QBODocumentCapture]? = nil) async throws -> QBODocumentCapture {
        try access.check()
        let store = store ?? .device
        let name = filename ?? url.lastPathComponent
        let type = contentType ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        // Reading and hashing the original run off the main actor.
        let (data, file) = try await Task.detached(priority: .userInitiated) {
            let data = try fileData(url)
            return (data, try QBODocumentFileInfo(filename: name, contentType: type, data: data))
        }.value
        try access.check()
        let targets = try QBODocumentTarget.normalized(targets)
        try job?.validate(targets: targets)
        // One listing (the caller's, or a fresh off-main one). A reused row is
        // re-read by ID; a new row is inserted only if the journal still holds
        // exactly the listed rows (checked on the serial journal writer).
        let rows: [QBODocumentCapture]
        if let knownRows { rows = knownRows } else { rows = try await store.list(access.owner); try access.check() }
        let matches = rows.filter { matchesCapture($0, scope: access.scope, file: file, targets: targets) }
        guard matches.count <= 1 else { throw QBODocumentError.changed }
        if let listed = matches.first {
            guard let original = try await store.read(access.owner, listed.id),
                  matchesCapture(original, scope: access.scope, file: file, targets: targets),
                  original.jobDocument == job, original.localAttachment == localAttachment else { throw QBODocumentError.changed }
            let saved = try await store.bytes(access.owner, original.id)
            try await Task.detached(priority: .userInitiated) { try file.verify(saved) }.value
            try access.check()
            return original
        }
        let row = QBODocumentCapture(id: UUID(), owner: access.owner, scope: access.scope, file: file,
                                    targets: targets, jobDocument: job, createdAt: Date(), localAttachment: localAttachment)
        try await store.insert(row, data, rows)
        try access.check()
        return row
    }

    /// The live (not cancelled) capture of exactly this original and destination.
    static func matchesCapture(_ row: QBODocumentCapture, scope: QBODocumentScope,
                               file: QBODocumentFileInfo, targets: [QBODocumentTarget]) -> Bool {
        !row.cancelledLocally && row.server?.state != .cancelled && row.scope == scope && row.file == file && row.targets == targets
    }

    nonisolated struct AttachmentSnapshot: Equatable, Sendable {
        let id: UUID
        let customerID: UUID
        let customerQuickBooksID: String
        let serviceCallID: UUID?
        let invoiceID: UUID?
        let estimateID: UUID?
        let kind: String
        let filename: String
        let path: String
        let file: QBODocumentFileInfo
        let job: QBODocumentJob?
        var localAttachment: QBODocumentLocalAttachment {
            .init(attachmentID: id, customerID: customerID, customerQuickBooksID: customerQuickBooksID,
                  serviceCallID: serviceCallID, invoiceID: invoiceID, estimateID: estimateID, kind: kind)
        }
    }

    nonisolated static func filename(_ attachment: ServiceDocumentAttachment) -> String {
        // Older document labels omit the extension. Preserve the readable
        // label while retaining the actual file type; never change its bytes.
        let name = attachment.displayName
        if (name as NSString).pathExtension.isEmpty, !attachment.localFileURL.pathExtension.isEmpty {
            return name + "." + attachment.localFileURL.pathExtension
        }
        return name
    }

    /// One saved invoice/estimate as read for a snapshot: its exact model
    /// identity plus the immutable facts its company proof is keyed on.
    nonisolated struct DocumentFact: Equatable, Sendable {
        let type: String
        let localID: UUID
        let providerID: String
        let createdAt: Date
        let model: PersistentIdentifier
    }

    /// An immutable, `Sendable` snapshot read off the main actor. It holds
    /// values and model identifiers only: never a SwiftData model or a secret.
    nonisolated struct SnapshotRead: Equatable, Sendable {
        let snapshot: AttachmentSnapshot
        let attachmentModel: PersistentIdentifier
        let customerModel: PersistentIdentifier
        let documents: [DocumentFact]
        let callModel: PersistentIdentifier?
    }

    /// Takes the attachment snapshot off the main actor: exact-ID reads in a
    /// private context, file read and SHA-256 on a background task. The main
    /// actor then confirms, from models it already holds in memory (no fetch),
    /// that no unsaved edit, pending delete or pending duplicate disagrees with
    /// what was read from the store.
    static func snapshot(_ attachment: ServiceDocumentAttachment, targets: [QBODocumentTarget], context: ModelContext,
                         retainedOriginal: Data? = nil) async throws -> SnapshotRead {
        guard attachment.modelContext === context, !attachment.isDeleted else { throw QBODocumentError.changed }
        let container = context.container, attachmentID = attachment.id, model = attachment.persistentModelID
        let read = try await Task.detached(priority: .userInitiated) {
            try QBOAttachmentSnapshotReader.read(container: container, attachmentID: attachmentID, expectedModel: model,
                                                 targets: targets, retainedOriginal: retainedOriginal)
        }.value
        try confirmInMemory(read, attachment: attachment, context: context)
        return read
    }

    /// The exact attachment for an identity read off the main actor: the
    /// already-registered instance, or one exact-ID fetch (at most two rows)
    /// whose model identity must match. Never a faulting stand-in for a row
    /// that may have been deleted while awaiting.
    static func exactAttachment(_ model: PersistentIdentifier, id: UUID,
                                context: ModelContext) throws -> ServiceDocumentAttachment {
        if let registered: ServiceDocumentAttachment = context.registeredModel(for: model) {
            guard registered.id == id, !registered.isDeleted else { throw QBODocumentError.changed }
            return registered
        }
        var fetch = FetchDescriptor<ServiceDocumentAttachment>(predicate: #Predicate { $0.id == id })
        fetch.fetchLimit = 2
        let matches = try context.fetch(fetch)
        guard matches.count == 1, let found = matches.first, found.persistentModelID == model,
              !found.isDeleted else { throw QBODocumentError.changed }
        return found
    }

    /// Main-actor confirmation using only already-registered models and the
    /// context's pending-change lists. A model that is not registered has no
    /// unsaved state here, so the store's value read off-main is authoritative.
    static func confirmInMemory(_ read: SnapshotRead, attachment held: ServiceDocumentAttachment?,
                                context: ModelContext) throws {
        let snapshot = read.snapshot
        let pending = context.insertedModelsArray + context.changedModelsArray
        let deleted = Set(context.deletedModelsArray.map(\.persistentModelID))
        var identities = [read.attachmentModel, read.customerModel] + read.documents.map(\.model)
        if let call = read.callModel { identities.append(call) }
        guard deleted.isDisjoint(with: identities) else { throw QBODocumentError.changed }
        let attachment: ServiceDocumentAttachment? = held ?? context.registeredModel(for: read.attachmentModel)
        if let attachment {
            guard attachment.persistentModelID == read.attachmentModel, !attachment.isDeleted,
                  attachment.id == snapshot.id, attachment.customer?.persistentModelID == read.customerModel,
                  attachment.invoiceID == snapshot.invoiceID, attachment.estimateID == snapshot.estimateID,
                  attachment.serviceCallID == snapshot.serviceCallID, attachment.kindRaw == snapshot.kind,
                  attachment.displayName == snapshot.filename, attachment.localFilePath == snapshot.path,
                  attachment.contentType == snapshot.file.contentType else { throw QBODocumentError.changed }
        }
        if let customer: Customer = context.registeredModel(for: read.customerModel) {
            guard customer.id == snapshot.customerID,
                  QuickBooksBillingIdentity.identifier(customer.quickBooksID) == snapshot.customerQuickBooksID else { throw QBODocumentError.changed }
        }
        for fact in read.documents {
            if fact.type == "Invoice", let invoice: Invoice = context.registeredModel(for: fact.model) {
                guard invoice.id == fact.localID, invoice.createdAt == fact.createdAt,
                      invoice.customer?.persistentModelID == read.customerModel, invoice.quickBooksIdentityReviewMessage == nil,
                      QuickBooksBillingIdentity.identifier(invoice.quickBooksID) == fact.providerID,
                      snapshot.serviceCallID == nil || invoice.serviceCallID == nil || snapshot.serviceCallID == invoice.serviceCallID
                else { throw QBODocumentError.changed }
            }
            if fact.type == "Estimate", let estimate: Estimate = context.registeredModel(for: fact.model) {
                guard estimate.id == fact.localID, estimate.createdAt == fact.createdAt,
                      estimate.customer?.persistentModelID == read.customerModel,
                      QuickBooksBillingIdentity.identifier(estimate.quickBooksID) == fact.providerID,
                      snapshot.serviceCallID == nil || estimate.serviceCallID == nil || snapshot.serviceCallID == estimate.serviceCallID ||
                        snapshot.serviceCallID == estimate.scheduledServiceCallID
                else { throw QBODocumentError.changed }
            }
        }
        if let callModel = read.callModel, let call: ServiceCall = context.registeredModel(for: callModel) {
            guard call.id == snapshot.serviceCallID, call.customer?.persistentModelID == read.customerModel else { throw QBODocumentError.changed }
        }
        // A pending (unsaved) record that duplicates an identity the store read
        // as unique would have made the original main-context check fail.
        let invoiceIDs = Set(read.documents.filter { $0.type == "Invoice" }.map(\.localID))
        let estimateIDs = Set(read.documents.filter { $0.type == "Estimate" }.map(\.localID))
        let invoiceProviders = Set(read.documents.filter { $0.type == "Invoice" }.map(\.providerID))
        let estimateProviders = Set(read.documents.filter { $0.type == "Estimate" }.map(\.providerID))
        for model in pending where !identities.contains(model.persistentModelID) {
            if let file = model as? ServiceDocumentAttachment, file.id == snapshot.id { throw QBODocumentError.changed }
            if let customer = model as? Customer, customer.id == snapshot.customerID { throw QBODocumentError.changed }
            if let invoice = model as? Invoice, invoiceIDs.contains(invoice.id) ||
                QuickBooksBillingIdentity.identifier(invoice.quickBooksID).map(invoiceProviders.contains) == true { throw QBODocumentError.changed }
            if let estimate = model as? Estimate, estimateIDs.contains(estimate.id) ||
                QuickBooksBillingIdentity.identifier(estimate.quickBooksID).map(estimateProviders.contains) == true { throw QBODocumentError.changed }
            if let call = model as? ServiceCall, call.id == snapshot.serviceCallID { throw QBODocumentError.changed }
        }
    }

    /// All attachment entry points share this operation. A late result cannot
    /// relabel another local file; failed saves retain the server-owned original
    /// so the next review can apply it without uploading another copy.
    static func upload(_ attachment: ServiceDocumentAttachment, references: [QuickBooksAttachableReference], context: ModelContext,
                       api: QuickBooksDataAPI? = nil, validate: @escaping () throws -> Void = {},
                       dependencies: Dependencies? = nil,
                       save: (ModelContext) throws -> Void = { try $0.save() }) async throws -> String {
        try validate()
        let api = api ?? .shared
        let dependencies = dependencies ?? .live
        let access = try dependencies.access(context, api)
        let targets = try QBODocumentTarget.normalized(references.map { .init(type: $0.EntityRef.type, id: $0.EntityRef.value) })
        let original = try await snapshot(attachment, targets: targets, context: context)
        try access.check(); try validate()
        if attachment.quickBooksAttachableID != nil && !attachment.isQuickBooksAttached(to: references) {
            // Extending an existing provider file's links needs its own reviewed
            // metadata operation, not a silent second upload of the same bytes.
            throw QBODocumentError.review
        }
        // The fence for every later step: workspace authority, the caller's
        // validation and the exact same local original (re-read off the main
        // actor), re-run after each of its own suspensions.
        let check: () async throws -> Void = {
            try access.check(); try validate()
            let current = try await snapshot(attachment, targets: targets, context: context)
            try access.check(); try validate()
            guard current == original else { throw QBODocumentError.changed }
        }
        let store = dependencies.store
        // One bounded journal listing, decrypted off the main actor and reused
        // for both the dispatched decision and the capture below.
        let rows = try await store.list(access.owner)
        try await check()
        // An original already dispatched under its saved scope is only
        // reconciled below. Anything else is a new provider write and first
        // needs the saved document's original company proof. Dispatch is
        // monotonic, so a row listed as dispatched is still dispatched.
        let dispatched = rows.contains {
            matchesCapture($0, scope: access.scope, file: original.snapshot.file, targets: targets) && isDispatched($0)
        }
        if !dispatched {
            try await dependencies.realmProof(try realmRecords(for: original, scope: access.scope))
            try await check()
        }
        let row = try await capture(access: access, url: attachment.localFileURL, filename: original.snapshot.file.filename,
                                    contentType: attachment.contentType, targets: targets, job: original.snapshot.job,
                                    localAttachment: original.snapshot.localAttachment, store: store, knownRows: rows)
        let session = try await QBODocumentCaptureSession(record: row, store: store, check: check)
        let client = QBODocumentUploadClient(transport: dependencies.transport, check: check)
        if isDispatched(row) { try await session.recover(client: client) }
        else { try await session.send(client: client) }
        try await check()
        guard let result = session.record.server, result.state == .confirmed, let identifier = result.providerID else { throw QBODocumentError.review }
        let oldID = attachment.quickBooksAttachableID, oldKeys = attachment.quickBooksAttachedEntityKeysRaw, oldError = attachment.quickBooksSyncError
        guard oldID == nil || oldID == identifier else { throw QBODocumentError.changed }
        attachment.quickBooksAttachableID = identifier; attachment.markQuickBooksAttached(to: references); attachment.quickBooksSyncError = nil
        do { try save(context) }
        catch {
            attachment.quickBooksAttachableID = oldID; attachment.quickBooksAttachedEntityKeysRaw = oldKeys; attachment.quickBooksSyncError = oldError
            throw QBODocumentError.storage
        }
        // The model now contains the original provider receipt. Do not re-run
        // its pre-write snapshot guard while acknowledging this local save.
        let acknowledged = try await QBODocumentCaptureSession(record: session.record, store: store, check: access.check)
        try await acknowledged.markLocalApplied()
        return identifier
    }

    /// The proof each saved invoice/estimate target must already carry, built
    /// from the exact documents the off-main snapshot read: ID, customer and
    /// `createdAt`, with this company, realm and environment.
    static func realmRecords(for read: SnapshotRead, scope: QBODocumentScope) throws -> [AutomaticOutboundSync.RealmRecord] {
        guard !read.documents.isEmpty, Set(read.documents.map(\.localID)).count == read.documents.count else { throw QBODocumentError.invalid }
        return read.documents.map {
            AutomaticOutboundSync.RealmRecord(companyID: scope.companyID, documentType: $0.type.lowercased(), documentID: $0.localID,
                customerID: read.snapshot.customerID, createdAt: $0.createdAt, realmID: scope.realmID, environment: scope.environment)
        }
    }

    /// A send was started (or may have reached the provider) under the row's
    /// saved scope. Reconciling it is never a new write.
    static func isDispatched(_ row: QBODocumentCapture) -> Bool {
        row.dispatchStarted || (row.server.map { [.sending, .uncertain, .confirmed].contains($0.state) } ?? false)
    }

    /// A captured original tied to a saved invoice/estimate may start a new
    /// send only with that document's original-company proof. The saved
    /// documents come from the row's job document and/or local attachment;
    /// when both exist they must name the same documents and customer, or the
    /// row fails closed. Only rows with neither (operator-entered targets with
    /// no saved local document) are outside this gate.
    static func requireRealmProof(for row: QBODocumentCapture, context: ModelContext,
                                  realmProof: ([AutomaticOutboundSync.RealmRecord]) async throws -> Void) async throws {
        var documents: [SavedDocument]?
        var customerID: UUID?
        if let job = row.jobDocument {
            try job.validate(targets: row.targets)
            documents = job.documents.map { .init(type: $0.type, localID: $0.localID) }
            customerID = job.localCustomerID
        }
        if let local = row.localAttachment {
            let localDocuments = try savedDocuments(targets: row.targets, invoiceID: local.invoiceID, estimateID: local.estimateID)
            if let documents {
                guard Set(localDocuments) == Set(documents), local.customerID == customerID else { throw QBODocumentError.invalid }
            }
            documents = localDocuments
            customerID = local.customerID
        }
        guard let documents, let customerID else { return }
        guard !documents.isEmpty, Set(documents).count == documents.count else { throw QBODocumentError.invalid }
        // Exact saved documents read off the main actor, then confirmed against
        // any registered (possibly unsaved) model before the proof check.
        let container = context.container
        let facts = try await Task.detached(priority: .userInitiated) {
            try QBOAttachmentSnapshotReader.documentFacts(container: container, documents: documents, customerID: customerID)
        }.value
        try confirmDocumentFacts(facts, customerID: customerID, context: context)
        try await realmProof(facts.map {
            AutomaticOutboundSync.RealmRecord(companyID: row.scope.companyID, documentType: $0.type.lowercased(), documentID: $0.localID,
                customerID: customerID, createdAt: $0.createdAt, realmID: row.scope.realmID, environment: row.scope.environment)
        })
    }

    /// In-memory (no fetch) confirmation of off-main document facts.
    static func confirmDocumentFacts(_ facts: [DocumentFact], customerID: UUID, context: ModelContext) throws {
        let deleted = Set(context.deletedModelsArray.map(\.persistentModelID))
        let ids = Set(facts.map(\.localID))
        for fact in facts {
            guard !deleted.contains(fact.model) else { throw QBODocumentError.changed }
            // `registeredModel(for:)` force-casts to the requested type, so ask
            // only for the type this identity was read as.
            switch fact.type {
            case "Invoice":
                if let invoice: Invoice = context.registeredModel(for: fact.model) {
                    guard invoice.id == fact.localID, invoice.createdAt == fact.createdAt, invoice.customer?.id == customerID else { throw QBODocumentError.changed }
                }
            case "Estimate":
                if let estimate: Estimate = context.registeredModel(for: fact.model) {
                    guard estimate.id == fact.localID, estimate.createdAt == fact.createdAt, estimate.customer?.id == customerID else { throw QBODocumentError.changed }
                }
            default:
                throw QBODocumentError.invalid
            }
        }
        let known = Set(facts.map(\.model))
        for model in context.insertedModelsArray where !known.contains(model.persistentModelID) {
            if let invoice = model as? Invoice, ids.contains(invoice.id) { throw QBODocumentError.changed }
            if let estimate = model as? Estimate, ids.contains(estimate.id) { throw QBODocumentError.changed }
        }
    }

    /// The one route that sends or reconciles an already-captured original
    /// (Receipts & Bills). A new send first requires saved-document proof and
    /// re-checks the session after that read; a dispatched row only reconciles.
    static func deliverCaptured(_ row: QBODocumentCapture, context: ModelContext, store: QBODocumentCaptureStore,
                                transport: @escaping QBODocumentUploadClient.Transport,
                                check: @escaping () async throws -> Void,
                                realmProof: ([AutomaticOutboundSync.RealmRecord]) async throws -> Void) async throws -> QBODocumentCaptureSession {
        let session = try await QBODocumentCaptureSession(record: row, store: store, check: check)
        let client = QBODocumentUploadClient(transport: transport, check: check)
        if isDispatched(row) {
            try await session.recover(client: client)
        } else {
            try await requireRealmProof(for: row, context: context, realmProof: realmProof)
            try await check()
            try await session.send(client: client)
        }
        try await check()
        guard session.record.server?.state == .confirmed else { throw QBODocumentError.review }
        return session
    }

    nonisolated struct SavedDocument: Hashable, Sendable {
        let type: String
        let localID: UUID
    }

    private static func savedDocuments(targets: [QBODocumentTarget], invoiceID: UUID?,
                                       estimateID: UUID?) throws -> [SavedDocument] {
        guard !targets.isEmpty else { throw QBODocumentError.invalid }
        return try targets.map { target in
            switch target.type {
            case "Invoice":
                guard let invoiceID else { throw QBODocumentError.invalid }
                return .init(type: target.type, localID: invoiceID)
            case "Estimate":
                guard let estimateID else { throw QBODocumentError.invalid }
                return .init(type: target.type, localID: estimateID)
            default:
                throw QBODocumentError.invalid
            }
        }
    }

    static func message(_ error: Error) -> String {
        (error as? QBODocumentError)?.localizedDescription ??
            (error as? AutomaticOutboundSync.RealmError)?.localizedDescription ??
            (error as? WorkspaceProviderAccessError)?.localizedDescription ?? "The original file needs review. Your saved file has not been removed."
    }

    /// Resolve retained media for the current authorized container without
    /// changing the device-specific path stored in the shared CloudKit model.
    static func retainedData(for attachment: ServiceDocumentAttachment, context: ModelContext,
                             dependencies: Dependencies? = nil) async throws -> (QBODocumentCapture, Data) {
        let dependencies = dependencies ?? .live
        let owner = try dependencies.owner(context)
        let attachmentID = attachment.id
        let originals = try await dependencies.store.list(owner).filter {
            ($0.localAttachment?.attachmentID ?? $0.jobDocument?.attachmentID) == attachmentID
        }
        guard try dependencies.owner(context) == owner else { throw QBODocumentError.access }
        guard originals.count == 1, let row = originals.first else { throw QBODocumentError.review }
        let bytes = try await dependencies.store.bytes(owner, row.id)
        try await checkLocalOriginal(row, context: context, retainedOriginal: bytes)
        guard try dependencies.owner(context) == owner else { throw QBODocumentError.access }
        return (row, bytes)
    }

    /// Archive-only read: Keychain access, encrypted journal enumeration,
    /// decryption and hashing run in a private background task. The owner and
    /// exact local original are checked again after the suspension point.
    static func retainedDataForArchive(for attachment: ServiceDocumentAttachment,
                                       context: ModelContext,
                                       reader: QBODocumentRetainedMediaReader? = nil) async throws -> Data {
        let controller = CompanyWorkspaceAccessController.shared
        guard let stamp = controller.operationStamp, !context.hasChanges else { throw QBODocumentError.access }
        let owner = try QBODocumentOwner.captureForBackgroundRead(context: context)
        let attachmentID = attachment.id
        let originalPath = attachment.localFilePath
        let originalKind = attachment.kindRaw
        let originalCustomerID = attachment.customer?.id
        let originalInvoiceID = attachment.invoiceID
        let originalEstimateID = attachment.estimateID
        let originalCallID = attachment.serviceCallID
        let originalFileSize = attachment.fileSizeBytes
        let originalName = attachment.displayName
        let originalType = attachment.contentType
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                       in: .userDomainMask).first else { throw QBODocumentError.storage }
        let reader = reader ?? QBODocumentRetainedMediaReader(
            container: context.container,
            directory: directory.appendingPathComponent("QBOOriginalFiles-v1", isDirectory: true))
        let media = try await reader.read(ownerStorageKey: owner.storageKey,
                                          actorEmail: owner.actorEmail,
                                          attachmentID: attachmentID)
        guard !Task.isCancelled, !context.hasChanges,
              controller.operationStamp == stamp,
              try QBODocumentOwner.captureForBackgroundRead(context: context) == owner else {
            throw QBODocumentError.access
        }
        var fetch = FetchDescriptor<ServiceDocumentAttachment>(predicate: #Predicate { $0.id == attachmentID })
        fetch.fetchLimit = 2
        let matches = try context.fetch(fetch)
        guard matches.count == 1, matches[0] === attachment,
              attachment.localFilePath == originalPath,
              attachment.kindRaw == originalKind,
              attachment.customer?.id == originalCustomerID,
              attachment.invoiceID == originalInvoiceID,
              attachment.estimateID == originalEstimateID,
              attachment.serviceCallID == originalCallID,
              attachment.fileSizeBytes == originalFileSize,
              attachment.displayName == originalName,
              attachment.contentType == originalType else { throw QBODocumentError.changed }
        let row = try JSONDecoder().decode(QBODocumentCapture.self, from: media.metadata)
        try row.validate()
        guard row.owner == owner,
              (row.localAttachment?.attachmentID ?? row.jobDocument?.attachmentID) == attachmentID,
              row.file.sha256 == media.sha256,
              row.file.size == media.bytes.count else { throw QBODocumentError.changed }
        guard controller.operationStamp == stamp,
              try QBODocumentOwner.captureForBackgroundRead(context: context) == owner else {
            throw QBODocumentError.access
        }
        return media.bytes
    }

    static func previewURL(for attachment: ServiceDocumentAttachment, context: ModelContext,
                           dependencies: Dependencies? = nil, directory: URL? = nil) async throws -> URL {
        let original = attachment.localFileURL
        if FileManager.default.fileExists(atPath: original.path) { return original }
        let (row, data) = try await retainedData(for: attachment, context: context, dependencies: dependencies)
        let root = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("GunnAireOriginalPreviews-v1", isDirectory: true)
        let folder = root.appendingPathComponent(row.owner.storageKey, isDirectory: true)
            .appendingPathComponent(row.id.uuidString.lowercased(), isDirectory: true)
        let url = folder.appendingPathComponent(row.file.filename)
        let file = row.file
        // Writing and re-hashing the preview copy happen off the main actor.
        return try await Task.detached(priority: .userInitiated) {
            do {
                if FileManager.default.fileExists(atPath: url.path) { try file.verify(fileData(url)); return url }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                try file.verify(fileData(url))
                return url
            } catch { throw QBODocumentError.storage }
        }.value
    }

    static func captureManual(access: Access, url: URL, call: ServiceCall?, stage: String,
                              targets: [QBODocumentTarget], context: ModelContext,
                              store: QBODocumentCaptureStore? = nil, directory: URL? = nil,
                              save: (ModelContext) throws -> Void = { try $0.save() }) async throws -> QBODocumentCapture {
        try access.check()
        guard ["before", "after", "supporting"].contains(stage) else { throw QBODocumentError.invalid }
        let store = store ?? .device
        guard let call else {
            // Operator-entered destination: `capture` reads, hashes and lists
            // off the main actor and re-checks the business after each await.
            return try await capture(access: access, url: url, targets: targets, job: nil, store: store)
        }
        let jobDestination = try await manualJobDestination(call, targets: targets, context: context)
        try access.check()
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        if stage != "supporting", !mime.hasPrefix("image/") { throw QBODocumentError.photoRequired }
        // Reading and hashing the original, and decrypting the journal headers,
        // both run off the main actor.
        let (data, info) = try await Task.detached(priority: .userInitiated) {
            let data = try fileData(url)
            return (data, try QBODocumentFileInfo(filename: url.lastPathComponent, contentType: mime, data: data))
        }.value
        let rows = try await store.list(access.owner)
        // After suspension: the same business and exactly the same job billing
        // destination, re-read off the main actor and confirmed in memory.
        try access.check()
        guard try await manualJobDestination(call, targets: targets, context: context) == jobDestination else {
            throw QBODocumentError.changed
        }
        try access.check()
        guard let customer = call.customer, customer.id == jobDestination.customerID else { throw QBODocumentError.jobDestination }
        let customerID = jobDestination.customerQuickBooksID, documentID = jobDestination.documentID
        let target = jobDestination.target
        let kind: ServiceDocumentAttachmentKind = stage == "before" ? .beforePhoto : stage == "after" ? .afterPhoto : .receipt
        let existing = rows.filter { matchesCapture($0, scope: access.scope, file: info, targets: targets) }
        guard existing.count <= 1 else { throw QBODocumentError.changed }
        if let listed = existing.first {
            guard let row = try await store.read(access.owner, listed.id),
                  matchesCapture(row, scope: access.scope, file: info, targets: targets),
                  let job = row.jobDocument, job.serviceCallID == call.id, job.localCustomerID == customer.id,
                  job.customerQuickBooksID == customerID, job.stage == stage, job.kind == kind.rawValue,
                  job.documents == [.init(type: target.type, localID: documentID, id: target.id)] else { throw QBODocumentError.changed }
            try await checkLocalOriginal(row, context: context)
            try access.check()
            return row
        }
        let attachmentID = UUID()
        let job = QBODocumentJob(attachmentID: attachmentID, serviceCallID: call.id, localCustomerID: customer.id,
            customerQuickBooksID: customerID, kind: kind.rawValue, stage: stage,
            documents: [.init(type: target.type, localID: documentID, id: target.id)])
        let isInvoice = target.type == "Invoice"
        let row = QBODocumentCapture(id: UUID(), owner: access.owner, scope: access.scope, file: info,
            targets: targets, jobDocument: job, createdAt: Date(),
            localAttachment: .init(attachmentID: attachmentID, customerID: customer.id, customerQuickBooksID: customerID,
                serviceCallID: call.id, invoiceID: isInvoice ? documentID : nil,
                estimateID: isInvoice ? nil : documentID, kind: kind.rawValue))
        // Retain the original even if the operational document or job save fails.
        // Inserted against the off-main listing; a row added meanwhile fails `.changed`.
        try await store.insert(row, data, rows)
        guard let directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { throw QBODocumentError.storage }
        let folder = directory.appendingPathComponent("GunnAire Attachments", isDirectory: true)
        let destination = folder.appendingPathComponent(attachmentID.uuidString + "-" + info.filename)
        // The job copy of the original is written off the main actor.
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }.value
        try access.check()
        guard call.modelContext === context, !call.isDeleted, call.customer === customer else { throw QBODocumentError.changed }
        let attachment = ServiceDocumentAttachment(id: attachmentID, customer: customer, serviceCallID: call.id,
            customerEquipmentID: call.customerEquipmentID, invoiceID: isInvoice ? documentID : nil,
            estimateID: isInvoice ? nil : documentID, kind: kind, displayName: info.filename,
            localFilePath: destination.path, contentType: info.contentType, fileSizeBytes: info.size)
        context.insert(attachment)
        let before = call.beforePhotoCount, after = call.afterPhotoCount, started = call.documentationStartedAt, checklist = call.documentationChecklist
        // Only this job's files (including the pending one) affect its progress.
        let callID = call.id
        call.refreshAttachmentProgress(from: try context.fetch(FetchDescriptor<ServiceDocumentAttachment>(
            predicate: #Predicate { $0.serviceCallID == callID })))
        do { try save(context) }
        catch {
            context.delete(attachment)
            call.beforePhotoCount = before; call.afterPhotoCount = after; call.documentationStartedAt = started; call.documentationChecklist = checklist
            throw QBODocumentError.storage
        }
        return row
    }

    /// The job's single billing destination, recomputed exactly after every
    /// suspension in `captureManual`.
    nonisolated struct ManualJobDestination: Equatable, Sendable {
        let callID: UUID
        let customerID: UUID
        let customerQuickBooksID: String
        let target: QBODocumentTarget
        let documentID: UUID
    }

    /// Resolves the job's billing destination with the unchanged
    /// `JobBillingDocumentLinks` rules over a private context, off the main
    /// actor. The store is authoritative only when this context holds no
    /// unsaved billing edit that could change the answer; any pending invoice,
    /// estimate or payment edit, or an edit to this job or its customer, fails
    /// closed. Checked before and after the read.
    static func manualJobDestination(_ call: ServiceCall, targets: [QBODocumentTarget],
                                     context: ModelContext) async throws -> ManualJobDestination {
        guard call.modelContext === context, !call.isDeleted else { throw QBODocumentError.jobDestination }
        try requireNoPendingBillingEdits(call, context: context)
        let container = context.container, callID = call.id, callModel = call.persistentModelID
        let destination = try await Task.detached(priority: .userInitiated) {
            try QBOAttachmentSnapshotReader.jobDestination(container: container, callID: callID,
                                                           expectedModel: callModel, targets: targets)
        }.value
        try requireNoPendingBillingEdits(call, context: context)
        guard call.modelContext === context, !call.isDeleted, call.id == destination.callID,
              call.customer?.id == destination.customerID else { throw QBODocumentError.changed }
        return destination
    }

    private static func requireNoPendingBillingEdits(_ call: ServiceCall, context: ModelContext) throws {
        let customerID = call.customer?.id
        let pending = context.insertedModelsArray + context.changedModelsArray + context.deletedModelsArray
        for model in pending {
            if model is Invoice || model is Estimate || model is Payment { throw QBODocumentError.changed }
            if let job = model as? ServiceCall, job.id == call.id { throw QBODocumentError.changed }
            if let customer = model as? Customer, customer.id == customerID { throw QBODocumentError.changed }
        }
    }

    /// The captured row's local original must still be exactly the saved file:
    /// read off the main actor by exact ID, confirmed in memory on return.
    @discardableResult
    static func checkLocalOriginal(_ row: QBODocumentCapture, context: ModelContext,
                                   retainedOriginal: Data? = nil) async throws -> SnapshotRead? {
        if let retainedOriginal {
            let file = row.file
            try await Task.detached(priority: .userInitiated) { try file.verify(retainedOriginal) }.value
        }
        guard let id = row.localAttachment?.attachmentID ?? row.jobDocument?.attachmentID else { return nil }
        let container = context.container, targets = row.targets
        let read = try await Task.detached(priority: .userInitiated) {
            try QBOAttachmentSnapshotReader.read(container: container, attachmentID: id, expectedModel: nil,
                                                 targets: targets, retainedOriginal: retainedOriginal)
        }.value
        try confirmInMemory(read, attachment: nil, context: context)
        guard read.snapshot.job == row.jobDocument, read.snapshot.file == row.file,
              row.localAttachment == nil || read.snapshot.localAttachment == row.localAttachment else { throw QBODocumentError.changed }
        return read
    }

    static func applyConfirmed(_ row: QBODocumentCapture, context: ModelContext,
                               retainedOriginal: Data? = nil,
                               save: (ModelContext) throws -> Void = { try $0.save() }) async throws {
        try row.validate()
        guard let id = row.localAttachment?.attachmentID ?? row.jobDocument?.attachmentID,
              let server = row.server, server.state == .confirmed, let identifier = server.providerID else { return }
        guard let read = try await checkLocalOriginal(row, context: context, retainedOriginal: retainedOriginal) else { return }
        // The exact model the off-main read identified, confirmed again in
        // memory after that suspension.
        let attachment = try exactAttachment(read.attachmentModel, id: id, context: context)
        try confirmInMemory(read, attachment: attachment, context: context)
        let oldID = attachment.quickBooksAttachableID, oldKeys = attachment.quickBooksAttachedEntityKeysRaw, oldError = attachment.quickBooksSyncError
        guard oldID == nil || oldID == identifier else { throw QBODocumentError.changed }
        let references = row.targets.map { QuickBooksAttachableReference(EntityRef: .init(type: $0.type, value: $0.id), IncludeOnSend: false) }
        attachment.quickBooksAttachableID = identifier; attachment.markQuickBooksAttached(to: references); attachment.quickBooksSyncError = nil
        do { try save(context) }
        catch {
            attachment.quickBooksAttachableID = oldID; attachment.quickBooksAttachedEntityKeysRaw = oldKeys; attachment.quickBooksSyncError = oldError
            throw QBODocumentError.storage
        }
    }

    @discardableResult
    static func enqueue(_ attachment: ServiceDocumentAttachment, references: [QuickBooksAttachableReference],
                        context: ModelContext, api: QuickBooksDataAPI? = nil,
                        dependencies: Dependencies? = nil) -> Task<Void, Never>? {
        let api = api ?? .shared
        let dependencies = dependencies ?? .live
        guard let access = try? dependencies.access(context, api) else { return nil }
        let identifier = attachment.id, path = attachment.localFilePath
        return Task { @MainActor in
            do {
                try access.check()
                _ = try await upload(attachment, references: references, context: context, api: api,
                                     validate: access.check, dependencies: dependencies)
            }
            catch {
                // In-memory identity only: the same live model in this context.
                guard (try? access.check()) != nil, attachment.modelContext === context, !attachment.isDeleted,
                      attachment.id == identifier, attachment.localFilePath == path else { return }
                let previous = attachment.quickBooksSyncError
                attachment.quickBooksSyncError = message(error)
                do { try context.save() }
                catch { attachment.quickBooksSyncError = previous }
            }
        }
    }
}

/// Exact-ID reads in a private context, run off the main actor. The rules are
/// those of the original main-context snapshot: one attachment, one customer
/// and one document per ID; a document's provider ID unique among saved
/// documents of its type; documents and job owned by the attachment's customer.
nonisolated enum QBOAttachmentSnapshotReader {
    static func read(container: ModelContainer, attachmentID: UUID, expectedModel: PersistentIdentifier?,
                     targets: [QBODocumentTarget], retainedOriginal: Data?) throws -> QBODocumentNativeWorkflow.SnapshotRead {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var fileFetch = FetchDescriptor<ServiceDocumentAttachment>(predicate: #Predicate { $0.id == attachmentID })
        fileFetch.fetchLimit = 2
        let files = try context.fetch(fileFetch)
        if expectedModel == nil, files.isEmpty { throw QBODocumentError.syncPending }
        guard files.count == 1, let attachment = files.first, !attachment.isDeleted,
              expectedModel == nil || attachment.persistentModelID == expectedModel else { throw QBODocumentError.changed }
        guard let customer = attachment.customer,
              attachment.canLinkToQuickBooksInvoiceAttachment || attachment.kind == .receipt,
              let customerReference = QuickBooksBillingIdentity.identifier(customer.quickBooksID) else { throw QBODocumentError.invalid }
        let customerID = customer.id
        var customerFetch = FetchDescriptor<Customer>(predicate: #Predicate { $0.id == customerID })
        customerFetch.fetchLimit = 2
        let customers = try context.fetch(customerFetch)
        guard customers.count == 1, customers.first?.persistentModelID == customer.persistentModelID else { throw QBODocumentError.invalid }
        var documents: [QBODocumentJob.Document] = []
        var facts: [QBODocumentNativeWorkflow.DocumentFact] = []
        for target in try QBODocumentTarget.normalized(targets) {
            switch target.type {
            case "Invoice":
                guard let id = attachment.invoiceID, let invoice = try uniqueInvoice(id: id, context: context),
                      invoice.customer?.persistentModelID == customer.persistentModelID, invoice.quickBooksIdentityReviewMessage == nil,
                      QuickBooksBillingIdentity.identifier(invoice.quickBooksID) == target.id,
                      attachment.serviceCallID == nil || invoice.serviceCallID == nil || attachment.serviceCallID == invoice.serviceCallID else { throw QBODocumentError.invalid }
                documents.append(.init(type: target.type, localID: id, id: target.id))
                facts.append(.init(type: target.type, localID: id, providerID: target.id, createdAt: invoice.createdAt, model: invoice.persistentModelID))
            case "Estimate":
                guard let id = attachment.estimateID, let estimate = try uniqueEstimate(id: id, context: context),
                      estimate.customer?.persistentModelID == customer.persistentModelID,
                      QuickBooksBillingIdentity.identifier(estimate.quickBooksID) == target.id,
                      attachment.serviceCallID == nil || estimate.serviceCallID == nil || attachment.serviceCallID == estimate.serviceCallID || attachment.serviceCallID == estimate.scheduledServiceCallID else { throw QBODocumentError.invalid }
                documents.append(.init(type: target.type, localID: id, id: target.id))
                facts.append(.init(type: target.type, localID: id, providerID: target.id, createdAt: estimate.createdAt, model: estimate.persistentModelID))
            default: throw QBODocumentError.invalid
            }
        }
        guard !documents.isEmpty else { throw QBODocumentError.invalid }
        let job: QBODocumentJob?
        var callModel: PersistentIdentifier?
        if let id = attachment.serviceCallID {
            var callFetch = FetchDescriptor<ServiceCall>(predicate: #Predicate { $0.id == id })
            callFetch.fetchLimit = 2
            let calls = try context.fetch(callFetch)
            guard calls.count == 1, calls[0].customer?.persistentModelID == customer.persistentModelID else { throw QBODocumentError.invalid }
            callModel = calls[0].persistentModelID
            let stage = attachment.kind == .beforePhoto ? "before" : attachment.kind == .afterPhoto ? "after" : "supporting"
            job = .init(attachmentID: attachment.id, serviceCallID: id, localCustomerID: customer.id,
                        customerQuickBooksID: customerReference, kind: attachment.kindRaw, stage: stage, documents: documents)
            try job?.validate(targets: targets)
        } else { job = nil }
        let bytes: Data
        if FileManager.default.fileExists(atPath: attachment.localFileURL.path) || retainedOriginal == nil {
            bytes = try QBODocumentNativeWorkflow.fileData(attachment.localFileURL)
        } else {
            // A CloudKit path from another device is not a local file. Only
            // explicitly verified retained bytes can stand in for that path.
            guard let original = retainedOriginal, original.count == attachment.fileSizeBytes else { throw QBODocumentError.changed }
            bytes = original
        }
        let snapshot = try QBODocumentNativeWorkflow.AttachmentSnapshot(id: attachment.id, customerID: customer.id,
            customerQuickBooksID: customerReference, serviceCallID: attachment.serviceCallID,
            invoiceID: attachment.invoiceID, estimateID: attachment.estimateID, kind: attachment.kindRaw,
            filename: attachment.displayName, path: attachment.localFilePath,
            file: .init(filename: QBODocumentNativeWorkflow.filename(attachment), contentType: attachment.contentType, data: bytes), job: job)
        return .init(snapshot: snapshot, attachmentModel: attachment.persistentModelID, customerModel: customer.persistentModelID,
                     documents: facts, callModel: callModel)
    }

    /// Exact saved documents for a captured row (no attachment model needed):
    /// one per ID, owned by `customerID`.
    static func documentFacts(container: ModelContainer, documents: [QBODocumentNativeWorkflow.SavedDocument],
                              customerID: UUID) throws -> [QBODocumentNativeWorkflow.DocumentFact] {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return try documents.map { document in
            switch document.type {
            case "Invoice":
                guard let invoice = try uniqueInvoice(id: document.localID, context: context),
                      invoice.customer?.id == customerID else { throw QBODocumentError.invalid }
                return .init(type: document.type, localID: document.localID,
                             providerID: QuickBooksBillingIdentity.identifier(invoice.quickBooksID) ?? "",
                             createdAt: invoice.createdAt, model: invoice.persistentModelID)
            case "Estimate":
                guard let estimate = try uniqueEstimate(id: document.localID, context: context),
                      estimate.customer?.id == customerID else { throw QBODocumentError.invalid }
                return .init(type: document.type, localID: document.localID,
                             providerID: QuickBooksBillingIdentity.identifier(estimate.quickBooksID) ?? "",
                             createdAt: estimate.createdAt, model: estimate.persistentModelID)
            default:
                throw QBODocumentError.invalid
            }
        }
    }

    /// The job's billing destination: the exact job (by ID and model identity)
    /// and the unchanged `JobBillingDocumentLinks` resolution, in a private context.
    static func jobDestination(container: ModelContainer, callID: UUID, expectedModel: PersistentIdentifier,
                               targets: [QBODocumentTarget]) throws -> QBODocumentNativeWorkflow.ManualJobDestination {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var callFetch = FetchDescriptor<ServiceCall>(predicate: #Predicate { $0.id == callID })
        callFetch.fetchLimit = 2
        let calls = try context.fetch(callFetch)
        guard calls.count == 1, let call = calls.first, call.persistentModelID == expectedModel, let customer = call.customer,
              let customerReference = QuickBooksBillingIdentity.identifier(customer.quickBooksID) else { throw QBODocumentError.jobDestination }
        // Billing resolution needs the saved invoice, estimate and payment
        // sets; they are read here, in a private context off the main actor.
        let invoices = try context.fetch(FetchDescriptor<Invoice>()), estimates = try context.fetch(FetchDescriptor<Estimate>())
        let payments = try context.fetch(FetchDescriptor<Payment>())
        guard let destination = JobBillingDocumentLinks.attachmentDestination(for: call, invoices: invoices, estimates: estimates, payments: payments),
              targets == [.init(type: destination.isInvoice ? "Invoice" : "Estimate", id: destination.providerID)] else {
            throw QBODocumentError.jobDestination
        }
        return .init(callID: call.id, customerID: customer.id, customerQuickBooksID: customerReference,
                     target: .init(type: destination.isInvoice ? "Invoice" : "Estimate", id: destination.providerID),
                     documentID: destination.documentID)
    }

    /// `JobBillingDocumentLinks.invoice(id:in:)` with exact reads: unique by ID,
    /// and its provider ID (if any) held by no other saved invoice.
    static func uniqueInvoice(id: UUID, context: ModelContext) throws -> Invoice? {
        var fetch = FetchDescriptor<Invoice>(predicate: #Predicate { $0.id == id })
        fetch.fetchLimit = 2
        let matches = try context.fetch(fetch)
        guard matches.count == 1, let invoice = matches.first else { return nil }
        if let provider = QuickBooksBillingIdentity.identifier(invoice.quickBooksID) {
            let linked = try context.fetch(FetchDescriptor<Invoice>(predicate: #Predicate { $0.quickBooksID != nil }))
            guard linked.filter({ QuickBooksBillingIdentity.identifier($0.quickBooksID) == provider }).count == 1 else { return nil }
        }
        return invoice
    }

    static func uniqueEstimate(id: UUID, context: ModelContext) throws -> Estimate? {
        var fetch = FetchDescriptor<Estimate>(predicate: #Predicate { $0.id == id })
        fetch.fetchLimit = 2
        let matches = try context.fetch(fetch)
        guard matches.count == 1, let estimate = matches.first else { return nil }
        if let provider = QuickBooksBillingIdentity.identifier(estimate.quickBooksID) {
            let linked = try context.fetch(FetchDescriptor<Estimate>(predicate: #Predicate { $0.quickBooksID != nil }))
            guard linked.filter({ QuickBooksBillingIdentity.identifier($0.quickBooksID) == provider }).count == 1 else { return nil }
        }
        return estimate
    }
}
