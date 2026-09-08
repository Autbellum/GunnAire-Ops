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
        static var live: Self {
            .init(owner: QBODocumentOwner.capture, access: QBODocumentNativeWorkflow.access, store: .device,
                  transport: GunnAireBackendService.documentUploadRequest)
        }
    }

    static func access(context: ModelContext, api: QuickBooksDataAPI = .shared) throws -> Access {
        let owner = try QBODocumentOwner.capture(context: context)
        let workflow = try api.captureWorkspaceWorkflow()
        guard workflow.companyID == owner.companyID, let realm = workflow.realmID else { throw QBODocumentError.access }
        let scope = QBODocumentScope(companyID: owner.companyID, realmID: realm, environment: workflow.environment)
        try scope.validate()
        return Access(owner: owner, scope: scope, check: {
            try workflow.check()
            guard try QBODocumentOwner.capture(context: context) == owner else { throw QBODocumentError.access }
        })
    }

    static func fileData(_ url: URL) throws -> Data {
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
                        store: QBODocumentCaptureStore? = nil) throws -> QBODocumentCapture {
        try access.check()
        let store = store ?? .device
        let data = try fileData(url)
        let file = try QBODocumentFileInfo(filename: filename ?? url.lastPathComponent,
            contentType: contentType ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream", data: data)
        let targets = try QBODocumentTarget.normalized(targets)
        try job?.validate(targets: targets)
        let rows = try store.list(access.owner)
        let matches = rows.filter { !$0.cancelledLocally && $0.server?.state != .cancelled && $0.scope == access.scope && $0.file == file && $0.targets == targets }
        guard matches.count <= 1 else { throw QBODocumentError.changed }
        if let original = matches.first {
            guard original.jobDocument == job, original.localAttachment == localAttachment else { throw QBODocumentError.changed }
            try file.verify(store.bytes(access.owner, original.id))
            return original
        }
        let row = QBODocumentCapture(id: UUID(), owner: access.owner, scope: access.scope, file: file,
                                    targets: targets, jobDocument: job, createdAt: Date(), localAttachment: localAttachment)
        try store.write(row, nil, data)
        return row
    }

    struct AttachmentSnapshot: Equatable {
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

    static func filename(_ attachment: ServiceDocumentAttachment) -> String {
        // Older document labels omit the extension. Preserve the readable
        // label while retaining the actual file type; never change its bytes.
        let name = attachment.displayName
        if (name as NSString).pathExtension.isEmpty, !attachment.localFileURL.pathExtension.isEmpty {
            return name + "." + attachment.localFileURL.pathExtension
        }
        return name
    }

    static func snapshot(_ attachment: ServiceDocumentAttachment, targets: [QBODocumentTarget], context: ModelContext) throws -> AttachmentSnapshot {
        let files = try context.fetch(FetchDescriptor<ServiceDocumentAttachment>()).filter { $0.id == attachment.id }
        guard files.count == 1, files.first === attachment, !attachment.isDeleted else { throw QBODocumentError.changed }
        let customers = try context.fetch(FetchDescriptor<Customer>())
        guard let customer = attachment.customer, customers.contains(where: { $0 === customer }),
              customers.filter({ $0.id == customer.id }).count == 1,
              attachment.canLinkToQuickBooksInvoiceAttachment || attachment.kind == .receipt,
              let customerReference = QuickBooksBillingIdentity.identifier(customer.quickBooksID) else { throw QBODocumentError.invalid }
        let invoices = try context.fetch(FetchDescriptor<Invoice>())
        let estimates = try context.fetch(FetchDescriptor<Estimate>())
        var documents: [QBODocumentJob.Document] = []
        for target in try QBODocumentTarget.normalized(targets) {
            switch target.type {
            case "Invoice":
                guard let id = attachment.invoiceID, let invoice = JobBillingDocumentLinks.invoice(id: id, in: invoices),
                      invoice.customer === customer, invoice.quickBooksIdentityReviewMessage == nil,
                      QuickBooksBillingIdentity.identifier(invoice.quickBooksID) == target.id,
                      attachment.serviceCallID == nil || invoice.serviceCallID == nil || attachment.serviceCallID == invoice.serviceCallID else { throw QBODocumentError.invalid }
                documents.append(.init(type: target.type, localID: id, id: target.id))
            case "Estimate":
                guard let id = attachment.estimateID, let estimate = JobBillingDocumentLinks.estimate(id: id, in: estimates),
                      estimate.customer === customer, QuickBooksBillingIdentity.identifier(estimate.quickBooksID) == target.id,
                      attachment.serviceCallID == nil || estimate.serviceCallID == nil || attachment.serviceCallID == estimate.serviceCallID || attachment.serviceCallID == estimate.scheduledServiceCallID else { throw QBODocumentError.invalid }
                documents.append(.init(type: target.type, localID: id, id: target.id))
            default: throw QBODocumentError.invalid
            }
        }
        guard !documents.isEmpty else { throw QBODocumentError.invalid }
        let job: QBODocumentJob?
        if let id = attachment.serviceCallID {
            let calls = try context.fetch(FetchDescriptor<ServiceCall>()).filter { $0.id == id }
            guard calls.count == 1, calls[0].customer === customer else { throw QBODocumentError.invalid }
            let stage = attachment.kind == .beforePhoto ? "before" : attachment.kind == .afterPhoto ? "after" : "supporting"
            job = .init(attachmentID: attachment.id, serviceCallID: id, localCustomerID: customer.id,
                        customerQuickBooksID: customerReference, kind: attachment.kindRaw, stage: stage, documents: documents)
            try job?.validate(targets: targets)
        } else { job = nil }
        return try .init(id: attachment.id, customerID: customer.id, customerQuickBooksID: customerReference, serviceCallID: attachment.serviceCallID,
            invoiceID: attachment.invoiceID, estimateID: attachment.estimateID, kind: attachment.kindRaw,
            filename: attachment.displayName, path: attachment.localFilePath,
            file: .init(filename: filename(attachment), contentType: attachment.contentType, data: fileData(attachment.localFileURL)), job: job)
    }

    /// All attachment entry points share this operation. A late result cannot
    /// relabel another local file; failed saves retain the server-owned original
    /// so the next review can apply it without uploading another copy.
    static func upload(_ attachment: ServiceDocumentAttachment, references: [QuickBooksAttachableReference], context: ModelContext,
                       api: QuickBooksDataAPI = .shared, validate: @escaping () throws -> Void = {},
                       dependencies: Dependencies? = nil,
                       save: (ModelContext) throws -> Void = { try $0.save() }) async throws -> String {
        try validate()
        let dependencies = dependencies ?? .live
        let access = try dependencies.access(context, api)
        let targets = try QBODocumentTarget.normalized(references.map { .init(type: $0.EntityRef.type, id: $0.EntityRef.value) })
        let original = try snapshot(attachment, targets: targets, context: context)
        if attachment.quickBooksAttachableID != nil && !attachment.isQuickBooksAttached(to: references) {
            // Extending an existing provider file's links needs its own reviewed
            // metadata operation, not a silent second upload of the same bytes.
            throw QBODocumentError.review
        }
        let store = dependencies.store
        let row = try capture(access: access, url: attachment.localFileURL, filename: original.file.filename,
                              contentType: attachment.contentType, targets: targets, job: original.job,
                              localAttachment: original.localAttachment, store: store)
        let check = {
            try access.check(); try validate()
            guard try snapshot(attachment, targets: targets, context: context) == original else { throw QBODocumentError.changed }
        }
        let session = try QBODocumentCaptureSession(record: row, store: store, check: check)
        let client = QBODocumentUploadClient(transport: dependencies.transport, check: check)
        if row.dispatchStarted || (row.server.map { [.sending, .uncertain, .confirmed].contains($0.state) } ?? false) { try await session.recover(client: client) }
        else { try await session.send(client: client) }
        try check()
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
        let acknowledged = try QBODocumentCaptureSession(record: session.record, store: store, check: access.check)
        try acknowledged.markLocalApplied()
        return identifier
    }

    static func message(_ error: Error) -> String {
        (error as? QBODocumentError)?.localizedDescription ??
            (error as? WorkspaceProviderAccessError)?.localizedDescription ?? "The original file needs review. Your saved file has not been removed."
    }

    static func captureManual(access: Access, url: URL, call: ServiceCall?, stage: String,
                              targets: [QBODocumentTarget], context: ModelContext,
                              store: QBODocumentCaptureStore? = nil, directory: URL? = nil,
                              save: (ModelContext) throws -> Void = { try $0.save() }) throws -> QBODocumentCapture {
        try access.check()
        guard ["before", "after", "supporting"].contains(stage) else { throw QBODocumentError.invalid }
        let store = store ?? .device
        guard let call else { return try capture(access: access, url: url, targets: targets, job: nil, store: store) }
        let calls = try context.fetch(FetchDescriptor<ServiceCall>()).filter { $0.id == call.id }
        guard calls.count == 1, calls.first === call, let customer = call.customer,
              let customerID = QuickBooksBillingIdentity.identifier(customer.quickBooksID) else { throw QBODocumentError.jobDestination }
        let invoices = try context.fetch(FetchDescriptor<Invoice>()), estimates = try context.fetch(FetchDescriptor<Estimate>())
        let payments = try context.fetch(FetchDescriptor<Payment>())
        guard let target = JobBillingDocumentLinks.attachmentTarget(for: call, invoices: invoices, estimates: estimates, payments: payments),
              targets == [.init(type: target.type.rawValue, id: target.id)] else { throw QBODocumentError.jobDestination }
        let documentID: UUID?
        if target.type == .invoice { documentID = JobBillingDocumentLinks.invoice(for: call, in: invoices, payments: payments)?.id }
        else { documentID = JobBillingDocumentLinks.estimate(for: call, in: estimates)?.id }
        guard let documentID else { throw QBODocumentError.jobDestination }
        let data = try fileData(url)
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let info = try QBODocumentFileInfo(filename: url.lastPathComponent, contentType: mime, data: data)
        if stage != "supporting", !mime.hasPrefix("image/") { throw QBODocumentError.photoRequired }
        let kind: ServiceDocumentAttachmentKind = stage == "before" ? .beforePhoto : stage == "after" ? .afterPhoto : .receipt
        let existing = try store.list(access.owner).filter {
            !$0.cancelledLocally && $0.server?.state != .cancelled && $0.scope == access.scope && $0.file == info && $0.targets == targets
        }
        guard existing.count <= 1 else { throw QBODocumentError.changed }
        if let row = existing.first {
            guard let job = row.jobDocument, job.serviceCallID == call.id, job.localCustomerID == customer.id,
                  job.customerQuickBooksID == customerID, job.stage == stage, job.kind == kind.rawValue,
                  job.documents == [.init(type: target.type.rawValue, localID: documentID, id: target.id)] else { throw QBODocumentError.changed }
            try checkLocalOriginal(row, context: context)
            return row
        }
        let attachmentID = UUID()
        let job = QBODocumentJob(attachmentID: attachmentID, serviceCallID: call.id, localCustomerID: customer.id,
            customerQuickBooksID: customerID, kind: kind.rawValue, stage: stage,
            documents: [.init(type: target.type.rawValue, localID: documentID, id: target.id)])
        let row = QBODocumentCapture(id: UUID(), owner: access.owner, scope: access.scope, file: info,
            targets: targets, jobDocument: job, createdAt: Date(),
            localAttachment: .init(attachmentID: attachmentID, customerID: customer.id, customerQuickBooksID: customerID,
                serviceCallID: call.id, invoiceID: target.type == .invoice ? documentID : nil,
                estimateID: target.type == .estimate ? documentID : nil, kind: kind.rawValue))
        // Retain the original even if the operational document or job save fails.
        try store.write(row, nil, data)
        guard let directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { throw QBODocumentError.storage }
        let folder = directory.appendingPathComponent("GunnAire Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(attachmentID.uuidString + "-" + info.filename)
        try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let attachment = ServiceDocumentAttachment(id: attachmentID, customer: customer, serviceCallID: call.id,
            customerEquipmentID: call.customerEquipmentID, invoiceID: target.type == .invoice ? documentID : nil,
            estimateID: target.type == .estimate ? documentID : nil, kind: kind, displayName: info.filename,
            localFilePath: destination.path, contentType: info.contentType, fileSizeBytes: info.size)
        context.insert(attachment)
        let before = call.beforePhotoCount, after = call.afterPhotoCount, started = call.documentationStartedAt, checklist = call.documentationChecklist
        call.refreshAttachmentProgress(from: try context.fetch(FetchDescriptor<ServiceDocumentAttachment>()))
        do { try save(context) }
        catch {
            context.delete(attachment)
            call.beforePhotoCount = before; call.afterPhotoCount = after; call.documentationStartedAt = started; call.documentationChecklist = checklist
            throw QBODocumentError.storage
        }
        return row
    }

    static func checkLocalOriginal(_ row: QBODocumentCapture, context: ModelContext) throws {
        guard let id = row.localAttachment?.attachmentID ?? row.jobDocument?.attachmentID else { return }
        let files = try context.fetch(FetchDescriptor<ServiceDocumentAttachment>()).filter { $0.id == id }
        guard files.count == 1 else { throw QBODocumentError.changed }
        let original = try snapshot(files[0], targets: row.targets, context: context)
        guard original.job == row.jobDocument, original.file == row.file,
              row.localAttachment == nil || original.localAttachment == row.localAttachment else { throw QBODocumentError.changed }
    }

    static func applyConfirmed(_ row: QBODocumentCapture, context: ModelContext,
                               save: (ModelContext) throws -> Void = { try $0.save() }) throws {
        try row.validate()
        guard let id = row.localAttachment?.attachmentID ?? row.jobDocument?.attachmentID,
              let server = row.server, server.state == .confirmed, let identifier = server.providerID else { return }
        try checkLocalOriginal(row, context: context)
        let files = try context.fetch(FetchDescriptor<ServiceDocumentAttachment>()).filter { $0.id == id }
        guard files.count == 1 else { throw QBODocumentError.changed }
        let attachment = files[0]
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
                        context: ModelContext, api: QuickBooksDataAPI = .shared,
                        dependencies: Dependencies? = nil) -> Task<Void, Never>? {
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
                guard (try? access.check()) != nil,
                      let current = try? context.fetch(FetchDescriptor<ServiceDocumentAttachment>()).filter({ $0.id == identifier }),
                      current.count == 1, current.first === attachment, attachment.localFilePath == path else { return }
                let previous = attachment.quickBooksSyncError
                attachment.quickBooksSyncError = message(error)
                do { try context.save() }
                catch { attachment.quickBooksSyncError = previous }
            }
        }
    }
}
